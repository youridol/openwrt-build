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
17. **生成 base `.config`**（`:633-646`）：写三个 `CONFIG_TARGET_*`，再 `make defconfig`
18. **启用所需包**（`:648-771`，逐项见 §4.1）
19. **校验 SQM / i18n / 排除项**（`:773-960`，见 §5.2）
20. **复制 overlay 并补执行位**（`:962-994`）
21. **校验 mosdns 模板契约**（`:996-1033`）
22. **校验 dnschain 契约**（`:1035-1350`）
23. **校验无嵌套 table 的 nft 片段**（`:1352-1400`）
24. **校验 SSR-Plus uci-defaults 顺序契约**（`:1402-1473`）
25. **下载软件包源码**（`:1475-1544`）：设 `DOWNLOAD_MIRROR` 与 `CURL_OPTIONS --max-time 300`，外层再套 `timeout 3000`，防单个慢源拖死整个 job
26. **用 gcc-13 预编译 gn**（`:1546-1571`）：装 `gcc-13 g++-13`，`make tools/ninja/compile`，再 `CC=gcc-13 CXX=g++-13 make package/feeds/helloworld/gn/host/compile`
27. **编译**（`:1573-1578`）：`make -j${{ env.JOBS }} V=s`
28. **产物重命名**（`:1591-1638`）：`openwrt-x86-64-<generic>…` → `openwrt-x86-64-ssrplus-<VERSION>-<SHA>-<后缀>`，同时生成 `.sha256`，并断言新名含版本号且以 `.img.gz` 结尾
29. **上传 artifact**（`:1640-1653`）
30. **断言 artifact 真实存在**（`:1664-1692`）：查 Actions API，最多 6 次、每次等 5 秒
31. **tag 构建时上传到 Release**（`:1699-1783`）：仅 `startsWith(github.ref, 'refs/tags/')`

### 4.1 `.config` 里被显式 `=y` 的符号

| 分组 | 符号 | 行号 |
|---|---|---|
| SSR-Plus | `CONFIG_PACKAGE_luci-app-ssr-plus=y` | `:652` |
| | `…_INCLUDE_Iptables_Transparent_Proxy=y` | `:653` |
| | `…_INCLUDE_Nftables_Transparent_Proxy` **is not set** | `:654` |
| | `…_INCLUDE_Xray=y` | `:655` |
| | `…_INCLUDE_ChinaDNS_NG=y` | `:656` |
| | `…_INCLUDE_MosDNS=y` | `:657` |
| | `…_INCLUDE_Shadow_TLS=y` | `:658` |
| | `…_INCLUDE_Kcptun=y` | `:659` |
| | `…_INCLUDE_NaiveProxy=y` | `:660` |
| | `…_INCLUDE_Shadowsocks_Simple_Obfs=y` | `:661` |
| | `…_INCLUDE_Shadowsocks_V2ray_Plugin=y` | `:662` |
| | `…_INCLUDE_ShadowsocksR_Libev_Client=y` | `:663` |
| | `…_INCLUDE_ShadowsocksR_Libev_Server=y` | `:664` |
| trafficctl | `CONFIG_PACKAGE_luci-app-trafficctl=y` | `:675` |
| | `CONFIG_PACKAGE_luci-i18n-trafficctl-zh-cn=y` | `:676` |
| dnschain | `CONFIG_PACKAGE_luci-app-dnschain=y` | `:681` |
| | `CONFIG_PACKAGE_luci-i18n-dnschain-zh-cn=y` | `:682` |
| | `CONFIG_PACKAGE_chinadns-ng=y`（**与后文自相矛盾**，见 §6.1） | `:687` |
| 主题 | `CONFIG_PACKAGE_luci-theme-shadcn=y` | `:709` |
| | `# CONFIG_PACKAGE_luci-theme-{material,openwrt,openwrt-2020,argon,design} is not set` | `:711-713` |
| DNS | `CONFIG_PACKAGE_dnsproxy=y` | `:717` |
| | `CONFIG_PACKAGE_luci-app-dnsproxy=y` | `:718` |
| | `CONFIG_PACKAGE_ca-bundle=y` | `:719` |
| | `CONFIG_PACKAGE_ca-certificates=y` | `:720` |
| 游戏 | `CONFIG_PACKAGE_kmod-tcp-bbr=y` | `:724` |
| | `CONFIG_PACKAGE_iptables-mod-fullconenat=y` | `:726` |
| SQM | `CONFIG_PACKAGE_sqm-scripts=y` | `:733` |
| | `CONFIG_PACKAGE_luci-app-sqm=y` | `:734` |
| | `CONFIG_PACKAGE_kmod-sched-cake=y` | `:735` |
| | `CONFIG_PACKAGE_kmod-ifb=y` | `:736` |
| | `CONFIG_PACKAGE_kmod-sched-core=y` | `:737` |
| | `CONFIG_PACKAGE_tc-tiny=y` | `:738` |
| trafficctl 依赖 | `CONFIG_PACKAGE_iw=y` | `:756` |
| | `CONFIG_PACKAGE_conntrack=y` | `:757` |
| 排除 | `# CONFIG_PACKAGE_{vsftpd,luci-app-vsftpd,luci-i18n-vsftpd-zh-cn,ksmbd-server,luci-app-ksmbd,luci-i18n-ksmbd-zh-cn,autosamba} is not set` | `:763-769` |

写完全部符号后再 `make defconfig`（`:771`），因为 defconfig 会按依赖解析重算所有符号。

### 4.2 为什么不能关掉 bootstrap

`build-openwrt.yml:697-708` 记录了完整理由：lede 的 `collections/luci/Makefile` 里 `LUCI_DEPENDS` **硬依赖** `+luci-theme-bootstrap`，写 `is not set` 会被下一次 `make defconfig` 的依赖求解再次选回 `=y`，于是「bootstrap 必须关闭」的断言必然失败（run 39549176947 就是这样挂的）。正确做法是保留 bootstrap 但切换默认主题，代价约 300KB，换来可回退。

### 4.3 `iw` / `conntrack` 为什么必须显式写

trafficctl 1.21.4 的 `LUCI_DEPENDS` 含 `+iw` 与 `+conntrack`。本仓库已从 Makefile 去掉 `+hostapd-utils`（它在 x86_64 无 WiFi 时永远不可满足，会让整包与中文包一起从 `.config` 消失），但 `iw`/`conntrack` 真实存在且可用，显式声明可避免「依赖靠自动解析、顺序一变就丢」（`build-openwrt.yml:740-757`）。

## 5. 每个契约校验步骤的断言清单

### 5.1 `Add luci-app-dnschain` 步骤内的断言（`:181-454`）

| 断言 | 行号 |
|---|---|
| 包目录存在，否则 `exit 1` | `:173-176` |
| 10 个关键文件逐个存在：`Makefile`、`luasrc/controller/dnschain.lua`、`luasrc/model/cbi/dnschain/{general,dnschain,diagrams}.lua`、`htdocs/…/dnschain.css`、`…/dnschain.js`、`menu.d/luci-app-dnschain.json`、`acl.d/luci-app-dnschain.json`、`po/zh-cn/luci-app-dnschain.po` | `:182-198` |
| 运行时组件 `files/usr/bin/dnschain-health`、`files/usr/share/dnschain/dnschain.sh` 存在 | `:207-215` |
| `dnschain-health` 有执行位 | `:219-226` |
| CSS 含 `data-darkmode="true"` | `:238-243` |
| `--dc-ok`/`--dc-warn`/`--dc-bad`/`--dc-info` 各定义 ≥2 次（浅色+暗色） | `:245-253` |
| CSS 与 JS 各自 > 500 字节 | `:255-263` |
| CSS 含 `cbi-tabmenu:not(:has(` | `:274-279` |
| JS 含 `dropEmptyTabmenu` | `:281-286` |
| CSS 含 `data-dc-meta` 收拢规则 | `:290-295` |
| `.dc-chain svg` 不得写死 `max-width` | `:306-311` |
| CSS 含 `dc-table-wrap` | `:313-318` |
| CSS 含 `dc-chain svg` 与 `min-width` | `:320-325` |
| CSS 含 `cbi-value:has(> .cbi-value-field > .dc-chain)` | `:333-338` |
| `dc-metrics`/`dc-table-wrap`/`dc-stats`/`dc-badge`/`dc-alert` 五类都纳入竖排规则 | `:340-347` |
| JS 含 `markBlockRows` | `:349-354` |
| `dc-block-row` 在 CSS 与 JS 都有 | `:356-361` |
| 表格滚动容器开闭数量相等且 ≥3 | `:369-377` |
| `viewBox` 宽度 > 最右节点右边缘（`X4 + NW + GAP + NW`） | `:382-397` |
| 链路图用贝塞尔 `C` 指令 | `:407-412` |
| 箭头 `marker("dc-a-` 至少 3 个 | `:414-420` |
| 曲线控制点有交叉保护 `math.floor((x2 - x1) / 2)` | `:422-427` |
| 节点填充 `fill="var(--dc-surface)"` | `:430-435` |
| `sh tools/verify-dnschain-domains.sh` 必须通过（129 条） | `:445-454` |

### 5.2 `Verify SQM / i18n enabled and file services excluded`（`:773-960`）

| 断言 | 行号 |
|---|---|
| `sqm-scripts`、`kmod-sched-cake`、`kmod-ifb`、`kmod-sched-core`、`tc-tiny` 全部 `=y` | `:779-789` |
| `luci-app-sqm` 缺失**只告警不阻断** | `:791-794` |
| `iw`、`conntrack` 必须 `=y` | `:801-809` |
| 反向断言：`LUCI_DEPENDS` 不得含 `hostapd-utils` | `:812-820` |
| `luci-app-trafficctl` 与 `luci-i18n-trafficctl-zh-cn` 必须 `=y`；失败时打印全部 `trafficctl` 相关行与 hostapd/wpad 变体行 | `:832-855` |
| `luci-app-dnschain` 与 `luci-i18n-dnschain-zh-cn` 必须 `=y`；失败时打印全部 `dnschain` 相关行 | `:868-884` |
| `vsftpd`、`ksmbd-server`、`autosamba` 必须**不**为 `=y` | `:886-894` |
| `luci-theme-shadcn` 必须 `=y` | `:909-914` |
| `luci-theme-bootstrap` **仅报告不判失败** | `:916-918` |
| 其余五个非默认主题必须关闭 | `:920-925` |
| 主题脚本 `99-zzz-luci-theme-shadcn` 存在且含 `luci.main.mediaurlbase` | `:939-947` |
| 排序断言：`99-zzz-luci-theme-shadcn` 晚于 `30_luci-theme-shadcn` | `:948-956` |

### 5.3 `Verify mosdns template contract`（`:996-1033`）

| 断言 | 行号 |
|---|---|
| 文件存在 | `:1006-1007` |
| 第 14 行**必须**是 `        upstreams:`（8 空格缩进） | `:1009-1016` |
| `exec: reject 0` 与 `exec: $forward_google` 都存在 | `:1018-1023` |
| `reject` 行号必须**小于** `forward` 行号 | `:1024-1028` |
| `DNS_MODE` 与 `DNS_PORT` 占位符存在 | `:1030-1032` |

### 5.4 `Verify dnschain framework contracts`（`:1035-1350`）

| # | 断言 | 行号 |
|---|---|---|
| 0 | 7 个文件存在（`dnschain.sh`、`init.d/dnschain`、`config/dnschain`、`reconcile`、`selftest`、`health`、`99-zz-dnschain`） | `:1048-1059` |
| 1 | 6 个 shell 文件 `sh -n` 通过（dash 解析） | `:1065-1077` |
| 2a | 剥注释后不得含进程替换 `<(` / `>(` | `:1095-1099` |
| 2b | 不得含 `[[ `（判据是「`[[` 后紧跟空白」，避免误伤 `[[:space:]]`） | `:1108-1112` |
| 2c | 不得含 bash 数组赋值 `name=(` | `:1115-1118` |
| 2d | 不得含作为命令的 `(( `（排除 `$((`） | `:1122-1126` |
| 3 | 库脚本不得生成 `--cache`、`--fallback`、`--ipv6-disabled` | `:1133-1145` |
| 4 | 库脚本不得定义 `dc_gen_filter_args`（chinadns-ng 已移除） | `:1153-1158` |
| 4b | 库脚本**必须**有 `dc_gen_foreign_args` | `:1161-1166` |
| 4c | 不得生成 `[/域名/]` 形式 | `:1171-1176` |
| 5 | 不得出现明文 `114.114.114.114` | `:1179-1184` |
| 6 | 不得过滤 `xn--` | `:1192-1197` |
| 7 | init 脚本不得含 `table ` 声明（裸 chain 契约） | `:1200-1205` |
| 8 | `99-zz-dnschain` 必须晚于 `99-gaming-optimize` | `:1212-1218` |
| 9 | 配置含 `entry_port '5353'`、`foreign_port '5336'`、`foreign 'keep'`、`domestic 'keep'`、`require_ipv6 '1'`、`filter_https_rr '0'` | `:1228-1237` |
| 9b | 国外上游必须是 `https://dns.google/dns-query`，且不得有 `tls://8.8.8.8` | `:1240-1251` |
| 10 | `files/etc/config/dnsproxy` 的 `cache.enabled` 为 `0`、无 `list fallback`、`ipv6_disabled '0'` | `:1258-1283` |
| 11 | `applechina.conf`：`server=` 恰好 173 条、明文 0 条、指向 `127.0.0.1#5353` 恰好 173 条 | `:1288-1309` |
| 12 | init 脚本含 `priority -151` 至少 1 处 | `:1313-1319` |
| 13 | `init.d/dnsproxy` 含 `dnschain_takes_over` | `:1323-1328` |
| 14 | 两份 ADR 文档在 `../openwrt-build/docs/adr/` 下存在 | `:1335-1342` |
| — | 任一 `rc=1` 则 `exit 1` | `:1344-1348` |

### 5.5 `Verify no nested-table nft fragments`（`:1352-1400`）

| 断言 | 行号 |
|---|---|
| `files/etc/nftables.d/*.nft` 每个文件都不得含 `^\s*table\s` | `:1372-1382` |
| 所有提到 `nftables.d` 的 `files/` 下脚本（跳过 `*.md`）也不得含 `^\s*table\s` | `:1385-1394` |
| 任一命中即 `exit 1` | `:1395-1398` |

### 5.6 `Verify SSR-Plus uci-defaults ordering contract`（`:1402-1473`）

| # | 断言 | 行号 |
|---|---|---|
| 0 | 文件存在 | `:1411-1412` |
| 1 | 含 `[ ! -s /etc/config/shadowsocksr ]` 守卫（空配置先铺底） | `:1415-1422` |
| 2 | 守卫里调用 `/etc/init.d/shadowsocksr reset` | `:1425-1429` |
| 3 | `uci -q get shadowsocksr.@global[0]` 守卫至少 1 处，且 `uci set shadowsocksr.@global[0]` 至少 1 处 | `:1436-1446` |
| 3b | 最后一处守卫之后必须还有写入 | `:1448-1454` |
| 4 | 不得有「未接失败日志的裸 `uci set`」 | `:1459-1464` |
| 5 | 含 `/etc/nftables.d/10-mss-clamp.nft` 字符串 | `:1467-1472` |

### 5.7 `Rename firmware with version` 内的断言（`:1591-1638`）

| 断言 | 行号 |
|---|---|
| 至少有一个 `.img.gz`，否则 `exit 1` | `:1600-1601`、`:1621` |
| 产物名含目标名与类型分隔符（`rest` 含 `-`） | `:1609-1612` |
| 每个产物名都含 `${VERSION}` | `:1627-1632` |
| 每个产物名都以 `.img.gz` 结尾 | `:1633-1636` |

### 5.8 `Upload artifacts` 与 `Assert firmware artifact exists`

- `if-no-files-found: error`（`:1650`）。默认值是 `warn`，语义是「没匹配到文件也照样成功」，会出现「构建显示成功、Actions 上却没有产物」（`:1645-1649`）。
- 上传 `*.img.gz` 与 `*.img.gz.sha256`（`:1651-1653`）。
- `Assert firmware artifact exists` 用 `gh api repos/$GH_REPO/actions/runs/$RUN_ID/artifacts --jq '.total_count'` 计数，最多 6 次、每次 5 秒，`< 1` 即 `exit 1`（`:1674-1691`）。

### 5.9 `Upload firmware to GitHub Release`（仅 tag）

| 断言 / 行为 | 行号 |
|---|---|
| 显式设 `GH_REPO`（工作区根没有 `.git`，不设会 `fatal: not a git repository`） | `:1701-1716` |
| `gh release view` 失败必须区分「尚未创建」与硬错误；后者立刻 `exit 1` | `:1729-1747` |
| 60 秒内未就绪则 `gh release create` 兜底 | `:1749-1753` |
| 已存在的同名 asset 跳过，其余 `gh release upload --clobber` | `:1759-1771` |
| 兜底断言：Release 上至少 1 个 `.img.gz`，否则 `exit 1` | `:1776-1781` |

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
| 权限 | `permissions: contents: write`（`build-openwrt.yml` 也各自声明，两个工作流的令牌**独立**） | `:15-16`；对比 `build-openwrt.yml:36-45` |

固件**不在**这个工作流上传 —— 由 `build-openwrt.yml` 的最后一步在 tag 构建时上传（`build-openwrt.yml:1699-1783`）。两边靠 tag 名对齐。

## 7. 已知问题

### 7.1 `chinadns-ng` 同时「必须有」和「不再要求」

- `build-openwrt.yml:684-687`：`echo "CONFIG_PACKAGE_chinadns-ng=y"`，注释称「dnschain 运行时依赖：chinadns-ng 由 SSR-Plus 的 INCLUDE_ChinaDNS_NG 带入；这里显式再声明一次」。
- 同文件 `:864-870`：「v0.10.0：不再要求 `CONFIG_PACKAGE_chinadns-ng`。框架已移除该组件（`-t` 不支持 DoH，而落地节点到 853 不通）」。
- 同文件 `:1153-1158` 断言库脚本**不得**定义 `dc_gen_filter_args`。

即 `.config` 里仍会带该包，但框架已不依赖它；`:687` 的注释与实现意图相反。它不会导致构建失败（SSR-Plus 的 `INCLUDE_ChinaDNS_NG=y` 本来就带入），但会误导读者以为框架依赖它。

### 7.2 MSS clamp 断言是假通过

- `build-openwrt.yml:1467-1472` 断言 `99-gaming-optimize` 里含字符串 `/etc/nftables.d/10-mss-clamp.nft`。
- 该字符串在文件里**只出现在注释**：`files/etc/uci-defaults/99-gaming-optimize:122`（「后来改为写 `/etc/nftables.d/10-mss-clamp.nft`（fw4 时代）。**两个版本都已删除**」）。
- 该段代码已被完整删除（`:118-152` 全是说明），理由是功能冗余 + fw3 路径死代码 + fw4 路径曾造成断网（`:124-151`）。
- 因此这条断言校验的不是「生成逻辑存在」，而是「解释删除原因的注释里提到了这个路径」——**注释被删就会红，逻辑被加回来也不会红**。它不能证明任何东西。

### 7.3 文档存在性检查必须带 `../openwrt-build/` 前缀

- `build-openwrt.yml:1330-1342` 的 `working-directory` 是 `lede`（`:1036`），而 `docs/` 在**仓库根**（与 `lede` 同级）。
- 直接写 `docs/adr/...` 会指到 `lede/docs/` —— 那是 lede 源码自带的目录，里面没有本仓库的 ADR（`:1331-1334`，v0.9.0 首次构建因此失败）。
- 正确写法是 `[ -f "../openwrt-build/$doc" ]`（`:1336`）。
- 同一模式还出现在 `:445-449`（`../openwrt-build/tools/verify-dnschain-domains.sh`）、`:812-816`、`:939`、`:967-968`。

### 7.4 本次核对新发现

- **`:440` 的断言条数已过期**：注释写「断言较多（88 条）」，实际 `tools/verify-dnschain-domains.sh` 现在输出 **129 条 OK**（本次实跑，见 `docs/operations/verification.md` §1.1）。
- **CI 不跑四个本地校验脚本**：`tools/check-dnschain-lua.py`、`tools/render-dnschain-diagrams.py`、`tools/extract-dnschain-i18n.py`、`tools/check-trafficctl-i18n.py` 在全仓库 `.yml` 里零引用（`grep -n "check-dnschain\|render-dnschain\|extract-dnschain\|check-trafficctl\|firmware-artifact\|ci-sim" .github/workflows/build-openwrt.yml` 无输出）。CI 只跑 `verify-dnschain-domains.sh`（`:449`）与 `verify-trafficctl-invariants.sh`（`:556`）。这四个脚本的结论在 CI 里没有任何强制力。
- **`verify-firmware-artifact.sh` 也未接入 CI**：它是刷机前的本地预检，需要解包后的目录参数（`tools/verify-firmware-artifact.sh:29-33`），CI 里没有产物解包步骤。
- **`:601-613` 的 `git reset --hard @{upstream}` 失败被 `|| true` 吞掉**：`(cd "$f" && git fetch origin && git reset --hard @{upstream}) || (…default_branch…) || true`，即所有 feed 都更新失败时该步骤仍返回 0。这与红线 3「禁止静默失败」的口径不一致（对比 `:977`、`:985` 明确写「不使用 `|| true`」）。实际影响有限：feed 更新失败不改变「用的是哪个 commit」这件事的可观测性，但会让「强制拉到最新」这个承诺无法验证。
- **`build-openwrt.yml` 与 `release.yml` 对 `CHANGELOG` 顶部格式的容忍度不同**：`build-openwrt.yml:107-114` 要求第一条 `## [` 必须是版本标题，`release.yml` 没有这条检查（只在 `:49` 用 `grep -nF` 找目标版本）。因此 `release.yml` 在顶部写 `## [未发布]` 时仍能正常发版，而 `build-openwrt.yml` 会拒绝构建 —— 两者的前置条件不一致。
