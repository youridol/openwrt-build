-- Copyright (C) 2026 openwrt-build
-- 网络 → DNS 链路
-- 设计依据: docs/adr/0003-dns-chain-framework.md / 0005-remove-chinadns-ng.md
--
-- 页面定位：DNS 配置总控台。集中管理 dnsmasq / dnsproxy / SSR-Plus
-- 三层的全部可控参数，并把链路实况可视化。
--
-- 它只做配置读写、校验、下发、自检与回滚，**不实现解析逻辑** ——
-- 页面与链路解耦是「改 UI 不坏链路」的前提。
--
-- ── 视觉实现说明（v0.12.0）──────────────────────────────────────
--
-- 用户要求用 shadcn MCP 重构前端。本包是 LuCI 应用（Lua + CBI 服务端
-- 渲染），仓库里没有 React / package.json / components.json，
-- `npx shadcn@latest info` 报告 framework="Manual"、config=null。
-- shadcn 的组件都是 React 组件，在这里无法安装也无法运行。
--
-- 因此实现的是 **shadcn 的视觉语言**而非其代码：
--   - 语义色令牌（ok/warn/bad/info）定义在 dnschain.css，
--     浅色与暗色两套，跟随 <html data-darkmode>
--   - 卡片 / 徽标 / 提示条 / 指标条 / 统计卡 / 表格 六类原语
--   - Tab 用前端分组实现（单张 CBI 表单 + JS 切换），
--     服务端仍是一次渲染，点击零网络请求
--
-- ── Tab 划分（6 个）──────────────────────────────────────────────
--
--   概览  链路图 + 指标 + 组件状态        ← 首屏主角，只读
--   解析  上游 / 双栈 / 端口 / 缓存        ← dnsproxy 与 dnsmasq 缓存
--   分流  名单规模 / 导入 / 源文件 / 归属   ← gfw 名单与 nftset
--   代理  SSR-Plus 兼容 / IPv6 / 拦截      ← 与 SSR-Plus 的接口
--   DHCP  DHCP 下发 DNS                    ← dnsmasq 的 DHCP 侧
--   诊断  自检表格 + 全部操作按钮          ← 只读结果 + 动作
--
-- 每个 section 通过 s.dc_tab 归组，由 dnschain.js 收拢成 tab 面板。

local ds = require "luci.model.cbi.dnschain.dnschain"
local dg = require "luci.model.cbi.dnschain.diagrams"

local m, s, o

m = Map("dnschain", translate("DNS 链路"),
	translate("集中控制 DNS 解析链路。dnsmasq / dnsproxy / SSR-Plus " ..
		"三层的可控参数都在这里，按功能分 Tab。"))

------------------------------------------------------------------------
-- 让按钮的操作结果能显示到页面上
--
-- 本页 5 个按钮原先都在 write() 里写 m.message，但**从来不会显示**。
-- 实测查明的三层原因（缺一层都不显示）：
--
--   ① Button 的 write() 需要非空 formvalue 才触发
--      （cbi.lua:1424 是 `if fvalue and #fvalue > 0`）。按钮 HTML 的
--      value 是按钮文字，浏览器提交会带上。
--   ② dispatcher.lua:237 是 `local cstate = res:parse()` —— 返回值被丢弃，
--      所以 state_handler 返回什么都到不了模板。
--   ③ dispatcher.lua:298 读的是 `res.message`，即 **map 对象自身的字段**。
--
--   m.message 这个字段名是 SimpleForm 的（cbi/simpleform.htm:22），
--   Map 模板不读它 —— 这就是原写法无效的原因。
--
-- 解法：write() 登记到 _pending_message → 覆写 state_handler，
-- 在 parse 结束时写到 self.message。
------------------------------------------------------------------------

local _pending_message = nil

local function setmsg(msg)
	_pending_message = msg
end

local _orig_state_handler = m.state_handler
function m.state_handler(self, state)
	local res = _orig_state_handler and _orig_state_handler(self, state)
	if _pending_message then
		self.message = _pending_message
		_pending_message = nil
	end
	return res
end

------------------------------------------------------------------------
-- Tab 归组
--
-- 为什么用「标题文本 → tab」映射，而不是给 section 打 HTML 属性：
--
--   CBI 的 section 模板（tsection.htm / nsection.htm）只输出固定结构，
--   不读取 section 对象上的自定义字段，所以没法直接加 data-dc-tab。
--
--   可选方案是覆盖模板文件，但那会把 LuCI 的内部结构复制进本包，
--   上游升级时容易冲突。改用「按标题文本归组」：
--   服务端输出一份 { 标题 => tab } 的 JSON，前端按 <h3> 文本匹配。
--
--   代价是标题文本不能随意改（改了要同步这张表），
--   但这比复制模板稳定得多。中文标题由 translate() 处理，
--   故映射表用 translate 后的值建键。
------------------------------------------------------------------------

local TAB_LABELS = {
	overview = translate("概览与诊断"),
	domains  = translate("域名"),
	resolve  = translate("解析"),
	split    = translate("分流"),
	proxy    = translate("代理"),
	dhcp     = translate("DHCP"),
}

-- section 标题 → tab
--
-- ⚠️ 键必须与 m:section() 的标题**逐字一致**（translate 后）。
--   两个自定义域名 section 现在的标题不同了（国内 / 国外），
--   否则页面上会出现两个同名块，且本表也只能映射到其中一个。
--
-- ── v0.15.0：概览与诊断合并 ────────────────────────────────────
--
-- 用户要求「概览 tab 和诊断合并在一页显示，严格查重重复功能移除」。
-- 合并前两个 tab 的内容重叠严重：
--
--   概览：结论徽标 / 解析链路图 / 分流决策图 / 链路指标 / 组件状态表
--   诊断：自检 20 项表格 / 两个配置项 / 5 个操作按钮
--
-- 重复项与处置：
--
--   ① 「结论徽标」与「自检 20 项」都来自 ds.selftest()，
--      展示的是同一次采集的两种视图（一句话 vs 逐项）。
--      → 保留两者但放同一 tab：徽标在顶部给结论，表格在下给证据。
--        请求级缓存保证 selftest 只跑一次（ds.cached）。
--   ② 概览里的「分流决策」图与「域名」tab 里的判定链路图
--      是**同一个函数 dg.route_map()** 渲染两次 —— 真正的重复。
--      → 删掉概览这份，只在「域名」tab 保留（那里还有单域名解释配套）。
--   ③ 「组件状态表」与「自检第 1–7 项」信息部分重叠，但前者是
--      端口/进程的实时快照、后者是端到端判定，视角不同，都保留。
--
-- 合并后 tab 由 7 个减为 6 个，「诊断」不再是独立 tab。
local SECTION_TAB = {
	-- 概览与诊断（合并）
	[translate("当前状态")]      = "overview",
	[translate("自检")]          = "overview",
	[translate("操作")]          = "overview",

	-- 域名 tab（v0.13.0）：自定义列表 + 判定链路 + 状态导图 + 改道表
	[translate("自定义域名 · 国内（补全归属）")] = "domains",
	[translate("自定义域名 · 国外（补全归属）")] = "domains",
	[translate("判定链路")]      = "domains",
	[translate("改道状态")]      = "domains",
	[translate("改道明细")]      = "domains",
	[translate("分诊结果")]      = "domains",
	[translate("观测与阈值")]    = "domains",
	[translate("域名操作")]      = "domains",

	[translate("国内上游")]      = "resolve",
	[translate("国外上游")]      = "resolve",
	[translate("双栈策略")]      = "resolve",
	[translate("端口与实例")]    = "resolve",
	[translate("缓存")]          = "resolve",

	[translate("名单规模")]      = "split",

	[translate("SSR-Plus 兼容")] = "proxy",
	[translate("拦截与框架开关")] = "proxy",

	[translate("DHCP 下发 DNS（明文）")] = "dhcp",
}

--- 输出 tab 元数据 + 加载静态资源
--
-- 为什么资源在 DummyValue 里输出：
--   LuCI 的 Map 页面没有「声明式附加资源」的接口（dispatcher 不提供
--   add_resource；cbi/map.htm 只渲染 section）。而 DummyValue 的
--   rawhtml 是原样输出的，浏览器会正常解析其中的 <link> 与 <script>。
--   这是最直接可靠的做法，不依赖主题内部结构。
--
-- 资源放在 htdocs/luci-static/resources/dnschain/，
-- 由 LuCI 静态路由自动暴露为 /luci-static/resources/dnschain/*。
local function emit_tab_meta(map)
	local meta = map:section(TypedSection, "dnschain", "")
	meta.anonymous = true
	meta.addremove = false
	local o = meta:option(DummyValue, "_dc_meta", "")
	o.rawhtml = true
	function o.cfgvalue()
		local function esc(s)
			-- JSON 字符串转义：反斜杠与双引号
			return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
		end
		local parts = {}
		for title, tab in pairs(SECTION_TAB) do
			parts[#parts + 1] = string.format('"%s":"%s"', esc(title), tab)
		end
		local labels = {}
		for id, lbl in pairs(TAB_LABELS) do
			labels[#labels + 1] = string.format('"%s":"%s"', id, esc(lbl))
		end

		-- ⚠️ 属性必须用**单引号**包裹。
		-- JSON 内容里有双引号，若属性用双引号（data-x="{...}"），
		-- 浏览器会在第一个 " 处截断，实测属性值只剩 "{"。
		local function attr(name, json)
			-- 内容里的单引号要转成 HTML 实体，避免提前闭合属性
			local v = (json:gsub("'", "&#39;"))
			return string.format(" %s='{%s}'", name, v)
		end

		local base = luci.config.main.resourcebase or "/luci-static/resources"

		-- ── 静态资源加版本号（v0.16.2 修）────────────────────────
		--
		-- 为什么必须加：这两个文件不带查询参数时，浏览器会按
		-- LuCI 的默认 Cache-Control 长期缓存。实测踩过：
		--
		--   改了 dnschain.js 的 countBadges()，文件已部署到
		--   /www/luci-static/…（fetch 带 nocache 能读到新内容），
		--   但页面**仍执行旧版** —— tab 徽标继续显示「10」，
		--   而用 DOM 模拟新逻辑却得出正确结果（counted=0）。
		--   换页面 URL 加 ?cachebust=1 也不生效（资源 URL 没变）。
		--
		--   这种失效最难查：服务端文件是对的、逻辑是对的、
		--   只有浏览器跑的是旧的 —— 会让人误以为代码没生效。
		--
		-- ⚠️ 版本号用 **包版本**（PKG_VERSION），不用文件 mtime。
		--   试过 nixio.fs.stat / luci.fs.stat 两条路，都会让本地校验器
		--   （tools/check-dnschain-lua.py）的桩缺失而整个文件加载失败
		--   （实测 PASS 从 132 掉到 78，报 "general.lua 能加载 FAIL"）。
		--   包版本是常量、无依赖，且语义正好 —— 「包升级了，资源该重拉」。
		local ver = "?v=1.3.3"

		return string.format(
			'<link rel="stylesheet" href="%s/dnschain/dnschain.css%s">' ..
			'<script defer src="%s/dnschain/dnschain.js%s"></script>' ..
			'<span data-dc-meta="1"%s%s></span>',
			base, ver, base, ver,
			attr("data-dc-section-tab", table.concat(parts, ",")),
			attr("data-dc-labels", table.concat(labels, ",")))
	end
end

------------------------------------------------------------------------
-- 概览：结论 + 链路图 + 指标 + 组件状态
--
-- 视觉取向：这是「诊断台」，首屏主角是**链路图** ——
-- 用户来这里的第一个问题是「现在请求怎么走、哪一段断了」。
-- 所以链路图最前，指标次之，组件状态表最后。
------------------------------------------------------------------------

s = m:section(TypedSection, "dnschain", translate("当前状态"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_conclusion", translate("结论"))
o.rawhtml = true
function o.cfgvalue()
	local result = ds.selftest()
	local concl = result.conclusion

	-- tone 由**语义分支**直接给出，不再回读译文判色（v0.14.4 修 L1）。
	--
	-- ⚠️ 原实现用 `concl:find("未监听")` 这类中文子串判色，而 concl 是
	--    translate() 后的字符串。任何非中文界面下所有分支都不命中 →
	--    永远绿色徽标。英文界面上「国内 dnsproxy 未监听 —— 客户机全部
	--    无法解析」会显示成绿色。中文文案微调也会让判色静默失效。
	local tone
	if concl == "" then
		local entry = ds.entry_port()
		local fport = ds.foreign_port()
		local fowner = ds.port_owner(fport, "udp")
		if not ds.port_listening(entry, "udp") then
			concl = translate("国内 dnsproxy 未监听 —— 客户机全部无法解析")
			tone = "bad"
		elseif fowner == "" then
			concl = translate("国外 dnsproxy 未监听 —— gfw 域名将 SERVFAIL，国内不受影响")
			tone = "bad"
		elseif not ds.is_dnsproxy(fowner) then
			concl = translate("国外端口被其他进程占用 —— gfw 域名会走错解析器")
			tone = "bad"
		elseif not ds.port_listening("1234", "tcp") then
			concl = translate("代理未运行 —— 国外域名将失败（国内不受影响）")
			tone = "bad"
		elseif ds.ssr_ipv6() ~= "1" then
			concl = translate("IPv6 流量代理未开 —— 国外 IPv6 会直连被 RST")
			tone = "warn"
		else
			concl = translate("链路正常")
			tone = "ok"
		end
	end

	-- concl 来自自检（已翻译好的整句），tone 未知时按关键字兜底一次，
	-- 但只在拿不到语义分支时才会走到这里。
	if not tone then
		local low = concl:lower()
		if low:find("servfail") or low:find("失败") or low:find("未监听")
			or low:find("占用") or low:find("failed") or low:find("not listening") then
			tone = "bad"
		elseif low:find("未开") or low:find("warn") or low:find("disabled") then
			tone = "warn"
		else
			tone = "ok"
		end
	end

	return string.format('<span class="dc-badge dc-badge--%s">%s</span>', tone, concl)
end

-- ── 链路图 ────────────────────────────────────────────────────────
o = s:option(DummyValue, "_chain_graph", translate("解析链路"))
o.rawhtml = true
function o.cfgvalue()
	local sn = ds.chain_snapshot()

	-- 颜色取自 CSS 变量，跟随明暗主题（不在 Lua 里硬编码色值）
	local function c(alive, warn)
		if warn then return "var(--dc-warn)" end
		return alive and "var(--dc-ok)" or "var(--dc-bad)"
	end

	-- ── 思维导图布局 ──────────────────────────────────────────────
	--
	-- 结构：左起单主干，在 dnsmasq 处一分为二（国内 / 国外两支），
	-- 之后各支再向右延伸。这正是实际的解析路径。
	--
	--        ┌─ dnsproxy国内 ── 国内上游
	-- LAN ─ dnsmasq ─┤
	--        └─ dnsproxy国外 ── SSR-Plus ── 国外上游
	--
	-- 连线全部用三次贝塞尔（C 指令）：
	--   v0.12.5 之前用直角折线（H V H），分叉处是硬拐角，视觉上像
	--   「断链」；改成贝塞尔后曲率连续，从节点边缘平滑出发。
	--
	-- ⚠️ 几何约束（改坐标必须同步改 W，CI 有断言）：
	--   最右节点 x = X5 = X4 + NW + GAP
	--   右边缘     = X5 + NW
	--   viewBox 宽 = W 必须 > 右边缘，留出边距
	--
	-- 列间距的取舍（v0.12.5）：
	--   dnsmasq 到 dnsproxy 那一列必须留出足够水平空间，否则分叉曲线
	--   的控制点无处安放（dx 上限 = 跨度/2），只能画成近乎垂直的折线。
	--   实测 X2→X3 从 188 拉到 216 后，曲线才有明显弧度。
	local W, H = 1120, 372
	local NW, NH = 128, 54
	local X1, X2, X3, X4 = 12, 228, 444, 720
	local GAP = 88
	local X5 = X4 + NW + GAP
	local YT, YB = 58, 226

	-- 各节点的垂直中心
	local YC = (YT + YB) / 2 + NH / 2   -- 主干中线
	local YTC = YT + NH / 2
	local YBC = YB + NH / 2

	local p = {}
	-- 给固有尺寸（width/height）：与两张导图一致，避免 CSS `width:auto`
	-- 在缺固有尺寸时回落到 100% 而放大。概览图本来就要自适应宽度，
	-- 由 `.dc-chain svg { width:100%; height:auto }` 覆盖这里的属性值，
	-- 所以写上是「有据可依的默认值」，不影响现有自适应行为。
	p[#p + 1] = string.format(
		'<div class="dc-chain"><svg viewBox="0 0 %d %d" width="%d" height="%d" ' ..
		'role="img" aria-label="%s">',
		W, H, W, H, translate("DNS 解析链路图"))

	-- 箭头标记：v0.15.0 按用户要求**全部移除**。
	--
	-- 原实现按状态色定义 3 个 <marker>（dc-a-ok/warn/bad）并给每条线
	-- 加 marker-end。移除后：
	--   · 连线只靠颜色与曲线形状表达走向
	--   · 不再需要 <defs>，也不再占用文档级 id
	--   · 与 diagrams.lua 的两张图口径一致（那边也移除了）
	-- 注意 hline/curve 的签名仍保留 color 参数 —— 它决定描边色，与箭头无关。

	--- 水平连线（两端节点垂直对齐时用）
	--
	-- 思维导图风格：轻微下沉的弧线，比直线更有「生长感」，
	-- 同时保持两端水平相接（起止切线水平，不会在节点边缘留缝）。
	local function hline(x1, x2, y, color)
		local mid = math.floor((x1 + x2) / 2)
		local dip = 3   -- 中点下沉像素
		return string.format(
			'<path d="M %d %d Q %d %d, %d %d" stroke="%s" stroke-width="2.5" ' ..
			'fill="none" stroke-linecap="round"/>',
			x1, y, mid, y + dip, x2, y, color)
	end

	--- 贝塞尔连线：从 (x1,y1) 平滑过渡到 (x2,y2)
	--
	-- 控制点取「水平各伸出 dx」的位置，形成 S 形。
	--
	-- ⚠️ dx 有硬上限 (x2-x1)/2（v0.12.5 修）：
	--   控制点必须满足 x1+dx <= x2-dx，否则第二控制点跑到第一控制点
	--   左边，曲线在中间兜回来、出现自交的 S 扭结 —— 看起来就是「断链」。
	--   实测踩过：dx=51 而 (x2-x1)/2=30，生成
	--     C 415 169, 373 85, 424 85    ← 415 > 373，扭结
	--
	-- 取值优先级：
	--   理想值 = 垂直落差 × 0.62（让起点切线约 30°，弧度明显且平滑）
	--   上限   = (x2-x1)/2（保证控制点不交叉）
	local function curve(x1, y1, x2, y2, color)
		local dy = math.abs(y2 - y1)
		local dx = math.floor(dy * 0.62)
		local cap = math.floor((x2 - x1) / 2)
		if dx > cap then dx = cap end
		if dx < 6 then dx = 6 end
		return string.format(
			'<path d="M %d %d C %d %d, %d %d, %d %d" stroke="%s" ' ..
			'stroke-width="2.5" fill="none" stroke-linecap="round"/>',
			x1, y1, x1 + dx, y1, x2 - dx, y2, x2, y2, color)
	end

	-- 节点：状态点 + 标题 + 副标题 + 说明
	--
	-- 填充用 --dc-surface 而不是 none：连线画在节点下层，
	-- 无填充时线会从节点内部透出来，看起来像「断链」。
	local function node(x, y, title, sub, alive, note)
		local col = c(alive)
		local s2 = string.format(
			'<g><rect x="%d" y="%d" width="%d" height="%d" rx="9" ' ..
			'fill="var(--dc-surface)" stroke="%s" stroke-width="2"/>' ..
			'<circle cx="%d" cy="%d" r="4" fill="%s"/>' ..
			'<text x="%d" y="%d" font-size="13" font-weight="600" fill="%s">%s</text>' ..
			'<text x="%d" y="%d" font-size="11" fill="%s" opacity="0.72">%s</text>',
			x, y, NW, NH, col,
			x + 12, y + 15, col,
			x + 24, y + 22, "currentColor", title,
			x + 24, y + 39, "currentColor", sub)
		if note then
			s2 = s2 .. string.format(
				'<text x="%d" y="%d" font-size="10" fill="%s" opacity="0.55">%s</text>',
				x + 24, y + 50, "currentColor", note)
		end
		return s2 .. '</g>'
	end

	local function label(x, y, txt, anchor)
		return string.format(
			'<text x="%d" y="%d" font-size="10" fill="%s" opacity="0.7"%s>%s</text>',
			x, y, "currentColor", anchor and (' text-anchor="' .. anchor .. '"') or "", txt)
	end

	-- ── 连线（先画，节点压在上层）──────────────────────────────────
	--
	-- 每条线都从「上一节点的右边缘」到「下一节点的左边缘」，
	-- 不留缝隙 —— 这是「不能断链」的关键。
	local cn_col = c(sn.dnsproxy_cn)
	local fg_col = c(sn.dnsproxy_fg)
	local proxy_col = c(sn.proxy_1234)
	local main_col = c(sn.dnsmasq)

	-- 主干：LAN → dnsmasq
	p[#p + 1] = hline(X1 + NW, X2, YC, main_col)

	-- 分叉：dnsmasq → 两个 dnsproxy
	--
	-- 两条曲线都从 dnsmasq 右缘**同一点**（YC）出发 —— 这是思维导图的
	-- 关键：从主干上一点放射出多条支线，而不是从两个错开的点各发一条
	-- （错开会在节点边缘形成一个小尖角，看起来像没接上）。
	p[#p + 1] = curve(X2 + NW, YC, X3, YTC, cn_col)
	p[#p + 1] = curve(X2 + NW, YC, X3, YBC, fg_col)

	-- 上支：dnsproxy国内 → 国内上游
	p[#p + 1] = hline(X3 + NW, X4, YTC, cn_col)

	-- 下支：dnsproxy国外 → SSR-Plus → 国外上游
	p[#p + 1] = hline(X3 + NW, X4, YBC, fg_col)
	p[#p + 1] = hline(X4 + NW, X5, YBC, proxy_col)

	-- ── 节点 ──────────────────────────────────────────────────────
	p[#p + 1] = node(X1, YC - NH / 2, translate("LAN 客户机"),
		translate("DHCP 下发"), true, nil)
	p[#p + 1] = node(X2, YC - NH / 2, "dnsmasq", ":53",
		sn.dnsmasq, sn.dnsmasq and translate("缓存 + 分流") or translate("未监听"))
	p[#p + 1] = node(X3, YT, translate("dnsproxy 国内"), ":" .. sn.entry_port,
		sn.dnsproxy_cn, translate("阿里 DoT/DoH"))
	p[#p + 1] = node(X3, YB, translate("dnsproxy 国外"), ":" .. sn.foreign_port,
		sn.dnsproxy_fg, translate("Google DoH"))
	p[#p + 1] = node(X4, YT, translate("国内上游"), translate("直连"),
		sn.dnsproxy_cn, translate("223.5.5.5"))
	p[#p + 1] = node(X4, YB, "SSR-Plus", ":1234",
		sn.proxy_1234, sn.proxy_1234 and translate("透明代理") or translate("未运行"))
	p[#p + 1] = node(X5, YB, translate("国外上游"), translate("经代理"),
		sn.proxy_1234 and sn.dnsproxy_fg, translate("dns.google"))

	-- 分叉标注
	--
	-- 分叉处水平只有 60px（X2+NW=364 到 X3=424）、垂直落差 84px，
	-- 空间很窄 —— 标签放进去必然压线（实测「默认」直接盖在曲线上）。
	--
	-- 改放在两个 dnsproxy 节点的**上方/下方空白区**，用短引线指到曲线，
	-- 既清晰又不遮挡连线。
	local function forkLabel(x, y, txt, anchor)
		return string.format(
			'<text x="%d" y="%d" font-size="10" fill="%s" opacity="0.7"%s>%s</text>',
			x, y, "currentColor", anchor and (' text-anchor="' .. anchor .. '"') or "", txt)
	end
	-- 「默认」在 dnsproxy 国内 上方
	p[#p + 1] = forkLabel(X3, YT - 10, translate("默认 → 国内上游"), "start")
	-- 「gfw 域名」在 dnsproxy 国外 下方
	p[#p + 1] = forkLabel(X3, YB + NH + 18, translate("gfw 域名 → 经代理出站"), "start")

	-- 底部说明（v0.16.0 改写）
	--
	-- 原文只写了「nftset 写入 blacklist → 流量进 :1234」，那是**旧机制**
	-- 的单一通路。现在实际有两条落库路径，且判定依据是实测而非静态归属：
	--
	--   ① 静态分流：域名在 gfw 名单里 → nftset 写 blacklist → 走 :1234
	--   ② 动态分诊：不在任何库的目标 → 试直连/试代理 → 按实测结果落库
	--
	-- 只写①会让看图的人以为「不在 gfw 名单就一定直连」，而实际
	-- 不在任何库的目标要先经过分诊，否则会落到兜底规则被误送代理
	-- （这正是 cdn.staticsfile.org 白屏的成因）。
	p[#p + 1] = label(X1 + 2, H - 30,
		translate("静态分流：gfw 名单命中 → nftset 写 blacklist → 流量进 :1234"))
	p[#p + 1] = label(X1 + 2, H - 16,
		translate("动态分诊：不在任何库 → 试直连，通→写 china；不通→试代理，通→写 blacklist；都不通→标 dead"))

	p[#p + 1] = '</svg></div>'
	return table.concat(p)
end

-- ── 实时诊断链路图（v0.15.0 新增，替代原「分流决策」在概览的重复渲染）──
--
-- 用户要求「加上实时诊断的链路思维导图」。
--
-- 与已有的三张图的区别（这是它存在的理由，不是又一张重复图）：
--
--   解析链路（_chain_graph）   静态拓扑 + 端口存活色。回答「组件在不在」。
--   判定链路（dg.route_map）   域名归属规则。回答「某个域名会怎么走」。
--   改道状态（dg.status_map）  观测域名的当前改道状态。回答「谁被改道了」。
--   ★ 实时诊断（本项）          **逐段实测判定**。回答「哪一段真的通、
--                             哪一段是死的、证据是什么」。
--
-- 数据来源是 ds.selftest() 的 20 项结果 —— 按**链路阶段**重新分组，
-- 每组取该项的 PASS/FAIL/SKIP 与证据串。这样一眼能看出断点在哪一段，
-- 而不用在 20 行表格里逐行找红色。
--
-- ⚠️ 不新增后端调用：selftest 已被 _conclusion 调用过，请求级缓存命中。
o = s:option(DummyValue, "_live_diag_map", translate("实时诊断链路"))
o.rawhtml = true
function o.cfgvalue()
	local result = ds.selftest()
	local items = result.items or {}

	-- 自检项 → 链路阶段分组
	--
	-- 键是阶段名，值是该阶段包含的自检项编号（与 dnschain-selftest 的
	-- `emit <序号>` 一一对应）。改 selftest 的项号时**必须同步这里**，
	-- tools/verify-dnschain-domains.sh 有断言检查编号覆盖完整。
	local STAGES = {
		{ id = "client",  label = translate("客户机入口"), items = { 1 } },
		{ id = "dnsmasq", label = "dnsmasq",           items = { 3, 15, 16 } },
		{ id = "domestic", label = translate("国内链路"), items = { 4, 5, 8, 9 } },
		{ id = "foreign",  label = translate("国外链路"), items = { 10, 11, 12 } },
		{ id = "proxy",    label = translate("代理与分流"), items = { 13 } },
		{ id = "split",    label = translate("分流规则"), items = { 2, 17, 18 } },
		{ id = "fw4",      label = "fw4",              items = { 14, 20 } },
		{ id = "policy",   label = translate("双栈与端口"), items = { 6, 7, 19 } },
	}

	local by_no = {}
	for _, it in ipairs(items) do
		by_no[tonumber(it.no) or 0] = it
	end

	-- 每个阶段汇总：最差状态 + 证据
	local function worst(st)
		local n_pass, n_fail, n_skip = 0, 0, 0
		local first_bad = nil
		for _, no in ipairs(st.items) do
			local it = by_no[no]
			if it then
				if it.status == "PASS" then n_pass = n_pass + 1
				elseif it.status == "SKIP" then n_skip = n_skip + 1
				else
					n_fail = n_fail + 1
					if not first_bad then first_bad = it end
				end
			end
		end
		local tone = "ok"
		if n_fail > 0 then tone = "bad"
		elseif n_skip > 0 then tone = "warn" end
		return tone, n_pass, n_fail, n_skip, first_bad
	end

	-- ── 组装阶段数据，交给 diagrams.lua 画思维导图 ──────────
	--
	-- v0.16.3：原来在这里内联拼 SVG（纵向列表），用户要求改成
	-- 思维导图。绘图逻辑移进 diagrams.lua 的 live_diag_map()，
	-- 与页面其余三张图同一套视觉语言（圆角节点、状态色、贝塞尔连线）。
	--
	-- 这里只负责「把 selftest 的 20 项归组成 8 个阶段」这件事 ——
	-- 归组规则是本页的业务知识，不该散到绘图层。
	local stage_data = {}
	for _, st in ipairs(STAGES) do
		local tone, n_pass, n_fail, n_skip, first_bad = worst(st)

		-- 证据：优先显示失败项的证据，否则显示本阶段第一项的证据
		local ev = ""
		if first_bad then
			ev = tostring(first_bad.detail or "")
		else
			for _, no in ipairs(st.items) do
				local it = by_no[no]
				if it and it.detail and it.detail ~= "" then
					ev = tostring(it.detail)
					break
				end
			end
		end

		stage_data[#stage_data + 1] = {
			id       = st.id,
			label    = st.label,
			tone     = tone,
			n_pass   = n_pass,
			n_fail   = n_fail,
			n_skip   = n_skip,
			evidence = ev,
		}
	end

	return dg.live_diag_map(stage_data)
end

-- ── 链路指标 ──────────────────────────────────────────────────────
o = s:option(DummyValue, "_charts", translate("链路指标"))
o.rawhtml = true
function o.cfgvalue()
	local sn = ds.chain_snapshot()

	-- 三条相对长度条形，绝对值标右侧
	local metrics = {
		{ label = translate("缓存插入"), value = sn.inserted,  cls = "info" },
		{ label = translate("转发上游"), value = sn.forwarded, cls = "ok" },
		{ label = translate("本地应答"), value = sn.local_ans, cls = "warn" },
	}

	local maxv = 1
	for _, mt in ipairs(metrics) do
		if (mt.value or 0) > maxv then maxv = mt.value end
	end

	local rows = {}
	for _, mt in ipairs(metrics) do
		local v = mt.value
		local pct = (v and v > 0) and math.floor(v * 100 / maxv) or 0
		rows[#rows + 1] = string.format(
			'<div class="dc-metric">' ..
			'<span class="dc-metric__label">%s</span>' ..
			'<span class="dc-metric__track">' ..
			'<span class="dc-metric__fill dc-metric__fill--%s" style="width:%d%%"></span>' ..
			'</span>' ..
			'<span class="dc-metric__value">%s</span></div>',
			mt.label, mt.cls, pct, v and tostring(v) or "—")
	end

	local function stat(label, value, hint)
		return string.format(
			'<div class="dc-stat">' ..
			'<div class="dc-stat__label">%s</div>' ..
			'<div class="dc-stat__value">%s</div>' ..
			'<div class="dc-stat__hint">%s</div></div>',
			label, value, hint)
	end

	local stats = table.concat({
		stat(translate("分流规则"), tostring(sn.split_count), translate("条 server=/域名/")),
		stat(translate("代理 IP 集"), tostring(sn.blacklist), translate("个国外 IP")),
		stat(translate("国内 IP 段"), tostring(sn.china), translate("个 CIDR")),
		stat(translate("未应答"), sn.unanswered and tostring(sn.unanswered) or "—",
			translate("次查询")),
	})

	return '<div class="dc-metrics">' .. table.concat(rows) .. '</div>' ..
		'<div class="dc-stats">' .. stats .. '</div>'
end

-- ── 组件状态表 ────────────────────────────────────────────────────
o = s:option(DummyValue, "_topology", translate("组件状态"))
o.rawhtml = true
function o.cfgvalue()
	local entry = ds.entry_port()
	local fport = ds.foreign_port()

	local rows = {}

	local function row(name, port, ok, detail)
		local badge = ok and '<span class="dc-badge dc-badge--ok">正常</span>'
			or '<span class="dc-badge dc-badge--bad">异常</span>'
		rows[#rows + 1] = string.format(
			'<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',
			name, port or "—", badge, detail or "")
	end

	local dnsmasq_ok = ds.port_listening("53", "udp")
	row("dnsmasq", "53", dnsmasq_ok,
		dnsmasq_ok and translate("唯一缓存层 + 唯一分流层 + DHCP") or translate("未监听"))

	local dp_ok = ds.port_listening(entry, "udp")
	row(translate("dnsproxy（国内）"), entry, dp_ok,
		dp_ok and translate("阿里 DoT/DoH，直连") or translate("未监听"))

	local f_pid = ds.port_owner(fport, "udp")
	local f_ok = ds.is_dnsproxy(f_pid)
	row(translate("dnsproxy（国外）"), fport, f_ok,
		f_ok and translate("Google DoH，经代理出站") or
		(f_pid ~= "" and (translate("被其他进程占用 (PID ") .. f_pid .. ")") or translate("未监听")))

	local proxy_ok = ds.port_listening("1234", "tcp")
	row(translate("SSR-Plus 代理"), "1234", proxy_ok,
		proxy_ok and translate("透明代理（IPv4 + IPv6）") or translate("未运行"))

	local v6_ok = (ds.ssr_ipv6() == "1")
	row(translate("IPv6 流量代理"), "ipv6_support", v6_ok,
		v6_ok and translate("已启用，国外 IPv6 也走代理") or translate("未启用"))

	local cstat = ds.cache_stats()
	local cache_ok = (cstat.dns_cache_inserted or 0) > 0
	row(translate("缓存"), "dnsmasq", cache_ok,
		string.format(translate("插入 %d / 本地应答 %d / 转发 %d"),
			cstat.dns_cache_inserted or 0,
			cstat.dns_local_answered or 0,
			cstat.dns_queries_forwarded or 0))

	return '<div class="dc-table-wrap"><table class="dc-table"><thead><tr>' ..
		'<th>' .. translate("组件") .. '</th>' ..
		'<th>' .. translate("端口") .. '</th>' ..
		'<th>' .. translate("状态") .. '</th>' ..
		'<th>' .. translate("说明") .. '</th>' ..
		'</tr></thead><tbody>' .. table.concat(rows) .. '</tbody></table></div>'
end

------------------------------------------------------------------------
-- Tab「域名」：自定义列表 + 判定链路 + 改道状态（v0.13.0）
--
-- 这一页要回答三个问题，顺序就是三个 section 的顺序：
--
--   ① 我录了哪些域名？            → 自定义域名（两个输入框 + 已录入清单）
--   ② 某个域名会怎么走、为什么？  → 判定链路（思维链路图）
--   ③ 现在哪些域名不正常？        → 改道状态（状态思维导图 + 明细表）
--
-- 为什么①②③必须是同一个 tab：
--   用户改完列表后最想知道的是「这下它会怎么走」，而改道状态又直接
--   依赖归属判定。拆成两个 tab 时，用户得来回切才能把三件事对上，
--   而这三件事在逻辑上是一条链。
------------------------------------------------------------------------

-- 归属标签（两处表格共用，避免两套文案漂移）
local CLASS_LABEL = {
	["custom-domestic"] = translate("自定义 · 国内"),
	["custom-foreign"]  = translate("自定义 · 国外"),
	["db-foreign"]      = translate("数据库命中"),
	["uncovered"]       = translate("未覆盖"),
	["invalid"]         = translate("格式非法"),
}

local function ds_class_label(cls)
	return dg.esc(CLASS_LABEL[cls] or cls or "—")
end

-- 校验一个域名（页面侧第一道闸）
--
-- 与脚本里的 dc_domain_valid 保持同一套规则，但**不追求完全等价**：
-- 这里的目标是「用户敲错时立刻看到」，脚本那道闸才是权威。
-- 页面校验写得过于复杂反而会误拒合法域名（例如 xn-- 形式的 IDNA），
-- 所以这里只拦「明显不对」的形态，剩下的交给脚本。
local function validate_domain(value)
	local raw = tostring(value or "")
	local v = raw:gsub("^%s+", ""):gsub("%s+$", ""):lower():gsub("%.$", "")

	-- 空值放行：DynamicList 的「最后一行空输入」是正常的，
	-- 由 rmempty 负责把它丢掉。这里返回 nil 会被当成「校验失败」，
	-- 用户就会看到「保存成功但配置没变」这种更难查的现象。
	-- 空值返回**归一化后**的空串（v0.14.4 修 M2）。
	-- 原实现 `return value` 返回的是原始输入，若用户输入纯空格，
	-- 得到 "  " 而非 ""，rmempty 判据不认它为空 → 一个空格串被写进
	-- UCI list，随后靠 dc_domain_valid 才拦住（页面无提示）。
	if v == "" then return v end

	if v:find("%s") then
		return nil, translate("不能含空格：") .. v
	end
	if v:find("[^a-z0-9%.%-]") then
		return nil, translate("只能包含字母、数字、点与连字符：") .. v
	end
	if v:find("%.%.") or v:sub(1, 1) == "." or v:sub(-1) == "." then
		return nil, translate("点的位置不对：") .. v
	end
	if not v:find("%.") then
		return nil, translate("至少要有两级（例如 example.com）：") .. v
	end

	-- 不做「禁止 --」的检查：xn-- 是合法的 IDNA 前缀，
	-- punycode 编码结果里也会出现 --。拦它会把 IDNA 域名误拒。
	local tld = v:match("%.([^%.]+)$") or ""
	if #tld < 2 then
		return nil, translate("顶级域至少 2 位：") .. v
	end
	if tld:match("^%d+$") then
		return nil, translate("顶级域不能是纯数字：") .. v
	end

	-- ── 以下四条与 shell 的 dc_domain_valid 对齐（v0.14.4 修 M1）──
	--
	-- ⚠️ 原实现只校验前 5 条，比 dc_domain_valid 少了这 4 条。
	--    后果：页面放行、写进 UCI，随后 dc_list_normalize 里
	--    `dc_domain_valid || continue` **静默跳过** —— 该域名不生成分流
	--    规则、不参与健康检测，而「已录入清单」表格仍显示它（读的是 UCI
	--    原值）。用户看到「已录入」却完全不生效，且无任何错误。
	--
	--    判据必须保证「页面拒绝集合 ⊆ 脚本拒绝集合」，否则必然漂移。

	-- 总长 ≤ 253（DNS 协议上限）
	if #v > 253 then
		return nil, translate("总长不能超过 253 个字符：") .. v
	end

	-- 每个 label ≤ 63，且首尾不能是连字符
	local label_bad
	for label in v:gmatch("[^%.]+") do
		if #label > 63 then
			label_bad = translate("每段不能超过 63 个字符：") .. label
			break
		end
		if label:sub(1, 1) == "-" or label:sub(-1) == "-" then
			label_bad = translate("每段首尾不能是连字符：") .. label
			break
		end
	end
	if label_bad then
		return nil, label_bad
	end

	-- 顶级域：xn-- 除外，必须纯字母（shell 侧同此判据）
	if not tld:match("^xn%-%-") and tld:match("[^a-z]") then
		return nil, translate("顶级域只能是字母（IDNA 用 xn-- 前缀）：") .. v
	end

	return v
end

-- ── 自定义域名（数据库补全）──────────────────────────────────────
--
-- 定位（v0.14.0 语义矫正，务必按这个理解改代码）：
--
--   这里是**补全数据库没覆盖的域名归属**，不是「手动改道开关」。
--   写进来的域名只做一件事：告诉框架「它的归属是哪条链」。
--   之后由 dnsmasq（server=/域名/）+ dnsproxy（两个实例）按归属分流，
--   并且**仍然参与健康检测与自动改道** —— 首选链不通、另一条通时照样改道。
--
--   旧文案写的是「不参与自动改道，你写的就是最终答案」，那是错的：
--   它让用户显式补全归属的域名反而失去了自动恢复能力。
--
-- 为什么是两个 NamedSection 而不是一个 section 两个 list：
--   UCI 里它们是两个独立的 config 段（dom_domestic / dom_foreign），
--   放进同一个 NamedSection 写回时会互相覆盖。
--   但**标题必须能区分**，否则页面上会出现两个一模一样的「自定义域名」。
s = m:section(NamedSection, "dom_domestic", "domains",
	translate("自定义域名 · 国内（补全归属）"),
	translate("手工补全数据库没覆盖的域名归属。<b>这里只决定「归属」，不是改道开关</b>：" ..
		"归属定了之后由 dnsmasq 与 dnsproxy 分流，且<b>仍然参与健康检测</b> —— " ..
		"首选链不通、另一条链通时照样自动改道。<br/>" ..
		"格式：只接受域名（含 <code>xn--</code> 形式），不接受通配符、IP、URL。"))
s.addremove = false

o = s:option(DynamicList, "domain", translate("国内域名（归属直连）"),
	translate("这些域名的归属记为国内 → 首选走国内 dnsproxy 实例（直连出口），" ..
		"解析结果同时写入 <code>china</code> IP 集。"))
o.datatype = "string"
o.rmempty = true
o.placeholder = "www.baidu.com"
o.validate = validate_domain

s = m:section(NamedSection, "dom_foreign", "domains",
	translate("自定义域名 · 国外（补全归属）"),
	translate("同上，但归属记为国外 → 首选走国外 dnsproxy 实例" ..
		"（经 <code>:1234</code> 代理出口），解析结果写入 <code>blacklist</code> IP 集。"))
s.addremove = false

o = s:option(DynamicList, "domain", translate("国外域名（归属代理）"),
	translate("这些域名的归属记为国外。同样<b>参与健康检测与自动改道</b>。"))
o.datatype = "string"
o.rmempty = true
o.placeholder = "www.google.com"
o.validate = validate_domain

-- 已录入清单 + 生效状态
--
-- 为什么同时显示「已保存」与「已生效」：
--   点保存只写 UCI，真正改分流要等 apply（它会重启 dnsmasq，
--   约 3 秒中断，所以不能自动触发）。只显示一份时，
--   用户保存完看不到变化会以为没生效，反复点保存。
o = s:option(DummyValue, "_domains_list", translate("已录入清单"))
o.rawhtml = true
function o.cfgvalue()
	local dom_uci = ds.uci_list("dom_domestic", "domain")
	local for_uci = ds.uci_list("dom_foreign", "domain")
	local dom_run = ds.custom_domestic()
	local for_run = ds.custom_foreign()

	-- 「已生效 / 待应用」徽标
	--
	-- ⚠️ 必须比「合法条数」，不能比 UCI 原始 token 数（v0.14.4 修 M4）。
	--
	--   原实现左边用 `#list`（`uci -q get` 的原始 token 数），右边用
	--   `n_run`（规范化 + 校验后的生效条数）。只要列表里有一个非法域名，
	--   两者**永久不等** —— 用户点了「重建分流规则并生效」、
	--   custom-domestic.txt 已正确重建，徽标仍显示「待应用（生效 2 条）」，
	--   反复点应用也永远等不到「已生效」。
	--
	--   现在左侧改用与 n_run 同源的「合法条数」，非法项单独用红徽标列出。
	local function count_valid(list)
		local n = 0
		for _, raw in ipairs(list) do
			if validate_domain(raw) then n = n + 1 end
		end
		return n
	end

	local function badge(list, n_run)
		local n_valid = count_valid(list)
		local n_bad = #list - n_valid
		if n_valid == n_run and n_bad == 0 then
			return '<span class="dc-badge dc-badge--ok">' .. translate("已生效") .. '</span>'
		end
		local parts = {}
		if n_valid ~= n_run then
			parts[#parts + 1] = string.format(translate("待应用（生效 %d 条）"), n_run)
		end
		if n_bad > 0 then
			parts[#parts + 1] = string.format(translate("%d 条格式非法，已跳过"), n_bad)
		end
		local tone = (n_bad > 0) and "dc-badge--bad" or "dc-badge--warn"
		return '<span class="dc-badge ' .. tone .. '">' ..
			table.concat(parts, " · ") .. '</span>'
	end

	local function chips(list, tone)
		if #list == 0 then
			return '<span class="dc-badge dc-badge--mute">' .. translate("（空）") .. '</span>'
		end
		local out = {}
		for _, d in ipairs(list) do
			out[#out + 1] = string.format(
				'<span class="dc-chip dc-chip--%s">%s</span>', tone, dg.esc(d))
		end
		return table.concat(out, " ")
	end

	local function row(title, list, n_run, tone)
		return string.format(
			'<tr><td>%s</td><td class="dc-table__num">%d</td>' ..
			'<td>%s</td><td>%s</td></tr>',
			title, #list, badge(list, n_run), chips(list, tone))
	end

	return '<div class="dc-table-wrap"><table class="dc-table"><thead><tr>' ..
		'<th>' .. translate("列表") .. '</th>' ..
		'<th class="dc-table__num">' .. translate("条数") .. '</th>' ..
		'<th>' .. translate("状态") .. '</th>' ..
		'<th>' .. translate("域名") .. '</th>' ..
		'</tr></thead><tbody>' ..
		row(translate("国内（直连）"), dom_uci, #dom_run, "dom") ..
		row(translate("国外（代理）"), for_uci, #for_run, "for") ..
		'</tbody></table></div>' ..
		'<div class="dc-hint">' ..
		translate("点「保存并应用」才会重建分流规则（会重启 dnsmasq，约 3 秒解析中断）。") ..
		'</div>'
end

-- ── 判定链路（思维链路图）──────────────────────────────────────────
s = m:section(TypedSection, "dnschain", translate("判定链路"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_route_map", translate("走法"))
o.rawhtml = true
function o.cfgvalue()
	return dg.route_map({
		entry_port   = ds.entry_port(),
		foreign_port = ds.foreign_port(),
		-- 与概览那张图区分（理由见概览里的注释）
		id_prefix    = "dcrt-dm",
	})
end

-- 单域名解释：用户输入一个域名，页面把「归属 → 首选 → 探测 → 结论」摊开
--
-- 为什么用 GET 参数而不是按钮 + 会话变量：
--   这里的查询是「看一眼就走」，不该持久化成 UCI 键（那会让配置里
--   多出一个和分流无关的字段，备份/还原时也跟着跑）。
--   用一次带参数的 GET 刷新即可，服务端读 formvalue 渲染结果。
--
-- 为什么 pcall 包一层：formvalue 只在真正的 HTTP 请求上下文里可用。
--   在 CLI（lua -e）或单元测试里调本文件时它不存在，
--   直接调会抛 "attempt to call a nil value" —— 整个页面 500。
local explain_domain = ""
do
	local http = require "luci.http"
	if http and type(http.formvalue) == "function" then
		local ok, v = pcall(http.formvalue, "dc_explain")
		if ok and type(v) == "string" then
			explain_domain = v:gsub("^%s+", ""):gsub("%s+$", "")
		end
	end
end

o = s:option(DummyValue, "_explain", translate("单域名解释"))
o.rawhtml = true
function o.cfgvalue()
	local function esc(s) return dg.esc(s) end

	-- ⚠️ 这里**不能**用 <form>。
	-- CBI 的 map 模板已经把整页包在 <form method="post"> 里，
	-- 再嵌一个 <form> 是非法 HTML：浏览器会直接丢掉内层 form 标签，
	-- 于是「解释」按钮实际提交的是**外层**表单 —— 也就是触发一次保存，
	-- 用户点「解释」却看到「配置已保存」，还会把没改完的输入一起提交。
	-- 改用普通 input + button，由 dnschain.js 绑点击后自己跳转。
	local input = string.format(
		'<div class="dc-inline-form" data-dc-explain>' ..
		'<input type="text" class="cbi-input-text" data-dc-explain-input value="%s" ' ..
		'placeholder="%s" />' ..
		'<button type="button" class="cbi-button cbi-button-action" data-dc-explain-go>%s</button>' ..
		'</div>',
		esc(explain_domain), translate("输入域名，例如 github.com"), translate("解释"))

	if explain_domain == "" then
		return input .. '<div class="dc-hint">' ..
			translate("输入一个域名，下面会列出它的归属、首选链路、两条链的实测结果与最终判定。") ..
			'</div>'
	end

	local e = ds.explain(explain_domain)

	if not next(e) then
		return input .. '<div class="dc-alert dc-alert--bad">' ..
			'<span class="dc-alert__icon">✗</span><div>' ..
			translate("取不到解释结果 —— 检查 /usr/bin/dnschain-health 是否存在且可执行。") ..
			'</div></div>'
	end

	local CLASS_LABEL = {
		["custom-domestic"] = translate("自定义 · 国内"),
		["custom-foreign"]  = translate("自定义 · 国外"),
		["db-foreign"]      = translate("数据库命中（gfw 名单）"),
		["uncovered"]       = translate("未覆盖（名单里没有）"),
		["invalid"]         = translate("格式非法"),
	}

	local CHAIN_LABEL = {
		domestic = translate("直连链路"),
		foreign  = translate("代理链路"),
	}

	local PROBE_TONE = {
		OK = "ok", EMPTY = "ok", NX = "info",
		TIMEOUT = "bad", FAIL = "bad",
	}

	local function probe_badge(v)
		if not v or v == "" then
			return '<span class="dc-badge dc-badge--mute">—</span>'
		end
		return string.format('<span class="dc-badge dc-badge--%s">%s</span>',
			PROBE_TONE[v] or "mute", esc(v))
	end

	local decision = e["DECISION"] or ""
	local DECISION_TONE = "ok"
	local DECISION_LABEL = decision

	if decision == "reroute-domestic" then
		DECISION_TONE = "warn"
		DECISION_LABEL = translate("改走直连")
	elseif decision == "reroute-foreign" then
		DECISION_TONE = "warn"
		DECISION_LABEL = translate("改走代理")
	elseif decision == "both-bad" then
		DECISION_TONE = "bad"
		DECISION_LABEL = translate("双链故障")
	elseif decision == "reject" then
		DECISION_TONE = "bad"
		DECISION_LABEL = translate("拒绝")
	elseif decision == "keep-domestic" then
		DECISION_LABEL = translate("保持直连")
	elseif decision == "keep-foreign" then
		DECISION_LABEL = translate("保持代理")
	end

	local function kv(k, v)
		return string.format(
			'<tr><td class="dc-kv__k">%s</td><td class="dc-kv__v">%s</td></tr>', k, v)
	end

	local rows = {
		kv(translate("域名"), '<code>' .. esc(e["DOMAIN"] or "") .. '</code>'),
		kv(translate("归属"),
			'<span class="dc-badge dc-badge--info">' ..
			esc(CLASS_LABEL[e["CLASS"]] or e["CLASS"] or "—") .. '</span>'),
		kv(translate("首选链路"),
			'<span class="dc-badge dc-badge--mute">' ..
			esc(CHAIN_LABEL[e["PREFERRED"]] or e["PREFERRED"] or "—") .. '</span>'),
		kv(translate("当前链路"),
			'<span class="dc-badge dc-badge--mute">' ..
			esc(CHAIN_LABEL[e["ACTIVE"]] or e["ACTIVE"] or "—") .. '</span>'),
		kv(translate("探测 · 直连"), probe_badge(e["PROBE_DOMESTIC"])),
		kv(translate("探测 · 代理"), probe_badge(e["PROBE_FOREIGN"])),
		kv(translate("答案 · 直连"),
			'<code>' .. esc(e["ANSWER_DOMESTIC"] ~= "" and e["ANSWER_DOMESTIC"] or "—") .. '</code>'),
		kv(translate("答案 · 代理"),
			'<code>' .. esc(e["ANSWER_FOREIGN"] ~= "" and e["ANSWER_FOREIGN"] or "—") .. '</code>'),
		kv(translate("归属来源"),
			e["CUSTOM"] == "1"
				and ('<span class="dc-badge dc-badge--info">' .. translate("自定义补全") .. '</span>')
				or ('<span class="dc-badge dc-badge--mute">' .. translate("数据库 / 未覆盖") .. '</span>')),
		kv(translate("判定"),
			string.format('<span class="dc-badge dc-badge--%s">%s</span>',
				DECISION_TONE, esc(DECISION_LABEL))),
		kv(translate("理由"), esc(e["REASON"] or "—")),
	}

	return input ..
		'<div class="dc-table-wrap"><table class="dc-table dc-kv">' ..
		'<tbody>' .. table.concat(rows) .. '</tbody></table></div>'
end

-- ── 改道状态（状态思维导图）────────────────────────────────────────
s = m:section(TypedSection, "dnschain", translate("改道状态"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_status_map", translate("状态导图"))
o.rawhtml = true
function o.cfgvalue()
	local rows = ds.health_rows()
	local sum = ds.health_summary()
	return dg.status_map(rows, sum)
end

-- 通道就绪性：改道写进 servers-file 后必须真的被 dnsmasq 读到
--
-- 只配 UCI 不生效的情况是存在的（dnsmasq 未重启、ujail 白名单不含
-- 该目录、进程被别处启动）。这一行是「改道看起来成功、实际没生效」
-- 的唯一可靠判据。
o = s:option(DummyValue, "_reroute_channel", translate("改道通道"))
o.rawhtml = true
function o.cfgvalue()
	local st = ds.serversfile_ready()

	local REASON = {
		["uci-missing"]  = translate("dhcp.@dnsmasq[0].serversfile 未设置 —— 改道无法生效"),
		["file-missing"] = translate("serversfile 指向的文件不存在 —— 框架可能未启动"),
		["no-dnsmasq"]   = translate("dnsmasq 未运行"),
		["conf-missing"] = translate("生效的 dnsmasq 配置里没有 servers-file —— 需重启 dnsmasq"),
		["jail-blocked"] = translate("servers-file 所在目录不在 ujail 白名单内 —— dnsmasq 读不到，改道会静默失效"),
	}

	if st.ready then
		return string.format(
			'<span class="dc-badge dc-badge--ok">%s</span> <code>%s</code>',
			translate("已就绪"), dg.esc(st.path))
	end

	local reason = REASON[st.reason] or st.reason
	return string.format(
		'<span class="dc-badge dc-badge--bad">%s</span> %s',
		translate("未就绪"), dg.esc(reason))
end

-- 自动改道的守护进程状态
--
-- 为什么必须有这一行（v0.13.0 补齐）：
--   守护进程由 procd 托管（init.d/dnschain 的 `procd_open_instance "health"`），
--   页面原来完全没有它的痕迹。于是出现一个无法自查的状态：
--   开关显示「已启用」、阈值也都配好了，但守护进程没起来 ——
--   **自动改道完全不发生，且没有任何提示**。
--   用户只能靠「等很久发现域名没被改道」来推断，无从定位。
o = s:option(DummyValue, "_health_daemon", translate("自动改道进程"))
o.rawhtml = true
function o.cfgvalue()
	local hd = ds.health_daemon()

	-- 三种状态分开表达，不要合并成「正常/异常」两档：
	--   · 开关关闭        → 灰（不探测是用户的选择，不是故障）
	--   · 开关开 + 在跑   → 绿
	--   · 开关开 + 没跑   → 红（这才是故障：用户以为在自动改道）
	if not hd.enabled then
		return string.format(
			'<span class="dc-badge">%s</span> %s',
			translate("已关闭"),
			translate("健康检测关闭，不探测也不改道；静态分流照常工作"))
	end

	if not hd.running then
		return string.format(
			'<span class="dc-badge dc-badge--bad">%s</span> %s',
			translate("未运行"),
			translate("开关已启用但守护进程没起来 —— 自动改道不会发生。" ..
				"请执行 <code>/etc/init.d/dnschain restart</code>，并确认日志无报错"))
	end

	local parts = {}
	parts[#parts + 1] = string.format(
		'<span class="dc-badge dc-badge--ok">%s</span>', translate("运行中"))
	parts[#parts + 1] = string.format(
		'<span class="dc-small">pid %s · %s</span>',
		dg.esc(hd.pid),
		(hd.interval > 0)
			and string.format(translate("每 %d 秒一轮"), hd.interval)
			or translate("不自动轮询（仅手动触发）"))

	if hd.age >= 0 then
		parts[#parts + 1] = string.format(
			'<span class="dc-small">%s %s</span>',
			translate("上次探测"),
			string.format(translate("%d 秒前"), hd.age))
	else
		parts[#parts + 1] = string.format(
			'<span class="dc-small">%s</span>', translate("尚未探测过"))
	end

	return table.concat(parts, " ")
end

-- ── 改道明细表 ────────────────────────────────────────────────────
s = m:section(TypedSection, "dnschain", translate("改道明细"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_status_table", translate("明细"))
o.rawhtml = true
function o.cfgvalue()
	local rows = ds.health_rows()

	if #rows == 0 then
		return '<div class="dc-alert dc-alert--info">' ..
			'<span class="dc-alert__icon">i</span><div>' ..
			translate("还没有探测数据。点下方「立即探测一轮」，或等待一个轮询间隔。") ..
			'</div></div>'
	end

	local CHAIN = { domestic = translate("直连"), foreign = translate("代理") }
	local STATE_TONE = {
		["ok"] = "ok", ["degraded"] = "warn", ["rerouted"] = "warn",
		["both-bad"] = "bad", ["unknown"] = "mute",
	}
	local STATE_LABEL = {
		["ok"] = translate("正常"), ["degraded"] = translate("降级中"),
		["rerouted"] = translate("已改道"), ["both-bad"] = translate("双链故障"),
		["unknown"] = translate("未探测"),
	}

	local trs = {}
	for _, r in ipairs(rows) do
		local moved = (r.active ~= r.pref)
		local chain_cell
		if moved then
			chain_cell = string.format(
				'%s <span class="dc-arrow">→</span> <b>%s</b>',
				CHAIN[r.pref] or r.pref, CHAIN[r.active] or r.active)
		else
			chain_cell = CHAIN[r.active] or r.active or "—"
		end

		trs[#trs + 1] = string.format(
			'<tr><td><code>%s</code></td>' ..
			'<td>%s</td><td>%s</td>' ..
			'<td class="dc-table__num">%d</td>' ..
			'<td>%s</td>' ..
			'<td><span class="dc-badge dc-badge--%s">%s</span></td>' ..
			'<td><code class="dc-small">%s</code></td></tr>',
			dg.esc(r.domain),
			ds_class_label(r["class"]),
			chain_cell,
			r.fail or 0,
			-- last=0 表示「从未探测」，不能渲染成 08:00:00（v0.14.4 修 L3）
			((r.last or 0) > 0 and os.date("%H:%M:%S", r.last) or "—"),
			STATE_TONE[r.state] or "mute",
			dg.esc(STATE_LABEL[r.state] or r.state or "—"),
			dg.esc(r.result or "—"))
	end

	return '<div class="dc-table-wrap"><table class="dc-table"><thead><tr>' ..
		'<th>' .. translate("域名") .. '</th>' ..
		'<th>' .. translate("归属") .. '</th>' ..
		'<th>' .. translate("链路") .. '</th>' ..
		'<th class="dc-table__num">' .. translate("连败") .. '</th>' ..
		'<th>' .. translate("最近探测") .. '</th>' ..
		'<th>' .. translate("状态") .. '</th>' ..
		'<th>' .. translate("原因") .. '</th>' ..
		'</tr></thead><tbody>' .. table.concat(trs) .. '</tbody></table></div>'
end

-- ── 观测与阈值 ────────────────────────────────────────────────────
-- ── 分诊结果（v0.16.0 新增）────────────────────────────────────────
--
-- 用户要求「所有功能都要能对得上视觉上看到的 web ui」。
-- 分诊是本次新增的核心能力，但在此之前**页面上完全看不到它的结果** ——
-- 用户只能通过命令行 `dnschain-triage list` 查，这与「视觉为准」冲突。
--
-- 这里把分诊结论摆出来，三档语义与落库动作一一对应：
--
--   direct  试直连通   → IP 已写入 china 集合、域名已写入 dom_domestic
--   proxy   直连不通，代理通 → IP 已写入 blacklist、域名已写入 dom_foreign
--   dead    都不通     → 两个集合都不写，等下一轮重试
--
-- ⚠️ 与「改道明细」的区别（不是重复功能）：
--   改道明细  看的是**观测列表**里 8 个种子域名的链路健康与自动改道
--   分诊结果  看的是**客户机实际访问过、但不在任何库里**的未知目标
--   两者输入集合不同、落库目标不同、判定方法不同（DNS 探测 vs HTTP 实测）
s = m:section(TypedSection, "dnschain", translate("分诊结果"),
	translate("不在 GFW 名单、不在代理 IP 集、不在国内 IP 段、也不在任何数据库的" ..
		"目标，会按「先试直连 → 直连不通试代理 → 都不通标 dead」判定。" ..
		"跑通的落库：IP 进对应集合（nft 自动合并成 IP 段），域名进对应列表。"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_triage_table", translate("结论"))
o.rawhtml = true
function o.cfgvalue()
	local t = ds.triage_rows()
	local rows = t.rows or {}
	local sum = t.summary or {}

	if #rows == 0 then
		return '<div class="dc-alert dc-alert--info">' ..
			'<span class="dc-alert__icon">i</span><div>' ..
			translate("还没有分诊记录。点「概览与诊断 → 操作 → 立即分诊未知目标」，" ..
				"或等待守护进程自动跑一轮。") ..
			'</div></div>'
	end

	local TONE = { direct = "ok", proxy = "warn", dead = "bad" }
	local TEXT = {
		direct = translate("直连通"),
		proxy  = translate("代理通"),
		dead   = translate("两种链路都不通"),
	}
	local KIND = { ip = translate("IP"), domain = translate("域名") }

	local p = {}
	-- data-dc-triage：标记这是分诊结果表。
	--
	-- dnschain.js 的 countBadges() 会跳过它内部的 .dc-badge--bad ——
	-- 因为「两种链路都不通」是客观观测结果，不是本页配置异常。
	-- 不跳过的话 tab 徽标会把 dead 条数当故障数（实测显示「10」，
	-- 让人以为有 10 处配置错误）。
	p[#p + 1] = '<div class="dc-table-wrap" data-dc-triage="1"><table class="dc-table"><thead><tr>' ..
		'<th>' .. translate("目标") .. '</th>' ..
		'<th>' .. translate("类型") .. '</th>' ..
		'<th>' .. translate("结论") .. '</th>' ..
		'<th>' .. translate("落库动作") .. '</th>' ..
		'</tr></thead><tbody>'

	for _, r in ipairs(rows) do
		local tone = TONE[r.verdict] or "mute"
		local action
		if r.verdict == "direct" then
			action = (r.kind == "ip")
				and translate("已加入 china 集合（直连）")
				or translate("已写入 dom_domestic（国内）")
		elseif r.verdict == "proxy" then
			action = (r.kind == "ip")
				and translate("已加入 blacklist 集合（代理）")
				or translate("已写入 dom_foreign（国外）")
		else
			action = translate("不写入任何集合，下一轮重试")
		end

		p[#p + 1] = string.format(
			'<tr><td><code>%s</code></td><td>%s</td>' ..
			'<td><span class="dc-badge dc-badge--%s">%s</span></td>' ..
			'<td>%s</td></tr>',
			r.target, KIND[r.kind] or r.kind, tone,
			TEXT[r.verdict] or r.verdict, action)
	end

	p[#p + 1] = '</tbody></table></div>'
	p[#p + 1] = string.format(
		'<div class="dc-hint">%s %d / %s %d / %s %d / %s %d</div>',
		translate("直连通"), sum.direct or 0,
		translate("代理通"), sum.proxy or 0,
		translate("都不通"), sum.dead or 0,
		translate("合计"), sum.total or 0)

	return table.concat(p)
end

s = m:section(TypedSection, "health", translate("观测与阈值"),
	translate("只探测<b>观测列表</b>里的域名，不做全量探测 —— " ..
		"3.5 万个域名一轮要几小时，也会把 dnsmasq 与 dnsproxy 打满。"))
s.anonymous = true
s.addremove = false
o = s:option(Flag, "enabled", translate("启用健康检测与自动改道"),
	translate("关闭后不探测、不改道，静态分流照常工作。"))
o.rmempty = false
o.default = "1"

o = s:option(DynamicList, "watch", translate("观测域名"),
	translate("清空后会自动回落到内置基准集（国内外各 4 个）。"))
o.datatype = "string"
o.rmempty = true
o:depends("enabled", "1")

o = s:option(Value, "timeout", translate("单次探测超时（秒）"),
	translate("BusyBox 的 <code>nslookup</code> 没有 <code>-timeout</code> 参数，" ..
		"框架自己实现硬超时，所以这个值就是真实上界。"))
o.datatype = "range(1, 10)"
o.default = "2"
o:depends("enabled", "1")

o = s:option(Value, "retries", translate("重试次数"),
	translate("每次探测失败后的重试次数（不含首次）。" ..
		"单次 UDP 丢包很常见，不重试会让改道变成随机行为。"))
o.datatype = "range(0, 5)"
o.default = "2"
o:depends("enabled", "1")

o = s:option(Value, "fail_threshold", translate("改道阈值（连败轮数）"),
	translate("连续失败多少轮才判定「不通」。取 1 会让单轮抖动直接触发改道。"))
o.datatype = "range(1, 10)"
o.default = "2"
o:depends("enabled", "1")

o = s:option(Value, "recover_threshold", translate("回切阈值（连续成功轮数）"),
	translate("首选链连续成功多少轮才回切。配合「最小驻留」避免临界状态反复横跳。"))
o.datatype = "range(1, 20)"
o.default = "3"
o:depends("enabled", "1")

o = s:option(Value, "min_dwell", translate("最小驻留（秒）"),
	translate("改道后至少停留多久才允许回切。"))
o.datatype = "range(0, 3600)"
o.default = "120"
o:depends("enabled", "1")

o = s:option(Value, "interval", translate("轮询间隔（秒）"),
	translate("0 = 不自动轮询，只能从下方按钮手动触发。小于 15 秒会被抬到 15 秒" ..
		"（一轮探测本身就要 3~10 秒，更短只会让两轮重叠）。"))
o.datatype = "range(0, 3600)"
o.default = "60"
o:depends("enabled", "1")

-- ── 域名操作 ──────────────────────────────────────────────────────
--
-- ⚠️ 按钮命名必须与页面底部 CBI 自动生成的「保存 / 保存并应用」区分开。
--
--   CBI 会在页面底部自动生成两个按钮（来自 Map 模板，无法移除）：
--     · 保存        → 只写 UCI
--     · 保存并应用  → 写 UCI + 调本 Map 的 apply_on_parse
--   而本 section 的这个按钮做的是**另一件事**：重建分流片段 + 重启 dnsmasq。
--
--   v0.14.0 之前它也叫「保存并应用」，于是页面上出现两个同名按钮
--   （实测 duplicates: [["保存并应用", 2]]），用户无法判断该点哪个。
--   现在改名为「重建分流规则并生效」，语义唯一。
s = m:section(TypedSection, "dnschain", translate("域名操作"))
s.anonymous = true
s.addremove = false

o = s:option(Button, "_apply_domains", translate("重建分流规则并生效"),
	translate("把当前配置重建为分流片段与动态上游文件，并重启 dnsmasq 让静态规则生效。" ..
		"<br/><b>会有约 3 秒解析中断</b> —— 静态片段通过 conf-dir 加载，" ..
		"实测 reload（SIGHUP）不会重读它，只能 restart。" ..
		"<br/>与底部「保存」的区别：保存只写配置，本按钮才让改动真正生效。"))
o.inputstyle = "apply"
function o.write(self, section)
	-- 不再无条件拼 ✓（v0.14.4 修 S6）：按实际出口决定符号与文案
	local ok, out = pcall(ds.apply_domains)
	ds.invalidate()
	setmsg(apply_message(ok, out) .. "\n" .. tostring(out or ""))
end

o = s:option(Button, "_cycle_now", translate("立即探测一轮"),
	translate("跑一轮健康检测并按阈值判定是否改道。" ..
		"<b>不会重启 dnsmasq</b>：改道只改 servers-file 并 SIGHUP。"))
o.inputstyle = "apply"
function o.write(self, section)
	local out = ds.health_cycle()
	ds.invalidate()
	setmsg("✓ " .. translate("探测完成") .. "\n" .. (out or ""))
end

o = s:option(Button, "_reset_health", translate("清空改道状态"),
	translate("把所有「已改道」撤回，回到「按归属走」。用于排障时确认某条链是否真的坏了。"))
o.inputstyle = "reset"
function o.write(self, section)
	local out = ds.reset_health()
	ds.invalidate()
	setmsg("✓ " .. translate("已清空") .. "\n" .. (out or ""))
end

-- ⚠️ 「校验自定义列表」按钮已移除（v0.14.0 去重）。
--
--   理由：格式校验已经在**保存时**做了两道 ——
--     · 页面 validate_domain()（输入框失焦即报错，手误立刻可见）
--     · dc_domain_valid()（兜住 uci set / 备份恢复等绕过页面的路径）
--   再放一个「事后校验」按钮，用户点它得到的结论与保存时的校验
--   完全一致，属于重复入口。
--
--   真正需要「事后体检」的场景（配置被外部改坏、域名同时出现在两边）
--   已由「诊断」tab 的「立即重新自检」覆盖 —— 那里是完整的 20 项检查，
--   比单看域名列表更全面。保留两个入口只会让人不知道该点哪个。
--
--   注意：ds.check_domains() 仍保留在模型层，自检会调用它。

------------------------------------------------------------------------
-- Tab「解析」：上游 + 双栈 + 端口 + 缓存
------------------------------------------------------------------------

-- 上游校验（国内/国外共用）
--
-- ⚠️ 收集值时必须防 table：uci 的 list 在 Lua 里是 table，
-- DynamicList 提交的 value 也可能是 table。旧实现直接拼进 urls
-- 会导致 dnschain.lua 的 url:match 崩溃 → 保存整体 500。
local function collect_strings(v, out)
	if type(v) == "string" then
		if v ~= "" then out[#out + 1] = v end
	elseif type(v) == "table" then
		for _, x in ipairs(v) do collect_strings(x, out) end
	end
end

local function validate_upstream(self, value, section)
	local urls = {}
	local uci = require "luci.model.uci".cursor()
	-- ⚠️ 只校验**本次输入**，不再合并该 section 的历史值（v0.14.4 修 M3）。
	--
	--   原实现把「该 section 已有的全部 server」和「当前这一行的新值」
	--   合并后整体判定，任一条不合规就整体返回 nil。于是某个上游被判
	--   端口越界后，该 section 里**每一行**的编辑都会被拒 —— 包括用户
	--   正想用来替换坏行的那一行，形成死锁，只能绕过页面改 UCI。
	--
	--   历史值由「一键归一」与自检负责提示。
	collect_strings(value, urls)

	local ok, bad = ds.validate_upstreams(urls)
	if not ok then
		return nil, translate("以下上游端口不在代理端口集内，路由器自身出向不会被代理：") ..
			" " .. table.concat(bad, "；")
	end
	return value
end

-- ── 国内上游 ──
s = m:section(NamedSection, "cn", "upstream", translate("国内上游"),
	translate("用于<b>不在</b> gfw 名单里的域名。直连出站，可混用 DoT 与 DoH，" ..
		"dnsproxy 会并行查询取最快。"))
s.addremove = false

o = s:option(DynamicList, "server", translate("上游服务器"))
o.datatype = "or(hostname, ipaddr)"
o.rmempty = false
o.validate = validate_upstream
o.placeholder = "tls://223.5.5.5"

-- ── 国外上游 ──
s = m:section(NamedSection, "foreign", "upstream", translate("国外上游"),
	translate("用于 gfw 名单里的域名。<b>必须用 DoH（https://，走 443）</b>，" ..
		"不能用 DoT（tls://，走 853）—— 实测落地节点到 853 全部 " ..
		"<code>peer sent close notify</code>，到 443 正常。"))
s.addremove = false

o = s:option(DynamicList, "server", translate("上游服务器"))
o.datatype = "or(hostname, ipaddr)"
o.rmempty = false
o.validate = validate_upstream
o.placeholder = "https://dns.google/dns-query"

o = s:option(Flag, "cert_verify", translate("校验上游证书"),
	translate("dnsproxy 的 DoH 上游走标准 TLS（带 SNI），可以正常校验证书。" ..
		"关闭后跳过校验，仅用于上游证书异常时的排障。" ..
		"<br/><b>注意：此项目前仅作记录，未接入 dnsproxy 的启动参数</b>" ..
		"（框架始终使用 dnsproxy 的默认校验行为）。"))
o.rmempty = true
o.default = "1"

o = s:option(Flag, "via_proxy", translate("经代理出站"),
	translate("国外上游的连接走 SSR-Plus 的 OUTPUT 链。" ..
		"要求 router_proxy=1 且 dports 含 443。" ..
		"<br/><b>不要关</b>：国外 DoH 直连会被墙，国外域名将全部无结果。" ..
		"<br/><b>注意：此项目前仅作记录，实际出站由 SSR-Plus 的" ..
		" <code>router_proxy</code> 与 dports 决定</b>（框架不改这两项）。"))
o.rmempty = true
o.default = "1"

-- ── 双栈策略 ──
--
-- 关键联动：ipv6_support=1 时 SSR-Plus 的 get_filter_aaaa() 直接返回 0，
-- 并调 set_ipv6_dns_filter 把 dnsmasq.filter_aaaa 设为 0 —— 无论偏好填什么。
-- 页面必须如实显示「当前是否被覆盖」，不能假装滑块有效。
s = m:section(TypedSection, "aaaa", translate("双栈策略"),
	translate("国外节点通常只有 IPv4。<b>启用 IPv6 流量代理</b>时，国外 IPv6 " ..
		"也会走代理，可以保留真实 AAAA；<b>不启用</b>时，国外 IPv6 是直连，" ..
		"拿到 AAAA 会被 RST，必须抑制。"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "domestic", translate("国内 AAAA"))
function o.cfgvalue()
	return translate("始终保留（国内双栈不受影响）")
end

o = s:option(DummyValue, "foreign", translate("国外 AAAA"))
o.rawhtml = true
function o.cfgvalue()
	local pref = ds.ssr_filter_aaaa()
	local eff = ds.dnsmasq_filter_aaaa()
	local v6 = ds.ssr_ipv6()
	local overridden = (v6 == "1" and pref ~= "0")

	local badge
	if eff == "0" then
		badge = '<span class="dc-badge dc-badge--ok">' .. translate("保留") .. '</span>'
	else
		badge = '<span class="dc-badge dc-badge--warn">' .. translate("抑制") .. '</span>'
	end

	if overridden then
		return badge .. ' <span style="font-size:11px;color:var(--dc-warn)">' ..
			translate("偏好值是「抑制」，但 ipv6_support=1 已强制覆盖为「保留」") ..
			'</span>'
	end
	return badge
end

-- 开关：写 shadowsocksr.@global[0].filter_aaaa
--
-- 为什么用 ListValue 而不是 Flag：
-- Flag 的 write() 拿到的 value 是 "1" 或空串，且它绑定在 aaaa.policy 这个
-- section 上；而我们要写的是**另一个包**（shadowsocksr）的键。
-- 实测用 Flag 时页面渲染成纯文本 + 说明，没有开关控件。
o = s:option(ListValue, "_filter_aaaa", translate("抑制国外 AAAA"),
	translate("写 <code>shadowsocksr.@global[0].filter_aaaa</code>。" ..
		"<br/><b>启用 IPv6 流量代理时此项无效</b> —— SSR-Plus 会强制覆盖为「保留」。" ..
		"<br/>只有<b>关闭</b> IPv6 流量代理时，此项才真正决定行为。"))
o:value("0", translate("关闭 —— 保留 AAAA（推荐）"))
o:value("1", translate("开启 —— 抑制国外 AAAA"))
o.rmempty = false
function o.cfgvalue()
	return ds.ssr_filter_aaaa() == "1" and "1" or "0"
end
function o.write(self, section, value)
	local v = (value == "1") and "1" or "0"
	-- 不能用 luci.sys.call("...%s...", v)：它不支持 %s 插值，
	-- 会把字面 "%s" 写进 UCI。
	luci.sys.call("uci -q set shadowsocksr.@global[0].filter_aaaa='" .. v ..
		"' && uci -q commit shadowsocksr")
	-- 检查结果并把错误码翻成中文（v0.14.4 修 M8）
	local ok, info = ds.sync_dnsmasq_filter_aaaa()
	if not ok and type(info) == "table" then
		if info.code == "uci_write_failed" then
			setmsg("✗ " .. translate("写入 dnsmasq.filter_aaaa 失败：") ..
				tostring(info.detail or ""))
		elseif info.code == "verify_failed" then
			setmsg("✗ " .. translate("dnsmasq 重启后 filter_aaaa 仍为 ") ..
				tostring(info.actual) .. translate("（期望 ") ..
				tostring(info.target) .. "）")
		else
			setmsg("✗ " .. translate("同步 dnsmasq.filter_aaaa 失败"))
		end
	end
end

o = s:option(DummyValue, "_aaaa_why", translate("实际生效值"))
o.rawhtml = true
function o.cfgvalue()
	local pref = ds.ssr_filter_aaaa()
	local eff = ds.dnsmasq_filter_aaaa()
	local v6 = ds.ssr_ipv6()
	return string.format(
		translate("偏好 <code>filter_aaaa=%s</code> · 生效 <code>dnsmasq.filter_aaaa=%s</code> · " ..
			"<code>ipv6_support=%s</code>"),
		pref ~= "" and pref or "?", eff ~= "" and eff or "?", v6 ~= "" and v6 or "?")
end

o = s:option(Flag, "filter_https_rr", translate("抑制 HTTPS/SVCB 记录"),
	translate("qtype 64（SVCB）与 65（HTTPS）可携带 <code>ipv6hint</code>，" ..
		"客户端能绕过 AAAA 抑制拿到 IPv6 地址。" ..
		"<br/>v0.10.0 起<b>默认关闭</b>：IPv6 流量代理已把国外 IPv6 送进代理，" ..
		"不再需要防止 ipv6hint 泄漏。" .. "<br/><b>注意：此项目前仅作记录，没有运行时消费者</b>（改了不会生效）。"))
o.rmempty = false
o.default = "0"

-- ── 端口与实例 ──
s = m:section(TypedSection, "dnschain", translate("端口与实例"))
s.anonymous = true
s.addremove = false

o = s:option(Value, "entry_port", translate("国内实例端口"),
	translate("dnsproxy 实例 1 的监听端口，默认 5353。与国外端口<b>不能相同</b>。"))
o.datatype = "port"
o.placeholder = "5353"
o.rmempty = false
o.default = "5353"

o = s:option(Value, "foreign_port", translate("国外实例端口"),
	translate("dnsproxy 实例 2 的监听端口，默认 5336。框架会用 " ..
		"<code>server=/域名/127.0.0.1#本端口</code> 把 gfw 域名分流过来。"))
o.datatype = "port"
o.placeholder = "5336"
o.rmempty = false
o.default = "5336"

o = s:option(DummyValue, "_ports", translate("当前监听"))
o.rawhtml = true
function o.cfgvalue()
	local entry = ds.entry_port()
	local fport = ds.foreign_port()
	local function b(ok)
		return ok and '<span class="dc-badge dc-badge--ok">' .. translate("在监听") .. '</span>'
			or '<span class="dc-badge dc-badge--bad">' .. translate("未监听") .. '</span>'
	end
	return string.format("国内 :%s %s &nbsp; 国外 :%s %s",
		entry, b(ds.port_listening(entry, "udp")),
		fport, b(ds.port_listening(fport, "udp")))
end

-- ── 缓存 ──
s = m:section(TypedSection, "cache", translate("缓存"),
	translate("缓存只在 dnsmasq 一层。dnsproxy 不缓存 —— " ..
		"两处并存会让同一域名出现两份答案（实测：经 :53 与直连 :5353 返回不同 IP）。"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用缓存"),
	translate("缓存由 dnsmasq 承担，实际始终启用 —— 框架不读这个开关。" ..
		"<br/><b>注意：此项目前仅作记录，没有运行时消费者</b>（改了不会生效）。"))
o.rmempty = false
o.default = "1"

o = s:option(Value, "size", translate("条目数"),
	translate("dnsmasq 的 cache-size。当前实测 8192 条足够家用；" ..
		"过大会占内存，过小会让命中率下降。"))
o.datatype = "range(128, 65536)"
o.placeholder = "8192"
o.default = "8192"
o:depends("enabled", "1")

o = s:option(DummyValue, "_cache_stat", translate("当前统计"))
o.rawhtml = true
function o.cfgvalue()
	local c = ds.cache_stats()
	local function n(k) return c[k] and tostring(c[k]) or "—" end
	return string.format(
		'<span class="dc-badge dc-badge--info">' .. translate("插入 %s") .. '</span> ' ..
		'<span class="dc-badge dc-badge--ok">' .. translate("本地应答 %s") .. '</span> ' ..
		'<span class="dc-badge dc-badge--mute">' .. translate("转发 %s") .. '</span>',
		n("dns_cache_inserted"), n("dns_local_answered"), n("dns_queries_forwarded"))
end

------------------------------------------------------------------------
-- Tab「分流」：名单规模 + 导入 + 源文件 + nftset 归属
------------------------------------------------------------------------

s = m:section(TypedSection, "lists", translate("名单规模"),
	translate("框架从 SSR-Plus 的名单文件抽取域名，生成 " ..
		"<code>server=/域名/127.0.0.1#国外端口</code> 与对应的 nftset 规则。" ..
		"它<b>不修改</b> SSR-Plus 的源文件。"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_stats", translate("规模"))
o.rawhtml = true
function o.cfgvalue()
	local st = ds.list_stats()
	local function stat(label, value, hint)
		return string.format(
			'<div class="dc-stat">' ..
			'<div class="dc-stat__label">%s</div>' ..
			'<div class="dc-stat__value">%s</div>' ..
			'<div class="dc-stat__hint">%s</div></div>',
			label, value, hint)
	end
	return '<div class="dc-stats">' .. table.concat({
		stat(translate("GFW 名单"), st.gfw_lines, translate("行（含 ipset=）")),
		stat(translate("基础名单"), st.base_lines, translate("行")),
		stat(translate("已生成分流"), st.domains, translate("条 server=/域名/")),
		stat(translate("最近更新"), st.updated ~= "" and st.updated or "—",
			translate("GFW 源文件 mtime")),
	}) .. '</div>'
end

o = s:option(DummyValue, "_ipset_audit", translate("IP 集归属核对"))
o.rawhtml = true
function o.cfgvalue()
	local sn = ds.chain_snapshot()
	local audit = ds.ipset_audit()

	local function row(name, cur, expect, note)
		local ok = (cur ~= nil)
		local badge = ok and '<span class="dc-badge dc-badge--ok">' .. translate("在册") .. '</span>'
			or '<span class="dc-badge dc-badge--bad">' .. translate("缺失") .. '</span>'
		return string.format(
			'<tr><td>%s</td><td class="dc-table__num">%s</td>' ..
			'<td class="dc-table__num">%s</td><td>%s</td><td>%s</td></tr>',
			name, cur and tostring(cur) or "—",
			expect and tostring(expect) or "—", badge, note or "")
	end

	local rows = {
		row(translate("代理 IP 集（blacklist）"), sn.blacklist, nil,
			translate("运行时动态累加，随解析的国外域名增长，不是固定值")),
		row(translate("国内 IP 段（china）"), sn.china, audit.china_src,
			translate("源 china_ssr.txt；nft 会把相邻段合并成区间，故区间数少于源行数")),
		row(translate("GFW 域名数"), audit.gfw_domains, audit.gfw_src,
			translate("源 gfw_list.conf 每域名占 2 行（server= + ipset=）")),
		row(translate("国内 IPv6 段"), audit.china6_src, audit.china6_src,
			translate("源 china6_ssr.txt，供 SSR-Plus 的 IPv6 分流使用")),
	}

	return '<div class="dc-table-wrap"><table class="dc-table"><thead><tr>' ..
		'<th>' .. translate("集合 / 数据库") .. '</th>' ..
		'<th class="dc-table__num">' .. translate("实测") .. '</th>' ..
		'<th class="dc-table__num">' .. translate("源行数") .. '</th>' ..
		'<th>' .. translate("状态") .. '</th>' ..
		'<th>' .. translate("说明") .. '</th>' ..
		'</tr></thead><tbody>' .. table.concat(rows) .. '</tbody></table></div>'
end

o = s:option(Flag, "auto_import", translate("自动导入"),
	translate("SSR-Plus 更新名单后，收敛器按间隔轮询源文件指纹并自动重新导入。"))
o.rmempty = false
o.default = "1"

o = s:option(Value, "import_interval", translate("轮询间隔（秒）"),
	translate("导入只在点「立即归一」时发生，没有定时调度。" ..
		"<br/><b>注意：此项目前仅作记录，没有运行时消费者</b>（改了不会生效）。"))
o.datatype = "range(10, 3600)"
o.default = "60"
o:depends("auto_import", "1")

o = s:option(Value, "restart_threshold", translate("重启阈值（%）"),
	translate("名单行数变化超过该百分比时才重启 dnsproxy（约 1 秒解析中断）。"))
o.datatype = "range(0, 100)"
o.default = "1"

o = s:option(Value, "gfw_source", translate("GFW 名单源"),
	translate("只读源文件。框架从这里抽取域名生成分流规则，<b>不修改</b>该文件。"))
o.datatype = "file"
o.placeholder = "/etc/ssrplus/gfw_list.conf"
o.rmempty = true

o = s:option(Value, "base_source", translate("基础名单源"),
	translate("SSR-Plus 的基础域名列表，与 GFW 名单一起导入。"))
o.datatype = "file"
o.placeholder = "/etc/ssrplus/gfw_base.conf"
o.rmempty = true

o = s:option(Value, "black_source", translate("强制代理名单源"),
	translate("SSR-Plus 的 <code>black.list</code>，命中即走代理。"))
o.datatype = "file"
o.placeholder = "/etc/ssrplus/black.list"
o.rmempty = true

------------------------------------------------------------------------
-- Tab「代理」：SSR-Plus 兼容 + IPv6 + 拦截开关
------------------------------------------------------------------------

s = m:section(TypedSection, "ssr", translate("SSR-Plus 兼容"),
	translate("框架与 SSR-Plus 的接口约定。收敛器在开机、SSR 配置变更、" ..
		"定时三处重放这些不变量。"))
s.anonymous = true
s.addremove = false

o = s:option(ListValue, "mode", translate("目标 DNS 模式"),
	translate("SSR-Plus 的 <code>pdnsd_enable</code>。框架要接管解析，" ..
		"必须让它<b>不启动自己的 DNS 后端</b>，否则会有两个解析器抢答。"))
o:value("0", translate("0 — 不启 DNS 后端（推荐）"))
o:value("7", translate("7 — 模块内置 DNS"))
o.rmempty = false
o.default = "0"

o = s:option(Flag, "enforce", translate("强制写回"),
	translate("关闭后只告警、不修改 SSR-Plus 的键。"))
o.rmempty = false
o.default = "1"

o = s:option(Flag, "require_ipv6", translate("要求启用 IPv6 流量代理"),
	translate("国外节点只有 IPv4。开启后收敛器会强制 <code>ipv6_support=1</code>，" ..
		"SSR-Plus 会装上 IPv6 代理链（<code>ss_spec6_*</code> + 策略路由），" ..
		"国外 IPv6 也走代理，从而可以保留国外 AAAA。" ..
		"<br/><b>不要关闭</b>：关闭后国外域名拿到真实 AAAA 却直连，会被 RST。"))
o.rmempty = false
o.default = "1"

o = s:option(DummyValue, "_ssr_state", translate("SSR-Plus 当前状态"))
o.rawhtml = true
function o.cfgvalue()
	local mode = ds.ssr_mode()
	local v6 = ds.ssr_ipv6()
	local gs = (luci.sys.exec("uci -q get shadowsocksr.@global[0].global_server 2>/dev/null") or ""):gsub("%s+", "")
	local rp = (luci.sys.exec("uci -q get shadowsocksr.@access_control[0].router_proxy 2>/dev/null") or ""):gsub("%s+", "")
	local es = (luci.sys.exec("uci -q get shadowsocksr.@global[0].enable_switch 2>/dev/null") or ""):gsub("%s+", "")

	local function b(ok, txt)
		return string.format('<span class="dc-badge dc-badge--%s">%s</span>',
			ok and "ok" or "warn", txt)
	end

	local parts = {
		"pdnsd_enable=" .. (mode ~= "" and mode or "?") ..
			" " .. b(mode == "0", mode == "0" and translate("已让位") or translate("会冲突")),
		"ipv6_support=" .. (v6 ~= "" and v6 or "?") ..
			" " .. b(v6 == "1", v6 == "1" and translate("已启用") or translate("未启用")),
		"router_proxy=" .. (rp ~= "" and rp or "?") ..
			" " .. b(rp == "1", rp == "1" and translate("出向走代理") or translate("直连")),
		"enable_switch=" .. (es ~= "" and es or "?") ..
			" " .. b(es == "0", es == "0" and translate("已关（推荐）") or translate("会周期性重启")),
	}
	if gs == "nil" then
		parts[#parts + 1] = '<span class="dc-badge dc-badge--bad">' ..
			translate("global_server=nil —— 客户机 DNS 会全部超时") .. '</span>'
	else
		parts[#parts + 1] = "global_server=" .. (gs ~= "" and gs or "?") ..
			" " .. b(gs ~= "" and gs ~= "nil", translate("正常"))
	end

	return table.concat(parts, '<br/>')
end

-- ── 拦截总开关 ──
s = m:section(TypedSection, "dnschain", translate("拦截与框架开关"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用 DNS 链路框架"),
	translate("关闭后框架不生成分流规则、不启动自己的 dnsproxy 实例。"))
o.rmempty = false
o.default = "1"

o = s:option(Flag, "intercept", translate("强制拦截客户机 DNS"),
	translate("开启：拦截静态 IP 客户机与 DHCP 客户机的 53，DHCP 下发路由器自身地址。" ..
		"关闭：只过滤不监听，客户机自行解析（DHCP 下发 DNS 生效）。"))
o.rmempty = false
o.default = "1"

o = s:option(Flag, "intercept_dot", translate("拒绝 LAN 出向 853（DoT/DoQ）"),
	translate("让自带 DoT 的客户端快速失败并回落明文 53，从而被本框架的策略覆盖。" ..
		"<br/>规则优先级 <code>-151</code>，先于 SSR-Plus 的 <code>mangle(-150)</code>。" ..
		"<br/><b>与「对客户机提供 DoH/DoT 服务端」互斥。</b>"))
o.rmempty = false
o.default = "1"

o = s:option(Flag, "intercept_doh", translate("尽力阻断公共 DoH"),
	translate("443 无法可靠区分 DoH 与普通 HTTPS，故此项只做<b>标注</b>，不实际拦截。" ..
		"默认关闭。"))
o.rmempty = false
o.default = "0"

------------------------------------------------------------------------
-- Tab「DHCP」：DHCP 下发 DNS
------------------------------------------------------------------------

s = m:section(TypedSection, "dhcp_dns", translate("DHCP 下发 DNS（明文）"),
	translate("仅在「强制拦截客户机 DNS」关闭时下发给 DHCP 客户机。" ..
		"拦截开启时，DHCP 一律下发路由器自身地址。最多 4 个。"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用自定义下发"))
o.rmempty = false
o.default = "1"

o = s:option(DynamicList, "server", translate("DNS 地址"))
o.datatype = "ip4addr"
o.rmempty = true

o = s:option(DummyValue, "_dhcp_state", translate("实际下发"))
o.rawhtml = true
function o.cfgvalue()
	local intercept = (luci.sys.exec("uci -q get dnschain.main.intercept 2>/dev/null") or ""):gsub("%s+", "")
	local lan = (luci.sys.exec("uci -q get network.lan.ipaddr 2>/dev/null") or ""):gsub("%s+", "")
	if intercept == "1" then
		return string.format('<span class="dc-badge dc-badge--info">%s</span>',
			translate("拦截已开启 → 下发路由器自身 ") .. (lan ~= "" and lan or "192.168.3.254"))
	end
	return string.format('<span class="dc-badge dc-badge--mute">%s</span>',
		translate("拦截已关闭 → 下发上方列表"))
end

------------------------------------------------------------------------
-- 概览与诊断（合并 tab，v0.15.0）
--
-- 原「诊断」是独立 tab，内容为：自检 20 项表格 + 两个配置项 + 5 个按钮。
-- 合并后归入 overview，与「当前状态」（结论 / 解析链路 / 实时诊断链路 /
-- 链路指标 / 组件状态）连成一条「先看结论 → 再看逐段证据 → 最后动手」
-- 的阅读顺序。
--
-- 重复项已在合并时消除：概览原有的「分流决策」图是「域名」tab 判定链路
-- 图的第二次渲染（同一函数 dg.route_map），已删除；改用本页独有的
-- 「实时诊断链路」图，它按链路阶段重新组织 selftest 的 20 项结果。
------------------------------------------------------------------------

s = m:section(TypedSection, "selftest", translate("自检"),
	translate("20 项检查覆盖链路可达性、分流正确性、上游加密、双栈策略、" ..
		"fw4 可加载性与明文旁路。失败自动回滚见下方开关。"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_selftest", translate("结果"))
o.rawhtml = true
function o.cfgvalue()
	local result = ds.selftest()
	local rows = {}

	for _, it in ipairs(result.items or {}) do
		local cls = (it.status == "PASS") and "dc-badge--ok"
			or (it.status == "SKIP") and "dc-badge--mute" or "dc-badge--bad"
		rows[#rows + 1] = string.format(
			'<tr><td class="dc-table__num">%d</td>' ..
			'<td><span class="dc-badge %s">%s</span></td>' ..
			'<td>%s</td><td>%s</td></tr>',
			-- name/detail 来自脚本 stdout，必须转义（v0.14.4 修 L2）：
			-- 证据串里可能出现 & 或 <（如 ss_spec&blacklist），
			-- 不转义会被当实体起始、或吞掉后续文本。
			it.no or 0, cls, it.status, dg.esc(it.name or ""), dg.esc(it.detail or ""))
	end

	local fail_n = (result.total or 0) - (result.pass or 0) - (result.skip or 0)
	local skip_n = result.skip or 0

	-- 徽标颜色按**数值**决定，不能固定用红色。
	-- 否则 FAIL 0 也会渲染成 dc-badge--bad，前端统计「异常数」时
	-- 会把它算成 1 项失败（实测：诊断 tab 显示红色 1，而实际 FAIL=0）。
	local function tone(n, bad_cls)
		if n > 0 then return bad_cls end
		return "dc-badge--mute"
	end

	local summary = string.format(
		'<span class="dc-badge dc-badge--ok">PASS %d</span> ' ..
		'<span class="dc-badge %s">FAIL %d</span> ' ..
		'<span class="dc-badge dc-badge--mute">SKIP %d</span>',
		result.pass or 0, tone(fail_n, "dc-badge--bad"), fail_n, skip_n)

	return '<div style="margin-bottom:10px">' .. summary ..
		(result.conclusion ~= "" and (' &nbsp; <span class="dc-badge dc-badge--info">' ..
			result.conclusion .. '</span>') or "") .. '</div>' ..
		'<div class="dc-table-wrap"><table class="dc-table"><thead><tr>' ..
		'<th class="dc-table__num">#</th><th>' .. translate("结果") .. '</th>' ..
		'<th>' .. translate("检查项") .. '</th><th>' .. translate("证据") .. '</th>' ..
		'</tr></thead><tbody>' .. table.concat(rows) .. '</tbody></table></div>'
end

o = s:option(Flag, "auto_rollback", translate("失败自动回滚"),
	translate("自检失败时自动回滚到上一次通过的配置快照。" ..
		"<br/><b>注意：此项目前仅作记录，回滚逻辑尚未实现</b>" ..
		"（失败时只记日志，不会自动回滚配置）。"))
o.rmempty = false
o.default = "1"

o = s:option(Value, "interval", translate("定时自检间隔（秒）"),
	translate("0 表示关闭定时自检。") ..
	translate("<br/><b>注意：仓库里没有定时调度</b>（无 cron、无 procd 实例），" ..
		"自检只在打开本页或点「一键自检」时运行。"))
o.datatype = "range(0, 86400)"
o.default = "300"

-- ── 操作 ──
--
-- 全部写操作后必须 ds.invalidate()：v0.11.1 加了请求级缓存，
-- selftest / chain_snapshot / list_stats 在同一请求内只跑一次。
-- 按钮执行完若不清缓存，页面显示的还是旧结果 —— 用户会以为「点了没反应」。
s = m:section(TypedSection, "dnschain", translate("操作"))
s.anonymous = true
s.addremove = false

o = s:option(Button, "_selftest_now", translate("立即重新自检"),
	translate("重新执行全部自检项。页面默认复用首次结果以加快加载，" ..
		"点此可强制刷新。"))
o.inputstyle = "apply"
function o.write(self, section)
	ds.invalidate("selftest")
	local r = ds.selftest()
	setmsg(translate("已重新自检") .. "：" ..
		string.format("PASS=%d", r.pass or 0) ..
		(r.conclusion ~= "" and (" — " .. r.conclusion) or ""))
end

o = s:option(Button, "_reconcile", translate("一键归一"),
	translate("立即重放不变量集：把 SSR-Plus / dnsmasq / dnsproxy 的相关键" ..
		"归一到框架期望值。"))
o.inputstyle = "apply"
function o.write(self, section)
	local ok, out = ds.reconcile_now()
	ds.invalidate()
	setmsg("✓ " .. translate("已归一") .. "\n" .. (out or ""))
end

o = s:option(Button, "_triage", translate("立即分诊未知目标"),
	translate("对「不在 GFW 名单、不在代理 IP 集、不在国内 IP 段、" ..
		"也不在任何数据库」的目标执行：先试直连，直连不通再试代理，" ..
		"都不通则标记为死。跑通的会落库（IP 进集合、域名进对应列表），" ..
		"下次开机与每轮收敛自动重放。"))
o.inputstyle = "apply"
function o.write(self, section)
	local ok, out = ds.triage_now()
	ds.invalidate()
	setmsg((ok and "✓ " or "✗ ") .. translate("已分诊") .. "\n" .. (out or ""))
end

o = s:option(Button, "_import", translate("手动导入名单"),
	translate("立即从 SSR-Plus 的名单文件重新生成框架的分流规则。"))
o.inputstyle = "apply"
function o.write(self, section)
	local ok, out = ds.import_lists()
	ds.invalidate()
	setmsg("✓ " .. translate("已导入") .. "\n" .. (out or ""))
end

o = s:option(Button, "_update_gfw", translate("更新 GFW 名单"),
	translate("调用 SSR-Plus 的 update.lua 下载最新名单，完成后由收敛器自动导入。"))
o.inputstyle = "apply"
function o.write(self, section)
	local ok, msg = ds.update_gfw_list()
	ds.invalidate()
	setmsg((ok and "✓ " or "✗ ") .. msg)
end

o = s:option(Button, "_flush_cache", translate("清空全部缓存"),
	translate("发送 SIGHUP 清空 dnsmasq 缓存：进程不重启、客户机无感知。" ..
		"「清空指定域名」做不到 —— dnsmasq 与 dnsproxy 都没有按域名淘汰单条缓存的接口。"))
o.inputstyle = "reload"
function o.write(self, section)
	local ok, msg = ds.flush_cache()
	ds.invalidate()
	setmsg((ok and "✓ " or "✗ ") .. msg)
end


------------------------------------------------------------------------
-- Tab 元数据（必须在最后建，渲染时输出给前端归组用）
------------------------------------------------------------------------

emit_tab_meta(m)

------------------------------------------------------------------------
-- 底部「保存并应用」与「保存」的语义区分
--
-- CBI 的 Map 模板会在页面底部自动生成两个按钮：
--   保存        → 只写 UCI（cbi-map.htm 的 save 动作）
--   保存并应用  → 写 UCI 后调用本 Map 的 apply_on_parse（若已定义）
--
-- 本页原来**没有**定义 apply_on_parse，于是「保存并应用」实际等于
-- 「保存」—— 两个按钮做同一件事，用户点「保存并应用」后以为分流
-- 已经生效，但静态片段并没有重建，页面上「待应用」的徽标还在。
-- 这是 v0.14.0 全链路审查发现的真实缺陷。
--
-- 现在补上：apply_on_parse 调 ds.apply_domains()（重建分流片段 +
-- 必要时重启 dnsmasq），让「保存并应用」真的「应用」。
--
-- 注意 apply_domains 内部已经做了「静态片段未变则不动 dnsmasq」的
-- 判断（MD5 比对），所以只改阈值之类的无关字段时不会白白断 3 秒。
function m.apply_on_parse(...)
	-- 先让 CBI 完成默认的解析与写盘，再执行应用动作。
	-- 顺序不能反：apply_domains 读的是已落盘的 UCI 值。
	local rv
	if Map.apply_on_parse then
		rv = Map.apply_on_parse(...)
	end
	local ok, out = pcall(ds.apply_domains)
	ds.invalidate()
	m.message = apply_message(ok, out)
	return rv
end

-- 把 dnschain-health apply 的输出翻成一句给用户看的话。
--
-- ⚠️ 必须覆盖全部出口（v0.14.4 修 S6）。
--
--   `dnschain-health apply` 有 5 条正常出口 + 2 条失败出口：
--     正常：DNSMASQ=restarted / skipped（框架未启用）/
--           skipped（无 init.d/dnsmasq）/ sighup（仅观测域名变化）/
--           unchanged（无变化）
--     失败：ERROR=生成分流片段失败 / ERROR=生成自定义列表失败
--
--   原实现只处理 `restarted` 一条，其余 4 条**不设置任何 message** ——
--   最常见的场景（只改了阈值、片段未变 → unchanged）用户点「保存并应用」
--   后看不到任何提示，会反复点。反过来按钮路径无条件拼 `✓`，
--   ERROR 时显示「✓ 已应用」+ 错误正文，符号与结论矛盾。
local APPLY_TEXT = {
	["restarted"] = translate("已应用（dnsmasq 已重启，静态片段生效）"),
	["sighup"]    = translate("已应用（仅观测域名变化，SIGHUP 已生效，无中断）"),
	["unchanged"] = translate("配置已保存（分流片段无变化，未重启 dnsmasq）"),
	["skipped"]   = translate("已保存，但未应用（详见下方说明）"),
}

function apply_message(ok, out)
	if not ok then
		return "✗ " .. translate("应用失败：") .. tostring(out)
	end
	out = out or ""

	-- 失败出口优先：输出里出现 ERROR= 就是失败，不管 DNSMASQ= 是什么
	local err = out:match("ERROR=([^\n]+)")
	if err then
		return "✗ " .. translate("应用失败：") .. err
	end

	-- ⚠️ 不能写 `DNSMASQ=(%S+)`：全角括号不是空白字符，`%S+` 会把
	--    「skipped（框架未启用）」整段吃掉，导致 state 永远匹配不上
	--    APPLY_TEXT 的键（实测 skipped 分支返回「✓ 已应用」而不是「!」）。
	--    这里只取 ASCII 状态词。
	local state = out:match("DNSMASQ=([%a%-]+)")
	if not state then
		-- 没有 DNSMASQ= 也没 ERROR=：脚本输出异常，如实回报
		return "✗ " .. translate("应用结果不明（脚本无输出）")
	end

	local base = APPLY_TEXT[state] or translate("已应用")
	-- skipped 的括号原因要带上，用户才知道为什么没应用
	if state == "skipped" then
		local why = out:match("DNSMASQ=skipped（([^）]+)）")
		if why then
			return "! " .. base .. "：" .. why
		end
	end
	return "✓ " .. base
end

return m
