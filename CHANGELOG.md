# Changelog

本仓库所有功能/配置改动均记录于此。版本判型遵循全局规范（PATCH / MINOR / MAJOR）。

## [v0.12.2] - 2026-10-22

### 修复 — 页面标题下多出一条灰色竖条

用户截图框出一条多余横条：位置在页面描述与 Tab 栏之间，
形状是约 **6×36px 的灰色竖条**。

#### 根因

CBI 为每个 Map 自动生成一个 `<ul class="cbi-tabmenu">` 容器。
本页的 section 都用 `TypedSection` / `NamedSection`，**没有声明 CBI
原生 tab**，所以它的 6 个 `<li>` 全是 `display:none`：

```html
<ul class="cbi-tabmenu">
  <li style="display:none" class="cbi-tab-disabled" data-tab="overview"><a href="#"></a></li>
  ... 共 6 个，全部 display:none
</ul>
```

但 `<ul>` 本身仍带主题背景色（shadcn 下是 `var(--muted)`，实测
`oklch(0.269 0 0)`）。子项全隐藏后容器塌成一条竖条，
宽 6px、高 36px，正好卡在描述与自建 tab 栏之间。

实测定位：

```
UL.cbi-tabmenu  rect: t=74 l=655 w=6 h=36
                bg: oklch(0.269 0 0)
                childCount: 6，全部 display:none
                prevSibling: DIV.cbi-map-descr
```

#### 修复

**CSS**（声明式，现代浏览器直接生效）：

```css
.cbi-tabmenu:not(:has(> li:not([style*="display:none"]):not([style*="display: none"]))) {
	display: none !important;
}
```

只隐藏「没有任何可见子项」的 tabmenu，避免误伤真正使用 CBI 原生 tab
的页面（那些 `<li>` 不是 `display:none`）。

**JS**（兜底，老 WebKit 不支持 `:has()`）：`dropEmptyTabmenu()` 在初始化时
遍历 `.cbi-tabmenu`，用 `getComputedStyle` 数可见子项，为 0 就移除节点。

**为什么用 CSS+JS 而不是去掉 CBI 的生成逻辑**：tabmenu 由 CBI 在渲染
阶段按 `.cbi-section` 结构补出来，不在 `general.lua` 的控制范围内；
改 CBI 内部实现会影响所有页面。

#### 验证

```
tabmenuExists: true          （节点仍在 DOM，但已隐藏）
tabmenuDisplay: "none"
elementsBetweenDescrAndTabs: []   （描述与 tab 栏之间已无任何可见元素）
tabsVisible: 46px
```

截图确认：描述文字下方直接是 Tab 栏，灰色竖条消失。

页面其余未变：HTTP 200、74173 字节、0 Lua 错误、12 section、
selftest **16/16 PASS**。

## [v0.12.1] - 2026-10-22

### 变更 — DNS 链路页从「网络」移到「服务」，紧跟 ShadowSocksR Plus+

原位置：网络 → DNS 链路。
新位置：**服务 → DNS 链路**，紧接在「ShadowSocksR Plus+」下一行。

理由：本页管的 dnsproxy 实例与 SSR-Plus 的分流是同一套链路，
放在「服务」下与 SSR-Plus 相邻，比埋在「网络」里更符合使用路径。

#### 排序依据（实测侧边栏顺序）

| 菜单项 | order | 定义位置 |
|---|---|---|
| ShadowSocksR Plus+ | **10** | `/usr/lib/lua/luci/controller/shadowsocksr.lua` |
| **DNS 链路** | **20** | 本页（新位置） |
| 动态 DNS | 59 | `menu.d/luci-app-ddns.json` |
| DNS Proxy | 60 | `menu.d/luci-app-dnsproxy.json` |
| 带宽监控 | 80 | `menu.d/luci-app-nlbwmon.json` |
| 网络唤醒 | 90 | `menu.d/luci-app-wol.json` |

⚠️ SSR-Plus 的 order **不在 menu.d JSON 里**，而是它 Lua controller
`entry()` 的最后一个参数（第 645 行）。要排在它下一行，本页 order
必须满足 `10 < order < 59`，取 **20** 留出余量。

#### 修掉的三个问题

**问题 A：设 `page.leaf = true` 会让侧边栏项消失**

v0.12.0 加过 `page.leaf = true`（本意是「每次进入都重新渲染」），
结果侧边栏里这一项**直接不见**。

实测原因是 leaf 节点在生成的菜单树 JSON 里带 `"wildcard": true`：

```json
"dns_chain": { "satisfied": true, …, "order": 20,
               "title": "DNS 链路", "wildcard": true }
```

LuCI 前端把 wildcard 节点当「占位/通配」不渲染成菜单链接。
去掉后正常，且 CBI 页面本来就不会被缓存（dispatcher 每次请求都重新
执行 controller 与 model）。

**问题 B：LuCI 菜单索引缓存键不含「文件内容」的语义变化**

`/usr/share/ucode/luci/dispatcher.uc:333` 的 `hash_filelist()` 是：

```ucode
hashval = hash(sprintf("%x|%x|%x", st.ino, st.mtime, st.size), hashval);
```

只吃 **inode / mtime / size**。用 `pscp -scp` 覆盖文件时，若 size 不变
且 mtime 落在同一秒，哈希不变 → 旧缓存继续生效。

改完菜单相关文件后必须：

```sh
rm -f /tmp/luci-indexcache.*.json
```

**问题 C：shadcn 主题的侧边栏有独立的前端缓存**

即使服务端菜单树已正确，侧边栏仍显示旧项。实测缓存位置：

| 位置 | 键 | 大小 |
|---|---|---|
| `sessionStorage` | `shadcn.sidebar.cache` | 8119 B |
| `localStorage` | `shadcn.sidebar` | 5 B |

主题从 `/luci-static/resources/menu-shadcn.js` 读代码，菜单数据缓存在
`sessionStorage`。**清 `/tmp/luci-indexcache` 不会影响它** —— 浏览器端
要清 sessionStorage，或关掉标签页重开。

#### 验证

菜单树 JSON（`window.ShadcnMenu.tree`）实测：

```
services 子项按 order 排序：
  upnp(0)  vlmcsd(0)  shadowsocksr(10)  dns_chain(20)
  ddns(59)  dnsproxy(60)  nlbw(80)  wol(90)

network 下已无 dns_chain
```

浏览器侧边栏截图确认：DNS 链路紧跟在 ShadowSocksR Plus+ 下一行。

页面本身无变化：6 个 tab、52 个配置项、selftest 16/16 PASS。

## [v0.12.0] - 2026-10-22

### 变更 — DNS 链路页重构为 Tab 式配置总控台（shadcn 视觉语言）

用户要求 7 项：美化图表、统一交互组件、删重复、集成三层全部可控参数并分 Tab、
优化性能、修链路图显示、核对 IP 集与各数据库一致性。

#### 关于 shadcn MCP 的实际情况

用户要求「用 shadcn MCP 重构前端」。实测确认**无法直接使用**：

```
$ npx shadcn@latest info --json
{ "project": { "framework": "Manual", "typescript": false,
               "tailwindVersion": null },
  "config": null, "components": [] }
```

本包是 LuCI 应用（Lua + CBI **服务端渲染**），仓库里没有 React、
没有 `package.json` / `components.json` / Tailwind。shadcn 的 Tabs、
Card、Chart、Badge 都是 React 组件，在这里无法安装也无法运行。

经确认改为**实现 shadcn 的视觉语言**而非其代码：

- 语义色令牌（ok/warn/bad/info）定义在 `dnschain.css`，浅色与暗色两套
- 卡片 / 徽标 / 提示条 / 指标条 / 统计卡 / 表格 六类原语
- 零构建、零依赖、离线可用，与 `luci-theme-shadcn` 视觉一致

#### 1. Tab 划分（6 个）

| Tab | 内容 | 原 section |
|---|---|---|
| **概览** | 结论 + 链路图 + 指标 + 组件状态 | 概览 |
| **解析** | 国内/国外上游 + 双栈 + 端口 + 缓存 | 5 个 |
| **分流** | 名单规模 + **IP 集核对** + 导入 + 源文件 | 名单与导入 |
| **代理** | SSR-Plus 兼容 + 拦截开关 | 2 个 |
| **DHCP** | DHCP 下发 DNS | 1 个 |
| **诊断** | 16 项自检 + 5 个操作按钮 | 自检 + 操作 |

**为什么用前端分组而不是 CBI 原生 tab**：CBI 的 tab 需要为每个 tab 建独立
Map 文件，页面加载要 parse 全部 Map —— 每个都跑一遍自检采集（实测 660ms），
反而更慢；而且跨 Map 无法一次保存。

实现：单张 CBI 表单 + 前端按 `<h3>` 标题归组，点击零网络请求。
归组表由服务端以 JSON 输出（`emit_tab_meta`），前端据此匹配。

**踩到的坑**：属性若用双引号包裹（`data-x="{...}"`），JSON 里的引号会把
属性截断，实测属性值只剩 `"{"`。必须用单引号包裹属性，内容里的单引号
转成 `&#39;`。

#### 2. 图表统一（第 1 项要求）

原来三处图表各写一套内联样式（条形、卡片、表格），颜色硬编码。
现在统一到 CSS 原语：

- `.dc-metric` — 指标条（轨道 + 填充 + 右对齐数值）
- `.dc-stat` — 统计卡（标签 / 数值 / 提示三层）
- `.dc-table` — 数据表（表头弱化、数字列 tabular-nums）
- `.dc-badge` — 状态徽标（ok/warn/bad/info/mute 五档）
- `.dc-alert` — 提示条（对应 shadcn Alert）

全部走 CSS 变量，明暗主题自动切换，不再在 Lua 里硬编码色值。

#### 3. 新增：IP 集归属核对表（第 7 项要求）

「分流」tab 新增一张核对表，实时对照 nft 集合与 SSR-Plus 各数据库。

**实测数据（2026-10-22）**：

| 集合 / 数据库 | 实测 | 源行数 | 说明 |
|---|---|---|---|
| 代理 IP 集（blacklist） | **200** | — | 运行时动态累加 |
| 国内 IP 段（china） | **2025** 区间 | **8612** CIDR | nft 合并相邻段 |
| GFW 域名数 | **17813** | **35608** | 源每域名 2 行（server= + ipset=） |
| 国内 IPv6 段 | **1019** | **1019** | 完全一致 |

**用户给出的三个基准全部核对一致**：GFW 17804（= 35608 ÷ 2）、
大陆 IP 段 8612、国内 IPv6 1019。

**关于「代理 IP 集 175」**：它不是固定配置，而是 `dnsmasq nftset=` 的
**运行时累加结果** —— 每解析出一个新的国外域名 IP 就加一条。
同一台机器上先后观测到 148 / 157 / 169 / 175 / 193 / 198 / 200。
所以核对目标不是「等于 175」，而是「只装 gfw 域名解析结果 + 随访问增长」。
页面按此语义显示，并注明「运行时动态累加，不是固定值」。

#### 4. 补全三层可控参数（第 4 项要求）

| 层 | 新增暴露的参数 |
|---|---|
| **dnsmasq** | `cache-size`、`filter_aaaa`（实际生效值，只读展示） |
| **dnsproxy** | 两个实例端口（`entry_port` / `foreign_port`）、`cert_verify`、`via_proxy` |
| **SSR-Plus** | `pdnsd_enable`、`ipv6_support`、`filter_aaaa`（可写）、`router_proxy` / `enable_switch` / `global_server`（只读展示） |

`filter_aaaa` 是本次重点：页面明确标注「写 `shadowsocksr` 的键，
但 `ipv6_support=1` 时会强制覆盖为保留」，并显示三个值的对照
（偏好 / 生效 / ipv6_support）。

#### 5. 性能（第 5 项要求）

| 阶段 | 页面加载 |
|---|---|
| v0.11.1 基线 | 1.22 s |
| 改造后（未优化） | 1.40 s |
| **优化后** | **1.29 s** |

新增的 IP 集核对表多花 0.07s，通过两处优化压回：

1. **`ipset_audit` 复用 `list_stats`** —— 原先 `gfw_list.conf`
   （35608 行）被读两次，实测多花 ~90ms
2. **`gfw_src` 直接取 `list_stats.gfw_lines`**，不再重复数行

耗时构成（实测）：`selftest` 690ms + 纯 Lua 读文件 136ms +
`nft china` 120ms + `netstat` 30ms + 其余 ~30ms ≈ 1.0s，
其余是 LuCI 框架开销。

#### 6. 修链路图（第 6 项要求）

- 连线颜色改为状态色（`var(--dc-ok)` / `var(--dc-bad)`），
  故障链路变红，一眼可见
- 文字用 `currentColor`，跟随主题
- 画布从 980 加宽到 1040，节点间距从 36px 拉到 96px（原来箭头几乎贴住节点）
- 标注放折线旁不压线
- 外层加 `.dc-chain { overflow-x: auto }`，窄屏可横向滚动而不挤压

#### 7. 删重复、合并集合（第 3 项要求）

原 12 个 section 里的重复与冗余：

| 处理 | 原项 | 去向 |
|---|---|---|
| 合并 | 「端口与实例」的 3 个只读项 | 并入「解析」tab，只留 2 个可编辑端口 + 1 个状态行 |
| 合并 | 「SSR-Plus 兼容」的 `_ssr_mode` / `_ssr_ipv6` | 合并为一个「SSR-Plus 当前状态」行（4 个徽标） |
| 删除 | 「双栈策略」的「说明」段 | 内容与「国外 AAAA」重复，已并入其描述 |
| 删除 | 「缓存」里与「自检」重复的统计 | 只保留缓存自己的计数 |
| 改语义 | 「名单规模」的纯文本 | 改为 4 张统计卡（GFW / 基础 / 已生成 / 最近更新） |

**功能一一对应**：改造后 52 个配置项覆盖原 30 项全部 + 新增 22 项
（端口、IP 集核对、SSR 状态、缓存统计等），无功能丢失。

### 修复

**BUG：诊断 tab 显示红色「1」但 FAIL=0**

摘要徽标「FAIL 0」用了 `dc-badge--bad`（红色），前端统计异常数时
按类名计数，把它算成 1 项失败。改为按数值决定颜色：`FAIL 0` 用中性色。

**BUG：tab 文字显示成「诊断1」**

徽标是按钮的子元素，`textContent` 把数字一起读进来。改为取第一个
文本节点。

**BUG：tab 栏上方多出 11px 空白**

服务端用空 section 输出元数据，CBI 给它套了 `.cbi-section` +
`.cbi-value` 两层。CSS 用 `:has()` 声明式处理，同时用 JS 兜底
（老 WebKit 不支持 `:has()`）。

### 验证

| # | 项目 | 结果 |
|---|---|---|
| 1 | 6 个 tab 切换 | 全部正常，默认「概览」 |
| 2 | 52 个配置项 | 0 空 section、0 Lua 错误 |
| 3 | 浅色主题 | 截图确认 |
| 4 | 深色主题 | 截图确认，徽标对比清晰 |
| 5 | IP 集核对表 | 4 行数据全部正确 |
| 6 | 链路图 | 7 节点、状态色、无压字 |
| 7 | 页面加载 | 1.29 s（5 次取样） |
| 8 | DNS 链路回归 | selftest **16/16 PASS** |
| 9 | 解析 | baidu 183.2.172.177 / taobao AAAA 240e:950:400:1:3::6d / google 142.251.153.119 / AAAA 2001:4860:4828:7700:: |
| 10 | 端到端 | google 302/302、baidu 200/200 |
| 11 | i18n | 222 条全覆盖 |
| 12 | CI 断言 | 新增 CSS 暗色令牌 + 资源非空断言 |

## [v0.11.1] - 2026-10-22

### 修复 — DNS 链路页从其他页面切过来要等 7.4 秒

用户报告：从其他页面切到 `dns_chain` 很慢。实测确认 **7.4 秒**，
而同固件的其他页面 **0.04 秒** —— 慢 **170 倍**。

#### 定位过程

用 `/proc/uptime` 做秒表（BusyBox 的 `date` 不支持 `%N`，`time` 内建的
输出格式又被管道吃掉，两种常见计时法在这里都不可用）逐项测：

```
dnschain-selftest        1370 ms   ← 被调用 2 次
ubus call dnsmasq metrics  10 ms
nft list set china        120 ms   ← 2025 个 CIDR
netstat                   20 ms    ← 每次 port_owner() 都起一个
```

页面里 `ds.selftest()` 被调用 **2 次**（「当前状态」+「自检表格」），
`ds.chain_snapshot()` 也被调用 **2 次**（链路图 + 图表），而
`chain_snapshot` 内部要查 4 个端口 → 4 个 `netstat` 进程。
同一份数据被反复采集，累计约 7.4 秒。

#### 修复 1：请求级缓存（主要收益）

在 `dnschain.lua` 加模块级 `cached(key, fn)`：同一 Lua 请求内每个采集函数
只真正执行一次。LuCI 每个 HTTP 请求是独立进程，模块级 table 天然只活一次
请求，无需失效逻辑、不会跨请求串数据。

覆盖：`selftest` / `chain_snapshot` / `cache_stats` / `list_stats` /
`set_count` / 6 个 uci 读取。

写操作（5 个按钮 + `sync_dnsmasq_filter_aaaa`）后调 `M.invalidate()`，
保证同请求内后续读取看到新值。

#### 修复 2：`listen_table()` 一次采集代替 N 次 netstat

原 `port_owner()` 每次起一个 `netstat -lnup`/`-lntp`。改为跑一次
`netstat -lntup`（TCP+UDP 合并），解析成 `{ ["udp:53"] = "16800" }` 表，
后续全部查表。`chain_snapshot` 的 4 次查询从 4 个进程降到 0。

#### 修复 3：`list_stats()` 改用纯 Lua 数行

原实现每个文件起一次 `wc -l`（3 个进程）+ 一次 `date -r`。改为
`io.open` + `gmatch("\n")` 数行（文件都在 page cache，35630 行 < 10ms）。
只保留 `date -r`（Lua 无 stat mtime 接口）。

#### 修复 4：`fw4 check` 按 mtime 指纹缓存

`fw4 check` 单次 **620ms**，占 selftest 45% —— 它要重新渲染整个 ruleset
模板（34 条 chain）再交给 `nft -c` 校验。

但它的结论只在「fw4 相关输入变了」时才变：`/etc/nftables.d/*.nft`、
`/etc/config/firewall`、fw4 模板、`ruleset-post/*.nft`。这些文件的
mtime 不变时，重复校验必然同结果。

改为按 mtime 指纹缓存到 `/tmp`（重启即清）：
- 输入没变 → 复用上次结论（0ms）
- 输入变了 → 重新校验
- `DNSCHAIN_FW4_NO_CACHE=1` → 强制重算（排障用）

#### 修复 5：第 15 项 grep 加 `^` 锚定（30 倍）

该项扫描全部 conf-dir（实测 2.1MB / 35630 行 `server=`），原正则
`server=/[^/]+/...` **没有行首锚定**，grep 要对每行尝试所有起始位置，
回溯代价高。

实测对比：

| 写法 | 耗时 |
|---|---|
| `server=/[^/]+/...`（无锚定） | 300 ms |
| `^server=/[^/]+/...`（有锚定） | **10 ms** |

#### 修复 6：第 2 项改为反选短路

`dnschain-split.conf` 实测 1.5MB / 17813 行。原实现用
`grep -hoE ... | sed | sort -u | tr` 收集全部端口再去重（3 个进程，170ms）。
改为「反选不等于 fport 的行 + head -1」，正常情况下扫到第一行即可确认
（170ms → 40ms）。

#### 效果

| 指标 | 修复前 | 修复后 | 倍数 |
|---|---|---|---|
| 页面加载 | 7.40 s | **1.22 s** | 6.1× |
| selftest 单次 | 1370 ms | **660 ms** | 2.1× |

#### 顺带修掉 3 个此前未发现的 BUG

**BUG A：所有组件显示红色 ✗「未监听」（最危险）**

`listen_table()` 的正则写成 `^(%u%l%l)`（首字母**大写**），而 BusyBox
`netstat` 输出的 Proto 是**小写** `tcp`/`udp` → 匹配不到任何行 →
所有端口判成「未监听」。

症状极具误导性：页面上 dnsmasq / 两个 dnsproxy / SSR-Plus 全变红 ✗、
结论行显示「国内 dnsproxy 未监听 —— 客户机全部无法解析」，
**而服务其实全在正常运行**。这类 bug 会让人以为全线故障。

同时修正 UDP 行没有 State 列的问题（不能固定列数，要取最后一个字段）。

**BUG B：5 个按钮的操作结果从来不显示**

本页「清空缓存 / 导入名单 / 更新 GFW / 一键归一」4 个按钮从 v0.9 起
就在 `write()` 里写 `m.message = "..."`，但**从来没显示过**。
本次新增的「立即重新自检」也一样。

实测查明的三层原因（缺一层都不显示）：

1. Button 的 `write()` 需要**非空 formvalue** 才触发 ——
   `cbi.lua:1424` 是 `if fvalue and #fvalue > 0`。按钮 HTML 的 value
   是按钮文字，浏览器提交会带上（用 curl 测时必须传 `name=按钮文字`）。
2. `dispatcher.lua:237` 是 `local cstate = res:parse()` —— **返回值被丢弃**，
   所以 `state_handler` 返回什么都到不了模板。
3. `dispatcher.lua:298` 读的是 `res.message`，即 **map 对象自身的字段**。

而 `m.message` 这个字段名是 **SimpleForm** 的（`cbi/simpleform.htm:22`），
Map 模板不读它 —— 这就是原写法无效的原因。

修复：`write()` 登记到 `_pending_message` → 覆写 `m.state_handler`，
在 parse 结束时写到 `self.message`。同时把消息里的 `<br/><pre>` 改成
`\n`（`map.htm` 用 `pcdata()` 转义 HTML，标签会显示成 `&#60;br/&#62;`）。

实测 4 个按钮消息均正确显示：
```
已重新自检：PASS=16 — 链路正常
✓ 已归一
✓ 已清空 dnsmasq 缓存（零中断）
✓ 已导入
```

**BUG C：`reconcile` 每次都误报写入失败**

`dnschain-reconcile` 第 101 行写的是
`access_control.@global[0].router_proxy` —— **缺包名，section 名也错**。
每次「一键归一」都输出：

```
dnschain: ERROR: 写入 access_control.@global[0].router_proxy=1 失败（原值 ''）
```

而该键实际已为 1（功能没坏，只是收敛器每次误报）。
正确键名是 `shadowsocksr.@access_control[0].router_proxy`。

### 新增 — 「立即重新自检」按钮

页面默认复用首次自检结果以加快加载。该按钮强制重算，
满足「用户主动要看最新状态」的场景。

### 验证

| # | 项目 | 方式 | 结果 |
|---|---|---|---|
| 1 | 页面加载耗时 | 路由器 curl 5 次 | **7.40s → 1.22s** |
| 2 | selftest 耗时 | `/proc/uptime` 秒表 | **1370ms → 660ms** |
| 3 | 组件状态 | 页面统计 | **12 个 ✓、0 个 ✗** |
| 4 | 按钮消息 | 4 个按钮 HTTP POST | 全部正确显示 |
| 5 | `reconcile` | 直接执行 | 无 ERROR 输出 |
| 6 | 页面完整性 | 浏览器实测 | 12 section、0 空、0 Lua 错误 |
| 7 | 链路图 / 图表 | 浏览器实测 | 7 节点 / 3 条形 + 4 卡片 |
| 8 | DNS 链路回归 | selftest + 解析 + 端到端 | **16/16 PASS** |
| 9 | 浅色 / 深色主题 | 浏览器截图 | 均正常 |

DNS 链路本身未受影响：
```
国内 baidu A      183.2.172.177
国内 taobao AAAA  240e:950:400:1:3::6d
国外 google A     142.251.157.119
国外 google AAAA  2001:4860:4827:7700::
google -4/‑6      302/302
baidu  -4/‑6      200/200
```

## [v0.11.0] - 2026-10-22

### 新增 — DNS 链路页升级为配置总控台（链路图 + 图表 + filter_aaaa 控制）

用户要求三件事：把 `shadowsocksr.filter_aaaa` 加到页面用滑块控制；检查
`dns_chain` 页的渲染 BUG；把全部控制功能补全为 DNS 配置总控台，并加图表
与链路图。施工中发现 **4 个真实渲染/提交 BUG**，一并修掉。

#### BUG 1：4 个 section 全部渲染为空（最严重）

现象：`概览`、`拦截总开关`、`端口与实例`、`操作` 四个 section 只显示
`This section contains no values yet`，里面的 `当前状态`、`链路状态`、
`当前端口`、4 个操作按钮全部不渲染。

根因：配置里是 `config dnschain 'main'` —— **类型名 `dnschain`，名字 `main`**。
而页面写的是 `m:section(TypedSection, "main")`，即「找类型为 `main` 的
section」—— 该类型不存在，于是拿到空集合。

修复：4 处改成 `TypedSection, "dnschain"`。

实测：空 section 从 4 → 0，配置项从 18 → 30 项，页面 37988 → 49260 字节。

#### BUG 2：上游服务器一个输入框都没有

现象：`解析策略` section 只渲染出 `上游服务器` 标题和两个 Flag，
`cn`/`foreign` 的 5 条上游地址（`tls://223.5.5.5` 等）**完全不可见、不可编辑**。

根因：`TypedSection + anonymous=true + template="cbi/tblsection"`。
`tblsection` 期望「每行一个具名 section」，而 `anonymous` 把 `cn`/`foreign`
两行合并，于是表格里只有列头、没有输入框。

修复：拆成两个 `NamedSection`（分别绑定 `cn` 与 `foreign`），去掉 `tblsection`。
语义也更清楚——国内池与国外池的约束本来就不同（国内可混用 DoT/DoH，
国外必须 DoH）。

实测：国内上游渲染出 3 个输入框，国外上游 2 个。

#### BUG 3：点「保存并应用」报 HTTP 500

现象：浏览器点保存后整页 500，任何配置都存不进去。

根因（从 500 页面抓到）：
```
dnschain.lua:95: attempt to call method 'match' (a nil value)
```
`upstream_port(url)` 直接 `url:match(...)`，而 `uci:foreach` 返回的
`sec.server` 在多值 list 时是 **table**，`DynamicList` 的 `value` 也可能是
table —— 传进来就崩。

修复：
- `upstream_port()` 加 `type(url) ~= "string"` 防御
- `validate_upstreams()` 增加 `collect_strings()` 摊平（接受
  string/table/nil 任意混合）
- 页面里的 `validate_upstream()` 同样改用 `collect_strings()`

实测：完整表单提交从 500 → 200。

#### BUG 4：`%s` 被字面写进 UCI

现象：`shadowsocksr.@global[0].filter_aaaa` 的值变成字符串 `%s`。

根因：`luci.sys.call("...'%s'...", v)` —— **`luci.sys.call` 不支持 `%s` 插值**，
它把参数原样当 shell 命令执行。

修复：改字符串拼接（`v` 只可能是 `"0"`/`"1"`，无注入风险）。

#### 新增：`filter_aaaa` 控制（用户明确要求）

页面「双栈策略」段新增三项：

| 控件 | 作用 |
|---|---|
| **抑制国外 AAAA**（下拉） | 写 `shadowsocksr.@global[0].filter_aaaa`，两选项：`关闭 — 保留 AAAA（推荐）` / `开启 — 抑制国外 AAAA` |
| **国外 AAAA**（状态） | 显示**实际生效值**，并在被覆盖时给出红字警示 |
| **实际生效值**（状态） | 同时显示 `shadowsocksr.filter_aaaa` / `dnsmasq.filter_aaaa` / `ipv6_support` 三个值 |

**关键设计：如实暴露联动关系，不假装滑块有效。**

实测（路由器上）：

```
shadowsocksr.filter_aaaa = 1   ← 用户偏好
ipv6_support             = 1
dnsmasq.filter_aaaa      = 0   ← 被 SSR-Plus 强制覆盖
```

`ipv6_support=1` 时，SSR-Plus 的 `get_filter_aaaa()` 直接返回 0 并调
`set_ipv6_dns_filter` 把 `dnsmasq.filter_aaaa` 设为 0 —— **无论偏好填什么**。

所以滑块的真实语义是「**关闭** IPv6 流量代理时要不要抑制 AAAA」。
页面用下拉旁的解释 + 红字警示把这一点讲清楚，而不是让用户以为设了就有用。

保存时 `sync_dnsmasq_filter_aaaa()` 会立即同步 dnsmasq 侧生效值，
**不重启 shadowsocksr**（那会断代理 3–10 秒）。

实测双向写入：

| 操作 | HTTP | `shadowsocksr.filter_aaaa` | `dnsmasq.filter_aaaa` |
|---|---|---|---|
| 设「关闭」 | 200 | 0 | 0 |
| 设「开启」 | 200 | 1 | 0（被 ipv6_support=1 覆盖，符合预期） |

#### 新增：解析链路图（内联 SVG，首屏主角）

7 节点三段式布局，全部用内联 SVG 实现（不引外部库）：

```
LAN 客户机 ──▶ dnsmasq ──┬──▶ dnsproxy 国内 ──▶ 国内上游（直连）
                          └──▶ dnsproxy 国外 ──▶ SSR-Plus ──▶ 国外上游（经代理）
```

- 节点颜色随存活状态变化（绿=正常 / 红=故障）
- 连线颜色同步，故障链路一眼可见
- 标注「默认」「gfw 域名」放在折线旁的空白处，**不压线**
- 底部标注 nftset 入集路径
- 用 `currentColor` + 显式语义色，**浅色与深色主题都验证过**

> 布局迭代 3 轮才定稿：初版两个 dnsproxy 上下错开 160px 却用斜线连接，
> 斜线正好穿过两行标注，实测截图里文字被线压住；改为直角折线并把标注
> 移到折线旁后解决。

#### 新增：链路指标（条形图 + 规模卡片）

- 三条相对长度条形：缓存插入 / 转发上游 / 本地应答，绝对值标在右侧
- 四张规模卡片：分流规则条数 / 代理 IP 集元素 / 国内 IP 段 / 未应答次数
- 图表限宽 620px（不限宽时 1387px 会把条形拉成横线，比例读不出）

数据来自 `chain_snapshot()` 一次采齐，全部是实测值；取不到时显示 `—`
而不是 `0`（0 与「未知」是两件事）。

#### 补全的控制项（配置键 100% 覆盖）

补齐 6 个此前未暴露的键：

| 键 | 说明 |
|---|---|
| `main.entry_port` | 国内实例端口（默认 5353） |
| `main.foreign_port` | 国外实例端口（默认 5336） |
| `main.intercept_doh` | 尽力阻断公共 DoH（仅标注） |
| `aaaa.filter_https_rr` | 抑制 SVCB/HTTPS 记录（默认关闭） |
| `lists.gfw_source` | GFW 名单源路径 |
| `lists.base_source` | 基础名单源路径 |
| `lists.black_source` | 强制代理名单源路径 |

另修正 7 个 `DummyValue` 缺 `rawhtml`（含 HTML 的显示成裸标签）。

#### 新增工具：`tools/extract-dnschain-i18n.py`

提取 `translate()` 字符串（正确处理多行 `..` 拼接），与 PO 比对。
`--write` 追加缺失条目。本次补齐 85 条，PO 从 117 → 197 条。

#### 验证

| # | 项目 | 方式 | 结果 |
|---|---|---|---|
| 1 | 3 个 Lua 文件语法 | `luac -p` | PASS |
| 2 | 空 section | 浏览器实测 | **4 → 0** |
| 3 | 配置项数 | 浏览器实测 | 18 → 30 |
| 4 | 上游输入框 | 浏览器实测 | 0 → 5（国内 3 + 国外 2） |
| 5 | 保存并应用 | 完整表单 POST | **500 → 200** |
| 6 | `filter_aaaa` 双向写入 | POST + `uci get` | 0↔1 正确 |
| 7 | 链路图 SVG | 浏览器实测 | 7 节点，浅色/深色均正常 |
| 8 | 图表 | 浏览器实测 | 3 条形 + 4 卡片 |
| 9 | 配置键覆盖 | 脚本比对 | 100% |
| 10 | i18n 覆盖 | `extract-dnschain-i18n.py` | 173 条全覆盖 |
| 11 | PO 结构 | 脚本校验 | 197 条、0 重复、0 空 msgstr |
| 12 | `rawhtml` 覆盖 | 脚本校验 | 全部覆盖 |

## [v0.10.0] - 2026-10-21

### 重构 — 移除 chinadns-ng，改双 dnsproxy 实例 + dnsmasq 分流

**起因**：v0.9.1 刷机后客户机全部无法解析。逐项排查发现两个真实缺陷，
且第一个修好后暴露出第二个更深的问题。

#### 缺陷 1：`paste` 命令缺失导致框架完全不启动（已修）

```
/etc/rc.common: line 273: paste: not found
ERROR: dnschain.upstream.foreign 为空，无法生成过滤器参数
ERROR: 生成运行时配置失败，中止启动
```

`dc_gen_filter_args` 用 `paste -sd, -` 拼国外上游列表，而 BusyBox **默认不编译
`paste`**（也没装 coreutils-paste）。`paste` 失败 → `trust` 为空 → 被误判成
「配置里没填上游」→ `dnsproxy :5353` 与 `chinadns-ng :5335` **都不启动**，
客户机解析全断。而 `uci get dnschain.foreign.server` 实际返回正常值。

改用 `awk 'NR>1{printf ","} {printf "%s", $0}'`（awk 在 BusyBox 必有）。
实测 5 种输入（单条/两条/三条/空/含空格）与 `paste -sd, -` **完全等价**。

#### 缺陷 2：chinadns-ng 的 DoT 上游在本环境永远不可用（架构性）

修好缺陷 1 后两个进程都起来了，但国外域名仍全部无结果。实测证据链：

| 测试 | 结果 |
|---|---|
| `tls://8.8.8.8:853` 经 `:1234` | ❌ `peer sent close notify`（只回 204 字节） |
| `tls://1.1.1.1:853` 经 `:1234` | ❌ 同上 |
| `tls://9.9.9.9:853` 经 `:1234` | ❌ 同上 |
| `8.8.8.8:443` 经 `:1234` | ✅ TLSv1.3 成功 |
| `1.1.1.1:80` 经 `:1234` | ✅ 301 |
| `223.5.5.5:853` **直连**（在 china 集） | ✅ TLSv1.3 |

**同一 IP，443/80 通、853 不通** → 落地节点到 853 的链路被阻断。

而 `chinadns-ng` 的 `-t` **只支持 `udp:// tcp:// tls://`，不支持 DoH**
（实测 `invalid proto: 'https://'`，二进制里 `doh` 字样数 = 0）。

**这形成死锁**：国外解析要么用 DoT（853 不通），要么放弃加密。
用国内 DNS 查国外则拿到污染答案（实测 `google → 104.244.42.197`、
`AAAA → 2001::1`）。

#### 新架构

```
dnsmasq:53（唯一缓存 + 唯一分流层）
  ├─ 默认              → 127.0.0.1#5353  dnsproxy 实例 1（阿里 DoT/DoH，直连）
  ├─ server=/国外域名/ → 127.0.0.1#5336  dnsproxy 实例 2（Google DoH，经 :1234）
  └─ nftset=/国外域名/4#inet#ss_spec#blacklist
       解析结果自动写入代理 IP 集（替代 chinadns-ng 的 -A）
```

| 组件 | 变化 |
|---|---|
| `chinadns-ng` | **移除**（不再启动、不再配置） |
| `dnsproxy` | 从 1 个实例变 **2 个**（`:5353` 国内 / `:5336` 国外） |
| 国外上游 | `tls://8.8.8.8` → `https://dns.google/dns-query`（DoH 走 443） |
| AAAA 抑制 | **取消**（`foreign 'suppress'` → `'keep'`） |
| `filter_https_rr` | `1` → `0`（不再抑制 SVCB/HTTPS） |
| SSR-Plus `ipv6_support` | 强制 `1`（IPv6 流量也走代理） |
| SSR-Plus `filter_aaaa` | 强制 `0`（保留国外双栈） |

#### 为什么取消 AAAA 抑制

SSR-Plus 的「IPv6 流量代理」（`ipv6_support=1`）实测效果：

| 测试 | 结果 |
|---|---|
| `curl -6 www.google.com` | ✅ 302 |
| `curl -6 www.youtube.com` | ✅ 200 |
| `curl -6 www.baidu.com` | ✅ 200（国内直连） |
| IPv6 代理链 | ✅ 10 条（`ss_spec6_*`） |
| 策略路由 | ✅ `fwmark 0x53535250 → table 999` |
| `dnsmasq.filter_aaaa` | ✅ 自动设为 **0** |

既然国外 IPv6 也走代理，就不存在「IPv6 直连被 RST」的问题，
抑制 AAAA 反而让国外站点失去双栈能力。

#### 关键教训：不能用 dnsproxy 的 `[/域名/]` 分流

最初实现是单实例 + `upstreams-domains.txt`（17767 条
`[/域名/]https://dns.google`）。**实测完全失败**：

```
DEBUG upstream is reserved idx=3    addr=https://dns.google:443/dns-query domains_num=1
DEBUG upstream is reserved idx=4    addr=https://dns.google:443/dns-query domains_num=1
...（一直到 idx=17769）
```

`dnsproxy` 为**每个域名各注册一条 reserved 上游**，17767 个条目耗尽资源，
查询直接 `connection timed out; no servers could be reached`。
而国内域名（走默认上游）正常。

改成「两个实例 + dnsmasq 的 `server=/域名/` 分流」后立即正常。

#### 关键教训：不能过滤 `xn--`

v0.9.x 生成上游文件时过滤 `xn--`（因为 dnsproxy 的 `[/域名/]` 形式不认
punycode，会整体拒绝启动）。v0.10.0 改用 dnsmasq 的 `server=/域名/` 形式，
**dnsmasq 原生支持 punycode，不能过滤**。

实测依据：`gfw_list.conf` 有 58 条 `xn--` 域名，过滤后它们只剩
`server=/域名/127.0.0.1#5335`（该端口已无监听），全部解析失败
（`apple.xn--czr694b`、`nike.xn--hxt814e` 等）。改为不过滤后恢复。

#### selftest 判据的四处修正

16 项自检里有 4 项的判据本身有误，一并修正：

| 项 | 旧判据 | 新判据 | 为什么 |
|---|---|---|---|
| 1 | 检查 `nft chain inet fw4 dns_intercept_lan` | 检查 LAN 地址上 `:53` 能否解析 | 该链**从来不存在**，而 dnsmasq 直接监听 LAN:53，客户机无需 nft 劫持 |
| 2 | 扫描整个 SSR conf-dir 的端口 | 只查框架自己的 `dnschain-split.conf` | SSR-Plus 的 17804 条 `#5335` 是它自己的文件（框架不重写），会永久误报 |
| 7 | 读 `shadowsocksr.filter_aaaa` | 读 `dhcp.@dnsmasq[0].filter_aaaa` | 前者是用户偏好，后者才是实际生效值；实测前者=1 而 AAAA 完全正常 |
| 15 | `grep -v '#5353'` | 只统计非 `127.0.0.1` 的 IP | 旧写法把 `#5336`（国外实例）误判成明文旁路，虚报 35627 条 |

另修 `dns_class` 的 AAAA 判定 bug：原用 `grep -vc ':'` 排除服务器行，
但 **IPv6 地址本身含冒号**，导致 AAAA 答案全被过滤 → 永久误报 EMPTY。

### 实测结果（路由器 192.168.3.254）

自检 **16/16 全 PASS，`CONCLUSION: 链路正常`**：

| 类别 | 结果 |
|---|---|
| 国内 A | `baidu → 183.2.172.177`、`qq → 121.14.77.221` ✅ |
| 国内 AAAA | `taobao → 240e:950:400:1:3::6e` ✅ 保留 |
| **国外 A** | `google → 142.251.155.119` ✅ **真实**（原为 `104.244.42.197`） |
| **国外 AAAA** | `google → 2001:4860:4826:7700::` ✅ **真实**（原为 `2001::1`） |

端到端访问：

| 目标 | IPv4 | IPv6 |
|---|---|---|
| google.com | 302 ✅ | 302 ✅ |
| youtube.com | 200 ✅ | 200 ✅ |
| github.com | 301 ✅ | 000（该站无 IPv6，正常） |
| baidu.com | 200 ✅ | 200 ✅ |

nftset 生效：`blacklist` 集内出现 `142.251.12.94`、`142.251.20.94` 等真实 IP。

### CI 断言同步

| 断言 | 旧 | 新 |
|---|---|---|
| 4 | 必须有 `-N tag:gfw` | **不得有** `dc_gen_filter_args` |
| 4b | — | 必须有 `dc_gen_foreign_args` |
| 4c | — | **不得有** `[/&/]` 形式（会耗尽 dnsproxy 资源） |
| 6 | 必须过滤 `xn--` | **不得过滤** `xn--` |
| 9 | `profile 'primary'` / `foreign 'suppress'` | `foreign_port '5336'` / `foreign 'keep'` / `require_ipv6 '1'` |
| 9b | — | 国外上游必须是 DoH，且不得有 `tls://8.8.8.8` |
| `.config` | 要求 `chinadns-ng=y` | 不再要求（框架不依赖该组件） |

`tools/verify-dnschain-ci-sim.sh` 模拟校验 **36 项全 OK**。

### 验证

| # | 项目 | 方式 | 结果 |
|---|---|---|---|
| 1 | 5 个脚本 dash 语法 | `sh -n` | 全 PASS |
| 2 | `paste`/`awk` 等价性 | 5 种输入对比 | 完全等价 |
| 3 | 双实例启动 | 路由器实测 | `:5353` + `:5336` 均在监听 |
| 4 | 自检 16 项 | 路由器实测 | **16/16 PASS** |
| 5 | 端到端 IPv4/IPv6 | `curl -4` / `curl -6` | 全通 |
| 6 | CI 模拟 | `verify-dnschain-ci-sim.sh` | 36 项 OK |
| 7 | YAML 语法 | `yaml.safe_load` | PASS |
| 8 | 行尾 | `od -c` | 全 LF |

## [v0.9.1] - 2026-10-21

### 修复 — 不能关掉 `luci-theme-bootstrap`（v0.9.1 首次构建失败）

run `39549176947` 失败于 `Verify SQM / i18n enabled`：

```
=== LuCI 主题：shadcn 必须启用 ===
OK   CONFIG_PACKAGE_luci-theme-shadcn=y
FAIL luci-theme-bootstrap 仍被启用（应已关闭）
--- .config 中与 luci-theme 有关的全部符号 ---
CONFIG_PACKAGE_luci-theme-bootstrap=y
CONFIG_PACKAGE_luci-theme-shadcn=y
```

**根因**：lede 的 `collections/luci/Makefile`（标准 LuCI 集合包）**硬依赖**
`+luci-theme-bootstrap`：

```make
LUCI_TITLE:=Standard OpenWrt set including full admin with ppp support and the default Bootstrap theme
LUCI_DEPENDS:= \
  +uhttpd +uhttpd-mod-ubus +luci-mod-admin-full +luci-theme-bootstrap \
  ...
```

写 `# CONFIG_PACKAGE_luci-theme-bootstrap is not set` 只会被下一条
`make defconfig` 的依赖求解**再次选回 `=y`**。这是我在设计时没查清的
依赖关系，属于过度设计。

**修正**：保留 bootstrap，只切换默认主题。

| 项 | 改前 | 改后 |
|---|---|---|
| `luci-theme-shadcn` | `=y` | `=y` |
| `luci-theme-bootstrap` | 试图关闭 → **失败** | **保留**（`=y`，作回退路径） |
| `material`/`openwrt`/`openwrt-2020`/`argon`/`design` | 关闭 | 关闭（不在集合包依赖里，可关） |
| 断言 | 要求 bootstrap 必须关闭 | bootstrap 仅报告；shadcn 必须启用；其余主题必须关闭 |

**保留 bootstrap 反而更好**：shadcn 若在真机上有兼容问题，把
`luci.main.mediaurlbase` 改回 `/luci-static/bootstrap` 即可回退，
**不需要重新编译固件**。代价只是固件多约 300 KB。

### 新增 — LuCI 主题 shadcn 编入固件并设为默认

按用户要求把 `youridol/luci-theme-shadcn` 作为固件的默认 LuCI 主题。

| 改动 | 位置 | 说明 |
|---|---|---|
| 新增 `Fetch luci-theme-shadcn` 步骤 | CI | `git clone --depth 1` 只取构建需要的 5 项（`Makefile` / `root` / `htdocs` / `ucode` / `LICENSE`），排除 `.dev`/`.husky`/`.github` 等开发工具链 |
| 新增 `files/etc/uci-defaults/99-zzz-luci-theme-shadcn` | overlay | **无条件**设 `luci.main.mediaurlbase=/luci-static/shadcn` |
| `.config` 启用 | CI | `luci-theme-shadcn=y`，关掉非默认主题 |
| 新增契约断言 | CI | 主题符号入 `.config`、overlay 脚本就位且排序晚于 `30_` |

**为什么必须自己写 overlay 脚本（主题包自带的那个不够）**

主题自带的 `root/etc/uci-defaults/30_luci-theme-shadcn` 内容是：

```sh
if [ "$PKG_UPGRADE" != 1 ]; then
    uci get luci.themes.Shadcn >/dev/null 2>&1 || \
    uci batch <<-EOF
        set luci.themes.Shadcn=/luci-static/shadcn
        set luci.main.mediaurlbase=/luci-static/shadcn
        commit luci
    EOF
fi
```

它用 `uci get luci.themes.Shadcn ||` 做**存在性短路**：只要该键已被注册，
整个 if 就跳过，**不会改 `mediaurlbase`**。而 LuCI 的默认主题由
`luci.main.mediaurlbase` 决定 —— 若它仍指向 `bootstrap`，shadcn 装了也看不到。

我们的 `99-zzz-` 排在 `30_` 之后，无条件写 `mediaurlbase`，覆盖任何先前值。
同时保留主题缺失保护：`/www/luci-static/shadcn/main.css` 不存在时跳过设置，
避免把 `mediaurlbase` 指到一个不存在的目录导致 LuCI 白屏。

**为什么用固定 clone 而不是 feed**

- 该仓库不在 lede 的任何 feed 里
- feed 机制会拉全部分支且无 commit 固定，主题更新导致样式错乱时很难定位版本
- 主题的 `main.css`（134 KB）与 6 个 woff2 **已预构建入库**，不需要前端构建
- 实测体积 1020 KB / 67 个文件（htdocs 占 896 KB）

### 修复 — `Download package sources` 卡死导致 6 小时超时

**现象**：run `39495602665`（commit `90457d4`）在 `Download package sources`
这一步跑了 **5h54m**，直到 job 的 6h 上限被取消。日志尾部：

```
48 23.2M   48 11.2M    0     0    556      0 12:09:24  5:52:10  6:17:14     0
                                              ↑ 556 B/s
```

即 `nasm-2.16.03.tar.gz` 从 `www.nasm.us` 以 **556 字节/秒**下载，
11.2 MB 花了 5h52m，预计还要 6h17m。

**根因**：lede 的 `scripts/download.pl` 对每个文件按 `@mirrors` 顺序逐个尝试
（`while (!-f ...) { my $mirror = shift @mirrors; ... }`），而 **curl 没有
单文件超时** —— 遇到慢源就无限等。

**对策**（都利用 `download.pl` 已有的扩展点，不改上游代码）：

| 手段 | 机制 | 效果 |
|---|---|---|
| `DOWNLOAD_MIRROR` | `download.pl:53-54` 读取，且 `localmirrors()` 在 `@mirrors` **最前面**被调用（第 241 行） | 列出的镜像**优先级最高**，慢源被跳过 |
| `CURL_OPTIONS=--max-time 300` | `download.pl:112` 透传给 curl | 单文件最多 5 分钟，超时即换下一个镜像 |
| `timeout 3000 make download` | 外层硬超时 | 即使 curl 选项没生效（如走 aria2c 分支），50 分钟后明确失败 |
| `timeout-minutes: 60` | 步骤级 | 兜底，不让它吃满 job 的 6h |

新增镜像列表（实测可达）：
`sources.cdn.openwrt.org` / `sources.openwrt.org` / `mirrors.aliyun.com/gnu` /
`mirrors.tencent.com/gnu` / `mirrors.ustc.edu.cn/gnu`。

下载前会先探测各镜像对 `nasm-2.16.03.tar.gz` 的 HTTP 状态（只报告不阻断），
失败时打印各镜像结果并提示「把可用镜像补进 `DOWNLOAD_MIRROR`」。

### 验证

| # | 项目 | 方式 | 结果 |
|---|---|---|---|
| 1 | YAML 语法 | `yaml.safe_load` | PASS |
| 2 | 超时防护 6 项 | 提取步骤脚本逐项断言 | 全 OK |
| 3 | 主题 Fetch 步骤 5 项 | 提取步骤脚本逐项断言 | 全 OK |
| 4 | **不再关闭 bootstrap** | 断言 for 循环与独立语句都不含 bootstrap | PASS |
| 5 | 主题断言修正 | bootstrap 仅报告、shadcn 必须启用、其余主题必须关闭 | PASS |
| 6 | overlay 脚本 | `sh -n`（dash） | PASS |
| 7 | 断言路径正确性 | 确认 `Apply files overlay` 在断言之后，故用 `../openwrt-build/` 前缀 | PASS |
| 8 | **真实 clone 主题** | `git clone --depth 1` + 复制 + 4 项契约断言 | 全 OK（commit `625a8c1`，1020 KB / 67 文件） |
| 9 | 行尾 | `od -c` 统计 CR | 全 0 |

**真实 clone 测试的实测数据**：

```
Makefile                      447 字节
30_luci-theme-shadcn          235 字节
main.css                   134262 字节（> 20000 下限，已预构建）
login.css                   11443 字节
主题总体积                   1020 KB / 67 个文件
```

## [v0.9.0] - 2026-10-20

### 新增 — DNS 链路框架 `dnschain`（运行时骨架 + 控制页面）

按 `docs/adr/0003-dns-chain-framework.md` 落地 P1/P2 阶段的运行时组件。
**本版本只交付骨架与页面，默认不启用**：`dnschain.main.enabled` 虽为 `1`，
但 `dnsproxy` 与 `chinadns-ng` 的实际启停由 `init.d/dnschain` 控制，
且首刷后需在页面确认端口所有权后才生效。

| 类型 | 路径 | 说明 |
|---|---|---|
| 新增 | `files/etc/config/dnschain` | UCI 配置（9 个 section） |
| 新增 | `files/usr/share/dnschain/dnschain.sh` | 共用函数库（配置读取、参数生成、端口校验） |
| 新增 | `files/etc/init.d/dnschain` | procd 托管 dnsproxy `:5353` 与过滤器 `:5335` |
| 新增 | `files/usr/bin/dnschain-reconcile` | 收敛器：重放不变量集 + 名单单向导入 |
| 新增 | `files/usr/bin/dnschain-selftest` | 16 项自检，输出机器可读结果 |
| 新增 | `files/etc/uci-defaults/99-zz-dnschain` | 首刷默认（排在 `99-gaming-optimize` 之后） |
| 新增 | `files/etc/capabilities/dnschain-filter.json` | 过滤器的 `CAP_NET_ADMIN`（`-A` 写 nftset 需要） |
| 新增 | `package/luci-app-dnschain/` | LuCI 页面（菜单 `网络 → DNS 链路`） |
| 修改 | `.gitattributes` | 5 条无扩展名路径强制 LF |
| 修改 | `.github/workflows/build-openwrt.yml` | `chmod +x` 清单 + 契约校验步骤 |

**核心设计要点**（每条都有 ADR 依据）：

1. **缓存只在 dnsmasq 一层**。`dnsproxy.args` 与 `filter.args` 由脚本生成，
   生成逻辑里**不存在** `--cache`（CI 有反向断言）。
2. **国外上游必须 IP 形式**。`dc_upstream_port` 按 scheme 推断端口，
   `preflight` 校验端口必须在运行时 `ss_spec_output` 端口集内，
   越界即拒绝启动并列出越界项（否则路由器自身出向静默直连、国外域名全挂）。
3. **IDNA 域名不进 dnsproxy 文件**。124 个 `xn--` 会让 dnsproxy
   **整体拒绝启动**（实测 `idna: invalid label`），故生成时过滤，
   另写 `idna-bypass.conf` 交由 dnsmasq 的 punycode 路径兜底。
4. **不配 `--fallback`**。过滤器不可用时返回 SERVFAIL 而非回落国内上游
   （后者会把 `youtube.com` 解析成 `31.13.92.37` 并缓存）。
5. **`-N tag:gfw` 而非裸 `-N`**。裸 `-N` 会连带抑制将来引入的其他组。
6. **不收 `114.114.114.114`**。chinadns-ng 的 `-c` 默认值就是明文 114，
   生成逻辑不写该参数，CI 断言参数里不出现该地址。
7. **收敛而非删除**。框架不删、不重写 SSR-Plus 生成的任何文件，
   保留 `server=/域名/#5335` 作为同策略旁路（ADR §9.1）。

**页面**（`网络 → DNS 链路`）：

- 概览：一句话结论行（按组件实测状态归纳）+ 6 行状态表（fw4 劫持 / dnsmasq /
  dnsproxy / 过滤器 / 代理 / 缓存统计）
- 拦截总开关（滑块）+ 拒绝 LAN 出向 853
- DHCP 下发 DNS（多个明文地址，仅拦截关闭时使用）
- 解析策略（两侧上游，含端口校验）
- 双栈策略（只读，附「1ms 空答复 ≠ 超时」说明）
- 端口档案 `primary` / `coexist` + SSR-Plus 当前模式显示
- 名单规模与导入（自动/手动 + 立即更新 GFW）
- 缓存开关与统计
- 16 项自检表格
- 四个动作按钮：清空缓存（SIGHUP 零中断）/ 手动导入 / 立即更新 GFW / 一键归一

### 修复 — CI 契约断言会把 `$(( ))` 误判成 bash 语法

新增的 `Verify dnschain framework contracts` 步骤首版用了
`\(\([^)]*\)\)[[:space:]]*$` 判定 bash 的 `(( ))` 命令，结果把
`pct=$(( delta * 100 / old_lines ))` 这类**合法的 POSIX 算术展开**也判成违规，
导致构建必然失败。已改为「行首或 `;`/`&&`/`||` 之后紧跟 `((` 且不是 `$((`」才判定。

### 修复 — 三次构建失败/缺陷的根因与处置（v0.9.0 出包前）

本版共触发 3 次构建，前两次失败或产物不完整。三次的根因各不相同，
且**都属于「本地校验看不出来」的类型**，值得逐条记录。

#### (1) `Verify dnschain framework contracts` 找不到 ADR 文档

```
FAIL 缺少 docs/adr/0003-dns-chain-framework.md
FAIL 缺少 docs/adr/0004-dns-chain-verification.md
```

根因：该步骤 `working-directory: lede`，而 `docs/` 在**仓库根**（与 lede 同级）。
`docs/...` 指到了 `lede/docs/`（lede 源码自带目录），里面没有本仓库的 ADR。

修法：改用 `../openwrt-build/docs/...`，与 CI 里其他引用仓库根文件的地方
（`../openwrt-build/patches/`、`../openwrt-build/package/`）一致。

**新增 `tools/verify-dnschain-ci-sim.sh`**：本地复现 CI 的工作目录
（`lede/` + `files/` 已复制）再跑同一段校验。原因：

| 本地跑法 | 结果 | 是否等价 CI |
|---|---|---|
| 在仓库根跑 | 全部通过 | **否**（没验证 lede/ 场景） |
| 在 lede/ 跑但没复制 files/ | 全部 FAIL | 否（CI 会先复制） |
| lede/ + files/ 已复制 | 与 CI 一致 | **是** |

#### (2) 产物版本号静默错位（`v0.8.6` 而非 `v0.9.0`）

产物名是 `openwrt-x86-64-ssrplus-v0.8.6-f39f3cd`。

根因：CI 用 `grep -m1 '^## \[v'` 取 CHANGELOG 第一个**带 `[v` 的**标题。
CHANGELOG 顶部写的是 `## [未发布]`，不匹配 `[v`，于是被跳过，
取到了下面的 `## [v0.8.6]`。**整个过程零报错**。

修法两处：
1. CHANGELOG 顶部标题改为 `## [v0.9.0] - 2026-10-20`
2. `Resolve version from CHANGELOG` 加断言：第一条 `## [` 标题必须就是版本标题，
   否则 `exit 1` 并打印两条标题

反向验证：改回 `[未发布]` → `EXIT=1`；改回 `v0.9.0` → `EXIT=0`。

#### (3) LuCI 页面整层缺失（最隐蔽的一处）

固件产物 245 MB、30 个步骤全绿、`Assert firmware artifact exists` 通过，
但解包后发现 **`luci-app-dnschain` 相关条目数 = 0** —— 页面一个文件都没编进去。

根因：CI 只写了 `Add luci-app-trafficctl` 的复制步骤，
**从未复制 `package/luci-app-dnschain`**，也没在 `.config` 里启用它。

修法三处：
1. 新增 `Add luci-app-dnschain` 步骤（复制 + 7 个关键文件断言）
2. `.config` 增加 `luci-app-dnschain=y`、`luci-i18n-dnschain-zh-cn=y`、
   `chinadns-ng=y`
3. `Verify SQM / i18n` 步骤加 `=== dnschain 本体与中文语言包都必须入配置 ===`
   断言块（符号被依赖求解丢弃时构建失败，而不是静默出包）

**验证方法本身也错了两次**，同样记录：

| 错误做法 | 后果 |
|---|---|
| 用 `unsquashfs -l <path>` 判断单文件是否存在 | 该命令对**不存在的路径也返回 0**，把「13 项全缺」误报成「13 项全 OK」 |
| 用 `unsquashfs -d <dir> <file> <多个路径>` | 该版本（4.5）不按预期提取，解出 0 个文件 |

正确做法：`unsquashfs -ll` 列**全量**清单再 grep，同时能看到权限位。

#### 由此新增的两条验证纪律（写入 ADR-0004 §0 的 E7/E8）

- **E7：overlay 文件在 ≠ 功能在。** 必须分两层查——`files/` 的 overlay
  与 `package/` 的 LuCI 页面。两条路径独立，包没编进去时 overlay 依然全在。
- **E8：不能用 `unsquashfs -l <path>` 判断存在性。** 用 `-ll` 列全量再 grep。

ADR-0004 相应新增 §1.2（第二层：LuCI 页面）、§12.1（刷机前的产物预检），
并把 §12 记录表从 20 项扩到 21 项。

### 测试中发现并修掉的缺陷（骨架阶段）

| # | 项目 | 方式 | 结果 |
|---|---|---|---|
| 1 | 5 个 shell 脚本语法 | `sh -n`（Ubuntu 22.04 的 `/bin/sh` = **dash**，与 CI runner 一致） | 全 PASS |
| 2 | 3 个 Lua 文件语法 | `luac5.1 -p`（Lua 5.1，与 LuCI 运行时一致） | 全 PASS |
| 3 | 3 个 JSON 文件 | `json.load` | 全 PASS |
| 4 | PO 文件配对 | `msgid`/`msgstr` 计数 | 108/108 |
| 5 | 行尾 | `od -c` 统计 CR 字节 | 全部 0 |
| 6 | 上游端口推断 | 6 种 URL 形态（含 IPv6 与显式端口） | 全部正确 |
| 7 | 名单提取与 IDNA 分离 | 仿真 `gfw_list.conf`（含 `xn--` 与无 TLD 非法域名） | 4 条合法 / 2 条 IDNA / 1 条非法被丢弃 |
| 8 | 参数生成 | mock uci/nft 环境跑 `dc_gen_*` | `-t` 有值、无 `--cache`/`--fallback`/`--ipv6-disabled`/明文 114 |
| 9 | 指纹幂等 | 连续两次 `dc_lists_fingerprint` | 相同；改名单后变化 |
| 10 | **CI 断言有效性** | 逐项故意破坏 7 处后复跑 | **7/7 被拦住**，恢复后全 PASS |

**测试中发现并修掉的真实缺陷**（都不是语法检查能发现的）：

1. `dc_get_list` 调用点传参错误 —— `dc_get_list upstream cn` 读的是
   `dnschain.upstream.cn`（一个 section），而配置里 option 名是 `server`，
   正确写法是 `dc_get_list cn server`。症状：`-t` 参数为空、过滤器起不来。
2. 库脚本里 `tr ' ' '\n'` 被写成 `tr '''\n'`（首个参数空格丢失），
   在 dash 下退化为恒等变换 → 所有 list 读取返回空。已统一改为双引号形式。
3. `dc_gen_filter_args` 在国外上游为空时会产出 `-t` 后跟空行；
   已改为显式报错并返回非零（禁止生成非法参数）。
4. `general.lua` 概览里有一段三元表达式两边都是 `"5353"` 的死代码，
   已改为真实的四分支判断（dnsproxy / 过滤器 / 端口占用 / 代理）。

### P3 — 收敛缓存层：dnsproxy 关闭缓存

`files/etc/config/dnsproxy` 改为缓存关闭，并移除 fallback：

| 项 | 改动 | 依据 |
|---|---|---|
| `cache.enabled` | `'1'` → `'0'` | 缓存只在 dnsmasq 一层（ADR §10.5）。三处并存会让同一域名出现两份答案 |
| `cache.min_ttl` / `max_ttl` | `60`/`86400` → `0`/`0` | `--cache-min-ttl` 会人为延长 TTL，改上游后最坏 60 秒仍给旧答案 |
| `list fallback` | **删除** | fallback 是全局的，过滤器不可用时回落污染上游（CHANGELOG v0.8.0 的 `youtube.com → 31.13.92.37` 就是这条路径） |
| `servers.upstream` | 三条国内 DoH → 两条 DoT + 一条 DoH | 与 `dnschain` 的 `config upstream 'cn'` 一致，避免「关掉框架后行为变了」 |

**新增 CI 断言**（3 条）：`cache.enabled` 必须为 `'0'`、不得有 `list fallback`、`ipv6_disabled` 必须为 `'0'`。

### P4 — 四项收尾

**1. `init.d/dnsproxy` 让位逻辑（解决端口抢占）**

此前 `init.d/dnsproxy`（START=90）与 `init.d/dnschain`（START=95）**都**启动
`/usr/bin/dnsproxy`，两个 procd 实例抢 `:5353`，后起的静默失败。

现在 `init.d/dnsproxy` 检测 `dnschain.main.enabled=1` 时：
- `start_service` 直接返回，打印「由 dnschain 框架托管」
- `stop_service` 不动拦截规则（本服务从未起过实例）
- `reload_service` 转发给 `dnschain reload`

判断依据是**配置意图**而非进程状态（开机时序下用 `pgrep` 会误判，AGENTS §8）。

**2. `applechina.conf` overlay（消除明文 DNS 旁路）**

新增 `files/etc/ssrplus/applechina.conf`：173 条 `server=/<Apple 域名>/114.114.114.114`
改为 `127.0.0.1#5353`。

- **不设** `apple_dns`：init 脚本的 `old_appledns` 用 `grep -oE` 只抽 IP、丢端口，
  二次启动会叠成 `127.0.0.1#5353#5353`（AGENTS §9 已记录）
- 行数保持 173（CI 断言），数据行全部指向加密入口（CI 断言）

**3. 853 拒绝的优先级已实测**

在路由器上验证了 ADR 列为必测项的 T2 写法：

```
裸 chain + priority -151 单独 nft -f  → 语法错误（缺 table 上下文，预期）
table 内嵌 priority -151 链           → ACCEPTED
nft list 显示                          → priority mangle - 1（即 -151，先于 mangle -150）
临时加载后 counter                     → 规则正常建立
```

结论：`/etc/nftables.d/15-dnschain-reject-dot.nft` 的裸 chain 写法**正确**，
fw4 会把它 include 到 `table inet fw4` 内部，优先级生效。

**4. `coexist` 档案的自检判据修正**

`dnschain-selftest` 第 2 项原判据在 `coexist` 下会误报（SSR 的旁路指向 `:5335`，
而 `filter_port` 是 `:5337`）。已改为按档案区分允许集，并在输出里显示 `profile`。

### 新增 — `docs/adr/0004-dns-chain-verification.md`（全链路验证规程）

刷机后逐项核对的执行文档，14 节：

| 节 | 内容 |
|---|---|
| §1 | 文件/执行位/包是否就位 |
| §2 | **端口所有权**（`:5335` 属谁、SSR 三个键） |
| §3 | **缓存层唯一性**（含「两份答案是否消失」的最强证据） |
| §4 | 四类域名解析（国内 A/AAAA、国外 AAAA 的 EMPTY 判据） |
| §5 | 分流三层（DNS / IP / 出站） |
| §6 | 双栈与 853 拒绝（含从客户机验证） |
| §7 | 名单导入（规模、dnsproxy 是否加载、自动导入） |
| §8 | **抗「改 LuCI 就坏」**（故意改坏三个键，看收敛器改回） |
| §9 | 降级矩阵（五处故障） |
| §10 | **失败排查树**（四类症状 → 定位路径） |
| §11 | 回滚（只退框架 / 完整回退） |
| §12 | 验证记录表（可勾选） |
| §13 | 已知边界（8 条，不属故障） |
| §14 | 与 ADR-0003 的章节对应 |

### 验证

| # | 项目 | 方式 | 结果 |
|---|---|---|---|
| 1 | 7 个 shell 脚本 | `sh -n`（Ubuntu 22.04 的 `/bin/sh` = dash） | 全 PASS |
| 2 | 3 个 Lua | `luac5.1 -p` | 全 PASS |
| 3 | 3 个 JSON | `json.load` | 全 PASS |
| 4 | YAML | `yaml.safe_load` | PASS |
| 5 | 行尾 | 全部改动文件 `od -c` 统计 CR | 全部 0 |
| 6 | CI 契约校验 | 提取步骤脚本本地执行 | 31 项全 OK |
| 7 | **断言有效性（第一批）** | 故意破坏 7 处 | **7/7 被拦住** |
| 8 | **断言有效性（P3/P4 新增）** | 故意破坏 6 处 | **6/6 被拦住** |
| 9 | 853 优先级 | 路由器实测 `nft -c -f` + 加载后 `nft list` | 显示 `priority mangle - 1`，语法有效 |

**仍待刷机后验证**（已在 ADR-0004 §12 列为可勾选项）：
- 页面在真机 LuCI 中的渲染（本地只有 Lua 语法校验）
- `8.8.8.8:853` / `1.1.1.1:853` 证书是否含 IP SAN（`--cert-verify` 依赖它）
- 端到端：`dnschain-selftest` 16 项在真机的实际输出
- §8 的「故意改坏再收敛」实测

### 文档 — 重写 DNS 链路框架 ADR，撤回两份与代码不符的旧稿

**背景**：`docs/adr/0003-dns-chain-architecture.md` 与 `0004-dns-chain-framework.md`
两份旧稿互相覆盖、都标「提议」，且多处写「已实测」但仓库里没有对应代码。
本轮在路由器上逐条取证后重写为**一份** ADR。

**删除**

| 文件 | 原因 |
|---|---|
| `docs/adr/0003-dns-chain-architecture.md` | ① `gfw2ipset.sh` 路径写错（实际在 `/usr/share/shadowsocksr/`，不在 `/usr/bin/`）；② 把「行数」当「域名数」（47434 vs 23717）；③ 声称的 `--upstream <path>` 域名文件生成器**从未存在**；④ 留了四个未决问题，与 0004 互相覆盖 |
| `docs/adr/0004-dns-chain-framework.md` | ① 自称取代 0003 但两者并存、都标「提议」；② 建立在「`dnsmasq restart` 已改 reload」之上，而仓库 overlay 实际生成的仍是 restart；③ `coexist` 档案下重写 `gfw_list.conf` 会引入新的时序依赖；④ 设计了三层缓存并存，与「只留一层」的结论相反 |

两份都是**孤岛文档**：除彼此外全仓库零引用（0004 除自身标题行外无任何引用），
CHANGELOG 无 v0.8.x 条目提及，`AGENTS.md` §4/§5 也未指向它们——因此能一路写着
与代码不符的内容而没人发现。

**新增**：`docs/adr/0003-dns-chain-framework.md`（编号复用 0003，不制造空洞）

核心设计：

| 项 | 决策 |
|---|---|
| 单一路由入口 | dnsproxy `:5353`，国内→国内加密池、gfw→策略过滤器 |
| 策略过滤器 | 框架自持 chinadns-ng `:5335`，只做 gfw 域名的 AAAA/HTTPS 抑制 + 国外 DoT |
| 单一缓存层 | 只在 dnsmasq（客户机唯一入口）；dnsproxy 与过滤器均不缓存 |
| 分流抗漂移 | **收敛**而非删除：保留 SSR 生成的 `server=/域名/#5335` 作为同策略旁路 |
| 名单导入 | 单向复制到 `/etc/dnschain/`，轮询 md5 自动导入 + 手动导入 |
| 拦截开关 | 滑块决定拦不拦；关闭时按页面配置的明文 DNS 下发给 DHCP 客户机 |

### 修复 — `AGENTS.md` §4.4 的断言会永久误报

原文断言「两处 `restart` 一律改 `reload`（`grep -c 'dnsmasq restart'` 应为 **0**）」。
路由器实测（`/etc/init.d/shadowsocksr`，3324 行）：

```
3161:	/etc/init.d/dnsmasq reload >/dev/null 2>&1          ← 真调用
3305:			echolog "restart: skip dnsmasq restart in stop()"   ← 只是日志字符串
3309:			/etc/init.d/dnsmasq reload >/dev/null 2>&1      ← 真调用
```

`grep -c` 返回 **1**，但那是 `echolog` 里的**文本**，不是调用点。已改为
「排除 `echolog` 行后统计真正的调用，应为 0」，并记下另一处漂移：
仓库 `files/etc/uci-defaults/99-gaming-optimize:503` 生成的代码**仍是**
`/etc/init.d/dnsmasq restart`，与固件实况不一致，下次刷机可能把 reload 改回 restart。

### 修复 — `GLOSSARY.md` 的组件角色已失效

- `dnsproxy` 条目仍写「另有 24 条硬编码国外域名例外指向 mosdns」——该清单
  v0.8.0 已删，且 `AGENTS.md` 明令不要加回。已重写为「唯一路由型解析器」。
- `dnsmasq` 改为「唯一入口 + 唯一缓存层 + DHCP」，删除「按域名分派」的旧描述。
- `mosdns` 改为「仅 SSR 模式 4 时存在，不在默认链路中」。
- 新增术语：`策略过滤器`、`端口所有权`、`档案`、`收敛器`。
- `跳数` 更新为 dnsmasq → dnsproxy → 过滤器 → 上游 DoT。

### 验证

本轮所有结论均来自路由器只读取证（`192.168.3.254`，OpenWrt 24.10.5 x86/64）。
关键实测：

| # | 事实 | 证据 |
|---|---|---|
| 1 | **dnsproxy 用国内上游直接答 gfw 域名会返回污染答案** | `www.google.com` → `2001::1` + `104.244.42.197`；同域名经 `:53` 分流得 `142.251.x.x` |
| 2 | 124 个 `xn--` 域名使 dnsproxy **整体拒绝启动** | `bad domain name "xn--wcvs22d1m.hk": idna: invalid label` |
| 3 | `gfw_list.conf` 47434 行 = 23717 域名 × 2 | `grep -c '^server='` = 23717，`^ipset=` = 23717 |
| 4 | 运行时副本 `ipset=` 被**整行删除**（不是转换） | `^ipset=`=0、`^nftset=`=0、行数 23717 |
| 5 | `gfw2ipset.sh` 在 `/usr/share/shadowsocksr/` | `find / -name 'gfw2ipset*'` |
| 6 | 三层缓存只有两层在工作 | mosdns `:5335` 连查 5 次全为 60–80ms（从不命中）；dnsmasq `:53` 为 80/0/0/10/0ms |
| 7 | dnsproxy `--cache-size` 单位是**字节**，当前 8192 = 8KB | `--help`：`Cache size (in bytes). Default: 64k.` |
| 8 | `ss_spec_output` 只匹配 TCP，端口集含 853 不含 53 | `nft list chain inet ss_spec ss_spec_output` |
| 9 | `blacklist` 7 元素（全来自 `wan_fw_ips`）、`whitelist` 空 | `nft list set` 实测 |
| 10 | 国内 IPv6 库是死路径 | `ipv6_support=0` → `ipv6_rules_apply` 首步 `return 0`；`nft list set inet ss_spec china6` 报不存在 |

**测量纪律**：`date +%s%N` 在 BusyBox 上**不支持**，会静默返回秒级值、全部显示
0ms（本轮首次测量因此作废）。测延迟必须用 `/proc/uptime`（厘秒）。

**未做**：本轮只交付文档，未改任何 `files/`、CI、`.gitattributes` 或页面代码。
固件代码落地按 ADR §13.4 的 P1–P4 分阶段进行。

## [v0.8.6] - 2026-10-20

### 修复 — SSR-Plus 运行一段时间后「无法安装透明代理规则，启动中止」

**症状**：SSR-Plus 偶发启动中止，日志只有一行：

```
2026-10-20 04:48:01: ERROR: 无法安装透明代理规则，启动中止。
```

紧接着 `restart` 会自己再试一次并成功，所以表现为「偶发、能自愈」，
但期间透明代理与 DNS 分流全部中断。

**关键线索**：`ssr-rules` 自己**一条失败日志都没有** —— 既无
`NFTables setup failed!`，也无 `NFT forced rebuild failed!`。
它所有失败分支都会 `loger 3` 记一笔，一条都没有说明它**不是跑失败的，
是被杀死的**。

**复现（5/5 稳定）**：并发两个 `/etc/init.d/shadowsocksr restart` 必定触发；
串行连跑 5 次增量恒为 0。

**根因（两个叠加）**：

1. **互斥锁形同虚设。** `set_lock()` 是 `flock -xn 1000`（`-n` 非阻塞）
   且**忽略返回值** —— 拿不到锁也照样往下走；`unset_lock()` 又
   `rm -rf "$LOCK_FILE"` 把**被锁的那个 inode 删掉**，下一个进程重新创建
   同名文件、锁到另一个 inode。实测：A 持锁时删文件后 B 立即也能拿到锁。
   于是 `start()` 与 `stop()` 真正并发执行。

2. **`stop()` 按 cmdline 杀 ssr-rules。**
   `ps_list | grep ssr-rules | xargs kill -9` 会杀掉**并发实例**正在执行的
   `/usr/bin/ssr-rules`。而 `start_rules()` 是
   `flush_r && ipset_r && fw_rule && ac_rule && tp_rule && ipv6_rules_apply && gen_include`
   的 `&&` 链，中途被 SIGKILL 必然返回非 0 → 打出该 ERROR。
   插桩实证：`step=flush_r ok` 之后不再有任何 step 日志。

**为什么「运行一段时间后」才出现**：开机是串行的。只有周期性触发器撞在一起
才并发 —— `ssr-monitor` 每 30s 巡检、`99-ssrplus-pppoe` 在 `ifup wan` 后
10s 触发、订阅自动更新。本机 `network.wan.proto=pppoe`，每次重拨都会触发
一次 restart，与 monitor 巡检重叠即中招。这解释了 04:09 / 04:11 / 04:47
三个时间点各出现一次的形态。

**修法**（`files/etc/uci-defaults/99-gaming-optimize` 第 4.10 节，幂等）：

| 改动 | 内容 |
|---|---|
| `set_lock()` | 改为有界等待（最多 60s），超时明确报错退出，不再静默继续 |
| `unset_lock()` | 只 `flock -u` + 关 fd，**不删锁文件**（文件常驻） |
| `unlock()` | 不再以「文件是否存在」判断（该判据与删除行为互相矛盾） |
| `stop()` | 不再按 cmdline kill ssr-rules；守护进程已由 `ssr-rules -K` 按 pid 文件停止 |

**验证**：

- 并发 restart × 5 轮、三并发 × 3 轮：ERROR 增量**全部为 0**
  （修复前每轮必现）。
- 锁的 A/B 对照（两个持锁 3s 的 worker 并发）：
  修复后总耗时 **6s**（真正串行），原版 **3s**（同时进入）。
- 串行 restart × 5 次：增量 0（未引入回归）。
- 端到端：`nft list tables` 含 2 个 ss_spec 表、`:5335`/`:1234` 均在监听、
  `fwmark 0x53535250` 规则在位、`global_server` 未被写成 nil、
  国内域名解析正常、`curl https://www.google.com` 经代理返回 302。
- `fw4 check` → `Ruleset passes nftables check.`
- 语法：`sh -n`（dash）通过；`.gitattributes` 要求的 LF 行尾保持（CR 字节 = 0）。

### 已知问题（本次未修，独立缺陷）

**`dnsmasq reload` 不会重新读取 conf-dir，导致 SSR-Plus 的 gfw 分流在
某些时机不生效。** 这是排查本轮故障时**顺带发现**的独立问题，
与上面的并发缺陷无关，未在本次改动范围内。

实测证据：往 `/tmp/dnsmasq.d/dnsmasq-ssrplus.d/` 放
`address=/zz-probe.invalid/3.3.3.3` 后，
`/etc/init.d/dnsmasq reload` → 探针解析**无结果**；
`/etc/init.d/dnsmasq restart` → 解析得 `3.3.3.3`。
dnsmasq 的 `SIGHUP` 只清缓存、不重读配置文件。

而 OpenWrt 的 `reload_service()` 是
`rc_procd start_service "$@"; procd_send_signal dnsmasq "$@"` ——
`start_service` 会重新生成 `/var/etc/dnsmasq.conf.*`，但 `SIGHUP` 不会
让已运行的进程重新读它，因此**新增的 conf-dir 文件对运行中的 dnsmasq 不可见**。

v0.8.3 把 `stop()`/`start()` 里的 `dnsmasq restart` 改成 `reload`，
目的是避免 restart 期间约 3 秒全断。这个目的达到了，但副作用是：
**SSR-Plus 重建 gfw_list.conf 后，dnsmasq 可能仍用旧内容**，
表现为部分国外域名拿到污染答案（实测 `www.reddit.com` 曾返回
`157.240.7.20` / `2001::1`，而直连 mosdns:5335 返回正确的
`151.101.x.x`）。

需在「零中断」与「配置必生效」之间重新取舍（候选：只在
gfw_list.conf 的 md5 变化时才 restart；或改用
`/etc/init.d/dnsmasq restart` 但把中断窗口压到最小）。
**改动此项属修改 DNS 配置，须先申请批准**（见 AGENTS.md 第 9 节）。

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

## [v0.8.3] - 2026-10-17

### 修复 — `restart` 期间 dnsmasq 被重启两次，客户机中断约 8 秒

`/etc/init.d/shadowsocksr` 的 `stop()` 与 `start()` **各自**执行一次
`/etc/init.d/dnsmasq restart`，而 `restart` 由 `/etc/rc.common` 实现为
`stop + start`，于是一次 `restart` 把 dnsmasq 重启**两次**。

实测（0.5 秒粒度记录 PID）：

```
修复前：22:45:18 → 22:45:21   又  22:45:32 → 22:45:35   ← 断两次
修复后：22:48:09 → 22:48:12                              ← 只断一次
```

每次 dnsmasq 不可用约 **3 秒**，期间客户机**所有**域名（含国内 baidu）
全部无法解析。

另：实测 `dnsmasq reload`（SIGHUP 重读配置）**失败 0 次**，且能正确加载新增的
`server=/域名/127.0.0.1#5335` 分流（已验证：临时写入
`server=/reloadtest.example/127.0.0.1#9999` 后 reload，查询确实被送往 `:9999`）。

### 变更

1. 覆写 `restart()`，设置并导出 `SSR_IN_RESTART=1`
2. `stop()` 内那次 dnsmasq `restart` 加标志守卫，restart 场景下跳过
3. 两处 `dnsmasq restart` 一律改为 `dnsmasq reload`（`restart` 计数降为 0）

**已验证**：`shadowsocksr restart` 全程 DNS 失败 0 次、dnsmasq PID 不变。

## [v0.8.2] - 2026-10-17

### 修复 — `ssr-switch` 把 `global_server` 写成 `nil`，导致客户机全部解析超时

v0.8.1 关闭 `enable_switch` 只是让守护**不再启动**，既管不住已在跑的守护，
也没修 `set_main_server()` 本身的缺陷。本轮补上真正的根因修复。

**监控日志给出了确凿的切换轨迹**（每 2 秒采样 `global_server`）：

```
22:02:31 *** gs=cfg014a8f → cfg194a8f   ← 被自动切到另一个节点
22:04:09 *** gs=cfg194a8f → nil          ← 再被切成 nil，客户机全挂
```

**根因：`set_main_server()` 只判空串，不判字符串 `"nil"`**

`/usr/bin/ssr-switch` 原实现：

```sh
set_main_server() {
	local sid="$1"
	[ -n "$sid" ] || return 1        # ← 只判空串
	uci set shadowsocksr.@global[0].global_server="$sid"
	uci commit shadowsocksr
}
```

而 `select_proxy()` 在全部候选节点探测失败时，把 `ENABLE_SERVER` 置为
**字符串 `"nil"`**（不是空串）。于是 `set_main_server "nil"` 顺利通过
`-n` 检查，`uci set global_server=nil` **落盘**。

后果链条：`load_config()` 见 `GLOBAL_SERVER=nil` 直接 `return 1`
→ 一条 nft 规则都不装、MosDNS/Xray 全不启动
→ 但 LuCI 里 `enable=1` 仍显示「运行中」
→ 客户机 DNS 全部 timeout，而路由器自身因走 `/etc/resolv.conf` 的
运营商 DNS 而显得正常（这就是「路由侧正常、客户机挂」的物理原因）。

**客户端实测症状与 DNS 无关，是连通性假象**：`conntrack` 显示

```
tcp SYN_SENT src=192.168.3.238 dst=20.205.243.166 dport=443 [UNREPLIED]
tcp SYN_SENT src=192.168.3.238 dst=104.244.42.197 dport=443 [UNREPLIED]
tcp ...      src=192.168.3.238 dst=171.108.221.221 dport=443 [OFFLOAD]   ← 国内正常
```

国内 TCP 正常 `[OFFLOAD]`，国外 TCP 全停在 `SYN_SENT` 无回应。
用户侧表现为「ping 通、HTTP 无 200」/ `os error 11001`。

### 变更

**`files/etc/uci-defaults/99-gaming-optimize`：给 `ssr-switch` 打两处幂等补丁**

| 补丁 | 内容 |
|---|---|
| (a) | `set_main_server()` 增加 `[ "$sid" != "nil" ] \|\| return 1`，显式拒绝写 nil |
| (b) | `run_once()` 的 else 分支不再盲写 `CURRENT_SERVER`，改为「保留原节点只重启」 |

两处都带 `修复 v0.8.2` 标记，打前先 `grep -q` 判重，因此**幂等**。
补丁后立刻 `sh -n` 校验，失败则自动回滚到 `.orig`
（遵循红线 3：禁止静默失败）。

**已验证**

- `set_main_server "nil"` 单元测试 → **返回 1（拦截成功）**，`global_server` 未被改动
- 脚本连跑 2 次：`gs=cfg014a8f`、`switch=0`、`nil防护=2`、`rule=14` **全部稳定**
- `sh -n /usr/bin/ssr-switch` 通过
- 客户机 5 分钟长窗口（每 30 秒一轮）：`gs` 保持 `cfg014a8f` 不再被改写

### 本轮方法论的教训（重要）

1. **「路由侧正常、客户机挂」这个组合本身就把矛头指向 SSR-Plus 的
   `global_server` 状态，而不是 DNS 配置。** 路由器走
   `/etc/resolv.conf`（运营商 DNS），完全绕过 dnsmasq/mosdns；
   只要客户机挂而路由器不挂，问题必在 `dnsmasq → dnsproxy/mosdns` 这条链上，
   而这条链在 `gs=nil` 时会整体失踪。
2. **必须监控 `global_server` 的变化，而不是只看某一时刻的组件状态。**
   我此前反复在「健康态」里测，每次都通过；只有按 2 秒粒度连续采样
   `global_server`，才看见 `cfg014a8f → cfg194a8f → nil` 的完整轨迹。
3. **`pgrep -f` 会匹配到诊断命令自身。** 一度报告「ssr-switch 有 2 个进程」，
   实际是 `pgrep -f "ssr-switch start"` 命中了自己的 `ash -c` 命令行。
   判定应遍历 `/proc/*/cmdline` 并排除 `ash -c`。

## [v0.8.1] - 2026-10-17

### 修复 — `ssr-switch` 周期性 restart 导致客户机 DNS 间歇失败

**故障现象**（用户复核后）：启用 SSR-Plus 后，客户机解析**时好时坏**；
`www.codebuddy.cn` 等域名偶发失败，而**路由器侧始终正常**；
dnsproxy 日志同时刷 `1.12.12.12` DoH 的 `context deadline exceeded`。

**根因：`enable_switch='1'` 让 `ssr-switch` 周期性重启整个服务**

`/usr/bin/ssr-switch` 每 `switch_time` 秒（本机 **667s**）探测当前节点，
失败即执行 `/etc/init.d/shadowsocksr restart`（脚本第 155 行）。
而 `start()` 的执行顺序制造了一个**必然的 DNS 空窗**：

```
21:39:35  gs=cfg014a8f  5335=0  1234=1  nft=0  gfw=23701   ← 分流已生效，后端未起
21:39:37  gs=cfg014a8f  5335=1  1234=1  nft=2  gfw=23701   ← 才就绪
```

即 `gfw2ipset` 先把 **23701 条** `server=/域名/127.0.0.1#5335` 拷进 dnsmasq，
约 2 秒后 `start_dns`/`start_server` 才拉起 MosDNS/Xray。这 **4 秒窗口**
内查任何 gfw_list 里的域名都 timeout。0.5 秒粒度采样已固证。

**探测本身还会误判**：`switch_time=3`（脚本内变量）是 **curl 超时 3 秒**，
跨境节点的 TLS 握手常超过它。探测失败且全部候选节点均判失败时，
`select_proxy` 返回 `ENABLE_SERVER=nil`，`switch_proxy` 便
`uci set global_server=nil` —— 界面仍显示「已启用」，但 `load_config()`
`return 1`，**一条规则都不装**，进入「已启用但空转」的半死状态
（本次多次实测到 `enable=1` 而 `global_server=nil`、无 `ss_spec` 表）。

另需注意：本机 68 个节点中 62 个共用同一域名
`unamecf.xn--ghqu5fm27b67w.com` → `108.162.198.60`（Cloudflare 地址）。
`nc -z` 对该地址报「不可达」，但 Xray 侧有 **ESTABLISHED** 连接
（`100.119.107.42:52836 → 108.162.198.60:443`），说明节点实际可用 ——
**裸 TCP 探测对这类地址不可信**，这也正是 ssr-switch 误判的来源。

### 变更

**`files/etc/uci-defaults/99-gaming-optimize`：`enable_switch='0'`**

单节点家用场景不需要自动切换，其收益远小于周期性中断的代价。
关闭后 `start_switch()` 的 `if` 不成立，守护不再启动，重启只在手动操作
或开机时发生。已在文件内写明「若日后确需自动切换」的三个前置条件：
①`switch_time`（探测超时）≥ 10s；②全节点失败时**保留原 `global_server`**
而非写 nil；③修 `start()` 顺序为「后端就绪后再装分流」。

**已验证**：连跑 10 轮 × 3 个此前失败域名（`www.moe.gov.cn`、
`www.codebuddy.cn`、`www.stats.gov.cn`），**10/10 全部正常，0 次失败**。

### 同时确认（无改动）

- `www.codebuddy.cn` / `www.moe.gov.cn` **均不在** `gfw_list`、`gfw_base`、
  `applechina.conf`、`deny.list` 中；`applechina.conf` 无宽泛通配条目。
  24 项清单复核结果：`codebuddy`/`dnse5`/`cn`/`com` 命中数均为 **0**。
- 解析到的 IP（`171.108.x`、`211.100.0.108`）**均落在 `nft @china` 内**，
  走直连、不经代理。
- `@china` 运行时集合覆盖三家国内 DoH（`223.5.5.5` / `1.12.12.12` /
  `36.99.170.86`），故 dnsproxy 的 DoH 出站**不会**被 `ss_spec` 劫持。
  那批 `1.12.12.12` 超时是**同一条 PTR 查询重试 3 次**（间隔恰为
  `--timeout 10s`：20:59:23/33/43），针对 `lb._dns-sd._udp.*.in-addr.arpa`
  反解；`parallel` 模式下其他上游仍在答，属噪声，非故障源。

### 排查方法沉淀（新增两条）

- **判定进程是否存在，不能用 `pgrep -x <名字>`**：SSR-Plus 的二进制以
  完整路径运行（`/var/etc/ssrplus/bin/v2ray`、`.../mosdns`），
  `pgrep -x xray` / `pgrep -x mosdns` 恒为 0，会误判成「后端没起」。
  应按 `/proc/*/cmdline` 匹配，或 `pgrep -f '/var/etc/ssrplus/bin/'`。
- **`nc -z` 不能用来判断代理节点可用性**：Cloudflare 前置的节点对裸 TCP
  不响应，但真实 TLS 握手正常。判据应看 `netstat -antp` 里是否有
  **ESTABLISHED** 到节点的连接，或直接测经代理解析/访问的结果。

## [v0.8.0] - 2026-10-17

### 修复 — 启用 ShadowSocksR Plus+ 后客户机 DNS 解析失败

**故障现象**（经用户复核后的准确描述）：启用 SSR-Plus 后，`192.168.3.254`
后的**客户机**解析异常；**路由器自身**不受影响；禁用后恢复。

**⭐ 结论先行：`filter_aaaa=1` 就是「国外去 AAAA、国内保双栈」的正确实现**

用户诉求是「国外不走 IPv6 直连（避免被 RST），国内保持双栈」。经实测，
当前 `shadowsocksr.@global[0].filter_aaaa='1'` **已经精确实现该语义**，
无需改动。实测（`Check-DnsName.js`，原始 UDP 绕过缓存）：

| 域名 | 归类 | A | AAAA | AAAA 耗时 |
|---|---|---|---|---|
| `www.moe.gov.cn` | 国内（不在 gfw_list） | ✅ `211.97.84.77` | ✅ `2408:875c:0:80::6c` | 28ms |
| `www.cac.gov.cn` | 国内（不在 gfw_list） | ✅ `27.155.113.144` | ✅ `240e:95c:806:40::413` | 36ms |
| `www.github.com` | 国外（在 gfw_list） | ✅ `4.237.22.38`（经代理） | ⛔ 空答复 | **1ms** |
| `www.youtube.com` | 国外（在 gfw_list） | ✅ `142.251.154.4` | ⛔ 空答复 | **1ms** |
| `www.wikipedia.org` | 国外（在 gfw_list） | ✅ `103.102.166.224` | ⛔ 空答复 | **1ms** |

**关键：国外 AAAA 是「1ms 空答复」而不是「5 秒超时」。** 客户端收到
`rcode=0 an=0` 会**立刻**回落查 A，不会等待。早先把这一形态误读为超时，
是本轮排查中最严重的一次误判（见下方「误判修正」）。

**分流依据（三份清单，规模为实测）**

| 清单 | 规模 | 作用 |
|---|---|---|
| `gfw_list.conf` | 23701 条 `server=/域名/127.0.0.1#5335` | 国外域名 → MosDNS |
| `gfw_base.conf` | 55 条 | 同上（基础集） |
| `applechina.conf` | 173 行明文 `114.114.114.114` | Apple 域名走国内明文 |
| `black.list` | 0 行 | 为空，不参与 |
| `deny.list` | 13 行 | 广告/禁止域名 |

国内域名**不在**上述清单内，因此走 dnsproxy:5353 的国内 DoH，双栈不受影响。

**实测证据（受控启停，非推测）**

客户机侧用原始 UDP（绕过系统缓存）：

| 场景 | `:5335` | `ss_spec` 规则 | 国内 A | 国外 A | 国外 AAAA |
|---|---|---|---|---|---|
| SSR 禁用 | 无监听 | 无 | 3/3 | 3/3 | ⚠️ 返回**污染值** `2001::1` |
| SSR 启用（后端正常） | 监听 | 有（2 表） | 3/3 | 3/3 | ⛔ 空答复 1ms（**预期**） |
| SSR 启用 + 后端全挂 | 无监听 | 有 | 3/3 | ❌ 超时 | ❌ 超时 |

**注意第 1 行**：禁用 SSR 时国外 AAAA 拿到的是
`2001:0:0:0:0:0:0:1` / `2001:df2:e500:ed1a::1` 这类**污染地址** ——
这正是「国外 IPv6 直连被 RST」的成因，也是必须启用 SSR 的理由之一。

**根因（真正需要修的，两条）**

1. **`stop()` 无法可靠停干净：`ssr-switch` 会在 stop 期间把后端重新拉起。**
   实测：`uci set enable=0` + `/etc/init.d/shadowsocksr stop` 之后，
   `enable=0` 但 `v2ray`(:1234)、`mosdns`(:5335) 仍在运行、
   `ss_spec` 两张表仍在、`ip rule 999` 仍在 —— 形成
   「已禁用但规则与后端都活着」的半停状态。此时客户机行为不受控。
   正确的手工清理顺序（已实测有效）：
   ```sh
   pkill -9 -f ssr-switch            # 必须先杀守护，否则它会把后端拉回来
   rm -f /var/lock/ssr-switch.lock
   uci set shadowsocksr.@global[0].enable='0'; uci commit shadowsocksr
   /etc/init.d/shadowsocksr stop
   pkill -9 -f '/var/etc/ssrplus/bin/'
   nft delete table inet ss_spec; nft delete table ip ss_spec_mangle
   ip rule del fwmark 0x53535250 table 999
   rm -f /tmp/dnsmasq.d/dnsmasq-ssrplus.conf
   rm -rf /tmp/dnsmasq.d/dnsmasq-ssrplus.d
   /etc/init.d/dnsmasq restart
   ```

2. **`gfw_list.conf` 在 stop 之后仍会残留在 dnsmasq 的 conf-dir 里。**
   实测：清理后 `dnsmasq-ssrplus.d/gfw_list.conf` 仍在（23701 条指向已死的
   `:5335`），导致**国外域名全部超时、国内正常**。必须显式删掉该目录并
   `restart dnsmasq`。这不是「自动」发生的 —— 是 stop 路径没清理干净。

**本版落地的改动**

1. **`files/etc/config/dnsproxy`：移除「24 个国外域名 → 127.0.0.1:5335」例外清单。**
   这 24 个域名在 `gfw_list.conf` 里 **24/24 全部命中**，属重复声明；
   而 SSR **禁用**时它是纯故障源 —— `:5335` 无监听 → dnsproxy 打
   `connection refused` → 回落 `https://1.12.12.12/dns-query` → 拿到污染答案。
   实测（移除前）：`youtube.com → 31.13.92.37`、`wikipedia.org → 31.13.94.36`
   （均为 Facebook 的 IP）；同时刻不在清单里的域名全部正常
   （`blogspot.com → 65.49.68.152`、`wordpress.com → 192.0.78.9`）。
   移除后 dnsproxy 只依赖国内 DoH 主链，不再隐式耦合 SSR-Plus 运行状态。

2. **`files/etc/uci-defaults/99-gaming-optimize`：`dhcp.@dnsmasq[0].dnsforwardmax='1024'`。**
   dnsmasq 并发转发槽默认仅 150。**防御性配置，非本次已证根因** ——
   故障窗口内 `logread | grep -c 'Maximum number of concurrent'` = 0。

3. **`files/etc/uci-defaults/99-gaming-optimize`：修复 ICMPv6 规则的非幂等。**
   原写法裸调 `uci add firewall rule`，每执行一次多一条 `ICMPv6-Input`/
   `ICMPv6-Forward`（实测连跑三次 → 各 3 条）。改为先按 name 查已有索引、
   存在则就地改写。连跑 3 次验证规则总数稳定在 14，每样恰好一条。
   **踩到的坑**：`uci set "$R.name='值'"` 会把单引号存进值里，
   导致按 name 精确匹配永远失败 —— 必须写 `uci set "$R.name=值"`。

**已验证**（路由器实测）

- `dnsproxy` 命令行不再含 `5335`：`--upstream` 只剩 alidns / 1.12.12.12 / doh.360.cn
- `dnsmasq` 生成配置含 `dns-forward-max=1024`（`/var/etc/dnsmasq.conf.cfg01411c` 第 13 行）
- 国内域名双栈保留，国外域名 A 正常、AAAA 1ms 空答复
- 彻底清理后客户机与路由器均恢复正常

**⚠️ 误判修正（本轮排查的教训，务必记住）**

排查过程中有三次判断被自己的测试方法误导：

1. **内联 Node 脚本的 DNS 报文匹配有 bug**，把无效响应当超时，导致
   误判成「国内域名也全挂」。改用 `Check-DnsName.js`（校验事务 ID +
   问题段回显 + 区分 EMPTY/NX/TIMEOUT）后结论反转：**国内一直正常**。
2. **`pgrep -x xray` / `pgrep -x mosdns` 匹配不到**实际进程 —— 它们以
   `/var/etc/ssrplus/bin/v2ray`、`/var/etc/ssrplus/bin/mosdns` 的完整路径运行。
   必须按 cmdline 匹配，不能按 exec 名。
3. **`luci-app-ssr-plus` 的「连通性检查」不能用于诊断 DNS。**
   其实现是 `/usr/lib/lua/luci/controller/shadowsocksr.lua` 第 1616 行：
   ```lua
   e.ret = luci.sys.call("curl -m 3 -sS -o /dev/null http://www." .. target .. ".com")
   ```
   它①走 `/etc/resolv.conf` 的运营商 DNS，**完全绕过 dnsmasq**；
   ②只测 `www.baidu.com`/`www.google.com` 的 HTTP 可达性，不看解析结果。
   因此无论 SSR 是否故障，它都会显示「连接正常」。

**未在本版修复（需改 `luci-app-ssr-plus` 上游脚本，另开 patch 承接）**

| 项 | 内容 |
|---|---|
| P1 | `global_server=nil` 时显式报错退出，而非静默空转 |
| P2 | 规则重建应「后端先起、断言 `:5335`/`:1234` 在监听、再装规则」 |
| P3 | `ln_start_bin` 的 `>/dev/null 2>&1 &` 应把 stderr 落到 `/var/log/ssrplus.log` |
| P5 | `stop()` 应先杀 `ssr-switch` 再停后端，并清理 `dnsmasq-ssrplus.d/` |

已核实：路由器装的是 helloworld `luci-app-ssr-plus 196-r19`（init 脚本
102,793 字节，md5 `9537dab2…`），上游 master 同一脚本只有 65,763 字节
（md5 `6db4ab8f…`），两者 `start()` 结构差异显著 —— 基于路由器副本做的
patch 无法 apply 到 CI 拉取的 master。故本版只落地不依赖上游的改动。

**已知遗留**：国内 DoH 上游对部分被墙域名本身就返回污染答案
（实测 `1.12.12.12` 的 DoH：`youtube.com → 174.132.167.252`、
`wikipedia.org → 31.13.88.169`）。SSR 禁用期间这些域名只能得到上游给的
答案，这是「禁用代理」的固有代价。

### 当前完整解析链路（v0.8.0 实测）

```
客户机 (192.168.3.x)
  │  DNS 查询 UDP/TCP 53
  ▼
┌─────────────────────────────────────────────────────────────┐
│ fw4  chain dns_intercept_lan                                │
│   type nat hook prerouting priority dstnat+1 (-99)          │
│   iifname br-lan udp/tcp dport 53 → redirect to :53          │
│   （把客户机发往任意 DNS 的查询都劫持到本机 dnsmasq）          │
└─────────────────────────────────────────────────────────────┘
  ▼
dnsmasq :53   (noresolv=1, dns-forward-max=1024, cache 8192)
  │
  │  ① 先查本地缓存 / DHCP 租约 / /etc/hosts
  │  ② 按 server=/域名/ 精确前缀匹配选择上游：
  │
  ├─【国内域名 + 所有未被清单命中的域名】──────────────────────┐
  │   默认 server=127.0.0.1#5353                              │
  │   ▼                                                        │
  │ dnsproxy :5353  (ALL_DOH, upstream_mode=fastest_addr)      │
  │   ├─ https://dns.alidns.com/dns-query   → 223.5.5.5        │
  │   ├─ https://1.12.12.12/dns-query       → 1.12.12.12       │
  │   └─ https://doh.360.cn/dns-query       → 36.99.170.86     │
  │   （三者均落在 nft @china 内，SSR 不代理，直连）             │
  │   fallback: https://1.12.12.12/dns-query                   │
  │   bootstrap: 223.5.5.5 / 223.6.6.6（仅解析上游主机名）      │
  │   ▼                                                        │
  │ 返回【真实 A + 真实 AAAA】→ 国内双栈直连                     │
  │                                                            │
  ├─【国外域名：gfw_list.conf 23701 条 + gfw_base 55 条】───────┤
  │   server=/<域名>/127.0.0.1#5335                            │
  │   ▼                                                        │
  │ MosDNS :5335  (SSR-Plus 管理, pdnsd_enable=4)              │
  │   启用 sequence: main_sequence_disable_IPv6                │
  │   ├─ qtype 28(AAAA) / 65(HTTPS) → reject 0  ← 去 AAAA      │
  │   ├─ prefer_ipv4                                           │
  │   └─ forward → https://dns.google/dns-query                │
  │                 https://cloudflare-dns.com/dns-query       │
  │                 （经 Xray/v2ray 代理出站，防污染）           │
  │   ▼                                                        │
  │ 返回【真实 A】+【AAAA 空答复(1ms)】                          │
  │   └→ 客户端立即回落 IPv4 → 走 ss_spec redirect to :1234     │
  │                                                            │
  └─【applechina.conf 173 行】→ 明文 114.114.114.114（直连）    │
                                                               │
  【deny.list 13 行】→ address=/域名/ → 拦为 0.0.0.0           │
└──────────────────────────────────────────────────────────────┘

代理链路（只影响 TCP/部分 UDP，不影响 DNS 解析本身）
  客户机 TCP → fw4 ss_spec_prerouting (priority filter, 晚于 dstnat+1)
             → ip daddr @china return（国内直连）
             → 其余 → ss_spec_wan_fw → redirect to :1234
             → Xray/v2ray → 国外服务器

IPv6 策略（用户明确要求）
  国内域名：保留真实 AAAA → IPv6 直连（实测 moe/cac 通）
  国外域名：AAAA 被 MosDNS reject → 无 AAAA 可用 → 只能走 IPv4 代理
             （避免「拿到污染 AAAA → 直连被 RST」的老问题）
```

### 排查方法沉淀

- 「启用后全挂」这类问题，**必须先区分四种结果**：`OK` / `EMPTY`
  （rcode=0 且 an=0）/ `NX`（rcode=3）/ `TIMEOUT`（无任何响应）。
  `EMPTY` 是**合法答复**，客户端立刻回落；只有 `TIMEOUT` 才会卡住客户端。
  把 `EMPTY` 当失败会得出完全错误的结论。
- 判定进程是否在跑，**按 `/proc/*/cmdline` 匹配完整路径**，
  不要用 `pgrep -x <名字>`（SSR-Plus 的二进制以完整路径运行）。
- 判定 UCI 改动是否真的落到进程，**看 `/proc/<pid>/cmdline` 与生成的配置文件**，
  不要只看 `uci show`。
- **不要用 SSR-Plus 的「连通性检查」诊断 DNS** —— 它走运营商 DNS，
  与 dnsmasq 链路无关。
- 在路由器上做并发实验时，`( cmd ) &` 会随 plink 会话结束被杀，
  **压不出真实并发**；两次「离线复现失败」都源于此。

## [v0.7.0] - 2026-10-13

### 变更 — 全链路移除 Telegram 机器人（含其 tab 与控制项）

按用户要求**完整下线** Telegram：不只是隐藏界面，而是把实现、接口与配置
一并从固件里拿掉。判为 MINOR（改动的是「组件」集合；本项目尚未到 1.0，
不适用 MAJOR 的对外接口破坏语义）。

**删除的文件（4 个）**

| 文件 | 原本作用 |
|---|---|
| `htdocs/.../view/trafficctl/telegram.js` | Telegram 配置页（页面级 tab） |
| `root/etc/init.d/trafficctl-telegram` | procd 服务脚本（`respawn` 型长轮询） |
| `root/usr/local/bin/trafficctl-telegram.sh` | Bot 守护进程本体（27 KB） |
| `root/usr/local/bin/trafficctl-telegram-test.sh` | 「发送测试消息」按钮的后端 |

**清理的引用点**

| 位置 | 处理 |
|---|---|
| `menu.d` | 删掉 Telegram tab 登记；`portfw`/`host` 的 order 3/4/5 → 3/4 |
| `acl.d` | 删掉 `telegram_config_get` / `telegram_config_set` / `telegram_test` 三项授权 |
| `rpcd/luci.trafficctl` | 删掉上述三个方法的签名与实现、`log_telegram` 读写 |
| `etc/config/trafficctl` | 删掉整个 `config telegram` 段与 `option log_telegram` |
| hotplug 新设备脚本 | 删掉「写 Telegram 通知标记」整段 |
| `trafficctl-fw.sh` | 删掉 `telegram*` 日志分类映射 |
| `Makefile` | postinst 不再启动该服务；**prerm 停用它**（见下） |
| `common.js` | `loggingSet` 去掉 `log_telegram` 参数位 |
| `status.css` | 删掉 Telegram 专用样式；`--tg-primary` 变量一并移除 |
| `README.md` | 删掉功能表、截图、依赖、快速上手、架构图与文件清单里的 Telegram |
| `po/` + `pot` | 删掉 3 条已无来源的 Telegram 译文（po 505 → 502 条） |
| i18n 工具 / patch 生成器 | 从文件清单移除，并给生成器加「删除文件」支持 |

### 变更 — 活动日志的「Telegram」分类开关一并移除

该分类只标记**由 Telegram 触发**的操作。来源消失后它永远不会再产生日志，
留着就是一个拨了没反应的死开关。日志分类现为 **阻断 / 速率限制 / 整形 / 配置**。

### 变更 — `tg-*` 类名改为 `tc-*`

`.tg-save-status` / `.tg-input` / `.tg-btn` 三个类**从来不是 Telegram 专属**：
设备页「保存为路由器默认值」的按钮与保存状态、设置页「新设备默认限速」的
数字输入都在用它们。Telegram 移除后继续用 `tg-` 前缀，等于用类名指向一个
已不存在的功能，故改名为 `.tc-save-status` / `.tc-input` / `.tc-btn`。
其余 `.tg-*`（消息气泡、内联键盘预览、分段控件、状态点等）确为 Telegram
专用，随视图一并删除。

### 修复 — 顺带修掉一个静默的进程缺陷

`trafficctl-telegram` 是 **`respawn` 型** procd 服务。opkg 升级顺序为
**prerm → 按旧文件清单删除 → postinst**：若把停机写在 postinst（我最初如此），
那时 init.d 脚本已被删除，procd 服务无从 `stop`，而被删掉的二进制仍可能被
反复重启。故停机移到 **prerm**（文件还在这刻停），并保留 `disable`。

### 升级路径（旧路由器）

`postinst` 幂等地清理三样**不归包文件清单管**的残留：

1. `/etc/config/trafficctl` 的 `config telegram` 段（conffile 整份保留）
2. `/etc/rc.d/*trafficctl-telegram` 开机软链
3. `/etc/trafficctl/telegram_known.json`（在 keep.d 中，跨 sysupgrade 保留）

留着它们等于把一个「界面上已无处可填、也永不生效」的 bot token 继续留在盘上。
全新安装时这些都不存在，是空操作。

### 验证

- **不变量**：新增 17 条断言（4 个文件缺席、menu.d/acl.d/rpcd/UCI/hotplug/
  fw.sh/common.js 逐层无残留、postinst 不启动 + prerm 停用、po 无孤儿条目）。
  `100755` 索引计数 29 → **26**（随 3 个可执行文件删除同步更新）。
  全绿，无 FAIL。
- **patch 链**：`0006-remove-telegram.patch`（含 3 处文件删除）在干净上游基线上
  重放成功，与 vendored 包**逐字节一致**。
  patch 生成器新增「删除文件」能力（此前只能改/加），并区分两种删除：
  上游存在的文件才能写进删除清单 —— `telegram.js` 是本仓库新增的，对它
  做「删除上游不存在的文件」会直接套用失败。
- **i18n**：po 505 → 502 条，pot 重生成 376 条，Telegram `msgid` 归零，覆盖率完整。
- **路由器实测**（192.168.3.254，先备份 `/root/trafficctl.v0.6.10.bak`）：
  - 顶部 tab 行 `设备 / 设置 / 端口转发` —— Telegram 已消失
  - 设置页日志分类 `阻断 / 速率限制 / 整形 / 配置`；`#tm-log-telegram` 不存在
  - 页面正文不再出现字符串 "Telegram"；控制台 0 错误
  - `ubus -v list luci.trafficctl` 里 Telegram 计数 0；
    `ubus call … telegram_config_get` → `Method not found`
  - 4 个文件已消失、rc.d 软链已清、`uci show trafficctl.telegram` 无输出、
    `log_telegram` 不存在、相关进程数 0
  - **回归**：设备页 21 行、20 个「限制」链接、限速弹层正常打开；
    设置页三张卡片、保存状态与数字输入的新类名均生效
- 类名改名后旧 `tg-*` 计数 0，新 `.tc-save-status` 3 处、输入框为
  `tc-input tc-input--num`。

## [v0.6.9] - 2026-10-13

### 变更 — 三个视图开关移除，三者恒开

「统计 / 连接 / 活动日志」三个滑动开关已移除，对应区块**恒开**。它们都是
「关掉就少看一块信息」，留着只是让人每次先确认一遍状态。视图开关行现在
只剩「扩展统计」与「反向DNS」两项。

随之作废 `showStats` / `showConns` / `showActivity` 三个选项。
**活动日志的内容必须在首屏主动加载** —— 原先那一步挂在开关的勾选回调里，
开关一移除就没人触发，这一段会永远空白（已加断言守住）。

### 变更 —「所有设备」移到搜索框左侧，移除最近设备

设备选择行原为「搜索框 + 最近设备 chip + 所有设备」，现只剩两个，
顺序为 **所有设备 | 搜索框**（用户指定）。最近设备 chip 行已移除；
`addRecentDevice` 仍在记录访问历史，只是不再有地方展示（将来若要恢复，
函数与存储都还在）。

### 变更 — 移除目标/共享/网段与速率档位行

用户框选的两块已删除：

| 删除内容 | 原先作用 |
|---|---|
| 最近设备 chip | 快速跳到最近看过的设备 |
| 目标输入框 + 共享（每台设备/共享） | 指定限速作用的网段与分配方式 |
| 整个网络/网段 chip | 同上，常用的网段一键填入 |
| 速率档位行（关/1Mbit…/自定义/上下行分别设置） | 选速率 |
| Shaper-Limiter 切换（原在卡片标题栏） | 选限速方式 |

「速率限制」卡片因此只剩：**标题 → 所有设备+搜索框 → 已有的网段限制 →
切断全网访问 → 视图开关**。实测卡片高度 **271px → 195px**。

**保留**「已有的网段限制」列表：它不在被删范围内，而且是既有全局限速
**唯一**可见、可删的地方 —— 删掉会让此前设过全网/网段限速的人再也去不掉
那条规则。

### 变更 — 限速入口移进设备表的「限制」

删掉卡片里的速率选择后，限速改从**设备表每行的「限制」**设置（用户选定）。
点它在该行旁边弹出限速设置：速率档位 + Shaper-Limiter + 上下行分别设置。

原先那个「限制」链接只是把目标设为该设备、再让你滚回卡片去点速率 ——
两步且要来回找。现在点哪台就设哪台，弹层标题写明设备名。

同一套部件实例与同一套切换逻辑被复用，只是换了挂载点。弹层挂在
`document.body` 上（脱离表格的 overflow 裁剪），点外部 / Esc / 再点关闭，
两个 `document` 监听器与 DOM 都随 `handleTeardown` 摘除。

### 修复 — 顺带修掉两个既有缺陷

1. **「上下行分别设置」从来没显示过**：`upRow`（上行速率输入行）构造后
   从未被挂进 DOM —— 那个按钮切换的是一个游离节点，点了永远看不到输入框。
   现已挂进弹层，功能恢复。
2. **弹层定位会落到屏幕外**：起初只按 `min(行底+4, 视口高-40)` 夹住，
   而弹层实测 **192px** 高、当时只剩 40px → 大半在屏幕外（截图为证）。
   改为**先显示再量真实高度**，下方放不下且上方更宽裕时翻到该行上方。
   实测翻转生效（下方不足时 `top=10`，完整落在视口内）。

### 验证

- 三个开关：开关行只剩「扩展、反向DNS」；统计/连接表/活动日志三块均可见。
- picker 行：子元素实测为 `[📊 所有设备, 搜索框]`，按钮左边界 < 输入框左边界。
- 删除项：`hasRateChips: false`、`hasScopeRow: false`、`recentChips: 0`；
  卡片子元素仅 `[header, picker-row, subnet-limits, cut, tail]`。
- 弹层：点「限制」打开，标题正确（命名设备显示「ALN-AL80 — 192.168.3.201」、
  无名设备只显示 IP）；档位 chip 10 个；Esc 关闭；点外部关闭；点档位不关闭。
- 定位：小视口（900px）滚到表中部后弹层翻到上方、`fullyInViewport: true`。
- 单设备模式：所有设备仍在搜索框左侧、所选设备保留在输入框、连接表可见。
- 控制台 0 错误；不变量校验全绿（新增 16 条断言）；i18n 完整。

### 说明 — 测试限速已撤销

验证弹层交互时点了一次「5 Mbit/s」，即真的给 192.168.3.203 设了限速。
随即点「关」撤销，并在路由器上确认：`nft list tables` 只有
`trafficctl_mon` / `fw4` / `ss_spec`，**无任何限速表**，`tc class` 在 br-lan 上
为 0 条 —— 规则已清干净。

## [v0.6.8] - 2026-10-13

### 变更 — 可见列改为复选框，且只列未显示的列

「可见列」弹层里原先是**圆形 chip**（最多 20 个，铺成五行、每行长短不一），
要在一堆同色小圆里找某一列。现改为**一行一个复选框**：命中区域大、左边缘对齐、
勾选状态一眼可读。

同时把**默认就显示的列**从清单里移除。它们本来就看得见，再给一个开关只会让人
以为「没勾上就是没有」。清单从 20 项减到 **7 项**（恰为默认隐藏的那一批）：
MAC、图表、字节、链路、应用、丢弃、队列。

### 变更 — 新增四个默认显示列：TCP | UDP | 互联网 | 限制

这四列原先默认隐藏、要在「可见列」里逐个打开。它们回答的是「这台设备在用什么、
有没有被限住」，属于日常判断的一部分，藏起来等于每次都要先开一遍。

默认列数 **9 → 13**，按用户指定顺序排在「操作」之后。实测四列都有真实数据
（首行 TCP 231.28 MB / UDP 2.01 MB），13 列在 1600px 下 `min-width` 1224px、
**无横向滚动**。

### 变更 — 概览常显并移到速率限制之上

- **移除「概览」开关**。它此前默认关闭，理由是「每拍多一次 rpcd 调用，
  不看的人不必付这个成本」；但实测这块信息（下载/上传/活跃设备/上联图/接口/排行）
  正是打开这一页最想先看到的东西，默认关着等于每次都要先点一下。它自己的开销
  （一次 `ifaces` 读取）已被防重入闸约束在同一拍内。
  随之作废 `showOverview` 选项，`pollIfaces` / `renderOverview` / `resize`
  三处判据统一只看 `isAllMode()`。
- **卡片移到速率限制之上**。概览回答「此刻网络怎么样」，是**读数**；速率限制是
  **操作**。读数放在操作上方才符合「先看后改」—— 此前顺序是 速率限制 → 概览 → 表格，
  等于每次都要先滚过一整张操作卡片才看得到读数。

视图开关行现为：统计 / 连接 / 扩展 / 反向DNS / 活动日志（少了「概览」）。

### 验证

- 结构：13 列且含 `tcp`、`udp`、`blocked`、`_throttle_kbit`；渲染顺序
  `overviewCard`(4589) → `rateLimitRow`(4590)；开关行不含「概览」。
- 复选框：7 项、`type=checkbox`、`allSameLeft: true`、行间距 25px、**零重叠**。
- 交互：勾选 MAC → 表格 13→14 列；取消 → 14→13 列；面板保持打开。
- 概览：默认 `overviewBodyVisible: true`；单设备模式下正确隐藏（只剩统计条）。
- 无横向滚动：13 列 `min-width` 1224px、容器 1285px。
- 控制台 0 错误；不变量校验全绿（新增 13 条断言）；i18n 完整。

### 修正 — 两处断言本身写得不对

- 「列开关写显式 false」断言在查 `= false`，而复选框改成了
  `= !cb.checked`。**改名后旧断言会永远失败**（这类不同步就会变成噪声，
  进而被忽略），已同步为新写法。
- 「概览卡片前置」断言里 `grep '^\t\t\t\t…'` 用了单引号 —— 其中的 `\t` 只是
  **字面反斜杠 t**，不是制表符，故永远匹配不到（报出「概览= 速率限制=」）。
  改用 awk 的 `[ \t]` 字符类。这是本仓库验证纪律记过的同一类坑。

## [v0.6.7] - 2026-10-13

### 变更 — 统计条并入上联概览卡片

「活跃 / 已阻断 / WiFi」原本是概览卡片**下方另起一行的窄条**，两者底部与表格
之间又各占一段间距 —— 视觉上是三块互不相干的东西，而它们说的其实是同一件事
（此刻网络的整体状况）。现合为一张卡片：统计条是卡片抬头，下面接上联概览。

两个开关是**独立**的（统计 / 概览），故卡片只是外壳，两个子块各自显隐；
卡片的可见性由「至少一个子块**有内容**且未关掉」决定：

| 统计 | 概览 | 卡片 |
|---|---|---|
| 开 | 开 | 显示（抬头 + 概览） |
| 关 | 开 | 显示（只有概览） |
| 开 | 关 | 显示（只有抬头） |
| 关 | 关 | **隐藏** |

判据必须带 `firstChild` 而不只是 `tc-hidden` —— 子块在首帧都是空的（统计条要等
第一次 `renderSummary` 才填），只看类名会让卡片画出一个**空边框**。

### 变更 — 上联图全宽

图表原先按**写死的 560px** 绘制，而容器实测 **1259px** —— 图只占左半，右侧一大片空。

不能用 CSS `width:100%` 拉伸：SVG 带 `viewBox`，等比放大 2.25 倍会把坐标轴与
刻度文字一起放大，字号失控。改为**按容器实测宽度重绘**（`graphWidth`），并：
- 扣除卡片自身的内边距与边框（`getComputedStyle` 读，不写死像素，改 CSS 不会悄悄失配）；
- 监听 `resize` 按新宽度重绘，只在宽度**真的变了**（≥2px）时才重画 —— 拖动窗口时
  `resize` 每帧触发，无条件重绘会连带重建表格行；
- 监听器具名挂到实例并在 `handleTeardown` 摘除。

实测：1600px 视口下 `svgW = 1259 = 容器宽`、溢出 **0**；缩到 1100px 后自动重绘为 759px。

### 变更 — 例行轮询不再闪状态行

例行轮询（`runAll` / `runSingle`）此前每秒往状态行写「扫描所有设备中…」→「✓ 完成」，
1 秒档位下这一行不停地闪。它是噪声而非信息 —— 轮询本来就该是看不见的。

现例行轮询**只在失败时**写状态；成功时只清掉**它自己**上次留下的错误，不碰动作消息。
**动作类反馈（限速 / 切断 / WiFi 黑名单）仍逐字保留** —— 那些是用户主动触发、
必须看到结果的操作。为此新增 `setRoutineStatus()`，与 `setStatus()` 分工明确。

实测：连续 7 秒采样，状态行始终保持隐藏、无文字。

### 修复 — 按钮组与表格之间没有行距

`.tc-menu-group` 只有上边距，按钮组下边缘与表格上边缘实测相距 **0px** —— 按钮看起来
贴在表头上，像表的一部分而不像「控制这张表的按钮」。表格自身没有上边距，故只能在这里
给：改为 `margin: 8px 0 12px`。实测行距 12px。

### 修复 — 关掉「统计」后统计条照样显示

`renderSummary` 与单设备分支都是**整体赋** `statsDiv.className`，把 `tc-hidden`
一起丢掉 → 下一次轮询把它写回来。改为先记下隐藏态、赋完类名再还原。

### 验证

- 卡片合并：`statsInsideCard: true`、抬头是卡片首个子元素、卡片高 403px。
- 开关独立性：四种组合逐一实测，结果与上表一致（含「都关 → 卡片隐藏」）。
- 单设备模式：卡片只剩统计条（连接/TCP/UDP），概览按设计隐藏。
- 全宽图表：1600px → 1259px（零溢出）；1100px → 759px（resize 自动重绘）。
- 例行轮询：7 秒 × 6 次采样，状态行始终隐藏；「扫描所有设备中」已从页面消失。
- 按钮行距：12px。
- 控制台 0 错误；不变量校验全绿（新增 13 条断言）；i18n 完整。

## [v0.6.6] - 2026-10-13

### 变更 — 视图开关直接展示，「可见列」并入按钮组

「视图与表格」那张可折叠卡片拆开，按用途分到两处：

- **开关直接展示**（统计 / 连接 / 概览 / 扩展 / rDNS / 活动日志）：一行常驻在
  速率限制卡片尾部。原先是可折叠卡片 —— 开关藏在折叠区里，表现为
  「内容不见了却不知道开关在哪」。
- **「可见列」收进按钮**：设备列 chip、连接表列 chip、连接表筛选全部移入
  一个「可见列」浮层。这些是「调表的显示」，平时不动却数量最多（设备列 20 个
  chip + 连接表列 8 个 + 筛选行），平铺出来最占横向空间。

按钮组排列为 **可见列 | ☰**（用户指定顺序）。

### 变更 — 两个菜单共用一个弹出面板工厂

☰（档位）与「可见列」的交互完全一致：点开、点别处关、Esc 关、面板内点击不关。
原先只有 ☰ 一套实现；再加一个必然会漂移（例如只有一边摘除监听器）。
抽出 `mkPopupMenu()` 供两者复用，并补一条新行为：**同一时刻只允许一个面板展开**
—— 两个浮层贴着同一个按钮组，同时展开会互相盖住。

### 修复 — 多列全开时列被压到 11px、MAC 折成三行

「可见列」让开列变容易后这个问题更容易遇到，实测暴露：

| 列数 | 修复前 | 修复后 |
|---|---|---|
| 默认 9 列 | 正常 | 正常（无横向滚动） |
| 20 列全开 | 图表/限制/丢弃/队列 = **11px**，MAC 折成 **3 行** | 各列拿到预算（最低 58px），MAC 单行，横向滚动 |

根因：列宽写在 CSS 的**百分比**里，而百分比是「占表宽的比例」—— 列一多，
各列比例被摊薄。改为**在 JS 里按每列的最小可用宽度（`COL_MIN_PX`）算**：
给每列一个像素预算，总和作为表的 `min-width`，各列百分比按「预算 / 总和」得出，
以**内联样式**写到表头上。于是：

- 容器窄于总和 → 表取 `min-width`，每列恰好拿到预算，外层横向滚动；
- 容器宽于总和 → 表铺满容器，各列按同一比例变大。

CSS 里原先那批百分比列宽随即全部失效（内联优先），**已删除** —— 两处共存必然
矛盾，留着就是无人察觉的死规则。新增断言禁止它再出现。

### 验证

- 结构：按钮组 `可见列 | ☰` 同在 `top=1011`、两个面板均默认收起。
- 开关行：六个开关在速率限制卡片内直接可见；「View & Table」文案已从页面消失。
- 面板内容：设备列 20 个 chip；单设备模式下自动换成连接表列 8 个 chip + 筛选行。
- 交互：两点菜单**互斥**（开一个另一个自动关）；Esc 关闭；面板内点 chip
  **不**关闭面板（实测切换后仍开着，且列数 7→6 真变了）。
- 列宽：20 列时 `min-width=1800px`、每列各自拿到预算、MAC 单行、横向滚动；
  默认 9 列 `min-width=920px`、无横向滚动。
- 控制台 0 错误；`verify-trafficctl-invariants.sh` 全绿（新增 15 条断言，
  并更新了 4 条查旧类名的断言 —— 类名从 `tc-speed-menu*` 改为通用
  `tc-menu*` 后，旧断言会永远失败）；i18n 447/447 完整。

## [v0.6.5] - 2026-10-13

### 变更 — 表头与单元格全部居中对齐

原先一行里混着**三种对齐**：表头左对齐、数字列右对齐、文字列左对齐。
设备多时列与列之间看起来是错位的 —— 读一列要在三种基准之间来回找。
现统一居中，每列的标题与内容落在同一条中轴上（实测九列的中轴偏差全为 **0**）。

作用域**只限真正的表格**（新增 `.tc-table--center` 修饰类）：

| 表格 | 是否居中 |
|---|---|
| 设备表（`buildSummaryTable`） | ✅ |
| 连接表（`buildTable`，单设备模式） | ✅ |
| 分组表（`buildGroupedTable`） | ✅ |
| 扩展统计面板（`buildExtendedStatsPanel`） | ❌ **保持左对齐** |

扩展统计面板也用 `.tc-table`，但它是「标签 — 数值」两栏行；居中后标签与数值
会各自居中，读起来不成列表。故它**不加**该类，并有断言守住这一点。

### 说明 — 两处容易漏掉的对齐

- **两行式单元格的子项**：IP/MAC、类型/厂商两列是 `.tc-cell-stack`（flex 列容器），
  其子项对齐由容器自己的 `align-items` 决定，**光给 `.td` 设 `text-align` 管不到** ——
  默认 `stretch` 会让上下两行左贴、与已居中的其他列不齐。故另给
  `.tc-table--center .td.tc-cell-stack { align-items: center }`。
- **未动全局工具类**：`.tc-right` / `.tc-center` 是全局类（表格之外也在用），
  统一改它们会波及别处。居中规则一律限定在 `.tc-table--center` 作用域内。

### 验证

- 逐列实测：九列表头 `text-align` 与单元格 `text-align` 均为 `center`；
  **表头中轴与首行内容中轴偏差全为 0**；`.tc-cell-stack` 的 `align-items` 为 `center`。
- 连接表（单设备模式）实测同样居中。
- 扩展统计面板实测**未**被居中（断言同时守住「不误加」）。
- 新增断言经**模拟误改验证有效**：把扩展面板也加上 `--center` 时断言会失败。
- 控制台 0 错误；`verify-trafficctl-invariants.sh` 全绿（新增 4 条断言）；
  i18n 448/448 完整；patch 重放逐字节一致。

### 修正 — 一处断言在数注释

新增的「三处表格居中」断言起初写 `grep -c 'tc-table--center'`，把**解释该类的
注释行**也算进去，报出 4 处（实际 3 处）。这正是 AGENTS.md 验证纪律第 6 条记过的
坑（断言要先剥掉注释行）。改为只匹配 `class':` 开头的真实代码行，并要求恰好 3 处。

## [v0.6.4] - 2026-10-13

### 变更 — 四组档位收进 ☰ 菜单，冷启动轮询改为 1 秒

「轮询 / 窗口 / 方法 / 刷新」原先平铺成一条常驻横向条贴在设备表上方。
它们**设好一次就不再动**，却每一屏都在：窄屏上四组各带标签会折成两三行，
长期占据设备表上方的位置。现收进一个 **☰** 图标按钮，默认收起，
表上方只剩一个 30×26 的图标（原条高 46px）。

交互：
- 点 ☰ 展开浮层（**绝对定位**，展开时设备表不跳动）；
- 点页面别处、按 **Esc**、再点 ☰ 都可以收起；
- 面板内部的点击不关闭（否则点档位就会立刻收起来）；
- 「保存为路由器默认值」移到面板底部 —— 它作用的正是这四个值。

**冷启动默认轮询 2s → 1s**。三处必须一致，否则会出现「界面显示 1s、
路由器实际下发 2s」的漂移：
| 位置 | 改动 |
|---|---|
| 前端 `common.js` `siteDefaults.pollInterval` | `2` → `1` |
| UCI `root/etc/config/trafficctl` `option poll_interval` | `'2'` → `'1'` |
| rpcd `luci.trafficctl` 兜底 `${poll:-N}` | `2` → `1`（config 缺失时用它） |

### 修复 — 三类字节轮询在 1 秒档位下会叠加请求

改默认 1s 前先实测了代价：单次 RPC **P50≈290ms、最坏 1877ms**，
而 `setInterval` **没有防重入**。实测 30 秒窗口内出现 **3 次重叠、最多 2 并发** ——
这正是 AGENTS.md 红线 9 记录过的故障形态（请求层层堆积 → rpcd 不断 fork 子脚本
→ 路由器 load 飙升 → 页面最终 `XHR request timed out`）。

给 `pollBytes` / `pollDrops` / `pollShapeStats` 各加一个防重入闸
（与既有的 `queryInFlight` 同一手法）：上一拍未返回就跳过这一拍。
**`.catch` 也必须解锁** —— 否则一次请求失败会让轮询永久停摆。

加固后实测：30 秒内 **0 重叠**、起跳间隔精确 1000ms
（此前为 3 次重叠）。仅首屏那一次 2165ms 的长调用属正常并发（加载期本就并发）。

### 修复 — `document` 上的菜单监听器未摘除

「点别处 / Esc 收起」需要挂在 `document` 上。若不具名保存并在离开页面时摘除，
切走 tab 后它们仍会收到点击、闭包里抓着已移除的 DOM（内存泄漏 + 每次进页
多积一层监听）。改为具名挂到实例（`_speedMenuDocClick` / `_speedMenuDocKey`），
在 `handleTeardown` 里 `removeEventListener`。

### 验证

- 结构实测：☰ 按钮 30×26px、默认收起；展开后面板 408×213px、
  4 行分别为 轮询(6 档) / 窗口(6 档) / 方法(2 档) / 刷新(7 档)，含保存按钮。
- **冷启动实测**：清空 `localStorage` 全部选项后重载，菜单「轮询」停在 **1s**。
- 交互实测：按钮开 → Esc 关 → 面板内点击**不**关 → 点页面别处关。
- 切到设置页再切回，菜单仍正常（监听器摘除无副作用）。
- **防重入实测**：1s 档位跑 30 秒，重叠 0 次、间隔精确 1000ms。
- 控制台 0 错误；`verify-trafficctl-invariants.sh` 全绿（新增 14 条断言）；
  i18n 448/448 完整。

### 说明 — 路由器上档位标签仍为英文

与 v0.6.3 同一原因：新增中文串要等**固件构建**时由 `po2lmo` 生成 `.lmo`
才生效，路由器上无该工具。i18n 校验已确认翻译完整。

## [v0.6.3] - 2026-10-13

### 变更 — 设备表按「两行式」重排，16 列压到 9 列

参照爱快设备列表的形状重排表格，每行改为「信息成对、上下两行」：

| 列 | 内容 |
|---|---|
| **IP / MAC** | 上行 IP（详情页入口），下行为 MAC（链到 DHCP/DNS 绑定）。原先这是两列 |
| **终端类型 / 厂商** | 上行为识别到的类型（手机/电视/摄像头…，带图标），下行为 **MAC 前缀查得的厂商** |
| **操作** | 上行「详情」、下行「限制」（把该设备设为目标） |

其余列重排为：连接数 → 上行速率 → 下行速率 → **累计上行** → **累计下行** →
类型/厂商 → 名称 → 操作。三处合并省掉 3 个列宽，**16 列压到 9 列**，
整屏（1600px）内不再需要横向滚动。

新增两个数据列：
- **累计上行 / 累计下行** 分列显示。原先只有一个「字节」列（上下行相加），
  看不出某台设备是哪一侧在跑量。方向语义已核对 `trafficctl-totals.sh`：
  `bytes_in` = 下行（路由器→设备）、`bytes_out` = 上行（设备→路由器），
  两者复用既有的 `renderTotalCell`，故「不可测」（flow offload 下为 -1）
  仍显示 ⚠ 而不是假的 0。
- **设备厂商**：取自固件内 `luci-app-oui` 的 100 KB 厂商库。实测能查到
  Xiaomi / Midea / Huawei / TCL / TP-Link / MSI；随机化 MAC 显示「随机 MAC」
  并说明按 MAC 查不到厂商。`luciOUI` 只导出 `decorate`（没有公开的 `lookup`），
  故用一个游离节点让它写入 `title` 再读回；`oui.js` 未被任何视图加载过时按需
  载入一次，失败则保持占位「—」，不影响表格渲染。

### 新增 — 分页条

底部「共 N 条 当前显示 a-b」+「每页 20/50/100/全部」+ 页码，与参照图一致。
选中的页长存 localStorage。分页**切片前先按当前排序列排序**
（`sortSummaryRows`，与表内排序同一套规则），否则第一页不是真正的最快设备。
单设备模式不显示分页条（只有一行数据）。

### 修复 — 四个只有实测才会暴露的问题

1. **列宽被拉成空槽 + 无意义横向滚动（两种症状同一个根因）**。
   `table-layout:auto` 下 `width:Npx` 只是**建议**：浏览器按内容重新分配，
   于是「累计上行」一列被撑到几百像素的空槽，同时「操作」列被压到 56px
   而它需要 154px 才放得下两个链接 → 整表溢出 **153px**。
   改为 `table-layout:fixed` + 百分比列宽（默认 9 列合计恰为 100%），
   并加 `min-width:860px`：窄屏宁可横向滚动，也不要把 IP 挤到折行、
   把「Details」截成「Detai」。
   *（fixed 布局还有一条规范行为：列宽之和小于表宽时多余空间会按各列比例
   摊分 —— 实测每列被放大 1.9 倍。百分比凑满 100% 就没有余量可摊。）*

2. **操作列的「两行」并成了一行「Details限制」**。两个子元素都是 `<a>`（inline），
   而 IP/MAC、类型/厂商列的第二个子是 `<div>`（block）故天然换行。
   给 `.tc-actions a` 加 `display:block` 才真的成两行。

3. **默认隐藏的列永远打不开**。列开关原本用 `delete` 移除键，而隐藏状态是
   「键存在且为真」——`delete` 后回落到默认隐藏，于是点开芯片变绿、
   表格里却仍没有这一列。改为打开时**写显式 `false`**。

4. **`app` 列有列定义但没有列开关** —— 打开后无法关闭。新增断言比对
   `cols` 与 `colChipDefs` 的键集，这次就是被它抓出来的。

### 修复 — 默认隐藏列的声明曾有两份真相

列定义里的 `hide:true` 与开关判定的默认值各写一份，必然漂移
（症状就是第 3 条：芯片显示已打开而表格不渲染）。统一为模块级
`TC_COL_DEFAULT_HIDDEN` + `isColHidden()`，并加断言。

### 说明 — 参照图有三列本机没有数据源，未实现

参照图来自**爱快（iKuai）系统**（浏览器中另开着它的标签页，图中 IP 段
`192.168.9.x` 也与本机 `192.168.3.254` 不同）。逐列核对后确认三列无法落地：

- **在线时长** —— 后端无 `first_seen` 记录，从不产出。
- **连接AP / SSID** —— `iw dev` 返回 **0 个接口**、`/sys/class/ieee80211`
  不存在：本机是**无 WiFi 硬件的 x86_64**。

按用户选择「省略这三列，其余严格按图排布」处理。硬做就是三列永远空白。

### 验证

- 逐项实测（`getBoundingClientRect`）：9 列、三处两行式全部成立
  （`ip` / `_tydev` / `_actions` 各 2 行）、行高 48px、
  **1600px 无横向滚动**、1100px 按预期转为滚动（860px 下限）。
- 分页实测：首页 20 行 → 第 2 页 4 行（`showing 21-24`）→ 每页 50 → 24 行 1 页。
- 列开关实测双向生效：TCP 开→列出现、关→列消失；MAC 同理。
- 厂商实测：Xiaomi / Midea / Huawei / TCL / TP-Link / MSI 均正确，
  随机 MAC 显示「随机 MAC」。
- 单设备模式回归：无分页条、`tc-cut` 仍可见；「详情」链接仍能进主机详情页
  （`/host/192.168.3.141`，页面含 `.tc-host-table`）。
- 页面无字面 `undefined`；控制台 0 错误。
- `verify-trafficctl-invariants.sh` 全绿（新增 7 条断言）；
  i18n 447/447 完整（新增 27 条中文翻译）。

### 已知 — 路由器上表头仍显示英文

新增的中文串要等**固件构建**才会生效：`.lmo` 由构建时的 `po2lmo` 生成，
而路由器上既无该工具、现有 `.lmo` 也只含旧串。i18n 校验已确认翻译完整，
刷入下一个固件后即为中文。

## [v0.6.2] - 2026-10-13

### 变更 — 设备页进一步收拢为「一张操作卡片 + 数据区」

四项布局调整，把原先四块各自占行的控件收进同一张卡片：

- **设备选择并入速率限制卡片**：搜索框 + 「所有设备」+ 最近设备 chip 原先是
  卡片**之上**的独立两行，而卡片里又有自己的「目标」选择器 —— 两处选择器一上一下，
  用户要在它们之间来回看。现并进卡片，与「目标」同排一行：左边选设备、右边设限制。
- **「整个网络 / 网段」并入「共享」同行**：它原在「共享」的下一行，实为同一组
  「往哪施加限制」的选项。现排在「共享」chip 右侧。
- **「View & Table」并入速率限制卡片**：原为独立卡片（有自己的外框与底色），
  现嵌为卡片尾部（`.tc-rate-panel__tail`，用一条上分隔线区分），去掉重复外框。
- **「表格与速率」从设置页搬到设备页设备列表上方**：这组档位（轮询 / 窗口 / 方法 /
  刷新 + 路由端默认值）决定的就是**下面那张设备表**怎么刷新、速率按什么窗口算；
  放在设备表上方改完立刻见效，放在设置页则要来回切 tab 才知道有没有生效。

设备页高度 **1519 → 1476px**（前半段操作区由约 480px 压到 447px，且不再有
「搜索框 / 所有设备」独占的两行）；设置页 **484 → 375px**（少了一张卡片）。

### 修复 — 三处 `var` 提升导致的 `undefined`

把三块控件并进先在文件上方构造的卡片时，引用了在文件**下方**才赋值的变量。
`var` 提升使变量存在但值为 `undefined`：其中一次被当成文本节点渲染，
页面上出现一个字面的 **"undefined"**；另一次直接抛
`TypeError: Cannot read properties of undefined (reading 'appendChild')`，整页空白。

处置：给 `actionRow`、`scopeRow` 各留一个占位容器（`actionSlot` / `scopeSlot`），
等它们真正构造完再 `appendChild`。这类错误的特征是**报错位置与根因不在一处**，
故三处都写了注释说明为什么必须先占位。

### 修复 — 设备选择行的块内换行

`.tc-picker-row__device` 用了 `flex-wrap: wrap`，导致「所有设备」被拆到搜索框的
下一行（该行 71px ＝ 两行）。同时 `.tc-search-wrapper` 是 `display:inline-block`
（为下拉浮层定位而设），在 flex 行内被压到内容宽度。

改为：三个子块一律 `flex-wrap: nowrap`，整行放不下时由**外层** `.tc-picker-row`
统一换行；并给行内搜索框显式宽度 240px。该行 **71 → 32px（单行）**。

### 验证

- 逐项实测（`getBoundingClientRect`）：搜索框与「所有设备」top 差 < 6px（同行）；
  设备选择块与「目标」`top` 完全相等（同排）；`.tc-picker-row` 单行 32px；
  `.tc-rate-panel` 447px，其中 `tc-rate-panel__tail` 内含 View & Table 卡片；
  `.tc-rate-panel .tc-cut` 存在（切断仍在同一卡片内，未失效）。
- 页面上不再出现字面的 `undefined`（已断言 `document.body.textContent`）。
- **两种模式都核对**：单设备模式下 `scopeRow` 隐藏、「阻断互联网 / 阻断WiFi」
  按钮可见；所有设备模式下反之。
- 设置页只剩三张卡片（流量卸载 / 新设备默认值 / 日志与持久化），375px；
  「表格与速率」确认已不在其中。
- 控制台 0 错误；`verify-trafficctl-invariants.sh` 全绿；i18n 0 缺失。

### 说明 — 反转了一条旧断言

v0.6.0 加过「设备页不得定义配置档位」的断言（当时那些档位迁往设置页）。
本次方向相反，故判据反转：**这些档位必须存在于 status.js，且不得在 settings.js
留副本**。同时新增「速率条排在设备表之前」的断言 —— 注意它比较的是
**render 树里的顺序**而非变量定义行号：`connsDiv` 的 `var` 声明在文件上方，
真正决定渲染次序的是它被放进返回树的位置（我第一版写成了比定义行号，误报）。

## [v0.6.1] - 2026-10-13

### 修复 — 设置页所有样式失效

`settings.js` **没有注入 `status.css`**，页面上全部 `tc-*` / `tg-*` 类失效：
卡片无边框无内边距、chip 无底色（档位挤成一片）、折叠箭头错位。
实测该页 `<link>` 只剩 `/luci-static/shadcn/main.css`，`.tc-card` 的计算样式为
`border 0px / radius 0px / background transparent`。

根因：LuCI 只为**视图模块**自动加载与之同名的样式表 —— 本视图是
`trafficctl/settings.js`，对应的 `trafficctl/settings.css` 不存在，因此
`status.css` 不会被自动带上。`status.js` / `telegram.js` / `host.js` 都在文件顶部
手动注入，唯独新增的 `settings.js` 漏了。已补上同一段注入代码。

### 修复 — 各卡片的多余换行

- **根因是容器的多列布局**：`.tc-settings-body` 原用 `column-count: 2` 瀑布流，
  它会把**每张卡片压成半宽**，于是「表格与速率」里 4 组档位 + 保存按钮被迫折成
  两行（实测行高 67px）。改为 grid 两列，并新增 `.tc-card--wide` 让内容多的卡片
  独占整行（多列做不到「单个子项跨列」）。该行行高 **67 → 32px**（单行排完）。
- **「流量卸载」卡片**：开关与它的说明原先各占一行、共 5 行（173px）。说明是长句、
  开关是短控件，同行并排并不挤压，改为同行后 **5 行 → 3 行**（141px）。
- **「日志与持久化」卡片**：「日志分类」是一个分组标题，却独占一行（42px）。
  改为与那 5 个分类开关同行，**42 → 22px**。
- 设置页整页高度 **584 → 484px**，且不再有空格子（原「日志与持久化」在最后一格
  留下半行空白）。

### 变更 — 「切断全部互联网访问」并入速率限制卡片

它原是与速率限制并列的独立卡片，两者都是「对设备/全网施加限制」却分成两块、
各占一行高度。现嵌入速率限制卡片下方（`.tc-cut--embedded`：去掉自己的外框与
底色，改用一条上分隔线区分功能区）。设备页高度进一步 **1519 → 775px**。

**这一项有安全约束**：该控件是本应用唯一能把操作者自己关在门外的功能，其状态必须
在页面一渲染出来就可读，**不得**藏进任何折叠区。故：
- 它留在恒常可见的速率限制卡片内，而不是移入设置页；
- `rateLimitRow` 去掉了初始的 `tc-hidden`。它原先靠 `updateModeUI()` 里的
  `classList.remove('tc-hidden')` 才显示，即依赖 `runQuery()` 那条异步链 ——
  一旦该链未走到（异常、RPC 挂起），面板连同切断开关会一起消失。
  对这一个控件而言，那种失败模式不可接受，故改为首屏即显示。

### 验证

- 路由器实测：设置页 `status.css` 已加载，`.tc-card` 边框 1px、`.tc-chip` 圆角 14px；
  grid 两列各 1102px，两张宽卡片 2217px 独占整行。
- 逐行测量：`表格与速率` 32px（单行）、`流量卸载` 21+21px、`日志与持久化` 22+22px，
  设置页 484px。
- 设备页实测 `rate.parentElement.contains(cut) === true`、
  `.tc-cut` 不再是 `.cbi-section` 的顶层子节点、`tc-cut--embedded` 生效、
  首屏高度 65px 可见；设备页 775px。
- 两种模式（单设备 / 所有设备）下切断面板都可见。
- 控制台 0 错误；`verify-trafficctl-invariants.sh` 全绿；i18n 0 缺失。

## [v0.6.0] - 2026-10-13

### 变更 — trafficctl 拆出独立的「设置」页，设备页去重与重排

设备页此前把**配置项**与**监控数据**混在一页：轮询/窗口/平均算法、路由端默认值、
流量卸载、新设备默认值、日志与持久化全部内联在设备表上方，实测该区块高 580px，
把「看谁在占带宽」这个主任务压到折叠线以下。这些配置又是一次性设置，不需要和设备表
抢注意力。本次按职责拆开：

| tab | 内容 |
|---|---|
| 设备 | 设备选择、断网开关、速率限制、概览与统计、设备表、**视图与表格**（本页显示开关与列可见性） |
| **设置**（新增） | 表格与速率、流量卸载、新设备默认值、日志与持久化 |
| Telegram机器人 | 不变 |
| 端口转发 | 不变 |

设备页整页高度由 **2915px 降到 1541px**（实测），其中原设置面板由 580px 降到
185px 且只剩「视图与表格」，并移到页面最后 —— 配置项不再挡在数据前面。

### 新增 — 页面共用模块 `trafficctl/common.js`

设置页与设备页需要同一套 rpc 声明、同一份 localStorage 选项、同一组「开关 / chip /
折叠卡片」控件。此前这些定义写在 `status.js` 里、被 `telegram.js` 复制了一份；再新增
设置页就会出现第三份，三份各自漂移（表现为同一个开关在不同页面行为不一致）。
现集中到 `htdocs/luci-static/resources/trafficctl/common.js`，设备页与设置页各
`'require trafficctl/common as T'` 一次。

**关键约束（踩过）**：该模块必须 `return baseclass.extend({...})`。LuCI 前端 require 在
`luci.js` 里对工厂返回值做 `Class.isSubclass(_class)` 断言，返回普通对象会直接抛
`TypeError: "trafficctl/common" factory yields invalid constructor` 并令整页加载失败。
require 返回的是 `new _class()` 的实例，故 `T.fmtBytes(...)` 这种实例方法调用成立。

### 移除 — 软件流量卸载的橙黄色公告横幅

软件卸载**不损失任何功能**（速率由图上的 nftables 计数器提供，限速与阻断照常），
却每次打开页面都弹一条橙黄色公告。模式本身在设置页「流量卸载」卡片里有常驻的
`Current mode` 显示，不靠横幅告知。**硬件卸载的告警保留** —— 那说的是该模式下
conntrack 字节计数器确实不更新、速率会显示为 0，属真实故障提示，必须告知。

### 修复 — 三处本次重构引入或暴露的缺陷

- **`connFiltersRow is not defined` 令设备页整页空白**：配置区迁出时把「连接表筛选」
  （协议/分组）的定义一并删掉了，而 `viewSection` 与 `updateTableSectionMode` 仍在
  引用它，`render()` 直接抛错。已把定义移回引用之前。
- **`status.js` 被写成 CRLF**：用编辑器整文件重写时落成 CRLF，而 patch 回放校验
  要求与 vendored 包逐字节一致，报「不一致」。`.gitattributes` 已有 `*.js text eol=lf`，
  但那只管 `git add` 时的规范化，**不会**自动修正工作树里已被写坏的文件。已改回 LF。
- **`config_set` 的 ubus 签名漏声明 `refresh_interval`**：读写代码都在，签名里却没有。
  ubus 实测仍会放行（能写入），但该参数不受类型校验，且与 `config_get` 的输出字段
  不对称，属「不报错但不一致」的隐性缺陷。已补进签名。

### 验证

- **路由器实测四个 tab**（已登录 LuCI）：`设备 | 设置 | Telegram机器人 | 端口转发`，
  顺序与激活态正确，设置页在顶部行中可见。
- **设置页四张卡片全部正常渲染**（表格与速率 / 流量卸载 / 新设备默认值 / 日志与持久化），
  中文全部生效，控制台 0 错误。
- **跨页生效实测**：在设置页把「刷新」档位点到 `2s` → `localStorage` 写入
  `{"refresh":2}` → 回到设备页后按 ubus 请求时间点聚类，实测轮询间隔为 **2 秒**
  （默认 5 秒时实测 5.0 秒）。`refresh_interval` 经 `ubus call luci.trafficctl config_set`
  单独写入 42 并读回确认，随后恢复为 5。
- **橙黄横幅确已消失**：设备页 `#tc-offload-banner` 容器存在但为空且为 `tc-hidden`，
  渲染高度 0。
- **设备页功能回归**：设备表 20 行、速率/累计有值、IP 链接仍在，控制台 0 错误。
- `tools/verify-trafficctl-invariants.sh` 全部通过（含 5 个 patch 在上游 v1.21.4 上重放
  并与 vendored 包逐字节一致）；`tools/check-trafficctl-i18n.py` 中文覆盖 0 缺失。

### 说明 — 新增的校验断言

`tools/verify-trafficctl-invariants.sh` 新增一组「被覆盖会静默失效」的断言：
`settings.js` / `common.js` 存在、`menu.d` 登记 settings 页、两个页面都引用
`trafficctl/common`、软件卸载横幅文案已消失且模式短路仍在、硬件卸载告警仍在、
设备页不再定义任何重复配置项。刷新档位的断言改为同时查 `status.js` 与 `settings.js`
（该 chip 已随「表格与速率」迁走，只查前者会在迁移后误报）。

`tools/check-trafficctl-i18n.py` 的 `JS_FILES` 补入 `settings.js` 与 `common.js`，
否则这两个文件的中文缺译不会被校验发现。

## [v0.5.0] - 2026-10-13

### 新增 — 主机实时连接详情页（从概览「流量排行」与设备表 IP/主机名进入）

概览面板的「流量排行」此前只显示速率，无法回答「这台主机在连谁」。现在主机名与
IP 都是链接，设备表的 IP 与设备名后也有 `↗` 入口，点击进入该主机的**实时连接详情页**。

**13 列表格**（点击表头排序）：

```
应用 | 协议 | 线路 | 外网地址 | 域名 | 源端口 | 目的地址 | 目的端口
     | 上行速率 | 下行速率 | 累计上行 | 累计下行 | 连接状态
```

页面地址 `admin/status/trafficctl/host/<ip>`。该路由在 `menu.d` 里**不设 `title`** ——
可直达、可收藏、可后退，但不会在侧边栏多出一个点不开的菜单项（`ui.menu.getChildren`
会跳过无 title 的节点，已实测确认）。

### 实现要点（含实测依据）

- **逐连接字段来自 conntrack 的回复方向元组**。一行 conntrack 有**两个**元组：

  ```
  orig:  src=客户端      dst=远端      sport=客户端口 dport=远端口 bytes=上行
  reply: src=NAT后源     dst=NAT后目的  sport=远端口   dport=客户端口 bytes=下行
  ```

  旧版 `trafficctl-device.sh` 只读第一个元组，因此拿不到源端口、外网地址，
  且「上行/下行」实际是同一个数。本次补出 `sport` / `bytes_up` / `bytes_down` /
  `wan`（= reply dst）/ `proxy`。仅有客户端**发起**的连接计入（首元组 src 必须是该设备），
  否则入站连接的两个方向会颠倒。

- **「外网地址」在两种情况下留空而不是硬填**：
  1. `proxy=true`（回复元组来自本机 `:1234`）—— 出口地址由代理节点决定，这条连接
     自己没有可报告的外网地址；
  2. `wan == 客户端自身 IP` —— 访问路由器本身（DNS/SSH/LuCI）不经 NAT，
     把内网地址填进「外网地址」列会被读成一个恰好是私网的公网地址。

- **速率与累计可信**（实测，非推断）：本机 `flow_offloading=1`，命中 flowtable 的连接带
  `[OFFLOAD]` 标记，但 `/proc/net/nf_conntrack` 的 `bytes` **仍在增长** ——
  40 MB 下载期间回复方向由 0 涨到 1.1 MB 级。故这两列直接显示真实值，无需降级标注。
  速率由前端两次采样差分得到（键为 proto+dst+sport+dport，避免同目的地多连接互相覆盖基线）。

- **「应用」列无数据时显示 `—`**：需要 netifyd DPI，本固件未安装；tooltip 说明缺的是 agent
  而不是这条连接。装上后自动有值。

- **轮询防重入**：与设备表同一套做法（`tick` + `queryInFlight` + `document.hidden`）。
  `trafficctl-device.sh` 每次要读完整 conntrack 表，1 秒档位下若无条件发起会让 rpcd
  不断 fork 子脚本。实测 1s 档位下间隔稳定在 ~1000ms、无堆积。

- **13 列横排**：shadcn 主题下 LuCI 的 `.table/.tr/.th` 被算成 `display:block`，
  表头会逐个竖着堆成一列（详情页 13 列尤其明显）。本页范围内显式改用 grid 定列，
  窄屏横向滚动；其余页面不受影响。

### 修复 — 三处此前会误导排查的工具缺陷

- **`tools/verify-trafficctl-invariants.sh` 的 patch 重放会误报不一致**：
  它的 `git apply` 没钉 `core.autocrlf=false`，会从全局配置继承 `true`（本机 Windows
  默认即如此），把补丁内容落成 CRLF，于是与 LF 的 vendored 包「逐字节不一致」，
  报出一堆「文件 differ」而差异只是行尾。regen 脚本自己钉了该设置所以通过、
  校验脚本没钉，两者结论相反。已钉死，并在差异**全部**是行尾时直接给出该结论。
- **`python3` 在 Windows 上常常存在但不可用**（Microsoft Store 占位符，执行后只打印
  「Python was not found」并非 0 退出）。`command -v python3` 判定「有 Python」，
  于是检查永远失败、却报成「中文翻译不完整」。改为逐个候选**实际执行** `--version`。
- **`tools/regen-trafficctl-patches.py` 在中文 Windows（GBK）上崩溃**：
  `subprocess.run(text=True)` 用系统区域编码解码 git 输出，含非 GBK 字节时抛
  `UnicodeDecodeError`；该异常发生在读取线程里，表现为 `stdout=None`，最终报
  `data must be str, not NoneType`，与真正的原因（编码）毫无关系。已显式 `encoding='utf-8'`。
  同时把「本地有、上游没有、未登记」的文件提示按正斜杠归一，避免 Windows 上把
  已登记的新文件（`host.js`）误报成未登记。

- **msgid 是全仓库共用的键**：新表头原用 `Application`，而 `nlbwmon.zh-cn.lmo`
  已把该 msgid 译成「应用层」，同键译文互相覆盖，表头会莫名变成 nlbwmon 的用词。
  已改用本应用既有的 `App`（「应用」，无冲突）—— 实测 `_('Application')` 在路由器上
  返回「应用层」而 `_('App')` 返回「应用」。

### 验证

- 路由器实测 `trafficctl-device.sh 192.168.3.238`：95 条连接，字段语义逐项核对 ——
  代理连接 `proxy=true` 且 `wan` 为空；访问路由器自身的连接 `wan` 为空；
  直连外网显示真实 NAT 后地址 `100.119.32.10`；上下行分开计数。
- 浏览器实测（已登录路由器）：
  - 详情页 13 列表头横排、无截断单元格；速率与累计显示真实数值；
  - 概览「流量排行」8 个链接、设备表 44 个链接，点击 IP 正确导航到详情页且
    不误触「整行选中该设备」；
  - 切到 1s 档位后间隔稳定 ~1000ms、无请求堆积；控制台 0 错误；
  - 设备页原有功能回归正常（22 行、速率/累计有值、点击行为未变）。
- `tools/verify-trafficctl-invariants.sh` 全部通过（含 4 个 patch 在上游 v1.21.4 上
  重放并与 vendored 包逐字节一致）；`tools/check-trafficctl-i18n.py` 中文覆盖 0 缺失。

> 表头中 `Line` / `WAN address` / `Dst port` / `Upload rate` 等在路由器上仍显示英文，
> 因为新串的 `.lmo` 由**构建主机**的 `po2lmo` 生成（路由器上无该工具），
> 需刷入本次构建的固件后才会变中文。`po/zh-cn` 的译文已就位并经校验完整。

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

## [v0.4.4] - 2026-10-09

### 变更（构建产物加版本号）

- **新增 `Resolve version from CHANGELOG` 步骤**（`build-openwrt.yml` 第 2 步，
  紧随 `Checkout openwrt-build` 之后）：
  - 从 `CHANGELOG.md` 顶部提取 `## [vX.Y.Z]` 作为**唯一版本来源**，
    与 `release.yml` 同源，避免两处版本号漂移。
  - 输出 `VERSION`（含 `v`）/ `VERSION_NOV`（不含 `v`）/ `SHORT_SHA`
    到 `$GITHUB_ENV` 供后续步骤使用。
  - 找不到版本标题或格式不符 `vMAJOR.MINOR.PATCH` 时**直接 `exit 1`**
    （红线 3：禁止静默失败 —— 无版本号不允许出包）。
- **新增 `Rename firmware with version` 步骤**，在编译后、上传前重命名产物：
  - `openwrt-x86-64-generic-ext4-combined-efi.img.gz`
    → `openwrt-x86-64-ssrplus-vX.Y.Z-<sha7>-ext4-combined-efi.img.gz`
  - 即把 `openwrt-x86-64-` 之后的目标名（`generic`）替换为
    `ssrplus-<VERSION>-<SHORT_SHA>`，**保留镜像类型后缀**
    （`ext4-combined-efi` / `squashfs-combined-efi` 等），便于辨认镜像类型。
  - 同时生成 `.sha256` 校验文件。
  - 重命名后**断言**产物名含版本号且以 `.img.gz` 结尾，不符即失败
    （防止将来改坏命名逻辑却默默出包）。
- **artifact 名带版本号**：`openwrt-x86-64-ssrplus-vX.Y.Z-<sha7>`，
  便于在 Actions 页区分每次构建；同时上传 `.sha256`。
- **Release 上传步骤**同步上传 `.img.gz` 与 `.sha256`（保持幂等：
  已存在的 asset 跳过）。

### 修复（仓库行尾未归一化导致 11195 行虚假 diff）

- **`.gitattributes` 增加兜底规则 `* text=auto eol=lf`**：
  - **症状**：工作树中 11 个文件为 CRLF 而索引为 LF，产生 **11195 行**
    虚假 diff（`git status` 持续噪声）。根因是仓库**缺少兜底行尾规则** ——
    原有规则只覆盖 `*.sh/*.nft/*.conf/*.json/*.yml/*.yaml/*.md` 与少数
    无扩展名文件，`package/` 下 vendored 包的 `Makefile` / `LICENSE` /
    `*.css` / `*.js` / `*.po` / `*.pot` 以及无扩展名的 config 与 hotplug
    脚本均无规则覆盖，外部工具改写后无人纠正。
  - **改动**：新增 `* text=auto eol=lf` 兜底（`text=auto` 会让 git 自行判定
    二进制文件并跳过，故无需逐个排除）；补充 `*.css/*.js/*.po/*.pot/*.htm/
    *.html/*.txt` 与 `package/**` 规则。
  - **已归一化 11 个文件**：`package/luci-app-trafficctl/` 下的
    `LICENSE`、`Makefile`、`htdocs/.../status.css`、`htdocs/.../status.js`、
    `po/templates/*.pot`、`po/zh-cn/*.po`、`root/etc/config/trafficctl`、
    `root/etc/hotplug.d/dhcp/99-trafficctl-newdevice`、
    `root/etc/hotplug.d/iface/99-trafficctl-shapes`、
    `root/etc/init.d/trafficctl-telegram`、`root/usr/libexec/rpcd/luci.trafficctl`。
  - **安全性已验证**：归一化前逐个确认这些文件与 HEAD 的 blob 一致
    （`git diff --ignore-cr-at-eol` 为空，即**纯行尾差异、无内容改动**），
    归一化后逐个 `git hash-object` 比对仍为 `SAME`。
  - **结果**：全仓库工作树 CRLF 文件数 = **0**，`git status` 不再有噪声。

### 验证（本次全链路，路由器 `192.168.3.254`，固件 `10aec80` = v0.4.2）

> 用户已全新刷机到 `10aec80abc3d367567405a629507d1439029fe25`（v0.4.2）。
> 该版本含 v0.4.1 的 BBR 修复与 v0.4.2 的 LAN IP 固化，**不含** v0.4.3 的
> SSR-Plus 写入修复，故本次验证同时确认了「已修复项仍然有效」与
> 「未修复项的失效形态符合预期」。

**生效项（实测）**：

| 项 | 实测值 |
|---|---|
| 内核 | `6.18.55`，`DISTRIB_REVISION='R26.10.9'` |
| LAN | `192.168.3.254/24`，`proto=static`（v0.4.2 固化生效） |
| PPPoE | `wan proto=pppoe device=eth1`，`pppoe-wan mtu 1492` |
| IPv6 | `wan_6 proto=dhcpv6 reqprefix=56`，`network.wan6` 已删除 |
| **SQM 上行** | `cake 45Mbit besteffort dual-srchost nat overhead 34 mpu 68` |
| **SQM 下行** | `ifb4pppoe-wan` `cake 900Mbit dual-dsthost nat ingress` |
| SQM 队列时延 | 上行 `pk_delay 674us / av_delay 636us`；下行 `pk_delay 25us / av_delay 4us` |
| SQM 整形工作 | 上行 `overlimits 190264`，`dropped 78 / 322655`（0.02%） |
| **BBR** | 运行时 `tcp_congestion_control = bbr`，`turboacc.global.set=1`，`turboacc.config.tcpcca=bbr`，`firewall.@defaults[0].tcpcca=bbr`（v0.4.1 双覆盖者修复生效） |
| `tcp_timestamps` | `1` |
| `tcp_notsent_lowat` | `4294967295`（默认不限） |
| 包 | `sqm-scripts 1.6.0-1`、`tc-tiny 6.18.0-2`、`kmod-sched-cake`/`kmod-ifb`/`kmod-sched-core 6.18.55-1` |
| i18n | `luci-i18n-trafficctl-zh-cn` 已编入（`opkg list-installed` 可见） |
| 已排除服务 | `vsftpd`/`luci-app-vsftpd`/`ksmbd-server`/`luci-app-ksmbd`/`autosamba` 均为 0 |

**连通性（端到端）**：`baidu 200`、`taobao 200`、`google 302`、`github 200`、
`youtube 200`；出口 IPv4 = `203.27.106.146`（代理节点，`ifconfig.me` 与
`api.ipify.org` 一致）。`qq.com` 返回 501 属站点对无 UA 请求的正常响应，非故障。

**DNS 分流（客户端路径 `127.0.0.1:53`）**：

| 域名 | A | AAAA | 判定 |
|---|---|---|---|
| `baidu.com` | 4 | 0 | 国内，上游确实无 AAAA |
| `taobao.com` | 8 | **8** | 国内，保留真实 AAAA（未误伤） |
| `qq.com` | 2 | 0 | 国内，上游确实无 AAAA |
| `google.com` | 6 | 0 | 经代理，AAAA 被拒 |
| `chatgpt.com` | 2 | 0 | 经代理，AAAA 被拒 |
| `steamcommunity.com` | 1 | 0 | 经代理，AAAA 被拒 |
| `github.com` | 1 | 0 | 经代理，AAAA 被拒 |

`gfw_list.conf` 中 `127.0.0.1#5335` 条数 = **23617**（与分流设计一致）；
`dnsmasq` `noresolv=1` + `server=127.0.0.1#5353`；`pdnsd_enable=4`（mosdns）、
`filter_aaaa=1`；`mosdns` 运行时 `DNS_MODE` = `main_sequence_disable_IPv6`。

**延迟与抖动**：网关 `0.080/0.090/0.132 ms`（0% 丢包）；
`223.5.5.5` `21.527/21.632/21.852 ms`（0% 丢包，max−min = 0.325 ms）。

**符合预期的未修复项（v0.4.3 已修，本固件是 v0.4.2）**：

- `tunnel_forward_mosdns = tcp://8.8.4.4:53,tcp://8.8.8.8:53`（包默认），
  且 `option tunnel_forward`（模板特征）**不存在**，说明该键由 LuCI CBI
  保存时写入；这与 v0.4.3 的根因分析一致（脚本写入因空配置失败而被丢弃）。
- `/etc/firewall.user` 中的 IPv6 MSS clamp 仍是死代码
  （`uci show firewall` 中 `firewall.user` include 计数 = 0），
  但功能未缺失：fw4 的 `mtu_fix=1`（lan/wan 均为 1）已下发 **4 条**
  `maxseg size set rt mtu` 规则覆盖 IPv4/IPv6。

**开机日志**：`dnsproxy` 的 ERROR 集中于开机窗口（`19:33:53`–`19:34:13`），
根因与上次一致 —— `eth1` 在 `proto=dhcp` 阶段从上游租到不路由公网的地址，
PPPoE 建立后即恢复，非新增故障。`modprobe` 报 `act_ipt`/`nss-ifb`
不存在属 SQM 固定模块清单的无害项（cake 实测正常）。
`ddns-scripts` 报 `Service section disabled!` 系上游默认模板未启用。

## [v0.4.3] - 2026-10-09

### 修复（SSR-Plus 三项 UCI 写入曾整体失效 —— 本节是本仓库迄今最隐蔽的坑）

- **`99-gaming-optimize` 写 `shadowsocksr.@global[0].*` 前先确保 `global` 段存在**：
  - **症状**：v0.4.x 刷机后 `tunnel_forward_mosdns` 是包默认的
    `tcp://8.8.4.4:53,tcp://8.8.8.8:53`，`pdnsd_enable` / `filter_aaaa` 也未被本脚本写入。
  - **根因（曾误判为 LuCI 覆盖，已被实测推翻）**：
    1. uci-defaults 按**文件名排序**执行，`99-gaming-optimize`（`9`）**先于**
       `luci-ssr-plus`（`l`）。
    2. 此刻 `/etc/config/shadowsocksr` 仍由 opkg conffile 提供，实测为 **0 字节**
       （`wc -c /rom/etc/config/shadowsocksr` = 0）。
    3. **空配置上 `uci set shadowsocksr.@global[0].<k>=<v>` 会失败** ——
       实测 `uci: Invalid argument` + `Entry not found`，退出码 1。
       故本节原来三条 `uci set ...@global[0].*` 全部静默丢弃。
    4. 随后 `luci-ssr-plus` 检测到空配置，执行
       `[ -s /etc/config/shadowsocksr ] || /etc/init.d/shadowsocksr reset`，
       用 `/usr/share/shadowsocksr/shadowsocksr.config` 模板铺底。该模板**不含**
       `tunnel_forward_mosdns`（只有旧的 `tunnel_forward '8.8.4.4:53'`），
       于是 LuCI 读取时回落到 `client.lua` 的 `o.default`。
  - **对策**：不能简单地在写前 `uci add shadowsocksr global` 抢先建段 ——
    实测该做法会让文件提前变非空，导致紧随其后的 `luci-ssr-plus` 里
    `[ -s /etc/config/shadowsocksr ] || /etc/init.d/shadowsocksr reset`
    **跳过 reset**，结果是只有 `global` 一个段、缺 `server_subscribe` /
    `access_control` / `socks5_proxy` / `http_proxy` / `server_global` /
    `global_xray_fragment` / `clash_client_group` 共 7 个段；
    实测该分支下对 `@server_subscribe[0]` 的写入直接失败（退出码 1）。
  - **正确做法**：以「配置是否为空」为判据**主动先跑一次模板铺底**
    （`[ ! -s /etc/config/shadowsocksr ]` 时调用
    `/etc/init.d/shadowsocksr reset`），使其结果与 `luci-ssr-plus` 将要做的
    一致；随后在此之上写入本节的值。判据与 `luci-ssr-plus` **同源**，
    故行为一致；非空（升级/保留配置）时保持不动。
  - **端到端验证**（隔离副本模拟空配置首刷）：
    - 模板铺底后段数 = **8**（与 `shadowsocksr.config` 模板一致）
    - `pdnsd_enable=4`、`tunnel_forward_mosdns=<DoH>`、`filter_aaaa=1` **三项均写入成功**
    - 模拟 `luci-ssr-plus` 对 `@server_subscribe[0]` 的写入**成功**（原风险点已消除）
    - 幂等复跑：段数仍为 8、`global` 段仍为 1（无重复累积）
  - **覆盖范围**：`pdnsd_enable`、`tunnel_forward_mosdns`、`filter_aaaa` 三处受影响；
    前两处集中在第 4.5 节，`filter_aaaa` 另加同源守卫防御将来调整脚本顺序。
  - 同时把这些 `uci set` 改为带显式失败日志（`|| log "ERROR: ..."`），
    避免同类静默丢弃再次发生（红线 3：禁止静默失败）。

### 变更（MSS clamp 改为 fw4/fw3 双后端）

- **`99-gaming-optimize` 的 IPv6 MSS clamp 按防火墙后端分派**：
  - **背景**：内核升到 6.18.55 后后端由 fw3(iptables) 变为 fw4(nftables)。
    fw4 **不加载** `/etc/firewall.user`（`uci show firewall` 中无该 include），
    故原先写入该文件的 `ip6tables` 行在 fw4 上是**死代码**。
  - **改动**：`command -v nft && [ -x /sbin/fw4 ]` 为真时写
    `/etc/nftables.d/10-mss-clamp.nft`（`table inet mssclamp`，含
    `maxseg size set rt mtu`）；否则沿用原 `/etc/firewall.user` 写法。
    与 `files/etc/init.d/dnsproxy` 的双后端策略保持一致。
  - **功能冗余说明**：该功能并未缺失 —— fw4 的 `mtu_fix=1`（本脚本设置）
    已为 lan/wan 生成 ingress/egress 共 **4 条** `maxseg size set rt mtu` 规则，
    覆盖 IPv4/IPv6。显式规则作为冗余保留。
  - **机制已验证（只读证据）**：`/etc/nftables.d/10-dnsproxy-lan-intercept.nft`
    的链原样出现在 live ruleset，证明 fw4 确实 glob include 该目录；
    `/etc/nftables.d/` 也在 `/lib/upgrade/keep.d/firewall4` 保留清单内。
    本片段已通过 `nft -c` 语法校验。
  - **启动顺序**：`/etc/init.d/boot`（START=10，跑 uci-defaults）早于
    `/etc/init.d/firewall`（START=19），故首开机即生效。

### 更正（撤销上一版的两处错误判断）

- **撤回「LuCI 下拉框无法表示 DoH 值 → 保存时被重置」的结论**。
  浏览器实测：该字段渲染为 `L.ui.Combobox`，**自定义值被正确渲染**为
  `<li data-value="https://dns.google/dns-query,..." selected="">`，
  `<input type="hidden" name="cbid...tunnel_forward_mosdns">` 的值也完全正确。
  LuCI 侧不存在该问题；真实原因是上面的 uci-defaults 写入失败。
- **撤回「`192.168.1.4` 是 `config_generate` 分配的默认 LAN 网段」的结论**。
  实测日志为 `udhcpc: unicasting a release of 192.168.1.4 to 192.168.1.1` ——
  它是 **WAN 侧 `eth1` 在 `proto='dhcp'` 阶段从上游 DHCP 租到的地址**
  （`board.json` 中 `network.wan.protocol='dhcp'`），随后因切到 PPPoE 而释放。
  结论方向不变（dnsproxy 于开机 29 秒内因上游不可达而报错），但根因描述已更正。

## [v0.4.2] - 2026-10-09

### 新增（LAN 固定 IP 固化）

- **`99-gaming-optimize` 增加 `network.lan.ipaddr='192.168.3.254'`**：
  - **动因**：本仓库此前**从未**设置 `network.lan.ipaddr`。而 `/bin/config_generate`
    第 165 行对 lan 的默认值是硬编码的 `192.168.1.1`（`/etc/board.json` 的
    `network.lan` 不含 `ipaddr`）。旧行为因此是：
    - 保留配置刷机 → 沿用旧 IP（现有路由器为 `192.168.3.254`）
    - **全新刷机（不保留配置）→ 回退 `192.168.1.1`**，客户端仍按
      `192.168.3.254` 访问即失联
  - **改动**：同时写 `ipaddr` / `netmask` / `proto='static'` / `device='br-lan'`，
    使任何刷机方式下 LAN 均为 `192.168.3.254/24`。
  - **执行顺序已核实无冲突**：`/etc/init.d/boot` 的 `boot()` 先执行
    `/bin/config_generate`，再执行 `uci_apply_defaults`（按文件名排序运行
    uci-defaults）。本脚本（`99-gaming-optimize`）排在 `15_odhcpd`、
    `14_migrate-dhcp-release` **之后**，且后两者都不写 `network`。
    `config_generate` 仅在 boot 内调用一次，不会再覆盖。
  - **风险**：LAN IP 变更本身会中断网络（需 `network reload` 或重启）。
    本脚本属**首开机一次性执行**，对已运行的路由器无影响；仅影响新刷固件的首次启动。
    当前路由器已是该值，因此本次改动**不产生任何中断**。
  - 同步更新该节点日志为 `network: lan=192.168.3.254/24, ...`。

## [v0.4.1] - 2026-10-09

> 刷机实测后的修复版本。v0.4.0 的改动在真实固件上验证，发现并修复 BBR 未生效的
> 两个覆盖者；其余改动（SQM 双向整形、filter_aaaa、i18n 符号名）已实测生效。

### 修复（BBR 未生效，被两个后执行者覆盖）

- **`99-gaming-optimize` 增加 `turboacc.global.set='1'` 与 `firewall.@defaults[0].tcpcca='bbr'`**：
  - **现象**：v0.4.0 刷机后 `turboacc.config.tcpcca` 仍为 `cubic`，
    运行时 `net.ipv4.tcp_congestion_control = cubic`。
  - **根因 1**：`/rom/etc/uci-defaults/turboacc` 在本脚本**之后**执行
    （uci-defaults 按文件名排序，`99-gaming-optimize` < `turboacc`），
    其逻辑是 `cat > /etc/config/turboacc` **整体重写**配置，把 `tcpcca` 写回 `cubic`。
    对策：先设 `turboacc.global.set='1'` —— 该脚本首行守卫
    `[ "$(uci -q get "turboacc.global.set")" -eq "1" ] && exit 0` 会使它直接退出。
    这是利用上游自身的幂等开关，无需修改上游包。
  - **根因 2**：内核升级到 6.18.55 后，`/etc/init.d/firewall`（`START=19`）
    新增 `apply_tcpcca_section()`，读 `firewall.@defaults[0].tcpcca`（默认 `cubic`）
    并 `sysctl -w` 覆盖，在 fw4 `start/reload/restart` 时都会执行。
    对策：同时设 `firewall.@defaults[0].tcpcca='bbr'`。
  - **验证**（路由器 192.168.3.254）：三项均为 `bbr`，运行时已生效。

### 已验证生效（v0.4.0 改动在真实固件的实测结果）

- **SQM 双向 cake 整形成功**：上行 `pppoe-wan` → `cake 45Mbit besteffort
  dual-srchost nat nowash overhead 34 mpu 68`；下行 `ifb4pppoe-wan` →
  `cake 900Mbit besteffort dual-dsthost nat ingress`。上行排队时延
  `pk_delay 23us / av_delay 3us`，`overlimits 203438`（整形器积极工作），
  丢包率 <0.01%。对照：刷机前 `pppoe-wan` 为 `qdisc noqueue`（无任何队列管理）。
- **`filter_aaaa=1` 生效**：`chatgpt.com` 的 AAAA 已被拒绝（回落 IPv4 走代理，
  ADR-0001 的语义得到实测确认）；`taobao.com` 仍返回 8 条真实 AAAA（未误伤国内）；
  `google.com` / `steamcommunity.com` / `github.com` 的 AAAA 均为 0 条（合成 SOA）。
- **mosdns `reject` 前置生效**：运行时 `/var/etc/ssrplus/mosdns-config.yaml`
  的序列为 `lazy_cache → reject → prefer_ipv4 → forward`（6 个 plugin 完整）。
- **trafficctl 中文语言包已编入**：`luci-i18n-trafficctl-zh-cn` 出现在
  `opkg list-installed`，证实 v0.4.0 的 i18n 符号名修正有效（原符号从未匹配）。
- **`wan6` 已删除**、`firewall zone wan` 只剩 `wan`、`vsftpd`/`ksmbd`/`autosamba`
  均已从固件移除、`tcp_timestamps=1`、`tcp_notsent_lowat` 回到默认不限。

### 记录（固件基线变化，本版本未修改这些）

- 内核 `6.12.107` → **`6.18.55`**；`DISTRIB_REVISION` `R26.05.20` → **`R26.10.9`**。
- **防火墙后端由 fw3/iptables 改为 fw4/nftables**（`table inet fw4`）。
  SSR-Plus 透明代理同步改用 nftables（`table inet ss_spec`；
  `blacklist_forward.conf` 输出 `nftset=` 而非 `ipset=`）。
- 由此产生一个已知死代码：`/etc/firewall.user` 不再被 fw4 加载
  （`uci show firewall` 中无该 include），故 `99-gaming-optimize` 追加的
  IPv6 MSS clamp 行在当前固件上不生效。功能未缺失 —— fw4 的 `mtu_fix=1`
  已原生下发 4 条 `tcp option maxseg size set rt mtu` 规则覆盖该功能。
  **后续应改为 fw4 的 include 机制（`/etc/nftables.d/`）或直接依赖 mtu_fix。**

### 未落地（需先定位 SSR-Plus 生成路径，同 v0.4.0）

- `applechina.conf` 明文 DNS 加密化、dnsmasq 日志恢复、whitelist 冗余清理。
- 另：`tunnel_forward_mosdns` 会被 LuCI 页面的
  `client_dns_defaults.htm` 在加载时重置为包默认（`tcp://8.8.4.4:53,...`）。
  本次已在路由器上手工改回 DoH 并重启生效；**仓库侧尚无防护**，
  需评估是否改为不依赖该 UCI 项，或加启动后校正。

## [v0.4.0] - 2026-10-09

> 依据：`docs/audit/2026-10-09-network-audit.md`（对在线路由器 `192.168.3.254` 的只读全链路审计，
> 含改动前基线与我方证据；审计过程中有三处初判被实测推翻，已在报告内显式标注）。
> 本次为功能级改动（整形 / DNS 序列 / 分流语义 / 构建包），故按 MINOR 定为 v0.4.0。
> 未打 `v0.3.5` tag —— HEAD 已含该修复但无 tag，本次不补。

### 新增（SQM / cake 整形）

- **`files/etc/config/sqm`（新文件）**：cake 整形默认配置。
  - 动因：实测固件**不含 `tc` 二进制，也不含 `sch_cake.ko`/`ifb.ko`**，`pppoe-wan`
    为 `qdisc noqueue`、无任何队列管理；上行 50 Mbps 是全链路最窄瓶颈，
    其排队时延是游戏 ping 抖动的直接来源。
  - 参数：`download 900000` / `upload 45000`（50 Mbps × 90%）、`qdisc cake`、
    `script piece_of_cake.qos`、`linklayer ethernet`、`overhead 34`、`tcMPU 68`。
  - 下行取保守的 900 Mbps 而非 1000，是为 N2930（4 核 Bay Trail）留余量，
    避免 CPU 先于 SQM 成为瓶颈；若刷机后实测峰值明显低于 900 再下调。
  - 队列：`iqdisc_opts 'ingress nat dual-dsthost'` + `eqdisc_opts 'nat dual-srchost'`。
  - 技术依据（一手来源已核）：**SQM 与 software flow offloading 兼容**，
    仅 hardware flow offloading 不兼容（内核 `__nf_flow_queue_xmit()` 仍调用
    `dev_queue_xmit()`，即 egress qdisc 不被绕过）。故**不关闭** `flow_offloading`，
    NAT1（fullcone）不受影响 —— 实测本机 `xt_FULLCONENAT` 与 `xt_FLOWOFFLOAD`
    已同时被引用并生效。
  - 已知限制：软件 flow offloading 命中后的报文不再经过 mangle，因此**不采用
    DSCP 分级**（其有效性无一手依据），只依赖 cake 的 per-flow 公平队列防大流饿死小包。

### 修复（BBR 未生效）

- **`turboacc.config.tcpcca` 由 `cubic` 改为 `bbr`**（`files/etc/uci-defaults/99-gaming-optimize`）：
  - **现象**：`sysctl net.ipv4.tcp_congestion_control` 运行时为 `cubic`，
    而 `/etc/sysctl.conf` 与 `/etc/sysctl.d/12-tcp-bbr.conf` 均写 `bbr`，
    `kmod-tcp-bbr` 已加载且 `bbr` 在可用列表中。
  - **根因**：`/etc/init.d/turboacc` 以 `S90` 启动（晚于 `S11sysctl`），
    其第 145 行 `sysctl -w net.ipv4.tcp_congestion_control="$tcpcca"`，
    而 `turboacc.config.tcpcca` 默认 `cubic`，开机后覆盖了 sysctl 的值。
  - **作用域澄清**：该开关只影响**路由器自身发起的 TCP**（dnsproxy 的 DoH 出站、
    代理隧道、`ssrplusupdate.sh`、opkg），**不影响** LAN 客户端转发的 TCP。
    原 `sysctl.conf` 注释将其描述为对游戏的作用，属过度声明，已更正。

### 修复（DNS 解析语义）

- **新增 `files/etc/ssrplus/mosdns-config.yaml` overlay，把 `reject` 规则前置**：
  - **问题**：上游模板把 `qtype 28/65 → reject 0` 排在 `$forward_google` **之后**。
    mosdns v5 的 `sequence` 依次执行每条 rule，`ActionReject.Exec` 用
    `qCtx.SetResponse(r)` 覆盖已写入的应答 —— 因此每个被拒的 AAAA/HTTPS 查询都会
    **先真向上游发一次再丢弃**，白付一次经代理的往返。
  - **落点**：语句顺序**只由模板决定**。`/etc/init.d/shadowsocksr` 第 1283–1288 行
    只做四件事（在第 15 行插 DoH 上游、替换 `DNS_PORT`、替换 `DNS_MODE`、改
    `concurrent`），**不重排 `args:` 序列**。故必须改模板。
  - **为何用 overlay**：原模板由 `luci-app-ssr-plus` 包提供且登记为 opkg conffile，
    包升级会覆盖它。仓库此前无该文件副本，新增 overlay 才能固化。
  - **硬约束**：`upstreams:` 必须保持在第 14 行（init 脚本用
    `awk -v line=14 'NR == line+1 {print text} 1'` 注入上游）。因此说明性注释
    **只能放在文件末尾**，文件顶部不得增加任何行。
  - **CI 守卫**：新增步骤 `Verify mosdns template contract`，断言第 14 行确为
    `upstreams:`、`reject` 行号小于 `forward` 行号、`DNS_MODE`/`DNS_PORT` 占位符存在。
    该契约无法被 YAML 语法检查发现，出错会让 mosdns 启动失败、23614 个 gfw_list
    域名解析全部中断，故必须阻断在构建期。
  - **本地验证**：已按 init 脚本的真实命令（awk 注入 + 两次 sed + `DNS_MODE` 替换）
    在本地完整模拟，转换结果经 YAML 解析确认 `plugins=6`、`upstreams` 2 条、
    `concurrent=2`、`reject` 下标 1 < `forward` 下标 3、`lazy_cache` 仍在首位、
    `udp/tcp_server` 的 `entry`/`listen` 正确。
- **`shadowsocksr.@global[0].filter_aaaa` 由 `'0'` 改为 `'1'`**：
  - **这是对 v0.3.5 结论的修正，方向相反。** v0.3.5 的前提是「dnsmasq 把所有域名
    都指向 `127.0.0.1#5335`」；该前提已不成立 —— 现网 dnsmasq 默认走
    `127.0.0.1#5353`（dnsproxy 国内 DoH），仅 `gfw_list.conf` 的 23614 个域名
    与 `black.list` 走 `#5335`（mosdns）。
  - 因此 `'1'` 下 mosdns 的 `reject 0` 只作用于**需走代理的域名**，即
    **拒绝集 = 需走代理的域名集**，正是期望语义：被墙域名回落 IPv4 走代理，
    其余国外域名保留真实 AAAA 走 IPv6 直连。
  - 实测（客户端真实路径）：`taobao.com` 返回 8 条真实 AAAA；
    `google.com`/`chatgpt.com`/`steamcommunity.com` 返回 mosdns 合成 SOA；
    `baidu.com`/`qq.com` 的 SOA 来自真实权威（上游确实无 AAAA，非被抑制）。
  - 若沿用仓库原值 `'0'`，那 23614 个被墙域名将拿到真实 AAAA 并在 IPv6 上
    直连被 RST，表现为「有 IPv6 但打不开站点」。详见 `docs/adr/0001-filter-aaaa-semantics.md`。
- **`tunnel_forward_mosdns` 由 3 个上游收敛为 2 个**（去掉 `https://dns.quad9.net/dns-query`）：
  三个上游以 `concurrent` 竞速取最快，quad9 从国内经代理访问明显慢于
  google/cloudflare，参与竞速只增加方差、不增加可用性。
- **`files/etc/config/dnsproxy` 头部注释更正**：原文写「国内国外统一加密解析、
  不分流」，与同文件 `servers` 段的显式分流（国外域名 → `127.0.0.1:5335`）矛盾。

### 修复（内核旋钮冲突与死配置）

- **`files/etc/rc.local` 删除 RPS 段**：实测该段从未生效 —— `rps_cpus` 最终由
  `packet_steering`（其 `service_triggers` 注册了 `interface.*` raw trigger，
  接口事件会再次触发 reload）改写为单核亲和（`eth0=1`、`eth1=4`），
  `rps_sock_flow_entries` 由 `autocore`（`S99`，最后执行）按 `核心数 × 4096`
  覆盖为 16384。保留该段只会误导后续维护者。
- **`files/etc/rc.local` 删除 `nf_conntrack_helper` 写入**：该 sysctl 路径在
  内核 6.12 已不存在，原 `echo 0 > ... 2>/dev/null` 静默失败。
- **`files/etc/sysctl.conf` 删除 `net.core.rps_sock_flow_entries = 32768`**：
  同上，运行时值由 `autocore` 决定（16384），该行是死配置。
- **`rc.local` / `sysctl.conf` 的 RPS 死配置根因已确证**（审计报告 §10 未决项 1 结案）：
  - `rps_flow_cnt` 的唯一清零点为 `/usr/libexec/network/packet-steering.uc` 第 80–86 行——
    当 UCI `network.@globals[0].steering_flows` 未设置时，默认 `local_flows=0` 被
    **无条件**写入所有队列。证据：该脚本 `-n` dry-run 输出与实测 `eth0=1`/`eth1=4`
    的 `rps_cpus` 指纹完全一致，而 `autocore`（写 `f`）与 `rc.local`（写 `f`）在 4 核下
    都产不出该值，故必是它最后覆盖。其 `service_triggers` 含
    `procd_add_raw_trigger "interface.*" 1000 …reload`，接口事件会再次清零。
  - 因此**若日后需要 `rps_flow_cnt` 非零，应设 `network.globals.steering_flows`**
    （上游 UCI 开关），而不是改 `rc.local`。本次未改（属可选优化，不影响既定目标）。
- **`files/etc/sysctl.conf` 删除 `net.ipv4.tcp_notsent_lowat = 131072`**：
  该值的正确用法是「降低」以改善交互延迟；而代理出口 RTT ≈200ms、上行 50 Mbps
  → BDP ≈1.25 MB，原值 128 KB 不到 BDP 的 1/10，会压制代理隧道与 DoH 吞吐，
  两种目的都不达成。恢复内核默认（不限制）。
- **`files/etc/sysctl.conf` 恢复 `net.ipv4.tcp_timestamps` 为内核默认 1**：
  原值 `0` 关闭 RFC1323 时间戳，同时失去 PAWS（防序号回绕重放）与 RTT 采样；
  唯一收益是每包省 12 字节，而「关闭可降低延迟」在官方文档中**无任何依据**
  （RFC 7323 §1.3 反而指出其对长肥管道是收益项）。

### 修复（DHCPv6 与 MTU）

- **`dhcp.lan.ra_mtu` 由 `1452` 改为 `1492`**：原值推导「1492 − 40」错把 IPv6
  基本头（40 B）当成要从链路 MTU 中预先扣除的封装开销。IPv6 头是报文本身的
  一部分，不占 MTU 之外；预先扣 40 字节只会让每个 IPv6 包少用 40 字节载荷。
  已通告 PPPoE 链路真实 MTU，PMTU 发现由 ICMPv6 `packet-too-big` + MSS clamp 覆盖。
- **删除 `network.wan6`**：实测该接口只跑一个 `-P0` 的 `odhcp6c`，不申请前缀，
  `eth1` 上无全局地址、日志零输出，属纯空转；ISP 的 IPv6 实际经 PPPoE 由
  `wan_6` 获取。同时 `del_list firewall.@zone[1].network='wan6'`，避免 fw3 引用
  不存在的接口。

### 修复（工程健壮性）

- **CI 修正 trafficctl 中文语言包的 CONFIG 符号名**（先于本次改动存在的静默失效）：
  - 原写 `CONFIG_PACKAGE_luci-i18n-luci-app-trafficctl-zh-cn=y`，**该符号从不匹配任何包**，
    被 kconfig 的 `confdata.c` 静默忽略（未知符号直接 `continue`，不报错），
    因此中文语言包**从未被编入固件**。
  - 正确符号为 `CONFIG_PACKAGE_luci-i18n-trafficctl-zh-cn`。推导依据 `luci.mk`：
    `LUCI_NAME = 目录名 = luci-app-trafficctl` → `LUCI_TYPE = word 2 = app` →
    `LUCI_BASENAME = patsubst luci-app-%,%,LUCI_NAME = trafficctl` →
    `LuciTranslation` 生成 `Package/luci-i18n-$(LUCI_BASENAME)-zh-cn`。
  - 同时在 CI 校验步骤中新增对该符号的**阻断式检查**（写错即 `exit 1`），
    避免同类静默失效再次发生。
- **`99-gaming-optimize` 的 MSS clamp 追加改为幂等**：原代码无条件
  `cat >> /etc/firewall.user`，实测该段在现网 `/etc/firewall.user` 中**已重复两遍**。
  改为追加前按标记行 `grep -q` 判重。
- **`.gitattributes` 补规则**：新增 `*.ps1`、`**/etc/config/sqm`、`**/etc/sysctl.conf`。
  其中 `*.ps1` 是修正 AGENTS.md §9 的失实声明（原称已固定 LF，实际无该规则）。

### 变更（构建）

- **CI 增加 SQM 相关包**：`sqm-scripts`、`luci-app-sqm`、`kmod-sched-cake`、
  `kmod-ifb`、`kmod-sched-core`、`tc-tiny`。
  - `sqm-scripts` 取自 coolsnowwolf/packages feed 的 **v1.6.0**（依赖 `iptables`
    而非 `nftables`，与本固件 fw3/iptables 后端匹配）；OpenWrt 官方 master 的
    v1.8.0 依赖 `nftables`，**不适用**。
  - `tc` 由 iproute2 的 `tc-tiny`（默认变体）提供 `/sbin/tc`。
- **CI 显式排除 `vsftpd`、`ksmbd-server`、`autosamba` 及其 LuCI/i18n 包**：
  实测用户不使用 SMB/FTP；`ksmbd` 未配置任何 share（仅 globals），`445` 空转。
  注意 `luci-app-vsftpd` 在 lede 的 `DEFAULT_PACKAGES.router` 里，故排除写在
  `make defconfig` **之前**。
- **CI 新增校验步骤** `Verify SQM enabled and file services excluded`：
  在 `make defconfig` 之后逐项复核（SQM 全部 `=y`、被排除项不为 `=y`），
  任一项不符即 `exit 1`，不使用 `|| true`（遵循「禁止静默失败」红线）。

### 新增（文档）

- `docs/audit/2026-10-09-network-audit.md`：本次全链路审计报告（数据流图、
  改动前基线、15 项问题、逐项回滚、验收清单）。
- `docs/adr/0001-filter-aaaa-semantics.md`：记录 `filter_aaaa` 的语义随
  dnsmasq 路由分裂而反转这一反直觉结论。
- `docs/adr/0002-no-ipv6-proxy.md`：记录「境外 IPv6 不经代理」是有意取舍而非遗漏。
- `GLOSSARY.md`：固定链路术语（分流 / 拒绝集 / 直连 / 强制代理 / 健康检查 /
  整形 / 排队时延 / overhead / 跳数）。
- `AGENTS.md`：更正 §2 红线 4（trafficctl 的 chmod 描述与 CI 不符）、
  §5（filter_aaaa 语义）、§9（.ps1 规则失实）、附录（9 个本机工具实际不存在）。

### 验证

- 静态检查：`ash -n` 通过 `files/etc/uci-defaults/99-gaming-optimize`、
  `files/etc/rc.local`、`files/etc/init.d/dnsproxy`；YAML 通过
  `python -c "import yaml"` 解析 `.github/workflows/build-openwrt.yml`。
- 端到端验证**待用户刷机后执行**，清单见审计报告 §8（配置生效 / DNS 回归 /
  游戏与抖动 / 性能四组），并保留改动前基线用于前后对比。
- 未在路由器上执行任何改动（本次仅改仓库）；NAT1 保持与否、下行峰值是否受
  影响，均属刷机后实测项。

### 未完成 / 已知限制

- **`mosdns-config.yaml` 的 `reject` 前置未落地**：运行时配置由 SSR-Plus init
  脚本生成（源模板含 `DNS_MODE`/`DNS_PORT` 占位符），改动位置未确认前不修改，
  以免改到不被读取的文件。见审计报告 §10 未决项 2。
- **`rps_flow_cnt` 被清零的写入方未定位**（`autocore` 写 4096，实测为 0）。
  在定位前不基于该参数做任何调优。见 §10 未决项 1。
- **上行吞吐无法测量**（本机无可用上传端点，公共镜像 PUT 返回 405），
  SQM 的上行效果只能通过「上行饱和时 ping 抬升」间接验证。
- **`applechina.conf` 的 173 条明文 DNS（`114.114.114.114`）未改**：用户已确认
  希望改走加密链，但该文件由 SSR-Plus 生成，生成路径未确认前不修改。
- **`whitelist_forward.conf` 的 8 条无效 `server=/域名/127.0.0.1` 未清理**：
  实测未形成自环（解析 0–1ms 正常返回），属冗余而非故障，同因 SSR-Plus 生成路径未知。

## [v0.3.5] - 2026-09-21

### 修复（双栈客户端「有公网 IPv6 地址却无法用 IPv6 上网」）

- **`files/etc/uci-defaults/99-gaming-optimize` — `filter_aaaa` 由 `1` 改为 `0`**：
  - **现象**：客户机（如 Hyper-V `vEthernet (External network)`）已通过
    SLAAC 获得全局 IPv6 地址（`240e:355:7f2b:8900::/64`）与默认路由
    （`fe80::230:18ff:fe0b:9b69`），`ping6` 国内外地址均通，但浏览器/IPv6
    站点访问失败，表现为「拿得到地址、上不了 IPv6 网」。
  - **根因**：`filter_aaaa=1` 时 SSR-Plus 生成的 MosDNS(5335) 使用
    `main_sequence_disable_IPv6`，对 `qtype 28`(AAAA) / `65`(HTTPS)
    一律 `reject 0`。而本固件 dnsmasq 把**所有 gfwlist 域名**
    （`/tmp/dnsmasq.d/dnsmasq-ssrplus.d/gfw_list.conf`，约 89 万行）
    **加上** `files/etc/config/dnsproxy` 显式国外域名列表全部指向
    `127.0.0.1#5335` → **国外域名永远拿不到 AAAA 记录** →
    客户端只有 A 记录，协议栈根本不会发起 IPv6 连接。
  - **实测（192.168.3.254，A/B 对照）**：
    - `filter_aaaa=1`：`google.com / github.com / www.wikipedia.org /
      www.debian.org / www.kernel.org / www.python.org / www.mozilla.org`
      的 AAAA 计数**全为 0**（`main_sequence_disable_IPv6`）；
    - `filter_aaaa=0`：上述域名 AAAA 立即恢复正常
      （google=5、github=1、wikipedia=2、debian=5…），
      客户端 `curl -6 https://www.cloudflare.com/` → **HTTP 200 / 1.3 MB**，
      清华 TUNA 镜像 IPv6 大文件（13.3 MB）下载正常；
      国内域名（baidu/qq/taobao）AAAA 与 A 记录均无回归。
  - **说明**：SSR-Plus 本固件仅代理 IPv4（`ip6tables` 中无任何
    `SS_SPEC_TPROXY`/`TPROXY6` 规则，`uci show shadowsocksr` 无 IPv6 选项），
    国外 IPv6 为**直连**。原 `filter_aaaa=1` 只能屏蔽记录、无法把 IPv6 流量
    导入代理，因此「国外仅 IPv4」既不能省流量也不提升匿名性，
    只会让双栈客户端失去 IPv6 能力。如需恢复旧语义可改回 `1`
    （代价：国外域名完全无 IPv6）。

### 修复（工程健壮性）

- **`.gitattributes` 无扩展名文件规则此前实际未生效**：
  原写法为根路径锚定的 `/etc/config/dnsproxy`、`/etc/init.d/dnsproxy`、
  `/etc/uci-defaults/99-gaming-optimize`，但仓库内真实路径带 `files/` 前缀
  （`files/etc/...`），`git check-attr` 显示 `attr/` 为空（未匹配）。
  改为 `**/` 通配（`**/etc/config/dnsproxy` 等）并补上此前遗漏的
  `files/etc/hotplug.d/iface/50-ipv6-pd-lan`、`files/etc/rc.local`。
  注：本次核查确认索引内 blob 已为 LF（`git ls-files --eol` 显示 `i/lf`），
  故 CI 未受影响；此改动消除的是 CRLF 回流的隐患。

### 验证

- 路由器 192.168.3.254 热应用后：国外域名 AAAA 恢复、客户端 IPv6
  网页与大文件传输正常、国内域名与 DNS 加密链路（dnsproxy→DoH）无回归，
  `odhcpd/dnsmasq/mosdns/v2ray/dnsproxy` 8 个进程健康。

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

## [v0.3.3] - 2026-09-02

### CI/CD

- **新增发版工作流 `release.yml`**：推送 `v*` tag 时自动创建 GitHub Release，
  Release notes 自动从 `CHANGELOG.md` 提取对应版本的日志段
  （`## [<tag>]` 到下一个 `## [` 之间，裁剪首尾空行）；支持 `workflow_dispatch`
  手动指定 tag 补发/更新（幂等：Release 已存在则仅更新 notes）。
  CHANGELOG 中找不到对应版本时工作流明确失败（不静默）。
- `build-openwrt.yml`：`v*` tag 推送时同样触发编译；编译成功后把固件产物
  （`*.img.gz`）上传到 release.yml 创建的 Release（等待 Release 就绪 ≤60s，
  文件已存在则跳过）；master 推送仍只保留 artifact。

### 验证

- `v0.3.2` 手动触发：Release 自动创建且 notes 与 CHANGELOG 一致；
- 重复触发：success（幂等更新 notes）；
- 不存在的版本（v9.9.9）：明确失败。

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

## [v0.2.4] - 2026-09-01

### 新增

- **luci-app-dnsproxy 完整简体中文汉化**（`patches/luci-app-dnsproxy/0003-add-zh-cn-localization.patch`）：
  源码级直译 6 个 JS 页面共 210 处字符串：
  - `main.js`：服务状态/版本/服务控制（启动/重启/停止/启用/禁用）等；
  - `settings.js`：全部配置选项卡（常规/服务器/缓存/TLS/隐私与安全/性能）与字段说明；
  - `diagnostics.js`、`logread.js`、`help.js`、`file.js`：诊断/日志/帮助/配置文件页。
  实现方式为直接替换 `_()` 字符串（不引入 luci.mk/po2lmo 构建链，零额外依赖，
  CI 仅按既有 patch 流程应用即可自动生效）。

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

## [v0.2.0] - 2026-09-01

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
