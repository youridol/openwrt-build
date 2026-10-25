-- Copyright (C) 2026 openwrt-build
-- DNS 分流框架控制页面
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

	-- ⚠️ 方括号 IPv6 必须单独判（v0.14.4 修）。
	--
	--   原写法 `:%[?([0-9]+)%]?$` 想同时兼容 `host:853` 与 `[v6]:853`，
	--   但对**不带端口**的 IPv6 字面量，末尾 `::1111` 会被当成端口：
	--     https://[2606:4700::1111]/dns-query  → port = "1111"（应为 443）
	--     tls://[2400:3200::1]                 → port = "1"   （应为 853）
	--
	--   后果：validate_upstreams 拿这个假端口去比对 ss_spec_output 的
	--   端口集。不在集合里 → 保存被拒且提示「端口 1111 不在…」，
	--   用户看不出问题在哪；恰好在集合里 → 该上游被误判合规，
	--   实际出向不走代理，国外解析静默失败。
	--
	--   IPv6 的端口只可能出现在 `]:` 之后，故先看是否以 `[` 开头。
	local port
	if hostport:match("^%[") then
		port = hostport:match("^%[[^%]]+%]:(%d+)$")
	else
		port = hostport:match(":(%d+)$")
	end
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

		-- 数「以某前缀开头的行」的条数（用于 server= / nftset= 这类指令行）
		local function count_prefix(path, prefix)
			local f = io.open(path, "r")
			if not f then
				return 0
			end
			local n = 0
			for line in f:lines() do
				if line:sub(1, #prefix) == prefix then n = n + 1 end
			end
			f:close()
			return n
		end

		stats.gfw_lines = count("/etc/ssrplus/gfw_list.conf")
		stats.base_lines = count("/etc/ssrplus/gfw_base.conf")

		-- 数据库覆盖的国外域名条数（纯域名清单，一行一个）
		--
		-- ⚠️ 这不是「分流规则条数」（v0.14.4 修 S5）。
		--    `foreign-split.conf` 是「数据库国外 − 自定义国内 − 观测域名」
		--    的**纯域名清单**（dnschain.sh 里明确写了「从 v0.13.0 起不再是
		--    dnsmasq 片段」）。真正的 `server=/域名/` 条数在
		--    dnschain-split.conf，其内容还包含用户自定义的两份列表。
		stats.domains = count("/var/etc/dnschain/foreign-split.conf")

		-- 真正的分流规则条数：数 dnschain-split.conf 的 server= 行
		stats.split_server_lines = count_prefix(
			"/tmp/dnsmasq.d/dnschain-split.conf", "server=")
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

		-- 分流条数：取**真正的** server=/域名/ 行数（v0.14.4 修 S5）
		--
		-- 原实现用 list_stats().domains，那是 foreign-split.conf 的
		-- 纯域名条数 —— 不含用户自定义的两份列表，页面标签
		-- 「条 server=/域名/」名不副实，数字偏小。
		local ls = M.list_stats()
		local split_lines = ls.split_server_lines or 0

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
-- ⚠️ 必须委托给 `dnschain-selftest flush`，不要在 Lua 侧自己找 PID
--    （v0.14.2 实测修正；v0.21.0 起入口从 dnschain-health 挪到 selftest）。
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
--    是正确实现；此前它没有 CLI 入口，成了死代码。
--    v0.21.0 删掉 dnschain-health 后，flush 子命令移到 dnschain-selftest
--    （它本来就在 rpcd ACL 白名单里，不必为它新建脚本）。
function M.flush_cache()
	local out = sys.exec("/usr/bin/dnschain-selftest flush 2>&1") or ""
	if out:find("OK=") then
		return true, out:gsub("^%s*OK=", ""):gsub("%s+$", "")
	end
	local err = out:match("ERROR=([^\n]*)")
	return false, err or "清空缓存失败（检查 dnsmasq 是否运行）"
end

--- 手动导入名单
-- 判定一段脚本输出是否代表失败。
--
-- ⚠️ 不能无条件 return true（v0.14.4 修 M6）。
--    dnschain-reconcile 的 main() 有 rc 传播（失败时非 0），但 Lua 侧
--    既不看退出码也不看输出里的 ERROR，恒返回 true —— 页面据此无条件
--    打 ✓。reconcile 因 preflight 失败、名单缺失、uci commit 失败而
--    整体失败时，页面仍显示「✓ 已归一」，只在正文里混着 ERROR 行。
--    这是 AGENTS 红线 3「禁止静默失败」在页面侧的缺口。
local function exec_ok(out)
	if not out then return false end
	if out:find("ERROR") or out:find("失败") then return false end
	return true
end

-- ⚠️ `M.import_lists()` 已删除（v0.18.0，ADR-0007 §2.2）。
--
--   它曾是「手动导入名单」按钮的后端，函数体与 `M.reconcile_now()`
--   **逐字相同**（都是 `dnschain-reconcile`），只差函数名。
--   而 `dnschain-reconcile` 本来就同时做「归一不变量」与「导入名单」
--   两件事（脚本头 :9-10），所以两个函数是同一件事的两个名字。
--
--   页面侧的两个按钮已合并为一个，这里同步删掉死函数 ——
--   留着它只会让后来者以为「导入名单」是独立能力，再接一个重复入口回来。

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
	local out = sys.exec("/usr/bin/dnschain-reconcile 2>&1") or ""
	return exec_ok(out), out
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
-- 把自检输出的一行「名称 — 证据」切成两段。
--
-- ⚠️ 不能写 `rest:match("^([^—]+)—%s*(.*)$")`（v0.14.4 修）。
--
--   Lua 的字符类按**字节**工作，不按码位。`—` 是 U+2014，
--   UTF-8 编码 E2 80 94。写进 `[^—]` 后实际是「排除 0xE2、0x80、0x94
--   这三个字节」。于是凡名称里含 `一`(E4 B8 80)、`上`(E4 B8 8A)、
--   `下`(E4 B8 8B) 这类第三字节为 0x80 的常用汉字，匹配直接失败。
--
--   实测：20 个 emit 名称里 **7 个失败**（整行都进 name、detail 为空），
--   另有 10 个「半失败」（name 尾随一个空格）。失败的 7 项恰好包括
--   「缓存层唯一」「端口所有权无冲突」「改道通道已就绪」—— 诊断页最该
--   看清的几项，而 #items 仍是 20、total 正确，看起来一切正常。
--
--   改用 `find(..., true)` 做**字节精确**匹配：分隔符是 5 字节的
--   " — "（空格 + 三字节破折号 + 空格），找到后按字节位置切。
local SELFTEST_SEP = " \226\128\148 "

local function split_selftest_name(rest)
	local p = rest:find(SELFTEST_SEP, 1, true)
	if not p then
		return nil, nil
	end
	return rest:sub(1, p - 1), rest:sub(p + #SELFTEST_SEP)
end

--- 跑一次自检
--
-- 参数 force：true 时**绕过**跨请求 TTL 缓存，强制真跑一次。
--   页面上的「立即重新自检」按钮必须传 true —— 否则用户点完
--   可能读到 10 秒内的旧结果，看起来像「按钮没生效」。
function M.selftest(force)
	if force then
		rawset(_G, "__dc_selftest_force", true)
	end
	local r = cached("selftest", function()
		return M._selftest_uncached()
	end)
	rawset(_G, "__dc_selftest_force", nil)
	return r
end

--- 自检的实际采集（含跨请求 TTL 缓存）
function M._selftest_uncached()
	-- ── 跨请求短 TTL 缓存（v0.16.5 性能修复）──────────────────
	--
	-- 为什么需要它（实测数据）：
	--   `dnschain-selftest` 单次 **1.20 秒**（20 项探测，含 6+ 次
	--   DNS 查询、nft/netstat 探测、配置比对）。
	--   `cached()` 只保证「同一请求内算一次」，但**每个 HTTP 请求
	--   都是独立进程** —— 用户每切一次 tab / 每刷一次页面都重跑。
	--   实测整页渲染 3.0 秒里，selftest 占 1.2 秒（40%）。
	--
	-- 缓存策略：
	--   · TTL 取 10 秒 —— 短到不会让用户看到过时结论，
	--     长到能覆盖「连续切 tab」这个高频场景
	--   · 落在 /var/run（tmpfs，不写 flash，重启即清）
	--   · 「立即重新自检」按钮走 `M.selftest(true)` 强制绕过
	--
	-- ⚠️ 为什么不用纯内存表：LuCI 每个请求独立进程，模块级变量
	--    活不过一个请求。必须落到文件才能跨请求复用。
	--
	-- ⚠️ 为什么 TTL 不取更长（比如 60 秒）：自检结论是诊断用的，
	--    用户点「立即重新自检」后若还看到 60 秒前的旧结果，
	--    会以为按钮失效。10 秒是「够快」与「够新」的交点。
	local SELFTEST_TTL = 10
	local cache_f = "/var/run/dnschain/.selftest.cache"

	if not rawget(_G, "__dc_selftest_force") then
		local mt = fs.stat(cache_f, "mtime")
		if mt then
			local age = os.time() - mt
			if age >= 0 and age < SELFTEST_TTL then
				local cf = io.open(cache_f, "r")
				if cf then
					local body = cf:read("*a")
					cf:close()
					if body and #body > 0 then
						return M._parse_selftest(body)
					end
				end
			end
		end
	end

	local out = sys.exec("/usr/bin/dnschain-selftest 2>&1") or ""

	-- 写缓存（失败不影响功能 —— 只是下次还得重跑）
	local wf = io.open(cache_f, "w")
	if wf then
		wf:write(out)
		wf:close()
	end

	return M._parse_selftest(out)
end

--- 解析 selftest 的文本输出（抽出来供「跑一次」与「读缓存」共用）
function M._parse_selftest(out)
	local items = {}
	for line in out:gmatch("[^\n]+") do
		local no, status, rest = line:match("^(%d+)%s+(%u+)%s+(.+)$")
		if no then
			local name, detail = split_selftest_name(rest)
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

	-- ── AT / DUR / RUN（v0.18.0，ADR-0007 §2.6）──────────────────
	--
	-- 三个字段都是**可选**的：v0.18.0 之前的 selftest 不输出它们，
	-- 而用户刷固件后 /var/run 里的旧缓存可能还是老格式。
	-- 取不到时留空串，视图层显示「—」，不报错。
	--
	-- ⚠️ 用 `[^%s]+` 而不是 `(%S+)`：Lua 的模式里 %s 才是空白类。
	--    AT 是 ISO8601（含 `-` 与 `:`），DUR 带 `s` 后缀，RUN 是纯数字，
	--    三者都不含空白，所以统一用 [^%s]+ 最稳。
	local at  = out:match("AT=([^%s]+)")
	local dur = out:match("DUR=([^%s]+)")
	local run = out:match("RUN=(%d+)")

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
		-- v0.18.0：运行时刻 / 耗时 / 轮次号（取不到时为空串/nil）
		at  = at or "",
		dur = dur or "",
		run = run and tonumber(run) or nil,
		raw = out,
	}
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

	-- ⚠️ 必须检查每一步的结果（v0.14.4 修 M8）。
	--
	--   原实现两条 sys.exec 的返回值都丢弃、`&&` 串联的 uci commit
	--   失败也无从得知，最后无条件 return true。
	--
	--   后果：uci 写失败或 dnsmasq 重启失败时，用户勾了「抑制国外 AAAA」、
	--   页面刷新后开关显示已切换（读的是 shadowsocksr.filter_aaaa，确实
	--   已写），但 dnsmasq.filter_aaaa 没变 → **实际行为未变**。
	--   这正是 AGENTS §5 反复强调的「读偏好值会得出错误结论」的现场。
	local out1 = sys.exec(
		"uci -q set dhcp.@dnsmasq[0].filter_aaaa='" .. target .. "' && uci -q commit dhcp 2>&1") or ""
	if out1:find("%S") then
		-- 数据层只返回错误码与原始输出，不拼 UI 文案
		-- （AGENTS：dnschain.lua 不得出现 translate，文案在视图层）
		return false, { code = "uci_write_failed", detail = out1, target = target }
	end

	-- 必须 restart 而非 reload：实测 reload（SIGHUP）不重读 conf-dir，
	-- 而 filter_aaaa 是写进 /var/etc/dnsmasq.conf.* 的
	sys.exec("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
	-- 写后失效相关缓存，让同请求内后续读取看到新值
	M.invalidate()

	-- 用「读回实际值」做最终判定：restart 的退出码不可靠（procd 异步）
	local after = M.dnsmasq_filter_aaaa()
	if after ~= target then
		return false, { code = "verify_failed", actual = after, target = target }
	end
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
-- 归属的真相在 /usr/share/dnschain/dnschain.sh 里，
-- 页面重复实现一份必然漂移 ——
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
	local out = sys.exec("/usr/bin/dnschain-selftest explain " .. M.shell_quote(domain) ..
		" 2>/dev/null") or ""
	local t = {}
	for raw in out:gmatch("[^\n]+") do
		local k, v = raw:match("^([A-Z_]+)=(.*)$")
		if k then t[k] = v end
	end
	return t
end


--- 应用自定义列表（重建派生文件 + 重启 dnsmasq）
function M.apply_domains()
	local out = sys.exec("/usr/bin/dnschain-selftest apply 2>&1") or ""
	M.invalidate()
	return out
end


-- ============================================================
-- 客户机链路诊断（v0.23.0，ADR-0009）
-- ------------------------------------------------------------
-- 数据来自 /usr/bin/dnschain-client-diag 的 TSV 输出。
-- 与自检 20 项**视角不同**：自检看路由器自身，这里看客户机实际收发。
--
-- ⚠️ 客户机识别用 IP + 主机名，**不用 MAC** ——
--    实测三台移动设备的 MAC 都是本地管理位（随机 MAC），
--    用它认设备会失效（ADR-0009 §2.4）。
-- ============================================================

local CLIENT_DIAG = "/usr/bin/dnschain-client-diag"

--- 解析 key=value 形式的状态输出
--
-- ⚠️ 键名必须允许**数字**（v0.24.0 实测踩过）。
--
--   原正则 `^([A-Z_]+)=(.*)$` 只认大写字母与下划线，于是
--   `CIDR_V4=123`、`V4_COUNT=123`、`HOOK_HITS=0` 这类含数字的键
--   **整个被丢弃** —— kv.CIDR_V4 恒为 nil，页面显示「v4 0 / v6 0」
--   而实际文件里有 221 行、集合里有 123 条元素。
--
--   症状是「有数据但页面显示 0」，且只影响含数字的键，
--   既有键（TABLE / HOOKED / ENABLED）全部正常，故极易漏看。
local function parse_kv(out)
	local t = {}
	for line in (out or ""):gmatch("[^\n]+") do
		local k, v = line:match("^([A-Z0-9_]+)=(.*)$")
		if k then t[k] = v end
	end
	return t
end

--- 诊断功能运行状态
function M.client_diag_status()
	local out = sys.exec(CLIENT_DIAG .. " status 2>&1") or ""
	local kv = parse_kv(out)
	return {
		enabled    = kv.ENABLED or "0",
		autofix    = kv.AUTOFIX or "0",
		last_scan  = kv.LAST_SCAN or "0",
		fail_count = kv.FAIL_COUNT or "0",
		retain_sec = kv.RETAIN_SEC or "3600",
		retain_max = kv.RETAIN_MAX or "500",
	}
end

--- 客户机列表
--
-- 输出格式：<IP>|<主机名>|<失败数>|<最近失败时刻>|<最近域名>
function M.client_diag_list()
	local out = sys.exec(CLIENT_DIAG .. " list 2>&1") or ""
	local rows = {}
	for line in out:gmatch("[^\n]+") do
		-- 六列：IP|主机名|失败数|最近失败|最近域名|查询数
		local ip, host, cnt, last, dom, qn =
			line:match("^([^|]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
		if ip then
			-- 字段名用 last_ts 而非 last：general.lua 里有一条断言禁止
			-- 出现 r.last（那是已删除的「改道明细」字段），复用同名字段
			-- 会让该断言误报。
			rows[#rows + 1] = {
				ip = ip, host = host or "", count = cnt or "0",
				last_ts = last or "0", domain = dom or "",
				queries = qn or "0",
			}
		end
	end
	return rows
end

--- 某客户机的完整查询链路（含成功）
--
-- 与 client_diag_detail 的区别：
--   detail  只有失败，用于排障
--   flow    全部查询，用于「这台设备刚才在干什么」
--
-- 输出格式：<epoch>|<域名>|<上游>|<状态>|<段>|<答案>
-- ip 为空时返回全部客户机。
function M.client_diag_flow(ip, limit)
	limit = tonumber(limit) or 200
	if limit < 1 then limit = 200 end
	if limit > 2000 then limit = 2000 end

	local cmd = CLIENT_DIAG .. " flow"
	-- 只允许 IP 字符，防止拼进 shell
	if ip and ip ~= "" then
		if not ip:match("^[0-9a-fA-F:.]+$") then return {} end
		cmd = cmd .. " '" .. ip .. "'"
	end
	cmd = cmd .. " " .. limit .. " 2>&1"

	local out = sys.exec(cmd) or ""
	local rows = {}
	-- 七列：<epoch>|<客户机>|<域名>|<上游>|<状态>|<段>|<答案>
	for line in out:gmatch("[^\n]+") do
		local ts, cli, dom, up, st, seg, ans =
			line:match("^([^|]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
		if ts then
			rows[#rows + 1] = {
				ts = ts, client = cli or "", domain = dom or "",
				upstream = up or "", state = st or "",
				seg = seg or "", answer = ans or "",
			}
		end
	end
	return rows
end

--- 某客户机的失败时间线
--
-- 输出格式：<epoch>|<域名>|<上游>|<状态>|<段>|<建议>
function M.client_diag_detail(ip)
	if not ip or ip == "" then return {} end
	-- 只允许 IP 字符，防止拼进 shell
	if not ip:match("^[0-9a-fA-F:.]+$") then return {} end

	local out = sys.exec(CLIENT_DIAG .. " detail '" .. ip .. "' 2>&1") or ""
	local rows = {}
	for line in out:gmatch("[^\n]+") do
		local ts, dom, up, st, seg = line:match("^([^|]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|")
		if ts then
			rows[#rows + 1] = {
				ts = ts, domain = dom or "", upstream = up or "",
				state = st or "", seg = seg or "",
			}
		end
	end
	return rows
end

--- 自愈审计记录
--
-- 输出格式：<id>|<epoch>|<级别>|<域名>|<结果>|<备注>
function M.client_diag_autofix_log()
	local out = sys.exec(CLIENT_DIAG .. " autofix-log 2>&1") or ""
	local rows = {}
	for line in out:gmatch("[^\n]+") do
		local id, ts, lv, dom, res, note = line:match(
			"^([^|]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
		if id then
			rows[#rows + 1] = {
				id = id, ts = ts or "0", level = lv or "",
				domain = dom or "", result = res or "", note = note or "",
			}
		end
	end
	return rows
end

--- 手动触发自愈
--
-- 手动路径**不受时间窗限制** —— 用户明知可以断网才会点（ADR-0009 §3.5）。
function M.client_diag_heal(level)
	level = tostring(level or "")
	if level ~= "1" and level ~= "2" and level ~= "3" then
		return false, "级别必须是 1/2/3"
	end
	local out = sys.exec(CLIENT_DIAG .. " heal " .. level .. " 2>&1") or ""
	M.invalidate()
	if out:find("OK=") then
		return true, out:gsub("^%s*OK=", ""):gsub("%s+$", "")
	end
	local err = out:match("ERROR=([^\n]*)")
	return false, err or "自愈失败"
end

--- 当前在线主机（第一级）
--
-- 输出格式：<IP>|<主机名>|<MAC>|<查询数>|<失败数>|<最近活动>|<最近域名>|<在线>
function M.client_diag_hosts()
	local out = sys.exec(CLIENT_DIAG .. " hosts 2>&1") or ""
	local rows = {}
	for line in out:gmatch("[^\n]+") do
		local ip, host, mac, qn, fn, lt, dom, on =
			line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
		if ip and ip ~= "" then
			rows[#rows + 1] = {
				ip = ip, host = host or "", mac = mac or "",
				queries = qn or "0", fails = fn or "0",
				last_ts = lt or "0", domain = dom or "",
				online = (on == "1"),
			}
		end
	end
	return rows
end

--- 单域名的完整链路（第二级下钻）
--
-- 输出 key|value 形式，返回一个有序数组供页面逐项渲染。
function M.client_diag_trace(ip, domain)
	if not domain or domain == "" then return {} end
	if ip and ip ~= "" and not ip:match("^[0-9a-fA-F:.]+$") then return {} end
	-- 域名只允许合法字符，防止拼进 shell
	if not domain:match("^[%w%._%-]+$") then return {} end

	local cmd = CLIENT_DIAG .. " trace"
	if ip and ip ~= "" then cmd = cmd .. " '" .. ip .. "'" else cmd = cmd .. " ''" end
	cmd = cmd .. " '" .. domain .. "' 2>&1"

	local out = sys.exec(cmd) or ""
	local rows = {}
	for line in out:gmatch("[^\n]+") do
		-- 格式：KEY|VALUE 或 KEY|VALUE|计数（UPSTREAM / STATE 带计数）
		local k, v, c = line:match("^([A-Z_]+)|([^|]*)|?([^|]*)$")
		if k then
			rows[#rows + 1] = { key = k, value = v or "", count = c or "" }
		end
	end
	return rows
end

--- 按关键词搜索域名
function M.client_diag_search(kw, ip, limit)
	if not kw or kw == "" then return {} end
	-- 关键词只允许常见域名字符，防止拼进 shell
	if not kw:match("^[%w%._%-]+$") then return {} end
	limit = tonumber(limit) or 200
	if limit < 1 then limit = 200 end
	if limit > 2000 then limit = 2000 end

	local cmd = CLIENT_DIAG .. " search '" .. kw .. "'"
	if ip and ip ~= "" and ip:match("^[0-9a-fA-F:.]+$") then
		cmd = cmd .. " '" .. ip .. "'"
	else
		cmd = cmd .. " ''"
	end
	cmd = cmd .. " " .. limit .. " 2>&1"

	local out = sys.exec(cmd) or ""
	local rows = {}
	for line in out:gmatch("[^\n]+") do
		local ts, cli, dom, up, st, seg, ans =
			line:match("^([^|]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
		if ts then
			rows[#rows + 1] = {
				ts = ts, client = cli or "", domain = dom or "",
				upstream = up or "", state = st or "",
				seg = seg or "", answer = ans or "",
			}
		end
	end
	return rows
end

--- 撤销一条自动归属调整（L4）
function M.client_diag_undo(id)
	if not id or not id:match("^[0-9]+$") then
		return false, "记录 id 非法"
	end
	local out = sys.exec(CLIENT_DIAG .. " undo " .. id .. " 2>&1") or ""
	M.invalidate()
	if out:find("OK=") then
		return true, out:gsub("^%s*OK=", ""):gsub("%s+$", "")
	end
	local err = out:match("ERROR=([^\n]*)")
	return false, err or "撤销失败"
end

-- ============================================================
-- 自动补全（v0.24.0，ADR-0010）
-- ------------------------------------------------------------
-- 页面要三样东西：
--   ① 状态（学习集合 / 元素数 / 挂钩三态）→ learn_status
--   ② 已学域名表与 IP 段表（带操作链接）  → learn_domains / learn_cidr
--   ③ 四个动作（学习 / 演练 / 清计数器 / 清规则）→ learn_run / learn_clear
--   ④ 表格里每行的「钉住 / 移除」→ learn_pin / learn_remove
--
-- ⚠️ 所有域名参数都必须经 M.shell_quote，side 只允许白名单值。
--    这不是防御性编程而是必要：域名来自 dnsmasq 日志（客户机可控），
--    而日志内容会被写进 shell 命令行。不转义就是命令注入。
-- ============================================================

--- 学习层状态
--
-- 输出 KEY=VALUE，字段名在脚本里是 TABLE / V4_COUNT / V6_COUNT /
-- HOOKED / CIDR_V4 / CIDR_V6 / ENABLED / AUTO_DOMESTIC / AUTO_FOREIGN。
function M.learn_status()
	local out = sys.exec(CLIENT_DIAG .. " learn-status 2>&1") or ""
	local kv = parse_kv(out)
	return {
		table          = kv.TABLE or "0",
		v4_count       = kv.V4_COUNT or "0",
		v6_count       = kv.V6_COUNT or "0",
		hooked         = kv.HOOKED or "0",
		hook_hits      = kv.HOOK_HITS or "0",
		cidr_v4        = kv.CIDR_V4 or "0",
		cidr_v6        = kv.CIDR_V6 or "0",
		enabled        = kv.ENABLED or "1",
		interval       = kv.INTERVAL or "1800",
		threshold      = kv.THRESHOLD or "3",
		batch          = kv.BATCH or "0",
		retain_days    = kv.RETAIN_DAYS or "30",
		timeout        = kv.TIMEOUT or "3",
		retries        = kv.RETRIES or "3",
		max_domains    = kv.MAX_DOMAINS or "0",
		max_cidr       = kv.MAX_CIDR or "0",
		autofix_thresh = kv.AUTOFIX_THRESHOLD or "5",
		autofix_intv   = kv.AUTOFIX_INTERVAL or "3600",
		auto_domestic  = kv.AUTO_DOMESTIC or "0",
		auto_foreign   = kv.AUTO_FOREIGN or "0",
		retry_pending  = kv.RETRY_PENDING or "0",
	}
end

--- 跑一轮学习（**后台启动，立即返回**）
--
-- 为什么不再同步等结果（v0.24.0 实测踩过）：
--   一轮学习实测 68~152 秒（43~92 个候选 × 每条最多 24 秒）。
--   页面按钮走 CGI，LuCI 的 uhttpd 超时后浏览器直接报
--   **502 Bad Gateway**，而进程还在跑 —— 用户以为失败又点一次，
--   实测出现 6 个并发 learn 进程，把路由器与上游一起打满。
--
--   现在改成 fork 到后台 + 立即返回「已启动」，页面显示进行中，
--   用户再点「立即刷新」或等自动刷新看结果。
--
-- dry = true 时后台跑 --dry-run（完全不落盘）。
function M.learn_run(dry)
	local cmd = CLIENT_DIAG .. " learn-start"
	if dry then cmd = cmd .. " --dry-run" end

	local out = sys.exec(cmd .. " 2>&1") or ""
	M.invalidate()

	local kv = parse_kv(out)

	if kv.BUSY == "1" then
		return "⏳ 已有一轮学习在跑（" .. (kv.AGE or "?") .. " 秒前开始），请等它结束"
	end
	if kv.STARTED == "1" then
		if dry then
			return "已启动演练（不落盘），稍后点「立即刷新」看结果"
		end
		return "已启动学习，稍后点「立即刷新」看结果"
	end
	-- 启动失败：把脚本给的原因带出来（可能是总开关关闭 / 锁冲突）
	local reason = kv.REASON or out:gsub("%s+$", "")
	return "✗ 启动失败：" .. reason
end

--- 学习是否进行中 + 上一轮结果
function M.learn_state()
	local out = sys.exec(CLIENT_DIAG .. " learn-state 2>&1") or ""
	local kv = parse_kv(out)

	local last = kv.LAST or ""
	local n_cand = last:match("CANDIDATES=(%d+)") or "0"
	local n_dom  = last:match("LEARNED_DOMESTIC=(%d+)") or "0"
	local n_for  = last:match("LEARNED_FOREIGN=(%d+)") or "0"
	local n_done = last:match("DONE=(%d+)") or "0"
	local err    = last:match("ERROR=([^%s]*)")

	-- 进度文件里的 DONE 更准（日志可能来自更早的一轮）
	local prog_done = kv.PROGRESS_DONE or ""
	if prog_done:match("^%d+$") then n_done = prog_done end

	return {
		running = kv.RUNNING or "0",
		start   = kv.START or "0",
		dry     = kv.DRY or "0",
		finish  = kv.END or "0",
		last_candidates = n_cand,
		last_domestic   = n_dom,
		last_foreign    = n_for,
		last_done       = n_done,
		progress_total  = kv.PROGRESS_TOTAL or "0",
		progress_done   = prog_done ~= "" and prog_done or "0",
		progress_current = kv.PROGRESS_CURRENT or "",
		last_error      = err,
	}
end

--- 清空学习层
--
-- what = "counter"（只清计数器）| "all"（彻底重置）
function M.learn_clear(what)
	what = tostring(what or "all")
	if what ~= "counter" and what ~= "rules" and what ~= "all" then
		return false, "参数必须是 counter / rules / all"
	end

	local out = sys.exec(CLIENT_DIAG .. " learn-clear " .. what .. " 2>&1") or ""
	M.invalidate()

	if out:find("OK=") then
		return true, out:gsub("^%s*OK=", ""):gsub("%s+$", "")
	end
	local err = out:match("ERROR=([^\n]*)")
	return false, err or "清空失败"
end

--- 已学域名表
--
-- 数据来源两处合并：
--   dom_auto_domestic / dom_auto_foreign（UCI，权威）
--   learn-counters.txt（计数器，提供「次数 / 客户机数」两列）
--
-- 为什么次数从计数器取而不是自己维护：计数器是学习的判据来源，
-- 页面显示它才能解释「为什么这个域名被学到了」。
function M.learn_domains()
	local rows = {}

	-- 计数器聚合：域名 → 最大次数、客户机台数、最近时刻
	local cnt = {}
	local f = io.open(M.state_dir .. "/learn-counters.txt", "r")
	if f then
		for raw in f:lines() do
			local dom, ip, n, first, last =
				raw:match("^([^|]+)|([^|]+)|([^|]*)|([^|]*)|([^|]*)$")
			if dom and dom ~= "" and ip and ip ~= "" then
				local c = tonumber(n) or 0
				local e = cnt[dom]
				if not e then
					e = { max = 0, hosts = 0, last = 0 }
					cnt[dom] = e
				end
				if c > e.max then e.max = c end
				e.hosts = e.hosts + 1
				local l = tonumber(last) or 0
				if l > e.last then e.last = l end
			end
		end
		f:close()
	end

	-- 审计表：域名 → 最近一次判定的来源（manual / auto / L4）
	local src = {}
	local fa = io.open(M.state_dir .. "/learn-audit.log", "r")
	if fa then
		for raw in fa:lines() do
			local _, dom, _, s = raw:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|")
			if dom and dom ~= "" and s and s ~= "" then
				src[dom] = s
			end
		end
		fa:close()
	end

	local function add(side)
		for _, dom in ipairs(M.uci_list("dom_auto_" .. side, "domain")) do
			local e = cnt[dom]
			rows[#rows + 1] = {
				domain = dom,
				side   = side,
				count  = e and tostring(e.max) or "—",
				hosts  = e and tostring(e.hosts) or "—",
				source = src[dom] or "—",
			}
		end
	end

	add("domestic")
	add("foreign")

	-- 按归属再按域名排序，页面顺序稳定
	table.sort(rows, function(a, b)
		if a.side ~= b.side then return a.side < b.side end
		return a.domain < b.domain
	end)

	return rows
end

--- 已学 IP 段表
--
-- 来源是 learn-cidr.txt（`4 <cidr>` / `6 <cidr>` 两列）。
-- 「来源域名」这一列**没有**逐段记录 —— 一个域名常解析出多个 /24，
-- 反向映射需要每轮重新解析，代价太高。故这里只显示地址族与段本身，
-- 「来源域名」列留给用户在「已学域名」表里对照。
function M.learn_cidr()
	local rows = {}
	local f = io.open(M.run_dir .. "/learn-cidr.txt", "r")
	if not f then return rows end

	for raw in f:lines() do
		local fam, cidr = raw:match("^(%d)%s+([^%s]+)$")
		if fam and cidr then
			rows[#rows + 1] = {
				cidr = cidr,
				family = fam == "6" and "IPv6" or "IPv4",
				domain = nil,
			}
		end
	end
	f:close()

	table.sort(rows, function(a, b) return a.cidr < b.cidr end)
	return rows
end

--- 表格里「钉住 / 移除」的操作 URL
--
-- 为什么用 URL 而不是 Button：
--   CBI 把整页包在一个 <form> 里，嵌套 form 会被浏览器丢弃；
--   而 Button 的 write() 只能挂在 section 上，无法按行区分。
--   故走 GET + controller 里的独立 action（见 controller/dnschain.lua）。
--
-- act = pin | remove | remove_cidr
function M.learn_action_url(act, value, side)
	local base = disco.build_url("admin", "services", "dns_chain", "learn")

	-- 参数值必须 URL 编码：域名里有 `-` `.` 是安全的，但
	-- CIDR 里的 `/` 会破坏 query 解析，必须编码成 %2F。
	local function enc(s)
		return (tostring(s or ""):gsub("[^%w%._%-]", function(c)
			return string.format("%%%02X", c:byte())
		end))
	end

	local url = base .. "?act=" .. enc(act) .. "&v=" .. enc(value)
	if side and side ~= "" then
		url = url .. "&side=" .. enc(side)
	end
	return url
end

--- 钉住：把自动学到的域名写进手写列表（学习永不覆盖）
--
-- 语义（清单要求）：钉住 = 用户认可这条归属，转成手写。
-- 手写优先于自动，故之后学习不会再改它。
function M.learn_pin(domain, side)
	domain = tostring(domain or "")
	side = tostring(side or "")

	-- side 白名单：只有两个合法值，其它一律拒绝
	if side ~= "domestic" and side ~= "foreign" then
		return false, "side 必须是 domestic / foreign"
	end

	-- 域名合法性：与页面校验同一条规则（只允许字母数字点横线）
	if not domain:match("^[%w][%w%.%-]*%.[%a][%w%.%-]*$") then
		return false, "域名格式非法"
	end

	local q = M.shell_quote(domain)
	local other = (side == "domestic") and "foreign" or "domestic"

	-- 先写手写侧，再从自动两侧删掉（避免同域名两处都有）
	local ok = os.execute(
		"uci -q add_list dnschain.dom_" .. side .. ".domain=" .. q .. " && " ..
		"uci -q del_list dnschain.dom_auto_" .. side .. ".domain=" .. q .. " ; " ..
		"uci -q del_list dnschain.dom_auto_" .. other .. ".domain=" .. q .. " ; " ..
		"uci -q del_list dnschain.dom_" .. other .. ".domain=" .. q .. " ; " ..
		"uci -q commit dnschain")

	M.invalidate()

	if ok ~= 0 and ok ~= true then
		return false, "写入失败"
	end

	-- 重建分流片段，让钉住立即生效
	sys.exec("/usr/bin/dnschain-selftest apply 2>&1")
	M.invalidate()
	return true, "已钉住 " .. domain .. " → 手写" .. side
end

--- 移除一条已学域名（两侧自动列表都删）
function M.learn_remove(domain)
	domain = tostring(domain or "")
	if not domain:match("^[%w][%w%.%-]*%.[%a][%w%.%-]*$") then
		return false, "域名格式非法"
	end

	local q = M.shell_quote(domain)
	local ok = os.execute(
		"uci -q del_list dnschain.dom_auto_domestic.domain=" .. q .. " ; " ..
		"uci -q del_list dnschain.dom_auto_foreign.domain=" .. q .. " ; " ..
		"uci -q commit dnschain")

	M.invalidate()

	if ok ~= 0 and ok ~= true then
		return false, "删除失败"
	end

	sys.exec("/usr/bin/dnschain-selftest apply 2>&1")
	M.invalidate()
	return true, "已移除 " .. domain
end

--- 移除一条已学 IP 段（从 learn-cidr.txt 删掉，下一轮不再灌入）
function M.learn_remove_cidr(cidr)
	cidr = tostring(cidr or "")
	-- CIDR 只允许十六进制/数字/点/冒号/斜杠
	if not cidr:match("^[%x%d%.:%/]+$") then
		return false, "CIDR 格式非法"
	end

	local path = M.run_dir .. "/learn-cidr.txt"
	local f = io.open(path, "r")
	if not f then return false, "learn-cidr.txt 不存在" end

	local keep = {}
	local hit = false
	for raw in f:lines() do
		local fam, c = raw:match("^(%d)%s+([^%s]+)$")
		if fam and c == cidr then
			hit = true
		else
			keep[#keep + 1] = raw
		end
	end
	f:close()

	if not hit then return false, "该 IP 段不在文件里" end

	local out = io.open(path, "w")
	if not out then return false, "写入失败" end
	for _, line in ipairs(keep) do
		out:write(line, "\n")
	end
	out:close()

	-- 立即重建集合，否则要等下一轮收敛才生效
	sys.exec("/usr/bin/dnschain-reconcile 2>&1")
	M.invalidate()
	return true, "已移除 IP 段 " .. cidr
end


return M
