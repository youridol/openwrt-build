# ADR-0007：DNS 分流页 tab 结构重构 —— 概览放结果、域名放资产与参数

- 状态：**已实施（v0.18.0，路由器 + 真实浏览器验证通过）**
- 日期：2026-10-24
- 相关：`package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua`、
  `.../dnschain.lua`、`.../diagrams.lua`、新建 `.../diagnosis.lua`、
  `package/luci-app-dnschain/htdocs/luci-static/resources/dnschain/dnschain.js`、
  `files/usr/bin/dnschain-selftest`、CHANGELOG v0.18.0
- 取代：无。本 ADR 只重排页面结构，不改 DNS 分流运行时逻辑
- 编号说明：**本文最初编为 0006，与既有的
  [`0006-domain-routing-and-reroute.md`](0006-domain-routing-and-reroute.md)
  （域名归属判定与自动改道）冲突，已改为 0007。**
  该冲突被 `docs/README.md:69`、`0003-dns-chain-framework.md:5,:452`、
  `docs/packages/luci-app-dnschain.md:766` 共 4 处引用证实。
  **新增 ADR 前必须先 `ls docs/adr/` 确认编号未被占用** —— 本项目 ADR 编号
  不连续（无 0008+），不能假设「最大号 + 1」。

> **⚠️ 文档联动硬性要求**
>
> 本次重构涉及 tab 结构与 section 归属，**任何后续修改都必须同步更新本文 §9「文档联动清单」列出的文件**，
> 否则视为未完成。
>
> 已知历史漂移证据：`docs/packages/luci-app-dnschain.md` 的 section 计数在
> v0.16.3~v0.17.1 期间被改过三次（19→20→21），每次都因为结构变了而文档没跟上。
> **改结构必须改文档，二者是同一次改动。**

---

## 1. 背景

用户提出：「域名页面和概览与诊断页面的 tab 合并方案，我感觉有点重合」。

### 1.1 取证结论：section 层面没有重合

`SECTION_TAB`（`general.lua:134-162`）显示两个 tab 的 section 标题**完全无交集**：

| tab | section |
|---|---|
| 概览与诊断 | 当前状态、自检、操作（3 个） |
| 域名 | 自定义域名·国内、自定义域名·国外、判定链路、改道状态、改道明细、分诊结果、观测与阈值、域名操作（8 个） |

### 1.2 取证结论：数据生产者也不重合

| 函数 | 出现位置 |
|---|---|
| `ds.chain_snapshot()` | 仅概览（:307、:625） |
| `ds.selftest()` | 仅概览（:251、:536、:2116） |
| `ds.health_rows()` / `health_summary()` | 仅域名（:1135、:1136、:1233） |
| `ds.triage_rows()` | 仅域名（:1366、:1373） |

字面共用的只有 `ds.entry_port()`、`ds.foreign_port()`、`ds.invalidate()` —— 都是端口参数或清缓存，**不承担数据生产**。

### 1.3 真正的重合在别处

用户感觉的「重合」来自三类真实缺陷，与 section 划分无关：

**① 同 tab 内两个按钮执行同一条命令**

| 按钮 | 行号 | 实际命令 |
|---|---|---|
| 一键归一 | :2196 | `dnschain-reconcile 2>&1` |
| 手动导入名单 | :2221 | `dnschain-reconcile 2>&1` |

模型层 `M.import_lists()`（`dnschain.lua:451`）与 `M.reconcile_now()`（:466）**函数体逐字相同**。

**② 「重建分流规则」有 3 个入口**

- 域名「重建分流规则并生效」:1570 → `dnschain-health apply`
- 概览「一键归一」/「手动导入名单」→ `dnschain-reconcile`（同样重建 split.conf + 可能 restart）
- 底部「保存并应用」→ `m.apply_on_parse()` :2273 → 同一个 `ds.apply_domains()`

v0.14.0 已因「两个同名按钮」修过一次（:1563 有记录），说明按钮重复是**反复出现的模式**。

**③ 同一个判定有两套独立实现，结论可能矛盾**

| 判定 | 概览侧 | 域名侧 |
|---|---|---|
| servers-file 就绪 | 自检第 19 项（`dnschain-selftest:770-831`） | `ds.serversfile_ready`（`dnschain.lua:1138-1214`） |
| health.state 解析 | 自检第 20 项（`dnschain-selftest:834-865`） | `ds.health_rows`（`dnschain-health:76-154`） |

页面可能一边显示「已就绪」、自检一边报 FAIL。

**④ 结构缺陷：「已录入清单」挂错 section**

`_domains_list`（:889）用 `o = s:option` 沿用了上一个 `s`（:870 的「自定义域名·国外」），
所以它实际渲染在**国外** section 内。它展示的是国内+国外**两个清单的合并只读视图**，
挂在「国外」下面语义是错的，`SECTION_TAB` 也因此没有它的键。

**⑤ 概览首屏四块内容都在回答「链路通不通」**

| 块 | 行号 | 数据源 | 形态 |
|---|---|---|---|
| 解析链路 | :304 | `ds.chain_snapshot()` :307 | 手写 SVG 1120×372 |
| 实时诊断链路 | :533 | `ds.selftest()` :536（20 项→8 阶段） | 思维导图 |
| 链路指标 | :622 | `ds.chain_snapshot()` :625 | 数值 |
| 组件状态 | :675 | `port_listening`/`port_owner`/`is_dnsproxy`/`ssr_ipv6`/`cache_stats` | 表格 |

「解析链路图」与「组件状态表」数据源几乎相同，只是图/表之别 —— 这是首屏最实在的重复。

---

## 2. 决定

**核心判据（后续加功能必须遵守）**：

> **概览放「结果」——现在通不通、哪里坏、怎么修。
> 域名放「资产与参数」——哪些域名归哪边、怎么判、阈值多少。**

### 2.1 tab 结构：保持 6 个，内容重排

**不减少 tab 数量。** 原方案考虑过压到 5 个，但「观测与阈值」是纯配置输入（7 个 UCI 键），
并入概览会让概览变成「看板 + 配置」混装。它改的是**域名怎么被探测**，语义属域名。

| tab | 内容（重排后） |
|---|---|
| **概览与诊断** | 结论徽标 + **合并后的链路图** + 图下折叠明细 + 自检 + 改道状态 + 改道明细 + 操作（全部按钮） |
| **域名** | 自定义域名·国内 + 自定义域名·国外 + **已录入清单（独立 section）** + 分诊规则图 + 单域名解释 + 分诊结果明细 + 观测与阈值 |
| 解析 / 分流 / 代理 / DHCP | 不变 |

### 2.2 按钮归位

- 「一键归一」与「手动导入名单」**合并为一个**（删「手动导入名单」，或改为真正只做名单导入而非 reconcile）
- 「立即分诊未知目标」**留在概览**，但概览增加**一行摘要**（共 N 条 / 已入库 M），明细表留域名
- 「立即探测一轮」「清空改道状态」跟着「改道状态」搬进概览
- 「重建分流规则并生效」保留在域名（它是域名配置的生效入口），但需在概览的操作区注明它存在

### 2.3 两张链路图合并为一张

`解析链路`（拓扑）+ `实时诊断链路`（20 项按 8 阶段重分组）**合并为一张带状态徽标的拓扑图**。

理由：用户要的是「一眼看出哪里有问题」。两张图并列要求用户在脑中做两次映射；
一张「拓扑 + 每节点状态徽标」正好是这个效果。合并后概览首屏只剩 **1 张图 + 1 个结论徽标**。

`组件状态表` 保留但**降级为图的下钻**（`dc-details` 折叠，JS 已支持，`dnschain.js:260-261`），
「链路指标」并入该折叠区。

### 2.4 动态诊断：不写死文案

**决定：不为每个失败分支手写因果文案。**

`dnschain-selftest` 有 **60 个 emit 调用点**、20 个检查项。若给每个 FAIL 分支手写
`cause`/`impact`/`fix`，等于把「写死」从 Lua 搬到 shell，且每处都可能与实际不符；
更糟的是**新增检查项时必然漏写**，于是新失败静默无提示。

**改用「证据 → 症状」规则推导**：`evidence`（emit 第 4 参数）本身已是动态的真实探测结果，
缺的不是原因文本，而是从证据到症状的**推导**。推导规则约十余条，放在新模块 `diagnosis.lua`。

### 2.5 自动生成分支（用户明确要求）

用户要求：「没有在链路分支的，自动生成分支」。三种情况全部覆盖：

| 情况 | 现状 | 处理 |
|---|---|---|
| **A. 新增检查项（编号 21+）未加入 STAGES** | 静默丢失，图中看不到 | 归入**兜底阶段「其他检查」**，并标注「未归入链路阶段（共 N 项）」 |
| **B. 证据串匹配不到任何规则** | 无提示 | 输出「未识别的失败模式」+ 证据原文 + 建议单独跑 `dnschain-selftest` |
| **C. 阶段 FAIL 但 evidence 为空** | 显示空 | 显示「证据缺失」+ 该阶段检查项编号清单 |

**边界必须诚实**：情况 B 宁可说「我不认识这个失败」，也不生成看似合理但可能错误的诊断 ——
错误诊断比没有诊断更糟。

### 2.6 时间戳与序列号

用户要求「加入时间戳和序列号尽量详细」。

**决定：时间戳由 `dnschain-selftest` 输出真实探测时刻**，不是页面渲染时刻。

理由：时间戳的价值在于判断「这份结论有多旧」——尤其配合 v0.16.5 引入的 10 秒 TTL 缓存，
用户必须知道看到的是缓存还是刚跑的。页面渲染时刻没有诊断价值。

格式（单项行不变，避免破坏现有解析）：

```
SUMMARY PASS=x FAIL=y SKIP=z AT=2026-10-24T18:30:00 DUR=1.2s RUN=42
```

- `AT`：本次自检运行时刻（`date '+%Y-%m-%dT%H:%M:%S'`，BusyBox 兼容）
- `DUR`：总耗时
- `RUN`：轮次号（递增计数落 `/var/run/dnschain/.selftest-run-no`）

页面解析 `AT`/`DUR`/`RUN` 显示在结论徽标旁，便于对比「上次 vs 这次」。

---

## 3. 被否决的方案

### 3.1 压到 5 个 tab，概览吞下观测与阈值

否决理由：观测与阈值是纯配置输入（7 个 UCI 键），并入概览会让概览变成「看板 + 配置」混装，
破坏 §2 的核心判据。

### 3.2 首屏折叠链路图，只留结论徽标

用户明确否决：「我就是想用图来更直观看到链路问题，所以我需要直接展开看板，可以快速观测哪里有问题」。

修正理解：图的价值是**定位**，不是阅读长文本。因此图默认展开，
原因信息放图下折叠区（默认展开第一处失败）。

### 3.3 给 60 个 emit 全部加 cause/impact/fix 三字段

否决理由见 §2.4：等于把写死搬到 shell，且新增项必然漏写。

### 3.4 把两张图并列保留，只改标题

否决理由：两张图并列要求用户在脑中做两次映射（「图 A 的那段」↔「图 B 的那个阶段」），
与「一眼看出哪里有问题」的目标相反。

---

## 4. 实施顺序

**分两步，不合并。**

### 第一步：修独立 bug（改动极小，可立即验证）

1. 合并「一键归一」与「手动导入名单」重复入口
2. 修「已录入清单」挂错 section（拆为独立 section，加进 `SECTION_TAB`）

理由：重复按钮是独立缺陷，与 tab 边界无关。混在一次大改里，出问题时无法判断是重构引入的
还是按钮本身的问题。v0.14.0 已因同类问题踩过一次（`general.lua:1563`）。

### 第二步：tab 重构

3. 新建 `diagnosis.lua`（证据→症状规则 + 兜底阶段 + 三种自动生成分支）
4. 改 `dnschain-selftest` 输出 `AT`/`DUR`/`RUN`
5. 合并两张链路图为一张（`diagrams.lua` 几何改动）
6. `SECTION_TAB` / `TAB_LABELS` / `dnschain.js` 的 `TAB_ORDER`（:46）三处同步
7. 按钮归位
8. 文档联动（§9）

⚠️ **`TAB_ORDER` 硬编码在 JS（`dnschain.js:46`）**，改 tab 必须同时改三处：
`SECTION_TAB`（Lua）、`TAB_LABELS`（Lua）、`TAB_ORDER`（JS）。漏改 JS 会导致 tab 顺序错乱或缺失。

⚠️ **另有一条更隐蔽的漏改：section 忘了登记进 `SECTION_TAB`。**

`dnschain.js` 的 `activate()` 对未归组 section 的处理是：

```js
sections.forEach(function (sec) {
    /* 未归组的 section 始终显示 —— 避免新增 section 后莫名消失 */
    if (!sec.tab) { sec.el.hidden = false; return; }
    sec.el.hidden = (sec.tab !== id);
});
```

这段兜底本意是「新增 section 忘了登记时不要让它消失」，但代价是它**在所有
tab 里都显示**。与「tab 顺序错乱」不同，这种漂移**看起来不像 bug** ——
用户只会在每个 tab 都看到同一块内容，以为那是刻意设计。

实测（v0.22.0）：把「DNS 分流状态」改名为「DNS 分流去向」时忘了改
`SECTION_TAB` 的键（改名后旧键变死键、新标题无键），结果这张导图在
状态/域名/上游/名单 **4 个 tab 全都渲染**。

**因此改 section 标题时，除了改 `m:section()` 的标题文本，必须同步改
`SECTION_TAB` 的键** —— 两处的键是「translate 之后的标题文本」，逐字匹配。

`tools/verify-dnschain-domains.sh` §13 已加断言：
逐个检查关键 section 是否在 `SECTION_TAB` 里出现过 `[translate("标题")]`。

**排查这类问题的正确方法**：不要用 `svg.offsetParent !== null` 判断可见性 ——
`SVGElement` **没有** `offsetParent` 属性，该表达式恒为 `true`，
会得出「所有 tab 都可见」的假象（本次排查第一轮就栽在这里）。
应改用 `getBoundingClientRect().height > 0` 并手动回溯祖先的 `hidden`。

---

## 5. 后果

### 5.1 好的后果

- 概览首屏从 4 块「链路通不通」降为 1 张图 + 1 个徽标
- 动线不再断裂（点分诊按钮就在概览看到摘要变化）
- 消除两套 servers-file / health.state 判定实现，结论不再矛盾
- 新增检查项不会再从图中消失
- 时间戳让用户能判断结论新旧（配合 TTL 缓存）

### 5.2 代价与风险

- **改 `dnschain-selftest` 输出格式**：`SUMMARY` 行加三个字段，需同步改解析端
  （`dnschain.lua` 的 `_parse_selftest`、`tools/check-dnschain-lua.py` 的桩数据）
- **合并链路图需要重画几何**：`diagrams.lua` 的 `live_diag_map` 要改成带徽标的拓扑，
  需新增几何断言（现有 `render-dnschain-diagrams.py` 有 70 条）
- **兜底阶段让图高度运行时可变**：几何断言需覆盖 8 阶段与 9 阶段两种形态
- **改名连锁**：「解析链路」→ 合并图、「判定链路」→「分诊规则」，
  会改 PO 文案与 `verify-dnschain-domains.sh` §9 钉着「判定链路」的断言、
  `check-dnschain-lua.py` 的 aria-label 断言

---

## 6. 验证要求

改完必须跑（按 AGENTS §4.0）：

```sh
sh tools/verify-dnschain-domains.sh          # 146 条契约断言（CI 也跑）
python3 tools/check-dnschain-lua.py          # 156 条（需 PYTHONIOENCODING=utf-8）
python3 tools/render-dnschain-diagrams.py    # 70 条
python3 tools/extract-dnschain-i18n.py       # 中文文案完整性
sh tools/verify-dnschain-ci-sim.sh           # 复现 CI 的目录场景
```

**新增断言（本次必须加）**：

1. `SECTION_TAB` 里每个 section 标题都能在 `general.lua` 找到对应 `m:section` 声明
2. `TAB_ORDER`（JS）与 `TAB_LABELS`（Lua）的 tab id 集合一致
3. `diagnosis.lua` 的兜底阶段存在，且 `STAGES` 未覆盖的编号会被归入
4. 合并图在 8 阶段与 9 阶段两种输入下都合法（rect 不越界、文字不溢出）
5. 两个重复按钮已合并（断言 `M.import_lists` 与 `M.reconcile_now` 不再并存）
6. 「已录入清单」有独立 section 且已进 `SECTION_TAB`

**真实环境验证**：路由器 `192.168.3.254` + 真实浏览器视觉验证（前端铁律）。

---

## 7. 术语（同步进 GLOSSARY.md）

| 术语 | 含义 | 代码落点 |
|---|---|---|
| **链路拓扑图** | 合并后的唯一链路图：8（或 9）个阶段节点 + 状态徽标 | `diagrams.lua` 新函数 |
| **兜底阶段** | STAGES 未覆盖的检查项归入的伪阶段「其他检查」 | `diagnosis.lua` |
| **未识别的失败模式** | 证据串匹配不到推导规则时的诚实输出 | `diagnosis.lua` |
| **自检轮次号** | 每次 `dnschain-selftest` 运行的递增序号 | `.selftest-run-no` |

---

## 8. 待确认

无。设计树已走完 21 个决策点。

---

## 9. 文档联动清单

**改结构必须逐条核对本表。** 完成一项打勾，未打勾即视为本次重构未完成。

| # | 文件 | 章节/位置 | 要改什么 | 状态 |
|---|---|---|---|---|
| 1 | `docs/adr/0007-tab-structure.md` | 全文 | 本文件；状态已改为「已实施」 | ✅ |
| 2 | `docs/packages/luci-app-dnschain.md` | section 清单与计数 | 已重算为 **21 个有标题的可见 section + 1 个元数据**，§4.1 表格与行号全部更新 | ✅ |
| 3 | `GLOSSARY.md` | 术语表 | 新增「页面诊断」一节，四个术语各带落点与反例 | ✅ |
| 4 | `AGENTS.md` | §1 工具表、§4.0 验证命令 | 已更新为 159 / 156 / 70，§4.0 验证命令同步 | ✅ |
| 5 | `docs/README.md` | ADR 索引 | 已在「按任务找文档」新增一行「改页面 tab 结构」 | ✅ |
| 6 | `docs/runtime/dns-chain.md` | 页面结构描述（若有） | 核对：该文件讲运行时链路，不含页面 tab 结构，无需改 | ✅ |
| 7 | `docs/operations/verification.md` | 验证步骤 | 核对：验证步骤按功能描述，未提 tab 名，无需改 | ✅ |
| 8 | `docs/routes.md` | 路由登记 | 已确认：tab 是前端 JS 分组，路由 `admin/services/dns_chain` 不变，**无需改** | ✅ |
| 9 | `CHANGELOG.md` | 新版本段 | 已写 v0.18.0 完整段（含取证、五项改动、验证数据） | ✅ |
| 10 | `package/luci-app-dnschain/po/zh-cn/luci-app-dnschain.po` | 全文 | 已用 `--write` 补齐，463 条无缺失 | ✅ |

⚠️ **改 tab 名或 section 名时，额外检查这三处钉着文案的断言**，漏改会永久失败：

- `tools/verify-dnschain-domains.sh` §9（钉「判定链路」等字样）
- `tools/check-dnschain-lua.py`（钉 aria-label，如「未知目标分诊链路图」）
- `tools/render-dnschain-diagrams.py`（钉图内节点文案）
