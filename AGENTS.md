# AGENTS.md — openwrt-build 项目须知

> 本文件面向在此仓库工作的 AI 编码代理。目标：让你在不破坏既有约定的前提下安全改动。
> 人类贡献者同样适用。**动手前请通读「红线」与「变更流程」两节。**

- 仓库：`youridol/openwrt-build`（默认分支 `master`）
- 用途：通过 GitHub Actions 编译**定制 x86_64 OpenWrt 固件**，并在推 tag 时自动发版
- 文档语言：中文（术语保留英文）。新增注释/日志/CHANGELOG 请沿用中文。
- 工作目录内的报告与脚本：见「附：本机排查工具」

---

## 1. 仓库地图

| 路径 | 角色 | 能否改上游 |
|---|---|---|
| `.github/workflows/build-openwrt.yml` | 主编译流水线（拉 lede → 装包 → 编译 → 传产物） | 本项目自有 |
| `.github/workflows/release.yml` | 推 `v*` tag 时建 Release，notes 自动取自 `CHANGELOG.md` | 本项目自有 |
| `package/luci-app-trafficctl/` | **本地包**（源自 `YusDyr/luci-app-trafficctl` **v1.21.4**），整包 vendored 进仓库；改动以 `patches/luci-app-trafficctl/*.patch` 记录 | 直接改本仓库副本，改完跑 `tools/regen-trafficctl-patches.py` |
| `patches/luci-app-trafficctl/*.patch` | trafficctl 相对上游的差分记录（**不参与构建**，供跟进上游 + CI 一致性校验） | 由 `tools/regen-trafficctl-patches.py` 生成，勿手改 |
| `tools/sync-trafficctl.sh` | 升级 trafficctl 到指定上游 tag（覆盖包目录 + 重算 patch + 回放校验） | 直接用 |
| `tools/check-trafficctl-i18n.py` | 校验中文翻译覆盖率；`--write-pot` 重生成 pot 模板 | 直接用 |
| `tools/verify-dnschain-domains.sh` | 域名归属与自动改道的 121 条契约断言（CI 与本地同一份） | 直接用 |
| `tools/check-dnschain-lua.py` | 用 lupa（真实 Lua）跑语法 + 模型 + **真实渲染页面每个 `cfgvalue()`** | 直接用 |
| `tools/render-dnschain-diagrams.py` | 两张思维导图的纯几何校验 + 输出可打开的 HTML 预览 | 直接用 |
| `tools/extract-dnschain-i18n.py` | 提取 `translate()` 中文并比对 PO（`--write` 追加缺失） | 直接用 |
| `patches/luci-app-dnsproxy/*.patch` | 上游 `adm1n5ky/luci-app-dnsproxy` 的**改动以 patch 形式**维护 | **禁止**改上游；只改 patch |
| `files/` | rootfs overlay（`files/etc/...` 合并进固件），**不是**上游源码 | 直接改 |
| `CHANGELOG.md` | 变更的唯一权威记录；版本判型 PATCH/MINOR/MAJOR | 每次功能改动必须追加 |
| `.gitattributes` | 强制关键文件 LF 行尾 —— **极其重要，见红线 1** | 按需扩规则 |
| `patches/luci-app-dnsproxy/README.md` | patch 维护规范（单一职责/最小修改/幂等） | — |

固件产物：`lede/bin/targets/x86/64/*.img.gz`，artifact 名 `openwrt-x86-64-ssrplus`。

---

## 2. 红线（不得违反）

1. **行尾必须是 LF。** `.gitattributes` 已强制 `*.patch/*.sh/*.conf/*.json/*.yml/*.nft/*.md` 及若干无扩展名文件。
   - CRLF 会导致 CI 里 `git apply` 失败、路由器上 shell 解析失败。
   - 给 `files/` 下**无扩展名**文件加规则时，模式必须匹配**仓库内真实路径**（带 `files/` 前缀），
     用 `**/etc/config/xxx` 而非 `/etc/config/xxx` —— 后者永不匹配（v0.3.5 修过这个坑）。
   - 新增无扩展名脚本/配置时，记得同步 `.gitattributes`。

2. **禁止修改上游仓库。** dnsproxy 的所有改动只以 patch 落地：
   上游 clone → `git apply --check` → `git apply`。CI 每次全新克隆，因此**天然幂等**。
   上游变更导致 patch 失败时，**必须让 CI 明确失败**——**严禁** `|| true` 或任何静默忽略。

3. **禁止静默失败。** 工作流中多处刻意 `exit 1`（缺 patch、Release 缺失、CHANGELOG 无对应版本）。
   不要为了「让 CI 变绿」而加容错兜底。

4. **执行位不可丢。** `files/etc/init.d/*`、`files/etc/uci-defaults/*`、`files/etc/hotplug.d/**`、
   `files/etc/rc.local` 均需 `+x`，CI 有显式 `chmod +x` 清单（`.github/workflows/build-openwrt.yml`）。
   新增此类文件后，请一并更新该清单。
   （`package/luci-app-trafficctl/` 的脚本不在此清单内，它们靠 git 索引里的 100755 位生效；
   CI 并未对它们 chmod。）

5. **不要提交本机凭据。** `.gitignore` 已排除 `rsh.py` 等**本机排查工具**（内含路由器明文口令）、
   一次性排障报告、编译产物与密钥。**新增此类文件时请同步补充 `.gitignore` 规则**；
   提交前仍须逐项确认 `git status`（`.gitignore` 是安全网，不是免检牌）。

6. **CHANGELOG 是发版依据。** `release.yml` 用 `grep -nF "## [$VER]"` 定位版本段；
   找不到即**中止发版**。改功能却不写 CHANGELOG → tag 发版会失败。

7. **`/etc/nftables.d/*.nft` 里禁止出现 `table` 声明 —— 只能写裸 chain。**
   fw4 的 ruleset 模板 `/usr/share/firewall4/templates/ruleset.uc` 第 15 行
   `table inet fw4 {` 开表，第 104 行 `include "/etc/nftables.d/*.nft"` ——
   **include 在该 table 内部**。写入 `table inet xxx { ... }` 会形成嵌套 table，
   nft 报 `syntax error, unexpected table`；而 fw4 的加载路径是
   `print | nft -c -f $STDIN || die "..."`，**校验失败即整个 ruleset 不加载**，
   input/forward/dstnat/srcnat、DNS 拦截、透明代理全部规则消失 → **断网**。

   v0.4.4 正是栽在这里（MSS clamp 片段写成完整 table，导致国内域名大面积
   无法解析）。该错误**无法被任何 YAML/shell 语法检查发现**。CI 已有守卫
   步骤 `Verify no nested-table nft fragments` 会显式断言并 `exit 1`。
   写片段前先对照既有的正确样例 `files/etc/init.d/dnsproxy`（裸 chain）。

8. **`/etc/nftables.d` 片段的建立必须用单事务 `nft -f`（原子）。**
   若用「先 `nft list set` 检查、再逐条 `nft add`」的写法，
   前端轮询（默认 2s）与手工调用并发时会**同时通过检查各建一套规则**，
   导致规则重复 → 同一数据包被累加两次 → 速率翻倍
   （实证：trafficctl 里 180 MB 下载被记成 380 MB）。
   正确做法是把 `delete table` + 重建写在**同一个 `nft -f` 文件**里，
   并在提交前先 `nft -c -f` 只校验。

9. **`package/luci-app-trafficctl/` 是 vendored 副本，改它必须同步 patch。**
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

---

## 3. 构建链路关键点（改 CI 前必读）

- 底座：`coolsnowwolf/lede` @ master；目标 `x86_64` / `DEVICE_generic`。
- **`JOBS=2`**：GHA runner 仅 7GB 内存，Go 编译 Xray 会 OOM，勿调高。
- **helloworld feed 需判重后再追加**：lede 自 2026 起自带该 feed，
  直接追加 → `Duplicate feed name 'helloworld'` → `feeds update` 失败（exit 25）→ 构建中止。
  现有写法 `grep -q ... || echo ...` 是幂等且必需的。
- **dnsproxy 版本冲突**：packages feed 为旧版 0.56.2，helloworld 为新版 **0.83.0**，
  包名冲突会导致构建二义性。CI 显式删除 `package/feeds/packages/dnsproxy` 并重建
  `package/feeds/helloworld/dnsproxy` 软链。**二进制取自 helloworld，init/config 取自 `files/` overlay。**
- **gn host 工具需 gcc-13 预编译**：naiveproxy 依赖 gn，gn 新版在 ubuntu-22.04 默认 gcc-12 上
  编译失败（libstdc++-12 ranges 不全），CI 装 gcc-13 并预生成 `.built` stamp。
- patch 应用时必须**先转绝对路径**：在 `(cd package/... )` 子 shell 内相对路径会失效。
- 启用的关键 CONFIG：`luci-app-ssr-plus`（含 Iptables 透明代理、Xray、ChinaDNS-NG、MosDNS 等）、
  `luci-app-trafficctl` + `luci-i18n-...-zh-cn`、`dnsproxy` + `luci-app-dnsproxy` + CA 证书、
  `kmod-tcp-bbr`、`iptables-mod-fullconenat`。
- **trafficctl 1.21.4 的额外依赖**：`iw`（读 WiFi 频段/信号）、`conntrack`
  （未卸载模式下的每设备字节统计）—— 这两个 CI 显式 `=y` 并断言。
  **`+hostapd-utils` 已从 Makefile 的 `LUCI_DEPENDS` 中移除**（本仓库补丁，见下）。
  上游 1.21.4 把它写成依赖，但它在 lede 里声明为
  `DEPENDS:=@<某个 hostapd/wpad 变体>` + `VARIANT:=*` —— **只有选中 hostapd/wpad
  变体时该符号才存在**。x86_64 无 WiFi 硬件 → 永远不可满足 → kconfig 把
  `luci-app-trafficctl` **整包**判为不可选，连带 `luci-i18n-trafficctl-zh-cn`
  （`DEPENDS:=$(PKG_NAME)`）一起从 `.config` 消失。
  **症状极其隐蔽**：构建不报错、界面变英文，只有 i18n 断言会挂
  （v0.4.7/v0.4.8 两次构建均由此失败）。已加 CI 反向断言禁止它被加回去；
  `tools/verify-trafficctl-invariants.sh` 也会检查。

---

## 4. 固件运行时架构（DNS / 代理）

> ⚠️ **本节下面那张图是「框架未接管时」的历史现状（v0.8.x 之前）。**
> **v0.10.0 起固件默认走 `dnschain` 框架，实际链路是：**
>
> ```
> LAN 客户端 → dnsmasq:53（唯一缓存 + 唯一分流层）
>   ├─ 默认              → 127.0.0.1#5353  dnsproxy 实例 1（阿里 DoT/DoH，直连）
>   ├─ server=/国外域名/ → 127.0.0.1#5336  dnsproxy 实例 2（Google DoH，经 :1234）
>   └─ nftset=/国外域名/4#inet#ss_spec#blacklist   解析结果写入代理 IP 集
> ```
>
> 详见 §4.0 与 [`docs/adr/0005-remove-chinadns-ng.md`](docs/adr/0005-remove-chinadns-ng.md)。
> 下面这张旧图保留用于理解「为什么历史上有 mosdns / :5335 这些遗留物」。

```
LAN 客户端
  └─ dnsmasq:53                     (noresolv=1, server=127.0.0.1#5353, dns-forward-max=1024)
       ├─ 默认 → dnsproxy:5353      (ALL_DOH 加密主链, upstream_mode=parallel)
       │     └─ 国内 DoH 三上游：阿里 / 1.12.12.12 / 360
       │        （v0.8.0 起 dnsproxy **不再**持有任何指向 :5335 的上游）
       └─ gfw_list.conf(23701 条) + black.list → 127.0.0.1#5335
             └─ mosdns:5335         (SSR-Plus 管理, pdnsd_enable=4)
                   └─ 国外 DoH（dns.google / cloudflare）经代理出站
```

**分流是分裂的**：只有 `gfw_list.conf` 与 `black.list` 里的域名走 mosdns，
其余境外域名走 dnsproxy 的国内 DoH（**这些会拿到被污染的答案**）。
这一点是理解 §5 的前提。

> **目标架构见 [`docs/adr/0003-dns-chain-framework.md`](docs/adr/0003-dns-chain-framework.md)。**
> **刷机后的逐项验证见 [`docs/adr/0004-dns-chain-verification.md`](docs/adr/0004-dns-chain-verification.md)。**
>
> 该 ADR 定义了取代上述现状的 DNS 链路框架（dnsproxy 唯一路由入口 + 框架自持
> chinadns-ng 策略过滤器 + 单一缓存层）。
>
> **落地状态（2026-10-20）：P1–P4 全部完成，代码已进仓库。**
> 已落地：
> - 运行时：`files/etc/config/dnschain`、`files/usr/share/dnschain/dnschain.sh`、
>   `files/etc/init.d/dnschain`、`files/usr/bin/dnschain-reconcile`、
>   `files/usr/bin/dnschain-selftest`、`files/etc/uci-defaults/99-zz-dnschain`
> - P3：`files/etc/config/dnsproxy` 已关闭缓存、删除 fallback
> - P4：`init.d/dnsproxy` 让位逻辑、`files/etc/ssrplus/applechina.conf` overlay、
>   853 拒绝的 `-151` 优先级（路由器实测通过）
> - 页面：`package/luci-app-dnschain/`
>
> **但「代码在仓库」≠「现网已切换」**：需刷机后按 ADR-0004 逐项验证。
> 判断现网是否已切换，看三样：
> ```sh
> netstat -lnup | grep -E ':(5335|5353)'        # :5335 应属 chinadns-ng
> uci -q get shadowsocksr.@global[0].pdnsd_enable   # 0 = 交给框架；4 = MosDNS
> /usr/bin/dnschain-selftest                     # 20 项
> ```
>
> 该 ADR 取代了两份已撤回的文档（`0003-dns-chain-architecture.md`、
> `0004-dns-chain-framework.md`），撤回原因见其 §15。撤回的核心教训：
> 那两份都写「已实测」，但仓库里没有对应代码（`--upstream <path>` 的生成器
> 从未存在），且是孤岛文档（除彼此外全仓库零引用）——**引用 ADR 前先确认
> 其结论在代码里有支撑**。

### 4.0 ⚠️ `dnschain` 框架的硬约束（改它之前必读）

> **v0.10.0 已移除 `chinadns-ng`**，改为「双 dnsproxy 实例 + dnsmasq 分流」。
> 架构与推翻原因见 [`docs/adr/0005-remove-chinadns-ng.md`](docs/adr/0005-remove-chinadns-ng.md)。
> 下表已按新架构更新；标 ~~删除线~~ 的是 v0.9.x 的旧约束，**已作废**。

```
dnsmasq:53（唯一缓存 + 唯一分流层）
  ├─ 默认              → 127.0.0.1#5353  dnsproxy 实例 1（阿里 DoT/DoH，直连）
  ├─ server=/国外域名/ → 127.0.0.1#5336  dnsproxy 实例 2（Google DoH，经 :1234）
  └─ nftset=/国外域名/4#inet#ss_spec#blacklist   解析结果写入代理 IP 集
```

| # | 约束 | 违反的后果 | CI 断言 |
|---|---|---|---|
| 1 | **缓存只在 dnsmasq 一层**，`dnsproxy.args` / `dnsproxy-foreign.args` / `files/etc/config/dnsproxy` 都不得启用缓存 | 同一域名出现两份答案（实测：经 `:53` 与直连 `:5353` 返回不同 IP） | 有 |
| 2 | **国外上游必须是 DoH（443），不能是 DoT（853）** | 落地节点到 853 全部 `peer sent close notify` → 国外域名全无结果 | 有 |
| 3 | **分流必须由 `dnsmasq` 的 `server=/域名/` 承担，不能用 dnsproxy 的 `[/域名/]`** | 17767 条 `[/域名/]` 会让 dnsproxy 为每域名注册一条 reserved 上游，资源耗尽 → `connection timed out` | 有 |
| 4 | **不得过滤 `xn--`** | dnsmasq 原生支持 punycode；过滤后 58 条 IDNA 域名失去分流，全部解析失败 | 有 |
| 5 | **不配 `--fallback`、不用 `--ipv6-disabled`** | 前者回落污染上游并缓存；后者连国内 AAAA 一起砍 | 有 |
| 6 | ~~`-N tag:gfw` 不能写成裸 `-N`~~ | **作废**（chinadns-ng 已移除） | — |
| 7 | **不得出现 `114.114.114.114`** | 明文上游绕过加密链路 | 有 |
| 8 | **`init.d/dnsproxy` 必须保留 `dnschain_takes_over` 让位逻辑** | 两个 procd 实例抢 `:5353`，后起的静默失败 | 有 |
| 9 | **`applechina.conf` 必须保持 173 条且全部指向 `127.0.0.1#5353`** | 明文 `114.114.114.114` 绕过 dnsproxy，Apple 域名不走加密链路 | 有 |
| 10 | **两个实例端口不能相同**（`entry_port` ≠ `foreign_port`） | 后起的实例静默失败 | 有（init 的 preflight） |
| 11 | **SSR-Plus 的 `ipv6_support` 必须为 1** | 国外域名拿到真实 AAAA 却直连 → 被 RST | 有（reconcile + selftest 第 7 项） |
| 12 | **`dnsmasq.filter_aaaa` 必须为 0** | 连国内 AAAA 一起砍（v0.10.0 起国外 AAAA 保留） | 有（selftest 第 7 项） |

另有两条通用约束：**`dnschain` 不删、不重写 SSR-Plus 生成的任何文件**
（`gfw_list.conf` 里的 `server=/域名/#5335` 保留原样；框架自己生成
`dnschain-split.conf` 指向 `:5336`。实测 dnsmasq 对同一域名的多条 `server=`
会全部作为候选，`:5335` 无监听时自动重试其它候选）；
**所有脚本必须 POSIX sh（dash）兼容**（CI 用 `sh -n` + 禁 bash 语法双检）。

### 4.0.1 ⚠️ 域名归属与自动改道的硬约束（v0.13.0）

> 设计依据：[`docs/adr/0006-domain-routing-and-reroute.md`](docs/adr/0006-domain-routing-and-reroute.md)。
> 落地校验：`sh tools/verify-dnschain-domains.sh`（121 条断言，CI 会跑）。

先记住三个概念，混了就必然改错：

| 概念 | 谁决定 | 存哪 |
|---|---|---|
| **归属**（class） | 配置 + 名单（静态） | UCI + `/var/etc/dnschain/db-domains.txt` |
| **首选**（preferred） | 归属的确定性映射 | 计算得出 |
| **当前**（active） | 健康探测（动态） | `/var/run/dnschain/health.state` |

| # | 约束 | 违反的后果 | 断言 |
|---|---|---|---|
| 13 | **自定义列表优先于 gfw 名单**（`custom-*` 先于 `db-foreign` 判定） | 用户写了「走直连」却不生效，且无从解释 | 有 |
| 14 | **未覆盖域名的首选链必须是 `domestic`** | 与 dnsmasq 默认上游不一致 →「不配置」与「配置了」行为不同 | 有 |
| 15 | **同一个域名只能有一处 `server=` 声明**：观测域名必须从静态片段里排除 | dnsmasq 把两条当**候选**（不是覆盖）→ 改道退化成随机走一条，两条链都通时完全看不出来 | 有（selftest 第 18 项） |
| 16 | **改道只走 `--servers-file` + SIGHUP，绝不 restart dnsmasq** | 改道可能每分钟发生，restart 每次约 3 秒解析中断 | 有（改道循环内禁 restart） |
| 17 | **`dhcp.@dnsmasq[0].serversfile` 必须下发且进程真带 `--servers-file`** | 只写文件不生效：页面显示「已改道」，实际没生效 | 有（selftest 第 19 项 + 页面「改道通道」） |
| 18 | **超时状态必须走 stdout，不能靠函数内变量** | `out=$(f)` 在子 shell 里跑，父 shell 读不到变量 → 超时被静默当成「返回空」 | 有 |
| 19 | **超时必须用完成标记文件，不能只用 `kill -0` 判活** | 子进程退出成僵尸，`kill -0` 仍成功 → 白等满整个超时 | 有（dash 单测含超时用例） |
| 20 | **`nftset` 目标集必须先 `nft list set` 探测再写** | SSR-Plus 未启用时 `ss_spec` 表不存在，dnsmasq 每解析一个域名都写集合失败、日志刷错 | 有 |
| 21 | **页面不得嵌套 `<form>`**（CBI 已把整页包在 `<form method="post">` 里） | 浏览器丢掉内层标签 →「解释」按钮实际提交外层表单（= 触发保存） | 有 |
| 22 | **同一页每个 SVG 的 marker id 前缀必须唯一**。判定链路图由**同一函数渲染两次**（概览 tab + 域名 tab），必须由调用方传不同的 `id_prefix`（`dcrt-ov` / `dcrt-dm`），状态图默认 `dcst` | CBI 的 tab 是 CSS 隐藏、**不是懒加载**，两个 tab 都进同一份 HTML。id 是文档级全局的，同名则 `url(#dcrt-a-ok)` 全部解析到第一个定义 —— 实测修复前有 5 组重复 id，配色一变就静默串掉，浏览器不报错 | 有（契约 4 条 + 图示 3 条） |
| 23 | **图示动态文本必须 HTML 转义** | 域名或原因含 `& < >` 时整张图解析失败（页面一片空白） | 有 |
| 24 | **`[[:space:]]` 不是 `[[ ]]`**：CI 的 bash 语法断言必须写成「`[[` 后紧跟空白」 | 直接 `grep '\[\['` 会命中 POSIX 字符类 → CI 永远红（v0.13.0 实测踩过） | 有 |
| 25 | **UCI section 名在文件内必须全局唯一**（与类型无关） | `config domains 'foreign'` 与 `config upstream 'foreign'` 同名 → uci 报 `section of different type overwrites`，**整个配置文件读不出来**，页面空白 + 服务起不来 | 有 |
| 26 | **`servers-file` 必须放在 ujail 已挂载目录**（`/var/run/dnsmasq/`），且文件 `0644` | dnsmasq 降权到 uid 453 运行，白名单外的路径**既不报错也不生效** → SIGHUP 成功、日志干净，改道却完全没发生 | 有（selftest 第 19 项） |
| 27 | **`dc_dnsmasq_pid` 必须选「持有 :53 socket」的进程**，不能取 `pidof` 第一个 | `pidof dnsmasq` 返回 3 个 PID，第一个是辅助子进程（`wchan=anon_pipe_read`、5 个 fd），对它 SIGHUP 是空操作 | 有 |
| 28 | **排除文件为空时不得直接 `grep -Fvxf`** | BusyBox `grep -Fvxf <空文件>` 返回 rc=1 且**输出零行** → 把输入全吞掉 → 分流片段变 0 字节 → preflight 拒绝启动 | 有（`dc_exclude`） |
| 29 | **归属判定必须做后缀匹配**（与 `server=/域名/` 语义一致）；自定义列表保持精确匹配 | 名单只写 `google.com` 时 `www.google.com` 被判 `uncovered` → 首选 domestic → 改道拉去直连 → **拿到污染答案**（实测 `31.13.92.37`，是 Facebook 的 IP） | 有 |
| 30 | **探测函数必须支持显式端口**，不能只认链路名 | 传 `127.0.0.1#59999` 会落到兜底分支探 `:5353`（活的）→ 死端口判为 `OK` → 「链路挂了却不改道」 | 有 |
| 31 | **改道等待期间不得更新 `last`**（用 `dc_health_write_keep_last`） | 每轮刷 `last=now` → `now-last` 恒为 0 → `min_dwell` 永不满足 → **回切被永久阻塞**（实测 ok 计数涨到 12、阈值 3，状态一直 `recover-wait`） | 有 |
| 32 | **被 `require` 的模块文件不得依赖全局 `translate`**，必须 `require "luci.i18n"` | 只有 CBI 模型文件享有 dispatcher 注入；模块里写裸 `translate` 会在 `cfgvalue()` 期间抛 nil value → **整页 500**。本地测试预置了 `translate` 桩，所以本地全绿、路由器 500 | 有 |
| 33 | **清缓存必须用 `dc_dnsmasq_pid`（按 `:53` socket 反查），不得用 `pidof dnsmasq` 第一个**。Lua 侧只调 `dnschain-health flush`，不自己找 PID | `pidof dnsmasq` 返回 3 个 PID，**第一个是 ujail 辅助子进程**（实测 `wchan=anon_pipe_read`、5 个 fd、0 个 `socket:53`）。对它 SIGHUP 是**空操作**，按钮点了完全无效，页面却报「已清空」——静默失效 | 有（契约 3 条） |
| 34 | **`dc_health_cycle` 必须有互斥锁**（`mkdir` 原子锁 + 死锁自动清理） | daemon 每 `interval` 秒跑一轮，页面「立即探测一轮」随时可触发。并发时 `dc_health_upsert` 的「读旧文件 → 过滤 → 写临时 → mv」不是原子的，后完成的进程会用少了对方新增行的副本覆盖 → **状态文件丢行** → 页面汇总对不上 | 有（契约 1 条） |
| 35 | **状态文件写盘只能有一处实现**（`dc_health_upsert`） | `dc_health_write` 与 `dc_health_write_keep_last` 原先各复制一整段写盘逻辑，只差 `last` 取值。改一处忘另一处 → 两个入口写出**格式不同**的状态文件，而 `status`/页面都按 7 字段解析 | 有（契约 1 条） |
| 36 | **selftest 缓存指纹必须覆盖所有影响结论的输入**（端口/进程/`ss_spec`/开关 + `filter_aaaa` + `ipv6_support` + gfw 行数 + 上游列表） | 漏项的症状是「改完配置看自检，60 秒内还是旧结论」，用户以为改动没生效。另：BusyBox **没有 `stat`**，取 mtime 必须用 `date -r <file> +%s` | 有（契约 2 条） |
| 37 | **tab 切换必须修正滚动位置** | 各 tab 高度差数倍（分流约 3000px、概览约 900px）。只切 `hidden` 不管滚动时，从长 tab 滚到底再切短 tab，`scrollY` 仍停在旧值 → 屏幕只剩页脚，看起来像「页面空了」 | — |
| 38 | **`dc_health_cycle` 的取锁必须在「实例就绪检查」之后** | 原顺序是「取锁 → 检查实例 → 不就绪就 `return`」，那条 `return` 不释放锁。daemon 是常驻进程、`$$` 恒定 → 某轮撞上 dnsproxy 未监听就永久自锁，后续每轮都打印「SKIP 已有一轮探测在跑」→ **改道功能完全停止而日志显示正常**。实测：同进程连跑 3 轮，第 2/3 轮全被自己的锁挡住 | 有（契约 1 条） |
| 39 | **禁止 `n=$(grep -c PAT f \|\| echo 0)`**。无匹配时 `grep -c` 既打印 `0` 又返回 rc=1，`\|\| echo 0` 再追加一个 → 得到 `"0\n0"`，`[ "$n" -eq 0 ]` 算术比较报错返回假 → **判据恒假**。用 `dc_count_lines`（awk 实现，恒输出单个整数） | 实测 `v=$(grep -c '^x' /tmp/t \|\| echo 0); [ "$v" -eq 0 ]` → rc=2。后果：nftset 归零自愈永不触发、`dc_prev_nftset_count` 返回脏值 | 有（契约 1 条） |
| 40 | **nftset 归零自愈必须在 `reconcile_invariants` 里**，不能放 `reconcile_lists` | `reconcile_lists` 在「名单指纹未变」时直接 `return 0`，而 nftset 归零与名单无关（SSR-Plus 重建窗口造成）→ 放那里等于**永不检查**。实测确认原位置从不触发 | 有（契约 1 条） |
| 41 | **一次配置应用只能重启 dnsmasq 一次**。`reload_service` 用标记文件 `/var/run/dnschain/.dnsmasq-dirty` 抑制中间步骤，末尾统一重启 | 原调用链 `reload_service → reload_dnsmasq` + `stop → stop_service → reload_dnsmasq` + `start → start_service → reload_dnsmasq` = **3 次**（实测主进程出现 4 个不同 PID），每次约 3 秒中断 → 一次保存断 9 秒以上。更糟的是中间那次跑在「分流片段已被写成停止注释」的状态下。⚠️ 不能用环境变量传递：procd 的 stop/start 会重新 exec，变量跨不过去（实测只减到 2 次） | 有 |
| 42 | **`stop_service` 必须清空 `watch.servers`，且在重启 dnsmasq 之前** | 该文件在 tmpfs、不会随 stop 消失，且 `serversfile` 仍指着它。stop 后重启 dnsmasq 会重读它 → 里面的 `server=/x/127.0.0.1#5336` 指向已停端口 → **关掉框架后这些域名稳定解析失败**，日志干净。清成注释占位而非删除（同 `update_dot_reject` 的理由） | 有 |
| 43 | **`uci-defaults` 里的 `serversfile` 必须引用库常量 `DNSCHAIN_WATCH_SERVERS`**，不得硬编码 | 原写死 `/var/etc/dnschain/watch.servers`，而库与 init 用 `/var/run/dnsmasq/`。平时 init 会纠正，但服务未启用/`preflight` 失败/首刷后先看页面时 UCI 里就是错路径 → dnsmasq（uid 453）读不到该目录，**既不报错也不生效** | 有（契约 1 条） |
| 44 | **`dc_run_timeout` 成功路径必须删 `.done` 标记文件** | 原只在入口 `rm -f`，而 `mktemp` 每次新路径 → 入口删不到别人的；成功返回两处又只 `wait`+`echo 0`+`return`。实测每次成功探测泄漏 1 个文件；健康 cycle 一轮约 48 次 × 每 60 秒 → **每天约 7 万个空文件**堆进 tmpfs，最终 `mktemp` 失败 → 探测全 FAIL → 误判双链都挂 | 有 |
| 45 | **页面配置项必须有 shell 消费者，否则明示「仅作记录」** | 实测 11 个键（`cache.enabled`/`cache.size`/`lists.black_source`/`lists.import_interval`/`selftest.auto_rollback`/`selftest.interval`/`main.intercept_doh`/`foreign.via_proxy`/`foreign.cert_verify`/`aaaa.*`/`ssr.mode`）有 Lua 定义但零消费者 —— 用户改了不生效，且无从察觉。`cache.size` 与 `lists.black_source` 已接上消费者；其余在页面明示「仅作记录」 | 有（契约 1 条） |
| 46 | **Lua 里禁止用 `[^—]` 这类「排除多字节字符」的字符类**。Lua 字符类按**字节**工作，`[^—]` 实际排除 `E2 80 94` 三个字节 | `—`(U+2014) 的 UTF-8 是 E2 80 94。凡名称含 `一`(E4 B8 80)、`上`、`下` 等第三字节为 0x80 的常用汉字，匹配**直接失败**。实测自检 20 项里 **7 项**解析失败（整行进 name、detail 为空），另有 10 项 name 尾随空格。改用 `find(sep, 1, true)` 字节精确匹配 | 有（lua 断言） |
| 47 | **URL 端口解析必须先判方括号 IPv6** | `:%[?([0-9]+)%]?$` 对不带端口的 IPv6 字面量会把末段当端口：`https://[2606:4700::1111]/` → `1111`（应 443）、`tls://[2400:3200::1]` → `1`（应 853）。后果：端口校验误拒或误判合规，国外解析静默失败 | 有（lua 断言） |
| 48 | **图示的未知/空 `state` 必须归入 `unknown` 档，保证行数守恒** | 原 `r.state or "unknown"` 只兜 nil，空串与未知值会落进不在 `STATUS_ORDER` 的键 → `present` 与 `n_all` 都不遍历它 → **域名在导图里凭空消失**，根节点还写「观测 1 个」。实测 3 行进 1 个 | 有（图示断言） |
| 49 | **`status_layout` 与 `status_map` 必须共用同一套布局计算**（`layout_plan`） | 原两者口径不同：`status_layout` 用 `pairs(rows)` 数**行数**，`status_map` 画**档位数**（最多 5 档，both-bad 恒占一档）；`NH` 也一个硬编码 60、一个随 hint 折行增长。实测 5 档各 1 个域名：实际高 386，报告 406 —— CI 几何断言验的是不存在的布局 | 有（图示断言） |
| 50 | **「分流规则条数」必须数 `dnschain-split.conf` 的 `server=` 行**，不是 `foreign-split.conf` 的行数 | 后者是「数据库国外 − 自定义国内 − 观测域名」的**纯域名清单**（不含 `server=` 前缀），页面标签「条 server=/域名/」名不副实。实测加 1 个自定义国外域名后：前者 23714、后者 23715，页面数字偏小 | 有（lua 断言） |
| 51 | **`apply` 的输出必须解析全部 5 条正常出口 + `ERROR=` 失败出口** | `cmd_apply` 出口：`DNSMASQ=restarted/skipped×2/sighup/unchanged` + `ERROR=`。原实现只处理 `restarted`，最常见的 `unchanged`（只改阈值、片段未变）用户点保存后**看不到任何提示**；按钮侧反过来无条件拼 `✓`，`ERROR` 时显示「✓ 已应用」+ 错误正文 | 有（lua 断言） |
| 52 | **`dc_get` 的第一个参数是 UCI section 的「名字」，不是「类型」**。`config ssr 'compat'` 要写 `dc_get compat mode`，不是 `dc_get ssr mode` | 配置文件里 `config <类型> '<名字>'`，而 `uci get dnschain.<名字>.<选项>` 只认名字。写类型时查的是「名字恰好等于该类型的 section」，通常不存在 → 恒返回空 → 恒走兜底值 → **用户的选择被静默推翻**。实测：`compat.mode=7` 时 `dc_get ssr mode` 返回空、函数返回 `0`；改 `dc_get compat mode` 才返回 `7`。本仓库已两次踩（`upstream`→`cn/foreign`、`ssr`→`compat`） | 有（契约 5 条，含反向断言） |

**改道判定的一句话规则**：首选链不通、且另一条链通 → 切到另一条。
两条需求规则（国外不通改直连 / 国内不通改代理）是这同一判定的两个实例，
因为首选已由归属决定。**双链都不通时不改道** —— 那是链路故障，
改道只会掩盖问题，页面标 `both-bad` 红档。

**新增/修改这一块后必须跑**（CI 同一份逻辑）：

```sh
sh tools/verify-dnschain-domains.sh          # 121 条契约断言
python3 tools/check-dnschain-lua.py          # 121 条：语法 + 模型 + 真实渲染页面
python3 tools/render-dnschain-diagrams.py    # 44 条：图示纯几何
python3 tools/extract-dnschain-i18n.py       # 中文文案完整性（缺译会中英混排）
sh tools/verify-dnschain-ci-sim.sh           # 复现 CI 的目录场景
```

`tools/check-dnschain-lua.py` 用 lupa（真实 Lua 解释器）**执行**每个
`cfgvalue()`，而不只是 `luac -p` —— 拼错的方法名、nil 索引、未定义变量
都只在渲染时才暴露，语法检查抓不到。

**853 拒绝的优先级已实测**（2026-10-20，路由器上）：
裸 chain + `priority -151` 单独 `nft -f` 会报语法错误（缺 table 上下文，属预期）；
经 fw4 include 到 `table inet fw4` 内部后**语法有效**，`nft list` 显示
`priority mangle - 1`，即先于 `ss_spec_mangle` 的 `mangle(-150)`。

> **v0.8.0：dnsproxy 的「24 个硬编码国外域名 → 127.0.0.1:5335」例外清单已删除。**
> 该清单 24/24 全部命中 `gfw_list.conf`，属重复声明；而 SSR-Plus **禁用**时
> 它是纯故障源（`:5335` 无监听 → `connection refused` → 回落 `1.12.12.12`
> → 污染答案，实测 `youtube.com → 31.13.92.37`、`wikipedia.org → 31.13.94.36`）。
> **不要把它加回去。** 详见 CHANGELOG v0.8.0 与「启用后全挂」一节。

**`dns-forward-max` 必须显式抬高。** dnsmasq 默认仅 **150** 个并发转发槽，
而本固件 `noresolv=1` 无兜底、且有 23701 个域名指向 `:5335`。
MosDNS 上游挂死时这些查询会在槽内挂到超时（实测单查询挂满 15 秒），
槽位耗尽会连带拖垮**国内**解析。现值为 `1024`，
写在 `files/etc/uci-defaults/99-gaming-optimize`；验证方式是看
`/var/etc/dnsmasq.conf.cfg01411c` 里是否出现 `dns-forward-max=1024`。

### 4.1 ⚠️ `enable_switch` 必须为 `'0'`（v0.8.1 起的硬约束）

`enable_switch='1'` 会让 `/usr/bin/ssr-switch` 每 `switch_time` 秒（本机 667s）
探测当前节点，失败即 `/etc/init.d/shadowsocksr restart`（ssr-switch 第 155 行）。
这条路径是**周期性 DNS 故障源**，机制如下：

1. `start()` 先 `start_rules` + `gfw2ipset`，把 23701 条
   `server=/域名/127.0.0.1#5335` 拷进 dnsmasq —— **此刻分流已生效**；
2. 约 2 秒后才 `start_dns`/`start_server` 拉起 MosDNS 与 Xray；
3. 于是有约 **4 秒空窗**：分流指向 `:5335`，而 `:5335` 尚无人监听。
   实测（0.5 秒粒度）：
   ```
   21:39:35  gs=cfg014a8f  5335=0  1234=1  nft=0  gfw=23701   ← 危险窗口
   21:39:37  gs=cfg014a8f  5335=1  1234=1  nft=2  gfw=23701   ← 才就绪
   ```

而且探测本身容易误判：`switch_time=3` 是 **curl 超时 3 秒**，跨境节点
TLS 握手常超过它。全部候选节点判失败时，`select_proxy` 返回 `nil`，
`switch_proxy` 就 `uci set global_server=nil` —— 界面仍显示「已启用」，
但 `load_config()` `return 1`，**一条规则都不装**，进入半死状态。

**结论：单节点家用场景关闭自动切换。** 若日后确需开启，必须同时满足
①探测超时 ≥ 10s；②全节点失败时保留原 `global_server`（不写 nil）；
③`start()` 改为「后端就绪后再装分流」。

### 4.2 ⚠️ `global_server` 绝不能是 `nil`（v0.8.2 起的硬约束）

`global_server='nil'` 是**客户机全挂的直接开关**，但界面看不出来：

- `load_config()` 见 `GLOBAL_SERVER=nil` 直接 `return 1`
  → **一条 nft 规则都不装**、MosDNS(:5335)/Xray(:1234) 全不启动
- 而 LuCI 里 `enable=1` 仍显示「运行中」，`ss_spec` 表也已消失
- 客户机 DNS 全部 timeout；**路由器自身却正常**（走 `/etc/resolv.conf`
  的运营商 DNS，完全绕过 dnsmasq）

**根因在 `/usr/bin/ssr-switch` 的 `set_main_server()`**：原实现只判空串
`[ -n "$sid" ] || return 1`，而 `select_proxy()` 失败时把 `ENABLE_SERVER`
置为**字符串 `"nil"`**（不是空串），于是 `set_main_server "nil"` 通过检查并
`uci set global_server=nil` **落盘**。监控日志实证：

```
22:02:31 *** gs=cfg014a8f → cfg194a8f   ← 被自动切换
22:04:09 *** gs=cfg194a8f → nil          ← 再被写成 nil，客户机全挂
```

v0.8.2 起 `files/etc/uci-defaults/99-gaming-optimize` 打两处**幂等**补丁
（带 `修复 v0.8.2` 标记，打前 `grep -q` 判重，补后 `sh -n` 校验，失败回滚）：

| 补丁 | 内容 |
|---|---|
| (a) | `set_main_server()` 增加 `[ "$sid" != "nil" ] \|\| return 1` |
| (b) | `run_once()` 的 else 分支不再盲写 `CURRENT_SERVER`，改为「保留原节点只重启」 |

**判定客户机故障是否属于这一类**，看三样：

```sh
uci -q get shadowsocksr.@global[0].global_server      # 必须是节点名，不能是 nil
nft list tables | grep -c ss_spec                     # 应为 2
netstat -lnu | grep -cE ':(5335|1234)'                # 各应为 1
```

**排查这类问题必须监控 `global_server` 的变化，不能只看某一时刻的组件状态。**
在健康态里测永远通过；只有按 2 秒粒度连续采样才看得见
`cfg014a8f → cfg194a8f → nil` 的轨迹。

**客户端症状会伪装成「连通性问题」而非「DNS 问题」**：`conntrack` 里
国内 TCP 是 `[OFFLOAD]`（正常），国外 TCP 全停在 `SYN_SENT [UNREPLIED]`
（无回应）。用户侧的表述是「ping 通、HTTP 无 200」或
`os error 11001`（不知道这样的主机）。

### 4.3 ⚠️ tproxy 端口列表绝不能含 53（v0.8.4 起的硬约束）

`dports='2'`（常用端口）的端口列表**曾经**含 `53`：

```sh
proxyport="-m multiport --dports 22,53,587,465,995,993,143,80,443,853,9418"
```

这是「启用 SSR-Plus 后客户机连 baidu 都解析不了、过一阵又自己好」的
**真正根因**，也是本仓库历史上最难定位的一处。

**机制**：客户机 DNS 会同时命中两条拦截路径，而 tproxy 那条先赢 ——

| 路径 | 表/链 | 优先级 | 结果 |
|---|---|---|---|
| TPROXY | `ip ss_spec_mangle prerouting` | **mangle = -150**（先执行） | DNS 被送进 `:1234` 给 v2ray |
| 劫持 | `inet fw4 dns_intercept_lan` | dstnat+1 = **-99**（后执行） | 本该到 dnsmasq，但已被抢走 |

**nft 计数器实证**（插三个计数器后发一次查询）：

```
DBG-dns-pre   packets 48    ← 到达 prerouting/mangle
DBG-dns-nat   packets 0     ← 从未到达 dns_intercept_lan
DBG-dns-in    packets 0     ← 从未进入 input
```

**v2ray 会为每个被 tproxy 的 DNS 打开一个绑定 `192.168.3.254:53` 的 UDP
socket 且不释放**，累积后反过来抢走 dnsmasq 的 DNS 包。实测累积过程：

```
23:11:49  socket=1    解析=1   ← 正常
23:11:56  socket=4    解析=0   ← 开始堆积
23:12:10  socket=50   解析=0
23:12:24  socket=167  解析=0
23:12:38  socket=246  解析=0   ← 完全不可用，连 baidu 也超时
```

峰值观测到 **283 个** socket 全部绑定 `192.168.3.254:53`，`rx_queue` 全部非零
（数据积压从未排空）。用 inode 反查确认属于 v2ray：PID 持有 22/23 个，
而 dnsmasq 只有 1 个。

**「自己会好」的原因**：v2ray 重启后 socket 归零 → 短暂恢复 → 再次堆积。

**正确做法**：

```sh
proxyport="-m multiport --dports 22,587,465,995,993,143,80,443,853,9418"
```

**关键坑：只改运行时 nft 规则不够。** 持久化规则
`/usr/share/nftables.d/ruleset-post/99-shadowsocksr.nft` 里仍含 53，
`fw4` 重载会把它加回来。必须同时改 init 脚本的端口列表，让
`ssr-rules -P` 重建的持久化文件也不含 53。

**排查这条的正确顺序**（缺一步都会走偏）：

```sh
# 1. 客户机实际使用的地址上，socket 数是否 >1
netstat -lnup | grep -c '192.168.3.254:53'     # 正常应为 1
# 2. 规则里还有没有 53
nft list chain ip ss_spec_mangle prerouting | grep dport
# 3. 持久化文件里还有没有 53（fw4 重载会复活它）
grep -l '22, 53,' /usr/share/nftables.d/ruleset-post/*.nft
# 4. 分段计数器：确认 DNS 包被谁吃掉
nft add rule ip ss_spec_mangle prerouting iifname "br-lan" udp dport 53 counter
nft add rule inet fw4 dns_intercept_lan iifname "br-lan" udp dport 53 counter
nft add rule inet fw4 input iifname "br-lan" udp dport 53 counter
```

**不要只测 `127.0.0.1:53`。** 客户机用的是 `192.168.3.254:53`，
后者被 v2ray 抢占时前者仍然正常 —— 这是最容易误判的一点。

**`netstat` 对多 socket 归因不可靠。** 要确认 socket 属于谁，
用 `/proc/net/udp` 取 inode 再反查 `/proc/<pid>/fd`：

```sh
INODES=$(awk 'NR>1 && $2 == "FE03A8C0:0035" {print $10}' /proc/net/udp)
for pid in <候选PID>; do
  n=0; for ino in $INODES; do ls -l /proc/$pid/fd 2>/dev/null | grep -q "socket:\[$ino\]" && n=$((n+1)); done
  echo "PID $pid 持有 :53 socket 数 = $n"
done
```

### 4.4 dnsmasq 一律用 `reload` 而非 `restart`（v0.8.3 起的硬约束）

`restart` 会杀进程再拉起，实测造成约 **3 秒完全不可用**，期间客户机
连 `www.baidu.com` 都无法解析。`reload`（SIGHUP 重读配置）实测失败 **0 次**，
且能正确加载新增的 `server=/域名/127.0.0.1#5335` 分流。

`init.d/shadowsocksr` 的 `stop()` 与 `start()` 原本**各自**重启一次 dnsmasq，
而 `restart` = `stop + start` → 一次 restart 断**两次**：

```
修复前：22:45:18 → 22:45:21   又  22:45:32 → 22:45:35   ← 断两次约 8 秒
修复后：22:48:09 → 22:48:12                              ← 只断一次
```

现已在 `files/etc/uci-defaults/99-gaming-optimize` 里打三处补丁：
覆写 `restart()` 设 `SSR_IN_RESTART=1`、`stop()` 内那次加标志守卫、
两处 `restart` 一律改 `reload`。

**⚠️ 断言写法（2026-10-20 修正）：不要用 `grep -c 'dnsmasq restart'` 应为 0。**

该断言会**永久误报**。路由器实测（`/etc/init.d/shadowsocksr`，3324 行）：

```
grep -n 'dnsmasq reload\|dnsmasq restart' /etc/init.d/shadowsocksr
3161:	/etc/init.d/dnsmasq reload >/dev/null 2>&1          ← 真调用
3305:			echolog "restart: skip dnsmasq restart in stop()"   ← 只是日志字符串
3309:			/etc/init.d/dnsmasq reload >/dev/null 2>&1      ← 真调用
```

`grep -c` 返回 **1**，但那是 `echolog` 里的**文本**，不是调用点。正确判据是
**排除 `echolog` 行后**统计真正的 `/etc/init.d/dnsmasq restart` 调用，应为 0。

**⚠️ 仓库 overlay 与固件实况已漂移（同期发现）。** 路由器上两处调用确实是
`reload`（符合意图），但仓库 `files/etc/uci-defaults/99-gaming-optimize:503`
生成的代码**仍是** `/etc/init.d/dnsmasq restart`。下一次刷机可能把 reload 改回
restart。落地 DNS 链路框架时须一并修正（见 `docs/adr/0003-dns-chain-framework.md` §2.7 D8）。

**⚠️ 但 `reload` 有一个已知副作用（v0.8.6 实测，尚未修）：它不重读 conf-dir。**
dnsmasq 的 `SIGHUP` 只清缓存、不重新解析配置文件；而 OpenWrt 的
`reload_service()` 是 `rc_procd start_service "$@"; procd_send_signal dnsmasq "$@"`
—— `start_service` 会重新生成 `/var/etc/dnsmasq.conf.*`，但已运行的进程
**不会**再读它。实测对照（往 `/tmp/dnsmasq.d/dnsmasq-ssrplus.d/` 放
`address=/zz-probe.invalid/3.3.3.3`）：

| 操作 | 探针解析结果 |
|---|---|
| `reload` | 无结果（未加载） |
| `restart` | `3.3.3.3`（已加载） |

后果：SSR-Plus 重建 `gfw_list.conf` 后，dnsmasq 可能仍用旧内容 →
部分国外域名拿到污染答案（实测 `www.reddit.com` 返回 `157.240.7.20` /
`2001::1`，而直连 `mosdns:5335` 返回正确的 `151.101.x.x`）。
排查此类现象时，**必须分别测「经 dnsmasq:53」与「直连 5335」**，
只测其中一个会把「分流未加载」误判成「mosdns 有问题」。

改动这一取舍属修改 DNS 配置，**须先申请批准**（见第 9 节）。

**判定进程是否存在，不要用 `pgrep -x <名字>`。** SSR-Plus 的二进制以完整路径
运行（`/var/etc/ssrplus/bin/v2ray`、`.../mosdns`），`pgrep -x xray` /
`pgrep -x mosdns` **恒为 0**，会误判成「后端没起」。应改用
`pgrep -f '/var/etc/ssrplus/bin/'` 或遍历 `/proc/*/cmdline`。

**`pgrep -f` 还会匹配到诊断命令自身。** 用
`pgrep -f "ssr-switch start"` 判定时，它会把执行该命令的 `ash -c`
也算进去（实测虚报成 2 个进程）。遍历 `/proc/*/cmdline` 时必须
`grep -v "ash -c"` 排除。

**`nc -z` 不能判断代理节点可用性。** Cloudflare 前置的节点对裸 TCP 不响应，
但 TLS 握手正常。判据应看 `netstat -antp` 是否有 **ESTABLISHED** 到节点的
连接，或直接测经代理的解析/访问结果。

- **SSR-Plus 透明代理只代理 IPv4。** 在 fw4/nftables 固件上体现为
  `table inet ss_spec` 的 `redirect to :1234`（**不是** iptables 的
  `REDIRECT --to-ports 1234` —— v0.4.x 起已全面切到 fw4，见下方「fw4 现状」）；
  **IPv6 侧只有 DNS 重定向，没有任何 TPROXY/REDIRECT** —— 国外 IPv6 是**直连**。
- **代理流量走 INPUT/OUTPUT，不经 forward。** REDIRECT 把目的地址改写为本机，
  故客户端流量「上升」为本机 INPUT、「下降」为本机 OUTPUT。
  任何「统计每设备流量」的实现挂在 forward 链上都会**几乎看不到流量**
  （实测客户端下载 150 MB，forward 仅 5932 B，output 为 157548502 B）。
- 进程：`v2ray`（dokodemo-door, port 1234, retcp 模式）、`mosdns`(:5335)、
  `dnsproxy`(127.0.0.1:5353)、`dnsmasq`(:53)、`ssr-switch`。
- SSR-Plus 强制代理：`/etc/ssrplus/black.list` → dnsmasq `ipset=/<域名>/blacklist`
  → 解析结果自动入 `blacklist` ipset → `SS_SPEC_WAN_AC` 命中即 REDIRECT 到 1234。
- 访问控制 `lan_ac_mode='0'` + `SS_SPEC_WAN_FW` 末尾兜底 → **所有非国内 IPv4 流量走代理**。

### fw4 现状（2026-10-10 核查，结论：已全面切换）

| 判据 | 实测 |
|---|---|
| 主 ruleset | `table inet fw4` 在跑，34 条 chain |
| DNS 拦截 | nftables：`chain dns_intercept_lan`（`iifname br-lan … redirect`） |
| 透明代理 | nftables：`table inet ss_spec` / `table ip ss_spec_mangle` |
| fullcone | nftables：`nft_fullcone` 模块 + `meta nfproto ipv4 fullcone` |
| `/etc/firewall.user` | include 计数 = **0**（死代码，fw4 不加载） |
| `iptables` 各表 | 仅剩 `-P` 默认策略行，**无任何规则** |
| `ip_tables` 内核模块 | **未加载** |

残留的 `iptables`/`ip6tables` 二进制与 `kmod-ipt-*` 是 SSR-Plus 等包的依赖项，
属正常共存，**不表示仍在用 fw3**。判定「是否还在用 fw3」应看
**规则实际落在哪个后端**，而不是看二进制是否存在。

---

## 5. ⚠️ `filter_aaaa` —— 语义随 dnsmasq 路由分裂而反转（动手前务必确认）

> 🚨 **v0.10.0 起本节结论已再次反转，先读这里再读下文。**
>
> | 版本 | `filter_aaaa` | 原因 |
> |---|---|---|
> | v0.4.0 ~ v0.9.x | `'1'`（抑制） | 国外 IPv6 直连 → 会 RST |
> | **v0.10.0 起** | **`'0'`（保留）** | SSR-Plus 的 IPv6 流量代理已把国外 IPv6 送进代理，不再需要抑制 |
>
> **实际生效的是 `dhcp.@dnsmasq[0].filter_aaaa`，不是
> `shadowsocksr.@global[0].filter_aaaa`。** 后者是用户偏好，前者才决定行为：
> `ipv6_support=1` 时 SSR-Plus 的 `get_filter_aaaa()` 直接返回 0，
> 并调 `set_ipv6_dns_filter` 把 `dnsmasq.filter_aaaa` 设为 0。
>
> 实测（v0.10.0）：`shadowsocksr.filter_aaaa=1` 但 `dnsmasq.filter_aaaa=0`，
> 而 AAAA 解析完全正常（taobao 2 条、google 8 条真实 AAAA）。
> **判据必须读 `dnsmasq.filter_aaaa`** —— 读前者会得出错误结论。
>
> 下文（v0.4.0 时代的推演）保留用于理解历史，但**结论已不适用**。

这是本仓库**最容易误改**的一个开关。它的「正确值」**不取决于开关字面，而取决于
dnsmasq 把哪些域名指向 mosdns:5335**。v0.4.0 时的仓库值是 **`'1'`**，
具体理由与完整推演见 `docs/adr/0001-filter-aaaa-semantics.md`。

| dnsmasq 路由 | `filter_aaaa` | 实际效果 |
|---|---|---|
| **全量**指向 `#5335`（v0.3.5 时代） | `'1'` | 所有国外域名失去 AAAA → 双栈客户端「有 IPv6 但上不了网」（v0.3.5 修的就是这个） |
| **分裂**（现状：默认 `#5353`，仅 `gfw_list.conf` 的 23701 条 + `black.list` 走 `#5335`） | `'1'` | 只有**需走代理的域名**失去 AAAA → 被墙域名回落 IPv4 走代理；其余国外域名保留 AAAA 走 IPv6 直连 |
| 分裂 | `'0'` | 那 23701 个被墙域名拿到真实 AAAA → IPv6 直连被 **RST** → 「有 IPv6 但打不开站点」 |

- **判定方法**：`grep -c '127.0.0.1#5335' /tmp/dnsmasq.d/dnsmasq-ssrplus.d/gfw_list.conf`
  与 `/var/etc/dnsmasq.conf.cfg01411c` 的 `server=` 行。先看路由，再判开关值。
- **实测基线（2026-10-09）**：`taobao.com` 返回 8 条真实 AAAA；`google.com` /
  `chatgpt.com` / `steamcommunity.com` 返回 mosdns 合成 SOA（`fake-ns.mosdns.fake.root`）；
  `baidu.com` / `qq.com` 的 SOA 来自真实权威（**上游确实没有 AAAA，不是被抑制**，
  勿把这当证据）。
- 相关机制：`get_filter_aaaa()`（`/etc/init.d/shadowsocksr`）→ init 脚本把模板里的
  `DNS_MODE` 占位符替换为 `main_sequence_disable_IPv6` 或 `main_sequence_with_IPv6`。
  改 UCI 后需 `/etc/init.d/shadowsocksr restart` 重新生成运行时配置
  （`/var/etc/ssrplus/mosdns-config.yaml`）。
- **改动此开关前必须同时确认路由形态，并同步 CHANGELOG 与 ADR-0001。**

### 5.1 用户的明确要求与当前实现（2026-10-17 实测确认）

用户要求：**国外不要 IPv6 直连**（避免被 RST），**国内保持双栈**。
当前 `filter_aaaa='1'` **已精确实现该语义，不要改动它**。实测：

| 域名 | 归类 | A | AAAA | AAAA 耗时 |
|---|---|---|---|---|
| `www.moe.gov.cn` | 国内（不在 gfw_list） | ✅ 真实 | ✅ `2408:875c:0:80::6c` | 28ms |
| `www.cac.gov.cn` | 国内（不在 gfw_list） | ✅ 真实 | ✅ `240e:95c:806:40::413` | 36ms |
| `www.github.com` | 国外（在 gfw_list） | ✅ 经代理 | ⛔ 空答复 | **1ms** |
| `www.youtube.com` | 国外（在 gfw_list） | ✅ 真实 | ⛔ 空答复 | **1ms** |

**⚠️ 极易误判的一点：国外 AAAA 是「1ms 空答复」，不是「5 秒超时」。**

MosDNS 的 `reject 0` 返回的是 `rcode=0` + `ancount=0`（合法答复：明确告知
「没有此类型记录」）。客户端收到后会**立刻**回落查 A，不会等待。
只有**收不到任何包**才是 `TIMEOUT`，那才会卡住客户端 5 秒。

排查时必须把四种结果分开判定，写检查脚本时尤其注意：

| 判定 | 条件 | 是否故障 |
|---|---|---|
| `OK` | rcode=0 且 ancount>0 | 否 |
| `EMPTY` | rcode=0 且 ancount=0 | **否**（`filter_aaaa` 的预期形态） |
| `NX` | rcode=3 | 否（域名不存在） |
| `TIMEOUT` | 完全无响应 | **是**（会卡住客户端） |
| `FAIL` | rcode=2 等 | **是**（上游故障） |

把 `EMPTY` 当成失败，会得出「国内也全挂」这种完全错误的结论 ——
本轮排查正是栽在这里。

**禁用 SSR-Plus 时国外 AAAA 会变回污染值**（实测 `2001:0:0:0:0:0:0:1`、
`2001:df2:e500:ed1a::1`）。这正是「国外 IPv6 直连被 RST」的成因，
也是必须启用 SSR 的理由之一 —— 不要以为禁用 SSR 更「干净」。

---

## 6. 路由器实验环境与验证方法

| 项 | 值 |
|---|---|
| 路由器 | OpenWrt 24.10.5 x86/64（SSH: `root@192.168.3.254`） |
| 本机 | Windows，`192.168.3.238`，网关/DNS = `192.168.3.254` |
| 双栈 | 本机持有运营商公网 IPv6 `240e:355:7f2b:8900::/64`（**原生可用**） |
| 路由器 SSH | dropbear，老 KEX；Windows 自带 `ssh.exe` 无密钥会 `Permission denied`。**可用通道**：`plink.exe`（PuTTY，端口 22）+ `-pw password`。**hostkey 每次刷机都会变**（已观测 `0rLD…` → `riiL…` → `Z+v8…` → `B1pg…`），故不要照抄旧值：先用 `plink -batch`（不带 `-hostkey`）试探，它会把当前指纹打印出来，再拿该指纹重试。传文件用 `pscp -scp`（**不能**用默认 SFTP：固件无 `sftp-server`）；`-hostkey` 值含 `+`/`/`，**必须加引号**，否则被 shell 误解析。`rsh.py` 当前不在磁盘上（见附录）。 |

**验证纪律**（本项目历史上多次因「只看进程在跑」而误判）：

1. **必须端到端验证**，不能只看服务启动。
2. **注意地址族**：`Test-NetConnection` / 浏览器可能选中 IPv6 而绕过 IPv4 代理，
   排查代理问题时务必同时看 `curl -4` 与 `curl -6` 的结果。
3. **注意 Cloudflare 机器人挑战**：用 `curl`/无头浏览器访问 chatgpt.com 会得到
   `403 Cf-Mitigated: challenge` —— 这是**反爬**，**不是**网络故障，勿误判。
   真实浏览器才是有效证据。
4. 改动 UCI 后确认**运行时**配置已重建（如 `/var/etc/ssrplus/mosdns-config.yaml`）。
5. 改完做**回归**：国内域名（baidu/qq/taobao）+ 国外站点（google/youtube/github）+ DNS 加密链路。
6. **在路由器上做诊断时，别让诊断本身污染测量结果**（实测踩过，误导过一次判断）：
   - BusyBox 的 `ps w` 会把长命令行**折行**，且脚本**自身的 cmdline 会包含搜索关键字**
     → `ps w | grep -c '<脚本名>'` 会**严重虚高**（我一度报出「2532 个进程」，
     真实只有 8 个，并据此误判成「生产事故」）。
     正确做法：遍历 `/proc/[0-9]*/cmdline`，**只匹配 exec 名 + 第一个参数**，
     不要把整条 cmdline 纳入匹配。
   - 循环 `for d in /proc/[0-9]*` 本身就会 fork 大量进程并推高 load。
     测 load 要用**单次读取**（`cat /proc/loadavg`），并观察它是否在**自行回落**；
     若回落，说明尖峰是诊断造成的。
   - 同理：断言脚本/CI 守卫里的 `grep` 要**先剥掉注释行**再判断，
     否则「解释错误写法的注释」会让断言永久误报（v0.4.7 的 nft 守卫、
     v0.4.10 的 `setInterval(runQuery` 守卫都踩过）。
8. **看 CI 日志要按位置截取，不要先 grep 关键字**（踩过，连错三次）：
   `gh run view --log` 里**源码回显占绝大部分** —— 每条 run 脚本都会以
   `N\t<原文>` 的形式重印一遍，真实执行输出夹在中间。用关键字 grep 会同时命中
   回显，于是误判成「没输出」或「输出正常」。
   正确做法：先定位真实执行的**第一条**输出（它不带行号前缀），再从那里
   **顺序原样**打印后续几十行。这样才看到那两行关键信息：
   `>>> 将固件产物上传到 Release v0.4.11（仓库 …）`（证明 GH_REPO 已生效）
   与随后的 `HTTP 403: Resource not accessible by integration`（真正的拦路虎）。
9. **权限类问题用 `Set up job` 步骤的 `GITHUB_TOKEN Permissions` 块自检**：
   它会列出本次运行**实际拿到**的权限（`Contents: read/write` 等），
   几分钟内就能看到，**不必等 3.5 小时构建结束**。
   `permissions` 是**按工作流**申请的，不是按仓库 —— 同一仓库里声明了的能用写权限、
   未声明的取仓库默认（本项目默认 `read`）。
   **注意：一旦工作流自己声明了 `permissions`，未列出的 scope 一律为 `none`**，
   不再回落到仓库默认。故用 `gh api` 查 Actions 相关接口时要显式加 `actions: read`，
   否则会 403、把一次正常构建判成红灯。
10. **改动前先备份**：`/etc/config/*`、`/var/etc/ssrplus/*` 到 `/root/ssrfix-backup-<ts>/`，
    并在报告中写明回滚命令。
11. **`tools/*.sh` 必须用 `sh` 自测，不能用 bash**：CI 用 `sh` 调用，runner 的
    `/bin/sh` 是 **dash**。bash 专有语法（进程替换 `<(...)`、`[[ ]]`、数组、`local`）
    在 dash 里是**解析期**错误 —— 脚本一行未执行即 exit 2，编译全部 skipped、
    没有任何产物。**本仓库已因此连续失败三天**（v0.8.4 tag + 10-18/10-19 定时构建）。
    自测：`sh -n <脚本>`、`sh <脚本>`、`shellcheck -s sh -S error <脚本>`。
    用 bash 跑会全绿、看不出问题。临时文件用脚本头部的 `$TMPD`（`mktemp -d`+`trap`），
    不要用进程替换。CI 有前置守卫 `Verify invariants script is POSIX sh (dash) compatible`。
12. **「构建绿了但没有产物」要当成失败**：`actions/upload-artifact` 的
    `if-no-files-found` **默认 `warn`**（没匹配到文件也算成功）。固件是唯一交付物，
    故显式设 `error`，并由 `Assert firmware artifact exists` 用 Actions API 计数兜底。
    只看步骤退出码会漏掉这类静默失效 —— 空 Release 是同一类。

---

## 7. 变更流程

1. **先读** `CHANGELOG.md` 尾部与相关 `files/`、`patches/` 的注释——大量约束写在注释里。
2. 判断改动归属：
   - dnsproxy 的 LuCI 改动 → 新增 `patches/luci-app-dnsproxy/000N-*.patch`（单一职责、递增编号）。
   - trafficctl 的改动 → **直接改** `package/luci-app-trafficctl/`（vendored 整包），
     改完**必须**跑 `python3 tools/regen-trafficctl-patches.py <上游包目录>`（见红线 9）。
   - 固件运行时配置 → 改 `files/` overlay；**首次开机默认值**改 `files/etc/uci-defaults/99-gaming-optimize`。
   - 编译流程/依赖 → 改 `.github/workflows/build-openwrt.yml`。
3. 本地**无法**完整编译（需 lede 全量环境）；至少做静态检查：
   - shell：`ash -n` / `sh -n`；JS：`node --check`；patch：干净克隆上 `git apply --check`。
4. 更新 `CHANGELOG.md`：`## [vX.Y.Z] - YYYY-MM-DD` + 变更/修复/新增/验证 小节。
5. 提交信息沿用现有风格：`fix(scope): 中文描述 (vX.Y.Z)` / `feat:` / `chore:` / `ci:` / `perf:`。
6. 发版：打 `v*` tag → 触发编译 + Release（notes 自动取自 CHANGELOG 对应段）。

---

## 8. 历史踩坑速查（均已修，勿回退）

| 症状 | 根因 | 处置 |
|---|---|---|
| CI `Duplicate feed name 'helloworld'` (exit 25) | lede 已自带该 feed，重复追加 | 追加前 `grep -q` 判重 |
| naiveproxy 编译失败（gn / gcc-12 ranges） | gn 新版需 gcc-13 | 装 gcc-13 预编译 gn |
| OOM / 构建被杀 | 7GB 内存跑 Xray(Go) | `JOBS=2` |
| 固件内 `/etc/init.d/dnsproxy` 无法执行、LuCI 服务控制全灰 | overlay 脚本缺执行位 / opkg 版本解析失败 | CI `chmod +x`；patch 0002 兼容 `/usr/lib/opkg/status` |
| dnsproxy 日志刷 `context deadline exceeded` | fallback 用了 8.8.8.8（被 SSR-Plus 接管，规则重建窗口必超时） | 删 8.8.8.8，只留国内可直连的 `1.12.12.12` |
| 客户端手填 8.8.8.8 可绕过加密 DNS | SSR-Plus 规则抢先于 DNS REDIRECT | DNS 拦截插入 `PREROUTING -I 1`，并写入 `prerouting_rule` 抗 fw3 reload |
| 开机时 LAN DNS 拦截规则不生成 | `procd` 异步启动，`pgrep` 误判 | 改为**按配置意图**判断，不用 pgrep |
| 无扩展名文件 CRLF 导致路由器解析失败 | `.gitattributes` 用了根锚定 `/etc/...`，实际路径带 `files/` 前缀 → 规则失效 | 改用 `**/etc/...` |
| 「有公网 IPv6 却上不了 IPv6」 | `filter_aaaa=1` → MosDNS 对 AAAA/HTTPS `reject 0` | v0.3.5 改为 `'0'`（**但见第 5 节的新冲突**） |

---

## 9. 当前未决 / 风险

- **[已解决] `filter_aaaa` 语义冲突**：v0.4.0 起仓库值与路由器在线值统一为 `'1'`，
  依据见第 5 节与 `docs/adr/0001-filter-aaaa-semantics.md`。
- **[已处理] 本机排查脚本防误提交**：`.gitignore` 已排除本机工具（含明文口令）、
  一次性排障报告与编译产物；`.gitattributes` 已加 `*.ps1 text eol=lf`。
  该文件是安全网而非免检牌——提交前仍须确认 `git status`。
- **[已处理] `v0.3.5` 无 tag**：HEAD 早已含 v0.3.5 的修复提交但从未打 tag；
  v0.4.0 未补打该 tag（仅本地标签现状，不影响代码）。
- **[已解决] mosdns 模板的 `reject` 前置**：v0.4.0 已新增
  `files/etc/ssrplus/mosdns-config.yaml` overlay 并加 CI 契约校验。
  **硬约束：`upstreams:` 必须留在第 14 行**（init 脚本用
  `awk -v line=14 'NR == line+1 {print text} 1'` 注入上游），因此该文件的
  说明性注释只能写在末尾，顶部不得增删任何行。
- **[已解决] `rps_flow_cnt` 的清零点**：确认为 `/usr/libexec/network/packet-steering.uc`
  第 80–86 行——UCI `network.@globals[0].steering_flows` 未设置时，默认值
  `local_flows=0` 被无条件写入；其 `service_triggers` 含 `interface.*` raw trigger，
  接口事件会再次清零。**若日后需要它非零，应设 `network.globals.steering_flows`
  （上游 UCI 开关），不要改 `rc.local`。**
- **[生成路径已查明，待批准] dnsmasq 日志与 Apple 域名的明文 DNS**（审计 §10 D13/D17）：
  两项都**不能用 overlay 硬覆盖**，原因已查清（详见 `docs/audit/2026-10-09-network-audit.md`
  末尾「2026-10-10 复核」一节）：
  - `log-facility=/dev/null` 由 LEDE 上游
    `package/lean/default-settings/files/zzz-default-settings` 每次构建
    `sed -i '/log-facility/d'` 再 `echo` 写入 —— overlay 会被再追加一行。
    正确做法是 UCI `dhcp.@dnsmasq[0].logfacility`（init 脚本第 944 行转成命令行参数，
    命令行优先于 conf-file）。
  - `applechina.conf` 的 173 条明文 `114.114.114.114` 由
    `/etc/init.d/shadowsocksr` 第 1442–1453 行处理。**陷阱**：把 `apple_dns` 设成
    `127.0.0.1#5353` **不幂等** —— `old_appledns` 只用 `grep -oE` 抽 IP、丢掉端口，
    二次启动会叠成 `127.0.0.1#5353#5353`。推荐做法是 overlay 该文件且**不设**
    `apple_dns`（此时那段 `if [ -n "$new_appledns" ]` 整体跳过，文件原样拷入）。
  - `whitelist_forward.conf` 已**不是**问题：当前 6 行且形状为
    `nftset=/域名/4#inet#ss_spec#whitelist_domain`（fw4 正确写法），上游升级后自行改掉。
  改动这两项属「修改 DNS 配置」，**须先申请批准**。
- **[已解决] `package/luci-app-trafficctl` 的 vendored 副本维护**（v0.4.7，升级到 1.21.4）：
  改为「**vendored 包 + patch 差分 + 同步脚本 + CI 断言**」四件套，不再依赖人工记忆。
  - `patches/luci-app-trafficctl/` 记录相对上游的全部差分，`UPSTREAM` 记录基线 tag。
  - 改功能就改 `package/` 下的文件，改完跑
    `python3 tools/regen-trafficctl-patches.py <上游包目录>` 让 patch 跟上；
    升级上游跑 `sh tools/sync-trafficctl.sh <tag>`。
  - CI 步骤 `Verify luci-app-trafficctl local invariants` 会从 `UPSTREAM` 记录的 tag
    **真实克隆上游、重放全部 patch、要求与 vendored 包逐字节一致**，
    并断言本地改动仍在（nft 后端语法/三钩子/`@lan`、`LUCI_DEPENDS` 不含
    hostapd-utils、`optRefresh` 与 `1s` 档位、**Telegram 已全链路移除**、
    中文翻译完整性）。
  全部断言集中在 `tools/verify-trafficctl-invariants.sh`（本地可复跑，
  与 CI 同一份逻辑；`TCTL_UPSTREAM_LOCAL=<上游包目录>` 可离线运行）。
  **必须保留的本地改动**（被覆盖会静默失效，不会报错）：
  1. 重写 `root/usr/local/bin/trafficctl-bytes-nft.sh` —— 上游**至今未修**，
     仍用本内核不支持的 `flags dynamic` map + `update @bytes_in` 且只挂 forward 单钩子
     （见红线 7/8 与第 4 节的「代理流量走 INPUT/OUTPUT」）。丢掉它 → **速率列恒为 `—`**。
  2. `Makefile` 去掉 `LUCI_DEPENDS` 里的 `+hostapd-utils` —— 见第 3 节。
     丢掉它 → **整包与中文包一起被 kconfig 丢弃，界面变英文**（构建不报错）。
  3. `status.js` / `status.css` / `menu.d` / `config` / `rpcd` 的
     刷新与 tab 改动 —— 默认 5 秒自动刷新、1s/2s 档位、`refresh_interval` 端到端
     接线、页面级 tab 为**设备 | 设置 | 端口转发**。
     丢掉它 → **冷启动不再自动刷新**、或设置区冒出内层 tab（两级 tab 让人分不清层级）。
  4. `po/zh-cn/luci-app-trafficctl.po` —— 丢掉它 → **中文界面变英文**。
  5. `host.js` + `trafficctl-device.sh` 的**主机实时连接详情页**（v0.5.0，见红线 9）——
     丢掉它 → 概览「流量排行」与设备表 IP 的链接 404。
  6. `settings.js` + `common.js` 的**设置独立 tab**（v0.6.0；布局于 v0.6.2 再调整）
     —— 配置项从设备页迁到 `admin/status/trafficctl/settings`，两页共用
     `resources/trafficctl/common.js`；同时移除软件卸载的橙黄横幅。
     丢掉它 → 配置重新挤回设备页、横幅复现，或两页各持一份定义。
     v0.6.2 起设备页操作区收拢为一张卡片（设备选择 + 目标 + 档位 + 切断 +
     View & Table），「表格与速率」档位则从设置页迁回**设备页设备表上方**
     （见红线 9 第 6 项与 CHANGELOG v0.6.2 的说明）。
     v0.6.3 起设备表为**两行式**（IP/MAC、类型/厂商、操作各一列两行）、
     16 列压到 9 列、新增「累计上行/下行」与「设备厂商」（OUI）、底部有分页条 ——
     详见红线 9 第 6 项的补充与 CHANGELOG v0.6.3。
     v0.6.4 起四组档位（轮询/窗口/方法/刷新）收进 ☰ 菜单（默认收起），
     冷启动轮询默认 2s → 1s（前端 / UCI / rpcd 三处一致），
     三类字节轮询加防重入闸 —— 详见红线 9 第 6 项的补充与 CHANGELOG v0.6.4。
     v0.6.9 起设备页操作区进一步简化（picker 行只剩「所有设备 | 搜索框」、
     三个视图开关移除恒开），限速入口移进设备表每行的「限制」弹层。
     v0.7.0 起 **Telegram 全链路移除**（视图 / menu.d / acl.d / rpcd 三方法 /
     init.d 服务 / 两个脚本 / UCI 段 / hotplug 通知 / 日志分类开关），
     并把三个被复用的 `tg-*` 类名改为中性的 `tc-*`。
- **[v0.7.0 起] `luci-app-trafficctl` 的 patch 生成器支持「删除文件」。**
  `tools/regen-trafficctl-patches.py` 的分组此前只支持「改/加文件」，而移除
  Telegram 必须删掉实现（`init.d` + 两个脚本）。现在四元组
  `(patch, desc, files, deletes)` 的第二份清单会被 `unlink` 后再 `git add -A`，
  于是 patch 里出现 `deleted file mode`，套用时真正删除。
  **两条约束**：
  - 删除清单里只能写**上游存在**的文件。`telegram.js` 是本仓库新增的视图
    （上游没有），对它做「删除上游不存在的文件」会让 `git apply` 直接失败 ——
    它只需不再出现在 0002 的新增清单里，重放后自然不存在。
  - 改动 `package/` 后 100755/100644 的索引计数会变，`verify-trafficctl-invariants.sh`
    里的硬编码数字（现为 **26**）要同步更新，否则断言会误报「执行位丢了」。
- **[已解决] 上游依赖把整包拖下水（v0.4.7 起潜伏，v0.4.9 修）**：
  上游 1.21.4 的 `LUCI_DEPENDS` 含 `+hostapd-utils`，而该包在 lede 里是
  `DEPENDS:=@<某个 hostapd/wpad 变体>` + `VARIANT:=*` —— 只有选中 hostapd/wpad
  变体时符号才存在。本目标 x86_64 无 WiFi → 不可满足 → kconfig 把
  `luci-app-trafficctl` 整包判为不可选，连带 `luci-i18n-trafficctl-zh-cn`
  （`DEPENDS:=$(PKG_NAME)`）一起从 `.config` 消失。
  **排查这类问题的方法**：不要在日志里 grep「符号是否存在」（CI 不 dump 整个
  `.config`，`is not set` 行又没有 `=`，很容易误判）。正确做法是
  **对比「已知能通过的旧版本」与「现在」的差异**，或直接在 CI 里
  `grep -E 'trafficctl' .config` 把全部相关行打出来。
- **[已解决] CI 守卫的依赖断言曾把正常情况判成失败**（v0.4.7 首次构建，v0.4.8 修）：
  我曾把 `hostapd-utils` 断言为「必须 `=y`」，但上游 `hostapd/Makefile` 里它的
  `DEPENDS` 是 `@` 加 `HOSTAPD_PROVIDERS` 列表 —— **只有选中某个 hostapd/wpad
  变体时该符号才存在**。x86_64 目标无 WiFi 硬件，符号合理地不存在 → 构建失败。
  教训：**断言一个 `CONFIG_PACKAGE_*` 之前，先确认该符号在当前目标上确实存在**；
  硬件相关的包只能「报告状态」，不能「必须 =y」。
- **[已解决] patch 里的伪 mode 变更**（v0.4.8）：regen 脚本在临时目录建 git 仓库，
  而上游 clone 在 Windows 挂载点（`/mnt/c`）被 DrvFs 一律报告为 `0777`，于是
  `git add -A` 记成 `100755`，与应有的索引模式不符（上游权威
  **29 × 100755 + 11 × 100644**），套用时打印
  `warning: xxx has type 100755, expected 100644`。
  处置：regen 以**本仓库 git 索引**为权威模式表，在 `git add` 之前 `os.chmod`。
  排查同类问题的入手点：`grep -h '^old mode\|^new mode' patches/luci-app-trafficctl/*.patch`
  应为空。
- **[已修复] trafficctl 速率恒为 `—`**（v0.4.5）：原 `trafficctl-bytes-nft.sh` 用了
  本内核不支持的 nftables 语法且错误被 `2>/dev/null` 吞掉，只剩空链；
  且只挂 forward 链、看不到 REDIRECT 后的代理流量。
  详见 CHANGELOG v0.4.5 与红线 7/8。
- **[已解决并实测] 所有 Release 曾经都是空的（v0.4.5~v0.4.11，v0.4.12 修）**：
  这个问题有**两个叠加的根因**，互相掩盖，只看最后那句错误提示会一直找错方向：

  1. **`gh` 无法确定仓库** —— `Upload firmware to GitHub Release` 步骤的
     `working-directory` 是**工作区根**，而本工作流把代码签出到
     `openwrt-build/` 与 `lede/` **子目录**，根目录**没有 `.git`**，于是报
     `failed to run git: fatal: not a git repository`。
     而当时的等待循环 `if gh release view … >/dev/null 2>&1; then break; fi`
     把**任何**失败都当成「Release 还没创建」→ 硬错误被吞、白等 60s，
     最后抛出误导性的「Release 不存在（release.yml 未运行？）」。
     **修法**：显式 `GH_REPO: ${{ github.repository }}`；等待循环区分
     「未找到」与硬错误。

  2. **工作流令牌权限不足**（v0.4.12 才找到）—— 修好第 1 条后，上传仍然被拒：
     `HTTP 403: Resource not accessible by integration`。
     原因是本仓库默认工作流令牌权限为 **read**
     （`gh api repos/<o>/<r>/actions/permissions/workflow`
     → `{"default_workflow_permissions":"read"}`），而
     **`build-openwrt.yml` 没有声明 `permissions`**，于是拿不到写权限。
     对照组：`release.yml` 自己声明了 `permissions: contents: write`，
     所以它能建 Release —— **两个工作流的令牌是各自独立申请的**。
     **修法**：`build-openwrt.yml` 顶层加 `permissions: contents: write`。

  另加了**兜底断言**：上传后 Release 上至少要有一个 `.img.gz`，否则 `exit 1`。

  **教训**：
  - `gh` 命令在 CI 里必须能确定仓库（`GH_REPO` 或 `--repo`），
    否则在非 git 目录下必失败。
  - 「等待某资源就绪」的循环不能把**所有**错误都当作「还没好」，
    否则真实错误被静默吞掉，只在最后抛一句与根因无关的提示。
  - 写 Release assets 需要 `permissions: contents: write`；
    仓库默认可能是 read，**不要假设默认够用**。
  - 发版这类动作要加**结果断言**（产物数 ≥ 1），不能只看步骤是否退出 0。
- **[已处理] CI 触发条件**：`on.push` 已加 `paths-ignore`
  （`**.md`/`docs/**`/`.gitignore`/`LICENSE`），纯文档推送不再白跑 3.5 小时。
  依据是 GitHub 官方文档原文 *"Path filters are not evaluated for pushes of tags."*
  —— **只对分支推送生效**，推 tag 仍照常触发，不影响发版。
  改这段属于「出错会静默失效」的一类（例如误把 tags 一起忽略 → 发版永不触发），
  改完必须用 PyYAML 解析 `on:` 块，逐项确认 `branches`/`tags`/`workflow_dispatch`/
  `schedule` 都在，且没有同时声明 `paths` 与 `paths-ignore`（GitHub 不允许共存）。
- **[风险] 上行吞吐无法测量**：本机无可用上传端点（公共镜像 PUT 返回 405，
  且未安装测速工具）。SQM 的上行效果目前只能通过「上行饱和时 ping 抬升」间接验证。
- **[风险] NAT1（fullcone）与软件 flow offloading 的交互无一手来源**：本机实测二者
  已并存生效（`xt_FULLCONENAT` 与 `xt_FLOWOFFLOAD` 同时被引用），但跨流量形态的
  保持情况仍需刷机后实测。

---

## 附：本机排查工具（勿提交）

> **注意**：以下文件当前**不在磁盘上**（除 `rsh.py` 曾被引用外，其余从未纳入版本管理）。
> 表中保留其用途描述，供将来重新创建时参照；对应 `.gitignore` 规则已就位。
> 路由器连接可用 `Y:\openwrt\rt.ps1`（plink，固定 hostkey）作为替代通道。

| 文件 | 用途 |
|---|---|
| `rsh.py` | paramiko SSH 到路由器执行命令（dropbear 兼容、UTF-8 安全）。**内含明文口令** |
| `Test-IPv6Hypothesis.ps1` | 对照实验：开关 IPv6 绑定对比结果（自动还原） |
| `Test-Asymmetry.ps1` | 对比域名地址族选择与实际连通性 |
| `Verify-Fix.ps1` | 修复后回归（DNS 族 / 多站点 / 出口 IP） |
| `backup.sh` `apply-fix.sh` `restart.sh` `final-check.sh` | 备份 / 应用 / 重启 / 复查 |
| `ChatGPT-访问故障-根因与修复报告.md` | 一次真实排障的完整记录（可作方法论参考） |
