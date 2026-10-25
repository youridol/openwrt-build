# ADR-0010：自动补全 —— 从客户机实际收发学出域名归属与 IP 段

- 状态：已实施（v0.24.0）
- 日期：2026-10-26
- 相关：[ADR-0006](0006-domain-routing-and-reroute.md)（域名归属与改道）、
  [ADR-0008](0008-direct-first-with-fallback.md)（直连优先 + fallback）、
  [ADR-0009](0009-client-link-diagnosis.md)（客户机链路诊断）
- 术语：[`GLOSSARY.md`](../../GLOSSARY.md) 的「自动补全」一节

---

## 1. 背景：70% 的答案 IP 判不出归属

`china` nft 集合是出站分流的唯一依据：命中就直连，不命中就走 `:1234`。
它由 SSR-Plus 从内置 IP 段生成，实测只有 **1333 条区间**（`nft list set inet ss_spec china`）。

实测对照（2026-10-25，路由器 `192.168.3.254`）：

| 判据 | 数值 |
|---|---|
| 抽样的国内可访问域名 | 112 |
| 答案 IP **不在** `china` 集合 | **79**（70%） |
| 其中 APNIC 官方 `|CN|ipv4|` 数据也查不到 | **110**（98%） |
| APNIC 完整中国 IPv4 段 | 8797 条 |

结论：**靠地理库判归属这条路走不通**。`china` 集合覆盖不全，
APNIC 数据也不收录国内 CDN 的回源 IP。已实证的误判案例：
阿里云 CDN 的 `47.239.100.208`（`ping` 22ms、`traceroute` 走 202.97 电信骨干）
连 APNIC 都不收录，于是被判成「境外」送去海外节点，而国内 CDN 拒绝海外访问
（经代理 0.3 秒即断，直连 200）。

ADR-0008 的「直连优先 + fallback」解决了「默认走直连」，
但解决不了「**哪些 IP 该走直连**」—— 兜底是 `return`（直连）之后，
真正需要代理的 IP 又必须靠 `blacklist` 精确命中。两端都需要准确的归属。

**唯一可靠的证据是「客户机实际访问通了」。**

---

## 2. 决定：域名为主判据，IP 为出站兜底

两层，职责不同，缺一不可：

| 层 | 数据 | 落点 | 决定什么 |
|---|---|---|---|
| 域名层 | `dom_auto_domestic` / `dom_auto_foreign` | `dnschain-split.conf` 的 `server=/域名/` | 解析**走哪条链** |
| IP 层 | `dc_learn4` / `dc_learn6` 集合 | `ss_spec_wan_ac` / `ss_spec6_tcp` 首行 `return` | 出站**是否绕代理** |

只做域名层不够：域名学对了、IP 没覆盖，流量照样绕海外（这正是 §1 的白屏）。
只做 IP 层也不够：域名走错链会拿到污染答案，学到的 IP 本身就是错的。

### 2.1 判定表（`_learn_judge`）

| 直连链 | 代理链 | 答案 | 判定 |
|---|---|---|---|
| 通 | 不通 | — | `domestic` |
| 通 | 通 | 不同 | `domestic` |
| 通 | 通 | 相同 | `both-ok-same`（不需要规则） |
| 不通 | 通 | — | `foreign` |
| 不通 | 不通 | — | `both-bad`（记重试，不写规则） |
| NXDOMAIN | NXDOMAIN | — | `invalid`（记重试） |

「答案不同 → domestic」有前提，必须写清：对合法国内 CDN 域名（`www.taobao.com`），
两条链返回不同 IP 是正常的（不同 CDN 节点），判 domestic 正确。
对**未入 gfw 名单但被污染**的域名，直连侧拿到的是污染答案，此时判 domestic 是错的 ——
这类域名由 §2.2 的 L4 纠错，但有最长一个 `learn_interval` 的窗口。

不做 TCP 实测来区分这两种情况：那需要每域名 2 次 `nc` 探测（每个 3 秒超时），
候选上千时不可行；DNS 级探测已足够筛掉「根本不通」。

### 2.2 L4：实测后翻转归属

`_learn_flip` 只做一个方向：

```
直连实测不通 + 代理实测通  → 从 dom_auto_domestic 删、写 dom_auto_foreign
其他（both-bad / 直连通）  → 不写，只记审计
```

反方向（国外 → 国内）是「学新域名」，由 `cmd_learn` 负责。
两个方向都做会让 L4 与 `cmd_learn` 互相覆盖，来回翻转。

**阈值与时间窗独立**：`learn_autofix_threshold`（默认 5）、
`learn_autofix_interval`（默认 3600 秒），与 L1-L3 的 `fail_threshold`（3）、
`autofix_interval` 分开计。理由：L1-L3 是幂等的服务动作（清缓存/重放/重启），
3 次就够；L4 会改 UCI 并触发分流重建，代价高得多，且失败可能只是抖动。
混用一个值会出两种错 —— 要么 3 次失败就改归属，要么 L1-L3 拖到 5 次才动。

---

## 3. 被推翻的方案（附实测证据）

### 3.1 `china6` 可写 → `auto-merge` 吞掉，dnsmasq 静默失败

**设想**：直接往 SSR-Plus 已有的 `china` / `china6` 集合里追加学到的 IP 段，
不新建集合。好处是 `ss_spec_wan_ac` 里已有 `ip daddr @china return`，无需改链。

**实测**：

```
nft add table inet t2
nft add set inet t2 s { type ipv4_addr; flags interval; auto-merge; }
nft add element inet t2 s { 203.0.113.0/24, 203.0.114.0/24 }
nft list set inet t2 s
  → elements = { 203.0.113.0-203.0.114.255 }     ← 两条合并成一条区间

nft delete element inet t2 s { 203.0.113.0/24 }
nft list set inet t2 s
  → elements = { 203.0.114.0/24 }
```

`auto-merge` 会把相邻段合并成区间，于是：

1. **无法精确删除单条** —— 删 `/24` 会拆分合并后的区间，删除结果与预期不符；
2. `china6` 的区间是 `2001:250::-2001:255:ffff:...` 这种大跨度，
   往里加 `/64` 会被合并进已有区间，**学了等于没学**，且看不出痕迹。

而且 SSR-Plus 每次 `start` 都会 `flush set` 重建这两个集合，
学习结果会被静默清空（无日志、无报错）。

**结论**：必须用**自己的集合**，不与 SSR-Plus 的集合混用。

### 3.2 独立 `inet dc_learn` 表 → 无法被 `ss_spec_wan_ac` 引用

**设想**：集合建在独立表 `inet dc_learn` 里，好处是 `ssr-rules:1174` 的
`nft delete table inet ss_spec` 不会连带删掉它。

**实测（nft 1.1.6，路由器 2026-10-25）**：

```
nft add table inet dctest
nft add set inet dctest s4 { type ipv4_addr; flags interval; }
nft add element inet dctest s4 { 203.0.113.0/24 }

nft add rule inet ss_spec ss_spec_wan_ac ip daddr @dctest.s4 return
  → Error: No such file or directory
nft add rule inet ss_spec ss_spec_wan_ac ip daddr @inet.dctest.s4 return
  → Error: No such file or directory
nft add rule inet ss_spec ss_spec_wan_ac ip daddr @dctest/s4 return
  → Error: No such file or directory
nft add rule inet ss_spec ss_spec_wan_ac ip daddr dctest@s4 return
  → Error: unknown raw payload base

nft add chain inet dctest c1
nft add rule inet ss_spec ss_spec_wan_ac jump dctest.c1
  → Error: Could not process rule: No such file or directory
```

**nft 不支持跨表引用集合，也不支持跨表 jump 链。** 独立表方案在语法层就不成立。

### 3.3 更早的 nat 链 `accept` → 拦不住后面的 redirect

**设想**：既然不能引用别的表，那就在**更早的 nat 链**里对学到的 IP 段 `accept`，
让它跳过后续链的 redirect。

**实测（2026-10-25）**：

```
nft add table inet dctest
nft add set inet dctest s4 { type ipv4_addr; flags interval; }
nft add element inet dctest s4 { 1.1.1.1 }
nft add chain inet dctest out { type nat hook output priority filter - 2; policy accept; }
nft add rule inet dctest out ip daddr @s4 accept

# 基线
nft -a list chain inet ss_spec ss_spec_wan_fw | grep redirect
  → counter packets 257 bytes 23688 redirect to :1234

curl https://1.1.1.1/
  → 301（被代理，走了海外节点）

# 复测
nft -a list chain inet ss_spec ss_spec_wan_fw | grep redirect
  → counter packets 258 bytes 23748 redirect to :1234     ← 照旧增长
```

**nat 表的 `accept` 不是「终止所有 nat 链」，只终止当前链。**
后续 nat base chain 仍会执行并 redirect。

### 3.4 最终采用：集合建在 `ss_spec` 内 + 入站链首行 `return`

代价：`ssr-rules:1174` 的 `nft delete table inet ss_spec` 会把集合一起删掉。
处置：**每轮收敛重建**（`dc_learn_hook` 幂等），页面显示挂钩状态。

实测验证（2026-10-25）：

```
# IPv4：ss_spec_wan_ac 首行
nft insert rule inet ss_spec ss_spec_wan_ac \
    ip daddr @dc_learn4 counter return comment "_DC_LEARN_HOOK_"

curl https://1.194.198.0/   ×2（该 IP 在集合内）
  → hook 计数器 packets 0 → 4
  → ss_spec_wan_fw 的 redirect 计数**不变**（未走代理）

curl https://1.0.0.1/        （不在集合内）
  → hook 计数器仍为 4（未命中）
  → 照旧被 redirect
```

```
# IPv6：ss_spec6_tcp 首行
nft insert rule inet ss_spec ss_spec6_tcp \
    ip6 daddr @dc_learn6 counter return comment "_DC_LEARN_HOOK6_"

curl -6 https://cloudflare.com/  ×2（2606:4700::/64 在集合内）
  → hook 计数器 packets 0 → 2
  → ss_spec6_redirect 计数**不变**（150 → 150）
```

挂钩必须带 `counter`：不带时 `nft list chain` 输出里没有 packets/bytes，
「挂钩到底有没有命中」无法观测 —— 实测一度以为挂钩失效，实际是生效了但无计数器可看。

---

## 4. 优先级

```
手写 dom_*  >  自动 dom_auto_*  >  数据库（gfw 名单）  >  未覆盖
```

- 手写优先由 `dc_gen_custom_lists` 保证：合并自动列表时用 `dc_exclude`
  剔掉手写已声明的域名，避免同一域名在 `custom-domestic.txt` 与
  `custom-foreign.txt` 里各出现一次（那会让 dnsmasq 把两条 `server=`
  当**候选**而非覆盖，取哪条不确定 —— v0.22.0 删改道的根因）。
- 页面「钉住」把自动条目转成手写：`uci add_list dom_<side>` +
  `del_list dom_auto_<side>` + `del_list dom_auto_<other>` + `del_list dom_<other>`。
- 页面「移除」只删两侧自动列表。

---

## 5. 防震荡

三个机制叠加，保证「学过的不再重复学」：

| 机制 | 作用 |
|---|---|
| 「已覆盖」判据 | 学到后写进 `dom_auto_*` → `dc_gen_custom_lists` 合并进 `custom-*.txt` → 下一轮 `_learn_candidates` 视其为已覆盖，跳过 |
| 父域覆盖 | 学到 `www.example.com` 后，`a.b.example.com` 不再单独学（逐级去掉最左标签查哈希） |
| L4 结果进规则表 | L4 翻转到 `dom_auto_foreign` 后同样进「已覆盖」，不会被 `cmd_learn` 再翻回来 |

**实测防震荡生效**：第二轮学习 `SKIPPED_COVERED=122`（第一轮学到的域名全部被跳过），
`CANDIDATES` 从 803 降到 375（阈值同时从 3 调到 5）。

---

## 6. 实测性能

### 6.1 nft 集合灌入（单事务 `nft -f`）

| 条数 | 耗时 | 文件大小 |
|---|---|---|
| 500 | 20 ms | 7 KB |
| 2000 | 60 ms | 28 KB |
| 10000 | 280 ms | 149 KB |
| 50000 | 1380 ms | 781 KB |

必须单事务（AGENTS 红线 8）：先 `flush` 再逐条 `add` 会在两条命令之间留出
「集合是空的」窗口，那时所有已学 IP 段失去直连豁免，流量突然绕海外。

### 6.2 学习一轮

| 场景 | 候选 | 耗时 |
|---|---|---|
| 首次（阈值 3，不限批） | 803 | 603 秒（触到 `_LEARN_BUDGET_SEC=600` 预算） |
| 阈值 5 + `learn_batch=60` | 375 | 约 40 秒 |

单域名实测（`dc_probe_chain` 两条链）：`acs.m.taobao.com` 直连 40ms + 代理 330ms。

### 6.3 候选筛选：从 109 秒到 480 毫秒

这是实现过程中最大的一处性能坑，记录备查：

原实现是 `awk | sort | while read dom; do ... done`，循环体里每条域名
fork 出 3~4 个进程（`grep -qxF`、父域逐级 `grep`、查重试队列的 `awk`）。
实测 647 个候选耗时 **109690 ms（109 秒）** —— 而这只是学习一轮的**准备阶段**。

改成单遍 awk（读三个「已覆盖」文件建哈希、读重试队列建哈希、扫计数器）
后，同样 647 条降到 **480 ms**（提速 227 倍）。

---

## 7. 默认值的选择依据

| 键 | 默认 | 依据 |
|---|---|---|
| `learn_enabled` | `1` | 功能默认开启；关闭后已学规则仍生效（页面显式提示条数） |
| `learn_interval` | `1800` | 30 分钟。一轮约 40 秒，不会持续占用 |
| `learn_threshold` | **`5`** | 实测阈值 3 → 954 个域名（大量一次性 CDN 边缘主机名）；阈值 5 → 429；阈值 8 → 127；阈值 12 → 20。家用常用站点（bilibili/taobao/quark/deepseek）在阈值 5 下全部保留 |
| `learn_batch` | **`60`** | 实测候选可达 800 条，不限批要跑几十分钟并占满 600 秒预算。60 条约 40 秒一轮，剩余候选后续周期消化 |
| `learn_retain_days` | `30` | 计数器只用于累计到阈值，太久远无参考价值且会让文件膨胀 |
| `learn_timeout` | `3` | 比 `health.timeout`（2 秒）长 —— 学习探测真实站点，跨境首包常超过 2 秒 |
| `learn_retries` | `3` | 单次 UDP 丢包常见，不重试会让结果随网络抖动漂移 |
| `learn_max_domains` | `0` | 不限。实测 2000 条约 65 KB UCI，可接受 |
| `learn_max_cidr` | `0` | 不限。实测 50000 条约 1.4 秒灌入 |
| `learn_autofix_threshold` | `5` | L4 独立阈值，见 §2.2 |
| `learn_autofix_interval` | `3600` | L4 独立时间窗，见 §2.2 |

**清单原写 `learn_threshold=3`、`learn_batch=0`，本实现改为 5 / 60，理由是上表的实测数据。**

---

## 8. 页面

「域名」tab 的「自动补全」section（`general.lua`）：

| 类型 | 数量 | 内容 |
|---|---|---|
| Flag | 1 | 启用自动补全 |
| Value | 9 | 周期（分钟）/ 触发次数 / 单轮上限 / 计数器保留 / 实测超时 / 重试 / 域名上限 / IP 段上限 / L4 阈值 |
| Button | 4 | 立即学习 / 演练（不落盘）/ 清空计数器 / 清空已学规则 |
| DummyValue | 3 | 学习层状态（6 行）/ 已学域名表（带「钉住」「移除」）/ 已学 IP 段表（带「移除」） |

### 8.1 学习必须在后台跑（页面按钮不能阻塞）

实测：一轮学习 68~603 秒，而 LuCI 按钮走 CGI，超时后浏览器报 **502 Bad Gateway**，
可进程还在跑 —— 用户以为失败又点一次，实测出现 **6 个并发 learn 进程**，
把路由器与上游一起打满。

处置三条：

1. **互斥锁** `$DNSCHAIN_STATE_DIR/.learn.lock`（目录锁，超 600 秒视为残留）：
   第二个实例直接退出并说明「已有一轮在跑」。
2. **按钮只启动不等待**：`learn-start` 用 `setsid` 把学习 fork 到独立会话
   （脱离 CGI 进程组，否则会被连带杀掉、日志 0 字节、锁残留），
   立即返回「已启动」。
3. **进度逐条落盘** `learn-progress.state`（`TOTAL` / `DONE` / `CURRENT`）：
   页面显示「正在实测 12/60」。原来只在全部结束时输出一次，
   页面在整个 8 分钟里只能显示「进行中」，用户无法区分「在跑」与「卡死」。

### 8.2 行内操作走独立路由

「钉住」「移除」是**每行**的动作，而 CBI 的 `Button` 只能挂在 section 上，
无法区分哪一行；`Table` 又要求每行是一个 UCI section，而这些行来自
list 选项与一个文本文件。

改用 GET + 独立路由 `admin/services/dns_chain/learn?act=..&v=..&side=..`，
服务端执行后 302 回本页并带 `learn_msg` 参数显示结果。

所有参数都经 model 层白名单校验与 `M.shell_quote` 转义 ——
域名来自 dnsmasq 日志（**客户机可控**），不转义就是命令注入。

---

## 9. 已知限制

| 限制 | 说明 | 处置 |
|---|---|---|
| 挂钩会被 SSR-Plus 整表删除 | `ssr-rules:1174` 的 `nft delete table inet ss_spec` | 每轮收敛 `dc_learn_hook` 重建；页面显示挂钩状态与命中数 |
| 「答案不同 → domestic」可能误判 | 见 §2.1 | 由 L4 在一个 `learn_interval` 窗口内纠错 |
| 一次性 CDN 主机名会被学到 | 阈值 5 仍有 429 个候选 | 提高阈值（8 → 127 个）、用「移除」逐个清理、`learn_max_domains` 设上限 |
| IPv6 只学 `/64` | 同站点跨多个 `/64` 时只覆盖其中一部分 | 接受：IPv6 侧流量占比低，且 `ss_spec6_*` 本身是兜底 redirect |
| 学到的 IP 段是「当时」的答案 | CDN 会换 IP | 每轮重新派生（`learn-cidr.txt` 整体重建），旧的自动消失 |
| `learn_max_cidr` 超限时静默截断 | 按文件顺序取前 N 条 | 页面显示「来源 IP 段」与「集合元素」两个数，不一致即可发现 |

---

## 10. 验证

本地（CI 也跑第一个）：

```sh
sh tools/verify-dnschain-domains.sh          # 契约断言
python3 tools/check-dnschain-lua.py          # Lua 模型 + 真实渲染
python3 tools/render-dnschain-diagrams.py --check
python3 tools/extract-dnschain-i18n.py
sh tools/verify-dnschain-ci-sim.sh
```

路由器实测（2026-10-25/26）：

| 项 | 实测值 |
|---|---|
| `learn --dry-run` | 候选 803，判定直连 505（未落盘） |
| `learn`（阈值 5 + batch 60） | 学到 60 条，`dom_auto_domestic` 有值 |
| `learn-cidr.txt` | v4 123 条 / v6 98 条 |
| `dc_learn4` / `dc_learn6` | 123 / 98 个元素 |
| `ss_spec_wan_ac` 挂钩 | 已挂，命中计数随真实流量增长 |
| 挂钩语义 | 集合内 IP 命中且不 redirect；集合外 IP 照旧 redirect |
| `split.conf` | 学到的域名 100% 生成 `server=/域名/127.0.0.1#5353` |
| 页面 | 10 控件可保存、2 张表有数据、4 按钮生效、6 行状态正确 |
