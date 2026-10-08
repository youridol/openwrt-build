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
| `package/luci-app-trafficctl/` | **本地包**（源自 `YusDyr/luci-app-trafficctl` v1.8.0），整包 vendored 进仓库 | 直接改本仓库副本 |
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

- **SSR-Plus 透明代理只代理 IPv4。** `iptables -t nat` 有 `REDIRECT --to-ports 1234`；
  **`ip6tables` 中只有 DNS 重定向，没有任何 TPROXY/REDIRECT** —— 国外 IPv6 是**直连**。
- 进程：`v2ray`（dokodemo-door, port 1234, retcp 模式）、`mosdns`(:5335)、
  `dnsproxy`(127.0.0.1:5353)、`dnsmasq`(:53)、`ssr-switch`。
- SSR-Plus 强制代理：`/etc/ssrplus/black.list` → dnsmasq `ipset=/<域名>/blacklist`
  → 解析结果自动入 `blacklist` ipset → `SS_SPEC_WAN_AC` 命中即 REDIRECT 到 1234。
- 访问控制 `lan_ac_mode='0'` + `SS_SPEC_WAN_FW` 末尾兜底 → **所有非国内 IPv4 流量走代理**。

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
| 路由器 SSH | dropbear，老 KEX；Windows 自带 `ssh.exe` 可能不兼容 → 用 `rsh.py`(paramiko) |

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
- **[未决] 以下三项需上机确认后才能改动**（详见审计报告 §10）：
  1. `mosdns-config.yaml` 的 `reject` 规则前置 —— 运行时配置由 SSR-Plus init 脚本
     生成（模板含 `DNS_MODE`/`DNS_PORT` 占位符），未确认改动位置前不动。
  2. `rps_flow_cnt` 被清零的写入方（`autocore` 写 4096，实测为 0）。
  3. `applechina.conf`（173 条指向 `114.114.114.114` 的明文 DNS）与
     `whitelist_forward.conf`（8 条无效 `server=/域名/127.0.0.1`）的生成路径。
- **[风险] `package/luci-app-trafficctl` 为 vendored 副本**（v1.8.0）：
  上游更新不会自动进入本仓库，需手动同步；改本地副本不会回流上游。
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
