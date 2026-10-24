# ADR-0005：移除 chinadns-ng —— 双 dnsproxy 实例 + dnsmasq 分流

- 状态：**已实施（v0.10.0，路由器实测通过）**；仓库侧仍有残留，见 §9
- 日期：2026-10-21；2026-10-23 按代码更正并标注失效断言
- 修订：[ADR-0003](0003-dns-chain-framework.md) 的 §5.3 第 5 条（国外 DoT 经代理）
  与 §5.4（AAAA 抑制策略）
- 推翻：[ADR-0002](0002-no-ipv6-proxy.md) 的「境外 IPv6 直连」前提
- 相关：`files/etc/config/dnschain`、`files/usr/share/dnschain/dnschain.sh`、
  `files/etc/init.d/dnschain`、`files/usr/bin/dnschain-selftest`、
  `files/usr/bin/dnschain-reconcile`、CHANGELOG v0.10.0

> **本文的写法**：原论证保留，凡与当前代码不符处标注 **【已更正】** 并给出证据。

---

## 1. 背景

v0.9.1 刷机后用户报告两个症状：

1. SSR-Plus 未启动节点时，DNS 分流页面打不开
2. 客户机全都解析不正常（国内正常，国外全部 `No answer`）

排查出两个真实缺陷，第二个是架构性的。

---

## 2. 缺陷 1：`paste` 缺失导致框架完全不启动

### 现象

```
/etc/rc.common: line 273: paste: not found
ERROR: dnschain.upstream.foreign 为空，无法生成过滤器参数
ERROR: 生成运行时配置失败，中止启动
```

`dnsproxy :5353` 与 `chinadns-ng :5335` **都不启动**，客户机解析全断。

### 根因

`dc_gen_filter_args()` 用 `paste -sd, -` 把多行上游拼成逗号分隔：

```sh
trust=$(dc_get_list foreign server | grep -v '^$' | paste -sd, -)
```

而 BusyBox **默认不编译 `paste`**，本固件也没装 `coreutils-paste`。
`paste` 失败 → `trust` 为空 → 被误判成「配置里没填上游」→ 中止启动。

误导性在于：`uci get dnschain.upstream.foreign.server` 实际返回正常值。

### 修复

改用 `awk`（BusyBox 必有）：

```sh
trust=$(dc_get_list foreign server | awk 'NR>1{printf ","} {printf "%s", $0}')
```

实测 5 种输入（单条 / 两条 / 三条 / 空 / 含空格）与 `paste -sd, -` **完全等价**。

> 该修复随 v0.10.0 一起落地；`dc_gen_filter_args` 本身在后续重构中被删除
> （CI 反向断言，`.github/workflows/build-openwrt.yml:1147-1158`）。

---

## 3. 缺陷 2：chinadns-ng 的 DoT 上游在本环境永远不可用

修好缺陷 1 后两个进程都起来了，但国外域名仍全部无结果。
`chinadns-ng` 日志反复报（653 次）：

```
[Upstream.zig:825 TCP.on_error] connect(tls://8.8.8.8) failed: peer sent close notify alert
```

### 实测证据链（全部在路由器本机，不经本地 Clash TUN）

| 目标 | 路径 | TCP | TLS |
|---|---|---|---|
| `8.8.8.8:443` | 经 `:1234` | ✅ | **✅ TLSv1.3** |
| `8.8.8.8:853` | 经 `:1234` | ❌ | **❌** |
| `1.1.1.1:853` | 经 `:1234` | ❌ | **❌** |
| `9.9.9.9:853` | 经 `:1234` | ❌ | **❌** |
| `223.5.5.5:853` | **直连**（在 `china` 集） | ✅ | ✅ TLSv1.3 |

conntrack 对比（同一时刻）：

```
# 223.5.5.5:853 → 直连
src=100.119.176.186 dst=223.5.5.5 sport=41806 dport=853 packets=10 bytes=2161

# 8.8.8.8:853 → 走代理，只回 204 字节就断
src=127.0.0.1 sport=1234 dst=100.119.176.186 packets=4 bytes=204
```

**同一 IP，443/80 通、853 不通** → 落地节点到 853 的链路被阻断。

### 能力边界

`chinadns-ng` 的 `-t` **只支持 `udp:// tcp:// tls://`**（及 `udpi:// tcpi://`）：

```
$ chinadns-ng -t https://dns.google/dns-query ...
invalid proto: 'https://'

$ strings /usr/bin/chinadns-ng | grep -cE 'doh|dns-query'
0
```

**不支持 DoH，不支持 QUIC。**

### 死锁

- DoT（853）→ 落地节点阻断
- DoH（443）→ `chinadns-ng` 不支持
- 退回国内 DNS 查国外 → 拿到污染答案

实测污染值（同一域名连查 3 次）：

| 来源 | 第 1 次 | 第 2 次 | 第 3 次 |
|---|---|---|---|
| 阿里 DoH | `174.132.167.252` | `31.13.92.37` | `174.132.167.252` |
| Google DoH（经代理） | `142.251.153.119` | `142.251.154.119` | `142.251.156.119` |

阿里在 `174.132.167.252`（伊朗 IP 段）与 `31.13.92.37` 之间**交替返回** ——
这是污染特征（返回少量固定假 IP），而 Google DoH 每次不同但都在
`142.251.15x.119` 真实地址池内。

> **注意一个易误判点**：`31.13.92.37` 经代理访问 Google 能返回 302、
> 证书是 `CN=www.google.com`，看起来「能用」。但污染 IP 常部署在真实服务
> 前面（中间人），能返回合法证书。**判据不是「能否连上」，而是
> 「地址由谁决定」** —— 方案 A（用国内 DoT 查国外）的本质是把国外域名的
> 解析权交给墙，只加密了传输过程。

---

## 4. 决策

**移除 `chinadns-ng`，改为两个 dnsproxy 实例 + dnsmasq 按域名分流。**

```
dnsmasq:53（唯一缓存 + 唯一分流层）
  ├─ 默认              → 127.0.0.1#5353  dnsproxy 实例 1（国内 DoT/DoH，直连）
  ├─ server=/国外域名/ → 127.0.0.1#5336  dnsproxy 实例 2（国外 DoH，经 :1234）
  └─ nftset=/国外域名/4#inet#ss_spec#blacklist
       解析结果自动写入代理 IP 集（替代 chinadns-ng 的 -A）
```

| 组件 | v0.9.x | v0.10.0 |
|---|---|---|
| `chinadns-ng` | `:5335` 策略过滤器 | **移除** |
| `dnsproxy` | 1 个实例（`:5353`） | **2 个实例**（`:5353` 国内 / `:5336` 国外） |
| 国外上游 | `tls://8.8.8.8`（DoT） | `https://dns.google/dns-query` + `https://cloudflare-dns.com/dns-query`（DoH） |
| 国外域名分流 | `dnsproxy` 的 `[/域名/]` | **`dnsmasq` 的 `server=/域名/`** |
| 解析结果入代理 IP 集 | `chinadns-ng -A` | **`dnsmasq nftset=`** |
| AAAA 抑制 | `-N tag:gfw` 抑制国外 | **不抑制** |
| `filter_https_rr` | `1` | `0` |

**【已更正】** 原文「国外上游」一栏只写一条 Google DoH。实际是**两条**：

- `list server 'https://dns.google/dns-query'`
- `list server 'https://cloudflare-dns.com/dns-query'`

证据：`files/etc/config/dnschain:67-68`。

两条都在同一 section 下，`dc_gen_foreign_args` 会逐条生成 `--upstream`
（`files/usr/share/dnschain/dnschain.sh:394-397`）。

### 4.1 为什么不再需要 AAAA 抑制

ADR-0002 的前提是「境外 IPv6 直连」，故必须抑制国外 AAAA 以免被 RST。
v0.10.0 启用 SSR-Plus 的「IPv6 流量代理」（`ipv6_support=1`）后该前提消失。

实测（`ipv6_support=1` 后）：

| 测试 | 结果 |
|---|---|
| `curl -6 www.google.com` | ✅ 302 |
| `curl -6 www.youtube.com` | ✅ 200 |
| `curl -6 www.baidu.com` | ✅ 200（国内直连） |
| IPv6 代理链 | ✅ 10 条（`ss_spec6_*`） |
| 策略路由 | ✅ `999: from all fwmark 0x53535250 lookup 999` + `local default dev lo table 999` |
| `dnsmasq.filter_aaaa` | ✅ 自动设为 **0** |

源码依据（上游 SSR-Plus 的 `/etc/init.d/shadowsocksr`）：

```sh
get_filter_aaaa() {
    ipv6_enabled && { echo 0; return; }    # ipv6_support=1 → 强制返回 0
    ...
}
ipv6_enabled() {
    [ "$(uci_get_by_type global ipv6_support 0)" = "1" ] && [ "$USE_TABLES" = "nftables" ]
}
```

既然国外 IPv6 也走代理，抑制 AAAA 只会让国外站点失去双栈能力。

#### 4.1.1 这 10 条链的来源（原文未说明）

**【已更正】** 原文只说「IPv6 代理链 10 条」，未说明生成者，容易被读成「本仓库生成」。

**本仓库没有生成 `ss_spec6_*` 的代码。** 全仓库对 `ss_spec6` 的引用只有注释：

| 位置 | 内容 |
|---|---|
| `files/etc/config/dnschain:30` | 「装上完整 IPv6 代理链（`ss_spec6_*`，10 条链 + fwmark 策略路由）」 |
| `files/etc/uci-defaults/99-zz-dnschain:60` | 「装上 `ss_spec6_*` 代理链（10 条）+ fwmark `0x53535250` 策略路由 table 999」 |
| `files/usr/bin/dnschain-reconcile:80` | 「装上 `ss_spec6_*` 代理链（10 条）+ fwmark 策略路由」 |
| `package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua:1660` | 页面说明文案 |

**生成者在上游 SSR-Plus**（`luci-app-ssr-plus` 的 `/etc/init.d/shadowsocksr` 与
`ssr-rules`）。本仓库只负责把 `ipv6_support` 置 `1`
（`files/etc/uci-defaults/99-zz-dnschain:65-70`、`files/usr/bin/dnschain-reconcile:84-87`），
让上游走它自己的 IPv6 分支。

**实测可见**（OpenWrt 24.10.5 / 内核 6.18.55）：

```
nft list table inet ss_spec
  ss_spec6_tcp          ss_spec6_redirect     ss_spec6_prerouting
  ss_spec6_output       ss_spec6_udp          ss_spec6_udp_proxy
  ss_spec6_mangle       ss_spec6_udp_output   ss_spec6_udp_mark
  ss_spec6_udp_local

ss_spec6_redirect 内含实际计数：
  tcp dport != { … } meta l4proto tcp counter packets 394 bytes 28776 redirect to :1234

ip -6 rule                     → 999: from all fwmark 0x53535250 lookup 999
ip -6 route show table 999     → local default dev lo
```

`packets 394` 是内核计数器，即「确实有 IPv6 流量被重定向」的直接证据 ——
不是配置声明。

**这条边界要写清**：`ss_spec6_*` 的链名、条数、优先级都不由本仓库维护，
上游升级可能改变它们。详见 [ADR-0002](0002-no-ipv6-proxy.md) §2.1。

---

## 5. 被否决的方案

### 方案 A：国外上游改成国内 DoT（阿里 223.5.5.5）

**改动最小**（一行配置），但**性质错误**：

- 阿里 DoT 传输本身很稳（实测 20/20 成功）
- 但它给国外域名的答案**由墙决定**（见 §3 污染值对比）
- 故障隐蔽：客户端显示「解析成功」，IP 却是错的

**否决理由**：DoT 只保护「路由器 ↔ 阿里」这一段，阿里的答案本身已被投毒。
这等于主动把国外域名的解析权交给墙。

### 方案 B：换一个 853 可用的落地节点

技术上最直接，但依赖用户提供节点，不是代码能解决的。
保留为可选项（若日后换到支持 853 的节点，DoT 可重新启用）。

### 方案 C：单实例 dnsproxy + `[/域名/]` 分流

**实测完全失败**，见 §6.1。已否决。

### 方案 D：保留 chinadns-ng 但不用它查国外

**未在原文讨论，本次补充说明为何不可行**：`chinadns-ng` 的存在意义就是
「国内上游 + 国外上游」双查并判定。只留国内一侧则退化成方案 A。
故移除是唯一出路。

---

## 6. 两个关键教训

### 6.1 不能用 dnsproxy 的 `[/域名/]` 做域名分流

最初实现是单实例 + `upstreams-domains.txt`（17767 条
`[/域名/]https://dns.google/dns-query`）。verbose 日志暴露了问题：

```
DEBUG upstream is reserved idx=3     addr=https://dns.google:443/dns-query domains_num=1
DEBUG upstream is reserved idx=4     addr=https://dns.google:443/dns-query domains_num=1
...
DEBUG upstream is reserved idx=17769 addr=https://dns.google:443/dns-query domains_num=1
```

`dnsproxy` 为**每个域名各注册一条 reserved 上游**。17767 个条目耗尽资源后：

```
;; connection timed out; no servers could be reached
```

而国内域名（走默认上游）完全正常 —— 这使问题看起来像「DoH 不可用」，
实际是「上游条目过多」。

改成「两个实例 + `dnsmasq` 的 `server=/域名/` 分流」后立即正常。

**另一条相关教训**：`--upstream-mode parallel` 会让国内 DoT 与国外 DoH
**并行竞争**。国内延迟更低，于是永远先返回污染答案（实测
`google → 104.244.42.197`、`AAAA → 2001::1`）。域名级分流必须让国外域名
**只**问 DoH，不能让两组上游竞争。

**现行状态**：`upstreams-domains.txt` 已不再生成，也无任何消费者。
它是这次失败尝试的遗留文件名，不要按名字去找它。

### 6.2 不能过滤 `xn--`

v0.9.x 生成上游文件时过滤 `xn--`，理由是 `dnsproxy` 的 `[/域名/]` 形式
不认 punycode（会整体拒绝启动：`idna: invalid label "wcvs22d1m"`）。

但 v0.10.0 改用 `dnsmasq` 的 `server=/域名/` 形式 —— **dnsmasq 原生支持
punycode，不能过滤**。

实测依据：`gfw_list.conf` 有 58 条 `xn--` 域名，过滤后它们只剩
`server=/域名/127.0.0.1#5335`（该端口已无监听），全部解析失败：

```
FAIL apple.xn--czr694b
FAIL apple.xn--fiqs8s
FAIL nike.xn--hxt814e
FAIL xn--3et96bj49ahpq.com
FAIL xn--4vq475g.com
```

改为不过滤后恢复（分流规则从 17767 条增至 17813 条）。

代码依据：`files/usr/share/dnschain/dnschain.sh:299-308`；
CI 反向断言禁止再过滤（`.github/workflows/build-openwrt.yml:1186-1197`）。

> 上述「17767 → 17813」是某时点实测快照，不是常量。

---

## 7. selftest 判据的四处修正

**16 项自检里有 4 项的判据本身有误。** 这些误报曾让我一度以为「改完还是坏的」。

| 项 | 旧判据 | 新判据 | 为什么 | 现行行号 |
|---|---|---|---|---|
| 1 | `nft chain inet fw4 dns_intercept_lan` 含 `dport 53` | LAN 地址上 `:53` 能否解析 | **框架启用时该链不被创建**（见 §7.1），而客户机 DNS 完全正常 | `files/usr/bin/dnschain-selftest:99-122` |
| 2 | 扫描整个 SSR conf-dir 的端口集合 | 只查框架自己的 `dnschain-split.conf` | SSR-Plus 的上万条 `#5335` 是**它自己的文件**（框架不重写），会永久误报 | `:124-160` |
| 7 | 读 `shadowsocksr.@global[0].filter_aaaa` | 读 `dhcp.@dnsmasq[0].filter_aaaa` | 前者是用户偏好，后者才是实际生效值 | `:233-253` |
| 15 | `grep -v '#5353'` 后统计 | 只统计非 `127.0.0.1` 的 IP | 旧写法把 `#5336`（国外实例）误判成明文旁路，虚报 35627 条 | `:371-402` |

另修 `dns_class()` 的 AAAA 判定 bug：原用 `grep '^Address:' | grep -vc ':'`
排除服务器行，但 **IPv6 地址本身含冒号**，导致 AAAA 答案全被过滤 →
第 9/11 项永久误报 `EMPTY`。改为按「去掉 `Address: ` 前缀后是否形如
`ip:port`」判定（`files/usr/share/dnschain/dnschain.sh:1406-1424`）。

### 7.1 第 1 项的「该链不存在」需要精确化

**【已更正】** 原文（本 ADR §7 表格第 1 行）写「该链**从来不存在**」。这不准确：

- `files/etc/init.d/dnsproxy:222-231` **有**生成 `dns_intercept_lan` 的代码
  （`update_lan_intercept` 的 nft 分支）。
- 但框架启用时 `start_service` 在 `:280-287` **提前 return**，根本不调用
  `update_lan_intercept`，因此该链**不被创建**。

正确表述：**框架启用时该链不被创建**（不是「从来不存在」）。
框架未启用时，`dnsproxy` 自己会创建它。

路由器侧实测一致：`/etc/nftables.d/` 下无 `10-dnsproxy-lan-intercept.nft`，
`nft list table inet fw4` 无 `dns_intercept_lan` 链。

### 7.2 项数：16 → 20

**【已更正】** 原文 §7 说「16 项自检里有 4 项」，§8.1 说「16/16 全 PASS」，
§11 说「应 16/16 PASS」，而 §11 第 8 条注释又说「自检 20 项全绿」——
**内部自相矛盾**。

现行事实：**20 项**。v0.13.0 为域名归属与自动改道加了第 17–20 项
（`files/usr/bin/dnschain-selftest:5-6` 的注释、`emit 17`…`emit 20`）。
以 20 为准。

---

## 8. 实测结果

### 8.1 自检 20/20 全 PASS（v0.10.0 实测时为 16 项）

> 下面是 v0.10.0 当时的 16 项输出。项 1–16 的文案与现行实现一致
> （逐项核对过 `files/usr/bin/dnschain-selftest` 的 `emit` 文案），
> 第 17–20 项是 v0.13.0 新增，此处按实际文案补上。

```
1  PASS 客户机 DNS 路径可达 — 192.168.3.254:53 应答 OK
2  PASS 框架分流规则正确 — dnschain-split.conf 全部指向 :5336
3  PASS dnsmasq 唯一默认上游 — server=127.0.0.1#5353 恰好 1 条
4  PASS dnsproxy 在监听 — 127.0.0.1:5353 应答 OK
5  PASS dnsproxy 参数一致 — 无 --cache、无 --fallback、无 --ipv6-disabled
6  PASS 无 chinadns-ng 残留 — :5335 无监听（v0.10.0 已移除该组件）
7  PASS 端口所有权无冲突 — pdnsd_enable=0、ipv6_support=1、dnsmasq.filter_aaaa=0
8  PASS 国内 A 正确 — www.baidu.com -> 183.2.172.177
9  PASS 国内 AAAA 保留 — www.taobao.com -> 240e:950:400:1:3::6e
10 PASS 国外 A 正确 — www.google.com -> 142.251.155.119
11 PASS 国外 AAAA 保留 — 返回真实 AAAA（IPv6 经代理出站）
12 PASS 国外 DoH 出站 — N 条到 DoH 上游的 ESTABLISHED
13 PASS 代理与分流在位 — ss_spec 表 2 个、:1234 在监听
14 PASS fw4 规则可加载 — fw4 check 通过
15 PASS 无明文旁路 — conf-dir 内无非 127.0.0.1 的 server=
16 PASS 缓存层唯一 — dnsmasq cache-size=8192，dnsproxy 无 --cache
17 PASS 自定义域名列表合法 — 国内 0 条、国外 0 条，格式全部通过
18 PASS 观测域名不与静态片段重复 — watch.servers 与 dnschain-split.conf 无交集
19 PASS 改道通道已就绪 — servers-file=/var/run/dnsmasq/watch.servers（已进 dnsmasq 配置，且在 ujail 白名单内）
20 SKIP 改道状态自洽 — 还没有探测数据（等一轮 interval 或从页面手动触发）

SUMMARY PASS=19 FAIL=0 SKIP=1
CONCLUSION: 链路正常
```

第 12 项与第 20 项可能为 SKIP，属正常（`files/usr/bin/dnschain-selftest:306`、
`:569`）。所以「全绿」的实际形态是 `FAIL=0`。

### 8.2 解析质量对比

| 类别 | v0.9.1（chinadns-ng） | v0.10.0（双实例） |
|---|---|---|
| 国内 A | `baidu → 183.2.172.177` ✅ | 同 ✅ |
| 国内 AAAA | `taobao → 240e:950:400:1:3::6e` ✅ | 同 ✅ |
| **国外 A** | `google → 104.244.42.197` ❌ 污染 | **`142.251.155.119`** ✅ |
| **国外 AAAA** | `google → 2001::1` ❌ 污染 | **`2001:4860:4826:7700::`** ✅ |

### 8.3 端到端访问

| 目标 | IPv4 | IPv6 |
|---|---|---|
| google.com | 302 ✅ | 302 ✅ |
| youtube.com | 200 ✅ | 200 ✅ |
| github.com | 301 ✅ | 000（该站无 IPv6，正常） |
| baidu.com | 200 ✅ | 200 ✅ |

### 8.4 nftset 生效

`ss_spec#blacklist` 集内出现真实 IP：`142.251.12.94`、`142.251.20.94`、
`142.251.150.119`（元素数从 7 增至 44）。

> 具体条数是快照，不是常量。判据是「随访问国外站点增长」。

### 8.5 LuCI 页面

登录后抓取 `/cgi-bin/luci/admin/services/dns_chain`（**路径已更正**，
原文写 `admin/network/dns_chain`）：

- **无 Lua 错误**（`lua error` / `stack traceback` 计数 = 0）
- 新文案已渲染：「端口与实例」「当前 IPv6 流量代理」
- 内嵌自检表格 20 项

页面注册在 `package/luci-app-dnschain/root/usr/share/luci/menu.d/luci-app-dnschain.json:2`
与 `package/luci-app-dnschain/luasrc/controller/dnschain.lua:37-39`。

---

## 9. 影响面与仓库残留

| 文件 | 改动 |
|---|---|
| `files/etc/config/dnschain` | 删 `profile`/`filter_port`；加 `foreign_port`/`require_ipv6`；`foreign.server` 改 DoH；`aaaa.foreign` → `keep`；`filter_https_rr` → `0` |
| `files/usr/share/dnschain/dnschain.sh` | 删 `dc_gen_filter_args`/`dc_filter_port`/`dc_is_framework_filter`；新增 `dc_gen_upstream_file`（生成纯域名清单）与 `dc_gen_foreign_args` |
| `files/etc/init.d/dnschain` | 删 filter 启动；加 `start_foreign_dnsproxy`；`update_dnsmasq_split`（同时生成 `server=` 与 `nftset=`） |
| `files/usr/bin/dnschain-selftest` | 4 项判据修正 + `dns_class` AAAA bug 修复 |
| `files/usr/bin/dnschain-reconcile` | 强制 `ipv6_support=1`、`filter_aaaa=0` |
| `files/etc/uci-defaults/99-zz-dnschain` | 首刷设 `ipv6_support=1`、`filter_aaaa=0` |
| `package/luci-app-dnschain/` | 页面同步（`filter_port` → `foreign_port` 等） |
| `.github/workflows/build-openwrt.yml` | 断言同步（见下） |

### 9.1 仓库侧残留（原文未提）

**【已更正/新增】** 移除 chinadns-ng 这件事在仓库里**没有彻底完成**，有两处残留：

| 残留 | 位置 | 与什么矛盾 |
|---|---|---|
| `CONFIG_PACKAGE_chinadns-ng=y` | `.github/workflows/build-openwrt.yml:687` | 同文件 `:864-867` 明确写「v0.10.0：不再要求 `CONFIG_PACKAGE_chinadns-ng`」 |
| `files/etc/capabilities/dnschain-filter.json` | 该文件本身 | **无消费者**。`-A` 参数（当年需要 `CAP_NET_ADMIN`）已随 chinadns-ng 消失；两个 procd 实例都不引用它（`files/etc/init.d/dnschain:274-317`），唯一引用 `/etc/capabilities/` 的是 `files/etc/init.d/dnsproxy:319`（用 `dnsproxy.json`） |

`CONFIG_PACKAGE_chinadns-ng=y` 的实际影响：SSR-Plus 的 `INCLUDE_ChinaDNS_NG`
本来就会带入该二进制，多写一行不改变固件内容，但会让读者误以为框架依赖它。
**CI 的硬断言（`:868-877`）只查 `luci-app-dnschain` 与语言包，不查 chinadns-ng** ——
所以这行残留不会被任何检查发现。

### 9.2 CI 断言的实际位置

| 断言 | 行号 |
|---|---|
| 库脚本不得定义 `dc_gen_filter_args` | `.github/workflows/build-openwrt.yml:1153-1158` |
| 必须有 `dc_gen_foreign_args` | `:1160-1166` |
| 不得生成 `[/域名/]` 形式 | `:1168-1176` |
| 不得写入 `114.114.114.114` | `:1178-1184` |
| 不得过滤 `xn--` | `:1186-1197` |
| nft 片段不得含 `table` 声明 | `:1199-1205` |
| uci-defaults 排序 | `:1207-1218` |
| 不得生成 `--cache` / `--fallback` / `--ipv6-disabled` | `:1130-1145` |

---

## 10. 遗留风险

| # | 风险 | 说明 |
|---|---|---|
| R1 | **依赖 SSR-Plus 的 IPv6 流量代理** | 若用户关闭 `ipv6_support`，国外 AAAA 会变成真实值却直连 → 被 RST。自检第 7 项会 FAIL 提醒（`files/usr/bin/dnschain-selftest:247-248`） |
| R2 | **SSR-Plus 重启期间国外解析短暂失败** | 国外实例查 DoH 依赖 `:1234` 已就绪。`dnschain` 是 `START=95`（`files/etc/init.d/dnschain:29`）、`dnsproxy` 是 `START=90`（`files/etc/init.d/dnsproxy:18`），但 SSR-Plus 自身的重启窗口内国外域名会失败 |
| R3 | **SSR-Plus 的 `gfw_list.conf` 仍指向 `:5335`** | 该端口已无监听。框架不重写它。实测 dnsmasq 对同一域名的多条 `server=` 会全部作为候选，`:5335` 无监听时自动重试其它候选，但这是**依赖加载顺序的隐式行为**（`files/usr/bin/dnschain-selftest:124-135` 的注释记录了该实测） |
| R4 | **国外 DoH 上游可被节点阻断** | 实测 `dns.google` 可用；若换节点需重新验证。配置里另有 `cloudflare-dns.com` 作冗余（`files/etc/config/dnschain:68`） |
| R5 | **853 仍不可用** | 若日后换到支持 853 的节点，可考虑恢复 DoT 作为备份上游；但 init 会硬校验拒绝 `tls://`（`files/etc/init.d/dnschain:200-212`），需同步改校验 |
| R6 | **`ss_spec6_*` 由上游生成** | 链名/条数/优先级不受本仓库控制，上游升级可能改变（§4.1.1） |
| R7 | **仓库残留 `CONFIG_PACKAGE_chinadns-ng=y`** | 与「不再要求」矛盾，且无断言覆盖（§9.1） |

---

## 11. 验证方式（刷机后）

```sh
# 1. 自检（应 FAIL=0，CONCLUSION: 链路正常；项数 20）
/usr/bin/dnschain-selftest -f

# 2. 两个实例都在监听
netstat -lnup | grep -E ':(5353|5336)'

# 3. chinadns-ng 必须不存在，且 :5335 必须空闲
pidof chinadns-ng                      # 应无输出
netstat -lnup | grep ':5335'           # 应无输出

# 4. 国外解析质量（应 142.251.x，不是 104.244.42.197）
nslookup -type=A www.google.com 192.168.3.254
nslookup -type=AAAA www.google.com 192.168.3.254    # 应为真实 AAAA，不是空

# 5. 国内双栈保留
nslookup -type=AAAA www.taobao.com 192.168.3.254

# 6. 端到端（IPv4 与 IPv6 都要测）
curl -4 -o /dev/null -w '%{http_code}\n' https://www.google.com
curl -6 -o /dev/null -w '%{http_code}\n' https://www.google.com

# 7. 分流规则与 nftset
grep -c '^server=/.*127.0.0.1#5336' /tmp/dnsmasq.d/dnschain-split.conf
grep -c '^nftset=' /tmp/dnsmasq.d/dnschain-split.conf     # 必须 > 0
nft list set inet ss_spec blacklist | grep -c 142.251

# 8. 页面
# 浏览器打开 /cgi-bin/luci/admin/services/dns_chain
#   应看到「端口与实例」「当前 IPv6 流量代理」两段，且自检 20 项
```

**【已更正】** 原文第 8 条写 `admin/network/dns_chain`，已改为
`admin/services/dns_chain`。原文第 3 条只查 `pidof chinadns-ng`，
补上「`:5335` 必须空闲」（二进制可能被 SSR-Plus 带入但进程不该运行；
`:5335` 有监听才是真故障）。第 7 条补上 `nftset=` 条数检查。

**判定国外解析是否正常，不要只看「有没有结果」** —— 污染 IP 也会返回结果。
判据是：`142.251.x.x`（真实）vs `104.244.42.197` / `31.13.92.37` /
`174.132.167.252`（污染）；AAAA 是 `2001:4860:x`（真实）vs `2001::1`（污染）。

污染值判据在自检里是硬编码的（`files/usr/bin/dnschain-selftest:77-84`），
可复用来写脚本。
