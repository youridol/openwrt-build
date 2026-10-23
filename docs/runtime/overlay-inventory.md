# `files/` overlay 全清单

`files/` 是 rootfs overlay：构建时 `cp -r ../openwrt-build/files ./` 复制进 `lede/files/`，打包阶段合并进固件根文件系统（`.github/workflows/build-openwrt.yml:962-974`）。它**不是**上游源码，改动直接生效于下一次构建。

## 1. 全清单

共 **20 个文件**（`files/` 下递归计数）。执行位列取自 `git ls-files -s files/`，即仓库索引里的真实模式位。

| 路径 | 类型 | 索引模式 | 执行位要求 | 作用 | 关键行号 |
|---|---|---|---|---|---|
| `files/etc/rc.local` | 可执行脚本 | `100755` | 需要 `+x`（overlay 已带） | 每次启动后的运行时优化：CPU governor 设 `performance`、`txqueuelen` 降到 100、网卡 IRQ 绑核、`busy_read`/`busy_poll` 设 50 | `:8-10`（governor）、`:31-33`（txqueuelen）、`:38-43`（IRQ affinity）、`:46-47`（busy poll）、`:12-27`（说明为何删掉 RPS 段） |
| `files/etc/sysctl.conf` | sysctl | `100644` | 不需要 | 全局内核参数：BBR、`tcp_fastopen=3`、UDP/rmem/wmem、conntrack 超时、`fq_codel`、`netdev_max_backlog=5000`、IPv6 转发与 DAD、`nf_conntrack_max=131072` | `:5-6`（BBR）、`:18-20`（fastopen/wmem）、`:27-28`（conntrack UDP 超时）、`:44-56`（IPv6 双栈）、`:60`（qdisc）、`:64`（backlog）、`:69-70`（busy poll）、`:88`（conntrack max） |
| `files/etc/sysctl.d/50-dnsproxy.conf` | sysctl | `100644` | 不需要 | 只做一件事：把 `rmem_max`/`wmem_max` 抬到 7500000，供 quic-go（DoQ/HTTP3）用 | `:3-4` |
| `files/etc/capabilities/dnschain-filter.json` | capabilities | `100644` | 不需要 | 授予 `CAP_NET_ADMIN`/`CAP_NET_BIND_SERVICE`/`CAP_NET_RAW` 的 capabilities 文件。**当前无消费者**（详见 `docs/runtime/dns-chain.md` §10.8） | `:2-26`（五个集合，各三项） |
| `files/etc/capabilities/dnsproxy.json` | capabilities | `100644` | 不需要 | 只授予 `CAP_NET_BIND_SERVICE`，被 `init.d/dnsproxy` 引用 | `:2-16`；消费点 `files/etc/init.d/dnsproxy:319` |
| `files/etc/config/dnschain` | config（UCI） | `100644` | 不需要 | 框架全部配置：总开关、两个端口、两池上游、AAAA 策略、名单源、缓存条目数、自定义列表段、健康探测与阈值、自检段、SSR 兼容段 | `:42-54`（main）、`:56-60`（cn 上游）、`:62-72`（foreign 上游）、`:74-82`（aaaa）、`:84-93`（lists）、`:95-99`（dhcp_dns）、`:101-104`（cache）、`:136-141`（domains）、`:163-191`（health，含 8 个 watch）、`:193-195`（selftest）、`:197-204`（ssr compat） |
| `files/etc/config/dnsproxy` | config（UCI） | `100644` | 不需要 | 框架**关闭时**才决定 dnsproxy 启动参数；取值与框架默认值保持一致。缓存 `enabled='0'`、`ipv6_disabled='0'`、无 `fallback` | `:21-41`（global）、`:46-63`（cache 关闭）、`:73-75`（hosts）、`:81-123`（servers + bootstrap）、`:125-140`（删除 fallback 的理由）、`:142-150`（tls 服务端关闭） |
| `files/etc/config/sqm` | config（UCI） | `100644` | 不需要 | cake 整形默认值：下行 900000 / 上行 45000 kbit/s、`overhead 34`、`tcMPU 68`、`piece_of_cake.qos`、`dual-dsthost`/`dual-srchost` | `:34-55`（全部选项）、`:9-20`（带宽与链路层取值依据）、`:22-31`（队列策略说明） |
| `files/etc/hotplug.d/iface/50-ipv6-pd-lan` | hotplug 脚本 | `100755` | 需要 `+x`（overlay 已带） | `wan_6` `ifup` 时 `sleep 3` 后 `ifup lan`，修复 PD 前缀拿到但 LAN 未应用的问题 | `:5-6`（双条件过滤）、`:8-9`（sleep + ifup） |
| `files/etc/init.d/dnschain` | init.d（procd） | `100644` | **需要** `+x`，靠 CI 补 | 框架服务脚本：生成运行时配置、preflight 校验、托管两个 dnsproxy 与健康守护、生成 fw4 片段、抑制重复重启 dnsmasq | `:29-31`（START/STOP/USE_PROCD）、`:38`（853 片段路径）、`:46-73`（generate_all）、`:161-215`（preflight）、`:233-269`（update_dot_reject）、`:274-290`（国内实例）、`:302-317`（国外实例）、`:342-352`（标记文件）、`:366-381`（健康实例）、`:422-462`（stop_service）、`:464-494`（reload_service） |
| `files/etc/init.d/dnsproxy` | init.d（procd） | `100755` | 需要 `+x`（overlay 已带） | 上游 dnsproxy 服务脚本 + 本地 ALL_DOH 扩展：LAN DNS 拦截的 nft/iptables 片段、**dnschain 让位逻辑** | `:17-18`（USE_PROCD/START）、`:24`（拦截片段路径）、`:157-189`（fw3/iptables 分支）、`:199-256`（按后端分派）、`:222-231`（fw4 裸 chain）、`:273-275`（让位判据）、`:280-287`（让位时不动拦截规则）、`:346-356`（reload 转发给 dnschain） |
| `files/etc/ssrplus/applechina.conf` | ssrplus overlay | `100644` | 不需要 | 173 条 Apple 域名分流，全部指向 `127.0.0.1#5353`（加密入口），替代上游的明文 `114.114.114.114` | `:1-18`（说明与两条硬约束）、`:19-191`（173 条 `server=`）；行数断言 `.github/workflows/build-openwrt.yml:1285-1309` |
| `files/etc/ssrplus/mosdns-config.yaml` | ssrplus overlay | `100644` | 不需要 | SSR-Plus 的 mosdns 模板副本。**`upstreams:` 必须正好在第 14 行**（init 用 `awk -v line=14` 注入），`reject 0` 前置到 `forward_google` 之前 | `:10-14`（forward_google 与 `upstreams:`）、`:16-24`（disable_IPv6 序列，含 reject）、`:26-30`（with_IPv6）、`:44-63`（契约说明与差异理由）；断言 `build-openwrt.yml:996-1033` |
| `files/etc/uci-defaults/99-gaming-optimize` | uci-defaults | `100755` | 需要 `+x`（overlay 已带） | 首刷默认值总入口：防火墙/flow offloading/MTU 修复、IPv6 双栈、LAN 固定 IP、SSR-Plus 的 MosDNS 与 AAAA 开关、dnsmasq 上游与并发槽、对 `init.d/shadowsocksr` 的四处幂等补丁、dnsmasq 日志改 syslog | `:290-306`（SSR 铺底 + `pdnsd_enable=4` + `tunnel_forward_mosdns`）、`:436-524`（v0.8.3 restart 守卫补丁）、`:527-595`（v0.8.4 移除 53）、`:597-726`（v0.8.6 并发守卫补丁）、`:729-762`（dnsmasq 上游与 `dnsforwardmax`）、`:764-799`（`filter_aaaa='1'`）、`:801-834`（日志改 syslog）、`:118-152`（MSS clamp 已移除的说明）、`:836-846`（commit 全部） |
| `files/etc/uci-defaults/99-zz-dnschain` | uci-defaults | `100644` | **需要** `+x`，靠 CI 补 | 框架首刷默认值：SSR-Plus 交给框架（`pdnsd_enable=0`、`ipv6_support=1`、`filter_aaaa=0`）、dnsproxy 拦截开关、dnsmasq 唯一上游与 `serversfile`、首轮生成运行时文件 | `:23-26`（配置文件存在性）、`:37-50`（`pdnsd_enable` → 0）、`:52-80`（IPv6 与 `filter_aaaa`）、`:93-99`（dnsproxy 键）、`:104-121`（dnsmasq 上游/槽/缓存）、`:128-153`（首轮生成）、`:155-184`（`serversfile` 走库常量） |
| `files/etc/uci-defaults/99-zzz-luci-theme-shadcn` | uci-defaults | `100644` | **需要** `+x`，靠 CI 补 | 把 shadcn 设为 LuCI 默认主题：无条件写 `luci.main.mediaurlbase`，覆盖主题自带 `30_luci-theme-shadcn` 的存在性短路 | `:30-39`（主题文件存在性守卫）、`:41-45`（注册主题）、`:47-54`（无条件设默认）、`:56`（commit）；排序断言 `build-openwrt.yml:948-956` |
| `files/usr/bin/dnschain-health` | 可执行脚本 | `100755` | 需要 `+x`（overlay 已带） | 健康探测与改道的 CLI：`cycle`/`daemon`/`status`/`explain`/`check`/`apply`/`reset`/`flush` 八个子命令 | `:16-23`（子命令说明，漏列 `flush`）、`:76-124`（status 的 ROW/SUM）、`:135-181`（check）、`:205-264`（apply：5 条正常出口 `restarted`/`sighup`/`unchanged`/`skipped（框架未启用）`/`skipped（无 init.d/dnsmasq）`，加 2 条 `ERROR=` 失败出口）、`:272-278`（reset）、`:309-316`（flush）、`:318-338`（daemon）、`:343-364`（入口） |
| `files/usr/bin/dnschain-reconcile` | 可执行脚本 | `100644` | **需要** `+x`，靠 CI 补 | 收敛器：把 SSR-Plus / dnsmasq / dnsproxy 的白名单键归一，名单单向导入，nftset 归零自愈，dnsmasq 日志自愈 | `:51-237`（reconcile_invariants）、`:63-112`（SSR 键归一）、`:122-139`（dnsmasq 键与唯一上游）、`:164-189`（nftset 自愈）、`:197-207`（端口集只校验）、`:213-234`（日志自愈）、`:245-310`（reconcile_lists）、`:316-362`（reconcile_intercept）、`:367-414`（main 的四处重启条件） |
| `files/usr/bin/dnschain-selftest` | 可执行脚本 | `100644` | **需要** `+x`，靠 CI 补 | 20 项全链路自检，带 60 秒结果缓存与指纹失效 | `:31-42`（emit）、`:99-575`（check_all 的 20 项）、`:580-672`（main 与退出码）、`:680-694`（原子写缓存）、`:698-740`（指纹） |
| `files/usr/share/dnschain/dnschain.sh` | 库 | `100644` | **需要** `+x`，靠 CI 补（三个脚本都 `source` 它） | 被 init、reconcile、selftest、health 共同 source 的函数库：配置读取、名单解析、归属判定、分流生成、dnsmasq PID 定位、硬超时执行、DNS 五分类、健康状态读写、改道判定、端口校验 | `:20-26`（路径常量）、`:40-50`（`dc_get`/`dc_get_list`）、`:162-179`（名单提取）、`:201-221`（`dc_exclude`）、`:332-372`（国内参数）、`:381-417`（国外参数）、`:454-491`（`dc_dnsmasq_pid`）、`:509-516`（端口集）、`:607-611`（四个运行时路径）、`:827-887`（归属判定）、`:1046-1149`（分流生成）、`:1165-1231`（watch.servers）、`:1282-1362`（硬超时）、`:1380-1425`（五分类）、`:1493-1509`（状态写盘）、`:1587-1770`（`dc_health_cycle`）、`:1943-1972`（端口校验） |

### 1.1 关于「18 个文件」

任务描述里的清单实际列出了 **20 个路径**，与 `files/` 下的真实文件数一致（`Get-ChildItem files -Recurse -File` = 20）。没有遗漏，也没有多余。

## 2. uci-defaults 执行顺序与覆盖关系

`uci-defaults` 按**文件名 C 排序**执行。实测（`printf '%s\n' 99-gaming-optimize 99-zz-dnschain 99-zzz-luci-theme-shadcn 30_luci-theme-shadcn | LC_ALL=C sort`）：

```
30_luci-theme-shadcn
99-gaming-optimize
99-zz-dnschain
99-zzz-luci-theme-shadcn
```

即仓库提供三个脚本的顺序是 `99-gaming-optimize` → `99-zz-dnschain` → `99-zzz-luci-theme-shadcn`，且主题包自带的 `30_luci-theme-shadcn` 排在最前。

顺序被刻意依赖，且 CI 有断言：

| 依赖 | 说明 | 证据 |
|---|---|---|
| `99-zz-dnschain` 必须晚于 `99-gaming-optimize` | 要覆盖后者写的 `pdnsd_enable=4` | `files/etc/uci-defaults/99-zz-dnschain:7-9`、`:34-35`；断言 `build-openwrt.yml:1207-1218` |
| `99-zzz-luci-theme-shadcn` 必须晚于 `30_luci-theme-shadcn` | 要覆盖主题包的存在性短路，无条件设默认主题 | `files/etc/uci-defaults/99-zzz-luci-theme-shadcn:21-23`；断言 `build-openwrt.yml:948-956` |

### 2.1 顺序导致的覆盖关系

| 键 | 先写的值 | 后写的值 | 最终生效 | 证据 |
|---|---|---|---|---|
| `shadowsocksr.@global[0].pdnsd_enable` | `'4'`（gaming） | `'0'`（zz-dnschain） | **`'0'`** | `99-gaming-optimize:303-304` → `99-zz-dnschain:45-50` |
| `shadowsocksr.@global[0].filter_aaaa` | `'1'`（gaming） | `'0'`（zz-dnschain） | **`'0'`** | `99-gaming-optimize:796-799` → `99-zz-dnschain:75-80`；另有 `dnschain-reconcile:97-98` 每次收敛再归一 |
| `shadowsocksr.@global[0].tunnel_forward_mosdns` | 写入 DoH 串（gaming） | **无人覆盖** | 保留 gaming 写入的值 | `99-gaming-optimize:305-306`；`99-zz-dnschain:82-83` 明确「不删除该键」 |
| `dhcp.@dnsmasq[0].cachesize` | `'8192'`（gaming，硬编码） | 读 `dnschain.cache.size`（zz-dnschain） | 页面配置值 | `99-gaming-optimize:736` → `99-zz-dnschain:108-120`；`dnschain-reconcile:150-162` 每次收敛再归一 |
| `dhcp.@dnsmasq[0].server` | `127.0.0.1#5353`（gaming） | 同样 `127.0.0.1#5353`（zz-dnschain，先 delete 再 add） | 恰好 1 条 | `99-gaming-optimize:732-734` → `99-zz-dnschain:104-105` |
| `luci.main.mediaurlbase` | 主题自带脚本可能短路不改 | 无条件写 `/luci-static/shadcn` | `/luci-static/shadcn` | `99-zzz-luci-theme-shadcn:47-54` |

前两条（`pdnsd_enable`、`filter_aaaa`）的覆盖是**设计意图**；`tunnel_forward_mosdns` 的「残留」不是设计意图，属代码内部不一致（详见 `docs/runtime/dns-chain.md` §10.2）。

## 3. `.gitattributes` 对 overlay 的强制 LF 规则

CRLF 会导致 `git apply` 失败与路由器上 shell 解析失败，故无扩展名的 overlay 文件必须逐条强制 LF。

规则分三层（`.gitattributes` 全文 72 行）：

### 3.1 兜底层

| 规则 | 行号 | 说明 |
|---|---|---|
| `* text=auto eol=lf` | `:15` | 按内容自动判定文本/二进制，文本一律 LF。`text=auto` 会让 git 自行跳过二进制文件 |

### 3.2 按扩展名层

| 规则 | 行号 |
|---|---|
| `*.patch` / `*.sh` / `*.nft` / `*.conf` / `*.json` / `*.yml` / `*.yaml` / `*.md` | `:20-27` |
| `*.css` / `*.js` / `*.po` / `*.pot` / `*.htm` / `*.html` / `*.txt` | `:29-35` |
| `*.ps1` | `:38` |

### 3.3 无扩展名 overlay 的逐条规则

| 规则 | 行号 | 对应文件 |
|---|---|---|
| `**/etc/config/dnsproxy` | `:47` | `files/etc/config/dnsproxy` |
| `**/etc/config/sqm` | `:48` | `files/etc/config/sqm` |
| `**/etc/init.d/dnsproxy` | `:49` | `files/etc/init.d/dnsproxy` |
| `**/etc/uci-defaults/99-gaming-optimize` | `:50` | `files/etc/uci-defaults/99-gaming-optimize` |
| `**/etc/hotplug.d/iface/50-ipv6-pd-lan` | `:51` | `files/etc/hotplug.d/iface/50-ipv6-pd-lan` |
| `**/etc/rc.local` | `:52` | `files/etc/rc.local` |
| `**/etc/sysctl.conf` | `:53` | `files/etc/sysctl.conf` |
| `**/etc/config/dnschain` | `:57` | `files/etc/config/dnschain` |
| `**/etc/init.d/dnschain` | `:58` | `files/etc/init.d/dnschain` |
| `**/etc/uci-defaults/99-zz-dnschain` | `:59` | `files/etc/uci-defaults/99-zz-dnschain` |
| `**/usr/bin/dnschain-reconcile` | `:60` | `files/usr/bin/dnschain-reconcile` |
| `**/usr/bin/dnschain-selftest` | `:61` | `files/usr/bin/dnschain-selftest` |
| `**/usr/bin/dnschain-health` | `:62` | `files/usr/bin/dnschain-health` |
| `**/usr/share/dnschain/dnschain.sh` | `:63` | `files/usr/share/dnschain/dnschain.sh` |
| `**/etc/capabilities/dnschain-filter.json` | `:64` | `files/etc/capabilities/dnschain-filter.json`（虽为 `.json`，仍显式列出） |
| `**/etc/uci-defaults/99-zzz-luci-theme-shadcn` | `:68` | `files/etc/uci-defaults/99-zzz-luci-theme-shadcn` |

### 3.4 为什么必须用 `**/` 前缀而不是根锚定

git 的 `.gitattributes` 模式**匹配的是仓库内真实路径**，不是部署后的路径。overlay 文件在仓库里的真实路径是 `files/etc/config/dnsproxy`，而不是 `/etc/config/dnsproxy`。

- 根锚定写法 `/etc/config/dnsproxy` 只匹配仓库根下名为 `etc` 的目录，永远匹配不到 `files/etc/...` → 规则形同虚设，`git check-attr` 显示 attr 为空。
- `**/etc/config/dnsproxy` 匹配任意深度下的 `etc/config/dnsproxy`，无论 overlay 被放在 `files/` 还是别的层都能生效。

这一点在 `.gitattributes:43-46` 有完整说明（「原先写成根锚定的 `/etc/config/dnsproxy` 永远匹配不到」），也是 v0.3.5 修过的坑（AGENTS 红线 1）。

### 3.5 未覆盖的文件

`files/etc/sysctl.d/50-dnsproxy.conf`、`files/etc/ssrplus/applechina.conf`、`files/etc/ssrplus/mosdns-config.yaml`、`files/etc/capabilities/dnsproxy.json` 由扩展名规则覆盖（`.conf` / `.yaml` / `.json`，`:23`、`:26`、`:24`）；`files/usr/bin/*`、`files/etc/init.d/*` 等无扩展名脚本由 `:57-68` 逐条覆盖。**没有 overlay 文件落在所有规则之外**。

## 4. 执行位来源

仓库索引里的真实模式位（`git ls-files -s files/`）：

| 模式 | 文件 |
|---|---|
| `100755` | `files/etc/hotplug.d/iface/50-ipv6-pd-lan`、`files/etc/init.d/dnsproxy`、`files/etc/rc.local`、`files/etc/uci-defaults/99-gaming-optimize`、`files/usr/bin/dnschain-health` |
| `100644` | 其余 **15 个**，包括 `files/etc/init.d/dnschain`、`files/etc/uci-defaults/99-zz-dnschain`、`files/etc/uci-defaults/99-zzz-luci-theme-shadcn`、`files/usr/bin/dnschain-reconcile`、`files/usr/bin/dnschain-selftest`、`files/usr/share/dnschain/dnschain.sh` |

即 **5 个 `100755` + 15 个 `100644`**，不是「只有 `dnschain-health` 一个可执行」。有 5 个文件在索引里已带执行位，另外 6 个需要靠 CI 补。

### 4.1 CI 的 `chmod +x` 清单

在 `Apply gaming optimization files overlay` 步骤里，复制完 overlay 后逐条设置（`.github/workflows/build-openwrt.yml:975-994`）：

| 行号 | 命令 | 覆盖对象 |
|---|---|---|
| `:979` | `chmod +x files/etc/init.d/dnsproxy` | dnsproxy 服务脚本 |
| `:980` | `chmod +x files/etc/rc.local` | rc.local（索引里已是 100755，冗余但无害） |
| `:981` | `chmod +x files/etc/uci-defaults/*` | 三个 uci-defaults 脚本 |
| `:982` | `if [ -d files/etc/hotplug.d/iface ]; then chmod +x files/etc/hotplug.d/iface/*; fi` | `50-ipv6-pd-lan` |
| `:983` | `if [ -d files/etc/hotplug.d/dhcp ]; then chmod +x files/etc/hotplug.d/dhcp/*; fi` | 该目录当前不存在，`if` 兜住 |
| `:986` | `if [ -f files/etc/init.d/dnschain ]; then chmod +x files/etc/init.d/dnschain; fi` | dnschain 服务脚本 |
| `:987` | `if [ -f files/usr/bin/dnschain-reconcile ]; then chmod +x files/usr/bin/dnschain-reconcile; fi` | 收敛器 |
| `:988` | `if [ -f files/usr/bin/dnschain-selftest ]; then chmod +x files/usr/bin/dnschain-selftest; fi` | 自检 |
| `:989` | `if [ -f files/usr/share/dnschain/dnschain.sh ]; then chmod +x files/usr/share/dnschain/dnschain.sh; fi` | 库脚本 |
| `:992` | `if [ -f files/usr/bin/dnschain-health ]; then chmod +x files/usr/bin/dnschain-health; fi` | 健康 CLI（索引里已是 100755） |

该步骤明确「不使用 `|| true`」，缺失必须让 CI 明确失败（`build-openwrt.yml:977`、`:985`）。

另有一步在复制包目录时就断言 `dnschain-health` 有执行位（`build-openwrt.yml:219-226`），失败信息是「缺执行位（页面按钮会静默失败）」。

固件产物预检也核对执行位：`etc/init.d/dnschain` 期望 `-rwxr-xr-x`，`etc/uci-defaults/99-zz-dnschain` 期望 `-rwxr-xr-x`，`usr/bin/dnschain-*` 与 `usr/share/dnschain/dnschain.sh` 期望 `-rwxr-xr-x`（`tools/verify-firmware-artifact.sh:137-145`）。

## 5. `applechina.conf` 的 173 条规则

文件 **191 行**，其中 `^server=` **173 条**，全部指向 `127.0.0.1#5353`；含 `114.114.114.114` 的只有 **1 行**，且是注释（`:4`，说明上游原文件的样子）。

- 173 条断言：`build-openwrt.yml:1292-1295`（`ap_data -ne 173` 即失败）。
- 明文为 0 断言：`build-openwrt.yml:1296-1299`。
- 全部指向加密入口断言：`build-openwrt.yml:1300-1303`（`ap_enc -ne 173` 即失败）。

### 5.1 为什么不能设 `shadowsocksr.@global[0].apple_dns`

`files/etc/ssrplus/applechina.conf:11-14` 写明理由：SSR-Plus 的 init 脚本里 `old_appledns` 用 `grep -oE` 只抽 IP、**丢掉端口**，二次启动会叠成 `127.0.0.1#5353#5353`，dnsmasq 解析该行出错。

不设 `apple_dns` 时，那段 `if [ -n "$new_appledns" ]` 整体跳过，overlay 文件原样拷入 —— 这是当前的正确状态。`files/etc/uci-defaults/99-zz-dnschain` 与 `99-gaming-optimize` 都**没有**写这个键（`grep -n apple_dns files/etc/uci-defaults/*` 无输出），与上述约束一致。

## 6. overlay 与其他构建步骤的时序

理解 overlay 何时生效需要知道步骤顺序（`.github/workflows/build-openwrt.yml`）：

1. `:63` 检出本仓库到 `openwrt-build/`
2. `:127` 检出 lede 到 `lede/`
3. `:161`、`:166` 复制本地包 `luci-app-trafficctl`、`luci-app-dnschain`
4. `:456` 拉主题 shadcn
5. `:558` 拉 dnsproxy 上游并应用 patch
6. `:633`、`:648` 写 `.config`
7. `:773` 校验 SQM/i18n/排除项
8. `:962` **复制 `files/` 进 `lede/files/` 并补执行位**
9. `:996` 校验 mosdns 模板
10. `:1035` 校验 dnschain 契约
11. `:1352` 校验 nft 片段
12. `:1402` 校验 SSR-Plus uci-defaults 顺序
13. `:1573` 编译

关键点：**契约校验步骤（9–12）跑在 overlay 复制（8）之后**，所以它们读的是 `lede/files/...`；唯一的例外是主题脚本检查，它显式用仓库路径 `../openwrt-build/files/etc/uci-defaults/99-zzz-luci-theme-shadcn`，理由是那一步在复制之前（`build-openwrt.yml:935-939`）。
