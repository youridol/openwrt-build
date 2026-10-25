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
~~域名此刻**实际**使用的链路，由健康探测与改道决定~~
**v0.22.0 起「当前」恒等于「首选」** —— 健康探测与改道已删除，
不存在「配置说 A、实际走 B」的情形。
_落点_：`dc_explain_domain` 仍输出 `ACTIVE=` 字段（页面「单域名解释」显示它），
但它的值直接取自 `dc_domain_preferred`。
_反例_：不要去找 `health.state` —— 该文件已不再生成。
_Avoid_: 生效链路、实际链路

**回落**（fallback）：
**v0.22.0 起取代「改道」的概念。** 直连上游不可用时，由
`dnsproxy --fallback 127.0.0.1:5336` 在**上游层**自动改走代理。
纯内存状态、无探测、无落库、无 SIGHUP。
_落点_：`files/usr/share/dnschain/dnschain.sh` 的 `dc_gen_dnsproxy_args()`
（生成 `--fallback` 行）
_反例_：⚠️ 地址格式必须是 `127.0.0.1:5336`（**冒号**），
不能写 dnsmasq 的 `127.0.0.1#5336` —— 写成 `#` 时 dnsproxy 拒绝启动。
⚠️ 只在「上游不可用」时触发，**不判断答案是否污染** ——
被污染的域名仍须由 gfw 名单显式写 `server=/域名/#5336`。
_Avoid_: 改道、切换、failover、故障转移（这些都是 v0.22.0 前的旧叫法）

**补全归属**：
自定义域名输入框的作用。用户录入只**补全数据库没覆盖的域名归属**，
决定该域名（及其所有子域名）走哪条链。
_落点_：`dc_domain_custom()`（`files/usr/share/dnschain/dnschain.sh`）
_反例_：v0.14.0 之前这里是 `fixed` 语义（命中即跳过改道），已删除；
v0.22.0 起连改道本身也没了，`CUSTOM=1` 只表示「归属由用户补全」。
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

**watch.servers**（已废弃，v0.22.0 删除）：
曾是 `--servers-file` 指向的文件，让改道只 SIGHUP 不重启即可换上游。

**它被删除的原因不是「冗余」，而是它会覆盖正确结果**：
它与 `dnschain-split.conf` 是两套并存的 `server=` 源，同一域名在两处都有
规则时 dnsmasq 把它们当**候选**（不是后者覆盖前者），取哪条不确定。
实测 `www.wikipedia.org` 经 `:53` 返回 `31.13.106.4`（Facebook 的 IP，污染值），
而两条 dnsproxy 链本身都返回正确的 `103.102.166.224`。

现在分流规则只有 `dnschain-split.conf` 一处来源。
升级时若发现残留文件，`init.d/dnschain` 会清掉它（自检第 18 项也会报）。
_Avoid_: 改道文件、动态上游（这两个词都指已删除的东西）

**health.state**（已废弃，v0.22.0 删除）：
曾是改道状态文件（`domain|preferred|active|fail|ok|last_epoch|last_result`）。
健康探测与改道删除后不再生成，`dc_health_upsert` 等 10 个函数一并移除。

**不要去找这个文件**。判断域名走哪条链，看归属判定（`dc_domain_class`）
或页面的「DNS 分流去向」图。
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

**dnschain-health**（已删除，v0.22.0）：
曾是健康探测与改道的实现（448 行）。删除后它的三个 CLI 入口移到
`dnschain-selftest` 的子命令：`flush` / `explain <域名>` / `apply`。

**为什么没新建脚本而是塞进 selftest**：`dnschain-selftest` 本来就在
rpcd ACL 的 command 白名单里，加子命令即可，不必为一个入口新建文件
并同步 ACL、CI 执行位清单、`.gitattributes` 三处。
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
菜单在**服务 → DNS 分流**（`admin/services/dns_chain`，`order=20`）。
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

## 页面诊断

> 本节术语来自 ADR-0007（tab 结构重构）。它们描述**页面上怎么呈现诊断结果**，
> 与运行时链路本身无关 —— 后者见「组件角色」一节。

**链路拓扑图**：
合并后的唯一链路图。把自检的 20 项按链路阶段归成若干节点，串成一条链，
每个节点带状态徽标（PASS/FAIL/SKIP 计数）。一张图既回答「链路长什么样」，
也回答「哪一段坏了」。
_落点_：`package/luci-app-dnschain/luasrc/model/cbi/dnschain/diagrams.lua`
_反例_：不是旧版「解析链路」与「实时诊断链路」两张图 —— 那两张要并排看，
读者得在脑中做两次映射（ADR-0007 §2.3）。
_Avoid_: 判定链路图、诊断思维导图

**分诊规则图**（已删除，v0.22.0）：
曾画「新目标怎么被判」的规则图（试直连 → 试代理 → 标记 dead）。
分诊功能整体删除后没有对应数据，`triage_map()` 一并移除。

_反例_：不要与「链路拓扑图」混淆 —— 后者仍在，反映此刻各段的实际通断。
_Avoid_: 判定链路（旧名，与「链路拓扑图」字面太近，已弃用）

**分流去向图**：
画「**我录入的**域名各自走哪条链」的导图。**v0.22.0 起只有两档**：
走直连 / 走代理。数据来自 `custom-domestic.txt` 与 `custom-foreign.txt`，
是**静态事实**，不依赖任何探测。
_落点_：`diagrams.lua` 的 `status_map()`（函数名保留，语义已改）
_反例_：不画 gfw 名单里那 2.3 万条 —— 画不下也无意义。
那部分去向由「概览」tab 的链路拓扑图说明。
_反例_：v0.22.0 前是五档（走首选链 / 首选链不稳 / 已切另一链 /
双链故障 / 未探测），那五档依赖健康探测，已随探测一起删除。
_Avoid_: 改道状态、改道明细（两个旧 section 名，已删除）

**兜底阶段**：
链路拓扑图里为「未被任何阶段认领的自检项」自动生成的伪阶段，标题「其他检查」。
新增自检项时若忘记归组，它会被收进这里而不是静默消失。
_落点_：`package/luci-app-dnschain/luasrc/model/cbi/dnschain/diagnosis.lua`
_反例_：不是错误状态 —— 它只是「还没归类」，项本身可能全是 PASS。
_Avoid_: 其他分组、杂项

**未识别的失败模式**：
自检项 FAIL、但其证据串匹配不到任何诊断推导规则时的**诚实输出**。
页面会明说「不认识这个失败」，并给出证据原文与复现命令。
_落点_：`diagnosis.lua`
_反例_：不是「未知错误」这类搪塞 —— 它必须附上原始证据串，否则等于什么都没说。
_Avoid_: 未知错误、其他异常

**自检轮次号**：
每次 `dnschain-selftest` 运行递增的序号，与运行时刻、耗时一起出现在
`SUMMARY` 行（`AT=` / `DUR=` / `RUN=`）。用来判断「这份结论是第几次跑的、
跟上次比有没有变化」。
_落点_：`files/usr/bin/dnschain-selftest`、计数文件 `/var/run/dnschain/.selftest-run-no`
_反例_：不是页面的渲染时刻 —— 那个值在配合 10 秒 TTL 缓存时会误导用户
（ADR-0007 §2.6）。
_Avoid_: 版本号、序号

---

**客户机链路诊断**：
以**客户机视角**分析「这台设备查了什么、收到什么、哪一段失败」的能力。
与「自检 20 项」是**不同视角**，不能互相替代：自检看路由器自身（进程/端口/规则），
本功能看客户机实际收发。
_落点_：`docs/adr/0009-client-link-diagnosis.md`（设计）；
实现后落在 `files/usr/bin/dnschain-client-diag` 与页面「客户机链路诊断」section。
_反例_：不是「自检的子集」—— 自检全绿而某台客户机打不开 App，正是本功能要解释的场景。
_Avoid_: 链路诊断（太宽，会与「链路拓扑图」混）、抓包分析（一期不抓包）

**四段链路**：
客户机一次解析/访问穿过的四个可独立失败的环节，诊断按段定位：

| 段 | 环节 | 日志能否判定 |
|---|---|---|
| ① | 客户机 → dnsmasq:53 | ✅ 靠「有 query 无 reply」反推 |
| ② | dnsmasq → dnsproxy | ✅ `forwarded` 后无 `reply` |
| ③ | dnsproxy → 上游 | ✅ `SERVFAIL` / `timed out` |
| ④ | 客户机 → 目标 IP | ❌ 需 tcpdump（二期） |

_落点_：`docs/adr/0009` §3.2
_反例_：不是「DNS 四段」—— 第 ④ 段是 TCP/TLS 层，不在 DNS 里。
_Avoid_: 链路分层、四层模型

**不算失败**（必须记住的四类正常现象）：
诊断时**绝不能**记成失败的四种日志形态，误判会让结论完全相反：

| 形态 | 为什么正常 |
|---|---|
| `NODATA-IPv6` | 手机先查 AAAA 拿到「无 IPv6」，再查 A 成功 —— 正常探测 |
| `NXDOMAIN` | 域名确实不存在 |
| `query is duplicate` | dnsmasq 的去重提示 |
| `<CNAME>` | 中间跳，后面还有最终答案 |

_落点_：`docs/adr/0009` §3.4、§2.2
_反例_：v0.4.0 时代曾把「空答复」当失败，得出「国内也全挂」的错误结论
（AGENTS.md §5.1 记载）。同类误判会重演。
_Avoid_: 异常答复、空结果

**分级自愈**：
按「能用小的就不用大的」顺序尝试的四个修复级别，逐级升级：

| 级 | 动作 | 中断 |
|---|---|---|
| L1 | `dnschain-selftest flush`（SIGHUP） | 零 |
| L2 | `dnschain-selftest apply`（重建规则） | 零～极短 |
| L3 | 重启 dnsmasq | 实测 3 秒 |
| L4 | 改域名归属（写自动列表） | 零 |

_落点_：`docs/adr/0009` §3.5
_反例_：不是「一有问题就重启」—— 那会在故障持续时反复断所有客户机 3 秒。
_Avoid_: 自动修复、自愈（单独用太含糊）

**自动列表**（`dom_auto_domestic` / `dom_auto_foreign`）：
系统自动写入的域名归属列表，与用户手工维护的 `dom_domestic` / `dom_foreign`
**分区隔离**。用户手写同域名时自动让位。
_落点_：`docs/adr/0009` §3.6
_反例_：不是「把手写列表交给系统管」—— v0.22.0 删掉自动改道，正是因为
自动写入覆盖了正确配置（`watch.servers` 与 `split.conf` 冲突，
`www.wikipedia.org` 拿到 Facebook 的 IP）。
_Avoid_: 自动归属、系统列表

**随机 MAC**（本地管理位）：
MAC 地址第 2 位为 `2`/`6`/`a`/`e` 时表示本地管理位，是 iOS/Android
隐私 MAC 的特征。**这类 MAC 会变，不能用它识别设备。**
实测三台移动设备全部是随机 MAC（`72:` / `ae:` / `f6:` 开头）。
_落点_：`/tmp/dhcp.leases`；识别逻辑见 `docs/adr/0009` §2.4、§3.3
_反例_：不是「设备的唯一标识」—— 稳定的标识是 IP（租期内固定）与主机名（设备自报）。
_Avoid_: 假 MAC、虚拟 MAC

---

## 自动补全

> v0.24.0 新增。设计依据 [`docs/adr/0010-auto-learn-domain-cidr.md`](docs/adr/0010-auto-learn-domain-cidr.md)。
> 这 7 个术语都在回答同一个问题的不同侧面：**怎么在没有可靠地理库的情况下，
> 判出一个域名该走直连还是代理。**

**自动补全**（auto-learn）：
从**客户机实际收发**推导域名归属的机制。判据是「这台设备真的访问通了」，
不是地理库。产出一层域名归属（`dom_auto_*`）与一层 IP 段（`dc_learn4`/`dc_learn6`）。
_落点_：`files/usr/bin/dnschain-client-diag` 的 `cmd_learn`；
`files/usr/share/dnschain/dnschain.sh` 的 `dc_learn_hook` / `dc_learn_apply_cidr`
_反例_：不是「按国家 IP 库判归属」—— 实测 112 个域名里 79 个的答案 IP
不在 `china` 集合，APNIC 官方数据对其中 110 个也查不到（`china` 只有 1333 条区间）。
_Avoid_: 自动学习、智能识别、AI 分流

**学习计数**（learn counter）：
「某域名被某台客户机查过几次」的累计记录，用于判定是否够格成为候选。
格式 `<域名>|<客户机>|<次数>|<首次>|<最近>`，落 `/var/run/dnschain/learn-counters.txt`。
**同一域名在 3 台机器各查 1 次，与 1 台机器查 3 次，是两种不同强度的证据** ——
判据取**单机最大值**而非总和。
_落点_：`_learn_accumulate`（累加）、`_learn_candidates`（按阈值筛）
_反例_：不是「流水表」—— 流水只留 600 秒（`flow_retain_sec`），
而累计要跨多轮，故必须单独一张表。
_Avoid_: 访问统计、热度

**学习游标**（learn cursor）：
流水表已消费到的位置，按**客户机**分别记 `<客户机>|<epoch>`。
作用是「同一批流水不会被重复累加」。
_落点_：`_learn_accumulate` 的第二段（只升不降）
_反例_：不能记单一游标 —— 不同客户机的流水交错写入，
单游标会漏掉「较晚写入但 epoch 较小」的记录。
_反例_：不能因为流水被修剪就让游标**回退** —— 下一轮会把已计过的记录再计一遍，次数虚高。
_Avoid_: 偏移量、指针

**待重试队列**（learn retry）：
「两条链都不通」的域名及其已试轮数，落 `/var/run/dnschain/learn-retry.txt`。
连续 3 轮都不通就**放弃实测**（`_LEARN_GIVEUP_MAX`），否则每轮都会重新测一遍。
_落点_：`_learn_retry_bump` / `_learn_retry_drop`
_反例_：不是「失败记录」—— 客户机链路诊断的 `client-fail.log` 记的是**客户机查询失败**，
本队列记的是**学习探测两条链都不通**，两者数据源与用途都不同。
_Avoid_: 黑名单、失败列表

**IP 段归属**（learn CIDR）：
把已学到的**国内**域名解析成 CIDR 后写进直连豁免集合的机制。
IPv4 取 `/24`、IPv6 取 `/64`。落 `/var/etc/dnschain/learn-cidr.txt`
（每行 `<4|6> <cidr>`），再单事务灌入 `ss_spec` 的 `dc_learn4` / `dc_learn6`。
_落点_：`dc_learn_derive_cidr`（派生）、`dc_learn_apply_cidr`（灌入）
_反例_：**只处理国内侧** —— 学到国外的域名不能进这个集合，
那会把本该走代理的 IP 改成直连。
_反例_：取更细（`/32`）会让相邻 IP 漏掉；取更粗（`/16`）会误伤整片。
_Avoid_: IP 库、网段表

**链路实测**（link probe）：
学习过程中对候选域名做的一次判定：分别经直连链（`:5353`）与代理链（`:5336`）
解析，按可达性与答案是否一致判出归属。
_落点_：`_learn_judge`；底层 `dc_probe_chain` / `dc_dns_first_addr`
_反例_：不是「TCP 探测」—— 那是 `dnschain-client-diag probe` 的职责（第④段链路），
学习只用 DNS 级探测，因为 TCP 探测每个域名要 3 秒超时，候选上千时不可行。
_Avoid_: 健康检查、连通性测试

**学习表**（learn set）：
存放学到的 IP 段的 nft 集合，名为 `dc_learn4` / `dc_learn6`，
**建在 `ss_spec` 表内**，并在 `ss_spec_wan_ac`（v4）与 `ss_spec6_tcp`（v6）
的**最前面**插一条带 `_DC_LEARN_HOOK_` 标记的 `counter return` 规则。
_落点_：`dc_learn_hook`（建集合 + 插挂钩）、`dc_learn_apply_cidr`（灌元素）
_反例_：**不能建成独立表** —— 实测 nft 1.1.6 不支持跨表引用集合
（`@dc_learn.s4` / `@inet.dc_learn.s4` / `@dc_learn/s4` / `dc_learn@s4` 四种写法
全部报错，跨表 `jump` 同样失败），独立表里的集合无法被 `ss_spec_wan_ac` 引用。
_反例_：**不能在更早的 nat 链里 `accept`** —— 实测在 `priority filter - 2` 建 nat output 链
并 accept 后，`ss_spec_wan_fw` 的 redirect 计数器照旧增长（257→258），拦不住。
_反例_：**挂钩不能追加到链尾** —— 前面的规则会 `jump ss_spec_wan_fw` 直接 redirect，
链尾的 `return` 永远轮不到。
_Avoid_: 学习集合、豁免表、白名单表

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
