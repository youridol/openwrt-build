# ADR-0008：直连优先 + 上游层自动回落（取代 ADR-0006 §4–§7）

- 状态：已接受（v0.22.0 落地）
- 日期：2026-10-25
- 取代：[ADR-0006](0006-domain-routing-and-reroute.md) 的 §4–§7
  （健康探测与自动改道）；§3「归属判定」与 §8「自定义列表语义」仍有效
- 相关：[ADR-0003](0003-dns-chain-framework.md)（链路框架）、
  [ADR-0005](0005-remove-chinadns-ng.md)（双 dnsproxy 实例）
- 落地校验：`sh tools/verify-dnschain-domains.sh`、
  `python3 tools/check-dnschain-lua.py`、
  `python3 tools/render-dnschain-diagrams.py`

---

## 1. 背景

ADR-0006 设计了一套**应用层**的链路健康机制：每 `interval` 秒探测观测域名，
按 `fail_threshold` / `recover_threshold` / `min_dwell` 判定是否改道，
结论写进 `watch.servers` 再 SIGHUP dnsmasq。

用户提出新的要求：

> 「客户机的所有流量走直连，直连不通自动改走代理」

这与 ADR-0006 的机制在**目标上重叠、在层次上不同**：

| | ADR-0006 | 用户要求 |
|---|---|---|
| 判定层 | 应用层（Lua/shell 定时探测） | 上游层（DNS 解析器内部） |
| 粒度 | 观测域名（默认 8 个） | **所有域名** |
| 触发条件 | 连续失败达阈值 | 上游不可用（即时） |
| 副作用 | 写 `watch.servers`、SIGHUP | 无（纯内存状态） |

用户明确要求：**「这样性能可以最大化」**。

---

## 2. 决定

**删除应用层的探测与改道，改由 `dnsproxy --fallback` 在上游层完成。**

### 2.1 DNS 层

`dc_gen_dnsproxy_args()` 给国内实例（`:5353`）加一行：

```
--fallback 127.0.0.1:5336
```

`dnsproxy` 的 `--fallback` 语义是「regular upstreams 不可用时改用它们」，
所以：所有走 `:5353` 的域名，直连上游不可用时**自动**落到 `:5336`（DoH 经代理）。

### 2.2 IP 层（无需改动）

IP 层**本来就是**「未覆盖走代理」。`nft list chain inet ss_spec ss_spec_wan_ac` 的
最后两条规则是：

```
ip daddr @china return          ← 国内 IP 段直连（实测 2186 条）
jump ss_spec_wan_fw             ← 其余一律走代理
```

所以「未覆盖 IP/IP 段默认走代理」这一条不需要任何改动。

### 2.3 删除清单

| 删除对象 | 规模 |
|---|---|
| `files/usr/bin/dnschain-triage` | 1710 行 |
| `files/usr/bin/dnschain-health` | 448 行 |
| `dnschain.sh` 的 `dc_health_*`（10 个函数）+ `dc_gen_watch_servers` + `dc_triage_*` | 592 行 |
| `dnschain.lua` 的 9 个函数（`health_rows` / `triage_rows` / …） | 358 行 |
| `general.lua` 的三个 section + 分诊摘要 | 610 行 |
| `diagrams.lua` 的 `triage_map` / `triage_layout` | 164 行 |

连带删除：`triage-*.list` 记录文件、`--servers-file` 配置、
页面「DNS 分流状态」「分诊结果」「观测与阈值」三个 section、
「清空改道状态」按钮、三个分诊开关。

### 2.4 保留

| 保留对象 | 理由 |
|---|---|
| `dc_domain_class` / `dc_domain_preferred` / `dc_domain_custom` | 归属判定是分流规则的基础，与探测无关 |
| `custom-domestic.txt` / `custom-foreign.txt` | 用户可配置的分流来源 |
| `dc_probe_chain` | 自检与「单域名解释」仍在用 |
| `dc_explain_domain` | 页面「单域名解释」在用 |
| 「DNS 分流去向」图 | 用户明确要求保留，改为静态分流去向（两档） |
| gfw 名单的 `server=/域名/#5336` | 见 §3.2 |

---

## 3. 为什么这样更好

### 3.1 消除双写冲突（这是删除改道的**决定性**理由）

`watch.servers`（改道通道）与 `dnschain-split.conf`（静态分流）是**两套并存**的
`server=` 源。同一个域名在两处都有规则时，dnsmasq 把它们当**候选**
（不是后者覆盖前者），取哪条不确定。

实测（路由器 2026-10-25）：

```
split.conf:    server=/wikipedia.org/127.0.0.1#5336      ← 正确（代理）
watch.servers: server=/www.wikipedia.org/127.0.0.1#5353  ← 改道遗留（直连）
```

结果：

```
$ nslookup www.wikipedia.org 127.0.0.1        # 经 dnsmasq:53
Address: 31.13.106.4                          ← Facebook 的 IP（污染值）

$ nslookup www.wikipedia.org 127.0.0.1:5353   # 直连国内链
Address: 103.102.166.224                      ← 正确

$ nslookup www.wikipedia.org 127.0.0.1:5336   # 代理链
Address: 103.102.166.224                      ← 正确
```

**两条 dnsproxy 链都是干净的，是改道通道把正确结果覆盖成了污染的。**
这不是配置错误，是「两套 `server=` 源并存」这个设计本身的问题 ——
删除改道后规则只有一处来源，冲突从根上消失。

### 3.2 fallback 不判断污染，所以 gfw 名单必须保留

`--fallback` 只在「上游**不可用**」（连接失败 / 超时）时触发，
**不判断答案是否正确**。

所以 `www.google.com` 经阿里 DoT 可能**拿到污染答案但不超时** → 不触发 fallback
→ 用户得到错误 IP。这类域名必须由 gfw 名单显式写 `server=/域名/#5336`。

两者互补：

| 机制 | 兜住的情况 |
|---|---|
| gfw 名单 `server=/域名/#5336` | **通但脏**（拿到污染答案） |
| `--fallback 127.0.0.1:5336` | **真的不通**（超时 / 连接失败） |

### 3.3 性能

| 项 | 改前 | 改后 |
|---|---|---|
| 每轮 cycle 的 `logread` | 1 次（分诊取候选） | **0** |
| 每轮 cycle 的探测 | 最多 12 个目标并发 | **0** |
| 页面 `dnschain-triage list` | 实测 1.19 秒 | **0** |
| 页面 `dnschain-health status` | 实测 0.21 秒 | **0** |
| 写盘 | 每轮重写 `watch.servers` + 状态文件 | **0** |

---

## 4. 实测证据

### 4.1 `--fallback` 在超时时也触发

起临时实例，主上游指向黑洞 `192.0.2.1`、`--fallback 127.0.0.1:5353`：

```
$ nslookup www.baidu.com 127.0.0.1:5399
Address: 183.2.172.177      ← 回落成功

$ nslookup www.wikipedia.org 127.0.0.1:5399
Address: 103.102.166.224    ← 回落成功
```

证明触发条件包含**超时**，不只是 `connection refused`。

### 4.2 ⚠️ 地址格式必须用冒号

```
--fallback 127.0.0.1:5336      ✅ 正确
--fallback 127.0.0.1#5336      ❌ dnsproxy 拒绝启动
```

写成 `#`（dnsmasq 的写法）时报：

```
ERROR configuring proxy: parsing fallback upstreams configuration:
  invalid address 127.0.0.1#5353: bad top-level domain name label
```

进程退出后端口无人监听、客户机全部无法解析，而页面只显示「dnsproxy 未监听」，
看不出是格式问题。**这是本次改动最容易踩的坑。**

### 4.3 去掉 `servers-file` 不影响 `split.conf`

两套独立机制：

| 文件 | 加载方式 |
|---|---|
| `dnschain-split.conf` | `conf-dir=/tmp/dnsmasq.d` |
| `watch.servers` | `servers-file=/var/run/dnsmasq/watch.servers` |

实测：删掉 `dhcp.@dnsmasq[0].serversfile` 并重启 dnsmasq 后，
`www.wikipedia.org` 仍正确解析为 `103.102.166.224`，进程参数里
`servers-file` 确实消失。

---

## 5. 后果与约束

### 5.1 升级时必须清理遗留

老版本会在 UCI 里留下 `dhcp.@dnsmasq[0].serversfile` 指向
`/var/run/dnsmasq/watch.servers`。该文件不再生成，但 UCI 值不会自动消失 ——
dnsmasq 启动时会去读一个不存在的文件并在日志里报错。

`init.d/dnschain` 的 `clear_serversfile()` 会清掉它，判据是
**「值是否等于旧的 watch.servers 路径」**而不是「是否非空」——
用户可能自己配了 `serversfile` 指向别处，那是他的选择，不该被我们清掉。

自检第 18/19 项也改为反向检查（「通道已清理」），防止残留把链路搞坏。

### 5.2 自检第 5 项判据变更

从「不得出现 `--fallback`」改为「允许，但**必须**指向
`127.0.0.1:<foreign_port>`」。

保留校验是必要的：若有人把 fallback 改成 `1.12.12.12` 之类的明文上游，
gfw 域名回落时又会拿到污染答案（这正是 v0.10.0 删 fallback 的原因）。

### 5.2b 删除 `watch.servers` 引出的两个连带缺陷（已修）

这两处是**删除动作本身引入的回归**，不修会静默丢域名。

**(a) 观测基准集让 8 个域名失去分流规则**

`dc_watch_list()` 原本在 `health.watch` 为空时回落到 8 个基准域名。
它们被 `dc_exclude` 从 `split.conf` 剔掉 —— 设计前提是「只在 `watch.servers`
里出现」。删除 `watch.servers` 后这个剔除变成纯粹的数据丢失：

```
$ nslookup github.com 127.0.0.1
;; connection timed out; no servers could be reached
$ nslookup api.github.com 127.0.0.1     # 不在观测列表，正常
Address: 140.82.114.5
```

自定义列表也救不回来：剔除发生在「数据库 − 自定义国内 − 观测域名」之后，
对自定义国外同样生效。

**修法**：`dc_watch_list()` 恒返回空，`DNSCHAIN_WATCH_SEED` 删除。

**(b) 同一域名在 `split.conf` 出现两次**

`github.com` 同时在 gfw 名单与自定义国外列表里，两段各写一条。
dnsmasq 把两条相同的 `server=` 当候选，与 §3.1 同源。

**修法**：数据库国外段也排除自定义国外。

实测修复后 47496 行、`sort -u` 后仍 47496 行，零重复。

### 5.3 未覆盖域名首次访问的延迟

直连不通时，`--fallback` 要等主上游 `--timeout 8s` 超时后才切代理。
所以**首次**访问一个直连不通的域名会慢约 8 秒，之后 dnsmasq 缓存了结果就不再慢。

若这个延迟不可接受，可调小 `--timeout`，但代价是正常查询也可能被误判超时。
当前保持 8s（与改动前一致）。

---

## 6. 被否决的方案

### 6.1 保留分诊，改为「只写内存不落库」

否掉理由：分诊的价值是「处理未覆盖域名直连不通」，而 fallback 已经兜住了
这个场景。保留它只是把「写文件」改成「写内存」，探测开销仍在
（每轮 `logread` + 最多 12 个并发探测），与「性能最大化」的目标矛盾。

### 6.2 未覆盖域名默认走代理（与直连优先相反）

否掉理由：用户明确要求「先走直连」。而且国内长尾域名（不在 gfw 名单里的
国内站）走代理会变慢，属于反向优化。

### 6.3 保留 `watch.servers`，只删分诊

否掉理由：§3.1 的双写冲突来自 `watch.servers` 本身，不是分诊。
只删分诊而保留改道，冲突照旧存在（实测 `www.wikipedia.org` 仍会拿到污染答案）。

---

## 7. 验证

```
$ dnschain-selftest -f | grep SUMMARY
SUMMARY PASS=19 FAIL=0 SKIP=1
CONCLUSION: 链路正常

$ dnschain-selftest apply
OK=国内 204 条、国外 31 条，分流 23970 条已生效

$ dnschain-selftest explain www.baidu.com
DOMAIN=www.baidu.com / CLASS=custom-foreign / PREFERRED=foreign / ACTIVE=foreign
```

dnsproxy 进程参数确认含 `--fallback 127.0.0.1:5336`；
`dhcp.@dnsmasq[0].serversfile` 已清空；
`/var/run/dnsmasq/watch.servers` 已删除。

工具断言：

| 工具 | 结果 |
|---|---|
| `sh tools/verify-dnschain-domains.sh` | 148 OK / 0 FAIL |
| `python3 tools/check-dnschain-lua.py` | PASS=108 FAIL=0 |
| `python3 tools/render-dnschain-diagrams.py --check` | PASS=54 FAIL=0 |
| `python3 tools/extract-dnschain-i18n.py` | 311 条无缺失 |
| `sh tools/verify-dnschain-ci-sim.sh` | RC=0 |
