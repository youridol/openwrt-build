# CI 流水线

两个工作流：`build-openwrt.yml`（编译 + 上传产物）与 `release.yml`（建 Release）。它们**各自独立申请令牌**，版本号都从 `CHANGELOG.md` 取。

## 1. 触发条件

`build-openwrt.yml:3-28`：

| 触发器 | 条件 | 行号 |
|---|---|---|
| `push` 到 `master` | 分支推送 | `:4-5` |
| `push` tag `v*` | 发版 | `:6-7` |
| `paths-ignore` | `**.md`、`docs/**`、`.gitignore`、`LICENSE` | `:21-25` |
| `workflow_dispatch` | 手动 | `:26` |
| `schedule` | `0 0 * * *`（每日 UTC 零点） | `:27-28` |

`paths-ignore` **只对分支推送生效**，推 tag 仍会触发 —— 这是刻意设计，依据是 GitHub 官方文档原文「Path filters are not evaluated for pushes of tags.」（`:14-17`）。注释还说明了为什么不用 `paths:` 白名单：白名单漏列任何新目录就会静默不构建，黑名单只需列出确定与固件无关的纯文档（`:19-20`）。

`release.yml:3-12`：`push` tag `v*`，或 `workflow_dispatch`（可选手填 `tag` 输入，留空则用 `GITHUB_REF_NAME`）。

## 2. 版本号唯一来源

`CHANGELOG.md` 顶部的 `## [vX.Y.Z]` 是唯一来源。`Resolve version from CHANGELOG` 步骤（`build-openwrt.yml:76-125`）分四步校验：

| # | 校验 | 失败行为 | 行号 |
|---|---|---|---|
| 1 | `grep -m1 '^## \[v' CHANGELOG.md` 必须非空 | 打印「找不到 '## [vX.Y.Z]' 版本标题，构建中止」并 `exit 1` | `:80-85` |
| 2 | 从该行 `sed` 抽出 `v…` 形式版本号 | 抽不出则 `exit 1` | `:87-91` |
| 3 | 版本号必须匹配 `v[0-9]*.[0-9]*.[0-9]*` | 格式异常则 `exit 1` | `:92-98` |
| 4 | **第一条 `## [` 标题必须就是版本标题** | 不等则 `exit 1`，并打印两行内容与修法 | `:107-114` |

第 4 条防的是版本号静默错位：若顶部写成 `## [未发布]`，它不匹配 `[v`，`grep -m1 '^## \[v'` 会跳过它、取到下面那个**旧版本**，产物名变成旧版本号而全程无报错（`:100-106`，v0.9.0 首次构建的实际故障）。

通过后导出三个变量到 `$GITHUB_ENV`：`VERSION`（含 `v`）、`VERSION_NOV`（不含 `v`）、`SHORT_SHA`（`${GITHUB_SHA}` 前 7 位）（`:117-125`）。

## 3. 底座与目标

| 项 | 值 | 行号 |
|---|---|---|
| 上游仓库 | `https://github.com/coolsnowwolf/lede.git` | `:31` |
| 分支 | `master` | `:32` |
| 目标架构 | `x86_64` | `:33` |
| 目标设备 | `CONFIG_TARGET_x86_64_DEVICE_generic=y` | `:640` |
| runner | `ubuntu-22.04` | `:60` |
| 并行度 | `JOBS=2` | `:146-148` |

`JOBS=2` 的理由写在注释里：GHA runner 只有 7GB 内存，Go 编译 Xray 会 OOM（`:147`）。

目标平台不是 `x86_64` 时直接 `exit 1` 并提示「请在此处添加其他目标平台的 base 配置」（`:642-645`）。

## 4. 关键步骤顺序

按工作流里的实际顺序（每步给起始行）：

1. **检出版本仓库**到 `openwrt-build/`（`:63-66`）
2. **解析版本号**（`:76-125`，见 §2）
3. **检出 lede** 到 `lede/`（`:127-132`）
4. **装构建依赖**（`:134-139`）
5. **释放磁盘**（`:141-144`）
6. **设 `JOBS=2`**（`:146-148`）
7. **helloworld feed 判重后追加**（`:150-159`）：先 `grep -q '^src-git helloworld' || echo …`，因为 lede 自 2026 起自带该 feed，直接追加会 `Duplicate feed name 'helloworld'` → `feeds update` exit 25（`:153-155`）
8. **复制 `package/luci-app-trafficctl`**（`:161-164`）
9. **复制 `package/luci-app-dnschain` 并做完整性断言**（`:166-454`）：断言 10 个关键文件存在、`dnschain-health` 有执行位、CSS 双主题令牌、表格滚动容器开闭数量相等且 ≥3、链路图 `viewBox` 容得下最右节点、贝塞尔曲线与箭头数量、`reject` 前置；最后调 `tools/verify-dnschain-domains.sh`（`:445-454`）
10. **拉取并裁剪主题 shadcn**（`:456-518`）：`git clone --depth 1`，只复制 `Makefile root htdocs ucode LICENSE`，断言 4 个关键文件与 `main.css > 20000` 字节
11. **`sh -n` 预检 invariants 脚本**（`:520-536`）：必须先于实际执行，否则 dash 的解析期错误只报一句 `Syntax error: "(" unexpected`，没有断言上下文
12. **跑 trafficctl 不变量**（`:538-556`）：`sh tools/verify-trafficctl-invariants.sh`
13. **拉 dnsproxy 上游并应用 patch**（`:558-593`）：
    - `git clone --depth 1 https://github.com/adm1n5ky/luci-app-dnsproxy.git package/luci-app-dnsproxy`（`:568-569`）
    - 先断言 `patches/luci-app-dnsproxy/*.patch` 非空（`:572-575`）
    - 逐个 patch **先转绝对路径**（`:580`，因为在 `(cd package/…)` 子 shell 里相对路径失效）
    - `git apply --check` 成功才 `git apply`（`:582-586`），**禁止 `|| true`**
    - 打印 `git diff --stat` 与 `diff | head -80` 供日志确认（`:591-593`）
14. **`feeds update -a` + `feeds install -a`**（`:595-599`）
15. **强制各 feed 拉到最新 commit**（`:601-615`）：遍历 `feeds/*/`，有 `.git` 就 `git fetch` + `git reset --hard @{upstream}`，失败再回落到默认分支
16. **对齐 dnsproxy 的 feed 链接**（`:617-631`）：删 `package/feeds/packages/dnsproxy`（旧版 0.56.2），`mkdir -p package/feeds/helloworld` 后 `ln -sfn ../../../feeds/helloworld/dnsproxy package/feeds/helloworld/dnsproxy`（新版 0.83.0）
17. **生成 `.config`（单一配方）**（`:679-689`）：调 `tools/gen-openwrt-config.sh`，由该脚本写入目标三元组、SSR-Plus 全部 INCLUDE、trafficctl / dnschain 及其中文包、主题、DNS、SQM、依赖与排除项，中间 `make defconfig` 两次。逐项见 §4.1。
18. **校验 SQM / i18n / 排除项**（`:691-878`，见 §5.2）
19. **复制 overlay 并补执行位**（`:880-912`）
20. **校验 mosdns 模板契约**（`:914-951`）
21. **校验 dnschain 契约**（`:953-1268`）
22. **校验无嵌套 table 的 nft 片段**（`:1270-1318`）
23. **校验 SSR-Plus uci-defaults 顺序契约**（`:1320-1391`）
24. **算缓存指纹**（`:1399-1421`）：`tools/lede-fingerprint.sh` 输出 `TOOLCHAIN_FP` / `HOST_FP`，见 §8.2
25. **归一源码 mtime**（`:1423-1438`）：`tools/normalize-mtime.sh`，工具链缓存能否被复用全看这一步，见 §8.3
26. **恢复 dl 镜像**（`:1440-1474`）：`tools/cache-release.sh restore … 'dl.*'` + `dir-mirror.sh unpack`；退出码 10 视为「首次运行」
27. **恢复工具链缓存**（`:1476-1545`）：按指纹取 `toolchain-*` / `host-*` 资产，解包后过 `tools/verify-toolchain-cache.sh`，再复核 stamp 是否比源码新；任一不满足即回退完整编译
28. **下载软件包源码**（`:1547-1620`）：设 `DOWNLOAD_MIRROR` 与 `CURL_OPTIONS --max-time 300`，调 `tools/make-download.sh`（内含硬超时 + 哈希不一致自愈）
29. **用 gcc-13 预编译 gn**（`:1622-1647`）：装 `gcc-13 g++-13`，`make tools/ninja/compile`，再 `CC=gcc-13 CXX=g++-13 make package/feeds/helloworld/gn/host/compile`
30. **编译**（`:1649-1654`）：`make -j${{ env.JOBS }} V=s`
31. **产物重命名**（`:1667-1714`）：`openwrt-x86-64-<generic>…` → `openwrt-x86-64-ssrplus-<VERSION>-<SHA>-<后缀>`，同时生成 `.sha256`，并断言新名含版本号且以 `.img.gz` 结尾
32. **上传 artifact**（`:1716-1729`）
33. **断言 artifact 真实存在**（`:1731-1759`）：查 Actions API，最多 6 次、每次等 5 秒
34. **回写 dl 镜像（尽力而为）**（`:1761-1795`）：`continue-on-error: true`，构建成功后把本轮补齐的 `dl/` 覆盖缓存，见 §8.5
35. **tag 构建时上传到 Release**（`:1797-1881`）：仅 `startsWith(github.ref, 'refs/tags/')`

### 4.1 `.config` 里被显式 `=y` 的符号

配方自 v0.17.0 起集中在 `tools/gen-openwrt-config.sh`（预热与构建共用同一份），
下表行号均指该文件。

| 分组 | 符号 | 行号 |
|---|---|---|
| 目标 | `CONFIG_TARGET_x86=y` / `_x86_64=y` / `_x86_64_DEVICE_generic=y` | `:47-49` |
| SSR-Plus | `CONFIG_PACKAGE_luci-app-ssr-plus=y` | `:66` |
| | `…_INCLUDE_Iptables_Transparent_Proxy=y` | `:67` |
| | `…_INCLUDE_Nftables_Transparent_Proxy` **is not set** | `:68` |
| | `…_INCLUDE_Xray=y` | `:69` |
| | `…_INCLUDE_ChinaDNS_NG=y` | `:70` |
| | `…_INCLUDE_MosDNS=y` | `:71` |
| | `…_INCLUDE_Shadow_TLS=y` | `:72` |
| | `…_INCLUDE_Kcptun=y` | `:73` |
| | `…_INCLUDE_NaiveProxy=y` | `:74` |
| | `…_INCLUDE_Shadowsocks_Simple_Obfs=y` | `:75` |
| | `…_INCLUDE_Shadowsocks_V2ray_Plugin=y` | `:76` |
| | `…_INCLUDE_ShadowsocksR_Libev_Client=y` | `:77` |
| | `…_INCLUDE_ShadowsocksR_Libev_Server=y` | `:78` |
| trafficctl | `CONFIG_PACKAGE_luci-app-trafficctl=y` | `:89` |
| | `CONFIG_PACKAGE_luci-i18n-trafficctl-zh-cn=y` | `:90` |
| dnschain | `CONFIG_PACKAGE_luci-app-dnschain=y` | `:95` |
| | `CONFIG_PACKAGE_luci-i18n-dnschain-zh-cn=y` | `:96` |
| | `CONFIG_PACKAGE_chinadns-ng=y`（**框架已不依赖**，见 §7.1） | `:105` |
| 主题 | `CONFIG_PACKAGE_luci-theme-shadcn=y` | `:127` |
| | `# CONFIG_PACKAGE_luci-theme-{material,openwrt,openwrt-2020,argon,design} is not set`（循环内） | `:129-131` |
| DNS | `CONFIG_PACKAGE_dnsproxy=y` | `:135` |
| | `CONFIG_PACKAGE_luci-app-dnsproxy=y` | `:136` |
| | `CONFIG_PACKAGE_ca-bundle=y` | `:137` |
| | `CONFIG_PACKAGE_ca-certificates=y` | `:138` |
| 游戏 | `CONFIG_PACKAGE_kmod-tcp-bbr=y` | `:142` |
| | `CONFIG_PACKAGE_iptables-mod-fullconenat=y` | `:144` |
| SQM | `CONFIG_PACKAGE_sqm-scripts=y` | `:151` |
| | `CONFIG_PACKAGE_luci-app-sqm=y` | `:152` |
| | `CONFIG_PACKAGE_kmod-sched-cake=y` | `:153` |
| | `CONFIG_PACKAGE_kmod-ifb=y` | `:154` |
| | `CONFIG_PACKAGE_kmod-sched-core=y` | `:155` |
| | `CONFIG_PACKAGE_tc-tiny=y` | `:156` |
| trafficctl 依赖 | `CONFIG_PACKAGE_iw=y` | `:174` |
| | `CONFIG_PACKAGE_conntrack=y` | `:175` |
| 排除 | `# CONFIG_PACKAGE_{vsftpd,luci-app-vsftpd,luci-i18n-vsftpd-zh-cn,ksmbd-server,luci-app-ksmbd,luci-i18n-ksmbd-zh-cn,autosamba} is not set` | `:181-187` |

脚本开头先 `make defconfig`（`:55`）建立目标三元组，写完全部符号后再 `make defconfig`
（`:189`），因为 defconfig 会按依赖解析重算所有符号。

**为什么抽成脚本而不是留在 YAML 里**：`.config` 决定 `make download` 要下哪些源码包。
预热 job（`cache-deps.yml`）与构建 job 若各写一份配方必然漂移，后果是
「预热以为不用某包 → 镜像里永远没有 → 每次构建回落到慢速第三方源」这种长期隐性失效。
脚本拒绝在 `.config` 已存在时运行，避免重复追加。

写完全部符号后再 `make defconfig`（`:189`），因为 defconfig 会按依赖解析重算所有符号。

### 4.2 为什么不能关掉 bootstrap

`build-openwrt.yml:814-825` 记录了完整理由：lede 的 `collections/luci/Makefile` 里 `LUCI_DEPENDS` **硬依赖** `+luci-theme-bootstrap`，写 `is not set` 会被下一次 `make defconfig` 的依赖求解再次选回 `=y`，于是「bootstrap 必须关闭」的断言必然失败（run 39549176947 就是这样挂的）。正确做法是保留 bootstrap 但切换默认主题，代价约 300KB，换来可回退。

### 4.3 `iw` / `conntrack` 为什么必须显式写

trafficctl 1.21.4 的 `LUCI_DEPENDS` 含 `+iw` 与 `+conntrack`。本仓库已从 Makefile 去掉 `+hostapd-utils`（它在 x86_64 无 WiFi 时永远不可满足，会让整包与中文包一起从 `.config` 消失），但 `iw`/`conntrack` 真实存在且可用，显式声明可避免「依赖靠自动解析、顺序一变就丢」（`build-openwrt.yml:714-738`）。

## 5. 每个契约校验步骤的断言清单

### 5.1 `Add luci-app-dnschain` 步骤内的断言（`:172-501`）

| 断言 | 行号 |
|---|---|
| 包目录存在，否则 `exit 1` | `:179-182` |
| 10 个关键文件逐个存在：`Makefile`、`luasrc/controller/dnschain.lua`、`luasrc/model/cbi/dnschain/{general,dnschain,diagrams}.lua`、`htdocs/…/dnschain.css`、`…/dnschain.js`、`menu.d/luci-app-dnschain.json`、`acl.d/luci-app-dnschain.json`、`po/zh-cn/luci-app-dnschain.po` | `:188-204` |
| 运行时组件 `files/usr/bin/dnschain-health`、`files/usr/bin/dnschain-triage`、`files/usr/share/dnschain/dnschain.sh` 存在 | `:218-227` |
| `dnschain-health` / `dnschain-triage` 有执行位 | `:231-239` |
| CSS 含 `data-darkmode="true"` | `:248-254` |
| `--dc-ok`/`--dc-warn`/`--dc-bad`/`--dc-info` 各定义 ≥2 次（浅色+暗色） | `:257-263` |
| CSS 与 JS 各自 > 500 字节 | `:266-273` |
| CSS 含 `cbi-tabmenu:not(:has(` | `:284-290` |
| JS 含 `dropEmptyTabmenu` | `:292-297` |
| CSS 含 `data-dc-meta` 收拢规则 | `:300-306` |
| `.dc-chain svg` 不得写死 `max-width` | `:316-323` |
| CSS 含 `dc-table-wrap` | `:325-329` |
| CSS 含 `dc-chain svg` 与 `min-width` | `:331-336` |
| CSS 含 `cbi-value:has(> .cbi-value-field > .dc-chain)` | `:343-349` |
| `dc-metrics`/`dc-table-wrap`/`dc-stats`/`dc-badge`/`dc-alert` 五类都纳入竖排规则 | `:351-357` |
| JS 含 `markBlockRows` | `:359-365` |
| `dc-block-row` 在 CSS 与 JS 都有 | `:367-372` |
| 表格滚动容器开闭数量相等且 ≥3 | `:380-389` |
| `viewBox` 宽度 > 最右节点右边缘（`X4 + NW + GAP + NW`） | `:394-409` |
| 链路图用贝塞尔 `C` 指令 | `:418-424` |
| `general.lua` / `diagrams.lua` 内联链路图不得有箭头（`marker-end` / `<marker>`） | `:438-458` |
| 图身份用 `data-dc-figure` 标记 | `:460-464` |
| 曲线控制点有交叉保护 `math.floor((x2 - x1) / 2)` | `:466-471` |
| 节点填充 `fill="var(--dc-surface)"` | `:473-479` |
| `sh tools/verify-dnschain-domains.sh` 必须通过（129 条） | `:491-498` |

### 5.2 `Verify SQM / i18n enabled and file services excluded`（`:691-879`）

| 断言 | 行号 |
|---|---|
| `sqm-scripts`、`kmod-sched-cake`、`kmod-ifb`、`kmod-sched-core`、`tc-tiny` 全部 `=y` | `:697-707` |
| `luci-app-sqm` 缺失**只告警不阻断** | `:709-712` |
| `iw`、`conntrack` 必须 `=y` | `:719-727` |
| 反向断言：`LUCI_DEPENDS` 不得含 `hostapd-utils` | `:728-738` |
| `luci-app-trafficctl` 与 `luci-i18n-trafficctl-zh-cn` 必须 `=y`；失败时打印全部 `trafficctl` 相关行与 hostapd/wpad 变体行 | `:750-773` |
| `luci-app-dnschain` 与 `luci-i18n-dnschain-zh-cn` 必须 `=y`；失败时打印全部 `dnschain` 相关行 | `:786-802` |
| `vsftpd`、`ksmbd-server`、`autosamba` 必须**不**为 `=y` | `:804-812` |
| `luci-theme-shadcn` 必须 `=y`；非默认主题（material/openwrt/openwrt-2020/argon/design）不得 `=y` | `:826-851` |
| `99-zzz-luci-theme-shadcn` 存在、含 `luci.main.mediaurlbase`、排序晚于 `30_luci-theme-shadcn` | `:853-878` |

### 5.3 `Verify mosdns template contract`（`:917-955`）

| 断言 | 行号 |
|---|---|
| 文件 `files/etc/ssrplus/mosdns-config.yaml` 存在 | `:927-928` |
| 第 14 行**必须**是 `        upstreams:`（8 空格缩进） | `:930-937` |
| `exec: reject 0` 与 `exec: $forward_google` 都存在 | `:939-944` |
| `reject` 行号必须**小于** `forward` 行号 | `:945-949` |
| `DNS_MODE` 与 `DNS_PORT` 占位符存在 | `:951-953` |

### 5.4 `Verify dnschain framework contracts`（`:956-1275`）

| # | 断言 | 行号 |
|---|---|---|
| 0 | 8 个文件存在（`dnschain.sh`、`init.d/dnschain`、`config/dnschain`、`reconcile`、`selftest`、`health`、`triage`、`99-zz-dnschain`） | `:969-981` |
| 1 | 7 个 shell 文件 `sh -n` 通过（dash 解析） | `:987-1000` |
| 2a | 剥注释后不得含进程替换 `<(` / `>(` | `:1018-1023` |
| 2b | 不得含 `[[ `（判据是「`[[` 后紧跟空白」，避免误伤 `[[:space:]]`） | `:1025-1036` |
| 2c | 不得含 bash 数组赋值 `name=(` | `:1038-1042` |
| 2d | 不得含作为命令的 `(( `（排除 `$((`） | `:1044-1050` |
| 3 | 库脚本不得生成 `--cache`、`--fallback`、`--ipv6-disabled` | `:1054-1069` |
| 4 | 库脚本不得定义 `dc_gen_filter_args`（chinadns-ng 已移除） | `:1071-1082` |
| 4b | 库脚本**必须**有 `dc_gen_foreign_args` | `:1084-1090` |
| 4c | 不得生成 `[/域名/]` 形式 | `:1092-1100` |
| 5 | 不得出现明文 `114.114.114.114` | `:1102-1108` |
| 6 | 不得过滤 `xn--` | `:1110-1121` |
| 7 | init 脚本不得含 `table ` 声明（裸 chain 契约） | `:1123-1129` |
| 8 | `99-zz-dnschain` 必须晚于 `99-gaming-optimize` | `:1131-1142` |
| 9 | 配置含 `entry_port '5353'`、`foreign_port '5336'`、`foreign 'keep'`、`domestic 'keep'`、`require_ipv6 '1'`、`filter_https_rr '0'` | `:1144-1161` |
| 9b | 国外上游必须是 `https://dns.google/dns-query`，且不得有 `tls://8.8.8.8` | `:1163-1175` |
| 10 | `files/etc/config/dnsproxy` 的 `cache.enabled` 为 `0`、无 `list fallback`、`ipv6_disabled '0'` | `:1177-1207` |
| 11 | `applechina.conf`：`server=` 恰好 173 条、明文 0 条、指向 `127.0.0.1#5353` 恰好 173 条 | `:1209-1233` |
| 12 | init 脚本含 `priority -151` 至少 1 处 | `:1235-1243` |
| 13 | `init.d/dnsproxy` 含 `dnschain_takes_over` | `:1245-1252` |
| 14 | 两份 ADR 文档在 `../openwrt-build/docs/adr/` 下存在 | `:1254-1266` |
| — | 任一 `rc=1` 则 `exit 1` | `:1268-1272` |

### 5.5 `Verify no nested-table nft fragments`（`:1276-1325`）

| 断言 | 行号 |
|---|---|
| `files/etc/nftables.d/*.nft` 每个文件都不得含 `^\s*table\s` | `:1294-1306` |
| 所有提到 `nftables.d` 的 `files/` 下脚本（跳过 `*.md`）也不得含 `^\s*table\s` | `:1307-1318` |
| 任一命中即 `exit 1` | `:1319-1322` |

### 5.6 `Verify SSR-Plus uci-defaults ordering contract`（`:1326-1408`）

| # | 断言 | 行号 |
|---|---|---|
| 0 | 文件 `files/etc/uci-defaults/99-gaming-optimize` 存在 | `:1335-1336` |
| 1 | 含 `[ ! -s /etc/config/shadowsocksr ]` 守卫（空配置先铺底） | `:1338-1346` |
| 2 | 守卫里调用 `/etc/init.d/shadowsocksr reset` | `:1348-1353` |
| 3 | `uci -q get shadowsocksr.@global[0]` 守卫至少 1 处，且 `uci set shadowsocksr.@global[0]` 至少 1 处 | `:1355-1370` |
| 3b | 最后一处守卫之后必须还有写入 | `:1371-1378` |
| 4 | 不得有「未接失败日志的裸 `uci set`」 | `:1380-1388` |
| 5 | 含 `/etc/nftables.d/10-mss-clamp.nft` 字符串 | `:1390-1396` |

### 5.7 `Rename firmware with version` 内的断言（`:1693-1741`）

| 断言 | 行号 |
|---|---|
| 至少有一个 `.img.gz`，否则 `exit 1` | `:1699`、`:1703`、`:1723` |
| 产物名含目标名与类型分隔符（`rest` 含 `-`） | `:1711-1714` |
| 每个产物名都含 `${VERSION}` | `:1731-1734` |
| 每个产物名都以 `.img.gz` 结尾 | `:1735-1738` |

### 5.8 `Upload artifacts` 与 `Assert firmware artifact exists`

- `if-no-files-found: error`（`:1752`）。默认值是 `warn`，语义是「没匹配到文件也照样成功」，会出现「构建显示成功、Actions 上却没有产物」（`:1747-1751`）。
- 上传 `*.img.gz` 与 `*.img.gz.sha256`（`:1753-1755`）。
- `Assert firmware artifact exists`（`:1766-1794`）用 `gh api repos/$GH_REPO/actions/runs/$RUN_ID/artifacts --jq '.total_count'` 计数，最多 6 次、每次 5 秒（`:1776-1782`），`< 1` 即 `exit 1`（`:1788-1793`）。

### 5.9 `Upload firmware to GitHub Release`（仅 tag，`:1833-1917`）

| 断言 / 行为 | 行号 |
|---|---|
| 显式设 `GH_REPO`（工作区根没有 `.git`，不设会 `fatal: not a git repository`） | `:1837-1850` |
| `gh release view` 失败必须区分「尚未创建」与硬错误；后者立刻 `exit 1` | `:1863-1881` |
| 60 秒内未就绪则 `gh release create` 兜底 | `:1883-1887` |
| 已存在的同名 asset 跳过，其余 `gh release upload --clobber` | `:1893-1905` |
| 兜底断言：Release 上至少 1 个 `.img.gz`，否则 `exit 1` | `:1910-1915` |
## 6. `release.yml`

| 步骤 | 行为 | 行号 |
|---|---|---|
| 确定 `VER` | 手动输入的 `tag` 优先，否则 `GITHUB_REF_NAME` | `:39-45` |
| 定位版本段 | `grep -nF "## [$VER]" CHANGELOG.md \| head -1 \| cut -d: -f1` | `:49` |
| 兼容无 `v` 前缀 | `VER` 不带 `v` 时再试 `## [v$VER]` | `:51-53` |
| 找不到 | 打印「CHANGELOG.md 中找不到版本 [$VER] 的日志段，中止发布」并 `exit 1` | `:54-57` |
| 版本段结束位置 | 从 `start+1` 起找下一个 `^## \[`；找不到则到文件末尾 | `:60-65` |
| 抽取 notes | `sed -n "$((start+1)),${end}p"`，再用 `perl` 裁掉首尾空行 | `:68-70` |
| 建或更新 Release | 已存在 → `gh release edit --notes-file`；否则 `gh release create --notes-file` | `:85-93` |
| 权限 | `permissions: contents: write`（`build-openwrt.yml` 也各自声明，两个工作流的令牌**独立**） | `:15-16`；对比 `build-openwrt.yml:49-62` |

固件**不在**这个工作流上传 —— 由 `build-openwrt.yml` 的最后一步在 tag 构建时上传（`build-openwrt.yml:1833-1917`）。两边靠 tag 名对齐。

## 7. 已知问题

### 7.1 `chinadns-ng` 同时「必须有」和「不再要求」

- `tools/gen-openwrt-config.sh:105`：`echo "CONFIG_PACKAGE_chinadns-ng=y"`，注释已更正为「由 SSR-Plus 的 INCLUDE 带入，显式再声明一次；v0.10.0 起 dnschain 框架已不再依赖它」。
- `build-openwrt.yml:782-785`：「v0.10.0：不再要求 `CONFIG_PACKAGE_chinadns-ng`。框架已移除该组件（`-t` 不支持 DoH，而落地节点到 853 不通）」。
- 同文件 `:1077-1082` 断言库脚本**不得**定义 `dc_gen_filter_args`。

即 `.config` 里仍会带该包，但框架已不依赖它（保留是因为 SSR-Plus 侧仍会用到）。它不会导致构建失败（SSR-Plus 的 `INCLUDE_ChinaDNS_NG=y` 本来就带入）。

### 7.2 MSS clamp 断言是假通过

- `build-openwrt.yml:1391-1396` 断言 `99-gaming-optimize` 里含字符串 `/etc/nftables.d/10-mss-clamp.nft`。
- 该字符串在文件里**只出现在注释**：`files/etc/uci-defaults/99-gaming-optimize` 的注释段（「后来改为写 `/etc/nftables.d/10-mss-clamp.nft`（fw4 时代）。**两个版本都已删除**」）。
- 该段代码已被完整删除，理由是功能冗余 + fw3 路径死代码 + fw4 路径曾造成断网。
- 因此这条断言校验的不是「生成逻辑存在」，而是「解释删除原因的注释里提到了这个路径」——**注释被删就会红，逻辑被加回来也不会红**。它不能证明任何东西。

### 7.3 文档存在性检查必须带 `../openwrt-build/` 前缀

- `build-openwrt.yml:1254-1266` 的 `working-directory` 是 `lede`（`:957`），而 `docs/` 在**仓库根**（与 `lede` 同级）。
- 直接写 `docs/adr/...` 会指到 `lede/docs/` —— 那是 lede 源码自带的目录，里面没有本仓库的 ADR（`:1254-1266`，v0.9.0 首次构建因此失败）。
- 正确写法是 `[ -f "../openwrt-build/$doc" ]`（`:1260`）。
- 同一模式还出现在 `:491-495`（`../openwrt-build/tools/verify-dnschain-domains.sh`）、`:1260`。

### 7.4 本次核对新发现

- **`:486` 的断言条数已过期**：`build-openwrt.yml:486` 的注释写「断言较多（88 条）」，而 `tools/verify-dnschain-domains.sh` 现在输出 **129 条 OK**（见 `docs/operations/verification.md` §1.1）。
- **CI 不跑四个本地校验脚本**：`tools/check-dnschain-lua.py`、`tools/render-dnschain-diagrams.py`、`tools/extract-dnschain-i18n.py`、`tools/check-trafficctl-i18n.py` 在全仓库 `.yml` 里零引用（`grep -n "check-dnschain\|render-dnschain\|extract-dnschain\|check-trafficctl\|firmware-artifact\|ci-sim" .github/workflows/build-openwrt.yml` 无输出）。CI 只跑 `verify-dnschain-domains.sh`（`:495`）与 `verify-trafficctl-invariants.sh`（`:602`）。这四个脚本的结论在 CI 里没有任何强制力。
- **`verify-firmware-artifact.sh` 也未接入 CI**：它是刷机前的本地预检，需要解包后的目录参数（`tools/verify-firmware-artifact.sh:29-33`），CI 里没有产物解包步骤。
- **`:647-662` 的 `git reset --hard @{upstream}` 失败被 `|| true` 吞掉**：`(cd "$f" && git fetch origin && git reset --hard @{upstream}) || (…default_branch…) || true`，即所有 feed 都更新失败时该步骤仍返回 0。这与红线 3「禁止静默失败」的口径不一致（对比 `:695`、`:737` 明确写「不使用 `|| true`」）。实际影响有限：feed 更新失败不改变「用的是哪个 commit」这件事的可观测性，但会让「强制拉到最新」这个承诺无法验证。
- **`build-openwrt.yml` 与 `release.yml` 对 `CHANGELOG` 顶部格式的容忍度不同**：`build-openwrt.yml:88-95` 要求第一条 `## [` 必须是版本标题，`release.yml` 没有这条检查（只在 `:49` 用 `grep -nF` 找目标版本）。因此 `release.yml` 在顶部写 `## [未发布]` 时仍能正常发版，而 `build-openwrt.yml` 会拒绝构建 —— 两者的前置条件不一致。

---

## 8. 构建缓存（dl 镜像 + 工具链）

### 8.0 实测效果（2026-10-24，同一提交的三次构建）

| 步骤 | 无缓存<br>`40069703261` | 仅 dl 缓存<br>`40076999673` | dl + 工具链缓存<br>`40083472916` |
|---|---|---|---|
| `Restore dl` | 1s（未命中） | 33s（下载 1.35 GB） | 74s（下载 1.35 GB） |
| `Restore toolchain` | 0s（未命中） | 1s（未命中） | **50s（下载 780 MB + 325 MB）** |
| `Download package sources` | **1323s（22 分 03 秒）** | **56s** | **46s** |
| `Prebuild gn host tool` | 685s | 496s | 600s |
| `Compile firmware` | 10241s | 7817s | （该 run 卡在 upx，已取消） |
| **job 总时长** | **3h31m** | **2h27m** | — |

**核心收益**：`Download package sources` 从 **22 分钟降到 46-56 秒**，
即原先「每次全新克隆都要重抓上千个 tarball」的开销被消除。
job 总时长从 3h31m 降到 2h27m（省 1h04m）。

注意 `Restore dl` 自己也要花 33-74 秒下载 1.35 GB —— 这笔开销远小于它省下的 22 分钟。
只有当 `dl/` 已经基本齐全时（例如本地有持久化缓存）才不需要它。

**`Restore toolchain` 的 0s / 1s 是「未命中」的可靠信号**：命中时必然有下载动作，
耗时不可能是 0 秒。反过来，若某次命中却只花 1 秒，说明资产根本没被下载到
（应检查 `cache-release.sh restore` 的 pattern 是否匹配）。

### 8.1 为什么不能用 `actions/cache`

| 维度 | `actions/cache` | Release 资产（本项目采用） |
|---|---|---|
| 单仓库总量 | 10 GB，超出按最后访问时间淘汰 | **无总量上限** |
| 过期 | **一周未被访问即删除** | 只有手动/脚本删除 |
| 单文件大小 | 需先打成单个 tar | 2 GB（故分片 1900 MB） |
| 下载路径 | GitHub 缓存服务 | GitHub CDN，**流量不出 GitHub** |
| 版本控制 | 只能靠 key 前缀模糊匹配 | 资产名 + `*.meta`，可精确校验 |

本项目的 `dl/` 是 GB 级（内核 + gcc + 各包 tarball），且构建**不是每天都跑**。
放 `actions/cache` 既装不下、又会被「一周未访问」淘汰 —— 缓存永远命中不了。
Release 资产两个问题都没有，代价是需要自己管分片与清理。

存放位置：tag `cache-build-v1` 的 Release（见 `build-openwrt.yml` 的 `env.CACHE_TAG`）。
刻意用 `cache-` 前缀而**不是** `v*`：两个工作流的 tag 触发都是 `v*`，
用 `v` 前缀会让「刷新缓存」误触发一次 3.5 小时的固件构建。

### 8.2 工具链指纹为什么用内容哈希，不用 git commit

`tools/lede-fingerprint.sh` 输出两个 64 位十六进制指纹：

| 指纹 | 覆盖内容 | 命中时省下 |
|---|---|---|
| `TOOLCHAIN_FP` | `toolchain/`、`target/linux/generic/`、`include/{toolchain,host-build,download,unpack}.mk` 的**文件内容**，加 `.config` 里编译器/libc/binutils/架构相关符号 | 约 30-45 分钟的交叉工具链编译 |
| `HOST_FP` | `tools/`、`include/{host-build,download,unpack,depends}.mk` 的文件内容，加同一份 `.config` 切片 | 约 40 多个宿主工具的编译 |

用 commit 做键会失效：lede master 每天都有提交（多在 feeds / target 其它地方），
缓存几乎永不命中。而工具链只由上面这些**内容**决定。

**不能用 `git log -1 -- <path>` 代替**：`actions/checkout` 默认 `fetch-depth: 1`，
浅克隆上若 HEAD 未触及该路径会返回**空**，于是「空 == 空」把所有版本都判成命中
—— 这是「静默用旧工具链」的最坏形态。内容哈希与克隆深度无关。

`.config` 只取切片而非整份：加一个普通包（如 `luci-app-xxx`）不应让工具链缓存失效。

### 8.3 mtime 归一 —— 工具链缓存能否被复用全看这一步

`tools/normalize-mtime.sh` 把源码树 mtime 固定为 `2000-01-01 00:00:00`。

必须做的原因（读 `scripts/timestamp.pl` 源码确认）：

- stampfile 规则调用 `timestamp.pl -n <stamp> <路径> <依赖stamp>`。
  对 `-n` 的处理是 **peek 而不 shift**（`elsif ($path =~ /^-n/) { my $arg = $ARGV[0]; $options{$path}=$arg; }`），
  所以 `<stamp>` 自己也在后续路径列表里被 stat 一次。
- 最终判据是「这批路径里 mtime 最大的那个是不是 `<stamp>` 自己」。
- 而 CI 每次都是**全新 git clone**，checkout 把所有源码 mtime 写成「现在」
  → 缓存里那份旧 stamp 必然更旧 → 工具链被判过期 → 完整重编。
- 同理 `host-build.mk` 的 stamp 名里含 `find_md5`（`find … -printf "%p%T@\n"` 也算 mtime），
  mtime 每次不同 → stamp 文件名每次都不同 → 宿主工具也必然重编。

**预热 job 与构建 job 必须用同一份归一规则**，否则两边的 `find_md5` 不同，缓存照样不命中。
两个工作流都调用同一个脚本。

排除目录：`.git`、`dl`、`build_dir`、`staging_dir`、`bin`、`tmp`、`logs`。
其中 `staging_dir`/`build_dir` 必须排除 —— 里面的 stamp 要保留真实 mtime 才会被判「比源码新」。

### 8.4 缓存不可用时的行为

两个恢复步骤都把「没有缓存」与「缓存坏了」分开处理：

| 退出码 | 含义 | 处理 |
|---|---|---|
| `0` | 命中 | 解包后继续 |
| `10` | 缓存不存在（首次运行/被清理） | 正常回退，**不算失败** |
| 其它 | 真的出错（权限、网络、资产损坏） | `exit 1` |

工具链解包后还要过两道校验，任一不过就**删掉解包结果、回退完整编译**：

1. `tools/verify-toolchain-cache.sh`：交叉 gcc 存在且 `--version` 能跑、
   **能真的编译并链接一个最小 C 程序**、`.gcc_final_installed` 与
   `.tools_compile*` 两个 stamp 都在、`staging_dir/host/bin` 文件数 ≥ 10。
   只检查文件存在是抓不到「二进制在但依赖的 .so 缺失」的。
2. 复核 `toolchain/` 里没有比 `.toolchain_compile` stamp 更新的文件
   （mtime 归一漏了目录时，这里会失败并打印是哪几个文件）。

### 8.5 `dl/` 的双写：定时预热 + 构建后回写

`dl/` 镜像有两个写入者，缺一不可：

| 写入者 | 时机 | 作用 |
|---|---|---|
| `cache-deps.yml` 的 `warm-dl` | 每天 UTC 20:00（北京时间 04:00） | 从零补齐所有源码包 |
| `build-openwrt.yml` 的 `Refresh dl mirror cache` | 每次**成功**构建后 | 补上「预热之后、构建之前」上游新 bump 的版本 |

只靠定时预热的话，上游在两次预热之间换掉的 tarball 永远补不进镜像，
表现为每次构建都在 dl 里缺同一个包、每次回落到慢速源。
构建后回写这一步是 `continue-on-error: true`：缓存是加速手段不是交付物，
它坏了不该让一次成功的固件构建变红。

### 8.6 哈希不一致的自愈（`tools/make-download.sh`）

`scripts/download.pl` 在本地文件哈希不符时是 **`die`**，不是重新下载：

```perl
if ($sum eq $file_hash) { cleanup(); exit 0; }
die "Hash of the local file $filename does not match ..."
```

长期缓存 `dl/` 之后这不是理论风险 —— 上游重打包但文件名不变时必然发生，
且**每次构建都会在同一处硬失败**。脚本从日志里精确取出不匹配的文件名、
逐个删除（打印文件名）、然后重试，最多 3 轮。删除前校验文件名不含路径分隔符，
避免文件名注入导致误删。

同时脚本外层套 `timeout 3000`：2026-10-21 的 run `39495602665` 曾在
`make download` 卡了 5h54m（nasm 从 `www.nasm.us` 以 556 B/s 下载），
直到 job 的 6h 上限被取消。

### 8.7 清理策略：不自动删

Release 资产**不会**过期，工具链每换一次指纹就多一份 GB 级资产。
但 `prune` 阶段刻意**只报告占用、不自动删除**：

指纹是内容哈希，一旦某次编译失败或配置回退，被删掉的旧指纹缓存**再也拿不回来**
（Release 资产删除不可恢复）。而保留的成本只是磁盘配额 —— Release 没有总量上限。

需要瘦身时手动执行：

```sh
gh release delete-asset cache-build-v1 <资产名> --yes   # 删单个
sh tools/cache-release.sh purge cache-build-v1          # 整体删除（下次构建会重新预热）
```

---

## 9. `cache-deps.yml`

### 9.1 触发条件

| 触发 | 条件 | 说明 |
|---|---|---|
| `schedule` | `0 20 * * *`（UTC） | 刻意排在 `build-openwrt.yml` 的 `0 0 * * *` **之前**，让那边用上刚刷新的缓存 |
| `workflow_dispatch` | 可选 `skip_dl` / `skip_toolchain` | 改了 `.config` 配方后必须手动跑一次，否则新加的源码包不会进镜像 |
| `push` | `master` + 5 个 `tools/*` 与自身路径 | 白名单：只关心「决定下载什么/编译什么」的输入，改 LuCI 页面不会白跑 40 分钟 |

### 9.2 三个 job

| job | 产出 | 超时 |
|---|---|---|
| `warm-dl` | `dl` 分片 + `dl.meta` | 180 分钟 |
| `warm-toolchain` | `toolchain-<FP>` / `host-<FP>` 分片 + meta，并输出 `toolchain_fp` / `host_fp` | 240 分钟 |
| `prune` | 只报告资产占用（见 §8.7） | — |

`warm-dl` 与 `warm-toolchain` **并行**（互不依赖），总时长是 `max` 而不是相加。

`warm-toolchain` 只编 `make tools/compile` + `make toolchain/compile`，**不出固件**，
并断言 `staging_dir/toolchain-*/bin` 里真有交叉 gcc（否则缓存的是空目录）。

**刻意不缓存** `build_dir/target-*`：包编译的中间产物与 `.config` 强耦合、体积大，
真正贵的是工具链本身。

### 9.3 并发创建的竞态

`warm-dl` 与 `warm-toolchain` 首次运行时会同时发现缓存 Release 不存在并同时创建，
后到的那次以 `already exists` 失败。故 `ensure_release` 不把创建失败当致命错误，
而是重新检查一次状态：已存在即视为另一路建好的，直接继续。

### 9.4 分片格式与一致性提交点

`tools/dir-mirror.sh` 打包：`tar -C <root> -cf - <paths> | <zstd|gzip> -o <name>.tar.<ext>`，
再 `split -b 1900M -d -a 2`。**流式管道，不落中间 tar** —— runner 磁盘有限。

`<name>.meta` 记录 `FORMAT/NAME/COMPRESS/PARTS/FILES/ARCHIVE_BYTES`。
解包时校验分片数与 meta 一致，不符即拒绝解包（镜像不完整时宁可失败，不要解出半个树）。

`cache-release.sh save` 的顺序是 **分片 → 清理同 NAME 的陈旧分片 → 最后传 meta**。
meta 是一致性提交点：只要它还没更新，读者看到的就还是旧的一致状态。

清理**只删同一 `NAME`** 的资产 —— 按「凡是不在本目录里的就删」会把同一个 Release 里
别的缓存种类（`toolchain-*` / `host-*`）一起删掉。

### 9.5 本地验证这些脚本

```sh
dash -n tools/*.sh                                   # POSIX 语法
python3 tools/verify-workflow-scripts.py             # 抽出所有 run: 块交给 dash -n
```

`verify-workflow-scripts.py` 存在的理由：YAML 能解析 ≠ shell 能解析。
本仓库最贵的一类失败就是「bash 专有语法写进 CI 脚本，dash 解析期 exit 2，
一步未执行、编译全 skipped、没有任何产物」。

---

## 10. 首次上线的真实故障（2026-10-24）

记录在这里是因为它们**都通过了本地静态检查**，只在真跑时暴露。
本地 `dash -n` + YAML 解析 + 单元测试全绿，仍然出现下面三个问题。

### 10.1 `dir-mirror.sh` 在部分路径缺失时静默退出

**现象**：`warm-toolchain` 停在 `Pack toolchain and host tools`，退出码 1，
但日志里**没有任何错误信息**（工具链那包已成功打出 817 MB，之后就没输出了）。

**根因**：`cmd_pack` 在 `set -eu` 下做

```sh
matches=$(cd "$SRC" && for m in $p; do [ -e "$m" ] && printf '%s\n' "$m"; done)
```

命令替换的退出码 = 替换里**最后一条命令**的退出码。当某个 path 参数的 glob
没匹配到时，`[ -e ]` 返回 1 → 整个赋值返回 1 → `set -e` 让脚本**静默退出**，
连 `die` 都来不及打印。

**为什么必然触发**：`staging_dir/hostpkg` 只在包构建（`IS_PACKAGE_BUILD`）时产生
（`rules.mk:195-197`），而 `warm-toolchain` 只跑 `make tools/compile` +
`make toolchain/compile`，不会创建它。所以这不是偶发。

**修法**：命令替换用显式 `exit 0` 收尾保证恒返回 0；`pack` 容忍「部分路径缺失」
（只打包存在的那几个），仅在一个都不存在时才 `die`。同时把
`cache-release.sh` 与 `cache-deps.yml` 里同形态的 `[ -f ] && continue` /
`[ -e ] && cp` 一律改成 `if`。

**教训**：`set -e` + 命令替换 + 循环体末尾的条件判断是危险组合。
写这类代码时要么显式 `exit 0` 收尾，要么把条件判断写成 `if`。

### 10.2 表格滚动容器断言误报

**现象**：构建停在 `Add luci-app-dnschain`，报
`FAIL 表格滚动容器数量不对：开 6 / 闭 7`。

**根因**：断言里「开」的判据要求 wrapper 与 table **紧邻**
（`grep -c 'dc-table-wrap"><table class="dc-table'`），
而 v0.16.3 给分诊表格加了额外属性：

```lua
'<div class="dc-table-wrap" data-dc-triage="1"><table class="dc-table">'
```

于是它匹配不到「开」，却仍被「闭」的判据数进去 → 6 vs 7。
真实表格数是 7 开 7 闭，页面本身没有问题。

**修法**：判据放宽到只认 `dc-table-wrap"` 前缀。真正要守的性质是
「开闭必须相等且 >= 3」，加什么属性都不该影响它；真有表格漏套 wrapper 时，
开闭数量仍会不等而报错。

### 10.3 runner 侧偶发卡死（非本项目问题）

`40083472916` 在 `Compile firmware` 阶段卡在 upx 编译（51%），
日志最大时间戳与 `run.updatedAt` 都停在 2.5 小时前，已取消。
同一提交的 `40076999673` 已 success，说明不是代码问题。

**识别方法**：看 `run.updatedAt` 与日志最大时间戳。
两者都长期不动 = 真卡住；只有日志不动但 `updatedAt` 在变 = 仍在推进。

**注意**：不要用「日志最后一行的时间戳」判断，日志行不是严格按时间排序的
（同一次运行的日志里，upx 的 51% 行可能排在后续行之前）。要取**最大**时间戳。
