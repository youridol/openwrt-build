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

s = m:section(TypedSection, "main", translate("概览"))
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

-- 组件状态表
o = s:option(DummyValue, "_topology", translate("链路状态"))
o.rawhtml = true
function o.cfgvalue()
	local entry = ds.entry_port()
	local fport = ds.foreign_port()
	local lan = (luci.sys.exec("uci -q get network.lan.ipaddr") or ""):gsub("%s+", "")

	local function row(name, port, ok, detail)
		local icon = ok and "✓" or "✗"
		local color = ok and "#2e7d32" or "#c62828"
		return string.format(
			'<tr><td style="padding:4px 8px;color:%s;font-weight:bold">%s</td>' ..
			'<td style="padding:4px 8px">%s</td>' ..
			'<td style="padding:4px 8px">%s</td>' ..
			'<td style="padding:4px 8px;color:#666">%s</td></tr>',
			color, icon, name, port or "—", detail or "")
	end

	local rows = {}

	-- 客户机 DNS 路径：dnsmasq 直接监听 LAN 地址的 53，
	-- 客户机无需经 nft 劫持即可问到（v0.10.0 实测确认）。
	local dnsmasq_ok = ds.port_listening("53", "udp")
	rows[#rows + 1] = row("dnsmasq", "53", dnsmasq_ok,
		dnsmasq_ok and translate("唯一缓存层 + 唯一分流层 + DHCP") or translate("未监听"))

	-- 国内 dnsproxy 实例
	local dp_ok = ds.port_listening(entry, "udp")
	rows[#rows + 1] = row(translate("dnsproxy（国内）"), entry, dp_ok,
		dp_ok and translate("阿里 DoT/DoH，直连") or translate("未监听"))

	-- 国外 dnsproxy 实例
	local f_pid = ds.port_owner(fport, "udp")
	local f_ok = ds.is_dnsproxy(f_pid)
	rows[#rows + 1] = row(translate("dnsproxy（国外）"), fport, f_ok,
		f_ok and translate("Google DoH，经代理出站") or
		(f_pid ~= "" and (translate("被其他进程占用 (PID ") .. f_pid .. ")") or translate("未监听")))

	-- 代理
	local proxy_ok = ds.port_listening("1234", "tcp")
	rows[#rows + 1] = row(translate("SSR-Plus 代理"), "1234", proxy_ok,
		proxy_ok and translate("透明代理（IPv4 + IPv6）") or translate("未运行 —— 国外域名将失败"))

	-- IPv6 流量代理
	local v6_ok = (ds.ssr_ipv6() == "1")
	rows[#rows + 1] = row(translate("IPv6 流量代理"), "ipv6_support", v6_ok,
		v6_ok and translate("已启用，国外 IPv6 也走代理") or translate("未启用 —— 国外 IPv6 会直连被 RST"))

	-- 缓存
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

s = m:section(TypedSection, "main", translate("拦截总开关"))
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
		"若不开启，客户端可能绕过 AAAA 抑制直接拿到真实 IPv6 地址。" ..
		"<br/><b>与「对客户机提供 DoH/DoT 服务端」互斥。</b>"))
o.rmempty = false
o.default = "1"

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

s = m:section(TypedSection, "upstream", translate("解析策略"),
	translate("两侧上游都必须加密（DoT 或 DoH）。" ..
		"国外上游必须是 <b>IP 形式</b>——dnsproxy 不支持 socks5，" ..
		"只能靠 IP 层把连接送进代理；用域名形式会因 SNI 与目标 IP 不一致而握手失败。"))
s.anonymous = true
s.addremove = false
s.template = "cbi/tblsection"

o = s:option(DynamicList, "server", translate("上游服务器"))
o.datatype = "or(hostname, ipaddr)"
o.rmempty = false
function o.validate(self, value, section)
	-- 收集本 section 的全部上游，做端口校验
	local urls = {}
	local uci = require "luci.model.uci".cursor()
	uci:foreach("dnschain", "upstream", function(sec)
		if sec[".name"] == section then
			for _, v in ipairs(sec.server or {}) do
				urls[#urls + 1] = v
			end
		end
	end)
	if value and value ~= "" then
		urls[#urls + 1] = value
	end

	local ok, bad = ds.validate_upstreams(urls)
	if not ok then
		return nil, translate("以下上游端口不在代理端口集内，路由器自身出向不会被代理：") ..
			" " .. table.concat(bad, "；")
	end
	return value
end

o = s:option(Flag, "cert_verify", translate("校验上游证书"),
	translate("dnsproxy 的 DoH 上游走标准 TLS（带 SNI），可以正常校验证书。" ..
		"关闭后跳过校验，仅用于上游证书异常时的排障。"))
o.rmempty = true
o.default = "1"
o:depends({ [".name"] = "foreign" })

o = s:option(Flag, "via_proxy", translate("经代理出站"),
	translate("国外上游的连接走 SSR-Plus 的 OUTPUT 链。" ..
		"要求 access_control.router_proxy=1 且 dports 含 443。" ..
		"<br/><b>不要关</b>：国外 DoH 直连会被墙，国外域名将全部无结果。"))
o.rmempty = true
o.default = "1"
o:depends({ [".name"] = "foreign" })

------------------------------------------------------------------------
-- 双栈策略（只读）
------------------------------------------------------------------------

s = m:section(TypedSection, "aaaa", translate("双栈策略（只读）"),
	translate("v0.10.0 起国外 AAAA <b>保留</b>：SSR-Plus 的 IPv6 流量代理" ..
		"（<code>ipv6_support=1</code>）会把国外 IPv6 也送进代理，" ..
		"不再存在「IPv6 直连被 RST」的问题，抑制 AAAA 反而让国外站点失去双栈。"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "domestic", translate("国内 AAAA"))
function o.cfgvalue()
	return translate("保留（国内双栈）")
end

o = s:option(DummyValue, "foreign", translate("国外 AAAA / HTTPS"))
function o.cfgvalue()
	return translate("保留（返回真实 AAAA，IPv6 经代理出站）")
end

o = s:option(DummyValue, "_why", translate("说明"))
function o.cfgvalue()
	return translate("v0.10.0 起国外 AAAA 不再抑制。SSR-Plus 的 IPv6 流量代理" ..
		"（ipv6_support=1）会把国外 IPv6 也送进代理，实测 curl -6 google → 302、" ..
		"youtube → 200。抑制 AAAA 只会让国外站点失去双栈能力。")
end

------------------------------------------------------------------------
-- 端口与实例
------------------------------------------------------------------------

s = m:section(TypedSection, "main", translate("端口与实例"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_ports", translate("当前端口"))
function o.cfgvalue()
	return string.format(
		translate("国内 dnsproxy :%s（阿里 DoT/DoH，直连）· 国外 dnsproxy :%s（Google DoH，经代理）"),
		ds.entry_port(), ds.foreign_port())
end

o = s:option(DummyValue, "_ssr_mode", translate("当前 SSR-Plus DNS 模式"))
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

s = m:section(TypedSection, "main", translate("操作"))
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
