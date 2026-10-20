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
一次 DNS 查询经过的解析器进程数量（本固件客户端侧最长为 dnsmasq → dnsproxy → 过滤器 → 上游 DoT，共 4 跳）。
_Avoid_: 层级、链路长度

**端口所有权**：
某端口在同一时刻只能由一个组件监听。`:5335` 归策略过滤器；SSR-Plus 若也绑该端口，两者必有一个静默失败。
_Avoid_: 端口冲突、端口占用

**档案**：
端口所有权的两套配置形态。`primary` 为过滤器占 `:5335`、SSR-Plus 处于模式 0 或 7；`coexist` 为过滤器迁 `:5337`、SSR-Plus 处于模式 1/4/5/6。
_Avoid_: 模式、profile

## 组件角色

**dnsmasq**：
`:53` 唯一入口，也是**唯一缓存层**；负责 DHCP、`/etc/hosts`、租约，唯一默认上游是 dnsproxy。不做策略。
_Avoid_: 本地 DNS

**dnsproxy**：
`:5353` 唯一路由型解析器。国内域名走国内加密池，gfw 域名交给策略过滤器。**不缓存、不抑制 AAAA、不写 nftset**。
_Avoid_: DoH 客户端

**策略过滤器**：
`:5335` 的 chinadns-ng 实例，由 DNS 链路框架自持（不是 SSR-Plus 的后端）。只做 gfw 域名的 AAAA/HTTPS 抑制与国外 DoT 上游。**不缓存、不解析国内域名**。
_Avoid_: 过滤器插件、AAAA 过滤器

**mosdns**：
仅在 SSR-Plus 的 `pdnsd_enable=4` 时存在，**不在默认链路中**。
_Avoid_: 国外 DNS

**收敛器**：
`dnschain-reconcile`。把 SSR-Plus 页面改动归一、重放端口所有权与 DNS 键的不变量集，并把 gfw 名单单向导入框架。不实现解析逻辑。
_Avoid_: 同步器、守护进程

**SSR-Plus**：
透明代理插件。IPv4 侧对命中的 TCP 做 `REDIRECT :1234`、UDP 做 `TPROXY :1234`；IPv6 侧不做代理。
_Avoid_: 代理插件、ssr
