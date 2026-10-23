# ADR-0006：域名归属判定与链路健康自动改道

- 状态：已接受（v0.13.0 落地；v0.14.0 语义矫正；2026-10-23 按代码逐条更正）
- 日期：2026-10-22；2026-10-23 修订
- 取代：无
- 相关：[ADR-0003](0003-dns-chain-framework.md)（链路框架）、
  [ADR-0005](0005-remove-chinadns-ng.md)（双 dnsproxy 实例）
- 落地校验：`sh tools/verify-dnschain-domains.sh`

> **本文的写法**：原论证保留，凡与当前代码不符处标注 **【已更正】** 并给出证据。

---

## 1. 背景与需求

ADR-0003/0005 落地后，分流规则只有两个来源：

1. **SSR-Plus 的 gfw 名单**（`gfw_list.conf`，运行时生成物，不在仓库）
2. **框架自己生成的静态片段** `dnschain-split.conf`
   （`files/usr/share/dnschain/dnschain.sh:1046-1149`）

用户提出五条需求：

| # | 需求 | 落在本 ADR 的哪一节 |
|---|---|---|
| 1 | UI 新增「国内域名」「国外域名」两个自定义输入框，可录入/查看/编辑/清除，输入做格式校验 | §3 |
| 2 | 数据库未覆盖的域名：当前链路探测不可达时自动切到直连或代理 | §4、§5 |
| 3 | 默认策略：未录入的域名，国外链失败改直连；国内链失败改代理 | §4.2 |
| 4 | 改道示例要在实现里体现 | §6 |
| 5 | 匹配、探测、切换要准确可靠，有超时/重试/判定条件，不影响现有解析 | §5、§7 |

需求 1 是纯配置功能；需求 2~5 的核心矛盾是：

> **「按名单分流」是静态的，而「链路可达性」是动态的。**
> 一个域名今天该走代理，不代表十分钟后还该走代理。

---

## 2. 决策：静态归属 + 动态改道，两者分离

### 2.1 三个概念必须分清

| 概念 | 含义 | 谁决定 | 存哪 | 证据 |
|---|---|---|---|---|
| **归属**（class） | 域名「应该」走哪条链 | 配置 + 名单（静态） | UCI + `/var/etc/dnschain/db-domains.txt` | `dnschain.sh:827-887` |
| **首选**（preferred） | 由归属推导出的链路 | 归属（确定性映射） | 计算得出 | `dnschain.sh:892-897` |
| **当前**（active） | 实际生效的链路 | 健康探测（动态） | `/var/run/dnschain/health.state` | `dnschain.sh:1473-1482` |

不分开这三个概念的后果是「配置」与「运行时」互相污染：用户改了名单，探测结果
却被当成配置的一部分；或者链路恢复后，配置里还留着「已改道」的痕迹。分开之后：

- 配置文件只描述**意图**（归属）
- 状态文件只描述**事实**（当前链路）
- 两者独立可查，页面同时显示，不一致就是「正在改道中」

### 2.2 归属的四个取值与优先级

```
custom-domestic   用户录入「国内域名」   ← 最高
custom-foreign    用户录入「国外域名」
db-foreign        命中 gfw/基础/黑名单
uncovered         三个来源都没覆盖       ← 最低
```

另有一个非归属值 `invalid`：域名格式不合法时返回它
（`dnschain.sh:830-831`）。

**自定义优先于名单**是刻意的：用户手工录入就是要覆盖名单的自动判定。
若反过来，用户会遇到「我明明写了走直连，它还是走代理」这种无解困惑
（`dnschain.sh:789-791`）。

**自定义是精确匹配，数据库是后缀匹配** —— 两者语义不同，不要混：

| 来源 | 匹配方式 | 原因 |
|---|---|---|
| 自定义列表 | `grep -Fqx`（精确） | 用户录 `google.com` 表达的是「这个域名走代理」，不是「所有子域名都走代理」（`dnschain.sh:833-838`） |
| 数据库 | 逐级剥标签 + `grep -Fxf`（后缀） | 与 dnsmasq 的 `server=/域名/` 语义一致；否则 `www.google.com` 会被判 `uncovered` → 首选 domestic → 改道拉去直连 → 拿到污染答案（`dnschain.sh:793-812`） |

### 2.3 首选链路的映射

```
custom-foreign / db-foreign  → foreign   （代理出口 :5336）
custom-domestic / uncovered  → domestic  （直连出口 :5353）
```

`uncovered → domestic` 不是随便定的：**dnsmasq 的默认上游就是
`127.0.0.1#<entry_port>`**（`files/etc/uci-defaults/99-zz-dnschain:104-107`
写入唯一一条 `server=127.0.0.1#5353`）。所以未覆盖域名本来就走直连。
改道逻辑必须与这个事实一致，否则「不配置任何东西」与「配置了框架」会表现出
不同行为 —— 那是最难排查的一类不一致（`dnschain.sh:567-573`）。

---

## 3. 自定义列表的实现

### 3.1 UCI 结构

```uci
config domains 'dom_domestic'
	list domain 'www.baidu.com'

config domains 'dom_foreign'
	list domain 'www.google.com'
```

**【已更正】** 原文写 `config domains 'domestic'` / `config domains 'foreign'`。
**实际 section 名是 `dom_domestic` / `dom_foreign`**：

- `files/etc/config/dnschain:136`（`config domains 'dom_domestic'`）
- `files/etc/config/dnschain:141`（`config domains 'dom_foreign'`）

**改名的原因**：UCI 的 section 名在**同一配置文件内必须唯一，与类型无关**。
文件里已有 `config upstream 'foreign'`（`:62`），再写 `config domains 'foreign'`
会让 uci 直接报：

```
Parse error (section of different type overwrites prior section with same name)
```

并且**整个 `/etc/config/dnschain` 都读不出来** —— 框架所有 uci 取值全部失败，
症状是「页面空白 + 服务起不来」，而报错只提 section 重名。
报错原文与推理记录在 `files/etc/config/dnschain:126-135`。

代码里的消费者：`dc_gen_custom_lists`（`dnschain.sh:941-947`）、
`cmd_check`（`dnschain-health:140-154`）、
`dc_list_normalize`（`dnschain.sh:699-707`）。

两个**独立段**，不是同一段两个 list。理由：写回时同一段的两个 list
会被 CBI 互相覆盖（`NamedSection` 的 `parse` 按 section 整体写）。
页面也是两个独立 section：`general.lua:731`（`dom_domestic`）、
`:747`（`dom_foreign`）。

**空 list 不要写成 `list domain ''`** —— 那会落一个空值，生成分流时要额外过滤，
页面上也会显示成一个空条目（`files/etc/config/dnschain:137-139`）。

### 3.2 三道校验闸

| 闸 | 位置 | 作用 |
|---|---|---|
| ① 页面 | `general.lua` 的 `validate_domain()` | 用户敲错时立刻看到 |
| ② 脚本 | `dc_domain_valid()`（`dnschain.sh:649-693`） | 兜住直接 `uci set` 或从备份恢复 |
| ③ 自检 | `dnschain-health check`（`:135-181`）+ selftest 第 17 项（`dnschain-selftest:422-439`） | 事后可查 |

页面那道**刻意不比脚本更严**。页面校验写得过于复杂会误拒合法域名
（典型是 `xn--` 形式的 IDNA —— `--` 在 punycode 里是正常字符，
拦它会把整类中文域名拒掉）。所以页面只拦「明显不对」的形态，
权威判定在脚本。

### 3.3 格式规则（`dc_domain_valid`）

`dnschain.sh:631-693` 的实际规则：

- 总长 ≤ 253，每个标签 1..63
- **至少两级**（单标签是主机名；`//` 是 dnsmasq 的「无点名字」特殊写法，
  混进来会改变语义）
- 标签只允许 `a-z 0-9 -`，不以 `-` 开头/结尾
- 顶级域：纯字母且 ≥2 位，**或 `xn--` 前缀**
- 拒绝 `..`、首尾点、以及 `[!a-z0-9.-]` 之外的字符
- **不接受通配符**：`server=/域名/` 是标签后缀匹配，用户写 `*.example.com`
  会得到一条永远匹配不到的规则，而页面上看不出任何异常（`dnschain.sh:642-644`）

规范化在 `dc_domain_normalize`（`:624-629`）：去首尾空白、去尾部点、转小写。
**只去首尾空白，不去中间的** —— 中间有空格一定不是合法域名，
去掉会把 `a .com` 静默变成 `a.com` 收下。

**同一域名同时出现在两个列表里必须拒绝**（归属无法确定）：
`dnschain-health check` 用 `grep -Fxf` 求交集（`:156-172`），
BusyBox 不保证带 `comm`。

### 3.4 分流结果

| 归属 | dnsmasq 规则 | nftset | 效果 |
|---|---|---|---|
| 自定义国内 | `server=/域名/127.0.0.1#<entry_port>` | `china` | 解析走直连，IP 入直连集 |
| 自定义国外 | `server=/域名/127.0.0.1#<foreign_port>` | `blacklist` | 解析走代理，IP 入代理集 |
| 数据库国外 | 同上 | `blacklist` | 同上 |
| 未覆盖 | 不写规则 | — | 落到 dnsmasq 默认上游（直连） |

证据：`dnschain.sh:1105-1124`。

`nftset` 目标集**先探测再写**（`dc_nftset_exists`，`dnschain.sh:973-975`）：
SSR-Plus 未启用时 `ss_spec` 表根本不存在，此时写 `nftset=` 会让 dnsmasq
每解析一个域名都尝试写集合并失败，在日志里刷错。宁可少写一行。

**但「宁可少写」是有条件的**（v0.14.1 实测修正）：SSR-Plus 重建规则的窗口内
`ss_spec` 表短暂消失，此时若一条 `nftset=` 都不写，国外流量就不进代理。
现行兜底：表整体不在但上一版片段有 `nftset` 行 → 沿用上一版行
（`dnschain.sh:1082-1103`）。

---

## 4. 自动改道的实现

### 4.1 核心规则（一句话）

> **首选链不通，且另一条链通 → 切到另一条链。**

### 4.2 两条需求规则如何落到这一句上

| 需求原文 | 对应场景 | 首选 | 另一条 | 结果 |
|---|---|---|---|---|
| 「访问国外链路失败则自动改为直连」 | 数据库国外域名 | `foreign` | `domestic` | 切直连 |
| 「访问国内链路失败则自动改为代理」 | 未覆盖域名 | `domestic` | `foreign` | 切代理 |

两条规则不是两个 if 分支，而是**同一个判定的两个实例** ——
因为「首选」已经由归属决定。这样加第三类域名时不需要再改判定逻辑
（`dnschain.sh:1578-1585`）。

### 4.3 判定状态机

对每个观测域名（`dc_health_cycle`，`dnschain.sh:1587-1770`）：

```
情形 A：当前 == 首选
    r_pref 通（OK/EMPTY）  → 计数清零，result=<r_pref>          → 状态 ok
    r_pref 不通：
        r_other 通          → fail++；
                              fail ≥ fail_threshold → 改道，result=switch:<a>-><b>
                              fail <  fail_threshold → result=probe:<a>
        r_other 也不通      → 不改道，result=both-bad:<a>/<b>
情形 B：当前 != 首选（已改道）
    r_pref 通：
        ok ≥ recover_threshold 且 now-last ≥ min_dwell
                            → 回切，result=recover:<r>
        否则                → 只累加 ok，保留 last，result=recover-wait:<r>
    r_pref 不通             → result=fallback:<r>，保持当前链
```

注意两处细节：

- **`NX` 也算「通」**：`dc_probe_chain` 把 `OK|EMPTY|NX` 都当作链可达
  （`dnschain.sh:1816-1824`）。域名不存在不代表链路故障。
- **`last` 是「上次改道的时刻」，不是「上次探测的时刻」**。等待回切期间必须用
  `dc_health_write_keep_last`，否则每轮刷 `last=now` → `now-last` 恒为 0 →
  `min_dwell` 永不满足 → **回切被永久阻塞**
  （`dnschain.sh:1516-1537`、`:1725-1747`）。

**为什么双链都不通时不改道**：那不是分流问题，是链路故障。改道只会把
「两条链都坏」伪装成「一条链能用」，掩盖真正的问题。页面把 `both-bad`
单独标红，直接提示「先查链路」（`dnschain.sh:1584-1585`）。

### 4.4 阈值默认值

与 `files/etc/config/dnschain:163-191` 逐项核对：

| 参数 | 配置默认值 | 代码读取点 | 理由（配置注释原文摘要） |
|---|---|---|---|
| `timeout` | `2`（秒） | `dnschain.sh:1647` | BusyBox `nslookup` 无 `-timeout`，框架自实现硬超时；2s 覆盖跨境 RTT 且一轮 10 域名可控 |
| `retries` | `2` | `dnschain.sh:1648` | 单次 UDP 丢包常见；不重试会让改道变成随机行为 |
| `fail_threshold` | `2`（轮） | `dnschain.sh:1649` | 避开单轮抖动（一轮里可能两个域名各丢一次包） |
| `recover_threshold` | `3`（轮） | `dnschain.sh:1650` | 链路临界时反复横跳，每次横跳都改一次 servers-file |
| `min_dwell` | `120`（秒） | `dnschain.sh:1651` | 同上，另加时间维度的下限 |
| `interval` | `60`（秒） | `dnschain-health:321`、`files/etc/init.d/dnschain:372` | 小于 15s 会被抬到 15s（一轮探测本身 3~10s，更短只会重叠） |
| `enabled` | `1` | `dnschain.sh:1595`、`files/etc/init.d/dnschain:369` | 关闭后不探测、不改道，静态分流照常 |

**`interval` 的三处特殊语义**：

- `interval=0` → 不进入轮询循环，只能从页面手动触发
  （`dnschain-health:322-325`）
- `interval < 15` → 被抬到 15（`dnschain-health:329`）
- `health.enabled=0` → init 不启动守护实例（`files/etc/init.d/dnschain:369-370`）

**`watch` 默认 8 条**（国内外各 4 个基准站点）：
`files/etc/config/dnschain:184-191`。

### 4.5 观测列表，不做全量探测

全量探测不可行，也会把 dnsmasq 与 dnsproxy 打满。
故只探测 `health.watch` 里的域名（`dc_watch_list`，`dnschain.sh:744-764`）。

**清空后自动回落到内置基准集** —— 空列表意味着永不探测、页面永远「无数据」，
用户会以为功能坏了（`dnschain.sh:709-716`、`:735-742`）。

**这是本设计明确的取舍**：改道只对观测域名生效，其余域名仍按静态归属走。
理由是「可观测性」比「全覆盖」更重要。

**观测域名必须从静态片段里排除** —— 见 §5.3。

---

## 5. 改道的生效通道：`--servers-file` + SIGHUP

### 5.1 为什么不能用静态片段

`dnschain-split.conf` 通过 `--conf-dir` 加载。**dnsmasq 的 `reload`（SIGHUP）
不重读 conf-dir** —— 改它必须 `restart`，代价约 3 秒解析中断。
改道是可能每分钟发生的事，绝不能走 restart
（`AGENTS.md:497-517`；`files/etc/init.d/dnschain:319-324`）。

### 5.2 采用的通道

dnsmasq 的 `--servers-file` 在收到 SIGHUP 时会被**重新读取**
（`dnschain.sh:1151-1163` 的注释记录了 `dnsmasq.c` 的 `EVENT_RELOAD` 分支
显式调用 `read_servers_file`）。于是：

```
改道 → 重写 /var/run/dnsmasq/watch.servers → kill -HUP dnsmasq
```

不重启、不清缓存、不影响未观测的域名。

OpenWrt 侧通过 UCI 下发：`dhcp.@dnsmasq[0].serversfile`
（`files/etc/init.d/dnschain:140-155`），由 `dnsmasq.init` 转成 `--servers-file`
（它把这个选项写进 `/var/etc/dnsmasq.conf.*`，**不放在命令行上**）。

**【已更正】** 原文 §5.2 写通道路径是 `/var/etc/dnschain/watch.servers`。
**实际是 `/var/run/dnsmasq/watch.servers`**：

- 库常量 `DNSCHAIN_WATCH_SERVERS="/var/run/dnsmasq/watch.servers"`
  （`files/usr/share/dnschain/dnschain.sh:607`）
- init 的 `update_serversfile` 用该常量写入 UCI
  （`files/etc/init.d/dnschain:143`、`:148`）
- uci-defaults 也引用库常量，取不到才回落到同一路径
  （`files/etc/uci-defaults/99-zz-dnschain:171-176`）

**必须在 ujail 已挂载的目录里**：dnsmasq 由 ujail 降权到 uid 453 运行，
只能看到 init 脚本里 `procd_add_jail_mount` 声明过的路径。
servers-file 指向白名单外的目录时**既不报错也不生效** —— SIGHUP 成功、
日志干净，改道却完全没发生（`dnschain.sh:589-606`）。

路由器实测：`uci get dhcp.@dnsmasq[0].serversfile`
→ `/var/run/dnsmasq/watch.servers`。

**文件权限必须是 `0644`**：`mktemp` 生成的是 `0600 root:root`，
uid 453 读不到（`dnschain.sh:1214-1228`）。

### 5.3 硬约束：一个域名只能有一处 `server=` 声明

若同一个域名同时出现在静态片段与 `watch.servers` 里，dnsmasq 会把两条
`server=` 当作**候选**（不是后者覆盖前者），改道就退化成「随机走一条」，
而且两条链都能解析时完全看不出问题（`dnschain.sh:1037-1042`）。

因此 `dc_gen_dnsmasq_split()` **必须**从静态片段里排除观测域名
（`dnschain.sh:1063-1075`）。自检第 18 项专门查这个重叠
（`dnschain-selftest:441-463`）。

排除用 `dc_exclude` 而不是裸 `grep -Fvxf`：BusyBox 的 `grep -Fvxf`
在 **pattern 文件为空** 时返回 rc=1 且**输出零行** —— 不是「一条都不排除」，
而是「把输入全吞掉」（`dnschain.sh:181-220`）。

### 5.4 通道就绪性必须验「生效的配置文件」

只配 UCI 不生效是存在的。判据不能只看进程 argv：OpenWrt 的
`init.d/dnsmasq` 用 `append_parm "$cfg" "serversfile" "--servers-file"`，
把它写进**生成的配置文件**而不是命令行。

所以三条判据（`dnschain-selftest:465-541`、`dnschain.lua:900-976`）：

1. `dhcp.@dnsmasq[0].serversfile` 配了路径
2. 文件存在且可读
3. **生效的 `/var/etc/dnsmasq.conf.*` 里有 `servers-file=<该路径>`**
4. （附加）该目录在 ujail 白名单内 —— 比较时两侧都要去掉尾斜杠，
   因为 `procd_add_jail_mount_rw /var/run/dnsmasq/` 带尾斜杠

页面「改道通道」一栏读同一套判据（`general.lua:1013-1040`）。

---

## 6. 需求第 4 条：改道示例在实现里的体现

单测（`tools/verify-dnschain-domains.sh` 与 `tools/check-dnschain-lua.py`
之外的 dash 单测）逐条覆盖。下列场景中的 `result` 值都是
`dc_health_cycle` 实际会写入的字符串（`dnschain.sh:1686-1751`）：

```
场景 A：github.com（db-foreign，首选 foreign）国外链 TIMEOUT、直连 OK
  第 1 轮 → fail=1 < 阈值 2 → 不改道，result=probe:TIMEOUT
  第 2 轮 → fail=2 ≥ 阈值且另一条通 → 改道，result=switch:TIMEOUT->OK
          watch.servers 出现 server=/github.com/127.0.0.1#5353

场景 B：www.qq.com（uncovered，首选 domestic）直连 TIMEOUT、代理 OK
  第 1 轮 → 不改道，result=probe:TIMEOUT
  第 2 轮 → 改道，result=switch:TIMEOUT->OK
          watch.servers 出现 server=/www.qq.com/127.0.0.1#5336

场景 C：两条链都 TIMEOUT → 不改道，result=both-bad:TIMEOUT/TIMEOUT

场景 D：改道后首选链恢复 → 连续 3 轮成功（recover_threshold）+ 驻留 ≥ 120s
        → 回切，result=recover:OK

场景 E：自定义列表里的域名 → 归属记为 custom-*，但**照常参与改道**
  例：www.baidu.com 录进自定义国内（归属 custom-domestic，首选 domestic）
  直连 TIMEOUT、代理 OK
  第 1 轮 → 不改道，result=probe:TIMEOUT
  第 2 轮 → 改道到 foreign，result=switch:TIMEOUT->OK
  链路恢复后 → result=recover:OK → 回切 domestic
```

### 6.1 场景与 `dnschain-health status` 的 5 档状态对照

`cmd_status` 的 `chain_state` 判定（`dnschain-health:102-112`）与上面场景的对应：

| 场景 | 写入的 `result` | `chain_state` |
|---|---|---|
| A/B/E 第 1 轮 | `probe:TIMEOUT` | **`degraded`** |
| A/B/E 第 2 轮 | `switch:TIMEOUT->OK` | **`rerouted`** |
| C | `both-bad:TIMEOUT/TIMEOUT` | **`both-bad`** |
| D 等待期 | `recover-wait:OK` | **`rerouted`** |
| D 回切后 | `recover:OK` | **`ok`**（落入 `*)` 分支） |
| 链路正常 | `OK` / `EMPTY` | **`ok`** |
| 还没有探测数据 | （空） | **`unknown`** |

**`custom` 不是一档状态**：它只是「归属由用户补全」的计数，
`SUM` 行里与 normal/degraded/rerouted/both_bad 并列输出，但那些是子集关系
（`dnschain-health:63-74`、`:119-122`）。

> ⚠️ **场景 E 的语义在 v0.14.0 被矫正过，此前实现是错的。**
>
> 旧实现把自定义域名当 `fixed`：命中就写 `fixed:` 状态并 `continue`
> **跳过整个改道判定**，注释写的是「你写的就是最终答案」。
> 这与需求直接冲突 —— 需求说自定义输入框「只作为补全追加到数据库而不是
> 直接改道」，而改道针对「数据库未覆盖的域名」；**补全归属正是给未覆盖
> 域名定归属**，它必须继续参与改道，否则用户显式补全的域名反而失去了
> 自动恢复能力。
>
> 旧实现还有个更严重的副作用：`fixed` 档**抢在探测结果之前**判定，
> 于是自定义域名的真实状态被永久吞掉 —— 页面看不出它是否健康，
> 汇总的 normal/rerouted/both_bad 也少算了它们，总数对不上。
>
> 现状（v0.14.0+）：`fixed` 档已删除，`dc_domain_fixed` 改名
> `dc_domain_custom`（只表示「归属由用户补全」，`dnschain.sh:899-931`），
> 改道循环不设例外（`dnschain.sh:1674-1682`）。

场景 A 对应需求第 4 条前半句（「表内未收录域名访问国外不通时改走直连」），
场景 B 对应后半句（「访问国内不通时改走代理」）。

> 注：需求原文说「表内未收录域名」，而场景 A 用的是数据库命中域名。
> 两者在改道机制上**完全一致** —— 因为改道只看「首选 vs 另一条」，
> 不看归属来源。区别只在首选是哪个。故用 A 演示「国外不通改直连」
> 的机制，B 演示「国内不通改代理」，合起来覆盖两条规则。

---

## 7. 对现有功能的影响

| 现有行为 | 影响 | 验证方式 |
|---|---|---|
| 静态分流（gfw 名单） | 不变，只是生成时多排除观测域名 | selftest 第 18 项 |
| dnsmasq 缓存（唯一缓存层） | 不变；SIGHUP 不清缓存 | selftest 第 16 项 |
| dnsproxy 双实例 | 不变；改道只换 dnsmasq 的上游指向 | selftest 第 1–15 项 |
| 开机时序 | 健康守护先 sleep 一个 interval 再探，避开开机风暴 | `dnschain-health:288-291`、`:332` |
| SSR-Plus 兼容 | 不变；`nftset` 目标集先探测再写 | `dc_nftset_exists` |
| 解析中断 | 保存配置时 restart 一次（约 3 秒）；**改道不中断** | `dc_health_cycle` 内无 restart |
| 并发安全 | `dc_health_cycle` 用 `mkdir` 原子锁，同一时刻只跑一轮 | `dnschain.sh:1597-1645` |

**锁的顺序很关键**：实例就绪检查必须在**取锁之前**。原顺序是
「取锁 → 检查实例 → 不就绪就 `return`」，那条 `return` 不释放锁；
daemon 是常驻进程、`$$` 恒定 → 某轮撞上 dnsproxy 未监听就永久自锁，
后续每轮都打印「SKIP 已有一轮探测在跑」→ **改道功能完全停止而日志正常**
（`dnschain.sh:1613-1629`）。

---

## 8. 页面与图

### 8.1 为什么新增「域名」tab

三件事在逻辑上是一条链：**我录了什么 → 它会怎么走 → 现在哪个不正常**。
拆成多个 tab 时用户得来回切才能对上，而「配置」与「诊断」分离会让
「为什么它没按我写的走」这个问题变成跨页推理。

实现：`general.lua:98-106` 的 `TAB_LABELS` 里有 `domains`；
对应 section 在 `general.lua:731`、`:747`、`:845`、`:1001`、`:1099`、
`:1168`、`:1236`。

### 8.2 两张图的职责分工

| 图 | 回答的问题 | 形态 | 实现 |
|---|---|---|---|
| **判定链路图** | 这个域名会怎么走、在哪一步出问题 | 上下两段：归属→首选 / 探测→结论 | `diagrams.lua` 的 `status_layout` |
| **改道状态图** | 现在哪些域名不正常、该查什么 | 一个根分五种状态，每种带计数、清单与下一步 | `diagrams.lua:730-745`（`status_map`） |

**状态分五档而不是「正常/异常」两档**：把「已自动改道并恢复可用」
与「两条链都不通」混在一起是错的 —— 前者不需要人介入，后者必须人介入。

`STATUS_ORDER = { "ok", "degraded", "rerouted", "both-bad", "unknown" }`
（`diagrams.lua:561`）。未知/空 `state` 必须归入 `unknown` 档以保证行数守恒
（`diagrams.lua:601-611`）。

### 8.3 图的实现约束（都踩过）

- 连线用三次贝塞尔 `C`。直角折线在分叉处是硬拐角，视觉上像断链
- 控制点 `dx ≤ (x2-x1)/2`，否则曲线自交成扭结
- 节点必须有填充，`fill="none"` 时连线从节点内部透出
- **marker id 必须带前缀**（`dcrt` / `dcst`）。判定链路图由**同一函数渲染两次**
  （概览 tab + 域名 tab），CBI 的 tab 是 CSS 隐藏、不是懒加载，两个 tab 都进
  同一份 HTML。id 是文档级全局的，同名则 `url(#dcrt-a-ok)` 全部解析到第一个定义
  （`diagrams.lua:26-27`、`:346-370`、`:741-745`）
- 动态文本必须 HTML 转义 —— 域名或原因含 `& < >` 会让整张图解析失败

这些约束由 `tools/render-dnschain-diagrams.py` 做纯几何校验。

### 8.4 单域名解释的消费者

页面「判定链路」里的「解释」按钮调 `dnschain-health explain <域名>`
（`dnschain.lua:842-856`），输出 12 个 `KEY=VALUE` 行。

**【新增章节】** 原文未列出这 12 个键，而它们是页面唯一的解释数据源：

| 键 | 含义 | 取值 | 代码 |
|---|---|---|---|
| `DOMAIN` | 规范化后的域名 | 小写、去尾点 | `dnschain.sh:1842` |
| `CLASS` | 归属 | `custom-domestic` / `custom-foreign` / `db-foreign` / `uncovered` / `invalid` | `:1843` |
| `PREFERRED` | 首选链路 | `domestic` / `foreign` | `:1867` |
| `ACTIVE` | 当前链路 | `domestic` / `foreign` | `:1868` |
| `WATCH` | 是否在观测列表 | `0` / `1` | `:1869` |
| `CUSTOM` | 归属是否由用户补全 | `0` / `1`（**不表示不参与改道**） | `:1870` |
| `PROBE_DOMESTIC` | 直连链探测结果 | `OK` / `EMPTY` / `NX` / `TIMEOUT` / `FAIL` | `:1881` |
| `PROBE_FOREIGN` | 代理链探测结果 | 同上 | `:1882` |
| `ANSWER_DOMESTIC` | 直连链首个地址 | 地址或空 | `:1883` |
| `ANSWER_FOREIGN` | 代理链首个地址 | 地址或空 | `:1884` |
| `DECISION` | 判定 | `keep-domestic` / `keep-foreign` / `reroute-domestic` / `reroute-foreign` / `both-bad` / `reject` | `:1934` |
| `REASON` | 中文原因 | 一句完整说明 | `:1935` |

`CLASS=invalid` 时只输出 `DOMAIN` / `CLASS` / `DECISION=reject` / `REASON`，
其余键缺省（`:1845-1849`）。

**缺字段就是「取不到」，页面显示「—」，不做默认值填充** ——
显示「—」比显示假的 0 好（`dnschain-health:34-35`）。

`DECISION` 的判定必须与 `dc_health_cycle` **完全一致**，否则用户按解释去排障
却发现系统干的是另一件事（`dnschain.sh:1886-1894`）。
两者规则相同，但 `explain` 是即时双链探测、`cycle` 是按阈值累计，
**单次不一致属正常**（`cycle` 需要连续 `fail_threshold` 轮才改道）。

---

## 9. 被否决的方案

### 9.1 否决：用 dnsproxy 的 `[/域名/]` 做动态分流

理由与 ADR-0005 相同：上万条 `[/域名/]` 会让 dnsproxy 为每域名
注册一条 reserved 上游，资源耗尽 → `connection timed out`。
实测过，不可行（`files/etc/init.d/dnschain:292-301`）。

### 9.2 否决：改道时 restart dnsmasq

3 秒解析中断，而改道可能每分钟发生。不可接受。

### 9.3 否决：全量探测所有域名

一轮几小时，且会把 dnsmasq 与 dnsproxy 打满。见 §4.5 的取舍说明。

### 9.4 否决：把「已改道」持久化到 UCI

断电前的「已改道」不该在下次开机继续生效 —— 那时链路可能是好的。
状态放 `/var/run`，重启即重算。这也让「配置」与「事实」保持分离（§2.1）。
服务停止时 `stop_service` 会主动删掉状态文件
（`files/etc/init.d/dnschain:434-436`）。

### 9.5 否决：页面用嵌套 `<form>` 做「单域名解释」

CBI 的 map 模板已把整页包在 `<form method="post">` 里。
内层 `<form>` 是非法 HTML，浏览器会丢掉内层标签 ——
「解释」按钮实际提交的是外层表单（= 触发保存）。
改用普通 input + button，由 `dnschain.js` 绑定点击后自己跳转（含拦截 Enter）。

### 9.6 否决：在 `dc_domain_class` 里加进程内 memo 缓存

v0.14.1 试过，反而更慢：取值要走 `printf | awk`（BusyBox ash 无关联数组），
一次 fork 就 0.02s，比直接 `grep -Fxf` 还贵。实测 8 个域名从 0.29s 涨到 0.36s。
真正的性能修复在**减少调用次数**与页面级缓存
（`dnschain.sh:814-826`）。

---

## 10. 后续可做

- 观测列表按「流量最大的域名」自动挑选（现在靠手工 + 基准集）
- 改道历史（现在只有最后一次结果，没有时间序列）
- 按 IP 集而非域名做改道判定（对 CDN 更准，但需要 conntrack 支持）
- **给收敛器补自动触发点**（ADR-0003 §9.2 的 N1）：本 ADR 的改道依赖
  `dnschain-health daemon` 常驻，但静态归属的归一（`dnschain-reconcile`）
  目前只能手动触发

---

## 11. 证据索引

| 断言 | 证据 |
|---|---|
| section 名是 `dom_domestic`/`dom_foreign` | `files/etc/config/dnschain:136`、`:141` |
| 改名原因（uci 报错原文） | `files/etc/config/dnschain:126-135` |
| 归属四档 + `invalid` | `dnschain.sh:827-887` |
| 首选映射 | `dnschain.sh:892-897` |
| 自定义精确匹配、数据库后缀匹配 | `dnschain.sh:833-842`、`:844-884` |
| 格式校验规则 | `dnschain.sh:631-693` |
| 阈值默认值 | `files/etc/config/dnschain:163-191` |
| 阈值读取点 | `dnschain.sh:1647-1651` |
| 状态机 | `dnschain.sh:1686-1751` |
| `last` 语义（回切不阻塞） | `dnschain.sh:1516-1537`、`:1725-1747` |
| `mkdir` 锁 + 检查顺序 | `dnschain.sh:1597-1645` |
| `watch.servers` 路径 | `dnschain.sh:607` |
| ujail 白名单约束 | `dnschain.sh:589-606` |
| 文件权限 `0644` | `dnschain.sh:1214-1228` |
| 排除观测域名 | `dnschain.sh:1063-1075` |
| `dc_exclude` 空文件坑 | `dnschain.sh:181-220` |
| 5 档状态 | `dnschain-health:102-112` |
| `custom` 只是计数 | `dnschain-health:63-74`、`:119-122` |
| explain 的 12 个键 | `dnschain.sh:1835-1936` |
| 自检第 17–20 项 | `dnschain-selftest:422-574` |
| 页面 7 个 tab | `general.lua:98-106` |
| 改道通道就绪判据 | `dnschain-selftest:465-541`、`dnschain.lua:900-976` |
