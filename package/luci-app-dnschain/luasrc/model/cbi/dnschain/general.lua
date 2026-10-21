-- Copyright (C) 2026 openwrt-build
-- 网络 → DNS 链路
-- 设计依据: docs/adr/0003-dns-chain-framework.md
--
-- 页面定位：只做配置读写、校验、下发、自检与回滚，不实现解析逻辑。
-- 配置写入单点：只有本页面（经 dnschain 的 init 与收敛器）写 DNS 键。

local ds = require "luci.model.cbi.dnschain.dnschain"

local m, s, o

m = Map("dnschain", translate("DNS 链路"),
	translate("集中控制 DNS 解析链路。本页面只负责配置与校验，" ..
		"不实现解析逻辑——解析由 dnsproxy 与策略过滤器完成。"))

------------------------------------------------------------------------
-- 概览：一句话结论 + 状态表
------------------------------------------------------------------------

------------------------------------------------------------------------
-- 概览：一句话结论 + 链路图 + 图表
--
-- 视觉取向：这一页是「诊断台」，不是营销页。首屏主角是**链路图** ——
-- 用户来这里的第一个问题是「现在请求是怎么走的、哪一段断了」。
-- 所以链路图放最前，配置项在后；图表只承担「链路是否健康」的量化，
-- 不与链路图争视觉重量。
--
-- 全部用内联 SVG，不引外部库：
--   - shadcn 主题下 LuCI 的表格是 display:block，SVG 不受影响
--   - 无网络依赖，路由器离线也能画
--   - 颜色取自 shadcn 的语义色（成功/警告/危险），跟随明暗主题
------------------------------------------------------------------------

s = m:section(TypedSection, "dnschain", translate("概览"))
s.anonymous = true
s.addremove = false

-- 一句话结论行（由自检结果驱动）
o = s:option(DummyValue, "_conclusion", translate("当前状态"))
o.rawhtml = true
function o.cfgvalue()
	local result = ds.selftest()
	local cls = "cbi-value-field"
	local concl = result.conclusion

	-- 没有结论行时按组件状态自行归纳
	if concl == "" then
		local entry = ds.entry_port()
		local fport = ds.foreign_port()
		local fowner = ds.port_owner(fport, "udp")
		if not ds.port_listening(entry, "udp") then
			concl = translate("国内 dnsproxy 未监听 —— 客户机全部无法解析")
			cls = cls .. " alert-message error"
		elseif fowner == "" then
			concl = translate("国外 dnsproxy 未监听 —— gfw 域名将 SERVFAIL，国内不受影响")
			cls = cls .. " alert-message warning"
		elseif not ds.is_dnsproxy(fowner) then
			concl = translate("国外端口被其他进程占用 —— gfw 域名会走错解析器")
			cls = cls .. " alert-message warning"
		elseif not ds.port_listening("1234", "tcp") then
			concl = translate("代理未运行 —— 国外域名将失败（国内不受影响）")
			cls = cls .. " alert-message warning"
		elseif ds.ssr_ipv6() ~= "1" then
			concl = translate("IPv6 流量代理未开 —— 国外 IPv6 会直连被 RST")
			cls = cls .. " alert-message warning"
		else
			concl = translate("链路正常")
			cls = cls .. " alert-message success"
		end
	end

	return string.format('<span class="%s">%s</span>', cls, concl)
end

-- ── 链路图（首屏主角）──────────────────────────────────────
--
-- 布局：三段式横向主干 + 分叉，避免斜线穿过标注文字。
--
--   ① 入口         ② 分流点        ③ 两个出口
--   LAN ──▶ dnsmasq ──┬──▶ dnsproxy 国内 ──▶ 国内上游
--                     └──▶ dnsproxy 国外 ──▶ SSR-Plus ──▶ 国外上游
--
-- 上一版把两个 dnsproxy 上下错开 160px 却用斜线连接，斜线正好穿过
-- 「默认 → 国内」「server=/gfw域名/ → 国外」两行标注，实测截图里文字被线压住。
-- 改为：标注放在**分支起点右侧的空白处**，且斜线改走直角折线。
o = s:option(DummyValue, "_chain_graph", translate("解析链路"))
o.rawhtml = true
function o.cfgvalue()
	local sn = ds.chain_snapshot()

	local C = {
		ok   = "#16a34a",
		bad  = "#dc2626",
		warn = "#d97706",
		line = "#cbd5e1",
		text = "currentColor",
	}

	local function col(alive)
		return alive and C.ok or C.bad
	end

	-- 画布与节点尺寸
	local W, H = 1040, 350
	local NW, NH = 128, 54

	-- 三列 x 坐标
	local X1, X2, X3, X4 = 12, 236, 424, 700
	-- 两行 y 坐标（上行 = 国内路径，下行 = 国外路径）
	local YT, YB = 52, 216

	local parts = {}
	parts[#parts + 1] = string.format(
		'<svg viewBox="0 0 %d %d" width="100%%" style="max-width:%dpx;height:auto;display:block" ' ..
		'font-family="inherit" role="img" aria-label="%s">',
		W, H, W, translate("DNS 解析链路图"))

	parts[#parts + 1] = string.format(
		'<defs><marker id="dca" viewBox="0 0 10 10" refX="9" refY="5" ' ..
		'markerWidth="7" markerHeight="7" orient="auto-start-reverse">' ..
		'<path d="M 0 0 L 10 5 L 0 10 z" fill="%s"/></marker></defs>', C.line)

	-- 直线
	local function line(x1, y1, x2, y2, color)
		return string.format(
			'<path d="M %d %d L %d %d" stroke="%s" stroke-width="2" fill="none" ' ..
			'marker-end="url(#dca)"/>', x1, y1, x2, y2, color)
	end

	-- 直角折线（先横、再竖、再横），用于分叉，不穿过文字
	local function elbow(x1, y1, xm, x2, y2, color)
		return string.format(
			'<path d="M %d %d H %d V %d H %d" stroke="%s" stroke-width="2" ' ..
			'fill="none" marker-end="url(#dca)"/>', x1, y1, xm, y2, x2, color)
	end

	-- 节点
	local function node(x, y, title, sub, alive, note)
		local c = col(alive)
		local s = string.format(
			'<g><rect x="%d" y="%d" width="%d" height="%d" rx="8" fill="none" ' ..
			'stroke="%s" stroke-width="2"/>' ..
			'<circle cx="%d" cy="%d" r="4" fill="%s"/>' ..
			'<text x="%d" y="%d" font-size="13" font-weight="600" fill="%s">%s</text>' ..
			'<text x="%d" y="%d" font-size="11" fill="%s" opacity="0.72">%s</text>',
			x, y, NW, NH, c,
			x + 12, y + 15, c,
			x + 24, y + 22, C.text, title,
			x + 24, y + 39, C.text, sub)
		if note then
			s = s .. string.format(
				'<text x="%d" y="%d" font-size="10" fill="%s" opacity="0.55">%s</text>',
				x + 24, y + 50, C.text, note)
		end
		return s .. '</g>'
	end

	-- 标注（无背景，靠位置避开线）
	local function label(x, y, txt)
		return string.format(
			'<text x="%d" y="%d" font-size="10" fill="%s" opacity="0.7">%s</text>',
			x, y, C.text, txt)
	end

	-- ── 连线（先画，节点压在上层）──
	-- LAN → dnsmasq（主干，垂直居中）
	parts[#parts + 1] = line(X1 + NW, (YT + YB) / 2 + NH / 2, X2, (YT + YB) / 2 + NH / 2,
		col(sn.dnsmasq))

	-- dnsmasq → 国内（折线：右出 → 上行 → 右进）
	parts[#parts + 1] = elbow(X2 + NW, YT + NH / 2, X2 + NW + 26, X3, YT + NH / 2,
		col(sn.dnsproxy_cn))

	-- dnsmasq → 国外（折线：右出 → 下行 → 右进）
	parts[#parts + 1] = elbow(X2 + NW, YB + NH / 2, X2 + NW + 26, X3, YB + NH / 2,
		col(sn.dnsproxy_fg))

	-- 国内 dnsproxy → 国内上游
	parts[#parts + 1] = line(X3 + NW, YT + NH / 2, X4, YT + NH / 2, col(sn.dnsproxy_cn))

	-- 国外 dnsproxy → SSR-Plus（同行直连）
	parts[#parts + 1] = line(X3 + NW, YB + NH / 2, X4, YB + NH / 2,
		col(sn.dnsproxy_fg and sn.proxy_1234))

	-- SSR-Plus → 国外上游
	parts[#parts + 1] = line(X4 + NW, YB + NH / 2, X4 + NW + 96, YB + NH / 2,
		col(sn.proxy_1234 and sn.dnsproxy_fg))

	-- ── 节点 ──
	parts[#parts + 1] = node(X1, (YT + YB) / 2, translate("LAN 客户机"),
		translate("DHCP 下发"), true, nil)

	parts[#parts + 1] = node(X2, (YT + YB) / 2, "dnsmasq", ":53",
		sn.dnsmasq, sn.dnsmasq and translate("缓存 + 分流") or translate("未监听"))

	parts[#parts + 1] = node(X3, YT, translate("dnsproxy 国内"), ":" .. sn.entry_port,
		sn.dnsproxy_cn, translate("阿里 DoT/DoH"))

	parts[#parts + 1] = node(X3, YB, translate("dnsproxy 国外"), ":" .. sn.foreign_port,
		sn.dnsproxy_fg, translate("Google DoH"))

	parts[#parts + 1] = node(X4, YT, translate("国内上游"), translate("直连"),
		sn.dnsproxy_cn, "223.5.5.5")

	parts[#parts + 1] = node(X4, YB, "SSR-Plus", ":1234",
		sn.proxy_1234, sn.proxy_1234 and translate("透明代理") or translate("未运行"))

	parts[#parts + 1] = node(X4 + NW + 96, YB, translate("国外上游"), translate("经代理"),
		sn.proxy_1234 and sn.dnsproxy_fg, "dns.google")

	-- ── 标注（放在分支折线的上方/下方空白，不压线）──
	parts[#parts + 1] = label(X2 + NW + 6, YT + NH / 2 - 8, translate("默认"))
	parts[#parts + 1] = label(X2 + NW + 6, YB + NH / 2 + 16, translate("gfw 域名"))

	-- ── 底部说明：nftset 入集 ──
	parts[#parts + 1] = string.format(
		'<text x="%d" y="%d" font-size="11" fill="%s" opacity="0.72">%s</text>',
		X1 + 4, H - 22, C.text,
		translate("国外域名解析结果经 nftset 写入 blacklist → 流量进 :1234"))

	parts[#parts + 1] = '</svg>'

	return table.concat(parts)
end
-- ── 统计图表 ───────────────────────────────────────────────
o = s:option(DummyValue, "_charts", translate("链路指标"))
o.rawhtml = true
function o.cfgvalue()
	local sn = ds.chain_snapshot()

	-- 三项条形图：缓存插入 / 转发 / 本地应答
	-- 用相对长度表达比例，绝对值标在右侧（不省略数字，避免「只看得懂形状」）
	local metrics = {
		{
			label = translate("缓存插入"),
			value = sn.inserted,
			hint  = translate("dnsmasq 写入缓存的条目"),
			color = "#2563eb",
		},
		{
			label = translate("转发上游"),
			value = sn.forwarded,
			hint  = translate("交给 dnsproxy 的查询"),
			color = "#7c3aed",
		},
		{
			label = translate("本地应答"),
			value = sn.local_ans,
			hint  = translate("缓存或 hosts 直接命中"),
			color = "#0891b2",
		},
	}

	local maxv = 1
	for _, m in ipairs(metrics) do
		if (m.value or 0) > maxv then maxv = m.value end
	end

	local rows = {}
	for _, m in ipairs(metrics) do
		local v = m.value
		local pct = (v and v > 0) and math.floor(v * 100 / maxv) or 0
		local shown = v and tostring(v) or "—"
		rows[#rows + 1] = string.format(
			'<div style="display:flex;align-items:center;gap:10px;margin:6px 0">' ..
			'<span style="flex:0 0 84px;font-size:12px;opacity:0.8">%s</span>' ..
			'<span style="flex:1 1 auto;height:10px;background:rgba(148,163,184,0.25);' ..
			'border-radius:5px;overflow:hidden">' ..
			'<span style="display:block;height:100%%;width:%d%%;background:%s;border-radius:5px"></span></span>' ..
			'<span style="flex:0 0 auto;font-size:12px;font-variant-numeric:tabular-nums;min-width:56px;text-align:right">%s</span>' ..
			'</div>',
			m.label, pct, m.color, shown)
	end

	-- 规模卡片：分流规则 / blacklist / china
	local function card(label, value, hint)
		return string.format(
			'<div style="flex:1 1 0;min-width:130px;padding:10px 12px;border:1px solid rgba(148,163,184,0.35);' ..
			'border-radius:8px">' ..
			'<div style="font-size:11px;opacity:0.7;margin-bottom:2px">%s</div>' ..
			'<div style="font-size:20px;font-weight:600;font-variant-numeric:tabular-nums;line-height:1.2">%s</div>' ..
			'<div style="font-size:10px;opacity:0.6;margin-top:2px">%s</div>' ..
			'</div>',
			label, value, hint)
	end

	local cards = table.concat({
		card(translate("分流规则"), tostring(sn.split_count), translate("条 server=/域名/")),
		card(translate("代理 IP 集"), tostring(sn.blacklist), translate("个国外 IP")),
		card(translate("国内 IP 段"), tostring(sn.china), translate("个 CIDR")),
		card(translate("未应答"), sn.unanswered and tostring(sn.unanswered) or "—", translate("次查询")),
	})

	return '<div style="margin-bottom:12px;max-width:620px">' .. table.concat(rows) .. '</div>' ..
		'<div style="display:flex;gap:8px;flex-wrap:wrap">' .. cards .. '</div>'
end

-- 组件状态表（保留原有逐项判据，链路图之外的细节视图）
o = s:option(DummyValue, "_topology", translate("组件状态"))
o.rawhtml = true
function o.cfgvalue()
	local entry = ds.entry_port()
	local fport = ds.foreign_port()

	local function row(name, port, ok, detail)
		local icon = ok and "✓" or "✗"
		local color = ok and "#16a34a" or "#dc2626"
		return string.format(
			'<tr><td style="padding:4px 8px;color:%s;font-weight:bold">%s</td>' ..
			'<td style="padding:4px 8px">%s</td>' ..
			'<td style="padding:4px 8px">%s</td>' ..
			'<td style="padding:4px 8px;opacity:0.7">%s</td></tr>',
			color, icon, name, port or "—", detail or "")
	end

	local rows = {}

	local dnsmasq_ok = ds.port_listening("53", "udp")
	rows[#rows + 1] = row("dnsmasq", "53", dnsmasq_ok,
		dnsmasq_ok and translate("唯一缓存层 + 唯一分流层 + DHCP") or translate("未监听"))

	local dp_ok = ds.port_listening(entry, "udp")
	rows[#rows + 1] = row(translate("dnsproxy（国内）"), entry, dp_ok,
		dp_ok and translate("阿里 DoT/DoH，直连") or translate("未监听"))

	local f_pid = ds.port_owner(fport, "udp")
	local f_ok = ds.is_dnsproxy(f_pid)
	rows[#rows + 1] = row(translate("dnsproxy（国外）"), fport, f_ok,
		f_ok and translate("Google DoH，经代理出站") or
		(f_pid ~= "" and (translate("被其他进程占用 (PID ") .. f_pid .. ")") or translate("未监听")))

	local proxy_ok = ds.port_listening("1234", "tcp")
	rows[#rows + 1] = row(translate("SSR-Plus 代理"), "1234", proxy_ok,
		proxy_ok and translate("透明代理（IPv4 + IPv6）") or translate("未运行 —— 国外域名将失败"))

	local v6_ok = (ds.ssr_ipv6() == "1")
	rows[#rows + 1] = row(translate("IPv6 流量代理"), "ipv6_support", v6_ok,
		v6_ok and translate("已启用，国外 IPv6 也走代理") or translate("未启用 —— 国外 IPv6 会直连被 RST"))

	local cstat = ds.cache_stats()
	local cache_ok = (cstat.dns_cache_inserted or 0) > 0
	rows[#rows + 1] = row(translate("缓存"), "dnsmasq", cache_ok,
		string.format(translate("插入 %d / 本地应答 %d / 转发 %d"),
			cstat.dns_cache_inserted or 0,
			cstat.dns_local_answered or 0,
			cstat.dns_queries_forwarded or 0))

	return '<table class="table" style="width:100%"><thead><tr>' ..
		'<th style="padding:4px 8px"></th>' ..
		'<th style="padding:4px 8px">' .. translate("组件") .. '</th>' ..
		'<th style="padding:4px 8px">' .. translate("端口") .. '</th>' ..
		'<th style="padding:4px 8px">' .. translate("说明") .. '</th>' ..
		'</tr></thead><tbody>' .. table.concat(rows) .. '</tbody></table>'
end

------------------------------------------------------------------------
-- 拦截总开关
------------------------------------------------------------------------

s = m:section(TypedSection, "dnschain", translate("拦截总开关"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "intercept", translate("强制拦截客户机 DNS"),
	translate("开启：拦截静态 IP 客户机与 DHCP 客户机的 53，DHCP 下发路由器自身地址。" ..
		"关闭：停用拦截规则，客户机自行解析；DHCP 客户机按下方「DHCP 下发 DNS」配置的地址解析。" ..
		"<br/><b>注意</b>：切换约 3 秒内新客户机拿不到地址、现有客户机 DNS 短暂中断（需重启 dnsmasq）。"))
o.rmempty = false
o.default = "1"

o = s:option(Flag, "enabled", translate("启用 DNS 链路框架"),
	translate("关闭后过滤器不再监听，gfw 域名会 SERVFAIL（不会回落明文上游）。"))
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

o = s:option(Value, "entry_port", translate("国内实例端口"),
	translate("dnsproxy 实例 1 的监听端口，默认 5353。改动后需重启框架；" ..
		"与国外端口<b>不能相同</b>。"))
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

------------------------------------------------------------------------
-- DHCP 下发 DNS（仅拦截关闭时使用）
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

------------------------------------------------------------------------
-- 解析策略
------------------------------------------------------------------------

-- 上游校验（两个 section 共用）
--
-- 为什么不用 TypedSection + template="cbi/tblsection"：
-- 实测（2026-10-22）该组合下 `上游服务器` 标题会渲染，但**一个输入框都没有**
-- —— 只有 4 个按钮的 name 出现在页面里。原因是 anonymous=true 把
-- cn/foreign 两行合并，而 tblsection 期望「每行一个具名 section」。
-- 改为两个 NamedSection（分别绑定 cn 与 foreign），每项都能独立编辑，
-- 语义也更清楚：国内池与国外池的约束本来就不同。
--
-- ⚠️ 收集值时必须防 table：
-- uci 的 list 在 Lua 里是 table，DynamicList 提交的 value 也可能是 table。
-- 旧实现直接 `ipairs(sec.server or {})` 再拼进 urls，而 DynamicList 的
-- value 是 table 时会被原样塞进 urls → dnschain.lua 的 url:match 崩溃 →
-- 页面「保存并应用」整体 500。实测报错：
--   dnschain.lua:95: attempt to call method 'match' (a nil value)
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

-- ── 国内上游 ──────────────────────────────────────────────
s = m:section(NamedSection, "cn", "upstream", translate("国内上游"),
	translate("用于<b>不在</b> gfw 名单里的域名。直连出站，可混用 DoT 与 DoH，" ..
		"dnsproxy 会并行查询取最快。"))
s.addremove = false

o = s:option(DynamicList, "server", translate("上游服务器"))
o.datatype = "or(hostname, ipaddr)"
o.rmempty = false
o.validate = validate_upstream
o.placeholder = "tls://223.5.5.5"

-- ── 国外上游 ──────────────────────────────────────────────
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
		"要求 access_control.router_proxy=1 且 dports 含 443。" ..
		"<br/><b>不要关</b>：国外 DoH 直连会被墙，国外域名将全部无结果。"))
o.rmempty = true
o.default = "1"

------------------------------------------------------------------------
-- 双栈策略
--
-- 这里有一个必须讲清楚的联动关系（否则用户会以为滑块无效）：
--
--   shadowsocksr.@global[0].filter_aaaa   是「用户偏好」
--   dhcp.@dnsmasq[0].filter_aaaa          是「实际生效值」
--
--   ipv6_support=1 时，SSR-Plus 的 get_filter_aaaa() 直接返回 0，
--   并调 set_ipv6_dns_filter 把 dnsmasq.filter_aaaa 设为 0 ——
--   **无论用户偏好填什么都覆盖**。
--
-- 实测（2026-10-22，路由器上）：
--   shadowsocksr.filter_aaaa = 1
--   ipv6_support             = 1
--   dnsmasq.filter_aaaa      = 0   ← 被强制
--   而 AAAA 解析完全正常（taobao 2 条、google 8 条真实 AAAA）
--
-- 所以这个滑块的真实语义是「**关闭** IPv6 流量代理时要不要抑制 AAAA」。
-- 页面必须如实显示「当前是否被覆盖」，不能假装它在生效。
------------------------------------------------------------------------

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

	local state
	if eff == "0" then
		state = translate("<b>保留</b>（返回真实 AAAA）")
	else
		state = translate("<b>抑制</b>（返回空答复 rcode=0 ancount=0）")
	end

	if overridden then
		return state .. "<br/><span style='color:#c62828'>" ..
			translate("注意：偏好值是「抑制」，但 ipv6_support=1 已把它强制覆盖为「保留」。") ..
			"</span>"
	end
	return state
end

-- 开关：写 shadowsocksr.@global[0].filter_aaaa
--
-- 这是本页面**唯一**写 SSR-Plus 的键的地方（其余键由收敛器管）。
--
-- 为什么用 ListValue 而不是 Flag：
-- Flag 的 write() 拿到的 value 是 "1" 或空串，且它绑定在 aaaa.policy 这个
-- section 上；而我们要写的是**另一个包**（shadowsocksr）的键。
-- 实测（2026-10-22）用 Flag 时页面渲染成纯文本 + 说明，没有开关控件。
-- ListValue 的 write() 能拿到明确的值，且渲染成两个可点的选项，语义更清楚。
o = s:option(ListValue, "_filter_aaaa", translate("抑制国外 AAAA"),
	translate("写 <code>shadowsocksr.@global[0].filter_aaaa</code>。" ..
		"<br/><b>启用 IPv6 流量代理时此项无效</b> —— SSR-Plus 会强制覆盖为「保留」，" ..
		"因为它已经把国外 IPv6 送进代理，抑制只会让国外站点失去双栈。" ..
		"<br/>只有<b>关闭</b> IPv6 流量代理时，此项才真正决定行为。"))
o.rawhtml = false
o:value("0", translate("关闭 —— 保留 AAAA（推荐）"))
o:value("1", translate("开启 —— 抑制国外 AAAA"))
o.rmempty = false
function o.cfgvalue()
	return ds.ssr_filter_aaaa() == "1" and "1" or "0"
end
function o.write(self, section, value)
	local v = (value == "1") and "1" or "0"
	-- ⚠️ 不能用 luci.sys.call("...%s...", v)：它不支持 %s 插值，
	-- 会把字面 "%s" 写进 UCI（实测 shadowsocksr.filter_aaaa 变成 "%s"）。
	-- 用字符串拼接，v 只可能是 "0"/"1"，无注入风险。
	luci.sys.call("uci -q set shadowsocksr.@global[0].filter_aaaa='" .. v ..
		"' && uci -q commit shadowsocksr")
	-- 立即同步 dnsmasq 的生效值（复刻 SSR-Plus 的 set_ipv6_dns_filter）
	-- 不重启 shadowsocksr：那会断代理 3-10 秒
	ds.sync_dnsmasq_filter_aaaa()
end

o = s:option(DummyValue, "_aaaa_why", translate("实际生效值"))
o.rawhtml = true
function o.cfgvalue()
	local pref = ds.ssr_filter_aaaa()
	local eff = ds.dnsmasq_filter_aaaa()
	local v6 = ds.ssr_ipv6()
	return string.format(
		translate("偏好 <code>shadowsocksr.filter_aaaa=%s</code> · " ..
			"生效 <code>dnsmasq.filter_aaaa=%s</code> · " ..
			"IPv6 流量代理 <code>ipv6_support=%s</code>"),
		pref ~= "" and pref or "?", eff ~= "" and eff or "?", v6 ~= "" and v6 or "?")
end

o = s:option(Flag, "filter_https_rr", translate("抑制 HTTPS/SVCB 记录"),
	translate("qtype 64（SVCB）与 65（HTTPS）可携带 <code>ipv6hint</code>，" ..
		"客户端能绕过 AAAA 抑制拿到 IPv6 地址。" ..
		"<br/>v0.10.0 起<b>默认关闭</b>：IPv6 流量代理已把国外 IPv6 送进代理，" ..
		"不再需要防止 ipv6hint 泄漏。只有<b>关闭</b> IPv6 流量代理、又要抑制 AAAA 时，" ..
		"才需要同时打开此项。"))
o.rmempty = false
o.default = "0"

------------------------------------------------------------------------
-- 端口与实例
------------------------------------------------------------------------

s = m:section(TypedSection, "dnschain", translate("端口与实例"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_ports", translate("当前端口"))
o.rawhtml = true
function o.cfgvalue()
	return string.format(
		translate("国内 dnsproxy :%s（阿里 DoT/DoH，直连）· 国外 dnsproxy :%s（Google DoH，经代理）"),
		ds.entry_port(), ds.foreign_port())
end

o = s:option(DummyValue, "_ssr_mode", translate("当前 SSR-Plus DNS 模式"))
o.rawhtml = true
function o.cfgvalue()
	local mode = ds.ssr_mode()
	local names = {
		["0"] = translate("不启 DNS 后端（解析全部交给本框架）"),
		["1"] = translate("使用 DNS2TCP 查询（会另起解析器，与框架冲突）"),
		["2"] = translate("DNS2SOCKS（本固件未安装该后端）"),
		["3"] = translate("RUST（本固件未安装该后端）"),
		["4"] = translate("使用 MOSDNS 查询（会另起解析器，与框架冲突）"),
		["5"] = translate("使用 DNSPROXY 查询（会再起一个 dnsproxy，与框架冲突）"),
		["6"] = translate("使用 ChinaDNS-NG 查询（会另起解析器，与框架冲突）"),
		["7"] = translate("优先使用模块内置 DNS（不绑端口）"),
	}
	return string.format("pdnsd_enable = %s —— %s", mode ~= "" and mode or "?", names[mode] or translate("未知"))
end

o = s:option(DummyValue, "_ssr_ipv6", translate("当前 IPv6 流量代理"))
o.rawhtml = true
function o.cfgvalue()
	local v6 = ds.ssr_ipv6()
	if v6 == "1" then
		return translate("ipv6_support = 1 —— 已启用，国外 IPv6 也走代理（国外 AAAA 保留）")
	end
	return translate("ipv6_support = %s —— 未启用，国外 IPv6 会直连被 RST"):format(v6 ~= "" and v6 or "?")
end

s = m:section(TypedSection, "ssr", translate("SSR-Plus 兼容"))
s.anonymous = true
s.addremove = false

o = s:option(ListValue, "mode", translate("目标模式"))
o:value("0", translate("0 — 不启 DNS 后端（推荐）"))
o:value("7", translate("7 — 模块内置 DNS"))
o.rmempty = false
o.default = "0"

o = s:option(Flag, "enforce", translate("强制写回"),
	translate("收敛器在开机、SSR 配置变更、定时三处重放不变量集。" ..
		"关闭后只告警、不修改 SSR-Plus 的键。"))
o.rmempty = false
o.default = "1"

o = s:option(Flag, "require_ipv6", translate("要求启用 IPv6 流量代理"),
	translate("国外节点只有 IPv4。开启后收敛器会强制 <code>ipv6_support=1</code>，" ..
		"SSR-Plus 会装上 IPv6 代理链（<code>ss_spec6_*</code> + 策略路由），" ..
		"国外 IPv6 也走代理，从而可以保留国外 AAAA。" ..
		"<br/><b>不要关闭</b>：关闭后国外域名拿到真实 AAAA 却直连，会被 RST。"))
o.rmempty = false
o.default = "1"

------------------------------------------------------------------------
-- 列表与文件
------------------------------------------------------------------------

s = m:section(TypedSection, "lists", translate("名单与导入"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_stats", translate("名单规模"))
o.rawhtml = true
function o.cfgvalue()
	local st = ds.list_stats()
	return string.format(
		translate("GFW 源 %d 行 · 基础 %d 行 · 已导入 %d 条<br/>最近更新：%s"),
		st.gfw_lines, st.base_lines, st.domains,
		st.updated ~= "" and st.updated or translate("未知"))
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

-- 名单源（只读源文件路径，一般不需改；列出以便核对与排障）
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
-- 缓存
------------------------------------------------------------------------

s = m:section(TypedSection, "cache", translate("缓存"),
	translate("缓存只在 dnsmasq 一层。dnsproxy 与过滤器都不缓存——" ..
		"三处并存会让同一域名出现两份答案（实测：经 :53 与直连 :5353 返回不同 IP）。"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用缓存"))
o.rmempty = false
o.default = "1"

o = s:option(Value, "size", translate("条目数"))
o.datatype = "range(128, 65536)"
o.default = "8192"

o = s:option(DummyValue, "_cache_stat", translate("当前统计"))
o.rawhtml = true
function o.cfgvalue()
	local st = ds.cache_stats()
	if not st.dns_cache_inserted then
		return translate("取不到统计（dnsmasq 可能未运行）")
	end
	return string.format(
		translate("已插入 %d 条 · 本地应答 %d 次 · 已转发 %d 次 · 陈旧应答 %d 次"),
		st.dns_cache_inserted or 0,
		st.dns_local_answered or 0,
		st.dns_queries_forwarded or 0,
		st.dns_stale_answered or 0)
end

------------------------------------------------------------------------
-- 自检
------------------------------------------------------------------------

s = m:section(TypedSection, "selftest", translate("自检"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "auto_rollback", translate("失败自动回滚"))
o.rmempty = false
o.default = "1"

o = s:option(Value, "interval", translate("定时自检间隔（秒）"))
o.datatype = "range(60, 3600)"
o.default = "300"

o = s:option(DummyValue, "_selftest", translate("一键自检"))
o.rawhtml = true
function o.cfgvalue()
	local result = ds.selftest()
	local rows = {}
	for _, it in ipairs(result.items or {}) do
		local color = (it.status == "PASS") and "#2e7d32"
			or (it.status == "SKIP") and "#999" or "#c62828"
		rows[#rows + 1] = string.format(
			'<tr><td style="padding:3px 8px;color:#666">%d</td>' ..
			'<td style="padding:3px 8px;color:%s;font-weight:bold">%s</td>' ..
			'<td style="padding:3px 8px">%s</td>' ..
			'<td style="padding:3px 8px;color:#666;font-size:90%%">%s</td></tr>',
			it.no, color, it.status, it.name, it.detail)
	end
	if #rows == 0 then
		return '<em>' .. translate("自检脚本未返回结果（可能未安装 dnschain-selftest）") .. '</em>'
	end
	return '<table class="table" style="width:100%">' ..
		'<thead><tr><th></th><th>' .. translate("结果") .. '</th>' ..
		'<th>' .. translate("检查项") .. '</th><th>' .. translate("证据") .. '</th></tr></thead>' ..
		'<tbody>' .. table.concat(rows) .. '</tbody></table>'
end

------------------------------------------------------------------------
-- 动作按钮
------------------------------------------------------------------------

s = m:section(TypedSection, "dnschain", translate("操作"))
s.anonymous = true
s.addremove = false

o = s:option(Button, "_flush_cache", translate("清空全部缓存"),
	translate("发送 SIGHUP 清空 dnsmasq 缓存：进程不重启、客户机无感知。" ..
		"「清空指定域名」做不到——dnsmasq 与 dnsproxy 都没有按域名淘汰单条缓存的接口。"))
o.inputstyle = "reload"
function o.write(self, section)
	local ok, msg = ds.flush_cache()
	m.message = (ok and "✓ " or "✗ ") .. msg
end

o = s:option(Button, "_import", translate("手动导入名单"),
	translate("立即从 SSR-Plus 的名单文件重新生成框架的域名文件。"))
o.inputstyle = "apply"
function o.write(self, section)
	local ok, out = ds.import_lists()
	m.message = "✓ " .. translate("已导入") .. "<br/><pre>" .. (out or "") .. "</pre>"
end

o = s:option(Button, "_update_gfw", translate("立即更新 GFW 名单"),
	translate("调用 SSR-Plus 的 update.lua 下载最新名单，完成后由收敛器自动导入。"))
o.inputstyle = "apply"
function o.write(self, section)
	local ok, msg = ds.update_gfw_list()
	m.message = (ok and "✓ " or "✗ ") .. msg
end

o = s:option(Button, "_reconcile", translate("一键归一"),
	translate("立即重放不变量集：把 SSR-Plus / dnsmasq / dnsproxy 的相关键归一到框架期望值。"))
o.inputstyle = "apply"
function o.write(self, section)
	local ok, out = ds.reconcile_now()
	m.message = "✓ " .. translate("已归一") .. "<br/><pre>" .. (out or "") .. "</pre>"
end

return m
