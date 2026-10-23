#!/bin/sh
# ============================================================
# dnschain 共用函数库
# ------------------------------------------------------------
# 被 init.d/dnschain、dnschain-reconcile、dnschain-selftest 共同 source。
# 设计依据：docs/adr/0003-dns-chain-framework.md
#
# 约束（AGENTS.md §6 第 11 条）：必须 POSIX sh（dash）兼容。
#   禁止：进程替换 <(...)、[[ ]]、关联数组（declare -A）。
#
#   `local` **可以**用 —— 本文件每个函数都在用，dash 与 BusyBox ash
#   都支持它。原注释把 local 也列进禁令，与实际用法矛盾，
#   会误导后续改动（有人据此删掉 local 反而引入变量污染）。
#   已更正（v0.14.3）。
#
#   注意 `declare -A` 属 bash 专有：实测 BusyBox ash 不支持，
#   写它只会得到一段永不执行的死代码（v0.14.3 删过一处）。
# ============================================================

DNSCHAIN_CONF="dnschain"
DNSCHAIN_RUN_DIR="/var/etc/dnschain"
DNSCHAIN_STATE_DIR="/var/run/dnschain"

# 框架自持的组件路径
DNSCHAIN_DNSMASQ_CONF_DIR="/tmp/dnsmasq.d"
DNSCHAIN_SSR_CONF_DIR="${DNSCHAIN_DNSMASQ_CONF_DIR}/dnsmasq-ssrplus.d"

# ------------------------------------------------------------
# 日志
# ------------------------------------------------------------
dnschain_log() {
	logger -t dnschain "$*"
	echo "dnschain: $*"
}

# ------------------------------------------------------------
# 读取配置（带默认值）
# 用法: dc_get <section> <option> <default>
# ------------------------------------------------------------
dc_get() {
	local v
	v=$(uci -q get "${DNSCHAIN_CONF}.$1.$2" 2>/dev/null)
	[ -n "$v" ] && { echo "$v"; return 0; }
	echo "$3"
}

# 读取 list 类型的全部值，每行一个
dc_get_list() {
	uci -q get "${DNSCHAIN_CONF}.$1.$2" 2>/dev/null | tr " " "\n" | grep -v "^$"
}

# ------------------------------------------------------------
# 该档案对应的 SSR-Plus pdnsd_enable 值
# 0 = 不启后端（v0.10.0 起框架也不再需要 :5335，但仍要求 0，
#     避免 SSR-Plus 自己起 mosdns/dns2tcp 制造第二个解析器）
# coexist 下允许 1/4/5/6，但框架不强制改
# ------------------------------------------------------------
# ⚠️ 必须读 `ssr.mode`，不能读 `main.profile`（v0.14.3 修 M2）。
#
#   原实现读 `dc_get main profile primary`，而配置文件里**没有**
#   `main.profile` 这个键 → 恒返回 "0"。而页面上用户能选
#   「目标 DNS 模式」（`ssr.mode`：0 或 7）却**没有任何脚本读它**。
#   结果：用户选「7 — 模块内置 DNS」并保存，收敛器仍强制写回
#   `pdnsd_enable=0` —— 用户的操作被静默推翻，且没有任何提示。
#
#   同一个事实曾存在两个键（profile / ssr.mode），一个不存在、
#   一个没人读。现在统一到 `ssr.mode`：
#     · 有显式 ssr.mode → 用它（尊重用户选择）
#     · 无 ssr.mode 但有 main.profile=coexist → 不强制（旧配置兼容）
#     · 都没有 → 默认 0（框架要接管解析，必须让它不启自己的 DNS 后端）
dc_ssr_mode_for_profile() {
	local mode profile
	# ⚠️ section 名是 compat，不是 ssr（v0.14.5 修）。
	#
	#    配置文件里是 `config ssr 'compat'` —— **类型是 ssr、名字是 compat**。
	#    `dc_get <name> <option>` 走的是 `uci get dnschain.<name>.<option>`，
	#    所以必须写 `dc_get compat mode`。写成 `dc_get ssr mode` 查的是
	#    「名字为 ssr 的 section」，而它不存在 → 恒返回空 → 恒走兜底 "0"。
	#
	#    这是 v0.14.4 的 M2 修复**没真正生效**的原因：当时把
	#    `main profile` 改成了 `ssr mode`，但名字仍然错，所以
	#    「页面选 7 被静默推翻」这个 bug 依然存在。
	#    实测：compat.mode=7 时本函数仍返回 0。
	mode=$(dc_get compat mode "")
	if [ -n "$mode" ]; then
		echo "$mode"
		return 0
	fi
	# 旧配置兼容：main.profile=coexist 表示「不强制，由用户决定」
	profile=$(dc_get main profile primary)
	case "$profile" in
		coexist) echo "" ;;
		*)       echo "0" ;;
	esac
}

# ------------------------------------------------------------
# 从**已有的** netstat 输出里查端口所有者
#
# 用法: dc_port_owner_from <netstat 输出> <port>
#
# 为什么需要这个函数（v0.14.9 性能）：
#   `netstat -lnup` 实测 23ms —— 它要读 /proc/net/udp 与 /proc/net/tcp 并
#   反查 socket inode 对应的进程名。而 dc_port_owner 每查**一个**端口就
#   跑一次 netstat。自检的缓存指纹一次要查 3 个端口（entry/foreign/1234），
#   就是 3 × 23ms 的纯重复开销。
#
#   把 netstat 的输出先取一次、再对多个端口查表，解析逻辑与
#   dc_port_owner 完全一致（同一条 awk + sed），只是输入换成调用方给的
#   快照。这样既不改变任何判定，也不改变 dc_port_owner 的返回值。
# ------------------------------------------------------------
dc_port_owner_from() {
	local tbl port
	tbl="$1"
	port="$2"

	printf '%s\n' "$tbl" \
		| awk -v p=":${port}" '$4 ~ p"$" {print $NF}' \
		| sed 's|/.*||' | head -1
}

# ------------------------------------------------------------
# 端口所有权探测：返回监听该端口的 PID（无监听则空）
# 用法: dc_port_owner <port> [proto]
# ------------------------------------------------------------
dc_port_owner() {
	local port proto
	port="$1"
	proto="${2:-udp}"

	if [ "$proto" = "udp" ]; then
		dc_port_owner_from "$(netstat -lnup 2>/dev/null)" "$port"
	else
		dc_port_owner_from "$(netstat -lntp 2>/dev/null)" "$port"
	fi
}

# 端口是否被监听
dc_port_listening() {
	local pid
	pid=$(dc_port_owner "$1" "${2:-udp}")
	[ -n "$pid" ]
}

# ------------------------------------------------------------
# 名单源文件的指纹（用于判断是否需要重新导入）
# 返回 "<md5> <总行数>"，源文件都不存在时返回空
# ------------------------------------------------------------
dc_lists_fingerprint() {
	local gfw base total md5s
	gfw=$(dc_get lists gfw_source /etc/ssrplus/gfw_list.conf)
	base=$(dc_get lists base_source /etc/ssrplus/gfw_base.conf)

	[ -r "$gfw" ] || { echo ""; return 0; }

	total=0
	md5s=""
	# gfw 已在函数开头 `[ -r ] || return` 过，这里无需再判（v0.14.3 清理）
	total=$((total + $(wc -l < "$gfw")))
	md5s="${md5s}$(md5sum "$gfw" 2>/dev/null | awk '{print $1}')"
	if [ -r "$base" ]; then
		total=$((total + $(wc -l < "$base")))
		md5s="${md5s}$(md5sum "$base" 2>/dev/null | awk '{print $1}')"
	fi

	echo "$(echo "$md5s" | md5sum | awk '{print $1}') $total"
}

# ------------------------------------------------------------
# 把名单源转成「纯域名」列表（每行一个，去重）
#
# 源格式（gfw_list.conf，实测 47434 行 = 23717 域名 x 2）：
#   server=/域名/127.0.0.1#5335
#   ipset=/域名/gfwlist
# 源格式（gfw_base.conf，实测 110 行）：
#   server=/域名/127.0.0.1#5335
#
# 输出：纯域名，已排序去重。**不过滤 xn--**（过滤在生成 dnsproxy 文件时做，
# 因为 dnsmasq 那条旁路能处理 punycode，需要保留完整集合）。
# ------------------------------------------------------------
dc_extract_domains() {
	local gfw base black
	gfw=$(dc_get lists gfw_source /etc/ssrplus/gfw_list.conf)
	base=$(dc_get lists base_source /etc/ssrplus/gfw_base.conf)
	# ⚠️ black_source 之前**没有消费者**（v0.14.3 修 M3）：
	#    页面「名单 → 黑名单源」可配，但归属判定只读 gfw + base，
	#    用户配的额外黑名单被完全忽略，且无从察觉。
	#    SSR-Plus 的 black.list 是**裸域名**格式（一行一个，无 server=/ 前缀），
	#    与 gfw_list 不同，故单独解析。
	black=$(dc_get lists black_source /etc/ssrplus/black.list)

	{
		[ -r "$gfw" ] && sed -n 's|^server=/\([^/]*\)/.*|\1|p' "$gfw"
		[ -r "$base" ] && sed -n 's|^server=/\([^/]*\)/.*|\1|p' "$base"
		# black.list：一行一个域名，可能带 # 注释与空行
		[ -r "$black" ] && sed -e 's/#.*//' -e 's/[[:space:]]//g' "$black"
	} | grep -v '^$' | sort -u
}

# ------------------------------------------------------------
# 用「排除列表」过滤输入（每行一个精确匹配）
#
# 用法: dc_exclude <排除文件> [输入文件]
#   排除文件为空 / 不存在 / 只有注释时，原样输出输入
#
# ⚠️ 必须自己做这个判断，不能直接 `grep -Fvxf <排除文件>`（v0.13.0 实测）：
#   BusyBox 的 grep 在 **pattern 文件为空** 时返回 rc=1 且**输出零行** ——
#   不是「一条都不排除」，而是「把输入全吞掉」。
#   实测：printf "a\nb\nc\n" | grep -Fvxf /tmp/empty  → 0 行
#   加 -s（抑制错误）也一样。
#
#   这个坑在本框架里**必然触发**：custom-domestic.txt 默认是空文件
#   （用户还没录自定义域名），而 db-domains.txt 有 23715 条 →
#   foreign-split.conf 变成 0 字节 → preflight 判「国外分流为空」→
#   拒绝启动，整条链路起不来（实测症状：dnschain restart 后
#   「ERROR: foreign-split.conf 为空」且 dnsproxy 不再监听）。
#
#   正确做法：排除文件为空时直接 cat，根本不调用 grep。
# ------------------------------------------------------------
dc_exclude() {
	local pat="$1"
	local input="$2"

	# 有内容才算「有排除项」：跳过空行与注释
	if [ -n "$pat" ] && [ -r "$pat" ] \
	   && grep -qvE '^[[:space:]]*(#|$)' "$pat" 2>/dev/null; then
		if [ -n "$input" ]; then
			grep -Fvxf "$pat" "$input" 2>/dev/null
		else
			grep -Fvxf "$pat" 2>/dev/null
		fi
	else
		if [ -n "$input" ]; then
			cat "$input" 2>/dev/null
		else
			cat 2>/dev/null
		fi
	fi
	return 0
}

# ------------------------------------------------------------
# 生成「国外域名 → 国外 dnsproxy 实例」的 dnsmasq 分流规则
#
# v0.10.0 架构：**两个 dnsproxy 实例 + dnsmasq 按域名分流**
#
#   实例 1（:5353，国内）：阿里 DoT/DoH，直连
#   实例 2（:5336，国外）：只有 Google DoH，经 :1234 代理
#
#   dnsmasq:53
#     ├─ 默认 → 127.0.0.1#5353（国内）
#     └─ server=/国外域名/127.0.0.1#5336（国外）
#
# ⚠️ 为什么不用 dnsproxy 的 [/域名/] 分流（这是关键教训）：
#   最初实现是让 dnsproxy 单实例加载 upstreams-domains.txt（17767 条
#   [/域名/]https://dns.google），实测**完全失败**：
#     - dnsproxy 为每个域名各注册一条 reserved 上游
#       （verbose 日志：upstream is reserved idx=3 ... idx=17769）
#     - 17767 个上游条目耗尽资源，查询 google 时直接
#       `connection timed out; no servers could be reached`
#     - 而国内域名（走默认上游）正常
#   改成两个实例 + dnsmasq 分流后，实测：
#     google A    → 142.251.155.119
#     google AAAA → 2001:4860:482d:7700::
#     baidu  A    → 183.2.172.177
#
# 输出文件：/var/etc/dnschain/foreign-split.conf（数据库国外的**生效**清单）
#
# 注意这个文件从 v0.13.0 起**不再**是 dnsmasq 片段（那是 dnschain-split.conf），
# 而是一份纯域名清单，两个用途：
#   ① preflight 的「国外分流规则非空」判据（空清单意味着 gfw 名单没就绪）
#   ② 页面的规模统计
# 它已经扣掉了「自定义国内」与「观测域名」—— 这两类不由静态规则决定去向，
# 留在清单里会让页面上的数字与实际分流不一致。
# ------------------------------------------------------------
dc_gen_upstream_file() {
	local outdir count fport tmp watch_f

	outdir="$DNSCHAIN_RUN_DIR"
	fport=$(dc_get main foreign_port 5336)

	mkdir -p "$outdir" || return 1

	# 国外上游必须至少一条
	if [ -z "$(dc_get_list foreign server | head -1)" ]; then
		dnschain_log "ERROR: dnschain.upstream.foreign 为空，无法生成国外分流规则"
		return 1
	fi

	dc_gen_custom_lists || return 1

	# ⚠️ 数据库文件必须真的就绪（v0.14.3 修 M7）。
	#
	#   原写法 `[ -s ... ] || dc_gen_db_domains >/dev/null` **不检查返回码**，
	#   随后 `if [ -r "$DNSCHAIN_DB_DOMAINS" ]` 为假时 $tmp 保持空，
	#   仍被 mv 成正式文件并 return 0 —— 静默产出 0 字节的
	#   foreign-split.conf。故障只在后面的 preflight 里以
	#   「foreign-split.conf 为空」出现，与真实原因（gfw 名单未就绪 /
	#   生成失败）隔了两层。
	if [ ! -s "$DNSCHAIN_DB_DOMAINS" ]; then
		dc_gen_db_domains >/dev/null 2>&1 || {
			dnschain_log "ERROR: 生成 db-domains 失败（gfw 名单不可读？）"
			return 1
		}
	fi
	if [ ! -s "$DNSCHAIN_DB_DOMAINS" ]; then
		dnschain_log "ERROR: db-domains 为空，无法生成国外分流规则"
		dnschain_log "ERROR: 请确认 lists.gfw_source 指向的名单文件存在且有内容"
		return 1
	fi

	tmp=$(mktemp) || return 1
	watch_f=$(mktemp) || { rm -f "$tmp"; return 1; }
	dc_watch_list > "$watch_f"

	# 数据库国外 − 自定义国内 − 观测域名
	#
	# ⚠️ **不过滤 xn--**（v0.10.0 修正）。
	# v0.9.x 过滤 IDNA 是因为 dnsproxy 的 `[/域名/]` 形式不认 punycode
	# （会整体拒绝启动：idna: invalid label "wcvs22d1m"）。
	# 但 v0.10.0 改用 dnsmasq 的 `server=/域名/` 形式 —— dnsmasq 原生支持
	# punycode，无需过滤。
	#
	# 不过滤的实测依据：gfw_list.conf 里有 58 条 xn-- 域名，过滤后它们
	# 只剩 gfw_list 的 `server=/域名/127.0.0.1#5335`（该端口已无监听），
	# 实测这 58 条全部解析失败（apple.xn--czr694b、nike.xn--hxt814e 等）。
	# 改成不过滤后它们也指向 :5336，恢复正常。
	#
	# ⚠️ 两次排除都必须走 dc_exclude（不能直接 grep -Fvxf）：
	#   custom-domestic.txt 默认是空文件，而 BusyBox grep 在 pattern
	#   文件为空时会吞掉全部输入 → foreign-split.conf 变 0 字节 →
	#   preflight 拒绝启动。详见 dc_exclude 的注释。
	if [ -r "$DNSCHAIN_DB_DOMAINS" ]; then
		dc_exclude "$DNSCHAIN_CUSTOM_DOM" "$DNSCHAIN_DB_DOMAINS" \
			| dc_exclude "$watch_f" > "$tmp"
	fi

	mv -f "$tmp" "${outdir}/foreign-split.conf" 2>/dev/null || { rm -f "$tmp" "$watch_f"; return 1; }
	rm -f "$watch_f"

	count=$(wc -l < "${outdir}/foreign-split.conf" 2>/dev/null || echo 0)

	dnschain_log "foreign-split.conf: ${count} 条（数据库国外 − 自定义国内 − 观测域名）→ 127.0.0.1#${fport}"
	echo "$count"
}

# ------------------------------------------------------------
# 国内 dnsproxy 实例参数（:5353）
# ADR §10.1：刻意不配 --cache*、--fallback、--ipv6-disabled
# ------------------------------------------------------------
dc_gen_dnsproxy_args() {
	local out entry
	out="$DNSCHAIN_RUN_DIR/dnsproxy.args"
	entry=$(dc_get main entry_port 5353)

	mkdir -p "$DNSCHAIN_RUN_DIR" || return 1

	{
		echo "--listen"
		echo "127.0.0.1"
		echo "--listen"
		echo "::1"
		echo "--port"
		echo "$entry"

		# 国内加密池
		dc_get_list cn server | while read -r up; do
			[ -n "$up" ] && { echo "--upstream"; echo "$up"; }
		done

		# bootstrap 仅用于解析加密上游的主机名
		echo "--bootstrap"
		echo "223.5.5.5"
		echo "--bootstrap"
		echo "223.6.6.6"

		echo "--timeout"
		echo "8s"

		# 单实例只服务国内域名，parallel 取最快即可
		echo "--upstream-mode"
		echo "parallel"

		echo "--hosts-file-enabled=true"
		echo "--hosts-files"
		echo "/etc/hosts"
	} > "$out"

	# 注意：这里**不写** --cache / --fallback / --ipv6-disabled。
	echo "$out"
}

# ------------------------------------------------------------
# 国外 dnsproxy 实例参数（:5336）
#
# 只配国外 DoH 上游。**必须用 DoH（443）**，不能用 DoT（853）：
#   实测落地节点到 8.8.8.8:853 / 1.1.1.1:853 全部
#   `peer sent close notify`（只回 204 字节），而 443 完全正常。
# ------------------------------------------------------------
dc_gen_foreign_args() {
	local out fport
	out="$DNSCHAIN_RUN_DIR/dnsproxy-foreign.args"
	fport=$(dc_get main foreign_port 5336)

	mkdir -p "$DNSCHAIN_RUN_DIR" || return 1

	{
		echo "--listen"
		echo "127.0.0.1"
		echo "--port"
		echo "$fport"

		# 国外加密池（DoH）
		dc_get_list foreign server | while read -r up; do
			[ -n "$up" ] && { echo "--upstream"; echo "$up"; }
		done

		echo "--bootstrap"
		echo "223.5.5.5"
		echo "--bootstrap"
		echo "223.6.6.6"

		echo "--timeout"
		echo "8s"

		# 国外只服务 gfw 域名，parallel 让多个 DoH 取最快
		echo "--upstream-mode"
		echo "parallel"

		echo "--hosts-file-enabled=true"
		echo "--hosts-files"
		echo "/etc/hosts"
	} > "$out"

	echo "$out"
}

# ------------------------------------------------------------
# 由参数文件构造命令行（每行一个参数，用空格安全拼接）
# ------------------------------------------------------------
dc_args_to_cmdline() {
	[ -r "$1" ] || return 1
	tr '\n' ' ' < "$1"
}

# ------------------------------------------------------------
# 当前 dnsmasq 的**真 worker** PID
#
# ⚠️ 不能直接用 `pidof dnsmasq | awk '{print $1}'`（v0.13.0 实测修正）。
#
# 本固件的 dnsmasq 是「ujail → dnsmasq → 子进程」三层结构，实测：
#
#   6623  /sbin/ujail -t 5 ... -- /usr/sbin/dnsmasq -C ...   ppid=1
#   6670  /usr/sbin/dnsmasq -C ... -k -x ...                 ppid=6623
#   6691  /usr/sbin/dnsmasq -C ... -k -x ...                 ppid=6670
#
#   `pidof dnsmasq` 返回 **6691 6670 6623**（新到旧），故取第一个拿到 6691。
#   但真正持有 :53 socket 的是 **6670**（38 个 fd），6691 只有 5 个 fd、
#   wchan = anon_pipe_read —— 它是 dnsmasq fork 出来等管道的辅助进程。
#
# 实测判据（/etc/hosts 会随 SIGHUP 重读）：
#   HUP → 6691 后 zz-hup-test.invalid 仍无解析结果
#   HUP → 6670 后立刻返回 192.0.2.99
#   即**发给 6691 的 SIGHUP 是空操作**。
#
# 后果（如果取错）：改道写进 watch.servers 后 SIGHUP 不生效，
# 页面显示「已改道」而实际没换上游 —— 正是最该避免的静默失效。
#
# 正确判据：**持有 :53 UDP socket 的那个 PID**。用 /proc/net/udp 的
# inode 反查 /proc/<pid>/fd，不依赖 pidof 的顺序（AGENTS §4.3 同法）。
# 取不到时回落到 pidof 的**最后一个**（最老、最可能是真 worker）。
# ------------------------------------------------------------
dc_dnsmasq_pid() {
	local inodes pid found

	# 1. 优先：持有 :53 UDP socket 的进程
	#
	# /proc/net/udp 的 local_address 形如 0100007F:0035（小端 hex），
	# 0035 = 53。只取 inode 列，再逐 pid 反查。
	inodes=$(awk 'NR > 1 && $2 ~ /:0035$/ { print $10 }' /proc/net/udp 2>/dev/null)

	if [ -n "$inodes" ]; then
		for pid in $(pidof dnsmasq 2>/dev/null); do
			for ino in $inodes; do
				if ls -l "/proc/${pid}/fd" 2>/dev/null | grep -q "socket:\[${ino}\]"; then
					echo "$pid"
					return 0
				fi
			done
		done
	fi

	# 2. 回落：pidof 的最后一个
	#
	# 为什么是最后一个而不是第一个：pidof 按 PID 降序输出，
	# 最后一个是最早启动的，在 ujail 结构里最靠近真正的 worker。
	# 这个回落不完美，但比「取第一个必错」好，且下面还有 pidfile 兜底。
	found=$(pidof dnsmasq 2>/dev/null | awk '{ print $NF }')
	[ -n "$found" ] && { echo "$found"; return 0; }

	# 3. 再回落：pidfile
	for f in /var/run/dnsmasq/dnsmasq.*.pid /var/run/dnsmasq.pid; do
		if [ -r "$f" ]; then
			found=$(cat "$f" 2>/dev/null | tr -d ' \n')
			[ -n "$found" ] && { echo "$found"; return 0; }
		fi
	done

	echo ""
}

# ------------------------------------------------------------
# 清空 dnsmasq 缓存（SIGHUP：只清缓存、不重读配置、进程不重启）
# 这条在「重读配置」用途上是缺陷，在「清缓存」用途上恰好是优点。
# ------------------------------------------------------------
dc_flush_cache() {
	local pid
	pid=$(dc_dnsmasq_pid)
	[ -n "$pid" ] || return 1
	kill -HUP "$pid" 2>/dev/null || return 1
	dnschain_log "已发送 SIGHUP 清空 dnsmasq 缓存 (pid=$pid)"
}

# ------------------------------------------------------------
# 读取运行时 ss_spec_output 的 TCP 端口集（用于上游端口校验）
# 输出形如 "22 80 143 443 465 587 853 993 995 9418"
# ------------------------------------------------------------
dc_output_ports() {
	nft list chain inet ss_spec ss_spec_output 2>/dev/null \
		| sed -n 's/.*tcp dport { \([^}]*\) }.*/\1/p' \
		| head -1 \
		| tr "," " " \
		| tr -s ' ' \
		| sed 's/^ *//; s/ *$//'
}

# 从上游 URL 里抽出端口；无显式端口时按 scheme 推断
# 用法: dc_upstream_port <url>
dc_upstream_port() {
	local url scheme hostport port
	url="$1"

	scheme=$(echo "$url" | sed -n 's|^\([a-z0-9+]*\)://.*|\1|p')
	[ -n "$scheme" ] || { echo ""; return 0; }

	hostport=$(echo "$url" | sed -e 's|^[a-z0-9+]*://||' -e 's|/.*$||')

	case "$hostport" in
		*:*\]*)   # [v6]:port
			port=$(echo "$hostport" | sed -n 's/.*\]:\([0-9]*\)$/\1/p')
			;;
		*:*)
			port=$(echo "$hostport" | sed -n 's/.*:\([0-9]*\)$/\1/p')
			;;
		*)
			port=""
			;;
	esac

	if [ -z "$port" ]; then
		case "$scheme" in
			https) port=443 ;;
			tls)   port=853 ;;
			quic)  port=853 ;;
			http)  port=80 ;;
			*)     port="" ;;
		esac
	fi

	echo "$port"
}

# ============================================================
# 域名归属 / 自定义列表 / 链路健康 / 自动改道（v0.13.0 新增）
# ------------------------------------------------------------
# 设计依据：docs/adr/0006-domain-routing-and-reroute.md
#
# 三个概念必须分清（页面与脚本用的是同一套定义）：
#
#   归属（class）  域名「应该」走哪条链，是**静态判定**，只看配置与名单：
#                    custom-domestic  用户手工录入「国内域名」
#                    custom-foreign   用户手工录入「国外域名」
#                    db-foreign       命中 SSR-Plus 的 gfw/基础名单
#                    uncovered        三个来源都没覆盖
#
#   首选（preferred）  归属推导出的链路：
#                    自定义与数据库国外 → foreign（代理出口）
#                    自定义国内 / 未覆盖 → domestic（直连出口）
#                    「未覆盖 → domestic」不是随便定的：dnsmasq 的默认
#                    上游就是 :entry_port（国内实例），所以未覆盖域名
#                    本来就走直连。改道逻辑必须与这个事实一致，
#                    否则「不配置任何东西」和「配置了框架」行为会不同。
#
#   当前（active）  实际生效的链路，由健康探测决定，可能与首选不同。
#
# 自动改道的两条规则（需求原文）：
#   未录入自定义列表的域名 ——
#     国外链路探测不通 → 改走直连（切到 domestic 实例）
#     国内链路探测不通 → 改走代理（切到 foreign 实例）
# 落到实现上就是一句话：**首选链不通且另一条链通，就切到另一条**。
# 两种情形分别对应上面的两条规则，见 dc_health_cycle 的注释。
#
# 为什么自定义列表里的域名不参与改道：
#   用户明确指定了走哪条链，那是对策略的表达，不是对可达性的猜测。
#   框架只报告它的健康状态，不擅自改道。
# ============================================================

# ⚠️ watch.servers 必须放在 **ujail 已挂载** 的目录里（v0.13.0 实测踩过）。
#
# 本固件的 dnsmasq 由 ujail 降权运行，实测 /proc/<pid>/status:
#     Uid: 453 453 453 453        ← dnsmasq 用户，不是 root
# 且 ujail 只挂载了固定的一组路径（由 init.d/dnsmasq 的
# `procd_add_jail_mount` 决定，**不接受 serversfile 指向的路径**）：
#     -r /tmp/dnsmasq.d        -rw /var/run/dnsmasq/   ...
#
# 原来放在 /var/etc/dnschain/ 下时，那个目录**既不在白名单、文件又是
# 0600 root:root**，于是：
#   · dnsmasq 读不到 → servers-file 一条都没加载
#   · SIGHUP 却成功返回、日志也不报错 → 改道完全无效且无迹可循
#   · 实测症状：github.com 经 :53 稳定超时（走 gfw_list 里指向死端口
#     :5335 的旧声明），而直连 :5336 / :5353 都正常
#
# 改到 /var/run/dnsmasq/ 后实测：指向不存在的 :59999 会立刻超时，
# 还原后立刻恢复 —— 证明 servers-file 真的被读了。
# （/var/run 是 tmpfs，重启即清空，每次启动都会重新生成，符合预期。）
DNSCHAIN_WATCH_SERVERS="/var/run/dnsmasq/watch.servers"
DNSCHAIN_DB_DOMAINS="${DNSCHAIN_RUN_DIR}/db-domains.txt"
DNSCHAIN_CUSTOM_DOM="${DNSCHAIN_RUN_DIR}/custom-domestic.txt"
DNSCHAIN_CUSTOM_FOR="${DNSCHAIN_RUN_DIR}/custom-foreign.txt"
DNSCHAIN_HEALTH_STATE="${DNSCHAIN_STATE_DIR}/health.state"

# ------------------------------------------------------------
# 域名规范化：去首尾空白、去尾部点、转小写
#
# 只去**首尾**空白，不去中间的 —— 中间有空格一定不是合法域名，
# 去掉会把 "a .com" 静默变成 "a.com" 收下，用户看到的却是自己写了
# 带空格的东西却被接受了。这类「宽容」在配置界面里是负资产。
#
# 为什么要转小写：dnsmasq 的 server=/域名/ 匹配是大小写不敏感的，
# 但状态文件与页面显示必须唯一，否则 Foo.com 与 foo.com 会被当成
# 两个观测目标、各自维护一份改道状态。
#
# ⚠️ 纯 shell 实现，不再 `sed | sed | tr`（v0.14.9 性能）。
#
#   原实现是一条管道三个外部命令 = **3 次 fork**，实测单次约 2.5ms。
#   dc_domain_class / dc_domain_valid 都要先归一化，而 status 对 8 个
#   域名要判 24 次归属（class + preferred + custom 各调一次）→
#   仅归一化就 72 次 fork。
#
#   `${s#"${s%%[![:space:]]*}"}` 是 POSIX 参数展开：先取「最长的纯空白
#   前缀」再删掉它，等价于 `s/^[[:space:]]*//`；尾部同理。
#   `[[:space:]]` 在 case/参数展开的字符类里 BusyBox ash 与 dash 都支持
#   （已在路由器实测，见 CHANGELOG 验证段）。
#
#   语义必须与旧实现**逐字节一致**，故顺序保持：先去首尾空白 →
#   再去**一个**尾部点 → 最后转小写。用 `tr` 而不是 `${s,,}`：
#   后者是 bash 4 专有，dash 不支持。
# ------------------------------------------------------------
dc_domain_normalize() {
	local s
	s="$1"
	# 去首尾空白（含 tab；`[[:space:]]` 覆盖空格/tab/换行）
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	# 去一个尾部点（只去一个，与 `sed 's/\.$//'` 一致）
	s=${s%.}
	printf '%s' "$s" | tr 'A-Z' 'a-z'
}

# ------------------------------------------------------------
# 域名格式校验（严格）
#
# 规则（与 dnsmasq 的 canonicalise 基本对齐，但更严）：
#   - 总长 ≤ 253，每个标签 1..63
#   - 至少两个标签（单标签是主机名，不是域名；dnsmasq 的 //
#     是「无点名字」的特殊写法，混进来会改变语义）
#   - 标签只允许 a-z 0-9 -，且不以 - 开头/结尾
#   - 顶级域必须是纯字母且 ≥2 位，或 punycode（xn--）
#   - 禁止 * / 空格 等字符
#
# 为什么不接受通配：server=/域名/ 是按标签后缀匹配的，
# 用户写 *.example.com 会得到一条永远匹配不到的规则，
# 而页面上看不出任何异常 —— 这类静默失效必须在录入时就拦住。
#
# 为什么接受 xn--：dnsmasq 原生支持 punycode（AGENTS §4.0 第 4 条），
# 过滤掉会让 IDNA 域名无法录入。
# ------------------------------------------------------------
# 校验「已经归一化过」的域名（v0.14.9 拆分）
#
# dc_domain_class 与 dc_domain_class_batch 都会先归一化再校验，
# 若校验内部再归一化一次，就是**重复的 2 次 fork**。
# 把校验主体抽成 _norm 版本，dc_domain_valid 保持原签名与语义不变
# （外部调用方仍然可以直接传原始输入）。
dc_domain_valid_norm() {
	local d label tld n _oifs

	d="$1"
	[ -n "$d" ] || return 1
	[ "${#d}" -le 253 ] || return 1

	case "$d" in
		*..*|.*|*.) return 1 ;;
		*[!a-z0-9.-]*) return 1 ;;
	esac

	case "$d" in
		*.*) : ;;
		*) return 1 ;;
	esac

	_oifs=$IFS
	IFS=.
	set -- $d
	IFS=$_oifs

	[ $# -ge 2 ] || return 1

	n=0
	tld=""
	for label in "$@"; do
		[ -n "$label" ] || return 1
		[ "${#label}" -le 63 ] || return 1
		case "$label" in
			-*|*-) return 1 ;;
			*[!a-z0-9-]*) return 1 ;;
		esac
		n=$((n + 1))
		tld="$label"
	done

	case "$tld" in
		xn--*) : ;;
		*[!a-z]*) return 1 ;;
		*) [ "${#tld}" -ge 2 ] || return 1 ;;
	esac

	return 0
}

# 对外入口：接受原始输入，先归一化再校验（签名与语义与旧版一致）
#
# ⚠️ 注意这个函数**会归一化两次**（自己一次，dc_domain_normalize 内部
# 的 sed/tr 管道只做一次，但调用方 dc_domain_class 已经归一化过一次）。
# 这是历史行为，v0.14.9 保留原样 —— 见 dc_domain_class_batch 里的说明。
dc_domain_valid() {
	dc_domain_valid_norm "$(dc_domain_normalize "$1")"
}

# ------------------------------------------------------------
# 把 UCI list 规范化成「每行一个合法域名，去重排序」
# 用法: dc_list_normalize <section> <option>
# ------------------------------------------------------------
dc_list_normalize() {
	local d
	dc_get_list "$1" "$2" | while read -r d; do
		[ -n "$d" ] || continue
		d=$(dc_domain_normalize "$d")
		dc_domain_valid "$d" || continue
		echo "$d"
	done | sort -u
}

# ------------------------------------------------------------
# 观测列表（参与健康探测与自动改道的域名）
#
# 回落逻辑：用户把 watch 清空后，用内置基准集。
# 为什么要回落而不是「空就是空」：空列表意味着永不探测、页面永远
# 显示「无数据」，用户会以为功能坏了。基准集是「国内外各 4 个」
# 的稳定站点，能代表两条链的通断。
#
# ⚠️ 必须**每行一个域名**（v0.14.0 修）。
#
#   旧写法是：
#     DNSCHAIN_WATCH_SEED="a.com b.com c.com
#                          d.com e.com"
#     printf '%s\n' "$DNSCHAIN_WATCH_SEED" | while read -r d; ...
#
#   `printf '%s\n' "$VAR"` 把整个变量当成**一个参数**，
#   于是 8 个域名被压成 2 行（按变量里的字面换行），
#   再 `read -r d` 读到的每一「行」其实是 4 个域名用空格连起来的串。
#   后果：dc_watch_list 输出 2 行、每行含多个域名，
#   而静态片段的排除用的是 `grep -Fvxf <watch文件>`（逐行精确匹配），
#   于是 github.com 等域名**排除不掉**，同时出现在静态片段与
#   servers-file 里 → dnsmasq 把两条 server= 当候选 →
#   改道退化成随机走一条。自检第 18 项正是查这个，实测 FAIL。
#
#   现在用多行字面量 + `printf '%s\n' $VAR`（不加引号，靠词分割 +
#   每行已是独立词），并显式逐个输出，语义明确。
DNSCHAIN_WATCH_SEED="www.baidu.com
www.taobao.com
www.qq.com
www.163.com
www.google.com
www.youtube.com
github.com
www.wikipedia.org"

dc_watch_list() {
	local d out

	out=$(dc_get_list health watch | while read -r d; do
		[ -n "$d" ] || continue
		d=$(dc_domain_normalize "$d")
		dc_domain_valid "$d" || continue
		echo "$d"
	done | sort -u)

	if [ -z "$out" ]; then
		# 基准集：逐词输出，保证一行一个域名
		out=$(printf '%s\n' $DNSCHAIN_WATCH_SEED \
			| while read -r d; do
				[ -n "$d" ] || continue
				echo "$d"
			done | sort -u)
	fi

	printf '%s\n' "$out"
}

# ------------------------------------------------------------
# 数据库域名集合（缓存成文件，供 O(1) 归属判定）
#
# 为什么缓存：gfw_list.conf 实测 3.5 万行，每次判定都 sed 一遍
# 要 200ms+，而页面一次渲染要做几十次判定。
# 文件由 dc_gen_db_domains 生成，随名单导入刷新。
# ------------------------------------------------------------
dc_gen_db_domains() {
	local n
	mkdir -p "$DNSCHAIN_RUN_DIR" || return 1
	dc_extract_domains \
		| grep -E '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$' \
		| tr 'A-Z' 'a-z' \
		| sort -u > "${DNSCHAIN_DB_DOMAINS}.tmp" || return 1
	mv -f "${DNSCHAIN_DB_DOMAINS}.tmp" "$DNSCHAIN_DB_DOMAINS" || return 1
	n=$(wc -l < "$DNSCHAIN_DB_DOMAINS" 2>/dev/null || echo 0)
	echo "$n"
}

# ------------------------------------------------------------
# 归属判定
# 输出：custom-domestic | custom-foreign | db-foreign | uncovered | invalid
#
# 优先级：自定义 > 数据库 > 未覆盖。
# 自定义优先是刻意的：用户手工录入就是要覆盖名单的自动判定，
# 否则「我明明写了走直连，它还是走代理」会成为无解的困惑。
#
# ⚠️ 必须做**后缀匹配**，不能只做精确匹配（v0.13.0 实测修正）。
#
# dnsmasq 的 `server=/google.com/` 对 `www.google.com` **生效**，
# 而 gfw 名单里只写了 `google.com`（实测：grep 到 google.com 有 1 条、
# www.google.com 有 0 条）。原来这里用 `grep -Fqx` 精确匹配，
# 于是 www.google.com 被判成 `uncovered` → 首选 domestic →
# 改道逻辑把它拉到直连 → 拿到**污染答案**：
#
#   实测 www.google.com  A 经 :5353（直连）→ 31.13.92.37（Facebook 的 IP）
#   实测 www.youtube.com A 经 :5353（直连）→ 185.45.5.35
#
# 也就是说：**归属判定比 dnsmasq 的实际匹配更窄**，会让本该走代理的
# 子域名被改道到直连。这不是「改道错了」，而是「归属就错了」。
#
# 判定顺序与 dnsmasq 一致：精确命中 → 逐级去掉最左标签再试。
# 例：a.b.google.com → a.b.google.com → b.google.com → google.com
# 这样 `db-foreign` 能覆盖所有子域名，与 dnsmasq 行为对齐。
#
# 为什么不用 `grep -F "$d"` 做子串匹配：那会让 `notgoogle.com`
# 命中 `google.com`。必须按标签边界匹配，故逐级剥标签。
# ------------------------------------------------------------
# ------------------------------------------------------------
# 归属判定
#
# ⚠️ 不要在这里加「进程内 memo 缓存」（v0.14.1 试过，反而更慢）。
#
#   曾尝试用变量查表缓存 dc_domain_class 的结果，但取值要走
#   `printf | awk`（BusyBox ash 无关联数组），一次 fork 就 0.02s ——
#   比直接 `grep -Fxf` 还贵。实测 8 个域名从 0.29s 涨到 0.36s。
#
#   真正的性能修复在**减少调用次数**与**页面级缓存**（见
#   dnschain.lua 的 health_status_raw 与 selftest 磁盘缓存），
#   而不是在函数内部做 memo。
# ------------------------------------------------------------
dc_domain_class() {
	local d cur

	d=$(dc_domain_normalize "$1")
	# ⚠️ 必须调 dc_domain_valid（它会**再归一化一次**），不能调
	# dc_domain_valid_norm（v0.14.9 保留原语义）。
	#
	#   旧实现就是这样：class 先归一化得到 $d，校验内部又归一化一遍。
	#   于是输入 "a.b.." 时：$d="a.b."，而校验看到的是 "a.b" → 判为合法。
	#   若改成 _norm 版本，校验看到 "a.b." → 命中 `*.` 分支 → 判为非法。
	#   这条路径虽然只在「尾部有 2 个以上点」的输入上才暴露，但
	#   dc_watch_list 确实可能产出 "a.b."（它只归一化一次再校验），
	#   所以必须逐字节保持旧行为。
	dc_domain_valid "$d" || { echo "invalid"; return 0; }

	# 自定义列表：精确匹配
	#
	# 为什么自定义**不**做后缀匹配：用户录 `google.com` 表达的是
	# 「这个域名走代理」，而不是「所有子域名都走代理」——后者是名单
	# 的语义。两种语义混在一起会让「我录了 google.com 却把
	# mail.google.com 也拉走了」变得无法解释。
	[ -r "$DNSCHAIN_CUSTOM_DOM" ] && grep -Fqx "$d" "$DNSCHAIN_CUSTOM_DOM" 2>/dev/null \
		&& { echo "custom-domestic"; return 0; }
	[ -r "$DNSCHAIN_CUSTOM_FOR" ] && grep -Fqx "$d" "$DNSCHAIN_CUSTOM_FOR" 2>/dev/null \
		&& { echo "custom-foreign"; return 0; }

	# 数据库：后缀匹配（与 dnsmasq 的 server=/域名/ 语义一致）
	#
	# ⚠️ 性能（v0.14.1，两轮优化后的最终形态）
	#
	# 第一轮问题：原实现对每一级标签各跑一次
	#   `grep -Fqx <标签> db-domains.txt`，文件实测 23715 行 ——
	#   单域名 0.06s，页面要判几十次。
	#
	# 第二轮尝试：把整个名单读进一个 shell 变量 `_DC_DB_BLOB`，
	#   再用 `case "$blob" in *"<换行>$cur<换行>"*)` 匹配。
	#   缓存确实生效了（实测 _DC_DB_LOADED=1、blob 348KB），
	#   但 **348KB 字符串的模式匹配本身很慢** —— 每次判定仍要
	#   扫描整个串，8 个域名 0.60s，比原来还慢。
	#
	# 第三轮（当前）：**一次 grep 批量比对所有候选后缀**。
#
#   曾尝试用关联数组（`declare -A`）做 O(1) 查表，但实测
#   BusyBox ash **不支持** `declare -A`（`sh -c 'eval "declare -A x=()"'
#   返回非 0），那整段是死代码；且 `declare` 属 bash 专有命令，
#   与本文件「必须 POSIX sh 兼容」的声明冲突。已删除（v0.14.3）。
#
#   现在只有一条实现：把所有候选后缀拼成 pattern 列表，
#   **一次** `grep -Fxf` 比对整个名单。实测 8 个域名 0.29s，够用。
	if [ -r "$DNSCHAIN_DB_DOMAINS" ]; then
		# 候选 = 自身 + 逐级剥标签后的后缀（至少保留两级）
		_dc_cands=""
		cur="$d"
		while :; do
			_dc_cands="$_dc_cands$cur
"
			cur=${cur#*.}
			case "$cur" in
				*.*) ;;
				*) break ;;
			esac
		done
		# grep -F 一次比对多个模式，命中即 db-foreign
		if printf '%s' "$_dc_cands" | grep -Fxf - "$DNSCHAIN_DB_DOMAINS" 2>/dev/null | head -1 | grep -q .; then
			echo "db-foreign"; return 0
		fi
	fi

	echo "uncovered"
}

# ------------------------------------------------------------
# 批量归属判定（v0.14.9 性能）
#
# 用法: dc_domain_class_batch  （stdin 每行一个**已归一化**域名）
# 输出: 每行 "<域名>|<class>"，**顺序与输入完全一致**，一行对一行。
#
# 为什么需要它：`dnschain-health status` 对每个观测域名要判三次归属
# （class / preferred / custom 各调一次 dc_domain_class），8 个域名
# 就是 24 次判定、24 次对 348KB 的 db-domains.txt 做 grep ——
# 实测 880ms，占 status 全部耗时的八成。
#
# 本函数把「一次 grep 比一个域名」换成「一次 grep 比全部域名」：
#   · 自定义两份列表：一次 grep -Fxf 拿全部命中
#   · 数据库：把所有候选后缀拼成一个 pattern 列表，一次 grep -Fxf
#   实测 db 扫描 50~60ms（无论 8 个还是 80 个域名，都是**一次**全表扫描），
#   剩下的优先级判定在纯 shell 里做，不 fork。
#
# 语义必须与逐个调 dc_domain_class **完全一致**：
#   ① 非法域名 → invalid（不查任何列表）
#   ② 自定义国内精确命中 → custom-domestic（优先级最高）
#   ③ 自定义国外精确命中 → custom-foreign
#   ④ 数据库后缀命中 → db-foreign
#   ⑤ 都没有 → uncovered
#   自定义只做**精确**匹配、数据库做**逐级剥标签的后缀**匹配，
#   这个区别与 dc_domain_class 的注释（v0.13.0 修正）一致，不得合并。
#
# 注意：本函数**不排序**。status 依赖输入顺序（也就是 dc_watch_list
# 的 sort -u 顺序）来保证输出行序稳定，这里排序会打乱它。
# ------------------------------------------------------------
dc_domain_class_batch() {
	local raw norm cur doms norms pats cands cd_hits cf_hits db_hits cls nl

	nl='
'
	doms=""
	norms=""
	pats=""
	cands=""

	# ── 第一遍：收齐域名，同时准备两类 pattern ──────────────────
	#
	# ⚠️ 这里必须精确复刻 dc_domain_class 的**两步归一化**（v0.14.9）。
	#
	#   dc_domain_class 的流程是：
	#     d2 = dc_domain_normalize "$1"      ← 第一次
	#     dc_domain_valid "$d2"              ← 内部再归一化成 d3 再校验
	#     之后所有匹配都用 **d2**
	#
	#   于是 "a.b.." 这种输入：d2="a.b."、d3="a.b" → 校验通过，
	#   匹配用 "a.b."。若只归一化一次就当非法处理，行为会变。
	#   batch 的输入来自 dc_watch_list（已归一化过一次），但为了
	#   对任意输入都与 dc_domain_class 等价，这里照样做两遍。
	while IFS= read -r raw; do
		[ -n "$raw" ] || continue
		doms="$doms$raw$nl"
		norm=$(dc_domain_normalize "$raw")
		norms="$norms$norm$nl"
		dc_domain_valid "$norm" || continue
		pats="$pats$norm$nl"
		# 候选后缀 = 自身 + 逐级剥标签（至少保留两级），与
		# dc_domain_class 里那段 while 完全相同的剥法。
		cur="$norm"
		while :; do
			cands="$cands$cur$nl"
			cur=${cur#*.}
			case "$cur" in
				*.*) ;;
				*) break ;;
			esac
		done
	done

	# ── 三次 grep：自定义两份 + 数据库一份 ──────────────────────
	# 文件不可读时保持空（对应 dc_domain_class 的 `[ -r ] && grep`）
	cd_hits=""
	cf_hits=""
	db_hits=""
	[ -n "$pats" ] && [ -r "$DNSCHAIN_CUSTOM_DOM" ] && \
		cd_hits=$(printf '%s' "$pats" | grep -Fxf - "$DNSCHAIN_CUSTOM_DOM" 2>/dev/null)
	[ -n "$pats" ] && [ -r "$DNSCHAIN_CUSTOM_FOR" ] && \
		cf_hits=$(printf '%s' "$pats" | grep -Fxf - "$DNSCHAIN_CUSTOM_FOR" 2>/dev/null)
	[ -n "$cands" ] && [ -r "$DNSCHAIN_DB_DOMAINS" ] && \
		db_hits=$(printf '%s' "$cands" | grep -Fxf - "$DNSCHAIN_DB_DOMAINS" 2>/dev/null)

	# ── 第二遍：按优先级逐个定档（纯 shell，无 fork）────────────
	#
	# 输出用**原始**域名（raw），与 dc_domain_class 的调用方
	# （cmd_status 打印 dc_watch_list 的原值）一致。
	while [ -n "$doms" ]; do
		raw=${doms%%"$nl"*}
		case "$doms" in
			*"$nl"*) doms=${doms#*"$nl"} ;;
			*)       doms="" ;;
		esac
		norm=${norms%%"$nl"*}
		case "$norms" in
			*"$nl"*) norms=${norms#*"$nl"} ;;
			*)       norms="" ;;
		esac
		[ -n "$raw" ] || continue

		if ! dc_domain_valid "$norm"; then
			printf '%s|invalid\n' "$raw"
			continue
		fi

		if _dc_set_has "$norm" "$cd_hits"; then
			printf '%s|custom-domestic\n' "$raw"
			continue
		fi
		if _dc_set_has "$norm" "$cf_hits"; then
			printf '%s|custom-foreign\n' "$raw"
			continue
		fi

		cls="uncovered"
		if [ -n "$db_hits" ]; then
			cur="$norm"
			while :; do
				if _dc_set_has "$cur" "$db_hits"; then
					cls="db-foreign"
					break
				fi
				cur=${cur#*.}
				case "$cur" in
					*.*) ;;
					*) break ;;
				esac
			done
		fi
		printf '%s|%s\n' "$raw" "$cls"
	done
	return 0
}

# 判断 $1 是否是「换行分隔集合」$2 里的一整项
#
# 用 case 而不是 grep：这是一次纯 shell 比较，不 fork。
# case 模式里带引号的展开按字面匹配（POSIX），故域名里的 `.`、`-`
# 不会被当成通配；两侧补换行保证是**整行**匹配而不是子串匹配
# （`163.com` 不能命中 `www.163.com`）。
_dc_set_has() {
	case "
$2
" in
		*"
$1
"*) return 0 ;;
	esac
	return 1
}

# ------------------------------------------------------------
# 首选链路（由归属推导）
# ------------------------------------------------------------
dc_domain_preferred() {
	case "$(dc_domain_class "$1")" in
		custom-foreign|db-foreign) echo "foreign" ;;
		*)                         echo "domestic" ;;
	esac
}

# ------------------------------------------------------------
# 自定义列表的定位：**补全数据库归属**，不是改道开关
#
# ⚠️ v0.14.0 语义矫正（此前实现是错的）。
#
#   旧实现把自定义域名当成「固定」：命中就写 health 的 fixed 状态，
#   **完全不参与健康检测与自动改道**。理由写的是「你写的就是最终答案」。
#
#   但那与需求相矛盾。需求的原文是：
#     · 自定义输入框「只作为补全追加到数据库而不是直接改道」，
#       由 dnsmasq 和 dnsproxy 判断如何分流；
#     · 「针对国内外数据库未覆盖的域名，实现链路健康检测与自动改道」。
#
#   两句话合起来的意思是：
#     自定义列表的作用是**告诉框架「这个域名的归属是哪条链」** ——
#     补上数据库没覆盖的那一块。归属定了，首选链也就定了；
#     但**首选链不等于最终链路** —— 如果首选链探测不通、另一条通，
#     仍然要改道。否则「补全归属」就变成了「绕过健康检测」。
#
#   所以现在：
#     · dc_domain_class 仍然优先返回 custom-*（补全归属，优先级最高）
#     · dc_domain_preferred 据此给出首选链
#     · 健康检测与改道对**所有**观测域名一视同仁，不再有 fixed 例外
#
#   保留这个函数只是为了兼容旧调用点，语义改为「用户显式指定了归属」
#   —— 它**不再**意味着「不参与改道」。
# ------------------------------------------------------------
dc_domain_custom() {
	case "$(dc_domain_class "$1")" in
		custom-domestic|custom-foreign) return 0 ;;
		*) return 1 ;;
	esac
}


# ------------------------------------------------------------
# 自定义列表落盘（供归属判定与分流生成共用）
#
# 注意：这不是「把 UCI 抄一遍」，而是**规范化后的唯一副本**。
# 归属判定、分流生成、页面显示全部读这三个文件，
# 避免三处各自解释一遍 UCI 而产生漂移。
# ------------------------------------------------------------
dc_gen_custom_lists() {
	mkdir -p "$DNSCHAIN_RUN_DIR" || return 1
	dc_list_normalize dom_domestic domain > "${DNSCHAIN_CUSTOM_DOM}.tmp" || return 1
	mv -f "${DNSCHAIN_CUSTOM_DOM}.tmp" "$DNSCHAIN_CUSTOM_DOM" || return 1
	dc_list_normalize dom_foreign domain > "${DNSCHAIN_CUSTOM_FOR}.tmp" || return 1
	mv -f "${DNSCHAIN_CUSTOM_FOR}.tmp" "$DNSCHAIN_CUSTOM_FOR" || return 1
}

# ------------------------------------------------------------
# nft 集合是否存在（决定要不要写 nftset= 行）
#
# 为什么必须先探测：SSR-Plus 未启用时 ss_spec 表根本不存在，
# 此时 dnsmasq 每解析一个域名都会尝试写集合并失败，
# 在日志里刷 "failed to add ... to nftset"。宁可少写一行，
# 也不要在别人的日志里制造噪声。
#
# ⚠️ 但这个「宁可少写」是**有条件**的（v0.14.1 实测修正）。
#
#   实测故障：在 SSR-Plus 页面点一次「保存并应用」，ssrplus 会重建
#   规则；期间 `ss_spec` 表短暂消失（重建窗口）。若 dnschain 恰好在
#   这个窗口里跑 apply，`dc_nftset_exists` 全部返回假 →
#   **23714 条 server= 照写、但 nftset= 一条都不写** →
#   国外域名能解析，可解析出的 IP 不进 blacklist 集合 →
#   **流量不走代理 → 国外链路整条断掉**，而日志干净、页面看着正常。
#
#   实测证据：`SPLIT=23714 0`（前半是 server= 条数，后半是 nftset 条数）。
#
#   修法见 dc_ss_spec_present / dc_nftset_exists 下方的兜底逻辑：
#   探测不到集合时，不再静默丢弃，而是**保留上一版片段里的 nftset 行**
#   （文件还在就沿用），并明确记一条日志。这样短暂重建窗口不会
#   把代理链路打掉。
# ------------------------------------------------------------
dc_nftset_exists() {
	nft list set inet ss_spec "$1" >/dev/null 2>&1
}

# ss_spec 表整体是否存在（判断「SSR-Plus 是否在管代理」）
#
# 与 dc_nftset_exists 分开：前者看表、后者看集合。
# 表在而集合不在，说明 ssrplus 正在重建中途（或规则被清）——
# 这是**暂时**状态，不该据此丢掉 nftset 行。
#
# ⚠️ 用 `nft list tables` 而不是 `nft list table inet ss_spec`（v0.14.9 性能）。
#
#   两者判据完全相同（表存在就会出现在表名列表里），但代价差 15 倍：
#     nft list table inet ss_spec   实测 150ms —— 它要 dump 整张表的
#                                   全部 chain/rule/set 内容，只为确认存在
#     nft list tables               实测  10ms —— 只列表名
#   自检的缓存指纹每次都要调它，150ms 占指纹开销的一半。
#   `grep -qxF` 是**整行精确匹配**，避免 `ss_spec6`、`ss_spec_mangle`
#   之类的前缀误命中（`nft list tables` 一行一张表，格式固定）。
dc_ss_spec_present() {
	nft list tables 2>/dev/null | grep -qxF 'table inet ss_spec'
}

# 安全计数：永远输出**一个**整数，且 rc 恒为 0
#
# ⚠️ 为什么不能写 `grep -c ... || echo 0`（v0.14.3 修，实测复现）
#
#   `grep -c` 在**无匹配**时既打印 `0`、又返回 rc=1。于是
#   `n=$(grep -c PATTERN f || echo 0)` 得到的是 **两行** "0\n0"：
#       $ v=$(grep -c '^nftset=' /tmp/t || echo 0); echo "[$v]"
#       [0
#       0]
#   而后续 `[ "$n" -eq 0 ]` 是算术比较，遇到含换行的值直接报错返回假
#   （实测 rc=2）。后果是**判据恒假**：
#     · reconcile 的「nftset 行数为 0 → 强制重建」自愈分支永不执行
#     · dc_prev_nftset_count 返回脏值 → 重建窗口兜底也失效
#   两者恰好都只在「计数为 0」时才是关键路径，于是 bug 只在故障时暴露。
#
# 用法: dc_count_lines <模式> <文件>
#   —— 文件不存在或无匹配都返回单个 0。
dc_count_lines() {
	local n
	[ -r "$2" ] || { echo 0; return 0; }
	# 先取输出再兜底：awk 无匹配时本来就打印 0 且 rc=0，最稳
	n=$(awk -v pat="$1" '$0 ~ pat { c++ } END { print c + 0 }' "$2" 2>/dev/null)
	case "$n" in
		''|*[!0-9]*) echo 0 ;;
		*)           echo "$n" ;;
	esac
	return 0
}

# 上一版分流片段里有没有 nftset 行（用于重建窗口内的兜底）
#
# 参数：片段文件路径
# 输出：上一版里 nftset 行的条数（单个整数）
dc_prev_nftset_count() {
	dc_count_lines '^nftset=' "$1"
}

# ------------------------------------------------------------
# 生成 dnsmasq 的完整分流片段（dnschain-split.conf）
#
# 这是**唯一**生成该文件的函数（init 与 reconcile 都调它），
# 避免历史上「两份文件各写一遍、内容逐渐不一致」的老问题。
#
# 规则：
#   数据库国外 − 自定义国内 − 观测列表  → server= 指向 foreign_port
#                                        + nftset 写 blacklist
#   自定义国外                          → server= 指向 foreign_port
#                                        + nftset 写 blacklist
#   自定义国内                          → server= 指向 entry_port
#                                        + nftset 写 china（强制直连）
#
# 为什么观测列表要从静态片段里排除：
#   观测域名的实际链路由健康探测动态决定，写在 watch.servers
#   （--servers-file，SIGHUP 即生效）。同一个域名若同时出现在
#   静态片段和 servers-file 里，dnsmasq 会把两条 server= 当作
#   **候选**（不是后者覆盖前者），改道就变成了「随机走一条」。
#   一个域名只能有一处声明 —— 这是本设计的硬约束。
#
# 输出：stdout 两行 "<split 条数> <nftset 条数>"
# ------------------------------------------------------------
dc_gen_dnsmasq_split() {
	local out eport fport tmp_dom tmp_split tmp_nft
	local n_split n_nft have_black have_china

	out="${DNSCHAIN_DNSMASQ_CONF_DIR}/dnschain-split.conf"
	eport=$(dc_get main entry_port 5353)
	fport=$(dc_get main foreign_port 5336)

	mkdir -p "$DNSCHAIN_DNSMASQ_CONF_DIR" || return 1

	dc_gen_custom_lists || return 1
	[ -s "$DNSCHAIN_DB_DOMAINS" ] || dc_gen_db_domains >/dev/null

	tmp_dom=$(mktemp) || return 1
	tmp_split=$(mktemp) || { rm -f "$tmp_dom"; return 1; }
	tmp_nft=$(mktemp) || { rm -f "$tmp_dom" "$tmp_split"; return 1; }

	# 观测列表：每行一个，用于排除
	local watch_f
	watch_f=$(mktemp) || { rm -f "$tmp_dom" "$tmp_split" "$tmp_nft"; return 1; }
	dc_watch_list > "$watch_f"

	# 数据库国外，排除自定义国内与观测列表
	#
	# 必须走 dc_exclude：custom-domestic.txt 默认空文件，
	# 直接 grep -Fvxf 会吞掉整个名单（详见 dc_exclude 注释）。
	if [ -r "$DNSCHAIN_DB_DOMAINS" ]; then
		dc_exclude "$DNSCHAIN_CUSTOM_DOM" "$DNSCHAIN_DB_DOMAINS" \
			| dc_exclude "$watch_f"
	fi > "$tmp_dom"

	have_black=0
	have_china=0
	dc_nftset_exists blacklist && have_black=1
	dc_nftset_exists china && have_china=1

	# ── 重建窗口兜底（v0.14.1）───────────────────────────────────
	#
	# 场景：在 SSR-Plus 页面点「保存并应用」时，ssrplus 会重建规则，
	# `ss_spec` 表在这期间短暂消失。若此刻恰好跑 apply，
	# 上面两个探测全为假 → nftset 行一条都不写 →
	# **国外流量不进代理**（解析正常，但 IP 不进 blacklist）。
	#
	# 判据：ss_spec 表整体不在，但上一版片段里**有** nftset 行
	#       → 说明不是「SSR-Plus 本来就没启用」，而是「正在重建」。
	#       此时沿用上一版的 nftset 行，等下一轮 apply 再自然收敛。
	#
	# 注意区分两种情况，不能一刀切保留：
	#   · SSR-Plus 从未启用（上一版也没有 nftset）→ 保持不写，避免刷日志
	#   · 曾经有、现在暂时没有（重建窗口）        → 保留，避免代理链路断掉
	prev_nft=$(dc_prev_nftset_count "$out")
	keep_prev_nft=0
	if [ "$have_black" = "0" ] || [ "$have_china" = "0" ]; then
		if [ "$prev_nft" -gt 0 ] && ! dc_ss_spec_present; then
			keep_prev_nft=1
			dnschain_log "警告: ss_spec 暂不可用（SSR-Plus 可能在重建），沿用上一版 ${prev_nft} 条 nftset 行，避免代理链路中断"
		fi
	fi

	# 1) 数据库国外 → 国外实例 + 入 blacklist
	if [ -s "$tmp_dom" ]; then
		sed "s|.*|server=/&/127.0.0.1#${fport}|" "$tmp_dom" >> "$tmp_split"
		[ "$have_black" = "1" ] && \
			sed 's|.*|nftset=/&/4#inet#ss_spec#blacklist|' "$tmp_dom" >> "$tmp_nft"
	fi

	# 2) 自定义国外 → 国外实例 + 入 blacklist
	if [ -s "$DNSCHAIN_CUSTOM_FOR" ]; then
		sed "s|.*|server=/&/127.0.0.1#${fport}|" "$DNSCHAIN_CUSTOM_FOR" >> "$tmp_split"
		[ "$have_black" = "1" ] && \
			sed 's|.*|nftset=/&/4#inet#ss_spec#blacklist|' "$DNSCHAIN_CUSTOM_FOR" >> "$tmp_nft"
	fi

	# 3) 自定义国内 → 国内实例 + 入 china（强制直连）
	if [ -s "$DNSCHAIN_CUSTOM_DOM" ]; then
		sed "s|.*|server=/&/127.0.0.1#${eport}|" "$DNSCHAIN_CUSTOM_DOM" >> "$tmp_split"
		[ "$have_china" = "1" ] && \
			sed 's|.*|nftset=/&/4#inet#ss_spec#china|' "$DNSCHAIN_CUSTOM_DOM" >> "$tmp_nft"
	fi

	# 兜底：保留上一版的 nftset 行（重建窗口内不丢代理链路）
	if [ "$keep_prev_nft" = "1" ]; then
		grep '^nftset=' "$out" 2>/dev/null >> "$tmp_nft" || true
	fi

	n_split=$(wc -l < "$tmp_split" 2>/dev/null || echo 0)
	n_nft=$(wc -l < "$tmp_nft" 2>/dev/null || echo 0)

	{
		echo "# dnschain: 域名分流（由 init.d/dnschain 生成，勿手工编辑）"
		echo "# 数据库国外 + 自定义国外 → :${fport}（代理出口）"
		echo "# 自定义国内            → :${eport}（直连出口，并写入 china 集强制直连）"
		echo "# 观测域名不在此文件：它们由 watch.servers（--servers-file）动态决定，"
		echo "#   同一域名只能有一处 server= 声明，否则 dnsmasq 会当成候选随机选。"
		cat "$tmp_split"
		[ "$n_nft" -gt 0 ] && {
			echo "# nftset: 解析结果写入对应 IP 集"
			cat "$tmp_nft"
		}
	} > "$out"

	rm -f "$tmp_dom" "$tmp_split" "$tmp_nft" "$watch_f"
	echo "${n_split} ${n_nft}"
}

# ------------------------------------------------------------
# 生成观测域名的动态上游文件（watch.servers）
#
# 走 dnsmasq 的 --servers-file：该文件在收到 SIGHUP 时会被
# **重新读取**（dnsmasq.c 的 EVENT_RELOAD 分支显式调用
# read_servers_file），因此改道只需 SIGHUP，不需要重启 dnsmasq。
#
# 这一点是本设计的稳定性基石：AGENTS §4.4 已实测「reload 不重读
# conf-dir」，所以静态片段改动必须 restart（约 3 秒中断）；
# 而改道是高频事件，绝不能走 restart。servers-file 正好提供了
# 一条「不重启也能换上游」的通道。
#
# 输出：changed | same
# ------------------------------------------------------------
dc_gen_watch_servers() {
	local eport fport tmp enabled d pref active

	eport=$(dc_get main entry_port 5353)
	fport=$(dc_get main foreign_port 5336)
	enabled=$(dc_get health enabled 1)

	# ⚠️ 必须建**目标文件所在目录**，不是 RUN_DIR（v0.14.3 修 M5）。
	#
	#   原写法 mkdir 的是 $DNSCHAIN_RUN_DIR（/var/etc/dnschain），
	#   而文件 mv 到 $DNSCHAIN_WATCH_SERVERS（/var/run/dnsmasq/）。
	#   后者由 dnsmasq 自己创建 —— 首刷时（uci-defaults 阶段）
	#   若 dnsmasq 尚未启动过，mv 就失败 → 本函数 return 1 →
	#   generate_all return 1 → start_service 直接「生成运行时配置失败，
	#   中止启动」，整条框架起不来，而错误信息不指向目录缺失。
	_watch_dir=$(dirname "$DNSCHAIN_WATCH_SERVERS")
	mkdir -p "$_watch_dir" 2>/dev/null || {
		dnschain_log "ERROR: 无法创建 watch.servers 目录 ${_watch_dir}"
		return 1
	}

	tmp=$(mktemp) || return 1

	{
		echo "# dnschain: 观测域名的动态上游（SIGHUP 生效，勿手工编辑）"
		echo "# 由 /usr/bin/dnschain-health 维护；改道只改本文件 + SIGHUP"
	} > "$tmp"

	dc_watch_list | while read -r d; do
		[ -n "$d" ] || continue
		pref=$(dc_domain_preferred "$d")
		active="$pref"
		if [ "$enabled" = "1" ]; then
			active=$(dc_health_active "$d" "$pref")
		fi
		# ── 分诊结论优先于归属（v0.16.0）─────────────────────
		#
		# 分诊（dnschain-triage）的结论是**实测**得到的：
		# 它真的发请求验证过直连通不通、代理通不通。
		# 而归属（dc_domain_preferred）只是查库，库不全时会判错。
		#
		# 实测教训：cdn.staticsfile.org 不在任何库里 → 归属判 domestic
		# 是「猜的」；分诊实测发现直连通，才把它落进 china。
		# 两者一致时无影响；不一致时以**实测**为准。
		#
		# ⚠️ 只覆盖「有分诊记录」的域名，无记录的仍按原逻辑走 ——
		#    不能让分诊未覆盖的域名失去健康检测与自动改道能力。
		_tri=$(dc_triage_verdict "$d")
		case "$_tri" in
			direct)  active="domestic" ;;
			proxy)   active="foreign"  ;;
		esac
		case "$active" in
			foreign)  echo "server=/$(echo "$d")/127.0.0.1#${fport}" ;;
			*)        echo "server=/$(echo "$d")/127.0.0.1#${eport}" ;;
		esac
	done >> "$tmp"

	if [ -r "$DNSCHAIN_WATCH_SERVERS" ] && cmp -s "$tmp" "$DNSCHAIN_WATCH_SERVERS"; then
		rm -f "$tmp"
		echo "same"
		return 0
	fi

	mv -f "$tmp" "$DNSCHAIN_WATCH_SERVERS" || return 1

	# ⚠️ 必须放开读权限，否则 dnsmasq 根本读不到这个文件（v0.13.0 实测）：
	#
	#   mktemp 生成的文件是 0600 root:root，而本固件的 dnsmasq 由 ujail
	#   降权到 uid 453（dnsmasq 用户）运行。实测 /proc/<pid>/status:
	#       Uid: 453 453 453 453
	#   于是 600 root:root 的文件它读不到 —— SIGHUP 看似成功，
	#   servers-file 却一条都没加载，改道完全无效（且没有任何报错）。
	#
	#   症状：watch.servers 内容正确、dnsmasq 也在跑、SIGHUP 也没报错，
	#   但观测域名走的一直是 gfw_list 里的旧上游（:5335，无监听）
	#   → 实测 github.com 经 :53 稳定超时，而直连 :5336 / :5353 都正常。
	#
	#   故这里显式 0644。这不是「放松安全」，而是让降权后的进程读得到：
	#   该文件只含域名与本地回环端口，不含任何凭据。
	chmod 0644 "$DNSCHAIN_WATCH_SERVERS" 2>/dev/null

	echo "changed"
}

# ------------------------------------------------------------
# 让 dnsmasq 重读 servers-file（SIGHUP：不重启、不清缓存）
#
# 注意：这里**不用** init.d/dnsmasq restart。改道是可能每分钟
# 发生的事，restart 会带来约 3 秒的解析中断（AGENTS §4.4）。
# ------------------------------------------------------------
dc_reload_servers_file() {
	local pid
	pid=$(dc_dnsmasq_pid)
	[ -n "$pid" ] || { dnschain_log "WARN: dnsmasq 未运行，跳过 SIGHUP"; return 1; }
	kill -HUP "$pid" 2>/dev/null || return 1
	return 0
}

# ------------------------------------------------------------
# 带硬超时的命令执行
#
# 用法: dc_run_timeout <秒> <输出文件> <命令...>
#   stdout: "0" = 命令正常结束；"1" = 命中硬超时
#   命令的 stdout+stderr 全部写进 <输出文件>
#
# 为什么状态码走 stdout 而不是变量：
#   调用方几乎总是写 out=$(dc_run_timeout ...)，而命令替换在**子 shell**
#   里执行 —— 函数内给变量赋值（如 DC_TIMEOUT_HIT=1）在父 shell 里
#   看不到，超时会被静默当成「命令返回空」。这个坑必须从接口上避开。
#
# 为什么需要硬超时：BusyBox 的 nslookup 没有 -timeout 参数，
# 链路不通时它会按 resolv.conf 的 timeout/attempts 卡住 5~15 秒。
# 探测循环里 10 个域名就能把一轮拖成分钟级。
#
# 为什么不用 `timeout` 命令：本固件不保证装了 coreutils 的 timeout，
# 而这里必须「一定」有超时。故用「后台子进程 + 完成标记文件」：
#   - 子进程跑完写标记 → 主流程看到标记即返回
#   - 到点没标记 → 发 TERM，包装层 trap 再杀真实命令
# 不能只用 kill -0 判活：子进程退出后会变成僵尸，kill -0 依然成功，
# 会白等满整个超时（这是踩过的坑，标记文件是必需的）。
# ------------------------------------------------------------
# 为什么这里没有「亚秒 sleep」辅助函数（v0.14.2 清理）
#
# 曾经有 dc_sleep_tick / dc_ticks_per_sec 两个函数，用于给
# dc_run_timeout 提供轮询粒度。但实测查明 OpenWrt 的 BusyBox：
#   · `sleep 0.05` / `sleep 0.1`  **直接失败**（只支持整数秒）
#   · `read -t 0.1`              报 `invalid timeout`
#   · `usleep`                   不存在
# 即**拿不到亚秒粒度**。故 dc_run_timeout 改为「紧密轮询 + 每 2000 转
# 才 sleep 1 秒」：快命令（nslookup 仅 0.02~0.4s）几乎零等待返回，
# 慢命令也不会忙等烧 CPU。两个辅助函数随之成为死代码，已删除。
#
# ⚠️ v0.14.9 补正：上面「快命令几乎零等待返回」这个判断**不成立**。
#    「每 2000 转才 sleep 1 秒」的实际后果是：任何耗时超过 2000 转
#    （实测约 20ms）的命令都会落进 sleep 1 分支，醒来时命令早已完成，
#    但要再等满 1 秒才复查标记 → **20ms~1020ms 的命令一律被向上取整
#    到约 1020~1070ms**。详见下面 dc_run_timeout 里的实测数据。
#    现在改用 dc_clock_ms 做真实毫秒时钟，这段历史保留以便对照。
# ------------------------------------------------------------
# ------------------------------------------------------------
# 单调毫秒时钟（纯 shell，无 fork）
#
# 用法: dc_clock_ms  → 结果写进变量 DC_CLOCK_MS
#
# 为什么不用 `date +%s%N`：BusyBox 的 date 不支持 %N（会静默返回秒级），
# 也不支持 `stat`。`/proc/uptime` 是唯一可靠的亚秒时钟来源。
# 用 `read` 内置命令读，不起子进程（实测 200 次 < 10ms）。
# ------------------------------------------------------------
dc_clock_ms() {
	local _u _s _f
	read -r _u _ < /proc/uptime
	_s=${_u%.*}
	_f=${_u#*.}
	# 去掉前导 0（"05" 在 $(( )) 里会被当成八进制 → 解析错误）
	while [ "${_f#0}" != "$_f" ]; do _f=${_f#0}; done
	[ -n "$_f" ] || _f=0
	DC_CLOCK_MS=$((_s * 1000 + _f * 10))
}

dc_run_timeout() {
	local secs out flag pid np spin fine_budget deadline

	secs="$1"
	out="$2"
	shift 2

	# 用固定路径而不是 mktemp：超时判定要读标记，多一个临时文件
	# 就多一处可能残留（重启前 /tmp 不会自动清）。
	flag="${out}.done"
	rm -f "$out" "$flag"

	# 包装子 shell 的三件事：
	#   ① 把真实命令放后台，自己 wait —— 这样 TERM 能打断 wait 进 trap
	#   ② trap 里 kill 掉真实命令的子进程，避免 nslookup 变成孤儿继续
	#      跑到 dnsproxy 自己的 8 秒超时（否则一轮探测会堆出十几个残留）
	#   ③ 正常结束时写完成标记
	(
		trap 'kill "$np" 2>/dev/null; exit 1' TERM INT
		"$@" > "$out" 2>&1 &
		np=$!
		wait "$np"
		: > "$flag"
	) &
	pid=$!

	# ── 等待策略（v0.14.9 重写，务必按这里的思路改）──────────────
	#
	# 约束：BusyBox 的 `sleep` **只支持整数秒**，`read -t` 不支持小数
	#      （实测报 `read: invalid timeout`），也没有 `usleep`。
	#      所以**拿不到亚秒粒度的 sleep**。
	#
	# ⚠️ 原实现是「每转 2000 次就 sleep 1 秒」，有一个被忽略的后果
	#    （v0.14.9 实测定位，这是自检最大的一处隐性开销）：
	#
	#      命令只要耗时超过「2000 转」（实测约 20ms），就会落进
	#      `sleep 1` 分支；醒来时命令**早已完成**，但要等到 1 秒后才
	#      再看标记。于是**任何 20ms~1020ms 的命令都被向上取整到约
	#      1020~1070ms**。实测（冷缓存，同一台路由器）：
	#
	#        google A  真实 220~540ms → 经 dc_run_timeout 恒为 1070ms
	#        google AAAA          同上 → 1070ms
	#
	#      也就是说：自检第 10/11 项的 1070ms 里，**只有约 500ms 是
	#      真实网络往返，另外约 530ms 是纯等待策略的量化误差**。
	#      这不是网络慢，改上游/换节点都治不好。
	#
	# 解法：用 `/proc/uptime`（纯 shell，无 fork）做真实时钟，
	#      在 `fine_budget` 毫秒内**紧密轮询**，之后才退回 `sleep 1`。
	#
	#      · fine_budget 覆盖实测最慢的正常答复（google A 冷 540ms）
	#        并留余量 → 正常答复的量化误差降到约 10ms
	#      · 超过 fine_budget 仍无标记（真正挂死的链路）→ 退回原来的
	#        sleep 1 轮询，CPU 不会长时间被占满，超时语义不变
	#      · 超时判定仍走 `kill -TERM` + 完成标记，**没有改动**
	#        dc_run_timeout 的对外契约（约束 18/19/44）：
	#        stdout 输出 0/1、成功路径删除 `.done`、超时发 TERM
	fine_budget=1200
	dc_clock_ms
	deadline=$((DC_CLOCK_MS + secs * 1000))
	local fine_end
	fine_end=$((DC_CLOCK_MS + fine_budget))

	# 先检查一次：命令若已瞬间完成，零等待返回
	if [ -f "$flag" ]; then
		wait "$pid" 2>/dev/null
		rm -f "$flag" 2>/dev/null
		echo 0
		return 0
	fi

	while :; do
		# 紧密轮询一批，再读一次真实时钟
		#
		# 2000 转实测约 20ms（纯 shell 循环，无 fork），即每 20ms 读一次
		# /proc/uptime。读时钟本身很便宜（read 是内置命令），但会走一次
		# 文件打开，故按批读而不是每转都读。
		spin=0
		while [ "$spin" -lt 2000 ]; do
			if [ -f "$flag" ]; then
				wait "$pid" 2>/dev/null
				rm -f "$flag" 2>/dev/null
				echo 0
				return 0
			fi
			spin=$((spin + 1))
		done

		dc_clock_ms

		# 到点：kill 掉包装层，其 trap 再杀真实命令
		#
		# 此刻 $pid 必然是「还在跑」或「已退出但未被 wait 回收的僵尸」。
		# 僵尸的 pid 在回收前不会被复用，故这里 kill 一定落在自己人身上。
		if [ "$DC_CLOCK_MS" -ge "$deadline" ]; then
			kill -TERM "$pid" 2>/dev/null
			wait "$pid" 2>/dev/null
			echo 1
			return 0
		fi

		# 超出紧密轮询预算：只有在「剩余时间还超过 1 秒」时才 sleep 1，
		# 否则继续紧密轮询直到到点。
		#
		# ⚠️ 这里不能无条件 sleep 1（v0.14.9 实测修正）：
		#    剩余不足 1 秒时 sleep 1 会**越过** deadline —— 实测 2 秒超时
		#    变成了 2270ms（原实现是 2000ms）。超时精度变差会让调用方的
		#    重试节奏漂移，也偏离约束 19 的语义。
		#    改为「够 1 秒才睡，不够就紧密轮询」，最坏多耗 1 秒 CPU
		#    （与原来每轮转 2000 次的开销同量级），但到点精确。
		if [ "$DC_CLOCK_MS" -ge "$fine_end" ] \
			&& [ $((deadline - DC_CLOCK_MS)) -gt 1000 ]; then
			sleep 1
		fi
	done
}

# ------------------------------------------------------------
# DNS 查询结果分类：OK / EMPTY / NX / TIMEOUT / FAIL
#
# 用法: dc_dns_class <域名> <服务器[:端口]> [qtype] [超时秒]
#
# 五分类的判据与「为什么不能把 EMPTY 当失败」见 AGENTS §5.1：
#   OK      rcode=0 且 ancount>0
#   EMPTY   rcode=0 且 ancount=0   ← NODATA，不是故障
#   NX      NXDOMAIN
#   TIMEOUT 完全无响应（硬超时命中，或 nslookup 报 timed out）
#   FAIL    其它错误
#
# 统计答案行用 awk 而不是 `grep -vc`：
# grep 无匹配时退出码为 1，`|| echo 0` 会追加第二个 0，
# 得到 "0\n0"，随后的 [ -gt ] 直接报错。awk 没有这个陷阱。
# ------------------------------------------------------------
dc_dns_class() {
	local name server qtype tmo ofile hit out an

	name="$1"
	server="$2"
	qtype="${3:-a}"
	tmo="${4:-2}"

	ofile=$(mktemp) || { echo "FAIL"; return 0; }

	if [ "$qtype" = "a" ]; then
		hit=$(dc_run_timeout "$tmo" "$ofile" nslookup "$name" "$server")
	else
		hit=$(dc_run_timeout "$tmo" "$ofile" nslookup "-type=${qtype}" "$name" "$server")
	fi
	out=$(cat "$ofile" 2>/dev/null)
	rm -f "$ofile"

	[ "$hit" = "1" ] && { echo "TIMEOUT"; return 0; }

	case "$out" in
		*NXDOMAIN*|*"does not exist"*) echo "NX"; return 0 ;;
		*"timed out"*|*"no servers could be reached"*|*"can't resolve"*)
			echo "TIMEOUT"; return 0 ;;
	esac

	an=$(printf '%s\n' "$out" | awk '
		/^Address:/ {
			a = $0
			sub(/^Address:[ \t]*/, "", a)
			if (a ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+$/) next
			if (a ~ /^\[.*\]:[0-9]+$/) next
			n++
		}
		END { print n + 0 }')

	if [ "${an:-0}" -gt 0 ] 2>/dev/null; then
		echo "OK"
		return 0
	fi

	case "$out" in
		*"Address:"*) echo "EMPTY" ;;
		*)            echo "FAIL" ;;
	esac
}

# 取第一个解析出的地址（用于「两条链答案是否一致」的判断）
dc_dns_first_addr() {
	local name server qtype tmo ofile out

	name="$1"; server="$2"; qtype="${3:-a}"; tmo="${4:-2}"

	ofile=$(mktemp) || return 0

	if [ "$qtype" = "a" ]; then
		dc_run_timeout "$tmo" "$ofile" nslookup "$name" "$server" >/dev/null
	else
		dc_run_timeout "$tmo" "$ofile" nslookup "-type=${qtype}" "$name" "$server" >/dev/null
	fi
	out=$(cat "$ofile" 2>/dev/null)
	rm -f "$ofile"

	printf '%s\n' "$out" | sed -n 's/^Address: \([0-9a-fA-F.:]*\)$/\1/p' | head -1
}

# ------------------------------------------------------------
# 健康状态读写
#
# 状态文件一行一个域名，字段用 | 分隔（域名里不会出现 |）：
#   domain|preferred|active|fail|ok|last_epoch|last_result
#
# 为什么落盘在 /var/run：改道状态是运行时事实，重启即失效重算。
# 持久化反而危险 —— 断电前的「已改道」不该在下次开机继续生效，
# 那时链路可能是好的。
# ------------------------------------------------------------

# 可选预加载：把整个状态文件读进变量，之后 dc_health_read 在内存里查
#
# 用法: dc_health_prime   （先调它，再连续读多个域名的字段）
#
# ⚠️ 不 prime 时 dc_health_read 的行为与原来**完全一致**（走 awk），
#    所以其它调用点（cycle / explain / 页面）不需要任何改动。
#
# 为什么值得：status 对 8 个域名读 5 个字段 = 40 次 dc_health_field，
# 每次 2 次 fork（awk 找行 + awk 取字段）→ 实测 160ms。
# 状态文件只有几百字节、十几行，整份读进变量后每次查表都是纯 shell 比较。
dc_health_prime() {
	_DC_HEALTH_BLOB=""
	_DC_HEALTH_LOADED=0
	[ -r "$DNSCHAIN_HEALTH_STATE" ] || return 0
	_DC_HEALTH_BLOB=$(cat "$DNSCHAIN_HEALTH_STATE" 2>/dev/null)
	_DC_HEALTH_LOADED=1
	return 0
}

# 写状态文件后必须让预加载缓存失效，否则同一进程里读到的还是旧内容
dc_health_prime_invalidate() {
	_DC_HEALTH_LOADED=0
	_DC_HEALTH_BLOB=""
	return 0
}

dc_health_read() {
	local d line rest nl
	d="$1"
	[ -r "$DNSCHAIN_HEALTH_STATE" ] || return 1

	# 已预加载：在内存里按「首字段精确等于 $d」找第一行
	#
	# 判据与 awk 的 `$1 == d` 等价：域名不含 |，故命中当且仅当
	# 整行等于 $d（只有一列的退化行）或以 "$d|" 开头。
	if [ "${_DC_HEALTH_LOADED:-0}" = "1" ]; then
		nl='
'
		rest="$_DC_HEALTH_BLOB"
		while [ -n "$rest" ]; do
			line=${rest%%"$nl"*}
			case "$rest" in
				*"$nl"*) rest=${rest#*"$nl"} ;;
				*)       rest="" ;;
			esac
			case "$line" in
				"$d"|"$d"\|*) printf '%s\n' "$line"; return 0 ;;
			esac
		done
		return 1
	fi

	line=$(awk -F'|' -v d="$d" '$1 == d { print; exit }' "$DNSCHAIN_HEALTH_STATE" 2>/dev/null)
	[ -n "$line" ] || return 1
	echo "$line"
}

# 从一行状态记录里取第 n 个字段（纯 shell，不 fork）
#
# 语义与 `echo "$line" | awk -F'|' -v n=N '{ print $n }'` 逐字节一致：
#   · 字段不足时输出空行（awk 对 n > NF 打印空）
#   · 分隔符是**单个** |，连续 || 之间是空字段
# 已用 8 组输入实测对照（含越界 n），见 CHANGELOG 验证段。
_dc_field() {
	local l n
	l="$1"
	n="$2"
	while [ "$n" -gt 1 ]; do
		case "$l" in
			*'|'*) l=${l#*'|'} ;;
			*)     l=""; break ;;
		esac
		n=$((n - 1))
	done
	case "$l" in
		*'|'*) printf '%s\n' "${l%%'|'*}" ;;
		*)     printf '%s\n' "$l" ;;
	esac
}

# 取字段：dc_health_field <domain> <1..7>
dc_health_field() {
	local line
	line=$(dc_health_read "$1") || return 1
	_dc_field "$line" "$2"
}

# 当前生效链路（无状态时回落到首选）
dc_health_active() {
	local pref active
	pref="$2"
	[ -n "$pref" ] || pref=$(dc_domain_preferred "$1")
	active=$(dc_health_field "$1" 3)
	case "$active" in
		domestic|foreign) echo "$active" ;;
		*)                echo "$pref" ;;
	esac
}

# ------------------------------------------------------------
# 分诊结论查询（v0.16.0）
#
# 返回：direct / proxy / dead / 空（无记录）
#
# 为什么要读分诊记录而不只是查库：分诊是**实测**结论（真的发了
# 请求验证直连与代理哪条通），而归属库只是静态数据、会不全。
# 两者冲突时以实测为准。
#
# 记录文件由 /usr/bin/dnschain-triage 维护：
#   /etc/dnschain/triage-domain.list   <域名>|<domestic|foreign|dead>
#   /etc/dnschain/triage-ip.list       <IP>|<direct|proxy|dead>
#
# 这里只读域名表（watch.servers 是按域名写的）；IP 表用于集合重放。
# ------------------------------------------------------------
dc_triage_verdict() {
	local d="$1" f="/etc/dnschain/triage-domain.list" v
	[ -r "$f" ] || return 0
	v=$(awk -F'|' -v d="$d" '$1 == d { print $2; exit }' "$f" 2>/dev/null)
	case "$v" in
		domestic) echo "direct" ;;
		foreign)  echo "proxy" ;;
		dead)     echo "dead" ;;
		*)        : ;;
	esac
}

# 状态文件写入的唯一实现（dc_health_write / _keep_last 都走这里）
#
# 为什么要抽出来（v0.14.2）：原来两个函数各自复制了一整段
# 「读旧文件 → awk 过滤同域名 → printf 追加 → mv」，只差 `last`
# 的取值方式。两份同样的写盘逻辑，改一处忘另一处就会让两个入口
# 写出格式不同的状态文件（而 status/页面都按 7 字段解析）。
#
# 参数：域名 首选 当前 失败数 成功数 last 结果
# 观测域名数量级是十位，整体重写成本可忽略。
dc_health_upsert() {
	local d pref active fail ok last res tmp

	d="$1"; pref="$2"; active="$3"; fail="$4"; ok="$5"; last="$6"; res="$7"

	mkdir -p "$DNSCHAIN_STATE_DIR" || return 1
	tmp=$(mktemp) || return 1

	if [ -r "$DNSCHAIN_HEALTH_STATE" ]; then
		awk -F'|' -v d="$d" '$1 != d' "$DNSCHAIN_HEALTH_STATE" > "$tmp" 2>/dev/null
	fi

	printf '%s|%s|%s|%s|%s|%s|%s\n' \
		"$d" "$pref" "$active" "$fail" "$ok" "$last" "$res" >> "$tmp"

	mv -f "$tmp" "$DNSCHAIN_HEALTH_STATE" || return 1

	# 状态文件已变，预加载缓存必须失效（否则同进程里读到旧内容）
	dc_health_prime_invalidate
}

# 写入/更新一行，last 由调用方给定（改道/首次探测时用 now）
dc_health_write() {
	dc_health_upsert "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# 更新一行但**保留原来的 last**
#
# 用途：改道后的「等回切」阶段。
#
# `last` 的语义是「上次**改道**发生的时刻」，`min_dwell` 用它算
# 「改道后至少停留多久」。若等待期间每轮都把它刷成 now，
# `now - last` 恒为 0 → dwell 永远不满足 → **回切被永久阻塞**。
#
# 实测（v0.13.0）：ok 计数涨到 12（阈值 3），状态一直停在
# `recover-wait:OK`，watch.servers 一直指向 :5336，
# 首选链早已恢复却不回切。这条正是「只测改道不测回切」会漏掉的。
dc_health_write_keep_last() {
	local d pref active fail ok res last

	d="$1"; pref="$2"; active="$3"; fail="$4"; ok="$5"; res="$6"

	# 取不到旧 last 时退回 now（首轮没有历史）
	last=$(dc_health_field "$d" 6 2>/dev/null)
	[ -n "$last" ] || last=$(date +%s 2>/dev/null || echo 0)

	dc_health_upsert "$d" "$pref" "$active" "$fail" "$ok" "$last" "$res"
}

# 状态表（供页面与 status 子命令读取）
# 输出：domain|pref|active|fail|ok|last|res
dc_health_state_dump() {
	[ -r "$DNSCHAIN_HEALTH_STATE" ] || return 0
	cat "$DNSCHAIN_HEALTH_STATE"
}

# 自定义列表的条数（页面统计用；列表本身由 dc_gen_custom_lists 落盘）
dc_custom_count() {
	local n
	case "$1" in
		domestic) n=$(wc -l < "$DNSCHAIN_CUSTOM_DOM" 2>/dev/null || echo 0) ;;
		foreign)  n=$(wc -l < "$DNSCHAIN_CUSTOM_FOR" 2>/dev/null || echo 0) ;;
		*)        echo 0; return 0 ;;
	esac
	echo "${n:-0}"
}

# ------------------------------------------------------------
# 一轮健康探测与改道判定
#
# 前置条件（缺一不可，否则整轮跳过、不改任何状态）：
#   1. 框架启用
#   2. 两个 dnsproxy 实例都在监听
#      —— 本地实例没起来时探测必然超时，此时改道是纯误判，
#         会把所有域名在开机阶段翻一遍。
#   3. health.enabled=1
#
# 判定（每个观测域名）：
#   r_pref = 探测首选链
#   r_other = 探测另一条链（仅在需要时探，省一半查询）
#
#   情形 A 当前 == 首选：
#     r_pref 通         → 计数清零
#     r_pref 不通       → fail++；若 fail ≥ 阈值 且 r_other 通 → 改道到另一条
#   情形 B 当前 == 另一条（已改道）：
#     r_pref 通         → ok++；若 ok ≥ 恢复阈值 且 停留时长 ≥ 最小驻留 → 回切
#     r_pref 不通       → ok 清零，保持现状
#
# 两条需求规则如何落在这里：
#   · 国外链路不通 → 改直连：数据库国外域名首选 foreign，
#     情形 A 命中，另一条链是 domestic（直连出口）→ 切直连。
#   · 国内链路不通 → 改代理：未覆盖域名首选 domestic（dnsmasq 默认上游），
#     情形 A 命中，另一条链是 foreign（代理出口）→ 切代理。
#
# 双链路都不通时不改道：那不是分流问题，改道只会掩盖故障。
# 此时保持当前链路并标记 both-bad，页面会直接提示去查链路。
# ------------------------------------------------------------
dc_health_cycle() {
	local enabled eport fport tmo retries fail_thr ok_thr dwell
	local d pref other active fail ok last res r_pref r_other
	local now decision changed
	local n_ok n_switch n_bad n_wait

	enabled=$(dc_get main enabled 1)
	[ "$enabled" = "1" ] || { echo "SKIP 框架未启用"; return 0; }
	[ "$(dc_get health enabled 1)" = "1" ] || { echo "SKIP 健康检测未启用"; return 0; }

	# ── 互斥：同一时刻只允许一轮 cycle（v0.14.2）─────────────────
	#
	# 为什么需要：daemon 每 interval 秒跑一轮，而页面「立即探测一轮」
	# 按钮随时可触发。两轮并发时 dc_health_upsert 的
	# 「读旧文件 → 过滤 → 写临时文件 → mv」不是原子的 ——
	# 后完成的进程会用自己那份（少了对方新增行）覆盖前者，导致
	# 状态文件丢行。丢行后 status 少算域名，页面汇总对不上。
	#
	# 用 mkdir 做锁（POSIX 里 mkdir 是原子的，且 BusyBox 一定有）。
	# 不加 `flock`：BusyBox 未必编译该命令。
	#
	# 拿不到锁就直接放弃本轮 —— 下一轮 interval 会再来，
	# 比排队等待更合适（排队会让 daemon 的周期逐渐漂移）。
	eport=$(dc_get main entry_port 5353)
	fport=$(dc_get main foreign_port 5336)

	# ⚠️ 实例就绪检查必须在**取锁之前**（v0.14.3 修）。
	#
	#   原顺序是「取锁 → 检查实例 → 不就绪就 return」，而那条 return
	#   不释放锁。daemon 是常驻进程、`$$` 恒定不变，于是：
	#     · 某一轮撞上 dnsproxy 未监听（开机时序 / dnsproxy 被 procd 重启
	#       / 手动 stop-start）→ 锁写下且永不删除
	#     · 后续每一轮 mkdir 失败 → 读到 holder pid → /proc/<pid> 存在
	#       （就是自己）→ 打印「SKIP 已有一轮探测在跑」→ 永久跳过
	#   结果：**改道功能从此完全停止**，而日志里是「正常 SKIP」、
	#   页面只是状态不再更新 —— 最难看出来的那种失效。
	#   实测复现：同一进程连跑 3 轮，第 2/3 轮均被自己的锁挡住。
	#
	#   现在把检查前移：不就绪时**根本没取锁**，直接返回是安全的。
	if ! dc_port_listening "$eport" udp || ! dc_port_listening "$fport" udp; then
		echo "SKIP 本地 dnsproxy 实例未就绪（:${eport} / :${fport}）"
		return 0
	fi

	local lockd
	lockd="$DNSCHAIN_STATE_DIR/.cycle.lock"
	if ! mkdir "$lockd" 2>/dev/null; then
		# 锁目录存在：检查持有者是否还活着（防上次异常退出留死锁）
		local holder
		holder=$(cat "$lockd/pid" 2>/dev/null)
		if [ -n "$holder" ] && [ -d "/proc/$holder" ]; then
			echo "SKIP 已有一轮探测在跑（pid=$holder）"
			return 0
		fi
		# 死锁：清掉重来（此时仍没拿到锁，直接返回即可）
		rm -rf "$lockd" 2>/dev/null
		mkdir "$lockd" 2>/dev/null || { echo "SKIP 取锁失败"; return 0; }
	fi
	echo $$ > "$lockd/pid" 2>/dev/null

	tmo=$(dc_get health timeout 2)
	retries=$(dc_get health retries 2)
	fail_thr=$(dc_get health fail_threshold 2)
	ok_thr=$(dc_get health recover_threshold 3)
	dwell=$(dc_get health min_dwell 120)

	now=$(date +%s 2>/dev/null || echo 0)
	changed=0
	n_ok=0; n_switch=0; n_bad=0; n_wait=0

	for d in $(dc_watch_list); do
		[ -n "$d" ] || continue

		pref=$(dc_domain_preferred "$d")
		case "$pref" in
			foreign) other="domestic" ;;
			*)       other="foreign" ;;
		esac

		active=$(dc_health_active "$d" "$pref")
		fail=$(dc_health_field "$d" 4)
		ok=$(dc_health_field "$d" 5)
		last=$(dc_health_field "$d" 6)
		[ -n "$fail" ] || fail=0
		[ -n "$ok" ] || ok=0
		[ -n "$last" ] || last=0

		# 自定义补全的域名**同样参与**健康检测与改道（v0.14.0 语义矫正）。
		#
		# 这里曾经有一段 `if dc_domain_fixed "$d"; then ... continue`，
		# 把自定义域名直接跳过、只记录健康。那是错的：
		# 自定义列表的作用是补全「归属」，归属只决定**首选**链，
		# 而首选链不通时仍应改道。跳过改道等于让用户显式写下的域名
		# 反而失去了自动恢复能力 —— 与需求 2/3 直接冲突。
		#
		# 现在所有观测域名走同一套判定，不设例外。

		r_pref=$(dc_probe_chain "$d" "$pref" "$tmo" "$retries")

		if [ "$active" = "$pref" ]; then
			if [ "$r_pref" = "OK" ] || [ "$r_pref" = "EMPTY" ]; then
				dc_health_write "$d" "$pref" "$pref" 0 0 "$now" "$r_pref"
				n_ok=$((n_ok + 1))
				continue
			fi

			# 首选链不通：只有另一条链确实通，才允许改道
			r_other=$(dc_probe_chain "$d" "$other" "$tmo" "$retries")

			case "$r_other" in
				OK|EMPTY)
					fail=$((fail + 1))
					if [ "$fail" -ge "$fail_thr" ]; then
						dc_health_write "$d" "$pref" "$other" 0 0 "$now" \
							"switch:$r_pref->$r_other"
						dnschain_log "改道: ${d} ${pref}(${r_pref}) → ${other}"
						changed=1
						n_switch=$((n_switch + 1))
					else
						dc_health_write "$d" "$pref" "$pref" "$fail" 0 "$now" \
							"probe:$r_pref"
						n_bad=$((n_bad + 1))
					fi
					;;
				*)
					# 两条链都不通：不是分流问题，不动策略
					dc_health_write "$d" "$pref" "$pref" 0 0 "$now" \
						"both-bad:$r_pref/$r_other"
					n_bad=$((n_bad + 1))
					;;
			esac
			continue
		fi

		# 已改道：观察首选链是否恢复
		if [ "$r_pref" = "OK" ] || [ "$r_pref" = "EMPTY" ]; then
			ok=$((ok + 1))

			# ⚠️ `last` 是**上次改道的时刻**，不是上次探测的时刻（v0.13.0 实测修正）。
			#
			# 原来这里在 else 分支也调 dc_health_write（会写 last=now），
			# 于是每轮都刷新 last，`now - last` 恒为 0，
			# `min_dwell` 永远不满足 → **回切被永久阻塞**。
			# 实测：ok 计数涨到 12（阈值 3），状态一直停在
			# `recover-wait:OK`，watch.servers 一直指向 :5336，
			# 即使首选链早就恢复了也不回切。
			#
			# 修法：等待期间**不更新 last**，只更新 ok 计数。
			# 这样 last 保持为「改道发生的那一刻」，dwell 才真正是
			# 「改道后至少停留多久」的语义。
			if [ "$ok" -ge "$ok_thr" ] && [ $((now - last)) -ge "$dwell" ] 2>/dev/null; then
				dc_health_write "$d" "$pref" "$pref" 0 0 "$now" "recover:$r_pref"
				dnschain_log "回切: ${d} ${other} → ${pref}（首选链恢复）"
				changed=1
				n_ok=$((n_ok + 1))
			else
				# 只累加 ok 计数，保留原 last
				dc_health_write_keep_last "$d" "$pref" "$other" 0 "$ok" \
					"recover-wait:$r_pref"
				n_wait=$((n_wait + 1))
			fi
		else
			dc_health_write "$d" "$pref" "$other" 0 0 "$now" "fallback:$r_pref"
			n_switch=$((n_switch + 1))
		fi
	done

	# 状态变了就重写 servers-file 并让 dnsmasq 重读（SIGHUP，不重启）
	if [ "$changed" = "1" ]; then
		case "$(dc_gen_watch_servers)" in
			changed) dc_reload_servers_file && \
				dnschain_log "已重写 watch.servers 并 SIGHUP 生效" ;;
			*) : ;;
		esac
	fi

	# wait = 回切等待中（首选链已恢复但未满足 recover_threshold）
	printf 'CYCLE ok=%s switch=%s bad=%s wait=%s\n' \
		"$n_ok" "$n_switch" "$n_bad" "$n_wait"

	# 释放互斥锁（正常路径）
	rm -rf "$lockd" 2>/dev/null

	# ── 分诊（v0.16.0）───────────────────────────────────────
	#
	# 放在释放锁之后：分诊要发真实 HTTP 请求（每个目标 3~6 秒），
	# 持锁跑会把下一轮 cycle 全挡掉。分诊有自己的幂等语义
	# （已落库的目标会判 known 直接跳过），并发跑不会互相破坏。
	#
	# ⚠️ 必须在锁外：否则 daemon 的周期会被分诊拖长，
	#    健康检测的时效性下降（这是本仓库历史上踩过的坑）。
	dc_triage_cycle

	return 0
}

# ------------------------------------------------------------
# 一轮分诊（v0.16.0）
#
# 对「不在任何归属库里」的目标执行：
#   ① 试直连（临时加入 china，发真实请求）
#   ② 直连不通 → 试代理（移入 blacklist，再发请求）
#   ③ 都不通 → 标记 dead
#   ④ 跑通 → 落库（IP 进集合、域名进 custom 列表）
#
# 是否启用由 UCI `dnschain.main.triage_enabled` 控制，默认 1。
#
# ⚠️ 为什么不在 dc_health_cycle 的循环里做：那个循环只处理
#    dc_watch_list() 的观测域名（默认 8 个种子域名）。而分诊要覆盖
#    **客户机实际访问的所有域名**，数据源是 dnsmasq 的查询日志。
#    两者的输入集合不同，硬塞进同一个循环会让语义混乱。
# ------------------------------------------------------------
dc_triage_cycle() {
	local enabled
	enabled=$(dc_get main triage_enabled 1)
	[ "$enabled" = "1" ] || { echo "TRIAGE SKIP 未启用"; return 0; }

	[ -x /usr/bin/dnschain-triage ] || {
		echo "TRIAGE SKIP 脚本缺失"
		return 0
	}

	# 每轮最多分诊多少个目标（防止日志里域名太多拖长周期）
	local max
	max=$(dc_get main triage_max 12)
	case "$max" in ''|*[!0-9]*) max=12 ;; esac

	# 数据源：客户机最近查询过的域名（排除路由器自身）
	local cands
	cands=$(logread 2>/dev/null \
		| grep -oE 'query\[[A-Z]+\] [^ ]+ from 192\.168\.[0-9]+\.[0-9]+' \
		| sed -e 's/^query\[[A-Z]*\] //' -e 's/ from .*$//' \
		| grep -vE '^(localhost|.*\.local|.*\.lan|.*\.arpa)$' \
		| sort -u | head -n "$max")

	[ -n "$cands" ] || { echo "TRIAGE SKIP 无候选"; return 0; }

	# 只分诊「未知」的（已有归属的跳过，triage 内部会再判一次）
	local out
	out=$(/usr/bin/dnschain-triage run $cands 2>/dev/null)
	printf '%s\n' "$out" | grep -E '^(ITEM|SUMMARY)' | sed 's/^/TRIAGE /'
	return 0
}

# ------------------------------------------------------------
# 单域名探测（带重试）
#
# 第二个参数接受两种形式：
#   ① 链路名：foreign | domestic   （按配置取端口）
#   ② 显式端口：127.0.0.1:5336 / 127.0.0.1#5336
#
# ⚠️ 必须支持形式 ②（v0.13.0 实测修正）。
#   原来只认形式 ①，其它一律落到 `*)` 分支 → 取 entry_port。
#   后果：传 `127.0.0.1#59999` 这种「指定端口探测」会被**静默改成**
#   探测 :5353，而 :5353 是活的 → 死端口被判为 OK。
#
#   这是最危险的一类错误：探测判据本身撒谎，于是
#   「链路挂了却不改道」——正是需求 2 要防的场景。
#   实测：dc_probe_chain www.google.com 127.0.0.1#59999 → OK（错）
#
# 为什么要有重试：单次 UDP 丢包很常见（尤其跨境）。
# 一次失败就判定不通会让改道变成随机行为。
# 重试次数取 health.retries，每次独立超时。
# ------------------------------------------------------------
dc_probe_chain() {
	local d chain tmo retries i port r target
	d="$1"; chain="$2"; tmo="${3:-2}"; retries="${4:-2}"

	case "$chain" in
		foreign)  port=$(dc_get main foreign_port 5336) ;;
		domestic) port=$(dc_get main entry_port 5353) ;;
		*)
			# 形式 ②：已经带了端口，直接用
			case "$chain" in
				*:*|*'#'*)
					# nslookup 要 `host:port` 形式，把 `#` 归一成 `:`
					target=$(echo "$chain" | tr '#' ':')
					port=""
					;;
				*)
					port=$(dc_get main entry_port 5353) ;;
			esac
			;;
	esac

	[ -n "${target:-}" ] || target="127.0.0.1:${port}"

	i=0
	while [ "$i" -le "$retries" ]; do
		r=$(dc_dns_class "$d" "$target" a "$tmo")
		case "$r" in
			OK|EMPTY|NX) echo "$r"; return 0 ;;
		esac
		i=$((i + 1))
	done

	echo "$r"
}

# ------------------------------------------------------------
# 决策解释（页面「归属判定」用它把结论摊开给人看）
#
# 输出 KEY=VALUE，一行一个，便于 Lua 侧逐行解析：
#   CLASS / PREFERRED / ACTIVE / WATCH / CUSTOM
#   PROBE_DOMESTIC / PROBE_FOREIGN / ANSWER_DOMESTIC / ANSWER_FOREIGN
#   DECISION / REASON
# ------------------------------------------------------------
dc_explain_domain() {
	local d cls pref active other tmo retries r_dom r_for a_dom a_for
	local watch custom decision reason dom_up for_up

	d=$(dc_domain_normalize "$1")
	cls=$(dc_domain_class "$d")

	echo "DOMAIN=${d}"
	echo "CLASS=${cls}"

	[ "$cls" = "invalid" ] && {
		echo "DECISION=reject"
		echo "REASON=域名格式不合法"
		return 0
	}

	pref=$(dc_domain_preferred "$d")
	case "$pref" in
		foreign) other="domestic" ;;
		*)       other="foreign" ;;
	esac

	active=$(dc_health_active "$d" "$pref")

	watch=0
	dc_watch_list | grep -Fqx "$d" && watch=1

	# CUSTOM=1 只表示「归属由用户在自定义列表里显式补全」，
	# **不再**表示「不参与改道」（v0.14.0 语义矫正）。
	custom=0
	dc_domain_custom "$d" && custom=1

	echo "PREFERRED=${pref}"
	echo "ACTIVE=${active}"
	echo "WATCH=${watch}"
	echo "CUSTOM=${custom}"

	tmo=$(dc_get health timeout 2)
	retries=$(dc_get health retries 2)

	r_dom=$(dc_probe_chain "$d" domestic "$tmo" "$retries")
	r_for=$(dc_probe_chain "$d" foreign "$tmo" "$retries")

	a_dom=$(dc_dns_first_addr "$d" "127.0.0.1:$(dc_get main entry_port 5353)" a "$tmo")
	a_for=$(dc_dns_first_addr "$d" "127.0.0.1:$(dc_get main foreign_port 5336)" a "$tmo")

	echo "PROBE_DOMESTIC=${r_dom}"
	echo "PROBE_FOREIGN=${r_for}"
	echo "ANSWER_DOMESTIC=${a_dom}"
	echo "ANSWER_FOREIGN=${a_for}"

	# 判定必须与 dc_health_cycle 的规则**完全一致** ——
	# 页面上的解释与守护进程的实际动作对不上，是最坏的一类不一致：
	# 用户按解释去排障，却发现系统干的是另一件事。
	# 所以这里也以「首选链」为基准，而不是「先看国内通不通」。
	#
	# ⚠️ v0.14.0：这里曾经有一条 `if fixed → decision=fixed` 的短路，
	# 把自定义域名直接判为「不改道」。那与 dc_health_cycle 现在的行为
	# 矛盾（后者对所有域名都判定改道）。已删除 —— 自定义域名与其它
	# 域名走完全相同的判定路径，只是 preferred 的来源不同。
	dom_up=0
	for_up=0
	case "$r_dom" in OK|EMPTY) dom_up=1 ;; esac
	case "$r_for" in OK|EMPTY) for_up=1 ;; esac

	if [ "$pref" = "foreign" ]; then
		if [ "$for_up" = "1" ]; then
			if [ "$dom_up" = "1" ] && [ -n "$a_dom" ] && [ -n "$a_for" ] && [ "$a_dom" != "$a_for" ]; then
				decision="keep-foreign"
				reason="国外链路可达，走代理；但两条链答案不同（直连 ${a_dom} / 代理 ${a_for}），直连侧疑似污染"
			else
				decision="keep-foreign"
				reason="国外链路可达，按归属走代理"
			fi
		elif [ "$dom_up" = "1" ]; then
			decision="reroute-domestic"
			reason="国外链路 ${r_for} 不可达、国内链路可达 → 改走直连"
		else
			decision="both-bad"
			reason="两条链都不通（直连 ${r_dom} / 代理 ${r_for}）→ 不是分流问题，请查链路"
		fi
	else
		if [ "$dom_up" = "1" ]; then
			if [ "$for_up" = "1" ] && [ -n "$a_dom" ] && [ -n "$a_for" ] && [ "$a_dom" != "$a_for" ]; then
				decision="keep-domestic"
				reason="国内链路可达，走直连；但两条链答案不同（直连 ${a_dom} / 代理 ${a_for}）"
			else
				decision="keep-domestic"
				reason="国内链路可达，按归属走直连"
			fi
		elif [ "$for_up" = "1" ]; then
			decision="reroute-foreign"
			reason="国内链路 ${r_dom} 不可达、国外链路可达 → 改走代理"
		else
			decision="both-bad"
			reason="两条链都不通（直连 ${r_dom} / 代理 ${r_for}）→ 不是分流问题，请查链路"
		fi
	fi

	echo "DECISION=${decision}"
	echo "REASON=${reason}"
}

# ------------------------------------------------------------
# 校验一组上游是否都在 ss_spec_output 的端口集内
# 用法: dc_validate_upstream_ports <url...>
# 返回 0 = 全部合规；1 = 有越界，并把越界的写进 stdout
# ------------------------------------------------------------
dc_validate_upstream_ports() {
	local ports bad url p
	ports=$(dc_output_ports)

	# 拿不到端口集时不阻断（可能 nft 尚未就绪），但记日志
	if [ -z "$ports" ]; then
		dnschain_log "WARN: 读不到 ss_spec_output 端口集，跳过上游端口校验"
		return 0
	fi

	# 用临时文件累积越界项，避免 bash 专有的 $'\n'
	bad=$(mktemp) || return 0
	for url in "$@"; do
		[ -n "$url" ] || continue
		p=$(dc_upstream_port "$url")
		[ -n "$p" ] || continue
		case " $ports " in
			*" $p "*) ;;
			*) echo "${url} (端口 ${p} 不在 ${ports})" >> "$bad" ;;
		esac
	done

	if [ -s "$bad" ]; then
		cat "$bad"
		rm -f "$bad"
		return 1
	fi
	rm -f "$bad"
	return 0
}
