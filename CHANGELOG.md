# Changelog

本仓库所有功能/配置改动均记录于此。版本判型遵循全局规范（PATCH / MINOR / MAJOR）。

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