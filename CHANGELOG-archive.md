# CHANGELOG 归档（已发布版本的详细记录）
> 本文件保存**已打 tag 发布**的旧版本详细内容。> `CHANGELOG.md` 里对应版本只留一行摘要 + 指向此处的指针。> 归档不丢信息：完整正文都在这里，按版本号倒序。---## [v0.2.0] - 2026-09-01

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

---
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

---
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

---
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

---
## [v0.2.4] - 2026-09-01

### 新增

- **luci-app-dnsproxy 完整简体中文汉化**（`patches/luci-app-dnsproxy/0003-add-zh-cn-localization.patch`）：
  源码级直译 6 个 JS 页面共 210 处字符串：
  - `main.js`：服务状态/版本/服务控制（启动/重启/停止/启用/禁用）等；
  - `settings.js`：全部配置选项卡（常规/服务器/缓存/TLS/隐私与安全/性能）与字段说明；
  - `diagnostics.js`、`logread.js`、`help.js`、`file.js`：诊断/日志/帮助/配置文件页。
  实现方式为直接替换 `_()` 字符串（不引入 luci.mk/po2lmo 构建链，零额外依赖，
  CI 仅按既有 patch 流程应用即可自动生效）。

---
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

---
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

---
## [v0.2.7] - 2026-09-02

### 修复（完整审查产出）

- **0003 汉化补丁补齐拦截开关标题**：审查发现 0003 的 settings.js 两个 hunk（第 6-66、77-316 行）
  未覆盖第 67-76 行的拦截开关（0001 加入），导致最终文件标题仍是双语
  「拦截所有客户端 DNS（Intercept all client DNS）」且描述含过时的 firewall4 表述。
  已重新生成 0003：标题改为纯中文「拦截所有客户端 DNS」，描述改为
  「由 dnsproxy init 自动管理（fw3 用 iptables、fw4 用 nftables）」，共 210 处替换。
- **init 注释同步双后端**：文件头与 `update_lan_intercept` 相关注释由仅描述 nftables 更新为
  fw3/fw4 双后端说明；`FW_USER` 增加 `local` 声明（避免泄漏到全局）。
- **config/dnsproxy 注释同步**：拦截管理描述由「init + firewall4」改为双后端。
- **文档同步**：patches README 与 CHANGELOG 中的 0001/0003 描述更新（双后端、210 处）。

### 审查验证

- 干净克隆 → 0001→0002→0003 顺序应用全部成功；6 个 JS 文件 `node --check` 全部通过；
  拦截开关最终为纯中文标题；ACL json 语法正确；所有 `_()` 字符串无漏汉化（技术术语保留英文）。

---
## [v0.3.0] - 2026-09-02

### 新增

- **国外域名 DNS 分流（走 SSR-Plus 代理）**：
  - `files/etc/config/dnsproxy`：`servers.upstream` 增加常用国外域名
    （google/youtube/github/twitter/x/facebook/instagram/whatsapp/telegram/reddit/
    discord/spotify/netflix/cloudflare/amazon/stackoverflow/wikipedia 等）的
    domain-specific 规则 → `127.0.0.1:5335`（SSR-Plus MosDNS）；
  - `files/etc/uci-defaults/99-gaming-optimize`：配置 SSR-Plus 启用 MosDNS
    （`pdnsd_enable=4`）与国外 DoH 上游（`tunnel_forward_mosdns` =
    dns.google/cloudflare-dns.com/quad9），MosDNS 监听 5335，上游经 SSR-Plus
    TPROXY 代理出站，返回真实 IP 防污染。
- **最终 DNS 架构**：
  ```
  LAN → dnsmasq:53 → dnsproxy:5353（ALL_DOH 加密主链）
                        ├─ 国内域名 → 国内 DoH（阿里/腾讯/360）
                        ├─ 国外域名 → MosDNS:5335（SSR-Plus，国外 DoH 经代理）
                        └─ fallback → 1.12.12.12（国内）/ 8.8.8.8（经代理）
  ```

### 验证（192.168.3.254）

- 国外域名全部真实 IP：google 142.251.152.119、github 20.205.243.166、
  youtube 142.251.155.4、reddit 151.101.65.140、twitter 151.101.66.146；
- 国内域名正常：baidu 183.2.172.177、qq 101.91.22.57；
- MosDNS(5335) 运行、dnsproxy running、SSR-Plus ENABLED、拦截规则 v4:2 v6:2。

---
## [v0.3.1] - 2026-09-02

### 修复

- **LAN DNS 拦截被 SSR-Plus 透明代理抢先**：SSR-Plus 的 `SS_SPEC_WAN_AC` 链在 PREROUTING
  第 1 条（fw3 restart 后重新插到最前），先于我们的 DNS REDIRECT（在 prerouting_rule 链内），
  导致客户端手动指定 8.8.8.8/1.1.1.1 的 DNS 查询被 SSR-Plus 劫持（到真 8.8.8.8 明文），
  未走 ALL_DOH 加密链路。
- 修复：`update_lan_intercept_ipt` 改为**用 `-I PREROUTING 1` 把 DNS REDIRECT 插入
  PREROUTING 最前**（firewall restart 重建链后再次 -I，确保先于 SSR-Plus 规则）；
  firewall.user 段仅保留说明注释（规则由 init 动态管理），避免重复。

### 验证（192.168.3.254 + Win11 客户端 192.168.3.238）

- Win11 `nslookup <域名> 8.8.8.8`：tracert 第一跳 192.168.3.254；254 的 PREROUTING
  REDIRECT UDP 计数随查询增长（0→9）；dnsproxy 日志显示该查询
  `sending request addr=https://doh.360.cn:443/dns-query`（**加密 DoH 上游**）→ 完整链路
  `Win11 → REDIRECT → dnsmasq:53 → dnsproxy:5353 → DoH` 加密解析生效。

---
## [v0.3.2] - 2026-09-02

### 变更

- **dnsproxy 上游模式改为 `parallel`**（原 `load_balance`）：
  - 实测（192.168.3.254，冷查询 10 样本中位数）：
    `parallel 39.6ms` < `load_balance 62.5ms` < `fastest_addr 97.7ms`；
  - `parallel`：并行查询全部上游取最快响应，延迟最低且稳定（P90 57-59ms）；
  - `load_balance`：轮询，偶发命中慢上游导致 P90 偏高（93ms）；
  - `fastest_addr`：每次查询对返回 IP 额外做 TCP/ICMP 探测，开销大（+40-50ms），
    仅适合上游返回不同质量 IP 的场景；本架构上游为同质国内 DoH、国外域名已分流
    到 MosDNS，故不推荐。

---
## [v0.3.4] - 2026-09-04

### 修复（DNS proxy 报错根治）

- **`files/etc/config/dnsproxy` — 移除对 SSR-Plus 代理的 DNS 兜底依赖**：
  - 删除 `fallback https://8.8.8.8/dns-query`：8.8.8.8 在 SSR-Plus blacklist 中，
    dnsproxy 进程（与主 netns 同 ns）到 8.8.8.8 的出站被 `REDIRECT :1234` 代理接管；
    SSR-Plus 规则重建/订阅更新窗口（每日 02:00 cron、开机、节点切换）内必超时，
    dnsproxy 无健康探活 → 日志刷 `context deadline exceeded` / `i/o timeout` ERROR。
  - 保留 `fallback https://1.12.12.12/dns-query`（国内直连、不依赖代理）作最兜底。
  - 上游 `https://doh.pub/dns-query` → `https://1.12.12.12/dns-query`：
    doh.pub 为域名型 DoH（依赖 bootstrap 明文预解析、曾现 502/超时），
    1.12.12.12 为 IP 型直连 DoH（china ipset 命中 → 不走代理、无 bootstrap 依赖）。
  - 国外域名（google/github 等）仍显式分流 MosDNS(5335)→SSR 代理 DoH，防污染不变。
- **`files/etc/init.d/dnsproxy` — 修复 fw3 LAN DNS 拦截规则被 SSR-Plus/fw3 reload 清空**：
  - 原实现 `iptables -I PREROUTING 1` + `firewall restart`：fw3 reload/restart 会重建
    nat 表冲掉规则，且 restart 会连带清掉 SSR-Plus 自身规则（重入风暴）；
    实测 PREROUTING 中已无任何 `dport 53` 拦截，客户端手填 DNS 可绕过加密链路。
  - 改为写入 fw3 用户链 `prerouting_rule`（SSR-Plus 不操作该链），命令写入
    `/etc/firewall.user` 由 fw3 reload 自动幂等重放；不再触发 firewall restart。
- **`files/etc/uci-defaults/99-gaming-optimize`**：同步注释说明。

### 验证

- 路由器 192.168.3.254 热补丁后：`github.com/www.baidu.com` 解析正常；
  SSR 规则重建窗口触发后 logread 无 dnsproxy ERROR；`iptables -t nat -S PREROUTING`
  拦截规则经 `prerouting_rule` 存在且在 SSR 规则之前生效（fw3 reload 后仍存活）。

---
## [v0.4.5] - 2026-10-10

### 修复（严重）— v0.4.4 导致 fw4 整体加载失败、国内域名大面积无法解析

**症状**：刷入 v0.4.4 后，多个国内域名/服务/软件无法解析与联网。

**根因（已在路由器上复现并定位到源码行）**：

1. fw4 的 ruleset 模板 `/usr/share/firewall4/templates/ruleset.uc` 中，
   第 15 行 `table inet fw4 {` 开表，第 104 行
   `include "/etc/nftables.d/*.nft"` —— **include 位于该 table 内部**。
   因此 `/etc/nftables.d/` 下的文件**只能是裸 chain**，不得含 table 声明。
2. v0.4.4 写入的是完整 `table inet mssclamp { chain ... }`，被嵌进
   `table inet fw4` 内部 → **嵌套 table** → nft 语法错误。
3. `fw4 check` 实测报错：
   ```
   /etc/nftables.d/10-mss-clamp.nft:1:1-5: Error: syntax error, unexpected table
   table inet mssclamp {
   ^^^^^
   ```
   而 fw4 的加载路径是
   `print | nft -c -f $STDIN || die "The rendered ruleset contains errors"`
   —— 校验失败则**整个 ruleset 不加载**，于是 input/forward/dstnat/srcnat、
   DNS 拦截、透明代理等全部规则消失，表现为国内解析与联网大面积异常。
4. 对照证据：同目录既有的 `10-dnsproxy-lan-intercept.nft` 用的是正确的
   **裸 chain** 写法，且实测该 chain 出现在 `table inet fw4` 内部
   （`nft list chain inet fw4 dns_intercept_lan` 成功）。

**处置**：**整段删除** `/etc/nftables.d/10-mss-clamp.nft` 的生成逻辑
（`files/etc/uci-defaults/99-gaming-optimize`），并在原处写明原因与硬约束。
删除而非改写的理由：

- **功能冗余**：上述 `firewall.@zone[0].mtu_fix='1'`（配合 wan zone 默认值）
  会让 fw4 原生生成 4 条 MSS clamp 规则（实测 `nft list table inet fw4`）：
  `oifname br-lan` / `oifname pppoe-wan` / `iifname br-lan` / `iifname pppoe-wan`
  各一条 `maxseg size set rt mtu`，用 `rt mtu` 在 PPPoE(1492) 场景下与显式
  clamp 等价，且同时覆盖 IPv4 与 IPv6。删掉不损失任何功能。
- **fw3 路径是死代码**：fw4 不加载 `/etc/firewall.user`
  （`uci show firewall` 中 firewall.user include 计数 = 0），原 ip6tables
  规则从未生效。
- **fw4 路径有风险**：即本次故障。
- 另删除了 `/etc/firewall.user` 中同源的历史遗留行（死代码）。

### 修复（严重）— trafficctl 速率监控完全失效（上下行都是 `—`）

**症状**：流量控制页面的「下行速率」列恒为 `—`；且没有任何上行速率列。

**根因（三层，均已实测确证）**：

1. **nftables 语法在本内核不被支持，且错误被静默吞掉**。
   `trafficctl-bytes-nft.sh` 用：
   ```
   nft add map ... '{ type ipv4_addr : counter; flags dynamic; }'
     -> Error: Could not process rule: Not supported
   nft add rule ... 'update @map { ip saddr counter }'
     -> Error: Could not process rule: Not supported
   ```
   本机内核 `6.18.55` / nftables `1.1.6`。两条错误都被 `2>/dev/null`
   吞掉，结果只留下一个**空的 forward 链**，ubus 的 `bytes` 方法
   永远返回 `[]`，前端两列速率恒为 `—`。
   实测本内核**可用**的等价语法为：
   `nft add set ... '{ type ipv4_addr; size 65535; flags dynamic; }'`
   配合 `nft add rule ... 'add @set { ip saddr counter }'`。
2. **挂钩点选错，看不到代理流量**。SSR-Plus 用 REDIRECT 把客户端连接引到
   路由器本机的 v2ray(:1234)，REDIRECT 把目的地址改写为本机，数据包因此走
   **INPUT/OUTPUT，不经 forward**。实测对照（客户端下载 150 MB）：
   | 挂钩点 | 增量 |
   |---|---|
   | `output daddr=客户端` | 157548502 B（完整捕获） |
   | `input saddr=客户端` | 1360391 B（客户端小请求） |
   | `forward saddr=客户端` | 5932 B（几乎为零） |
   原实现只挂 forward，故完全看不到。
3. **集合会被非 LAN 地址污染**。output 钩子会看到路由器自身对 WAN 的连接，
   仅用 `oifname br-lan` 限定仍会写入 `1.2.4.8`、`10.x`、`14.x` 等地址。
   实测必须同时限定**地址属于 LAN 网段**（自动生成的 `@lan` 集合）才能收敛。

**处置**：重写 `trafficctl-bytes-nft.sh`：

- 改用内核支持的 `set` + `add @set { ... counter }` 语法。
- 同时挂 **forward / input / output** 三个钩子（三者对同一数据包互斥，
  不重复计数）：
  - 下行 = `forward daddr=设备` + `output daddr=设备`
  - 上行 = `forward saddr=设备` + `input saddr=设备`
- 三个钩子均用 `@lan` 集合限定地址归属；`@lan` 由 `tctl_lan_subnets`
  **动态生成**（支持多网桥/多 VLAN），不硬编码。
- 建立逻辑改为**单事务原子重建**（`nft -f` 内 `delete table` + 重建）。
  原「先检查后逐条 add」的写法存在竞态：前端每 2 秒轮询与手工调用并发时，
  两个进程会同时通过检查各建一套规则 → 规则重复 → 速率翻倍
  （实测 180 MB 下载被记成 380 MB）。原子事务下并发调用只会整体覆盖，
  结构始终唯一。
- 结构自检（集合存在 + 各链规则条数正确）后才重建，避免每次轮询清零计数。
- 解析器适配 `nft list set` 的 `IP counter packets N bytes M` 格式
  （旧实现按 `nft list map` 的 `IP : counter ...` 解析，格式已不匹配）。
- 重建前先 `nft -c -f` 只校验不提交，避免写坏运行中的防火墙。

### 新增 — trafficctl 设备表「上行速率」列

- 新增 `_upspeed` 列（`UL Speed`），紧邻「下行速率」。
- 上行数据其实**早已存在**（`packets_out` 差分算出的 `speedUp`），
  但此前只用于弹窗图表，未进入设备表；本次将其并行接入新状态
  `_upSpeedMap` / `_upSpeedHistory` / `_upSpeedEwma`，与下行完全对称。
- 上下行**色义区分**：下行用 `--tc-speed`（蓝），上行用 `--tc-ok`（绿，
  与弹窗图表中上行曲线一致），新增 `.tc-upspeed-active` 样式。
- `updateSpeedCells` 实时刷新上行单元格；设备下线时同步清理三份上行状态。
- 底部提示改为「下载与上传速率每 2 秒更新一次」。
- 补充 4 条翻译：`UL Speed` / `Current upload speed (bytes/sec from device to router)`
  / `changes are saved automatically` / 提示串（旧串同步替换），
  `.po` 与 `.pot` 均已更新。

### 变更 — trafficctl 设置区改为常显卡片网格（不再整体收起）

- 旧实现把整个设置区包在可折叠容器内且**初始隐藏**，用户必须点击标题才能
  看到任何设置项，收起后完全看不出里面有什么。
- 现改为：常显标题栏（不可折）+ 内容始终可见；内部各小节改为
  **自适应卡片网格**（`repeat(auto-fit, minmax(320px, 1fr))`，
  窄屏单列、宽屏多列），每节标题恒常显，仅**单节内容**可独立折收。
- 「显示」「表格与速率」默认展开；「Telegram机器人」「日志与持久化」
  「流量卸载」内容较重，默认收起但标题可见、一键展开。
- 各节展开状态持久化到 `localStorage`，刷新后保持用户的布局选择。
- 懒加载改为 `onFirstOpen` 回调（首次展开才发起 RPC），避免一次性打满请求。

### 验证（路由器 192.168.3.254，OpenWrt 24.10.5 / 内核 6.18.55）

- **fw4 修复**：`fw4 check` 由报 `unexpected table` 变为
  `Ruleset passes nftables check.`；`table inet fw4` 内 chain 数 34、
  DNS 拦截规则 2 条、`ss_spec` 表在、fullcone 规则 2 条；
  baidu/taobao/jd/bilibili 均 200，google 302，github 200，出口 `203.27.106.146`。
- **速率后端**：并发 8 实例后 `forward=2 / input=1 / output=1`（无重复）；
  180 MB 下载实测 `bytes_in` 增量 190296934（不翻倍）；
  `bytes` RPC 由 `[]` 变为含真实数据（本机 993 MB）；
  集合内非 LAN 地址数 = 0。
- **速率前端**：设备表新增「UL Speed」列；
  实测 `192.168.3.238` 下=35.7 Kbit/s、上=23.7 Kbit/s，
  下行 class `tc-speed-active`（蓝）、上行 class `tc-upspeed-active`（绿），
  21 个 sparkline 全部渲染，提示为中文「平均 / 最大」。
- **设置区**：默认展开；3 列卡片网格；5 个小节标题全部可见。

### 说明

- 本次同时完成了「是否已全面切到 fw4」的核查，结论：**已全面切换**。
  判据：`table inet fw4` 在跑且承载全部规则（34 条链）；DNS 拦截与透明代理
  均在 nftables（`iifname br-lan ... redirect`、`table inet ss_spec`）；
  fw3 专属的 `/etc/firewall.user` include 计数为 0（死代码）；
  `iptables filter/nat/mangle` 与 `ip6tables mangle` 只剩默认策略行
  （无任何规则）；`ip_tables` 内核模块**未加载**。
  残留的 `iptables`/`ip6tables` 二进制与 `kmod-ipt-*` 是 SSR-Plus 等包的
  依赖项，属正常共存，不表示仍在用 fw3。
- 本版本**修复了 v0.4.4 的严重故障**，建议刷入替换。

---
## [v0.4.6] - 2026-10-10

### 修复 — trafficctl 三处交互缺陷（设置未展开 / 布局凌乱 / 不自动刷新）

**1. 设置区未能完全展开**

- 根因：`mkCollapsible` 把每个小节的折叠状态**持久化到 `localStorage`**
  （键 `tc.set.<标题>`）。用户曾收起过某个小节后，该状态被永久记住，
  之后每次打开页面它都是收起的 —— 表现为「设置没有完全展开」。
  此外 4 个小节（Telegram / 日志 / 流量卸载 / 表格与速率）初始 `startOpen=false`。
- 处置：**移除折叠状态持久化**（折叠仅在本次会话内有效），并把
  `startOpen` 缺省值改为 `true` —— 全部小节默认展开。
- 顺带修正一处**懒加载时序缺陷**：此前需先 `mkCollapsible(...)` 返回对象、
  再赋值 `api.onFirstOpen`。当小节初始即展开时，`mkCollapsible` 内部已触发
  首次展开，而此时回调尚未挂上 → **懒加载永不执行，内容区空白**。
  现改为把 loader 作为**构造参数**传入，在展开时刻同步触发。

**2. 设置区布局凌乱**

- 根因（两次迭代才定案）：
  - 首版用 `repeat(auto-fit, minmax(320px,1fr))` 网格。CSS Grid 的**行高由该行
    最高的卡片决定**，邻列矮卡片下方留大片空白。
  - 次版改为按语义手工分两列（flex）。当某列含 Telegram（实测高度 **1270px**）
    这类超长卡片时，另一列出现数百像素空白（实测左列 340px vs 右列 1692px）。
- 处置：改为**扁平列表 + CSS 多列瀑布流**（`column-count: 2` + `break-inside: avoid`），
  由浏览器按卡片实际高度自动分列，列高自然均衡；窄屏（≤760px）自动降为单列。
  卡片顺序按使用频率排列：显示 / 表格与速率 → 流量卸载 → 日志 → Telegram。
  展开态改用**左侧色条**标示（比整框变色更克制、更易扫视）。
- 顺带修掉一处**chips 溢出**：`.tc-chips-wrap` **此前完全没有样式定义**，
  导致「可见列」一长串 chips 不换行、右侧被卡片的 `overflow:hidden` 裁掉。
  现补上 `display:flex; flex-wrap:wrap`。

**3. 冷启动不按刷新间隔拉数据 / 选中设备后速率定格**

- 根因（三处，均为真实缺陷）：
  - **默认刷新为「关」**：`refreshPick` 用 `opts.refresh||0` 作默认值，
    冷启动打开页面后**数据完全不会自动刷新**，必须手动点「所有设备」才更新一次。
  - **单设备模式直接跳过速率轮询**：`pollBytes()` 开头
    `if (!isAllMode()) return;` —— 选定某台设备后，速率与流量曲线**永久定格**。
  - **单设备模式主动停掉轮询**：`runQuery()` 在非 all 分支调用
    `self._stopBytesPoll()`，把速率/丢弃/整形轮询**整体停掉**，
    而 `runSingle()` 只查一次连接列表。
- 处置：
  - 新增 `getRefreshSecs()`，缺省 **5 秒**（用户显式选「关」时仍尊重其选择）；
    `_setupTimer` 改用它，冷启动即建立定时器。
  - `pollBytes()` 去掉按模式提前返回，改为**按模式分派刷新目标**：
    all 模式刷表格单元格，单设备模式刷该设备的流量曲线。
  - `runQuery()` 的单设备分支由 `_stopBytesPoll()` 改为 `_startBytesPoll()`。
  - `_restartBytesPoll()` 不再限定 all 模式。
  - `_startBytesPoll()` 在 `pollInterval=0`（用户选「关」）时仍照常建立
    丢弃/整形轮询，避免那两个面板一起冻结。
  - 新增 `refreshSpeedViews()`：「窗口」「方法」变更时**立即**按新参数重算并重绘
    （此前只是写进 `localStorage`，要等下一个轮询周期才生效，用户观感是
    「改了没反应」）；切换「方法」时同时清空历史与 EWMA 累加器，避免混算。
  - 从「关」切回非 0 刷新间隔时立刻拉一次，不让用户白等一整个间隔。

### 验证（路由器 192.168.3.254，OpenWrt 24.10.5 / 内核 6.18.55）

- **设置区**：5 个卡片 `allOpen=true`（全部展开）；两列瀑布流；
  懒加载全部生效（Telegram 760px 内容、流量卸载 203px、日志 154px 均已加载）。
- **冷启动自动刷新**：清空 `localStorage`（模拟全新访客）后重载页面，
  **不做任何交互**，3 秒内自动出现数据（`active=1`、22 个 sparkline 渲染），
  本机 `192.168.3.238` 下=32.0 Kbit/s、上=9.2 Kbit/s。
  修复前该场景必须手动点「所有设备」才有数据。
- **「刷新」chip 默认高亮 5s**（`refreshActive=["5s"]`）。
- **状态文本周期性变化**：`扫描所有设备中…` ↔ `✓ 完成` 每约 5 秒交替，
  证明定时器在持续拉取。
- **单设备模式图表自动刷新**：选定 `192.168.3.238` 后**不做任何操作**，
  连续 8 次采样中 SVG 路径坐标持续变化、`uniqueD=8`、
  SVG 长度 17883 → 19131 持续增长，证明新数据点在不断追加。
  修复前此模式下 `pollBytes` 直接 return，图表永久静止。
- 顺带确认 v0.4.5 的后端修复仍正常：`trafficctl-bytes-nft.sh` 返回真实数据，
  `forward` 规则数恰为 2（无重复累计）。

---
## [v0.4.7] - 2026-10-10

### 新增 — trafficctl 升级到上游 1.21.4 并建立「可跟进上游」的维护机制

**背景**：本地包此前是上游 `YusDyr/luci-app-trafficctl` **v1.8.0** 的 vendored 副本，
版本落后很多（`status.js` 3077 → 4677 行），且上游更新不会自动进入本仓库。
本次拉到上游最新 **1.21.4**，把本地改动重新落地，并把差分固化成 patch，
使「日后跟进上游」成为可验证的流程而不是靠人工记忆。

**1. 全量 vendor 上游 1.21.4**

- 包内文件 30 → **43**（上游新增 13 个文件：`portfw.js`、`trafficctl-cut.sh`、
  `trafficctl-ifaces.sh`、`trafficctl-metrics.sh`、`trafficctl-names.sh`、
  `trafficctl-netify.sh`、`trafficctl-portfw.sh`、`trafficctl-rdns-refresh.sh`、
  `trafficctl-subnets.sh`、`trafficctl-totals.sh`、`www/cgi-bin/trafficctl-metrics`、
  `init.d/trafficctl-cut`、`lib/upgrade/keep.d/luci-app-trafficctl`）。
- `LUCI_DEPENDS` 新增 `+tc +iw +hostapd-utils`；`config/trafficctl` 新增
  `shape_ifb`、`netify_endpoint`、`netify_interval` 等项。
- 上游 Windows checkout 为 CRLF（实测 39/40 文件）→ 全部转 LF（红线 1）；
  执行位按上游 git 索引恢复为 **29 × 100755 + 14 × 100644**
  （Windows 上 `Copy-Item` 会丢失该信息，必须用 `git update-index --chmod`）。

**2. 保留并重新落地本地改动（三项）**

- **（关键）重写 `trafficctl-bytes-nft.sh`**：上游**至今未修**该缺陷，
  仍用本内核不支持的语法且只挂 forward 单钩子。
  - `nft add map … '{ type ipv4_addr : counter; flags dynamic; }'` 与
    `'update @bytes_in { ip daddr counter }'` 在内核 6.18.55 / nftables 1.1.6 上
    均报 `Error: Could not process rule: Not supported`，错误被 `2>/dev/null` 吞掉
    → 集合从不建立、脚本永远返回 `[]` → **速率列恒为 `—`**。
    上游 1.21.4 仅新增了「失败时回退 conntrack」，但 **conntrack 看不到被
    REDIRECT 到本机的代理流量**，速率仍不准。
  - 改为受支持的 `set { type ipv4_addr; size 65535; flags dynamic; }` +
    `add @set { ip saddr counter }`。
  - **三钩子并用**（上游只有 forward）：SSR-Plus 用 REDIRECT 把客户端连接引到
    本机 v2ray(:1234)，数据包走 **INPUT/OUTPUT 而非 forward**。
  - 用 `@lan` 集合限定地址归属，避免 `output` 钩子把路由器自身对 WAN 的连接
    （`1.2.4.8`、`10.x` 等）写进集合污染数据。
  - 保留单事务原子重建 + `nft -c -f` 预校验（红线 8）。
  - 保留上游 JSON 契约字段 `bytes_tcp` / `bytes_udp` / `src` / `degraded`
    （`trafficctl-totals.sh` 会消费，缺失会导致重基线判定与信任标记失真）。
- **设置区 tab 分页 + 默认自动刷新 + 1s/2s 档位**：
  - Telegram Bot 表单极长（实测单卡片 1270px），改为独立 tab
    （`Display & Table` / `Devices` / `Telegram Bot`），tab 选择持久化。
  - 上游刷新默认值是「**关**」（`loadOpts().refresh || 0`），冷启动不刷新；
    改为经 `optRefresh()` 取默认 5 秒，并新增 UCI
    `trafficctl.main.refresh_interval`（默认 `5`）实现**路由端可下发**。
  - 刷新档位新增 **1s / 2s**（上游最短 5s）。
  - 设置区由「默认折叠隐藏」改为**常显标题栏 + 内容始终可见**。
  - 新增 `refreshSpeedViews()`：改「窗口」「方法」后立即重算重绘。
- **中文翻译**：新增 `po/zh-cn/luci-app-trafficctl.po`，覆盖 **403/403** 条界面
  字符串、0 条空译文；`.pot` 模板一并重生成（上游只带 121 条，实际需要 403 条）。

**3. 建立「可跟进上游」的维护机制**

- `patches/luci-app-trafficctl/`（4 个 patch + `UPSTREAM` + `README.md`）：
  记录相对上游的全部差分。`UPSTREAM` 记录基线 tag（`v1.21.4`）。
- `tools/sync-trafficctl.sh`：一条命令升级上游 —— 克隆指定 tag、覆盖包目录
  （保留本地专有文件）、重算 patch、在干净基线上回放校验。
- `tools/regen-trafficctl-patches.py`：改完 `package/` 下的文件后重算 patch，
  并**验证「干净上游基线 + 全部 patch」与工作树逐字节一致**。
- `tools/check-trafficctl-i18n.py`：校验中文覆盖率；
  `--write-pot` 可直接重生成模板。
- **CI 新增守卫** `Verify luci-app-trafficctl local invariants`：
  断言 nft 后端不含禁用语法、三钩子与 `@lan` 齐备、JSON 契约字段完整、
  po/zh-cn 存在且翻译完整、`optRefresh` 与 `1s` 档位存在、设置区 tab 存在、
  无 `td[data-…]` 前缀选择器；并从 `UPSTREAM` 记录的 tag **真实克隆上游、
  重放全部 patch、要求结果与 vendored 包逐字节一致**。
  上游发新版而 patch 未跟上时 CI 显式失败，不再静默。
- CI 显式启用 `iw`、`hostapd-utils`、`conntrack` 并断言（1.21.4 的功能依赖；
  缺 `hostapd_cli` 时界面会提示「WiFi 阻断未生效」）。

**4. 顺带修复**

- 设备表底部提示文案由 "Download speed updates…" 改为
  "Download **and upload** speeds update…"（表格已有上下行两列）。

### 验证

**静态**

- `node --check status.js / portfw.js` 通过；全部 shell 脚本 `sh -n` 通过。
- `msgfmt --check` 编译通过，**443 条已翻译**；`msgfmt` 反解确认
  `Display & Table → 显示与表格` 确实在产物中。
- `tools/check-trafficctl-i18n.py`：界面字符串 403 条、po 443 条、
  缺失 0、空译文 0。
- `tools/regen-trafficctl-patches.py`：patch 可 `git apply -p1` 套用、
  结果与工作树逐字节一致、可 `-R` 干净回退。
- 全仓库跟踪文件 CRLF = **0**。
- CI YAML 解析合法（26 个步骤）。

**路由器实测（192.168.3.254，固件 24.10.5 x86/64）**

- nft 后端：从零重建后 `nft list table inet trafficctl_mon` 显示集合与三钩子
  全部正确（`mon_forward` 2 条规则 / `mon_input` 1 条 / `mon_output` 1 条），
  `@lan` 正确解析为 `192.168.3.0/24`，建表耗时 0.43s。
- 计数器实测增长：持续下载 60 MB 文件时本机 `bytes_in` 从
  `395776761` 稳步增至 `911225010`（每 2 秒约 +115 MB）。
- UI 端到端：本机下行 2.3–3.4 Mbit/s、上行 4.1–6.1 Mbit/s，
  12 次采样 **10 个不同值**（修复前恒为 `—`）。
- 1 秒刷新精确验证：10 秒内 10 次 ubus 调用，时间戳间隔**精确 1000ms**
  （`callsPerSec: 1.00`）。
- 默认刷新：冷启动（已清 `localStorage`）后自动进入
  `扫描所有设备中…` ↔ `✓ 完成` 循环，无需任何手动操作。
- tab：渲染出 `Display & Table` / `设备` / `Telegram机器人` 三个 tab，
  默认打开第一个，Telegram 为独立页。
- rpcd：`ubus call luci.trafficctl config_get` 返回
  `"refresh_interval": 5`，端到端接线打通。

**已知限制（非缺陷）**

- 路由器上的 `luci-app-trafficctl.zh-cn.lmo` 是 **10 月 9 日刷机**时从 1.8.0
  编译的旧文件，故新增字符串（如 `Display & Table`）在**当前路由器**上仍显示
  英文。`.lmo` 由构建主机的 `po2lmo` 在打包时生成（路由器上没有该工具），
  下一次固件构建会从本仓库 `.po` 重新编译 —— 已用 `msgfmt` 编译出 444 条
  译文证明该串在产物中。

---
## [v0.4.8] - 2026-10-10

### 新增 — Telegram 机器人提升为页面级独立 tab

顶部 tab 行由「设备 | 端口转发」变为 **「设备 | Telegram机器人 | 端口转发」**，
设置区内的嵌套 tab 全部取消（两级 tab 会让人分不清哪一层在切页）。

- **新增独立视图 `telegram.js`**（396 行）：把 `status.js` 里的 `loadTelegramUI`
  （304 行）连同它依赖的 `mkToggle`（10 行）与 `RATE_PRESETS`（11 行）一起迁出。
  搬迁前做过依赖分析，确认它只用到全局 `E` / `_` 与三个 `rpc.declare`，
  **不引用** `status.js` 的任何局部作用域（`self` / `opts` / `loadOpts` /
  `settingsBody` 等），因此可以安全独立成视图。
- `status.js` 删除 `tgSection`、`loadTelegramUI`、三个 `callTelegram*` 声明，
  以及 `tabDisplay` / `tabDevices` / `tabTelegram` / `settingsTabBar` /
  `selectSettingsTab` 整套内层 tab 机制（−307 行、−29 行）。其余设置项改为
  在 `settingsBody` 内顺序常显。
- `menu.d` 新增 `telegram` 页，`order` 排为 **设备(1) | Telegram(2) | 端口转发(3)**。
- CSS 移除 `.tc-settings-tabs` / `.tc-stab` / `.tc-settings-pane`；卡片瀑布流移到
  `.tc-settings-body`（`column-count: 2`，≤760px 降为单列）。

### 修复 — v0.4.7 构建失败：依赖断言写错

v0.4.7 在 5m11s 失败于 CI 步骤 `Verify SQM / i18n`。根因是**我新增的断言写错了**：
把 `hostapd-utils` 断言为「必须 `=y`」。上游 `hostapd/Makefile` 里该包的
`DEPENDS` 是 `@` 加 `HOSTAPD_PROVIDERS` 列表 —— **只有选中某个 hostapd/wpad
变体时该符号才存在**。本目标是 x86_64、无 WiFi 硬件（实测路由器上无
`/sys/class/ieee80211`、无 `hostapd`/`wpad` 二进制），符号合理地不存在。

- `iw` / `conntrack` 仍断言必须 `=y`（`conntrack` 实测真实存在：opkg 有
  `conntrack 1.4.7-1`，`/usr/sbin/conntrack` 在位）。
- `hostapd-utils` 改为**条件启用**（仅当检测到 hostapd/wpad 变体时才写 `=y`），
  校验时只报告状态，缺失不阻断构建。
- 用 4 个场景本地验证断言逻辑：无 WiFi ✓、有 WiFi + utils ✓、缺 `iw` ✗（被拦）、
  缺 `conntrack` ✗（被拦）。

### 修复 — patch 里的伪 mode 变更

v0.4.7 的 patch 含大量 `index a..b 100755`，套用时打印
`warning: xxx has type 100755, expected 100644`。根因：regen 脚本在临时目录建
git 仓库，而上游 clone 位于 Windows 挂载点（`/mnt/c`），DrvFs 把文件一律报告为
`0777`，于是 `git add -A` 记成 `100755`，与 patch 应有的索引模式不符
（上游权威：**29 × 100755 + 11 × 100644**）。

- `tools/regen-trafficctl-patches.py` 新增 `local_index_modes()` / `apply_modes()`：
  以**本仓库 git 索引**为权威模式表，在 `git add` **之前** `os.chmod` 落盘权限。
- 生成后复查「无 `old`/`new mode` 行」。
- 实测：三个 patch 重放**零告警**且与 vendored 包**逐字节一致**。

### 变更 — CI 守卫重构为可本地复跑的脚本

把 226 行内联断言抽成 `tools/verify-trafficctl-invariants.sh`。抽出的两个理由：
内联的 heredoc/python 段在 YAML 里易因缩进出错，且**本地无法复现**；抽出后
本地 `sh tools/verify-trafficctl-invariants.sh` 与 CI 用同一份逻辑，不会出现
「本地过了 CI 挂」。断言覆盖：nft 后端语法/三钩子/`@lan`/单事务、JSON 契约字段、
`po/zh-cn` 完整性、`optRefresh` 与 1s 档位、`refresh_interval` 端到端、
设置区无内层 tab、`telegram.js` 与 `menu.d` 登记、无 `td[data-]` 前缀选择器、
文件模式与上游一致，以及「从 `UPSTREAM` 记录的 tag 克隆 → 重放全部 patch →
与 vendored 包逐字节一致」。

### 修复 — sync 脚本的设计缺陷

原 `tools/sync-trafficctl.sh` 先覆盖 `package/` 再重算 patch —— 这会把本地改动
一起覆盖掉，重算出**空 patch**。重写为：备份 → 覆盖新上游 → **套用旧 patch**
（冲突则明确中止并给出回滚命令）→ 重算 → 更新 `UPSTREAM` → 复跑校验。
并加入前置检查：包目录或 patch 目录有未提交改动时**拒绝执行**。
同时把 patch 生成逻辑统一到 regen 工具一处，避免两份实现漂移。

### 验证

**静态**：`node --check`（`status.js`/`portfw.js`/`telegram.js`）通过；
全部 shell `sh -n` 通过；`msgfmt` 编译通过，中文翻译 **402/402** 覆盖、0 空译文；
文件模式 **29 × 100755 + 11 × 100644**（与上游一致）；patch 无 `old`/`new mode` 行；
workflow YAML 合法（26 步）。

**负向测试（9 项，全部被抓住）**：nft 退回不支持语法、缺 output 钩子、
移除 `optRefresh`、缺 1s 档位、`status.js` 出现内层 tab 痕迹、`telegram.js` 缺失、
`menu.d` 未登记、模式漂移、中文翻译缺失 —— 破坏后脚本均退出 1 并打印对应
FAIL 行；恢复后复跑通过。

**路由器实测（192.168.3.254）**：顶部 tab 渲染为
**设备 | Telegram机器人 | 端口转发**，三者切换正常、高亮正确；
Telegram 独立页含 7 个开关 + 17 个键盘按钮，全中文；
设备页设置区无内层 tab、5 个卡片常显、`column-count=2` 瀑布流生效；
设备表 22 下行 + 22 上行单元格，速率实时刷新（187 bit/s ~ 129.9 Kbit/s）。

**已知限制（非缺陷）**：路由器上的 `.lmo` 是 10 月 9 日刷机时从 1.8.0 编译的旧
文件，故本版新增字符串（如 `New Device Defaults`、`Display & Table`）在当前
路由器上仍显示英文。`.lmo` 由构建主机的 `po2lmo` 在打包时生成（路由器上没有该
工具），下一次固件构建会从本仓库 `.po` 重新编译。

---
## [v0.4.9] - 2026-10-10

### 修复 — 上游依赖导致整个包与中文语言包被静默丢弃

v0.4.8 的标签构建在 `Verify SQM / i18n` 步骤失败，原因**不是**上一节修掉的那个断言，
而是更深的依赖问题，且症状极其隐蔽。

**根因**：上游 1.21.4 的 `LUCI_DEPENDS` 是
`+conntrack +luci-base +rpcd +curl +tc +iw +hostapd-utils`。
其中 `hostapd-utils` 在 lede 里声明为

```
DEPENDS:=@$(subst $(space),||,$(foreach pkg,$(HOSTAPD_PROVIDERS),PACKAGE_$(pkg)))
VARIANT:=*
```

即**只有选中了某个 hostapd/wpad 变体时该符号才存在**。本固件目标是 **x86_64 且无
WiFi 硬件**（实测路由器上无 `/sys/class/ieee80211`、无 `hostapd`/`wpad` 二进制），
所以这个依赖**永远无法满足**。kconfig 的依赖求解因此把 `luci-app-trafficctl`
**整包**判定为不可选，连带 `luci.mk` 的 `LuciTranslation` 生成的语言包子包
`luci-i18n-trafficctl-zh-cn`（`DEPENDS:=$(PKG_NAME)`）一起从 `.config` 消失。

**为什么难发现**：构建**不报错**（`opkg` 只是不装这两个包），界面**只是变英文**，
没有 `exit 1` 也没有 `WARNING`。只有那一条断言会挂。而且 v0.4.6 及更早的
`Makefile` 里 `LUCI_DEPENDS:=+conntrack +luci-base +rpcd +curl` 并没有这串依赖，
所以这个坑是**随 v0.4.7 升级上游 1.21.4 一起引入的**，v0.4.7 又恰好先被另一个
断言挡住、从未走到这里，因此一直潜伏到 v0.4.8 才暴露。

**处置**：

- `package/luci-app-trafficctl/Makefile` 的 `LUCI_DEPENDS` **去掉 `+hostapd-utils`**，
  并写明理由。`hostapd_cli` 只用于「WiFi 拒绝列表立即生效」，属可选增强：
  `trafficctl-fw.sh` 调用前先做 `command -v hostapd_cli` 检测，缺失时回落到 ubus
  封禁并在界面提示；本目标无 WiFi，该功能本就不适用。
- CI 新增**反向断言**：`LUCI_DEPENDS` 一旦又出现 `hostapd-utils` 立即失败，
  避免日后「同步上游」时把坑带回来。
- CI 诊断输出修正：原诊断用 `grep -E '…trafficctl.*='`，而 kconfig 对未启用的
  bool 写的是 `# CONFIG_PACKAGE_x is not set`（**行尾没有 `=`**），因此它永远匹配
  不到、会误报「无任何 trafficctl i18n 符号」。现改为打印
  `grep -E 'trafficctl' .config` 的全部相关行，并附带 hostapd/wpad 变体状态。
- `tools/verify-trafficctl-invariants.sh` 同步加入该断言（本地可复跑）。
- `tools/regen-trafficctl-patches.py` 把 `Makefile` 纳入 `0002` 分组，
  patch 里现在记录了 `-…+hostapd-utils` / `+…` 这一行差分。

### 验证

`tools/verify-trafficctl-invariants.sh` 全绿（含 `LUCI_DEPENDS` 反向断言、
patch 在干净上游基线上重放零告警且与 vendored 包逐字节一致）。
另用负向样例确认该断言有效：把 `+hostapd-utils` 写回即被命中。

**教训**：断言一个 `CONFIG_PACKAGE_*` 之前，先确认该符号在当前目标上确实存在；
硬件相关的包只能「报告状态」，不能「必须 `=y`」。更进一步，**列出依赖时也要确认
每个包在当前目标上可满足** —— 一个不可满足的可选依赖会静默拖垮整包。

---
## [v0.4.10] - 2026-10-10

### 修复 — 1 秒刷新档位会把请求堆积到路由器上（我上一版引入的真问题）

v0.4.6 为满足「最低按 1 秒刷新」把档位放到了 1s/2s，v0.4.8 又把它接进
`_setupTimer`。但**上游的实现是 `setInterval(runQuery, iv*1000)`，不看上一拍是否
回来**。

本机实测（192.168.3.254，23 台设备）：一次 `summary` ubus 调用要 **1.5–1.9 秒**
（它要读完整 conntrack 表 1052 条 + nft 链 + `tc class`）。所以档位设成 **1 秒**时，
浏览器每 1 秒发一次、每次 1.9 秒才回 —— 请求层层堆积：rpcd 不断 fork
`trafficctl-summary.sh`，路由器 load 飙到三位数，页面反而卡住并最终
`✗ XHR request timed out`。这正是我一边观察到的现象。

**处置**：

- `status.js` 新增防重入的一拍函数 `tick()`：
  - 上一拍还在跑就**跳过这一拍**（`queryInFlight`）；
  - 页面不可见（`document.hidden`）时不轮询，避免后台标签页白耗路由器；
  - 锁的复位挂在 `runQuery` 返回的 **promise** 上，保证请求真正结束才解锁。
- 为此 `runAll()` 与 `runSingle()` 改为**返回**各自的 promise（原先它们只发起、
  不返回），`runQuery()` 也改为返回 promise，并把 `updateExtendedStats()` 纳入
  同一条链，使锁覆盖整个刷新过程而不只是「发起请求」那一刻。
- 效果：档位设 1s 时，实际节奏自动退化为后端能承受的约 2 秒一拍，**不再堆积**。

### 验证

**浏览器实测（1s 档位，20 秒窗口）**：ubus 调用 23 次；`summary`（约 1520 ms）
严格按 **2000 ms** 间隔发出 —— 1s 的 tick 触发后看到上一个未回就跳过；
**同一接口内零重叠**。

**路由器实测**：测试后 load 由三位数降到 **1.25**，`trafficctl-summary.sh`
进程数 **1**（无 ppid=1 的孤儿进程），关键服务（dnsmasq/dnsproxy/shadowsocksr）
全部正常，`ping 223.5.5.5` 往返 18 ms（移动宽带链路正常）。

**静态**：`node --check` 通过；`tools/verify-trafficctl-invariants.sh` 新增
5 项断言（`setInterval(tick,`、无 `setInterval(runQuery,`、`queryInFlight`、
`document.hidden`、`runAll`/`runSingle` 返回 promise）并全绿；
patch 在干净上游基线上重放零告警且与 vendored 包逐字节一致。

### 说明

断言脚本判断「有无 `setInterval(runQuery,`」前会先剥掉 `//` 注释行 ——
代码与自己写的解释性注释都会提到那个错误写法，不剥会导致永久误报
（这个坑在 v0.4.7 的 nft 守卫上已经踩过一次）。

---
## [v0.4.11] - 2026-10-10

### 修复 — 所有 Release 都是空的（长期存在，v0.4.5 起每个版本都没有固件）

**先说结论**：v0.4.5 ~ v0.4.10 **六个 Release 的 assets 全部为 0**，一个固件文件都没有。
而流水线除了最后一步之外**全程显示成功** —— 属于最难发现的那类静默失效。

**根因**：`Upload firmware to GitHub Release` 这一步的
`working-directory` 是**工作区根**，而本工作流用
`with.path: openwrt-build` / `with.path: lede` 把两份代码签出到了**子目录**，
根目录下**没有 `.git`**。`gh` 找不到本地仓库就无法确定目标仓库，于是：

```
failed to run git: fatal: not a git repository (or any of the parent directories): .git
```

更糟的是当时的等待循环写成了
`if gh release view "$VER" >/dev/null 2>&1; then break; fi` ——
它把**任何**失败都当成「Release 还没创建」，于是这个硬错误被吞掉、白等 60 秒，
最后只抛出一句 `Release vX 不存在（release.yml 未运行？）`，把根因指向了错误的方向。

**处置**：

- 该步骤显式声明 `GH_REPO: ${{ github.repository }}`（官方文档明确支持该环境变量，
  用于「otherwise operate on a local repository」的命令）。
- 等待循环改为**区分两类失败**：只有「未找到」才继续等待，其他失败立刻
  打印真实输出并 `exit 1`。
- 新增**兜底断言**：上传结束后 Release 上至少要有一个 `.img.gz`，否则 `exit 1`。
  这正是本次能发现该问题的机制 —— 以前「上传失败但步骤不报错」的组合
  会让空 Release 一直存在。

### 验证

- **复现**：在无 `.git` 的目录里跑 `gh release view v0.4.10` → 得到上述
  `fatal: not a git repository`；加上 `GH_REPO` 后同一命令成功。
- **控制流测试**（用假 `gh` 打桩，不触碰远端仓库）三个场景全部符合预期：
  A. 未设 `GH_REPO` → 立刻报硬错误（不再白等 60s）；
  B. 设了 `GH_REPO` 且 Release 尚未创建 → 等满后走 `gh release create` 兜底并上传 2 个文件；
  C. Release 已存在 → 正常上传。
- **幂等性与断言**单独验证：assets 为空→上传；含同名→跳过；只有旧版本→上传新版本；
  名字只是前缀相近（`<name>.bak`）→不误判为已存在；
  兜底断言的 `grep -c '\.img\.gz$'` 在空 assets 下得 0（会正确失败）、有产物时得 1。
- `bash -n` 通过；YAML 合法（26 步）；`tags` 与新增的 `paths-ignore` 均保留。

**注意**：本次修复只影响**今后**的发版。v0.4.5 ~ v0.4.10 的 Release 仍是空的 ——
它们对应的固件在 Actions artifact 里（如
`openwrt-x86-64-ssrplus-v0.4.10-51fb93f`，255 MB），但未附加到 Release。

### 变更 — 纯文档推送不再触发 3.5 小时编译

`on.push` 新增 `paths-ignore`（`**.md` / `docs/**` / `.gitignore` / `LICENSE`）。
安全性依据是 GitHub 官方文档原文 *"Path filters are not evaluated for pushes of tags."*
—— 只对分支推送生效，推 tag 仍照常触发，不影响发版。本次提交本身即为实测：
只改 `.yml` 仍正常触发。

---
## [v0.4.12] - 2026-10-10

### 修复 — Release 上传失败的**第二个**根因：工作流令牌权限

v0.4.11 修掉了 `GH_REPO` 缺失（gh 在非 git 目录无法确定仓库），并在 v0.4.11 的
tag 构建里**确认那一步已生效** —— 日志出现了
`>>> 将固件产物上传到 Release v0.4.11（仓库 youridol/openwrt-build）`，
并且正常列出了两个固件文件。但紧接着上传仍被拒：

```
HTTP 403: Resource not accessible by integration
   (.../releases/408449361/assets?name=openwrt-x86-64-ssrplus-v0.4.11-1b42cf0-…img.gz)
```

这是**令牌权限不足**的典型报错。核对后确认：

| 工作流 | permissions 声明 | 结果 |
|---|---|---|
| `release.yml` | `contents: write` | 能创建 Release —— 一直正常 |
| `build-openwrt.yml` | **没有**（故取仓库默认） | 上传产物被拒 403 |

而本仓库的默认工作流令牌权限是 **`read`**：
`gh api repos/youridol/openwrt-build/actions/permissions/workflow`
→ `{"default_workflow_permissions":"read"}`。

**两个工作流的令牌是各自独立申请的** —— `release.yml` 声明了写入权限所以能建
Release，`build-openwrt.yml` 没声明就只有只读权限、传不了 assets。
这解释了为什么「Release 建得出来、固件一个都传不上去」能长期共存：
两个问题互相掩盖，只看最后那句误导性的错误提示会一直找错方向。

**处置**：`build-openwrt.yml` 顶层新增

```yaml
permissions:
  contents: write
```

与 `release.yml` 保持一致。

### 验证

- **v0.4.11 的日志已确认前一修复生效**：`GH_REPO` 存在、目标仓库正确、
  固件文件已枚举（`ls -l` 列出了两个 `.img.gz`）。
- **第二个根因有直接证据**（不再是推断）：v0.4.11 构建的 `Set up job` 步骤
  打印了它实际拿到的令牌权限 ——
  ```
  GITHUB_TOKEN Permissions
    Contents: read
    Metadata: read
    Packages: read
  ```
  `Contents: read` 正是 `gh release upload` 收到
  `HTTP 403: Resource not accessible by integration` 的原因；
  该 403 的 endpoint 与 GitHub 文档「Upload a release asset」
  （`POST /repos/{owner}/{repo}/releases/{release_id}/assets`）一致。
- **A/B 直接对照（同一天、同一仓库实测）**：
  - `release.yml`（声明 `contents: write`）运行时打印 `Contents: write` → 能建 Release；
  - `build-openwrt.yml`（v0.4.11，未声明）运行时打印 `Contents: read` → 上传被 403 拒。
  两者唯一差别就是 `permissions` 声明，构成干净的对照实验。
- **修复已由 v0.4.12 的 tag 构建端到端验证通过**（构建结论 `success`）：

  | 版本 | Release 产物 | `.img.gz` |
  |---|---|---|
  | **v0.4.12** | **4 个** | **2 个** ✓ |
  | v0.4.11 及更早 | 0 个 | 0 个 ✗ |

  上传的校验文件与 GitHub 自己计算的文件摘要**逐字节一致**，证明上传内容完整：

  ```
  combined-efi.img.gz   58e4bd5a341ad28c7c86043da1c24a3d63afaadb465f40b0bb64b8d1206e356d
  rootfs.img.gz         6182e2bb09a17c1279ffff5195c8ff64b6a1e89c032330722884c07e0163aca6
  ```

  Release notes 确认取自 `CHANGELOG.md` 对应版本段。

### 说明

v0.4.5 ~ v0.4.11 的 Release 均为空。固件本身**都已成功编译**并保存在
Actions artifact 里（如 `openwrt-x86-64-ssrplus-v0.4.11-1b42cf0`），
只是没能附加到 Release。补齐属发布动作，需另行确认。

---
## [v0.8.4] - 2026-10-17

### 修复 — tproxy 端口列表含 53，导致 v2ray 抢走 dnsmasq 的 DNS 包

**这是「启用 SSR-Plus 后客户机连 baidu 都解析不了、过一阵又自己好」的真正根因。**
前三轮（v0.8.0~v0.8.3）修的是真实缺陷，但都不是这一条。

**故障表现**：启用后约 1~2 分钟开始，客户机**所有**域名（含 `baidu.com`、
`bilibili.com`）解析超时；再等几分钟自行恢复；如此循环。用户截图里
apple / github / google / youtube / bilibili / baidu **六个全红**。
而路由器自身解析始终正常（走 `/etc/resolv.conf` 的运营商 DNS）。

**根因：客户机 DNS 同时命中两条拦截路径，且 tproxy 那条先赢**

`dports='2'`（常用端口）对应的端口列表原本含 **53**：

```sh
proxyport="-m multiport --dports 22,53,587,465,995,993,143,80,443,853,9418"
```

于是客户机 UDP/53 会被 `ss_spec_mangle prerouting`（priority **mangle = -150**）
TPROXY 到 `:1234` 交给 v2ray。但客户机 DNS 本已被 fw4 的
`dns_intercept_lan`（priority **dstnat+1 = -99**）劫持到本机 dnsmasq ——
**两条路径必须只留一条，而 mangle(-150) 比 dstnat+1(-99) 更早执行**，
所以 tproxy 先命中，dnsmasq 根本收不到包。

**nft 计数器给出决定性证据**（插入三个调试计数器后发一次查询）：

```
DBG-dns-pre   packets 48    ← 客户机 DNS 到达 prerouting/mangle
DBG-dns-nat   packets 0     ← 从未到达 dstnat 的 dns_intercept_lan
DBG-dns-in    packets 0     ← 从未进入 input 链
```

**v2ray 会为每个被 tproxy 的 DNS 打开一个绑定 `192.168.3.254:53` 的
UDP socket 且不释放**，累积后反过来抢走 dnsmasq 的 DNS 包。实测累积过程
（每 6 秒采样）：

```
23:11:49  socket=1    解析=1     ← 正常
23:11:56  socket=4    解析=0     ← 开始堆积
23:12:03  socket=13   解析=0
23:12:10  socket=50   解析=0
23:12:17  socket=91   解析=0
23:12:24  socket=167  解析=0
23:12:31  socket=220  解析=0
23:12:38  socket=246  解析=0     ← 完全不可用，连 baidu 也超时
```

峰值观测到 **283 个** UDP socket 全部绑定 `192.168.3.254:53`，且 283 个的
`rx_queue` 全为非零（数据积压从未被排空）。用 inode 反查确认这些 fd
属于 v2ray（PID 1954 持有 22/23 个，而 dnsmasq 只有 1 个）。

**为什么「自己会好」**：`ssr-monitor` 或用户重启 SSR 后 v2ray 重启、
socket 归零 → 短暂恢复 → 随后再次堆积。这就是周期性的来源。

### 变更

**`files/etc/uci-defaults/99-gaming-optimize`：从 `dports=2` 的端口列表移除 53**

```diff
-proxyport="-m multiport --dports 22,53,587,465,995,993,143,80,443,853,9418"
+proxyport="-m multiport --dports 22,587,465,995,993,143,80,443,853,9418"
```

**关键坑：只改运行时 nft 规则不够。** 旧的持久化规则
`/usr/share/nftables.d/ruleset-post/99-shadowsocksr.nft` 里仍含 53，
`fw4` 重载会把它加回来。必须同时改 init 脚本里的端口列表，让
`ssr-rules -P` 重新生成的持久化文件也不含 53。补丁里已包含「检测并删除
含 53 的旧持久化文件」这一步。

**已验证**

- 重建后规则：`udp dport { 22, 80, 143, 443, 465, 587, 853, 993, 995, 9418 }`
  —— **不含 53**；持久化文件同步更新
- `192.168.3.254:53` socket 数从 283 → **1**
- 3 分钟持续 DNS 压力（每 8 秒采样，每轮 5 个域名）：socket 恒为 1，解析 100% 成功
- 完整复现启用流程 + 66 秒连续观测：**40/40 全部 OK，0 次失败**（修复前 12/30 失败）
- 长窗口 6 分钟：`socket` 恒为 1，全部 OK
- 用户截图六个站点：`apple 200` / `github 200` / `google 302` / `youtube 200` /
  `bilibili 200` / `baidu 200`
- 脚本连跑 2 次幂等：`gs`/`sw`/`v082=2`/`v083=4`/`v084=1`/`rule=14` 全部稳定

### 本轮排查方法论（重要）

1. **「路由器自己正常、客户机不正常」必须查 `192.168.3.254:53` 的 socket 归属**，
   不能只测 `127.0.0.1:53`。前者是客户机实际使用的地址，被 v2ray 抢占时
   `netstat -lnup | grep -c '192.168.3.254:53'` 会明显 > 1。
2. **用 `nft` 计数器分段定位 DNS 包走到哪一步**，而不是猜。三个计数器
   （prerouting / dstnat / input）一次查询就能区分「没到」「被劫走」「被丢」。
3. **`ip daddr 192.168.0.0/16 return` 这条豁免看起来能救，但它救不了** ——
   客户机 DNS 的目标确实是 `192.168.3.254`（在豁免范围内），
   可 tproxy 规则 `udp dport {22,53,...} ip daddr != @ss_spec_wan_ac`
   之前的规则先按 dport 命中了别的分支。**判定时要按 dport 而非只按 daddr。**
4. **`netstat` 对多 socket 归因不可靠**，要确认 socket 属于谁，
   用 `/proc/net/udp` 拿 inode 再反查 `/proc/<pid>/fd`。

---
## [v0.8.5] - 2026-10-19

### 修复 — 定时构建连续失败：校验脚本用了 dash 不支持的进程替换

**症状**：10-18、10-19 两次定时构建在 `Verify luci-app-trafficctl local invariants`
步骤失败，报错只有一行：

```
tools/verify-trafficctl-invariants.sh: 494: Syntax error: "(" unexpected
##[error]Process completed with exit code 2.
```

**根因**：该脚本在 v0.7.0 提交里被大幅扩写（337 行 → 984 行），新增的列键集
断言用了 **bash 专有的进程替换** `<(...)`：

```sh
diff <(printf '%s\n' "$_HIDDEN_KEYS") <(printf '%s\n' "$_CHIP_KEYS") || true
```

而 CI 用 `sh tools/verify-trafficctl-invariants.sh` 调用，ubuntu runner 的
`/bin/sh` 是 **dash**。进程替换在 dash 里不是运行时错误，而是**解析期语法错误** ——
整个脚本连第一行都没执行就 exit 2，于是编译步骤全部 skipped，
`Compile firmware` / `Upload artifacts` 都是 `skipped`，自然没有产物。

**为什么本地看不出来**：本机（WSL）用 `bash` 跑同一脚本时 163 条断言全绿。
只有用 `sh` 才会暴露 —— 这正是「本地过了 CI 挂」的形态。

**共 3 处进程替换**（全部改为临时文件，临时目录由脚本头部 `$TMPD` 提供，
`trap ... EXIT` 统一清理）：

| 行 | 用途 | 改法 |
|---|---|---|
| 494 | `diff` 两个键集 | 先 `printf > "$TMPD/*.keys"` 再 `diff 两文件` |
| 508 | `comm -23` 求差集 | 两个键集落盘后 `comm -23 文件 文件` |
| 983 | `cmp` 比对去掉 CR 后的内容 | 各自 `tr -d '\r' > "$TMPD/cr_a"` 后 `cmp` |

### 新增 — 三道守卫，防止同类问题再次静默通过

1. **`sh -n` 解析前置检查**（`Verify invariants script is POSIX sh (dash) compatible`，
   排在跑断言**之前**）：解析失败时直接打印「含 bash 专有语法」，不再让人对着
   `Syntax error: "(" unexpected` 猜第 494 行是什么。
2. **`Upload artifacts` 改 `if-no-files-found: error`**：该参数默认是 `warn`，
   语义是「没匹配到文件也照样成功」→「构建绿了、Actions 上却没有产物」。
   固件是本流水线唯一交付物，缺了就该红。
3. **`Assert firmware artifact exists`**：`upload-artifact` 之后用 Actions API
   (`gh api .../actions/runs/<id>/artifacts`) 核对本次 run 的实际 artifact 计数，
   为 0 则 `exit 1`。`if-no-files-found` 只保证「有文件被匹配到」，不保证上传成功；
   这里以 API 计数为准。为此在 `permissions` 补 `actions: read`
   （声明 permissions 后未列出的 scope 一律为 none，不会回落到仓库默认）。

### 变更

- `.github/workflows/build-openwrt.yml`：新增 2 步（解析检查、产物断言），
  `Upload artifacts` 加 `if-no-files-found: error`，`permissions` 补 `actions: read`。
- `tools/verify-trafficctl-invariants.sh`：3 处进程替换改为临时文件；
  文件头补「必须保持 POSIX sh 兼容」的说明与 `$TMPD`/`trap`。

### 验证

- `sh -n tools/verify-trafficctl-invariants.sh` → 退出码 0（修复前该命令在 dash 下
  直接报 `Syntax error: "(" unexpected`）。
- `sh tools/verify-trafficctl-invariants.sh`（**用 dash，与 CI 同一条命令**）→
  退出码 0，163 条 `OK`、0 条 `FAIL`；第 5/7 节（文件模式、patch 重放）均实际执行到
  「重放结果与 vendored 包逐字节一致」。
- 工作流经 PyYAML 解析：`permissions` 为 `{contents: write, actions: read}`；
  步骤顺序为 …→ 解析检查(9) → 跑断言(10) → … → 编译(24) → 改名(25) →
  上传产物(26) → 产物断言(27) → 上传 Release(28)。
- **尚未经真实 CI 构建验证**：本地无 GitHub Actions runner，上述为静态与脚本级
  验证。下一次 master 推送或定时构建通过、且 Actions 页面确实出现 artifact，
  才算端到端闭环。

---
## [v0.12.5] - 2026-10-22

### 变更 — 解析链路图改为思维导图形态（带弧度、不断链）

用户要求：审计实际链路是否正确；把链路图改成思维导图，不能断链，
分叉处要带弧度。

#### 一、链路审计结果：图与实际一致

逐段实测（`nslookup -port`，BusyBox 只支持这个写法）：

| 边 | 实测结果 | 判定 |
|---|---|---|
| 边1 国内 经 :53 | `183.2.172.177` | ✅ 与直连 :5353 一致 |
| 边1 国外 经 :53 | `142.251.150.119` | ✅ 真实 Google IP |
| 边2 国内 直连 :5353 | `183.2.172.177` | ✅ 走默认上游 |
| **边2' 国外 直连 :5353** | **`157.240.7.20`** | ⚠️ **被污染**（Facebook 的 IP 冒充 google） |
| 边3 国外 直连 :5336 | `142.251.155.119` | ✅ 真实 Google IP |
| 边3' 国内 直连 :5336 | `103.235.47.188` | ✅ 能解析（但绕道国外上游） |

**边2' 是本次审计最有价值的一条**：它证明「国外域名若不经过
`server=/域名/#5336` 分流、而走默认上游，就会拿到污染 IP」——
这正是分流存在的理由，也印证图上的分叉是必需的。

其余核对项全部符合预期：

```
dnsmasq 默认上游        server=127.0.0.1#5353（1 条）
指向 #5336 的分流       17813 条
指向 #5335 的残留       0 条        ← chinadns-ng/mosdns 已彻底移除
nftset 目标            inet ss_spec blacklist
国内 dnsproxy 上游       tls://223.5.5.5, tls://223.6.6.6, alidns DoH
国外 dnsproxy 上游       dns.google DoH, cloudflare-dns.com DoH
SSR-Plus               :1234 监听、pdnsd_enable=0、ipv6_support=1、
                       router_proxy=1、global_server=cfg0a4a8f
AAAA                   国内 240e:950:400:1:3::6d、国外 2001:4860:4829:7700::
```

#### 二、链路图改造

**① 直角折线 → 贝塞尔弧线**

原来分叉用 `H V H` 直角折线，拐角是硬边，视觉上像「断链」。
改为三次贝塞尔 `C` 指令，曲率连续。

曲线控制点取值调了三轮，每轮都有实测依据：

| 轮次 | dx 取值 | 结果 |
|---|---|---|
| ① | 跨度 × 45% = 27px | 垂直落差 84px，曲线几乎垂直下坠，仍像折角 |
| ② | 跨度一半 + 落差 35% = 57px | 水平跨度只有 60px，控制点顶到终点，起点出现小折角 |
| ③ | 落差 × 0.62，上限 跨度/2 | 起点切线约 30°，整条平滑 S 形 |

**② 修掉自交扭结（真实 bug）**

第 ② 轮生成的路径是：

```
C 415 169, 373 85, 424 85
         ↑         ↑
      第一控制点  第二控制点   ← 415 > 373，控制点交叉
```

控制点交叉会让曲线在中间**兜回来**、形成自交的 S 扭结 —— 这就是
用户看到的「断链」。修复：加硬上限 `dx <= (x2-x1)/2`。

**③ 加大列间距给曲线留空间**

跨度 60px 时 dx 上限只有 30px，弧度仍然受限。把 `X2→X3` 从
188 拉到 216（节点间距 60→88px），`X4` 相应右移，`W` 从 1060
加到 1120。实测修复后控制点完全对称：`C 400 169, 400 85`。

**④ 箭头按状态色分别定义**

原来只定义一个固定灰色箭头 `dca`。红/绿连线配灰箭头，看起来
像没连上。改为 `dc-a-ok` / `dc-a-warn` / `dc-a-bad` 三个，
按连线状态色选。

**⑤ 节点加填充**

原来 `fill="none"`，连线画在节点下层会从节点内部透出来，
视觉上像「穿过节点」。改为 `fill="var(--dc-surface)"`。

**⑥ 分叉标注移位**

分叉处水平只有 60px、垂直落差 84px，标签放进去必然压线
（实测「默认」直接盖在曲线上）。改放到两个 dnsproxy 节点的
上方/下方空白区：`默认 → 国内上游`、`gfw 域名 → 经代理出站`。

**⑦ 水平连线也改为弧线**

用 `Q` 二次贝塞尔，中点下沉 3px，比直线更有生长感，同时
起止切线水平，不会在节点边缘留缝。

#### 三、验证

页面实测（浏览器 DOM）：

```
viewBox="0 0 1120 372"
连线 6 条：2 条 C 贝塞尔（分叉）+ 4 条 Q 弧线
控制点交叉扭结：0 处
箭头标记：3 个（ok/warn/bad）
节点：7 个，全部 fill=var(--dc-surface)
```

几何约束：`W=1120 > 最右节点右边缘 1064`，余量 56px。

链路本身未受影响：selftest **16/16 PASS**，`CONCLUSION: 链路正常`。

#### 四、CI 新增五条断言

```
必须用贝塞尔 C 指令画分叉（H/V 直角折线会像断链）
箭头必须按状态色定义 >= 3 个
曲线控制点必须有交叉保护（dx <= 跨度/2）
节点 fill 必须是 --dc-surface（否则连线透出，像断链）
viewBox 必须容得下最右节点（沿用 v0.12.3）
```

---
