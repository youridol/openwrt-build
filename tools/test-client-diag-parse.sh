#!/bin/sh
# ============================================================
# dnschain-client-diag 的解析回归测试
# ------------------------------------------------------------
# 用**真实日志样本**验证 _diag_parse 的四类判定：
#   ok / nodata / noreply / servfail
#
# 为什么必须有这个测试（ADR-0009 §6）：
#   实测踩过两个真实缺陷，都是靠这份样本发现的：
#
#   ① CNAME 链终态丢失 —— 一个查询 ID 会有多条 reply，
#      query[HTTPS] 的终态是 NODATA（记录确实不存在，**正常**），
#      旧实现只认第一条 reply，把 3 个能正常解析的域名判成失败，
#      还对其中一个误执行了 L1 自愈。
#
#   ② 行尾 CR 导致比较失配 —— f[6] 变成 "SERVFAIL\r"，
#      与 "SERVFAIL" 不相等，失败被静默判成 ok。
#
# 用法：sh tools/test-client-diag-parse.sh
# 退出码：0 = 全部通过；1 = 有失败
# ============================================================

set -u

DIAG=files/usr/bin/dnschain-client-diag
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT INT TERM

rc=0
pass() { echo "OK   $1"; }
fail() { echo "FAIL $1" >&2; rc=1; }

if [ ! -f "$DIAG" ]; then
	echo "FAIL 缺少 $DIAG" >&2
	exit 1
fi

# ── 提取 _diag_parse 函数体 ────────────────────────────────
sed -n '/^_diag_parse() {/,/^}/p' "$DIAG" | sed '1i #!/bin/sh' > "$TMPD/fn.sh"
if [ ! -s "$TMPD/fn.sh" ]; then
	fail "无法提取 _diag_parse"
	exit 1
fi

# ── 真实日志样本（取自路由器实测，含 CRLF 行尾以覆盖缺陷 ②）──
#
# 样本设计：
#   metric.huya.com     query[HTTPS] → NODATA      应判 nodata（不是失败）
#   hs.p2p.huya.com     CNAME 链 4 跳 → NODATA     应判 nodata（不是失败）
#   www.baidu.com       正常 A 记录                应判 ok
#   broken.example      forwarded 后无 reply       应判 noreply（失败）
#   fail.example        reply SERVFAIL             应判 servfail（失败）
cat > "$TMPD/sample.txt" <<'SAMPLE'
Sun Oct 25 16:19:55 2026 syslog.info dnsmasq[2610]: 221000 192.168.3.99/1111 forwarded truncated.example to 127.0.0.1#5353
Sun Oct 25 16:19:56 2026 syslog.info dnsmasq[2611]: 221158 192.168.3.238/10196 query[HTTPS] metric.huya.com from 192.168.3.238
Sun Oct 25 16:19:56 2026 syslog.info dnsmasq[2611]: 221158 192.168.3.238/10196 forwarded metric.huya.com to 127.0.0.1#5353
Sun Oct 25 16:19:56 2026 syslog.info dnsmasq[2611]: 221158 192.168.3.238/10196 reply metric.huya.com is NODATA
Sun Oct 25 16:20:00 2026 syslog.info dnsmasq[2614]: 221459 192.168.3.238/9057 query[HTTPS] hs.p2p.huya.com from 192.168.3.238
Sun Oct 25 16:20:00 2026 syslog.info dnsmasq[2614]: 221459 192.168.3.238/9057 forwarded hs.p2p.huya.com to 127.0.0.1#5353
Sun Oct 25 16:20:00 2026 syslog.info dnsmasq[2614]: 221459 192.168.3.238/9057 reply hs.p2p.huya.com is <CNAME>
Sun Oct 25 16:20:00 2026 syslog.info dnsmasq[2614]: 221459 192.168.3.238/9057 reply hs.p2p.huya.com.c.volcfcdndvs.com is <CNAME>
Sun Oct 25 16:20:00 2026 syslog.info dnsmasq[2614]: 221459 192.168.3.238/9057 reply huya-p2p.jx.volclivedvs.com is <CNAME>
Sun Oct 25 16:20:00 2026 syslog.info dnsmasq[2614]: 221459 192.168.3.238/9057 reply huya-p2p.tx.volclivedvs.com is <CNAME>
Sun Oct 25 16:20:00 2026 syslog.info dnsmasq[2614]: 221459 192.168.3.238/9057 reply sched-l1-dk.tx.volclivedvs.com is NODATA
Sun Oct 25 16:20:01 2026 syslog.info dnsmasq[2620]: 221600 192.168.3.50/1234 query[A] www.baidu.com from 192.168.3.50
Sun Oct 25 16:20:01 2026 syslog.info dnsmasq[2620]: 221600 192.168.3.50/1234 forwarded www.baidu.com to 127.0.0.1#5353
Sun Oct 25 16:20:01 2026 syslog.info dnsmasq[2620]: 221600 192.168.3.50/1234 reply www.baidu.com is 1.2.3.4
Sun Oct 25 16:20:02 2026 syslog.info dnsmasq[2621]: 221700 192.168.3.50/5678 query[A] broken.example from 192.168.3.50
Sun Oct 25 16:20:02 2026 syslog.info dnsmasq[2621]: 221700 192.168.3.50/5678 forwarded broken.example to 127.0.0.1#5353
Sun Oct 25 16:20:03 2026 syslog.info dnsmasq[2622]: 221800 192.168.3.50/9999 query[A] fail.example from 192.168.3.50
Sun Oct 25 16:20:03 2026 syslog.info dnsmasq[2622]: 221800 192.168.3.50/9999 forwarded fail.example to 127.0.0.1#5353
Sun Oct 25 16:20:03 2026 syslog.info dnsmasq[2622]: 221800 192.168.3.50/9999 reply fail.example is SERVFAIL
Sun Oct 25 16:20:04 2026 syslog.info dnsmasq[2852]: 235836 192.168.3.60/6229 query[AAAA] cached.example from 192.168.3.60
Sun Oct 25 16:20:04 2026 syslog.info dnsmasq[2852]: 235836 192.168.3.60/6229 cached cached.example is NODATA-IPv6
Sun Oct 25 16:20:05 2026 syslog.info dnsmasq[2853]: 235900 192.168.3.60/7000 query[A] cachedhit.example from 192.168.3.60
Sun Oct 25 16:20:05 2026 syslog.info dnsmasq[2853]: 235900 192.168.3.60/7000 cached cachedhit.example is 5.6.7.8
Sun Oct 25 16:20:06 2026 syslog.info dnsmasq[2860]: 236000 192.168.3.70/1111 query[A] cnametrunc.example from 192.168.3.70
Sun Oct 25 16:20:06 2026 syslog.info dnsmasq[2860]: 236000 192.168.3.70/1111 forwarded cnametrunc.example to 127.0.0.1#5353
Sun Oct 25 16:20:06 2026 syslog.info dnsmasq[2860]: 236000 192.168.3.70/1111 reply cnametrunc.example is <CNAME>
Sun Oct 25 16:20:07 2026 syslog.info dnsmasq[2870]: 237000 192.168.3.80/2222 query[A] tailpending.example from 192.168.3.80
Sun Oct 25 16:20:07 2026 syslog.info dnsmasq[2870]: 237000 192.168.3.80/2222 forwarded tailpending.example to 127.0.0.1#5353
SAMPLE

# ── 另做一份带 CRLF 的样本，专门覆盖缺陷 ② ──────────────────
sed 's/$/\r/' "$TMPD/sample.txt" > "$TMPD/sample-crlf.txt"

# ── 跑解析 ────────────────────────────────────────────────
run_parse() {
	sh -c ". '$TMPD/fn.sh'; _diag_parse < '$1'"
}

OUT=$(run_parse "$TMPD/sample.txt")

# ── 逐条断言 ──────────────────────────────────────────────
# 判据：某域名的 state 字段（第 4 列）
state_of() {
	printf '%s\n' "$OUT" | awk -F'|' -v d="$1" '$2 == d { print $4; exit }'
}

check_state() {
	_d=$1; _want=$2; _why=$3
	_got=$(state_of "$_d")
	if [ "$_got" = "$_want" ]; then
		pass "$_d → $_want（$_why）"
	else
		fail "$_d 期望 $_want，实际 '$_got'（$_why）"
	fi
}

check_state "metric.huya.com"   "nodata"   "NODATA 是正常终态，不是失败"
check_state "hs.p2p.huya.com"   "nodata"   "CNAME 链终态取最后一条 reply"
check_state "www.baidu.com"     "ok"       "正常 A 记录"
check_state "broken.example"    "noreply"  "有 forwarded 无 reply，第②段失败"
check_state "fail.example"      "servfail" "上游明确失败，第③段失败"
#    cached 是命中缓存直接回复，占日志第二多（实测 182 条 vs reply 439 条）。
#    原实现只认 reply，导致所有缓存命中的查询被判成 noreply ——
#    实测 28 条「失败」里绝大多数是这条引起的误报。
check_state "cached.example"    "nodata"   "cached + NODATA-IPv6 不是失败"
check_state "cachedhit.example" "ok"       "cached + 真实答案"
#    pending：收到 <CNAME> 但终态答案落在日志窗口外。
#    实测 www.163.com 就是这样 —— 若判成失败，每次扫都会把正常域名
#    记成故障并触发误自愈（实测踩过，误对 gateway.fe.apple-dns.cn
#    执行了 L1 自愈）。
check_state "cnametrunc.example" "pending" "CNAME 链未完（窗口截断），不是失败"

# ── 窗口首条必须被丢弃 ───────────────────────────────────
#
# 滑动窗口（tail -n N）会把第一条查询的尾部截掉，它前面还有多少行
# 我们不知道。实测 api.deepseek.com：ID 250633 的 4 条真实 A 记录落在
# 窗口外，窗口内只剩 query + forwarded → 被判 noreply 失败，
# 而该域名解析完全正常。故首条一律丢弃。
if printf '%s\n' "$OUT" | grep -q '^[^|]*|truncated\.example|'; then
	fail "窗口首条残缺查询未被丢弃（会把正常域名误判成失败）"
else
	pass "窗口首条残缺查询已丢弃"
fi
#    末条同理：它的 reply 可能还没写进日志（日志正在增长）。
#    实测 chat-4.tmspk.net 有 reply 且能解析，却因 reply 落在窗口外被判 noreply。
if printf '%s\n' "$OUT" | grep -q '^[^|]*|tailpending\.example|'; then
	fail "窗口末条未完成查询未被丢弃（会把正常域名误判成失败）"
else
	pass "窗口末条未完成查询已丢弃"
fi

# ── 带 CRLF 的样本必须得出完全相同的判定（缺陷 ②）──────────
OUT_CR=$(run_parse "$TMPD/sample-crlf.txt")
if [ "$OUT_CR" = "$OUT" ]; then
	pass "CRLF 行尾不影响判定（已剥离 CR）"
else
	fail "CRLF 行尾导致判定改变（f[6] 带 \\r 会让字符串比较失配）"
	printf '  LF  : %s\n' "$OUT"    >&2
	printf '  CRLF: %s\n' "$OUT_CR" >&2
fi

# ── CNAME 不得覆盖原始查询域名（缺陷 ①）─────────────────────
_dom=$(printf '%s\n' "$OUT" | awk -F'|' '$2 ~ /^hs\.p2p\.huya\.com$/ { print $2; exit }')
if [ -n "$_dom" ]; then
	pass "CNAME 链保留原始查询域名（不被 volcfcdndvs.com 覆盖）"
else
	fail "CNAME 链的原始查询域名被覆盖（客户机问的是 hs.p2p.huya.com）"
fi

# ── 失败判据只认 servfail / noreply ─────────────────────────
#
# 直接对 _diag_is_fail 做真值表测试：nodata/nxdomain/ok 都不得算失败。
if sh -c ". '$TMPD/fn.sh'; . '$DIAG' 2>/dev/null" 2>/dev/null; then
	:
fi
# _diag_is_fail 不在 _diag_parse 的提取范围内，单独从脚本里取
sed -n '/^_diag_is_fail() {/,/^}/p' "$DIAG" > "$TMPD/isfail.sh"
if [ -s "$TMPD/isfail.sh" ]; then
	for _st in nodata nxdomain ok refused duplicate pending noquery; do
		if sh -c ". '$TMPD/isfail.sh'; _diag_is_fail $_st"; then
			fail "状态 $_st 被判成失败（ADR-0009 §3.4 明确它不算失败）"
		else
			pass "状态 $_st 不算失败"
		fi
	done
	for _st in servfail noreply; do
		if sh -c ". '$TMPD/isfail.sh'; _diag_is_fail $_st"; then
			pass "状态 $_st 算失败"
		else
			fail "状态 $_st 没有被判成失败"
		fi
	done
else
	fail "无法提取 _diag_is_fail"
fi

# ── 流式解析（daemon 用）必须正确处理跨多行的查询 ──────────
#
# 这是实际部署后暴露的最严重问题：daemon 原用 `logread | tail -n 2000`
# 快照，一条查询跨 20+ 行时窗口边界切在中间 → 判成 noreply →
# 每轮把正常域名记成故障，记录数 7→38→78 膨胀，还对
# copilot.tencent.com 误执行了 L1 自愈。
#
# 改为持续跟随 + 流式解析后，同一查询的所有行都在流里，不再有边界问题。
sed -n '/^_diag_stream() {/,/^}/p' "$DIAG" | sed '1i #!/bin/sh' > "$TMPD/sfn.sh"
if [ -s "$TMPD/sfn.sh" ]; then
	cat > "$TMPD/stream.txt" <<'STREAM'
dnsmasq[1]: 255688 240e::1/51550 query[A] www.apple.com from 240e::1
dnsmasq[1]: 255688 240e::1/51550 forwarded www.apple.com to 127.0.0.1#5353
dnsmasq[1]: 255688 240e::1/51550 reply www.apple.com is <CNAME>
dnsmasq[1]: 255688 240e::1/51550 reply www-apple-com.v.aaplimg.com is <CNAME>
dnsmasq[1]: 255688 240e::1/51550 nftset add 4 inet ss_spec whitelist_domain 124.226.75.191 apple.com
dnsmasq[1]: 255688 240e::1/51550 reply www.apple.com.w.cdngslb.com is 124.226.75.191
dnsmasq[1]: 255688 240e::1/51550 reply www.apple.com.w.cdngslb.com is 124.226.75.196
dnsmasq[1]: 300004 1.1.1.1/4 query[A] dead.example from 1.1.1.1
dnsmasq[1]: 300004 1.1.1.1/4 forwarded dead.example to 127.0.0.1#5353
STREAM
	SOUT=$(sh -c ". '$TMPD/sfn.sh'; _diag_stream < '$TMPD/stream.txt'")

	# 跨 20+ 行的查询（含 nftset 穿插）必须判 ok，且只输出一次
	_apple=$(printf '%s\n' "$SOUT" | grep -c '^[^|]*|www\.apple\.com|')
	if [ "$_apple" = "1" ]; then
		pass "流式解析：跨多行查询只输出一次"
	else
		fail "流式解析：www.apple.com 输出了 $_apple 次（应恰好 1 次）"
	fi
	if printf '%s\n' "$SOUT" | grep -q '^[^|]*|www\.apple\.com|[^|]*|ok|'; then
		pass "流式解析：含 nftset 穿插的查询判 ok"
	else
		fail "流式解析：含 nftset 穿插的查询没有判 ok"
	fi
	# 真正只有 forwarded 的才是 noreply
	if printf '%s\n' "$SOUT" | grep -q '^[^|]*|dead\.example|[^|]*|noreply|'; then
		pass "流式解析：真 noreply 仍能识别"
	else
		fail "流式解析：真 noreply 没识别出来"
	fi
else
	fail "无法提取 _diag_stream"
fi

echo ""
if [ "$rc" -ne 0 ]; then
	echo "!!! 客户机诊断解析测试失败" >&2
	exit 1
fi
echo "客户机诊断解析测试通过。"
exit 0
