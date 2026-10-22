-- Copyright (C) 2026 openwrt-build
-- DNS 链路框架控制页面
-- 设计依据: docs/adr/0003-dns-chain-framework.md
--
-- 定位：只做配置读写、校验、下发、自检与回滚，**不实现解析逻辑**。
-- 页面与链路解耦是「改 UI 不坏链路」的前提。
--
-- v0.10.0 变更（移除 chinadns-ng，改双 dnsproxy 实例）：
--   - filter_port() → foreign_port()：不再有「过滤器端口」，改为国外实例端口
--   - is_framework_filter() → is_dnsproxy()：不再检测 chinadns-ng
--   - list_stats 的 upstreams-domains.txt → foreign-split.conf
--   - 删除 idna 统计（v0.10.0 不再生成 idna-bypass.conf，xn-- 域名并入主分流）
--   - 修 stat -c %y：BusyBox 的 stat 不支持 -c，改用 date -r

local fs = require "nixio.fs"
local sys = require "luci.sys"
local http = require "luci.http"
local disco = require "luci.dispatcher"

local M = {}

M.sys = sys

------------------------------------------------------------------------
-- 请求级缓存
--
-- 为什么需要它（v0.11.1 性能修复）：
--
-- 实测（2026-10-22，路由器上）本页面加载 7.4 秒，而其他页面 0.04 秒 ——
-- 慢 170 倍。逐项计时后定位到「同一份数据被反复采集」：
--
--   ds.selftest()        被调用 2 次 × 1370ms = 2740ms
--   ds.chain_snapshot()  被调用 2 次，每次内部起 9 个进程
--                        （4×netstat + 2×nft + 4×uci + 1×ubus）
--   ds.cache_stats()     被调用 2 次
--   ds.list_stats()      被调用 1 次
--
-- 其中 nft list set china 单次 120ms（2025 个 CIDR），
-- netstat 单次 20ms。重复采集累计约 7.4 秒。
--
-- 解法：在模块级做**请求级**缓存 —— 同一个 Lua 请求内，
-- 每个采集函数只真正执行一次，后续命中缓存。
--
-- 为什么不是全局缓存：LuCI 每个 HTTP 请求是独立的 Lua 进程/上下文，
-- 模块级 table 天然只活一次请求，无需失效逻辑，也不会跨请求串数据。
-- 页面上的「保存后立即刷新」会发起新请求 → 拿到新数据。
------------------------------------------------------------------------

local _cache = {}

--- 带缓存的取值：同一请求内 key 只计算一次
local function cached(key, fn)
	local v = _cache[key]
	if v == nil then
		v = fn()
		-- 用 sentinel 区分「算出来是 nil」与「还没算」
		if v == nil then v = false end
		_cache[key] = v
	end
	if v == false then return nil end
	return v
end

--- 显式失效（写操作后调用，让同请求内后续读取看到新值）
function M.invalidate(key)
	if key then
		_cache[key] = nil
	else
		_cache = {}
	end
end

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

--- 一次性采集全部监听端口表
--
-- 性能要点（v0.11.1）：原实现每次 port_owner() 都起一个 netstat 进程，
-- 而 chain_snapshot 要查 4 个端口、页面又调 2 次 chain_snapshot
-- → 8 个 netstat 进程（单次 20ms）。改为「跑一次 netstat，
-- 把结果解析成 { ["udp:53"] = "1234" } 表」，后续全部查表。
--
-- 用 -lntup 一次同时拿到 TCP 与 UDP（BusyBox netstat 支持组合标志），
-- 比分别跑 -lnup / -lntp 少一半进程。
function M.listen_table()
	return cached("listen_table", function()
		local out = sys.exec("netstat -lntup 2>/dev/null") or ""
		local tbl = {}

		-- BusyBox netstat 的行形如（注意 Proto 是**小写**）：
		--   tcp        0      0 192.168.3.254:53   0.0.0.0:*   LISTEN  16800/dnsmasq
		--   udp        0      0 127.0.0.1:5353     0.0.0.0:*           17071/dnsproxy
		--   tcp6       0      0 :::80              :::*        LISTEN  1590/uhttpd
		--
		-- ⚠️ 两个实测踩过的坑（v0.11.1）：
		--   1. Proto 是 **小写**。原先写 `^(%u%l%l)`（首字母大写）匹配不到任何行，
		--      导致所有端口都被判成「未监听」—— 页面上所有组件变红 ✗，
		--      而服务其实全在跑。这是最危险的一类 bug：看起来像全线故障。
		--   2. UDP 行没有 State 列（LISTEN 只在 TCP 出现），所以不能固定列数，
		--      要用「最后一个是 PID/名字」的取法。
		for line in out:gmatch("[^\n]+") do
			-- 小写 proto（tcp/udp，可能带 6 后缀）
			local proto, addr, rest = line:match("^(%a%a%a%d?)%s+%d+%s+%d+%s+(%S+)%s+%S+%s+(.+)$")
			if proto and addr then
				proto = proto:lower():gsub("6$", "")
				local port = addr:match(":(%d+)$")
				if port then
					-- rest 里可能是 "LISTEN  17071/dnsproxy" 或 "17071/dnsproxy" 或 "-"
					local pid = rest:match("(%d+)/") or rest:match("(%d+)%s*$")
					local key = proto .. ":" .. port
					if not tbl[key] or (pid and tbl[key] == "") then
						tbl[key] = pid or ""
					end
				end
			end
		end
		return tbl
	end) or {}
end

--- 端口监听者 PID
function M.port_owner(port, proto)
	proto = (proto or "udp"):lower()
	local tbl = M.listen_table()
	return tbl[proto .. ":" .. tostring(port)] or ""
end

--- 端口是否被监听
function M.port_listening(port, proto)
	return M.port_owner(port, proto) ~= ""
end

--- 该 PID 是否是框架的 dnsproxy
--
-- v0.10.0：从 is_framework_filter（检测 chinadns-ng）改为检测 dnsproxy。
-- 框架现在托管**两个** dnsproxy 实例（国内 :5353、国外 :5336），
-- 两者都是 /usr/bin/dnsproxy，故只需匹配二进制名。
function M.is_dnsproxy(pid)
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
	return cmd:find("dnsproxy") ~= nil
end

--- 读取 ss_spec_output 的 TCP 端口集
function M.output_ports()
	local out = sys.exec("nft list chain inet ss_spec ss_spec_output 2>/dev/null | sed -n 's/.*tcp dport { \\([^}]*\\) }.*/\\1/p' | head -1") or ""
	out = out:gsub("%s+", "")
	return out
end

--- 从上游 URL 抽端口
--
-- ⚠️ 必须防御非字符串入参。
-- 实测（2026-10-22）：保存页面时报 500，
--   dnschain.lua:95: attempt to call method 'match' (a nil value)
-- 根因是 uci:foreach 返回的 sec.server 在多值 list 时是 table，
-- 而 DynamicList 的 validate 收到的 value 也可能是 table。
-- 旧代码直接 url:match() 就崩了 —— 页面「保存并应用」整体 500。
function M.upstream_port(url)
	if type(url) ~= "string" or url == "" then
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
--
--- urls 里可能混入 table（uci list 值）与 nil，统一在这里摊平。
function M.validate_upstreams(urls)
	local ports = M.output_ports()
	if ports == "" then
		-- nft 尚未就绪时不阻断
		return true, {}
	end

	-- 摊平：接受 string / table / nil 的任意混合
	local flat = {}
	local function push(v)
		if type(v) == "string" then
			if v ~= "" then flat[#flat + 1] = v end
		elseif type(v) == "table" then
			for _, x in ipairs(v) do push(x) end
		end
	end
	for _, u in ipairs(urls or {}) do push(u) end

	local bad = {}
	for _, u in ipairs(flat) do
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
--
-- 性能要点（v0.11.1）：原实现每个文件起一次 `wc -l`、再起一次 `date -r`，
-- 共 4 个进程。改为纯 Lua 读文件数行（这些文件都在 page cache 里，
-- 实测 35630 行的文件数行耗时 < 10ms），完全不 fork。
function M.list_stats()
	return cached("list_stats", function()
		local stats = {}

		-- 纯 Lua 数行：只数 \n，不构造行数组（35630 行时省内存也更快）
		local function count(path)
			local f = io.open(path, "r")
			if not f then
				return 0
			end
			local data = f:read("*a") or ""
			f:close()
			local n = 0
			for _ in data:gmatch("\n") do n = n + 1 end
			-- 最后一行没有换行符时补 1
			if data ~= "" and data:sub(-1) ~= "\n" then n = n + 1 end
			return n
		end

		stats.gfw_lines = count("/etc/ssrplus/gfw_list.conf")
		stats.base_lines = count("/etc/ssrplus/gfw_base.conf")
		-- v0.10.0：分流规则由 dnsmasq 承担，文件名为 foreign-split.conf
		stats.domains = count("/var/etc/dnschain/foreign-split.conf")

		-- 修改时间：BusyBox 的 stat 不支持 -c（实测报错），改用 date -r。
		-- 这一次保留外部命令（Lua 无 stat mtime 接口），但只在缓存未命中时跑一次。
		local mt = sys.exec("date -r /etc/ssrplus/gfw_list.conf '+%Y-%m-%d %H:%M' 2>/dev/null") or ""
		stats.updated = (mt:gsub("%s+$", ""))
		return stats
	end)
end

--- 缓存统计（dnsmasq metrics）
function M.cache_stats()
	return cached("cache_stats", function()
		local out = sys.exec("ubus call dnsmasq metrics 2>/dev/null") or ""
		local stats = {}
		for k, v in out:gmatch('"([%w_]+)"%s*:%s*(%d+)') do
			stats[k] = tonumber(v)
		end
		return stats
	end)
end

--- nft 集合的元素数
--
-- blacklist = 国外域名的解析结果（由 dnsmasq 的 nftset= 写入）
-- china     = SSR-Plus 维护的国内 IP 段
--
-- 性能要点（v0.11.1）：`nft list set china` 有 2025 个 CIDR，
-- 单次 120ms。缓存后同一请求内只跑一次。
function M.set_count(name)
	return cached("set_count:" .. name, function()
		local out = sys.exec(
			"nft list set inet ss_spec " .. name .. " 2>/dev/null " ..
			"| grep -cE '([0-9]{1,3}\\.){3}[0-9]{1,3}'") or "0"
		return tonumber((out:gsub("%s+", ""))) or 0
	end) or 0
end

--- 链路快照：链路图与图表都从这里取数，一次采齐
--
-- 全部字段都是「实测值」，取不到时给 nil，由视图层显示「—」，
-- 不编造 0（0 与「未知」是两件事）。
function M.chain_snapshot()
	return cached("chain_snapshot", function()
		local entry = M.entry_port()
		local fport = M.foreign_port()
		local v6 = M.ssr_ipv6()
		local cs = M.cache_stats()

		local function listening(port, proto)
			return M.port_owner(port, proto or "udp") ~= ""
		end

		-- 分流条数复用 list_stats 的结果（它已缓存，且用的是纯 Lua 数行）
		local split_lines = M.list_stats().domains or 0

		return {
			-- 组件存活
			dnsmasq      = listening("53", "udp"),
			dnsproxy_cn  = listening(entry, "udp"),
			dnsproxy_fg  = listening(fport, "udp"),
			proxy_1234   = listening("1234", "tcp"),
			ipv6_proxy   = (v6 == "1"),

			-- 端口与规模
			entry_port   = entry,
			foreign_port = fport,
			split_count  = split_lines,
			blacklist    = M.set_count("blacklist"),
			china        = M.set_count("china"),

			-- dnsmasq 计数
			inserted     = cs.dns_cache_inserted,
			forwarded    = cs.dns_queries_forwarded,
			local_ans    = cs.dns_local_answered,
			unanswered   = cs.dns_unanswered,

			-- AAAA 状态
			aaaa_pref    = M.ssr_filter_aaaa(),
			aaaa_eff     = M.dnsmasq_filter_aaaa(),
		}
	end)
end

------------------------------------------------------------------------
-- 动作（供页面按钮调用）
------------------------------------------------------------------------

--- 清空缓存：SIGHUP，零中断
-- 清空 dnsmasq 缓存
--
-- ⚠️ 必须委托给 `dnschain-health flush`，不要在 Lua 侧自己找 PID
--    （v0.14.2 实测修正）。
--
--    原实现是 `pidof dnsmasq | awk '{print $1}'` —— 而 `pidof dnsmasq`
--    返回 **3 个** PID，第一个是 **ujail 辅助子进程**：
--        PID 21400  wchan=anon_pipe_read  fds=5   socket:53=0   ← 被选中
--        PID 21368  wchan=poll_schedule…  fds=36  socket:53=25  ← 真正干活的
--        PID 21331  wchan=do_epoll_wait   fds=7   socket:53=1
--    对 21400 发 SIGHUP 是**空操作**，按钮点了完全无效，
--    但页面照样报「已清空 dnsmasq 缓存（零中断）」—— 静默失效。
--
--    库里的 dc_flush_cache 用 dc_dnsmasq_pid 按 :53 socket inode 反查，
--    是正确实现；此前它没有 CLI 入口，成了死代码。现在补了
--    `dnschain-health flush` 子命令，Lua 只调它，两边不再各写一份。
function M.flush_cache()
	local out = sys.exec("/usr/bin/dnschain-health flush 2>&1") or ""
	if out:find("OK=") then
		return true, out:gsub("^%s*OK=", ""):gsub("%s+$", "")
	end
	local err = out:match("ERROR=([^\n]*)")
	return false, err or "清空缓存失败（检查 dnsmasq 是否运行）"
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
--
-- 性能要点（v0.11.1）：selftest 单次实测 1370ms（它内部要跑 6+ 条 DNS 查询、
-- nft/netstat 探测、配置比对）。页面里「当前状态」与「自检表格」两处都要它，
-- 原来各跑一次 → 2740ms，占整页 7.4 秒的 37%。
--
-- 加请求级缓存后只跑一次。**注意**：不能用长 TTL 缓存 ——
-- 自检结果要反映「此刻」的状态，用户点「一键自检」按钮必须看到新结果，
-- 所以按钮回调里会显式 invalidate("selftest")。
function M.selftest()
	return cached("selftest", function()
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
			-- 视图层要显示 SKIP 与总数，这里一并给出（原来只有 pass）
			skip = (function()
				local _, _, sk = out:match("SUMMARY PASS=(%d+) FAIL=(%d+) SKIP=(%d+)")
				return sk and tonumber(sk) or 0
			end)(),
			total = #items,
			conclusion = conclusion or "",
			raw = out,
		}
	end)
end

--- IP 集与各数据库的一致性核对
--
-- 用户要求核对「代理 IP 集 175 个」与 SSR-Plus 各数据库是否一致。
-- 实测结论（2026-10-22）：
--
--   GFW 列表       17804 域名  ← /tmp/dnsmasq.d/.../gfw_list.conf
--                              源 gfw_list.conf 每域名占 2 行（server= + ipset=），
--                              故源文件 35608 行 = 17804 × 2，两者一致
--   大陆 IP 段     8612 CIDR   ← /etc/ssrplus/china_ssr.txt
--   国内 IPv6      1019 CIDR   ← /etc/ssrplus/china6_ssr.txt
--   代理 IP 集     动态值      ← nft set blacklist，由 dnsmasq nftset= 写入
--
-- 「代理 IP 集 175」不是固定配置：它是运行时累加的。每次解析出一个新的
-- 国外域名 IP，dnsmasq 就把它加进 blacklist。同一台机器上先后观测到
-- 148 / 157 / 169 / 175 / 193 / 198 —— 随访问的国外站点增多而增长。
-- 所以核对的目标不是「等于 175」，而是：
--   ① 它只装 gfw 域名的解析结果（不混入国内 IP）
--   ② 条目数随访问增长（说明 nftset 在工作）
--   ③ 各源数据库行数与 SSR-Plus 的一致
function M.ipset_audit()
	return cached("ipset_audit", function()
		local function lines(path)
			local f = io.open(path, "r")
			if not f then return nil end
			local data = f:read("*a") or ""
			f:close()
			local n = 0
			for _ in data:gmatch("\n") do n = n + 1 end
			if data ~= "" and data:sub(-1) ~= "\n" then n = n + 1 end
			return n
		end

		-- GFW 域名数：复用 list_stats 已算好的结果。
		--
		-- 性能要点（v0.12.0）：原先这里重新扫一遍 gfw_list.conf（17804 行）
		-- 与 gfw_src 的 35608 行读取 —— 同一个文件被读两次，实测多花 ~90ms。
		-- 现在 gfw_src 直接取 list_stats.gfw_lines，不重复读。
		local st = M.list_stats()

		return {
			gfw_domains = st.domains,
			gfw_src     = st.gfw_lines,
			china_src   = lines("/etc/ssrplus/china_ssr.txt"),
			china6_src  = lines("/etc/ssrplus/china6_ssr.txt"),
		}
	end)
end

--- uci 单值读取（带缓存）
--
-- 性能要点（v0.11.1）：每次 sys.exec("uci -q get ...") 都是一次 fork。
-- 页面里 ssr_mode / ssr_ipv6 / ssr_filter_aaaa / dnsmasq_filter_aaaa /
-- entry_port / foreign_port 各被读多次（chain_snapshot 与 _ports 行都读），
-- 累计 10+ 次 fork。统一走缓存。
local function uci_get(key)
	return cached("uci:" .. key, function()
		return (sys.exec("uci -q get " .. key .. " 2>/dev/null") or ""):gsub("%s+", "")
	end) or ""
end

--- 当前 SSR-Plus DNS 模式
function M.ssr_mode()
	return uci_get("shadowsocksr.@global[0].pdnsd_enable")
end

--- 当前 SSR-Plus 的 IPv6 流量代理开关
function M.ssr_ipv6()
	return uci_get("shadowsocksr.@global[0].ipv6_support")
end

--- SSR-Plus 的 AAAA 抑制「用户偏好」值
--
-- ⚠️ 这不是实际生效值。ipv6_support=1 时 SSR-Plus 会覆盖它。
-- 判据要读 M.dnsmasq_filter_aaaa()。
function M.ssr_filter_aaaa()
	return uci_get("shadowsocksr.@global[0].filter_aaaa")
end

--- dnsmasq 的 AAAA 抑制「实际生效」值
--
-- 实测（2026-10-22）：shadowsocksr.filter_aaaa=1 而本值=0，
-- 因为 ipv6_support=1 时 get_filter_aaaa() 强制返回 0。
function M.dnsmasq_filter_aaaa()
	return uci_get("dhcp.@dnsmasq[0].filter_aaaa")
end

--- 把用户偏好同步到 dnsmasq 的生效值
--
-- 复刻 SSR-Plus 的 set_ipv6_dns_filter() 逻辑，但不重启 shadowsocksr
-- （那会断代理 3–10 秒）。规则：
--   ipv6_support=1  → dnsmasq.filter_aaaa 必须为 0（强制保留 AAAA）
--   否则            → dnsmasq.filter_aaaa 跟随用户偏好
--
-- 返回 (ok, message)
function M.sync_dnsmasq_filter_aaaa()
	local v6 = M.ssr_ipv6()
	local pref = M.ssr_filter_aaaa()
	local target

	if v6 == "1" then
		target = "0"
	else
		target = (pref == "1") and "1" or "0"
	end

	local cur = M.dnsmasq_filter_aaaa()
	if cur == target then
		return true, nil
	end

	sys.exec("uci -q set dhcp.@dnsmasq[0].filter_aaaa='" .. target .. "' && uci -q commit dhcp")
	-- 必须 restart 而非 reload：实测 reload（SIGHUP）不重读 conf-dir，
	-- 而 filter_aaaa 是写进 /var/etc/dnsmasq.conf.* 的
	sys.exec("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
	-- 写后失效相关缓存，让同请求内后续读取看到新值
	M.invalidate()
	return true, target
end

--- 国外 dnsproxy 实例端口（v0.10.0 取代 filter_port）
function M.foreign_port()
	local p = uci_get("dnschain.main.foreign_port")
	return (p ~= "") and p or "5336"
end

--- 国内 dnsproxy 实例端口
function M.entry_port()
	local p = uci_get("dnschain.main.entry_port")
	return (p ~= "") and p or "5353"
end

-----------------------------------------------------------------------
-- 域名归属 / 自定义列表 / 链路健康（v0.13.0）
--
-- 这一层只做「读运行时产物 + 调脚本」，**不自己重新实现判定逻辑**。
-- 归属与改道的真相在 /usr/share/dnschain/dnschain.sh 与
-- /usr/bin/dnschain-health 里，页面重复实现一份必然漂移 ——
-- 而「页面显示 A、实际干 B」是这类配置页最难排查的故障。
-----------------------------------------------------------------------

--- 运行时目录
M.run_dir = "/var/etc/dnschain"
M.state_dir = "/var/run/dnschain"

--- 读一个纯文本列表文件（每行一条，去空行、去注释）
--
-- 注意：**不能**给 for 的循环变量赋值。Lua 5.4 起 for 的控制变量是
-- const（lupa/新固件上会直接报 "attempt to assign to const variable"），
-- 而本固件是 5.1、桌面验证环境是 5.4 —— 两种都要能跑，
-- 故另起一个变量接结果。
local function read_lines(path)
	local f = io.open(path, "r")
	if not f then return {} end
	local out = {}
	for raw in f:lines() do
		local s = raw:gsub("^%s+", ""):gsub("%s+$", "")
		if s ~= "" and s:sub(1, 1) ~= "#" then
			out[#out + 1] = s
		end
	end
	f:close()
	return out
end
M.read_lines = read_lines

--- 自定义列表（已规范化，由脚本落盘）
function M.custom_domestic()
	return cached("custom_domestic", function()
		return read_lines(M.run_dir .. "/custom-domestic.txt")
	end) or {}
end

function M.custom_foreign()
	return cached("custom_foreign", function()
		return read_lines(M.run_dir .. "/custom-foreign.txt")
	end) or {}
end

--- UCI 里的原始自定义列表（用户刚改、还没 apply 时以它为准）
--
-- 页面要同时显示「已保存的」与「已生效的」两份：
-- 只显示后者时，用户点保存后看不到变化（因为要等 apply）；
-- 只显示前者时，看不出 apply 是否真的成功了。
function M.uci_list(section, option)
	return cached("ucilist:" .. section .. "." .. option, function()
		local out = {}
		local f = io.popen("uci -q get dnschain." .. section .. "." .. option .. " 2>/dev/null")
		if not f then return out end
		local data = f:read("*a") or ""
		f:close()
		for tok in data:gmatch("%S+") do
			out[#out + 1] = tok
		end
		return out
	end) or {}
end

--- 观测列表（UCI 原值；为空时脚本会回落到内置基准集）
function M.watch_list()
	return M.uci_list("health", "watch")
end

--- 健康状态行
--
-- 返回 { {domain, class, pref, active, fail, ok, last, result, state}, ... }
-- 字段顺序与 dnschain-health status 的 ROW 行一一对应。
--
-- ⚠️ 与 health_summary 共用**同一次** status 调用（v0.14.1 性能修正）。
--
--   原来 health_rows 与 health_summary 各自 `sys.exec("dnschain-health status")`
--   一次，而该命令实测耗时 1.67 秒（它要遍历 /proc 找守护进程、
--   读 health.state、逐域名算归属）。页面两处都用 → **白跑两遍**。
--
--   现在两者都从 health_status_raw() 取，那个函数自带缓存，
--   整个请求只执行一次。实测页面总耗时从 5.6s 降到约 3.9s。
local function health_status_raw()
	return cached("health_status_raw", function()
		return sys.exec("/usr/bin/dnschain-health status 2>/dev/null") or ""
	end) or ""
end

function M.health_rows()
	return cached("health_rows", function()
		local out = health_status_raw()
		local rows = {}
		for raw in out:gmatch("[^\n]+") do
			local payload = raw:match("^ROW%s+(.+)$")
			if payload then
				-- 用 gmatch 按 | 切分；Lua 的 split 没有标准实现，
				-- 这里手工展开，避免引入 luci.util.split 的版本差异
				local f = {}
				for part in (payload .. "|"):gmatch("([^|]*)|") do
					f[#f + 1] = part
				end
				if #f >= 9 then
					rows[#rows + 1] = {
						domain = f[1],
						class  = f[2],
						pref   = f[3],
						active = f[4],
						fail   = tonumber(f[5]) or 0,
						ok     = tonumber(f[6]) or 0,
						last   = tonumber(f[7]) or 0,
						result = f[8],
						state  = f[9],
					}
				end
			end
		end
		return rows
	end) or {}
end

--- 健康汇总
function M.health_summary()
	return cached("health_summary", function()
		local out = health_status_raw()
		local line = out:match("SUM%s+([^\n]+)") or ""
		local s = {}
		for k, v in line:gmatch("(%w+)=(%d+)") do
			s[k] = tonumber(v)
		end
		return s
	end) or {}
end

--- 单域名解释（页面「思维链路图」用它把判定摊开）
--
-- 返回 key => value 的表。脚本输出 KEY=VALUE，缺字段就是取不到。
--
-- 参数必须 shell 转义：域名经 shell 传给脚本，含空格/引号时会变成
-- 多个参数甚至命令注入。用「单引号包裹 + 内部单引号转义」是最稳妥的
-- POSIX 写法，不依赖 luci 的 util.shellquote（版本差异较大）。
function M.shell_quote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.explain(domain)
	if type(domain) ~= "string" or domain == "" then
		return {}
	end
	local out = sys.exec("/usr/bin/dnschain-health explain " .. M.shell_quote(domain) ..
		" 2>/dev/null") or ""
	local t = {}
	for raw in out:gmatch("[^\n]+") do
		local k, v = raw:match("^([A-Z_]+)=(.*)$")
		if k then t[k] = v end
	end
	return t
end

--- 运行一轮健康检测（页面按钮）
function M.health_cycle()
	local out = sys.exec("/usr/bin/dnschain-health cycle 2>&1") or ""
	M.invalidate()
	return out
end

--- 应用自定义列表（重建派生文件 + 重启 dnsmasq）
function M.apply_domains()
	local out = sys.exec("/usr/bin/dnschain-health apply 2>&1") or ""
	M.invalidate()
	return out
end

--- 清空改道状态
function M.reset_health()
	local out = sys.exec("/usr/bin/dnschain-health reset 2>&1") or ""
	M.invalidate()
	return out
end

--- 自定义列表校验（返回 ok, 明细文本）
function M.check_domains()
	local out = sys.exec("/usr/bin/dnschain-health check 2>&1") or ""
	local ok = out:match("^OK") ~= nil or out:match("\nOK$") ~= nil
	return ok, out
end

--- dnsmasq 是否已带 --servers-file（改道通道是否就绪）
--
-- 只设了 UCI 不生效：必须验运行进程的实际参数。
-- 这是「改道看起来成功、实际没生效」的唯一可靠判据。
--- 改道通道是否就绪
--
-- 判据必须查**生效的 dnsmasq 配置文件**，不能只看进程 argv
-- （v0.13.0 路由器实测修正）。
--
-- OpenWrt 的 init.d/dnsmasq 是
--   `append_parm "$cfg" "serversfile" "--servers-file"`
-- 它把这个选项写进 /var/etc/dnsmasq.conf.*，**不放在命令行上**。
-- 实测 dnsmasq 的 cmdline 只有：
--   /usr/sbin/dnsmasq -C /var/etc/dnsmasq.conf.cfg01411c -k -x ...
-- 而 `servers-file=` 出现在该配置文件第 21 行。
-- 按 argv 判定会永远报「未就绪」，而通道其实是好的 ——
-- 页面于是显示「改道通道未就绪」，用户会去排查一个不存在的故障。
--
-- 三条判据：
--   a) UCI 配了路径
--   b) 文件存在（且 dnsmasq 读得到 —— ujail 白名单见下）
--   c) 生效的 dnsmasq 配置文件里真有 servers-file 指向它
function M.serversfile_ready()
	return cached("serversfile_ready", function()
		local uci_sf = uci_get("dhcp.@dnsmasq[0].serversfile")
		if uci_sf == "" then
			return { ready = false, reason = "uci-missing", path = "" }
		end

		if not fs.access(uci_sf) then
			return { ready = false, reason = "file-missing", path = uci_sf }
		end

		-- c) 生效的 dnsmasq 配置里有没有指向它的 servers-file
		local conf_found = false
		local conf_glob = io.popen("ls /var/etc/dnsmasq.conf.* 2>/dev/null")
		if conf_glob then
			for path in conf_glob:lines() do
				local f = io.open(path, "r")
				if f then
					local body = f:read("*a") or ""
					f:close()
					-- 精确匹配整行，避免 servers-file=/a 命中 /ab
					if body:find("servers%-file=" .. uci_sf:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "\n") then
						conf_found = true
						break
					end
				end
			end
			conf_glob:close()
		end

		if not conf_found then
			return { ready = false, reason = "conf-missing", path = uci_sf }
		end

		-- b2) ujail 是否允许 dnsmasq 读这个目录
		--
		-- dnsmasq 由 ujail 降权到 uid 453 运行，只能看到 init 脚本里
		-- `procd_add_jail_mount` 声明过的路径。servers-file 指向白名单
		-- 之外的目录时**既不报错也不生效** —— 最隐蔽的一种失效。
		local pid = M.port_owner("53", "udp")
		if pid == "" then
			return { ready = false, reason = "no-dnsmasq", path = uci_sf }
		end

		local ppid = ""
		local st = io.open("/proc/" .. pid .. "/status", "r")
		if st then
			for line in st:lines() do
				local p = line:match("^PPid:%s*(%d+)")
				if p then ppid = p; break end
			end
			st:close()
		end

		if ppid ~= "" then
			local cf = io.open("/proc/" .. ppid .. "/cmdline", "r")
			if cf then
				local cmd = (cf:read("*a") or ""):gsub("%z", "\n")
				cf:close()
				local jail_dir = uci_sf:match("^(.*)/[^/]+$") or ""
				if jail_dir ~= "" then
					local found = false
					for line in cmd:gmatch("[^\n]+") do
						-- ujail 的挂载参数带尾斜杠（procd_add_jail_mount_rw /var/run/dnsmasq/）
						local norm = line:gsub("/+$", "")
						if norm == jail_dir then found = true; break end
					end
					if not found then
						return { ready = false, reason = "jail-blocked", path = uci_sf }
					end
				end
			end
		end

		return { ready = true, reason = "", path = uci_sf }
	end)
end

--- 健康守护进程状态（页面要显示「自动改道是否在跑」）
--
-- 为什么需要：守护进程由 procd 托管（`procd_open_instance "health"`），
-- 页面原来完全没有它的任何痕迹 —— 用户改了阈值、开了开关，
-- 却无法确认「它到底有没有在跑」。开关显示「已启用」而守护进程
-- 没起来时，自动改道**完全不发生**，且没有任何提示。
function M.health_daemon()
	return cached("health_daemon", function()
		local enabled = uci_get("dnschain.health.enabled")
		if enabled == nil or enabled == "" then enabled = "1" end

		local interval = uci_get("dnschain.health.interval") or "60"

		-- 找 procd 实例：遍历 /proc 找 `dnschain-health daemon`
		local pid, uptime = "", ""
		local d = io.popen("ls -d /proc/[0-9]* 2>/dev/null")
		if d then
			for p in d:lines() do
				local n = p:match("^/proc/(%d+)$")
				if n then
					local f = io.open(p .. "/cmdline", "r")
					if f then
						local cmd = (f:read("*a") or ""):gsub("%z", " ")
						f:close()
						if cmd:find("dnschain%-health") and cmd:find("daemon") then
							pid = n
							local sf = io.open(p .. "/stat", "r")
							if sf then
								local line = sf:read("*l") or ""
								sf:close()
								local start = line:match("^%d+ %S+ %S+ %d+ %d+ %d+ %d+ %d+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (%d+)")
								if start then uptime = start end
							end
							break
						end
					end
				end
			end
			d:close()
		end

		-- 上次探测时间（从状态文件里取最大的 last）
		local last = 0
		local f = io.open("/var/run/dnschain/health.state", "r")
		if f then
			for line in f:lines() do
				local t = line:match("|(%d+)|[^|]*$")
				if t then
					t = tonumber(t)
					if t and t > last then last = t end
				end
			end
			f:close()
		end

		local now = os.time()
		local age = (last > 0) and (now - last) or -1

		return {
			enabled  = (enabled == "1"),
			running  = (pid ~= ""),
			pid      = pid,
			interval = tonumber(interval) or 60,
			last_run = last,
			age      = age,
		}
	end)
end

--- watch.servers 的实际内容（用于「当前改道生效情况」核对）

--- 静态分流片段的条数（不含注释）
--
-- 为什么要 pcall 包一层：io.lines 在文件不存在时**抛错**而不是返回 nil，
-- 而这里的调用点位于页面渲染路径上 —— 未装框架、文件尚未生成时
-- 会直接 500，用户看到的是「页面打不开」而不是「还没有数据」。
function M.split_rule_count()
	return cached("split_rule_count", function()
		local n = 0
		local ok = pcall(function()
			for _ in io.lines("/tmp/dnsmasq.d/dnschain-split.conf") do
				n = n + 1
			end
		end)
		if not ok then return 0 end
		return n
	end) or 0
end

return M
