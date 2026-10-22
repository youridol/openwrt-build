-- Copyright (C) 2026 openwrt-build
-- 判定链路图 / 改道状态图（纯 SVG 生成，无外部依赖）
-- 设计依据: docs/adr/0006-domain-routing-and-reroute.md
--
-- ── 为什么单独一个模块 ────────────────────────────────────────────
--
-- 1. 两张图既要在页面里显示，也要能被本地脚本渲染成图片核对布局。
--    放在 general.lua 里就只能靠「打开页面看一眼」，而布局错位
--    （节点压线、标签盖住连线、文字超出 viewBox）在浏览器里
--    往往被当成「样式问题」而不是「坐标算错」。
--    抽出来之后 tools/render-dnschain-diagrams.py 可以直接喂假数据、
--    出 PNG，坐标对不对一目了然。
--
-- 2. 几何常量集中在本文件顶部。改一次坐标不用翻 1100 行的页面文件。
--
-- ── 硬约束（都踩过，别改回去）────────────────────────────────────
--
--   · 颜色一律走 CSS 变量（--dc-ok/warn/bad/info），跟随明暗主题。
--     写死色值会在暗色主题下变成「绿徽标配浅背景」。
--   · 连线用三次贝塞尔 C 指令。直角折线（H/V/H）在分叉处是硬拐角，
--     视觉上像「断链」—— 这正是 v0.12.5 修掉的问题。
--   · 曲线控制点 dx 必须 ≤ (x2-x1)/2。否则第二控制点跑到第一控制点
--     左边，曲线在中间兜回来、出现自交扭结，看起来也是断链。
--   · 节点必须有填充（var(--dc-surface)）。fill="none" 时连线从节点
--     内部透出来，同样像断链。
--   · marker id 必须带前缀。同一页有多张 SVG 时 id 是**文档级全局**的，
--     同名 marker 会全部解析到第一个定义 —— 颜色就串了。
--   · 所有动态文本必须转义。域名与原因串来自配置文件与探测结果，
--     含 & < > 时会让整个 SVG 解析失败（页面变成一片空白）。
--
-- ⚠️ 必须显式引入 translate（v0.13.0 实测踩过）。
--
--   在 LuCI 的 CBI 模型文件里，`translate` / `_` 是由 luci.i18n 注入到
--   全局环境的 —— 但那只在 **dispatcher 的请求上下文**里成立。
--   本模块是被 require 的普通 Lua 模块，直接在函数体里写裸
--   `translate("…")` 会抛：
--       attempt to call global 'translate' (a nil value)
--   而这个错误发生在 **cfgvalue() 执行期间**，表现为整个页面 500，
--   且错误信息只说 translate 是 nil，不提是哪个文件缺引入。
--
--   更隐蔽的一点：本地 tools/check-dnschain-lua.py 用 lupa 跑测试时
--   预先注入了 translate 桩，所以本地全绿、路由器上 500。
--   测试桩与真实环境不一致正是这类问题的温床 ——
--   故这里显式 require，并在测试脚本里**不再注入 translate 桩**，
--   让本地与路由器行为一致。
local i18n = require "luci.i18n"
local translate = i18n.translate

local D = {}

-----------------------------------------------------------------------
-- 文本转义
-----------------------------------------------------------------------
local function esc(s)
	s = tostring(s or "")
	s = s:gsub("&", "&amp;")
	s = s:gsub("<", "&lt;")
	s = s:gsub(">", "&gt;")
	s = s:gsub('"', "&quot;")
	return s
end
D.esc = esc

-----------------------------------------------------------------------
-- 语义色（与 dnschain.css 的令牌一一对应）
-----------------------------------------------------------------------
local C = {
	ok   = "var(--dc-ok)",
	warn = "var(--dc-warn)",
	bad  = "var(--dc-bad)",
	info = "var(--dc-info)",
	mute = "var(--dc-idle)",
}
D.colors = C

-----------------------------------------------------------------------
-- 箭头定义：按状态色各一个
--
-- 只定义一个固定灰色时，红/绿连线配灰箭头，看起来像没连上。
-----------------------------------------------------------------------
local function defs(prefix)
	local out = { "<defs>" }
	for _, tone in ipairs({ "ok", "warn", "bad", "info", "mute" }) do
		out[#out + 1] = string.format(
			'<marker id="%s-a-%s" viewBox="0 0 10 10" refX="9" refY="5" ' ..
			'markerWidth="7" markerHeight="7" orient="auto-start-reverse">' ..
			'<path d="M 0 0 L 10 5 L 0 10 z" fill="%s"/></marker>',
			prefix, tone, C[tone])
	end
	out[#out + 1] = "</defs>"
	return table.concat(out)
end

local function arrow(prefix, tone)
	return string.format("url(#%s-a-%s)", prefix, tone or "ok")
end

-----------------------------------------------------------------------
-- 连线
--
-- hline：两端垂直对齐时的水平线，中点轻微下沉（思维导图的「生长感」）。
-- curve：从 (x1,y1) 平滑过渡到 (x2,y2) 的 S 形三次贝塞尔。
--
-- ⚠️ dx 上限 (x2-x1)/2 是硬约束，见文件头。
-----------------------------------------------------------------------
local function hline(x1, x2, y, tone, prefix, dash)
	local mid = math.floor((x1 + x2) / 2)
	local dip = 3
	return string.format(
		'<path d="M %d %d Q %d %d, %d %d" stroke="%s" stroke-width="2.5" ' ..
		'fill="none" stroke-linecap="round" marker-end="%s"%s/>',
		x1, y, mid, y + dip, x2, y, C[tone or "ok"], arrow(prefix, tone),
		dash and ' stroke-dasharray="5 4"' or "")
end

local function curve(x1, y1, x2, y2, tone, prefix)
	local dy = math.abs(y2 - y1)
	local dx = math.floor(dy * 0.62)
	local cap = math.floor((x2 - x1) / 2)
	if dx > cap then dx = cap end
	if dx < 6 then dx = 6 end
	return string.format(
		'<path d="M %d %d C %d %d, %d %d, %d %d" stroke="%s" ' ..
		'stroke-width="2.5" fill="none" stroke-linecap="round" marker-end="%s"/>',
		x1, y1, x1 + dx, y1, x2 - dx, y2, x2, y2, C[tone or "ok"], arrow(prefix, tone))
end

--- 竖虚线（用于「上一阶段 → 下一阶段」的跨段连接）
local function vline(x, y1, y2, tone, prefix)
	return string.format(
		'<path d="M %d %d L %d %d" stroke="%s" stroke-width="2" ' ..
		'fill="none" stroke-dasharray="5 4" marker-end="%s" opacity="0.75"/>',
		x, y1, x, y2, C[tone or "mute"], arrow(prefix, tone or "mute"))
end

-----------------------------------------------------------------------
-- 节点
--
-- 三行文字：标题 / 副标题 / 说明（说明可选，需要 h >= 54）。
-- 左侧一个小圆点表状态色 —— 扫一眼就能看出哪一段是红的。
-----------------------------------------------------------------------
local function box(x, y, w, h, title, sub, note, tone)
	local col = C[tone or "ok"]
	local out = {
		string.format(
			'<g><rect x="%d" y="%d" width="%d" height="%d" rx="9" ' ..
			'fill="var(--dc-surface)" stroke="%s" stroke-width="2"/>',
			x, y, w, h, col),
		string.format('<circle cx="%d" cy="%d" r="4" fill="%s"/>', x + 12, y + 16, col),
		string.format(
			'<text x="%d" y="%d" font-size="13" font-weight="600" fill="currentColor">%s</text>',
			x + 24, y + 21, esc(title)),
	}
	if sub and sub ~= "" then
		out[#out + 1] = string.format(
			'<text x="%d" y="%d" font-size="11" fill="currentColor" opacity="0.72">%s</text>',
			x + 24, y + 37, esc(sub))
	end
	if note and note ~= "" then
		out[#out + 1] = string.format(
			'<text x="%d" y="%d" font-size="10" fill="currentColor" opacity="0.55">%s</text>',
			x + 24, y + 51, esc(note))
	end
	out[#out + 1] = "</g>"
	return table.concat(out)
end

--- 独立文本（标注用）
local function label(x, y, txt, tone, size, opacity)
	return string.format(
		'<text x="%d" y="%d" font-size="%d" fill="%s" opacity="%s">%s</text>',
		x, y, size or 10, tone and C[tone] or "currentColor",
		opacity or "0.7", esc(txt))
end

-----------------------------------------------------------------------
-- 判定链路图（思维链路图）
--
-- 要回答的问题是「这个域名会怎么走、在哪一步出的问题」，所以图分
-- **上下两段**，对应两个阶段：
--
--   上段：域名 → 归属 → 首选链路     （静态判定，只看配置与名单）
--   下段：首选链探测 → 结论           （动态判定，看链路通不通）
--
-- 为什么按「结果」分组而不是按「来源」分组：
--   用户真正想知道的是「它走直连还是走代理」，按结果分组时
--   每两条线汇聚到同一个节点，一眼就能看出归属与去向的对应关系；
--   按来源分组则会出现两条长斜线跨越整张图（uncovered → 直连
--   要跨过 代理 那一行），正是「看起来像断链」的典型形态。
--
-- opts 全部可选，缺省时显示静态说明（不依赖运行时数据）。
-----------------------------------------------------------------------
local ROUTE_W, ROUTE_H = 720, 520

function D.route_map(opts)
	opts = opts or {}

	local p = "dcrt"
	local NW2, NW3 = 196, 208
	local X1, X2, X3 = 14, 190, 440
	local NH, GAP = 46, 14

	-- 上段四行（按去向分组：前两行→直连，后两行→代理）
	local A_Y = { 16, 76, 136, 196 }
	local y_dom = A_Y[1]
	local y_for = A_Y[3]
	local y_merged_dom = math.floor((A_Y[1] + A_Y[2]) / 2) - math.floor(NH / 2)
	local y_merged_for = math.floor((A_Y[3] + A_Y[4]) / 2) - math.floor(NH / 2)

	-- 下段三行
	local B_Y = { 292, 352, 412 }
	local y_root_b = 292 - NH - 20

	-- 底部两行说明的基线。
	--
	-- ⚠️ 必须给下段最后一个节点（双链故障，底边 = B_Y[3] + NH = 458）
	-- 留出字高（10px 字号的上沿约在基线 −8）。v0.13.0 初版把第一行
	-- 放在 486-26 = 460，只比节点底边低 2px，实际渲染时文字压进了
	-- 「双链故障」那个框里 —— 而纯几何断言（只看 viewBox 越界）发现不了。
	-- 现在改成 486 / 504，并让 viewBox 高度留到 520（504 + 字高 + 余量）。
	local y_note1 = 486
	local y_note2 = 504

	local o = {}
	-- ⚠️ 必须同时给出 width/height 固有尺寸（v0.13.0 实测修正）。
	--
	-- 只写 viewBox 时，SVG 没有「固有尺寸」，CSS 的 `width:auto`
	-- 会回落到 `100%` —— 图被拉伸到容器宽度 1246px，高度等比放大到
	-- 900px（520 × 1246/720），字号从 11px 涨到 19px。
	-- 症状：一张 720×520 的图占满整屏还多，用户滚动时只看到几个
	-- 放大的框，反馈「导图看不到」。DOM 里 SVG 在、内容完整、
	-- 纯几何断言全绿 —— 问题只在「没有固有尺寸」这一点上。
	--
	-- 写死 width/height 后浏览器按 720×520 渲染，CSS 里再用
	-- max-width:100% 兜住窄屏。
	o[#o + 1] = string.format(
		'<div class="dc-chain dc-chain--map"><svg viewBox="0 0 %d %d" ' ..
		'width="%d" height="%d" role="img" ' ..
		'aria-label="%s">', ROUTE_W, ROUTE_H, ROUTE_W, ROUTE_H,
		translate("域名判定链路图"))
	o[#o + 1] = defs(p)

	--------------------------------------------------------------------
	-- 上段连线
	--------------------------------------------------------------------
	local x_root_r = X1 + 120
	local x2_l = X2
	local x2_r = X2 + NW2
	local x3_l = X3

	-- 根 → 四个归属分支（从同一点放射，错开会在节点边缘留小尖角）
	local root_cy = A_Y[1] + math.floor(NH / 2) - 12
	for i = 1, 4 do
		local cy = A_Y[i] + math.floor(NH / 2)
		o[#o + 1] = curve(x_root_r, root_cy, x2_l, cy, "info", p)
	end

	-- 四个归属 → 两个去向
	o[#o + 1] = curve(x2_r, A_Y[1] + math.floor(NH / 2), x3_l,
		y_merged_dom + math.floor(NH / 2), "ok", p)
	o[#o + 1] = curve(x2_r, A_Y[2] + math.floor(NH / 2), x3_l,
		y_merged_dom + math.floor(NH / 2), "ok", p)
	o[#o + 1] = curve(x2_r, A_Y[3] + math.floor(NH / 2), x3_l,
		y_merged_for + math.floor(NH / 2), "info", p)
	o[#o + 1] = curve(x2_r, A_Y[4] + math.floor(NH / 2), x3_l,
		y_merged_for + math.floor(NH / 2), "info", p)

	--------------------------------------------------------------------
	-- 上段节点
	--------------------------------------------------------------------
	o[#o + 1] = box(X1, A_Y[1], 120, NH, translate("域名"), translate("用户录入"), nil, "info")

	o[#o + 1] = box(X2, A_Y[1], NW2, NH, translate("自定义 · 国内"),
		"domains.domestic", nil, "ok")
	o[#o + 1] = box(X2, A_Y[2], NW2, NH, translate("未覆盖"),
		translate("名单里没有"), nil, "warn")
	o[#o + 1] = box(X2, A_Y[3], NW2, NH, translate("自定义 · 国外"),
		"domains.foreign", nil, "info")
	o[#o + 1] = box(X2, A_Y[4], NW2, NH, translate("数据库命中"),
		translate("gfw 名单"), nil, "info")

	o[#o + 1] = box(X3, y_merged_dom, NW3, NH, translate("直连链路"),
		":" .. tostring(opts.entry_port or "5353"), nil, "ok")
	o[#o + 1] = box(X3, y_merged_for, NW3, NH, translate("代理链路"),
		":" .. tostring(opts.foreign_port or "5336"), nil, "info")

	--------------------------------------------------------------------
	-- 上段 → 下段的跨段连接
	--------------------------------------------------------------------
	o[#o + 1] = vline(X1 + 60, A_Y[1] + NH + 2, y_root_b - 2, "mute", p)
	o[#o + 1] = label(X1 + 68, A_Y[1] + NH + 40, translate("归属确定后"), "mute", 10, "0.6")
	o[#o + 1] = label(X1 + 68, A_Y[1] + NH + 54, translate("进入链路探测"), "mute", 10, "0.6")

	--------------------------------------------------------------------
	-- 下段连线
	--------------------------------------------------------------------
	local b_root_r = X1 + 120
	local b_root_cy = y_root_b + math.floor(NH / 2)
	o[#o + 1] = curve(b_root_r, b_root_cy, X2, B_Y[1] + math.floor(NH / 2), "info", p)
	o[#o + 1] = curve(b_root_r, b_root_cy, X2, B_Y[2] + math.floor(NH / 2), "info", p)

	-- 首选链探测 → 保持 / 改道
	o[#o + 1] = curve(x2_r, B_Y[1] + math.floor(NH / 2), x3_l,
		B_Y[1] + math.floor(NH / 2), "ok", p)
	o[#o + 1] = curve(x2_r, B_Y[1] + math.floor(NH / 2), x3_l,
		B_Y[2] + math.floor(NH / 2), "warn", p)
	-- 另一条链探测 → 改道 / 双链故障
	o[#o + 1] = curve(x2_r, B_Y[2] + math.floor(NH / 2), x3_l,
		B_Y[2] + math.floor(NH / 2), "warn", p)
	o[#o + 1] = curve(x2_r, B_Y[2] + math.floor(NH / 2), x3_l,
		B_Y[3] + math.floor(NH / 2), "bad", p)

	--------------------------------------------------------------------
	-- 下段节点
	--------------------------------------------------------------------
	o[#o + 1] = box(X1, y_root_b, 120, NH, translate("链路探测"),
		translate("阈值判定"), nil, "info")
	o[#o + 1] = box(X2, B_Y[1], NW2, NH, translate("探测首选链路"),
		translate("超时 + 重试"), nil, "ok")
	o[#o + 1] = box(X2, B_Y[2], NW2, NH, translate("探测另一条链路"),
		translate("仅在首选失败时"), nil, "warn")

	o[#o + 1] = box(X3, B_Y[1], NW3, NH, translate("保持"),
		translate("首选链可达"), nil, "ok")
	o[#o + 1] = box(X3, B_Y[2], NW3, NH, translate("改道"),
		translate("首选不通 · 另一条通"), nil, "warn")
	o[#o + 1] = box(X3, B_Y[3], NW3, NH, translate("双链故障"),
		translate("都不通 → 不改道"), nil, "bad")

	--------------------------------------------------------------------
	-- 底部说明：把两条需求规则原样写出来
	--
	-- 图能表达结构，但「国外不通改直连 / 国内不通改代理」是**规则**，
	-- 只画线会让人自己推导；写在图下方才是可核对的。
	--------------------------------------------------------------------
	o[#o + 1] = label(X1 + 2, y_note1,
		translate("未录入自定义列表的域名：访问国外链路不通 → 自动改走直连；访问国内链路不通 → 自动改走代理"),
		nil, 10, "0.7")
	o[#o + 1] = label(X1 + 2, y_note2,
		translate("两条链都不通时不改道 —— 那是链路故障，改道只会掩盖问题"),
		"mute", 10, "0.55")

	o[#o + 1] = "</svg></div>"
	return table.concat(o)
end

--- 供几何校验读取的布局常量
--
-- 为什么暴露出来：tools/render-dnschain-diagrams.py 需要知道
-- 「最后一个节点的底边」与「说明文字的基线」，才能断言两者不重叠。
-- 之前只校验 viewBox 越界，结果文字压进节点框里的问题**没被发现**
-- （v0.13.0 实测截图才看见）。把常量交出去，断言就能精确到像素。
function D.route_layout()
	return {
		w = ROUTE_W,
		h = ROUTE_H,
		node_h = 46,
		-- 下段最后一个节点（双链故障）的底边
		last_node_bottom = 412 + 46,
		note1 = 486,
		note2 = 504,
	}
end

-----------------------------------------------------------------------
-- 改道状态图（状态思维导图）
--
-- 要回答的问题是「现在哪些域名不正常、该去查什么」，所以它是
-- **按状态分组**的：一个根分出五种状态，每种状态带计数与域名清单，
-- 问题状态（降级 / 改道 / 双链故障）额外给一句「下一步查什么」。
--
-- 为什么状态是这五档（而不是「正常 / 异常」两档）：
--   「异常」把「已自动改道并恢复可用」和「两条链都不通」混在一起，
--   前者不需要人介入、后者必须人介入。分档之后红黄绿各自含义唯一，
--   用户看到红色就知道要动手，看到黄色知道系统正在自愈。
--
-- rows：dnschain-health status 的 ROW 行（见 dnschain.lua health_rows）
-- summary：SUM 行（可选，只用于总数）
-----------------------------------------------------------------------
local STATUS_ORDER = { "ok", "degraded", "rerouted", "both-bad", "fixed", "unknown" }

local STATUS_META = {
	["ok"] = {
		title = translate("正常"),
		tone = "ok",
		hint = translate("首选链路可达"),
	},
	["degraded"] = {
		title = translate("降级中"),
		tone = "warn",
		hint = translate("首选链开始失败，未达改道阈值"),
	},
	["rerouted"] = {
		title = translate("已改道"),
		tone = "warn",
		hint = translate("自动切到另一条链，恢复后会自动回切"),
	},
	["both-bad"] = {
		title = translate("双链故障"),
		tone = "bad",
		hint = translate("两条链都不通 → 先查 dnsproxy 与代理"),
	},
	["fixed"] = {
		title = translate("固定归属"),
		tone = "info",
		hint = translate("自定义列表已指定，不参与改道"),
	},
	["unknown"] = {
		title = translate("未探测"),
		tone = "mute",
		hint = translate("等一轮间隔或手动触发探测"),
	},
}

local STATUS_W, STATUS_H = 760, 0

function D.status_map(rows, summary)
	rows = rows or {}
	summary = summary or {}

	-- 按状态分组
	local groups = {}
	for _, st in ipairs(STATUS_ORDER) do groups[st] = {} end
	for _, r in ipairs(rows) do
		local st = r.state or "unknown"
		if not groups[st] then groups[st] = {} end
		groups[st][#groups[st] + 1] = r
	end

	-- 只画有内容的状态 + 始终画 both-bad（即使为 0，也要让用户看见
	-- 「这个档存在且现在是空的」—— 隐藏它会让「为什么没有红色」变成疑问）
	local present = {}
	for _, st in ipairs(STATUS_ORDER) do
		if #groups[st] > 0 or st == "both-bad" then
			present[#present + 1] = st
		end
	end
	if #present == 0 then present = { "unknown" } end

	-- NH 取 60 而不是 56：状态节点是三行文字（标题 13px / 计数 11px /
	-- 提示 10px），基线分别在 y+21 / y+37 / y+51，三行字的下沿约在 y+53。
	-- 56 高的框只剩 3px —— 浏览器实测贴得很紧，视觉上像溢出。
	-- 60 给到 7px，与左右内边距（12px）比例协调。
	local NH, GAP = 60, 12
	local X1, X2, X3 = 14, 190, 400
	local NW2 = 180
	local NW3 = 336

	local total_h = #present * NH + (#present - 1) * GAP
	local top = 24
	local H = top + total_h + 34
	local root_y = top + math.floor(total_h / 2) - math.floor(NH / 2)

	local p = "dcst"
	local o = {}
	-- 同判定链路图：必须给 width/height 固有尺寸，
	-- 否则 CSS `width:auto` 回落到 100%，图被拉伸放大（见上）。
	o[#o + 1] = string.format(
		'<div class="dc-chain dc-chain--map"><svg viewBox="0 0 %d %d" ' ..
		'width="%d" height="%d" role="img" ' ..
		'aria-label="%s">', STATUS_W, H, STATUS_W, H,
		translate("改道状态思维导图"))
	o[#o + 1] = defs(p)

	local x_root_r = X1 + 150
	local x2_r = X2 + NW2

	-- 根 → 各状态
	for i, st in ipairs(present) do
		local y = top + (i - 1) * (NH + GAP)
		local meta = STATUS_META[st] or STATUS_META["unknown"]
		o[#o + 1] = curve(x_root_r, root_y + math.floor(NH / 2),
			X2, y + math.floor(NH / 2), meta.tone, p)
	end

	-- 状态 → 域名清单
	for i, st in ipairs(present) do
		local y = top + (i - 1) * (NH + GAP)
		local meta = STATUS_META[st] or STATUS_META["unknown"]
		o[#o + 1] = curve(x2_r, y + math.floor(NH / 2),
			X3, y + math.floor(NH / 2), meta.tone, p)
	end

	-- 根节点
	local n_all = 0
	for _, st in ipairs(present) do n_all = n_all + #groups[st] end
	local root_tone = "ok"
	if #groups["both-bad"] > 0 then
		root_tone = "bad"
	elseif #groups["rerouted"] > 0 or #groups["degraded"] > 0 then
		root_tone = "warn"
	end

	o[#o + 1] = box(X1, root_y, 150, NH, translate("改道状态"),
		string.format(translate("观测 %d 个"), n_all), nil, root_tone)

	-- 状态节点 + 域名清单
	for i, st in ipairs(present) do
		local y = top + (i - 1) * (NH + GAP)
		local meta = STATUS_META[st] or STATUS_META["unknown"]
		local list = groups[st]
		local n = #list

		o[#o + 1] = box(X2, y, NW2, NH, meta.title,
			string.format(translate("%d 个域名"), n), meta.hint, meta.tone)

		-- 域名清单：每行最多 2 个（等宽计算不了，用长度估算），最多 3 行
		local names = {}
		for _, r in ipairs(list) do
			local tag = r.domain or "?"
			if r.active and r.pref and r.active ~= r.pref then
				tag = string.format("%s → %s", tag,
					r.active == "foreign" and translate("代理") or translate("直连"))
			end
			names[#names + 1] = tag
		end

		local lines = {}
		local cur = ""
		for _, nm in ipairs(names) do
			local cand = (cur == "") and nm or (cur .. "、" .. nm)
			-- 估算：中文按 2 个宽度单位，ASCII 按 1 个；一行 52 单位
			local w = 0
			for c in cand:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
				w = w + (#c > 1 and 2 or 1)
			end
			if w > 52 and cur ~= "" then
				lines[#lines + 1] = cur
				cur = nm
			else
				cur = cand
			end
		end
		if cur ~= "" then lines[#lines + 1] = cur end

		local shown = {}
		for k = 1, math.min(#lines, 3) do shown[#shown + 1] = lines[k] end
		if #lines > 3 then
			shown[#shown + 1] = string.format(translate("…等 %d 个"), n)
		end

		local ty = y + 20
		if #shown == 0 then
			o[#o + 1] = label(X3 + 6, y + 30, translate("（无）"), "mute", 11, "0.5")
		else
			for _, ln in ipairs(shown) do
				o[#o + 1] = label(X3 + 6, ty, ln, nil, 11, "0.8")
				ty = ty + 14
			end
		end
	end

	-- 底部：把「红色要动手 / 黄色在自愈」这条读图规则写明
	--
	-- ⚠️ 基线取 H-12，而 H = top + total_h + 34 —— 最后一个节点的底边是
	-- top + total_h，故与文字之间有 34-12 = 22px 余量，足够 10px 字号。
	-- 这个余量是刻意的：v0.13.0 在判定链路图里曾把余量写成 2px，
	-- 结果文字压进了节点框（纯 viewBox 断言查不出来，截图才看见）。
	o[#o + 1] = label(X1 + 2, H - 12,
		translate("红色 = 需要人工介入；黄色 = 系统已自动处理，观察即可；绿色 = 按归属正常走"),
		nil, 10, "0.62")

	o[#o + 1] = "</svg></div>"
	return table.concat(o)
end

--- 供几何校验读取的状态图布局
--
-- ⚠️ NH/GAP/top 必须与 status_map() 里的字面值一致。
-- 这是本模块唯一一处「两处写同一组常量」的地方，改成共享 local 会让
-- status_map 与它耦合（后者是纯渲染、不该被测试工具反向依赖）。
-- 故在 CI 断言里校验两处一致，而不是靠人记。
function D.status_layout(rows)
	rows = rows or {}
	local present = 0
	for _ in pairs(rows) do present = present + 1 end
	-- 至少一档（both-bad 恒在）
	if present == 0 then present = 1 end

	local NH, GAP = 60, 12
	local top = 24
	local total_h = present * NH + (present - 1) * GAP
	return {
		w = STATUS_W,
		h = top + total_h + 34,
		node_h = NH,
		last_node_bottom = top + total_h,
		note = top + total_h + 34 - 12,
	}
end

return D
