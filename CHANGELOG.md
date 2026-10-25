# Changelog

本仓库所有功能/配置改动均记录于此。版本判型遵循全局规范（PATCH / MINOR / MAJOR）。


## [v0.23.0] - 2026-10-25

### 新增 — 客户机链路诊断与分级自愈

用户要求：「在 DNS 分流插件中添加在线读取抓包主机链路信息分析客户机不通的链路后处理」，
场景是**某些移动 App 混合国内外的资源打不开**（举例：拓竹 / Bambu）。

设计依据：`docs/adr/0009-client-link-diagnosis.md`。

#### ① 数据来源：日志优先，一期不抓包

实测事实（路由器，2026-10-25）：

| 项 | 实测 |
|---|---|
| `dnsmasq` 的 `logqueries` | **已是 1** |
| 日志可用条数 | 998 条 |
| `tcpdump` | **未安装**（CI 未启用） |
| 日志动作分布 | `reply` 439 / `cached` 182 / `forwarded` 114 / `nftset` 24 |

DNS 层的四段链路里，前三段日志完全够用，只有「DNS 成功但 TCP 连不上」
必须抓包 —— 那一层留二期。一期零新增依赖。

#### ② 四段链路判定

| 段 | 环节 | 判据 |
|---|---|---|
| ① | 客户机 → dnsmasq:53 | 有 query 无 forwarded |
| ② | dnsmasq → dnsproxy | 有 forwarded 无 reply |
| ③ | dnsproxy → 上游 | `SERVFAIL` |
| ④ | 客户机 → 目标 IP | 需 tcpdump（二期） |

#### ③ 客户机识别用 IP + 主机名，不用 MAC

实测 `/tmp/dhcp.leases` 里三台移动设备的 MAC 全是本地管理位（随机 MAC）：

```
72:62:84:8a:f3:8c  ALN-AL80     ← 第2位 2 = 本地管理位
ae:fb:34:6e:fa:cd  iPhone       ← 第2位 e = 本地管理位
f6:d9:87:82:9b:dd  vivo-Y52s    ← 第2位 6 = 本地管理位
5c:e5:0c:b2:b1:ee  zhimi-air... ← 第2位 c = 全局唯一（真实）
```

**随机 MAC 恰恰证明 MAC 不能作设备身份。** 稳定的是 IP（租期内固定）
与主机名（设备自报，不受随机 MAC 影响）。实测主机名显示正确：
`PSDN-TC30-3BA9` / `ALN-AL80` / `vivo-Y52s`。

#### ④ 分级自愈 L1 → L4

| 级 | 动作 | 中断 | 自动 |
|---|---|---|---|
| L1 | `dnschain-selftest flush`（SIGHUP） | 零 | ✅ |
| L2 | `dnschain-selftest apply` | 零～极短 | ✅ |
| L3 | 重启 dnsmasq | 实测 3 秒 | ✅ |
| L4 | 改域名归属（写自动列表） | 零 | ✅ |

**时间窗**：自动自愈默认每小时最多 1 次（可配）；**手动触发不受限**
—— 用户明知可以断网才会点。限频是必须的：故障持续时不限频会反复
重启 dnsmasq，每次让**所有客户机**断 3 秒，而问题可能根本不在 dnsmasq。

#### ⑤ 自动列表分区隔离（L4 不碰手写列表）

| 列表 | 谁写 | 优先级 |
|---|---|---|
| `dom_domestic` / `dom_foreign` | **用户手工** | **高**（永不被自动改写） |
| `dom_auto_domestic` / `dom_auto_foreign` | 系统自动 | 低（手写同域名时让位） |

v0.22.0 删掉自动改道的教训就是**自动动作静默覆盖正确配置**
（`watch.servers` 与 `split.conf` 冲突，`www.wikipedia.org` 拿到
Facebook 的 IP）。故 L4 只处理 `CLASS=uncovered` 的域名，
且每次自动调整都记审计、可逐条撤销。

#### ⑥ 页面：两层结构，放状态 tab

```
上层 客户机列表      192.168.3.203 · ALN-AL80   失败 3 条   [诊断]
下层 失败时间线      16:02:11  makerworld.bblmw.cn  ③ 上游失败
```

新增 section「客户机链路诊断」，排在「DNS 分流去向」之后。
已登记进 `SECTION_TAB`（漏了会在所有 tab 都显示 —— v0.22.0 踩过）。

### 修复 — 施工中发现并修掉的五个真实缺陷

#### (a) v0.22.0 遗留：init 在启动已删除的 `dnschain-health`

`start_health_daemon()` 仍执行 `procd_set_param command
/usr/bin/dnschain-health daemon`，而该脚本 v0.22.0 已删除。
实测 procd 里有 2 条 health 实例记录、`/usr/bin/dnschain-health` 不存在
—— 每次开机都在尝试启动一个不存在的程序。

改为启动新的客户机诊断守护（承担同样的后台周期任务角色）。

#### (b) CNAME 链终态丢失 → 正常域名被判失败并误自愈

一个查询 ID 会有**多条** reply（CNAME 每跳一行），最后一行才是终态。
实测 `hs.p2p.huya.com`（query[HTTPS]）：

```
221459 ... reply hs.p2p.huya.com is <CNAME>
221459 ... reply huya-p2p.jx.volclivedvs.com is <CNAME>
221459 ... reply sched-l1-dk.tx.volclivedvs.com is NODATA   ← 终态，正常
```

旧实现只认第一条 reply，把 3 个能正常解析的域名判成失败，
还对其中一个**误执行了 L1 自愈**。

#### (c) `cached` 动作未处理

`cached` 是命中缓存直接回复，占日志第二多（182 条 vs reply 439 条）。
旧实现只认 `reply`，所有缓存命中的查询 state 为空 → 判成 `noreply`。
实测 28 条「失败」里绝大多数是这条引起的。

#### (d) 行尾 CR 导致字符串比较失配

`f[6]` 变成 `"SERVFAIL\r"`，与 `"SERVFAIL"` 不相等 →
**失败被静默判成 ok**，诊断功能等于失效。加 `sub(/\r$/, "")`。

#### (e) 快照窗口截断 → 每轮把正常域名记成故障

这是**最严重**的一个。daemon 原用 `logread | tail -n 2000` 快照，
而一条查询跨 20+ 行（CNAME 链 + nftset 穿插）。窗口边界切在中间时：

- `www.apple.com` 一条查询 20+ 行、10 条真实 A 记录，窗口切中间 → 判 noreply
- `api.deepseek.com` 4 条真实 A 记录落在窗口外 → 判 noreply

后果：连扫 3 轮记录数 **7 → 38 → 78** 持续膨胀，并对
`copilot.tencent.com` 误执行了 L1 自愈。

**修法**：daemon 改为 `logread -f` 持续跟随 + 流式解析
（`_diag_stream`），每个查询的完整生命周期都在流里，不再有边界问题。
实测 40 秒真实流量：**失败记录 0 条、自愈记录空**。

### 补齐 — 实时查询链路与可配置项（用户反馈缺功能）

首版只做了「失败时间线」，漏了用户明确要的两件事。已补齐：

#### ① 实时查询链路（含成功查询）

首版 `_diag_is_fail "$st" || continue` 只记失败，**成功查询全丢**，
回答不了「这台设备刚才查了什么、走的哪条链」。

现在分两张表：

| 表 | 内容 | 用途 |
|---|---|---|
| `client-flow.log` | **全部查询**（含成功） | 「这台设备在干什么」 |
| `client-fail.log` | 只有真失败 | 自愈阈值判定 |

页面新增「实时查询链路」表格：时刻 / 客户机 / 域名 / 结果 / 链路 / 答案。
实测 200 行，能看到真实流量（`makerworld.bblmw.cn` → `124.227.185.33` 等）。

客户机列表也加了「查询数」列（实测 230 / 49 / 36 / 10 / 9 / 3）。

#### ② 可自定义时间与条目数量

首版这九个键只有 `dc_get` 读取，**页面无任何输入框** —— 用户改不了。

现在全部暴露成输入框：启用诊断 / 启用自动自愈 / 扫描间隔 / 失败阈值 /
失败判定窗口 / **查询流水保留秒数** / **查询流水条目上限** /
失败记录保留秒数 / 失败记录条目上限 / 自动自愈最小间隔。

按用户要求「默认 1 小时」：失败记录默认 3600 秒；查询流水量大，默认 600 秒。

#### ③ 施工中发现的两个真实缺陷

**(a) `list` 在失败表为空时整体返回** —— 只判 `DIAG_FAIL_LOG` 存在与否，
于是没有任何失败记录的客户机**在列表里完全不出现**，用户以为「这台设备
没上网」。改为失败表与流水表任一存在即继续。

**(b) `flow` 参数解析错位** —— Lua 侧 IP 为空时拼出 `flow 200`，
而脚本把 `200` 当 IP 用 → 零输出 → 页面一直空白。改为按「纯数字即条数」
兼容两种形态。

**(c) 文件权限 0600 导致 LuCI 读不到** —— `mktemp` 建的文件是 `0600`，
而 rpcd 以受限身份读，页面显示「保留期内还没有查询流水」而数据其实在。
改为 trim 后与首次创建时都 `chmod 644`。

### 补齐 — 两级结构与搜索（用户第二轮反馈）

用户要求「第一级是当前在线主机，选定点击主机后转到第二级，按选中的
主机实时刷新整个链路状态，要详细，从哪来去哪里，打开主域名后跳转到
哪里，到哪一步出问题，刷新率可自定义时间+手动刷新；还需要带搜索框
功能按域名和关键词搜索」。全部落地：

#### ① 两级结构

```
第一级  在线主机列表（26 台）
  状态  IP             主机名                 查询数  失败数  最近活动   最近域名        操作
  在线  192.168.3.203  ALN-AL80                49      0     17:22    makerworld...  [查看链路]

第二级  单机链路（点「查看链路」进入，URL 带 ?dc_host=）
  时刻      查什么（点开看链路）        结果      到哪里去  答案
  17:25:19  harness.deepseek.com       无此类型   直连      NODATA-IPv6
  17:25:19  harness.deepseek.com       成功       直连      116.205.40.114

  域名链路详情（点域名进入，URL 带 ?dc_dom=）
  ✅ 全链路正常，未发现失败
  从哪里来：客户机 192.168.3.238
  第一跳：本机 dnsmasq  dnsmasq:53（唯一缓存与分流层）
  第二跳：上游实例      127.0.0.1#5353 ×20
  最终答案              113.105.155.193
  归属判定              uncovered → domestic
  查询 34 次 · 成功 13 次 · 首次 17:12:42 · 最近 17:22:17
```

**在线主机取自 ARP 邻居表**（`ip neigh show` 的 REACHABLE/STALE/DELAY），
不是只靠历史记录 —— 否则已下线设备也会列为在线。

#### ② 搜索框（按域名关键词）

新增 `search` 子命令 + 页面输入框。不区分大小写子串匹配，
可叠加当前选中的主机收窄。回车改为带 `dc_q` 参数的 GET（不是 POST，
否则会触发保存配置）。

#### ③ 刷新保留上下文

自动/手动刷新都带当前 URL 参数。实测踩过：不带 `location.search` 时
每次刷新都跳回第一级，用户正在看的第二级详情被踢掉。

#### ④ 新增三个脚本子命令

| 命令 | 作用 |
|---|---|
| `hosts` | 在线主机（ARP + 查询/失败统计） |
| `trace <IP> <域名>` | 单域名完整链路（含归属判定） |
| `search <关键词> [IP] [N]` | 按域名搜索 |

### 修复 — 在线主机表排除离线设备

用户要求「表中排除掉离线设备」。`hosts` 原先把「保留期内有查询记录」
的主机也列出（标 offline），现已过滤。

判据是 **ARP 邻居表**（`ip neigh show` 的 REACHABLE/STALE/DELAY/PROBE），
不用「最近活动时间」——DHCP 租约 12 小时，设备关机后查询记录还会留很久，
按时间判会把关机设备列成在线。

实测：26 台 → **20 台**（过滤 6 台离线），`online` 字段全为 1。

### 调查 — `cc.sefan.pw` 白屏（未复现，非本框架缺陷）

用户报告「主域名通了 CDN 不加载，白屏无法自愈」，示例域名
`cc.sefan.pw`，客户机 `192.168.3.238`。

#### 页面结构

抓包分析后确认该站的结构：

```html
<!-- 主域名只是个壳，正文 .change 是 display:none -->
<div class="change">...</div>
<!-- 唯一可见内容在这个 iframe 里 -->
<iframe src="https://cdn.sofan.one:65533/?host=cc.sefan.pw&v=1">
```

iframe 地址写在混淆代码里：
`atob("aHR0cHM6Ly9jZG4uc29mYW4ub25lOjY1NTMz")` = `https://cdn.sofan.one:65533`

**所以「主域名通了但白屏」的机制成立**：主域名返回 200，但可见内容全在
`:65533` 的 iframe 里，iframe 加载不出来就是白屏。

#### 逐层实测结果

| 检查项 | 结果 |
|---|---|
| `cc.sefan.pw` DNS（经路由器 / 公共 DNS） | 一致，`173.242.115.69` |
| `cdn.sofan.one` DNS | 一致，`103.20.60.49` |
| TCP 443 / 65533 | **通** |
| 从路由器 `openssl s_client` | **TLS 握手成功**，证书链验证通过 |
| 从客户机 curl（默认 UA） | 超时 |
| 从客户机 curl（**Chrome UA**） | **200** |
| 从客户机 curl（Chrome UA + **Referer**） | **200，0.15 秒** |
| 从客户机 curl（完整浏览器头） | **200，0.14 秒** |
| 真实浏览器（Playwright）加载 | iframe 主文档 + 3 个静态资源**全部 200** |

**结论：从 `192.168.3.238` 访问该站网络层完全正常。** 未复现白屏。

#### 已排除的假设

| 假设 | 排除依据 |
|---|---|
| DNS 被污染 | 三个 DNS 源答案一致 |
| IP 被墙 | TCP 通、ping 通（176ms）、路由器 TLS 成功 |
| 端口 65533 不在代理列表 | 确实是（列表只有 `22,80,143,443,465,587,853,993,995,9418`），但加上后**反而更差**：客户机从「超时 25 秒」变成「TLS 立即失败 0.9 秒」，且路由器本机原本能通也变成不通。已完整回滚 |
| UA 过滤 | 默认 UA 超时、Chrome UA 200 —— 但这只影响 curl，浏览器本来发 Chrome UA |
| Referer 必需 | 无 Referer 超时、有 Referer 200 —— 但浏览器发 iframe 请求本来带 Referer |

#### 顺带修复的探测能力

新增两个子命令（供日后排查同类问题）：

| 命令 | 作用 |
|---|---|
| `probe <域名> [端口] [超时]` | 探测「DNS 通但 TCP 不通」（ADR-0009 第 ④ 段） |
| `cdncheck [IP] [N]` | 扫描最近访问的域名，找出 TCP 不通的 |

⚠️ **探测方式经过实测筛选**，三种「看起来能用」的都不行：

| 写法 | 结果 |
|---|---|
| `nc -z -w N <ip> <port>` | 本机 BusyBox `nc` 只支持 `nc [IPADDR PORT]`，传 `-z/-w` 直接报 Usage 返回 1 → **所有域名被误判 timeout**（`cc.sefan.pw` 明明 200 却报 timeout） |
| `/dev/tcp/<ip>/<port>` | ash 未编译该特性 |
| `wget --spider` | 需要 Host/SNI，裸 IP 探测失败 rc=4 |
| **`timeout N sh -c "nc <ip> <port> </dev/null"`** | **唯一可靠** |

#### 未解决

**「为什么用户会看到白屏」尚未定位。** 从这台机器测不出问题，
可能原因（均未验证）：用户看到的是特定时段/特定设备的现象、
该站自身的服务端限流、或浏览器缓存了失败的 iframe。

下一步需要用户提供：白屏发生时的**具体时间**与**设备**，以便回查
当时的 `client-flow.log`（保留 10 分钟，需及时取）。

### 修复 — 出站兜底改为直连（系统性问题，非单一域名）

用户指出「只要从整个路由器出口就是访问不到」「不是单一域名的问题，
还有其他网页也会有这种现象」「不要治标不治本」。

上一版给 `47.239.0.0/16` 加 whitelist 只是**治标**。本版修根因。

#### 根因

SSR-Plus 的 `ss_spec_wan_ac` 链最后一条是**无条件** `jump ss_spec_wan_fw`
（= 走代理），含义是「**不在 `china` / `whitelist` 集合里的 IP 一律走代理**」。

而 `china` 集合只有 **4316 条**（SSR-Plus 精简版），覆盖严重不全：

| 网段 | 是否在 china_ssr.txt |
|---|---|
| `47.239.0.0/16` | **不在** |
| `123.57.0.0/16` | **不在** |
| `116.62.0.0/16` | **不在** |
| `118.31.0.0/16` | **不在** |
| `36.152.0.0/13` | **不在** |
| `223.5.0.0/16`（阿里 DNS） | **不在** |

实测 `47.239.100.208`：
- ping **22ms**、traceroute 走 **202.97.x.x（中国电信骨干）** → 确实在国内
- 但**连 APNIC 官方 8797 条数据都不收录**（该段未在 APNIC 注册）
- 所以任何 chnroute 都会漏掉它

后果：漏判的国内 IP 被送去**海外节点**，国内 CDN 拒绝海外访问：

```
经代理访问该 IP：0.3 秒即断（TLS 被关闭）
直连访问该 IP：  200
```

**这解释了「其他网页也有这种现象」** —— 任何 CDN 回源到未收录国内 IP
的站点都会白屏，不是单个域名的问题。

#### 修复

把兜底规则从「走代理」改为「走直连」：

```nft
# 改前（最后一条）
jump ss_spec_wan_fw                      # 不在 china → 走代理

# 改后
return comment "_DC_DIRECT_DEFAULT_"     # 不在 china → 直连
```

分流依据改为「**只有 `blacklist` 才走代理**」——`blacklist` 由 gfw 名单
（23771 条域名）的解析结果通过 nftset 填充，是「明确需要代理」的集合。

这符合 ADR-0009 的「直连优先」：国内能通就不要绕海外。

#### 验证（客户机侧，非路由器侧）

| 站点 | 结果 | 延迟 | 路径 |
|---|---|---|---|
| baidu | 200 | 0.34s | 直连 |
| taobao | 200 | 0.19s | 直连 |
| qq | 200 | 0.28s | 直连 |
| aliyun | 200 | 0.26s | 直连 |
| **cdn.staticsfile.org** | **200** | **0.36s** | **直连（修复前失败）** |
| google | 302 | 1.66s | 代理 |
| github | 200 | 4.60s | 代理 |
| youtube | 200 | 1.29s | 代理 |
| cloudflare | 200 | 1.57s | 代理 |

国内站延迟 0.2-0.4s（直连特征），国外站延迟 1.3-4.6s（代理特征）——
**分流行为正确，且没有破坏代理**。

`cc.sefan.pw` 浏览器截图 93031 字节，完整渲染。

#### 教训

**判断修没修好必须以「经路由器上网的客户机」为准，不能以路由器自身为准。**

我上一版用路由器的 `curl` / `openssl` 测通就以为修好了，而路由器走
OUTPUT 链、客户机走 PREROUTING 链，两者的出站判定可以不同。
用户明确指出这一点后才定位到根因。

### 修复 — 国内 IP 被误判走代理导致 CDN 加载失败（白屏，已治标）

用户报告「主域名通了 CDN 不加载，白屏无法自愈，**经该路由器的客户机
都白屏，手机移动网络正常**」。示例 `cc.sefan.pw`，客户机 `192.168.3.238`。

#### 根因

页面依赖 `cdn.staticsfile.org` 的 jQuery，该域名解析到
**`47.239.100.208`（阿里云上海）**。这个 IP **不在 SSR-Plus 的
`china` / `whitelist` 集合里**（集合里只有 `47.246.x.x`），
于是被判为国外 → 走 v2ray 代理 → **代理出站到国内阿里云失败**。

完整链条：

```
cdn.staticsfile.org → 47.239.100.208（阿里云上海，不在 china 集合）
  → 误判为国外 → redirect to :1234（v2ray）
  → 代理出站到国内失败 → TLS 被关闭（ERR_CONNECTION_CLOSED）
  → jQuery 加载失败
  → 页面 $(function(){...}) 不执行
  → iframe 的 src 永远不设置
  → 白屏
```

**这解释了「手机移动网络正常」**——移动网络不经这台路由器，
不会有这个误判。

#### 实测证据

| 检查 | 结果 |
|---|---|
| 客户机 conntrack | `192.168.3.238 → 47.239.100.208:443 → 192.168.3.254:1234`（进代理） |
| `china` 集合 | **不含** `47.239.x.x` |
| 走代理 curl | `ERR_CONNECTION_CLOSED` / TLS 握手失败 |
| 直连 curl | **200**，0.15 秒 |
| 加入 whitelist 后浏览器 | **3/3 正常**，截图 93031 字节 |

#### 修复

新增配置 `dnschain.main.direct_cidr`（可重复的 CIDR 列表），
收敛时自动写入 SSR-Plus 的 `whitelist` 集合（命中即直连）。

```sh
# files/etc/config/dnschain
config dnschain 'main'
    ...
    list direct_cidr '47.239.0.0/16'
```

`dc_apply_direct_cidr()` 在 `dnschain-reconcile` **末尾**调用。

#### 施工中踩的三个坑

**(a) `uci get` 读不到 `list` 类型** —— `uci -q get dnschain.main.direct_cidr`
对多值选项返回 rc=1，表现为「配置明明写了却读不到」。必须用
`uci show` 后按 key 前缀过滤。

**(b) 配置写错了 section** —— 我先把 `direct_cidr` 放在 `client_diag`
section 里（因为它跟在 `flow_retain_max` 后面），而代码读的是
`dnschain.main`。已移到 `main`。

**(c) 调用位置太早** —— 放在 reconcile 开头时，`whitelist` 集合
可能还不存在（由 SSR-Plus 创建），写入**静默失败**：函数返回 0、
uci 能读到配置，但集合里一条都没有。必须放在末尾。

#### 已排除的假设

排查过程中逐一排除了这些（都做过实测，不是推测）：

| 假设 | 排除依据 |
|---|---|
| DNS 污染 | 三个 DNS 源答案一致 |
| IP 被墙 | TCP 通、ping 176ms |
| 端口 65533 不在代理列表 | 确实是，但加上后客户机从「超时 25 秒」变成「TLS 立即失败」，路由器本机原本能通也变不通，已回滚 |
| flow offloading 破坏连接 | 关闭后仍白屏 |
| MTU 不匹配（1500 vs 1492） | 客户机改 1492 后仍白屏 |
| 服务器 h2 实现有缺陷 | Node 的 http2 模块 3/3 成功，114541 字节 |
| 浏览器缓存 | 全新 profile + 禁用缓存仍白屏 |
| 页面 JS 导致 | 禁用 JS 后仍白屏（因为 iframe 的 src 由 JS 设置，属预期） |
| Referer / UA 过滤 | curl 带 Chrome UA + Referer 稳定 200，10/10 成功 |

### 新增 — 解析回归测试 `tools/test-client-diag-parse.sh`

24 条断言，用**真实日志样本**覆盖上面 (b)(c)(d)(e) 四个缺陷，
外加「不算失败」的六类真值表（`nodata` / `nxdomain` / `ok` /
`refused` / `duplicate` / `pending` / `noquery` 均不算失败）。

⚠️ 这是纯本地工具，**CI 不跑** —— 必须自己跑。

### 验证

```
verify-dnschain-domains.sh   165 OK / 0 FAIL（新增 15 条契约断言）
check-dnschain-lua.py        111 PASS / 0 FAIL
render-dnschain-diagrams.py   54 PASS / 0 FAIL
extract-dnschain-i18n.py     357 条无缺失
verify-dnschain-ci-sim.sh    RC=0
test-client-diag-parse.sh    24 条全过
```

路由器实测（OpenWrt 24.10.5）：

```
dnschain-client-diag status     ENABLED=1 AUTOFIX=1 RETAIN_SEC=3600
dnschain-client-diag list       192.168.3.203|ALN-AL80|...
dnschain-client-diag scan       失败记录 0 条（无误报）
```

### 边界（必须明说）

**「DNS 正常但 App 仍打不开」一期不覆盖。** 实测拓竹设备的 DNS 与主链路
全部健康（`api.bambulab.cn` → `119.0.68.19`、`device-file.bambulab.cn`
→ 阿里云上海 `180.163.123.186`、MQTT `47.100.40.179:8883`），说明这类
问题的根因在更上层（证书 / 鉴权 / 区域限制 / 固件）。一期只能告诉用户
「DNS 层正常，问题在更上层」，二期抓包才补得上第 ④ 段。

---

## [v0.22.0] - 2026-10-25

### 重构 — 直连优先 + 自动回落；删除分诊与健康改道

用户要求：**「客户机的所有流量走直连，直连不通自动改走代理」**。

这个语义由 `dnsproxy` 的 `--fallback` 在上游层完成，**不需要**应用层的
探测、判定、落库。因此分诊（1710 行）与健康改道（448 行）整体删除。

#### ① `dnsproxy --fallback`：直连不通自动切代理

`dc_gen_dnsproxy_args()` 给国内实例（`:5353`）加：

```
--fallback 127.0.0.1:5336
```

效果：所有走 `:5353` 的域名，直连上游不可用时自动落到 `:5336`（DoH 经代理）。
零探测、零记录、零落库。

**⚠️ 地址格式必须用冒号 `127.0.0.1:5336`，不能用 dnsmasq 的 `127.0.0.1#5336`。**
实测写成 `#` 时 dnsproxy 直接拒绝启动：

```
ERROR configuring proxy: parsing fallback upstreams configuration:
  invalid address 127.0.0.1#5353: bad top-level domain name label
```

进程退出后端口无人监听、客户机全部无法解析，而页面只显示「dnsproxy 未监听」，
看不出是格式问题。

**实测验证**（路由器 2026-10-25）：起临时实例，主上游指向黑洞 `192.0.2.1`、
fallback 指向可用链，两个域名都解析成功 —— 证明 `--fallback` 在**超时**时
也触发（不只在 connection refused 时）。

**为什么与 v0.10.0 删掉 fallback 不矛盾**：那次删的是旧架构（`:5335` chinadns-ng）
的 fallback，它指向 `https://1.12.12.12/dns-query`（国内明文 DoH），gfw 域名
回落时拿到污染答案（实测 `youtube.com → 31.13.92.37`）。现在的 fallback 指向
`:5336`，是独立 dnsproxy 实例、上游是 DoH 经代理出站，不会污染。性质完全不同。

#### ② 删除分诊（`dnschain-triage`，1710 行）

它原本做「未覆盖域名 → 试直连 → 不通试代理 → 落库」。
有了 fallback，这套探测判定失去意义。

连带删除：`triage-*.list` 三个记录文件、`dc_triage_cycle`、`dc_triage_verdict`、
页面「分诊结果」section、`triage_map` 导图、三个开关（`triage_enabled` /
`triage_max` / `triage_conc`）、`dnschain-reconcile` 与 uci-defaults 里的重放逻辑。

#### ③ 删除健康探测与自动改道（`dnschain-health`，448 行）

**这不是「功能重复」，而是一个真实缺陷的源头。** 实测证据：

`watch.servers`（改道通道）与 `dnschain-split.conf`（静态分流）是**两套并存**
的 `server=` 源。同一个域名在两处都有规则时，dnsmasq 把它们当**候选**
（不是后者覆盖前者），取哪条不确定：

```
split.conf:    server=/wikipedia.org/127.0.0.1#5336      ← 正确（代理）
watch.servers: server=/www.wikipedia.org/127.0.0.1#5353  ← 改道遗留（直连）
```

结果 `www.wikipedia.org` 经 `:53` 返回 **`31.13.106.4`（Facebook 的 IP，污染值）**，
而两条 dnsproxy 链本身都返回正确的 `103.102.166.224`。
**也就是说改道功能会把正确的分流规则覆盖成错误的。**

删除后分流规则只有 `split.conf` 一处来源，冲突从根上消失。

连带删除：`dc_health_*` 十个函数、`dc_gen_watch_servers`、`update_serversfile`、
`--servers-file` 配置、页面「DNS 分流状态」与「观测与阈值」两个 section、
「清空改道状态」按钮。

**实测确认删除安全**：去掉 `serversfile` 后 dnsmasq 仍正常加载 `split.conf`
（前者走 `--servers-file`，后者走 `conf-dir=/tmp/dnsmasq.d`，两套独立机制）。
去掉后 `www.wikipedia.org` 解析为 `103.102.166.224`（正确）。

#### ④ 域名 TAB 重构

| 改前 | 改后 |
|---|---|
| 自定义域名 · 国内 | **国内直连**（多行输入，每行一个） |
| 自定义域名 · 国外 | **国外代理**（同上） |
| 已录入清单 | 保留（实时条数） |
| 分诊结果 | **删除** |
| DNS 分流状态（五档导图） | **改为两档**：走直连 / 走代理 |
| 观测与阈值 | **删除** |

「DNS 分流去向」图保留（用户明确要求），但语义从「健康状态」改为
**静态分流去向**：根 → 走直连 / 走代理 → 域名清单。数据来自
`custom-domestic.txt` / `custom-foreign.txt`，不依赖任何探测。

只画用户录入的域名，不画 gfw 名单里那 2.3 万条（画不下也无意义）。

#### ④b 「DNS 分流去向」图只保留在「状态」tab

改名为「DNS 分流去向」后**忘了把它登记进 `SECTION_TAB`**，结果这张图在
**4 个 tab 里全都渲染**。

根因在 `dnschain.js` 的 `activate()`：

```js
sections.forEach(function (sec) {
    /* 未归组的 section 始终显示 —— 避免新增 section 后莫名消失 */
    if (!sec.tab) { sec.el.hidden = false; return; }
    sec.el.hidden = (sec.tab !== id);
});
```

这段兜底本意是「新增 section 忘了登记时不要让它消失」，但代价是它**永远可见**。

实测（修复前，逐个 tab 点开并检查 SVG 的真实几何高度 + 祖先 `hidden`）：

| tab | 可见图 |
|---|---|
| 状态 | 链路拓扑图、DNS 分流去向导图 |
| 域名 | DNS 分流去向导图 ← 不该有 |
| 上游 | DNS 分流去向导图 ← 不该有 |
| 名单 | DNS 分流去向导图 ← 不该有 |

修法：在 `SECTION_TAB` 里加 `[translate("DNS 分流去向")] = "status"`。
同时清掉三个已删 section 的死键（`DNS 分流状态` / `分诊结果` / `观测与阈值`），
表从 18 键减到 16 键，与页面上 16 个 section 一一对应。

⚠️ **排查时的一个陷阱**：最初用
`[...document.querySelectorAll('svg[role="img"]')].filter(s => s.offsetParent !== null)`
判断可见性，结果**四个 tab 全都报「可见」** —— 因为 `SVGElement` 没有
`offsetParent` 属性，表达式恒为 `undefined !== null`（即 `true`）。
正确做法是用 `getBoundingClientRect().height > 0` 并手动回溯祖先的 `hidden`。

修复后实测：只有「状态」tab 有两张图，其余三个 tab 的 SVG 数为 0。

断言也补了一条：`SECTION_TAB` 里必须有这三个 section 的登记，
漏了会让断言直接报「未登记进 SECTION_TAB（会在所有 tab 都显示）」。

#### ⑤ `dnschain-selftest` 接管三个子命令

`dnschain-health` 删除后，它承载的 CLI 入口移入 `dnschain-selftest`
（该脚本本来就在 rpcd ACL 白名单里，不必新建脚本）：

| 子命令 | 用途 | 输出契约 |
|---|---|---|
| `flush` | 清空 dnsmasq 缓存（SIGHUP） | `OK=<pid>` / `ERROR=<原因>` |
| `explain <域名>` | 单域名解释 | `KEY=VALUE` 行 |
| `apply` | 应用自定义列表 | `OK=国内 N 条…` / `ERROR=…` |

Lua 侧 `M.flush_cache` / `M.explain` / `M.apply_domains` 相应改调这三个子命令；
`apply_message` 的解析从旧的 `DNSMASQ=restarted|sighup|…` 改为 `OK=` / `ERROR=`。

#### ⑥ 自检第 5/18/19 项判据更新

- **第 5 项**：从「不得出现 `--fallback`」改为「允许，但**必须**指向
  `127.0.0.1:<foreign_port>`」。这样既放行正确用法，又能拦住
  「fallback 指向外部明文上游」这个真实风险（那会拿到污染答案）。
- **第 18/19 项**：从「改道通道已就绪」改为「改道通道已清理」——
  防止从老版本升级上来时残留 `serversfile` 或 `watch.servers` 把链路搞坏。

#### ⑦ 修复删 watch.servers 引入的两个连带缺陷

这两个都是**删除动作本身引入的回归**，在路由器实测中发现，不修会静默丢域名。

**(a) 观测基准集导致 8 个域名没有分流规则**

`dc_watch_list()` 在用户没配 `health.watch` 时回落到 8 个基准域名
（`www.baidu.com` / `www.qq.com` / `github.com` / `www.google.com` /
`www.youtube.com` / `www.wikipedia.org` / `www.taobao.com` / `www.163.com`）。

这 8 个被 `dc_gen_dnsmasq_split` 用 `dc_exclude` 从 `split.conf` 剔掉 ——
原本的设计是「它们只在 `watch.servers` 里出现」。删除 `watch.servers` 后，
这个剔除动作变成**纯粹的数据丢失**：

```
$ nslookup github.com 127.0.0.1
;; connection timed out; no servers could be reached

$ nslookup api.github.com 127.0.0.1     # 不在观测列表，正常
Address: 140.82.114.5
```

`grep '^server=/github\.com/' split.conf` 为空 —— 它没有任何规则。
更隐蔽的是**自定义列表也救不回来**：剔除发生在「数据库 − 自定义国内 −
观测域名」之后，对自定义国外同样生效。

修法：`dc_watch_list()` 恒返回空，`DNSCHAIN_WATCH_SEED` 删除。
剔除 0 条，所有域名都能拿到规则。

**(b) 同一域名在 split.conf 里出现两次**

`github.com` 同时在 gfw 名单（数据库国外）与自定义国外列表里，
两段各写一条 → `split.conf` 出现两条相同的 `server=/github.com/#5336`。

dnsmasq 把两条相同的 `server=` 当**候选**（不是去重），与 ADR-0008 §3.1
描述的问题同源。修法：数据库国外那一段也排除自定义国外
（`dc_exclude "$DNSCHAIN_CUSTOM_FOR"`）。

实测修复后：`split.conf` 47496 行，`sort -u` 后仍 47496 行 —— **零重复**。

#### 验证

| 工具 | 结果 |
|---|---|
| `sh tools/verify-dnschain-domains.sh` | **148 OK / 0 FAIL**（断言从 166 重写为 148） |
| `python tools/check-dnschain-lua.py` | **PASS=108 FAIL=0**（从 144 降，删掉的都是分诊/改道断言） |
| `python tools/render-dnschain-diagrams.py --check` | **PASS=54 FAIL=0**（从 70 降，`triage_map` 用例删除） |
| `python tools/extract-dnschain-i18n.py` | 311 条无缺失（从 430 降 119 条，删掉的都是分诊/改道文案） |
| `sh tools/verify-dnschain-ci-sim.sh` | RC=0 |
| `dash -n` × 5 + `luac -p` × 4 | 全通过 |

**真实路由器验证（OpenWrt 24.10.5，`192.168.3.254`）**

```
$ dnschain-selftest flush
OK=7973
$ dnschain-selftest explain www.baidu.com
DOMAIN=www.baidu.com / CLASS=custom-foreign / PREFERRED=foreign / ACTIVE=foreign
$ dnschain-selftest apply
OK=国内 204 条、国外 31 条，分流 23970 条已生效
$ dnschain-selftest -f | grep SUMMARY
SUMMARY PASS=19 FAIL=0 SKIP=1
CONCLUSION: 链路正常
```

dnsproxy 进程参数确认含 `--fallback 127.0.0.1:5336`；
`dhcp.@dnsmasq[0].serversfile` 已清空；`/var/run/dnsmasq/watch.servers` 已删除。

**12 个域名端到端连通性**（路由器实测，清空自动写入列表后）：

| 域名 | 结果 | 链路 |
|---|---|---|
| www.baidu.com | 240e:ff:e020:98c:0:ff:b061:c306 | 直连 |
| www.qq.com | 183.60.118.213 | 直连 |
| www.taobao.com | 124.226.75.233 | 直连 |
| www.163.com | 171.109.97.35 | 直连 |
| github.com | 20.205.243.166 | 代理（自定义国外） |
| api.github.com | 140.82.114.5 | 代理（自定义国外） |
| www.google.com | 2001:4860:4826:7700:: | 代理（自定义国外） |
| www.youtube.com | 2001:4860:482b:400:: | 代理（自定义国外） |
| www.wikipedia.org | 2001:df2:e500:ed1a::1 | 直连（未录入） |
| www.reddit.com | 151.101.193.140 | 直连（未录入） |
| www.apple.com | 240e:950:400:3:3::18 | 直连（未录入） |
| www.bing.com | 23.215.7.17 | 直连（未录入） |

**污染消除确认**：`www.wikipedia.org` 从 `31.13.106.4`（Facebook IP，污染值）
变为 `2001:df2:e500:ed1a::1`（真实 IPv6）。

**分流片段完整性**：47496 行，`sort -u` 后仍 47496 行 —— **零重复**。

**浏览器视觉验证**：页面两张 SVG（链路拓扑图 + DNS 分流去向导图），
后者正确渲染两档（走直连 204 个 / 走代理 31 个），无「分诊」「观测与阈值」
「DNS 分流状态」残留，无运行时错误。

**删除量**：`dnschain-triage` 2048 行 + `dnschain-health` 448 行 + `dnschain.sh`
592 行 + `general.lua` 610 行 + `diagrams.lua` 164 行 + `dnschain.lua` 358 行
≈ **4200 行**。

**回滚**：`git checkout -- package/luci-app-dnschain/ files/ .github/ tools/`；
路由器侧回滚点 `/root/dnschain-refactor-20261025-021148`。


## [v0.21.0] - 2026-10-25

### 变更 — 自定义域名改为大输入框；分诊失败 3 次后停止记录与探测

#### ① 两个自定义域名列表改为多行文本框

用户要求：「改为一个大输入框，每一行一个域名即可」。

原先是 `DynamicList`：每加一个域名要点一次「+」再填一行。批量补 20 个域名
就是 20 次点击，而用户手头通常已有一份域名清单（记事本、网页、别人的配置），
整段粘进一个大框才是自然操作。

改为 `TextValue` 多行文本框（12 行），UCI 里**仍存成 list** ——
下游 `dc_gen_custom_lists` 读到的格式完全不变，后端零改动。

`write()` 的处理：

| 输入 | 行为 |
|---|---|
| 空行 | 忽略 |
| `#` 开头的行 | 忽略（允许整段粘带注释的清单） |
| 前后空格 | trim |
| 大写 | 转小写 |
| 行尾的点 | 去掉 |
| 重复行 | 去重（只留第一次出现） |
| 格式非法 | **跳过**并在页面上汇总提示 |

**为什么非法行是「跳过」而不是「让整页保存失败」**：
实测用户既有配置里本来就含 3 条 `_4483._https.*` 形式的 SRV 风格域名，
任何一次保存都会被它们挡住 —— 用户无法保存任何其它改动，比不校验更糟。
而且这些域名在后端 `dc_domain_valid_norm` 同样非法，从未进入 `split.conf`，
是死数据。改为跳过后，用户保存一次就顺手清理了它们（实测自检第 17 项
从 FAIL 变 PASS）。

#### ② 分诊失败 3 次后不再记录、不再探测

用户要求：「分诊超过三次失败的可以不再记录，从表格消失也不再探测，
直到下次客户机发起请求，这样可以避免长期重复失败监测浪费性能」。

在此之前，一个永远不通的目标（已下线的 CDN 边缘、拼错的域名、
客户机误查询的垃圾域名）会被**每一轮 cycle 反复探测**：dead 的目标要试
「直连超时 + 代理超时」两轮，按 `health.interval=60s` 算，一天 1440 轮
× 2 = 2880 次探测，而它永远不会通。

实现：

- 新增 `/etc/dnschain/triage-giveup.list`，格式 `目标|失败次数|最后失败时间`。
  **不扩展** `triage-ip.list` / `triage-domain.list` 的格式 —— 那两个文件被
  8 处 awk/read 按位置解析，加字段会让所有解析点错位。
- 只有 `dead` 算失败；`direct` / `proxy` / `known` 都把计数清零 ——
  这样「偶尔失败但多数成功」的目标不会被误踢。
- 达到 3 次后从主记录删除（表格里消失），后续 `run` 跳过它，
  并输出 `GIVEUP skipped=N（已达失败阈值，等客户机重新请求）`。
- **恢复条件**：`logread` 里该目标的 query 时间戳**晚于**最后失败时间。
  不能只看「出现在日志里」—— 日志缓冲只有 128KB（实测 919 行），
  一个反复被查询的失败域名会一直留在里面，那等于没有过滤。
- `clear` 命令同时清空计数文件（否则「清空了但还是不探测」更困惑）。

**踩到的 BusyBox 差异**：`date -d 'Sun Oct 25 01:28:26 2026'` 报
`invalid date`，必须用 `date -D '%a %b %d %H:%M:%S %Y' -d ...` 显式给输入格式。

**性能**：`logread` 一次约 30~60ms，若对每个目标各跑一次，12 个目标就是
0.5 秒 —— 而这段代码在每轮 cycle 里跑。改为一次抓取缓存到临时文件，
后续目标只 grep 本地缓存。

#### 验证

| 工具 | 结果 |
|---|---|
| `sh tools/verify-dnschain-domains.sh` | **166 OK / 0 FAIL**（新增 4 条断言） |
| `python tools/check-dnschain-lua.py` | **PASS=144 FAIL=0** |
| `python tools/render-dnschain-diagrams.py --check` | **PASS=70 FAIL=0** |
| `python tools/extract-dnschain-i18n.py` | 430 条无缺失 |
| `sh tools/verify-dnschain-ci-sim.sh` | RC=0 |
| `dash -n` × 5 脚本 + `luac -p` × 4 文件 | 全通过 |

**新增断言（4 条）**：两个多行输入框存在；write 里逐行校验；
write 后显式 commit；write 返回真值。

**真实路由器验证（OpenWrt 24.10.5，`192.168.3.254`）**

分诊放弃逻辑的单元与端到端测试（用必然失败的 `192.0.2.199`）：

| 轮次 | 计数 | 主记录 | 行为 |
|---|---|---|---|
| 1 | 1 | 1 | 记录 dead |
| 2 | 2 | 1 | 记录 dead |
| 3 | **3** | **0** | 从记录中删除 |
| 4 | 3 | 0 | `GIVEUP skipped=1`，不探测 |

`should_retry` 四个场景全部正确（日志请求早于/晚于最后失败、
日志里无该目标、无失败记录）。

大输入框保存链路（真实浏览器）：

| 输入 | 结果 |
|---|---|
| `FINALPROBE.COM` | → `finalprobe.com`（小写） |
| `FINALPROBE.COM` + `finalprobe.com` | → 只 1 条（去重） |
| `  trimmed.example.org  ` | → `trimmed.example.org`（trim） |
| `# comment` | 计数 0（注释过滤） |
| `_bad._x.test` | 计数 0（非法跳过 + 页面提示） |

页面提示原文：「已跳过 1 个格式非法的域名（后端同样不接受，不会生效）：7: _bad._x.test」

自检 **19 PASS / 0 FAIL / 1 SKIP**，`CONCLUSION: 链路正常`。
第 17 项「自定义域名列表合法」从 FAIL 变 **PASS**（保存时清掉了 3 条死数据）。

**⚠️ 本版踩到并记录的一个 LuCI 陷阱**：
`TextValue` 的 `write` 里只调 `map:set()` 时，值停在 uci 的 staging 区，
依赖 `Map.parse` 之后统一 `uci:save` 落盘。但本 Map 覆写了 `apply_on_parse`，
实测那条链**没有生效** —— 页面回显正确（值进了内存）、`uci changes` 为空、
`/etc/config/dnschain` 内容不变，请求结束值就丢了。
修法是在 `write` 里显式 `uci:save` + `uci:commit`，并且**必须 `return true`**
（LuCI 的 `parse` 用 `if self:write(...) then section.changed = true end`，
不返回真值就一个字节都不写）。

**回滚**：`git checkout -- package/luci-app-dnschain/ files/usr/bin/dnschain-triage`


## [v0.20.0] - 2026-10-25

### 变更 — 全链路规整为「DNS 分流插件」：tab 6→4、section 20→18、按钮 8→3、删除 7 个假开关

用户要求：「把 luci-app-dnschain 全部功能梳理一遍，规整为 DNS 分流插件，
前后端全链路梳理，把当前凌乱的功能全部标准化简化交互，减轻用户交互压力
减少繁琐操作，尽量自动化，减少阅读压力」。

#### 规整依据：DNS 分流只有三个动作，且都已自动化

| 动作 | 谁在做 | 用户要管吗 |
|---|---|---|
| **判定**：域名该走哪条链 | 分诊实测 + 归属库 + 健康改道 | 不用管 |
| **落地**：写成 dnsmasq 规则 | `dc_gen_dnsmasq_split` + `watch.servers` | 不用管 |
| **生效**：让 dnsmasq 读到 | `apply_on_parse`（保存即生效） | 不用管 |

所以页面只需提供两件事：**① 现在什么状态 ② 我认为该走哪条链的域名**。

#### tab 6 → 4

| 新 tab | 职责 | 由哪些旧 tab 合并 |
|---|---|---|
| **状态** | 现在通不通、分流到哪了 | 概览与诊断 |
| **域名** | 哪些域名我指定了走哪条 | 域名 |
| **上游** | 往哪儿问、怎么问 | 解析 + 代理 + DHCP |
| **名单** | 规则库从哪来、多大、怎么体检 | 分流 + 观测阈值 + 自检 |

⚠️ 改 tab 必须同步三处：`SECTION_TAB`（Lua）、`TAB_LABELS`（Lua）、
`TAB_ORDER`（JS，`dnschain.js:46`）。漏改 JS 会导致 tab 不显示或顺序错乱。

#### section 20 → 18

| 删除 | 理由 |
|---|---|
| **判定链路** | 规则图与「分流去向图」语义重叠（一张讲规则、一张讲事实）。规则内容保留在 `docs/runtime/dns-chain.md`。其中「单域名解释」保留，并入「域名」tab |
| **域名操作** | 唯一按钮与页底「保存并应用」调同一个 `ds.apply_domains()`，完全重复 |

#### 按钮 8 → 3

| 保留 | 位置 | 理由 |
|---|---|---|
| 立即重新自检 | 状态/操作 | **唯一需要用户主动触发的**（绕过 10 秒缓存强制真跑） |
| 清空改道状态 | 状态/DNS 分流状态 | 排障动作，就地可用 |
| 清空全部缓存 | 上游/缓存 | 属缓存配置，低频 |

删除的 5 个及去向：「重建分流规则并生效」→ 与「保存并应用」重复；
「一键归一」→ 守护自动；「立即分诊未知目标」→ 随 `dc_health_cycle` 自动；
「更新 GFW 名单」→ SSR-Plus 自身定时 + `auto_import`；
「立即探测一轮」→ 守护按 `health.interval` 自动。

#### 删除 7 个「假开关」

共同问题：**可以改，但后端完全不读，改了没有任何效果**。

| 开关 | 页面自述（删除前） |
|---|---|
| 尽力阻断公共 DoH | 「只做标注，不实际拦截」 |
| 校验上游证书 | 「未接入 dnsproxy 的启动参数」 |
| 经代理出站 | 「实际出站由 SSR-Plus 决定」 |
| 抑制 HTTPS/SVCB | 「没有运行时消费者」 |
| 启用缓存 | 「实际始终启用，框架不读这个开关」 |
| 失败自动回滚 | 「回滚逻辑尚未实现」 |
| 定时自检间隔 | 「仓库里没有定时调度」 |

**判据是「后端有没有真的读它」，不是「名字听起来像自动」。**
按此判据，`lists.auto_import` **保留** —— 见下。

#### 新增 — 自动化：health 守护内跑 reconcile

用户要求「尽量自动化」。在此之前 `dnschain-reconcile` **没有任何调度器**：
全仓库无 cron、无 procd 实例、无开机钩子，唯一调用点是页面的「一键归一」按钮。
于是 SSR-Plus 更新名单后，框架的域名文件仍是旧的，直到用户想起来去点按钮 ——
而 `lists.auto_import`（默认 1）与 `import_interval`（默认 60 秒）
这两个配置项的存在，说明设计意图本来就是「自动导入」，只是没有东西驱动它。

`dnschain-health:cmd_daemon` 现在每轮探测后顺带调一次 reconcile。
`reconcile_lists` 内部先比名单指纹，未变则零动作（不会反复重启 dnsmasq）。

**边界处理**：原实现 `interval=0` 时守护直接 `return 0` 退出，
会连带把名单自动收敛也关掉。现改为：`interval=0` 时不进探测循环，
但仍按 300 秒固定间隔做名单收敛 —— 用户关的只是探测，不该让名单永不更新。

#### 修复 — 自检第 2 项永久误报（真实缺陷，非本版引入）

`dnschain-split.conf` 里有 26 条指向 `#5353` 的规则，都是**自定义国内域名**
（`www.qq.com`、`api.bilibili.com`、`amdc.alipay.com` 等）。
`dc_gen_dnsmasq_split`（`dnschain.sh:1346`）**故意**把它们写成 `#${eport}` ——
自定义国内域名就该走国内链，这是分流功能本身。

但自检 `_scan_item2` 只认 `#${fport}`（5336），把 26 条**正确规则**报成
「出现未预期端口: 5336 5353（应为 5336）」，导致页面链路拓扑图的
「分流规则」阶段**永久显示红色 FAIL**。

**这比不检查更糟**：用户看到常驻红点会以为分流坏了，实际完全正常 ——
一个假的警报会训练用户忽略所有警报。

修法：判据允许 `fport` 与 `eport` 两种，只报其它端口；
`bad_ports` 列表也同步滤掉两个合法端口（原实现连自己要求的 5336 都列进去了，自相矛盾）。

#### 修复 — 观测域名与静态片段重复（真实缺陷，导致改道静默失效）

`dnschain-split.conf` 的文件头注释写着「观测域名不在此文件：它们由
`watch.servers` 动态决定，同一域名只能有一处 `server=` 声明，
否则 dnsmasq 会当成候选随机选」—— 但自定义域名段**没有排除观测域名**，
违反了这条自己的规则。

实测：8 个观测域名里 6 个同时出现在两处
（`www.qq.com`、`www.163.com`、`www.baidu.com`、`www.google.com`、
`www.wikipedia.org`、`www.youtube.com`）。

两条 `server=` 都在时 dnsmasq 把它们当**候选**（不是后者覆盖），
改道切链后就变成「随机走一条」—— **改道功能静默失效**。

修法：自定义国外/国内两段都加上 `dc_exclude "$watch_f"`。

#### 验证

| 工具 | 结果 |
|---|---|
| `sh tools/verify-dnschain-domains.sh` | **164 OK / 0 FAIL** |
| `python tools/check-dnschain-lua.py` | **PASS=144 FAIL=0** |
| `python tools/render-dnschain-diagrams.py --check` | **PASS=70 FAIL=0** |
| `python tools/extract-dnschain-i18n.py` | 428 条无缺失（比上版少 = 删假开关文案的净减少） |
| `sh tools/verify-dnschain-ci-sim.sh` | RC=0 |
| `dash -n` × 4 脚本 + `luac -p` × 4 文件 + `node --check` | 全通过 |

**新增断言（5 条）**：18 个 section 都有 `m:section` 声明；
旧 section「判定链路」「域名操作」不得再出现；
4 个新 tab id 在 Lua 与 JS 都存在；旧 tab id 不得残留；
分流明细全绿时折叠。

**真实路由器验证（OpenWrt 24.10.5，`192.168.3.254`）**

| 项 | 结果 |
|---|---|
| 热渲染 | **1.38–1.39 s**（冷启动 6.40 s，重启后首次） |
| Lua 错误 | **0** |
| section 数 | **18** |
| tab | **4**（状态 / 域名 / 上游 / 名单） |
| 按钮 | **3**（+ CBI 原生 Save） |
| 假开关残留 | 0 |
| **自检** | **PASS=20 FAIL=0**，`CONCLUSION: 链路正常` |
| 观测域名重复 | **0**（修前 6） |

**真实浏览器视觉验证（Chrome + luci-theme-shadcn）**：
链路拓扑图 8 个阶段**全部绿色**（修前「分流规则」是红色 FAIL）；
断点诊断「20 项自检全部通过，没有断点需要诊断」+ 时间戳；
4 个 tab 正常切换，18 个 section 全部归组。

**回滚**：`git checkout -- package/luci-app-dnschain/ files/usr/bin/dnschain-{health,selftest} files/usr/share/dnschain/dnschain.sh`


## [v0.19.0] - 2026-10-24

### 变更 — 「改道状态」+「改道明细」合并为「DNS 分流状态」

用户提出：「我想把『改道状态』+『改道明细』合并到一个 DNS 分流状态导图，
其实改道就是 DNS 分流」。

**这个判断在代码里成立。** `dc_health_cycle` 每轮做的事就是**决定某个域名
走哪条链**，而 `watch.servers` 里 `active` 字段最终写成的就是
`server=/域名/127.0.0.1#<port>` —— 那正是 DNS 分流本身。
「改道」只是「分流结果发生变化」这一事件的旧叫法，**不是独立能力**。

#### 合并前的冗余

| section | 内容 |
|---|---|
| 改道状态 | 一张导图 + 「改道通道」+「自动改道进程」两行 |
| 改道明细 | 一张 7 列表 |

两块讲同一件事（这 8 个域名现在走哪条链、为什么），却要滚两次屏。
而且导图里已按状态分组列出域名，明细表又把同一批域名再列一遍，
只多了「连败 / 最近探测 / 原因」。

#### 合并后的结构（一块讲完整件事）

| 位置 | 内容 | 回答什么 |
|---|---|---|
| 分流去向 | 导图 | 哪些域名走直连、哪些走代理、哪些偏了 |
| 自动改道 | 一行（原两行压缩） | 通道就绪吗、守护在跑吗 |
| 分流明细 | 折叠表 | 连败次数、最近探测、原因 |

#### 两处细节

**① 导图五档改名**（内部 id 不变 —— 它们是与 `dnschain-health`
状态文件的契约，改名会破坏运行时）：

| 旧标题 | 新标题 |
|---|---|
| 正常 | 走首选链 |
| 降级中 | 首选链不稳 |
| 已改道 | 已切另一链 |
| 双链故障 | 双链故障（保留） |
| 未探测 | 未探测（保留） |

改的是**视角**：说「去向」而不是「评价」。
aria-label 同步改为「DNS 分流去向导图」。

**② 明细表全绿时默认折叠**：8 个观测域名绝大多数时候全正常，
全绿表信息密度极低却占满首屏。有 `degraded`/`rerouted`/`both-bad`
时自动展开并显示完整表格。
「未探测」**不计入异常** —— 它只是还没跑过，不是故障。

#### ⚠️ 没有删「通道就绪」与「守护运行」

它们是**故障前置条件**，不是冗余显示：

- 通道未就绪 → 改道写了文件但 dnsmasq 读不到 → **静默失效**
- 守护未运行 → 开关显示已启用但完全不改道 → **静默失效**

两者都是「看起来正常、实际没生效」，是排查这类问题的唯一可靠判据。
合并时把两行压成一行（它们共同回答「自动改道此刻真的在工作吗」），
但**一条判据都没丢**。

#### 验证

| 工具 | 结果 |
|---|---|
| `sh tools/verify-dnschain-domains.sh` | **162 OK / 0 FAIL**（新增 4 条合并断言） |
| `python tools/check-dnschain-lua.py` | **PASS=155 FAIL=0** |
| `python tools/render-dnschain-diagrams.py --check` | **PASS=70 FAIL=0** |
| `python tools/extract-dnschain-i18n.py` | 461 条无缺失 |
| `sh tools/verify-dnschain-ci-sim.sh` | RC=0 |
| `luac -p` × 4 文件 | 全通过 |

**新增断言（4 条）**：
1. `SECTION_TAB` 的 20 个 section 都有 `m:section` 声明
2. 旧 section「改道状态」已合并（不得再作为 `m:section` 出现）
3. 旧 section「改道明细」已合并
4. 分流明细全绿时折叠并给摘要

**真实路由器验证（OpenWrt 24.10.5，`192.168.3.254`）**：
渲染 3.91 s / 342 KB，Lua 错误 **0**；
`>改道状态<` 0、`>改道明细<` 0、`改道状态思维导图` 0、`自动改道进程` 0；
section 数从 21 降到 **20**。

**真实浏览器视觉验证（Chrome + luci-theme-shadcn）**：
「DNS 分流状态」一块讲完 —— 分流去向导图（8 个域名全在「走首选链」档，
双链故障 0 个）、自动改道一行（通道就绪 · 守护运行中 pid 21520 ·
每 60 秒一轮 · 上次探测 21 秒前）、分流明细折叠为
「8 个观测域名，全部分流正常」。

**回滚**：`git checkout -- package/luci-app-dnschain/luasrc/model/cbi/dnschain/{general,diagrams}.lua`


## [v0.17.0] - 2026-10-24

### CI：定时预热 dl 镜像与交叉工具链，消除每次构建的重复下载

用户要求：「解决每次提交编译都要重新下载 dl 包和工具链」。

#### 改前

每次 push 都从零开始：`make download` 抓上千个上游 tarball，再完整编译
交叉工具链与 40 多个宿主工具。两条路径都可能极慢或直接失败。

实测证据（run `39495602665`，2026-10-21）：`make download` 卡了 **5h54m**，
日志尾部是 `nasm-2.16.03.tar.gz` 从 `www.nasm.us` 以 **556 B/s** 下载，
直到 job 的 6h 上限被取消。同一轮构建没有任何产物。

#### 改后

新增 `.github/workflows/cache-deps.yml`，把两件昂贵工作搬到 GitHub 内部网络上
做成可复用资产，供 `build-openwrt.yml` 直接取用：

| 资产 | 内容 | 命中时省下 |
|---|---|---|
| `dl` | `dl/` 全部源码包，分片存放 | 15-25 分钟下载，并消除慢源卡死风险 |
| `toolchain-<FP>` | `staging_dir/toolchain-*` + `build_dir/toolchain-*` | 约 30-45 分钟交叉工具链编译 |
| `host-<FP>` | `staging_dir/host`、`hostpkg`、`build_dir/host` | 约 40 多个宿主工具编译 |

存放位置是 tag `cache-build-v1` 的 Release（`env.CACHE_TAG`）。**不是发版**：
标记为 prerelease，标题写明「这不是发版」，删除它只会让下一次构建变慢。

#### 为什么用 Release 资产而不是 `actions/cache`

| 维度 | `actions/cache` | Release 资产 |
|---|---|---|
| 单仓库总量 | 10 GB，超出按最后访问时间淘汰 | 无总量上限 |
| 过期 | **一周未被访问即删除** | 只有手动删除 |
| 单文件大小 | 需先打成单个 tar | 2 GB（故分片 1900 MB） |
| 下载路径 | GitHub 缓存服务 | GitHub CDN，流量不出 GitHub |

`dl/` 是 GB 级，且构建不是每天都跑 —— 放 `actions/cache` 既装不下、
又会被「一周未访问」淘汰，缓存永远命中不了。

#### 工具链指纹用内容哈希，不用 git commit

`tools/lede-fingerprint.sh` 输出 `TOOLCHAIN_FP` / `HOST_FP`，覆盖
`toolchain/`、`target/linux/generic/`、`tools/`、相关 `include/*.mk` 的
**文件内容**，加 `.config` 里编译器/libc/binutils/架构相关的符号切片。

- 用 commit 做键会失效：lede master 每天都有提交，缓存几乎永不命中。
- 用 `git log -1 -- <path>` 更危险：`actions/checkout` 默认浅克隆，
  HEAD 未触及该路径时返回**空**，于是「空 == 空」把所有版本都判成命中
  —— 静默用旧工具链。内容哈希与克隆深度无关。
- `.config` 只取切片：加一个普通包不该让工具链缓存失效。

#### mtime 归一 —— 不做则工具链缓存 100% 不生效

`tools/normalize-mtime.sh` 把源码树 mtime 固定为 `2000-01-01`。理由（读
`scripts/timestamp.pl` 与 `include/depends.mk` 源码确认）：

- stamp 规则是 `timestamp.pl -n <stamp> <路径> <依赖stamp>`，`-n` 的取值是
  **peek 而不 shift**，所以 `<stamp>` 自己也在被 stat 的路径列表里；
  判据是「这批路径里 mtime 最大的那个是不是 `<stamp>` 自己」。
- 全新 git clone 把所有源码 mtime 写成「现在」→ 缓存里那份旧 stamp 必然更旧
  → 工具链被判过期 → 完整重编。
- 宿主工具 stamp 名里含 `find_md5`（`find … -printf "%p%T@"`，也算 mtime），
  mtime 每次不同 → stamp 文件名每次都不同 → 宿主工具也必然重编。

**预热 job 与构建 job 用同一个脚本、同一套排除规则**，否则两边 `find_md5`
不同，缓存照样不命中。

#### 哈希不一致的自愈

`scripts/download.pl` 在本地文件哈希不符时是 `die`，**不是重新下载**：

```perl
if ($sum eq $file_hash) { cleanup(); exit 0; }
die "Hash of the local file $filename does not match ..."
```

长期缓存 `dl/` 之后这不是理论风险 —— 上游重打包但文件名不变时必然发生，
且每次构建都会在同一处硬失败。`tools/make-download.sh` 从日志里精确取出
不匹配的文件名、逐个删除（打印文件名）、重试最多 3 轮；同时外层套
`timeout 3000` 防单个慢源拖死 job。

#### `dl/` 双写

| 写入者 | 时机 | 作用 |
|---|---|---|
| `cache-deps.yml` 的 `warm-dl` | 每天 UTC 20:00（北京 04:00） | 从零补齐所有源码包 |
| `build-openwrt.yml` 的 `Refresh dl mirror cache` | 每次**成功**构建后 | 补上「预热之后、构建之前」上游新 bump 的版本 |

只靠定时预热的话，上游在两次预热之间换掉的 tarball 永远补不进镜像。
构建后回写那一步是 `continue-on-error: true`：缓存是加速手段不是交付物。

#### 新增脚本

| 脚本 | 职责 |
|---|---|
| `tools/gen-openwrt-config.sh` | `.config` 的**单一配方**，预热与构建共用；拒绝在 `.config` 已存在时运行 |
| `tools/dir-mirror.sh` | 通用分片镜像打包/解包（`tar → zstd/gzip` 流式，不落中间包） |
| `tools/cache-release.sh` | Release 资产的存/取/列/删，用退出码 10 区分「没有缓存」与「缓存坏了」 |
| `tools/lede-fingerprint.sh` | 工具链/宿主工具的内容指纹 |
| `tools/normalize-mtime.sh` | 源码树 mtime 归一，并自检有无漏网目录 |
| `tools/verify-toolchain-cache.sh` | 解包后判定缓存能否复用（含「真编译一个最小 C 程序」） |
| `tools/make-download.sh` | `make download` + 硬超时 + 哈希自愈 |
| `tools/verify-workflow-scripts.py` | 抽出工作流里所有 `run:` 块交给 `dash -n` |

#### 修复

- **`.config` 配方抽成脚本**：原先内联在 YAML 里，预热 job 若再抄一份必然漂移，
  后果是「预热以为不用某包 → 镜像里永远没有 → 每次构建回落到慢速源」。
- **`chinadns-ng` 的注释与实现相反**：原注释称「dnschain 运行时依赖」，
  而 v0.10.0 起框架已不依赖它（`docs/adr/0005-remove-chinadns-ng.md`）。
  已按实况更正为「由 SSR-Plus 的 INCLUDE 带入，显式再声明一次」。
- **`build-openwrt.yml` 中两段注释与步骤错位**：dl 回写步骤的说明原在
  「产物兜底断言」上方，产物断言的说明原在 dl 回写步骤上方，已各归其位。
- **`docs/build/ci.md` 大量行号引用失效**：因新增步骤导致整体下移，
  已按实际位置重算 §4 步骤表、§4.1 符号表、§5.1-§5.9 断言表、§7 已知问题。
  同时新增 §8「构建缓存」与 §9「`cache-deps.yml`」两章。
- **`docs/operations/verification.md` 的 CI 行号**：`verify-dnschain-domains.sh`
  与 `verify-trafficctl-invariants.sh` 的调用位置改为带文件名的新行号。

#### 验证

本地实跑（Windows + WSL Ubuntu-22.04，`/bin/sh` 为 dash）：

- `dash -n` 全部 7 个新脚本：通过。
- `python3 tools/verify-workflow-scripts.py`：3 个工作流共 57 个 `run:` 块，
  0 个语法错误。
- `dir-mirror.sh` 往返：3 分片打包→解包后 `diff -r` 内容完全一致；
  删掉一个分片后拒绝解包（`分片数不符：meta 写 4，实际 3`）。
- `cache-release.sh`（stub 掉 `gh`）：save 覆盖旧分片、只删同 `NAME` 的资产
  （另一个缓存种类存活）、restore 按 pattern 下载、缺失 Release 返回 10。
- 完整缓存链路：pack → save → restore → unpack → `diff -r` 三个子树全部一致
  → `verify-toolchain-cache.sh` 返回 0；删掉分片后解包被拒。
- `verify-toolchain-cache.sh` 四类负例（缺目录 / 假 gcc / 缺工具链 stamp /
  缺宿主工具 stamp）均返回 11。
- `make-download.sh` 四条路径：哈希自愈（删文件后重试）、超时提示、
  一般失败回显末 40 行、成功计数，行为均符合设计。
- `gen-openwrt-config.sh` 产出 48 行 `.config`，关键符号齐全；
  二次运行被拒（`rc=1`）。

未做：真实 GitHub Actions 运行（本机无法执行 3.5 小时构建）。
首次 push 后需确认三件事：`cache-deps.yml` 三个 job 全绿、
`cache-build-v1` Release 上有 `dl.meta` 与 `toolchain-*.meta`、
下一次构建日志里出现 `工具链缓存校验通过`。

## [v0.18.0] - 2026-10-24

### 变更 — tab 结构重构：概览放结果、域名放资产与参数（ADR-0007）

用户提出「域名页面和概览与诊断页面的 tab 合并方案，我感觉有点重合」。

**取证结论：section 层面没有重合。** 两个 tab 的 section 标题零交集，
数据生产者也不重叠（`chain_snapshot`/`selftest` 只在概览，
`health_rows`/`triage_rows` 只在域名）。真实的重合是五类缺陷：

| 缺陷 | 证据 |
|---|---|
| 两个按钮执行同一命令 | 「一键归一」与「手动导入名单」都是 `dnschain-reconcile`，模型层函数体逐字相同 |
| 「重建分流规则」3 个入口 | 域名按钮 + 概览两按钮 + 保存并应用 |
| 同一判定两套实现 | servers-file 就绪：自检第 19 项 vs `ds.serversfile_ready`；结论可矛盾 |
| 「已录入清单」挂错 section | 沿用上一个 `s`，实际渲染在「国外」下，语义错 |
| 概览首屏 4 块都在答「通不通」 | 解析链路图 / 实时诊断图 / 链路指标 / 组件状态表 |

**核心判据**（写进 ADR，后续加功能必须遵守）：
**概览放「结果」——现在通不通、哪里坏、怎么修。
域名放「资产与参数」——哪些域名归哪边、怎么判、阈值多少。**

#### 修复 — 两个重复入口

- 「手动导入名单」按钮删除。`dnschain-reconcile` 本就**同时做**「归一不变量」
  与「导入名单」两件事（脚本头 :9-10），两个按钮是同一件事的两个名字。
  另一个必须删的理由：它无条件打 ✓，不看 `exec_ok` 结论，违反 AGENTS 红线 3。
- `M.import_lists()` 一并删除（死函数，留着会让后来者再接一个重复入口）。

#### 修复 — 「已录入清单」拆为独立 section

它是国内+国外**两个清单的合并只读视图**，原先挂在「国外」的 `s` 下，
`SECTION_TAB` 里也没有它的键。现在独立成 section 并登记。

#### 变更 — 两张链路图合并为一张「链路拓扑图」

`解析链路`（拓扑）+ `实时诊断链路`（20 项按 8 阶段重分组）合并。
旧版两张图并列，用户得在脑中做两次映射（「图 A 的那段」↔「图 B 的那个阶段」）。
新版：8 个阶段串成一条链（表达「流量依次经过」），每节点带状态徽标，
断点处线条变红。`_chain_graph`（手写内联 SVG 1120×372）已删除。

`链路指标` 与 `组件状态` 合并进 `<details>` 折叠下钻 —— 图负责**定位**
（哪一段红了），表负责**确认**（具体哪个 PID 占了端口）。

#### 新增 — diagnosis.lua：动态诊断，不写死文案

用户要求「动态看到链路问题，自动化解决不了时让用户可视化快速解决」。

`dnschain-selftest` 有 **60 个 emit 调用点**。给每个 FAIL 分支手写
cause/impact/fix 等于把「写死」搬到 shell，且**新增检查项时必然漏写**。
改用「证据 → 症状」规则推导：`evidence` 本身已是动态真实探测结果，
缺的是推导。规则十余条，覆盖绝大多数失败形态。

**三种自动生成分支**（用户明确要求）：

| 情况 | 处理 |
|---|---|
| 新增检查项未归组 | 自动进**兜底阶段「其他检查」**，标注「未归入链路阶段（共 N 项）」 |
| 证据匹配不到规则 | 输出「**未识别的失败模式**」+ 证据原文 + 复现命令 |
| 阶段 FAIL 但证据为空 | 显示「证据缺失」+ 该阶段检查项编号 |

**边界是诚实的**：宁可说「我不认识这个失败」，也不生成看起来合理但可能错误的
诊断 —— 错误诊断比没有诊断更糟。

#### 新增 — selftest 输出 AT / DUR / RUN

用户要求「加入时间戳和序列号尽量详细」。

```
SUMMARY PASS=20 FAIL=0 SKIP=0 AT=2026-10-24T18:36:47 DUR=1s RUN=4
```

- `AT` 是**自检运行时刻**，不是页面渲染时刻 —— 配合 60 秒结果缓存与
  10 秒跨请求 TTL 缓存，用户必须能判断这份结论有多旧
- `RUN` 是轮次号，**读缓存时不递增**（轮次号含义是「第几次真跑」）
- 单项行不变，避免破坏现有解析

#### 变更 — 改道状态/明细与相关按钮搬进概览

改道状态/明细是**结果**，观测与阈值是**参数**。前者搬概览（与改道触发按钮同 tab，
点完就地看到变化），后者留域名。概览另加「分诊摘要」一行（共 N 条 / 已入库 M），
明细仍留域名 —— 200+ 行表格不会把链路图挤下去。

#### 验证

**本地静态校验（全部通过）**

| 工具 | 结果 |
|---|---|
| `sh tools/verify-dnschain-domains.sh` | **159 OK / 0 FAIL**，RC=0（新增第 13 节 13 条 tab 结构断言） |
| `python tools/check-dnschain-lua.py` | **PASS=156 FAIL=0** |
| `python tools/render-dnschain-diagrams.py --check` | **PASS=70 FAIL=0** |
| `python tools/extract-dnschain-i18n.py` | 463 条无缺失（比上版少 18 条 = 删除旧图与合并按钮的净减少） |
| `sh tools/verify-dnschain-ci-sim.sh` | RC=0 |
| `dash -n` × 3 脚本 + `luac -p` × 4 文件 | 全通过 |

`diagnosis.lua` 逻辑单测（真实 Lua）：STAGES 覆盖 1-20 完整；加第 21 项 →
自动生成兜底阶段并标注「未归入链路阶段（共 1 项）」；4 条规则正确命中，
1 条诚实报「未识别」。

**真实路由器验证（OpenWrt 24.10.5，`192.168.3.254`）**

| 项 | 结果 |
|---|---|
| 整页渲染 | 3.65 s / 343 KB，Lua 错误 **0** |
| `AT`/`DUR`/`RUN` | 实测 `AT=2026-10-24T18:36:47 DUR=1s RUN=1`；缓存命中 RUN 不变；`-f` 后 RUN=2 |
| 20 项自检 | 完整，`CONCLUSION: 链路正常` |
| 旧内容消失 | 解析链路 0、实时诊断链路 0、手动导入名单 0、链路指标 0 |
| 新内容出现 | 链路拓扑图、断点诊断、分诊摘要、展开组件状态与指标 |

**真实浏览器视觉验证（Chrome + luci-theme-shadcn）**

- 6 个 tab 正常，21 个 section 全部归组
- 概览首屏：结论徽标「链路正常」+ **链路拓扑图**（8 阶段成链、每节点带 PASS 计数
  与真实证据）+ **断点诊断**（「20 项自检全部通过」+ 时间戳「运行于
  2026-10-24T18:43:47 · 耗时 1s · 第 4 轮」）+ 组件状态折叠区
- 4 张 SVG 全部渲染：链路拓扑图 / 未知目标分诊链路图 / 改道状态思维导图 / 分诊结果思维导图
- 「已录入清单」独立成 section，位置在「国外」之后、「判定链路」之前

**回滚**：备份在 `/root/dnschain-bak-20261024-151049`（第一步改动前）。

## [v0.17.1] - 2026-10-24

### 变更 — DNS 分流页与最新分流标准对齐；修复页面性能（冷启动 55s → 3.7s）

用户要求四件事：① 核对每个 TAB 与最新分流逻辑一致；② 核实所有思维导图与
分流逻辑/规则库/代码一一对应；③ 分诊结果表把 IP 转 IP 段入库并加时间戳与
序号，已入库的默认不再显示；④ 全局改名为「DNS 分流」。
随后追加第五件：⑤ 修复切换本页时 CPU 暴涨、页面打开很慢。

对照标准（需求原文）：

```
入口条件：不在 GFW 名单、不在 blacklist、不在 china、不在任何数据库
① 试直连（真实发请求）
    通 → 落库：IP 写 china 集合，域名写 custom-domestic.txt
    不通 → ②
② 试代理（移入 blacklist 后再发请求）
    通 → 落库：IP 写 blacklist 集合，域名写 custom-foreign.txt
    不通 → ③
③ 标记 dead，不加入任何集合
```

#### 修复 — `dnschain-triage apply` 有 1/3 的 IP 记录永远重放不到

`apply` 的「补全 DNS 轮询漏掉的 IP」那段用 `rec_ip_put "$_ip" "$v"` 写入，
而 `$v` 是**域名的**结论（`domestic`/`foreign`），不是 IP 的（`direct`/`proxy`）。
于是 IP 记录里会出现 `47.76.188.58|domestic`，而重放的 `case` 只匹配
`direct|proxy` → **静默跳过**。

症状：域名落库了，但它名下的 IP 段在 SSR-Plus 重启后不再被重放 →
集合里缺段 → 该 IP 走兜底规则被送进代理 → 页面白屏，而分诊记录看着一切正常。

两处修：写入端改 `rec_ip_put "$_ip" "$_vd"`（IP 的结论）；
读取端 `case` 同时接受 `direct|domestic` 与 `proxy|foreign`（兼容历史记录）。

#### 修复 — `cmd_list` 输出的域名结论页面认不出

记录文件里域名存 `domestic`/`foreign`，页面表格按 `direct`/`proxy` 查 TONE 表。
不归一的话徽标退化成灰色、文案显示原始值，看起来像「未知结论」。
现在 `list` 统一映射成 `direct`/`proxy`/`dead`。

#### 新增 — 分诊记录带时间戳，`list` 输出序号 / IP 段 / 是否已入库

记录格式从 2 字段扩到 3 字段（前 2 字段与旧版兼容，旧记录时间显示 `—`，
不强制迁移 —— 迁移会改写用户已有的审计记录）：

```
<目标>|<结论>|<写入时间 YYYY-MM-DDTHH:MM:SS>
```

`list` 输出（v0.16.4 起 7 字段）：

```
ITEM <序号>|<目标>|<类型>|<结果>|<时间>|<IP段>|<是否已入库>
```

IP 段与「已入库」都是**每次 list 现算的派生量**，不存盘：
段由 `cidr_for_ip` 唯一决定（规则一改重算即得），「已入库」要查当前 nft/UCI
状态（上游 SSR-Plus 重启会清空集合，旧的「已入库=1」就是错的）。

时间戳用 `date '+%Y-%m-%dT%H:%M:%S'`，**不用 `date -Iseconds`** ——
BusyBox 的 date 没有 `-I`（实测 `date: invalid option -- 'I'`）。

#### 修复 — 页面性能：冷启动 55 秒 → 3.7 秒，热加载 1.4 秒

**用户报告**：切到本页 / 冷启动时 CPU 负载暴涨，页面打开很慢。

**实测根因**（路由器 N2930 / OpenWrt 24.10.5，全部数据为现场测得）：

| 环节 | 优化前 | 根因 |
|---|---|---|
| `dnschain-triage list` | **52.49 s** | 每行一次 `nft get element`（实测 **140 ms/次**，208 次） |
| `dnschain-triage apply` | **62.65 s** | 同上，且每轮收敛都跑 |
| 整页冷启动 | **55.18 s** | 页面两处调用 `triage_rows()`，加上 selftest/health 各重跑 |
| 整页热加载 | **3.0 s** | 每请求独立进程，请求内缓存跨不过去 |

⚠️ 旧代码注释写「实测单次 nft get element 约 8ms」—— **这是错的**，实测
140ms，差 17 倍。注释里的错误数字会让后来者误判「这点开销可以接受」。

**五级修复**（每级都单独实测）：

1. **集合快照**：`nft list set`（110ms/次，共 2 次）替代逐条 `get element`。
   nft 调用 **208 → 2**，list 52.49s → 10.05s。
2. **`cidr_for_ip` 去 fork**：`ip_prefix2`/`ip_to_cidr` 改用 `${ip%%.*}`
   参数展开（原来每 IP 4 次 `cut`），段表匹配改 `case`（原来 13 条 × 2 次 `cut`）。
   10.05s → 1.17s。
3. **awk 批量算段**：用一个 awk 进程把整份记录文件转成 ITEM 行，shell 不再逐行。
   1.17s → 0.96s。
4. **awk 内哈希表判成员**：把 56KB 快照按逗号 split 进哈希表。
   原来 shell 的 `case` 要线性扫描 56KB × 246 行 ≈ 13MB。0.96s → **0.41s**。
5. **区间覆盖判定**：集合带 `flags interval` + `auto-merge`，被父段包含的段
   在 `nft list set` 里**查不到字面**（实测 `36.110.0.0/16` 被
   `36.96.0.0-36.113.255.255` 覆盖，`add` 返回 0 但不新增记录）。
   只做精确匹配会让 `apply` **永不幂等**（`applied` 恒为 93）。
   改用「区间展开 + 按 lo 排序 + 二分查覆盖」，复杂度 O(m·log n) ——
   线性扫版实测把 list 拖回 3.72s、apply 拖到 40s，二分后回到 0.82s。

**apply 另修两处**：
- 域名补全段原来每 IP 调 `cidr_for_ip` + `_dc_snap_covers`（117 次函数调用，
  占 apply 16 秒里的 12 秒），改为 awk 批处理。
- `rec_ip_put` 每次重写整个记录文件（`grep -v` + `mv`），逐条写是 O(n²)，
  改为攒到临时文件一次性 merge。

**页面侧跨请求 TTL 缓存**（10 秒，落 `/var/run/dnschain/`，tmpfs 不写 flash）：
`selftest`（1.20s）、`triage list`（1.19s）、`health status`（0.21s）。
LuCI 每个 HTTP 请求是独立进程，`cached()` 只覆盖请求内 —— 切一次 tab 就全重跑。

⚠️ 引入缓存后必须同步的三处（否则用户点按钮看到旧结果）：
`ds.selftest(true)` 绕过 TTL；「立即分诊」删 `.triage-list.cache`；
「立即探测一轮」「清空改道状态」删 `.health-status.cache`。

**最终实测**：

| 指标 | 优化前 | 优化后 | 倍数 |
|---|---|---|---|
| `triage list` | 52.49 s | **0.41 s** | 128× |
| `triage apply` | 62.65 s | **1.78 s** | 35× |
| 整页冷启动 | 55.18 s | **3.69 s** | 15× |
| 整页热加载 | 3.0 s | **1.44 s** | 2× |
| 浏览器 TTFB | ~55 s | **1.58 s** | 35× |
| `apply` 幂等性 | 恒 applied=93 | **applied=0** | — |

CPU 负载：页面加载期间 `loadavg` 0.65（优化前持续打满）。

**新增 16 条性能不变量断言**（`tools/verify-dnschain-domains.sh` §12）：
锁住「不在循环里用 `set_has`」「必须有集合快照函数」「list 必须批量化」
「必须用覆盖判定」「三个缓存文件必须存在」「按钮必须能绕过/删除缓存」。
这类回归功能上完全正确、断言全绿、只是慢，是最难发现的一类。

⚠️ 写这些断言时踩了 AGENTS §6 第 7 条记载的坑：`cmd_apply` 里有
「旧实现每行调 set_has」的**解释性注释**，不剥注释会让断言永久误报。
已改为先 `grep -v '^[[:space:]]*#'` 再判断。

#### 变更 — 分诊结果表格：加序号/时间/IP 段，已入库折叠留档

表格列从 4 列扩到 7 列：序号 / 目标 / 类型 / IP 段 / 结论 / 落库动作 / 时间。

「已入库的不需要再次被看到」用**折叠**而不是删除实现：
待处理（dead / 尚未入库）正常显示；已入库的收进默认关闭的 `<details>`
（`dc-details`，原生元素，无需 JS，键盘可达）。保留的原因是与
「加时间戳和序号便于追踪审计」这一条并存 —— 从 HTML 里删掉，审计线索就断了。

#### 变更 — 重画「判定链路图」，与最新分流标准逐节点对齐

旧图画的是另一套逻辑（域名 → 归属 → 首选链探测 → 保持/改道），那是 v0.13.0
的「健康探测 + 自动改道」，与分诊标准不是一回事。两套图并列摆在同一页，
用户无法判断「到底哪套在起作用」。

新图三行三列，与标准逐条对应：

```
入口(未知目标) ─┬→ ① 试直连 ─→ 直连通 → 落库 china / custom-domestic.txt
                │       ↓(不通)                    ↓(也不通)
                ├→ ② 试代理 ─→ 代理通 → 落库 blacklist / custom-foreign.txt
                │       ↓(不通)
                └→ ③ 标记 dead ─→ 不加入任何集合
       已有归属（跳过，不干预）
```

几何约束（改坐标必须同步改 `route_layout`，有断言）：

- `NH` 从 48 提到 **64** —— `box()` 三行基线在 `y+21 / y+37 / y+51`，
  取 48 时第三行跑到框外（文字压在下边框上），只查 viewBox 越界的断言发现不了。
- 「已有归属」放 C1 而不是 C2：放 C2 会占住第三行中间列，②→③ 的竖线
  要么穿过它、要么与第三行横线交叉。
- 入口**只连 ①**：从入口同时连 ② 会被读成「入口可以直接试代理」，
  与「① 不通 → 才进 ②」矛盾。①→②、②→③ 用竖虚线表达条件性推进。

#### 新增 — 分诊结果思维导图（落点分布）

规则图（route_map）画「为什么会这样判」，本图画「现在落在哪一档」：
三档（① 直连通 / ② 代理通 / ③ 都不通）+ 每档条数与已入库数 + 落库去向。
`triage_layout()` 与 `triage_map()` 共用同一套档位与行高算法。

#### 修复 — 分诊开关此前只存在于脚本默认值里，页面完全没有入口

后台每轮收敛都会读 `triage_enabled`（默认开）与 `triage_max`（默认 12）
并发真实 HTTP 请求，而页面上**一个入口都没有** —— 用户既看不到它在跑，
也无法关掉。现补三个键进 UCI 与页面：

| 键 | 默认 | 作用 |
|---|---|---|
| `triage_enabled` | `1` | 总开关 |
| `triage_max` | `12` | 每轮最多分诊几个目标 |
| `triage_conc` | `8` | 并发数（脚本读环境变量，现由 `dc_triage_cycle` 从 UCI 导出） |

⚠️ 并发数必须 `export DNSCHAIN_TRIAGE_CONC` 再调脚本 —— 不导出的话
页面上的设置**完全不生效**，而界面又显示成用户改过的值。

#### 变更 — 全局改名「DNS 链路」→「DNS 分流」

按用户确认的范围：**只改显示文案**。以下内部标识全部保持不变（改名会让
老配置不自动迁移、并波及 Makefile/menu.d/acl.d/controller/20 个 section/
5 个校验脚本/docs/CHANGELOG）：

包名 `luci-app-dnschain`、路由 `admin/services/dns_chain`、
脚本 `dnschain-*`、UCI 配置名 `dnschain`。

改动点：菜单标题（menu.d + controller）、页面标题与描述、`启用 DNS 分流框架`
开关文案、PO、Makefile description、`docs/routes.md`、`docs/packages/
luci-app-dnschain.md`、`docs/runtime/*`、`docs/adr/0003`、`docs/adr/0004`、
`docs/adr/0005`、`docs/README.md`、`GLOSSARY.md`、`AGENTS.md`、
运行时脚本头注释。

⚠️ 仓库里**没有**「DNS改道」这个旧称（全仓库 grep 为 0），旧称实际只有
「DNS 链路」。

#### 验证

**本地静态校验（全部通过）**

| 工具 | 结果 |
|---|---|
| `python tools/check-dnschain-lua.py` | **PASS=156 FAIL=0** |
| `python tools/render-dnschain-diagrams.py --check` | **PASS=70 FAIL=0** |
| `python tools/extract-dnschain-i18n.py` | 481 条中文文案无缺失 |
| `sh tools/verify-dnschain-domains.sh` | **132 OK / 0 FAIL**，RC=0 |
| `sh tools/verify-dnschain-ci-sim.sh` | RC=0，CI 模拟校验通过 |
| `dash -n` × 6 个脚本 | 全部通过（triage / dnschain.sh / reconcile / init.d / uci-defaults / dnsproxy） |
| `node --check dnschain.js` | 通过 |
| `luac -p` × 4 个 Lua 文件 | 全部通过 |

⚠️ 首次运行时 `check-dnschain-lua.py` 有 6 条 FAIL、`verify-dnschain-domains.sh`
有 9 条 FAIL —— 全部是**断言仍钉着旧图内容**（`域名判定链路图` / `直连链路` /
`自动改走直连` 等）。图按新标准重画后这些字符串本就不该存在。已把断言改为
新图的节点文案，并补上「IP 一律转段」「dead 不入库」两条硬约束的断言。
这不是「改断言让它变绿」—— 改的是断言对应的**事实**，且新增了更强的检查
（如分诊表 7 列、`dc-details` 折叠、三个分诊开关必须注册）。

**真实路由器验证（OpenWrt 24.10.5 x86/64，`192.168.3.254`）**

部署方式：备份到 `/root/dnschain-bak-20261024-151049` 后覆盖 10 个文件。

| 项 | 结果 |
|---|---|
| 部署后 `sh -n` | triage 与 dnschain.sh 均通过 |
| 菜单标题 | `"title": "DNS 分流"`（实测读到） |
| 页面 HTTP | **200 / 286747 B**，Lua 错误 **0** |
| 自检 | **PASS=20 FAIL=0 SKIP=0**，`CONCLUSION: 链路正常` |
| 分诊守护进程 | 真实跑一轮：`total=12 direct=10 proxy=1 dead=0 known=1` |
| 时间戳写入 | 实测 `example.com\|domestic\|2026-10-24T16:01:22`（3 字段） |
| `list` 归一 | 实测输出 `ITEM 182\|example.com\|domain\|direct\|2026-10-24T16:01:22\|\|0` |
| **apply 修复实证** | 制造 `203.0.113.77\|domestic` 脏记录 → apply 前 china 无 `203.0.113.0/24`，apply 后**有**（修复前该记录被静默跳过） |
| 旧记录兼容 | 2 字段记录仍可读，时间列显示 `—`（不迁移） |

**真实浏览器视觉验证（Chrome + luci-theme-shadcn）**

- 6 个 tab 全部存在：概览与诊断 / 域名 / 解析 / 分流 / 代理 / DHCP
- 21 个 section 全部归组，无「未归组」泄漏
- **分诊结果区**：三个开关（启用自动分诊 ✅、每轮最多 12、并发 8）正常渲染
- **落点分布思维导图**：三档 + 计数 + 落库去向，实测「① 直连通 162 条 · 已入库 63」
- **7 列表格**：序号 / 目标 / 类型 / IP 段 / 结论 / 落库动作 / 时间，实测
  `3 | 36.110.192.103 | IP | 36.110.0.0/16 | 直连通 | 已加入 china 集合（直连）| —`
- **已入库折叠区**：`open=false`（默认关闭），summary「已入库（审计留档，默认折叠）（69）」，
  内部 70 行；展开后完整显示审计留档
- **判定链路图**：按新标准渲染（未知目标 → ① 试直连 → ② 试代理 → ③ 标记 dead，
  含「已有归属」支与两条底部硬约束），连线无交叉、文字无溢出
- 汇总行：`直连通 162 / 代理通 16 / 都不通 10 / 合计 188`

**回滚命令**

```sh
cp -r /root/dnschain-bak-20261024-151049/* /   # 按需逐项覆盖
/etc/init.d/rpcd restart
```

## [v0.16.3] - 2026-10-24

### 实时诊断链路改为思维导图

用户要求：「实时诊断链路改为思维导图」。

#### 改前

v0.15.0 版是一列「阶段名 + 状态点 + 计数 + 证据」的**纵向列表**。
信息是全的，但它不是链路图 —— 看不出段与段之间的顺序与依赖关系，
而诊断的核心问题恰恰是「断在哪一段、下游受不受影响」。

#### 改后

三层思维导图，与页面其余三张图同一套视觉语言：

```
        根（整体结论 / 全通 / PASS 20 / FAIL 0）
          ├─ 客户机入口 ┈┈ 192.168.3.254:53 应答 OK
          ├─ dnsmasq   ┈┈ server=127.0.0.1#5353 恰好 1 条
          ├─ 国内链路   ┈┈ 127.0.0.1:5353 应答 OK
          ├─ 国外链路   ┈┈ www.google.com -> 142.251.151.119
          ├─ 代理与分流 ┈┈ ss_spec 表 2 个、:1234 在监听
          ├─ 分流规则   ┈┈ dnschain-split.conf 全部指向 :5336
          ├─ fw4       ┈┈ fw4 check 通过
          └─ 双栈与端口 ┈┈ :5335 无监听
```

- **根 → 阶段**：贝塞尔曲线，用该阶段的**状态色** —— 一眼看出哪条支路是红的
- **阶段 → 证据**：细虚线 + 浅底框，视觉上是「附注」而非「下游」
- **根节点**：标题「整体结论」、副标题给结论（全通 / 部分跳过 / 有断点）、
  第三行给 `PASS n / FAIL n`

#### 职责划分

绘图逻辑移进 `diagrams.lua` 的 `live_diag_map()`，`general.lua` 只负责
「把 selftest 的 20 项归组成 8 个阶段」—— 归组规则是业务知识，
不该散到绘图层。

#### 布局参数（实测标定）

| 项 | 值 | 依据 |
|---|---|---|
| 画布宽 | 1180 | 证据列最长串约 300px（11px 字号），留余量 |
| 阶段节点 | 168×52 | 最长阶段名「双栈与端口」约 66px，留余量 |
| 证据框 | 420 宽 | 超长仍走 `truncate(ev, 64)` 截断加省略号 |
| 高度 | 546（8 阶段） | `16*2 + 8*52 + 7*14`，由阶段数直接算出 |

**固有宽高必须给**：否则 CSS `width:auto` 回落到 100%，图被拉伸放大
（这是本仓库踩过的老问题，判定链路图与改道状态图都遇到过）。

#### 校验

`tools/render-dnschain-diagrams.py` 新增 8 条断言（PASS 48 → **56**）：

```
ok   实时诊断图产出合法 SVG
ok   实时诊断图有 figure 身份标记
ok   实时诊断图有固有宽高（1180x546）
ok   实时诊断图含全部 8 个阶段
ok   实时诊断图含证据串
ok   实时诊断图根节点给出整体结论（有断点）
ok   实时诊断图所有图元在 viewBox 内
ok   实时诊断图空数据时不报错
```

`tools/check-dnschain-lua.py` 的 aria-label 断言同步改为
「实时诊断链路思维导图」（与其余三张图的命名统一）。

#### 视觉验证（以看到的为准）

实测 DOM：

| 项 | 值 |
|---|---|
| viewBox | `0 0 1180 546` |
| 固有宽高 | `1180 × 546` |
| `<rect>` | 17 个（1 根 + 8 阶段 + 8 证据框） |
| `<path>` | 16 条（8 贝塞尔 + 8 虚线） |
| `<text>` | 27 段 |

截图确认：根节点居中、8 条曲线扇形展开、每条支路末端的证据框对齐。

#### 验证

```sh
python tools/check-dnschain-lua.py        # PASS=134 FAIL=0
python tools/render-dnschain-diagrams.py  # PASS=56 FAIL=0
python tools/extract-dnschain-i18n.py     # 462 条无缺失
sh tools/verify-dnschain-domains.sh       # 131 OK / 0 FAIL
```

路由器：页面 HTTP 200 / 233216 B，0 Lua 错误，自检 `PASS=20 FAIL=0`。

#### 改动范围

```
M package/luci-app-dnschain/luasrc/model/cbi/dnschain/diagrams.lua
M package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua
M tools/render-dnschain-diagrams.py
M tools/check-dnschain-lua.py
M package/luci-app-dnschain/po/zh-cn/luci-app-dnschain.po
```

---

## [v0.16.2] - 2026-10-24

### 按 IP 段落库、修实时诊断图乱码、修空方块组件

三项修复，均以**实际渲染的页面**为准验证。

#### 一、IP 段计算与落库（用户要求）

> 用户原话：「计算当前IP，查看IP归属后 -> 算出IP段再追加入 china
> 或者国外代理列表数据库中」

之前的做法是把单个 IP 直接丢进集合。集合带 `auto-merge`，相邻 IP
会被 nft 自动合并，但**孤立的 IP 永远是 /32**，同机房的兄弟 IP
下次仍要重新分诊。

现在按 IP 所在网段算出 CIDR：

```
① 已知网段表优先（CN_SEGS / OVERSEAS_SEGS）—— 大厂/云厂商实际分配段
② 都不匹配 → 退化为 /24（同一 /24 通常同机房同策略）
③ 特殊段保护：127/8、169.254/16、224/4、私网等绝不外扩
```

实测计算：

| IP | 方向 | 算出段 |
|---|---|---|
| `47.76.188.58` | direct | `47.76.0.0/16` |
| `47.239.100.208` | direct | `47.239.0.0/16` |
| `171.108.216.18` | direct | `171.108.0.0/16` |
| `17.248.224.13` | proxy | `17.248.0.0/16` |
| `8.8.8.8` | proxy | `8.8.8.0/24` |
| `192.168.3.1` | direct | `192.168.3.1`（特殊段不扩） |
| `127.0.0.1` | direct | `127.0.0.1`（特殊段不扩） |

**只扩到 /24，不扩到 /16 或更粗**：`/16` 会吞掉 65536 个地址，
其中很可能包含别的组织的段。`47.76.0.0/16` 是阿里云海外节点，
但该段内也可能有非阿里的分配 —— 扩太粗会误伤。网段表里的
`/16` 是**已知归属**的例外（逐个核实过的）。

#### 二、实时诊断链路显示 BUG（截图里的 `111111111111113311`）

**根因**：`diagrams.lua` 的 `truncate()` 取值位置错了。

`utf8_iter` 每次返回三个值 `(码点, 字符原文, 字节长度)`，而原实现写：

```lua
for _, _, raw in utf8_iter(s) do   -- 第三个位置拿到的是「字节长度」
```

于是每个字符被替换成它的字节数（1/2/3/4）。实测：

```
"192.168.3.254:53 应答 OK"           → "1111111111111111133111"
"dnschain-split.conf 全部指向 :5336" → "111111111111111111113333111111"
```

**这个 bug 极其隐蔽**：代码语法正确、类型不报错、SVG 也能正常渲染，
只是文字全变成 1/3/4 —— 只有**看页面截图**才能发现。这也印证了
「以看到的视觉效果为准」的必要性。

修复后实测：

```
客户机入口    PASS 1   192.168.3.254:53 应答 OK
dnsmasq      PASS 3   server=127.0.0.1#5353 恰好 1 条
国外链路      PASS 3   www.google.com -> 142.251.153.119
代理与分流    PASS 1   ss_spec 表 2 个、:1234 在监听、global_server=cfg0b4a8f
```

#### 三、标题下方的空方块组件

**根因**：那是 LuCI 原生的 `<ul class="cbi-tabmenu">`。

本页的 tab 由 `dnschain.js` 生成 `.dc-tabs`，原生 `cbi-tabmenu` 是空的
（每个 `<li>` 里只有空 `<a>`）。但主题 CSS 给它设了
`display:inline-flex; height: 36px; padding: …`，于是渲染成一个
**32×36px 的空方块**，挂在标题和 tab 栏之间。

CSS 里其实**已经有**隐藏规则，但选择器写的是：

```css
.dc-tabs ~ .cbi-tabmenu { display: none !important; }
```

`~` 是**后续兄弟**选择器，而实际 DOM 里 `cbi-tabmenu` 在 `dc-tabs`
**之前** —— 规则永远不匹配。这就是「规则写了但没生效」：不报错、
不警告，只是没作用。

改为按父容器定位，覆盖两种顺序：

```css
.cbi-map > .cbi-tabmenu,
.cbi-map .cbi-tabmenu:empty,
.dc-tabs ~ .cbi-tabmenu { display: none !important; }
```

实测修复后：`display: none`、`0×0`。

#### 四、连带发现并修复的三个问题

**① 分诊把 google 误判成国内（严重）**

修完上面三项后，自检第 10 项 FAIL：

```
10 FAIL 国外 A 正确 — www.google.com -> 2001::1（污染值）
```

根因链：

```
分诊把 www.google.com 判 domestic
  → 写进 dom_domestic
  → watch.servers 指向 :5353（国内链）
  → 解析出 185.45.5.35 / 2001::1（污染值）
  → 自检 FAIL
```

**为什么「直连能连上」不能证明「该走直连」**：污染 IP 本身是
**能连通**的 —— 它就是本地劫持者的地址，直连返回 302。于是
`probe_http` 判定「通」，分诊据此写 domestic。但正确结论恰恰相反：
被污染说明**必须走代理**，让国外 DoH 拿到干净答案。

修法：在「试直连」之前加一步**污染/名单优先判定**：

```
① 域名在 GFW 名单里     → 强制走代理（归属是「需绕开污染」，
                          与直连是否偶然能通无关）
② 解析出已知污染值      → 强制走代理
```

修复后实测：

```
www.google.com → 142.251.150.119 / 142.251.154.119 / …
AAAA           → 2001:4860:482b:7700:: / …
自检第 10 项   → PASS
```

**② 脚本被 source 时会误触发完整分诊**

调试时用 `sh -c '. /tmp/triage; cidr_for_ip ...'`，结果整个分诊
跑了一遍（输出 8 个 ITEM）—— 因为脚本末尾的 case 分发在 source 时
同样执行，而 `$1` 恰好是空的 → 走了默认的 `run` 分支。

这在生产里也是隐患：任何脚本 source 它都会意外触发一轮完整分诊
（几十秒 + 发真实请求）。

修法：用 `basename "$0"` 判据。实测（路由器 dash）：

| 场景 | `$0` |
|---|---|
| `sh /tmp/t.sh` | `/tmp/t.sh` |
| `. /tmp/t.sh` | `sh`（外层 shell 名） |

⚠️ 另一个常见写法 `(return 0 2>/dev/null) && …` **在本环境无效**：
子 shell 里 `return` 总是合法且成功，两种情形都返回 0，实测两次都
打印「被 source」。不能用它判断。

**③ tab 徽标把 dead 条数当配置异常**

分诊表用红徽标表示「这个目标两种链路都不通」—— 那是**客观观测
结果**，不是本页配置有错。但 `countBadges()` 统计了所有
`.dc-badge--bad`，于是 tab 显示「10」，看上去像「有 10 处配置错误」。

修法：给分诊表加 `data-dc-triage` 标记，`countBadges()` 跳过其内部徽标。

**④ 静态资源被浏览器强缓存**

改完 JS 后页面仍执行旧版 —— 文件已部署（fetch 带 nocache 能读到新
内容），但浏览器缓存了。换页面 URL 加 `?cachebust=1` 也不生效
（资源 URL 没变）。

这种失效最难查：服务端文件是对的、逻辑是对的，只有浏览器跑的是旧的。

修法：CSS/JS 的 URL 加 `?v=<包版本>`。

⚠️ 试过 `nixio.fs.stat` / `luci.fs.stat` 两条路取 mtime，都会让本地
校验器的桩缺失而整个文件加载失败（实测 PASS 从 132 掉到 78，
报 `general.lua 能加载 FAIL`）。改用包版本常量，无依赖且语义正好。

#### 五、视觉验证（以看到的为准）

| 检查项 | 修复前 | 修复后 |
|---|---|---|
| `.cbi-tabmenu` | `inline-flex`，32×36px 空方块 | `display:none`，0×0 |
| 实时诊断证据 | `111111111111113311` | `192.168.3.254:53 应答 OK` |
| tab 徽标 | 域名 tab 显示「10」 | 无徽标 |
| google 解析 | `2001::1`（污染） | `142.251.150.119`（真实） |
| 自检 | `PASS=19 FAIL=1` | `PASS=20 FAIL=0` |

#### 六、验证

| 项目 | 结果 |
|---|---|
| `cc.sefan.pw` / `cc.sofan.biz` / `kn.btlms.org` | 各 **200 × 3/3** |
| `cdn.staticsfile.org/jquery.min.js` | **200 / 114541 B** |
| `www.baidu.com` / `www.google.com` / `github.com` / `www.youtube.com` | 200 / 302 / 200 / 200 |
| `dnschain-selftest` | `PASS=20 FAIL=0` |
| 分诊分布 | 99 direct / 1 proxy / 10 dead |

```sh
python tools/check-dnschain-lua.py        # PASS=134 FAIL=0
python tools/render-dnschain-diagrams.py  # PASS=48 FAIL=0
python tools/extract-dnschain-i18n.py     # 458 条无缺失
sh tools/verify-dnschain-domains.sh       # 131 OK / 0 FAIL
```

#### 七、改动范围

```
M files/usr/bin/dnschain-triage
M package/luci-app-dnschain/luasrc/model/cbi/dnschain/diagrams.lua
M package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua
M package/luci-app-dnschain/htdocs/luci-static/resources/dnschain/dnschain.css
M package/luci-app-dnschain/htdocs/luci-static/resources/dnschain/dnschain.js
```

#### 八、已知边界

- 网段表（`CN_SEGS` / `OVERSEAS_SEGS`）是**逐个核实过归属**的白名单，
  不覆盖的 IP 退化为 `/24`。新增云厂商段时补进表里即可。
- `MAX_PROBE_IPS=1` 的取舍见 v0.16.0 段；`apply` 会重新解析 A 记录
  补全轮询漏掉的 IP。
- GFW 名单判定用父域回溯（`www.google.com` → `google.com`），
  最多回溯到顶级域。

---

## [v0.16.1] - 2026-10-24

### 全链路审查：修复分诊落库被覆盖、补分诊结果面板、校准文档

以**实际渲染的页面**为准做全链路审查（不是只看代码通过）。
逐 tab 截图核对，发现并修复 3 个真实缺陷。

#### 一、严重缺陷：分诊落库被框架覆盖（数据丢失）

**现象**：页面「自定义域名·国内」表格显示「0 条 / 已生效 1 条」——
两个数字自相矛盾。

**根因**：`dnschain-triage apply` 直接往 `custom-domestic.txt` 追加，
而该文件是 `dc_gen_custom_lists()` 从 UCI `dom_domestic` **重新生成**的
运行时副本（`dnschain.sh:1156-1162`）。实测：

```
分诊写入后 custom-domestic.txt = 1 行（cc.sefan.pw）
跑一次 dc_gen_custom_lists  →  变成 0 行，分诊结果丢失
```

页面上的矛盾正是这么来的：表格读文件（1 条）、输入框读 UCI（0 条）。

**修法**：改写 UCI list，让框架自己去生成文件。

**同时修掉一个更隐蔽的坑**：`config domains 'dom_domestic'` 是**空 section**，
真正的 list 选项叫 `domain`（`general.lua` 里 DynamicList 的名字）。
写成 `uci add_list dnschain.dom_domestic=...` 会**静默失败** ——
uci 把 `dom_domestic` 当 section 名、找不到同名 option，命令返回 0
但什么都没写。正确路径是 `dnschain.dom_domestic.domain`。

修复后实测：UCI 11 条 → 生成文件 11 行 → 再跑 generate 仍 11 行（不再丢失）。

#### 二、缺失功能：分诊结果在页面上完全不可见

用户要求「所有功能都要能对得上视觉上看到的 web ui」。
分诊是 v0.16.0 的核心能力，但之前只能通过命令行 `dnschain-triage list` 查。

**新增 section「分诊结果」**（`general.lua:1317`，归 `domains` tab）：

| 列 | 内容 |
|---|---|
| 目标 | IP 或域名 |
| 类型 | IP / 域名 |
| 结论 | 直连通 / 代理通 / 两种链路都不通（三色徽标） |
| 落库动作 | 已加入 china 集合 / 已加入 blacklist 集合 / 已写入 dom_domestic / 已写入 dom_foreign / 不写入任何集合 |

底部汇总：直连通 N / 代理通 N / 都不通 N / 合计 N。

**与「改道明细」不是重复功能**：

| | 改道明细 | 分诊结果 |
|---|---|---|
| 输入集合 | 观测列表里 8 个种子域名 | 客户机访问过、但不在任何库里的未知目标 |
| 判定方法 | DNS 探测（两条链各一次） | HTTP 实测（试直连 / 试代理） |
| 落库目标 | `watch.servers`（DNS 走哪个实例） | `china`/`blacklist` 集合 + `dom_domestic`/`dom_foreign` |
| 回答的问题 | 「首选链通不通、要不要改道」 | 「这个未知目标该直连还是走代理」 |

实测渲染 51 行，三列语义与落库动作一一对应。

#### 三、思维导图未体现新分诊逻辑

概览 tab 的解析链路图底部只写：

> 国外域名解析结果经 nftset 写入 blacklist → 流量进 :1234

这是**旧机制的单一通路**。实际现在有两条落库路径，只写一条会让人
误以为「不在 gfw 名单就一定直连」—— 而不在任何库的目标要先经过分诊，
否则会落到兜底规则被误送代理（这正是 `cdn.staticsfile.org` 白屏的成因）。

改为两行说明：

```
静态分流：gfw 名单命中 → nftset 写 blacklist → 流量进 :1234
动态分诊：不在任何库 → 试直连，通→写 china；不通→试代理，通→写 blacklist；都不通→标 dead
```

#### 四、文档校准

`docs/packages/luci-app-dnschain.md`：

- §4.1 标题与表格：19 → **20 个 section**，新增「分诊结果」行，
  全部行号重新核对
- 新增 v0.16.0 变更说明块（含与「改道明细」的对比表）
- 修正 **7 处失效行号引用**（全部逐个对照 `general.lua` 实际内容定位）：

| 原引用 | 实际位置 | 内容 |
|---|---|---|
| `:231` | `:232` | 语义判色注释块起点 |
| `:1424-` | `:1632-` | `_filter_aaaa` 的 ListValue |
| `:1430-1441` | `:1652-1660` | `setmsg` 校验失败 |
| `:1864-1868` | `:2102-2106` | `_import` 按钮 |
| `:1930-1934` | `:2172-2196` | DNSMASQ 出口注释 |
| `:1959-1962` | `:2200-2203` | DNSMASQ 解析注释 |
| `:1963` | `:2204` | DNSMASQ 解析代码 |

校验结果：**92 处 `general.lua:NNN` 引用全部有效**（在范围内且非空行），
`SECTION_TAB` 的 20 个标题全部在文档中。

#### 五、审查方法（这次怎么保证「不误判正常」）

不看代码通过，只看页面：

1. 用真实浏览器打开页面，读 **DOM 实际状态**（`getComputedStyle` + `offsetParent`）
2. 逐个点击 6 个 `.dc-tab`，统计每次点击后**可见**的 section
3. 逐 tab 截图，人工核对内容
4. 对每个新功能，确认它在 DOM 里**真实渲染出数据行**，而不是只存在于 Lua 代码

实测结果：

| 检查项 | 结果 |
|---|---|
| tab 数 | 6（`概览与诊断`/`域名`/`解析`/`分流`/`代理`/`DHCP`） |
| 可见 section | 20 个，全部有 tab 归属，无跨 tab 重复 |
| SVG 图 | 4 张（解析链路 / 实时诊断链路 / 判定链路 / 改道状态） |
| 分诊面板 | 51 行真实数据 |
| 自定义域名 | 11 条，输入框与表格一致 |
| Lua 错误 | 0 |

#### 六、改动范围

```
M files/usr/bin/dnschain-triage
M package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua
M package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua
M package/luci-app-dnschain/po/zh-cn/luci-app-dnschain.po
M docs/packages/luci-app-dnschain.md
```

#### 七、补修：DNS 轮询漏掉的 IP 导致再次白屏

审查过程中实测发现：修复完上面三项后，`jquery` 又变 `000`。

**根因**：`cdn.staticsfile.org` 有 **2 个 A 记录**
（`47.239.100.208` / `47.76.188.58`）。分诊在某一刻跑，
只看到当时 DNS 返回的那一个，落库也就只有一个。
之后 DNS 轮询到另一个 IP → 它不在 `china` 集合 → 走兜底规则被送去代理
→ 代理连不上 → 又白屏。

实测复现：

```
47.76.188.58 在 china 集合里，47.239.100.208 不在
nslookup 返回 47.239.100.208
jquery → 000
```

**修法**：`apply` 时对每个已记录域名**重新解析当前 A 记录**，
把没记录过的 IP 按该域名的结论补上。

为什么放在 `apply` 而不是 `run`：`apply` 每轮收敛都跑，能持续跟上
DNS 轮询；而 `run` 要发真实请求，不能高频跑。

实测：删掉 IP → `000` → `apply` 补全 → `200 / 114541`，记录同时回填。

#### 八、验证


```sh
python tools/check-dnschain-lua.py        # PASS=134 FAIL=0
python tools/render-dnschain-diagrams.py  # PASS=48 FAIL=0
python tools/extract-dnschain-i18n.py     # 458 条无缺失
sh tools/verify-dnschain-domains.sh       # 131 OK / 0 FAIL
```

路由器实测：页面 HTTP 200 / 165325 B，三站 `cc.sefan.pw`/`cc.sofan.biz`/
`kn.btlms.org` 各 200，`jquery.min.js` 200 / 114541 B，自检
`PASS=20 FAIL=0`。

---

## [v0.16.0] - 2026-10-24

### 新增「默认直连 → 直连不通试代理 → 都不通标死」的自动分诊

修 `cc.sefan.pw` / `cc.sofan.biz` / `kn.btlms.org` 在客户机白屏的问题。
根因不在站点，在**本链路把国内可达的 IP 误判成国外、送去了代理**。

#### 需求原文（用户原话，不可改写）

> 不在 GFW 名单、不在代理 IP 集（blacklist）、不在国内 IP 段（china）
> 不在任何数据库的域名或者 IP 和 IP 段全部先走直连，如果直连不通
> 再走 SSR plus，如果都不通就标记是死的。如果跑通了就标记出来
> 是 IP 就转为 IP 段追加到现有的数据库中，如果是域名就追加到
> 域名对应列表数据中。

#### 根因（闭环实测）

三个站都引用 `cdn.staticsfile.org`（jQuery 静态资源），它解析到
`47.239.100.208` / `47.76.188.58`（阿里云海外节点）。

这两个 IP **不在 nft 的 `ss_spec china` 集合**（该集合只有 3794 条 CIDR，
而中国 IPv4 实际需要 8000+ 条 —— 明显不全），于是命中 `ss_spec_wan_fw`
兜底规则 `redirect to :1234` → 走代理。代理连不上它们 → TLS 握手断开
→ 浏览器拿不到 jQuery → 页面第一句 `$("body")` 抛
`ReferenceError: $ is not defined` → 整页白屏。

**决定性实验**（在 `ss_spec_output` 临时插 `ip daddr <IP> return` 绕开代理）：

| 状态 | curl | ping |
|---|---|---|
| 绕过代理（直连） | **200 / 114541 字节** | 21ms |
| 走代理 | `000` | 21ms（ICMP 不受代理影响） |
| 删规则复原 | `000` | — |

对照：`223.5.5.5`（国内 DNS）19ms、`8.8.8.8`（真国外）189ms。
21ms 的 IP 显然国内可达，被判为国外代理是误判。

#### 为什么上一版方案（RTT 猜测）被推翻

上一版用「ICMP RTT ≤ 80ms 判国内 → 加进 china」来猜。它错在
**用间接指标猜结论**：

- RTT 低不等于 HTTP 能跑通（服务器可能活着但不服务）
- RTT 高不等于必须走代理（绕路但可达的情况存在）
- 猜错就把流量塞进错误链路，故障依旧

本版改成**实测**：真的发请求，看能不能拿到响应。与需求原文
「直连不通再走代理」完全一致，不需要任何猜测。

#### 分诊流程

```
① 判定「是否未知」
     不在 china、不在 blacklist、不在 GFW 名单、不在 db-domains
     → 是未知，进入②；否则跳过（已有归属，不干预）

② 试直连
     临时把目标加入 china，发真实 HTTP 请求
     能拿到任意 HTTP 响应 → 直连通

③ 直连不通 → 试代理
     把目标从 china 移出、加入 blacklist，再发真实请求
     能拿到任意 HTTP 响应 → 代理通

④ 都不通 → 标记 dead，两个集合都不加

⑤ 落库（只在跑通时）
     · IP   → 加入 china 或 blacklist 集合
              （两集合都有 auto-merge，nft 自动合并成 CIDR 段）
     · 域名 → 追加到 custom-domestic.txt 或 custom-foreign.txt
              并写持久化记录，重启后重放
```

#### 三个必须记录的实现要点

**一、域名分诊必须追踪子资源**

首版只分诊「主站域名」，对 `cc.sefan.pw` 判定 direct（主站确实通），
但页面依然白屏 —— 因为它依赖 `cdn.staticsfile.org` 上的 jQuery。

```
cc.sefan.pw 主站 173.242.115.69        → 直连 200（通的）
cdn.staticsfile.org 47.239.100.208     → 走代理 000（不通）
页面 console: ERR_CONNECTION_CLOSED + ReferenceError: $ is not defined
```

**「主站能打开」不等于「页面能用」**。现在分诊会抓页面、抽出
`src=`/`href=` 里的外部域名，逐个分诊它们的 IP。

**二、探测 IP 必须带正确 SNI**

直接 `curl https://1.2.3.4/` 不带 SNI，很多 CDN 会回
`tlsv1 alert internal error`（SSL alert 80）→ 被判「链路不通」，
而实际上带 SNI 完全正常。实测（`47.76.188.58`，已加入 china 直连）：

| 方式 | 结果 |
|---|---|
| `https://IP/`（无 SNI） | `000` |
| `--resolve DOM:443:IP https://DOM/` | **`301`** |
| `-H "Host: DOM" https://IP/` | `000`（Host 头不参与 TLS） |
| `openssl` 无 SNI | `alert 80` |
| `openssl -servername DOM` | `CONNECTION ESTABLISHED` |

所以探测一律用 `--resolve` 带域名做 SNI，不直接打 IP。

**三、性能：串行 41 秒 → 并发 16 秒**

| 阶段 | 12 目标耗时 | 单 dead 域名 |
|---|---|---|
| 初版串行 | 41.0s | 12.7s |
| 8 并发 | 32.4s | — |
| + 限 MAX_PROBE_IPS=3 | 21.1s | 8.9s |
| + 限 MAX_PROBE_IPS=1 | **16.3s** | **3.7s** |

`MAX_PROBE_IPS=1` 的依据：同一域名的 A 记录由同一个 GSLB 下发，
通常落在同一机房、同一套策略上，试 1 个就能判断链路通不通。
若某域名确实「部分 IP 通、部分不通」，判成 dead 后下一轮 cycle
会重新分诊（记录可覆盖），不会永久卡死。

#### 与现有改道通道的关系

| 机制 | 作用域 | 谁写 |
|---|---|---|
| `watch.servers` | 只管**观测列表**（默认 8 个种子域名）的 DNS 走哪个 dnsproxy 实例 | `dc_health_cycle` 按健康探测结果 |
| `china` / `blacklist` 集合 | 管**所有流量**的 TCP 走直连还是代理 | `dnschain-triage` 按实测结论 |

两者独立。分诊靠后者生效 —— 这就是为什么 `cc.sefan.pw` 不在
watch 列表里也能修好。

`dc_gen_watch_servers` 里加了分诊结论优先：有分诊记录的域名按
实测结论写上游，无记录的仍按原逻辑（不能让未覆盖的域名失去
健康检测与自动改道能力）。

#### 持久化

记录写在 `/etc/dnschain/`：

```
triage-ip.list       <IP>|<direct|proxy|dead>
triage-domain.list   <域名>|<domestic|foreign|dead>
```

`china` / `blacklist` 由上游 SSR-Plus 每次 start 时 `flush set` 重建，
增补的元素会被清掉。故两处重放：

- `dnschain-reconcile` 每轮收敛重放（实测：清掉后立刻 `000`，重放后 `200 / 114541`）
- `99-zz-dnschain` 首刷阶段重放一次

#### 页面新增

「操作」小节加按钮「**立即分诊未知目标**」，调 `dnschain-triage run`。

#### 验证（路由器实测）

| 项目 | 结果 |
|---|---|
| `cc.sefan.pw` | **200 × 3/3** |
| `cc.sofan.biz` | **200 × 3/3** |
| `kn.btlms.org` | **200 × 3/3** |
| `cdn.staticsfile.org/jquery.min.js` | **200 / 114541 B** |
| 分诊记录 | 10 条，全部 direct |
| 持久化闭环 | 清空 → `000` → 收敛器重放 10 条 → `200` |

回归：

| 项目 | 结果 |
|---|---|
| `www.baidu.com` | 200 |
| `www.google.com` | 302 |
| `github.com` | 200 |
| `www.youtube.com` | 200 |
| `dnschain-selftest` | `PASS=20 FAIL=0` |
| `dnschain-health cycle` | 11.4s（含分诊） |

断言：

```sh
sh tools/verify-dnschain-domains.sh       # 131 OK / 0 FAIL
python tools/check-dnschain-lua.py        # PASS=133 FAIL=0
python tools/extract-dnschain-i18n.py     # 435 条无缺失
sh -n 全部 4 个改动脚本                   # OK
```

#### 改动范围

```
A files/usr/bin/dnschain-triage
M files/usr/share/dnschain/dnschain.sh
M files/usr/bin/dnschain-reconcile
M files/etc/uci-defaults/99-zz-dnschain
M package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua
M package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua
M package/luci-app-dnschain/po/zh-cn/luci-app-dnschain.po
M .gitattributes
```

#### 已知边界

- 分诊只**增补**集合，不删除用户已有的任何元素或数据库行。
- `MAX_SUBS=6`：一个页面最多分诊 6 个子资源（防止引用几十个外部域的
  页面拖死分诊）。超出部分不处理，但不影响已处理的那些落库。
- `MAX_PROBE_IPS=1` 的取舍见上文；异常域名判 dead 后下一轮会重试。
- 分诊在 `dc_health_cycle` 的**锁外**执行 —— 它要发真实 HTTP 请求，
  持锁跑会把下一轮 cycle 全挡掉。

---

## [v0.15.3] - 2026-10-24

### `dnschain-health status` 1070ms → 210ms（降 80%）

用户同意后实施的第二项性能优化。**输出逐字节不变**，已在路由器实测。

> 三个版本的正文按实际改动顺序排列：v0.15.1（网格布局）→ v0.15.2（容器框）
> → v0.15.3（本段，status 性能）。三处改动共同解决了用户报的
> 「改道状态思维导图显示不足 / 没有框」与「页面打开慢」。

#### 根因比预估更严重

`cmd_status` 对每个观测域名调了**三次** `dc_domain_class`：

- `cls` 一次
- `pref` 经 `dc_domain_preferred` 再一次
- `custom` 经 `dc_domain_custom` 再一次

8 个域名 × 3 = **24 次全表扫描** ≈ 880ms。

⚠️ **同时纠正一处此前的错误判断**：`dc_domain_class` 扫的是
`db-domains.txt`（348KB / 23715 行），**不是** `dnschain-split.conf`
（2MB / 47434 行）。后者是 dnsmasq 片段，不参与归属判定。

#### 改法

| 函数 | 改动 |
|---|---|
| 新增 `dc_domain_class_batch` | 批量归属判定。先收集全部域名与候选后缀，用**三次** `grep -Fxf` 拿全部命中（自定义国内 / 自定义国外 / 数据库各一次），之后优先级判定全在纯 shell 里做。24 次扫描降到 **1 次**，实测 50~60ms。**不排序**，顺序与输入一一对应（status 依赖该顺序保证行序稳定） |
| 新增 `_dc_set_has` | 纯 shell 判断域名是否在换行分隔集合里。两侧补换行做**整行**匹配（`163.com` 不命中 `www.163.com`），`case` 里带引号展开按字面匹配，域名里的 `.`/`-` 不当通配。不 fork |
| 新增 `dc_domain_valid_norm` | 把校验主体与归一化拆开。`dc_domain_valid` 保留原签名（内部仍归一化再调 `_norm`），外部调用方零改动 |
| `dc_domain_normalize` | 原 `sed \| sed \| tr` 三命令管道（**3 次 fork**，单次 2.5ms）→ POSIX 参数展开去首尾空白 + 去一个尾部点 + 保留 `tr` 转小写。转小写仍用 `tr` 不用 `${s,,}`（后者是 bash 4 专有） |
| 新增 `dc_health_prime` / `dc_health_prime_invalidate` | 可选预加载：整份 `health.state`（几百字节、十几行）读进变量，之后 `dc_health_read` 在内存里查。**不 prime 时行为与原来完全一致**（走 awk），故 cycle / explain / 页面等调用点无需改动。`dc_health_upsert` 写完状态文件后调 invalidate |
| 新增 `_dc_field` | 纯 shell 取第 n 个字段，语义与 `awk -F'|' -v n=N '{print $n}'` 逐字节一致（含字段不足时输出空行） |
| `dc_health_field` | 从「2 次 fork（awk 找行 + awk 取字段）」改为「1 次查表 + 纯 shell 取字段」 |
| `dc_domain_class` | 仅改为复用 `dc_domain_valid`（**故意不换成 `_norm`**），见下方警告 |
| `cmd_status`（`dnschain-health`） | 改为「一次批量判定 + 一次预加载」。循环前 `classes=$(dc_watch_list \| dc_domain_class_batch)`；`pref` 由 `cls` 内联推导（`custom-foreign\|db-foreign` → foreign，其余 → domestic），与 `dc_domain_preferred` 定义相同；`n_custom` 由 `cls` 内联判定，与 `dc_domain_custom` 定义相同 |

**⚠️ 一处必须保留的旧行为**：`dc_domain_class` 会**二次归一化** ——
输入 `a.b..` 时 `$d="a.b."`，校验内部再归一化成 `"a.b"` 判为合法。
批量版精确复刻了这条路径。若「顺手清理」成 `_norm`，行为会变，
而 `dc_watch_list` 确实可能产出 `a.b.`。

#### 实测数据

`status` 耗时（同一台路由器，各 5 次取中位数）：

| | 第 1 轮 | 第 2 轮 | 中位数 |
|---|---|---|---|
| 改前 | 1060~1110ms | 1060~1070ms | **1070ms** |
| 改后 | 210~220ms | 210~220ms | **210ms** |

整页耗时：

| | 改前 | 改后 |
|---|---|---|
| 冷启动（清 selftest 缓存） | 3280~3720ms | **2570~2650ms** |
| 热启动（selftest 已缓存） | 2650ms | **1840~1860ms** |

#### 验证

**逐字节输出一致**（三层比对）：

1. 旧库+旧 health vs 新库+新 health vs 新库+旧 health，三者输出 md5
   全部为 `bcb90c64ccb1580b6c27bd4019ee4d1e`，`cmp` IDENTICAL。
   第三项同时证明**新库对旧 health 完全向后兼容**。
2. 批量 vs 逐个归属判定：8 个域名逐行 `SAME=8 DIFF=0`；
   反向验证（故意用错数据）能检出 8 处 DIFF，证明比对有效。
3. 沙箱端到端 8 场景：空自定义全 OK / 自定义非空 / 混合五档 /
   部分域名无状态 / 状态文件不存在 / 空状态文件 / db-domains 缺失 /
   观测列表为空 —— 全部 SAME。

**断言**：

```sh
sh tools/verify-dnschain-domains.sh       # 131 OK / 0 FAIL
python tools/check-dnschain-lua.py        # PASS=133 FAIL=0
python tools/render-dnschain-diagrams.py  # PASS=48 FAIL=0
python tools/extract-dnschain-i18n.py     # 432 条无缺失
```

**路由器实测**：`status` 210~220ms，输出与部署前逐字节一致；
整页连续 3 次 HTTP 200；自检 `PASS=20 FAIL=0 SKIP=0`；
端口 `:5353`/`:5336`/`:1234` 各 1、`:5335` 无监听；国内外解析正常；无错误日志。

#### 发现但未改的性能问题（记录备查）

1. `dc_health_cycle` 没有 prime 状态文件，每轮 8 域 × 5 次 awk 读盘。
   没改的原因：cycle 在循环体里会 `dc_health_write`（每次写都 invalidate），
   语义上需要「每次读到最新」，要改得重新设计缓存粒度。
2. `dc_gen_dnsmasq_split` 对 23715 条做两遍 `sed` 全量扫描（一遍 `server=`、
   一遍 `nftset=`）。属 `apply`/`reconcile` 路径，不在页面关键路径上。
3. `dc_exclude` 的 `grep -Fvxf` 每次全量扫 23715 条，
   `dc_gen_dnsmasq_split` 里串行调了两次。
4. `explain` 仍是 930~1320ms —— 内部要做真实 DNS 探测（两条链各一次），
   属必要成本，不是可优化的量化误差。

---

## [v0.15.2] - 2026-10-24

### 改道状态思维导图：域名清单补容器框（视觉缺陷）

**问题**（用户第二次反馈）：v0.15.1 把域名清单改成多列网格后，
**域名只是悬在空白里的文字，没有容器**。左侧「正常」框有边框有底色，
右侧 8 个域名什么都没有，看起来像「框丢了」，也不像「从状态框引出的清单」。

**改法**：给清单区补一个浅底细边矩形：

```
<rect x="405" y="30" width="481" height="40" rx="7"
      fill="var(--dc-surface)" stroke="var(--dc-ok)"
      stroke-width="1.5" stroke-opacity="0.45"/>
```

三个设计要点：

| 要点 | 取值 | 理由 |
|---|---|---|
| 描边色跟随该档语义色 | `--dc-ok` / `--dc-warn` / `--dc-bad` / `--dc-idle` | 「正常」档绿框、「双链故障」档红框，与左侧状态框一致 |
| `stroke-opacity="0.45"` | 淡描边 | 清单是次要信息，不该和状态框抢视觉权重 |
| 内边距 6 → 10px | `LIST_PAD` | 有框后文字需离边框更远才不显拥挤 |

高度按实际用到的行数算（8 个域名 4 列 2 行 → `h=40`；「（无）」档 1 行 → `h=26`）。

改后视觉链路完整：

```
┌─────────┐      ┌──────────┐      ┌──────────────────────────────┐
│改道状态 │──┬──→│  正常    │─────→│ github.com  www.163.com  ... │
│观测 8个 │  │   │ 8 个域名 │      │ www.qq.com  www.taobao.com   │
└─────────┘  │   └──────────┘      └──────────────────────────────┘
             │   ┌──────────┐      ┌──────────────┐
             └──→│ 双链故障 │─────→│   （无）     │
                 │ 0 个域名 │      └──────────────┘
                 └──────────┘
```

**顺带修掉的断言缺陷**：清单容器本身也是 `<rect>`，原断言取
「所有 rect 的最大右缘」会把它误当成状态框，导致「8 个域名未分栏」误报。
现在按宽度区分（小于画布一半的是状态框/根框，其余是清单容器）。

**路由器实测**：清单容器 `x=405 w=481`，右缘 886 < 900；
`stroke-opacity="0.45"` 存在且颜色随档位（ok/bad）；
域名坐标 x=415/533/651/769，4 列 × 2 行；页面连续 3 次 HTTP 200。

---

## [v0.15.1] - 2026-10-24

### 改道状态思维导图：域名清单改多列网格（「显示不足」）

**问题**（用户第一次反馈，截图可见）：原实现把域名用「、」串成若干行。
8 个域名挤成 3 行，**第三行只剩 `www.youtube.com` 一个（占 91px），
右侧空出 252px**，同时前两行又逼近右边界 —— 既浪费空间又显得「没显示全」。

实测（画布 760 宽、清单区可用 335px）：

```
行1 右端=734 留白= 20   github.com、www.163.com、www.baidu.com、www.google.com
行2 右端=681 留白= 73   www.qq.com、www.taobao.com、www.wikipedia.org
行3 右端=502 留白=252   www.youtube.com        ← 只剩一个，右侧空 252px
```

**改法**（不是简单加宽画布 —— 那只是把问题推到更长的域名上）：

| 改动 | 说明 |
|---|---|
| 画布 760 → **900** | 给清单更多横向预算 |
| 「、」串接 → **多列网格** | 每格一个域名；先按最宽的算列宽，再按可用宽度均分列数 |
| 按**列宽**截断 | 单个域名超宽时按列宽（不是整行宽）截断补 `…` |

改后（4 列 × 2 行，均匀铺满）：

```
x=411 y=44  github.com        x=533 y=44  www.163.com
x=655 y=44  www.baidu.com     x=777 y=44  www.google.com
x=411 y=58  www.qq.com        x=533 y=58  www.taobao.com
x=655 y=58  www.wikipedia.org x=777 y=58  www.youtube.com
```

最右 867 < 900，无溢出。

**新增 4 条防回归断言**，其中关键的一条：

> 只查「是否分栏」不够 —— 760 宽时旧逻辑也能折成 2~3 行，
> 真正的判据是「每行右端留白不能超过一整列宽」。

区分能力已验证：旧逻辑在 760 宽下第 3 行留白 252px，会被抓住。

---

## [v0.15.0] - 2026-10-23

### DNS 链路页：移除导图箭头、合并概览与诊断、新增实时诊断导图、冷启动 3960ms → 840ms

用户四项要求，逐项落地。全部改动都有实机验证，不含推测。

#### 一、所有思维导图连线移除箭头

三处独立实现全部改掉，不再生成任何 `<marker>`：

| 位置 | 改动 |
|---|---|
| `diagrams.lua` `hline()` / `curve()` / `vline()` | 删掉 `marker-end` 参数 |
| `diagrams.lua` `defs()` / `arrow()` | **整个函数删除** |
| `general.lua` 内联链路图 `marker()` / `arrow()` | 同样删除，不再输出 `<defs>` |

副作用处理：同页多图的 SVG id 冲突根因消失（marker id 是文档级全局的），
但「同页多图」的前提仍在，故保留 `id_prefix` 参数、改落在无副作用的
`data-dc-figure="<prefix>"` 上（`diagrams.lua:91-94`）。

断言全部改为**反向条件**（不得出现 `<marker` / `marker-end`）：
`tools/render-dnschain-diagrams.py:176`（`check_no_arrows`）、
`tools/verify-dnschain-domains.sh:645-660`、`build-openwrt.yml:414-447`。

⚠️ CI 与 shell 断言必须先剥 Lua 注释行（`grep -v '^[[:space:]]*--'`）再判断 ——
注释里写了「v0.15.0 移除了 marker-end」，不剥注释会让断言永久误报
（本仓库已踩过同类问题，见 `AGENTS.md` 第 6 条）。

#### 二、思维导图查重：删掉重复渲染的那一张

`dg.route_map()` 原本被渲染**两次** —— 概览 tab 的「分流决策」与域名 tab 的
「走法」，是同一函数的两份输出。已删除概览那份。

`tools/check-dnschain-lua.py` 新增断言「判定链路图只由一个 option 渲染」，
统计口径按 option 名去重（该测试脚本会把 `general.lua` 加载两次，
直接数 HTML 出现次数会恒为 2×N）。

#### 三、概览与诊断合并为一页

tab 由 **7 个减为 6 个**，「诊断」不再是独立 tab。`自检` 与 `操作` 两个
section 归入 `overview`，改名「概览与诊断」。

合并时消除的重复：

- 概览的「分流决策」图 = 域名 tab 判定链路图的第二次渲染 → 删除。
- 「结论」徽标与「自检 20 项」表格**不是**重复：同一次 `ds.selftest()` 的
  两种视图（一句话 vs 逐项证据），请求级缓存保证只跑一次，两者都保留。

#### 四、新增「实时诊断链路」思维导图

把自检 20 项**按链路阶段重新分组**，逐段给最差状态、PASS/FAIL/SKIP 计数、
证据串：客户机入口 / dnsmasq / 国内链路 / 国外链路 / 代理与分流 /
分流规则 / fw4 / 双栈与端口。

与已有三张图的职责边界（这是它存在的理由）：

| 图 | 回答什么问题 |
|---|---|
| 解析链路 | 组件在不在、端口是否监听 |
| **实时诊断链路** | **哪一段真的通、断在哪、证据是什么** |
| 判定链路 | 某个域名按规则会怎么走 |
| 改道状态 | 哪些观测域名当前被改道 |

**零新增后端调用** —— `ds.selftest()` 已被「结论」徽标调用过，缓存命中。

#### 五、冷启动性能：3960ms → 840ms（降 78%）

实测（同一台路由器、每次清 `/var/run/dnschain/selftest.cache` 后跑 `-f`）：

| | 第 1 次 | 第 2 次 | 第 3 次 |
|---|---|---|---|
| 改前 | 2830ms | 2850ms | 2860ms |
| 改后 | 1080ms | 860ms | 840ms |

20 项判定逐项比对 **IDENTICAL**（`cmp` 只比 `序号|状态|项目名`），
`SUMMARY PASS=20 FAIL=0 SKIP=0` 两版一致。证据串唯一差异是
`www.google.com` 返回的真实 IP（142.251.153.119 vs 142.251.151.119），
属上游轮换，非脚本行为变化。

**最大发现：`dc_run_timeout` 的等待粒度是隐藏成本**

原实现「每转 2000 次就 `sleep 1`」，而 2000 转实测仅约 20ms ——
于是**任何耗时落在 20ms~1020ms 的命令都被向上取整到约 1070ms**。
item 10 的 1070ms 里只有约 500ms 是真实网络往返，另外约 530ms 是纯量化误差。

改用 `/proc/uptime` 毫秒时钟（纯 shell、无 fork），紧密轮询 1200ms 后才按需
`sleep`。超时语义、`.done` 完成标记、stdout 0/1 契约全部未动
（硬约束第 18/19/44 条）。实测 `dc_run_timeout` 1/2/3 秒对 `sleep 30`
→ 1020/2010/3000ms，精确。

**其余优化**：

| 项 | 原耗时 | 改后 | 做法 |
|---|---|---|---|
| item 18 | 1350ms | 10ms | 8×`grep -qE` → 单次 `grep -oE\|sed\|sort -u\|grep -Fxcf` |
| item 15 | 340ms | 0ms | `-vE` 过滤提到前面 |
| item 2 | 210ms | 20ms | 放后台与其它扫描并行 |
| item 1/8/9/10/11 | 1140ms（串行） | 与本地检查重叠 | 五项探测在开头一起后台启动，第 8 项处 `wait` 收齐 |
| item 13 | 150ms | 10ms | `nft list table` → `nft list tables` |
| item 19 | 120ms | 10ms | 每行 `echo\|sed` → 单次 `sed\|grep -qxF` |
| item 20 | 80ms | 0ms | 每行 4×awk → 单次 awk |
| item 3/4/5/6/13 快照 | 4×netstat + 2×pidof = 138ms | 46ms | 一次 netstat/dnsmasq_pid 快照复用 |
| 指纹 | 约 320ms | 约 60ms | 同快照复用 + `dc_get_list` 4 次 → 2 次 |

**中途抓到并修掉的真 bug**：BusyBox 的 `grep -Fxcf <空文件>` **匹配所有行**
（实测 3 行输入返回 3），而原实现的 `for` 循环在空列表时零次迭代返回 0。
空观测列表会让 item 18 误报 FAIL。已加 `[ -s "$watch_file" ]` 守卫，
并用 6 种边界情形逐条比对新旧实现。

#### 六、页面侧新增样式

`dnschain.css` 加 `.dc-chain--live`：纵向单列、无横向滚动、无 620px 下限
（内容不超 720，窄屏压到 480 仍可读）。

#### 七、补修：DNS 轮询漏掉的 IP 导致再次白屏

审查过程中实测发现：修复完上面三项后，`jquery` 又变 `000`。

**根因**：`cdn.staticsfile.org` 有 **2 个 A 记录**
（`47.239.100.208` / `47.76.188.58`）。分诊在某一刻跑，
只看到当时 DNS 返回的那一个，落库也就只有一个。
之后 DNS 轮询到另一个 IP → 它不在 `china` 集合 → 走兜底规则被送去代理
→ 代理连不上 → 又白屏。

实测复现：

```
47.76.188.58 在 china 集合里，47.239.100.208 不在
nslookup 返回 47.239.100.208
jquery → 000
```

**修法**：`apply` 时对每个已记录域名**重新解析当前 A 记录**，
把没记录过的 IP 按该域名的结论补上。

为什么放在 `apply` 而不是 `run`：`apply` 每轮收敛都跑，能持续跟上
DNS 轮询；而 `run` 要发真实请求，不能高频跑。

实测：删掉 IP → `000` → `apply` 补全 → `200 / 114541`，记录同时回填。

#### 八、验证


```sh
sh tools/verify-dnschain-domains.sh       # 131 OK / 0 FAIL
python tools/check-dnschain-lua.py        # PASS=131 FAIL=0
python tools/render-dnschain-diagrams.py  # PASS=44 FAIL=0
python tools/extract-dnschain-i18n.py     # 432 条无缺失
sh tools/verify-trafficctl-invariants.sh  # 通过
```

实机验证（路由器只读 + 临时覆盖后已完整恢复）：

- 页面 HTTP 200 / 135853 B / 2810ms
- 4 张图各出现 1 次（`data-dc-figure` 前缀 `dcrt-dm`、`dcst` 各 1）
- 6 个 tab，含「概览与诊断」，**无「诊断」**
- 实时诊断图 8 个阶段名全部在页面里
- `marker-end` 与 `<marker` 在页面 HTML 中**均为 0**

#### 八、i18n

新增 8 条中文文案（「概览与诊断」「实时诊断链路」+ 6 个链路阶段名），
已由 `extract-dnschain-i18n.py --write` 追加。PO 由 467 组增至 **475 组**
（1431 行），空 msgstr 仍为 4（文件头与多行续行）。

#### 九、文档联动

`docs/packages/luci-app-dnschain.md`：

- §4.1 表格重写为 6 tab / 19 section，19 行 section 行号全部重新核对
- 新增 §4.1.1「四张图的职责边界」、§4.1.2「连线不画箭头」
- 新增 §3.1.1「冷启动为什么慢：实测拆解」与 §3.1.2「性能优化策略」
  （含 3 条已实施 + 5 条可选 + 1 条不建议做的，各带收益与风险）
- 全文 90 个 `general.lua:NNN` 引用逐条核对，落空 0 个

#### 十、未改动的部分

- `package/luci-app-trafficctl/README.md`（上游原文，红线 9）
- `files/etc/` 下任何文件
- 代码本身只动了 `package/luci-app-dnschain/` 内 4 个文件 +
  `files/usr/bin/dnschain-selftest` + `files/usr/share/dnschain/dnschain.sh`

已知遗留（未修，非本次范围）：

- item 10 证据里的地址在 IPv4/IPv6 间偶发跳变 —— 原版脚本同样会跳
  （`dc_dns_first_addr` 的正则 `[0-9a-fA-F.:]*` 同时匹配 A 和 AAAA，
  而 dnsmasq 双栈返回顺序不定），判定恒为 PASS，不影响结论。
- item 14 的 `fw4 check` 缓存未命中时总耗时会回到约 1.5s —— 原有设计，未改。

---

## [v0.14.9] - 2026-10-23

### 全部文档按代码取证重构：新增 7 份分层文档，更正 6 个 ADR 与 2 份 README

**起因**：用户要求「以当前项目的实际代码和路由配置为唯一依据，逐项核准并更正所有项目文档；
禁止猜测与臆断；每个修改的路由功能必须对应仓库和路由器功能，并都必须实际取证；
严格遵循渐进式披露原则；在各项目文档中明确写清每个对应路由所使用的插件及其作用」。

**做法**：先做取证（仓库代码 + 路由器只读实测），再按「读者要回答什么问题」分层重写。
取证阶段用 4 个子代理并行审计（dnschain 路由、trafficctl 路由、ADR 事实核对、运行时链路），
写入阶段用 4 个子代理按互不重叠的写范围并行，主代理负责路由总表、索引与 `AGENTS.md`。

#### 一、新增文档（7 份，共 2852 行）

| 文件 | 行数 | 内容 |
|---|---|---|
| `docs/README.md` | 98 | **文档入口**。按任务找文档的导航表 + 可核查性约定 + 维护规则 |
| `docs/routes.md` | 180 | **全部 LuCI 路由的唯一登记处**。3 个插件共 12 条路由，逐条给路径/标题/order/action/ACL/声明位置，以及路由器实测的菜单树 |
| `docs/packages/luci-app-dnschain.md` | 613 | DNS 链路页：1 条路由（双通道声明）、7 tab、20 section、页面元素→脚本命令全表、8 个 `dnschain-health` 子命令、11 条 ACL 缺口 |
| `docs/packages/luci-app-trafficctl.md` | 542 | 流量控制页：5 条路由、4 视图、34 个 ubus 方法、23 个脚本、CGI 指标端点、14 条已知不一致 |
| `docs/packages/luci-app-dnsproxy.md` | 470 | DNS Proxy 页：6 条上游路由、3 个 patch 各自改了什么、LAN 拦截的真实生效路径、16 条不一致 |
| `docs/runtime/dns-chain.md` | 389 | DNS 链路运行时：实际链路图、两个 dnsproxy 实例逐参数、preflight 5 条硬校验、procd 3 实例、自检 20 项逐项、10 条内部不一致、7 组实测基线 |
| `docs/runtime/overlay-inventory.md` | 189 | `files/` 全部 20 个文件逐行表、uci-defaults 执行顺序与 6 条覆盖关系、`.gitattributes` 16 条规则、执行位来源 |
| `docs/runtime/constraints.md` | 161 | dnschain 52 条硬约束全表（从 `AGENTS.md` §4.0 外移） |
| `docs/build/ci.md` | 317 | CI 31 步有序清单、38 个显式 `=y` 符号、6 组契约断言约 90 条、4 条已知问题 |
| `docs/operations/verification.md` | 354 | 8 个本地校验脚本实跑结果、路由器只读取证通道、DNS 五分类排障、14 条误判清单 |

#### 二、重写 `GLOSSARY.md`（97 → 305 行）

删除已失效术语（`拒绝集`、`档案`、`策略过滤器`），新增 `分流`、`nftset`、`watch.servers`、
`health.state`、`vendored 包`、`patch 重放`、`uci-defaults`、`ujail`。
每条术语给定义 + 代码落点（`路径:行号`）+ 反例（易混词）。
组件角色按现状重写：dnsmasq 是**唯一**缓存与**唯一**分流层；两个 dnsproxy 实例都不缓存；
mosdns 只在 `pdnsd_enable=4` 时存在、不在默认链路；SSR-Plus **IPv4 与 IPv6 都代理**。

#### 三、更正 6 个 ADR（共 75 条断言）

按「已失效标注 / 行号更正 / 事实更正」三类处理，原文保留 + 标注失效原因 + 写清现行事实：

| ADR | 原行数 | 现行数 | 改动 |
|---|---|---|---|
| `0001-filter-aaaa-semantics.md` | 27 | 178 | 状态改 `superseded`。原「仓库值取 `'1'`」错：实际 4 个写入点最终生效 `'0'` |
| `0002-no-ipv6-proxy.md` | 23 | 137 | 状态改 `superseded`。**已被运行时推翻**：`ipv6_support=1` + 实测 10 条 `ss_spec6_*` 链 + `fwmark 0x53535250` → table 999 |
| `0003-dns-chain-framework.md` | 974 | 1071 | 顶部加 §0「已失效断言」对照表（23 行）。更正 `:5335` 语义、国外上游 DoH、UCI 键名、7 tab、20 项自检、`--timeout 8s`、`foreign-split.conf` 而非 `upstreams-domains.txt` |
| `0004-dns-chain-verification.md` | 704 | 1121 | 更正页面路径 `admin/services/dns_chain`、端口集合补 `5336`、`PASS=16`→20、`pidof` 双实例、新增 `dnschain-health` 8 子命令一节 |
| `0005-remove-chinadns-ng.md` | 401 | 551 | 内部矛盾（16/16 vs 20 项）统一为 20；`dns_intercept_lan` 改为「框架启用时不被创建」而非「从来不存在」；国外上游 2 条 DoH |
| `0006-domain-routing-and-reroute.md` | 373 | 603 | UCI 段名 `dom_domestic`/`dom_foreign`；`watch.servers` 实际在 `/var/run/dnsmasq/`；补 `dnschain-health explain` 的 12 个输出键 |

#### 四、更正 2 份 README

- `patches/luci-app-trafficctl/README.md`：「五个 patch」→ **六个**（补 `0006-remove-telegram.patch`
  的完整说明小节）；「实际需要 425 条」→ 实测 pot 376 / po 502 并说明 124 条孤儿 msgid 来源；
  「设备 \| 设置 \| Telegram机器人 \| 端口转发」→ 现为三项（Telegram 已全链路移除）。
- `CHANGELOG-archive.md`：第 2 行标题块、`---` 与 `## [v0.2.0]` 三者被压成一行，
  导致 `v0.2.0` **没有标题**、22 个归档锚点全部指向不存在的目标。已拆行修复。

#### 五、`AGENTS.md` 精简（65602 → 48937 字节）

原文件已超 65536 字节工作区指令预算、被系统截断。处理：

- §4.0 的 52 条硬约束全表（11658 B）→ 外移到 `docs/runtime/constraints.md`，
  `AGENTS.md` 保留「最容易踩的 8 条」+ 指针。
- §1 仓库地图补 `docs/` 与 `GLOSSARY.md` 两行。

#### 六、更正 `AGENTS.md` 内 4 处失实断言

| 位置 | 原文 | 实际 |
|---|---|---|
| §4 引言 | 「框架自持 chinadns-ng 策略过滤器」 | v0.10.0 已移除；改为「dnsmasq 唯一缓存+分流，dnsproxy 两实例」 |
| §4 验证命令 | `:5335 应属 chinadns-ng` | `:5335` 应**无监听**；补 `5336` |
| §4.4 | 「IPv6 侧只有 DNS 重定向，国外 IPv6 直连」 | **IPv6 也代理**（10 条 `ss_spec6_*` + fwmark 策略路由） |
| §5.1 | 「当前 `filter_aaaa='1'` 已精确实现，不要改动」 | 最终生效 `'0'`；4 个写入点表格已补 |
| §9 | 「`applechina.conf` 175 行」 | **173 条 `server=`**（全文 191 行，18 行注释） |

#### 七、补记两个漏写的版本段

`v0.14.6`（`f54ae36`）与 `v0.14.7`（`97b826f`）已打 tag，但 CHANGELOG 里没有对应段 ——
`release.yml` 的 `grep -nF "## [$VER]"` 对这两个 tag 会 `exit 1`。已按 git 记录补记，
并更正 v0.14.7 对照表里三行与代码不符的结论（P0-1 无整形 / P2-7 不设 `ra_mtu` /
P2-8b 改幂等 —— 三条都与实际相反）。

#### 八、复核确认的数字

全部实跑复核，未采用任何文档里的旧数字：

```sh
sh tools/verify-dnschain-domains.sh       # 129 OK / 0 FAIL
python tools/check-dnschain-lua.py        # PASS=121 FAIL=0（需 PYTHONIOENCODING=utf-8）
python tools/render-dnschain-diagrams.py  # PASS=44 FAIL=0
python tools/extract-dnschain-i18n.py     # 426 条无缺失
python tools/check-trafficctl-i18n.py     # 376 / 502 / 376，缺 0
```

⚠️ 同时确认：**只有 `verify-dnschain-domains.sh` 被 CI 调用**
（`build-openwrt.yml:449`）。另外四个是纯本地工具，`build-openwrt.yml` 里零调用点 ——
「CI 会拦住」这个假设对它们不成立。

#### 九、本次未改动的部分（有意为之）

- `package/luci-app-trafficctl/README.md` 是**上游原文**，其中 5 处指向上游 `docs/API.md`
  等文件的链接在本仓库不存在。这是上游包不带文档所致，不是本仓库的断链，
  改了会让 patch 重放与上游不一致（`AGENTS.md` 红线 9）。
- 代码本身零改动。本次只改文档，`git diff --stat` 里没有任何 `package/`、`files/`、
  `patches/*.patch`、`.github/` 文件。

---

## [v0.14.8] - 2026-10-23

### 修复 dnsmasq 日志全部丢失（审计 P2-13）

**症状**：`dhcp.@dnsmasq[0].logqueries=1`（在记录），但
`logread | grep -c 'dnsmasq\['` **恒为 0** —— 日志一条都没出来。

**根因**（实测）：
1. 上游 `99-default-settings:59-60` 每次构建执行
   `sed -i '/log-facility/d' /etc/dnsmasq.conf` 再
   `echo "log-facility=/dev/null" >> /etc/dnsmasq.conf`
2. 生成的 `/var/etc/dnsmasq.conf.*` **第 2 行是 `conf-file=/etc/dnsmasq.conf`**
   → 那行被加载 → 日志写进 `/dev/null`
3. 进程的 stdout/stderr 也指向 `/dev/null`（`/proc/<pid>/fd/1 -> /dev/null`）

**三种「看起来对」的修法都失败，已逐一实测排除**：

| 修法 | 结果 |
|---|---|
| UCI `dhcp.@dnsmasq[0].logfacility='/dev/log'` | **dnsmasq 起不来**：`illegal repeated keyword at line 13` —— `init.d/dnsmasq:944` 的 `append_parm logfacility` 会再写一条 `log-facility=`，与 conf-file 里的重复 |
| `log-facility=/dev/log`（直接改文件） | **起不来**：`cannot open log /dev/log: No such device or address` —— 该 socket 存在但 ujail 沙箱未挂载 |
| `log-facility=/tmp/dnsmasq.log` | 能启动，但**不写文件**（沙箱只允许白名单路径），日志照样丢 |
| **`log-facility=syslog`** | **可用**：正常启动，日志进 logread |

实测 `syslog` 方案：发 2 次查询后 `logread` 新增 30~36 条，含完整查询详情
（`dnsmasq[1]: 10 192.168.3.238/54385 reply xxx is <CNAME>`）。

**修法**（两处，互为保险）：
1. `files/etc/uci-defaults/99-gaming-optimize` 新增 §6.9：幂等改成 `syslog`
2. `files/usr/bin/dnschain-reconcile` 的 `reconcile_invariants` 每次收敛校正
   （uci-defaults 只在刷机后跑一次，之后可能被上游覆盖）

收敛器只在**真正改动过**时才重启 dnsmasq（`DNSCHAIN_LOG_CHANGED` 标记），
避免每轮都断一下。

**实测验证**：
- 幂等：连跑 2 次仍只有 1 行 `log-facility=syslog`
- 自愈：手动改回 `/dev/null` → 跑收敛 → 自动改回 `syslog` 并重启
- 第二次收敛无改动（`:53` 保持 10 个 socket，自检 20/20）
- 页面响应无退化（开日志 2.133s / 关日志 2.168s，三次均值一致）
- 日志增长温和：30 秒约 27 行，128KB 缓冲区可存约 2 小时，其他服务日志仍在

**applechina.conf 一并核实**：仓库 overlay 里 175 行指向 `127.0.0.1#5353`，
唯一含 `114.114.114.114` 的是注释（说明历史）。`apple_dns` 保持为空 ——
这是正确做法（设了会因 `grep -oE` 丢端口而叠成 `127.0.0.1#5353#5353`）。

**断言**：新增 4 条契约断言（129 条），含反向断言禁止改用 UCI `logfacility`。

### CHANGELOG 归档

23 个**已打 tag 发布**的旧版本（v0.12.5 及更早）详细内容移到
`CHANGELOG-archive.md`，主文件对应位置留一行摘要 + 指针。

- 主文件 316632 → 249245 字节
- 归档 70220 字节
- **不丢信息**：完整正文都在归档文件里
- **不破坏发版**：`release.yml` 的 `grep -nF "## [$VER]"` 对 23 个 tag 版本
  逐个实测，**全部仍能定位**（归档不动的版本 v0.13.x/v0.14.x 也照常）

---

## [v0.14.7] - 2026-10-23

### 审计报告补「现状对照」表 + 说明上游 README 断链

> ⚠️ **本段是事后补记**：该版本已打 tag（提交 `97b826f`），但当时漏写 CHANGELOG 段。
> 补记时一并更正了原提交里两处失实结论，见下方「⚠️ 事后更正」。

**一、审计报告加现状对照表**

`docs/audit/2026-10-09-network-audit.md` 是 2026-10-09 的一次性快照，正文保持原样
（那是当时的实测记录），但在开头加了一张对照表，标注 19 项在**当时 HEAD** 的状态。

**二、说明上游 README 的 5 处断链**

`package/luci-app-trafficctl/README.md` 里有 5 处链接指向 `docs/API.md` /
`docs/ARCHITECTURE.md` 等，在本仓库不存在。核实：这是**上游原文**（升级到 1.21.4
时就有，上游包里不带这些文档），不是本仓库的断链。**不要改它** —— 改了会让 patch
重放与上游不一致。已写入 `AGENTS.md` 红线 9。

**⚠️ 事后更正（v0.14.9 复核时发现）**

该提交的对照表里有三行与代码不符，已在 v0.14.9 的文档重构中更正：

| 当时的结论 | 实际 | 证据 |
|---|---|---|
| P0-1「上行 50 Mbps 无整形 —— 仓库无 tc/qdisc 配置」 | **已有 cake 整形** | `files/etc/config/sqm:34-55`（`download 900000` / `upload 45000` / `qdisc cake` / `script piece_of_cake.qos`）；CI 也在 `build-openwrt.yml` 里显式启用 `sqm-scripts` |
| P2-7「仓库不再设 `ra_mtu`」 | **仍在设** | `files/etc/uci-defaults/99-gaming-optimize:221` `uci set dhcp.lan.ra_mtu='1492'` |
| P2-8b「MSS clamp 改为幂等追加」 | **整段已删除**，不是改幂等 | `99-gaming-optimize:118-152` 是「已移除（2026-10-10）」的说明块；`files/etc/firewall.user` 在仓库里根本不存在 |

另有一处 P2-13 的处置建议写「正确做法是 UCI `dhcp.@dnsmasq[0].logfacility`，**待批准**」，
但该做法已实测失败（`illegal repeated keyword`）—— 见 v0.14.8 段的三方案排除表。
真正可用的是 `log-facility=syslog`，v0.14.8 已落地。

---

## [v0.14.6] - 2026-10-23

### 严格核对 + 精简全部 markdown，修复 CHANGELOG 版本段结构

> ⚠️ **本段是事后补记**：该版本已打 tag（提交 `f54ae36`），但当时漏写 CHANGELOG 段。

**一、[严重] CHANGELOG 有 7 个版本段没有顶层标题 → 发版必失败**

`release.yml` 用 `grep -nF "## [$VER]"` 定位版本段，找不到即 `exit 1`。
实测 v0.14.0 ~ v0.14.5 与 v0.13.2 **全部找不到** —— 它们被写成 `####` 四级标题，
嵌套在 `## [v0.13.0]` 段内部（这也是该段膨胀到 62KB 的原因）。
且 §十八~§二十一 在文件里是倒序（二十一、二十、十九、十八）。

修法：拆成 7 个独立顶层版本段，按版本号倒序排列，`####` 降为 `###`。
用 `release.yml` 的原命令实测提取：

```
v0.14.5 start=6   end=79    3216 B
v0.14.4 start=80  end=243   9747 B
v0.14.0 start=622 end=721   5510 B
v0.13.0 start=801 end=1116 19760 B
```

全部正确，且不吞并相邻版本。特征串逐版本比对，内容零丢失。

**二、[严重] AGENTS.md 超 65536 字节硬预算（89823 → 62018）**

超预算会被系统截断，末尾内容读不到。按占比精简：

- 红线第 9 条（trafficctl，18170 B，占 §2 的 84%）→ 外移到
  `patches/luci-app-trafficctl/README.md` 的「本地改动清单」一节，
  `AGENTS.md` 留六项摘要 + 指针。红线效力不变。
- §9 当前未决/风险（13397 → 2588）：16 条里 11 条标着「已解决/已处理」，
  属历史归档 → 压成一张归档表，只留 4 条真正未决的。

**三、[核对] 断言数与文档一致性**

实际：契约 126、Lua 121、图示 44、i18n 426、自检 20。
`AGENTS.md` 有 3 处写「121 条契约断言」→ 改为 126。

CHANGELOG 里的历史数字（163/17/16/13 条等）**不改** —— 那记录的是当时的状态。
`docs/adr/0005` 的「16 项自检」同理保留（描述 v0.9.0 时代）。

---

## [v0.14.5] - 2026-10-23

### 落实度复查：修 v0.14.4 未真正生效的修复 + 补审 CSS/config

### 落实度复查：修 v0.14.4 未真正生效的修复 + 补审 CSS/config（v0.14.5）

按要求复查「全链路检查是否完全落实」。逐项核验后发现 **v0.14.4 的 M2 修复
并未真正生效**，另有两处此前未系统审查的区域（CSS 变量、config 键一致性）。

##### 一、[严重] `dc_ssr_mode_for_profile` 改对了逻辑但**写错了 section 名**

v0.14.4 的 M2 把「读不存在的 `main.profile`」改成「读 `ssr.mode`」，
但配置文件里是 **`config ssr 'compat'`** —— 类型是 `ssr`、**名字是 `compat`**。
`dc_get <name> <option>` 走 `uci get dnschain.<name>.<option>`，
所以 `dc_get ssr mode` 查的是「名字为 ssr 的 section」，它不存在 →
恒返回空 → 恒走兜底 `"0"`。

**即 M2 修复后，页面选「7 — 模块内置 DNS」仍然被静默推翻。**

实测证据：
```
uci get dnschain.ssr.mode    = （空）
uci get dnschain.compat.mode = 7
compat.mode=7 → dc_ssr_mode_for_profile 返回 0   ← 修复前
compat.mode=7 → dc_ssr_mode_for_profile 返回 7   ← 修复后
```

同一错误还有两处（reconcile 一直读不到，恒用默认值 1）：
- `enforce=$(dc_get ssr enforce 1)`
- `if [ "$(dc_get ssr require_ipv6 1)" = "1" ]`

修法：三处全部改为 `dc_get compat ...`。
新增 5 条契约断言锁住（含「禁止出现 `dc_get ssr <opt>`」的反向断言）。

> 教训：**`dc_get` 的第一个参数是 section 名，不是类型**。
> 本仓库已有同名坑（`config upstream 'cn'` 必须写 `dc_get cn ...`），
> 这是第二次踩 —— 已在断言里对 `ssr.*` 三处加反向守卫。

##### 二、[中等] CSS 存在无效自定义属性值

```css
--dc-fg-muted: opacity: 0.65;
```

自定义属性里不能放 `opacity: 0.65` 这种**声明**，浏览器会把它当字符串；
真有人 `var(--dc-fg-muted)` 当 opacity 用时得到无效值。
且 `--dc-fg` 与 `--dc-fg-muted` **全文件零消费者**（Lua/JS 也未引用）。

修法：删掉两个变量并写明理由。弱化文字直接用 `opacity` 属性，不绕变量。
复查后 CSS 的 18 个变量全部有定义、无悬空引用。

##### 三、[核查] config 47 个键的消费者覆盖

逐键核对 `config` 里 47 个 option/list 的 shell 消费者：

| 类别 | 数量 | 状态 |
|---|---|---|
| 有消费者 | 34 | 正常 |
| list 类型（无值时为空） | 3 | 正常（`dom_*.domain` / `health.watch`） |
| 有兜底的不存在键 | 1 | `main.profile`（旧配置兼容，代码有默认值） |
| 已在页面标注「仅作记录」 | 9 | 正常 |

即除本次修的 3 处外，没有发现新的「配了不生效且无提示」的键。

##### 四、复测

```
本地：dash 8/8、shell 90+23、lua 121、图示 44、契约 126（新增 5）、
      i18n 426、CI 模拟通过
路由器：selftest 20/20、:53/:5353/:5336 全 OK、nftset=23714、
        ss_spec=2、:1234=1、cycle ok=8、零泄漏零残留
        页面 HTTP 200、157KB、SVG 4、marker 0 重复、Lua 报错 0、响应 2.14s
        compat.mode=7 → dc_ssr_mode_for_profile 返回 7（修复前恒 0）
```
## [v0.14.4] - 2026-10-23

### Lua 层深审：6 项严重 + 9 项中等 + 9 项轻微缺陷修复

### Lua 层深审：6 项严重 + 9 项中等 + 9 项轻微缺陷修复（v0.14.4）

对 4 个 Lua 文件（3595 行）做第三轮审查，逐条用 lupa（真实 Lua）实测验证。
**24 项报告里 3 项经实测不成立**，未作改动（见末节）。

##### S1 [严重] selftest 名称解析用 `[^—]`，20 项里 7 项失败

```lua
local name, detail = rest:match("^([^—]+)—%s*(.*)$")
```

Lua 的字符类按**字节**工作。`—`(U+2014) 的 UTF-8 是 `E2 80 94`，
写进 `[^—]` 后实际是「排除 E2、80、94 三个字节」。凡名称含
`一`(E4 B8 80)、`上`(E4 B8 8A)、`下`(E4 B8 8B) 等第三字节为 0x80 的
常用汉字，匹配**直接失败**。

实测 10 个真实 emit 名称：**7 个失败**（整行进 name、detail 为空），
3 个「半失败」（name 尾随一个空格）。失败的包括「缓存层唯一」
「端口所有权无冲突」「改道通道已就绪」—— 诊断页最该看清的几项，
而 `#items` 仍是 20、`total` 正确，看起来一切正常，只是内容错位。

修法：改用 `find(sep, 1, true)` 做**字节精确**匹配（分隔符是 5 字节的
`" — "`），找到后按字节位置切。实测 10/10 正确、无尾随空格。

##### S2 [严重] `upstream_port` 把 IPv6 末段当端口

```lua
local port = hostport:match(":%[?([0-9]+)%]?$")
```

实测：
```
https://[2606:4700::1111]/dns-query  → 1111（应 443）
tls://[2400:3200::1]                 → 1   （应 853）
```

后果：`validate_upstreams` 拿这个假端口比对 `ss_spec_output` 端口集。
不在集合里 → 保存被拒且提示「端口 1111 不在…」，用户看不出问题在哪；
恰好在集合里 → 该上游被误判合规，实际出向不走代理，国外解析静默失败。

修法：IPv6 的端口只可能出现在 `]:` 之后，先判 `^%[` 再分别取。
实测 7/7 正确。

##### S3 [严重] `status_map` 静默丢弃未知 state，行数不守恒

`local st = r.state or "unknown"` 只兜 nil。空串与任何未知值
（如脚本将来新增 `probing`）会落进 `groups` 里一个**不在 `STATUS_ORDER`
中**的键，而 `present` 只遍历 `STATUS_ORDER`、`n_all` 也只累加那些组
—— 这些行被**静默丢弃**。

实测：3 行（`ok` / `""` / `weird-state`）只画出 1 个域名，
根节点也写「观测 1 个」。看起来像「只有 1 个域名需要关注」，无任何提示。

修法：`normalize_state()` 把未知/空值统一归入 `unknown` 档，保证
「画出的行数 == 输入行数」。实测 3 行全部进图、计数 3。

##### S4 [严重] `status_layout` 与 `status_map` 口径不同 → CI 验错布局

两处不一致：
1. `status_layout` 用 `pairs(rows)` 数**数据行数**，`status_map` 画
   **状态档位数**（最多 5 档，`both-bad` 恒占一档）
2. `NH` 一个硬编码 60，一个 `math.max(60, 21+16+max_hint_lines*14+8)`

实测（5 档各 1 个域名）：`status_map` 实际 viewBox 高 **386**，
`status_layout` 报 **406** —— 差 20px。`check_note_clearance` 与
`check_text_fits_boxes` 的断言全部基于这份错值。

修法：抽出 `layout_plan(rows)`，由两者共用。实测三种数据形态
（5 档/1 档/6 行 3 档）下高度完全一致（471/216/301）。

##### S5 [严重] 「分流规则条数」取错文件

`stats.domains` 读 `foreign-split.conf`，而那是
「数据库国外 − 自定义国内 − 观测域名」的**纯域名清单**
（`dnschain.sh` 里明确写了「从 v0.13.0 起不再是 dnsmasq 片段」）。
真正的 `server=/域名/` 条数在 `dnschain-split.conf`。

实测加 1 个自定义国外域名后：`foreign-split.conf` 仍 23714，
`dnschain-split.conf` 的 `server=` 变 23715 —— 页面数字偏小，
标签「条 server=/域名/」名不副实。

另有 `M.split_rule_count()` 读的正是对的文件，但**全仓库零调用点**，
且它数的是所有行（含注释与 `nftset=`），口径也不对。

修法：`list_stats` 增加 `split_server_lines`（数 `server=` 前缀行），
`chain_snapshot` 改用它；删掉死函数 `split_rule_count`。

##### S6 [严重] 「保存并应用」4 条分支无反馈，按钮无条件打 ✓

`cmd_apply` 有 5 条正常出口 + 2 条失败出口：
```
DNSMASQ=restarted（静态片段已变）
DNSMASQ=skipped（框架未启用）
DNSMASQ=skipped（无 init.d/dnsmasq）
DNSMASQ=sighup（仅观测域名变化）
DNSMASQ=unchanged（无变化，未动 dnsmasq）
ERROR=生成分流片段失败 / ERROR=生成自定义列表失败
```
而 `apply_on_parse` 只处理 `restarted`，其余 4 条**不设置任何 message**。
最常见的 `unchanged`（只改阈值、片段未变）用户点保存后看不到任何提示，
会反复点；框架未启用时更是什么都不显示。

按钮路径反过来，无条件拼 `✓` —— `ERROR` 时显示「✓ 已应用」+ 错误正文。

修法：`apply_message()` 统一解析，按出口给 `✓`/`!`/`✗` 与对应文案，
`skipped` 还带上具体原因。实测 8/8 分支正确。

##### 中等缺陷（9 项）

| # | 问题 | 处置 |
|---|---|---|
| M1 | `validate_domain` 比 `dc_domain_valid` 少 4 条（总长≤253、label≤63、label 首尾非 `-`、TLD 非 `xn--` 须纯字母）→ 页面放行、脚本 `dc_domain_valid \|\| continue` 静默跳过 → 「已录入」却不生效 | 补齐 4 条，保证「页面拒绝集 ⊆ 脚本拒绝集」。实测 10/10 |
| M2 | 空值分支返回**原始** `value`（可能是 `"  "`）而非归一值 → `rmempty` 不认它为空，空格串被写进 UCI | 改为返回 `v`（空串） |
| M3 | `validate_upstream` 把「该 section 全部已有值」与本次输入合并后整体判定 → 一行坏就整段报错，包括用户想用来替换坏行的那一行，形成死锁 | 只校验本次 `value` |
| M4 | 「待应用」徽标比的是 UCI 原始 token 数与生效条数 → 有一个非法域名就永久显示「待应用」 | 改用「合法条数」比较，非法项单独红徽标列出 |
| M5 | `%w` 不含下划线 → `both_bad=1` 被解析成 `bad = 1`，丢 `both_` 前缀 | 改 `[%w_]+` |
| M6 | `import_lists` / `reconcile_now` 恒返回 `true` → reconcile 失败时页面仍打 ✓（违反红线 3） | 加 `exec_ok()` 扫描 ERROR/失败 |
| M7 | `box_lines` 的 `w` 形参从未使用；单个超宽域名（AWS/CloudFront 风格）直接溢出 viewBox 被裁 | 按宽硬切并补 `…`。实测零溢出 |
| M8 | `sync_dnsmasq_filter_aaaa` 丢弃所有 `sys.exec` 返回值，恒 `return true` → 写失败时开关显示已切换但行为未变 | 返回结构化错误码（数据层不放 UI 文案）+ 写后读回校验 |
| M9 | 5 个配置项（`cache.enabled`/`filter_https_rr`/`import_interval`/`selftest.interval`/`intercept_doh`）无消费者却无标注；`dnschain-reconcile` 根本没有调度者 | 补「仅作记录」标注；`selftest.interval` 明说「仓库里没有定时调度」 |

##### 轻微缺陷（9 项）

| # | 问题 | 处置 |
|---|---|---|
| L1 | `_conclusion` 按**译文子串**判色（`concl:find("未监听")`）→ 非中文界面恒绿，英文界面上「国内 dnsproxy 未监听」显示成绿色 | 改按语义分支给 tone；保留关键字兜底 |
| L2 | selftest 表格的 `name`/`detail` 未转义（同文件 `r.result`/`r.domain` 都用了 `dg.esc`），而 detail 是脚本 stdout 直通 | 套 `dg.esc` |
| L3 | `os.date("%H:%M:%S", r.last or 0)` 对 `last=0` 渲染成 `08:00:00`，看起来像真实探测时刻 | `> 0` 才格式化，否则 `—` |
| L4 | `STATUS_H` 恒 0 且从未被读取（死常量） | 删除 |
| L5 | `/proc/<pid>/stat` 的 pattern 捕获第 21 字段（应第 22 = starttime），实际取到 `itrealvalue`；`uptime` 还是死变量 | 整段删除并写明理由 |
| L6 | `M.check_domains` 注释称「自检会调用它」，实际零调用点 | 删除函数 |
| L7 | 同一页出现「16 项检查」与「20 项检查」两个数字 | 改为 20 |
| L8 | SVG `aria-label` 未转义（其余动态文本都过了 `esc`） | 套 `esc` |
| L9 | controller 直接用 `nixio.fs` 而未 `require`，脱离 dispatcher 的环境会抛 nil 索引 | 显式 `require "nixio.fs"` |

##### 实测排除的 3 项（不改）

| 怀疑 | 实测结论 |
|---|---|
| S4 的 `render-dnschain-diagrams.py` 传 6 键表报 `h=478` | 那是**测试脚本传错数据**（`{ [1]=true, ... }` 占位表）。改传真实 `sample_rows()` 后与 `status_map` 完全一致 |
| L1 英文 locale 下判色失效 | 逻辑成立但需真机切 locale 才能观察；已按语义重构，不再依赖译文 |
| L8 翻译里是否真有双引号 | 当前中文文案无 `"`，属预防性加固 |

##### 验证

```
本地：dash 8/8、shell 90+23、lua 121（新增 33 条）、图示 44（新增 6 条）、
      契约 121、i18n 426、CI 模拟通过
路由器：页面 HTTP 200、160KB、SVG 4、marker 0 重复、Lua 报错 0、
        「16 项检查」已改 20、响应 1.86s
```

> **环境说明**：本轮验收时该路由器上的 SSR-Plus 处于
> `global_server=nil` 状态（配置文件里没有任何 `servers` 节点，
> `/etc/config/shadowsocksr` 仅 72 行、9 个 section，无订阅 URL），
> 因此自检第 13 项「代理与分流在位」FAIL。这是**环境既有状态**
> （AGENTS §4.2 记录的已知故障模式），与本次 Lua 改动无关 ——
> 本轮改动只涉及页面渲染与数据读取，不可能删除 UCI 节点。
> dnschain 框架本身正常：`:5353` 国内 OK、`:53` 国内外均 OK、
> `nftset=23714`、cycle 自动把 4 个国外域名改道到直连（正确行为）。
## [v0.14.3] - 2026-10-22

### 运行时 shell 层深审：6 项严重 + 9 项中等缺陷修复

### 运行时 shell 层深审：6 项严重 + 9 项中等缺陷修复（v0.14.3）

对 `files/` 下 6 个运行时脚本（共 3887 行）做第二轮只读审查，
逐条在路由器上实测验证后修复。**29 项报告里有 3 项经实测不成立，
未作改动**（见末节）。

##### S1 [严重] 健康探测取锁后提前返回不释放 → 改道功能永久停摆

`dc_health_cycle` 原顺序是「取锁 → 检查实例就绪 → 不就绪就 `return 0`」，
而那条 `return` **不释放锁**。

daemon 是常驻进程、`$$` 恒定不变，于是：
- 某轮撞上 dnsproxy 未监听（开机时序 / dnsproxy 被 procd 重启 / 手动 stop-start）
  → 锁写下且永不删除
- 后续每轮 `mkdir` 失败 → 读到 holder pid → `/proc/<pid>` 存在（就是自己）
  → 打印「SKIP 已有一轮探测在跑」→ **永久跳过**

结果：**改道功能从此完全停止**，而日志里是「正常 SKIP」、页面只是状态不再更新。

实测复现（同一进程连跑 3 轮）：
```
第 1 轮: SKIP 本地 dnsproxy 实例未就绪（:5353 / :59999）
   锁: 残留  pid=1641
第 2 轮: SKIP 已有一轮探测在跑（pid=1641）
第 3 轮: SKIP 已有一轮探测在跑（pid=1641）
```

修法：把实例就绪检查**移到取锁之前** —— 不就绪时根本没取锁，直接返回安全。
实测修复后三轮都正确判断、锁无残留。

##### S2 [严重] `grep -c || echo 0` 双输出 → nftset 自愈永不触发

`grep -c` 在**无匹配**时既打印 `0`、又返回 rc=1。于是
`n=$(grep -c PAT f || echo 0)` 得到的是**两行** `"0\n0"`：

```
$ v=$(grep -c '^nftset=' /tmp/t || echo 0); echo "[$v]"
[0
0]
$ [ "$v" -eq 0 ]; echo $?
2                     ← 算术比较报错返回假
```

后果是**判据恒假**，而它恰好只在「计数为 0」时才是关键路径：

- reconcile 的「nftset 行数为 0 → 强制重建」自愈分支**永不执行**
- `dc_prev_nftset_count` 返回脏值 → 重建窗口兜底也失效

即 v0.14.1 想修的那个「代理链路整条断」故障在收敛路径上依然不自愈。

修法：新增 `dc_count_lines`（awk 实现，恒输出单个整数、rc 恒 0），
替换全仓库 6 处同类写法。

##### S3 [严重] 一次配置应用重启 dnsmasq 3 次（约 9 秒中断）

`reload_service` 的调用链是：
```
reload_service → reload_dnsmasq          （第 1 次）
              → stop → stop_service → reload_dnsmasq（第 2 次）
              → start → start_service → reload_dnsmasq（第 3 次）
```
实测一次 `/etc/init.d/dnschain reload` 期间 dnsmasq 主进程出现
**4 个不同 PID**（6576→7704→7873→9467）。AGENTS §4.4 实测 restart 约
3 秒完全不可用 → 一次保存断 9 秒以上。

更糟的是第 2 次发生在 `stop_service` 已把分流片段写成「服务已停止」注释之后、
`start` 重建之前 —— 那几秒 dnsmasq 跑在**没有分流片段**的状态下，
所有国外域名走默认上游。

修法：用标记文件 `/var/run/dnschain/.dnsmasq-dirty` 抑制中间步骤，
末尾统一重启一次。
**不能用环境变量**：procd 的 stop/start 会重新 exec，变量跨不过去
（实测用环境变量只能减到 2 次）。

##### S4 [严重] 首刷默认值把 serversfile 指到 ujail 白名单外

`99-zz-dnschain:151` 写死 `/var/etc/dnschain/watch.servers`，
而库常量与 init 的 `update_serversfile` 都用 `/var/run/dnsmasq/watch.servers`。

平时 init 启动时会纠正，所以看不出来；但服务未启用、`preflight` 失败、
或用户首刷后先看页面再启动服务时，UCI 里就是那个错路径 ——
dnsmasq 以 uid 453 运行、读不到该目录，**既不报错也不生效**，
改道静默失效（正是 AGENTS 约束 26 描述的症状）。

修法：改为引用库常量（子 shell 取值，避免污染本脚本），并加区间校验。

##### S5 [严重] stop 后 dnsmasq 仍按旧的 watch.servers 改道到已停端口

`stop_service` 清掉了 health 状态、把两个片段改成注释，但**没清 `watch.servers`**，
也没撤 `serversfile`，随后还 restart 了 dnsmasq。

而 `/var/run/dnsmasq/watch.servers` 是 tmpfs 文件、不会随 stop 消失。
stop 后重启 dnsmasq 会**重新读取**它 —— 里面若有
`server=/github.com/127.0.0.1#5336` 而 `:5336` 已无人监听，
这些观测域名就变成稳定解析失败。用户看到的是「关掉框架后 github 打不开了」，
而日志干净。

修法：`stop_service` 里把它清成注释占位（不删除，否则 dnsmasq 启动时读不到
serversfile 会报错），**然后**再 restart dnsmasq —— 顺序不能反。

##### S6 [严重] `dc_run_timeout` 每次成功调用泄漏一个 `.done` 文件

完成标记文件只在入口 `rm -f`，但成功返回的两处都只 `wait` + `echo 0` + `return 0`，
从不删除标记文件；而 `mktemp` 每次给新路径，入口那次删不到别人的。

实测：两次 `dc_dns_class` 泄漏 2 个文件。
健康 cycle 一轮 8 域名 × 2 链 × 最多 3 次重试 ≈ 48 次，
daemon 每 60 秒一轮 → **每天约 7 万个空文件**堆进 tmpfs
（/tmp 与 /var 同属内存盘），最终 `mktemp` 失败 → 探测全返回 FAIL
→ 误判成双链都挂、页面标 both-bad。

修法：成功返回前删掉标记文件。实测 10 次探测 + 完整 cycle 后零泄漏。

##### 中等缺陷（9 项，全部实测确认后修复）

| # | 问题 | 处置 |
|---|---|---|
| M2 | `dc_ssr_mode_for_profile` 读不存在的 `main.profile` → 恒返回 `"0"`；页面能选 `ssr.mode`（0/7）却**无人读**，用户选「7」被静默推翻 | 改为读 `ssr.mode`，保留 `main.profile=coexist` 兼容 |
| M3 | 11 个页面配置项**零消费者**（`cache.size`/`lists.black_source`/`via_proxy`/`cert_verify`/`auto_rollback` 等），用户改了不生效且无从察觉 | `cache.size` → 写 `dhcp.cachesize`（uci-defaults + reconcile 双路）；`lists.black_source` → 接入归属判定；其余在页面明示「仅作记录」 |
| M4 | 自检第 3 项对 `/var/etc/dnsmasq.conf.*` 通配，多份文件时 `grep -c` 输出 `路径:计数`，`head -1` 取到带路径的行 → 恒 FAIL | 改为从 dnsmasq 进程 argv 取真正在用的 `-C` 路径 |
| M5 | `dc_gen_watch_servers` 建的是 `$DNSCHAIN_RUN_DIR`，却把文件 `mv` 到 `/var/run/dnsmasq/` → 后者不存在时整条启动失败 | 改为建目标文件所在目录，失败时把具体路径打进日志 |
| M6 | `reconcile_intercept` 用 `grep '^6,'` 只匹配行首 → DNS 不是第一项时永不删除旧的明文 DNS 下发，客户机绕过整个框架 | 改为按项匹配（`tr ' ' '\n'` 后逐项判） |
| M7 | `dc_gen_upstream_file` 不检查 `dc_gen_db_domains` 返回码，数据库缺失时静默产出 0 字节文件并报成功 | 显式检查两次，失败时写明原因（名单未就绪/生成失败） |
| M8 | 关联数组分支（`declare -A`）在 BusyBox ash 下是死代码，且 `declare` 属 bash 专有，与「POSIX sh 兼容」声明冲突 | 删除该分支，只留 `grep -Fxf` 批量匹配一条实现 |
| M9 | `main()` 丢弃 `reconcile_intercept` 的返回码，且该函数恒 `return 0` → commit/restart 失败时收敛器仍以 0 退出，页面「一键归一」永远报成功 | 函数内失败置非 0，`main` 取 rc |
| M1 | 怀疑 `dc_dns_first_addr` 把 nslookup 的 Server 地址行当答案 | **实测不成立**：返回的是真实 IPv6 地址，未含 `:端口`。**未改动** |

##### 清理（10 项死代码与过时注释）

`DNSCHAIN_ETC_DIR`（定义后从未使用）、`dc_domain_fixed`（v0.14.0 语义矫正后的
兼容壳，名字反而误导）、`verbose`（死变量）、`M.watch_servers_file`（无调用者
且路径已漂移）、`dc_lists_fingerprint` 内层重复判断、`cmd_apply` 硬编码路径、
自检指纹硬编码 gfw 路径、库头注释「禁止 local」（与全文实际用法矛盾）、
自检头注释声称有定时任务（仓库里无任何调度）。

##### 实测排除的 3 项（不改，避免无依据改动）

| 怀疑 | 实测结论 |
|---|---|
| M1 `dc_dns_first_addr` 把 Server 行当答案 | 返回 `240e:ff:e020:99b:0:ff:b099:cff1`，是真实答案，未中招 |
| M4 自检第 3 项恒 FAIL | 当前只有 1 份 `dnsmasq.conf.*`，未触发；但隐患真实，已按「取当前生效文件」加固 |
| M8 `declare -A` 是否有支持 | `sh -c 'eval "declare -A x=()"'` 返回非 0 → 确认 ash 不支持，该分支确为死代码 |

##### 验证

```
本地：dash 8/8、shell 90+23、lua 88、图示 38、契约 121、i18n 412、CI 模拟通过
路由器：selftest 20/20、五条需求 54/54、页面 2.03s
        :53/:5353/:5336 全 OK、nftset=23714、ss_spec=2
        .done 零泄漏、锁无残留、serversfile 正确、cachesize 一致
        nftset 归零自愈端到端验证通过（检测→重建→重启→链路 OK）
```
## [v0.14.2] - 2026-10-22

### 全链路严谨审查：7 项缺陷修复 + 文档对齐

### 全链路严谨审查：7 项缺陷修复 + 文档对齐（v0.14.2）

按要求逐条梳理每个功能链路、以代码与运行结果为依据审查，
覆盖隐性/显性 bug、边界条件、异常处理、数据一致性、视觉/UI/图表/交互。
共确认 **7 项缺陷**（2 项严重），另清理 3 处死代码与 1 处重复实现。

##### 一、[严重] 页面「清空全部缓存」完全无效

`flush_cache()` 在 Lua 侧用 `pidof dnsmasq | awk '{print $1}'` 取 PID，
而 `pidof dnsmasq` 返回 **3 个** PID，第一个是 **ujail 辅助子进程**：

```
PID 21400  wchan=anon_pipe_read   fds=5   socket:53=0    ← 被选中（错）
PID 21368  wchan=poll_schedule…   fds=36  socket:53=25   ← 真正干活的
PID 21331  wchan=do_epoll_wait    fds=7   socket:53=1
```

对它 SIGHUP 是**空操作** —— 按钮点了完全无效，页面却照样报
「已清空 dnsmasq 缓存（零中断）」。这是典型的静默失效。

而库里的 `dc_flush_cache` 早已用 `dc_dnsmasq_pid`（按 `:53` socket inode
反查）正确实现，却**没有 CLI 入口**，成了死代码 —— 同一功能写了两份，
其中一份是错的。

修法：补 `dnschain-health flush` 子命令，Lua 只调它。实测输出
`已发送 SIGHUP 清空 dnsmasq 缓存 (pid=21368)`，dnsmasq 未受影响、`:53` 正常。

##### 二、[严重] 判定链路图渲染两次 → 5 组 marker id 重复

实测页面 HTML：`id="dcrt-a-ok"` 等 **5 个 id 各出现 2 次**。

根因：`dg.route_map()` 被渲染**两次** —— 概览 tab 的「分流决策」与
域名 tab 的「走法」。CBI 的 tab 是 CSS 隐藏、**不是懒加载**，
两个 tab 的内容都进同一份 HTML，而 SVG id 是**文档级全局**的。

后果：`url(#dcrt-a-ok)` 全部解析到**第一个**定义。当前两图配色恰好相同
所以看不出异常，但一旦一处改了色，箭头颜色就静默串掉，浏览器不报错。

修法：`route_map` / `status_map` 支持 `id_prefix` 参数，两处调用分别传
`dcrt-ov` / `dcrt-dm`。实测修复后 15 个 marker id 全部唯一。

##### 三、[中等] selftest 缓存指纹覆盖不足 → 改配置后 60 秒内报旧结论

原指纹只含端口/进程/`ss_spec`/开关，漏了三类：
`filter_aaaa`、`ipv6_support`、gfw 行数、上游列表。
症状是「改完配置看自检，还是旧结论」，用户以为改动没生效。

修法：补全指纹。实测改 `filter_aaaa` 后指纹从 `...|0|1|...` 变为
`...|1|1|...`，缓存自动失效并重跑（0.30s → 3.16s）。

顺带修掉一个取错 section 名的 bug：`dc_get_list upstream server` 返回空
（UCI 里是 `config upstream 'cn'` / `'foreign'`，类型是 upstream、
名字是 cn/foreign），导致上游变化完全检测不到。

##### 四、[中等] tab 切换不处理滚动 → 长 tab 切短 tab 后停在空白处

各 tab 高度差数倍（分流约 3000px、概览约 900px）。`activate()` 只切
`hidden` 不管滚动，从长 tab 滚到底再切短 tab 时 `scrollY` 仍停在旧值，
新内容早已在视口上方，屏幕只剩页脚。

修法：新内容顶部若已跑到视口上方，滚回 tab 栏位置（留 8px 边距）；
只在这种情况下才动，避免打断用户在同高度 tab 间的小幅滚动。

##### 五、[中等] 状态写盘重复实现 + 并发无锁

`dc_health_write` 与 `dc_health_write_keep_last` 各复制了一整段
「读旧文件 → awk 过滤同域名 → printf 追加 → mv」，只差 `last` 取值。
两份同样的写盘逻辑，改一处忘另一处就会写出格式不同的状态文件，
而 `status`/页面都按 7 字段解析。

另：`dc_health_cycle` 无互斥锁。daemon 每 `interval` 秒跑一轮，
页面「立即探测一轮」随时可触发，并发时后完成的进程会用少了对方新增行的
副本覆盖 → 状态文件丢行。

修法：
- 抽出 `dc_health_upsert` 作为唯一写盘实现（瘦身 33 行）
- 加 `mkdir` 原子锁 + 死锁自动清理（`kill -9` 后锁残留能自愈）

实测 3 个并发 cycle：1 个执行、2 个正确跳过，状态 8 行无重复，锁无残留；
`kill -9` 中断后下一轮自动清理死锁。

##### 六、[轻微] `preflight` 变量未 `local` + 编号重复

`_dot_bad` 未在函数首行 `local` 列表里 → 污染全局。注释编号有两个「4.」。
已修正（编号 1~5 连续）。

##### 七、[清理] 死代码与重复

| 项 | 处置 |
|---|---|
| `dc_sleep_tick` / `dc_ticks_per_sec` | 删除（紧密轮询改造后已成死代码） |
| `dc_flush_cache` | 补 CLI 入口后复活（见第一节） |
| `dnschain_die` | 保留（错误处理基础设施） |

`dnschain.sh` 从 1894 行降到 1861 行。

##### 八、实测排除的「疑似 bug」（不改，避免无依据改动）

| 怀疑 | 实测结论 |
|---|---|
| `dc_domain_valid` 用 `set --` 会污染调用者位置参数 | **不会**。POSIX sh 函数有独立位置参数作用域，实测调用前后 `$#` 与 `$1` 不变 |
| `dc_domain_valid` 改 `IFS` 后中途 `return` 会泄漏 | **不会**。`IFS=.` 与 `IFS=$_oifs` 在连续三行内完成，之后才可能 `return` |
| 空数据时 `status_map` 产出非法 SVG | **不会**。输出合法（无 NaN/nil） |
| 超长域名（180 字符）文字溢出框 | **不会**。`wrap_text` 正确换行，溢出 0 处 |
| 含 `& < >` 的域名破坏 SVG | **不会**。转义正确 |
| CBI `depends` 目标字段不存在 | **不会**。只有 `enabled`/`auto_attach` 两个目标，都在同 section 且先定义 |

##### 九、文档对齐（用户要求第 3 项）

实测发现 **4 类文档漂移**，全部修正：

| 文档 | 漂移 | 修正 |
|---|---|---|
| `AGENTS.md` | 契约断言 99 条（实际 119）、lua 83 条（88）、图示 30 条（38）、自检 16 项（20） | 全部更新；并新增硬约束 33~37（清缓存 PID / 互斥锁 / 单点写盘 / 缓存指纹 / tab 滚动） |
| `docs/adr/0006` | 场景 E 仍写「状态 fixed:OK，永不改道」—— 正是 v0.14.0 已废除的语义 | 改写为「照常参与改道」并附完整矫正说明与实测轨迹 |
| `docs/adr/0004` | 两处「自检 16 项」 | 改为 20 项 |
| `docs/adr/0003` | G5 事务与 §9 步骤里的「16 项自检」 | 改为 20 项 |
| `docs/adr/0005` | 验证步骤「自检 16 项全绿」 | 改为 20 项 |
| `GLOSSARY.md` | 「策略过滤器 `:5335` chinadns-ng」「4 跳」「档案 `:5335/:5337`」均已作废；**缺**归属/首选/当前三个核心概念 | 重写为双实例架构；跳数改 3 跳；补 5 个术语（归属/首选/当前/改道/补全归属） |

> CHANGELOG 里历史条目的「16 项」保留 —— 那是当时的事实记录，
> 不应改写历史。

##### 十、复测

```
本地：dash 8/8、shell 89+23、lua 88、图示 38、契约 119、i18n 409、CI 模拟通过
路由器：selftest 20/20、五条需求 54/54、页面响应 2.08s
        页面结构：SVG 4 个、marker 15 个全唯一、嵌套 form 1 个、Lua 报错 0
        flush 实测发到 pid=21368（正确），dnsmasq 未受影响
```
## [v0.14.1] - 2026-10-22

### 页面响应慢 + 操作 ssrplus 后国外链路断

### 页面响应慢 + 操作 ssrplus 后国外链路断（v0.14.1）

用户报告两个 bug：
① 切换 `dns_chain` 页面响应时间太长；
② 操作 ssrplus 页面后国外链路不通，自检第 10/11/13 项 FAIL
（`国外 A 正确` / `国外 AAAA 保留` / `代理与分流在位`）。

##### 一、国外链路断：nftset 行被静默清空

**根因**：在 SSR-Plus 页面点「保存并应用」时，ssrplus 会重建规则，
`ss_spec` 表在重建窗口内**短暂消失**。若 `dnschain` 恰好在此窗口跑
`apply`，`dc_nftset_exists` 对所有集合都返回假 →
**23714 条 `server=` 照写、但 `nftset=` 一条都不写**。

后果链条（这是最难定位的地方，日志完全干净）：

```
server=/域名/127.0.0.1#5336    ← 国外域名仍能解析（正常）
（缺 nftset=）                  ← 解析出的 IP 不进 blacklist 集合
→ 流量不命中 ss_spec_wan_ac
→ 不走代理
→ 国外链路整条断掉
```

实测证据：`dnschain-health apply` 输出 `SPLIT=23714 0`
（前半是 server= 条数，后半是 nftset 条数）。

**修法（两层保护）**：

| 层 | 位置 | 行为 |
|---|---|---|
| 生成时兜底 | `dc_gen_dnsmasq_split` | 探测不到集合时，若上一版片段**有** nftset 行且 `ss_spec` 整体不在 → 沿用上一版行，记一条警告。区分「SSR-Plus 从未启用」（保持不写）与「正在重建」（保留） |
| reconcile 自愈 | `dnschain-reconcile` | 重建后若 `ss_spec` 在而 nftset 为 0 → 强制再生成一次；行数下降也告警 |

同时新增 `dc_ss_spec_present()`（查表而非查集合）——
这是区分「重建中」与「未启用」的唯一可靠判据。

**验证**：删掉 `ss_spec` 后跑 apply，nftset 仍为 23714（兜底生效）；
恢复后跑 reconcile，自动修复到 23714。

##### 二、页面响应 5.6 秒 → 1.96 秒

逐层定位到 4 个真实瓶颈（每一层都单独实测过）：

| # | 瓶颈 | 实测 | 修法 |
|---|---|---|---|
| 1 | `health_rows` 与 `health_summary` **各自**跑一次 `dnschain-health status` | 各 1.67s，白跑两遍 | 新增 `health_status_raw()` 共用一次调用 |
| 2 | `dc_domain_class` 对每级标签各 `grep` 一次 23715 行名单 | 单域名 0.06s | 改「一次 grep 批量比对所有候选后缀」 |
| 3 | `dc_run_timeout` 每 tick `sleep 1`（BusyBox sleep 只支持整数） | nslookup 仅 0.02s，却被拖满 1 秒 | 改「紧密轮询 + 每 2000 转才 sleep 1 秒」 |
| 4 | selftest 20 项含 4 处真实 DNS 查询，页面每次刷新都跑 | 3.5s | 加 60 秒磁盘缓存 + 失效指纹 |

**第 3 条的排查过程值得记**：先怀疑 `sleep 0.1` 可用（OpenWrt 常开
FANCY_SLEEP），实测 `sleep 0.05` / `sleep 0.1` **都失败**；
`read -t 0.1` 报 `invalid timeout`；`usleep` 不存在。
即 **BusyBox 拿不到亚秒粒度**。所以不能靠缩短 tick，
只能让「快路径不付等待代价」——紧密轮询到命令完成即返回。

##### 三、过程中发现并修掉的 4 个实现级 bug

| bug | 症状 | 根因 |
|---|---|---|
| 缓存永不命中 | 第二次仍跑 3.5s | BusyBox **没有 `stat` 命令**，`stat -c %Y` 恒为空 → 改 `date -r` |
| SUMMARY 行消失 | 验收脚本报「自检有失败: 」（空值） | 改成 `_DC_BODY=$(check_all)` 捕获输出后，漏了 `main` 原本单独打印的 SUMMARY |
| SUMMARY 全是 0 | `SUMMARY PASS=0 FAIL=0` | `PASS_CNT` 等计数在 `check_all` 的子 shell 里，父 shell 读到 0 → 改从捕获文本统计 |
| `selftest` 函数被破坏 | `Syntax error: word unexpected` | 用正则批量替换时 PowerShell 把 `$_body` 当变量插值 → 改用 Python 按文本块精确替换 |

##### 四、复测

```
页面响应（真实登录，3 次）：1.99s / 1.97s / 1.96s   （原 5.6s，-65%）
自检：首次 2.76s（无缓存）、第二次 0.23s（命中缓存）
       SUMMARY PASS=20 FAIL=0 SKIP=0，CONCLUSION: 链路正常
五条需求验收：PASS=54 FAIL=0
国外链路：:5353 baidu=OK、:5336 google=OK
          ss_spec=2、nftset=23714

本地：dash 8/8、shell 89+23、lua 88、图示 35、契约 112、i18n 409、CI 模拟通过
```

**缓存正确性单独验证**（关键：缓存不能掩盖故障）：
停掉 v2ray → 指纹从 `5353|5336|4040|4041|1|1|1` 变为
`...|0|0|1` → 缓存自动失效并重跑 → 准确报出用户描述的那三项 FAIL。
恢复后回到 20/20。
## [v0.14.0] - 2026-10-22

### 语义矫正（自定义=补全归属）与 UI 去重

### 语义矫正与 UI 去重（v0.14.0）

用户指出两件事：
① 全链路检查所有功能与页面组件，移除合并重合重复的；
② 「国内/国外域名」输入框**只作为补全追加到数据库而不是直接改道**，
由 dnsmasq 与 dnsproxy 判断分流；针对数据库未覆盖的域名实现健康检测
与自动改道；③ 明确默认策略（国外不通改直连、国内不通改代理）。

##### 一、最关键的矫正：自定义列表不是「改道开关」

旧实现把自定义域名当 `fixed`：命中就写 `fixed:` 状态并 `continue`
**跳过整个改道判定**。注释写的是「你写的就是最终答案」。

这与需求直接冲突。需求说自定义只「补全归属」，而改道针对
「数据库未覆盖的域名」—— 补全归属**正是**给未覆盖域名定归属，
它必须继续参与改道，否则用户显式补全的域名反而失去了自动恢复能力。

| 位置 | 旧行为 | 新行为 |
|---|---|---|
| `dc_health_cycle` | 命中自定义 → `continue` 跳过改道 | 与其它域名同一套判定，不设例外 |
| `dc_domain_fixed` | 表示「不参与改道」 | 改名 `dc_domain_custom`，只表示「归属由用户补全」 |
| `dc_explain_domain` | `decision=fixed`（不改道） | 走同一套判定；输出 `CUSTOM=1` 标注归属来源 |
| `dnschain-health status` | `fixed` 独占一档 | 删除该档；自定义域名归入 ok/degraded/rerouted/both-bad，汇总用 `custom=<n>` 标注来源 |
| 页面「参与改道」行 | 显示「否（自定义固定）」 | 改为「归属来源：自定义补全 / 数据库·未覆盖」 |

**为什么旧实现的问题比「行为不对」更严重**：`fixed` 档抢在探测结果之前
判定，于是自定义域名的真实状态被永久吞掉 —— 页面看不出它是否健康，
汇总的 normal/rerouted/both_bad 也少算了它们，总数对不上。

##### 二、实测中发现并修掉的真实缺陷：观测基准集被压成一行

矫正后自检第 18 项 FAIL（`PASS=19 FAIL=1`）：
`github.com` 同时出现在静态片段与 `servers-file` 里。

根因在 `dc_watch_list` 的种子集回退：

```sh
DNSCHAIN_WATCH_SEED="a.com b.com c.com d.com
                     e.com f.com g.com h.com"
printf '%s\n' "$DNSCHAIN_WATCH_SEED" | while read -r d; ...
```

`printf '%s\n' "$VAR"` 把整个变量当**一个参数** → 8 个域名被压成
2 行、每行 4 个用空格连起来 → `dc_watch_list` 输出 2 行多域名 →
静态片段用 `grep -Fvxf`（逐行精确匹配）排除时**排除不掉** →
同一域名两处 `server=` → dnsmasq 当候选 → **改道退化成随机走一条**。

修法：种子集改多行字面量 + `printf '%s\n' $VAR`（不加引号，逐词输出）。
实测 SPLIT 从 23715 → 23714（排除掉重复的那个），自检回到 20/20。

##### 三、UI 去重（浏览器逐按钮测量后发现 3 处）

| 重复 | 现象 | 处置 |
|---|---|---|
| 两个「自定义域名」section | 标题完全相同，用户分不清哪个是国内 | 改为「自定义域名 · 国内（补全归属）」/「· 国外（补全归属）」，同步 `SECTION_TAB` |
| 「校验自定义列表」按钮 | 与保存时的两道校验（页面 `validate_domain` + 脚本 `dc_domain_valid`）完全重复 | 删除按钮；`check` 子命令保留（自检第 18 项仍在用） |
| 两个「保存并应用」 | 页面底部 CBI 自动生成的 + 「域名操作」里的，同名同观感 | 后者改名「重建分流规则并生效」并写明与「保存」的区别 |

##### 四、补上一个真实缺陷：底部「保存并应用」其实等于「保存」

`Map` 未定义 `apply_on_parse`，于是 CBI 底部的「保存并应用」与「保存」
行为完全相同 —— 用户点「保存并应用」后以为分流已生效，但静态片段
根本没重建，页面上「待应用」徽标还在。

已补 `m.apply_on_parse`，调 `ds.apply_domains()`。
其中 MD5 比对保证「只改阈值」这类无关字段时**不会**白断 3 秒
（实测：改 `timeout` 后 `DNSMASQ=unchanged`，片段 MD5 未变）。

##### 五、端到端实测（自定义域名确实参与改道）

用 `nft` 阻断 `lo → :5353` 制造真实故障，观测域名设为
`www.baidu.com` 并放进自定义国内列表：

```
基线      CLASS=custom-domestic  CUSTOM=1   domestic  ok
注入故障  轮1  domestic   fail=1  probe:TIMEOUT   degraded
          轮2  foreign    switch:TIMEOUT->OK      rerouted   ← 改道成功
撤销故障  轮1-2 foreign   recover-wait:OK        rerouted
          轮3  domestic   recover:OK              ok         ← 回切成功
```

`min_dwell=120s` 在测试窗口内是把该值临时设为 0 才观察到的 ——
它是防抖设计，不是阻塞缺陷（复测时把 `recover_threshold` 设为 2、
`min_dwell` 设为 0 后两轮即回切）。

##### 六、复测

```
本地：dash 8/8、shell 89+23、lua 88、图示 35、契约 106、i18n 409、JS 通过
路由器：selftest 20/20、五条需求 54/54、页面渲染 15/15（HTTP 200 / 152 KB）

浏览器实测（真实登录）：
  可见 section：自定义域名 · 国内（补全归属） / · 国外（补全归属） /
                判定链路 / 改道状态 / 改道明细 / 观测与阈值 / 域名操作
  按钮重复：仅剩「保存」×2（CBI 页头+页脚固有，非本包引入）
```
## [v0.13.2] - 2026-10-22

### 改道状态导图的文字溢出与显示不全

### 改道状态导图的文字溢出与显示不全（v0.13.2）

用户反馈：「修复改道状态的思维导图样式 bug，内容显示不全和内容显示超出
边界的 bug」。浏览器逐框测量后确认是**两个独立缺陷**。

**缺陷 1：内容超出边界（文字画到框外）**

`box()` 画完 `<rect>` 就直接写 `<text>`，**从不检查文字宽度**。
而 SVG 的 `<text>` 既不会自动换行，也不会把框撑大 —— 超宽就直接画到框外。

实测（真实登录、真实 DOM，`getBBox()` 逐条比对）：

```
「两条链都不通 → 先查 dnsproxy 与代理」
   文字右缘 390  >  框右缘 370   → 溢出 20px
```

框宽 `NW2=180` 硬编码，内容区只有 `180 − 24(左内边距) − 12(右)` = **144px**，
而该 hint 是 19 个全角字符 ≈ 190px。

**缺陷 2：内容显示不全（长清单被截断）**

右侧域名清单按「52 个宽度单位」硬编码折行 —— 那个数字与真实框宽无关。
框变宽后仍按旧值折，白白浪费空间；框变窄时又会溢出。

**修法：引入文本度量 + 折行 + 按内容算框宽**

| 改动 | 说明 |
|---|---|
| 新增 `char_em()` / `text_w()` | 估算像素宽度：CJK 1.0em、ASCII 0.55em、其余 0.6em。偏保守（宁大不小） |
| 新增 `wrap_text()` | 按像素宽度折行，优先在「、，→；·/」后断开 |
| 新增 `box_lines()` | 把一段长文本折成多行画进框内 |
| `NW2` 改为**按最长行计算** | 下限仍 180，但内容更长时自动加宽（实测 189） |
| `NH` 改为**按 hint 行数计算** | 60 → 73（两行 hint 时） |
| 清单折行改用 `text_w(…, 11) > NW3` | 与真实框宽挂钩，不再用魔数 52 |

**同时修掉两个实现级 bug（都很隐蔽）**

1. **`wrap_text` 里残留 `i = i + len`**：这段来自更早的 `while` 循环，
   改成 `for` 后 `i` 从未定义，`len` 也随之失效 → 断点判断永不触发 →
   **永不折行**。而「不溢出」仍然成立（因为框被撑宽了）——
   所以只测溢出的断言抓不到它。
2. **`utf8.codes` 在 Lua 5.1 不存在**：LuCI 在 OpenWrt 上跑的是 **Lua 5.1**，
   `utf8` 库是 5.3+ 才有。本地 lupa 是 5.4，于是「本地全绿、路由器 500」。
   改为自带 `utf8_iter()`，不依赖标准库版本。

**为什么原有的几何断言全部通过**

`tools/render-dnschain-diagrams.py` 原来只查三件事：
节点互不重叠、不超出 viewBox、说明文字不压住节点框。
**文字溢出框但仍在 viewBox 内**时，三条全部成立 —— 这正是漏网的原因。

**新增两条断言，并各自做了反向验证（用旧参数构造样本，确认会 FAIL）**

| 断言 | 判据 | 反向验证 |
|---|---|---|
| `check_text_inside_boxes` | 框内每条 `<text>` 的估算右缘 ≤ 框右缘 − 6px | 旧参数 → 报「超出 32 px」✓ |
| `check_hint_wrapped` | 存在框内 ≥2 行 10px 文本（证明折行真的生效） | 单行样本 → 报「未折行」✓ |

第二条是必要的：只测溢出的话，**把框加宽到刚好容下长文本也能通过**，
但那会把宽度预算从右侧域名清单抢走，清单反而被截断。

**复测（2026-10-22）**

```
本地：dash 8/8、shell 90+23、lua 88、图示 35、契约 99、i18n 413、JS 通过
路由器：selftest 20/20、五条需求 54/54、页面渲染 15/15

浏览器逐框实测（正余量 = 未溢出）：
  框 #1 189×73  正常 / 8 个域名 / 首选链路可达       rightGap 100  bottomGap 18
  框 #2 189×73  双链故障 / 0 个域名 / 两条链都不通 → 先查 dnsproxy （rightGap 18）
                / 与代理                              bottomGap 5
  溢出 0 处，超出 viewBox 0 处
```

## [v0.13.0] - 2026-10-22

### 新增 — 域名归属控制与链路健康自动改道

用户需求（五条）：UI 新增国内外两个自定义域名输入框（可录入/查看/编辑/清除、
格式校验）；数据库未覆盖域名在当前链路探测不可达时自动改道；明确默认策略
（国外不通改直连、国内不通改代理）；改道示例要体现在实现里；匹配/探测/切换
必须可靠且有超时重试判定，不影响现有解析与稳定性。

设计依据：[`docs/adr/0006-domain-routing-and-reroute.md`](docs/adr/0006-domain-routing-and-reroute.md)。

#### 一、三个概念分清（这是整套设计的地基）

| 概念 | 含义 | 谁决定 | 存哪 |
|---|---|---|---|
| **归属** | 域名「应该」走哪条链 | 配置 + 名单（静态） | UCI + `db-domains.txt` |
| **首选** | 由归属推导出的链路 | 归属（确定性映射） | 计算得出 |
| **当前** | 实际生效的链路 | 健康探测（动态） | `/var/run/dnschain/health.state` |

不分开的后果是「配置」与「运行时」互相污染。分开之后，
配置文件只描述意图、状态文件只描述事实，两者不一致 = 正在改道中。

#### 二、自定义列表（需求 1）

```
config domains 'domestic'   list domain 'www.baidu.com'
config domains 'foreign'    list domain 'www.google.com'
```

- **两个独立 UCI 段**，不是同一段两个 list（同一段的两个 list 会被
  CBI 的 `NamedSection` 写回时互相覆盖）
- 归属优先级：**自定义 > 数据库 > 未覆盖**。自定义优先是刻意的 ——
  否则用户会遇到「我明明写了走直连，它还是走代理」这种无解困惑
- 三道校验闸：页面 `validate_domain()`（手误立刻可见）→
  脚本 `dc_domain_valid()`（兜住直接 `uci set` / 备份恢复）→
  selftest 第 17 项（事后可查）
- **页面那道刻意不比脚本更严**：写得过于复杂会误拒合法域名，
  典型是 `xn--` 形式的 IDNA（`--` 在 punycode 里是正常字符）
- 不接受通配符：`server=/域名/` 是标签后缀匹配，`*.example.com`
  会得到一条永远匹配不到的规则，而页面上看不出任何异常

分流结果：

| 归属 | dnsmasq | nftset | 效果 |
|---|---|---|---|
| 自定义国内 | `server=/域名/#5353` | `china` | 解析直连，IP 入直连集 |
| 自定义国外 / 数据库 | `server=/域名/#5336` | `blacklist` | 解析走代理，IP 入代理集 |
| 未覆盖 | 不写 | — | 落到默认上游（直连） |

`nftset` 目标集**先探测再写**：SSR-Plus 未启用时 `ss_spec` 表不存在，
写 `nftset=` 会让 dnsmasq 每解析一个域名都尝试写集合失败、日志刷错。

#### 三、自动改道（需求 2/3/4）

**核心规则一句话：首选链不通，且另一条链通 → 切到另一条链。**

两条需求规则是这同一个判定的两个实例（因为首选已由归属决定）：

| 需求原文 | 场景 | 首选 | 另一条 | 结果 |
|---|---|---|---|---|
| 国外链失败改直连 | 数据库国外域名 | `foreign` | `domestic` | 切直连 |
| 国内链失败改代理 | 未覆盖域名 | `domestic` | `foreign` | 切代理 |

> 「未覆盖 → 直连」不是随便定的：dnsmasq 的默认上游就是
> `127.0.0.1#<entry_port>`，所以未覆盖域名本来就走直连。
> 改道逻辑必须与这个事实一致，否则「不配置」与「配置了」行为不同。

判定状态机：

```
情形 A：当前 == 首选
    r_pref 通     → fail=0，保持
    r_pref 不通   → fail++；≥ fail_threshold 且 r_other 通 → 改道
情形 B：当前 != 首选（已改道）
    r_pref 通     → ok++；≥ recover_threshold 且 停留 ≥ min_dwell → 回切
    r_pref 不通   → ok=0，保持现状
双链都不通        → 不改道，标记 both-bad
```

**双链都不通时不改道**：那不是分流问题，是链路故障。改道只会把
「两条链都坏」伪装成「一条链能用」，掩盖真正的问题。

阈值默认值与理由：

| 参数 | 默认 | 理由 |
|---|---|---|
| `timeout` | 2s | BusyBox `nslookup` 无 `-timeout`，框架自实现硬超时 |
| `retries` | 2 | 单次 UDP 丢包常见；不重试会让改道变成随机行为 |
| `fail_threshold` | 2 轮 | 避开单轮抖动（一轮里可能两个域名各丢一次包） |
| `recover_threshold` | 3 轮 | 链路临界时反复横跳，每次横跳都改一次 servers-file |
| `min_dwell` | 120s | 同上，另加时间维度下限 |
| `interval` | 60s | <15s 会被抬到 15s（一轮探测本身 3~10s） |

#### 四、改道只 SIGHUP，不重启 dnsmasq（需求 5 的关键）

`dnschain-split.conf` 通过 `--conf-dir` 加载，而**实测 reload
（SIGHUP）不重读 conf-dir**（AGENTS §4.4）→ 改它必须 restart，
代价约 3 秒中断。改道可能每分钟发生，绝不能走 restart。

采用的通道是 `--servers-file`：dnsmasq 收到 SIGHUP 会**重新读取**它
（`dnsmasq.c` 的 `EVENT_RELOAD` 分支调用 `read_servers_file`）。

```
改道 → 重写 /var/etc/dnschain/watch.servers → kill -HUP dnsmasq
```

不重启、不清缓存、不影响未观测域名。UCI 侧通过
`dhcp.@dnsmasq[0].serversfile` 下发（首刷即写 + 每次启动校验）。

**硬约束：一个域名只能有一处 `server=` 声明。** 同一域名若同时出现在
静态片段与 `watch.servers` 里，dnsmasq 会把两条 `server=` 当作**候选**
（不是后者覆盖前者），改道退化成「随机走一条」，且两条链都能解析时
完全看不出问题。故 `dc_gen_dnsmasq_split()` 必须排除观测域名，
selftest 第 18 项专查这个重叠。

#### 五、新增运行时组件

| 文件 | 职责 |
|---|---|
| `files/usr/bin/dnschain-health` | 探测 / 改道 / 回切 / explain / status / check / apply / reset / daemon |
| `files/usr/share/dnschain/dnschain.sh` | 新增域名校验、归属判定、分流生成、探测与判定（约 +700 行） |
| `files/etc/init.d/dnschain` | 分流生成收口到库函数；新增 `update_serversfile`、`start_health_daemon` |
| `files/etc/config/dnschain` | 新增 `domains`（两个段）与 `health` 段 |
| `files/etc/uci-defaults/99-zz-dnschain` | 首刷生成派生文件 + 配 `serversfile` |
| `files/usr/bin/dnschain-selftest` | 新增第 17~20 项（列表合法性 / 片段不重叠 / 通道就绪 / 状态自洽） |

`dc_run_timeout` 的实现要点（踩过两个坑）：

- **超时状态走 stdout，不走变量**。调用方几乎总是
  `out=$(dc_run_timeout ...)`，而命令替换在**子 shell** 里执行 ——
  函数内给变量赋值父 shell 看不到，超时会被静默当成「返回空」
- **必须用完成标记文件，不能只用 `kill -0` 判活**。子进程退出后变成
  僵尸，`kill -0` 依然成功，会白等满整个超时

#### 六、页面（需求 1 的 UI 部分）

新增第 2 个 tab「**域名**」（`TAB_ORDER` 里紧跟「概览」），三个问题一条链：

1. **自定义域名** —— 两个 `DynamicList` 输入框 + 已录入清单
   （同时显示「已保存」与「已生效」两份条数：只显示后者时用户保存后
   看不到变化会反复点保存；只显示前者看不出 apply 是否真的成功）
2. **判定链路** —— 思维链路图 + 单域名解释
3. **改道状态** —— 状态思维导图 + 通道就绪性 + 明细表 + 阈值 + 四个操作按钮

#### 七、两张思维导图（用户明确要求）

**判定链路图**（`dcrt`，viewBox 720×486）—— 上下两段对应两个阶段：

```
上段：域名 → 归属（自定义国内/未覆盖/自定义国外/数据库）→ 首选（直连/代理）
下段：链路探测 → 探测首选链 / 探测另一条链 → 保持 / 改道 / 双链故障
```

按**结果**分组而不是按来源分组：用户真正想知道「走直连还是走代理」，
按结果分组时每两条线汇聚到同一节点，一眼看出归属与去向的对应；
按来源分组则会出现两条长斜线跨越整张图（`uncovered → 直连` 要跨过
「代理」那一行），正是「看起来像断链」的典型形态。

**改道状态图**（`dcst`，viewBox 760×动态）—— 一个根分五档：

| 档 | 色 | 含义 | 下一步 |
|---|---|---|---|
| 正常 | 绿 | 首选链可达 | 无需动作 |
| 降级中 | 黄 | 首选开始失败，未达阈值 | 观察 |
| 已改道 | 黄 | 已自动切到另一条 | 观察，恢复后自动回切 |
| 双链故障 | 红 | 两条链都不通 | **动手查** dnsproxy 与代理 |
| 固定归属 | 蓝 | 自定义指定 | 不参与改道 |

**为什么分五档而不是「正常/异常」两档**：把「已自动改道并恢复可用」
与「两条链都不通」混在一起是错的 —— 前者不需要人介入、后者必须人介入。
分档之后红黄绿含义唯一，用户看到红色就知道要动手。

图下都写明读图规则与需求原文，图能表达结构但规则要可核对。

#### 八、验证

新增三个本地校验工具（CI 与本地跑同一份逻辑）：

| 工具 | 断言数 | 覆盖 |
|---|---|---|
| `tools/verify-dnschain-domains.sh` | 88 | 需求 1~5 的每条落地 + 图示约束 + 无嵌套 form |
| `tools/check-dnschain-lua.py` | 77 | 语法 + controller + 模型 + **真实渲染页面全部 DummyValue** + HTML 标签配对 |
| `tools/render-dnschain-diagrams.py` | 24 | 纯几何：越界 / 重叠 / 控制点交叉 / marker 前缀 / 转义 |

外加 dash 单测 94 条（71 + 23，含需求第 4 条的两个改道示例）。

`tools/check-dnschain-lua.py` 用 lupa（真实 Lua 解释器）而非 `luac -p`：
不只查语法，还要**执行**每个 `cfgvalue()`，才能抓到拼错的方法名、
nil 索引、未定义变量这类只在渲染时才暴露的错。

#### 九、同时修掉的两个既有断言误报

- **CI 的 `[[ ]]` 检查会命中 POSIX 字符类 `[[:space:]]`**。
  本仓库 `dnschain.sh` 里有 `sed -e 's/^[[:space:]]*//'`，
  旧断言把它判成 bash 语法 → CI 永远红。改为「`[[` 后紧跟空白」才算。
- **`verify-dnschain-ci-sim.sh` 在 Windows 上崩于 GBK**。
  workflow 注释里有 `⚠️`，Python 默认用 GBK 写 stdout 会
  `UnicodeEncodeError`。CI 是 Linux（UTF-8）看不出，而本地复跑正是
  这个脚本的用途，故显式指定 UTF-8。

#### 十、已知取舍

- **只探测观测列表，不做全量探测**（3.5 万域名一轮几小时，且会把
  dnsmasq 与 dnsproxy 打满）。改道只对观测域名生效，其余按静态归属走。
  理由：一个能说清楚「这 8 个域名现在走哪」的系统，比一个
  「什么都在改但什么都看不见」的系统更可靠。
- 观测列表目前靠手工 + 内置基准集，未做「按流量自动挑选」。
- 改道只保留最后一次结果，没有时间序列。

#### 十一、路由器实测发现并修掉的 8 个问题

本地 8 层校验（dash 语法、shell 单测、lupa 真实 Lua、图示几何、
契约断言、CI 模拟、i18n、JS/JSON）**全部通过之后**，部署到
OpenWrt 24.10.5 实测才暴露出来的问题。记在这里是因为每一条都
只能靠「在真机上跑一遍」发现，静态检查与单测都看不见。

| # | 症状 | 根因 | 修法 |
|---|---|---|---|
| 1 | `uci` 报 `Parse error (section of different type overwrites prior section with same name)`，**整个配置文件读不出来** | `config domains 'foreign'` 与已有的 `config upstream 'foreign'` **同名**。UCI 的 section 名是**文件级唯一**，与类型无关 | 改名 `dom_domestic` / `dom_foreign`，并加「section 名全局唯一」断言 |
| 2 | `dnschain restart` 报 `foreign-split.conf 为空`，链路起不来 | `custom-domestic.txt` 默认是**空文件**，而 BusyBox `grep -Fvxf <空文件>` 返回 rc=1 且**输出零行**（不是「一条都不排除」，而是把输入全吞掉） | 新增 `dc_exclude`：排除文件为空时走 `cat` 放行 |
| 3 | 改道写进 `watch.servers` 后 SIGHUP 成功，但**改道完全没生效**，且日志干净 | `watch.servers` 在 `/var/etc/dnschain/` 下：既不在 ujail 挂载白名单、文件又是 `0600 root:root`，而 dnsmasq 降权到 **uid 453** 运行 | 移到 `/var/run/dnsmasq/`（ujail 已 `-rw` 挂载）+ `chmod 0644` |
| 4 | 同一症状的另一半：`dc_dnsmasq_pid` 选中**辅助子进程** | `pidof dnsmasq` 返回 3 个 PID，第一个是 `wchan=anon_pipe_read` 的辅助进程，对它 SIGHUP 是空操作 | 改用「持有 :53 socket 的 PID」（`/proc/net/udp` inode 反查） |
| 5 | `www.google.com` / `www.youtube.com` 拿到**污染答案**（`31.13.92.37` 是 Facebook 的 IP） | 归属判定用 `grep -Fqx` 精确匹配，而 gfw 名单只写了 `google.com`；dnsmasq 的 `server=/google.com/` 对子域名生效 → 子域名被判 `uncovered` → 首选 domestic → 改道拉去直连 | 归属判定改为**逐级剥标签的后缀匹配**，与 dnsmasq 语义对齐；自定义列表仍保持精确匹配（两种语义不能混） |
| 6 | 死端口被探测判为 `OK`，于是「链路挂了却不改道」 | `dc_probe_chain` 只认 `foreign`/`domestic` 两个链路名，其它落到 `*)` 分支取 `entry_port` → 传 `127.0.0.1#59999` 会被**静默改成**探测 `:5353`（活的） | 支持显式端口形式（`host:port` / `host#port`） |
| 7 | 改道后**永远不回切**，状态卡在 `recover-wait:OK`（ok 计数涨到 12，阈值 3） | 等待分支每轮都调 `dc_health_write`（写 `last=now`），`now - last` 恒为 0 → `min_dwell` 永不满足 | 新增 `dc_health_write_keep_last`：等待期间**不更新 last**，`last` 保持为「改道发生的那一刻」 |
| 8 | 打开页面 **HTTP 500**：`attempt to call global 'translate' (a nil value)` | `diagrams.lua` 是被 `require` 的**普通模块**，没有 dispatcher 注入的全局 `translate`。本地测试预置了 `translate` 桩，所以本地全绿、路由器 500 | 显式 `local i18n = require "luci.i18n"`；测试同时提供 `luci.i18n` 模块并加「模块文件不得裸调 translate」断言 |

第 8 条的教训最值得记：**测试桩比真实环境宽松，问题就会溜过去**。
本地 lupa 测试给 `_G.translate` 注入了桩，于是 `diagrams.lua` 里写裸
`translate` 也能跑通；而真实 LuCI 里只有 CBI 模型文件才享有注入。
修法是同时补 `luci.i18n` 模块桩**并**加静态断言，
让「本地通过」与「路由器可用」的判据一致。

#### 十二、路由器端实测结论（2026-10-22）

| 验证 | 结果 |
|---|---|
| `dnschain-selftest`（20 项） | PASS=20 FAIL=0 SKIP=0 |
| 五条需求端到端验收 | PASS=54 FAIL=0 |
| 改道 + 回切（nft 真实故障注入） | PASS=14 FAIL=0 |
| LuCI 页面真实登录渲染（4 个 tab） | PASS=15 FAIL=0，HTTP 200 / 135 KB |

改道与回切的实测轨迹（用 `nft` 阻断 `lo -> :5353` 制造真实故障）：

```
基线          端口=5353 状态=ok
注入故障      探测=TIMEOUT
轮 1          端口=5353 状态=degraded      ← 未达阈值
轮 2          端口=5336 状态=rerouted      ← 改道成功
撤销故障      探测=OK
轮 1-2        端口=5336 状态=rerouted      ← 等 recover_threshold
轮 3          端口=5353 状态=ok            ← 回切成功
```

`min_dwell=120s` 在测试窗口内是刻意回拨 `last` 才观察到的 ——
它是防抖设计，不是缺陷。

#### 十三、UI 全链路复核补漏（用户反馈「导图看不到」后）

用户反馈「链路自动分流导图没有看到」，并指出要审查新功能是否全部
落到 LuCI Web UI。复核后**确认 3 个真问题 + 2 个缺失组件**。

| # | 问题 | 根因 | 修法 |
|---|---|---|---|
| 1 | 两张导图**看不到** | SVG 只写了 `viewBox`，**没有 `width`/`height` 固有尺寸**。CSS 的 `width:auto` 于是回落到 `100%` —— 图被拉伸到容器宽 1246px、高度等比放大到 900px（520×1246/720），字号从 11px 涨到 19px。一张 720×520 的图占满整屏还多，滚动时只看到几个放大的框 | 生成 SVG 时写入 `width`/`height`（`720×520` / `760×190`）；CSS 改 `width:auto; height:auto; max-width:100%` |
| 2 | 页面「改道通道」误报**未就绪** | `serversfile_ready()` 查进程 argv 里有没有 `--servers-file`，而 OpenWrt 的 dnsmasq init 用 `append_parm` 把它写进**配置文件**。按 argv 判定永远报未就绪 —— 用户会去排查一个不存在的故障 | 改查生效的 `/var/etc/dnsmasq.conf.*` 里有没有 `servers-file=`，并额外校验 ujail 白名单 |
| 3 | 导图只藏在「域名」tab 里 | tab 按钮带徽标数字（显示成「域名1」），看不出里面有图 | 概览页也放一张分流决策图（同一个 `dg.route_map`，不是两份实现） |
| 4 | **缺**：自动改道守护进程状态 | 守护进程由 procd 托管，页面完全没有它的痕迹。开关显示「已启用」而进程没起来时，**自动改道完全不发生且无任何提示** | 新增「自动改道进程」行：运行中/未运行/已关闭三档，含 pid、轮询间隔、上次探测距今秒数 |
| 5 | **缺**：`jail-blocked` 诊断 | `serversfile_ready` 的 reason 表里没有 ujail 拦截这一项 | 补上，并明确提示「dnsmasq 读不到，改道会静默失效」 |

**为什么这 5 条本地全绿也发现不了**：

- #1 不是几何问题（节点坐标、viewBox、文字位置全部正确），
  是「矢量图被当位图拉伸」。`tools/render-dnschain-diagrams.py`
  只校验几何，看不到 CSS 生效后的渲染尺寸。
  现已补断言 `check_intrinsic_size`：SVG 必须有 width/height。
- #2 与 selftest 第 19 项是**同一个坑的第二个出口**。
  当时只修了 selftest，漏了页面模型 —— 同一个判据写了两处，
  改一处不改另一处，症状就会从「自检报错」变成「页面报错」。
- #4/#5 是**功能有、UI 没有**：运行时完全正常，但用户无从确认。
  这类缺口只能靠「拿功能清单逐项去页面上找入口」发现。

**复核方法**（可复用）：把 `dnschain-health` 的 7 个子命令与
`files/etc/config/dnschain` 的每个 option 列成清单，
逐项在页面里搜对应控件；找不到的就是缺口。

| 功能 | UI 落点 |
|---|---|
| `health.enabled` / `timeout` / `retries` / `fail_threshold` / `recover_threshold` / `min_dwell` / `interval` / `watch` | 「观测与阈值」（域名 tab） |
| `dom_domestic` / `dom_foreign` | 「自定义域名」×2（域名 tab） |
| `status` | 「状态导图」+「改道明细」 |
| `explain` | 「单域名解释」 |
| `cycle` | 「立即探测一轮」按钮 |
| `apply` | 「保存并应用」按钮 |
| `reset` | 「清空改道状态」按钮 |
| `check` | 「校验自定义列表」按钮 |
| `daemon` | **原先缺** → 已补「自动改道进程」状态行 |

#### 十四、UI 补漏后的复测（2026-10-22）

| 验证 | 结果 |
|---|---|
| `dnschain-selftest` | PASS=20 FAIL=0 SKIP=0 |
| 五条需求端到端验收 | PASS=54 FAIL=0 |
| LuCI 页面真实登录渲染 | PASS=15 FAIL=0，HTTP 200 / **156 KB**（补图后增加 21 KB） |
| 本地 8 层 | dash 8/8、shell 90+23、lua 88、图示 32、契约 99、i18n 412、JS/JSON 通过 |

浏览器实测（真实登录、真实 DOM）：

```
概览页 SVG：DNS 解析链路图 1246×414 / 域名判定链路图 720×520（固有尺寸）
域名页 SVG：域名判定链路图 720×520 / 改道状态思维导图 760×190
改道通道    ：已就绪 /var/run/dnsmasq/watch.servers
自动改道进程：运行中 pid 31483 · 每 60 秒一轮 · 上次探测 26 秒前
```

## [v0.12.5] - 2026-10-22

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v0125)

## [v0.12.4] - 2026-10-22

### 修复 — 概览卡片左侧留白 193px（视觉上「偏右、没居中」）

用户再次反馈：概览页左边留白很大，整体偏右。

#### 根因

CBI 的 `.cbi-value` 是「**标签列固定 160px** + 字段列」两栏布局：

```
.cbi-value-title { width: 160px; flex: 0 0 160px }
.cbi-value-field { flex: 1 1 0% }
```

这个布局对「标题 — 输入框」的短字段是对的（左侧 160px 用于对齐标签）。
但概览里那 4 行字段区放的是**整块内容**：

| 行 | 字段区内容 |
|---|---|
| 结论 | `SPAN.dc-badge`（状态徽标） |
| 解析链路 | `DIV.dc-chain`（链路图，宽 1070） |
| 链路指标 | `DIV.dc-metrics` + `DIV.dc-stats` |
| 组件状态 | `DIV.dc-table-wrap`（5 列表格） |

而它们的标签只有 4 个汉字（实测文本宽约 48px）。标签列仍占 160px，
**左侧白白空出 193px**：

```
section 内容区左缘        191
标签列                   192 ~ 352   （宽 160，文字只占 48）
字段列（链路图等）       368 起
左侧死空间               368 - 191 = 177px
```

用户框选的正是这块区域。

#### 修复

把「字段区放整块内容」的行改成**竖排**：标签变成上方的小标题，
内容占满整行宽度。

判据用 CSS `:has()` 按**内容类型**匹配（CBI 不支持给 option 加自定义
CSS 类，所以不能从 Lua 侧打标记）：

```css
.cbi-value:has(> .cbi-value-field > .dc-chain),
.cbi-value:has(> .cbi-value-field > .dc-metrics),
.cbi-value:has(> .cbi-value-field > .dc-table-wrap),
.cbi-value:has(> .cbi-value-field > .dc-stats),
.cbi-value:has(> .cbi-value-field > .dc-badge),
.cbi-value:has(> .cbi-value-field > .dc-alert) {
	display: block;
}
/* 标签列取消固定宽度，变上方小标题 */
.cbi-value:has(...) > .cbi-value-title { width: auto; flex: none; margin: 0 0 8px; ... }
/* 字段列占满整行 */
.cbi-value:has(...) > .cbi-value-field { width: 100%; flex: none; }
```

**JS 兜底**（老 WebKit 无 `:has()`）：`markBlockRows()` 遍历
`.cbi-value > .cbi-value-field`，检查**直接子元素**是否带
`dc-chain` / `dc-metrics` / `dc-stats` / `dc-table-wrap` / `dc-badge` /
`dc-alert` 之一，命中就给该行加 `.dc-block-row`。

只看直接子元素是有意的：表格内部也有 `.dc-table`，若用后代匹配会让
整行误判（虽然结果相同，但语义上应只认「字段区第一层是块级组件」）。

#### 验证

修复后逐 tab 测量「字段列左缘 − 内容区左缘」（即左侧死空间）：

| Tab | 块级行 | 最大死空间 |
|---|---|---|
| **概览** | 结论 / 解析链路 / 链路指标 / 组件状态 | **1px** |
| 解析 | 国外 AAAA / 当前监听 / 当前统计 | 177px |
| 分流 | 规模 / IP 集归属核对 | 177px |
| 代理 | SSR-Plus 当前状态 | 177px |
| DHCP | 实际下发 | 177px |
| 诊断 | 结果 | 177px |

概览的 177px → **1px**（红框区域消失，链路图从卡片左缘开始）。

其他 tab 保留 177px 是**正确的**：它们的字段是真正的表单控件
（服务器列表、端口输入框、开关），标签最长 22 个汉字
（「拒绝 LAN 出向 853（DoT/DoQ）」实测文本宽 210px），
160px 标签列用于让这些字段纵向对齐，属 CBI 表单的正常形态。

页面其余未变：HTTP 200、0 Lua 错误、12 section、selftest **16/16 PASS**。

## [v0.12.3] - 2026-10-22

### 修复 — 各 Tab 内图表与组件偏右、超出卡片边界

用户报告：所有 tab 页里图表与相关组件「偏右显示、超出卡片右边边界」。

用脚本逐 tab、逐宽度测量「子元素右边缘 vs 卡片内容区右边缘」，
定位到**两个独立问题**。

#### 问题 A：链路图最右节点被 viewBox 裁掉（真实溢出）

链路图是固定 `viewBox` 的内联 SVG，节点坐标手算：

```
最右节点（国外上游）x = X4 + NW + 96 = 700 + 128 + 96 = 924
右边缘 = 924 + 128 = 1052
viewBox 宽 = W = 1040          → 超出 12px
```

节点被裁掉一部分。在 1100px 视口下实测**超出卡片内容区 8px**：

```
tag: g     txt: "国外上游经代理dns.google"   over: 8px
tag: rect  （同一节点的边框）                 over: 8px
```

**修复**：把最右列间距提为具名常量，并让 `W` 与之绑定：

```lua
local W, H = 1060, 356
local GAP = 88              -- 第 4 列到最右节点的水平间距
local X5 = X4 + NW + GAP    -- 916
-- 右边缘 = 916 + 128 = 1044，viewBox 1060，留 16px 边距
```

原来 3 处硬编码 `X4 + NW + 96` 全部改用 `X5`，避免再次算错。

#### 问题 B：链路图左侧贴边、右侧空 30px（视觉上「偏右」）

```css
.dc-chain svg { max-width: 1040px; }   /* 旧 */
```

容器（section 内容区）实测 1070px，SVG 被限死在 1040 ——
**左贴容器左缘、右边空 30px**。视觉上整张图偏左，而最右节点又紧贴
SVG 右缘，两者叠加看起来像「偏右溢出」。

**修复**：去掉 `max-width`，交给 `viewBox` 缩放：

```css
.dc-chain svg {
	width: 100%;
	height: auto;
	min-width: 720px;   /* 低于此宽度改横向滚动，避免文字不可读 */
}
@media (min-width: 1180px) {
	.dc-chain svg { min-width: 0; }
}
```

实测修复后 SVG 在容器内 `leftGap: 0, rightGap: 0` —— 完全填满。

#### 问题 C：窄屏下表格溢出 31px

420px 手机宽度下，「分流」「诊断」的 5 列表格放不进卡片，
实测溢出 **31px**、50 处越界。

**修复**：给表格套滚动容器 `.dc-table-wrap`（`overflow-x: auto`），
表格自身保留 `min-width` 不被压扁：

```css
.dc-table-wrap { width: 100%; max-width: 100%; overflow-x: auto; }
.dc-table { width: 100%; min-width: 480px; }
@media (max-width: 720px) { .dc-table { min-width: 420px; } }
```

为什么包一层而不是直接给 `<table>` 加 `overflow`：`table-layout`
下 `<table>` 的 overflow 行为不可靠（多数浏览器直接忽略），
滚动必须由块级祖先承担。

视图层 3 个表格（组件状态 / IP 集核对 / 自检）全部套上该容器。

#### 验证：11 个宽度断点 × 6 个 tab

用脚本把 `.cbi-map` 的宽度依次设为 1280 / 1100 / 1000 / 900 / 800 /
720 / 640 / 560 / 480 / 420 / 375，每个宽度下遍历全部 6 个 tab，
统计「子元素右边缘超出卡片内容区 > 2px」的数量：

| 宽度 | 溢出数 | SVG 左间距 | SVG 右间距 |
|---|---|---|---|
| 1280 | 0 | 0 | 0 |
| 1100 | 0 | 0 | 0 |
| 1000 | 0 | 0 | 0 |
| 900 | 0 | 0 | 0 |
| 800 | 0 | 0 | 0 |
| 720 | 0 | 0 | 0 |
| 640 | 0 | 0 | 0 |
| 560 | 0 | 0 | 0 |
| 480 | 0 | 0 | 0 |
| 420 | 0 | 0 | 0 |
| 375 | 0 | 0 | 0 |

表格滚动容器实测：`overParent: 0`、`canScroll: true`（内容可滚动，
容器本身不越界），页面无横向滚动条。

#### 顺带核实：内容区居中是正常的

`.cbi-map` 外层 `form` 的 `margin: 582px / 582px`（左右相等），
在 2502px 宽的 `#maincontent` 里居中。左右留白实测 606 / 616 相差
10px 是**滚动条宽度**造成，属正常。

卡片内四块（链路图 / 指标条 / 统计卡 / 表格）左边缘统一为 368、
右边缘统一为 1438 —— CBI 标准的「标签列 + 字段列」两栏布局，
不是错位。

## [v0.12.2] - 2026-10-22

### 修复 — 页面标题下多出一条灰色竖条

用户截图框出一条多余横条：位置在页面描述与 Tab 栏之间，
形状是约 **6×36px 的灰色竖条**。

#### 根因

CBI 为每个 Map 自动生成一个 `<ul class="cbi-tabmenu">` 容器。
本页的 section 都用 `TypedSection` / `NamedSection`，**没有声明 CBI
原生 tab**，所以它的 6 个 `<li>` 全是 `display:none`：

```html
<ul class="cbi-tabmenu">
  <li style="display:none" class="cbi-tab-disabled" data-tab="overview"><a href="#"></a></li>
  ... 共 6 个，全部 display:none
</ul>
```

但 `<ul>` 本身仍带主题背景色（shadcn 下是 `var(--muted)`，实测
`oklch(0.269 0 0)`）。子项全隐藏后容器塌成一条竖条，
宽 6px、高 36px，正好卡在描述与自建 tab 栏之间。

实测定位：

```
UL.cbi-tabmenu  rect: t=74 l=655 w=6 h=36
                bg: oklch(0.269 0 0)
                childCount: 6，全部 display:none
                prevSibling: DIV.cbi-map-descr
```

#### 修复

**CSS**（声明式，现代浏览器直接生效）：

```css
.cbi-tabmenu:not(:has(> li:not([style*="display:none"]):not([style*="display: none"]))) {
	display: none !important;
}
```

只隐藏「没有任何可见子项」的 tabmenu，避免误伤真正使用 CBI 原生 tab
的页面（那些 `<li>` 不是 `display:none`）。

**JS**（兜底，老 WebKit 不支持 `:has()`）：`dropEmptyTabmenu()` 在初始化时
遍历 `.cbi-tabmenu`，用 `getComputedStyle` 数可见子项，为 0 就移除节点。

**为什么用 CSS+JS 而不是去掉 CBI 的生成逻辑**：tabmenu 由 CBI 在渲染
阶段按 `.cbi-section` 结构补出来，不在 `general.lua` 的控制范围内；
改 CBI 内部实现会影响所有页面。

#### 验证

```
tabmenuExists: true          （节点仍在 DOM，但已隐藏）
tabmenuDisplay: "none"
elementsBetweenDescrAndTabs: []   （描述与 tab 栏之间已无任何可见元素）
tabsVisible: 46px
```

截图确认：描述文字下方直接是 Tab 栏，灰色竖条消失。

页面其余未变：HTTP 200、74173 字节、0 Lua 错误、12 section、
selftest **16/16 PASS**。

## [v0.12.1] - 2026-10-22

### 变更 — DNS 链路页从「网络」移到「服务」，紧跟 ShadowSocksR Plus+

原位置：网络 → DNS 链路。
新位置：**服务 → DNS 链路**，紧接在「ShadowSocksR Plus+」下一行。

理由：本页管的 dnsproxy 实例与 SSR-Plus 的分流是同一套链路，
放在「服务」下与 SSR-Plus 相邻，比埋在「网络」里更符合使用路径。

#### 排序依据（实测侧边栏顺序）

| 菜单项 | order | 定义位置 |
|---|---|---|
| ShadowSocksR Plus+ | **10** | `/usr/lib/lua/luci/controller/shadowsocksr.lua` |
| **DNS 链路** | **20** | 本页（新位置） |
| 动态 DNS | 59 | `menu.d/luci-app-ddns.json` |
| DNS Proxy | 60 | `menu.d/luci-app-dnsproxy.json` |
| 带宽监控 | 80 | `menu.d/luci-app-nlbwmon.json` |
| 网络唤醒 | 90 | `menu.d/luci-app-wol.json` |

⚠️ SSR-Plus 的 order **不在 menu.d JSON 里**，而是它 Lua controller
`entry()` 的最后一个参数（第 645 行）。要排在它下一行，本页 order
必须满足 `10 < order < 59`，取 **20** 留出余量。

#### 修掉的三个问题

**问题 A：设 `page.leaf = true` 会让侧边栏项消失**

v0.12.0 加过 `page.leaf = true`（本意是「每次进入都重新渲染」），
结果侧边栏里这一项**直接不见**。

实测原因是 leaf 节点在生成的菜单树 JSON 里带 `"wildcard": true`：

```json
"dns_chain": { "satisfied": true, …, "order": 20,
               "title": "DNS 链路", "wildcard": true }
```

LuCI 前端把 wildcard 节点当「占位/通配」不渲染成菜单链接。
去掉后正常，且 CBI 页面本来就不会被缓存（dispatcher 每次请求都重新
执行 controller 与 model）。

**问题 B：LuCI 菜单索引缓存键不含「文件内容」的语义变化**

`/usr/share/ucode/luci/dispatcher.uc:333` 的 `hash_filelist()` 是：

```ucode
hashval = hash(sprintf("%x|%x|%x", st.ino, st.mtime, st.size), hashval);
```

只吃 **inode / mtime / size**。用 `pscp -scp` 覆盖文件时，若 size 不变
且 mtime 落在同一秒，哈希不变 → 旧缓存继续生效。

改完菜单相关文件后必须：

```sh
rm -f /tmp/luci-indexcache.*.json
```

**问题 C：shadcn 主题的侧边栏有独立的前端缓存**

即使服务端菜单树已正确，侧边栏仍显示旧项。实测缓存位置：

| 位置 | 键 | 大小 |
|---|---|---|
| `sessionStorage` | `shadcn.sidebar.cache` | 8119 B |
| `localStorage` | `shadcn.sidebar` | 5 B |

主题从 `/luci-static/resources/menu-shadcn.js` 读代码，菜单数据缓存在
`sessionStorage`。**清 `/tmp/luci-indexcache` 不会影响它** —— 浏览器端
要清 sessionStorage，或关掉标签页重开。

#### 验证

菜单树 JSON（`window.ShadcnMenu.tree`）实测：

```
services 子项按 order 排序：
  upnp(0)  vlmcsd(0)  shadowsocksr(10)  dns_chain(20)
  ddns(59)  dnsproxy(60)  nlbw(80)  wol(90)

network 下已无 dns_chain
```

浏览器侧边栏截图确认：DNS 链路紧跟在 ShadowSocksR Plus+ 下一行。

页面本身无变化：6 个 tab、52 个配置项、selftest 16/16 PASS。

## [v0.12.0] - 2026-10-22

### 变更 — DNS 链路页重构为 Tab 式配置总控台（shadcn 视觉语言）

用户要求 7 项：美化图表、统一交互组件、删重复、集成三层全部可控参数并分 Tab、
优化性能、修链路图显示、核对 IP 集与各数据库一致性。

#### 关于 shadcn MCP 的实际情况

用户要求「用 shadcn MCP 重构前端」。实测确认**无法直接使用**：

```
$ npx shadcn@latest info --json
{ "project": { "framework": "Manual", "typescript": false,
               "tailwindVersion": null },
  "config": null, "components": [] }
```

本包是 LuCI 应用（Lua + CBI **服务端渲染**），仓库里没有 React、
没有 `package.json` / `components.json` / Tailwind。shadcn 的 Tabs、
Card、Chart、Badge 都是 React 组件，在这里无法安装也无法运行。

经确认改为**实现 shadcn 的视觉语言**而非其代码：

- 语义色令牌（ok/warn/bad/info）定义在 `dnschain.css`，浅色与暗色两套
- 卡片 / 徽标 / 提示条 / 指标条 / 统计卡 / 表格 六类原语
- 零构建、零依赖、离线可用，与 `luci-theme-shadcn` 视觉一致

#### 1. Tab 划分（6 个）

| Tab | 内容 | 原 section |
|---|---|---|
| **概览** | 结论 + 链路图 + 指标 + 组件状态 | 概览 |
| **解析** | 国内/国外上游 + 双栈 + 端口 + 缓存 | 5 个 |
| **分流** | 名单规模 + **IP 集核对** + 导入 + 源文件 | 名单与导入 |
| **代理** | SSR-Plus 兼容 + 拦截开关 | 2 个 |
| **DHCP** | DHCP 下发 DNS | 1 个 |
| **诊断** | 16 项自检 + 5 个操作按钮 | 自检 + 操作 |

**为什么用前端分组而不是 CBI 原生 tab**：CBI 的 tab 需要为每个 tab 建独立
Map 文件，页面加载要 parse 全部 Map —— 每个都跑一遍自检采集（实测 660ms），
反而更慢；而且跨 Map 无法一次保存。

实现：单张 CBI 表单 + 前端按 `<h3>` 标题归组，点击零网络请求。
归组表由服务端以 JSON 输出（`emit_tab_meta`），前端据此匹配。

**踩到的坑**：属性若用双引号包裹（`data-x="{...}"`），JSON 里的引号会把
属性截断，实测属性值只剩 `"{"`。必须用单引号包裹属性，内容里的单引号
转成 `&#39;`。

#### 2. 图表统一（第 1 项要求）

原来三处图表各写一套内联样式（条形、卡片、表格），颜色硬编码。
现在统一到 CSS 原语：

- `.dc-metric` — 指标条（轨道 + 填充 + 右对齐数值）
- `.dc-stat` — 统计卡（标签 / 数值 / 提示三层）
- `.dc-table` — 数据表（表头弱化、数字列 tabular-nums）
- `.dc-badge` — 状态徽标（ok/warn/bad/info/mute 五档）
- `.dc-alert` — 提示条（对应 shadcn Alert）

全部走 CSS 变量，明暗主题自动切换，不再在 Lua 里硬编码色值。

#### 3. 新增：IP 集归属核对表（第 7 项要求）

「分流」tab 新增一张核对表，实时对照 nft 集合与 SSR-Plus 各数据库。

**实测数据（2026-10-22）**：

| 集合 / 数据库 | 实测 | 源行数 | 说明 |
|---|---|---|---|
| 代理 IP 集（blacklist） | **200** | — | 运行时动态累加 |
| 国内 IP 段（china） | **2025** 区间 | **8612** CIDR | nft 合并相邻段 |
| GFW 域名数 | **17813** | **35608** | 源每域名 2 行（server= + ipset=） |
| 国内 IPv6 段 | **1019** | **1019** | 完全一致 |

**用户给出的三个基准全部核对一致**：GFW 17804（= 35608 ÷ 2）、
大陆 IP 段 8612、国内 IPv6 1019。

**关于「代理 IP 集 175」**：它不是固定配置，而是 `dnsmasq nftset=` 的
**运行时累加结果** —— 每解析出一个新的国外域名 IP 就加一条。
同一台机器上先后观测到 148 / 157 / 169 / 175 / 193 / 198 / 200。
所以核对目标不是「等于 175」，而是「只装 gfw 域名解析结果 + 随访问增长」。
页面按此语义显示，并注明「运行时动态累加，不是固定值」。

#### 4. 补全三层可控参数（第 4 项要求）

| 层 | 新增暴露的参数 |
|---|---|
| **dnsmasq** | `cache-size`、`filter_aaaa`（实际生效值，只读展示） |
| **dnsproxy** | 两个实例端口（`entry_port` / `foreign_port`）、`cert_verify`、`via_proxy` |
| **SSR-Plus** | `pdnsd_enable`、`ipv6_support`、`filter_aaaa`（可写）、`router_proxy` / `enable_switch` / `global_server`（只读展示） |

`filter_aaaa` 是本次重点：页面明确标注「写 `shadowsocksr` 的键，
但 `ipv6_support=1` 时会强制覆盖为保留」，并显示三个值的对照
（偏好 / 生效 / ipv6_support）。

#### 5. 性能（第 5 项要求）

| 阶段 | 页面加载 |
|---|---|
| v0.11.1 基线 | 1.22 s |
| 改造后（未优化） | 1.40 s |
| **优化后** | **1.29 s** |

新增的 IP 集核对表多花 0.07s，通过两处优化压回：

1. **`ipset_audit` 复用 `list_stats`** —— 原先 `gfw_list.conf`
   （35608 行）被读两次，实测多花 ~90ms
2. **`gfw_src` 直接取 `list_stats.gfw_lines`**，不再重复数行

耗时构成（实测）：`selftest` 690ms + 纯 Lua 读文件 136ms +
`nft china` 120ms + `netstat` 30ms + 其余 ~30ms ≈ 1.0s，
其余是 LuCI 框架开销。

#### 6. 修链路图（第 6 项要求）

- 连线颜色改为状态色（`var(--dc-ok)` / `var(--dc-bad)`），
  故障链路变红，一眼可见
- 文字用 `currentColor`，跟随主题
- 画布从 980 加宽到 1040，节点间距从 36px 拉到 96px（原来箭头几乎贴住节点）
- 标注放折线旁不压线
- 外层加 `.dc-chain { overflow-x: auto }`，窄屏可横向滚动而不挤压

#### 7. 删重复、合并集合（第 3 项要求）

原 12 个 section 里的重复与冗余：

| 处理 | 原项 | 去向 |
|---|---|---|
| 合并 | 「端口与实例」的 3 个只读项 | 并入「解析」tab，只留 2 个可编辑端口 + 1 个状态行 |
| 合并 | 「SSR-Plus 兼容」的 `_ssr_mode` / `_ssr_ipv6` | 合并为一个「SSR-Plus 当前状态」行（4 个徽标） |
| 删除 | 「双栈策略」的「说明」段 | 内容与「国外 AAAA」重复，已并入其描述 |
| 删除 | 「缓存」里与「自检」重复的统计 | 只保留缓存自己的计数 |
| 改语义 | 「名单规模」的纯文本 | 改为 4 张统计卡（GFW / 基础 / 已生成 / 最近更新） |

**功能一一对应**：改造后 52 个配置项覆盖原 30 项全部 + 新增 22 项
（端口、IP 集核对、SSR 状态、缓存统计等），无功能丢失。

### 修复

**BUG：诊断 tab 显示红色「1」但 FAIL=0**

摘要徽标「FAIL 0」用了 `dc-badge--bad`（红色），前端统计异常数时
按类名计数，把它算成 1 项失败。改为按数值决定颜色：`FAIL 0` 用中性色。

**BUG：tab 文字显示成「诊断1」**

徽标是按钮的子元素，`textContent` 把数字一起读进来。改为取第一个
文本节点。

**BUG：tab 栏上方多出 11px 空白**

服务端用空 section 输出元数据，CBI 给它套了 `.cbi-section` +
`.cbi-value` 两层。CSS 用 `:has()` 声明式处理，同时用 JS 兜底
（老 WebKit 不支持 `:has()`）。

### 验证

| # | 项目 | 结果 |
|---|---|---|
| 1 | 6 个 tab 切换 | 全部正常，默认「概览」 |
| 2 | 52 个配置项 | 0 空 section、0 Lua 错误 |
| 3 | 浅色主题 | 截图确认 |
| 4 | 深色主题 | 截图确认，徽标对比清晰 |
| 5 | IP 集核对表 | 4 行数据全部正确 |
| 6 | 链路图 | 7 节点、状态色、无压字 |
| 7 | 页面加载 | 1.29 s（5 次取样） |
| 8 | DNS 链路回归 | selftest **16/16 PASS** |
| 9 | 解析 | baidu 183.2.172.177 / taobao AAAA 240e:950:400:1:3::6d / google 142.251.153.119 / AAAA 2001:4860:4828:7700:: |
| 10 | 端到端 | google 302/302、baidu 200/200 |
| 11 | i18n | 222 条全覆盖 |
| 12 | CI 断言 | 新增 CSS 暗色令牌 + 资源非空断言 |

## [v0.11.1] - 2026-10-22

### 修复 — DNS 链路页从其他页面切过来要等 7.4 秒

用户报告：从其他页面切到 `dns_chain` 很慢。实测确认 **7.4 秒**，
而同固件的其他页面 **0.04 秒** —— 慢 **170 倍**。

#### 定位过程

用 `/proc/uptime` 做秒表（BusyBox 的 `date` 不支持 `%N`，`time` 内建的
输出格式又被管道吃掉，两种常见计时法在这里都不可用）逐项测：

```
dnschain-selftest        1370 ms   ← 被调用 2 次
ubus call dnsmasq metrics  10 ms
nft list set china        120 ms   ← 2025 个 CIDR
netstat                   20 ms    ← 每次 port_owner() 都起一个
```

页面里 `ds.selftest()` 被调用 **2 次**（「当前状态」+「自检表格」），
`ds.chain_snapshot()` 也被调用 **2 次**（链路图 + 图表），而
`chain_snapshot` 内部要查 4 个端口 → 4 个 `netstat` 进程。
同一份数据被反复采集，累计约 7.4 秒。

#### 修复 1：请求级缓存（主要收益）

在 `dnschain.lua` 加模块级 `cached(key, fn)`：同一 Lua 请求内每个采集函数
只真正执行一次。LuCI 每个 HTTP 请求是独立进程，模块级 table 天然只活一次
请求，无需失效逻辑、不会跨请求串数据。

覆盖：`selftest` / `chain_snapshot` / `cache_stats` / `list_stats` /
`set_count` / 6 个 uci 读取。

写操作（5 个按钮 + `sync_dnsmasq_filter_aaaa`）后调 `M.invalidate()`，
保证同请求内后续读取看到新值。

#### 修复 2：`listen_table()` 一次采集代替 N 次 netstat

原 `port_owner()` 每次起一个 `netstat -lnup`/`-lntp`。改为跑一次
`netstat -lntup`（TCP+UDP 合并），解析成 `{ ["udp:53"] = "16800" }` 表，
后续全部查表。`chain_snapshot` 的 4 次查询从 4 个进程降到 0。

#### 修复 3：`list_stats()` 改用纯 Lua 数行

原实现每个文件起一次 `wc -l`（3 个进程）+ 一次 `date -r`。改为
`io.open` + `gmatch("\n")` 数行（文件都在 page cache，35630 行 < 10ms）。
只保留 `date -r`（Lua 无 stat mtime 接口）。

#### 修复 4：`fw4 check` 按 mtime 指纹缓存

`fw4 check` 单次 **620ms**，占 selftest 45% —— 它要重新渲染整个 ruleset
模板（34 条 chain）再交给 `nft -c` 校验。

但它的结论只在「fw4 相关输入变了」时才变：`/etc/nftables.d/*.nft`、
`/etc/config/firewall`、fw4 模板、`ruleset-post/*.nft`。这些文件的
mtime 不变时，重复校验必然同结果。

改为按 mtime 指纹缓存到 `/tmp`（重启即清）：
- 输入没变 → 复用上次结论（0ms）
- 输入变了 → 重新校验
- `DNSCHAIN_FW4_NO_CACHE=1` → 强制重算（排障用）

#### 修复 5：第 15 项 grep 加 `^` 锚定（30 倍）

该项扫描全部 conf-dir（实测 2.1MB / 35630 行 `server=`），原正则
`server=/[^/]+/...` **没有行首锚定**，grep 要对每行尝试所有起始位置，
回溯代价高。

实测对比：

| 写法 | 耗时 |
|---|---|
| `server=/[^/]+/...`（无锚定） | 300 ms |
| `^server=/[^/]+/...`（有锚定） | **10 ms** |

#### 修复 6：第 2 项改为反选短路

`dnschain-split.conf` 实测 1.5MB / 17813 行。原实现用
`grep -hoE ... | sed | sort -u | tr` 收集全部端口再去重（3 个进程，170ms）。
改为「反选不等于 fport 的行 + head -1」，正常情况下扫到第一行即可确认
（170ms → 40ms）。

#### 效果

| 指标 | 修复前 | 修复后 | 倍数 |
|---|---|---|---|
| 页面加载 | 7.40 s | **1.22 s** | 6.1× |
| selftest 单次 | 1370 ms | **660 ms** | 2.1× |

#### 顺带修掉 3 个此前未发现的 BUG

**BUG A：所有组件显示红色 ✗「未监听」（最危险）**

`listen_table()` 的正则写成 `^(%u%l%l)`（首字母**大写**），而 BusyBox
`netstat` 输出的 Proto 是**小写** `tcp`/`udp` → 匹配不到任何行 →
所有端口判成「未监听」。

症状极具误导性：页面上 dnsmasq / 两个 dnsproxy / SSR-Plus 全变红 ✗、
结论行显示「国内 dnsproxy 未监听 —— 客户机全部无法解析」，
**而服务其实全在正常运行**。这类 bug 会让人以为全线故障。

同时修正 UDP 行没有 State 列的问题（不能固定列数，要取最后一个字段）。

**BUG B：5 个按钮的操作结果从来不显示**

本页「清空缓存 / 导入名单 / 更新 GFW / 一键归一」4 个按钮从 v0.9 起
就在 `write()` 里写 `m.message = "..."`，但**从来没显示过**。
本次新增的「立即重新自检」也一样。

实测查明的三层原因（缺一层都不显示）：

1. Button 的 `write()` 需要**非空 formvalue** 才触发 ——
   `cbi.lua:1424` 是 `if fvalue and #fvalue > 0`。按钮 HTML 的 value
   是按钮文字，浏览器提交会带上（用 curl 测时必须传 `name=按钮文字`）。
2. `dispatcher.lua:237` 是 `local cstate = res:parse()` —— **返回值被丢弃**，
   所以 `state_handler` 返回什么都到不了模板。
3. `dispatcher.lua:298` 读的是 `res.message`，即 **map 对象自身的字段**。

而 `m.message` 这个字段名是 **SimpleForm** 的（`cbi/simpleform.htm:22`），
Map 模板不读它 —— 这就是原写法无效的原因。

修复：`write()` 登记到 `_pending_message` → 覆写 `m.state_handler`，
在 parse 结束时写到 `self.message`。同时把消息里的 `<br/><pre>` 改成
`\n`（`map.htm` 用 `pcdata()` 转义 HTML，标签会显示成 `&#60;br/&#62;`）。

实测 4 个按钮消息均正确显示：
```
已重新自检：PASS=16 — 链路正常
✓ 已归一
✓ 已清空 dnsmasq 缓存（零中断）
✓ 已导入
```

**BUG C：`reconcile` 每次都误报写入失败**

`dnschain-reconcile` 第 101 行写的是
`access_control.@global[0].router_proxy` —— **缺包名，section 名也错**。
每次「一键归一」都输出：

```
dnschain: ERROR: 写入 access_control.@global[0].router_proxy=1 失败（原值 ''）
```

而该键实际已为 1（功能没坏，只是收敛器每次误报）。
正确键名是 `shadowsocksr.@access_control[0].router_proxy`。

### 新增 — 「立即重新自检」按钮

页面默认复用首次自检结果以加快加载。该按钮强制重算，
满足「用户主动要看最新状态」的场景。

### 验证

| # | 项目 | 方式 | 结果 |
|---|---|---|---|
| 1 | 页面加载耗时 | 路由器 curl 5 次 | **7.40s → 1.22s** |
| 2 | selftest 耗时 | `/proc/uptime` 秒表 | **1370ms → 660ms** |
| 3 | 组件状态 | 页面统计 | **12 个 ✓、0 个 ✗** |
| 4 | 按钮消息 | 4 个按钮 HTTP POST | 全部正确显示 |
| 5 | `reconcile` | 直接执行 | 无 ERROR 输出 |
| 6 | 页面完整性 | 浏览器实测 | 12 section、0 空、0 Lua 错误 |
| 7 | 链路图 / 图表 | 浏览器实测 | 7 节点 / 3 条形 + 4 卡片 |
| 8 | DNS 链路回归 | selftest + 解析 + 端到端 | **16/16 PASS** |
| 9 | 浅色 / 深色主题 | 浏览器截图 | 均正常 |

DNS 链路本身未受影响：
```
国内 baidu A      183.2.172.177
国内 taobao AAAA  240e:950:400:1:3::6d
国外 google A     142.251.157.119
国外 google AAAA  2001:4860:4827:7700::
google -4/‑6      302/302
baidu  -4/‑6      200/200
```

## [v0.11.0] - 2026-10-22

### 新增 — DNS 链路页升级为配置总控台（链路图 + 图表 + filter_aaaa 控制）

用户要求三件事：把 `shadowsocksr.filter_aaaa` 加到页面用滑块控制；检查
`dns_chain` 页的渲染 BUG；把全部控制功能补全为 DNS 配置总控台，并加图表
与链路图。施工中发现 **4 个真实渲染/提交 BUG**，一并修掉。

#### BUG 1：4 个 section 全部渲染为空（最严重）

现象：`概览`、`拦截总开关`、`端口与实例`、`操作` 四个 section 只显示
`This section contains no values yet`，里面的 `当前状态`、`链路状态`、
`当前端口`、4 个操作按钮全部不渲染。

根因：配置里是 `config dnschain 'main'` —— **类型名 `dnschain`，名字 `main`**。
而页面写的是 `m:section(TypedSection, "main")`，即「找类型为 `main` 的
section」—— 该类型不存在，于是拿到空集合。

修复：4 处改成 `TypedSection, "dnschain"`。

实测：空 section 从 4 → 0，配置项从 18 → 30 项，页面 37988 → 49260 字节。

#### BUG 2：上游服务器一个输入框都没有

现象：`解析策略` section 只渲染出 `上游服务器` 标题和两个 Flag，
`cn`/`foreign` 的 5 条上游地址（`tls://223.5.5.5` 等）**完全不可见、不可编辑**。

根因：`TypedSection + anonymous=true + template="cbi/tblsection"`。
`tblsection` 期望「每行一个具名 section」，而 `anonymous` 把 `cn`/`foreign`
两行合并，于是表格里只有列头、没有输入框。

修复：拆成两个 `NamedSection`（分别绑定 `cn` 与 `foreign`），去掉 `tblsection`。
语义也更清楚——国内池与国外池的约束本来就不同（国内可混用 DoT/DoH，
国外必须 DoH）。

实测：国内上游渲染出 3 个输入框，国外上游 2 个。

#### BUG 3：点「保存并应用」报 HTTP 500

现象：浏览器点保存后整页 500，任何配置都存不进去。

根因（从 500 页面抓到）：
```
dnschain.lua:95: attempt to call method 'match' (a nil value)
```
`upstream_port(url)` 直接 `url:match(...)`，而 `uci:foreach` 返回的
`sec.server` 在多值 list 时是 **table**，`DynamicList` 的 `value` 也可能是
table —— 传进来就崩。

修复：
- `upstream_port()` 加 `type(url) ~= "string"` 防御
- `validate_upstreams()` 增加 `collect_strings()` 摊平（接受
  string/table/nil 任意混合）
- 页面里的 `validate_upstream()` 同样改用 `collect_strings()`

实测：完整表单提交从 500 → 200。

#### BUG 4：`%s` 被字面写进 UCI

现象：`shadowsocksr.@global[0].filter_aaaa` 的值变成字符串 `%s`。

根因：`luci.sys.call("...'%s'...", v)` —— **`luci.sys.call` 不支持 `%s` 插值**，
它把参数原样当 shell 命令执行。

修复：改字符串拼接（`v` 只可能是 `"0"`/`"1"`，无注入风险）。

#### 新增：`filter_aaaa` 控制（用户明确要求）

页面「双栈策略」段新增三项：

| 控件 | 作用 |
|---|---|
| **抑制国外 AAAA**（下拉） | 写 `shadowsocksr.@global[0].filter_aaaa`，两选项：`关闭 — 保留 AAAA（推荐）` / `开启 — 抑制国外 AAAA` |
| **国外 AAAA**（状态） | 显示**实际生效值**，并在被覆盖时给出红字警示 |
| **实际生效值**（状态） | 同时显示 `shadowsocksr.filter_aaaa` / `dnsmasq.filter_aaaa` / `ipv6_support` 三个值 |

**关键设计：如实暴露联动关系，不假装滑块有效。**

实测（路由器上）：

```
shadowsocksr.filter_aaaa = 1   ← 用户偏好
ipv6_support             = 1
dnsmasq.filter_aaaa      = 0   ← 被 SSR-Plus 强制覆盖
```

`ipv6_support=1` 时，SSR-Plus 的 `get_filter_aaaa()` 直接返回 0 并调
`set_ipv6_dns_filter` 把 `dnsmasq.filter_aaaa` 设为 0 —— **无论偏好填什么**。

所以滑块的真实语义是「**关闭** IPv6 流量代理时要不要抑制 AAAA」。
页面用下拉旁的解释 + 红字警示把这一点讲清楚，而不是让用户以为设了就有用。

保存时 `sync_dnsmasq_filter_aaaa()` 会立即同步 dnsmasq 侧生效值，
**不重启 shadowsocksr**（那会断代理 3–10 秒）。

实测双向写入：

| 操作 | HTTP | `shadowsocksr.filter_aaaa` | `dnsmasq.filter_aaaa` |
|---|---|---|---|
| 设「关闭」 | 200 | 0 | 0 |
| 设「开启」 | 200 | 1 | 0（被 ipv6_support=1 覆盖，符合预期） |

#### 新增：解析链路图（内联 SVG，首屏主角）

7 节点三段式布局，全部用内联 SVG 实现（不引外部库）：

```
LAN 客户机 ──▶ dnsmasq ──┬──▶ dnsproxy 国内 ──▶ 国内上游（直连）
                          └──▶ dnsproxy 国外 ──▶ SSR-Plus ──▶ 国外上游（经代理）
```

- 节点颜色随存活状态变化（绿=正常 / 红=故障）
- 连线颜色同步，故障链路一眼可见
- 标注「默认」「gfw 域名」放在折线旁的空白处，**不压线**
- 底部标注 nftset 入集路径
- 用 `currentColor` + 显式语义色，**浅色与深色主题都验证过**

> 布局迭代 3 轮才定稿：初版两个 dnsproxy 上下错开 160px 却用斜线连接，
> 斜线正好穿过两行标注，实测截图里文字被线压住；改为直角折线并把标注
> 移到折线旁后解决。

#### 新增：链路指标（条形图 + 规模卡片）

- 三条相对长度条形：缓存插入 / 转发上游 / 本地应答，绝对值标在右侧
- 四张规模卡片：分流规则条数 / 代理 IP 集元素 / 国内 IP 段 / 未应答次数
- 图表限宽 620px（不限宽时 1387px 会把条形拉成横线，比例读不出）

数据来自 `chain_snapshot()` 一次采齐，全部是实测值；取不到时显示 `—`
而不是 `0`（0 与「未知」是两件事）。

#### 补全的控制项（配置键 100% 覆盖）

补齐 6 个此前未暴露的键：

| 键 | 说明 |
|---|---|
| `main.entry_port` | 国内实例端口（默认 5353） |
| `main.foreign_port` | 国外实例端口（默认 5336） |
| `main.intercept_doh` | 尽力阻断公共 DoH（仅标注） |
| `aaaa.filter_https_rr` | 抑制 SVCB/HTTPS 记录（默认关闭） |
| `lists.gfw_source` | GFW 名单源路径 |
| `lists.base_source` | 基础名单源路径 |
| `lists.black_source` | 强制代理名单源路径 |

另修正 7 个 `DummyValue` 缺 `rawhtml`（含 HTML 的显示成裸标签）。

#### 新增工具：`tools/extract-dnschain-i18n.py`

提取 `translate()` 字符串（正确处理多行 `..` 拼接），与 PO 比对。
`--write` 追加缺失条目。本次补齐 85 条，PO 从 117 → 197 条。

#### 验证

| # | 项目 | 方式 | 结果 |
|---|---|---|---|
| 1 | 3 个 Lua 文件语法 | `luac -p` | PASS |
| 2 | 空 section | 浏览器实测 | **4 → 0** |
| 3 | 配置项数 | 浏览器实测 | 18 → 30 |
| 4 | 上游输入框 | 浏览器实测 | 0 → 5（国内 3 + 国外 2） |
| 5 | 保存并应用 | 完整表单 POST | **500 → 200** |
| 6 | `filter_aaaa` 双向写入 | POST + `uci get` | 0↔1 正确 |
| 7 | 链路图 SVG | 浏览器实测 | 7 节点，浅色/深色均正常 |
| 8 | 图表 | 浏览器实测 | 3 条形 + 4 卡片 |
| 9 | 配置键覆盖 | 脚本比对 | 100% |
| 10 | i18n 覆盖 | `extract-dnschain-i18n.py` | 173 条全覆盖 |
| 11 | PO 结构 | 脚本校验 | 197 条、0 重复、0 空 msgstr |
| 12 | `rawhtml` 覆盖 | 脚本校验 | 全部覆盖 |

## [v0.10.0] - 2026-10-21

### 重构 — 移除 chinadns-ng，改双 dnsproxy 实例 + dnsmasq 分流

**起因**：v0.9.1 刷机后客户机全部无法解析。逐项排查发现两个真实缺陷，
且第一个修好后暴露出第二个更深的问题。

#### 缺陷 1：`paste` 命令缺失导致框架完全不启动（已修）

```
/etc/rc.common: line 273: paste: not found
ERROR: dnschain.upstream.foreign 为空，无法生成过滤器参数
ERROR: 生成运行时配置失败，中止启动
```

`dc_gen_filter_args` 用 `paste -sd, -` 拼国外上游列表，而 BusyBox **默认不编译
`paste`**（也没装 coreutils-paste）。`paste` 失败 → `trust` 为空 → 被误判成
「配置里没填上游」→ `dnsproxy :5353` 与 `chinadns-ng :5335` **都不启动**，
客户机解析全断。而 `uci get dnschain.foreign.server` 实际返回正常值。

改用 `awk 'NR>1{printf ","} {printf "%s", $0}'`（awk 在 BusyBox 必有）。
实测 5 种输入（单条/两条/三条/空/含空格）与 `paste -sd, -` **完全等价**。

#### 缺陷 2：chinadns-ng 的 DoT 上游在本环境永远不可用（架构性）

修好缺陷 1 后两个进程都起来了，但国外域名仍全部无结果。实测证据链：

| 测试 | 结果 |
|---|---|
| `tls://8.8.8.8:853` 经 `:1234` | ❌ `peer sent close notify`（只回 204 字节） |
| `tls://1.1.1.1:853` 经 `:1234` | ❌ 同上 |
| `tls://9.9.9.9:853` 经 `:1234` | ❌ 同上 |
| `8.8.8.8:443` 经 `:1234` | ✅ TLSv1.3 成功 |
| `1.1.1.1:80` 经 `:1234` | ✅ 301 |
| `223.5.5.5:853` **直连**（在 china 集） | ✅ TLSv1.3 |

**同一 IP，443/80 通、853 不通** → 落地节点到 853 的链路被阻断。

而 `chinadns-ng` 的 `-t` **只支持 `udp:// tcp:// tls://`，不支持 DoH**
（实测 `invalid proto: 'https://'`，二进制里 `doh` 字样数 = 0）。

**这形成死锁**：国外解析要么用 DoT（853 不通），要么放弃加密。
用国内 DNS 查国外则拿到污染答案（实测 `google → 104.244.42.197`、
`AAAA → 2001::1`）。

#### 新架构

```
dnsmasq:53（唯一缓存 + 唯一分流层）
  ├─ 默认              → 127.0.0.1#5353  dnsproxy 实例 1（阿里 DoT/DoH，直连）
  ├─ server=/国外域名/ → 127.0.0.1#5336  dnsproxy 实例 2（Google DoH，经 :1234）
  └─ nftset=/国外域名/4#inet#ss_spec#blacklist
       解析结果自动写入代理 IP 集（替代 chinadns-ng 的 -A）
```

| 组件 | 变化 |
|---|---|
| `chinadns-ng` | **移除**（不再启动、不再配置） |
| `dnsproxy` | 从 1 个实例变 **2 个**（`:5353` 国内 / `:5336` 国外） |
| 国外上游 | `tls://8.8.8.8` → `https://dns.google/dns-query`（DoH 走 443） |
| AAAA 抑制 | **取消**（`foreign 'suppress'` → `'keep'`） |
| `filter_https_rr` | `1` → `0`（不再抑制 SVCB/HTTPS） |
| SSR-Plus `ipv6_support` | 强制 `1`（IPv6 流量也走代理） |
| SSR-Plus `filter_aaaa` | 强制 `0`（保留国外双栈） |

#### 为什么取消 AAAA 抑制

SSR-Plus 的「IPv6 流量代理」（`ipv6_support=1`）实测效果：

| 测试 | 结果 |
|---|---|
| `curl -6 www.google.com` | ✅ 302 |
| `curl -6 www.youtube.com` | ✅ 200 |
| `curl -6 www.baidu.com` | ✅ 200（国内直连） |
| IPv6 代理链 | ✅ 10 条（`ss_spec6_*`） |
| 策略路由 | ✅ `fwmark 0x53535250 → table 999` |
| `dnsmasq.filter_aaaa` | ✅ 自动设为 **0** |

既然国外 IPv6 也走代理，就不存在「IPv6 直连被 RST」的问题，
抑制 AAAA 反而让国外站点失去双栈能力。

#### 关键教训：不能用 dnsproxy 的 `[/域名/]` 分流

最初实现是单实例 + `upstreams-domains.txt`（17767 条
`[/域名/]https://dns.google`）。**实测完全失败**：

```
DEBUG upstream is reserved idx=3    addr=https://dns.google:443/dns-query domains_num=1
DEBUG upstream is reserved idx=4    addr=https://dns.google:443/dns-query domains_num=1
...（一直到 idx=17769）
```

`dnsproxy` 为**每个域名各注册一条 reserved 上游**，17767 个条目耗尽资源，
查询直接 `connection timed out; no servers could be reached`。
而国内域名（走默认上游）正常。

改成「两个实例 + dnsmasq 的 `server=/域名/` 分流」后立即正常。

#### 关键教训：不能过滤 `xn--`

v0.9.x 生成上游文件时过滤 `xn--`（因为 dnsproxy 的 `[/域名/]` 形式不认
punycode，会整体拒绝启动）。v0.10.0 改用 dnsmasq 的 `server=/域名/` 形式，
**dnsmasq 原生支持 punycode，不能过滤**。

实测依据：`gfw_list.conf` 有 58 条 `xn--` 域名，过滤后它们只剩
`server=/域名/127.0.0.1#5335`（该端口已无监听），全部解析失败
（`apple.xn--czr694b`、`nike.xn--hxt814e` 等）。改为不过滤后恢复。

#### selftest 判据的四处修正

16 项自检里有 4 项的判据本身有误，一并修正：

| 项 | 旧判据 | 新判据 | 为什么 |
|---|---|---|---|
| 1 | 检查 `nft chain inet fw4 dns_intercept_lan` | 检查 LAN 地址上 `:53` 能否解析 | 该链**从来不存在**，而 dnsmasq 直接监听 LAN:53，客户机无需 nft 劫持 |
| 2 | 扫描整个 SSR conf-dir 的端口 | 只查框架自己的 `dnschain-split.conf` | SSR-Plus 的 17804 条 `#5335` 是它自己的文件（框架不重写），会永久误报 |
| 7 | 读 `shadowsocksr.filter_aaaa` | 读 `dhcp.@dnsmasq[0].filter_aaaa` | 前者是用户偏好，后者才是实际生效值；实测前者=1 而 AAAA 完全正常 |
| 15 | `grep -v '#5353'` | 只统计非 `127.0.0.1` 的 IP | 旧写法把 `#5336`（国外实例）误判成明文旁路，虚报 35627 条 |

另修 `dns_class` 的 AAAA 判定 bug：原用 `grep -vc ':'` 排除服务器行，
但 **IPv6 地址本身含冒号**，导致 AAAA 答案全被过滤 → 永久误报 EMPTY。

### 实测结果（路由器 192.168.3.254）

自检 **16/16 全 PASS，`CONCLUSION: 链路正常`**：

| 类别 | 结果 |
|---|---|
| 国内 A | `baidu → 183.2.172.177`、`qq → 121.14.77.221` ✅ |
| 国内 AAAA | `taobao → 240e:950:400:1:3::6e` ✅ 保留 |
| **国外 A** | `google → 142.251.155.119` ✅ **真实**（原为 `104.244.42.197`） |
| **国外 AAAA** | `google → 2001:4860:4826:7700::` ✅ **真实**（原为 `2001::1`） |

端到端访问：

| 目标 | IPv4 | IPv6 |
|---|---|---|
| google.com | 302 ✅ | 302 ✅ |
| youtube.com | 200 ✅ | 200 ✅ |
| github.com | 301 ✅ | 000（该站无 IPv6，正常） |
| baidu.com | 200 ✅ | 200 ✅ |

nftset 生效：`blacklist` 集内出现 `142.251.12.94`、`142.251.20.94` 等真实 IP。

### CI 断言同步

| 断言 | 旧 | 新 |
|---|---|---|
| 4 | 必须有 `-N tag:gfw` | **不得有** `dc_gen_filter_args` |
| 4b | — | 必须有 `dc_gen_foreign_args` |
| 4c | — | **不得有** `[/&/]` 形式（会耗尽 dnsproxy 资源） |
| 6 | 必须过滤 `xn--` | **不得过滤** `xn--` |
| 9 | `profile 'primary'` / `foreign 'suppress'` | `foreign_port '5336'` / `foreign 'keep'` / `require_ipv6 '1'` |
| 9b | — | 国外上游必须是 DoH，且不得有 `tls://8.8.8.8` |
| `.config` | 要求 `chinadns-ng=y` | 不再要求（框架不依赖该组件） |

`tools/verify-dnschain-ci-sim.sh` 模拟校验 **36 项全 OK**。

### 验证

| # | 项目 | 方式 | 结果 |
|---|---|---|---|
| 1 | 5 个脚本 dash 语法 | `sh -n` | 全 PASS |
| 2 | `paste`/`awk` 等价性 | 5 种输入对比 | 完全等价 |
| 3 | 双实例启动 | 路由器实测 | `:5353` + `:5336` 均在监听 |
| 4 | 自检 16 项 | 路由器实测 | **16/16 PASS** |
| 5 | 端到端 IPv4/IPv6 | `curl -4` / `curl -6` | 全通 |
| 6 | CI 模拟 | `verify-dnschain-ci-sim.sh` | 36 项 OK |
| 7 | YAML 语法 | `yaml.safe_load` | PASS |
| 8 | 行尾 | `od -c` | 全 LF |

## [v0.9.1] - 2026-10-21

### 修复 — 不能关掉 `luci-theme-bootstrap`（v0.9.1 首次构建失败）

run `39549176947` 失败于 `Verify SQM / i18n enabled`：

```
=== LuCI 主题：shadcn 必须启用 ===
OK   CONFIG_PACKAGE_luci-theme-shadcn=y
FAIL luci-theme-bootstrap 仍被启用（应已关闭）
--- .config 中与 luci-theme 有关的全部符号 ---
CONFIG_PACKAGE_luci-theme-bootstrap=y
CONFIG_PACKAGE_luci-theme-shadcn=y
```

**根因**：lede 的 `collections/luci/Makefile`（标准 LuCI 集合包）**硬依赖**
`+luci-theme-bootstrap`：

```make
LUCI_TITLE:=Standard OpenWrt set including full admin with ppp support and the default Bootstrap theme
LUCI_DEPENDS:= \
  +uhttpd +uhttpd-mod-ubus +luci-mod-admin-full +luci-theme-bootstrap \
  ...
```

写 `# CONFIG_PACKAGE_luci-theme-bootstrap is not set` 只会被下一条
`make defconfig` 的依赖求解**再次选回 `=y`**。这是我在设计时没查清的
依赖关系，属于过度设计。

**修正**：保留 bootstrap，只切换默认主题。

| 项 | 改前 | 改后 |
|---|---|---|
| `luci-theme-shadcn` | `=y` | `=y` |
| `luci-theme-bootstrap` | 试图关闭 → **失败** | **保留**（`=y`，作回退路径） |
| `material`/`openwrt`/`openwrt-2020`/`argon`/`design` | 关闭 | 关闭（不在集合包依赖里，可关） |
| 断言 | 要求 bootstrap 必须关闭 | bootstrap 仅报告；shadcn 必须启用；其余主题必须关闭 |

**保留 bootstrap 反而更好**：shadcn 若在真机上有兼容问题，把
`luci.main.mediaurlbase` 改回 `/luci-static/bootstrap` 即可回退，
**不需要重新编译固件**。代价只是固件多约 300 KB。

### 新增 — LuCI 主题 shadcn 编入固件并设为默认

按用户要求把 `youridol/luci-theme-shadcn` 作为固件的默认 LuCI 主题。

| 改动 | 位置 | 说明 |
|---|---|---|
| 新增 `Fetch luci-theme-shadcn` 步骤 | CI | `git clone --depth 1` 只取构建需要的 5 项（`Makefile` / `root` / `htdocs` / `ucode` / `LICENSE`），排除 `.dev`/`.husky`/`.github` 等开发工具链 |
| 新增 `files/etc/uci-defaults/99-zzz-luci-theme-shadcn` | overlay | **无条件**设 `luci.main.mediaurlbase=/luci-static/shadcn` |
| `.config` 启用 | CI | `luci-theme-shadcn=y`，关掉非默认主题 |
| 新增契约断言 | CI | 主题符号入 `.config`、overlay 脚本就位且排序晚于 `30_` |

**为什么必须自己写 overlay 脚本（主题包自带的那个不够）**

主题自带的 `root/etc/uci-defaults/30_luci-theme-shadcn` 内容是：

```sh
if [ "$PKG_UPGRADE" != 1 ]; then
    uci get luci.themes.Shadcn >/dev/null 2>&1 || \
    uci batch <<-EOF
        set luci.themes.Shadcn=/luci-static/shadcn
        set luci.main.mediaurlbase=/luci-static/shadcn
        commit luci
    EOF
fi
```

它用 `uci get luci.themes.Shadcn ||` 做**存在性短路**：只要该键已被注册，
整个 if 就跳过，**不会改 `mediaurlbase`**。而 LuCI 的默认主题由
`luci.main.mediaurlbase` 决定 —— 若它仍指向 `bootstrap`，shadcn 装了也看不到。

我们的 `99-zzz-` 排在 `30_` 之后，无条件写 `mediaurlbase`，覆盖任何先前值。
同时保留主题缺失保护：`/www/luci-static/shadcn/main.css` 不存在时跳过设置，
避免把 `mediaurlbase` 指到一个不存在的目录导致 LuCI 白屏。

**为什么用固定 clone 而不是 feed**

- 该仓库不在 lede 的任何 feed 里
- feed 机制会拉全部分支且无 commit 固定，主题更新导致样式错乱时很难定位版本
- 主题的 `main.css`（134 KB）与 6 个 woff2 **已预构建入库**，不需要前端构建
- 实测体积 1020 KB / 67 个文件（htdocs 占 896 KB）

### 修复 — `Download package sources` 卡死导致 6 小时超时

**现象**：run `39495602665`（commit `90457d4`）在 `Download package sources`
这一步跑了 **5h54m**，直到 job 的 6h 上限被取消。日志尾部：

```
48 23.2M   48 11.2M    0     0    556      0 12:09:24  5:52:10  6:17:14     0
                                              ↑ 556 B/s
```

即 `nasm-2.16.03.tar.gz` 从 `www.nasm.us` 以 **556 字节/秒**下载，
11.2 MB 花了 5h52m，预计还要 6h17m。

**根因**：lede 的 `scripts/download.pl` 对每个文件按 `@mirrors` 顺序逐个尝试
（`while (!-f ...) { my $mirror = shift @mirrors; ... }`），而 **curl 没有
单文件超时** —— 遇到慢源就无限等。

**对策**（都利用 `download.pl` 已有的扩展点，不改上游代码）：

| 手段 | 机制 | 效果 |
|---|---|---|
| `DOWNLOAD_MIRROR` | `download.pl:53-54` 读取，且 `localmirrors()` 在 `@mirrors` **最前面**被调用（第 241 行） | 列出的镜像**优先级最高**，慢源被跳过 |
| `CURL_OPTIONS=--max-time 300` | `download.pl:112` 透传给 curl | 单文件最多 5 分钟，超时即换下一个镜像 |
| `timeout 3000 make download` | 外层硬超时 | 即使 curl 选项没生效（如走 aria2c 分支），50 分钟后明确失败 |
| `timeout-minutes: 60` | 步骤级 | 兜底，不让它吃满 job 的 6h |

新增镜像列表（实测可达）：
`sources.cdn.openwrt.org` / `sources.openwrt.org` / `mirrors.aliyun.com/gnu` /
`mirrors.tencent.com/gnu` / `mirrors.ustc.edu.cn/gnu`。

下载前会先探测各镜像对 `nasm-2.16.03.tar.gz` 的 HTTP 状态（只报告不阻断），
失败时打印各镜像结果并提示「把可用镜像补进 `DOWNLOAD_MIRROR`」。

### 验证

| # | 项目 | 方式 | 结果 |
|---|---|---|---|
| 1 | YAML 语法 | `yaml.safe_load` | PASS |
| 2 | 超时防护 6 项 | 提取步骤脚本逐项断言 | 全 OK |
| 3 | 主题 Fetch 步骤 5 项 | 提取步骤脚本逐项断言 | 全 OK |
| 4 | **不再关闭 bootstrap** | 断言 for 循环与独立语句都不含 bootstrap | PASS |
| 5 | 主题断言修正 | bootstrap 仅报告、shadcn 必须启用、其余主题必须关闭 | PASS |
| 6 | overlay 脚本 | `sh -n`（dash） | PASS |
| 7 | 断言路径正确性 | 确认 `Apply files overlay` 在断言之后，故用 `../openwrt-build/` 前缀 | PASS |
| 8 | **真实 clone 主题** | `git clone --depth 1` + 复制 + 4 项契约断言 | 全 OK（commit `625a8c1`，1020 KB / 67 文件） |
| 9 | 行尾 | `od -c` 统计 CR | 全 0 |

**真实 clone 测试的实测数据**：

```
Makefile                      447 字节
30_luci-theme-shadcn          235 字节
main.css                   134262 字节（> 20000 下限，已预构建）
login.css                   11443 字节
主题总体积                   1020 KB / 67 个文件
```

## [v0.9.0] - 2026-10-20

### 新增 — DNS 链路框架 `dnschain`（运行时骨架 + 控制页面）

按 `docs/adr/0003-dns-chain-framework.md` 落地 P1/P2 阶段的运行时组件。
**本版本只交付骨架与页面，默认不启用**：`dnschain.main.enabled` 虽为 `1`，
但 `dnsproxy` 与 `chinadns-ng` 的实际启停由 `init.d/dnschain` 控制，
且首刷后需在页面确认端口所有权后才生效。

| 类型 | 路径 | 说明 |
|---|---|---|
| 新增 | `files/etc/config/dnschain` | UCI 配置（9 个 section） |
| 新增 | `files/usr/share/dnschain/dnschain.sh` | 共用函数库（配置读取、参数生成、端口校验） |
| 新增 | `files/etc/init.d/dnschain` | procd 托管 dnsproxy `:5353` 与过滤器 `:5335` |
| 新增 | `files/usr/bin/dnschain-reconcile` | 收敛器：重放不变量集 + 名单单向导入 |
| 新增 | `files/usr/bin/dnschain-selftest` | 16 项自检，输出机器可读结果 |
| 新增 | `files/etc/uci-defaults/99-zz-dnschain` | 首刷默认（排在 `99-gaming-optimize` 之后） |
| 新增 | `files/etc/capabilities/dnschain-filter.json` | 过滤器的 `CAP_NET_ADMIN`（`-A` 写 nftset 需要） |
| 新增 | `package/luci-app-dnschain/` | LuCI 页面（菜单 `网络 → DNS 链路`） |
| 修改 | `.gitattributes` | 5 条无扩展名路径强制 LF |
| 修改 | `.github/workflows/build-openwrt.yml` | `chmod +x` 清单 + 契约校验步骤 |

**核心设计要点**（每条都有 ADR 依据）：

1. **缓存只在 dnsmasq 一层**。`dnsproxy.args` 与 `filter.args` 由脚本生成，
   生成逻辑里**不存在** `--cache`（CI 有反向断言）。
2. **国外上游必须 IP 形式**。`dc_upstream_port` 按 scheme 推断端口，
   `preflight` 校验端口必须在运行时 `ss_spec_output` 端口集内，
   越界即拒绝启动并列出越界项（否则路由器自身出向静默直连、国外域名全挂）。
3. **IDNA 域名不进 dnsproxy 文件**。124 个 `xn--` 会让 dnsproxy
   **整体拒绝启动**（实测 `idna: invalid label`），故生成时过滤，
   另写 `idna-bypass.conf` 交由 dnsmasq 的 punycode 路径兜底。
4. **不配 `--fallback`**。过滤器不可用时返回 SERVFAIL 而非回落国内上游
   （后者会把 `youtube.com` 解析成 `31.13.92.37` 并缓存）。
5. **`-N tag:gfw` 而非裸 `-N`**。裸 `-N` 会连带抑制将来引入的其他组。
6. **不收 `114.114.114.114`**。chinadns-ng 的 `-c` 默认值就是明文 114，
   生成逻辑不写该参数，CI 断言参数里不出现该地址。
7. **收敛而非删除**。框架不删、不重写 SSR-Plus 生成的任何文件，
   保留 `server=/域名/#5335` 作为同策略旁路（ADR §9.1）。

**页面**（`网络 → DNS 链路`）：

- 概览：一句话结论行（按组件实测状态归纳）+ 6 行状态表（fw4 劫持 / dnsmasq /
  dnsproxy / 过滤器 / 代理 / 缓存统计）
- 拦截总开关（滑块）+ 拒绝 LAN 出向 853
- DHCP 下发 DNS（多个明文地址，仅拦截关闭时使用）
- 解析策略（两侧上游，含端口校验）
- 双栈策略（只读，附「1ms 空答复 ≠ 超时」说明）
- 端口档案 `primary` / `coexist` + SSR-Plus 当前模式显示
- 名单规模与导入（自动/手动 + 立即更新 GFW）
- 缓存开关与统计
- 16 项自检表格
- 四个动作按钮：清空缓存（SIGHUP 零中断）/ 手动导入 / 立即更新 GFW / 一键归一

### 修复 — CI 契约断言会把 `$(( ))` 误判成 bash 语法

新增的 `Verify dnschain framework contracts` 步骤首版用了
`\(\([^)]*\)\)[[:space:]]*$` 判定 bash 的 `(( ))` 命令，结果把
`pct=$(( delta * 100 / old_lines ))` 这类**合法的 POSIX 算术展开**也判成违规，
导致构建必然失败。已改为「行首或 `;`/`&&`/`||` 之后紧跟 `((` 且不是 `$((`」才判定。

### 修复 — 三次构建失败/缺陷的根因与处置（v0.9.0 出包前）

本版共触发 3 次构建，前两次失败或产物不完整。三次的根因各不相同，
且**都属于「本地校验看不出来」的类型**，值得逐条记录。

#### (1) `Verify dnschain framework contracts` 找不到 ADR 文档

```
FAIL 缺少 docs/adr/0003-dns-chain-framework.md
FAIL 缺少 docs/adr/0004-dns-chain-verification.md
```

根因：该步骤 `working-directory: lede`，而 `docs/` 在**仓库根**（与 lede 同级）。
`docs/...` 指到了 `lede/docs/`（lede 源码自带目录），里面没有本仓库的 ADR。

修法：改用 `../openwrt-build/docs/...`，与 CI 里其他引用仓库根文件的地方
（`../openwrt-build/patches/`、`../openwrt-build/package/`）一致。

**新增 `tools/verify-dnschain-ci-sim.sh`**：本地复现 CI 的工作目录
（`lede/` + `files/` 已复制）再跑同一段校验。原因：

| 本地跑法 | 结果 | 是否等价 CI |
|---|---|---|
| 在仓库根跑 | 全部通过 | **否**（没验证 lede/ 场景） |
| 在 lede/ 跑但没复制 files/ | 全部 FAIL | 否（CI 会先复制） |
| lede/ + files/ 已复制 | 与 CI 一致 | **是** |

#### (2) 产物版本号静默错位（`v0.8.6` 而非 `v0.9.0`）

产物名是 `openwrt-x86-64-ssrplus-v0.8.6-f39f3cd`。

根因：CI 用 `grep -m1 '^## \[v'` 取 CHANGELOG 第一个**带 `[v` 的**标题。
CHANGELOG 顶部写的是 `## [未发布]`，不匹配 `[v`，于是被跳过，
取到了下面的 `## [v0.8.6]`。**整个过程零报错**。

修法两处：
1. CHANGELOG 顶部标题改为 `## [v0.9.0] - 2026-10-20`
2. `Resolve version from CHANGELOG` 加断言：第一条 `## [` 标题必须就是版本标题，
   否则 `exit 1` 并打印两条标题

反向验证：改回 `[未发布]` → `EXIT=1`；改回 `v0.9.0` → `EXIT=0`。

#### (3) LuCI 页面整层缺失（最隐蔽的一处）

固件产物 245 MB、30 个步骤全绿、`Assert firmware artifact exists` 通过，
但解包后发现 **`luci-app-dnschain` 相关条目数 = 0** —— 页面一个文件都没编进去。

根因：CI 只写了 `Add luci-app-trafficctl` 的复制步骤，
**从未复制 `package/luci-app-dnschain`**，也没在 `.config` 里启用它。

修法三处：
1. 新增 `Add luci-app-dnschain` 步骤（复制 + 7 个关键文件断言）
2. `.config` 增加 `luci-app-dnschain=y`、`luci-i18n-dnschain-zh-cn=y`、
   `chinadns-ng=y`
3. `Verify SQM / i18n` 步骤加 `=== dnschain 本体与中文语言包都必须入配置 ===`
   断言块（符号被依赖求解丢弃时构建失败，而不是静默出包）

**验证方法本身也错了两次**，同样记录：

| 错误做法 | 后果 |
|---|---|
| 用 `unsquashfs -l <path>` 判断单文件是否存在 | 该命令对**不存在的路径也返回 0**，把「13 项全缺」误报成「13 项全 OK」 |
| 用 `unsquashfs -d <dir> <file> <多个路径>` | 该版本（4.5）不按预期提取，解出 0 个文件 |

正确做法：`unsquashfs -ll` 列**全量**清单再 grep，同时能看到权限位。

#### 由此新增的两条验证纪律（写入 ADR-0004 §0 的 E7/E8）

- **E7：overlay 文件在 ≠ 功能在。** 必须分两层查——`files/` 的 overlay
  与 `package/` 的 LuCI 页面。两条路径独立，包没编进去时 overlay 依然全在。
- **E8：不能用 `unsquashfs -l <path>` 判断存在性。** 用 `-ll` 列全量再 grep。

ADR-0004 相应新增 §1.2（第二层：LuCI 页面）、§12.1（刷机前的产物预检），
并把 §12 记录表从 20 项扩到 21 项。

### 测试中发现并修掉的缺陷（骨架阶段）

| # | 项目 | 方式 | 结果 |
|---|---|---|---|
| 1 | 5 个 shell 脚本语法 | `sh -n`（Ubuntu 22.04 的 `/bin/sh` = **dash**，与 CI runner 一致） | 全 PASS |
| 2 | 3 个 Lua 文件语法 | `luac5.1 -p`（Lua 5.1，与 LuCI 运行时一致） | 全 PASS |
| 3 | 3 个 JSON 文件 | `json.load` | 全 PASS |
| 4 | PO 文件配对 | `msgid`/`msgstr` 计数 | 108/108 |
| 5 | 行尾 | `od -c` 统计 CR 字节 | 全部 0 |
| 6 | 上游端口推断 | 6 种 URL 形态（含 IPv6 与显式端口） | 全部正确 |
| 7 | 名单提取与 IDNA 分离 | 仿真 `gfw_list.conf`（含 `xn--` 与无 TLD 非法域名） | 4 条合法 / 2 条 IDNA / 1 条非法被丢弃 |
| 8 | 参数生成 | mock uci/nft 环境跑 `dc_gen_*` | `-t` 有值、无 `--cache`/`--fallback`/`--ipv6-disabled`/明文 114 |
| 9 | 指纹幂等 | 连续两次 `dc_lists_fingerprint` | 相同；改名单后变化 |
| 10 | **CI 断言有效性** | 逐项故意破坏 7 处后复跑 | **7/7 被拦住**，恢复后全 PASS |

**测试中发现并修掉的真实缺陷**（都不是语法检查能发现的）：

1. `dc_get_list` 调用点传参错误 —— `dc_get_list upstream cn` 读的是
   `dnschain.upstream.cn`（一个 section），而配置里 option 名是 `server`，
   正确写法是 `dc_get_list cn server`。症状：`-t` 参数为空、过滤器起不来。
2. 库脚本里 `tr ' ' '\n'` 被写成 `tr '''\n'`（首个参数空格丢失），
   在 dash 下退化为恒等变换 → 所有 list 读取返回空。已统一改为双引号形式。
3. `dc_gen_filter_args` 在国外上游为空时会产出 `-t` 后跟空行；
   已改为显式报错并返回非零（禁止生成非法参数）。
4. `general.lua` 概览里有一段三元表达式两边都是 `"5353"` 的死代码，
   已改为真实的四分支判断（dnsproxy / 过滤器 / 端口占用 / 代理）。

### P3 — 收敛缓存层：dnsproxy 关闭缓存

`files/etc/config/dnsproxy` 改为缓存关闭，并移除 fallback：

| 项 | 改动 | 依据 |
|---|---|---|
| `cache.enabled` | `'1'` → `'0'` | 缓存只在 dnsmasq 一层（ADR §10.5）。三处并存会让同一域名出现两份答案 |
| `cache.min_ttl` / `max_ttl` | `60`/`86400` → `0`/`0` | `--cache-min-ttl` 会人为延长 TTL，改上游后最坏 60 秒仍给旧答案 |
| `list fallback` | **删除** | fallback 是全局的，过滤器不可用时回落污染上游（CHANGELOG v0.8.0 的 `youtube.com → 31.13.92.37` 就是这条路径） |
| `servers.upstream` | 三条国内 DoH → 两条 DoT + 一条 DoH | 与 `dnschain` 的 `config upstream 'cn'` 一致，避免「关掉框架后行为变了」 |

**新增 CI 断言**（3 条）：`cache.enabled` 必须为 `'0'`、不得有 `list fallback`、`ipv6_disabled` 必须为 `'0'`。

### P4 — 四项收尾

**1. `init.d/dnsproxy` 让位逻辑（解决端口抢占）**

此前 `init.d/dnsproxy`（START=90）与 `init.d/dnschain`（START=95）**都**启动
`/usr/bin/dnsproxy`，两个 procd 实例抢 `:5353`，后起的静默失败。

现在 `init.d/dnsproxy` 检测 `dnschain.main.enabled=1` 时：
- `start_service` 直接返回，打印「由 dnschain 框架托管」
- `stop_service` 不动拦截规则（本服务从未起过实例）
- `reload_service` 转发给 `dnschain reload`

判断依据是**配置意图**而非进程状态（开机时序下用 `pgrep` 会误判，AGENTS §8）。

**2. `applechina.conf` overlay（消除明文 DNS 旁路）**

新增 `files/etc/ssrplus/applechina.conf`：173 条 `server=/<Apple 域名>/114.114.114.114`
改为 `127.0.0.1#5353`。

- **不设** `apple_dns`：init 脚本的 `old_appledns` 用 `grep -oE` 只抽 IP、丢端口，
  二次启动会叠成 `127.0.0.1#5353#5353`（AGENTS §9 已记录）
- 行数保持 173（CI 断言），数据行全部指向加密入口（CI 断言）

**3. 853 拒绝的优先级已实测**

在路由器上验证了 ADR 列为必测项的 T2 写法：

```
裸 chain + priority -151 单独 nft -f  → 语法错误（缺 table 上下文，预期）
table 内嵌 priority -151 链           → ACCEPTED
nft list 显示                          → priority mangle - 1（即 -151，先于 mangle -150）
临时加载后 counter                     → 规则正常建立
```

结论：`/etc/nftables.d/15-dnschain-reject-dot.nft` 的裸 chain 写法**正确**，
fw4 会把它 include 到 `table inet fw4` 内部，优先级生效。

**4. `coexist` 档案的自检判据修正**

`dnschain-selftest` 第 2 项原判据在 `coexist` 下会误报（SSR 的旁路指向 `:5335`，
而 `filter_port` 是 `:5337`）。已改为按档案区分允许集，并在输出里显示 `profile`。

### 新增 — `docs/adr/0004-dns-chain-verification.md`（全链路验证规程）

刷机后逐项核对的执行文档，14 节：

| 节 | 内容 |
|---|---|
| §1 | 文件/执行位/包是否就位 |
| §2 | **端口所有权**（`:5335` 属谁、SSR 三个键） |
| §3 | **缓存层唯一性**（含「两份答案是否消失」的最强证据） |
| §4 | 四类域名解析（国内 A/AAAA、国外 AAAA 的 EMPTY 判据） |
| §5 | 分流三层（DNS / IP / 出站） |
| §6 | 双栈与 853 拒绝（含从客户机验证） |
| §7 | 名单导入（规模、dnsproxy 是否加载、自动导入） |
| §8 | **抗「改 LuCI 就坏」**（故意改坏三个键，看收敛器改回） |
| §9 | 降级矩阵（五处故障） |
| §10 | **失败排查树**（四类症状 → 定位路径） |
| §11 | 回滚（只退框架 / 完整回退） |
| §12 | 验证记录表（可勾选） |
| §13 | 已知边界（8 条，不属故障） |
| §14 | 与 ADR-0003 的章节对应 |

### 验证

| # | 项目 | 方式 | 结果 |
|---|---|---|---|
| 1 | 7 个 shell 脚本 | `sh -n`（Ubuntu 22.04 的 `/bin/sh` = dash） | 全 PASS |
| 2 | 3 个 Lua | `luac5.1 -p` | 全 PASS |
| 3 | 3 个 JSON | `json.load` | 全 PASS |
| 4 | YAML | `yaml.safe_load` | PASS |
| 5 | 行尾 | 全部改动文件 `od -c` 统计 CR | 全部 0 |
| 6 | CI 契约校验 | 提取步骤脚本本地执行 | 31 项全 OK |
| 7 | **断言有效性（第一批）** | 故意破坏 7 处 | **7/7 被拦住** |
| 8 | **断言有效性（P3/P4 新增）** | 故意破坏 6 处 | **6/6 被拦住** |
| 9 | 853 优先级 | 路由器实测 `nft -c -f` + 加载后 `nft list` | 显示 `priority mangle - 1`，语法有效 |

**仍待刷机后验证**（已在 ADR-0004 §12 列为可勾选项）：
- 页面在真机 LuCI 中的渲染（本地只有 Lua 语法校验）
- `8.8.8.8:853` / `1.1.1.1:853` 证书是否含 IP SAN（`--cert-verify` 依赖它）
- 端到端：`dnschain-selftest` 16 项在真机的实际输出
- §8 的「故意改坏再收敛」实测

### 文档 — 重写 DNS 链路框架 ADR，撤回两份与代码不符的旧稿

**背景**：`docs/adr/0003-dns-chain-architecture.md` 与 `0004-dns-chain-framework.md`
两份旧稿互相覆盖、都标「提议」，且多处写「已实测」但仓库里没有对应代码。
本轮在路由器上逐条取证后重写为**一份** ADR。

**删除**

| 文件 | 原因 |
|---|---|
| `docs/adr/0003-dns-chain-architecture.md` | ① `gfw2ipset.sh` 路径写错（实际在 `/usr/share/shadowsocksr/`，不在 `/usr/bin/`）；② 把「行数」当「域名数」（47434 vs 23717）；③ 声称的 `--upstream <path>` 域名文件生成器**从未存在**；④ 留了四个未决问题，与 0004 互相覆盖 |
| `docs/adr/0004-dns-chain-framework.md` | ① 自称取代 0003 但两者并存、都标「提议」；② 建立在「`dnsmasq restart` 已改 reload」之上，而仓库 overlay 实际生成的仍是 restart；③ `coexist` 档案下重写 `gfw_list.conf` 会引入新的时序依赖；④ 设计了三层缓存并存，与「只留一层」的结论相反 |

两份都是**孤岛文档**：除彼此外全仓库零引用（0004 除自身标题行外无任何引用），
CHANGELOG 无 v0.8.x 条目提及，`AGENTS.md` §4/§5 也未指向它们——因此能一路写着
与代码不符的内容而没人发现。

**新增**：`docs/adr/0003-dns-chain-framework.md`（编号复用 0003，不制造空洞）

核心设计：

| 项 | 决策 |
|---|---|
| 单一路由入口 | dnsproxy `:5353`，国内→国内加密池、gfw→策略过滤器 |
| 策略过滤器 | 框架自持 chinadns-ng `:5335`，只做 gfw 域名的 AAAA/HTTPS 抑制 + 国外 DoT |
| 单一缓存层 | 只在 dnsmasq（客户机唯一入口）；dnsproxy 与过滤器均不缓存 |
| 分流抗漂移 | **收敛**而非删除：保留 SSR 生成的 `server=/域名/#5335` 作为同策略旁路 |
| 名单导入 | 单向复制到 `/etc/dnschain/`，轮询 md5 自动导入 + 手动导入 |
| 拦截开关 | 滑块决定拦不拦；关闭时按页面配置的明文 DNS 下发给 DHCP 客户机 |

### 修复 — `AGENTS.md` §4.4 的断言会永久误报

原文断言「两处 `restart` 一律改 `reload`（`grep -c 'dnsmasq restart'` 应为 **0**）」。
路由器实测（`/etc/init.d/shadowsocksr`，3324 行）：

```
3161:	/etc/init.d/dnsmasq reload >/dev/null 2>&1          ← 真调用
3305:			echolog "restart: skip dnsmasq restart in stop()"   ← 只是日志字符串
3309:			/etc/init.d/dnsmasq reload >/dev/null 2>&1      ← 真调用
```

`grep -c` 返回 **1**，但那是 `echolog` 里的**文本**，不是调用点。已改为
「排除 `echolog` 行后统计真正的调用，应为 0」，并记下另一处漂移：
仓库 `files/etc/uci-defaults/99-gaming-optimize:503` 生成的代码**仍是**
`/etc/init.d/dnsmasq restart`，与固件实况不一致，下次刷机可能把 reload 改回 restart。

### 修复 — `GLOSSARY.md` 的组件角色已失效

- `dnsproxy` 条目仍写「另有 24 条硬编码国外域名例外指向 mosdns」——该清单
  v0.8.0 已删，且 `AGENTS.md` 明令不要加回。已重写为「唯一路由型解析器」。
- `dnsmasq` 改为「唯一入口 + 唯一缓存层 + DHCP」，删除「按域名分派」的旧描述。
- `mosdns` 改为「仅 SSR 模式 4 时存在，不在默认链路中」。
- 新增术语：`策略过滤器`、`端口所有权`、`档案`、`收敛器`。
- `跳数` 更新为 dnsmasq → dnsproxy → 过滤器 → 上游 DoT。

### 验证

本轮所有结论均来自路由器只读取证（`192.168.3.254`，OpenWrt 24.10.5 x86/64）。
关键实测：

| # | 事实 | 证据 |
|---|---|---|
| 1 | **dnsproxy 用国内上游直接答 gfw 域名会返回污染答案** | `www.google.com` → `2001::1` + `104.244.42.197`；同域名经 `:53` 分流得 `142.251.x.x` |
| 2 | 124 个 `xn--` 域名使 dnsproxy **整体拒绝启动** | `bad domain name "xn--wcvs22d1m.hk": idna: invalid label` |
| 3 | `gfw_list.conf` 47434 行 = 23717 域名 × 2 | `grep -c '^server='` = 23717，`^ipset=` = 23717 |
| 4 | 运行时副本 `ipset=` 被**整行删除**（不是转换） | `^ipset=`=0、`^nftset=`=0、行数 23717 |
| 5 | `gfw2ipset.sh` 在 `/usr/share/shadowsocksr/` | `find / -name 'gfw2ipset*'` |
| 6 | 三层缓存只有两层在工作 | mosdns `:5335` 连查 5 次全为 60–80ms（从不命中）；dnsmasq `:53` 为 80/0/0/10/0ms |
| 7 | dnsproxy `--cache-size` 单位是**字节**，当前 8192 = 8KB | `--help`：`Cache size (in bytes). Default: 64k.` |
| 8 | `ss_spec_output` 只匹配 TCP，端口集含 853 不含 53 | `nft list chain inet ss_spec ss_spec_output` |
| 9 | `blacklist` 7 元素（全来自 `wan_fw_ips`）、`whitelist` 空 | `nft list set` 实测 |
| 10 | 国内 IPv6 库是死路径 | `ipv6_support=0` → `ipv6_rules_apply` 首步 `return 0`；`nft list set inet ss_spec china6` 报不存在 |

**测量纪律**：`date +%s%N` 在 BusyBox 上**不支持**，会静默返回秒级值、全部显示
0ms（本轮首次测量因此作废）。测延迟必须用 `/proc/uptime`（厘秒）。

**未做**：本轮只交付文档，未改任何 `files/`、CI、`.gitattributes` 或页面代码。
固件代码落地按 ADR §13.4 的 P1–P4 分阶段进行。

## [v0.8.6] - 2026-10-20

### 修复 — SSR-Plus 运行一段时间后「无法安装透明代理规则，启动中止」

**症状**：SSR-Plus 偶发启动中止，日志只有一行：

```
2026-10-20 04:48:01: ERROR: 无法安装透明代理规则，启动中止。
```

紧接着 `restart` 会自己再试一次并成功，所以表现为「偶发、能自愈」，
但期间透明代理与 DNS 分流全部中断。

**关键线索**：`ssr-rules` 自己**一条失败日志都没有** —— 既无
`NFTables setup failed!`，也无 `NFT forced rebuild failed!`。
它所有失败分支都会 `loger 3` 记一笔，一条都没有说明它**不是跑失败的，
是被杀死的**。

**复现（5/5 稳定）**：并发两个 `/etc/init.d/shadowsocksr restart` 必定触发；
串行连跑 5 次增量恒为 0。

**根因（两个叠加）**：

1. **互斥锁形同虚设。** `set_lock()` 是 `flock -xn 1000`（`-n` 非阻塞）
   且**忽略返回值** —— 拿不到锁也照样往下走；`unset_lock()` 又
   `rm -rf "$LOCK_FILE"` 把**被锁的那个 inode 删掉**，下一个进程重新创建
   同名文件、锁到另一个 inode。实测：A 持锁时删文件后 B 立即也能拿到锁。
   于是 `start()` 与 `stop()` 真正并发执行。

2. **`stop()` 按 cmdline 杀 ssr-rules。**
   `ps_list | grep ssr-rules | xargs kill -9` 会杀掉**并发实例**正在执行的
   `/usr/bin/ssr-rules`。而 `start_rules()` 是
   `flush_r && ipset_r && fw_rule && ac_rule && tp_rule && ipv6_rules_apply && gen_include`
   的 `&&` 链，中途被 SIGKILL 必然返回非 0 → 打出该 ERROR。
   插桩实证：`step=flush_r ok` 之后不再有任何 step 日志。

**为什么「运行一段时间后」才出现**：开机是串行的。只有周期性触发器撞在一起
才并发 —— `ssr-monitor` 每 30s 巡检、`99-ssrplus-pppoe` 在 `ifup wan` 后
10s 触发、订阅自动更新。本机 `network.wan.proto=pppoe`，每次重拨都会触发
一次 restart，与 monitor 巡检重叠即中招。这解释了 04:09 / 04:11 / 04:47
三个时间点各出现一次的形态。

**修法**（`files/etc/uci-defaults/99-gaming-optimize` 第 4.10 节，幂等）：

| 改动 | 内容 |
|---|---|
| `set_lock()` | 改为有界等待（最多 60s），超时明确报错退出，不再静默继续 |
| `unset_lock()` | 只 `flock -u` + 关 fd，**不删锁文件**（文件常驻） |
| `unlock()` | 不再以「文件是否存在」判断（该判据与删除行为互相矛盾） |
| `stop()` | 不再按 cmdline kill ssr-rules；守护进程已由 `ssr-rules -K` 按 pid 文件停止 |

**验证**：

- 并发 restart × 5 轮、三并发 × 3 轮：ERROR 增量**全部为 0**
  （修复前每轮必现）。
- 锁的 A/B 对照（两个持锁 3s 的 worker 并发）：
  修复后总耗时 **6s**（真正串行），原版 **3s**（同时进入）。
- 串行 restart × 5 次：增量 0（未引入回归）。
- 端到端：`nft list tables` 含 2 个 ss_spec 表、`:5335`/`:1234` 均在监听、
  `fwmark 0x53535250` 规则在位、`global_server` 未被写成 nil、
  国内域名解析正常、`curl https://www.google.com` 经代理返回 302。
- `fw4 check` → `Ruleset passes nftables check.`
- 语法：`sh -n`（dash）通过；`.gitattributes` 要求的 LF 行尾保持（CR 字节 = 0）。

### 已知问题（本次未修，独立缺陷）

**`dnsmasq reload` 不会重新读取 conf-dir，导致 SSR-Plus 的 gfw 分流在
某些时机不生效。** 这是排查本轮故障时**顺带发现**的独立问题，
与上面的并发缺陷无关，未在本次改动范围内。

实测证据：往 `/tmp/dnsmasq.d/dnsmasq-ssrplus.d/` 放
`address=/zz-probe.invalid/3.3.3.3` 后，
`/etc/init.d/dnsmasq reload` → 探针解析**无结果**；
`/etc/init.d/dnsmasq restart` → 解析得 `3.3.3.3`。
dnsmasq 的 `SIGHUP` 只清缓存、不重读配置文件。

而 OpenWrt 的 `reload_service()` 是
`rc_procd start_service "$@"; procd_send_signal dnsmasq "$@"` ——
`start_service` 会重新生成 `/var/etc/dnsmasq.conf.*`，但 `SIGHUP` 不会
让已运行的进程重新读它，因此**新增的 conf-dir 文件对运行中的 dnsmasq 不可见**。

v0.8.3 把 `stop()`/`start()` 里的 `dnsmasq restart` 改成 `reload`，
目的是避免 restart 期间约 3 秒全断。这个目的达到了，但副作用是：
**SSR-Plus 重建 gfw_list.conf 后，dnsmasq 可能仍用旧内容**，
表现为部分国外域名拿到污染答案（实测 `www.reddit.com` 曾返回
`157.240.7.20` / `2001::1`，而直连 mosdns:5335 返回正确的
`151.101.x.x`）。

需在「零中断」与「配置必生效」之间重新取舍（候选：只在
gfw_list.conf 的 md5 变化时才 restart；或改用
`/etc/init.d/dnsmasq restart` 但把中断窗口压到最小）。
**改动此项属修改 DNS 配置，须先申请批准**（见 AGENTS.md 第 9 节）。

## [v0.8.5] - 2026-10-19

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v085)

## [v0.8.4] - 2026-10-17

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v084)

## [v0.8.3] - 2026-10-17

### 修复 — `restart` 期间 dnsmasq 被重启两次，客户机中断约 8 秒

`/etc/init.d/shadowsocksr` 的 `stop()` 与 `start()` **各自**执行一次
`/etc/init.d/dnsmasq restart`，而 `restart` 由 `/etc/rc.common` 实现为
`stop + start`，于是一次 `restart` 把 dnsmasq 重启**两次**。

实测（0.5 秒粒度记录 PID）：

```
修复前：22:45:18 → 22:45:21   又  22:45:32 → 22:45:35   ← 断两次
修复后：22:48:09 → 22:48:12                              ← 只断一次
```

每次 dnsmasq 不可用约 **3 秒**，期间客户机**所有**域名（含国内 baidu）
全部无法解析。

另：实测 `dnsmasq reload`（SIGHUP 重读配置）**失败 0 次**，且能正确加载新增的
`server=/域名/127.0.0.1#5335` 分流（已验证：临时写入
`server=/reloadtest.example/127.0.0.1#9999` 后 reload，查询确实被送往 `:9999`）。

### 变更

1. 覆写 `restart()`，设置并导出 `SSR_IN_RESTART=1`
2. `stop()` 内那次 dnsmasq `restart` 加标志守卫，restart 场景下跳过
3. 两处 `dnsmasq restart` 一律改为 `dnsmasq reload`（`restart` 计数降为 0）

**已验证**：`shadowsocksr restart` 全程 DNS 失败 0 次、dnsmasq PID 不变。

## [v0.8.2] - 2026-10-17

### 修复 — `ssr-switch` 把 `global_server` 写成 `nil`，导致客户机全部解析超时

v0.8.1 关闭 `enable_switch` 只是让守护**不再启动**，既管不住已在跑的守护，
也没修 `set_main_server()` 本身的缺陷。本轮补上真正的根因修复。

**监控日志给出了确凿的切换轨迹**（每 2 秒采样 `global_server`）：

```
22:02:31 *** gs=cfg014a8f → cfg194a8f   ← 被自动切到另一个节点
22:04:09 *** gs=cfg194a8f → nil          ← 再被切成 nil，客户机全挂
```

**根因：`set_main_server()` 只判空串，不判字符串 `"nil"`**

`/usr/bin/ssr-switch` 原实现：

```sh
set_main_server() {
	local sid="$1"
	[ -n "$sid" ] || return 1        # ← 只判空串
	uci set shadowsocksr.@global[0].global_server="$sid"
	uci commit shadowsocksr
}
```

而 `select_proxy()` 在全部候选节点探测失败时，把 `ENABLE_SERVER` 置为
**字符串 `"nil"`**（不是空串）。于是 `set_main_server "nil"` 顺利通过
`-n` 检查，`uci set global_server=nil` **落盘**。

后果链条：`load_config()` 见 `GLOBAL_SERVER=nil` 直接 `return 1`
→ 一条 nft 规则都不装、MosDNS/Xray 全不启动
→ 但 LuCI 里 `enable=1` 仍显示「运行中」
→ 客户机 DNS 全部 timeout，而路由器自身因走 `/etc/resolv.conf` 的
运营商 DNS 而显得正常（这就是「路由侧正常、客户机挂」的物理原因）。

**客户端实测症状与 DNS 无关，是连通性假象**：`conntrack` 显示

```
tcp SYN_SENT src=192.168.3.238 dst=20.205.243.166 dport=443 [UNREPLIED]
tcp SYN_SENT src=192.168.3.238 dst=104.244.42.197 dport=443 [UNREPLIED]
tcp ...      src=192.168.3.238 dst=171.108.221.221 dport=443 [OFFLOAD]   ← 国内正常
```

国内 TCP 正常 `[OFFLOAD]`，国外 TCP 全停在 `SYN_SENT` 无回应。
用户侧表现为「ping 通、HTTP 无 200」/ `os error 11001`。

### 变更

**`files/etc/uci-defaults/99-gaming-optimize`：给 `ssr-switch` 打两处幂等补丁**

| 补丁 | 内容 |
|---|---|
| (a) | `set_main_server()` 增加 `[ "$sid" != "nil" ] \|\| return 1`，显式拒绝写 nil |
| (b) | `run_once()` 的 else 分支不再盲写 `CURRENT_SERVER`，改为「保留原节点只重启」 |

两处都带 `修复 v0.8.2` 标记，打前先 `grep -q` 判重，因此**幂等**。
补丁后立刻 `sh -n` 校验，失败则自动回滚到 `.orig`
（遵循红线 3：禁止静默失败）。

**已验证**

- `set_main_server "nil"` 单元测试 → **返回 1（拦截成功）**，`global_server` 未被改动
- 脚本连跑 2 次：`gs=cfg014a8f`、`switch=0`、`nil防护=2`、`rule=14` **全部稳定**
- `sh -n /usr/bin/ssr-switch` 通过
- 客户机 5 分钟长窗口（每 30 秒一轮）：`gs` 保持 `cfg014a8f` 不再被改写

### 本轮方法论的教训（重要）

1. **「路由侧正常、客户机挂」这个组合本身就把矛头指向 SSR-Plus 的
   `global_server` 状态，而不是 DNS 配置。** 路由器走
   `/etc/resolv.conf`（运营商 DNS），完全绕过 dnsmasq/mosdns；
   只要客户机挂而路由器不挂，问题必在 `dnsmasq → dnsproxy/mosdns` 这条链上，
   而这条链在 `gs=nil` 时会整体失踪。
2. **必须监控 `global_server` 的变化，而不是只看某一时刻的组件状态。**
   我此前反复在「健康态」里测，每次都通过；只有按 2 秒粒度连续采样
   `global_server`，才看见 `cfg014a8f → cfg194a8f → nil` 的完整轨迹。
3. **`pgrep -f` 会匹配到诊断命令自身。** 一度报告「ssr-switch 有 2 个进程」，
   实际是 `pgrep -f "ssr-switch start"` 命中了自己的 `ash -c` 命令行。
   判定应遍历 `/proc/*/cmdline` 并排除 `ash -c`。

## [v0.8.1] - 2026-10-17

### 修复 — `ssr-switch` 周期性 restart 导致客户机 DNS 间歇失败

**故障现象**（用户复核后）：启用 SSR-Plus 后，客户机解析**时好时坏**；
`www.codebuddy.cn` 等域名偶发失败，而**路由器侧始终正常**；
dnsproxy 日志同时刷 `1.12.12.12` DoH 的 `context deadline exceeded`。

**根因：`enable_switch='1'` 让 `ssr-switch` 周期性重启整个服务**

`/usr/bin/ssr-switch` 每 `switch_time` 秒（本机 **667s**）探测当前节点，
失败即执行 `/etc/init.d/shadowsocksr restart`（脚本第 155 行）。
而 `start()` 的执行顺序制造了一个**必然的 DNS 空窗**：

```
21:39:35  gs=cfg014a8f  5335=0  1234=1  nft=0  gfw=23701   ← 分流已生效，后端未起
21:39:37  gs=cfg014a8f  5335=1  1234=1  nft=2  gfw=23701   ← 才就绪
```

即 `gfw2ipset` 先把 **23701 条** `server=/域名/127.0.0.1#5335` 拷进 dnsmasq，
约 2 秒后 `start_dns`/`start_server` 才拉起 MosDNS/Xray。这 **4 秒窗口**
内查任何 gfw_list 里的域名都 timeout。0.5 秒粒度采样已固证。

**探测本身还会误判**：`switch_time=3`（脚本内变量）是 **curl 超时 3 秒**，
跨境节点的 TLS 握手常超过它。探测失败且全部候选节点均判失败时，
`select_proxy` 返回 `ENABLE_SERVER=nil`，`switch_proxy` 便
`uci set global_server=nil` —— 界面仍显示「已启用」，但 `load_config()`
`return 1`，**一条规则都不装**，进入「已启用但空转」的半死状态
（本次多次实测到 `enable=1` 而 `global_server=nil`、无 `ss_spec` 表）。

另需注意：本机 68 个节点中 62 个共用同一域名
`unamecf.xn--ghqu5fm27b67w.com` → `108.162.198.60`（Cloudflare 地址）。
`nc -z` 对该地址报「不可达」，但 Xray 侧有 **ESTABLISHED** 连接
（`100.119.107.42:52836 → 108.162.198.60:443`），说明节点实际可用 ——
**裸 TCP 探测对这类地址不可信**，这也正是 ssr-switch 误判的来源。

### 变更

**`files/etc/uci-defaults/99-gaming-optimize`：`enable_switch='0'`**

单节点家用场景不需要自动切换，其收益远小于周期性中断的代价。
关闭后 `start_switch()` 的 `if` 不成立，守护不再启动，重启只在手动操作
或开机时发生。已在文件内写明「若日后确需自动切换」的三个前置条件：
①`switch_time`（探测超时）≥ 10s；②全节点失败时**保留原 `global_server`**
而非写 nil；③修 `start()` 顺序为「后端就绪后再装分流」。

**已验证**：连跑 10 轮 × 3 个此前失败域名（`www.moe.gov.cn`、
`www.codebuddy.cn`、`www.stats.gov.cn`），**10/10 全部正常，0 次失败**。

### 同时确认（无改动）

- `www.codebuddy.cn` / `www.moe.gov.cn` **均不在** `gfw_list`、`gfw_base`、
  `applechina.conf`、`deny.list` 中；`applechina.conf` 无宽泛通配条目。
  24 项清单复核结果：`codebuddy`/`dnse5`/`cn`/`com` 命中数均为 **0**。
- 解析到的 IP（`171.108.x`、`211.100.0.108`）**均落在 `nft @china` 内**，
  走直连、不经代理。
- `@china` 运行时集合覆盖三家国内 DoH（`223.5.5.5` / `1.12.12.12` /
  `36.99.170.86`），故 dnsproxy 的 DoH 出站**不会**被 `ss_spec` 劫持。
  那批 `1.12.12.12` 超时是**同一条 PTR 查询重试 3 次**（间隔恰为
  `--timeout 10s`：20:59:23/33/43），针对 `lb._dns-sd._udp.*.in-addr.arpa`
  反解；`parallel` 模式下其他上游仍在答，属噪声，非故障源。

### 排查方法沉淀（新增两条）

- **判定进程是否存在，不能用 `pgrep -x <名字>`**：SSR-Plus 的二进制以
  完整路径运行（`/var/etc/ssrplus/bin/v2ray`、`.../mosdns`），
  `pgrep -x xray` / `pgrep -x mosdns` 恒为 0，会误判成「后端没起」。
  应按 `/proc/*/cmdline` 匹配，或 `pgrep -f '/var/etc/ssrplus/bin/'`。
- **`nc -z` 不能用来判断代理节点可用性**：Cloudflare 前置的节点对裸 TCP
  不响应，但真实 TLS 握手正常。判据应看 `netstat -antp` 里是否有
  **ESTABLISHED** 到节点的连接，或直接测经代理解析/访问的结果。

## [v0.8.0] - 2026-10-17

### 修复 — 启用 ShadowSocksR Plus+ 后客户机 DNS 解析失败

**故障现象**（经用户复核后的准确描述）：启用 SSR-Plus 后，`192.168.3.254`
后的**客户机**解析异常；**路由器自身**不受影响；禁用后恢复。

**⭐ 结论先行：`filter_aaaa=1` 就是「国外去 AAAA、国内保双栈」的正确实现**

用户诉求是「国外不走 IPv6 直连（避免被 RST），国内保持双栈」。经实测，
当前 `shadowsocksr.@global[0].filter_aaaa='1'` **已经精确实现该语义**，
无需改动。实测（`Check-DnsName.js`，原始 UDP 绕过缓存）：

| 域名 | 归类 | A | AAAA | AAAA 耗时 |
|---|---|---|---|---|
| `www.moe.gov.cn` | 国内（不在 gfw_list） | ✅ `211.97.84.77` | ✅ `2408:875c:0:80::6c` | 28ms |
| `www.cac.gov.cn` | 国内（不在 gfw_list） | ✅ `27.155.113.144` | ✅ `240e:95c:806:40::413` | 36ms |
| `www.github.com` | 国外（在 gfw_list） | ✅ `4.237.22.38`（经代理） | ⛔ 空答复 | **1ms** |
| `www.youtube.com` | 国外（在 gfw_list） | ✅ `142.251.154.4` | ⛔ 空答复 | **1ms** |
| `www.wikipedia.org` | 国外（在 gfw_list） | ✅ `103.102.166.224` | ⛔ 空答复 | **1ms** |

**关键：国外 AAAA 是「1ms 空答复」而不是「5 秒超时」。** 客户端收到
`rcode=0 an=0` 会**立刻**回落查 A，不会等待。早先把这一形态误读为超时，
是本轮排查中最严重的一次误判（见下方「误判修正」）。

**分流依据（三份清单，规模为实测）**

| 清单 | 规模 | 作用 |
|---|---|---|
| `gfw_list.conf` | 23701 条 `server=/域名/127.0.0.1#5335` | 国外域名 → MosDNS |
| `gfw_base.conf` | 55 条 | 同上（基础集） |
| `applechina.conf` | 173 行明文 `114.114.114.114` | Apple 域名走国内明文 |
| `black.list` | 0 行 | 为空，不参与 |
| `deny.list` | 13 行 | 广告/禁止域名 |

国内域名**不在**上述清单内，因此走 dnsproxy:5353 的国内 DoH，双栈不受影响。

**实测证据（受控启停，非推测）**

客户机侧用原始 UDP（绕过系统缓存）：

| 场景 | `:5335` | `ss_spec` 规则 | 国内 A | 国外 A | 国外 AAAA |
|---|---|---|---|---|---|
| SSR 禁用 | 无监听 | 无 | 3/3 | 3/3 | ⚠️ 返回**污染值** `2001::1` |
| SSR 启用（后端正常） | 监听 | 有（2 表） | 3/3 | 3/3 | ⛔ 空答复 1ms（**预期**） |
| SSR 启用 + 后端全挂 | 无监听 | 有 | 3/3 | ❌ 超时 | ❌ 超时 |

**注意第 1 行**：禁用 SSR 时国外 AAAA 拿到的是
`2001:0:0:0:0:0:0:1` / `2001:df2:e500:ed1a::1` 这类**污染地址** ——
这正是「国外 IPv6 直连被 RST」的成因，也是必须启用 SSR 的理由之一。

**根因（真正需要修的，两条）**

1. **`stop()` 无法可靠停干净：`ssr-switch` 会在 stop 期间把后端重新拉起。**
   实测：`uci set enable=0` + `/etc/init.d/shadowsocksr stop` 之后，
   `enable=0` 但 `v2ray`(:1234)、`mosdns`(:5335) 仍在运行、
   `ss_spec` 两张表仍在、`ip rule 999` 仍在 —— 形成
   「已禁用但规则与后端都活着」的半停状态。此时客户机行为不受控。
   正确的手工清理顺序（已实测有效）：
   ```sh
   pkill -9 -f ssr-switch            # 必须先杀守护，否则它会把后端拉回来
   rm -f /var/lock/ssr-switch.lock
   uci set shadowsocksr.@global[0].enable='0'; uci commit shadowsocksr
   /etc/init.d/shadowsocksr stop
   pkill -9 -f '/var/etc/ssrplus/bin/'
   nft delete table inet ss_spec; nft delete table ip ss_spec_mangle
   ip rule del fwmark 0x53535250 table 999
   rm -f /tmp/dnsmasq.d/dnsmasq-ssrplus.conf
   rm -rf /tmp/dnsmasq.d/dnsmasq-ssrplus.d
   /etc/init.d/dnsmasq restart
   ```

2. **`gfw_list.conf` 在 stop 之后仍会残留在 dnsmasq 的 conf-dir 里。**
   实测：清理后 `dnsmasq-ssrplus.d/gfw_list.conf` 仍在（23701 条指向已死的
   `:5335`），导致**国外域名全部超时、国内正常**。必须显式删掉该目录并
   `restart dnsmasq`。这不是「自动」发生的 —— 是 stop 路径没清理干净。

**本版落地的改动**

1. **`files/etc/config/dnsproxy`：移除「24 个国外域名 → 127.0.0.1:5335」例外清单。**
   这 24 个域名在 `gfw_list.conf` 里 **24/24 全部命中**，属重复声明；
   而 SSR **禁用**时它是纯故障源 —— `:5335` 无监听 → dnsproxy 打
   `connection refused` → 回落 `https://1.12.12.12/dns-query` → 拿到污染答案。
   实测（移除前）：`youtube.com → 31.13.92.37`、`wikipedia.org → 31.13.94.36`
   （均为 Facebook 的 IP）；同时刻不在清单里的域名全部正常
   （`blogspot.com → 65.49.68.152`、`wordpress.com → 192.0.78.9`）。
   移除后 dnsproxy 只依赖国内 DoH 主链，不再隐式耦合 SSR-Plus 运行状态。

2. **`files/etc/uci-defaults/99-gaming-optimize`：`dhcp.@dnsmasq[0].dnsforwardmax='1024'`。**
   dnsmasq 并发转发槽默认仅 150。**防御性配置，非本次已证根因** ——
   故障窗口内 `logread | grep -c 'Maximum number of concurrent'` = 0。

3. **`files/etc/uci-defaults/99-gaming-optimize`：修复 ICMPv6 规则的非幂等。**
   原写法裸调 `uci add firewall rule`，每执行一次多一条 `ICMPv6-Input`/
   `ICMPv6-Forward`（实测连跑三次 → 各 3 条）。改为先按 name 查已有索引、
   存在则就地改写。连跑 3 次验证规则总数稳定在 14，每样恰好一条。
   **踩到的坑**：`uci set "$R.name='值'"` 会把单引号存进值里，
   导致按 name 精确匹配永远失败 —— 必须写 `uci set "$R.name=值"`。

**已验证**（路由器实测）

- `dnsproxy` 命令行不再含 `5335`：`--upstream` 只剩 alidns / 1.12.12.12 / doh.360.cn
- `dnsmasq` 生成配置含 `dns-forward-max=1024`（`/var/etc/dnsmasq.conf.cfg01411c` 第 13 行）
- 国内域名双栈保留，国外域名 A 正常、AAAA 1ms 空答复
- 彻底清理后客户机与路由器均恢复正常

**⚠️ 误判修正（本轮排查的教训，务必记住）**

排查过程中有三次判断被自己的测试方法误导：

1. **内联 Node 脚本的 DNS 报文匹配有 bug**，把无效响应当超时，导致
   误判成「国内域名也全挂」。改用 `Check-DnsName.js`（校验事务 ID +
   问题段回显 + 区分 EMPTY/NX/TIMEOUT）后结论反转：**国内一直正常**。
2. **`pgrep -x xray` / `pgrep -x mosdns` 匹配不到**实际进程 —— 它们以
   `/var/etc/ssrplus/bin/v2ray`、`/var/etc/ssrplus/bin/mosdns` 的完整路径运行。
   必须按 cmdline 匹配，不能按 exec 名。
3. **`luci-app-ssr-plus` 的「连通性检查」不能用于诊断 DNS。**
   其实现是 `/usr/lib/lua/luci/controller/shadowsocksr.lua` 第 1616 行：
   ```lua
   e.ret = luci.sys.call("curl -m 3 -sS -o /dev/null http://www." .. target .. ".com")
   ```
   它①走 `/etc/resolv.conf` 的运营商 DNS，**完全绕过 dnsmasq**；
   ②只测 `www.baidu.com`/`www.google.com` 的 HTTP 可达性，不看解析结果。
   因此无论 SSR 是否故障，它都会显示「连接正常」。

**未在本版修复（需改 `luci-app-ssr-plus` 上游脚本，另开 patch 承接）**

| 项 | 内容 |
|---|---|
| P1 | `global_server=nil` 时显式报错退出，而非静默空转 |
| P2 | 规则重建应「后端先起、断言 `:5335`/`:1234` 在监听、再装规则」 |
| P3 | `ln_start_bin` 的 `>/dev/null 2>&1 &` 应把 stderr 落到 `/var/log/ssrplus.log` |
| P5 | `stop()` 应先杀 `ssr-switch` 再停后端，并清理 `dnsmasq-ssrplus.d/` |

已核实：路由器装的是 helloworld `luci-app-ssr-plus 196-r19`（init 脚本
102,793 字节，md5 `9537dab2…`），上游 master 同一脚本只有 65,763 字节
（md5 `6db4ab8f…`），两者 `start()` 结构差异显著 —— 基于路由器副本做的
patch 无法 apply 到 CI 拉取的 master。故本版只落地不依赖上游的改动。

**已知遗留**：国内 DoH 上游对部分被墙域名本身就返回污染答案
（实测 `1.12.12.12` 的 DoH：`youtube.com → 174.132.167.252`、
`wikipedia.org → 31.13.88.169`）。SSR 禁用期间这些域名只能得到上游给的
答案，这是「禁用代理」的固有代价。

### 当前完整解析链路（v0.8.0 实测）

```
客户机 (192.168.3.x)
  │  DNS 查询 UDP/TCP 53
  ▼
┌─────────────────────────────────────────────────────────────┐
│ fw4  chain dns_intercept_lan                                │
│   type nat hook prerouting priority dstnat+1 (-99)          │
│   iifname br-lan udp/tcp dport 53 → redirect to :53          │
│   （把客户机发往任意 DNS 的查询都劫持到本机 dnsmasq）          │
└─────────────────────────────────────────────────────────────┘
  ▼
dnsmasq :53   (noresolv=1, dns-forward-max=1024, cache 8192)
  │
  │  ① 先查本地缓存 / DHCP 租约 / /etc/hosts
  │  ② 按 server=/域名/ 精确前缀匹配选择上游：
  │
  ├─【国内域名 + 所有未被清单命中的域名】──────────────────────┐
  │   默认 server=127.0.0.1#5353                              │
  │   ▼                                                        │
  │ dnsproxy :5353  (ALL_DOH, upstream_mode=fastest_addr)      │
  │   ├─ https://dns.alidns.com/dns-query   → 223.5.5.5        │
  │   ├─ https://1.12.12.12/dns-query       → 1.12.12.12       │
  │   └─ https://doh.360.cn/dns-query       → 36.99.170.86     │
  │   （三者均落在 nft @china 内，SSR 不代理，直连）             │
  │   fallback: https://1.12.12.12/dns-query                   │
  │   bootstrap: 223.5.5.5 / 223.6.6.6（仅解析上游主机名）      │
  │   ▼                                                        │
  │ 返回【真实 A + 真实 AAAA】→ 国内双栈直连                     │
  │                                                            │
  ├─【国外域名：gfw_list.conf 23701 条 + gfw_base 55 条】───────┤
  │   server=/<域名>/127.0.0.1#5335                            │
  │   ▼                                                        │
  │ MosDNS :5335  (SSR-Plus 管理, pdnsd_enable=4)              │
  │   启用 sequence: main_sequence_disable_IPv6                │
  │   ├─ qtype 28(AAAA) / 65(HTTPS) → reject 0  ← 去 AAAA      │
  │   ├─ prefer_ipv4                                           │
  │   └─ forward → https://dns.google/dns-query                │
  │                 https://cloudflare-dns.com/dns-query       │
  │                 （经 Xray/v2ray 代理出站，防污染）           │
  │   ▼                                                        │
  │ 返回【真实 A】+【AAAA 空答复(1ms)】                          │
  │   └→ 客户端立即回落 IPv4 → 走 ss_spec redirect to :1234     │
  │                                                            │
  └─【applechina.conf 173 行】→ 明文 114.114.114.114（直连）    │
                                                               │
  【deny.list 13 行】→ address=/域名/ → 拦为 0.0.0.0           │
└──────────────────────────────────────────────────────────────┘

代理链路（只影响 TCP/部分 UDP，不影响 DNS 解析本身）
  客户机 TCP → fw4 ss_spec_prerouting (priority filter, 晚于 dstnat+1)
             → ip daddr @china return（国内直连）
             → 其余 → ss_spec_wan_fw → redirect to :1234
             → Xray/v2ray → 国外服务器

IPv6 策略（用户明确要求）
  国内域名：保留真实 AAAA → IPv6 直连（实测 moe/cac 通）
  国外域名：AAAA 被 MosDNS reject → 无 AAAA 可用 → 只能走 IPv4 代理
             （避免「拿到污染 AAAA → 直连被 RST」的老问题）
```

### 排查方法沉淀

- 「启用后全挂」这类问题，**必须先区分四种结果**：`OK` / `EMPTY`
  （rcode=0 且 an=0）/ `NX`（rcode=3）/ `TIMEOUT`（无任何响应）。
  `EMPTY` 是**合法答复**，客户端立刻回落；只有 `TIMEOUT` 才会卡住客户端。
  把 `EMPTY` 当失败会得出完全错误的结论。
- 判定进程是否在跑，**按 `/proc/*/cmdline` 匹配完整路径**，
  不要用 `pgrep -x <名字>`（SSR-Plus 的二进制以完整路径运行）。
- 判定 UCI 改动是否真的落到进程，**看 `/proc/<pid>/cmdline` 与生成的配置文件**，
  不要只看 `uci show`。
- **不要用 SSR-Plus 的「连通性检查」诊断 DNS** —— 它走运营商 DNS，
  与 dnsmasq 链路无关。
- 在路由器上做并发实验时，`( cmd ) &` 会随 plink 会话结束被杀，
  **压不出真实并发**；两次「离线复现失败」都源于此。

## [v0.7.0] - 2026-10-13

### 变更 — 全链路移除 Telegram 机器人（含其 tab 与控制项）

按用户要求**完整下线** Telegram：不只是隐藏界面，而是把实现、接口与配置
一并从固件里拿掉。判为 MINOR（改动的是「组件」集合；本项目尚未到 1.0，
不适用 MAJOR 的对外接口破坏语义）。

**删除的文件（4 个）**

| 文件 | 原本作用 |
|---|---|
| `htdocs/.../view/trafficctl/telegram.js` | Telegram 配置页（页面级 tab） |
| `root/etc/init.d/trafficctl-telegram` | procd 服务脚本（`respawn` 型长轮询） |
| `root/usr/local/bin/trafficctl-telegram.sh` | Bot 守护进程本体（27 KB） |
| `root/usr/local/bin/trafficctl-telegram-test.sh` | 「发送测试消息」按钮的后端 |

**清理的引用点**

| 位置 | 处理 |
|---|---|
| `menu.d` | 删掉 Telegram tab 登记；`portfw`/`host` 的 order 3/4/5 → 3/4 |
| `acl.d` | 删掉 `telegram_config_get` / `telegram_config_set` / `telegram_test` 三项授权 |
| `rpcd/luci.trafficctl` | 删掉上述三个方法的签名与实现、`log_telegram` 读写 |
| `etc/config/trafficctl` | 删掉整个 `config telegram` 段与 `option log_telegram` |
| hotplug 新设备脚本 | 删掉「写 Telegram 通知标记」整段 |
| `trafficctl-fw.sh` | 删掉 `telegram*` 日志分类映射 |
| `Makefile` | postinst 不再启动该服务；**prerm 停用它**（见下） |
| `common.js` | `loggingSet` 去掉 `log_telegram` 参数位 |
| `status.css` | 删掉 Telegram 专用样式；`--tg-primary` 变量一并移除 |
| `README.md` | 删掉功能表、截图、依赖、快速上手、架构图与文件清单里的 Telegram |
| `po/` + `pot` | 删掉 3 条已无来源的 Telegram 译文（po 505 → 502 条） |
| i18n 工具 / patch 生成器 | 从文件清单移除，并给生成器加「删除文件」支持 |

### 变更 — 活动日志的「Telegram」分类开关一并移除

该分类只标记**由 Telegram 触发**的操作。来源消失后它永远不会再产生日志，
留着就是一个拨了没反应的死开关。日志分类现为 **阻断 / 速率限制 / 整形 / 配置**。

### 变更 — `tg-*` 类名改为 `tc-*`

`.tg-save-status` / `.tg-input` / `.tg-btn` 三个类**从来不是 Telegram 专属**：
设备页「保存为路由器默认值」的按钮与保存状态、设置页「新设备默认限速」的
数字输入都在用它们。Telegram 移除后继续用 `tg-` 前缀，等于用类名指向一个
已不存在的功能，故改名为 `.tc-save-status` / `.tc-input` / `.tc-btn`。
其余 `.tg-*`（消息气泡、内联键盘预览、分段控件、状态点等）确为 Telegram
专用，随视图一并删除。

### 修复 — 顺带修掉一个静默的进程缺陷

`trafficctl-telegram` 是 **`respawn` 型** procd 服务。opkg 升级顺序为
**prerm → 按旧文件清单删除 → postinst**：若把停机写在 postinst（我最初如此），
那时 init.d 脚本已被删除，procd 服务无从 `stop`，而被删掉的二进制仍可能被
反复重启。故停机移到 **prerm**（文件还在这刻停），并保留 `disable`。

### 升级路径（旧路由器）

`postinst` 幂等地清理三样**不归包文件清单管**的残留：

1. `/etc/config/trafficctl` 的 `config telegram` 段（conffile 整份保留）
2. `/etc/rc.d/*trafficctl-telegram` 开机软链
3. `/etc/trafficctl/telegram_known.json`（在 keep.d 中，跨 sysupgrade 保留）

留着它们等于把一个「界面上已无处可填、也永不生效」的 bot token 继续留在盘上。
全新安装时这些都不存在，是空操作。

### 验证

- **不变量**：新增 17 条断言（4 个文件缺席、menu.d/acl.d/rpcd/UCI/hotplug/
  fw.sh/common.js 逐层无残留、postinst 不启动 + prerm 停用、po 无孤儿条目）。
  `100755` 索引计数 29 → **26**（随 3 个可执行文件删除同步更新）。
  全绿，无 FAIL。
- **patch 链**：`0006-remove-telegram.patch`（含 3 处文件删除）在干净上游基线上
  重放成功，与 vendored 包**逐字节一致**。
  patch 生成器新增「删除文件」能力（此前只能改/加），并区分两种删除：
  上游存在的文件才能写进删除清单 —— `telegram.js` 是本仓库新增的，对它
  做「删除上游不存在的文件」会直接套用失败。
- **i18n**：po 505 → 502 条，pot 重生成 376 条，Telegram `msgid` 归零，覆盖率完整。
- **路由器实测**（192.168.3.254，先备份 `/root/trafficctl.v0.6.10.bak`）：
  - 顶部 tab 行 `设备 / 设置 / 端口转发` —— Telegram 已消失
  - 设置页日志分类 `阻断 / 速率限制 / 整形 / 配置`；`#tm-log-telegram` 不存在
  - 页面正文不再出现字符串 "Telegram"；控制台 0 错误
  - `ubus -v list luci.trafficctl` 里 Telegram 计数 0；
    `ubus call … telegram_config_get` → `Method not found`
  - 4 个文件已消失、rc.d 软链已清、`uci show trafficctl.telegram` 无输出、
    `log_telegram` 不存在、相关进程数 0
  - **回归**：设备页 21 行、20 个「限制」链接、限速弹层正常打开；
    设置页三张卡片、保存状态与数字输入的新类名均生效
- 类名改名后旧 `tg-*` 计数 0，新 `.tc-save-status` 3 处、输入框为
  `tc-input tc-input--num`。

## [v0.6.9] - 2026-10-13

### 变更 — 三个视图开关移除，三者恒开

「统计 / 连接 / 活动日志」三个滑动开关已移除，对应区块**恒开**。它们都是
「关掉就少看一块信息」，留着只是让人每次先确认一遍状态。视图开关行现在
只剩「扩展统计」与「反向DNS」两项。

随之作废 `showStats` / `showConns` / `showActivity` 三个选项。
**活动日志的内容必须在首屏主动加载** —— 原先那一步挂在开关的勾选回调里，
开关一移除就没人触发，这一段会永远空白（已加断言守住）。

### 变更 —「所有设备」移到搜索框左侧，移除最近设备

设备选择行原为「搜索框 + 最近设备 chip + 所有设备」，现只剩两个，
顺序为 **所有设备 | 搜索框**（用户指定）。最近设备 chip 行已移除；
`addRecentDevice` 仍在记录访问历史，只是不再有地方展示（将来若要恢复，
函数与存储都还在）。

### 变更 — 移除目标/共享/网段与速率档位行

用户框选的两块已删除：

| 删除内容 | 原先作用 |
|---|---|
| 最近设备 chip | 快速跳到最近看过的设备 |
| 目标输入框 + 共享（每台设备/共享） | 指定限速作用的网段与分配方式 |
| 整个网络/网段 chip | 同上，常用的网段一键填入 |
| 速率档位行（关/1Mbit…/自定义/上下行分别设置） | 选速率 |
| Shaper-Limiter 切换（原在卡片标题栏） | 选限速方式 |

「速率限制」卡片因此只剩：**标题 → 所有设备+搜索框 → 已有的网段限制 →
切断全网访问 → 视图开关**。实测卡片高度 **271px → 195px**。

**保留**「已有的网段限制」列表：它不在被删范围内，而且是既有全局限速
**唯一**可见、可删的地方 —— 删掉会让此前设过全网/网段限速的人再也去不掉
那条规则。

### 变更 — 限速入口移进设备表的「限制」

删掉卡片里的速率选择后，限速改从**设备表每行的「限制」**设置（用户选定）。
点它在该行旁边弹出限速设置：速率档位 + Shaper-Limiter + 上下行分别设置。

原先那个「限制」链接只是把目标设为该设备、再让你滚回卡片去点速率 ——
两步且要来回找。现在点哪台就设哪台，弹层标题写明设备名。

同一套部件实例与同一套切换逻辑被复用，只是换了挂载点。弹层挂在
`document.body` 上（脱离表格的 overflow 裁剪），点外部 / Esc / 再点关闭，
两个 `document` 监听器与 DOM 都随 `handleTeardown` 摘除。

### 修复 — 顺带修掉两个既有缺陷

1. **「上下行分别设置」从来没显示过**：`upRow`（上行速率输入行）构造后
   从未被挂进 DOM —— 那个按钮切换的是一个游离节点，点了永远看不到输入框。
   现已挂进弹层，功能恢复。
2. **弹层定位会落到屏幕外**：起初只按 `min(行底+4, 视口高-40)` 夹住，
   而弹层实测 **192px** 高、当时只剩 40px → 大半在屏幕外（截图为证）。
   改为**先显示再量真实高度**，下方放不下且上方更宽裕时翻到该行上方。
   实测翻转生效（下方不足时 `top=10`，完整落在视口内）。

### 验证

- 三个开关：开关行只剩「扩展、反向DNS」；统计/连接表/活动日志三块均可见。
- picker 行：子元素实测为 `[📊 所有设备, 搜索框]`，按钮左边界 < 输入框左边界。
- 删除项：`hasRateChips: false`、`hasScopeRow: false`、`recentChips: 0`；
  卡片子元素仅 `[header, picker-row, subnet-limits, cut, tail]`。
- 弹层：点「限制」打开，标题正确（命名设备显示「ALN-AL80 — 192.168.3.201」、
  无名设备只显示 IP）；档位 chip 10 个；Esc 关闭；点外部关闭；点档位不关闭。
- 定位：小视口（900px）滚到表中部后弹层翻到上方、`fullyInViewport: true`。
- 单设备模式：所有设备仍在搜索框左侧、所选设备保留在输入框、连接表可见。
- 控制台 0 错误；不变量校验全绿（新增 16 条断言）；i18n 完整。

### 说明 — 测试限速已撤销

验证弹层交互时点了一次「5 Mbit/s」，即真的给 192.168.3.203 设了限速。
随即点「关」撤销，并在路由器上确认：`nft list tables` 只有
`trafficctl_mon` / `fw4` / `ss_spec`，**无任何限速表**，`tc class` 在 br-lan 上
为 0 条 —— 规则已清干净。

## [v0.6.8] - 2026-10-13

### 变更 — 可见列改为复选框，且只列未显示的列

「可见列」弹层里原先是**圆形 chip**（最多 20 个，铺成五行、每行长短不一），
要在一堆同色小圆里找某一列。现改为**一行一个复选框**：命中区域大、左边缘对齐、
勾选状态一眼可读。

同时把**默认就显示的列**从清单里移除。它们本来就看得见，再给一个开关只会让人
以为「没勾上就是没有」。清单从 20 项减到 **7 项**（恰为默认隐藏的那一批）：
MAC、图表、字节、链路、应用、丢弃、队列。

### 变更 — 新增四个默认显示列：TCP | UDP | 互联网 | 限制

这四列原先默认隐藏、要在「可见列」里逐个打开。它们回答的是「这台设备在用什么、
有没有被限住」，属于日常判断的一部分，藏起来等于每次都要先开一遍。

默认列数 **9 → 13**，按用户指定顺序排在「操作」之后。实测四列都有真实数据
（首行 TCP 231.28 MB / UDP 2.01 MB），13 列在 1600px 下 `min-width` 1224px、
**无横向滚动**。

### 变更 — 概览常显并移到速率限制之上

- **移除「概览」开关**。它此前默认关闭，理由是「每拍多一次 rpcd 调用，
  不看的人不必付这个成本」；但实测这块信息（下载/上传/活跃设备/上联图/接口/排行）
  正是打开这一页最想先看到的东西，默认关着等于每次都要先点一下。它自己的开销
  （一次 `ifaces` 读取）已被防重入闸约束在同一拍内。
  随之作废 `showOverview` 选项，`pollIfaces` / `renderOverview` / `resize`
  三处判据统一只看 `isAllMode()`。
- **卡片移到速率限制之上**。概览回答「此刻网络怎么样」，是**读数**；速率限制是
  **操作**。读数放在操作上方才符合「先看后改」—— 此前顺序是 速率限制 → 概览 → 表格，
  等于每次都要先滚过一整张操作卡片才看得到读数。

视图开关行现为：统计 / 连接 / 扩展 / 反向DNS / 活动日志（少了「概览」）。

### 验证

- 结构：13 列且含 `tcp`、`udp`、`blocked`、`_throttle_kbit`；渲染顺序
  `overviewCard`(4589) → `rateLimitRow`(4590)；开关行不含「概览」。
- 复选框：7 项、`type=checkbox`、`allSameLeft: true`、行间距 25px、**零重叠**。
- 交互：勾选 MAC → 表格 13→14 列；取消 → 14→13 列；面板保持打开。
- 概览：默认 `overviewBodyVisible: true`；单设备模式下正确隐藏（只剩统计条）。
- 无横向滚动：13 列 `min-width` 1224px、容器 1285px。
- 控制台 0 错误；不变量校验全绿（新增 13 条断言）；i18n 完整。

### 修正 — 两处断言本身写得不对

- 「列开关写显式 false」断言在查 `= false`，而复选框改成了
  `= !cb.checked`。**改名后旧断言会永远失败**（这类不同步就会变成噪声，
  进而被忽略），已同步为新写法。
- 「概览卡片前置」断言里 `grep '^\t\t\t\t…'` 用了单引号 —— 其中的 `\t` 只是
  **字面反斜杠 t**，不是制表符，故永远匹配不到（报出「概览= 速率限制=」）。
  改用 awk 的 `[ \t]` 字符类。这是本仓库验证纪律记过的同一类坑。

## [v0.6.7] - 2026-10-13

### 变更 — 统计条并入上联概览卡片

「活跃 / 已阻断 / WiFi」原本是概览卡片**下方另起一行的窄条**，两者底部与表格
之间又各占一段间距 —— 视觉上是三块互不相干的东西，而它们说的其实是同一件事
（此刻网络的整体状况）。现合为一张卡片：统计条是卡片抬头，下面接上联概览。

两个开关是**独立**的（统计 / 概览），故卡片只是外壳，两个子块各自显隐；
卡片的可见性由「至少一个子块**有内容**且未关掉」决定：

| 统计 | 概览 | 卡片 |
|---|---|---|
| 开 | 开 | 显示（抬头 + 概览） |
| 关 | 开 | 显示（只有概览） |
| 开 | 关 | 显示（只有抬头） |
| 关 | 关 | **隐藏** |

判据必须带 `firstChild` 而不只是 `tc-hidden` —— 子块在首帧都是空的（统计条要等
第一次 `renderSummary` 才填），只看类名会让卡片画出一个**空边框**。

### 变更 — 上联图全宽

图表原先按**写死的 560px** 绘制，而容器实测 **1259px** —— 图只占左半，右侧一大片空。

不能用 CSS `width:100%` 拉伸：SVG 带 `viewBox`，等比放大 2.25 倍会把坐标轴与
刻度文字一起放大，字号失控。改为**按容器实测宽度重绘**（`graphWidth`），并：
- 扣除卡片自身的内边距与边框（`getComputedStyle` 读，不写死像素，改 CSS 不会悄悄失配）；
- 监听 `resize` 按新宽度重绘，只在宽度**真的变了**（≥2px）时才重画 —— 拖动窗口时
  `resize` 每帧触发，无条件重绘会连带重建表格行；
- 监听器具名挂到实例并在 `handleTeardown` 摘除。

实测：1600px 视口下 `svgW = 1259 = 容器宽`、溢出 **0**；缩到 1100px 后自动重绘为 759px。

### 变更 — 例行轮询不再闪状态行

例行轮询（`runAll` / `runSingle`）此前每秒往状态行写「扫描所有设备中…」→「✓ 完成」，
1 秒档位下这一行不停地闪。它是噪声而非信息 —— 轮询本来就该是看不见的。

现例行轮询**只在失败时**写状态；成功时只清掉**它自己**上次留下的错误，不碰动作消息。
**动作类反馈（限速 / 切断 / WiFi 黑名单）仍逐字保留** —— 那些是用户主动触发、
必须看到结果的操作。为此新增 `setRoutineStatus()`，与 `setStatus()` 分工明确。

实测：连续 7 秒采样，状态行始终保持隐藏、无文字。

### 修复 — 按钮组与表格之间没有行距

`.tc-menu-group` 只有上边距，按钮组下边缘与表格上边缘实测相距 **0px** —— 按钮看起来
贴在表头上，像表的一部分而不像「控制这张表的按钮」。表格自身没有上边距，故只能在这里
给：改为 `margin: 8px 0 12px`。实测行距 12px。

### 修复 — 关掉「统计」后统计条照样显示

`renderSummary` 与单设备分支都是**整体赋** `statsDiv.className`，把 `tc-hidden`
一起丢掉 → 下一次轮询把它写回来。改为先记下隐藏态、赋完类名再还原。

### 验证

- 卡片合并：`statsInsideCard: true`、抬头是卡片首个子元素、卡片高 403px。
- 开关独立性：四种组合逐一实测，结果与上表一致（含「都关 → 卡片隐藏」）。
- 单设备模式：卡片只剩统计条（连接/TCP/UDP），概览按设计隐藏。
- 全宽图表：1600px → 1259px（零溢出）；1100px → 759px（resize 自动重绘）。
- 例行轮询：7 秒 × 6 次采样，状态行始终隐藏；「扫描所有设备中」已从页面消失。
- 按钮行距：12px。
- 控制台 0 错误；不变量校验全绿（新增 13 条断言）；i18n 完整。

## [v0.6.6] - 2026-10-13

### 变更 — 视图开关直接展示，「可见列」并入按钮组

「视图与表格」那张可折叠卡片拆开，按用途分到两处：

- **开关直接展示**（统计 / 连接 / 概览 / 扩展 / rDNS / 活动日志）：一行常驻在
  速率限制卡片尾部。原先是可折叠卡片 —— 开关藏在折叠区里，表现为
  「内容不见了却不知道开关在哪」。
- **「可见列」收进按钮**：设备列 chip、连接表列 chip、连接表筛选全部移入
  一个「可见列」浮层。这些是「调表的显示」，平时不动却数量最多（设备列 20 个
  chip + 连接表列 8 个 + 筛选行），平铺出来最占横向空间。

按钮组排列为 **可见列 | ☰**（用户指定顺序）。

### 变更 — 两个菜单共用一个弹出面板工厂

☰（档位）与「可见列」的交互完全一致：点开、点别处关、Esc 关、面板内点击不关。
原先只有 ☰ 一套实现；再加一个必然会漂移（例如只有一边摘除监听器）。
抽出 `mkPopupMenu()` 供两者复用，并补一条新行为：**同一时刻只允许一个面板展开**
—— 两个浮层贴着同一个按钮组，同时展开会互相盖住。

### 修复 — 多列全开时列被压到 11px、MAC 折成三行

「可见列」让开列变容易后这个问题更容易遇到，实测暴露：

| 列数 | 修复前 | 修复后 |
|---|---|---|
| 默认 9 列 | 正常 | 正常（无横向滚动） |
| 20 列全开 | 图表/限制/丢弃/队列 = **11px**，MAC 折成 **3 行** | 各列拿到预算（最低 58px），MAC 单行，横向滚动 |

根因：列宽写在 CSS 的**百分比**里，而百分比是「占表宽的比例」—— 列一多，
各列比例被摊薄。改为**在 JS 里按每列的最小可用宽度（`COL_MIN_PX`）算**：
给每列一个像素预算，总和作为表的 `min-width`，各列百分比按「预算 / 总和」得出，
以**内联样式**写到表头上。于是：

- 容器窄于总和 → 表取 `min-width`，每列恰好拿到预算，外层横向滚动；
- 容器宽于总和 → 表铺满容器，各列按同一比例变大。

CSS 里原先那批百分比列宽随即全部失效（内联优先），**已删除** —— 两处共存必然
矛盾，留着就是无人察觉的死规则。新增断言禁止它再出现。

### 验证

- 结构：按钮组 `可见列 | ☰` 同在 `top=1011`、两个面板均默认收起。
- 开关行：六个开关在速率限制卡片内直接可见；「View & Table」文案已从页面消失。
- 面板内容：设备列 20 个 chip；单设备模式下自动换成连接表列 8 个 chip + 筛选行。
- 交互：两点菜单**互斥**（开一个另一个自动关）；Esc 关闭；面板内点 chip
  **不**关闭面板（实测切换后仍开着，且列数 7→6 真变了）。
- 列宽：20 列时 `min-width=1800px`、每列各自拿到预算、MAC 单行、横向滚动；
  默认 9 列 `min-width=920px`、无横向滚动。
- 控制台 0 错误；`verify-trafficctl-invariants.sh` 全绿（新增 15 条断言，
  并更新了 4 条查旧类名的断言 —— 类名从 `tc-speed-menu*` 改为通用
  `tc-menu*` 后，旧断言会永远失败）；i18n 447/447 完整。

## [v0.6.5] - 2026-10-13

### 变更 — 表头与单元格全部居中对齐

原先一行里混着**三种对齐**：表头左对齐、数字列右对齐、文字列左对齐。
设备多时列与列之间看起来是错位的 —— 读一列要在三种基准之间来回找。
现统一居中，每列的标题与内容落在同一条中轴上（实测九列的中轴偏差全为 **0**）。

作用域**只限真正的表格**（新增 `.tc-table--center` 修饰类）：

| 表格 | 是否居中 |
|---|---|
| 设备表（`buildSummaryTable`） | ✅ |
| 连接表（`buildTable`，单设备模式） | ✅ |
| 分组表（`buildGroupedTable`） | ✅ |
| 扩展统计面板（`buildExtendedStatsPanel`） | ❌ **保持左对齐** |

扩展统计面板也用 `.tc-table`，但它是「标签 — 数值」两栏行；居中后标签与数值
会各自居中，读起来不成列表。故它**不加**该类，并有断言守住这一点。

### 说明 — 两处容易漏掉的对齐

- **两行式单元格的子项**：IP/MAC、类型/厂商两列是 `.tc-cell-stack`（flex 列容器），
  其子项对齐由容器自己的 `align-items` 决定，**光给 `.td` 设 `text-align` 管不到** ——
  默认 `stretch` 会让上下两行左贴、与已居中的其他列不齐。故另给
  `.tc-table--center .td.tc-cell-stack { align-items: center }`。
- **未动全局工具类**：`.tc-right` / `.tc-center` 是全局类（表格之外也在用），
  统一改它们会波及别处。居中规则一律限定在 `.tc-table--center` 作用域内。

### 验证

- 逐列实测：九列表头 `text-align` 与单元格 `text-align` 均为 `center`；
  **表头中轴与首行内容中轴偏差全为 0**；`.tc-cell-stack` 的 `align-items` 为 `center`。
- 连接表（单设备模式）实测同样居中。
- 扩展统计面板实测**未**被居中（断言同时守住「不误加」）。
- 新增断言经**模拟误改验证有效**：把扩展面板也加上 `--center` 时断言会失败。
- 控制台 0 错误；`verify-trafficctl-invariants.sh` 全绿（新增 4 条断言）；
  i18n 448/448 完整；patch 重放逐字节一致。

### 修正 — 一处断言在数注释

新增的「三处表格居中」断言起初写 `grep -c 'tc-table--center'`，把**解释该类的
注释行**也算进去，报出 4 处（实际 3 处）。这正是 AGENTS.md 验证纪律第 6 条记过的
坑（断言要先剥掉注释行）。改为只匹配 `class':` 开头的真实代码行，并要求恰好 3 处。

## [v0.6.4] - 2026-10-13

### 变更 — 四组档位收进 ☰ 菜单，冷启动轮询改为 1 秒

「轮询 / 窗口 / 方法 / 刷新」原先平铺成一条常驻横向条贴在设备表上方。
它们**设好一次就不再动**，却每一屏都在：窄屏上四组各带标签会折成两三行，
长期占据设备表上方的位置。现收进一个 **☰** 图标按钮，默认收起，
表上方只剩一个 30×26 的图标（原条高 46px）。

交互：
- 点 ☰ 展开浮层（**绝对定位**，展开时设备表不跳动）；
- 点页面别处、按 **Esc**、再点 ☰ 都可以收起；
- 面板内部的点击不关闭（否则点档位就会立刻收起来）；
- 「保存为路由器默认值」移到面板底部 —— 它作用的正是这四个值。

**冷启动默认轮询 2s → 1s**。三处必须一致，否则会出现「界面显示 1s、
路由器实际下发 2s」的漂移：
| 位置 | 改动 |
|---|---|
| 前端 `common.js` `siteDefaults.pollInterval` | `2` → `1` |
| UCI `root/etc/config/trafficctl` `option poll_interval` | `'2'` → `'1'` |
| rpcd `luci.trafficctl` 兜底 `${poll:-N}` | `2` → `1`（config 缺失时用它） |

### 修复 — 三类字节轮询在 1 秒档位下会叠加请求

改默认 1s 前先实测了代价：单次 RPC **P50≈290ms、最坏 1877ms**，
而 `setInterval` **没有防重入**。实测 30 秒窗口内出现 **3 次重叠、最多 2 并发** ——
这正是 AGENTS.md 红线 9 记录过的故障形态（请求层层堆积 → rpcd 不断 fork 子脚本
→ 路由器 load 飙升 → 页面最终 `XHR request timed out`）。

给 `pollBytes` / `pollDrops` / `pollShapeStats` 各加一个防重入闸
（与既有的 `queryInFlight` 同一手法）：上一拍未返回就跳过这一拍。
**`.catch` 也必须解锁** —— 否则一次请求失败会让轮询永久停摆。

加固后实测：30 秒内 **0 重叠**、起跳间隔精确 1000ms
（此前为 3 次重叠）。仅首屏那一次 2165ms 的长调用属正常并发（加载期本就并发）。

### 修复 — `document` 上的菜单监听器未摘除

「点别处 / Esc 收起」需要挂在 `document` 上。若不具名保存并在离开页面时摘除，
切走 tab 后它们仍会收到点击、闭包里抓着已移除的 DOM（内存泄漏 + 每次进页
多积一层监听）。改为具名挂到实例（`_speedMenuDocClick` / `_speedMenuDocKey`），
在 `handleTeardown` 里 `removeEventListener`。

### 验证

- 结构实测：☰ 按钮 30×26px、默认收起；展开后面板 408×213px、
  4 行分别为 轮询(6 档) / 窗口(6 档) / 方法(2 档) / 刷新(7 档)，含保存按钮。
- **冷启动实测**：清空 `localStorage` 全部选项后重载，菜单「轮询」停在 **1s**。
- 交互实测：按钮开 → Esc 关 → 面板内点击**不**关 → 点页面别处关。
- 切到设置页再切回，菜单仍正常（监听器摘除无副作用）。
- **防重入实测**：1s 档位跑 30 秒，重叠 0 次、间隔精确 1000ms。
- 控制台 0 错误；`verify-trafficctl-invariants.sh` 全绿（新增 14 条断言）；
  i18n 448/448 完整。

### 说明 — 路由器上档位标签仍为英文

与 v0.6.3 同一原因：新增中文串要等**固件构建**时由 `po2lmo` 生成 `.lmo`
才生效，路由器上无该工具。i18n 校验已确认翻译完整。

## [v0.6.3] - 2026-10-13

### 变更 — 设备表按「两行式」重排，16 列压到 9 列

参照爱快设备列表的形状重排表格，每行改为「信息成对、上下两行」：

| 列 | 内容 |
|---|---|
| **IP / MAC** | 上行 IP（详情页入口），下行为 MAC（链到 DHCP/DNS 绑定）。原先这是两列 |
| **终端类型 / 厂商** | 上行为识别到的类型（手机/电视/摄像头…，带图标），下行为 **MAC 前缀查得的厂商** |
| **操作** | 上行「详情」、下行「限制」（把该设备设为目标） |

其余列重排为：连接数 → 上行速率 → 下行速率 → **累计上行** → **累计下行** →
类型/厂商 → 名称 → 操作。三处合并省掉 3 个列宽，**16 列压到 9 列**，
整屏（1600px）内不再需要横向滚动。

新增两个数据列：
- **累计上行 / 累计下行** 分列显示。原先只有一个「字节」列（上下行相加），
  看不出某台设备是哪一侧在跑量。方向语义已核对 `trafficctl-totals.sh`：
  `bytes_in` = 下行（路由器→设备）、`bytes_out` = 上行（设备→路由器），
  两者复用既有的 `renderTotalCell`，故「不可测」（flow offload 下为 -1）
  仍显示 ⚠ 而不是假的 0。
- **设备厂商**：取自固件内 `luci-app-oui` 的 100 KB 厂商库。实测能查到
  Xiaomi / Midea / Huawei / TCL / TP-Link / MSI；随机化 MAC 显示「随机 MAC」
  并说明按 MAC 查不到厂商。`luciOUI` 只导出 `decorate`（没有公开的 `lookup`），
  故用一个游离节点让它写入 `title` 再读回；`oui.js` 未被任何视图加载过时按需
  载入一次，失败则保持占位「—」，不影响表格渲染。

### 新增 — 分页条

底部「共 N 条 当前显示 a-b」+「每页 20/50/100/全部」+ 页码，与参照图一致。
选中的页长存 localStorage。分页**切片前先按当前排序列排序**
（`sortSummaryRows`，与表内排序同一套规则），否则第一页不是真正的最快设备。
单设备模式不显示分页条（只有一行数据）。

### 修复 — 四个只有实测才会暴露的问题

1. **列宽被拉成空槽 + 无意义横向滚动（两种症状同一个根因）**。
   `table-layout:auto` 下 `width:Npx` 只是**建议**：浏览器按内容重新分配，
   于是「累计上行」一列被撑到几百像素的空槽，同时「操作」列被压到 56px
   而它需要 154px 才放得下两个链接 → 整表溢出 **153px**。
   改为 `table-layout:fixed` + 百分比列宽（默认 9 列合计恰为 100%），
   并加 `min-width:860px`：窄屏宁可横向滚动，也不要把 IP 挤到折行、
   把「Details」截成「Detai」。
   *（fixed 布局还有一条规范行为：列宽之和小于表宽时多余空间会按各列比例
   摊分 —— 实测每列被放大 1.9 倍。百分比凑满 100% 就没有余量可摊。）*

2. **操作列的「两行」并成了一行「Details限制」**。两个子元素都是 `<a>`（inline），
   而 IP/MAC、类型/厂商列的第二个子是 `<div>`（block）故天然换行。
   给 `.tc-actions a` 加 `display:block` 才真的成两行。

3. **默认隐藏的列永远打不开**。列开关原本用 `delete` 移除键，而隐藏状态是
   「键存在且为真」——`delete` 后回落到默认隐藏，于是点开芯片变绿、
   表格里却仍没有这一列。改为打开时**写显式 `false`**。

4. **`app` 列有列定义但没有列开关** —— 打开后无法关闭。新增断言比对
   `cols` 与 `colChipDefs` 的键集，这次就是被它抓出来的。

### 修复 — 默认隐藏列的声明曾有两份真相

列定义里的 `hide:true` 与开关判定的默认值各写一份，必然漂移
（症状就是第 3 条：芯片显示已打开而表格不渲染）。统一为模块级
`TC_COL_DEFAULT_HIDDEN` + `isColHidden()`，并加断言。

### 说明 — 参照图有三列本机没有数据源，未实现

参照图来自**爱快（iKuai）系统**（浏览器中另开着它的标签页，图中 IP 段
`192.168.9.x` 也与本机 `192.168.3.254` 不同）。逐列核对后确认三列无法落地：

- **在线时长** —— 后端无 `first_seen` 记录，从不产出。
- **连接AP / SSID** —— `iw dev` 返回 **0 个接口**、`/sys/class/ieee80211`
  不存在：本机是**无 WiFi 硬件的 x86_64**。

按用户选择「省略这三列，其余严格按图排布」处理。硬做就是三列永远空白。

### 验证

- 逐项实测（`getBoundingClientRect`）：9 列、三处两行式全部成立
  （`ip` / `_tydev` / `_actions` 各 2 行）、行高 48px、
  **1600px 无横向滚动**、1100px 按预期转为滚动（860px 下限）。
- 分页实测：首页 20 行 → 第 2 页 4 行（`showing 21-24`）→ 每页 50 → 24 行 1 页。
- 列开关实测双向生效：TCP 开→列出现、关→列消失；MAC 同理。
- 厂商实测：Xiaomi / Midea / Huawei / TCL / TP-Link / MSI 均正确，
  随机 MAC 显示「随机 MAC」。
- 单设备模式回归：无分页条、`tc-cut` 仍可见；「详情」链接仍能进主机详情页
  （`/host/192.168.3.141`，页面含 `.tc-host-table`）。
- 页面无字面 `undefined`；控制台 0 错误。
- `verify-trafficctl-invariants.sh` 全绿（新增 7 条断言）；
  i18n 447/447 完整（新增 27 条中文翻译）。

### 已知 — 路由器上表头仍显示英文

新增的中文串要等**固件构建**才会生效：`.lmo` 由构建时的 `po2lmo` 生成，
而路由器上既无该工具、现有 `.lmo` 也只含旧串。i18n 校验已确认翻译完整，
刷入下一个固件后即为中文。

## [v0.6.2] - 2026-10-13

### 变更 — 设备页进一步收拢为「一张操作卡片 + 数据区」

四项布局调整，把原先四块各自占行的控件收进同一张卡片：

- **设备选择并入速率限制卡片**：搜索框 + 「所有设备」+ 最近设备 chip 原先是
  卡片**之上**的独立两行，而卡片里又有自己的「目标」选择器 —— 两处选择器一上一下，
  用户要在它们之间来回看。现并进卡片，与「目标」同排一行：左边选设备、右边设限制。
- **「整个网络 / 网段」并入「共享」同行**：它原在「共享」的下一行，实为同一组
  「往哪施加限制」的选项。现排在「共享」chip 右侧。
- **「View & Table」并入速率限制卡片**：原为独立卡片（有自己的外框与底色），
  现嵌为卡片尾部（`.tc-rate-panel__tail`，用一条上分隔线区分），去掉重复外框。
- **「表格与速率」从设置页搬到设备页设备列表上方**：这组档位（轮询 / 窗口 / 方法 /
  刷新 + 路由端默认值）决定的就是**下面那张设备表**怎么刷新、速率按什么窗口算；
  放在设备表上方改完立刻见效，放在设置页则要来回切 tab 才知道有没有生效。

设备页高度 **1519 → 1476px**（前半段操作区由约 480px 压到 447px，且不再有
「搜索框 / 所有设备」独占的两行）；设置页 **484 → 375px**（少了一张卡片）。

### 修复 — 三处 `var` 提升导致的 `undefined`

把三块控件并进先在文件上方构造的卡片时，引用了在文件**下方**才赋值的变量。
`var` 提升使变量存在但值为 `undefined`：其中一次被当成文本节点渲染，
页面上出现一个字面的 **"undefined"**；另一次直接抛
`TypeError: Cannot read properties of undefined (reading 'appendChild')`，整页空白。

处置：给 `actionRow`、`scopeRow` 各留一个占位容器（`actionSlot` / `scopeSlot`），
等它们真正构造完再 `appendChild`。这类错误的特征是**报错位置与根因不在一处**，
故三处都写了注释说明为什么必须先占位。

### 修复 — 设备选择行的块内换行

`.tc-picker-row__device` 用了 `flex-wrap: wrap`，导致「所有设备」被拆到搜索框的
下一行（该行 71px ＝ 两行）。同时 `.tc-search-wrapper` 是 `display:inline-block`
（为下拉浮层定位而设），在 flex 行内被压到内容宽度。

改为：三个子块一律 `flex-wrap: nowrap`，整行放不下时由**外层** `.tc-picker-row`
统一换行；并给行内搜索框显式宽度 240px。该行 **71 → 32px（单行）**。

### 验证

- 逐项实测（`getBoundingClientRect`）：搜索框与「所有设备」top 差 < 6px（同行）；
  设备选择块与「目标」`top` 完全相等（同排）；`.tc-picker-row` 单行 32px；
  `.tc-rate-panel` 447px，其中 `tc-rate-panel__tail` 内含 View & Table 卡片；
  `.tc-rate-panel .tc-cut` 存在（切断仍在同一卡片内，未失效）。
- 页面上不再出现字面的 `undefined`（已断言 `document.body.textContent`）。
- **两种模式都核对**：单设备模式下 `scopeRow` 隐藏、「阻断互联网 / 阻断WiFi」
  按钮可见；所有设备模式下反之。
- 设置页只剩三张卡片（流量卸载 / 新设备默认值 / 日志与持久化），375px；
  「表格与速率」确认已不在其中。
- 控制台 0 错误；`verify-trafficctl-invariants.sh` 全绿；i18n 0 缺失。

### 说明 — 反转了一条旧断言

v0.6.0 加过「设备页不得定义配置档位」的断言（当时那些档位迁往设置页）。
本次方向相反，故判据反转：**这些档位必须存在于 status.js，且不得在 settings.js
留副本**。同时新增「速率条排在设备表之前」的断言 —— 注意它比较的是
**render 树里的顺序**而非变量定义行号：`connsDiv` 的 `var` 声明在文件上方，
真正决定渲染次序的是它被放进返回树的位置（我第一版写成了比定义行号，误报）。

## [v0.6.1] - 2026-10-13

### 修复 — 设置页所有样式失效

`settings.js` **没有注入 `status.css`**，页面上全部 `tc-*` / `tg-*` 类失效：
卡片无边框无内边距、chip 无底色（档位挤成一片）、折叠箭头错位。
实测该页 `<link>` 只剩 `/luci-static/shadcn/main.css`，`.tc-card` 的计算样式为
`border 0px / radius 0px / background transparent`。

根因：LuCI 只为**视图模块**自动加载与之同名的样式表 —— 本视图是
`trafficctl/settings.js`，对应的 `trafficctl/settings.css` 不存在，因此
`status.css` 不会被自动带上。`status.js` / `telegram.js` / `host.js` 都在文件顶部
手动注入，唯独新增的 `settings.js` 漏了。已补上同一段注入代码。

### 修复 — 各卡片的多余换行

- **根因是容器的多列布局**：`.tc-settings-body` 原用 `column-count: 2` 瀑布流，
  它会把**每张卡片压成半宽**，于是「表格与速率」里 4 组档位 + 保存按钮被迫折成
  两行（实测行高 67px）。改为 grid 两列，并新增 `.tc-card--wide` 让内容多的卡片
  独占整行（多列做不到「单个子项跨列」）。该行行高 **67 → 32px**（单行排完）。
- **「流量卸载」卡片**：开关与它的说明原先各占一行、共 5 行（173px）。说明是长句、
  开关是短控件，同行并排并不挤压，改为同行后 **5 行 → 3 行**（141px）。
- **「日志与持久化」卡片**：「日志分类」是一个分组标题，却独占一行（42px）。
  改为与那 5 个分类开关同行，**42 → 22px**。
- 设置页整页高度 **584 → 484px**，且不再有空格子（原「日志与持久化」在最后一格
  留下半行空白）。

### 变更 — 「切断全部互联网访问」并入速率限制卡片

它原是与速率限制并列的独立卡片，两者都是「对设备/全网施加限制」却分成两块、
各占一行高度。现嵌入速率限制卡片下方（`.tc-cut--embedded`：去掉自己的外框与
底色，改用一条上分隔线区分功能区）。设备页高度进一步 **1519 → 775px**。

**这一项有安全约束**：该控件是本应用唯一能把操作者自己关在门外的功能，其状态必须
在页面一渲染出来就可读，**不得**藏进任何折叠区。故：
- 它留在恒常可见的速率限制卡片内，而不是移入设置页；
- `rateLimitRow` 去掉了初始的 `tc-hidden`。它原先靠 `updateModeUI()` 里的
  `classList.remove('tc-hidden')` 才显示，即依赖 `runQuery()` 那条异步链 ——
  一旦该链未走到（异常、RPC 挂起），面板连同切断开关会一起消失。
  对这一个控件而言，那种失败模式不可接受，故改为首屏即显示。

### 验证

- 路由器实测：设置页 `status.css` 已加载，`.tc-card` 边框 1px、`.tc-chip` 圆角 14px；
  grid 两列各 1102px，两张宽卡片 2217px 独占整行。
- 逐行测量：`表格与速率` 32px（单行）、`流量卸载` 21+21px、`日志与持久化` 22+22px，
  设置页 484px。
- 设备页实测 `rate.parentElement.contains(cut) === true`、
  `.tc-cut` 不再是 `.cbi-section` 的顶层子节点、`tc-cut--embedded` 生效、
  首屏高度 65px 可见；设备页 775px。
- 两种模式（单设备 / 所有设备）下切断面板都可见。
- 控制台 0 错误；`verify-trafficctl-invariants.sh` 全绿；i18n 0 缺失。

## [v0.6.0] - 2026-10-13

### 变更 — trafficctl 拆出独立的「设置」页，设备页去重与重排

设备页此前把**配置项**与**监控数据**混在一页：轮询/窗口/平均算法、路由端默认值、
流量卸载、新设备默认值、日志与持久化全部内联在设备表上方，实测该区块高 580px，
把「看谁在占带宽」这个主任务压到折叠线以下。这些配置又是一次性设置，不需要和设备表
抢注意力。本次按职责拆开：

| tab | 内容 |
|---|---|
| 设备 | 设备选择、断网开关、速率限制、概览与统计、设备表、**视图与表格**（本页显示开关与列可见性） |
| **设置**（新增） | 表格与速率、流量卸载、新设备默认值、日志与持久化 |
| Telegram机器人 | 不变 |
| 端口转发 | 不变 |

设备页整页高度由 **2915px 降到 1541px**（实测），其中原设置面板由 580px 降到
185px 且只剩「视图与表格」，并移到页面最后 —— 配置项不再挡在数据前面。

### 新增 — 页面共用模块 `trafficctl/common.js`

设置页与设备页需要同一套 rpc 声明、同一份 localStorage 选项、同一组「开关 / chip /
折叠卡片」控件。此前这些定义写在 `status.js` 里、被 `telegram.js` 复制了一份；再新增
设置页就会出现第三份，三份各自漂移（表现为同一个开关在不同页面行为不一致）。
现集中到 `htdocs/luci-static/resources/trafficctl/common.js`，设备页与设置页各
`'require trafficctl/common as T'` 一次。

**关键约束（踩过）**：该模块必须 `return baseclass.extend({...})`。LuCI 前端 require 在
`luci.js` 里对工厂返回值做 `Class.isSubclass(_class)` 断言，返回普通对象会直接抛
`TypeError: "trafficctl/common" factory yields invalid constructor` 并令整页加载失败。
require 返回的是 `new _class()` 的实例，故 `T.fmtBytes(...)` 这种实例方法调用成立。

### 移除 — 软件流量卸载的橙黄色公告横幅

软件卸载**不损失任何功能**（速率由图上的 nftables 计数器提供，限速与阻断照常），
却每次打开页面都弹一条橙黄色公告。模式本身在设置页「流量卸载」卡片里有常驻的
`Current mode` 显示，不靠横幅告知。**硬件卸载的告警保留** —— 那说的是该模式下
conntrack 字节计数器确实不更新、速率会显示为 0，属真实故障提示，必须告知。

### 修复 — 三处本次重构引入或暴露的缺陷

- **`connFiltersRow is not defined` 令设备页整页空白**：配置区迁出时把「连接表筛选」
  （协议/分组）的定义一并删掉了，而 `viewSection` 与 `updateTableSectionMode` 仍在
  引用它，`render()` 直接抛错。已把定义移回引用之前。
- **`status.js` 被写成 CRLF**：用编辑器整文件重写时落成 CRLF，而 patch 回放校验
  要求与 vendored 包逐字节一致，报「不一致」。`.gitattributes` 已有 `*.js text eol=lf`，
  但那只管 `git add` 时的规范化，**不会**自动修正工作树里已被写坏的文件。已改回 LF。
- **`config_set` 的 ubus 签名漏声明 `refresh_interval`**：读写代码都在，签名里却没有。
  ubus 实测仍会放行（能写入），但该参数不受类型校验，且与 `config_get` 的输出字段
  不对称，属「不报错但不一致」的隐性缺陷。已补进签名。

### 验证

- **路由器实测四个 tab**（已登录 LuCI）：`设备 | 设置 | Telegram机器人 | 端口转发`，
  顺序与激活态正确，设置页在顶部行中可见。
- **设置页四张卡片全部正常渲染**（表格与速率 / 流量卸载 / 新设备默认值 / 日志与持久化），
  中文全部生效，控制台 0 错误。
- **跨页生效实测**：在设置页把「刷新」档位点到 `2s` → `localStorage` 写入
  `{"refresh":2}` → 回到设备页后按 ubus 请求时间点聚类，实测轮询间隔为 **2 秒**
  （默认 5 秒时实测 5.0 秒）。`refresh_interval` 经 `ubus call luci.trafficctl config_set`
  单独写入 42 并读回确认，随后恢复为 5。
- **橙黄横幅确已消失**：设备页 `#tc-offload-banner` 容器存在但为空且为 `tc-hidden`，
  渲染高度 0。
- **设备页功能回归**：设备表 20 行、速率/累计有值、IP 链接仍在，控制台 0 错误。
- `tools/verify-trafficctl-invariants.sh` 全部通过（含 5 个 patch 在上游 v1.21.4 上重放
  并与 vendored 包逐字节一致）；`tools/check-trafficctl-i18n.py` 中文覆盖 0 缺失。

### 说明 — 新增的校验断言

`tools/verify-trafficctl-invariants.sh` 新增一组「被覆盖会静默失效」的断言：
`settings.js` / `common.js` 存在、`menu.d` 登记 settings 页、两个页面都引用
`trafficctl/common`、软件卸载横幅文案已消失且模式短路仍在、硬件卸载告警仍在、
设备页不再定义任何重复配置项。刷新档位的断言改为同时查 `status.js` 与 `settings.js`
（该 chip 已随「表格与速率」迁走，只查前者会在迁移后误报）。

`tools/check-trafficctl-i18n.py` 的 `JS_FILES` 补入 `settings.js` 与 `common.js`，
否则这两个文件的中文缺译不会被校验发现。

## [v0.5.0] - 2026-10-13

### 新增 — 主机实时连接详情页（从概览「流量排行」与设备表 IP/主机名进入）

概览面板的「流量排行」此前只显示速率，无法回答「这台主机在连谁」。现在主机名与
IP 都是链接，设备表的 IP 与设备名后也有 `↗` 入口，点击进入该主机的**实时连接详情页**。

**13 列表格**（点击表头排序）：

```
应用 | 协议 | 线路 | 外网地址 | 域名 | 源端口 | 目的地址 | 目的端口
     | 上行速率 | 下行速率 | 累计上行 | 累计下行 | 连接状态
```

页面地址 `admin/status/trafficctl/host/<ip>`。该路由在 `menu.d` 里**不设 `title`** ——
可直达、可收藏、可后退，但不会在侧边栏多出一个点不开的菜单项（`ui.menu.getChildren`
会跳过无 title 的节点，已实测确认）。

### 实现要点（含实测依据）

- **逐连接字段来自 conntrack 的回复方向元组**。一行 conntrack 有**两个**元组：

  ```
  orig:  src=客户端      dst=远端      sport=客户端口 dport=远端口 bytes=上行
  reply: src=NAT后源     dst=NAT后目的  sport=远端口   dport=客户端口 bytes=下行
  ```

  旧版 `trafficctl-device.sh` 只读第一个元组，因此拿不到源端口、外网地址，
  且「上行/下行」实际是同一个数。本次补出 `sport` / `bytes_up` / `bytes_down` /
  `wan`（= reply dst）/ `proxy`。仅有客户端**发起**的连接计入（首元组 src 必须是该设备），
  否则入站连接的两个方向会颠倒。

- **「外网地址」在两种情况下留空而不是硬填**：
  1. `proxy=true`（回复元组来自本机 `:1234`）—— 出口地址由代理节点决定，这条连接
     自己没有可报告的外网地址；
  2. `wan == 客户端自身 IP` —— 访问路由器本身（DNS/SSH/LuCI）不经 NAT，
     把内网地址填进「外网地址」列会被读成一个恰好是私网的公网地址。

- **速率与累计可信**（实测，非推断）：本机 `flow_offloading=1`，命中 flowtable 的连接带
  `[OFFLOAD]` 标记，但 `/proc/net/nf_conntrack` 的 `bytes` **仍在增长** ——
  40 MB 下载期间回复方向由 0 涨到 1.1 MB 级。故这两列直接显示真实值，无需降级标注。
  速率由前端两次采样差分得到（键为 proto+dst+sport+dport，避免同目的地多连接互相覆盖基线）。

- **「应用」列无数据时显示 `—`**：需要 netifyd DPI，本固件未安装；tooltip 说明缺的是 agent
  而不是这条连接。装上后自动有值。

- **轮询防重入**：与设备表同一套做法（`tick` + `queryInFlight` + `document.hidden`）。
  `trafficctl-device.sh` 每次要读完整 conntrack 表，1 秒档位下若无条件发起会让 rpcd
  不断 fork 子脚本。实测 1s 档位下间隔稳定在 ~1000ms、无堆积。

- **13 列横排**：shadcn 主题下 LuCI 的 `.table/.tr/.th` 被算成 `display:block`，
  表头会逐个竖着堆成一列（详情页 13 列尤其明显）。本页范围内显式改用 grid 定列，
  窄屏横向滚动；其余页面不受影响。

### 修复 — 三处此前会误导排查的工具缺陷

- **`tools/verify-trafficctl-invariants.sh` 的 patch 重放会误报不一致**：
  它的 `git apply` 没钉 `core.autocrlf=false`，会从全局配置继承 `true`（本机 Windows
  默认即如此），把补丁内容落成 CRLF，于是与 LF 的 vendored 包「逐字节不一致」，
  报出一堆「文件 differ」而差异只是行尾。regen 脚本自己钉了该设置所以通过、
  校验脚本没钉，两者结论相反。已钉死，并在差异**全部**是行尾时直接给出该结论。
- **`python3` 在 Windows 上常常存在但不可用**（Microsoft Store 占位符，执行后只打印
  「Python was not found」并非 0 退出）。`command -v python3` 判定「有 Python」，
  于是检查永远失败、却报成「中文翻译不完整」。改为逐个候选**实际执行** `--version`。
- **`tools/regen-trafficctl-patches.py` 在中文 Windows（GBK）上崩溃**：
  `subprocess.run(text=True)` 用系统区域编码解码 git 输出，含非 GBK 字节时抛
  `UnicodeDecodeError`；该异常发生在读取线程里，表现为 `stdout=None`，最终报
  `data must be str, not NoneType`，与真正的原因（编码）毫无关系。已显式 `encoding='utf-8'`。
  同时把「本地有、上游没有、未登记」的文件提示按正斜杠归一，避免 Windows 上把
  已登记的新文件（`host.js`）误报成未登记。

- **msgid 是全仓库共用的键**：新表头原用 `Application`，而 `nlbwmon.zh-cn.lmo`
  已把该 msgid 译成「应用层」，同键译文互相覆盖，表头会莫名变成 nlbwmon 的用词。
  已改用本应用既有的 `App`（「应用」，无冲突）—— 实测 `_('Application')` 在路由器上
  返回「应用层」而 `_('App')` 返回「应用」。

### 验证

- 路由器实测 `trafficctl-device.sh 192.168.3.238`：95 条连接，字段语义逐项核对 ——
  代理连接 `proxy=true` 且 `wan` 为空；访问路由器自身的连接 `wan` 为空；
  直连外网显示真实 NAT 后地址 `100.119.32.10`；上下行分开计数。
- 浏览器实测（已登录路由器）：
  - 详情页 13 列表头横排、无截断单元格；速率与累计显示真实数值；
  - 概览「流量排行」8 个链接、设备表 44 个链接，点击 IP 正确导航到详情页且
    不误触「整行选中该设备」；
  - 切到 1s 档位后间隔稳定 ~1000ms、无请求堆积；控制台 0 错误；
  - 设备页原有功能回归正常（22 行、速率/累计有值、点击行为未变）。
- `tools/verify-trafficctl-invariants.sh` 全部通过（含 4 个 patch 在上游 v1.21.4 上
  重放并与 vendored 包逐字节一致）；`tools/check-trafficctl-i18n.py` 中文覆盖 0 缺失。

> 表头中 `Line` / `WAN address` / `Dst port` / `Upload rate` 等在路由器上仍显示英文，
> 因为新串的 `.lmo` 由**构建主机**的 `po2lmo` 生成（路由器上无该工具），
> 需刷入本次构建的固件后才会变中文。`po/zh-cn` 的译文已就位并经校验完整。

## [v0.4.12] - 2026-10-10

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v0412)

## [v0.4.11] - 2026-10-10

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v0411)

## [v0.4.10] - 2026-10-10

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v0410)

## [v0.4.9] - 2026-10-10

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v049)

## [v0.4.8] - 2026-10-10

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v048)

## [v0.4.7] - 2026-10-10

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v047)

## [v0.4.6] - 2026-10-10

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v046)

## [v0.4.5] - 2026-10-10

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v045)

## [v0.4.4] - 2026-10-09

### 变更（构建产物加版本号）

- **新增 `Resolve version from CHANGELOG` 步骤**（`build-openwrt.yml` 第 2 步，
  紧随 `Checkout openwrt-build` 之后）：
  - 从 `CHANGELOG.md` 顶部提取 `## [vX.Y.Z]` 作为**唯一版本来源**，
    与 `release.yml` 同源，避免两处版本号漂移。
  - 输出 `VERSION`（含 `v`）/ `VERSION_NOV`（不含 `v`）/ `SHORT_SHA`
    到 `$GITHUB_ENV` 供后续步骤使用。
  - 找不到版本标题或格式不符 `vMAJOR.MINOR.PATCH` 时**直接 `exit 1`**
    （红线 3：禁止静默失败 —— 无版本号不允许出包）。
- **新增 `Rename firmware with version` 步骤**，在编译后、上传前重命名产物：
  - `openwrt-x86-64-generic-ext4-combined-efi.img.gz`
    → `openwrt-x86-64-ssrplus-vX.Y.Z-<sha7>-ext4-combined-efi.img.gz`
  - 即把 `openwrt-x86-64-` 之后的目标名（`generic`）替换为
    `ssrplus-<VERSION>-<SHORT_SHA>`，**保留镜像类型后缀**
    （`ext4-combined-efi` / `squashfs-combined-efi` 等），便于辨认镜像类型。
  - 同时生成 `.sha256` 校验文件。
  - 重命名后**断言**产物名含版本号且以 `.img.gz` 结尾，不符即失败
    （防止将来改坏命名逻辑却默默出包）。
- **artifact 名带版本号**：`openwrt-x86-64-ssrplus-vX.Y.Z-<sha7>`，
  便于在 Actions 页区分每次构建；同时上传 `.sha256`。
- **Release 上传步骤**同步上传 `.img.gz` 与 `.sha256`（保持幂等：
  已存在的 asset 跳过）。

### 修复（仓库行尾未归一化导致 11195 行虚假 diff）

- **`.gitattributes` 增加兜底规则 `* text=auto eol=lf`**：
  - **症状**：工作树中 11 个文件为 CRLF 而索引为 LF，产生 **11195 行**
    虚假 diff（`git status` 持续噪声）。根因是仓库**缺少兜底行尾规则** ——
    原有规则只覆盖 `*.sh/*.nft/*.conf/*.json/*.yml/*.yaml/*.md` 与少数
    无扩展名文件，`package/` 下 vendored 包的 `Makefile` / `LICENSE` /
    `*.css` / `*.js` / `*.po` / `*.pot` 以及无扩展名的 config 与 hotplug
    脚本均无规则覆盖，外部工具改写后无人纠正。
  - **改动**：新增 `* text=auto eol=lf` 兜底（`text=auto` 会让 git 自行判定
    二进制文件并跳过，故无需逐个排除）；补充 `*.css/*.js/*.po/*.pot/*.htm/
    *.html/*.txt` 与 `package/**` 规则。
  - **已归一化 11 个文件**：`package/luci-app-trafficctl/` 下的
    `LICENSE`、`Makefile`、`htdocs/.../status.css`、`htdocs/.../status.js`、
    `po/templates/*.pot`、`po/zh-cn/*.po`、`root/etc/config/trafficctl`、
    `root/etc/hotplug.d/dhcp/99-trafficctl-newdevice`、
    `root/etc/hotplug.d/iface/99-trafficctl-shapes`、
    `root/etc/init.d/trafficctl-telegram`、`root/usr/libexec/rpcd/luci.trafficctl`。
  - **安全性已验证**：归一化前逐个确认这些文件与 HEAD 的 blob 一致
    （`git diff --ignore-cr-at-eol` 为空，即**纯行尾差异、无内容改动**），
    归一化后逐个 `git hash-object` 比对仍为 `SAME`。
  - **结果**：全仓库工作树 CRLF 文件数 = **0**，`git status` 不再有噪声。

### 验证（本次全链路，路由器 `192.168.3.254`，固件 `10aec80` = v0.4.2）

> 用户已全新刷机到 `10aec80abc3d367567405a629507d1439029fe25`（v0.4.2）。
> 该版本含 v0.4.1 的 BBR 修复与 v0.4.2 的 LAN IP 固化，**不含** v0.4.3 的
> SSR-Plus 写入修复，故本次验证同时确认了「已修复项仍然有效」与
> 「未修复项的失效形态符合预期」。

**生效项（实测）**：

| 项 | 实测值 |
|---|---|
| 内核 | `6.18.55`，`DISTRIB_REVISION='R26.10.9'` |
| LAN | `192.168.3.254/24`，`proto=static`（v0.4.2 固化生效） |
| PPPoE | `wan proto=pppoe device=eth1`，`pppoe-wan mtu 1492` |
| IPv6 | `wan_6 proto=dhcpv6 reqprefix=56`，`network.wan6` 已删除 |
| **SQM 上行** | `cake 45Mbit besteffort dual-srchost nat overhead 34 mpu 68` |
| **SQM 下行** | `ifb4pppoe-wan` `cake 900Mbit dual-dsthost nat ingress` |
| SQM 队列时延 | 上行 `pk_delay 674us / av_delay 636us`；下行 `pk_delay 25us / av_delay 4us` |
| SQM 整形工作 | 上行 `overlimits 190264`，`dropped 78 / 322655`（0.02%） |
| **BBR** | 运行时 `tcp_congestion_control = bbr`，`turboacc.global.set=1`，`turboacc.config.tcpcca=bbr`，`firewall.@defaults[0].tcpcca=bbr`（v0.4.1 双覆盖者修复生效） |
| `tcp_timestamps` | `1` |
| `tcp_notsent_lowat` | `4294967295`（默认不限） |
| 包 | `sqm-scripts 1.6.0-1`、`tc-tiny 6.18.0-2`、`kmod-sched-cake`/`kmod-ifb`/`kmod-sched-core 6.18.55-1` |
| i18n | `luci-i18n-trafficctl-zh-cn` 已编入（`opkg list-installed` 可见） |
| 已排除服务 | `vsftpd`/`luci-app-vsftpd`/`ksmbd-server`/`luci-app-ksmbd`/`autosamba` 均为 0 |

**连通性（端到端）**：`baidu 200`、`taobao 200`、`google 302`、`github 200`、
`youtube 200`；出口 IPv4 = `203.27.106.146`（代理节点，`ifconfig.me` 与
`api.ipify.org` 一致）。`qq.com` 返回 501 属站点对无 UA 请求的正常响应，非故障。

**DNS 分流（客户端路径 `127.0.0.1:53`）**：

| 域名 | A | AAAA | 判定 |
|---|---|---|---|
| `baidu.com` | 4 | 0 | 国内，上游确实无 AAAA |
| `taobao.com` | 8 | **8** | 国内，保留真实 AAAA（未误伤） |
| `qq.com` | 2 | 0 | 国内，上游确实无 AAAA |
| `google.com` | 6 | 0 | 经代理，AAAA 被拒 |
| `chatgpt.com` | 2 | 0 | 经代理，AAAA 被拒 |
| `steamcommunity.com` | 1 | 0 | 经代理，AAAA 被拒 |
| `github.com` | 1 | 0 | 经代理，AAAA 被拒 |

`gfw_list.conf` 中 `127.0.0.1#5335` 条数 = **23617**（与分流设计一致）；
`dnsmasq` `noresolv=1` + `server=127.0.0.1#5353`；`pdnsd_enable=4`（mosdns）、
`filter_aaaa=1`；`mosdns` 运行时 `DNS_MODE` = `main_sequence_disable_IPv6`。

**延迟与抖动**：网关 `0.080/0.090/0.132 ms`（0% 丢包）；
`223.5.5.5` `21.527/21.632/21.852 ms`（0% 丢包，max−min = 0.325 ms）。

**符合预期的未修复项（v0.4.3 已修，本固件是 v0.4.2）**：

- `tunnel_forward_mosdns = tcp://8.8.4.4:53,tcp://8.8.8.8:53`（包默认），
  且 `option tunnel_forward`（模板特征）**不存在**，说明该键由 LuCI CBI
  保存时写入；这与 v0.4.3 的根因分析一致（脚本写入因空配置失败而被丢弃）。
- `/etc/firewall.user` 中的 IPv6 MSS clamp 仍是死代码
  （`uci show firewall` 中 `firewall.user` include 计数 = 0），
  但功能未缺失：fw4 的 `mtu_fix=1`（lan/wan 均为 1）已下发 **4 条**
  `maxseg size set rt mtu` 规则覆盖 IPv4/IPv6。

**开机日志**：`dnsproxy` 的 ERROR 集中于开机窗口（`19:33:53`–`19:34:13`），
根因与上次一致 —— `eth1` 在 `proto=dhcp` 阶段从上游租到不路由公网的地址，
PPPoE 建立后即恢复，非新增故障。`modprobe` 报 `act_ipt`/`nss-ifb`
不存在属 SQM 固定模块清单的无害项（cake 实测正常）。
`ddns-scripts` 报 `Service section disabled!` 系上游默认模板未启用。

## [v0.4.3] - 2026-10-09

### 修复（SSR-Plus 三项 UCI 写入曾整体失效 —— 本节是本仓库迄今最隐蔽的坑）

- **`99-gaming-optimize` 写 `shadowsocksr.@global[0].*` 前先确保 `global` 段存在**：
  - **症状**：v0.4.x 刷机后 `tunnel_forward_mosdns` 是包默认的
    `tcp://8.8.4.4:53,tcp://8.8.8.8:53`，`pdnsd_enable` / `filter_aaaa` 也未被本脚本写入。
  - **根因（曾误判为 LuCI 覆盖，已被实测推翻）**：
    1. uci-defaults 按**文件名排序**执行，`99-gaming-optimize`（`9`）**先于**
       `luci-ssr-plus`（`l`）。
    2. 此刻 `/etc/config/shadowsocksr` 仍由 opkg conffile 提供，实测为 **0 字节**
       （`wc -c /rom/etc/config/shadowsocksr` = 0）。
    3. **空配置上 `uci set shadowsocksr.@global[0].<k>=<v>` 会失败** ——
       实测 `uci: Invalid argument` + `Entry not found`，退出码 1。
       故本节原来三条 `uci set ...@global[0].*` 全部静默丢弃。
    4. 随后 `luci-ssr-plus` 检测到空配置，执行
       `[ -s /etc/config/shadowsocksr ] || /etc/init.d/shadowsocksr reset`，
       用 `/usr/share/shadowsocksr/shadowsocksr.config` 模板铺底。该模板**不含**
       `tunnel_forward_mosdns`（只有旧的 `tunnel_forward '8.8.4.4:53'`），
       于是 LuCI 读取时回落到 `client.lua` 的 `o.default`。
  - **对策**：不能简单地在写前 `uci add shadowsocksr global` 抢先建段 ——
    实测该做法会让文件提前变非空，导致紧随其后的 `luci-ssr-plus` 里
    `[ -s /etc/config/shadowsocksr ] || /etc/init.d/shadowsocksr reset`
    **跳过 reset**，结果是只有 `global` 一个段、缺 `server_subscribe` /
    `access_control` / `socks5_proxy` / `http_proxy` / `server_global` /
    `global_xray_fragment` / `clash_client_group` 共 7 个段；
    实测该分支下对 `@server_subscribe[0]` 的写入直接失败（退出码 1）。
  - **正确做法**：以「配置是否为空」为判据**主动先跑一次模板铺底**
    （`[ ! -s /etc/config/shadowsocksr ]` 时调用
    `/etc/init.d/shadowsocksr reset`），使其结果与 `luci-ssr-plus` 将要做的
    一致；随后在此之上写入本节的值。判据与 `luci-ssr-plus` **同源**，
    故行为一致；非空（升级/保留配置）时保持不动。
  - **端到端验证**（隔离副本模拟空配置首刷）：
    - 模板铺底后段数 = **8**（与 `shadowsocksr.config` 模板一致）
    - `pdnsd_enable=4`、`tunnel_forward_mosdns=<DoH>`、`filter_aaaa=1` **三项均写入成功**
    - 模拟 `luci-ssr-plus` 对 `@server_subscribe[0]` 的写入**成功**（原风险点已消除）
    - 幂等复跑：段数仍为 8、`global` 段仍为 1（无重复累积）
  - **覆盖范围**：`pdnsd_enable`、`tunnel_forward_mosdns`、`filter_aaaa` 三处受影响；
    前两处集中在第 4.5 节，`filter_aaaa` 另加同源守卫防御将来调整脚本顺序。
  - 同时把这些 `uci set` 改为带显式失败日志（`|| log "ERROR: ..."`），
    避免同类静默丢弃再次发生（红线 3：禁止静默失败）。

### 变更（MSS clamp 改为 fw4/fw3 双后端）

- **`99-gaming-optimize` 的 IPv6 MSS clamp 按防火墙后端分派**：
  - **背景**：内核升到 6.18.55 后后端由 fw3(iptables) 变为 fw4(nftables)。
    fw4 **不加载** `/etc/firewall.user`（`uci show firewall` 中无该 include），
    故原先写入该文件的 `ip6tables` 行在 fw4 上是**死代码**。
  - **改动**：`command -v nft && [ -x /sbin/fw4 ]` 为真时写
    `/etc/nftables.d/10-mss-clamp.nft`（`table inet mssclamp`，含
    `maxseg size set rt mtu`）；否则沿用原 `/etc/firewall.user` 写法。
    与 `files/etc/init.d/dnsproxy` 的双后端策略保持一致。
  - **功能冗余说明**：该功能并未缺失 —— fw4 的 `mtu_fix=1`（本脚本设置）
    已为 lan/wan 生成 ingress/egress 共 **4 条** `maxseg size set rt mtu` 规则，
    覆盖 IPv4/IPv6。显式规则作为冗余保留。
  - **机制已验证（只读证据）**：`/etc/nftables.d/10-dnsproxy-lan-intercept.nft`
    的链原样出现在 live ruleset，证明 fw4 确实 glob include 该目录；
    `/etc/nftables.d/` 也在 `/lib/upgrade/keep.d/firewall4` 保留清单内。
    本片段已通过 `nft -c` 语法校验。
  - **启动顺序**：`/etc/init.d/boot`（START=10，跑 uci-defaults）早于
    `/etc/init.d/firewall`（START=19），故首开机即生效。

### 更正（撤销上一版的两处错误判断）

- **撤回「LuCI 下拉框无法表示 DoH 值 → 保存时被重置」的结论**。
  浏览器实测：该字段渲染为 `L.ui.Combobox`，**自定义值被正确渲染**为
  `<li data-value="https://dns.google/dns-query,..." selected="">`，
  `<input type="hidden" name="cbid...tunnel_forward_mosdns">` 的值也完全正确。
  LuCI 侧不存在该问题；真实原因是上面的 uci-defaults 写入失败。
- **撤回「`192.168.1.4` 是 `config_generate` 分配的默认 LAN 网段」的结论**。
  实测日志为 `udhcpc: unicasting a release of 192.168.1.4 to 192.168.1.1` ——
  它是 **WAN 侧 `eth1` 在 `proto='dhcp'` 阶段从上游 DHCP 租到的地址**
  （`board.json` 中 `network.wan.protocol='dhcp'`），随后因切到 PPPoE 而释放。
  结论方向不变（dnsproxy 于开机 29 秒内因上游不可达而报错），但根因描述已更正。

## [v0.4.2] - 2026-10-09

### 新增（LAN 固定 IP 固化）

- **`99-gaming-optimize` 增加 `network.lan.ipaddr='192.168.3.254'`**：
  - **动因**：本仓库此前**从未**设置 `network.lan.ipaddr`。而 `/bin/config_generate`
    第 165 行对 lan 的默认值是硬编码的 `192.168.1.1`（`/etc/board.json` 的
    `network.lan` 不含 `ipaddr`）。旧行为因此是：
    - 保留配置刷机 → 沿用旧 IP（现有路由器为 `192.168.3.254`）
    - **全新刷机（不保留配置）→ 回退 `192.168.1.1`**，客户端仍按
      `192.168.3.254` 访问即失联
  - **改动**：同时写 `ipaddr` / `netmask` / `proto='static'` / `device='br-lan'`，
    使任何刷机方式下 LAN 均为 `192.168.3.254/24`。
  - **执行顺序已核实无冲突**：`/etc/init.d/boot` 的 `boot()` 先执行
    `/bin/config_generate`，再执行 `uci_apply_defaults`（按文件名排序运行
    uci-defaults）。本脚本（`99-gaming-optimize`）排在 `15_odhcpd`、
    `14_migrate-dhcp-release` **之后**，且后两者都不写 `network`。
    `config_generate` 仅在 boot 内调用一次，不会再覆盖。
  - **风险**：LAN IP 变更本身会中断网络（需 `network reload` 或重启）。
    本脚本属**首开机一次性执行**，对已运行的路由器无影响；仅影响新刷固件的首次启动。
    当前路由器已是该值，因此本次改动**不产生任何中断**。
  - 同步更新该节点日志为 `network: lan=192.168.3.254/24, ...`。

## [v0.4.1] - 2026-10-09

> 刷机实测后的修复版本。v0.4.0 的改动在真实固件上验证，发现并修复 BBR 未生效的
> 两个覆盖者；其余改动（SQM 双向整形、filter_aaaa、i18n 符号名）已实测生效。

### 修复（BBR 未生效，被两个后执行者覆盖）

- **`99-gaming-optimize` 增加 `turboacc.global.set='1'` 与 `firewall.@defaults[0].tcpcca='bbr'`**：
  - **现象**：v0.4.0 刷机后 `turboacc.config.tcpcca` 仍为 `cubic`，
    运行时 `net.ipv4.tcp_congestion_control = cubic`。
  - **根因 1**：`/rom/etc/uci-defaults/turboacc` 在本脚本**之后**执行
    （uci-defaults 按文件名排序，`99-gaming-optimize` < `turboacc`），
    其逻辑是 `cat > /etc/config/turboacc` **整体重写**配置，把 `tcpcca` 写回 `cubic`。
    对策：先设 `turboacc.global.set='1'` —— 该脚本首行守卫
    `[ "$(uci -q get "turboacc.global.set")" -eq "1" ] && exit 0` 会使它直接退出。
    这是利用上游自身的幂等开关，无需修改上游包。
  - **根因 2**：内核升级到 6.18.55 后，`/etc/init.d/firewall`（`START=19`）
    新增 `apply_tcpcca_section()`，读 `firewall.@defaults[0].tcpcca`（默认 `cubic`）
    并 `sysctl -w` 覆盖，在 fw4 `start/reload/restart` 时都会执行。
    对策：同时设 `firewall.@defaults[0].tcpcca='bbr'`。
  - **验证**（路由器 192.168.3.254）：三项均为 `bbr`，运行时已生效。

### 已验证生效（v0.4.0 改动在真实固件的实测结果）

- **SQM 双向 cake 整形成功**：上行 `pppoe-wan` → `cake 45Mbit besteffort
  dual-srchost nat nowash overhead 34 mpu 68`；下行 `ifb4pppoe-wan` →
  `cake 900Mbit besteffort dual-dsthost nat ingress`。上行排队时延
  `pk_delay 23us / av_delay 3us`，`overlimits 203438`（整形器积极工作），
  丢包率 <0.01%。对照：刷机前 `pppoe-wan` 为 `qdisc noqueue`（无任何队列管理）。
- **`filter_aaaa=1` 生效**：`chatgpt.com` 的 AAAA 已被拒绝（回落 IPv4 走代理，
  ADR-0001 的语义得到实测确认）；`taobao.com` 仍返回 8 条真实 AAAA（未误伤国内）；
  `google.com` / `steamcommunity.com` / `github.com` 的 AAAA 均为 0 条（合成 SOA）。
- **mosdns `reject` 前置生效**：运行时 `/var/etc/ssrplus/mosdns-config.yaml`
  的序列为 `lazy_cache → reject → prefer_ipv4 → forward`（6 个 plugin 完整）。
- **trafficctl 中文语言包已编入**：`luci-i18n-trafficctl-zh-cn` 出现在
  `opkg list-installed`，证实 v0.4.0 的 i18n 符号名修正有效（原符号从未匹配）。
- **`wan6` 已删除**、`firewall zone wan` 只剩 `wan`、`vsftpd`/`ksmbd`/`autosamba`
  均已从固件移除、`tcp_timestamps=1`、`tcp_notsent_lowat` 回到默认不限。

### 记录（固件基线变化，本版本未修改这些）

- 内核 `6.12.107` → **`6.18.55`**；`DISTRIB_REVISION` `R26.05.20` → **`R26.10.9`**。
- **防火墙后端由 fw3/iptables 改为 fw4/nftables**（`table inet fw4`）。
  SSR-Plus 透明代理同步改用 nftables（`table inet ss_spec`；
  `blacklist_forward.conf` 输出 `nftset=` 而非 `ipset=`）。
- 由此产生一个已知死代码：`/etc/firewall.user` 不再被 fw4 加载
  （`uci show firewall` 中无该 include），故 `99-gaming-optimize` 追加的
  IPv6 MSS clamp 行在当前固件上不生效。功能未缺失 —— fw4 的 `mtu_fix=1`
  已原生下发 4 条 `tcp option maxseg size set rt mtu` 规则覆盖该功能。
  **后续应改为 fw4 的 include 机制（`/etc/nftables.d/`）或直接依赖 mtu_fix。**

### 未落地（需先定位 SSR-Plus 生成路径，同 v0.4.0）

- `applechina.conf` 明文 DNS 加密化、dnsmasq 日志恢复、whitelist 冗余清理。
- 另：`tunnel_forward_mosdns` 会被 LuCI 页面的
  `client_dns_defaults.htm` 在加载时重置为包默认（`tcp://8.8.4.4:53,...`）。
  本次已在路由器上手工改回 DoH 并重启生效；**仓库侧尚无防护**，
  需评估是否改为不依赖该 UCI 项，或加启动后校正。

## [v0.4.0] - 2026-10-09

> 依据：`docs/audit/2026-10-09-network-audit.md`（对在线路由器 `192.168.3.254` 的只读全链路审计，
> 含改动前基线与我方证据；审计过程中有三处初判被实测推翻，已在报告内显式标注）。
> 本次为功能级改动（整形 / DNS 序列 / 分流语义 / 构建包），故按 MINOR 定为 v0.4.0。
> 未打 `v0.3.5` tag —— HEAD 已含该修复但无 tag，本次不补。

### 新增（SQM / cake 整形）

- **`files/etc/config/sqm`（新文件）**：cake 整形默认配置。
  - 动因：实测固件**不含 `tc` 二进制，也不含 `sch_cake.ko`/`ifb.ko`**，`pppoe-wan`
    为 `qdisc noqueue`、无任何队列管理；上行 50 Mbps 是全链路最窄瓶颈，
    其排队时延是游戏 ping 抖动的直接来源。
  - 参数：`download 900000` / `upload 45000`（50 Mbps × 90%）、`qdisc cake`、
    `script piece_of_cake.qos`、`linklayer ethernet`、`overhead 34`、`tcMPU 68`。
  - 下行取保守的 900 Mbps 而非 1000，是为 N2930（4 核 Bay Trail）留余量，
    避免 CPU 先于 SQM 成为瓶颈；若刷机后实测峰值明显低于 900 再下调。
  - 队列：`iqdisc_opts 'ingress nat dual-dsthost'` + `eqdisc_opts 'nat dual-srchost'`。
  - 技术依据（一手来源已核）：**SQM 与 software flow offloading 兼容**，
    仅 hardware flow offloading 不兼容（内核 `__nf_flow_queue_xmit()` 仍调用
    `dev_queue_xmit()`，即 egress qdisc 不被绕过）。故**不关闭** `flow_offloading`，
    NAT1（fullcone）不受影响 —— 实测本机 `xt_FULLCONENAT` 与 `xt_FLOWOFFLOAD`
    已同时被引用并生效。
  - 已知限制：软件 flow offloading 命中后的报文不再经过 mangle，因此**不采用
    DSCP 分级**（其有效性无一手依据），只依赖 cake 的 per-flow 公平队列防大流饿死小包。

### 修复（BBR 未生效）

- **`turboacc.config.tcpcca` 由 `cubic` 改为 `bbr`**（`files/etc/uci-defaults/99-gaming-optimize`）：
  - **现象**：`sysctl net.ipv4.tcp_congestion_control` 运行时为 `cubic`，
    而 `/etc/sysctl.conf` 与 `/etc/sysctl.d/12-tcp-bbr.conf` 均写 `bbr`，
    `kmod-tcp-bbr` 已加载且 `bbr` 在可用列表中。
  - **根因**：`/etc/init.d/turboacc` 以 `S90` 启动（晚于 `S11sysctl`），
    其第 145 行 `sysctl -w net.ipv4.tcp_congestion_control="$tcpcca"`，
    而 `turboacc.config.tcpcca` 默认 `cubic`，开机后覆盖了 sysctl 的值。
  - **作用域澄清**：该开关只影响**路由器自身发起的 TCP**（dnsproxy 的 DoH 出站、
    代理隧道、`ssrplusupdate.sh`、opkg），**不影响** LAN 客户端转发的 TCP。
    原 `sysctl.conf` 注释将其描述为对游戏的作用，属过度声明，已更正。

### 修复（DNS 解析语义）

- **新增 `files/etc/ssrplus/mosdns-config.yaml` overlay，把 `reject` 规则前置**：
  - **问题**：上游模板把 `qtype 28/65 → reject 0` 排在 `$forward_google` **之后**。
    mosdns v5 的 `sequence` 依次执行每条 rule，`ActionReject.Exec` 用
    `qCtx.SetResponse(r)` 覆盖已写入的应答 —— 因此每个被拒的 AAAA/HTTPS 查询都会
    **先真向上游发一次再丢弃**，白付一次经代理的往返。
  - **落点**：语句顺序**只由模板决定**。`/etc/init.d/shadowsocksr` 第 1283–1288 行
    只做四件事（在第 15 行插 DoH 上游、替换 `DNS_PORT`、替换 `DNS_MODE`、改
    `concurrent`），**不重排 `args:` 序列**。故必须改模板。
  - **为何用 overlay**：原模板由 `luci-app-ssr-plus` 包提供且登记为 opkg conffile，
    包升级会覆盖它。仓库此前无该文件副本，新增 overlay 才能固化。
  - **硬约束**：`upstreams:` 必须保持在第 14 行（init 脚本用
    `awk -v line=14 'NR == line+1 {print text} 1'` 注入上游）。因此说明性注释
    **只能放在文件末尾**，文件顶部不得增加任何行。
  - **CI 守卫**：新增步骤 `Verify mosdns template contract`，断言第 14 行确为
    `upstreams:`、`reject` 行号小于 `forward` 行号、`DNS_MODE`/`DNS_PORT` 占位符存在。
    该契约无法被 YAML 语法检查发现，出错会让 mosdns 启动失败、23614 个 gfw_list
    域名解析全部中断，故必须阻断在构建期。
  - **本地验证**：已按 init 脚本的真实命令（awk 注入 + 两次 sed + `DNS_MODE` 替换）
    在本地完整模拟，转换结果经 YAML 解析确认 `plugins=6`、`upstreams` 2 条、
    `concurrent=2`、`reject` 下标 1 < `forward` 下标 3、`lazy_cache` 仍在首位、
    `udp/tcp_server` 的 `entry`/`listen` 正确。
- **`shadowsocksr.@global[0].filter_aaaa` 由 `'0'` 改为 `'1'`**：
  - **这是对 v0.3.5 结论的修正，方向相反。** v0.3.5 的前提是「dnsmasq 把所有域名
    都指向 `127.0.0.1#5335`」；该前提已不成立 —— 现网 dnsmasq 默认走
    `127.0.0.1#5353`（dnsproxy 国内 DoH），仅 `gfw_list.conf` 的 23614 个域名
    与 `black.list` 走 `#5335`（mosdns）。
  - 因此 `'1'` 下 mosdns 的 `reject 0` 只作用于**需走代理的域名**，即
    **拒绝集 = 需走代理的域名集**，正是期望语义：被墙域名回落 IPv4 走代理，
    其余国外域名保留真实 AAAA 走 IPv6 直连。
  - 实测（客户端真实路径）：`taobao.com` 返回 8 条真实 AAAA；
    `google.com`/`chatgpt.com`/`steamcommunity.com` 返回 mosdns 合成 SOA；
    `baidu.com`/`qq.com` 的 SOA 来自真实权威（上游确实无 AAAA，非被抑制）。
  - 若沿用仓库原值 `'0'`，那 23614 个被墙域名将拿到真实 AAAA 并在 IPv6 上
    直连被 RST，表现为「有 IPv6 但打不开站点」。详见 `docs/adr/0001-filter-aaaa-semantics.md`。
- **`tunnel_forward_mosdns` 由 3 个上游收敛为 2 个**（去掉 `https://dns.quad9.net/dns-query`）：
  三个上游以 `concurrent` 竞速取最快，quad9 从国内经代理访问明显慢于
  google/cloudflare，参与竞速只增加方差、不增加可用性。
- **`files/etc/config/dnsproxy` 头部注释更正**：原文写「国内国外统一加密解析、
  不分流」，与同文件 `servers` 段的显式分流（国外域名 → `127.0.0.1:5335`）矛盾。

### 修复（内核旋钮冲突与死配置）

- **`files/etc/rc.local` 删除 RPS 段**：实测该段从未生效 —— `rps_cpus` 最终由
  `packet_steering`（其 `service_triggers` 注册了 `interface.*` raw trigger，
  接口事件会再次触发 reload）改写为单核亲和（`eth0=1`、`eth1=4`），
  `rps_sock_flow_entries` 由 `autocore`（`S99`，最后执行）按 `核心数 × 4096`
  覆盖为 16384。保留该段只会误导后续维护者。
- **`files/etc/rc.local` 删除 `nf_conntrack_helper` 写入**：该 sysctl 路径在
  内核 6.12 已不存在，原 `echo 0 > ... 2>/dev/null` 静默失败。
- **`files/etc/sysctl.conf` 删除 `net.core.rps_sock_flow_entries = 32768`**：
  同上，运行时值由 `autocore` 决定（16384），该行是死配置。
- **`rc.local` / `sysctl.conf` 的 RPS 死配置根因已确证**（审计报告 §10 未决项 1 结案）：
  - `rps_flow_cnt` 的唯一清零点为 `/usr/libexec/network/packet-steering.uc` 第 80–86 行——
    当 UCI `network.@globals[0].steering_flows` 未设置时，默认 `local_flows=0` 被
    **无条件**写入所有队列。证据：该脚本 `-n` dry-run 输出与实测 `eth0=1`/`eth1=4`
    的 `rps_cpus` 指纹完全一致，而 `autocore`（写 `f`）与 `rc.local`（写 `f`）在 4 核下
    都产不出该值，故必是它最后覆盖。其 `service_triggers` 含
    `procd_add_raw_trigger "interface.*" 1000 …reload`，接口事件会再次清零。
  - 因此**若日后需要 `rps_flow_cnt` 非零，应设 `network.globals.steering_flows`**
    （上游 UCI 开关），而不是改 `rc.local`。本次未改（属可选优化，不影响既定目标）。
- **`files/etc/sysctl.conf` 删除 `net.ipv4.tcp_notsent_lowat = 131072`**：
  该值的正确用法是「降低」以改善交互延迟；而代理出口 RTT ≈200ms、上行 50 Mbps
  → BDP ≈1.25 MB，原值 128 KB 不到 BDP 的 1/10，会压制代理隧道与 DoH 吞吐，
  两种目的都不达成。恢复内核默认（不限制）。
- **`files/etc/sysctl.conf` 恢复 `net.ipv4.tcp_timestamps` 为内核默认 1**：
  原值 `0` 关闭 RFC1323 时间戳，同时失去 PAWS（防序号回绕重放）与 RTT 采样；
  唯一收益是每包省 12 字节，而「关闭可降低延迟」在官方文档中**无任何依据**
  （RFC 7323 §1.3 反而指出其对长肥管道是收益项）。

### 修复（DHCPv6 与 MTU）

- **`dhcp.lan.ra_mtu` 由 `1452` 改为 `1492`**：原值推导「1492 − 40」错把 IPv6
  基本头（40 B）当成要从链路 MTU 中预先扣除的封装开销。IPv6 头是报文本身的
  一部分，不占 MTU 之外；预先扣 40 字节只会让每个 IPv6 包少用 40 字节载荷。
  已通告 PPPoE 链路真实 MTU，PMTU 发现由 ICMPv6 `packet-too-big` + MSS clamp 覆盖。
- **删除 `network.wan6`**：实测该接口只跑一个 `-P0` 的 `odhcp6c`，不申请前缀，
  `eth1` 上无全局地址、日志零输出，属纯空转；ISP 的 IPv6 实际经 PPPoE 由
  `wan_6` 获取。同时 `del_list firewall.@zone[1].network='wan6'`，避免 fw3 引用
  不存在的接口。

### 修复（工程健壮性）

- **CI 修正 trafficctl 中文语言包的 CONFIG 符号名**（先于本次改动存在的静默失效）：
  - 原写 `CONFIG_PACKAGE_luci-i18n-luci-app-trafficctl-zh-cn=y`，**该符号从不匹配任何包**，
    被 kconfig 的 `confdata.c` 静默忽略（未知符号直接 `continue`，不报错），
    因此中文语言包**从未被编入固件**。
  - 正确符号为 `CONFIG_PACKAGE_luci-i18n-trafficctl-zh-cn`。推导依据 `luci.mk`：
    `LUCI_NAME = 目录名 = luci-app-trafficctl` → `LUCI_TYPE = word 2 = app` →
    `LUCI_BASENAME = patsubst luci-app-%,%,LUCI_NAME = trafficctl` →
    `LuciTranslation` 生成 `Package/luci-i18n-$(LUCI_BASENAME)-zh-cn`。
  - 同时在 CI 校验步骤中新增对该符号的**阻断式检查**（写错即 `exit 1`），
    避免同类静默失效再次发生。
- **`99-gaming-optimize` 的 MSS clamp 追加改为幂等**：原代码无条件
  `cat >> /etc/firewall.user`，实测该段在现网 `/etc/firewall.user` 中**已重复两遍**。
  改为追加前按标记行 `grep -q` 判重。
- **`.gitattributes` 补规则**：新增 `*.ps1`、`**/etc/config/sqm`、`**/etc/sysctl.conf`。
  其中 `*.ps1` 是修正 AGENTS.md §9 的失实声明（原称已固定 LF，实际无该规则）。

### 变更（构建）

- **CI 增加 SQM 相关包**：`sqm-scripts`、`luci-app-sqm`、`kmod-sched-cake`、
  `kmod-ifb`、`kmod-sched-core`、`tc-tiny`。
  - `sqm-scripts` 取自 coolsnowwolf/packages feed 的 **v1.6.0**（依赖 `iptables`
    而非 `nftables`，与本固件 fw3/iptables 后端匹配）；OpenWrt 官方 master 的
    v1.8.0 依赖 `nftables`，**不适用**。
  - `tc` 由 iproute2 的 `tc-tiny`（默认变体）提供 `/sbin/tc`。
- **CI 显式排除 `vsftpd`、`ksmbd-server`、`autosamba` 及其 LuCI/i18n 包**：
  实测用户不使用 SMB/FTP；`ksmbd` 未配置任何 share（仅 globals），`445` 空转。
  注意 `luci-app-vsftpd` 在 lede 的 `DEFAULT_PACKAGES.router` 里，故排除写在
  `make defconfig` **之前**。
- **CI 新增校验步骤** `Verify SQM enabled and file services excluded`：
  在 `make defconfig` 之后逐项复核（SQM 全部 `=y`、被排除项不为 `=y`），
  任一项不符即 `exit 1`，不使用 `|| true`（遵循「禁止静默失败」红线）。

### 新增（文档）

- `docs/audit/2026-10-09-network-audit.md`：本次全链路审计报告（数据流图、
  改动前基线、15 项问题、逐项回滚、验收清单）。
- `docs/adr/0001-filter-aaaa-semantics.md`：记录 `filter_aaaa` 的语义随
  dnsmasq 路由分裂而反转这一反直觉结论。
- `docs/adr/0002-no-ipv6-proxy.md`：记录「境外 IPv6 不经代理」是有意取舍而非遗漏。
- `GLOSSARY.md`：固定链路术语（分流 / 拒绝集 / 直连 / 强制代理 / 健康检查 /
  整形 / 排队时延 / overhead / 跳数）。
- `AGENTS.md`：更正 §2 红线 4（trafficctl 的 chmod 描述与 CI 不符）、
  §5（filter_aaaa 语义）、§9（.ps1 规则失实）、附录（9 个本机工具实际不存在）。

### 验证

- 静态检查：`ash -n` 通过 `files/etc/uci-defaults/99-gaming-optimize`、
  `files/etc/rc.local`、`files/etc/init.d/dnsproxy`；YAML 通过
  `python -c "import yaml"` 解析 `.github/workflows/build-openwrt.yml`。
- 端到端验证**待用户刷机后执行**，清单见审计报告 §8（配置生效 / DNS 回归 /
  游戏与抖动 / 性能四组），并保留改动前基线用于前后对比。
- 未在路由器上执行任何改动（本次仅改仓库）；NAT1 保持与否、下行峰值是否受
  影响，均属刷机后实测项。

### 未完成 / 已知限制

- **`mosdns-config.yaml` 的 `reject` 前置未落地**：运行时配置由 SSR-Plus init
  脚本生成（源模板含 `DNS_MODE`/`DNS_PORT` 占位符），改动位置未确认前不修改，
  以免改到不被读取的文件。见审计报告 §10 未决项 2。
- **`rps_flow_cnt` 被清零的写入方未定位**（`autocore` 写 4096，实测为 0）。
  在定位前不基于该参数做任何调优。见 §10 未决项 1。
- **上行吞吐无法测量**（本机无可用上传端点，公共镜像 PUT 返回 405），
  SQM 的上行效果只能通过「上行饱和时 ping 抬升」间接验证。
- **`applechina.conf` 的 173 条明文 DNS（`114.114.114.114`）未改**：用户已确认
  希望改走加密链，但该文件由 SSR-Plus 生成，生成路径未确认前不修改。
- **`whitelist_forward.conf` 的 8 条无效 `server=/域名/127.0.0.1` 未清理**：
  实测未形成自环（解析 0–1ms 正常返回），属冗余而非故障，同因 SSR-Plus 生成路径未知。

## [v0.3.5] - 2026-09-21

### 修复（双栈客户端「有公网 IPv6 地址却无法用 IPv6 上网」）

- **`files/etc/uci-defaults/99-gaming-optimize` — `filter_aaaa` 由 `1` 改为 `0`**：
  - **现象**：客户机（如 Hyper-V `vEthernet (External network)`）已通过
    SLAAC 获得全局 IPv6 地址（`240e:355:7f2b:8900::/64`）与默认路由
    （`fe80::230:18ff:fe0b:9b69`），`ping6` 国内外地址均通，但浏览器/IPv6
    站点访问失败，表现为「拿得到地址、上不了 IPv6 网」。
  - **根因**：`filter_aaaa=1` 时 SSR-Plus 生成的 MosDNS(5335) 使用
    `main_sequence_disable_IPv6`，对 `qtype 28`(AAAA) / `65`(HTTPS)
    一律 `reject 0`。而本固件 dnsmasq 把**所有 gfwlist 域名**
    （`/tmp/dnsmasq.d/dnsmasq-ssrplus.d/gfw_list.conf`，约 89 万行）
    **加上** `files/etc/config/dnsproxy` 显式国外域名列表全部指向
    `127.0.0.1#5335` → **国外域名永远拿不到 AAAA 记录** →
    客户端只有 A 记录，协议栈根本不会发起 IPv6 连接。
  - **实测（192.168.3.254，A/B 对照）**：
    - `filter_aaaa=1`：`google.com / github.com / www.wikipedia.org /
      www.debian.org / www.kernel.org / www.python.org / www.mozilla.org`
      的 AAAA 计数**全为 0**（`main_sequence_disable_IPv6`）；
    - `filter_aaaa=0`：上述域名 AAAA 立即恢复正常
      （google=5、github=1、wikipedia=2、debian=5…），
      客户端 `curl -6 https://www.cloudflare.com/` → **HTTP 200 / 1.3 MB**，
      清华 TUNA 镜像 IPv6 大文件（13.3 MB）下载正常；
      国内域名（baidu/qq/taobao）AAAA 与 A 记录均无回归。
  - **说明**：SSR-Plus 本固件仅代理 IPv4（`ip6tables` 中无任何
    `SS_SPEC_TPROXY`/`TPROXY6` 规则，`uci show shadowsocksr` 无 IPv6 选项），
    国外 IPv6 为**直连**。原 `filter_aaaa=1` 只能屏蔽记录、无法把 IPv6 流量
    导入代理，因此「国外仅 IPv4」既不能省流量也不提升匿名性，
    只会让双栈客户端失去 IPv6 能力。如需恢复旧语义可改回 `1`
    （代价：国外域名完全无 IPv6）。

### 修复（工程健壮性）

- **`.gitattributes` 无扩展名文件规则此前实际未生效**：
  原写法为根路径锚定的 `/etc/config/dnsproxy`、`/etc/init.d/dnsproxy`、
  `/etc/uci-defaults/99-gaming-optimize`，但仓库内真实路径带 `files/` 前缀
  （`files/etc/...`），`git check-attr` 显示 `attr/` 为空（未匹配）。
  改为 `**/` 通配（`**/etc/config/dnsproxy` 等）并补上此前遗漏的
  `files/etc/hotplug.d/iface/50-ipv6-pd-lan`、`files/etc/rc.local`。
  注：本次核查确认索引内 blob 已为 LF（`git ls-files --eol` 显示 `i/lf`），
  故 CI 未受影响；此改动消除的是 CRLF 回流的隐患。

### 验证

- 路由器 192.168.3.254 热应用后：国外域名 AAAA 恢复、客户端 IPv6
  网页与大文件传输正常、国内域名与 DNS 加密链路（dnsproxy→DoH）无回归，
  `odhcpd/dnsmasq/mosdns/v2ray/dnsproxy` 8 个进程健康。

## [v0.3.4] - 2026-09-04

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v034)

## [v0.3.3] - 2026-09-02

### CI/CD

- **新增发版工作流 `release.yml`**：推送 `v*` tag 时自动创建 GitHub Release，
  Release notes 自动从 `CHANGELOG.md` 提取对应版本的日志段
  （`## [<tag>]` 到下一个 `## [` 之间，裁剪首尾空行）；支持 `workflow_dispatch`
  手动指定 tag 补发/更新（幂等：Release 已存在则仅更新 notes）。
  CHANGELOG 中找不到对应版本时工作流明确失败（不静默）。
- `build-openwrt.yml`：`v*` tag 推送时同样触发编译；编译成功后把固件产物
  （`*.img.gz`）上传到 release.yml 创建的 Release（等待 Release 就绪 ≤60s，
  文件已存在则跳过）；master 推送仍只保留 artifact。

### 验证

- `v0.3.2` 手动触发：Release 自动创建且 notes 与 CHANGELOG 一致；
- 重复触发：success（幂等更新 notes）；
- 不存在的版本（v9.9.9）：明确失败。

## [v0.3.2] - 2026-09-02

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v032)

## [v0.3.1] - 2026-09-02

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v031)

## [v0.3.0] - 2026-09-02

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v030)

## [v0.2.7] - 2026-09-02

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v027)

## [v0.2.6] - 2026-09-02

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v026)

## [v0.2.5] - 2026-09-02

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v025)

## [v0.2.4] - 2026-09-01

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v024)

## [v0.2.3] - 2026-09-01

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v023)

## [v0.2.2] - 2026-09-01

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v022)

## [v0.2.1] - 2026-09-01

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v021)

## [v0.2.0] - 2026-09-01

> 详细记录已归档 → [`CHANGELOG-archive.md`](CHANGELOG-archive.md#v020)

