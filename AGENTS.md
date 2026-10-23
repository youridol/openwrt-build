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
| `tools/verify-dnschain-domains.sh` | 域名归属与自动改道的 126 条契约断言（CI 与本地同一份） | 直接用 |
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
   改完 `package/` 下任何文件后**必须**跑
   `python3 tools/regen-trafficctl-patches.py <上游包目录>` 重算 patch，
   否则 CI 的 `Verify luci-app-trafficctl local invariants` 会 `exit 1`。
   升级上游用 `sh tools/sync-trafficctl.sh <tag>`。

   **六项本地改动必须保留**（被覆盖会静默失效，界面不报错、构建也成功）：
   ① `trafficctl-bytes-nft.sh` 重写（丢掉 → 速率列恒 `—`）；
   ② `Makefile` 去掉 `+hostapd-utils`（丢掉 → 整包被 kconfig 丢弃、界面变英文）；
   ③ `status.js`/`status.css`/`menu.d`/`config`/`rpcd` 的刷新与 tab 改动；
   ④ `po/zh-cn/*.po`（丢掉 → 中文界面变英文）；
   ⑤ `host.js` + `trafficctl-device.sh` 主机连接详情页；
   ⑥ `settings.js` + `common.js` 设置独立 tab。

   **每条的具体易错点、实测数据与断言位置见
   [`patches/luci-app-trafficctl/README.md`](patches/luci-app-trafficctl/README.md)
   的「本地改动清单」一节** —— 那是本条的完整版，改 trafficctl 前必读。

   ⚠️ `package/luci-app-trafficctl/README.md` 是**上游原文**，其中有 5 处指向
   上游仓库 `docs/API.md` 等文件的链接在本仓库不存在（上游包里不带这些文档）。
   这**不是**本仓库的断链，**不要改它** —— 改了会让 patch 重放与上游不一致。
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
> 落地校验：`sh tools/verify-dnschain-domains.sh`（126 条断言，CI 会跑）。

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
sh tools/verify-dnschain-domains.sh          # 126 条契约断言
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

**只列真正未决的。已解决的历史条目见本节末尾的归档说明。**

- **[待批准] dnsmasq 日志与 Apple 域名的明文 DNS**（审计 §10 D13/D17）：
  两项都**不能用 overlay 硬覆盖**，生成路径已查明：
  - `log-facility=/dev/null` 由 LEDE 上游 `zzz-default-settings` 每次构建
    `sed -i '/log-facility/d'` 再 `echo` 写入 → overlay 会被再追加一行。
    正确做法是 UCI `dhcp.@dnsmasq[0].logfacility`（init 脚本转命令行参数，优先于 conf-file）。
  - `applechina.conf` 的 173 条明文 `114.114.114.114` 由
    `/etc/init.d/shadowsocksr` 处理。**陷阱**：把 `apple_dns` 设成 `127.0.0.1#5353`
    **不幂等** —— `old_appledns` 用 `grep -oE` 抽 IP、丢掉端口，二次启动叠成
    `127.0.0.1#5353#5353`。推荐 overlay 该文件且**不设** `apple_dns`。
  - `whitelist_forward.conf` 已不是问题（当前 6 行、fw4 正确写法）。
  改动属「修改 DNS 配置」，**须先申请批准**。详见
  `docs/audit/2026-10-09-network-audit.md` 末尾「2026-10-10 复核」。

- **[风险] 上行吞吐无法测量**：本机无可用上传端点（公共镜像 PUT 返回 405），
  trafficctl 的上行速率列只能靠 conntrack 字节差，冷启动首帧为 `—`。

- **[风险] NAT1（fullcone）与软件 flow offloading 的交互无一手来源**：
  本机实测二者同时开启时 fullcone 仍生效，但上游未文档化该组合，升级后需复测。

- **[约束] `mosdns-config.yaml` 的 `upstreams:` 必须留在第 14 行**
  （init 脚本用 `awk -v line=14` 注入上游）→ 说明性注释只能写在末尾，
  顶部不得增删任何行。该文件现由 `files/etc/ssrplus/` overlay 提供。

### 已归档的历史条目

以下条目曾在此节，均已解决，细节见 `CHANGELOG.md` 对应版本段：

| 条目 | 解决版本 |
|---|---|
| `filter_aaaa` 语义冲突 | v0.4.0（后被 v0.10.0 反转，见 §5） |
| 本机排查脚本防误提交 | `.gitignore` + `.gitattributes` |
| `v0.3.5` 无 tag | 仅本地标签现状，不影响代码 |
| mosdns 模板 `reject` 前置 | v0.4.0 |
| `rps_flow_cnt` 清零点 | 确认为 `packet-steering.uc`；需非零时设 `network.globals.steering_flows` |
| trafficctl vendored 维护 / patch 生成器 / 速率恒 `—` / 上游依赖拖累 / CI 守卫误判 / 伪 mode 变更 | v0.4.5~v0.4.9，见红线 9 与 `patches/luci-app-trafficctl/README.md` |
| 所有 Release 曾经都是空的 | v0.4.12 |
| CI 触发条件 | `on.push.paths-ignore` |

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
