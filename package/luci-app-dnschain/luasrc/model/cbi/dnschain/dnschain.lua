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




--- watch.servers 的实际内容（用于「当前改道生效情况」核对）


return M
