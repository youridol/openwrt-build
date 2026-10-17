# patches/luci-app-trafficctl

`luci-app-trafficctl` 相对上游 `YusDyr/luci-app-trafficctl` 的**差分记录**。

## 与 `package/luci-app-trafficctl/` 的关系

本仓库把上游整包 vendored 到 `package/luci-app-trafficctl/`，CI **直接使用**
该目录（不联网）。本目录的 patch **不参与固件构建**，它的作用是：

- **记录**我们对上游做了哪些改动（差分可读、可评审）；
- **保证可跟进上游**：CI 会从 `UPSTREAM` 记录的 tag 克隆上游、套用全部 patch，
  并要求结果与 vendored 包**逐字节一致**。上游发新版而 patch 未跟上时 CI 明确失败。

因此：**改功能改 `package/` 下的文件**，改完重跑生成器让 patch 跟上。

| 文件 | 作用 |
|---|---|
| `UPSTREAM` | 基线上游 tag（单行，如 `v1.21.4`） |
| `0001-*.patch` | nftables 字节计数后端重写（功能性修复） |
| `0002-*.patch` | 设置区 tab 化、默认自动刷新、卡片瀑布流布局 |
| `0003-*.patch` | 中文翻译（新增 `po/zh-cn/` + 同步 pot 模板） |
| `0004-*.patch` | 主机实时连接详情页（13 列表格）+ conntrack 回复方向字段 |
| `0005-*.patch` | 设置独立成 tab + 页面共用模块 `common.js` + 设备页去重与重排 |

## 五个 patch 各自为什么存在

### 0001 — 重写 nft 字节计数后端（**不改就功能失效**）

上游至今使用本内核**不支持**的语法：

```sh
nft add map inet trafficctl_mon bytes_in '{ type ipv4_addr : counter; flags dynamic; }'
nft add rule inet trafficctl_mon mon_forward 'update @bytes_in { ip daddr counter }'
```

实测内核 6.18.55 / nftables 1.1.6 对两者均返回
`Error: Could not process rule: Not supported`。错误被 `2>/dev/null` 吞掉，
于是集合从不建立、规则添加全失败、脚本永远返回 `[]` —— **速率列恒为 `—`**，
且界面不报错、构建也成功，属静默功能失效。

上游 1.21.4 的改进只有两处：加了「规则方向」守卫与失败时
`TCTL_FORCE_CONNTRACK=1` 回退到 conntrack。回退虽比返回 `[]` 好，
但 **conntrack 看不到被 REDIRECT 到本机的代理流量**，速率仍不准。

本 patch 改为本内核可用的写法，并同时修掉三个独立缺陷：

1. **语法**：`set { type ipv4_addr; size 65535; flags dynamic; }` +
   `add @set { ip saddr counter }`（实测受支持）。
2. **钩子**：上游只挂 `forward`。SSR-Plus 用 REDIRECT 把客户端连接引到本机
   v2ray(:1234)，目的地址被改写为本机，数据包因此走 **INPUT/OUTPUT 而非 forward**。
   实测对照组（客户端下载 150 MB）：

   | 钩子 | 方向 | 计数 |
   |---|---|---|
   | forward | saddr=客户端 | 5932 B（几乎为零） |
   | output | daddr=客户端 | 157548502 B（完整） |
   | input | saddr=客户端 | 1360391 B（客户端小请求） |

   故三钩子并用（三者对同一包互斥，不会重复计数）。
3. **`@lan` 限定**：`output` 钩子会看到路由器自身对 WAN 的连接，只用
   `oifname br-lan` 限定仍会写入 `1.2.4.8`、`10.x` 等地址，把集合污染成
   满额并让前端出现无关行。`@lan` 由 `tctl_lan_subnets` 动态生成，支持多网桥。

另保留 AGENTS.md 红线 8 要求的**单事务原子重建**（`delete table` 与重建写在同一
个 `nft -f` 文件、提交前先 `nft -c -f` 校验），避免前端轮询与手工调用并发时
各建一套规则导致速率翻倍（实证：180 MB 下载被记成 380 MB）。

JSON 契约与上游保持一致（`ip` / `bytes_in` / `bytes_out` / `bytes_tcp` /
`bytes_udp` / `src` / `degraded`），因为 `trafficctl-totals.sh` 会消费
`bytes_tcp`（`-1` 表示无法按协议拆分）、`src`（识别计数源切换以重基线）与
`degraded`（信任标记）。

### 0002 — 设置区 tab 化 + 默认自动刷新 + 卡片瀑布流

- **tab 化**：上游把整个设置区放在可折叠容器里且**初始隐藏**，用户必须点标题
  才能看到设置项；Telegram Bot 表单极长（实测单卡片 1270px），与其它设置混在
  一起会把整页撑到 2600px 以上。改为常显标题栏 + 三个 tab
  （`Display & Table`／`Devices`／`Telegram Bot`），tab 选择持久化到 localStorage。
- **默认自动刷新**：上游 `_setupTimer` 直接读 `loadOpts().refresh || 0`，即
  **默认「关」** —— 冷启动打开页面后设备表完全不自动刷新，观感就是「表格不自动
  刷新」。改为经 `optRefresh()` 取默认 5 秒，并保留管理员经 UCI
  `trafficctl.main.refresh_interval` 下发的机制；用户显式选「关」仍被尊重。
- **1s / 2s 档位**：上游刷新最短 5s。新增 1s、2s（最低 1 秒）。
- **卡片瀑布流**：`.tc-settings-pane { column-count: 2 }`，卡片高度差异大时
  由浏览器自动均衡分列。
- **补齐缺失样式**：上游**完全没有** `.tc-chips-wrap` 的样式，导致「可见列」
  一长串 chips 不换行、右侧被卡片 `overflow:hidden` 裁掉。
- **`refreshSpeedViews()`**：改「窗口」或「方法」后立即重算重绘，不再等下一个
  轮询周期（上游观感是「改了没反应」）。
- **`refresh_interval` 端到端接线**：新增 UCI 项 `trafficctl.main.refresh_interval`
  （默认 `5`），rpcd 的 `config_get`/`config_set` 读写它并做边界校验
  （`0` = 关闭，或 `1`–`3600` 秒），前端 `callConfigSet` 的 `params` 同步加一位，
  使「Save as router default」也能把刷新间隔写为路由端默认值。
  该 patch 因此涉及 4 个文件（2 个前端 + `config` + `rpcd`）。

### 0003 — 中文翻译

上游 `po/` 下只有 `templates/`，**没有** `zh-cn`。本 patch 新增完整中文翻译。

- 上游机制要求目录名 `zh_Hans`，但 `luci.mk` 会把目录名 `zh-cn` 映射为
  `zh_Hans`，故 `po/zh-cn/` 可被正确识别（CI 已实测
  `CONFIG_PACKAGE_luci-i18n-trafficctl-zh-cn=y` 通过）。
- 覆盖情况由 `tools/check-trafficctl-i18n.py` 校验；CI 会在译文缺失时失败。
- `.pot` 模板一并重生成（上游只带了 121 条，实际需要 425 条）。

### 0004 — 主机实时连接详情页

新增 `htdocs/.../view/trafficctl/host.js`（新页面）与 `menu.d` 的
`admin/status/trafficctl/host/*` 路由，并让 `status.js` 的「流量排行」与设备表
IP/主机名指向它。后端 `trafficctl-device.sh` 补出 conntrack **回复方向**元组的字段。

三个容易在同步上游时被抹掉、且抹掉后**不报错**的要点：

1. **路由不设 `title`**：`ui.menu.getChildren` 会跳过无 title 的节点，因此该页
   可直达/可收藏/可后退，但**不进侧边栏**。加回 title 就多出一个菜单项。
2. **回复方向元组**：一行 conntrack 有两个元组，`sport`/`wan`（外网地址）与
   分开的 `bytes_up`/`bytes_down` 都来自第二个。只读第一个 →
   源端口与外网地址全空、上下行变成同一个数。
3. **13 列用 grid 定列**：shadcn 主题下 LuCI 的 `.table/.tr/.th` 是 `display:block`，
   表头会竖着堆成一列。样式限定在 `.tc-host-table` 内，不改动既有页面。

「外网地址」在两种情况下**留空而不是硬填**：`proxy=true`（出口地址由代理节点决定）、
以及 `wan == 客户端自身 IP`（访问路由器本身不经 NAT）。填上都会被读成
「一个恰好是私网/本机的公网地址」。

「应用」列需要 netifyd DPI（本固件未装），无数据时显示 `—` 并以 tooltip 说明原因。

### 0005 — 设置独立成 tab + 页面共用模块 + 设备页去重

上游把**配置项**（轮询/窗口/平均算法、路由端默认值、流量卸载、新设备默认值、
日志与持久化）与**监控数据**放在同一页，实测该配置区块高 580px，把设备表压到
折叠线以下。本 patch 按职责拆开：

- 新增 `htdocs/.../view/trafficctl/settings.js`，成为页面级 tab「设置」
  （`menu.d` 登记 `admin/status/trafficctl/settings`，顺序 2；
  Telegram 与端口转发顺延为 3、4）。顶部行为
  **设备 | 设置 | Telegram机器人 | 端口转发**。
- 新增 `htdocs/luci-static/resources/trafficctl/common.js`：rpc 声明、
  localStorage 选项（`loadOpts`/`optRefresh` 等）、格式化函数、
  开关/chip/折叠卡片控件。此前这些定义在 `status.js` 里、被 `telegram.js`
  复制一份，再加设置页就是第三份，三份各自漂移。
- 设备页只保留「视图与表格」（本页显示开关 + 列可见性），并移到页面最后；
  整页高度由 **2915px 降到 1541px**（实测）。
- 移除软件流量卸载的橙黄色公告横幅。软件卸载不损失任何功能，却每次开页都公告
  一遍；模式本身在设置页「流量卸载」卡片里有常驻的 `Current mode` 显示。
  **硬件卸载的告警保留** —— 该模式下 conntrack 字节计数器确实不更新。
- `rpcd` 的 `config_set` 签名补上 `refresh_interval`（此前只有读写代码、
  没有声明；ubus 实测仍放行，但参数不受类型校验，且与 `config_get` 输出不对称）。

四个容易在同步上游时被抹掉、且抹掉后**不报错**的要点：

1. **`common.js` 必须 `return baseclass.extend({…})`**：LuCI 前端 require 在
   `luci.js` 里对工厂返回值做 `Class.isSubclass(_class)` 断言，普通对象会抛
   `TypeError: "…" factory yields invalid constructor` 并令整页加载失败。
2. **软件卸载横幅必须保持移除**（`mkOffloadBanner` 对 `software` /
   `software-counter` 直接 `return null`），但硬件卸载告警必须保留。
3. **设备页不得再定义** `refreshPick` / `pollIntervalPick` / `avgWindowPick` /
   `avgMethodPick` / `defaultsSaveBtn`，否则与设置页形成两份副本。
4. **`connFiltersRow` 的定义必须先于引用**：它是「连接表筛选」（协议/分组），
   迁配置区时极易被一并删掉，而 `viewSection` 与 `updateTableSectionMode`
   仍引用它 → `ReferenceError` 令设备页整页空白。

## 维护流程

**改了 `package/` 下的文件之后：**

```sh
# 上游 clone 到本地（或用 tools/sync-trafficctl.sh 让它自己拉）
python3 tools/regen-trafficctl-patches.py /path/to/upstream-repo
```

**要升级到新的上游版本：**

```sh
sh tools/sync-trafficctl.sh v1.21.5   # 覆盖包目录 + 重算 patch
```

该脚本会覆盖 `package/luci-app-trafficctl/`（保留 `LICENSE`、`README.md`、
`po/zh-cn/`），然后用当前工作树重算 patch，并在干净基线上回放校验。
**升级后必须逐项确认本文件列出的本地改动是否仍在**（当前共六项，其中第 6 项
另含 `settings.js` + `common.js`）—— 被覆盖掉的功能
不会报错，只会静默失效；CI 的
`Verify luci-app-trafficctl local invariants` 步骤会兜住大部分情况。

## 规范

沿用 `patches/luci-app-dnsproxy/README.md` 的约定：

- 单一职责，一个 patch 只做一件事；
- 递增编号，顺序即套用顺序；
- 最小修改；
- 幂等 —— 生成器每次都从干净上游基线重算，因此天然幂等；
- **禁止** `|| true` 之类的静默忽略。
