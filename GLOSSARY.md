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
一次 DNS 查询经过的解析器进程数量（本固件客户端侧最长为 dnsmasq → dnsproxy → mosdns → 上游 DoH，共 4 跳）。
_Avoid_: 层级、链路长度

## 组件角色

**dnsmasq**：
`:53` 唯一入口，负责按域名把查询分派给 dnsproxy 或 mosdns，并做本地缓存与 DHCP。
_Avoid_: 本地 DNS

**dnsproxy**：
`:5353` 加密解析主链，默认上游为国内 DoH，另有 24 条硬编码国外域名例外指向 mosdns。
_Avoid_: DoH 客户端

**mosdns**：
`:5335` 国外域名解析器，由 SSR-Plus 管理，经代理出站查询国外 DoH，并执行 AAAA 拒绝集。
_Avoid_: 国外 DNS

**SSR-Plus**：
透明代理插件。IPv4 侧对命中的 TCP 做 `REDIRECT :1234`、UDP 做 `TPROXY :1234`；IPv6 侧不做代理。
_Avoid_: 代理插件、ssr
