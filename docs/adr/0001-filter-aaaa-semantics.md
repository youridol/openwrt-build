# ADR-0001：`filter_aaaa` 的拒绝集语义（已失效）

- 状态：**superseded（v0.10.0 起语义反转）** —— 原状态 `accepted（2026-10-09）`
- 日期：2026-10-09（原始）；2026-10-23 标注失效并重写
- 取代者：[ADR-0005](0005-remove-chinadns-ng.md)（移除 chinadns-ng，国外 AAAA 改为保留）
- 相关：`files/etc/config/dnschain`、`files/etc/uci-defaults/99-gaming-optimize`、
  `files/etc/uci-defaults/99-zz-dnschain`、`files/usr/bin/dnschain-reconcile`、
  `files/usr/bin/dnschain-selftest`、`package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua`

> **本文的写法**：原 ADR 的论证保留，但凡与当前代码不符的断言一律就地标注
> **【已失效】**，并给出失效原因与现行事实。这样后来者能看到「为什么曾经那样写」，
> 而不是面对一份被悄悄改干净的文档。

---

## 1. 状态与结论摘要

| 项 | 原 ADR（2026-10-09） | 现行（v0.10.0 起） |
|---|---|---|
| `shadowsocksr.@global[0].filter_aaaa` | 仓库值取 `'1'` | 被 `99-zz-dnschain` 覆盖为 `'0'`，收敛器每轮再强制 `'0'` |
| 实际决定行为的键 | 未区分 | `dhcp.@dnsmasq[0].filter_aaaa`（不是 `shadowsocksr` 那个） |
| 国外 AAAA | 抑制（`reject 0`） | **保留**，由 SSR-Plus 的 IPv6 流量代理送出 |
| 实现抑制的组件 | MosDNS 的 `reject 0` | 该组件已不在默认链路 |
| 被墙域名条数 | 写成常量 `23614` | 不写成常量（名单是运行时生成物） |

---

## 2. 背景（原文保留）

> 原 ADR：SSR-Plus 的 `filter_aaaa` 决定 MosDNS 生成的解析序列：`'1'` →
> `main_sequence_disable_IPv6`（对 `qtype 28/65` 执行 `reject 0`），`'0'` →
> `main_sequence_with_IPv6`。

**【已失效】** 该前提不成立，原因有两条：

1. MosDNS 只在 SSR-Plus 的 `pdnsd_enable=4` 时存在，而框架要求 `pdnsd_enable` 为 `0`
   （`files/usr/bin/dnschain-reconcile:66-69` 把 `pdnsd_enable` 归一为 `dc_ssr_mode_for_profile`
   的结果，`files/etc/config/dnschain:200` 的 `ssr.mode` 默认 `'0'`），
   默认链路里没有 MosDNS 进程。
2. `filter_aaaa` 的**实际生效值**由 SSR-Plus 的 `set_ipv6_dns_filter` 写入
   `dhcp.@dnsmasq[0].filter_aaaa`；`ipv6_support=1` 时 `get_filter_aaaa()` 直接返回 0。
   页面「双栈策略 → 实际生效值」把两者并列显示，正是为了让读者看清这一点
   （`package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua:1444-1454`）。
   自检也只读 `dnsmasq` 那个键（`files/usr/bin/dnschain-selftest:244-252`）。

> 原 ADR：v0.3.5 曾把仓库值定为 `'0'`，理由是当时 `filter_aaaa='1'` 导致「双栈客户端
> 有公网 IPv6 却无法用 IPv6 上网」。

这条属历史陈述，保留（无代码可核，且不影响现行结论）。

---

## 3. 原决策与它的失效原因

> 原 ADR：仓库值取 `'1'`，并保留现网行为。现网路由已不是 v0.3.5 时的形态：
> `gfw_list.conf` 的 23614 个域名与 `black.list` 的 `chatgpt.com` 指向
> `127.0.0.1#5335`，其余域名走 dnsproxy 的国内 DoH。因此 MosDNS 的 `reject 0`
> 只作用于**需走代理的域名**，而非全部国外域名。

### 3.1 仓库值已不是 `'1'`（事实更正）

| 写入点 | 写入值 | 证据 |
|---|---|---|
| `99-gaming-optimize`（历史遗留） | `'1'` | `files/etc/uci-defaults/99-gaming-optimize:796-799` |
| `99-zz-dnschain`（后执行，覆盖前者） | `'0'` | `files/etc/uci-defaults/99-zz-dnschain:75-80` |
| `dnschain-reconcile`（每轮强制） | `'0'` | `files/usr/bin/dnschain-reconcile:97-98` |

`uci-defaults` 按文件名做 C 排序执行，`99-gaming-optimize` 先于 `99-zz-dnschain`；
这条顺序本身有 CI 断言（`.github/workflows/build-openwrt.yml:1207-1218`）。
所以 `99-gaming-optimize` 写的 `'1'` **每次刷机都会被后一个脚本覆盖成 `'0'`**，
之后由收敛器每轮重放（`dnschain-reconcile` 的 `reconcile_invariants`，
`files/usr/bin/dnschain-reconcile:51-113`）。

`99-gaming-optimize:796` 那段 `uci set` 与其上方 §6 的整段注释
（`files/etc/uci-defaults/99-gaming-optimize:765-799`）都停留在 v0.9.x 语义，
**当前无人清理**；读到它不能当成生效值。

### 3.2 抑制链已整体消失（前提失效）

| 原 ADR 的断言 | 现行事实 | 证据 |
|---|---|---|
| 由 MosDNS 的 `reject 0` 实现拒绝集 | 框架不再启动任何 `:5335` 服务；自检第 6 项断言 `:5335` **无监听** | `files/usr/bin/dnschain-selftest:220-231` |
| 国外 AAAA 被抑制 | `aaaa.policy` 为 `domestic 'keep'` / `foreign 'keep'`，且 `filter_https_rr '0'` | `files/etc/config/dnschain:74-82` |
| — | init 脚本头部明确写「不再抑制 AAAA」 | `files/etc/init.d/dnschain:19-20` |
| — | 自检第 11 项期望 `www.google.com` AAAA 为 `OK`；`EMPTY` 判 **FAIL** | `files/usr/bin/dnschain-selftest:282-293` |

注意自检第 11 项的语义与 v0.9.x **相反**：那时 `EMPTY` 是期望值，
现在 `EMPTY` 意味着 AAAA 被砍了。

### 3.3 「23614」这个数字不能写成常量（事实更正）

原 ADR 三处引用 `23614`（正文、被否决方案、后果）。该数字是某一次实测时
`gfw_list.conf` 的域名条数，而**该文件不在仓库里**：`files/etc/ssrplus/` 只有
`applechina.conf` 与 `mosdns-config.yaml` 两个文件，`gfw_list.conf` 由 SSR-Plus
运行时生成。仓库内其它位置对同一文件给出的是 `23717`、`23701`、`17804`、
`23714` 等不同数字：

| 数字 | 出处 |
|---|---|
| `23717`（47434 行 ÷ 2） | `files/usr/share/dnschain/dnschain.sh:153` |
| `23701` | `files/etc/uci-defaults/99-gaming-optimize:317`、`:322-323`、`:744-746` |
| `23614` | `files/etc/uci-defaults/99-gaming-optimize:772`、`:784`、`files/etc/ssrplus/mosdns-config.yaml:51` |
| `17804` | `files/usr/bin/dnschain-selftest:128`、`package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua:544` |
| `23714` | `files/usr/bin/dnschain-reconcile:168`、`files/usr/share/dnschain/dnschain.sh:962`、`:966` |
| `17813` | `files/usr/bin/dnschain-selftest:143` |

**结论**：任何具体条数都只能当作「某时点实测快照」，不得写进 ADR 作为常量。
需要规模时读运行时产物（页面走 `M.list_stats()`
`package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua:271-325`）。

---

## 4. 现行事实（本节即当前真相）

### 4.1 两个键，只有一个决定行为

```
shadowsocksr.@global[0].filter_aaaa   ← 用户偏好，被 ipv6_support=1 覆盖
dhcp.@dnsmasq[0].filter_aaaa          ← 实际生效值，必须为 '0'
```

- 偏好键的写入点：`general.lua:1412-1442`（页面开关，`ListValue`，写 `shadowsocksr` 键，
  随后调 `sync_dnsmasq_filter_aaaa` 同步到 dnsmasq）。
- 生效键的同步实现：`package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua:633-678`
  （`ipv6_support=1` → 目标值恒为 `0`；写后用读回值校验，失败返回 `verify_failed`）。
- 生效键的断言：`files/usr/bin/dnschain-selftest:244-252`。

### 4.2 为什么现在必须是 `'0'`

`ipv6_support=1` 时 SSR-Plus 会装上 IPv6 透明代理链，国外 IPv6 也进代理
（详见 [ADR-0002](0002-no-ipv6-proxy.md) 的失效说明与
[ADR-0005](0005-remove-chinadns-ng.md) §4.1）。既然国外 IPv6 不再直连，
抑制 AAAA 只会让国外站点失去双栈能力，没有任何收益。

`files/etc/config/dnschain:26-33` 的注释记录的就是这条推理。

---

## 5. 后果（更新）

- **不要按本文原结论把 `filter_aaaa` 改回 `'1'`。** 那会让国外 AAAA 变空，
  自检第 11 项 FAIL（`files/usr/bin/dnschain-selftest:290`）。
- 判断当前行为**必须读 `dhcp.@dnsmasq[0].filter_aaaa`**；读
  `shadowsocksr.@global[0].filter_aaaa` 会得出相反结论。
- 关闭 `ipv6_support` 时两个键才会重新耦合：那时偏好键真正决定行为
  （`dnschain.lua:638-642` 的分支），但国外 AAAA 会拿到真实值却直连 —— 这是
  ADR-0002 记录过的故障形态。
- `99-gaming-optimize:765-799` 与 `files/etc/ssrplus/mosdns-config.yaml:51` 里的
  v0.9.x 语义注释属遗留文本，改动 `filter_aaaa` 前不要以它们为依据。

---

## 6. 被否决的方案（原文保留，附失效说明）

> 原 ADR：取 `'0'`：那 23614 个被墙域名会拿到真实 AAAA，客户端改走 IPv6 直连，
> 被 RST，表现为「有 IPv6 但打不开站点」。

**【已失效】** 该否决理由随 ADR-0002 一起失效：国外 IPv6 现在经代理出站，
不存在「直连被 RST」。而且仓库现在**正是**取 `'0'`
（`files/etc/uci-defaults/99-zz-dnschain:76-80`、`files/usr/bin/dnschain-reconcile:97-98`）。

现行被否决的方案是反向的：**取 `'1'`（抑制）**。否决理由见 §4.2。

---

## 7. 证据索引

| 断言 | 证据 |
|---|---|
| `99-gaming-optimize` 仍写 `'1'` | `files/etc/uci-defaults/99-gaming-optimize:796` |
| `99-zz-dnschain` 写 `'0'` 并覆盖前者 | `files/etc/uci-defaults/99-zz-dnschain:45-50`（`pdnsd_enable` 同一套覆盖逻辑）、`:75-80` |
| 排序由 CI 断言 | `.github/workflows/build-openwrt.yml:1207-1218` |
| 收敛器强制 `'0'` | `files/usr/bin/dnschain-reconcile:97-98` |
| 实际生效键是 `dnsmasq` 的 | `files/usr/bin/dnschain-selftest:244-252`、`general.lua:1444-1454` |
| `aaaa.policy` 为 keep/keep | `files/etc/config/dnschain:74-82` |
| `:5335` 必须无监听 | `files/usr/bin/dnschain-selftest:220-231` |
| 自检第 11 项期望 `OK` | `files/usr/bin/dnschain-selftest:282-293` |
| 页面开关写偏好键并同步 | `general.lua:1412-1442`、`dnschain.lua:633-678` |
