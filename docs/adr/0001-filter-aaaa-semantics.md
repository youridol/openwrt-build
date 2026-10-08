# filter_aaaa 取 '1'：拒绝集等于需走代理的域名集

状态：accepted（2026-10-09）

## 背景

SSR-Plus 的 `filter_aaaa` 决定 MosDNS 生成的解析序列：`'1'` → `main_sequence_disable_IPv6`（对 `qtype 28/65` 执行 `reject 0`），`'0'` → `main_sequence_with_IPv6`。

v0.3.5 曾把仓库值定为 `'0'`，理由是当时 `filter_aaaa='1'` 导致「双栈客户端有公网 IPv6 却无法用 IPv6 上网」。那个判断成立的前提是：**dnsmasq 把全部域名都指向 `127.0.0.1#5335`**（即所有域名都走 MosDNS，于是 AAAA 被全局拒绝）。

## 决策

仓库值取 `'1'`，并保留现网行为。

现网路由已不是 v0.3.5 时的形态：`gfw_list.conf` 的 23614 个域名与 `black.list` 的 `chatgpt.com` 指向 `127.0.0.1#5335`，其余域名走 dnsproxy 的国内 DoH。因此 MosDNS 的 `reject 0` 只作用于**需走代理的域名**，而非全部国外域名。实测：`taobao.com` 返回 8 条真实 AAAA；`baidu.com`/`qq.com` 的 SOA 来自真实权威（上游确实无 AAAA）；`google.com`/`chatgpt.com`/`steamcommunity.com` 返回 MosDNS 合成 SOA（`fake-ns.mosdns.fake.root`）。

于是 `'1'` 得到的效果是：需走代理的域名只剩 IPv4、回落走代理（避免被墙域名在 IPv6 上直连被 RST）；其余国外域名保留真实 AAAA、走 IPv6 直连。

## 被否决的方案

取 `'0'`：那 23614 个被墙域名会拿到真实 AAAA，客户端改走 IPv6 直连，被 RST，表现为「有 IPv6 但打不开站点」。即 v0.3.5 修复的问题会以相反的方式复现。

## 后果

- 同一开关的「正确值」随 dnsmasq 的路由是否分裂而反转。**这是本仓库最容易误改的一处**：改动前必须先确认 `gfw_list.conf` 的实际去向，不能凭开关字面或历史结论判断。
- 已知边界：被墙但不在拒绝集内的域名，在 IPv6 上仍为直连。参见 ADR-0002。
- 改 UCI 后需 `/etc/init.d/shadowsocksr restart` 重新生成 `/var/etc/ssrplus/mosdns-config.yaml` 才生效。
