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
--   · 连线**不画箭头**（v0.15.0 按用户要求移除）。思维导图的语义是
--     「从主干生长出分支」，靠曲线形状与颜色表达走向即可；箭头在密集
--     分支处会互相压盖，反而看不清。
--     ⇒ 因此也**不再生成 `<marker>` 定义**。曾经的 id 前缀机制
--     （`id_prefix` 参数）现在只用于给 `<g>` 打 `data-dc-figure` 标记，
--     供前端与测试区分同一页上的多张图；不再影响任何 SVG id。
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
-- 图身份标记（v0.15.0 起替代原来的 marker id 前缀）
--
-- 原机制：每张图按状态色定义 5 个 <marker>，id 带前缀避免同页冲突。
-- v0.15.0 按用户要求移除全部箭头 ⇒ 没有 marker 了。
--
-- 但「同一页有多张图」这个事实还在（概览/诊断合并后同页 3 张），
-- 前端与测试仍需要区分它们，故保留一个无副作用的身份标记：
-- 给最外层 <g> 打 data-dc-figure="<prefix>"。
-- 它不影响渲染，也不参与任何 SVG id 解析。
-----------------------------------------------------------------------
local function figure_attr(prefix)
	return string.format(' data-dc-figure="%s"', prefix)
end
D.figure_attr = figure_attr

-----------------------------------------------------------------------
-- 连线（v0.15.0：全部去掉 marker-end，不再画箭头）
--
-- hline：两端垂直对齐时的水平线，中点轻微下沉（思维导图的「生长感」）。
-- curve：从 (x1,y1) 平滑过渡到 (x2,y2) 的 S 形三次贝塞尔。
-- vline：跨段的竖虚线。
--
-- ⚠️ dx 上限 (x2-x1)/2 是硬约束，见文件头。
-----------------------------------------------------------------------
local function hline(x1, x2, y, tone, prefix, dash)
	local mid = math.floor((x1 + x2) / 2)
	local dip = 3
	return string.format(
		'<path d="M %d %d Q %d %d, %d %d" stroke="%s" stroke-width="2.5" ' ..
		'fill="none" stroke-linecap="round"%s/>',
		x1, y, mid, y + dip, x2, y, C[tone or "ok"],
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
		'stroke-width="2.5" fill="none" stroke-linecap="round"/>',
		x1, y1, x1 + dx, y1, x2 - dx, y2, x2, y2, C[tone or "ok"])
end

--- 竖虚线（用于「上一阶段 → 下一阶段」的跨段连接）
local function vline(x, y1, y2, tone, prefix)
	return string.format(
		'<path d="M %d %d L %d %d" stroke="%s" stroke-width="2" ' ..
		'fill="none" stroke-dasharray="5 4" opacity="0.75"/>',
		x, y1, x, y2, C[tone or "mute"])
end

-----------------------------------------------------------------------
-- 节点
--
-- 三行文字：标题 / 副标题 / 说明（说明可选，需要 h >= 54）。
-- 左侧一个小圆点表状态色 —— 扫一眼就能看出哪一段是红的。
-----------------------------------------------------------------------
-----------------------------------------------------------------------
-- 文本宽度估算
--
-- 为什么必须自己算：SVG 的 <text> 不会自动换行，也不会把框撑大 ——
-- 文字超宽就直接画到框外（视觉上「内容超出边界」），
-- 或被后续节点盖住（视觉上「内容显示不全」）。
-- 而 Lua 侧拿不到真实字体度量（无 Canvas），只能按字符宽度估。
--
-- 估算规则：
--   · CJK（含全角标点、中文）按 1.0 em
--   · ASCII 按 0.55 em（13px 字号下实测 Helvetica/系统无衬线约 0.5~0.6）
--   · 其余（西里尔、希腊等）按 0.6 em
-- 偏保守（宁大不小）：估小了会溢出，估大了只是多留白。
-----------------------------------------------------------------------
-----------------------------------------------------------------------
-- UTF-8 迭代兼容层
--
-- ⚠️ LuCI 在 OpenWrt 上跑的是 **Lua 5.1**，没有 `utf8` 库
-- （`utf8.codes` / `utf8.codepoint` 是 5.3+ 才有）。
-- 本地 lupa 测试环境可能是 5.4，于是「本地过、路由器炸」。
-- 这里自带实现，不依赖标准库版本。
-----------------------------------------------------------------------
local function utf8_iter(s)
	local i = 1
	local n = #s
	return function()
		if i > n then return nil end
		local b = s:byte(i)
		local len = 1
		if b >= 0xF0 then len = 4
		elseif b >= 0xE0 then len = 3
		elseif b >= 0xC0 then len = 2 end
		if i + len - 1 > n then len = 1 end
		local bytes = { s:byte(i, i + len - 1) }
		local cp
		if len == 1 then
			cp = bytes[1]
		elseif len == 2 then
			cp = (bytes[1] - 0xC0) * 0x40 + (bytes[2] - 0x80)
		elseif len == 3 then
			cp = (bytes[1] - 0xE0) * 0x1000 + (bytes[2] - 0x80) * 0x40 + (bytes[3] - 0x80)
		else
			cp = (bytes[1] - 0xF0) * 0x40000 + (bytes[2] - 0x80) * 0x1000
				+ (bytes[3] - 0x80) * 0x40 + (bytes[4] - 0x80)
		end
		local start = i
		i = i + len
		return cp, s:sub(start, start + len - 1), len
	end
end

local function char_em(cp)
	if cp >= 0x1100 and (
		cp <= 0x115F or            -- Hangul Jamo
		cp == 0x2329 or cp == 0x232A or
		(cp >= 0x2E80 and cp <= 0xA4CF) or   -- CJK Radicals … Yi
		(cp >= 0xAC00 and cp <= 0xD7A3) or   -- Hangul Syllables
		(cp >= 0xF900 and cp <= 0xFAFF) or   -- CJK Compatibility Ideographs
		(cp >= 0xFE30 and cp <= 0xFE6F) or   -- CJK Compatibility Forms
		(cp >= 0xFF00 and cp <= 0xFF60) or   -- Fullwidth Forms
		(cp >= 0xFFE0 and cp <= 0xFFE6) or
		(cp >= 0x20000 and cp <= 0x3FFFD)    -- CJK Ext
	) then
		return 1.0
	elseif cp < 0x80 then
		return 0.55
	end
	return 0.6
end

--- 估算字符串在给定字号下的像素宽度
local function text_w(s, size)
	local total = 0
	for cp in utf8_iter(s) do
		total = total + char_em(cp)
	end
	return math.ceil(total * size)
end

--- 按字符数截断，超长补省略号（v0.15.0，实时诊断图用）
--
-- 为什么按「字符数」而不是「像素」：实时诊断图的证据串是等宽小字、
-- 单行显示，按像素算反而要在视图层再引一次 text_w，得不偿失。
--
-- ⚠️ 必须按 UTF-8 码点切，不能 `s:sub(1, n)` —— Lua 的 sub 按**字节**，
-- 切在多字节字符中间会产出非法 UTF-8，整个 SVG 解析失败（页面空白）。
-- 本仓库已踩过同类问题（AGENTS.md 第 46 条：Lua 字符类按字节工作）。
--
-- ⚠️⚠️ 取值位置踩过坑（v0.16.2 修）：`utf8_iter` 每次返回
--   `cp, 字符原文, 字节长度` 三个值。原实现写 `for _, _, raw in utf8_iter(s)`，
--   第三个位置拿到的是**字节长度**（1/2/3/4），不是字符 ——
--   于是所有证据串被渲染成 `111111111111113311` 这种数字串。
--
--   实测（修复前）：
--     "192.168.3.254:53 应答 OK"  →  "1111111111111111133111"
--     "dnschain-split.conf 全部指向 :5336" → "111111111111111111113333111111"
--
--   这个 bug 极其隐蔽：代码语法正确、类型不报错、SVG 也能正常渲染，
--   只是文字全变成了 1/3/4 —— 只有**看页面截图**才能发现。
local function truncate(s, max_chars)
	s = tostring(s or "")
	local out, n = {}, 0
	-- 第二个返回值才是字符原文
	for _, ch in utf8_iter(s) do
		if n >= max_chars then
			return table.concat(out) .. "…"
		end
		out[#out + 1] = ch
		n = n + 1
	end
	return table.concat(out)
end
D.truncate = truncate

--- 按像素宽度折行（SVG <text> 不会自动换行，只能自己切）
--
-- 返回若干行。优先在「、」「，」「 」「→」后断开，避免把词切碎。
--
-- 实现要点（踩过的坑）：
--   · 不能边累加边在「超宽」时回退 —— 若断点位置在行首，回退会产出
--     空行。故这里改成**两阶段**：先累积到超宽，再在累积串里找
--     最后一个断点切分；找不到断点才硬切。
--   · `cur_w` 必须与 `cur` 严格同步。早期版本用 while 循环残留了
--     `i = i + len`（for 循环里 i 未定义），导致 len 恒为 nil、
--     断点判断失效 → 永不折行。
local function wrap_text(s, size, max_w)
	if s == nil or s == "" then return {} end
	if max_w <= 0 then return { s } end
	if text_w(s, size) <= max_w then return { s } end

	-- 断点字符：在这些字符**之后**可以断行
	local function is_break(ch)
		return ch == "、" or ch == "，" or ch == " " or ch == "→"
			or ch == "；" or ch == "·" or ch == "/" or ch == "," 
	end

	local lines = {}
	local cur = ""
	local cur_w = 0

	for cp, ch, len in utf8_iter(s) do
		local w = char_em(cp) * size

		-- 加进来会超宽 → 先把 cur 断行
		if cur ~= "" and cur_w + w > max_w then
			-- 在 cur 里找最后一个断点
			local cut = nil
			local acc_w = 0
			local pos = 0
			for ccp, cch, clen in utf8_iter(cur) do
				acc_w = acc_w + char_em(ccp) * size
				pos = pos + clen
				if is_break(cch) then cut = pos end
			end
			if cut and cut > 0 and cut < #cur then
				lines[#lines + 1] = cur:sub(1, cut)
				cur = cur:sub(cut + 1)
			else
				lines[#lines + 1] = cur
				cur = ""
			end
			cur_w = text_w(cur, size)
		end

		cur = cur .. ch
		cur_w = cur_w + w
	end

	if cur ~= "" then lines[#lines + 1] = cur end
	return lines
end

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

--- 多行文本节点（框内用，自动折行）
--
-- 与 box() 的区别：box 的三行是「标题/副标题/提示」固定结构，
-- 这里是把**一段长文本**折成多行，用于 hint 这类会超宽的说明。
local function box_lines(x, y, w, lines, size, opacity, color, weight)
	local out = {}
	for i, ln in ipairs(lines) do
		out[#out + 1] = string.format(
			'<text x="%d" y="%d" font-size="%d"%s fill="%s" opacity="%s">%s</text>',
			x, y + (i - 1) * math.floor(size * 1.35), size,
			weight and (' font-weight="' .. weight .. '"') or "",
			color or "currentColor", opacity or "0.72", esc(ln))
	end
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
--
-- ⚠️ opts.id_prefix 必须由调用方区分（v0.14.2 修）。
--
--   这张图被渲染**两次**：概览 tab 的「分流决策」与域名 tab 的「走法」。
--   CBI 的 tab 是 CSS 隐藏、**不是懒加载** —— 两个 tab 的内容都进同一份
--   HTML。而 SVG 的 id 是**文档级全局**的，两处用同一个 "dcrt" 前缀
--   就会出现 5 组重复 id（dcrt-a-ok/warn/bad/info/mute 各两份）。
--
--   后果：`url(#dcrt-a-ok)` 全部解析到**第一个**定义。当前两图配色恰好
--   相同所以看不出异常，但一旦一处改了色（或将来只渲染一处），
--   箭头颜色就会静默串掉。浏览器也不报错 —— 属最难发现的一类。
--
--   实测证据（v0.14.1 页面）：`grep -o 'id="dcrt[^"]*"'` 有 5 个重复。
-----------------------------------------------------------------------
local ROUTE_W, ROUTE_H = 720, 520

function D.route_map(opts)
	opts = opts or {}

	-- 图身份：v0.15.0 起不再有 marker id，prefix 只用于 data-dc-figure 标记。
	--
	-- 用 rawget 而不是 opts.id_prefix：lupa（测试用的真实 Lua 解释器）
	-- 把 Python dict 桥接成 Lua 表时，**缺失的键会抛 KeyError 而不是返回
	-- nil**，因为 Lua 侧的 __index 落到了 Python 的 __getitem__。
	-- 生产环境（原生 Lua 表）两种写法等价，但 rawget 在两种环境下都安全。
	local p = rawget(opts, "id_prefix") or "dcrt"
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
		esc(translate("域名判定链路图")))
	o[#o + 1] = "<g" .. figure_attr(p) .. ">"

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

	o[#o + 1] = "</g></svg></div>"
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
--
-- ⚠️ v0.14.0：原来的 "fixed" 档（「固定归属 / 不参与改道」）已删除。
--
--   自定义列表的定位改成了「补全数据库归属」—— 它只决定**首选**链，
--   仍然参与健康检测与自动改道。于是「固定不改道」这个状态不再存在，
--   再画一档会让页面说一套、运行时做另一套。
--
--   自定义域名现在归入正常的 ok / degraded / rerouted / both-bad 档，
--   由 class 字段（custom-*）体现「归属来自用户补全」。
-- -----------------------------------------------------------------------
local STATUS_ORDER = { "ok", "degraded", "rerouted", "both-bad", "unknown" }

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
	["unknown"] = {
		title = translate("未探测"),
		tone = "mute",
		hint = translate("等一轮间隔或手动触发探测"),
	},
}

-- 高度由 status_map 内的 layout_plan 算出，不存在固定高度常量
-- （原 STATUS_H 恒为 0 且从未被读取，v0.14.4 删）
--
-- ── 宽度（v0.15.1 修「域名清单显示不足」）──────────────────────
--
-- 原值 760。实测问题：8 个观测域名在右侧清单里被挤成 3 行，
-- 而第三行只有 www.youtube.com 一个（占 91px）—— 右侧空出 250px 空白，
-- 同时前两行又逼近右边界。视觉上就是「内容没显示全」。
--
-- 算式（改前）：X3=415 → NW3=331 → avail=325px，而 8 个域名的
-- 自然总宽约 710px（含「、」分隔符）→ 必须折 3 行。
--
-- 改法不是简单加宽画布（那只是把问题推到更长的域名上），而是：
--   ① 画布加宽到 900，给清单更多横向预算
--   ② 清单改为**多列网格**：先算出能放几列，再按列均分，
--      避免「最后一行只剩一个」的畸形折行
--   ③ 每个域名单独成格（不再用「、」串成一行），列间用间距分隔
--      —— 这样任意数量的域名都能均匀铺开，不会出现半行空白
local STATUS_W = 900

-- 把一行的 state 归一到「可画」的档位。
--
-- ⚠️ 未知/空 state 必须归入 unknown（v0.14.4 修）。
--
--   原实现 `local st = r.state or "unknown"` 只兜 nil，空串与任何
--   未知值（如脚本将来新增 `probing`）会落进 groups 里一个**不在
--   STATUS_ORDER 中**的键。而 `present` 只遍历 STATUS_ORDER、
--   `n_all` 也只累加 STATUS_ORDER 的组 —— 这些行被**静默丢弃**。
--
--   实测：3 行（state 分别为 ok / "" / weird-state）只画出 1 个域名，
--   根节点也写「观测 1 个」。看起来像「只有 1 个域名需要关注」，
--   没有任何提示。状态文件被手工改坏、或脚本新增状态值时会踩到。
--
--   现在统一归入 unknown 档，保证「画出的行数 == 输入行数」。
local function normalize_state(st)
	if type(st) ~= "string" then return "unknown" end
	for _, known in ipairs(STATUS_ORDER) do
		if st == known then return st end
	end
	return "unknown"
end

-- 状态图的分组与布局计算（status_map 与 status_layout 共用）。
--
-- ⚠️ 抽出来的理由（v0.14.4）：原来 status_map 与 status_layout 各算一遍，
-- 口径不同 —— status_layout 用 `pairs(rows)` 数**数据行数**，而
-- status_map 画的是**状态档位数**（最多 5 档，both-bad 恒占一档）；
-- status_layout 还把 NH 硬编码成 60，而 status_map 的 NH 随 hint
-- 折行数增长。实测 5 档各 1 个域名时：status_map 实际高 386，
-- status_layout 报 406 —— CI 的几何断言一直在验一个不存在的布局。
local function layout_plan(rows)
	rows = rows or {}

	-- 按状态分组（未知 state 归入 unknown，不丢弃）
	local groups = {}
	for _, st in ipairs(STATUS_ORDER) do groups[st] = {} end
	for _, r in ipairs(rows) do
		local st = normalize_state(r.state)
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

	local n_all = 0
	for _, st in ipairs(STATUS_ORDER) do n_all = n_all + #groups[st] end

	-- ── 布局参数 ──────────────────────────────────────────────────────
	--
	-- ⚠️ 框宽不能写死（v0.13.1 实测修正）。
	--
	-- 原实现 NW2=180 硬编码，而 hint 最长的是
	-- 「自动切到另一条链，恢复后会自动回切」（19 个全角字符 ≈ 190px），
	-- 框内容区只有 180-24-12 = 144px → 文字画到框外 20px。
	-- 浏览器实测：`两条链都不通 → 先查 dnsproxy 与代理` right=390，
	-- 而框右缘 370 —— 溢出 20px，看起来就是「内容超出边界」。
	--
	-- 现在改成：先按**最长一行文本**算出需要的框宽，再取整。
	-- hint 仍然会折行（三行结构不能无限加宽），
	-- 但框宽保证容得下折行后的每一行。
	local NH_MIN = 60
	local GAP = 12
	local X1 = 14
	local ROOT_W = 150
	local X2 = X1 + ROOT_W + 26

	-- 折行宽度上限：hint 在 10px 字号下最多占这么宽
	--
	-- 取 168 而不是 210 的理由：
	--   210 时最长的 hint（「自动切到另一条链，恢复后会自动回切」≈190px）
	--   仍能一行放下 → 框被撑到 219px 宽，而右侧域名清单只剩
	--   760-219-40 = 501px。清单里最长的一行（两个长域名 + 箭头）
	--   反而更挤。**把宽度预算留给清单**：hint 是说明性文字，
	--   折成两行不损失信息；清单是主数据，挤了就得截断。
	local HINT_MAX_W = 168
	-- 框内容区左右内边距：左 24（避让圆点）、右 12
	local PAD_L, PAD_R = 24, 12

	-- 预计算每个状态的 hint 折行结果与所需宽度
	local plan = {}
	local max_inner = 0
	for _, st in ipairs(present) do
		local meta = STATUS_META[st] or STATUS_META["unknown"]
		local hint_lines = wrap_text(meta.hint, 10, HINT_MAX_W)
		local need = 0
		-- 标题（13px 粗体）
		need = math.max(need, text_w(meta.title, 13))
		-- 计数（11px）
		need = math.max(need, text_w(string.format(translate("%d 个域名"),
			#groups[st]), 11))
		-- hint 每行（10px）
		for _, ln in ipairs(hint_lines) do
			need = math.max(need, text_w(ln, 10))
		end
		if need > max_inner then max_inner = need end
		plan[st] = { meta = meta, hint_lines = hint_lines, need = need }
	end

	-- 框宽 = 内边距 + 最长内容；下限 180 保持视觉均衡
	local NW2 = math.max(180, max_inner + PAD_L + PAD_R)

	-- 框高随 hint 行数增长（三行结构：标题 / 计数 / hint…）
	local max_hint_lines = 1
	for _, st in ipairs(present) do
		local n = #plan[st].hint_lines
		if n > max_hint_lines then max_hint_lines = n end
	end
	-- 21(标题基线) + 16(计数) + 行数*14 + 底部留白
	local NH = math.max(NH_MIN, 21 + 16 + max_hint_lines * 14 + 8)

	local X3 = X2 + NW2 + 26
	local NW3 = STATUS_W - X3 - 14

	local total_h = #present * NH + (#present - 1) * GAP
	local top = 24
	local H = top + total_h + 34
	local root_y = top + math.floor(total_h / 2) - math.floor(NH / 2)

	return {
		groups = groups, present = present, plan = plan, n_all = n_all,
		NW2 = NW2, NH = NH, X3 = X3, NW3 = NW3,
		total_h = total_h, top = top, H = H, root_y = root_y,
		X1 = X1, X2 = X2, ROOT_W = ROOT_W, GAP = GAP,
		PAD_L = PAD_L, PAD_R = PAD_R,
	}
end

function D.status_map(rows, summary, id_prefix)
	rows = rows or {}
	summary = summary or {}

	local LP = layout_plan(rows)
	local groups, present, plan = LP.groups, LP.present, LP.plan
	local n_all, NW2, NH, X3, NW3 = LP.n_all, LP.NW2, LP.NH, LP.X3, LP.NW3
	local total_h, top, H, root_y = LP.total_h, LP.top, LP.H, LP.root_y
	local X1, X2, ROOT_W, GAP = LP.X1, LP.X2, LP.ROOT_W, LP.GAP
	local PAD_L, PAD_R = LP.PAD_L, LP.PAD_R

	-- 图身份：v0.15.0 起不再有 marker id，prefix 只用于 data-dc-figure 标记。
	--
	-- 接口保持第三个参数 id_prefix，以免将来在别处再渲染一次时
	-- 无法区分同一页上的两张图。
	local p = id_prefix or "dcst"
	local o = {}
	-- 同判定链路图：必须给 width/height 固有尺寸，
	-- 否则 CSS `width:auto` 回落到 100%，图被拉伸放大（见上）。
	o[#o + 1] = string.format(
		'<div class="dc-chain dc-chain--map"><svg viewBox="0 0 %d %d" ' ..
		'width="%d" height="%d" role="img" ' ..
		'aria-label="%s">', STATUS_W, H, STATUS_W, H,
		esc(translate("改道状态思维导图")))
	o[#o + 1] = "<g" .. figure_attr(p) .. ">"

	local x_root_r = X1 + ROOT_W
	local x2_r = X2 + NW2

	-- 根 → 各状态
	for i, st in ipairs(present) do
		local y = top + (i - 1) * (NH + GAP)
		o[#o + 1] = curve(x_root_r, root_y + math.floor(NH / 2),
			X2, y + math.floor(NH / 2), plan[st].meta.tone, p)
	end

	-- 状态 → 域名清单
	for i, st in ipairs(present) do
		local y = top + (i - 1) * (NH + GAP)
		o[#o + 1] = curve(x2_r, y + math.floor(NH / 2),
			X3, y + math.floor(NH / 2), plan[st].meta.tone, p)
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

	o[#o + 1] = box(X1, root_y, ROOT_W, NH, translate("改道状态"),
		string.format(translate("观测 %d 个"), n_all), nil, root_tone)

	-- 状态节点 + 域名清单
	for i, st in ipairs(present) do
		local y = top + (i - 1) * (NH + GAP)
		local pl = plan[st]
		local meta = pl.meta
		local list = groups[st]
		local n = #list

		-- 标题 + 计数（用 box 的两行结构，hint 单独折行画）
		o[#o + 1] = box(X2, y, NW2, NH, meta.title,
			string.format(translate("%d 个域名"), n), nil, meta.tone)

		-- hint：折行后画在第三行位置起
		o[#o + 1] = box_lines(X2 + PAD_L, y + 51, NW2 - PAD_L - PAD_R,
			pl.hint_lines, 10, "0.55", nil, nil)

		-- ── 域名清单：多列网格 + 独立容器框（v0.15.2）─────────────
		--
		-- v0.15.1 改成多列网格解决了「最后一行只剩一个」的问题，但留下了
		-- 一个新的视觉缺陷：**域名只是悬在空白里的文字，没有容器**。
		-- 左侧的「正常」框有边框、有底色，右侧的域名却什么都没有 ——
		-- 看起来像是「框丢了」，而不是「这是清单」。
		--
		-- v0.15.2 补上容器：
		--   · 一个浅底、细边的矩形，包住整个清单区
		--   · 左侧留 8px 内边距，与连线末端衔接
		--   · 边框色跟随该档的语义色（绿/黄/红/灰），但更淡
		--
		-- 这样视觉上就是「状态框 ──→ 清单框」的完整链路。
		local names = {}
		for _, r in ipairs(list) do
			local tag = r.domain or "?"
			if r.active and r.pref and r.active ~= r.pref then
				tag = string.format("%s → %s", tag,
					r.active == "foreign" and translate("代理") or translate("直连"))
			end
			names[#names + 1] = tag
		end

		-- 清单容器框左右内边距（v0.15.2：加框后从 6 增到 10）
		local LIST_PAD = 10
		local avail = NW3 - LIST_PAD * 2
		local COL_GAP = 14        -- 列间距
		local ROW_STEP = 14       -- 行距（与字号 11 匹配）

		-- 每格的最大自然宽度；超宽的域名先按「列宽上限」截断
		local max_cell = 0
		for _, nm in ipairs(names) do
			local w = text_w(nm, 11)
			if w > max_cell then max_cell = w end
		end

		-- 单列上限：不超过可用宽度的一半，否则一列占满、无从分栏
		local cell_cap = math.max(60, math.floor(avail / 2))
		local n_cols = 1
		if max_cell + COL_GAP <= avail then
			-- 理想列宽 = 最宽那格 + 间距；据此算最多能放几列
			n_cols = math.max(1, math.floor((avail + COL_GAP) / (max_cell + COL_GAP)))
		else
			-- 有超宽域名：按 cell_cap 截断后再算列数
			n_cols = math.max(1, math.floor((avail + COL_GAP) / (cell_cap + COL_GAP)))
		end
		-- 列数不超过域名总数（1 个域名不该开 5 列）
		if n_cols > #names then n_cols = #names end
		if n_cols < 1 then n_cols = 1 end

		local col_w = math.floor((avail - (n_cols - 1) * COL_GAP) / n_cols)

		-- 按列宽截断每个域名
		local function fit(nm)
			if text_w(nm, 11) <= col_w then return nm end
			local ell_w = text_w("…", 11)
			local keep = nm
			while #keep > 1 and text_w(keep, 11) + ell_w > col_w do
				keep = keep:sub(1, #keep - 1)
			end
			return keep .. "…"
		end

		local max_rows = math.max(1, math.floor((NH - 8) / ROW_STEP))
		local capacity = n_cols * max_rows
		local truncated = (#names > capacity)

		-- 截断时最后一行留一格放「…等 N 个」
		local to_show = truncated and (capacity - 1) or #names
		if to_show < 0 then to_show = 0 end

		-- ── 清单容器框（v0.15.2）─────────────────────────────────
		--
		-- 没有容器时，域名只是悬在空白里的文字，视觉上像「框丢了」。
		-- 这里画一个浅底细边矩形包住整块清单：
		--   · x 从 X3 起（连线末端），宽度到画布右缘留 14px
		--   · 高度 = 实际用到的行数 * ROW_STEP + 上下内边距
		--   · 边框用该档语义色的淡版本（stroke-opacity 0.45）
		--   · 填充用 --dc-surface，与左侧状态框一致
		--
		-- ⚠️ 必须画在文字**之前**（先入数组），否则框会盖住文字。
		local used_rows = math.max(1, math.ceil(math.max(to_show, 1) / n_cols))
		if truncated then
			used_rows = math.max(1, math.ceil((to_show + 1) / n_cols))
		end
		local box_h = used_rows * ROW_STEP + 12
		local box_x = X3
		local box_w = STATUS_W - X3 - 14
		o[#o + 1] = string.format(
			'<rect x="%d" y="%d" width="%d" height="%d" rx="7" ' ..
			'fill="var(--dc-surface)" stroke="%s" stroke-width="1.5" ' ..
			'stroke-opacity="0.45"/>',
			box_x, y + 6, box_w, box_h, C[meta.tone])

		if #names == 0 then
			o[#o + 1] = label(X3 + 10, y + 26, translate("（无）"), "mute", 11, "0.5")
		else
			for k = 1, to_show do
				local idx = k - 1
				local col = idx % n_cols
				local row = math.floor(idx / n_cols)
				o[#o + 1] = string.format(
					'<text x="%d" y="%d" font-size="11" fill="currentColor" opacity="0.8">%s</text>',
					X3 + 10 + col * (col_w + COL_GAP),
					y + 20 + row * ROW_STEP,
					esc(fit(names[k])))
			end
			if truncated then
				local idx = to_show
				local col = idx % n_cols
				local row = math.floor(idx / n_cols)
				o[#o + 1] = string.format(
					'<text x="%d" y="%d" font-size="11" fill="currentColor" opacity="0.55">%s</text>',
					X3 + 10 + col * (col_w + COL_GAP),
					y + 20 + row * ROW_STEP,
					esc(string.format(translate("…等 %d 个"), n)))
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

	o[#o + 1] = "</g></svg></div>"
	return table.concat(o)
end

--- 供几何校验读取的状态图布局
--
-- ⚠️ 必须与 status_map() 用**同一套档位与框高算法**（v0.14.4 修）。
--
--   原实现有两处口径不一致，导致 CI 的几何断言验的是一个不存在的布局：
--     ① `for _ in pairs(rows)` 数的是**数据行数**，而 status_map 画的是
--        **状态档位数**（最多 5 档，且 both-bad 恒占一档）。行数 ≠ 档位数
--        时必然不等。
--     ② `NH` 硬编码 60，而 status_map 的 NH 会随 hint 折行数增长
--        （math.max(NH_MIN, 21+16+max_hint_lines*14+8)）。
--
--   实测（5 档各 1 个域名）：status_map 实际 viewBox 高 386，
--   本函数报 406 —— 差 20px。断言「说明文字不压节点」用的是错值，
--   即使真把文字压进节点也未必能发现。
--
--   现在抽出 layout_plan(rows)，由 status_map 与 status_layout 共用。
function D.status_layout(rows)
	rows = rows or {}
	local plan = layout_plan(rows)
	return {
		w = STATUS_W,
		h = plan.H,
		node_h = plan.NH,
		last_node_bottom = plan.top + plan.total_h,
		note = plan.H - 12,
		-- 供断言核对「档位数」而不是「行数」
		tiers = #plan.present,
		rows = plan.n_all,
	}
end

------------------------------------------------------------------------
-- 实时诊断链路思维导图（v0.16.3）
--
-- ── 为什么要改成思维导图（用户要求）──────────────────────────────
--
--   v0.15.0 版是一列「阶段名 + 状态点 + 计数 + 证据」的纵向列表。
--   信息是全的，但它不是「链路图」—— 看不出段与段之间的**顺序与
--   依赖关系**，而诊断的核心问题恰恰是「断在哪一段、下游受不受影响」。
--
--   本版改成三层思维导图，与页面其余三张图同一套视觉语言：
--
--      根（整体结论）
--        ├─ 阶段1 ── 证据
--        ├─ 阶段2 ── 证据
--        └─ ...
--
--   根 → 阶段的连线用该阶段的状态色：一眼看出哪条支路是红的。
--
-- ── 布局参数怎么定的 ─────────────────────────────────────────
--
--   左侧根节点固定宽度，中间阶段列，右侧证据列。
--   阶段数量固定 8 个（对应 selftest 的 8 个链路阶段），故高度
--   可直接由行距算出，不需要 status_map 那种动态分组。
--
--   证据列宽度取 420：实测最长的证据串是
--   「ss_spec 表 2 个、:1234 在监听、global_server=cfg0b4a8f」，
--   在 11px 字号下约 300px，留出余量后 420 够用；超长仍会被
--   truncate 截断并加省略号。
------------------------------------------------------------------------
local LIVE_W = 1180
local LIVE_NH = 52          -- 阶段节点高
local LIVE_GAP = 14         -- 阶段之间垂直间距
local LIVE_ROOT_W = 150     -- 根节点宽
local LIVE_STAGE_W = 168    -- 阶段节点宽
local LIVE_EVID_W = 420     -- 证据框宽
local LIVE_X1 = 14          -- 根节点 x
local LIVE_X2 = 208         -- 阶段节点 x
local LIVE_X3 = 424         -- 证据框 x
local LIVE_TOP = 16         -- 首个阶段顶部

--- 实时诊断链路思维导图
--
-- 参数 stages：{ { id, label, tone, n_pass, n_fail, n_skip, evidence }, ... }
-- 返回：完整 SVG 字符串（含外层 <div>）
function D.live_diag_map(stages)
	stages = stages or {}
	local n = #stages
	if n == 0 then
		return '<div class="dc-chain dc-chain--live"></div>'
	end

	local H = LIVE_TOP * 2 + n * LIVE_NH + (n - 1) * LIVE_GAP
	local root_cy = LIVE_TOP + math.floor((n * LIVE_NH + (n - 1) * LIVE_GAP) / 2)
	local root_h = 74

	-- 根节点色调：有 FAIL 就是 bad，否则有 SKIP 是 warn，否则 ok
	local root_tone = "ok"
	for _, st in ipairs(stages) do
		if st.tone == "bad" then root_tone = "bad"; break end
		if st.tone == "warn" then root_tone = "warn" end
	end

	local p = "dclive"
	local o = {}

	-- 固有宽高必须给：否则 CSS width:auto 回落到 100%，图被拉伸放大
	o[#o + 1] = string.format(
		'<div class="dc-chain dc-chain--live"><svg viewBox="0 0 %d %d" ' ..
		'width="%d" height="%d" role="img" aria-label="%s">',
		LIVE_W, H, LIVE_W, H, esc(translate("实时诊断链路思维导图")))
	o[#o + 1] = "<g" .. figure_attr(p) .. ">"

	local root_right = LIVE_X1 + LIVE_ROOT_W

	-- ── 根 → 各阶段的连线 ──────────────────────────────────
	-- 用该阶段的状态色：一眼看出哪条支路是红的
	for i, st in ipairs(stages) do
		local y = LIVE_TOP + (i - 1) * (LIVE_NH + LIVE_GAP)
		o[#o + 1] = curve(root_right, root_cy, LIVE_X2,
			y + math.floor(LIVE_NH / 2), st.tone, p)
	end

	-- ── 阶段 → 证据的连线（细虚线，表示「附带说明」而非「下游」）──
	for i, st in ipairs(stages) do
		local y = LIVE_TOP + (i - 1) * (LIVE_NH + LIVE_GAP)
		local cy = y + math.floor(LIVE_NH / 2)
		o[#o + 1] = hline(LIVE_X2 + LIVE_STAGE_W, LIVE_X3, cy,
			st.tone, p, true)
	end

	-- ── 根节点 ────────────────────────────────────────────
	local n_pass, n_fail, n_skip = 0, 0, 0
	for _, st in ipairs(stages) do
		n_pass = n_pass + (st.n_pass or 0)
		n_fail = n_fail + (st.n_fail or 0)
		n_skip = n_skip + (st.n_skip or 0)
	end

	local verdict
	if n_fail > 0 then
		verdict = translate("有断点")
	elseif n_skip > 0 then
		verdict = translate("部分跳过")
	else
		verdict = translate("全通")
	end

	o[#o + 1] = box(LIVE_X1, root_cy - math.floor(root_h / 2),
		LIVE_ROOT_W, root_h, translate("整体结论"), verdict,
		string.format("PASS %d / FAIL %d", n_pass, n_fail), root_tone)

	-- ── 阶段节点 + 证据 ───────────────────────────────────
	for i, st in ipairs(stages) do
		local y = LIVE_TOP + (i - 1) * (LIVE_NH + LIVE_GAP)

		-- 阶段节点：标题 = 阶段名，副标题 = PASS/FAIL 计数
		local cnt = string.format("PASS %d", st.n_pass or 0)
		if (st.n_fail or 0) > 0 then
			cnt = cnt .. string.format(" · FAIL %d", st.n_fail)
		end
		if (st.n_skip or 0) > 0 then
			cnt = cnt .. string.format(" · SKIP %d", st.n_skip)
		end

		o[#o + 1] = box(LIVE_X2, y, LIVE_STAGE_W, LIVE_NH,
			st.label or st.id or "", cnt, nil, st.tone)

		-- 证据框：浅底、无边框，视觉上是「附注」而非「节点」
		local ev = st.evidence or ""
		if ev ~= "" then
			local cy = y + math.floor(LIVE_NH / 2)
			o[#o + 1] = string.format(
				'<rect x="%d" y="%d" width="%d" height="%d" rx="6" ' ..
				'fill="currentColor" opacity="0.045"/>',
				LIVE_X3, cy - 13, LIVE_EVID_W, 26)
			o[#o + 1] = string.format(
				'<text x="%d" y="%d" font-size="11" fill="currentColor" ' ..
				'opacity="0.72">%s</text>',
				LIVE_X3 + 10, cy + 4, esc(truncate(ev, 64)))
		end
	end

	o[#o + 1] = "</g></svg></div>"
	return table.concat(o)
end

return D
