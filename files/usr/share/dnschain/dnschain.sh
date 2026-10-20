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
# 端口档案
# 返回过滤器应监听的端口。primary=5335，coexist=5337。
# ------------------------------------------------------------
dc_filter_port() {
	local profile
	profile=$(dc_get main profile primary)
	case "$profile" in
		coexist) echo "5337" ;;
		*)       echo "5335" ;;
	esac
}

# 该档案对应的 SSR-Plus pdnsd_enable 值
# 0 = 不启后端（:5335 归框架）；coexist 下允许 1/4/5/6，但框架不强制改
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

# 该 PID 的命令行是否属于框架的 chinadns-ng
dc_is_framework_filter() {
	local pid cmd
	pid="$1"
	[ -n "$pid" ] || return 1
	[ -r "/proc/${pid}/cmdline" ] || return 1
	cmd=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)
	case "$cmd" in
		*chinadns-ng*) return 0 ;;
		*)             return 1 ;;
	esac
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
# 生成 dnsproxy 的域名上游文件
#
# 两条硬约束（ADR §10.1）：
#   1. 必须过滤 xn-- 与非法标签 —— dnsproxy 会**整体拒绝启动**，
#      不是跳过坏条目（实测：idna: invalid label "wcvs22d1m"）。
#   2. 每行形如 [/域名/]127.0.0.1:<filter_port>
#
# 输出文件：/var/etc/dnschain/upstreams-domains.txt
# 同时把被过滤掉的 IDNA 域名写到 idna-skipped.txt 供页面显示。
# ------------------------------------------------------------
dc_gen_upstream_file() {
	local port outdir all filtered skipped count kept
	port=$(dc_filter_port)
	outdir="$DNSCHAIN_RUN_DIR"

	mkdir -p "$outdir" || return 1

	all=$(mktemp "${outdir}/.domains.XXXXXX") || return 1
	dc_extract_domains > "$all"

	# 合法域名：字母数字开头结尾，中间允许 . _ -，至少一个点，顶级域 >= 2 字母
	# 显式排除 xn--（IDNA punycode，dnsproxy 的 idna 解析器不认）
	filtered=$(mktemp "${outdir}/.valid.XXXXXX") || { rm -f "$all"; return 1; }
	grep -vE 'xn--' "$all" \
		| grep -E '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$' \
		> "$filtered"

	skipped=$(mktemp "${outdir}/.idna.XXXXXX") || { rm -f "$all" "$filtered"; return 1; }
	grep -E 'xn--' "$all" > "$skipped"

	sed "s|.*|[/&/]127.0.0.1:${port}|" "$filtered" > "${outdir}/upstreams-domains.txt"
	sed "s|.*|server=/&/127.0.0.1#${port}|" "$skipped" > "${outdir}/idna-bypass.conf"

	count=$(wc -l < "$filtered" 2>/dev/null || echo 0)
	kept=$(wc -l < "$skipped" 2>/dev/null || echo 0)

	rm -f "$all" "$filtered" "$skipped"

	dnschain_log "upstreams-domains.txt: ${count} 条；IDNA 跳过 ${kept} 条（写入 idna-bypass.conf）"
	echo "$count"
}

# ------------------------------------------------------------
# dnsproxy 启动参数（写入 dnsproxy.args，一行一个参数）
# ADR §10.1：刻意不配 --cache*、--fallback、--ipv6-disabled
# ------------------------------------------------------------
dc_gen_dnsproxy_args() {
	local out entry port up domfile
	out="$DNSCHAIN_RUN_DIR/dnsproxy.args"
	entry=$(dc_get main entry_port 5353)
	port=$(dc_filter_port)
	domfile="$DNSCHAIN_RUN_DIR/upstreams-domains.txt"

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

		# 国外域名 → 策略过滤器（文件形式）
		[ -s "$domfile" ] && { echo "--upstream"; echo "$domfile"; }

		# bootstrap 仅用于解析加密上游的主机名（明文是它唯一且应有的用途）
		echo "--bootstrap"
		echo "223.5.5.5"
		echo "--bootstrap"
		echo "223.6.6.6"

		echo "--timeout"
		echo "5s"
		echo "--upstream-mode"
		echo "parallel"

		# hosts
		echo "--hosts-file-enabled=true"
		echo "--hosts-files"
		echo "/etc/hosts"
	} > "$out"

	# 注意：这里**不写** --cache / --cache-optimistic / --cache-size /
	# --cache-min-ttl / --cache-max-ttl / --fallback / --ipv6-disabled。
	# 理由见 ADR §10.1、§10.2、§10.5。
	echo "$out"
}

# ------------------------------------------------------------
# chinadns-ng 启动参数
# ADR §10.3
# ------------------------------------------------------------
dc_gen_filter_args() {
	local out port trust
	out="$DNSCHAIN_RUN_DIR/filter.args"
	port=$(dc_filter_port)

	mkdir -p "$DNSCHAIN_RUN_DIR" || return 1

	# 国外上游列表必须非空，否则 chinadns-ng 会拿到一个空的 -t 参数、
	# 起不来或行为未定义。宁可在这里失败，也不生成非法参数（禁止静默失败）。
	trust=$(dc_get_list foreign server | grep -v '^$' | paste -sd, -)
	if [ -z "$trust" ]; then
		dnschain_log "ERROR: dnschain.upstream.foreign 为空，无法生成过滤器参数"
		dnschain_log "ERROR: 请在页面「解析策略 → 国外上游」至少填一条（默认 tls://8.8.8.8）"
		return 1
	fi

	{
		echo "-b"
		echo "127.0.0.1"
		echo "-l"
		echo "$port"
		# 只接收 gfw 域名：-d gfw 把未匹配的也归为 tag:gfw，
		# 故不需要 -g（多一份名单只会制造第二个真相源）
		echo "-d"
		echo "gfw"

		# 国外 DoT（IP 形式，经 :1234 代理出站）
		echo "-t"
		echo "$trust"

		# 只对 gfw 组抑制 AAAA（不要写成裸 -N）
		echo "-N"
		echo "tag:gfw"
		# 同时抑制 qtype 64/65（SVCB/HTTPS 携带 ipv6hint）
		echo "--filter-qtype"
		echo "64,65"

		# 尽力而为地把 gfw 域名的解析结果写进 blacklist（会被 ssr-rules flush）
		echo "-A"
		echo "inet@ss_spec@blacklist"

		# 证书校验（默认是 no，必须显式开）
		if [ "$(dc_get upstream foreign cert_verify 1)" = "1" ]; then
			echo "--cert-verify"
			echo "--ca-certs"
			echo "/etc/ssl/certs/ca-certificates.crt"
		fi

		echo "-o"
		echo "5"
	} > "$out"

	# 注意：这里**不写** --cache / --cache-stale / --cache-refresh
	# （缓存只在 dnsmasq 一层，ADR §10.5）
	# 也**不写** -c/--china-dns（默认值是明文 114.114.114.114，ADR §10.3）
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
