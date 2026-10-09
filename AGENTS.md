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
   - **四项本地改动必须保留**（被覆盖会静默失效，界面不报错、构建也成功）：
     1. `root/usr/local/bin/trafficctl-bytes-nft.sh` 的重写 —— 上游至今用本内核
        不支持的 `flags dynamic` map + `update @bytes_in`，且只挂 forward 单钩子；
        丢掉它 → **速率列恒为 `—`**。详见红线 7/8 与第 4 节。
     2. `Makefile` 的 `LUCI_DEPENDS` 去掉 `+hostapd-utils` —— 该符号只在选中
        hostapd/wpad 变体时存在，x86_64 无 WiFi → 不可满足 → kconfig 把整包
        连同 `luci-i18n-trafficctl-zh-cn` 一起从 `.config` 丢弃。
        丢掉这个修正 → **界面变英文、i18n 断言失败**（构建不报错，症状隐蔽）。
     3. `status.js`/`status.css`/`telegram.js`/`menu.d`/`config`/`rpcd` 的刷新与 tab 改动 ——
        丢掉它 → **冷启动不再自动刷新**、Telegram 变回超长折叠小节、或设置区冒出
        内层 tab。Telegram 必须是**页面级** tab（顶部行：设备 | Telegram机器人 | 端口转发）。
        **轮询必须防重入**（`setInterval(tick, …)` + `queryInFlight` + `document.hidden`）：
        一次 `summary` 实测 1.5–1.9 秒，而档位可设 1 秒，退回
        `setInterval(runQuery, …)` 会让请求层层堆积、rpcd 不断 fork 子脚本、
        路由器 load 飙到三位数、页面最终 `XHR request timed out`。
     4. `po/zh-cn/luci-app-trafficctl.po` —— 丢掉它 → **中文界面变英文**。
   新增/修改该包的中文字符串后，跑 `python3 tools/check-trafficctl-i18n.py`
     （缺失会失败；用 `--write-pot` 同步模板）。

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

```
LAN 客户端
  └─ dnsmasq:53                     (noresolv=1, server=127.0.0.1#5353)
       ├─ 默认 → dnsproxy:5353      (ALL_DOH 加密主链, upstream_mode=parallel)
       │     ├─ 国内域名 → 阿里 / 1.12.12.12 / 360 DoH
       │     └─ 24 个硬编码国外域名 → 127.0.0.1:5335
       └─ gfw_list.conf(23614 条) + black.list → 127.0.0.1#5335
             └─ mosdns:5335         (SSR-Plus 管理, pdnsd_enable=4)
                   └─ 国外 DoH（dns.google / cloudflare）经代理出站
```

**分流是分裂的**：只有 `gfw_list.conf` 与 `black.list` 里的域名走 mosdns，
其余（含大多数境外域名）走 dnsproxy 的国内 DoH。这一点是理解 §5 的前提。

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

这是本仓库**最容易误改**的一个开关。它的「正确值」**不取决于开关字面，而取决于
dnsmasq 把哪些域名指向 mosdns:5335**。当前仓库值 **`'1'`**（v0.4.0 起），
具体理由与完整推演见 `docs/adr/0001-filter-aaaa-semantics.md`。

| dnsmasq 路由 | `filter_aaaa` | 实际效果 |
|---|---|---|
| **全量**指向 `#5335`（v0.3.5 时代） | `'1'` | 所有国外域名失去 AAAA → 双栈客户端「有 IPv6 但上不了网」（v0.3.5 修的就是这个） |
| **分裂**（现状：默认 `#5353`，仅 `gfw_list.conf` 的 23614 条 + `black.list` 走 `#5335`） | `'1'` | 只有**需走代理的域名**失去 AAAA → 被墙域名回落 IPv4 走代理；其余国外域名保留 AAAA 走 IPv6 直连 |
| 分裂 | `'0'` | 那 23614 个被墙域名拿到真实 AAAA → IPv6 直连被 **RST** → 「有 IPv6 但打不开站点」 |

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
6. 改动前**先备份**：`/etc/config/*`、`/var/etc/ssrplus/*` 到 `/root/ssrfix-backup-<ts>/`，
   并在报告中写明回滚命令。

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
    hostapd-utils、`optRefresh` 与 `1s` 档位、Telegram 为页面级 tab、
    中文翻译完整性）。
  全部断言集中在 `tools/verify-trafficctl-invariants.sh`（本地可复跑，
  与 CI 同一份逻辑；`TCTL_UPSTREAM_LOCAL=<上游包目录>` 可离线运行）。
  **必须保留的本地改动**（被覆盖会静默失效，不会报错）：
  1. 重写 `root/usr/local/bin/trafficctl-bytes-nft.sh` —— 上游**至今未修**，
     仍用本内核不支持的 `flags dynamic` map + `update @bytes_in` 且只挂 forward 单钩子
     （见红线 7/8 与第 4 节的「代理流量走 INPUT/OUTPUT」）。丢掉它 → **速率列恒为 `—`**。
  2. `Makefile` 去掉 `LUCI_DEPENDS` 里的 `+hostapd-utils` —— 见第 3 节。
     丢掉它 → **整包与中文包一起被 kconfig 丢弃，界面变英文**（构建不报错）。
  3. `status.js` / `status.css` / `telegram.js` / `menu.d` / `config` / `rpcd` 的
     刷新与 tab 改动 —— 默认 5 秒自动刷新、1s/2s 档位、`refresh_interval` 端到端
     接线、**Telegram 为页面级独立 tab**（顶部行：设备 | Telegram机器人 | 端口转发）。
     丢掉它 → **冷启动不再自动刷新**、Telegram 变回超长折叠小节、或设置区冒出
     内层 tab（两级 tab 让人分不清层级）。
  4. `po/zh-cn/luci-app-trafficctl.po` —— 丢掉它 → **中文界面变英文**。
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
