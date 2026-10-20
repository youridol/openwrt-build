-- Copyright (C) 2026 openwrt-build
-- DNS 链路框架控制页面
-- 设计依据: docs/adr/0003-dns-chain-framework.md
--
-- 定位：只做配置读写、校验、下发、自检与回滚，**不实现解析逻辑**。
-- 页面与链路解耦是「改 UI 不坏链路」的前提。

local fs = require "nixio.fs"
local sys = require "luci.sys"
local http = require "luci.http"
local disco = require "luci.dispatcher"

local M = {}

M.sys = sys

------------------------------------------------------------------------
-- 运行时状态读取（全部只读，供页面展示）
------------------------------------------------------------------------

--- 读取 /var/etc/dnschain 下的参数文件
function M.read_args(name)
	local path = "/var/etc/dnschain/" .. name
	if not fs.access(path) then
		return nil
	end
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local lines = {}
	for line in f:lines() do
		if line ~= "" then
			lines[#lines + 1] = line
		end
	end
	f:close()
	return lines
end

--- 端口监听者 PID
function M.port_owner(port, proto)
	proto = proto or "udp"
	local flag = (proto == "udp") and "-lnup" or "-lntp"
	local out = sys.exec("netstat " .. flag .. " 2>/dev/null | awk '$4 ~ /:" .. port .. "$/ {print $NF}' | sed 's|/.*||' | head -1") or ""
	return (out:gsub("%s+", ""))
end

--- 端口是否被监听
function M.port_listening(port, proto)
	return M.port_owner(port, proto) ~= ""
end

--- 该 PID 是否属于框架的 chinadns-ng
function M.is_framework_filter(pid)
	if not pid or pid == "" then
		return false
	end
	local cmdline = "/proc/" .. pid .. "/cmdline"
	if not fs.access(cmdline) then
		return false
	end
	local f = io.open(cmdline, "r")
	if not f then
		return false
	end
	local cmd = f:read("*a") or ""
	f:close()
	return cmd:find("chinadns%-ng") ~= nil
end

--- 读取 ss_spec_output 的 TCP 端口集
function M.output_ports()
	local out = sys.exec("nft list chain inet ss_spec ss_spec_output 2>/dev/null | sed -n 's/.*tcp dport { \\([^}]*\\) }.*/\\1/p' | head -1") or ""
	out = out:gsub("%s+", "")
	return out
end

--- 从上游 URL 抽端口
function M.upstream_port(url)
	if not url or url == "" then
		return nil
	end
	local scheme = url:match("^([%w+]+)://")
	if not scheme then
		return nil
	end
	local hostport = url:gsub("^[%w+]+://", ""):gsub("/.*$", "")
	local port = hostport:match(":%[?([0-9]+)%]?$")
	if not port then
		if scheme == "https" then
			port = "443"
		elseif scheme == "tls" or scheme == "quic" then
			port = "853"
		elseif scheme == "http" then
			port = "80"
		end
	end
	return port
end

--- 校验一组上游端口是否都在代理端口集内
--- 返回 (ok, 越界列表)
function M.validate_upstreams(urls)
	local ports = M.output_ports()
	if ports == "" then
		-- nft 尚未就绪时不阻断
		return true, {}
	end
	local bad = {}
	for _, u in ipairs(urls) do
		local p = M.upstream_port(u)
		if p then
			if not ("," .. ports .. ","):find("," .. p .. ",", 1, true) then
				bad[#bad + 1] = u .. "（端口 " .. p .. " 不在 " .. ports .. "）"
			end
		end
	end
	return (#bad == 0), bad
end

--- 名单规模
function M.list_stats()
	local stats = {}
	local function count(path)
		if not fs.access(path) then
			return 0
		end
		local out = sys.exec("wc -l < " .. path .. " 2>/dev/null") or "0"
		return tonumber((out:gsub("%s+", ""))) or 0
	end
	stats.gfw_lines = count("/etc/ssrplus/gfw_list.conf")
	stats.base_lines = count("/etc/ssrplus/gfw_base.conf")
	stats.domains = count("/var/etc/dnschain/upstreams-domains.txt")
	stats.idna = count("/var/etc/dnschain/idna-bypass.conf")
	local mt = sys.exec("stat -c %y /etc/ssrplus/gfw_list.conf 2>/dev/null") or ""
	stats.updated = (mt:gsub("%s+$", ""))
	return stats
end

--- 缓存统计（dnsmasq metrics）
function M.cache_stats()
	local out = sys.exec("ubus call dnsmasq metrics 2>/dev/null") or ""
	local stats = {}
	for k, v in out:gmatch('"([%w_]+)"%s*:%s*(%d+)') do
		stats[k] = tonumber(v)
	end
	return stats
end

------------------------------------------------------------------------
-- 动作（供页面按钮调用）
------------------------------------------------------------------------

--- 清空缓存：SIGHUP，零中断
function M.flush_cache()
	local pid = sys.exec("pidof dnsmasq 2>/dev/null | awk '{print $1}'") or ""
	pid = pid:gsub("%s+", "")
	if pid == "" then
		return false, "dnsmasq 未运行"
	end
	sys.exec("kill -HUP " .. pid .. " 2>/dev/null")
	return true, "已清空 dnsmasq 缓存（零中断）"
end

--- 手动导入名单
function M.import_lists()
	local out = sys.exec("/usr/bin/dnschain-reconcile 2>&1")
	return true, out
end

--- 触发 SSR-Plus 更新 GFW 名单
function M.update_gfw_list()
	if not fs.access("/usr/share/shadowsocksr/update.lua") then
		return false, "未找到 SSR-Plus 的 update.lua"
	end
	sys.exec("/usr/bin/lua /usr/share/shadowsocksr/update.lua gfw_data 2>&1")
	return true, "已请求更新 GFW 名单（完成后由收敛器自动导入）"
end

--- 一键归一（写回 SSR-Plus 的键）
function M.reconcile_now()
	local out = sys.exec("/usr/bin/dnschain-reconcile 2>&1")
	return true, out
end

--- 运行自检
function M.selftest()
	local out = sys.exec("/usr/bin/dnschain-selftest 2>&1") or ""
	local items = {}
	for line in out:gmatch("[^\n]+") do
		local no, status, rest = line:match("^(%d+)%s+(%u+)%s+(.+)$")
		if no then
			local name, detail = rest:match("^([^—]+)—%s*(.*)$")
			items[#items + 1] = {
				no = tonumber(no),
				status = status,
				name = (name or rest):gsub("%s+$", ""),
				detail = detail or ""
			}
		end
	end
	local summary = out:match("SUMMARY PASS=(%d+) FAIL=(%d+) SKIP=(%d+)")
	local conclusion = out:match("CONCLUSION:%s*([^\n]+)")
	return {
		items = items,
		pass = summary and tonumber((summary)) or 0,
		conclusion = conclusion or ""
	}, out
end

--- 当前 SSR-Plus DNS 模式
function M.ssr_mode()
	return (sys.exec("uci -q get shadowsocksr.@global[0].pdnsd_enable 2>/dev/null") or ""):gsub("%s+", "")
end

--- 当前 profile 对应的过滤器端口
function M.filter_port()
	local profile = (sys.exec("uci -q get dnschain.main.profile 2>/dev/null") or ""):gsub("%s+", "")
	return (profile == "coexist") and "5337" or "5335"
end

return M
