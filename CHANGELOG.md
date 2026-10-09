# Changelog

本仓库所有功能/配置改动均记录于此。版本判型遵循全局规范（PATCH / MINOR / MAJOR）。

## [v0.4.7] - 2026-10-10

### 新增 — trafficctl 升级到上游 1.21.4 并建立「可跟进上游」的维护机制

**背景**：本地包此前是上游 `YusDyr/luci-app-trafficctl` **v1.8.0** 的 vendored 副本，
版本落后很多（`status.js` 3077 → 4677 行），且上游更新不会自动进入本仓库。
本次拉到上游最新 **1.21.4**，把本地改动重新落地，并把差分固化成 patch，
使「日后跟进上游」成为可验证的流程而不是靠人工记忆。

**1. 全量 vendor 上游 1.21.4**

- 包内文件 30 → **43**（上游新增 13 个文件：`portfw.js`、`trafficctl-cut.sh`、
  `trafficctl-ifaces.sh`、`trafficctl-metrics.sh`、`trafficctl-names.sh`、
  `trafficctl-netify.sh`、`trafficctl-portfw.sh`、`trafficctl-rdns-refresh.sh`、
  `trafficctl-subnets.sh`、`trafficctl-totals.sh`、`www/cgi-bin/trafficctl-metrics`、
  `init.d/trafficctl-cut`、`lib/upgrade/keep.d/luci-app-trafficctl`）。
- `LUCI_DEPENDS` 新增 `+tc +iw +hostapd-utils`；`config/trafficctl` 新增
  `shape_ifb`、`netify_endpoint`、`netify_interval` 等项。
- 上游 Windows checkout 为 CRLF（实测 39/40 文件）→ 全部转 LF（红线 1）；
  执行位按上游 git 索引恢复为 **29 × 100755 + 14 × 100644**
  （Windows 上 `Copy-Item` 会丢失该信息，必须用 `git update-index --chmod`）。

**2. 保留并重新落地本地改动（三项）**

- **（关键）重写 `trafficctl-bytes-nft.sh`**：上游**至今未修**该缺陷，
  仍用本内核不支持的语法且只挂 forward 单钩子。
  - `nft add map … '{ type ipv4_addr : counter; flags dynamic; }'` 与
    `'update @bytes_in { ip daddr counter }'` 在内核 6.18.55 / nftables 1.1.6 上
    均报 `Error: Could not process rule: Not supported`，错误被 `2>/dev/null` 吞掉
    → 集合从不建立、脚本永远返回 `[]` → **速率列恒为 `—`**。
    上游 1.21.4 仅新增了「失败时回退 conntrack」，但 **conntrack 看不到被
    REDIRECT 到本机的代理流量**，速率仍不准。
  - 改为受支持的 `set { type ipv4_addr; size 65535; flags dynamic; }` +
    `add @set { ip saddr counter }`。
  - **三钩子并用**（上游只有 forward）：SSR-Plus 用 REDIRECT 把客户端连接引到
    本机 v2ray(:1234)，数据包走 **INPUT/OUTPUT 而非 forward**。
  - 用 `@lan` 集合限定地址归属，避免 `output` 钩子把路由器自身对 WAN 的连接
    （`1.2.4.8`、`10.x` 等）写进集合污染数据。
  - 保留单事务原子重建 + `nft -c -f` 预校验（红线 8）。
  - 保留上游 JSON 契约字段 `bytes_tcp` / `bytes_udp` / `src` / `degraded`
    （`trafficctl-totals.sh` 会消费，缺失会导致重基线判定与信任标记失真）。
- **设置区 tab 分页 + 默认自动刷新 + 1s/2s 档位**：
  - Telegram Bot 表单极长（实测单卡片 1270px），改为独立 tab
    （`Display & Table` / `Devices` / `Telegram Bot`），tab 选择持久化。
  - 上游刷新默认值是「**关**」（`loadOpts().refresh || 0`），冷启动不刷新；
    改为经 `optRefresh()` 取默认 5 秒，并新增 UCI
    `trafficctl.main.refresh_interval`（默认 `5`）实现**路由端可下发**。
  - 刷新档位新增 **1s / 2s**（上游最短 5s）。
  - 设置区由「默认折叠隐藏」改为**常显标题栏 + 内容始终可见**。
  - 新增 `refreshSpeedViews()`：改「窗口」「方法」后立即重算重绘。
- **中文翻译**：新增 `po/zh-cn/luci-app-trafficctl.po`，覆盖 **403/403** 条界面
  字符串、0 条空译文；`.pot` 模板一并重生成（上游只带 121 条，实际需要 403 条）。

**3. 建立「可跟进上游」的维护机制**

- `patches/luci-app-trafficctl/`（4 个 patch + `UPSTREAM` + `README.md`）：
  记录相对上游的全部差分。`UPSTREAM` 记录基线 tag（`v1.21.4`）。
- `tools/sync-trafficctl.sh`：一条命令升级上游 —— 克隆指定 tag、覆盖包目录
  （保留本地专有文件）、重算 patch、在干净基线上回放校验。
- `tools/regen-trafficctl-patches.py`：改完 `package/` 下的文件后重算 patch，
  并**验证「干净上游基线 + 全部 patch」与工作树逐字节一致**。
- `tools/check-trafficctl-i18n.py`：校验中文覆盖率；
  `--write-pot` 可直接重生成模板。
- **CI 新增守卫** `Verify luci-app-trafficctl local invariants`：
  断言 nft 后端不含禁用语法、三钩子与 `@lan` 齐备、JSON 契约字段完整、
  po/zh-cn 存在且翻译完整、`optRefresh` 与 `1s` 档位存在、设置区 tab 存在、
  无 `td[data-…]` 前缀选择器；并从 `UPSTREAM` 记录的 tag **真实克隆上游、
  重放全部 patch、要求结果与 vendored 包逐字节一致**。
  上游发新版而 patch 未跟上时 CI 显式失败，不再静默。
- CI 显式启用 `iw`、`hostapd-utils`、`conntrack` 并断言（1.21.4 的功能依赖；
  缺 `hostapd_cli` 时界面会提示「WiFi 阻断未生效」）。

**4. 顺带修复**

- 设备表底部提示文案由 "Download speed updates…" 改为
  "Download **and upload** speeds update…"（表格已有上下行两列）。

### 验证

**静态**

- `node --check status.js / portfw.js` 通过；全部 shell 脚本 `sh -n` 通过。
- `msgfmt --check` 编译通过，**443 条已翻译**；`msgfmt` 反解确认
  `Display & Table → 显示与表格` 确实在产物中。
- `tools/check-trafficctl-i18n.py`：界面字符串 403 条、po 443 条、
  缺失 0、空译文 0。
- `tools/regen-trafficctl-patches.py`：patch 可 `git apply -p1` 套用、
  结果与工作树逐字节一致、可 `-R` 干净回退。
- 全仓库跟踪文件 CRLF = **0**。
- CI YAML 解析合法（26 个步骤）。

**路由器实测（192.168.3.254，固件 24.10.5 x86/64）**

- nft 后端：从零重建后 `nft list table inet trafficctl_mon` 显示集合与三钩子
  全部正确（`mon_forward` 2 条规则 / `mon_input` 1 条 / `mon_output` 1 条），
  `@lan` 正确解析为 `192.168.3.0/24`，建表耗时 0.43s。
- 计数器实测增长：持续下载 60 MB 文件时本机 `bytes_in` 从
  `395776761` 稳步增至 `911225010`（每 2 秒约 +115 MB）。
- UI 端到端：本机下行 2.3–3.4 Mbit/s、上行 4.1–6.1 Mbit/s，
  12 次采样 **10 个不同值**（修复前恒为 `—`）。
- 1 秒刷新精确验证：10 秒内 10 次 ubus 调用，时间戳间隔**精确 1000ms**
  （`callsPerSec: 1.00`）。
- 默认刷新：冷启动（已清 `localStorage`）后自动进入
  `扫描所有设备中…` ↔ `✓ 完成` 循环，无需任何手动操作。
- tab：渲染出 `Display & Table` / `设备` / `Telegram机器人` 三个 tab，
  默认打开第一个，Telegram 为独立页。
- rpcd：`ubus call luci.trafficctl config_get` 返回
  `"refresh_interval": 5`，端到端接线打通。

**已知限制（非缺陷）**

- 路由器上的 `luci-app-trafficctl.zh-cn.lmo` 是 **10 月 9 日刷机**时从 1.8.0
  编译的旧文件，故新增字符串（如 `Display & Table`）在**当前路由器**上仍显示
  英文。`.lmo` 由构建主机的 `po2lmo` 在打包时生成（路由器上没有该工具），
  下一次固件构建会从本仓库 `.po` 重新编译 —— 已用 `msgfmt` 编译出 444 条
  译文证明该串在产物中。

## [v0.4.6] - 2026-10-10

### 修复 — trafficctl 三处交互缺陷（设置未展开 / 布局凌乱 / 不自动刷新）

**1. 设置区未能完全展开**

- 根因：`mkCollapsible` 把每个小节的折叠状态**持久化到 `localStorage`**
  （键 `tc.set.<标题>`）。用户曾收起过某个小节后，该状态被永久记住，
  之后每次打开页面它都是收起的 —— 表现为「设置没有完全展开」。
  此外 4 个小节（Telegram / 日志 / 流量卸载 / 表格与速率）初始 `startOpen=false`。
- 处置：**移除折叠状态持久化**（折叠仅在本次会话内有效），并把
  `startOpen` 缺省值改为 `true` —— 全部小节默认展开。
- 顺带修正一处**懒加载时序缺陷**：此前需先 `mkCollapsible(...)` 返回对象、
  再赋值 `api.onFirstOpen`。当小节初始即展开时，`mkCollapsible` 内部已触发
  首次展开，而此时回调尚未挂上 → **懒加载永不执行，内容区空白**。
  现改为把 loader 作为**构造参数**传入，在展开时刻同步触发。

**2. 设置区布局凌乱**

- 根因（两次迭代才定案）：
  - 首版用 `repeat(auto-fit, minmax(320px,1fr))` 网格。CSS Grid 的**行高由该行
    最高的卡片决定**，邻列矮卡片下方留大片空白。
  - 次版改为按语义手工分两列（flex）。当某列含 Telegram（实测高度 **1270px**）
    这类超长卡片时，另一列出现数百像素空白（实测左列 340px vs 右列 1692px）。
- 处置：改为**扁平列表 + CSS 多列瀑布流**（`column-count: 2` + `break-inside: avoid`），
  由浏览器按卡片实际高度自动分列，列高自然均衡；窄屏（≤760px）自动降为单列。
  卡片顺序按使用频率排列：显示 / 表格与速率 → 流量卸载 → 日志 → Telegram。
  展开态改用**左侧色条**标示（比整框变色更克制、更易扫视）。
- 顺带修掉一处**chips 溢出**：`.tc-chips-wrap` **此前完全没有样式定义**，
  导致「可见列」一长串 chips 不换行、右侧被卡片的 `overflow:hidden` 裁掉。
  现补上 `display:flex; flex-wrap:wrap`。

**3. 冷启动不按刷新间隔拉数据 / 选中设备后速率定格**

- 根因（三处，均为真实缺陷）：
  - **默认刷新为「关」**：`refreshPick` 用 `opts.refresh||0` 作默认值，
    冷启动打开页面后**数据完全不会自动刷新**，必须手动点「所有设备」才更新一次。
  - **单设备模式直接跳过速率轮询**：`pollBytes()` 开头
    `if (!isAllMode()) return;` —— 选定某台设备后，速率与流量曲线**永久定格**。
  - **单设备模式主动停掉轮询**：`runQuery()` 在非 all 分支调用
    `self._stopBytesPoll()`，把速率/丢弃/整形轮询**整体停掉**，
    而 `runSingle()` 只查一次连接列表。
- 处置：
  - 新增 `getRefreshSecs()`，缺省 **5 秒**（用户显式选「关」时仍尊重其选择）；
    `_setupTimer` 改用它，冷启动即建立定时器。
  - `pollBytes()` 去掉按模式提前返回，改为**按模式分派刷新目标**：
    all 模式刷表格单元格，单设备模式刷该设备的流量曲线。
  - `runQuery()` 的单设备分支由 `_stopBytesPoll()` 改为 `_startBytesPoll()`。
  - `_restartBytesPoll()` 不再限定 all 模式。
  - `_startBytesPoll()` 在 `pollInterval=0`（用户选「关」）时仍照常建立
    丢弃/整形轮询，避免那两个面板一起冻结。
  - 新增 `refreshSpeedViews()`：「窗口」「方法」变更时**立即**按新参数重算并重绘
    （此前只是写进 `localStorage`，要等下一个轮询周期才生效，用户观感是
    「改了没反应」）；切换「方法」时同时清空历史与 EWMA 累加器，避免混算。
  - 从「关」切回非 0 刷新间隔时立刻拉一次，不让用户白等一整个间隔。

### 验证（路由器 192.168.3.254，OpenWrt 24.10.5 / 内核 6.18.55）

- **设置区**：5 个卡片 `allOpen=true`（全部展开）；两列瀑布流；
  懒加载全部生效（Telegram 760px 内容、流量卸载 203px、日志 154px 均已加载）。
- **冷启动自动刷新**：清空 `localStorage`（模拟全新访客）后重载页面，
  **不做任何交互**，3 秒内自动出现数据（`active=1`、22 个 sparkline 渲染），
  本机 `192.168.3.238` 下=32.0 Kbit/s、上=9.2 Kbit/s。
  修复前该场景必须手动点「所有设备」才有数据。
- **「刷新」chip 默认高亮 5s**（`refreshActive=["5s"]`）。
- **状态文本周期性变化**：`扫描所有设备中…` ↔ `✓ 完成` 每约 5 秒交替，
  证明定时器在持续拉取。
- **单设备模式图表自动刷新**：选定 `192.168.3.238` 后**不做任何操作**，
  连续 8 次采样中 SVG 路径坐标持续变化、`uniqueD=8`、
  SVG 长度 17883 → 19131 持续增长，证明新数据点在不断追加。
  修复前此模式下 `pollBytes` 直接 return，图表永久静止。
- 顺带确认 v0.4.5 的后端修复仍正常：`trafficctl-bytes-nft.sh` 返回真实数据，
  `forward` 规则数恰为 2（无重复累计）。

## [v0.4.5] - 2026-10-10

### 修复（严重）— v0.4.4 导致 fw4 整体加载失败、国内域名大面积无法解析

**症状**：刷入 v0.4.4 后，多个国内域名/服务/软件无法解析与联网。

**根因（已在路由器上复现并定位到源码行）**：

1. fw4 的 ruleset 模板 `/usr/share/firewall4/templates/ruleset.uc` 中，
   第 15 行 `table inet fw4 {` 开表，第 104 行
   `include "/etc/nftables.d/*.nft"` —— **include 位于该 table 内部**。
   因此 `/etc/nftables.d/` 下的文件**只能是裸 chain**，不得含 table 声明。
2. v0.4.4 写入的是完整 `table inet mssclamp { chain ... }`，被嵌进
   `table inet fw4` 内部 → **嵌套 table** → nft 语法错误。
3. `fw4 check` 实测报错：
   ```
   /etc/nftables.d/10-mss-clamp.nft:1:1-5: Error: syntax error, unexpected table
   table inet mssclamp {
   ^^^^^
   ```
   而 fw4 的加载路径是
   `print | nft -c -f $STDIN || die "The rendered ruleset contains errors"`
   —— 校验失败则**整个 ruleset 不加载**，于是 input/forward/dstnat/srcnat、
   DNS 拦截、透明代理等全部规则消失，表现为国内解析与联网大面积异常。
4. 对照证据：同目录既有的 `10-dnsproxy-lan-intercept.nft` 用的是正确的
   **裸 chain** 写法，且实测该 chain 出现在 `table inet fw4` 内部
   （`nft list chain inet fw4 dns_intercept_lan` 成功）。

**处置**：**整段删除** `/etc/nftables.d/10-mss-clamp.nft` 的生成逻辑
（`files/etc/uci-defaults/99-gaming-optimize`），并在原处写明原因与硬约束。
删除而非改写的理由：

- **功能冗余**：上述 `firewall.@zone[0].mtu_fix='1'`（配合 wan zone 默认值）
  会让 fw4 原生生成 4 条 MSS clamp 规则（实测 `nft list table inet fw4`）：
  `oifname br-lan` / `oifname pppoe-wan` / `iifname br-lan` / `iifname pppoe-wan`
  各一条 `maxseg size set rt mtu`，用 `rt mtu` 在 PPPoE(1492) 场景下与显式
  clamp 等价，且同时覆盖 IPv4 与 IPv6。删掉不损失任何功能。
- **fw3 路径是死代码**：fw4 不加载 `/etc/firewall.user`
  （`uci show firewall` 中 firewall.user include 计数 = 0），原 ip6tables
  规则从未生效。
- **fw4 路径有风险**：即本次故障。
- 另删除了 `/etc/firewall.user` 中同源的历史遗留行（死代码）。

### 修复（严重）— trafficctl 速率监控完全失效（上下行都是 `—`）

**症状**：流量控制页面的「下行速率」列恒为 `—`；且没有任何上行速率列。

**根因（三层，均已实测确证）**：

1. **nftables 语法在本内核不被支持，且错误被静默吞掉**。
   `trafficctl-bytes-nft.sh` 用：
   ```
   nft add map ... '{ type ipv4_addr : counter; flags dynamic; }'
     -> Error: Could not process rule: Not supported
   nft add rule ... 'update @map { ip saddr counter }'
     -> Error: Could not process rule: Not supported
   ```
   本机内核 `6.18.55` / nftables `1.1.6`。两条错误都被 `2>/dev/null`
   吞掉，结果只留下一个**空的 forward 链**，ubus 的 `bytes` 方法
   永远返回 `[]`，前端两列速率恒为 `—`。
   实测本内核**可用**的等价语法为：
   `nft add set ... '{ type ipv4_addr; size 65535; flags dynamic; }'`
   配合 `nft add rule ... 'add @set { ip saddr counter }'`。
2. **挂钩点选错，看不到代理流量**。SSR-Plus 用 REDIRECT 把客户端连接引到
   路由器本机的 v2ray(:1234)，REDIRECT 把目的地址改写为本机，数据包因此走
   **INPUT/OUTPUT，不经 forward**。实测对照（客户端下载 150 MB）：
   | 挂钩点 | 增量 |
   |---|---|
   | `output daddr=客户端` | 157548502 B（完整捕获） |
   | `input saddr=客户端` | 1360391 B（客户端小请求） |
   | `forward saddr=客户端` | 5932 B（几乎为零） |
   原实现只挂 forward，故完全看不到。
3. **集合会被非 LAN 地址污染**。output 钩子会看到路由器自身对 WAN 的连接，
   仅用 `oifname br-lan` 限定仍会写入 `1.2.4.8`、`10.x`、`14.x` 等地址。
   实测必须同时限定**地址属于 LAN 网段**（自动生成的 `@lan` 集合）才能收敛。

**处置**：重写 `trafficctl-bytes-nft.sh`：

- 改用内核支持的 `set` + `add @set { ... counter }` 语法。
- 同时挂 **forward / input / output** 三个钩子（三者对同一数据包互斥，
  不重复计数）：
  - 下行 = `forward daddr=设备` + `output daddr=设备`
  - 上行 = `forward saddr=设备` + `input saddr=设备`
- 三个钩子均用 `@lan` 集合限定地址归属；`@lan` 由 `tctl_lan_subnets`
  **动态生成**（支持多网桥/多 VLAN），不硬编码。
- 建立逻辑改为**单事务原子重建**（`nft -f` 内 `delete table` + 重建）。
  原「先检查后逐条 add」的写法存在竞态：前端每 2 秒轮询与手工调用并发时，
  两个进程会同时通过检查各建一套规则 → 规则重复 → 速率翻倍
  （实测 180 MB 下载被记成 380 MB）。原子事务下并发调用只会整体覆盖，
  结构始终唯一。
- 结构自检（集合存在 + 各链规则条数正确）后才重建，避免每次轮询清零计数。
- 解析器适配 `nft list set` 的 `IP counter packets N bytes M` 格式
  （旧实现按 `nft list map` 的 `IP : counter ...` 解析，格式已不匹配）。
- 重建前先 `nft -c -f` 只校验不提交，避免写坏运行中的防火墙。

### 新增 — trafficctl 设备表「上行速率」列

- 新增 `_upspeed` 列（`UL Speed`），紧邻「下行速率」。
- 上行数据其实**早已存在**（`packets_out` 差分算出的 `speedUp`），
  但此前只用于弹窗图表，未进入设备表；本次将其并行接入新状态
  `_upSpeedMap` / `_upSpeedHistory` / `_upSpeedEwma`，与下行完全对称。
- 上下行**色义区分**：下行用 `--tc-speed`（蓝），上行用 `--tc-ok`（绿，
  与弹窗图表中上行曲线一致），新增 `.tc-upspeed-active` 样式。
- `updateSpeedCells` 实时刷新上行单元格；设备下线时同步清理三份上行状态。
- 底部提示改为「下载与上传速率每 2 秒更新一次」。
- 补充 4 条翻译：`UL Speed` / `Current upload speed (bytes/sec from device to router)`
  / `changes are saved automatically` / 提示串（旧串同步替换），
  `.po` 与 `.pot` 均已更新。

### 变更 — trafficctl 设置区改为常显卡片网格（不再整体收起）

- 旧实现把整个设置区包在可折叠容器内且**初始隐藏**，用户必须点击标题才能
  看到任何设置项，收起后完全看不出里面有什么。
- 现改为：常显标题栏（不可折）+ 内容始终可见；内部各小节改为
  **自适应卡片网格**（`repeat(auto-fit, minmax(320px, 1fr))`，
  窄屏单列、宽屏多列），每节标题恒常显，仅**单节内容**可独立折收。
- 「显示」「表格与速率」默认展开；「Telegram机器人」「日志与持久化」
  「流量卸载」内容较重，默认收起但标题可见、一键展开。
- 各节展开状态持久化到 `localStorage`，刷新后保持用户的布局选择。
- 懒加载改为 `onFirstOpen` 回调（首次展开才发起 RPC），避免一次性打满请求。

### 验证（路由器 192.168.3.254，OpenWrt 24.10.5 / 内核 6.18.55）

- **fw4 修复**：`fw4 check` 由报 `unexpected table` 变为
  `Ruleset passes nftables check.`；`table inet fw4` 内 chain 数 34、
  DNS 拦截规则 2 条、`ss_spec` 表在、fullcone 规则 2 条；
  baidu/taobao/jd/bilibili 均 200，google 302，github 200，出口 `203.27.106.146`。
- **速率后端**：并发 8 实例后 `forward=2 / input=1 / output=1`（无重复）；
  180 MB 下载实测 `bytes_in` 增量 190296934（不翻倍）；
  `bytes` RPC 由 `[]` 变为含真实数据（本机 993 MB）；
  集合内非 LAN 地址数 = 0。
- **速率前端**：设备表新增「UL Speed」列；
  实测 `192.168.3.238` 下=35.7 Kbit/s、上=23.7 Kbit/s，
  下行 class `tc-speed-active`（蓝）、上行 class `tc-upspeed-active`（绿），
  21 个 sparkline 全部渲染，提示为中文「平均 / 最大」。
- **设置区**：默认展开；3 列卡片网格；5 个小节标题全部可见。

### 说明

- 本次同时完成了「是否已全面切到 fw4」的核查，结论：**已全面切换**。
  判据：`table inet fw4` 在跑且承载全部规则（34 条链）；DNS 拦截与透明代理
  均在 nftables（`iifname br-lan ... redirect`、`table inet ss_spec`）；
  fw3 专属的 `/etc/firewall.user` include 计数为 0（死代码）；
  `iptables filter/nat/mangle` 与 `ip6tables mangle` 只剩默认策略行
  （无任何规则）；`ip_tables` 内核模块**未加载**。
  残留的 `iptables`/`ip6tables` 二进制与 `kmod-ipt-*` 是 SSR-Plus 等包的
  依赖项，属正常共存，不表示仍在用 fw3。
- 本版本**修复了 v0.4.4 的严重故障**，建议刷入替换。

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

### 修复（DNS proxy 报错根治）

- **`files/etc/config/dnsproxy` — 移除对 SSR-Plus 代理的 DNS 兜底依赖**：
  - 删除 `fallback https://8.8.8.8/dns-query`：8.8.8.8 在 SSR-Plus blacklist 中，
    dnsproxy 进程（与主 netns 同 ns）到 8.8.8.8 的出站被 `REDIRECT :1234` 代理接管；
    SSR-Plus 规则重建/订阅更新窗口（每日 02:00 cron、开机、节点切换）内必超时，
    dnsproxy 无健康探活 → 日志刷 `context deadline exceeded` / `i/o timeout` ERROR。
  - 保留 `fallback https://1.12.12.12/dns-query`（国内直连、不依赖代理）作最兜底。
  - 上游 `https://doh.pub/dns-query` → `https://1.12.12.12/dns-query`：
    doh.pub 为域名型 DoH（依赖 bootstrap 明文预解析、曾现 502/超时），
    1.12.12.12 为 IP 型直连 DoH（china ipset 命中 → 不走代理、无 bootstrap 依赖）。
  - 国外域名（google/github 等）仍显式分流 MosDNS(5335)→SSR 代理 DoH，防污染不变。
- **`files/etc/init.d/dnsproxy` — 修复 fw3 LAN DNS 拦截规则被 SSR-Plus/fw3 reload 清空**：
  - 原实现 `iptables -I PREROUTING 1` + `firewall restart`：fw3 reload/restart 会重建
    nat 表冲掉规则，且 restart 会连带清掉 SSR-Plus 自身规则（重入风暴）；
    实测 PREROUTING 中已无任何 `dport 53` 拦截，客户端手填 DNS 可绕过加密链路。
  - 改为写入 fw3 用户链 `prerouting_rule`（SSR-Plus 不操作该链），命令写入
    `/etc/firewall.user` 由 fw3 reload 自动幂等重放；不再触发 firewall restart。
- **`files/etc/uci-defaults/99-gaming-optimize`**：同步注释说明。

### 验证

- 路由器 192.168.3.254 热补丁后：`github.com/www.baidu.com` 解析正常；
  SSR 规则重建窗口触发后 logread 无 dnsproxy ERROR；`iptables -t nat -S PREROUTING`
  拦截规则经 `prerouting_rule` 存在且在 SSR 规则之前生效（fw3 reload 后仍存活）。

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

### 变更

- **dnsproxy 上游模式改为 `parallel`**（原 `load_balance`）：
  - 实测（192.168.3.254，冷查询 10 样本中位数）：
    `parallel 39.6ms` < `load_balance 62.5ms` < `fastest_addr 97.7ms`；
  - `parallel`：并行查询全部上游取最快响应，延迟最低且稳定（P90 57-59ms）；
  - `load_balance`：轮询，偶发命中慢上游导致 P90 偏高（93ms）；
  - `fastest_addr`：每次查询对返回 IP 额外做 TCP/ICMP 探测，开销大（+40-50ms），
    仅适合上游返回不同质量 IP 的场景；本架构上游为同质国内 DoH、国外域名已分流
    到 MosDNS，故不推荐。

## [v0.3.1] - 2026-09-02

### 修复

- **LAN DNS 拦截被 SSR-Plus 透明代理抢先**：SSR-Plus 的 `SS_SPEC_WAN_AC` 链在 PREROUTING
  第 1 条（fw3 restart 后重新插到最前），先于我们的 DNS REDIRECT（在 prerouting_rule 链内），
  导致客户端手动指定 8.8.8.8/1.1.1.1 的 DNS 查询被 SSR-Plus 劫持（到真 8.8.8.8 明文），
  未走 ALL_DOH 加密链路。
- 修复：`update_lan_intercept_ipt` 改为**用 `-I PREROUTING 1` 把 DNS REDIRECT 插入
  PREROUTING 最前**（firewall restart 重建链后再次 -I，确保先于 SSR-Plus 规则）；
  firewall.user 段仅保留说明注释（规则由 init 动态管理），避免重复。

### 验证（192.168.3.254 + Win11 客户端 192.168.3.238）

- Win11 `nslookup <域名> 8.8.8.8`：tracert 第一跳 192.168.3.254；254 的 PREROUTING
  REDIRECT UDP 计数随查询增长（0→9）；dnsproxy 日志显示该查询
  `sending request addr=https://doh.360.cn:443/dns-query`（**加密 DoH 上游**）→ 完整链路
  `Win11 → REDIRECT → dnsmasq:53 → dnsproxy:5353 → DoH` 加密解析生效。

## [v0.3.0] - 2026-09-02

### 新增

- **国外域名 DNS 分流（走 SSR-Plus 代理）**：
  - `files/etc/config/dnsproxy`：`servers.upstream` 增加常用国外域名
    （google/youtube/github/twitter/x/facebook/instagram/whatsapp/telegram/reddit/
    discord/spotify/netflix/cloudflare/amazon/stackoverflow/wikipedia 等）的
    domain-specific 规则 → `127.0.0.1:5335`（SSR-Plus MosDNS）；
  - `files/etc/uci-defaults/99-gaming-optimize`：配置 SSR-Plus 启用 MosDNS
    （`pdnsd_enable=4`）与国外 DoH 上游（`tunnel_forward_mosdns` =
    dns.google/cloudflare-dns.com/quad9），MosDNS 监听 5335，上游经 SSR-Plus
    TPROXY 代理出站，返回真实 IP 防污染。
- **最终 DNS 架构**：
  ```
  LAN → dnsmasq:53 → dnsproxy:5353（ALL_DOH 加密主链）
                        ├─ 国内域名 → 国内 DoH（阿里/腾讯/360）
                        ├─ 国外域名 → MosDNS:5335（SSR-Plus，国外 DoH 经代理）
                        └─ fallback → 1.12.12.12（国内）/ 8.8.8.8（经代理）
  ```

### 验证（192.168.3.254）

- 国外域名全部真实 IP：google 142.251.152.119、github 20.205.243.166、
  youtube 142.251.155.4、reddit 151.101.65.140、twitter 151.101.66.146；
- 国内域名正常：baidu 183.2.172.177、qq 101.91.22.57；
- MosDNS(5335) 运行、dnsproxy running、SSR-Plus ENABLED、拦截规则 v4:2 v6:2。

## [v0.2.7] - 2026-09-02

### 修复（完整审查产出）

- **0003 汉化补丁补齐拦截开关标题**：审查发现 0003 的 settings.js 两个 hunk（第 6-66、77-316 行）
  未覆盖第 67-76 行的拦截开关（0001 加入），导致最终文件标题仍是双语
  「拦截所有客户端 DNS（Intercept all client DNS）」且描述含过时的 firewall4 表述。
  已重新生成 0003：标题改为纯中文「拦截所有客户端 DNS」，描述改为
  「由 dnsproxy init 自动管理（fw3 用 iptables、fw4 用 nftables）」，共 210 处替换。
- **init 注释同步双后端**：文件头与 `update_lan_intercept` 相关注释由仅描述 nftables 更新为
  fw3/fw4 双后端说明；`FW_USER` 增加 `local` 声明（避免泄漏到全局）。
- **config/dnsproxy 注释同步**：拦截管理描述由「init + firewall4」改为双后端。
- **文档同步**：patches README 与 CHANGELOG 中的 0001/0003 描述更新（双后端、210 处）。

### 审查验证

- 干净克隆 → 0001→0002→0003 顺序应用全部成功；6 个 JS 文件 `node --check` 全部通过；
  拦截开关最终为纯中文标题；ACL json 语法正确；所有 `_()` 字符串无漏汉化（技术术语保留英文）。

## [v0.2.6] - 2026-09-02

### 修复

- **开机时 LAN DNS 拦截规则不生成（时序 bug）**：`start_service` 中 `update_lan_intercept`
  在 `procd_close_instance` 后立即执行，用 `pgrep dnsproxy` 判断运行状态——但 procd 异步
  启动进程，开机瞬间进程可能尚未就绪 → 误判为“未运行” → 走了关闭分支，拦截规则不生成。
- 改为**按配置意图判断**（`lan_dns_intercept=1` 且 `dnsproxy.global.enabled=1` 即开启），
  `update_lan_intercept` 支持 `auto|off` 两种模式：
  - `auto`（start/reload）：按配置判断开启或关闭；
  - `off`（stop/disabled）：强制移除规则，防止客户端 DNS 被导向失效链路断网。
  删除不再使用的 `service_is_running`（pgrep）辅助函数。

### 验证（虚拟机 192.168.3.241，最新固件）

- stop → 规则移除（v4/v6 均 0）；start → 规则恢复（v4:2 v6:2）；reload → 保持；
- **reboot → 开机后规则自动生成（v4:2 v6:2，firewall.user ALL_DOH 段存在），dnsproxy running+ENABLED**。

## [v0.2.5] - 2026-09-02

### 修复

- **LAN DNS 强制拦截在 fw3（iptables）固件上不生效**：lede（coolsnowwolf）默认防火墙仍是
  fw3（xtables-legacy），无 `nft` 命令、不读取 `/etc/nftables.d/`，原有仅基于 firewall4 的
  拦截实现完全无效。
- 改造 `files/etc/init.d/dnsproxy` 的 `update_lan_intercept` 为**双后端自动检测**：
  - `nft` 命令存在（fw4/OpenWrt 25.x）→ 写 `/etc/nftables.d/10-dnsproxy-lan-intercept.nft`
    （`chain dns_intercept_lan`，priority dstnat+1，v4/v6 UDP/TCP 53 redirect）+ `fw4 reload`；
  - 无 `nft`（fw3/lede）→ 写 `/etc/firewall.user` 的 `ALL_DOH` 标记段
    （v4 用 `prerouting_rule` 自定义链，v6 用 `PREROUTING` 主链，因 fw3 的 ip6tables 无自定义链）
    + `/etc/init.d/firewall restart`。
  - 标记段包裹保证幂等（先删旧段再写）；ON/OFF 均触发防火墙重载即时生效。

### 验证（虚拟机 192.168.3.241，fw3/iptables-legacy）

- ON：`iptables -t nat -L prerouting_rule` 与 `ip6tables -t nat -L PREROUTING` 均出现
  UDP/TCP 53 → REDIRECT 规则；
- OFF：规则全部移除，dnsproxy 服务保持 running；
- 重新 ON：规则恢复。
- 说明：该 VM 无 WAN（PPPoE 未拨号），dnsproxy 的 DoH bootstrap 不可达属环境限制；
  配置链路（LAN→dnsmasq:53→dnsproxy:5353→DoH）与拦截规则均已实证正确。

## [v0.2.4] - 2026-09-01

### 新增

- **luci-app-dnsproxy 完整简体中文汉化**（`patches/luci-app-dnsproxy/0003-add-zh-cn-localization.patch`）：
  源码级直译 6 个 JS 页面共 210 处字符串：
  - `main.js`：服务状态/版本/服务控制（启动/重启/停止/启用/禁用）等；
  - `settings.js`：全部配置选项卡（常规/服务器/缓存/TLS/隐私与安全/性能）与字段说明；
  - `diagnostics.js`、`logread.js`、`help.js`、`file.js`：诊断/日志/帮助/配置文件页。
  实现方式为直接替换 `_()` 字符串（不引入 luci.mk/po2lmo 构建链，零额外依赖，
  CI 仅按既有 patch 流程应用即可自动生效）。

## [v0.2.3] - 2026-09-01

### 修复

- **LuCI「Service Control」全部按钮不可用（实测固件 192.168.3.241）**，两个独立根因：
  1. **init 脚本无执行位**：`files/etc/init.d/dnsproxy` 以 644 写入 rootfs，
     `rc init dnsproxy ...` / 服务启停全部 Permission denied，dnsproxy 服务未运行。
     修复：git 标记该文件 100755 + CI files overlay 步骤统一 `chmod +x`
     （init/uci-defaults/hotplug/rc.local），且不使用 `|| true` 静默忽略。
  2. **LuCI 前端版本探测不兼容 opkg**：上游 `parseVersion` 只读 `/lib/apk/db/installed`
     （apk 格式，OpenWrt 25.x），lede 24.10 用 opkg（无该文件）→ `notInstalled=true` →
     Service Control 全部按钮被禁用（含 Start/Stop/Restart/Enable/Disable）。
     新增 `patches/luci-app-dnsproxy/0002-fix-version-detect-for-opkg.patch`：
     - `main.js`：apk 数据库为空时回退读取 `/usr/lib/opkg/status`，解析
       `Package: dnsproxy` / `Version: 0.83.0-1`；
     - ACL 增加 `/usr/lib/opkg/status` 只读权限（否则 rpcd 返回 403）。
- **`/etc/nftables.d` 目录缺失**：init 写拦截规则文件前 `mkdir -p /etc/nftables.d`
  （部分固件 firewall4 未创建该目录，写入会失败）。

## [v0.2.2] - 2026-09-01

### 修复

- **CI 固件编译失败（gn host 工具）**：helloworld feed 的 `gn`（2026-08-13，Chromium 构建工具）
  是 SSR-Plus 组件 naiveproxy 的 host 构建依赖（`PKG_BUILD_DEPENDS:=gn/host`）。
  gn 新版在 ubuntu-22.04 默认 gcc-12 下编译失败：
  `src/gn/scope.h:241` 的 `values_ | std::views::transform(...)` 报 ranges 约束错误
  （libstdc++-12 的 ranges 适配不完整，gcc-13 已修复），导致 `package_compile` 汇总 Error 2、
  整个固件构建失败（2026-09-01 run 实测 2h18m 后失败于此）。
- 处理方案（不改 helloworld 上游、不关闭 SSR-Plus 任何组件）：
  - CI 新增步骤「Prebuild gn host tool with gcc-13」：安装 `gcc-13/g++-13`
    （ubuntu-toolchain-r/test PPA），先 `make tools/ninja/compile` 备好 ninja，
    再以 `CC=gcc-13 CXX=g++-13` 预编译 `package/feeds/helloworld/gn/host/compile`
    （gn 的 build/gen.py 读取 CC/CXX 环境变量写入 build.ninja），
    预编译成功即生成 `.built` stamp，`make world` 时 OpenWrt 自动跳过 gn。

## [v0.2.1] - 2026-09-01

### 修复

- **CI 构建失败修复**：lede `feeds.conf.default` 自 2026 年起已自带 `helloworld` feed，旧 CI 无条件追加同名 feed，
  导致 `Duplicate feed name 'helloworld'` → `feeds update` 失败（exit 25）→ 构建中止。
  现改为**幂等判重追加**（`grep -q '^src-git helloworld' || echo ... >>`），仅当缺失时追加。
- **fw4 拦截规则可靠性加固**：LAN DNS 拦截关闭时不再删除 `/etc/nftables.d/*.nft` 文件本身，
  而是写入无规则的注释占位文件——fw4 ruleset 对 `/etc/nftables.d/*.nft` 使用 glob include，
  目录为空会导致 fw4 reload 失败；保留占位文件保证 reload 始终成功且无拦截规则。
- **https-dns-proxy 升级残留清理**：由 `uci delete https-dns-proxy`（无法可靠删除整个配置文件）
  改为直接 `rm -f /etc/config/https-dns-proxy`，彻底清除升级残留。
- **行尾安全**：新增 `.gitattributes` 强制 `*.patch / *.sh / *.nft / *.yml / *.json / *.md` 保持 LF，
  防止 Windows checkout 转为 CRLF 破坏 CI 的 `git apply` 与路由器上 shell 脚本执行。

### 变更

- `build-openwrt.yml`：helloworld feed 添加改为判重幂等；其余 ALL_DOH 集成步骤不变（v0.2.0）。

## [v0.2.0] - 2026-09-01

### 新增

- **ALL_DOH 加密 DNS 主链**：集成 `dnsproxy`（AdGuard DNS Proxy，helloworld feed 0.83.0 二进制）+ `luci-app-dnsproxy`，形成
  `LAN → dnsmasq:53 → dnsproxy:5353 → DoH/DoT → Internet` 统一加密解析链路（国内/国外一致，不做分流，无明文 fallback）。
  - `files/etc/config/dnsproxy`：ALL_DOH 默认 UCI 配置（enabled=1、DoH 上游、bootstrap 仅解析上游主机名）。
  - `files/etc/init.d/dnsproxy`：基于 ImmortalWrt 上游 procd 脚本扩展的 init，含 nftables 拦截规则自动管理。
  - `files/etc/capabilities/dnsproxy.json`、`files/etc/sysctl.d/50-dnsproxy.conf`：运行所需 capability 与内核参数。
- **LuCI「拦截所有客户端 DNS」ON/OFF 开关**（`patches/luci-app-dnsproxy/0001-add-lan-dns-intercept.patch`）：
  - 以 patch 形式维护，CI 拉取上游 `adm1n5ky/luci-app-dnsproxy` 后自动应用，不修改上游仓库。
  - UCI 键 `dnsproxy.global.lan_dns_intercept`（与上游 `global` section 结构一致，不冲突）。
  - 默认 ON（uci-defaults 强制 `lan_dns_intercept=1`，固件首次启动即生效）。
  - ON/OFF 即时生效：LuCI 保存后触发 `rc init dnsproxy reload` → 生成/删除
    `/etc/nftables.d/10-dnsproxy-lan-intercept.nft` → `fw4 reload`。
- **LAN DNS 强制拦截（firewall4/nftables 原生）**：
  - 规则写入 `firewall4` 自动 include 的 `/etc/nftables.d/`，IPv4/IPv6 的 UDP/TCP 53 一并重定向至本机 dnsmasq。
  - 绑定 `iifname`（LAN 设备），客户端手动指定 `8.8.8.8`/`1.1.1.1` 无法绕过；不影响 WAN、路由器自身 DNS、现有代理与 dnsproxy 出向流量。
  - 服务未运行（disabled/stop）时自动移除规则，防止将客户端强制到失效链路导致断网。

### 变更

- `dnsmasq` 上游由 `127.0.0.1#5054`（https-dns-proxy）改为 `127.0.0.1#5353`（dnsproxy ALL_DOH）。
- `files/etc/uci-defaults/99-gaming-optimize`：第 4/5/7 节由 https-dns-proxy 改为 dnsproxy ALL_DOH，
  并兼容清理旧版 `https-dns-proxy` 与旧 `all_servers`/`fastest_addr` 残留。

### 移除

- **https-dns-proxy 彻底移除**（含升级残留清理）：
  - CI `CONFIG_PACKAGE_https-dns-proxy`、`CONFIG_PACKAGE_luci-app-https-dns-proxy`、
    `CONFIG_PACKAGE_luci-i18n-https-dns-proxy-zh-cn` 全部删除。
  - uci-defaults 中 https-dns-proxy 配置与 commit 删除。
  - 启动脚本 / LuCI 引用 / 依赖：不再编译该包，固件中不再存在。
- 移除与 helloworld 冲突的旧版 `packages feed dnsproxy (0.56.2)`（CI 构建阶段删除其 feed 链接，仅保留 0.83.0）。

### CI/CD

- `build-openwrt.yml` 新增步骤「Fetch luci-app-dnsproxy upstream and apply local patches (ALL_DOH)」：
  - 每次全新 clone 上游 → `git apply --check` + `git apply` 依次应用 `patches/luci-app-dnsproxy/*.patch`。
  - patch 应用失败即构建失败（禁止 `|| true` / 静默忽略），上游不兼容变更时 CI 明确报错，
    编译日志输出 `git diff --stat` 确认 patch 已生效。
- 编译包配置更新：`dnsproxy`、`luci-app-dnsproxy`、`ca-bundle`、`ca-certificates` 开启；
  https-dns-proxy 三包配置移除。SSR-Plus、Trafficctl、BBR、Fullcone NAT 等其它配置保持不动。