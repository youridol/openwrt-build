# 文档索引

本仓库的文档按**读者要回答的问题**分层。先读第一层，需要细节时再往下钻。

```
你要做什么？
├─ 第一次接触这个仓库            → 本文件 §1 概览
├─ 查某个 URL 由谁提供、调什么   → docs/routes.md（路由总表，唯一登记处）
├─ 改某个 LuCI 页面             → docs/packages/<包名>.md
├─ 改 DNS / 代理链路            → docs/runtime/dns-chain.md
├─ 改固件里落地的文件           → docs/runtime/overlay-inventory.md
├─ 改 CI / 发版                 → docs/build/ci.md
├─ 上机验证 / 排障              → docs/operations/verification.md
└─ 想知道某决定为什么这么做      → docs/adr/
```

---

## 1. 概览

本仓库编译一台 x86_64 家用路由器的 OpenWrt 固件。它**不含** OpenWrt 主源码，只含四类东西：

| 类别 | 路径 | 作用 |
|---|---|---|
| 构建配方 | `.github/workflows/` | 拉 lede → 装包 → 编译 → 上传产物 / 发版 |
| 两个本地 LuCI 包 | `package/luci-app-dnschain/`、`package/luci-app-trafficctl/` | 随固件编译的页面与后端 |
| 上游包的 patch | `patches/luci-app-dnsproxy/`、`patches/luci-app-trafficctl/` | 以差分形式记录对上游的改动 |
| rootfs overlay | `files/` | 直接合并进固件的运行时配置与脚本（20 个文件） |

固件产物：`lede/bin/targets/x86/64/*.img.gz`，artifact 名 `openwrt-x86-64-ssrplus`。

### 三条链路，一句话各自是什么

| 链路 | 入口 | 分流者 | 出口 |
|---|---|---|---|
| DNS | `dnsmasq:53` | `dnsmasq` 的 `server=/域名/` | 国内 → `dnsproxy:5353`（DoT 直连）；国外 → `dnsproxy:5336`（DoH 经 `:1234`） |
| 代理（IPv4） | nft `inet ss_spec` | `china` IP 集 + `blacklist` IP 集 | `REDIRECT/TPROXY → v2ray:1234` |
| 代理（IPv6） | nft `inet ss_spec` 的 10 条 `ss_spec6_*` 链 | `china6` IP 集 | `redirect/tproxy → :1234`，`fwmark 0x53535250 → table 999` |

三条链路的细节见 `docs/runtime/dns-chain.md`。

---

## 2. 文档清单

| 文档 | 回答什么问题 | 主要读者 |
|---|---|---|
| `docs/routes.md` | 仓库里有哪些 LuCI 路由？各自落到哪个视图、哪个后端、哪个 ACL？ | 要定位「点这个按钮会发生什么」的人 |
| `docs/packages/luci-app-dnschain.md` | DNS 分流页怎么组成？7 个 tab、21 个 section（20 个有标题）、8 个后端子命令各自是什么？ | 改 dnschain 页面或脚本的人 |
| `docs/packages/luci-app-trafficctl.md` | 流量控制页怎么组成？5 条路由、34 个 ubus 方法、23 个脚本、CGI 指标端点？ | 改 trafficctl 的人 |
| `docs/packages/luci-app-dnsproxy.md` | DNS Proxy 页是本仓库改的哪几处？LAN 拦截真的生效吗？ | 改 dnsproxy patch 或排查 DNS 劫持的人 |
| `docs/runtime/dns-chain.md` | 运行时 DNS 分流长什么样？两个 dnsproxy 实例的参数、分流片段、改道通道、20 项自检 | 改 DNS 行为或排查解析故障的人 |
| `docs/runtime/overlay-inventory.md` | `files/` 里 20 个文件各自干什么？执行位从哪来？uci-defaults 谁覆盖谁？ | 改固件落地文件的人 |
| `docs/build/ci.md` | CI 按什么顺序做什么？有哪些契约断言？发版怎么取 notes？ | 改 CI、发版、排查构建失败的人 |
| `docs/operations/verification.md` | 本地能跑哪些校验？路由器上怎么只读取证？排障顺序是什么？常见误判有哪些？ | 验证改动、排查故障的人 |
| `docs/adr/` | 每个架构决定当时怎么权衡、后来为什么被推翻 | 想知道「为什么不是另一种做法」的人 |
| `GLOSSARY.md` | 归属/首选/当前、分流、nftset、watch.servers 等易混术语 | 所有人 |
| `AGENTS.md` | 给 AI 编码代理的硬约束与红线 | AI 代理、人类贡献者 |
| `CHANGELOG.md` / `CHANGELOG-archive.md` | 每个版本改了什么 | 查版本变更的人 |

---

## 3. 按任务找文档

| 任务 | 先读 | 再读 |
|---|---|---|
| 新增一个 LuCI 页面 | `docs/routes.md` §0-1 | 对应包的「路由表」与「请求走向」 |
| 给已有页面加一个开关 | 对应包文档的「页面元素 → 后端调用」 | `docs/runtime/overlay-inventory.md`（如果它要写 UCI 默认值） |
| 改 DNS 分流规则 | `docs/runtime/dns-chain.md` | `docs/adr/0008-direct-first-with-fallback.md`（**v0.22.0 起的分流语义**）、`docs/adr/0006-domain-routing-and-reroute.md`（§3 归属判定仍有效，§4–§7 已失效） |
| 改页面 tab 结构 / section 归属 | `docs/adr/0007-tab-structure.md`（含**文档联动清单**，改结构必读） | `docs/packages/luci-app-dnschain.md` 的 section 清单 |
| 改 DNS 拦截行为 | `docs/packages/luci-app-dnsproxy.md` | `files/etc/init.d/dnsproxy` 的 `dnschain_takes_over` |
| 升级 trafficctl 上游 | `patches/luci-app-trafficctl/README.md` | `docs/packages/luci-app-trafficctl.md` 的「构建与打包」 |
| 排查「客户机解析不了」 | `docs/operations/verification.md` 的排障顺序 | `docs/runtime/dns-chain.md` |
| 排查「构建绿了但没产物」 | `docs/build/ci.md` 的「已知问题」 | `docs/operations/verification.md` |
| 发版 | `docs/build/ci.md` §发版 | `CHANGELOG.md` 顶部格式 |

---

## 4. 文档的可核查性约定

本仓库的文档有一个硬要求：**每条事实断言都要能追到代码**。

- 写法：`…（证据：path/to/file:行号）`。
- 无法从仓库内确认的，明确写「仓库内无对应实现」或「仓库内无证据」，**不写成结论**。
- 运行时实测（路由器上的输出）标注为「实测快照」并给出时间点 —— 它证明「当时是什么」，不证明「现在一定还是」。
- 文档与代码冲突时，以代码为准，并在文档里标注差异（这是本仓库历史上多次踩坑的教训：ADR-0003/0004 曾把「设计意图」写成「已实现事实」）。

---

## 5. 文档维护

| 什么时候 | 要改什么 |
|---|---|
| 加/删/改路由 | `docs/routes.md` + 对应包文档的路由表 |
| 加/删/改 ubus 方法或脚本 | 对应包文档的接口表 |
| 加/删 `files/` 下文件 | `docs/runtime/overlay-inventory.md` + `.gitattributes` |
| 加/删 CI 步骤或断言 | `docs/build/ci.md` |
| 推翻一个架构决定 | 新建 ADR，并把旧 ADR 状态改为 `superseded` 且指向新 ADR |
| 任何功能改动 | `CHANGELOG.md`（发版依据，缺失会导致 `release.yml` 中止） |
