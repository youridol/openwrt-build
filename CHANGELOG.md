# Changelog

本仓库所有功能/配置改动均记录于此。版本判型遵循全局规范（PATCH / MINOR / MAJOR）。

## [v0.2.6] - 2026-09-02

### 修复

- **开机时 LAN DNS 拦截规则不生成（时序 bug）**：`start_service` 中 `update_lan_intercept`
  在 `procd_close_instance` 后立即执行，用 `pgrep dnsproxy` 判断运行状态——但 procd 异步
  启动进程，开机瞬间进程可能尚未就绪 → 误判为“未运行” → 走了关闭分支，拦截规则不生成。
- 改为**按配置意图判断**（`lan_dns_intercept=1` 且 `dnsproxy.global.enabled=1` 即开启），
  `update_lan_intercept` 支持 `auto|off` 两种模式：
  - `auto`（start/reload）：按配置判断开启或关闭；
  - `off`（stop/disabled）：强制移除规则，防止客户端 DNS 被导向失效链路断网。
  删除不再使用的 `service_is_running`（pgrep）辅助函数。

### 验证（虚拟机 192.168.3.241，最新固件）

- stop → 规则移除（v4/v6 均 0）；start → 规则恢复（v4:2 v6:2）；reload → 保持；
- **reboot → 开机后规则自动生成（v4:2 v6:2，firewall.user ALL_DOH 段存在），dnsproxy running+ENABLED**。

## [v0.2.5] - 2026-09-02

### 修复

- **LAN DNS 强制拦截在 fw3（iptables）固件上不生效**：lede（coolsnowwolf）默认防火墙仍是
  fw3（xtables-legacy），无 `nft` 命令、不读取 `/etc/nftables.d/`，原有仅基于 firewall4 的
  拦截实现完全无效。
- 改造 `files/etc/init.d/dnsproxy` 的 `update_lan_intercept` 为**双后端自动检测**：
  - `nft` 命令存在（fw4/OpenWrt 25.x）→ 写 `/etc/nftables.d/10-dnsproxy-lan-intercept.nft`
    （`chain dns_intercept_lan`，priority dstnat+1，v4/v6 UDP/TCP 53 redirect）+ `fw4 reload`；
  - 无 `nft`（fw3/lede）→ 写 `/etc/firewall.user` 的 `ALL_DOH` 标记段
    （v4 用 `prerouting_rule` 自定义链，v6 用 `PREROUTING` 主链，因 fw3 的 ip6tables 无自定义链）
    + `/etc/init.d/firewall restart`。
  - 标记段包裹保证幂等（先删旧段再写）；ON/OFF 均触发防火墙重载即时生效。

### 验证（虚拟机 192.168.3.241，fw3/iptables-legacy）

- ON：`iptables -t nat -L prerouting_rule` 与 `ip6tables -t nat -L PREROUTING` 均出现
  UDP/TCP 53 → REDIRECT 规则；
- OFF：规则全部移除，dnsproxy 服务保持 running；
- 重新 ON：规则恢复。
- 说明：该 VM 无 WAN（PPPoE 未拨号），dnsproxy 的 DoH bootstrap 不可达属环境限制；
  配置链路（LAN→dnsmasq:53→dnsproxy:5353→DoH）与拦截规则均已实证正确。

## [v0.2.4] - 2026-09-01

### 新增

- **luci-app-dnsproxy 完整简体中文汉化**（`patches/luci-app-dnsproxy/0003-add-zh-cn-localization.patch`）：
  源码级直译 6 个 JS 页面共 206 处字符串：
  - `main.js`：服务状态/版本/服务控制（启动/重启/停止/启用/禁用）等；
  - `settings.js`：全部配置选项卡（常规/服务器/缓存/TLS/隐私与安全/性能）与字段说明；
  - `diagnostics.js`、`logread.js`、`help.js`、`file.js`：诊断/日志/帮助/配置文件页。
  实现方式为直接替换 `_()` 字符串（不引入 luci.mk/po2lmo 构建链，零额外依赖，
  CI 仅按既有 patch 流程应用即可自动生效）。

## [v0.2.3] - 2026-09-01

### 修复

- **LuCI「Service Control」全部按钮不可用（实测固件 192.168.3.241）**，两个独立根因：
  1. **init 脚本无执行位**：`files/etc/init.d/dnsproxy` 以 644 写入 rootfs，
     `rc init dnsproxy ...` / 服务启停全部 Permission denied，dnsproxy 服务未运行。
     修复：git 标记该文件 100755 + CI files overlay 步骤统一 `chmod +x`
     （init/uci-defaults/hotplug/rc.local），且不使用 `|| true` 静默忽略。
  2. **LuCI 前端版本探测不兼容 opkg**：上游 `parseVersion` 只读 `/lib/apk/db/installed`
     （apk 格式，OpenWrt 25.x），lede 24.10 用 opkg（无该文件）→ `notInstalled=true` →
     Service Control 全部按钮被禁用（含 Start/Stop/Restart/Enable/Disable）。
     新增 `patches/luci-app-dnsproxy/0002-fix-version-detect-for-opkg.patch`：
     - `main.js`：apk 数据库为空时回退读取 `/usr/lib/opkg/status`，解析
       `Package: dnsproxy` / `Version: 0.83.0-1`；
     - ACL 增加 `/usr/lib/opkg/status` 只读权限（否则 rpcd 返回 403）。
- **`/etc/nftables.d` 目录缺失**：init 写拦截规则文件前 `mkdir -p /etc/nftables.d`
  （部分固件 firewall4 未创建该目录，写入会失败）。

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