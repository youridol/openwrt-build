# openwrt-build 网络链路

本仓库编译的 x86_64 OpenWrt 固件面向单台家用路由（`192.168.3.254`），需要同时满足
双栈 IPv6、国内外分流、游戏低延迟三件事。本表固定这套链路里反复出现、且字面相近
容易混淆的术语。

**每条术语给出三样**：定义、在代码里的落点、易混的反例。
定义只描述概念，不描述实现细节；实现细节看落点指向的那一行。

> 本表在 v0.10.0 与 v0.13.0 两次架构变更后重写过。
> 已删除的条目（`拒绝集`、`档案`）与已作废的表述，见文末「已废弃术语」。

---

## Language

**分流**：
按域名或目的 IP 的归属，决定流量走哪条出口链路（直连或代理）。
在本框架里，域名分流**只由 dnsmasq 的 `server=/域名/` 承担**。
_落点_：`files/usr/share/dnschain/dnschain.sh:1046-1149`（生成 `dnschain-split.conf`）
_反例_：不是 dnsproxy 的 `[/域名/]` —— 那种形式会给每个域名注册一条 reserved 上游，
上万条时资源耗尽（`files/etc/init.d/dnschain:292-301` 记录了实测）。
_反例_：也不是 `nftset=` —— 那只负责把解析结果写进 IP 集，不做路由决策。
_Avoid_: 分组、规则

**直连**：
不经过 SSR-Plus 的 `:1234`，由 `pppoe-wan` 直接出站。
框架里对应 `domestic` 链，出口是 dnsproxy 实例 1（`entry_port`，默认 `:5353`）。
_落点_：`files/usr/share/dnschain/dnschain.sh:1796-1811`（`dc_probe_chain` 的链路名→端口映射）
_反例_：不是「不走加密 DNS」—— 直连链仍然走 DoT/DoH，只是不经代理。
_Avoid_: 绕过、走本地

**代理出口**（`foreign`）：
经 SSR-Plus 的 `:1234` 出站。框架里对应 `foreign` 链，出口是 dnsproxy 实例 2
（`foreign_port`，默认 `:5336`），它的上游是 DoH。
_落点_：`files/etc/config/dnschain:62-68`（上游）、`:50`（端口）
_Avoid_: 国外链、翻墙

**强制代理**：
命中 `blacklist` nft 集的流量，无条件进入 `:1234`。
框架侧不直接维护它，只通过 dnsmasq 的 `nftset=` 往集里写 IP。
_落点_：`files/usr/share/dnschain/dnschain.sh:1105-1117`
_反例_：不是 `whitelist`（那是放行集，属上游 SSR-Plus）。
_Avoid_: 白名单反向

**归属**（class）：
一个域名的静态归类，由配置与名单决定，取值为
`custom-domestic` / `custom-foreign` / `db-foreign` / `uncovered`，
格式不合法时为 `invalid`。**只回答「这个域名属于哪条链」，不回答「现在实际走哪条」**。
_落点_：`files/usr/share/dnschain/dnschain.sh:827-887`（`dc_domain_class`）
_反例_：自定义列表是**精确匹配**，数据库是**后缀匹配**，两者语义不同
（`dnschain.sh:833-842` vs `:844-884`）。
_Avoid_: 分类、类型

**首选**（preferred）：
由归属确定性推导出的链路：`custom-foreign` 与 `db-foreign` → `foreign`，
其余（含 `uncovered`）→ `domestic`。**不是最终结果**，会被健康探测改写。
_落点_：`files/usr/share/dnschain/dnschain.sh:892-897`
_反例_：`uncovered → domestic` 不是随便定的 —— dnsmasq 的默认上游就是国内实例，
所以未覆盖域名本来就走直连（`dnschain.sh:567-573`）。
_Avoid_: 默认链路、最优链路

**当前**（active）：
域名此刻**实际**使用的链路，由健康探测与改道决定，落在
`/var/run/dnschain/health.state` 的第 3 个字段。可以与首选不同。
_落点_：`files/usr/share/dnschain/dnschain.sh:1473-1482`（`dc_health_active`）
_反例_：不是 UCI 里的配置 —— 状态放 `/var/run`，重启即重算。
_Avoid_: 生效链路、实际链路

**改道**：
当**首选**链不通、且**另一条**链通时，把该域名切到另一条链。
只改 `watch.servers` + SIGHUP，**绝不 restart dnsmasq**（否则每次约 3 秒解析中断）。
两条链都不通时**不改道**（标 `both-bad`）—— 那是链路故障，改道只会掩盖问题。
_落点_：`files/usr/share/dnschain/dnschain.sh:1686-1761`
_反例_：不是「按域名列表批量切」—— 只对 `health.watch` 里的观测域名生效。
_Avoid_: 切换、failover、故障转移

**补全归属**：
自定义域名输入框的作用。用户录入只**补全数据库没覆盖的域名归属**，
不是「锁定不改道」的开关 —— 补全后的域名照常参与健康检测与自动改道。
_落点_：`files/usr/share/dnschain/dnschain.sh:899-931`（`dc_domain_custom`）
_反例_：v0.14.0 之前这里是 `fixed` 语义（命中即跳过改道），已删除；
现在 `CUSTOM=1` 只表示「归属由用户补全」（`dnschain.sh:1862-1865`）。
_Avoid_: 固定域名、强制走某链

**整形**：
在出口队列上主动限速并重排报文顺序，以控制排队时延（bufferbloat）。
目的是降低时延方差，不以提高吞吐为目的。
_落点_：`files/etc/config/sqm`（`qdisc 'cake'`、`script 'piece_of_cake.qos'`）
_反例_：不是「提高带宽」—— 上行刻意配成签约值的 90%（`upload '45000'`）。
_Avoid_: 限速、QoS

**排队时延**：
报文在出口队列中等待发送的时间。上行饱和时它是游戏 ping 抖动的直接来源。
_落点_：`files/etc/config/sqm` 头部注释
_Avoid_: 延迟、latency

**overhead**：
cake 整形时，为每个报文补记的链路层额外字节数（PPP/PPPoE/以太头、FCS、前导、IFG）。
取值必须与真实链路匹配，否则整形速率不准。
_落点_：`files/etc/config/sqm` 的 `option overhead '34'`（PPPoE 8 + 以太 14 + FCS 4 + 前导/IFG 8）
_反例_：不是 cake 的 `ethernet` 关键字（那是 38/84，差 4 字节/包）。
_Avoid_: 开销、额外开销

**跳数**：
一次 DNS 查询经过的解析器进程数量。v0.10.0 移除 chinadns-ng 后，客户端侧固定为 **3 跳**：

```
dnsmasq :53 → dnsproxy（:5353 国内实例 或 :5336 国外实例）→ 上游 DoT/DoH
```

（v0.9.x 及更早是 4 跳，多一层 `:5335` 策略过滤器。）
_落点_：`files/etc/config/dnschain:7-12` 的链路图注释
_反例_：不是「查询包数量」—— 一次查询可能有 A + AAAA 两次往返，仍算 3 跳。
_Avoid_: 层级、链路长度

**端口所有权**：
某端口在同一时刻只能由一个组件监听。本框架占 `:5353`（国内实例）与
`:5336`（国外实例），**两者不能相同**（init 的 preflight 会拒绝启动）。
`:5335` 在 v0.10.0 后**必须空闲**。
_落点_：`files/etc/init.d/dnschain:186-191`（两端口不能相同）、
`files/usr/bin/dnschain-selftest:220-231`（`:5335` 无监听）
_反例_：`:5335` 不是「保留端口」—— 有进程占它就是故障。
_Avoid_: 端口冲突、端口占用

**nftset**：
dnsmasq 的选项，把某个域名的**解析结果**（IP）自动写进一个 nft 集合。
它只写集，不做路由决策；真正的流量判定由 `ss_spec` 的规则链读取该集完成。
_落点_：`files/usr/share/dnschain/dnschain.sh:1105-1124`
（生成 `nftset=/域名/4#inet#ss_spec#blacklist` 与 `…#china`）
_反例_：不是 ipset 的 `ipset=`（那是旧语法）；也不是「域名规则」，它作用于解析出的 IP。
_反例_：目标集必须先探测再写 —— SSR-Plus 未启用时 `ss_spec` 表不存在
（`dnschain.sh:949-984`）。
_Avoid_: IP 集写入、域名集

**watch.servers**：
`--servers-file` 指向的文件，内容是一批 `server=/域名/127.0.0.1#端口` 行。
dnsmasq 收到 SIGHUP 时会**重新读取**它，因此它是改道唯一的生效通道。
路径固定为 `/var/run/dnsmasq/watch.servers`。
_落点_：`files/usr/share/dnschain/dnschain.sh:607`（常量）、`:1165-1231`（生成）、
`:1239-1245`（SIGHUP）
_反例_：不是 `/var/etc/dnschain/watch.servers` —— 那个路径 dnsmasq（uid 453）读不到，
SIGHUP 成功但完全不生效（`dnschain.sh:589-606`）。
_反例_：不是 `dnschain-split.conf` —— 那个走 `--conf-dir`，改了必须 restart。
_Avoid_: 改道文件、动态上游

**health.state**：
改道状态文件，一行一个域名，7 个字段用 `|` 分隔：

```
domain|preferred|active|fail|ok|last_epoch|last_result
```

位于 `/var/run/dnschain/health.state`，重启即清空重算。
_落点_：`files/usr/share/dnschain/dnschain.sh:1446-1455`（格式说明）、`:1493-1509`（唯一写入实现）
_反例_：不是配置 —— 不持久化到 UCI（`ADR-0006` §9.4）。
_反例_：`last` 是「上次**改道**的时刻」，不是「上次探测的时刻」；
等待回切期间必须保留它，否则 `min_dwell` 永不满足（`dnschain.sh:1516-1537`）。
_Avoid_: 状态库、探测结果

**vendored 包**：
整包复制进本仓库的上游 LuCI 应用，改动以 patch 形式记录。
目前只有 `package/luci-app-trafficctl/`（源自上游 **v1.21.4**）。
改它之后**必须**跑 `python3 tools/regen-trafficctl-patches.py <上游包目录>` 重算 patch。
_落点_：`package/luci-app-trafficctl/Makefile:4`（`PKG_VERSION:=1.21.4`）、
`patches/luci-app-trafficctl/UPSTREAM`（`v1.21.4`）、
`tools/regen-trafficctl-patches.py:2-10`
_反例_：`luci-app-dnsproxy` 不是 vendored —— 它由 feed 提供，改动只以
`patches/luci-app-dnsproxy/*.patch` 落地，禁止改上游。
_Avoid_: 本地包、内嵌包

**patch 重放**：
CI 每次构建都全新克隆上游，然后依次 `git apply` 本仓库的 patch。
因为每次都是干净克隆，所以**天然幂等**；patch 失败必须让 CI 明确失败，
严禁 `|| true`。
_落点_：`.github/workflows/build-openwrt.yml:564-586`
（先 `git apply --check`，再 `git apply`；patch 路径先转绝对路径）
_反例_：不是「打一次就永久生效」—— 本地改上游副本不会被 CI 采用。
_Avoid_: 打补丁、应用差异

**uci-defaults**：
`/etc/uci-defaults/` 下的首刷脚本，按**文件名 C 排序**执行，执行后自动删除。
本仓库有三个：`99-gaming-optimize`、`99-zz-dnschain`、`99-zzz-luci-theme-shadcn`。
排序是硬契约：`99-zz-dnschain` 必须晚于 `99-gaming-optimize`，否则无法覆盖
后者写入的 `pdnsd_enable=4`。
_落点_：`files/etc/uci-defaults/99-zz-dnschain:7-9`、
CI 断言 `.github/workflows/build-openwrt.yml:1207-1218`
_反例_：不是「每次开机都跑」—— 只在**首刷**跑一次，之后靠收敛器纠正。
_Avoid_: 初始化脚本、默认值脚本

**ujail**：
OpenWrt 的轻量沙箱，把服务降权到非 root 用户并限制可见路径。
本固件的 dnsmasq 由 ujail 降权到 **uid 453**，只能看到
`procd_add_jail_mount` 声明过的目录。
_落点_：`files/usr/share/dnschain/dnschain.sh:589-606`（实测 `Uid: 453 453 453 453`）
_反例_：路径不在白名单时**既不报错也不生效** —— 这是最隐蔽的失效形态
（改道"看起来成功、实际没发生"）。
_Avoid_: 沙箱、chroot

## 组件角色

**dnsmasq**：
`:53` 唯一入口，也是**唯一缓存层**与**唯一分流层**；负责 DHCP、`/etc/hosts`、
租约，唯一默认上游是 dnsproxy 实例 1。不做策略判断。
_落点_：`files/etc/uci-defaults/99-zz-dnschain:104-121`（server/noresolv/dnsforwardmax/cachesize）
_Avoid_: 本地 DNS

**dnsproxy**：
本框架跑**两个实例**，都不缓存、都不抑制 AAAA、都不写 nftset：

| 实例 | 端口 | 上游 | 监听地址 | 服务对象 |
|---|---|---|---|---|
| 1（国内） | `entry_port`，默认 `5353` | 国内 DoT/DoH，直连 | `127.0.0.1` + `::1` | 默认上游（未覆盖域名） |
| 2（国外） | `foreign_port`，默认 `5336` | 国外 DoH，经 `:1234` | `127.0.0.1` | `server=/国外域名/` 命中的 |

_落点_：`files/usr/share/dnschain/dnschain.sh:332-372`（实例 1 参数）、
`:381-417`（实例 2 参数）
_反例_：不是「一个 dnsproxy 加域名分流」—— 那种方案实测资源耗尽
（`files/etc/init.d/dnschain:292-301`）。
_Avoid_: DoH 客户端

**国外实例**：
`:5336` 的 dnsproxy 实例 2。上游是 DoH（经 `:1234` 代理出站），**不缓存**、
不监听 `::1`。v0.10.0 起取代已移除的 chinadns-ng（原 `:5335` 策略过滤器）。
_落点_：`files/etc/config/dnschain:49-50`、`:62-72`
_反例_：上游**必须是 `https://`**，不能是 `tls://` —— 落地节点到 853 全部不通，
init 会硬校验拒绝启动（`files/etc/init.d/dnschain:200-212`）。
_Avoid_: 过滤器、chinadns-ng、策略过滤器

**mosdns**：
仅在 SSR-Plus 的 `pdnsd_enable=4` 时存在，**不在默认链路中**。
_落点_：`files/etc/config/dnschain:197-204`（`ssr.mode '0'`）、
`files/usr/bin/dnschain-selftest:245-246`（模式必须是 0 或 7）
_反例_：不是「可选缓存层」—— 它开着就占 `:5335`，自检第 6 项会 FAIL。
_Avoid_: 国外 DNS

**收敛器**：
`dnschain-reconcile`。把 SSR-Plus 页面改动归一、重放端口所有权与 DNS 键的不变量集，
并把 gfw 名单单向导入框架。不实现解析逻辑。
_落点_：`files/usr/bin/dnschain-reconcile:51-237`（不变量集）、`:245-310`（名单导入）
_反例_：**它没有自动触发点** —— init 不调用它，无 procd 触发器，无 cron。
只在页面点「一键归一」或「手动导入名单」时执行
（`package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua:451-469`）。
_Avoid_: 同步器、守护进程

**dnschain-health**：
健康探测与改道的唯一实现，也是页面所有操作按钮的后端。
8 个子命令：`cycle` / `daemon` / `status` / `explain <域名>` / `check` /
`apply` / `reset` / `flush`。
_落点_：`files/usr/bin/dnschain-health:350-363`（子命令分派）
_反例_：`daemon` 由 procd 托管（`files/etc/init.d/dnschain:366-381`），
不是 cron（`dnschain-health:283-295` 解释了为什么不用 cron）。
_Avoid_: 探测器、守护脚本

**dnschain-selftest**：
20 项只读自检。输出格式 `<序号> <PASS|FAIL|SKIP> <项目名> — <证据>`，
末尾 `SUMMARY PASS=n FAIL=n SKIP=n` 与 `CONCLUSION: …`。
结果缓存 60 秒，`-f` 强制刷新。
_落点_：`files/usr/bin/dnschain-selftest:99-575`（20 项）、`:580-672`（入口与缓存）
_反例_：不是 16 项 —— v0.13.0 加了第 17–20 项（`:5-6`）。
_Avoid_: 健康检查（那是 `dnschain-health` 的职责）

**luci-app-dnschain**：
页面包，**只做配置读写、校验、下发、展示，不实现判定逻辑**。
7 个 Tab：概览 / 域名 / 解析 / 分流 / 代理 / DHCP / 诊断。
菜单在**服务 → DNS 链路**（`admin/services/dns_chain`，`order=20`）。
_落点_：`package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua:98-106`（tab）、
`package/luci-app-dnschain/root/usr/share/luci/menu.d/luci-app-dnschain.json:2`
_反例_：不是「页面自己算一遍」—— 它读脚本产物，自己重算必然漂移
（`dnschain.lua:692-699`）。
_Avoid_: 配置页、DNS 管理页

**luci-app-trafficctl**：
流量统计页面，vendored 整包（上游 **v1.21.4**）。有六项本地改动必须保留，
丢掉会静默失效（界面不报错、构建也成功）。
_落点_：`package/luci-app-trafficctl/Makefile:3-4`、`patches/luci-app-trafficctl/README.md`
_反例_：不是 feed 包 —— 它整包在仓库里，改完必须重算 patch。
_Avoid_: 流量监控、带宽统计

**SSR-Plus**：
透明代理插件。**IPv4 与 IPv6 都代理**：IPv4 侧对命中的 TCP 做 `REDIRECT :1234`、
UDP 做 `TPROXY :1234`；IPv6 侧由 `ipv6_support=1` 装上 `ss_spec6_*` 链。
_落点_：`files/etc/uci-defaults/99-zz-dnschain:65-70`（置 `ipv6_support=1`）、
`files/usr/bin/dnschain-reconcile:84-87`
_反例_：`ss_spec6_*` 的规则**不由本仓库生成** —— 生成者在上游 SSR-Plus，
本仓库只负责置键（ADR-0002 §2.1）。
_反例_：不是「只代理 IPv4」—— 那是 v0.9.x 及更早的事实。
_Avoid_: 代理插件、ssr

---

## 已废弃术语

以下条目在旧版 `GLOSSARY.md` 中存在，现已删除或改写。保留说明是为了让读到旧文档的人
知道它们指什么、为什么不再用。

| 旧术语 | 旧定义 | 为什么废弃 | 现行替代 |
|---|---|---|---|
| **拒绝集** | 对 AAAA 查询返回空应答（`reject 0`）的域名集合 | 实现它的 MosDNS 已不在默认链路；v0.10.0 起国外 AAAA **不再抑制** | 无。见 `files/etc/config/dnschain:74-82`（`aaaa.policy` 全为 `keep`）与 `docs/adr/0001` §4 |
| **档案**（`profile`） | 端口所有权的两套配置形态（`primary` / `coexist`） | 配置里**没有** `profile` 键；全仓库无 `5337` 端口 | 无。端口结构固定为 `entry_port` + `foreign_port`（`files/etc/config/dnschain:47-50`） |
| **策略过滤器** | `:5335` 的 chinadns-ng 实例，只做 gfw 域名的 AAAA/HTTPS 抑制与国外 DoT | 该组件已移除；`:5335` 必须空闲 | 「国外实例」（`:5336` 的 dnsproxy 实例 2） |

**另外两处曾要求新增但从未落地的术语**：`docs/adr/0003` 的 §13.3 曾要求
新增「策略过滤器」条目并把「跳数」写成 4 跳。该要求已作废 ——
现行 GLOSSARY 无「策略过滤器」，跳数是 3 跳。
