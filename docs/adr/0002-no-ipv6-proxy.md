# 境外 IPv6 不经代理，保持直连

状态：accepted（2026-10-09）

## 背景

`ip6tables` 中只有两条规则（`-A PREROUTING -i br-lan -p tcp/udp --dport 53 -j REDIRECT --to-ports 53`），`ip6tables -S | grep -c 1234` 实测为 **0**。即 IPv4 侧有完整的 `REDIRECT`/`TPROXY :1234`，而境外 IPv6 全部由 `pppoe-wan` 直连出站。

一个只读审计者会自然地把这判为「代理只覆盖 IPv4 的缺口」，并建议补 TPROXY6。

## 决策

保持现状，不补 IPv6 透明代理。

「需走代理的域名走代理」这一功能诉求已由 AAAA 拒绝集覆盖（见 ADR-0001）：被墙域名拿不到 AAAA，客户端只剩 IPv4 可用，自然经 `:1234` 出站。而未被拒绝的境外域名走 IPv6 直连，省掉代理封装，时延更低。

补 TPROXY6 需要代理核心与防火墙同时支持，并新增一整套 `ip6tables` 规则与路由标记，等于引入第二个透明代理面；其收益（覆盖少量走出拒绝集的域名）与风险不成比例。

## 后果

- 境外 IPv6 直连是**有意设计**，不是遗漏。后续任何「补齐 IPv6 代理」的改动都应以 ADR-0001 是否仍成立为前提。
- 已知边界：不在拒绝集内的被墙域名，在 IPv6 上会直连并被 RST。缓解手段是把该域名加入 `black.list`，而不是补全 IPv6 代理。
- `files/etc/uci-defaults/99-gaming-optimize` 中「SSR-Plus 仅代理 IPv4、国外 IPv6 为直连」的说明与本节一致，不应删除。
