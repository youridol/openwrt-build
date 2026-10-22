# openwrt-build 网络链路

本仓库编译的 x86_64 OpenWrt 固件面向单台家用路由（`192.168.3.254`），需要同时满足双栈 IPv6、国内外分流、游戏低延迟三件事。本表固定这套链路里反复出现、且字面相近容易混淆的术语。

## Language

**分流**：
按域名或目的 IP 的归属，决定流量走哪条出口链路（直连或代理）以及由哪台解析器应答。
_Avoid_: 分组、规则

**拒绝集**：
对 AAAA 查询返回空应答（`reject 0`）的域名集合。语义上等于「需走代理的域名集」，不等于「全部国外域名」。
_Avoid_: 屏蔽列表、黑名单

**直连**：
不经过 SSR-Plus 的 `:1234`，由 `pppoe-wan` 直接出站。
_Avoid_: 绕过、走本地

**强制代理**：
命中 `blacklist` ipset 的流量，无条件进入 `:1234`，不参与 `china` 判定的豁免。
_Avoid_: 白名单反向

**健康检查**：
周期性探测节点可用性，**失败达 `switch_try_count` 阈值后才切换**。区别于「定时轮换」。
_Avoid_: 定时切换、自动轮换

**归属**（class）：
一个域名的静态归类，由配置与名单决定，取值为 `custom-domestic` / `custom-foreign` / `db-foreign` / `uncovered`。**只回答「这个域名属于哪条链」，不回答「现在实际走哪条」**。
_Avoid_: 分类、类型

**首选**（preferred）：
由归属确定性推导出的链路：`custom-foreign` 与 `db-foreign` → `foreign`，其余（含 `uncovered`）→ `domestic`。**不是最终结果**，会被健康探测改写。
_Avoid_: 默认链路、最优链路

**当前**（active）：
域名此刻**实际**使用的链路，由健康探测与改道决定，落在 `/var/run/dnschain/health.state`。可以与首选不同。
_Avoid_: 生效链路、实际链路

**改道**：
当**首选**链不通、且**另一条**链通时，把该域名切到另一条链。只改 `watch.servers` + SIGHUP，**绝不 restart dnsmasq**（否则每次约 3 秒解析中断）。两条链都不通时**不改道**（标 `both-bad`）—— 那是链路故障，改道只会掩盖问题。
_Avoid_: 切换、failover、故障转移

**补全归属**：
自定义域名输入框的作用。用户录入只**补全数据库没覆盖的域名归属**，不是「锁定不改道」的开关 —— 补全后的域名照常参与健康检测与自动改道。
_Avoid_: 固定域名、强制走某链

**整形**：
在出口队列上主动限速并重排报文顺序，以控制排队时延（bufferbloat）。目的是降低时延方差，不以提高吞吐为目的。
_Avoid_: 限速、QoS

**排队时延**：
报文在出口队列中等待发送的时间。上行饱和时它是游戏 ping 抖动的直接来源。
_Avoid_: 延迟、latency

**overhead**：
cake 整形时，为每个报文补记的链路层额外字节数（PPP/PPPoE/以太头、FCS、前导、IFG）。取值必须与真实链路匹配，否则整形速率不准。
_Avoid_: 开销、额外开销

**跳数**：
一次 DNS 查询经过的解析器进程数量。v0.10.0 移除 chinadns-ng 后，客户端侧固定为 **3 跳**：
dnsmasq `:53` → dnsproxy（`:5353` 国内实例或 `:5336` 国外实例）→ 上游 DoT/DoH。
（v0.9.x 及更早是 4 跳，多一层 `:5335` 策略过滤器。）
_Avoid_: 层级、链路长度

**端口所有权**：
某端口在同一时刻只能由一个组件监听。本框架占 `:5353`（国内实例）与 `:5336`（国外实例），**两者不能相同**（init 的 preflight 会拒绝启动）。SSR-Plus 若也绑同一端口，两者必有一个静默失败。
_Avoid_: 端口冲突、端口占用

**档案**：
端口所有权的两套配置形态（`primary` / `coexist`），历史上用于区分「框架自持过滤器」与「与 SSR-Plus 共存」两种端口分配。v0.10.0 移除 chinadns-ng 后，本框架固定占 `:5353` + `:5336`，档案只剩 `primary` 一种有效形态。
_Avoid_: 模式、profile

## 组件角色

**dnsmasq**：
`:53` 唯一入口，也是**唯一缓存层**；负责 DHCP、`/etc/hosts`、租约，唯一默认上游是 dnsproxy。不做策略。
_Avoid_: 本地 DNS

**dnsproxy**：
本框架跑**两个实例**：国内实例 `:5353`（DoT 直连）与国外实例 `:5336`（DoH 经代理）。两者都**不缓存、不抑制 AAAA、不写 nftset** —— 分流由 dnsmasq 的 `server=/域名/` 决定，解析结果入 `ss_spec` 集合由 dnsmasq 的 `nftset=` 决定。
_Avoid_: DoH 客户端

**国外实例**：
`:5336` 的 dnsproxy 实例 2，国内实例之外的第二个路由型解析器。上游是 DoH（经 `:1234` 代理出站），**不缓存**。v0.10.0 起取代已移除的 chinadns-ng（原 `:5335` 策略过滤器）。
_Avoid_: 过滤器、chinadns-ng、策略过滤器

**mosdns**：
仅在 SSR-Plus 的 `pdnsd_enable=4` 时存在，**不在默认链路中**。
_Avoid_: 国外 DNS

**收敛器**：
`dnschain-reconcile`。把 SSR-Plus 页面改动归一、重放端口所有权与 DNS 键的不变量集，并把 gfw 名单单向导入框架。不实现解析逻辑。
_Avoid_: 同步器、守护进程

**SSR-Plus**：
透明代理插件。IPv4 侧对命中的 TCP 做 `REDIRECT :1234`、UDP 做 `TPROXY :1234`；IPv6 侧不做代理。
_Avoid_: 代理插件、ssr
