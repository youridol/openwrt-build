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
	overview = translate("概览"),
	resolve  = translate("解析"),
	split    = translate("分流"),
	proxy    = translate("代理"),
	dhcp     = translate("DHCP"),
	diag     = translate("诊断"),
}

-- section 标题 → tab
local SECTION_TAB = {
	[translate("当前状态")]      = "overview",

	[translate("国内上游")]      = "resolve",
	[translate("国外上游")]      = "resolve",
	[translate("双栈策略")]      = "resolve",
	[translate("端口与实例")]    = "resolve",
	[translate("缓存")]          = "resolve",

	[translate("名单规模")]      = "split",

	[translate("SSR-Plus 兼容")] = "proxy",
	[translate("拦截与框架开关")] = "proxy",

	[translate("DHCP 下发 DNS（明文）")] = "dhcp",

	[translate("自检")]          = "diag",
	[translate("操作")]          = "diag",
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
		return string.format(
			'<link rel="stylesheet" href="%s/dnschain/dnschain.css">' ..
			'<script defer src="%s/dnschain/dnschain.js"></script>' ..
			'<span data-dc-meta="1"%s%s></span>',
			base, base,
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

	if concl == "" then
		local entry = ds.entry_port()
		local fport = ds.foreign_port()
		local fowner = ds.port_owner(fport, "udp")
		if not ds.port_listening(entry, "udp") then
			concl = translate("国内 dnsproxy 未监听 —— 客户机全部无法解析")
		elseif fowner == "" then
			concl = translate("国外 dnsproxy 未监听 —— gfw 域名将 SERVFAIL，国内不受影响")
		elseif not ds.is_dnsproxy(fowner) then
			concl = translate("国外端口被其他进程占用 —— gfw 域名会走错解析器")
		elseif not ds.port_listening("1234", "tcp") then
			concl = translate("代理未运行 —— 国外域名将失败（国内不受影响）")
		elseif ds.ssr_ipv6() ~= "1" then
			concl = translate("IPv6 流量代理未开 —— 国外 IPv6 会直连被 RST")
		else
			concl = translate("链路正常")
		end
	end

	-- 结论用徽标表达状态，不再靠颜色语义猜测
	local cls = "dc-badge--ok"
	local low = concl:lower()
	if concl:find("未监听") or concl:find("失败") or concl:find("占用") then
		cls = "dc-badge--bad"
	elseif concl:find("未开") or concl:find("SERVFAIL") then
		cls = "dc-badge--warn"
	end

	return string.format('<span class="dc-badge %s">%s</span>', cls, concl)
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

	-- ── 画布与节点几何 ────────────────────────────────────────────
	--
	-- 坐标系是固定的 viewBox（SVG 会自动缩放适应容器），所以这里的
	-- 数字只需保证「所有节点完整落在 viewBox 内」，不必跟随容器宽度。
	--
	-- ⚠️ 最右一列的右边缘必须留出边距（v0.12.3 修）：
	--
	--   最右节点 x = X4 + NW + GAP = 700 + 128 + 88 = 916
	--   右边缘     = 916 + NW = 916 + 128 = 1044
	--   viewBox 宽 = W = 1060，留 16px 边距
	--
	-- v0.12.2 及之前是 X4 + NW + 96 = 924，右边缘 1052 > W(1040) ——
	-- 「国外上游」节点被 viewBox 裁掉 12px，在窄视口下实测超出卡片
	-- 内容区 8px（卡片 padding 16px，SVG 被 max-width 撑满时按比例放大）。
	-- 改坐标后必须同步 W，二者是绑定的。
	local W, H = 1060, 356
	local NW, NH = 128, 54
	local X1, X2, X3, X4 = 12, 236, 424, 700
	local GAP = 88              -- 第 4 列到最右节点的水平间距
	local X5 = X4 + NW + GAP    -- 最右节点（国外上游）
	local YT, YB = 52, 216

	local p = {}
	p[#p + 1] = string.format(
		'<div class="dc-chain"><svg viewBox="0 0 %d %d" role="img" aria-label="%s">',
		W, H, translate("DNS 解析链路图"))

	p[#p + 1] = string.format(
		'<defs><marker id="dca" viewBox="0 0 10 10" refX="9" refY="5" ' ..
		'markerWidth="7" markerHeight="7" orient="auto-start-reverse">' ..
		'<path d="M 0 0 L 10 5 L 0 10 z" fill="%s"/></marker></defs>',
		"var(--dc-border)")

	local function line(x1, y1, x2, y2, color)
		return string.format(
			'<path d="M %d %d L %d %d" stroke="%s" stroke-width="2" fill="none" ' ..
			'marker-end="url(#dca)"/>', x1, y1, x2, y2, color)
	end

	local function elbow(x1, y1, xm, x2, y2, color)
		return string.format(
			'<path d="M %d %d H %d V %d H %d" stroke="%s" stroke-width="2" ' ..
			'fill="none" marker-end="url(#dca)"/>', x1, y1, xm, y2, x2, color)
	end

	-- 节点：状态点 + 标题 + 副标题 + 说明
	local function node(x, y, title, sub, alive, note)
		local col = c(alive)
		local s2 = string.format(
			'<g><rect x="%d" y="%d" width="%d" height="%d" rx="8" fill="none" ' ..
			'stroke="%s" stroke-width="2"/>' ..
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

	-- 连线（先画，节点压在上层）
	p[#p + 1] = line(X1 + NW, (YT + YB) / 2 + NH / 2, X2, (YT + YB) / 2 + NH / 2,
		c(sn.dnsmasq))
	p[#p + 1] = elbow(X2 + NW, YT + NH / 2, X2 + NW + 26, X3, YT + NH / 2,
		c(sn.dnsproxy_cn))
	p[#p + 1] = elbow(X2 + NW, YB + NH / 2, X2 + NW + 26, X3, YB + NH / 2,
		c(sn.dnsproxy_fg))
	p[#p + 1] = line(X3 + NW, YT + NH / 2, X4, YT + NH / 2, c(sn.dnsproxy_cn))
	p[#p + 1] = line(X3 + NW, YB + NH / 2, X4, YB + NH / 2,
		c(sn.dnsproxy_fg and sn.proxy_1234))
	p[#p + 1] = line(X4 + NW, YB + NH / 2, X5, YB + NH / 2,
		c(sn.proxy_1234 and sn.dnsproxy_fg))

	-- 节点
	p[#p + 1] = node(X1, (YT + YB) / 2, translate("LAN 客户机"),
		translate("DHCP 下发"), true, nil)
	p[#p + 1] = node(X2, (YT + YB) / 2, "dnsmasq", ":53",
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

	-- 分流标注（放在折线旁，不压线）
	p[#p + 1] = label(X2 + NW + 6, YT + NH / 2 - 8, translate("默认"))
	p[#p + 1] = label(X2 + NW + 6, YB + NH / 2 + 16, translate("gfw 域名"))

	-- 底部：nftset 入集说明
	p[#p + 1] = label(X1 + 4, H - 22,
		translate("国外域名解析结果经 nftset 写入 blacklist → 流量进 :1234"))

	p[#p + 1] = '</svg></div>'
	return table.concat(p)
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
	uci:foreach("dnschain", "upstream", function(sec)
		if sec[".name"] == section then
			collect_strings(sec.server, urls)
		end
	end)
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
		"关闭后跳过校验，仅用于上游证书异常时的排障。"))
o.rmempty = true
o.default = "1"

o = s:option(Flag, "via_proxy", translate("经代理出站"),
	translate("国外上游的连接走 SSR-Plus 的 OUTPUT 链。" ..
		"要求 router_proxy=1 且 dports 含 443。" ..
		"<br/><b>不要关</b>：国外 DoH 直连会被墙，国外域名将全部无结果。"))
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
	ds.sync_dnsmasq_filter_aaaa()
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
		"不再需要防止 ipv6hint 泄漏。"))
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

o = s:option(Flag, "enabled", translate("启用缓存"))
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

o = s:option(Value, "import_interval", translate("轮询间隔（秒）"))
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
-- Tab「诊断」：自检表格 + 操作
------------------------------------------------------------------------

s = m:section(TypedSection, "selftest", translate("自检"),
	translate("16 项检查覆盖链路可达性、分流正确性、上游加密、双栈策略、" ..
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
			it.no or 0, cls, it.status, it.name or "", it.detail or "")
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
	translate("自检失败时自动回滚到上一次通过的配置快照。"))
o.rmempty = false
o.default = "1"

o = s:option(Value, "interval", translate("定时自检间隔（秒）"),
	translate("0 表示关闭定时自检。"))
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

return m
