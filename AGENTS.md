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
| `tools/verify-dnschain-domains.sh` | 域名归属与分流规则的 204 条契约断言（CI 与本地同一份；§12 是性能不变量，§15 是自动补全） | 直接用 |
| `tools/check-dnschain-lua.py` | 用 lupa（真实 Lua）跑语法 + 模型 + **真实渲染页面每个 `cfgvalue()`** | 直接用 |
| `tools/render-dnschain-diagrams.py` | 两张思维导图的纯几何校验 + 输出可打开的 HTML 预览 | 直接用 |
| `tools/extract-dnschain-i18n.py` | 提取 `translate()` 中文并比对 PO（`--write` 追加缺失） | 直接用 |
| `patches/luci-app-dnsproxy/*.patch` | 上游 `adm1n5ky/luci-app-dnsproxy` 的**改动以 patch 形式**维护 | **禁止**改上游；只改 patch |
| `files/` | rootfs overlay（`files/etc/...` 合并进固件），**不是**上游源码 | 直接改 |
| `CHANGELOG.md` | 变更的唯一权威记录；版本判型 PATCH/MINOR/MAJOR | 每次功能改动必须追加 |
| `.gitattributes` | 强制关键文件 LF 行尾 —— **极其重要，见红线 1** | 按需扩规则 |
| `patches/luci-app-dnsproxy/README.md` | patch 维护规范（单一职责/最小修改/幂等） | — |
| `docs/` | 分层文档。**入口 `docs/README.md`（按任务找文档）；`docs/routes.md` 是全部 LuCI 路由的唯一登记处**。其余：`docs/packages/`（每个 LuCI 包）、`docs/runtime/`（DNS 分流与 overlay 清单）、`docs/build/ci.md`、`docs/operations/verification.md`、`docs/adr/`（架构决定） | 改代码后按 `docs/README.md` §5 联动更新 |
| `GLOSSARY.md` | 易混术语（归属/首选/当前、分流、nftset、fallback…），每条带代码落点 | 新增术语时同步 |

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
> **运行时的实际形态见 [`docs/runtime/dns-chain.md`](docs/runtime/dns-chain.md)（按代码取证，逐条带行号）。**
>
> 该 ADR 定义了取代上述现状的 DNS 分流框架：**dnsmasq 唯一缓存 + 唯一分流层，
> dnsproxy 两个不带缓存的实例（`:5353` 国内 / `:5336` 国外）**。
> ⚠️ ADR-0003 正文写于 v0.9.x，其中「框架自持 chinadns-ng 策略过滤器」
> 已被 v0.10.0 推翻（见 `docs/adr/0005-remove-chinadns-ng.md`）；
> ADR-0003 顶部 §0 有「已失效断言」对照表，引用前先看那张表。
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
> 🚨 **v0.22.0 变更：`dnschain-health` 与 `dnschain-triage` 已删除**
> （分诊 1710 行 + 健康改道 448 行）。理由：用户要求「直连不通自动改走代理」，
> 这由 `dnsproxy --fallback`（`:5353` → `:5336`）在上游层完成，不需要应用层
> 探测判定。而且 `watch.servers` 与 `dnschain-split.conf` 是两套并存的
> `server=` 源，同域名两处都有规则时 dnsmasq 当**候选**而非覆盖 ——
> 实测 `www.wikipedia.org` 因此拿到污染答案 `31.13.106.4`，
> 而两条 dnsproxy 链本身都返回正确的 `103.102.166.224`。
> 详见 `CHANGELOG.md` v0.22.0 与下方 §4.0「分流语义」。
>
> **但「代码在仓库」≠「现网已切换」**：需刷机后按 ADR-0004 逐项验证。
> 判断现网是否已切换，看三样：
> ```sh
> netstat -lnup | grep -E ':(5335|5353|5336)'
>   # :5353 与 :5336 各应有一个 dnsproxy；:5335 应**无**监听（chinadns-ng 已移除）
> uci -q get shadowsocksr.@global[0].pdnsd_enable   # 0 = 交给框架；4 = MosDNS
> /usr/bin/dnschain-selftest                        # 20 项（18/19 已改为「通道已清理」检查）
> ```
>
> 该 ADR 取代了两份已撤回的文档（`0003-dns-chain-architecture.md`、
> `0004-dns-chain-framework.md`），撤回原因见其 §15。撤回的核心教训：
> 那两份都写「已实测」，但仓库里没有对应代码（`--upstream <path>` 的生成器
> 从未存在），且是孤岛文档（除彼此外全仓库零引用）——**引用 ADR 前先确认
> 其结论在代码里有支撑**。

### 4.0 ⚠️ `dnschain` 框架的硬约束

> **全表 64 条在 [`docs/runtime/constraints.md`](docs/runtime/constraints.md) —— 改这一块之前必读，本文件不再重复。**

v0.10.0 起 `chinadns-ng` 已移除（`docs/adr/0005-remove-chinadns-ng.md`），改为
「双 dnsproxy 实例 + dnsmasq 分流」：

```
dnsmasq:53（唯一缓存 + 唯一分流层）
  ├─ 默认              → 127.0.0.1#5353  dnsproxy 实例 1（国内 DoT/DoH，直连）
  ├─ server=/国外域名/ → 127.0.0.1#5336  dnsproxy 实例 2（DoH，经 :1234）
  └─ nftset=/国外域名/4#inet#ss_spec#blacklist   解析结果写入代理 IP 集
```

**最容易踩的 8 条**（完整 64 条见 `docs/runtime/constraints.md`）：

| # | 约束 | 违反的后果 |
|---|---|---|
| 1 | **缓存只在 dnsmasq 一层** | 同一域名两份答案（实测经 `:53` 与直连 `:5353` 返回不同 IP） |
| 2 | **国外上游必须 DoH（443），不能 DoT（853）** | 落地节点到 853 全部 `peer sent close notify` → 国外域名全无结果 |
| 3 | **分流只能由 dnsmasq 的 `server=/域名/` 承担，不能用 dnsproxy 的 `[/域名/]`** | dnsproxy 为每域名注册一条 reserved 上游 → 资源耗尽 → `connection timed out` |
| 8 | **`init.d/dnsproxy` 必须保留 `dnschain_takes_over` 让位逻辑** | 两个 procd 实例抢 `:5353`，后起的静默失败 |
| 12 | **`dnsmasq.filter_aaaa` 必须为 0** | 连国内 AAAA 一起砍（v0.10.0 起国外 AAAA 保留，见 §5.1） |
| 17 | ~~`dhcp.@dnsmasq[0].serversfile` 必须下发~~ **v0.22.0 起该通道已删除**：改由 `dnsproxy --fallback` 承担「直连不通改走代理」。`serversfile` 若有残留会被 `init.d/dnschain` 的 `clear_serversfile` 清掉 | 残留会让 dnsmasq 读不存在的文件并刷日志；若文件里还有旧规则，会与 `split.conf` 冲突并把正确分流覆盖成错误的 |
| 33 | **清缓存/发 SIGHUP 必须用 `dc_dnsmasq_pid`（按 `:53` socket 反查），不得用 `pidof` 第一个** | 第一个 PID 是 ujail 辅助子进程，SIGHUP 是**空操作** → 按钮点了完全无效，页面却报成功 |
| 41 | **一次配置应用只能重启 dnsmasq 一次**（标记文件 `/var/run/dnschain/.dnsmasq-dirty`） | 原调用链重启 3 次，一次保存断 9 秒以上 |

**v0.22.0 起的分流语义**：客户机所有流量**先走直连**（`:5353`），
直连上游不可用时由 `dnsproxy --fallback 127.0.0.1:5336` **自动改走代理**。
不再有应用层的探测、判定、改道 —— 那套机制（`dc_health_cycle` +
`watch.servers`）已整体删除。

⚠️ `--fallback` 的地址格式必须是 `127.0.0.1:5336`（**冒号**），
不能写 dnsmasq 的 `127.0.0.1#5336`。实测写成 `#` 时 dnsproxy
直接拒绝启动，进程退出后端口无人监听、客户机全部无法解析。

⚠️ `--fallback` 只在「上游不可用」时触发，**不判断答案是否被污染**。
所以 gfw 名单仍必须保留（显式写 `server=/域名/#5336`）：
名单兜「通但脏」，fallback 兜「真的不通」，两者互补。

**改这一块之后必须跑**：

```sh
sh tools/verify-dnschain-domains.sh          # 204 条契约断言（CI 也跑）
python3 tools/check-dnschain-lua.py          # 123 条（需 PYTHONIOENCODING=utf-8）
python3 tools/render-dnschain-diagrams.py --check   # 88 条
python3 tools/extract-dnschain-i18n.py       # 中文文案完整性
sh tools/verify-dnschain-ci-sim.sh           # 复现 CI 的目录场景
```

⚠️ **只有第一个被 CI 调用**，其余四个是纯本地工具 —— 不能指望 CI 拦住。

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
restart。落地 DNS 分流框架时须一并修正（见 `docs/adr/0003-dns-chain-framework.md` §2.7 D8）。

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

- **SSR-Plus 透明代理 IPv4 与 IPv6 都代理。** 在 fw4/nftables 固件上体现为
  `table inet ss_spec` 的 `redirect to :1234`（**不是** iptables 的
  `REDIRECT --to-ports 1234` —— v0.4.x 起已全面切到 fw4，见下方「fw4 现状」）。
  ⚠️ **旧结论「IPv6 侧只有 DNS 重定向、国外 IPv6 是直连」已被 v0.10.0 推翻**
  （`ipv6_support='1'`）。实测（2026-10-23，OpenWrt 24.10.5 / 内核 6.18.55）：
  `nft list table inet ss_spec` 有 **10 条** `ss_spec6_*` 链
  （`ss_spec6_tcp` / `_redirect` / `_prerouting` / `_output` / `_udp` /
  `_udp_proxy` / `_mangle` / `_udp_output` / `_udp_mark` / `_udp_local`），
  `ss_spec6_redirect` 里有 `tcp dport != {…} counter packets 394 bytes 28776 redirect to :1234`；
  `ip -6 rule` 有 `999: from all fwmark 0x53535250 lookup 999`，
  `ip -6 route show table 999` 为 `local default dev lo`。
  这些规则的**生成者不在本仓库**（属上游 `luci-app-ssr-plus`），本仓库只负责把
  `ipv6_support` 置 1（`files/etc/uci-defaults/99-zz-dnschain:65-70`、
  `files/usr/bin/dnschain-reconcile:84-87`）。详见
  [`docs/adr/0002-no-ipv6-proxy.md`](docs/adr/0002-no-ipv6-proxy.md)（状态已改为 superseded）。
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

### 5.1 用户的明确要求与当前实现

用户要求：**国外不要 IPv6 直连**（避免被 RST），**国内保持双栈**。

⚠️ **仓库里 `shadowsocksr.filter_aaaa` 有四个写入点，最终生效 `'0'`**（不是 `'1'`）：

| 写入点 | 值 | 执行时机 |
|---|---|---|
| `files/etc/uci-defaults/99-gaming-optimize:796` | `'1'` | uci-defaults 第一个执行 → **被后面覆盖，是死写入** |
| `files/etc/uci-defaults/99-zz-dnschain:76-80` | `'0'` | 后执行，覆盖前者 |
| `files/usr/bin/dnschain-reconcile:97-98` | `'0'` | 每轮收敛强制写回 |
| 页面「双栈策略」开关（`general.lua:1412-1442`） | 用户选 0/1 | 被收敛器推翻 |

所以 v0.10.0 之后的语义是「**国外 AAAA 保留、由 IPv6 流量代理承载**」，
不是「抑制国外 AAAA」。`99-gaming-optimize:765-799` 那段「`'0'` 会被 RST」的
推演属 v0.9.x 前提，**读它会得出相反结论**。

`filter_aaaa='1'` 时代（v0.4.0~v0.9.x）的实测基线（2026-10-17）：

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

- **[已修 v0.14.8] dnsmasq 日志曾全部丢失**（审计 P2-13）。
  根因：上游 `99-default-settings` 每次构建把 `/etc/dnsmasq.conf` 写成
  `log-facility=/dev/null`，而生成的配置 `conf-file=` 引用它 → 日志进黑洞。
  实测 `logqueries=1` 但 `logread | grep -c 'dnsmasq\['` 恒为 0。

  ⚠️ **三种「看起来对」的修法都失败，已实测排除，勿再试**：

  | 修法 | 结果 |
  |---|---|
  | UCI `dhcp.@dnsmasq[0].logfacility` | **dnsmasq 起不来**：`illegal repeated keyword` —— `init.d/dnsmasq:944` 的 `append_parm` 会再写一条，与 conf-file 重复 |
  | `log-facility=/dev/log` | **起不来**：`cannot open log /dev/log` —— socket 存在但 ujail 未挂载 |
  | `log-facility=/tmp/dnsmasq.log` | 能启动但**不写文件**（沙箱只允许白名单路径） |
  | **`log-facility=syslog`** | **唯一可用** |

  修法两处：`99-gaming-optimize` §6.9（幂等）+ `dnschain-reconcile` 每次收敛自愈
  （防被上游覆盖）。收敛器只在真改过时才重启 dnsmasq。

- **[风险] `applechina.conf` 的明文 DNS 已解决，但 `apple_dns` 仍不能设**：
  仓库 overlay 里 **173 条 `server=`** 全部指向 `127.0.0.1#5353`（全文 191 行，
  其中 18 行注释；唯一含 `114.114.114.114` 的也是注释）。**陷阱**：把 `apple_dns`
  设成 `127.0.0.1#5353` **不幂等** —— `old_appledns` 用 `grep -oE` 抽 IP、
  丢掉端口，二次启动叠成 `127.0.0.1#5353#5353`。当前 `apple_dns` 为空是
  **正确状态**，不要填。

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
