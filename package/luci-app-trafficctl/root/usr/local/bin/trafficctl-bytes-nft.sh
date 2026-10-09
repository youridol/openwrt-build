#!/bin/sh
# shellcheck shell=dash
# Per-device byte counters using nftables sets with per-element counters.
# Output: JSON array [{"ip":"...","bytes_in":N,"bytes_out":N}]
#
# ═══════════════════════════════════════════════════════════════════════════
# 2026-10-10 重写。原实现在内核 6.18.55 上**完全失效**，两列速率恒为 `—`。
# ═══════════════════════════════════════════════════════════════════════════
#
# 【缺陷 1 — 语法不被支持（静默失败）】
# 原实现用了本内核不支持的 nftables 语法，错误又被 `2>/dev/null` 吞掉：
#   nft add map ... '{ type ipv4_addr : counter; flags dynamic; }'
#     -> Error: Could not process rule: Not supported
#   nft add rule ... 'update @map { ip saddr counter }'
#     -> Error: Could not process rule: Not supported
# 结果只留下一个**空的 forward 链**，ubus 的 bytes 方法永远返回 `[]`。
# 实测本内核（6.18.55 / nftables 1.1.6）**可用**的等价语法：
#   nft add set  ... '{ type ipv4_addr; size 65535; flags dynamic; }'
#   nft add rule ... 'add @set { ip saddr counter }'
#
# 【缺陷 2 — 挂钩点选错，看不到代理流量】
# SSR-Plus 用 REDIRECT 把客户端连接引到本机 v2ray(:1234)，REDIRECT 改写目的
# 地址为本机，数据包因此走 **INPUT/OUTPUT**，**不经 forward**。
# 实测对照（客户端下载 150 MB）：
#   output daddr=客户端 -> 157548502 B   完整捕获
#   input  saddr=客户端 ->   1360391 B   客户端上行小包
#   forward saddr=客户端 ->      5932 B  几乎为零
# 故同时挂三个钩子；三者对同一数据包互斥，不会重复计数：
#   下行(→设备) = forward daddr=设备 + output  daddr=设备
#   上行(设备→) = forward saddr=设备 + input   saddr=设备
#
# 【缺陷 3 — 集合被非 LAN 地址污染】
# output 钩子会看到路由器自身对 WAN 的连接（旁路由场景尤甚），若只用
# `oifname br-lan` 限定，仍会写入 1.2.4.8、10.x、14.x 等公网/异网地址。
# 实测必须同时限定**目的地址属于 LAN 网段**（自动生成的 @lan 集合）
# 才能把集合内容收敛到真实 LAN 客户端：
#   iifname "br-lan" ip saddr @lan add @set { ... }      # 上行
#   oifname "br-lan" ip daddr @lan add @set { ... }      # 下行
# @lan 集合由 tctl_lan_subnets 动态生成（支持多网桥/多 VLAN），不硬编码。
#
# 【缺陷 4 — 解析格式不匹配】
# `nft list set` 的元素是 `IP counter packets N bytes M`（无冒号），
# 与旧 `nft list map` 的 `IP : counter ...` 不同；元素还会跨行折行。
# awk 按空白切分并跟踪「最近一个 IP」即可正确累加。
# ═══════════════════════════════════════════════════════════════════════════

. /usr/local/bin/trafficctl-fw.sh

command -v nft >/dev/null 2>&1 || { echo '[]'; exit 0; }

T="trafficctl_mon"
LAN=$(tctl_get_lan_device)
[ -z "$LAN" ] && LAN="br-lan"

# 由 LAN 网段列表构造 nft 集合元素，例如 " 192.168.3.0/24, 192.168.10.0/24"
# tctl_lan_subnets 输出每行：l3_device netbase block router_int
LAN_ELEMS=$(tctl_lan_subnets 2>/dev/null | awk '
{
    base = $2 + 0; block = $3 + 0
    if (block <= 0) next
    # 由整数网基与块大小还原 CIDR 前缀长度
    n = 0; b = block
    while (b > 1) { b = int(b / 2); n++ }
    o1 = int(base / 16777216) % 256
    o2 = int(base / 65536) % 256
    o3 = int(base / 256) % 256
    o4 = base % 256
    printf "%s%s.%s.%s.%s/%d", (cnt++ ? ", " : ""), o1, o2, o3, o4, (32 - n)
}')

[ -z "$LAN_ELEMS" ] && { echo '[]'; exit 0; }

# ─────────────────────────────────────────────────────────────────────────
# 幂等建立：**单事务原子重建**（用 nft -f，不用逐条 nft add）
#
# 为什么必须原子：本脚本会被多个调用方并发触发 —— 前端每 pollInterval 秒
# 轮询一次（默认 2s），可能同时有手工调用/多个浏览器标签。若用
# `if ! nft list set ...; then nft add chain ...; nft add rule ...; fi`
# 这种「先检查后逐条建」的写法，两个进程会**同时通过检查**，各自建一套规则，
# 导致规则重复 → 同一数据包被累加两次 → 速率翻倍。
# 实测踩过：180 MB 下载被记成 380 MB。
#
# nft -f 把整个 ruleset 作为一个事务提交，内核保证原子性：
#   `delete table` + `table { ... }` 在**同一个文件**里
# 要么全成功，要么全失败，不存在中间状态。并发调用时后者会整体覆盖前者，
# 结果始终只有一套规则（可能短暂丢一次计数，但不会重复累计）。
#
# 注意：重建会清零计数。为避免每次轮询都清零，仅在「结构不完整」时重建；
# 结构判据用 `nft -c`（只校验不提交）检查预期规则是否存在。
# ─────────────────────────────────────────────────────────────────────────

NFT_SNIPPET="/tmp/.trafficctl-mon.nft"

# 结构完整性判据：集合存在 + 各链规则条数正确（forward 2、input 1、output 1）
need_build=0
if ! nft list set inet "$T" bytes_in >/dev/null 2>&1; then
    need_build=1
elif [ "$(nft list chain inet "$T" mon_forward 2>/dev/null | grep -c 'add @bytes')" -ne 2 ]; then
    need_build=1
elif [ "$(nft list chain inet "$T" mon_input 2>/dev/null | grep -c 'add @bytes')" -ne 1 ]; then
    need_build=1
elif [ "$(nft list chain inet "$T" mon_output 2>/dev/null | grep -c 'add @bytes')" -ne 1 ]; then
    need_build=1
fi

if [ "$need_build" = "1" ]; then
    # 整个 ruleset 在一个事务内提交（delete + 重建），保证原子且结构唯一
    cat > "$NFT_SNIPPET" <<EOF
table inet $T
delete table inet $T
table inet $T {
	set lan {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { $LAN_ELEMS }
	}
	set bytes_in {
		type ipv4_addr
		size 65535
		flags dynamic
	}
	set bytes_out {
		type ipv4_addr
		size 65535
		flags dynamic
	}
	chain mon_forward {
		type filter hook forward priority -200; policy accept;
		iifname "$LAN" ip daddr @lan add @bytes_in  { ip daddr counter }
		iifname "$LAN" ip saddr @lan add @bytes_out { ip saddr counter }
	}
	chain mon_input {
		type filter hook input priority -200; policy accept;
		iifname "$LAN" ip saddr @lan add @bytes_out { ip saddr counter }
	}
	chain mon_output {
		type filter hook output priority -200; policy accept;
		oifname "$LAN" ip daddr @lan add @bytes_in { ip daddr counter }
	}
}
EOF
    # 先校验（nft -c 不提交），通过才真正加载；避免写坏防火墙规则集
    if nft -c -f "$NFT_SNIPPET" 2>/dev/null; then
        nft -f "$NFT_SNIPPET" 2>/dev/null
    fi
    rm -f "$NFT_SNIPPET"
fi

IN=$(nft list set inet "$T" bytes_in 2>/dev/null)
OUT=$(nft list set inet "$T" bytes_out 2>/dev/null)

# 元素形如：`192.168.3.238 counter packets 204 bytes 17949,`
printf '%s\n__SEP__\n%s\n' "$IN" "$OUT" | awk '
/^__SEP__$/ { phase = 1; next }
{
    cur = ""
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
            cur = $i
        } else if ($i == "bytes" && cur != "") {
            val = $(i+1) + 0
            if (phase == 0) in_b[cur]  += val
            else            out_b[cur] += val
            cur = ""
        }
    }
}
END {
    printf "["
    n = 0
    for (ip in in_b) {
        if (n > 0) printf ","
        printf "{\"ip\":\"%s\",\"bytes_in\":%d,\"bytes_out\":%d}", ip, in_b[ip], out_b[ip]+0
        n++
    }
    for (ip in out_b) {
        if (!(ip in in_b)) {
            if (n > 0) printf ","
            printf "{\"ip\":\"%s\",\"bytes_in\":0,\"bytes_out\":%d}", ip, out_b[ip]
            n++
        }
    }
    printf "]\n"
}
'
