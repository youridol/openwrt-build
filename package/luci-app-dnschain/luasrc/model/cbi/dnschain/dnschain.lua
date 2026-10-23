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

function M.import_lists()
	local out = sys.exec("/usr/bin/dnschain-reconcile 2>&1") or ""
	return exec_ok(out), out
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
	local out = sys.exec("/usr/bin/dnschain-reconcile 2>&1") or ""
	return exec_ok(out), out
end

--- 立即分诊未知目标（v0.16.0）
--
-- 逻辑（用户需求原文）：
--   不在 GFW 名单、不在代理 IP 集（blacklist）、不在国内 IP 段（china）、
--   不在任何数据库的域名 / IP / IP 段，全部先走直连；
--   直连不通再走 SSR-Plus；都不通则标记为死。
--   跑通的落库：IP 转 IP 段追加到集合，域名追加到对应列表。
--
-- 判定依据是**实测**（真的发 HTTP 请求），不是查库或猜延迟。
function M.triage_now()
	local out = sys.exec("/usr/bin/dnschain-triage run 2>&1") or ""
	return exec_ok(out), out
end

--- 读取分诊结果（v0.16.0）
--
-- 返回：{ { target, kind, verdict }, ... } 与汇总
--   kind    = "ip" | "domain"
--   verdict = "direct" | "proxy" | "dead"
--
-- 数据源是 /usr/bin/dnschain-triage list 的输出：
--   ITEM <目标>|<类型>|<结果>
--   SUMMARY total=<n> direct=<n> proxy=<n> dead=<n>
--
-- 为什么要读脚本而不是直接读记录文件：记录文件有两份
-- （triage-ip.list / triage-domain.list），格式与语义在脚本里统一，
-- 页面重复实现一遍解析就会漂移。
function M.triage_rows()
	return cached("triage_rows", function()
		local rows, sum = {}, {}
		local out = sys.exec("/usr/bin/dnschain-triage list 2>/dev/null") or ""

		for line in out:gmatch("[^\n]+") do
			local it = line:match("^ITEM%s+(.+)$")
			if it then
				local target, kind, verdict = it:match("^([^|]+)|([^|]+)|([^|]+)$")
				if target and verdict then
					rows[#rows + 1] = {
						target = target,
						kind = kind or "",
						verdict = verdict,
					}
				end
			end
			local sm = line:match("^SUMMARY%s+(.+)$")
			if sm then
				for k, v in sm:gmatch("(%w+)=(%d+)") do
					sum[k] = tonumber(v) or 0
				end
			end
		end

		return { rows = rows, summary = sum }
	end)
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

function M.selftest()
	return cached("selftest", function()
		local out = sys.exec("/usr/bin/dnschain-selftest 2>&1") or ""
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
		-- ⚠️ `%w` 不含下划线（v0.14.4 修 M5）：`both_bad=1` 会被解析成
		-- `bad = 1`，丢掉 `both_` 前缀（实测确认）。汇总键目前没人读，
		-- 但这是一个「看起来有、实际没有」的通道，谁哪天用
		-- summary.both_bad 就会拿到 nil。
		for k, v in line:gmatch("([%w_]+)=(%d+)") do
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
		local pid = ""
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
							-- ⚠️ 不再解析 /proc/<pid>/stat 取启动时间（v0.14.4 删 L5）。
							--
							--   原 pattern 有 21 个占位符，捕获的是第 21 个字段，
							--   而 starttime 是 /proc/<pid>/stat 的第 22 个
							--   （第 1 是 pid、第 2 是 comm、第 3 是 state…），
							--   实际取到的是 itrealvalue。而且 uptime 在返回表里
							--   **没有出现**，是纯死变量。
							--
							--   这是一处「看起来在算进程运行时长」的假实现：
							--   谁把 uptime 加进返回表就会显示错误时长。
							--   真要运行时长应从 /proc/uptime 减去 starttime/HZ。
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


return M
