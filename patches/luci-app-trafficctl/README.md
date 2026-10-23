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
| `0006-*.patch` | 移除 Telegram 机器人（页面、后端脚本、UCI 段、日志项全链路删除） |

## 六个 patch 各自为什么存在

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
- `.pot` 模板一并重生成（上游只带了 121 条；当前 pot 实测 376 条、po 502 条。
  ⚠️ 早期本文写「实际需要 425 条」，那是 Telegram 时代的数字，已过时。
  `po` 里另有 124 条 `pot` 没有的孤儿 msgid（`#~` 计数为 0，是活条目，不是 GNU gettext
  的 obsolete 标记），来源是 Telegram 字符串与已删界面文案 —— 它们不影响覆盖率判定。

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
  端口转发顺延为 3）。顶部行为 **设备 | 设置 | 端口转发**
  （本 patch 落地时还有 Telegram tab，v0.7.0 起由 0006 全链路移除，现为三项）。
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

### 0006 — 移除 Telegram 机器人（v0.7.0）

上游 1.21.4 带一整套 Telegram Bot：页面 tab、`trafficctl-telegram.sh`、
`trafficctl-telegram-test.sh`、`/etc/init.d/trafficctl-telegram`、UCI `trafficctl.telegram`
段、`logging.log_telegram` 日志项，以及 ACL 里的对应方法。

本仓库不需要它，且它带来三个实际负担：`+curl` 依赖（仅为发 Telegram 消息）、
一个常驻 init.d 服务、以及一个需要长期维护 token 的攻击面。

本 patch 全链路删除（证据：`0006-remove-telegram.patch` 的 `diff --git` 列表）：

| 删除对象 | 说明 |
|---|---|
| `root/etc/init.d/trafficctl-telegram` | 整个文件删除 |
| `root/usr/local/bin/trafficctl-telegram.sh` | 整个文件删除 |
| `root/usr/local/bin/trafficctl-telegram-test.sh` | 整个文件删除 |
| `root/usr/share/rpcd/acl.d/luci-app-trafficctl.json` | 去掉 Telegram 相关 ubus 方法 |
| `root/usr/local/bin/trafficctl-fw.sh` | 去掉 Telegram 通知钩子 |
| `root/etc/hotplug.d/dhcp/99-trafficctl-newdevice` | 去掉新设备 Telegram 通知 |
| `README.md` | 上游 README 里的 Telegram 章节 |

配套的清理在 `Makefile` 的 `postinst`（`package/luci-app-trafficctl/Makefile:74-90`）：
stop + disable 残留服务、`killall trafficctl-telegram.sh`、删
`/etc/rc.d/*trafficctl-telegram`、删 `/etc/trafficctl/telegram_known.json`、
删 UCI `trafficctl.telegram` 与 `logging.log_telegram`。
**刷机升级时老配置里的这些残留会被这段 postinst 清掉**，不需要手工处理。

⚠️ 两点遗留（不是 bug，但读文档时要知道）：

- `Makefile:38` 的 `LUCI_DEPENDS` 仍含 `+curl`。全包 23 个脚本 + 1 个 CGI
  已无任何 `curl` 调用 —— 它是 Telegram 时代的遗留依赖，删掉是安全的，但属独立改动。
- `po/zh-cn/luci-app-trafficctl.po` 里仍有 124 条 Telegram 时代的 msgid
  （见上文 0003 小节），它们不影响覆盖率判定。

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

---

## 本地改动清单（从 AGENTS.md 红线外移，2026-10-23）

> 本节原在 `AGENTS.md` 红线第 9 条，占 18KB。AGENTS.md 有 65536 字节硬预算，
> 外移到此处。**红线效力不变** —— 改动 `package/luci-app-trafficctl/` 前必读。

### 硬约束：vendored 副本，改它必须同步 patch
   这项包**不靠 patch 构建**（CI 直接 `cp -r` 整个目录），但它的改动必须固化：
   - 改完 `package/` 下的任何文件后，**必须**跑
     `python3 tools/regen-trafficctl-patches.py <上游包目录>` 重算 patch，
     否则 CI 的 `Verify luci-app-trafficctl local invariants` 会因
     「patch 重放结果 ≠ vendored 包」而 `exit 1`。
   - 升级上游用 `sh tools/sync-trafficctl.sh <tag>`（会覆盖包目录并重算 patch）。
   - **六项本地改动必须保留**（被覆盖会静默失效，界面不报错、构建也成功）：
     1. `root/usr/local/bin/trafficctl-bytes-nft.sh` 的重写 —— 上游至今用本内核
        不支持的 `flags dynamic` map + `update @bytes_in`，且只挂 forward 单钩子；
        丢掉它 → **速率列恒为 `—`**。详见红线 7/8 与第 4 节。
     2. `Makefile` 的 `LUCI_DEPENDS` 去掉 `+hostapd-utils` —— 该符号只在选中
        hostapd/wpad 变体时存在，x86_64 无 WiFi → 不可满足 → kconfig 把整包
        连同 `luci-i18n-trafficctl-zh-cn` 一起从 `.config` 丢弃。
        丢掉这个修正 → **界面变英文、i18n 断言失败**（构建不报错，症状隐蔽）。
     3. `status.js`/`status.css`/`menu.d`/`config`/`rpcd` 的刷新与 tab 改动 ——
        丢掉它 → **冷启动不再自动刷新**、或设置区冒出内层 tab。
        页面级 tab 为**设备 | 设置 | 端口转发**
        （v0.7.0 起 Telegram tab 已全链路移除，见红线 9 第 3 条补充）。
        **轮询必须防重入**（`setInterval(tick, …)` + `queryInFlight` + `document.hidden`）：
        一次 `summary` 实测 1.5–1.9 秒，而档位可设 1 秒，退回
        `setInterval(runQuery, …)` 会让请求层层堆积、rpcd 不断 fork 子脚本、
        路由器 load 飙到三位数、页面最终 `XHR request timed out`。
     4. `po/zh-cn/luci-app-trafficctl.po` —— 丢掉它 → **中文界面变英文**。
     5. `host.js` + `trafficctl-device.sh` 的**主机实时连接详情页**（v0.5.0）——
        丢掉它 → 概览「流量排行」与设备表 IP 的链接 404。要留意三点：
        - 详情页路由 `admin/status/trafficctl/host/*` 在 `menu.d` 里**不设 `title`**：
          可直达、可收藏、可后退，但**不进侧边栏**（`ui.menu.getChildren` 会跳过
          无 title 的节点）。给它加回 title 就会多出一个点不开的菜单项。
        - `trafficctl-device.sh` 读的是 conntrack 的**第二个**（回复方向）元组，
          否则源端口与「外网地址」全空、且上下行会变成同一个数。
        - 13 列在 shadcn 主题下必须由 `.tc-host-table` 自己用 grid 定列：
          该主题下 LuCI 的 `.table/.tr/.th` 是 `display:block`，表头会竖着堆成一列
          （既有设备表当前也是这个表现，本次未改动其布局）。
     6. `settings.js` + `common.js` 的**设置独立 tab**（v0.6.0；布局于 v0.6.2 再调整）
        —— 配置项整体从设备页迁到 `admin/status/trafficctl/settings`；两页共用
        `resources/trafficctl/common.js`（rpc 声明、localStorage 选项、
        开关/chip/折叠卡片控件）。丢掉它 → 配置重新挤回设备页，或两页各持一份
        定义而渐渐不一致。易错点：
        - **`common.js` 必须 `return baseclass.extend({…})`**。LuCI 前端 require
          在 `luci.js` 里对工厂返回值做 `Class.isSubclass(_class)` 断言，返回普通对象
          直接抛 `TypeError: "…" factory yields invalid constructor`，整页加载失败。
          require 返回的是实例，故调用方写 `T.fmtBytes(...)` 成立。
        - **软件卸载的橙黄横幅必须保持移除**（`mkOffloadBanner` 对 `software` /
          `software-counter` 直接 `return null`）；但**硬件卸载的告警必须保留**，
          那说的是该模式下 conntrack 字节计数器确实不更新、速率会显示为 0。
        - **每个视图都要自己注入 `status.css`**（`status.js` / `settings.js` /
          `host.js` / `portfw.js`）。LuCI 只自动加载与**视图同名**的样式，而
          htdocs 下没有 `settings.css`。漏注入时页面不报错，
          只是所有 `tc-*` 类失效（卡片无边框、chip 无底色）。
        - **设备页与设置页不得各持一份同名配置档位（v0.6.2 起方向）**：
          `pollIntervalPick` / `avgWindowPick` / `avgMethodPick` / `refreshPick` /
          `defaultsBtn` 必须存在于 **`status.js`**（设备表上方），且**不得**在
          `settings.js` 留副本 —— 两处各一份时同一档位会显示不同默认值。
          （v0.6.0~v0.6.1 曾短暂相反，见 CHANGELOG。）
        - **设备页操作区是三块并进同一张卡片的**：设备选择（`.tc-picker-row`，
          块内 `flex-wrap: nowrap`）、切断（`.tc-cut--embedded`）、
          View & Table（`.tc-rate-panel__tail`）。并块时**必须用占位容器**
          （`actionSlot` / `scopeSlot` / `panelTail`）：被并进来的块往往在文件**下方**
          才构造，直接引用会因 `var` 提升拿到 `undefined` —— 轻则页面出现字面的
          "undefined"，重则 `appendChild` 抛错导致整页空白（两样都踩过）。
          v0.6.9 起 `scopeSlot` 已随「目标/共享/网段」一并删除（picker 行只剩
          「所有设备 | 搜索框」）。
        `tools/verify-trafficctl-invariants.sh` 已对以上各点加断言。
        - **设备表是「两行式」的（v0.6.3）**：`ip`（IP 上 / MAC 下）、
          `_tydev`（类型上 / 厂商下）、`_actions`（详情上 / 限制下）三列各含
          两个子元素。要留意四点（都是实测踩出来的）：
          - 两行靠子元素**块级**成立。`.table.tc-table .td` 是 `table-cell`，
            `.tc-cell-stack` 的 flex 列布局会被覆盖，故子元素若都是 `<a>`
            （inline）会并成一行 —— `.tc-actions a` 必须显式 `display:block`。
          - 表格必须 `table-layout:fixed`。`auto` 布局下 `width` 只是建议：
            数字列被拉成几百像素空槽，同时「操作」列被压到放不下两个链接
            → 整表溢出（实测 153px）。**列宽由 JS 的列预算给**（见下方
            v0.6.6 那条），不要写回 CSS 百分比。
          - **默认隐藏列只能有一处声明**：模块级 `TC_COL_DEFAULT_HIDDEN` +
            `isColHidden()`。列定义里再写 `hide:true` 就是两份真相，必然漂移。
          - 列开关**必须写显式布尔，不能 `delete`**：`delete` 后
            `isColHidden` 回落到默认隐藏，表现为「勾是勾了、表格里却没有这一列」。
        - **设备厂商来自固件内 `luci-app-oui`**（100KB 厂商库，实测能查
          Xiaomi/Midea/Huawei/TCL/TP-Link）。它只导出 `decorate`，**没有公开的
          `lookup`** —— 用一个游离节点让 `decorate` 写 `title` 再读回。
          `oui.js` 未被任何视图加载过时需按需 `<script>` 载入一次；
          取不到厂商保持占位「—」，不可抛错（它是附加信息，不该让表格挂掉）。
          CI 未显式启用该包，靠固件里已存在；换目标平台时先确认它仍在。
        - **分页切片前必须先排序**（`sortSummaryRows`，与表内同一套规则），
          否则第一页不是真正的最快设备。分页只在「所有设备」模式出现。
        - **参照图若来自别的系统**（如爱快），先逐列核对数据源再动手：
          本机无 WiFi 硬件（`iw dev` 返回 0 个接口），故「连接AP / SSID」
          两列没有来源；后端也不产出在线时长（无 `first_seen`）。
        - **四组档位收在 ☰ 菜单里（v0.6.4；类名于 v0.6.6 改为通用 `tc-menu*`）**：
          `tc-menu` + `tc-menu-btn` + `tc-menu-panel`（面板默认 `tc-hidden`）。
          浮层绝对定位，展开时设备表不跳动；点别处 / Esc / 再点按钮收起，
          面板内点击不收起。两个 `document` 监听器**必须具名挂到实例并在
          `handleTeardown` 摘除**，否则切 tab 后仍在收点击、闭包抓着已移除的 DOM。
        - **冷启动轮询默认 1 秒，三处必须一致**（v0.6.4）：前端
          `common.js` 的 `siteDefaults.pollInterval`、UCI
          `root/etc/config/trafficctl` 的 `option poll_interval`、rpcd
          `luci.trafficctl` 的 `${poll:-N}` 兜底。任一不同 → 界面与路由器下发值
          漂移。三处都有断言。
        - **字节轮询必须防重入**（v0.6.4 加固）：`pollBytes` / `pollDrops` /
          `pollShapeStats` 各有 `*InFlight` 闸，且 `.catch` 里也要解锁 ——
          只 `.then` 解锁会在一次请求失败后让轮询永久停摆。1 秒档位下单次 RPC
          最坏实测 1.9s，无闸时 30 秒内重叠 3 次（≥2 并发）。
          实测方法：`performance.getEntriesByType('resource')` 过滤 `/ubus/`，
          比对相邻请求的 `startTime` 与 `startTime+duration` 是否交叠；
          **测量窗口不要跨页面加载**，否则会把首屏那一次正常并发算成重叠。
        - **表格居中限定在 `.tc-table--center` 作用域（v0.6.5）**：三处真正的
          表格（设备表 / 连接表 / 分组表）带该类，**扩展统计面板不带** ——
          它是「标签 — 数值」两栏行，居中就读不成列表。两条易错：
          - 两行式单元格（`.tc-cell-stack`）的子项对齐由容器 `align-items`
            决定，**只设 `.td { text-align }` 管不到**，必须另加
            `align-items: center`，否则 IP/MAC 与类型/厂商两列会左贴。
          - **不要改全局的 `.tc-right` / `.tc-center`**（表格之外也在用），
            一律限定在 `.tc-table--center` 内。
          断言只数 `class':` 开头的真实代码行并要求**恰好 3 处** ——
          直接 grep 类名会把注释行也算进去（实测虚报成 4 处）。
        - **按钮组与弹出面板（v0.6.6）**：`tc-menu-group`（右对齐的按钮组）>
          `tc-menu`（按钮 + 浮层）> `tc-menu-btn` + `tc-menu-panel`。
          两个菜单共用 `mkPopupMenu()` 工厂：顺序固定为**可见列 | ☰**，
          且**同一时刻只允许一个面板展开**（两个浮层贴着同一按钮组，同时开
          会互相盖住）。类名是通用的，**不再叫 `tc-speed-menu*`** —— 改名后
          旧断言会永远失败，同步更新 `tools/verify-trafficctl-invariants.sh`。
        - **视图开关直接展示，不裹折叠卡片（v0.6.6）**：`tc-view-toggles`
          常驻速率限制卡片尾部。v0.6.9 起该行只剩「扩展统计 / 反向DNS」
          （统计 / 连接 / 活动日志三个开关已移除、恒开，见下）。
          开关藏在折叠区里的症状是「内容不见了却不知道开关在哪」。
        - **列表宽按每列最小预算算，不要写回 CSS 百分比（v0.6.6）**：
          `COL_MIN_PX` 给每列一个像素预算，总和即表的 `min-width`，
          各列百分比按「预算/总和」以**内联样式**写到表头。CSS 百分比是
          「占表宽的比例」，列一多就被摊薄 —— 实测 20 列时图表/限制/丢弃/队列
          被压到 **11px**、MAC 折成三行。两处共存必然矛盾（内联赢），
          故 CSS 里那批写死的列宽已删除，并有断言禁止它回来。
        - **统计条与上联概览在同一张卡片里（v0.6.7）**：`overviewCard`
          （`.tc-overview`）内含 `statsDiv`（抬头行）+ `overviewDiv`
          （`.tc-ov-body`，即概览本体）。三条易错：
          - **定义顺序**：`statsDiv` 必须**先**定义，否则 `E(..., [statsDiv, …])`
            因 var 提升拿到 `undefined` → 整页空白（本仓库踩过两次，已加断言）。
          - **两个开关独立**（统计 / 概览），卡片只是外壳：可见性由
            `updateOverviewCard()` 按「至少一个子块**有内容**且未关掉」决定。
            判据必须含 `firstChild` —— 子块首帧是空的，只看 `tc-hidden`
            会画出一个**空边框**。
          - **`statsDiv.className` 是整体赋值**（`'alert-message info'`），会把
            `tc-hidden` 一起丢掉 → 关掉「统计」后下次轮询又显示出来。
            必须先记下隐藏态、赋完再还原（`renderSummary` 与单设备分支各一处）。
        - **上联图按容器实宽重绘，别用 CSS 拉伸（v0.6.7）**：图带 `viewBox`，
          `width:100%` 会把坐标轴与刻度文字一起放大。故按 `graphWidth`
          （容器实宽 − padding − border，用 `getComputedStyle` 读）重绘，
          并监听 `resize`（只在宽度变化 ≥2px 时重画，否则拖窗口会每帧重建表格行）。
          监听器具名挂到实例、在 `handleTeardown` 摘除。
        - **例行轮询不得写状态行（v0.6.7）**：`runAll` / `runSingle` 走
          `setRoutineStatus()` —— 只在**失败**时显示，成功时只清自己的旧错误。
          此前每秒写「扫描中…/✓ 完成」，1 秒档位下一直闪，是噪声不是信息。
          **动作类反馈（限速/切断/WiFi）仍必须走 `setStatus()`** 并逐字保留：
          那些是用户主动触发、必须看到结果的操作；全改成静默会让「切断成功」
          也没有提示。两者分工有断言守住。
        - **按钮组与表格之间要有行距**：`.tc-menu-group` 的 `margin: 8px 0 12px`。
          表格自身没有上边距，只写上边距会让按钮贴住表头（实测间距曾为 0）。
        - **可见列是复选框，且只列「未显示」的列（v0.6.8）**：清单
          （`colChipDefs`）**恰好等于 `TC_COL_DEFAULT_HIDDEN`**，不含默认显示的列 ——
          默认就看得见的列再给个开关，只会让人以为「没勾上就是没有」。
          断言按此校验（相等 + 每个 key 都在 `cols` 里 + 默认列不得混入）。
          `cols` 与清单**不再要求键集相等**（旧断言已改）。
        - **列开关必须写显式布尔，两个方向都写**（v0.6.8 起是
          `self._hiddenCols[ct.key] = !cb.checked`）：`delete` 会让
          `isColHidden` 回落默认隐藏，表现为「勾是勾了、表格里却没有这一列」
          （已用运行时语义复现验证）。
        - **默认显示列（v0.6.8）**：IP/MAC、连接数、四个速率列、类型厂商、名称、
          操作、**TCP、UDP、互联网、限制**（共 13 列）默认可见。后四个是 v0.6.8
          从隐藏提升为显示的，断言会逐个校验它们不在 `TC_COL_DEFAULT_HIDDEN` 里。
        - **概览常显、无开关、在速率限制之上（v0.6.8）**：`showOverview` 选项已作废，
          `pollIfaces` / `renderOverview` / `resize` 三处判据**只看 `isAllMode()`**。
          渲染顺序上 `overviewCard` 必须在 `rateLimitRow` **之前**（读数是先看的、
          操作是后改的）。改这块时注意两处断言坑（都踩过）：
          - `grep '^\t\t…'` 用单引号时 `\t` 是**字面反斜杠 t**，不是制表符 →
            断言永远匹配不到。改用 awk 的 `[ \t]` 字符类。
          - 改写法后要同步相关断言（如 `= false` → `= !cb.checked`），
            否则旧断言永远失败、变成噪声。
        - **三个视图开关已移除、恒开（v0.6.9）**：`showStats` / `showConns` /
          `showActivity` 作废；开关行只剩「扩展统计 / 反向DNS」。
          两个易漏点：
          - **活动日志的内容要首屏主动加载**：原先那一步挂在开关回调里，
            开关移除后没人触发，整段永远空白。
          - 容器不得再带初始 `tc-hidden` 门。
        - **限速入口在设备表行内，不在卡片里（v0.6.9）**：卡片里的速率档位行
          与「目标/共享/网段」已删除。点某行「限制」打开 `tc-limit-popup`，
          目标取自 `_limitIp`（由 `mkLimitPopup`/`openLimitPopup` 设置）。
          **`scopeInput` 已删除**，不要在别处引用。
          - 弹层挂在 `document.body`，必须随 `handleTeardown` 摘 DOM 与两个
            `document` 监听器。
          - **定位要先显示再量 `offsetHeight`**：弹层高度随内容变化（自定义行、
            上行分栏可展开），用固定估值会把它放到视口外（实测 192px 高、
            只剩 40px 空间）。下方放不下且上方更宽裕时翻到行上方。
        - **「已有的网段限制」列表必须保留**（`renderSubnetLimits`）：它是既有
          全局限速**唯一**可见、可删的地方。删掉它，此前设过全网/网段限速的人
          再也去不掉那条规则。
        - **`upRow` 曾经是孤儿节点**：构造后从未挂进 DOM，「上下行分别设置」
          按钮切换的是一个游离节点，点了永远看不到输入框。v0.6.9 已挂进弹层。
          改这块时确保它仍在某个渲染树里。
   新增/修改该包的中文字符串后，跑 `python3 tools/check-trafficctl-i18n.py`
     （缺失会失败；用 `--write-pot` 同步模板）。**新增的视图/共用文件要一并加进
     `tools/check-trafficctl-i18n.py` 的 `JS_FILES`**，否则该页的中文缺译
     不会被校验发现（表现为页面中英混排）。当前已列入 `status.js` / `portfw.js` /
     `host.js` / `settings.js` / `common.js`。

