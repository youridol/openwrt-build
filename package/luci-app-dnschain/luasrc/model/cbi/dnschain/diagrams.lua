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
-- ── v0.16.4 重画：与「最新分流链路标准」逐节点对齐 ──────────────
--
-- 用户给的标准（需求原文，不可改写）：
--
--   入口条件：不在 GFW 名单、不在 blacklist、不在 china、不在任何数据库
--   ① 试直连（真实发请求）
--        通 → 落库：IP 写入 china 集合，域名写入 custom-domestic.txt
--        不通 → ②
--   ② 试代理（移入 blacklist 后再发请求）
--        通 → 落库：IP 写入 blacklist 集合，域名写入 custom-foreign.txt
--        不通 → ③
--   ③ 标记 dead，不加入任何集合
--
-- 旧图画的是**另一套逻辑**（域名 → 归属 → 首选链探测 → 保持/改道），
-- 那是 v0.13.0 的「健康探测 + 自动改道」，与上面的分诊标准不是一回事。
-- 两张图并列摆在同一页时，用户无法判断「到底哪套在起作用」——
-- 这正是本次要求「思维导图与最新分流逻辑一一对应」要解决的问题。
--
-- 新图的节点与标准逐条对应（左→右三段）：
--
--   入口判定 ─┬→ ① 试直连 ─┬→ 直连通 → 落库 china / custom-domestic
--             │             └→ 不通 → ②
--             ├→ ② 试代理 ─┬→ 代理通 → 落库 blacklist / custom-foreign
--             │             └→ 都不通 → ③
--             └→ 已有归属（跳过，不参与分诊）
--
-- 为什么仍然保留「已有归属」这一支：入口条件写的是「不在任何库里」才
-- 进入分诊，画上这一支才能表达「为什么有的目标不走这三步」。
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
local ROUTE_W, ROUTE_H = 860, 330

function D.route_map(opts)
	opts = opts or {}

	-- 图身份：v0.15.0 起不再有 marker id，prefix 只用于 data-dc-figure 标记。
	--
	-- 用 rawget 而不是 opts.id_prefix：lupa（测试用的真实 Lua 解释器）
	-- 把 Python dict 桥接成 Lua 表时，**缺失的键会抛 KeyError 而不是返回
	-- nil**，因为 Lua 侧的 __index 落到了 Python 的 __getitem__。
	-- 生产环境（原生 Lua 表）两者等价，但 rawget 在两种环境下都安全。
	local p = rawget(opts, "id_prefix") or "dcrt"

	-- ── 布局（改坐标必须同步改 route_layout，CI 有几何断言）────────
	--
	-- 三列：
	--   C1 入口 / 跳过判定      x=14  w=150
	--   C2 两个探测步骤          x=214 w=200
	--   C3 落库 / dead 结果      x=470 w=250
	--
	-- 三行（NH=64，GAP=24）：
	--   R1 y=16   未知目标     ① 试直连       直连通 → 落库
	--   R2 y=104  —            ② 试代理       代理通 → 落库
	--   R3 y=192  已有归属     ③ 标记 dead    不加入任何集合
	--
	-- ⚠️ 「已有归属」必须放 C1 而不是 C2。
	--
	--   放 C2 会占住 R3 的中间列，于是 ② → ③ 的竖线要么穿过它，
	--   要么被迫绕到 C2/C3 之间的空隙、又与 R3 的横向连线交叉。
	--   移到 C1 后，C2 列只剩 ①② 两个探测步骤，② → ③ 是一条
	--   24px 的短竖线，全程不碰任何节点。
	--
	-- ⚠️ NH 必须 ≥ 64：box() 的三行分别落在 y+21 / y+37 / y+51。
	--   取 48 时第三行（note）跑到框外，视觉上是「文字压在框的下边框上」，
	--   而只查 viewBox 越界的断言发现不了。
	local NW1, NW2, NW3 = 150, 200, 250
	local X1, X2, X3 = 14, 214, 470
	local NH, GAP = 64, 24

	local R1, R2, R3 = 16, 104, 192

	local y_note1 = 286
	local y_note2 = 304

	local o = {}
	-- ⚠️ 必须同时给出 width/height 固有尺寸（v0.13.0 实测修正）。
	--
	-- 只写 viewBox 时，SVG 没有「固有尺寸」，CSS 的 `width:auto`
	-- 会回落到 `100%` —— 图被拉伸到容器宽度，高度等比放大，
	-- 字号跟着涨。症状：图占满整屏还多，用户滚动时只看到几个放大的框，
	-- 反馈「导图看不到」。DOM 里 SVG 在、内容完整、纯几何断言全绿 ——
	-- 问题只在「没有固有尺寸」这一点上。
	--
	-- 写死 width/height 后浏览器按原始尺寸渲染，CSS 里再用
	-- max-width:100% 兜住窄屏。
	o[#o + 1] = string.format(
		'<div class="dc-chain dc-chain--map"><svg viewBox="0 0 %d %d" ' ..
		'width="%d" height="%d" role="img" ' ..
		'aria-label="%s">', ROUTE_W, ROUTE_H, ROUTE_W, ROUTE_H,
		esc(translate("未知目标分诊链路图")))
	o[#o + 1] = "<g" .. figure_attr(p) .. ">"

	local half = math.floor(NH / 2)
	local x1_r = X1 + NW1
	local x2_l = X2
	local x2_r = X2 + NW2
	local x3_l = X3

	--------------------------------------------------------------------
	-- 连线
	--
	-- ⚠️ 入口**只连 ①**，② 与 ③ 由「不通则下一步」的竖线引入。
	--
	--   初版从入口同时连出 ① 与 ② 两条曲线，语义上等于「入口可以直接
	--   去试代理」，与标准里的「① 不通 → 才进 ②」矛盾。图上多画一条线，
	--   读者就会以为存在一条不存在的路径。
	--------------------------------------------------------------------
	-- 入口 → ①（同排直线）
	o[#o + 1] = curve(x1_r, R1 + half, x2_l, R1 + half, "ok", p)
	-- 入口 → 已有归属（C1 列内竖虚线，全程不碰任何框：
	--   X1 列在 R2 那一排是空的）
	o[#o + 1] = vline(X1 + math.floor(NW1 / 2), R1 + NH + 2,
		R3 - 2, "mute", p)

	-- ① → 直连通
	o[#o + 1] = curve(x2_r, R1 + half, x3_l, R1 + half, "ok", p)
	-- ② → 代理通
	o[#o + 1] = curve(x2_r, R2 + half, x3_l, R2 + half, "warn", p)
	-- ③ → 不加入任何集合
	o[#o + 1] = curve(x2_r, R3 + half, x3_l, R3 + half, "bad", p)

	-- 「不通则下一步」：① → ②、② → ③
	--
	-- 两段都落在 C2 列中线、只跨 24px 的行间空隙，不碰任何节点。
	-- 用虚线（vline 自带 dasharray）表达「条件性推进」而非「必然流向」。
	o[#o + 1] = vline(X2 + math.floor(NW2 / 2), R1 + NH + 2, R2 - 2, "warn", p)
	o[#o + 1] = vline(X2 + math.floor(NW2 / 2), R2 + NH + 2, R3 - 2, "bad", p)

	--------------------------------------------------------------------
	-- 节点
	--------------------------------------------------------------------
	o[#o + 1] = box(X1, R1, NW1, NH, translate("未知目标"),
		translate("不在任何库"), translate("入口条件"), "info")
	o[#o + 1] = box(X1, R3, NW1, NH, translate("已有归属"),
		translate("跳过，不干预"), nil, "mute")

	o[#o + 1] = box(X2, R1, NW2, NH, translate("① 试直连"),
		translate("真实发请求"), nil, "ok")
	o[#o + 1] = box(X2, R2, NW2, NH, translate("② 试代理"),
		translate("先移入 blacklist"), translate("再发真实请求"), "warn")
	o[#o + 1] = box(X2, R3, NW2, NH, translate("③ 标记 dead"),
		translate("两条链路都不通"), nil, "bad")

	o[#o + 1] = box(X3, R1, NW3, NH, translate("直连通 → 落库"),
		translate("IP → china 集合"),
		translate("域名 → custom-domestic.txt"), "ok")
	o[#o + 1] = box(X3, R2, NW3, NH, translate("代理通 → 落库"),
		translate("IP → blacklist 集合"),
		translate("域名 → custom-foreign.txt"), "warn")
	o[#o + 1] = box(X3, R3, NW3, NH, translate("不加入任何集合"),
		translate("下一轮重新分诊"), nil, "bad")

	--------------------------------------------------------------------
	-- 底部说明：把标准的硬约束原样写出来
	--
	-- 图能表达结构，但「IP 一律转段入库」「dead 不入库」是**规则**，
	-- 只画线会让人自己推导；写在图下方才是可核对的。
	--------------------------------------------------------------------
	o[#o + 1] = label(X1 + 2, y_note1,
		translate("IP 一律先算成 CIDR 段再入库（已知网段表优先，否则 /24），不写单个 /32"),
		nil, 10, "0.7")
	o[#o + 1] = label(X1 + 2, y_note2,
		translate("dead 不进任何集合 —— 它没有可用链路，写进去只会把错误答案固化"),
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
		node_h = 64,
		-- 最后一个节点的底边（R3 + NH = 192 + 64）
		last_node_bottom = 192 + 64,
		note1 = 286,
		note2 = 304,
	}
end

-- ══════════════════════════════════════════════════════════════
-- v0.21.0：triage_map / triage_layout 已删除
--
-- 它们画「分诊结果的落点分布」（直连通 / 代理通 / dead 各多少条）。
-- 分诊功能整体移除后没有数据源，也没有存在的意义 ——
-- 未覆盖域名由 dnsproxy 的 --fallback 自动兜底，不再产生「落点」。
-- ══════════════════════════════════════════════════════════════

-----------------------------------------------------------------------
-- DNS 分流去向图（状态思维导图）
--
-- ── v0.21.0：语义重写 ────────────────────────────────────────────
--
-- 原图按「五档健康状态」分组（走首选链 / 首选链不稳 / 已切另一链 /
-- 双链故障 / 未探测），数据来自 dnschain-health 的探测结果。
--
-- 健康探测与自动改道在 v0.21.0 整体删除后，那五档失去了数据源。
-- 但用户明确要求**保留这张图**，改为显示**静态分流去向**：
--
--   根（分流去向）
--     ├─ 走直连 ── 自定义国内列表 + 未覆盖域名（默认 :5353）
--     └─ 走代理 ── 自定义国外列表 + gfw 名单（:5336）
--
-- 这张图回答的是「这个域名（及其子域名）现在走哪条链」，
-- 数据来自归属判定（dc_domain_class），是**静态事实**，不需要探测。
--
-- ── 为什么仍是两档而不是三档 ─────────────────────────────────────
--
-- 删除「首选链不稳 / 已切另一链 / 双链故障」三档，因为：
--   · 没有探测就没有「稳不稳」这个事实
--   · 直连不通时由 dnsproxy 的 --fallback 自动切 :5336，
--     那不是「改道」，是上游层的兜底，对用户不可见也不需要显示
--
-- 「未探测」档也删除 —— 静态分流不需要探测就能确定去向。
--
-- rows：{ { domain=..., chain="domestic"|"foreign", class=... }, ... }
--   由 general.lua 的 status_map cfgvalue 从归属判定构造。
-- summary：保留参数位以兼容旧调用（只用于总数，可传 nil）
-----------------------------------------------------------------------
local STATUS_ORDER = { "domestic", "foreign" }

-- 两档的标题、说明与语义色
--
-- tone 沿用既有的 ok / warn 配色：
--   直连 → ok（绿）  代理 → warn（黄，需要经代理，稍慢是正常的）
local STATUS_META = {
	["domestic"] = {
		title = translate("走直连"),
		tone = "ok",
		hint = translate("国内直连出口，不经代理"),
	},
	["foreign"] = {
		title = translate("走代理"),
		tone = "warn",
		hint = translate("经代理出口，可访问境外站点"),
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

-- v0.21.0：normalize_state 已删除（状态档位从五档减到两档，
-- 未知值在 layout_plan 里直接归 domestic，不需要单独归一函数）

-- 状态图的分组与布局计算（status_map 与 status_layout 共用）。
--
-- ⚠️ 抽出来的理由（v0.14.4）：原来 status_map 与 status_layout 各算一遍，
-- 口径不同 —— status_layout 用 `pairs(rows)` 数**数据行数**，而
-- status_map 画的是**档位数**（v0.21.0 起固定 2 档：直连 / 代理）；
-- status_layout 还把 NH 硬编码成 60，而 status_map 的 NH 随 hint
-- 折行数增长。历史教训：5 档各 1 个域名时 status_map 实际高 386，
-- status_layout 报 406 —— CI 的几何断言一直在验一个不存在的布局。
local function layout_plan(rows)
	rows = rows or {}

	-- 按链路分组（v0.21.0：只看 r.chain，未知值归 domestic）
	--
	-- 两档都**始终画出来**，即使某档为空 —— 空档本身是信息：
	-- 「走代理 0 个」说明用户还没录任何国外域名，这是有用的状态，
	-- 藏起来会让用户以为图坏了。
	local groups = {}
	for _, st in ipairs(STATUS_ORDER) do groups[st] = {} end
	for _, r in ipairs(rows) do
		local st = (r.chain == "foreign") and "foreign" or "domestic"
		groups[st][#groups[st] + 1] = r
	end

	local present = {}
	for _, st in ipairs(STATUS_ORDER) do
		present[#present + 1] = st
	end

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
		esc(translate("DNS 分流去向导图")))
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
	-- 根节点恒为绿色：两档都是「正常工作」，没有故障态可言
	local root_tone = "ok"

	o[#o + 1] = box(X1, root_y, ROOT_W, NH, translate("分流去向"),
		string.format(translate("共 %d 个"), n_all), nil, root_tone)

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
		-- v0.21.0：不再显示「域名 → 代理/直连」的改道箭头 ——
		-- 没有改道了，每个域名只属于它所在的那一档。
		local names = {}
		for _, r in ipairs(list) do
			names[#names + 1] = r.domain or "?"
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
--        **档位数**（v0.21.0 起固定 2 档）。行数 ≠ 档位数
--        时必然不等。
--     ② `NH` 硬编码 60，而 status_map 的 NH 会随 hint 折行数增长
--        （math.max(NH_MIN, 21+16+max_hint_lines*14+8)）。
--
--   历史实测（当时的 5 档各 1 个域名）：status_map 实际 viewBox 高 386，
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
local LIVE_NH = 58          -- 阶段节点高（v0.18.0 从 52 提到 58，多一行徽标）
local LIVE_GAP = 16         -- 阶段之间垂直间距
local LIVE_ROOT_W = 150     -- 根节点宽
local LIVE_STAGE_W = 176    -- 阶段节点宽（v0.18.0 从 168 微调，容下徽标文字）
local LIVE_EVID_W = 420     -- 证据框宽
local LIVE_X1 = 14          -- 根节点 x
local LIVE_X2 = 208         -- 阶段节点 x
local LIVE_X3 = 424         -- 证据框 x
local LIVE_TOP = 16         -- 首个阶段顶部

--- 链路拓扑图（v0.18.0 合并「解析链路」+「实时诊断链路」）
--
-- ── 为什么合并（ADR-0007 §2.3）──────────────────────────────────
--
-- 概览原本有两张图：
--   · 解析链路  —— 拓扑：dnsmasq→dnsproxy:5353/:5336→:1234 通不通
--   · 实时诊断链路 —— 20 项自检按 8 个阶段重分组
--
-- 两张都在讲「链路」，一张是结构、一张是阶段，并列要求用户在脑中做
-- 两次映射（「图 A 的那段」↔「图 B 的那个阶段」）。用户要的是
-- 「一眼看出哪里有问题」，一张「拓扑 + 每节点状态徽标」正好是这个效果。
--
-- ── 视觉语义（与旧版的区别）─────────────────────────────────────
--
--   · 节点串成**一条链**（竖直），表达「流量依次经过这些阶段」，
--     而不是旧版从根节点发散成 8 条平行支路（那读起来像「8 个独立检查」）
--   · 每个节点带状态徽标（PASS/FAIL/SKIP 计数），红的即断点
--   · 相邻节点之间画**箭头状连线**，断点处线条变红并加粗
--   · 证据框仍挂在节点右侧，但只在有证据时出现
--
-- ── 为什么保留函数名 live_diag_map ──────────────────────────────
--
-- 改名会连带改 general.lua 的调用、断言里的 `dclive` 标记、
-- 以及三处钉着 aria-label 的断言。收益（名字更准）远小于成本，
-- 所以保留名字，只改语义 —— 在 aria-label 上体现新定位。
--
-- 参数 stages：{ { id, label, tone, n_pass, n_fail, n_skip, evidence, note }, ... }
--   note 是可选副标题（兜底阶段用它显示「未归入链路阶段（共 N 项）」）
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
		LIVE_W, H, LIVE_W, H, esc(translate("链路拓扑图")))
	o[#o + 1] = "<g" .. figure_attr(p) .. ">"

	local root_right = LIVE_X1 + LIVE_ROOT_W

	-- ── 根 → 首个阶段（链路入口）──────────────────────────────
	o[#o + 1] = curve(root_right, root_cy, LIVE_X2,
		LIVE_TOP + math.floor(LIVE_NH / 2), stages[1].tone or "ok", p)

	-- ── 阶段之间的连线：竖直、带箭头语义（v0.18.0 新增）─────────
	--
	-- 旧版是「根 → 每个阶段」的发散结构，读起来像 8 个独立检查。
	-- 新版串成一条链：流量依次经过这些阶段，断了就往下传不过去。
	--
	-- 线条颜色取**上游节点**的状态色：上游坏了，下游这段就是红的。
	for i = 1, n - 1 do
		local y1 = LIVE_TOP + (i - 1) * (LIVE_NH + LIVE_GAP) + LIVE_NH
		local y2 = LIVE_TOP + i * (LIVE_NH + LIVE_GAP)
		local x  = LIVE_X2 + math.floor(LIVE_STAGE_W / 2)
		local tone = stages[i].tone or "ok"
		o[#o + 1] = vline(x, y1, y2, tone, p)
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

		-- 阶段节点：标题 = 阶段名，副标题 = 计数（或兜底阶段的 note）
		local cnt
		if st.note and st.note ~= "" then
			-- 兜底阶段：优先显示「未归入链路阶段（共 N 项）」，
			-- 这比 PASS/FAIL 计数更有信息量 —— 它在提示维护者去归组
			cnt = st.note
		else
			cnt = string.format("PASS %d", st.n_pass or 0)
			if (st.n_fail or 0) > 0 then
				cnt = cnt .. string.format(" · FAIL %d", st.n_fail)
			end
			if (st.n_skip or 0) > 0 then
				cnt = cnt .. string.format(" · SKIP %d", st.n_skip)
			end
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

--- 链路拓扑图的几何（供断言核对）
function D.live_diag_layout(stages)
	local n = #(stages or {})
	local h = LIVE_TOP * 2 + n * LIVE_NH + (n - 1) * LIVE_GAP
	return {
		w = LIVE_W,
		h = h,
		node_h = LIVE_NH,
		gap = LIVE_GAP,
		stages = n,
		last_node_bottom = LIVE_TOP + n * LIVE_NH + (n - 1) * LIVE_GAP,
	}
end

return D
