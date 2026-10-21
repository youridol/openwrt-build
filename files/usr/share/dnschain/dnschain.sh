#!/bin/sh
# ============================================================
# dnschain 共用函数库
# ------------------------------------------------------------
# 被 init.d/dnschain、dnschain-reconcile、dnschain-selftest 共同 source。
# 设计依据：docs/adr/0003-dns-chain-framework.md
#
# 约束（AGENTS.md §6 第 11 条）：必须 POSIX sh（dash）兼容。
#   禁止进程替换 <(...)、[[ ]]、数组、local。
# ============================================================

DNSCHAIN_CONF="dnschain"
DNSCHAIN_RUN_DIR="/var/etc/dnschain"
DNSCHAIN_ETC_DIR="/etc/dnschain"
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

dnschain_die() {
	logger -t dnschain "ERROR: $*"
	echo "dnschain: ERROR: $*" >&2
	exit 1
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
dc_ssr_mode_for_profile() {
	local profile
	profile=$(dc_get main profile primary)
	case "$profile" in
		coexist) echo "" ;;   # 不强制，由用户决定
		*)       echo "0" ;;
	esac
}

# ------------------------------------------------------------
# 端口所有权探测：返回监听该端口的 PID（无监听则空）
# 用法: dc_port_owner <port> [proto]
# ------------------------------------------------------------
dc_port_owner() {
	local port proto pid
	port="$1"
	proto="${2:-udp}"

	pid=""
	if [ "$proto" = "udp" ]; then
		pid=$(netstat -lnup 2>/dev/null \
			| awk -v p=":${port}" '$4 ~ p"$" {print $NF}' \
			| sed 's|/.*||' | head -1)
	else
		pid=$(netstat -lntp 2>/dev/null \
			| awk -v p=":${port}" '$4 ~ p"$" {print $NF}' \
			| sed 's|/.*||' | head -1)
	fi
	echo "$pid"
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
	if [ -r "$gfw" ]; then
		total=$((total + $(wc -l < "$gfw")))
		md5s="${md5s}$(md5sum "$gfw" 2>/dev/null | awk '{print $1}')"
	fi
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
	local gfw base
	gfw=$(dc_get lists gfw_source /etc/ssrplus/gfw_list.conf)
	base=$(dc_get lists base_source /etc/ssrplus/gfw_base.conf)

	{
		[ -r "$gfw" ] && sed -n 's|^server=/\([^/]*\)/.*|\1|p' "$gfw"
		[ -r "$base" ] && sed -n 's|^server=/\([^/]*\)/.*|\1|p' "$base"
	} | grep -v '^$' | sort -u
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
# 输出文件：/var/etc/dnschain/foreign-split.conf（dnsmasq 片段）
# 同时把 IDNA 域名写到 idna-bypass.conf（dnsmasq 的 punycode 旁路）。
# ------------------------------------------------------------
dc_gen_upstream_file() {
	local outdir count fport

	outdir="$DNSCHAIN_RUN_DIR"
	fport=$(dc_get main foreign_port 5336)

	mkdir -p "$outdir" || return 1

	# 国外上游必须至少一条
	if [ -z "$(dc_get_list foreign server | head -1)" ]; then
		dnschain_log "ERROR: dnschain.upstream.foreign 为空，无法生成国外分流规则"
		return 1
	fi

	# 国外域名 → 国外 dnsproxy 实例（dnsmasq 的 server= 规则）
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
	# 仍需过滤**非法标签**（不是合法域名的垃圾行）。
	dc_extract_domains \
		| grep -E '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$' \
		| sed "s|.*|server=/&/127.0.0.1#${fport}|" > "${outdir}/foreign-split.conf"

	count=$(wc -l < "${outdir}/foreign-split.conf" 2>/dev/null || echo 0)

	dnschain_log "foreign-split.conf: ${count} 条 → 127.0.0.1#${fport}"
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
# 当前 dnsmasq 的 PID
# ------------------------------------------------------------
dc_dnsmasq_pid() {
	pidof dnsmasq 2>/dev/null | awk '{print $1}'
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
