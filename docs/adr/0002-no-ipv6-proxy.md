# ADR-0002：境外 IPv6 不经代理，保持直连（已失效）

- 状态：**superseded（v0.10.0 起 IPv6 流量代理启用）** —— 原状态 `accepted（2026-10-09）`
- 日期：2026-10-09（原始）；2026-10-23 标注失效并重写
- 被推翻依据：[ADR-0005](0005-remove-chinadns-ng.md) §4.1（`ipv6_support=1`）
- 相关：`files/etc/uci-defaults/99-zz-dnschain`、`files/usr/bin/dnschain-reconcile`、
  `files/etc/config/dnschain`、`files/usr/bin/dnschain-selftest`

> **本文的写法**：原论证保留，凡被推翻处标注 **【已失效】** 并给出推翻依据与现行事实。

---

## 1. 原决策（原文保留）

> `ip6tables` 中只有两条规则（`-A PREROUTING -i br-lan -p tcp/udp --dport 53
> -j REDIRECT --to-ports 53`），`ip6tables -S | grep -c 1234` 实测为 **0**。
> 即 IPv4 侧有完整的 `REDIRECT`/`TPROXY :1234`，而境外 IPv6 全部由
> `pppoe-wan` 直连出站。
>
> 保持现状，不补 IPv6 透明代理。
>
> 「需走代理的域名走代理」这一功能诉求已由 AAAA 拒绝集覆盖（见 ADR-0001）：
> 被墙域名拿不到 AAAA，客户端只剩 IPv4 可用，自然经 `:1234` 出站。而未被拒绝的
> 境外域名走 IPv6 直连，省掉代理封装，时延更低。

**【已失效】** 整段前提与结论都已不成立：

1. **拒绝集本身不存在了。** ADR-0001 的「拒绝集 = 需走代理的域名集」由 MosDNS 的
   `reject 0` 实现，而 MosDNS 不在默认链路（`files/etc/config/dnschain:197-204`
   的 `ssr.mode '0'`；`files/usr/bin/dnschain-selftest:220-231` 断言 `:5335` 无监听）。
   现行 `aaaa.policy` 是 `domestic 'keep'` / `foreign 'keep'`
   （`files/etc/config/dnschain:78-79`）。
2. **IPv6 透明代理已经存在且在计数。** 仓库强制 `ipv6_support='1'`（见 §2），
   SSR-Plus 据此装上 IPv6 代理链。
3. 因此「境外 IPv6 全部直连」既不成立，也不再是有意设计。

---

## 2. 现行事实：仓库强制 `ipv6_support='1'`

| 写入点 | 值 | 证据 |
|---|---|---|
| `99-zz-dnschain` | `'1'` | `files/etc/uci-defaults/99-zz-dnschain:65-70` |
| `dnschain-reconcile`（每轮） | `'1'` | `files/usr/bin/dnschain-reconcile:84-87` |
| 配置里的期望值 | `require_ipv6 '1'` | `files/etc/config/dnschain:203-204` |
| 自检判据 | `ipv6_support` 必须为 `1` | `files/usr/bin/dnschain-selftest:247-248` |

收敛器的开关由 `ssr.compat.require_ipv6` 控制（`dnschain-reconcile:84`），
默认 `1`（`files/etc/config/dnschain:204`）。

### 2.1 谁真正生成 IPv6 代理规则

**本仓库没有生成 `ss_spec6_*` 的代码。** 全仓库对 `ss_spec6` 的引用只有注释
（`files/etc/config/dnschain:30`、`files/etc/uci-defaults/99-zz-dnschain:60`、
`files/usr/bin/dnschain-reconcile:80`、`package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua:1660`），
没有一条 nft 片段或规则生成语句。

生成者在**上游 SSR-Plus**（`luci-app-ssr-plus` 的 `/etc/init.d/shadowsocksr`
与其 `ssr-rules`）。本仓库只负责把 `ipv6_support` 置 `1`，让上游走它自己的
IPv6 分支。这条边界必须写清：`ss_spec6_*` 的规则内容、链数与优先级都不由本仓库维护，
上游升级可能改变它们。

### 2.2 路由器实测（OpenWrt 24.10.5 / 内核 6.18.55）

`nft list table inet ss_spec` 可见 10 条 IPv6 链：

```
ss_spec6_tcp          ss_spec6_redirect     ss_spec6_prerouting
ss_spec6_output       ss_spec6_udp          ss_spec6_udp_proxy
ss_spec6_mangle       ss_spec6_udp_output   ss_spec6_udp_mark
ss_spec6_udp_local
```

其中 `ss_spec6_redirect` 含实际计数规则：

```
tcp dport != { ... } meta l4proto tcp counter packets 394 bytes 28776 redirect to :1234
```

策略路由同样在位：

```
ip -6 rule           → 999: from all fwmark 0x53535250 lookup 999
ip -6 route show table 999 → local default dev lo
```

`packets 394` 是「确实有 IPv6 流量被重定向」的直接证据 —— 这不是配置声明，
是内核计数器。

### 2.3 与 AAAA 策略的联动

`ipv6_support=1` 会让上游 `get_filter_aaaa()` 直接返回 `0`，并把
`dhcp.@dnsmasq[0].filter_aaaa` 设为 `0`（`files/etc/config/dnschain:26-33` 的注释、
`files/usr/bin/dnschain-selftest:235-252`）。所以「保留国外 AAAA」与「IPv6 走代理」
是同一套开关的两面，不能只改一面。

---

## 3. 后果（更新）

- **不要按本文原结论关闭 IPv6 代理。** 关闭后国外域名拿到真实 AAAA 却直连，
  会被 RST —— 这正是原 ADR 想避免、现在由代理解决的那个问题
  （`files/etc/config/dnschain:26-33`）。
- 自检第 7 项在 `ipv6_support != 1` 时 FAIL，证据串写明「否则国外 AAAA 无意义」
  （`files/usr/bin/dnschain-selftest:247-248`）。
- 排查 IPv6 相关故障时，本仓库能负责的只有「`ipv6_support` 是否为 1」与
  「`dnsmasq.filter_aaaa` 是否为 0」。链是否存在、链名是否变化，要去上游
  SSR-Plus 的代码里查。
- `files/etc/uci-defaults/99-gaming-optimize:786-787` 仍写着
  「SSR-Plus 仅代理 IPv4（无 ip6tables/TPROXY6 规则）……详见 docs/adr/0002」。
  该注释已失实，且它指向的正是本文原来的结论 —— 读到它不要采信。

---

## 4. 被否决的方案（原文保留，附失效说明）

> 补 TPROXY6 需要代理核心与防火墙同时支持，并新增一整套 `ip6tables` 规则与路由标记，
> 等于引入第二个透明代理面；其收益（覆盖少量走出拒绝集的域名）与风险不成比例。

**【已失效】** 这套成本核算已不适用：`ipv6_support=1` 后，IPv6 代理由上游 SSR-Plus
自带实现，本仓库没有为此新增任何 nft/iptables 规则。当年的「第二个透明代理面」
现在是上游既有能力的一部分。

现行被否决的方案是反向的：**关闭 IPv6 代理**（见 §3 第一条）。

---

## 5. 证据索引

| 断言 | 证据 |
|---|---|
| 强制 `ipv6_support=1` | `files/etc/uci-defaults/99-zz-dnschain:65-70`、`files/usr/bin/dnschain-reconcile:84-87` |
| 期望值 `require_ipv6 '1'` | `files/etc/config/dnschain:203-204` |
| 自检要求 `ipv6_support=1` | `files/usr/bin/dnschain-selftest:243-252` |
| 仓库无 `ss_spec6` 生成代码 | 全仓库仅注释引用：`files/etc/config/dnschain:30`、`files/etc/uci-defaults/99-zz-dnschain:60`、`files/usr/bin/dnschain-reconcile:80`、`general.lua:1660` |
| AAAA 不再抑制 | `files/etc/config/dnschain:74-82`、`files/etc/init.d/dnschain:19-20` |
| 失效的遗留注释 | `files/etc/uci-defaults/99-gaming-optimize:786-787` |
