# dnschain 硬约束全表（52 条）

本文件是 `AGENTS.md` §4 的完整版。`AGENTS.md` 只保留最容易踩的前若干条与指针，**全表以本文件为准**。

每条约束的「违反后果」都来自实测或代码推演，改这一块之前逐条读。

---

## 0. 三个必须先记住的概念

混了就必然改错：

| 概念 | 谁决定 | 存哪 |
|---|---|---|
| **归属**（class） | 配置 + 名单（静态） | UCI + `/var/etc/dnschain/db-domains.txt` |
| **首选**（preferred） | 归属的确定性映射 | 计算得出 |
| **当前**（active） | 健康探测（动态） | `/var/run/dnschain/health.state` |

---

## 1. 链路形态（v0.10.0 起）

```
dnsmasq:53（唯一缓存 + 唯一分流层）
  ├─ 默认              → 127.0.0.1#5353  dnsproxy 实例 1（阿里 DoT/DoH，直连）
  ├─ server=/国外域名/ → 127.0.0.1#5336  dnsproxy 实例 2（DoH，经 :1234）
  └─ nftset=/国外域名/4#inet#ss_spec#blacklist   解析结果写入代理 IP 集
```

`chinadns-ng` 已于 v0.10.0 移除（`docs/adr/0005-remove-chinadns-ng.md`），`:5335` 必须无监听。

---

## 2. 约束 1–12：DNS 分流基本形态

| # | 约束 | 违反的后果 | CI 断言 |
|---|---|---|---|
| 1 | **缓存只在 dnsmasq 一层**，`dnsproxy.args` / `dnsproxy-foreign.args` / `files/etc/config/dnsproxy` 都不得启用缓存 | 同一域名出现两份答案（实测：经 `:53` 与直连 `:5353` 返回不同 IP） | 有 |
| 2 | **国外上游必须是 DoH（443），不能是 DoT（853）** | 落地节点到 853 全部 `peer sent close notify` → 国外域名全无结果 | 有 |
| 3 | **分流必须由 `dnsmasq` 的 `server=/域名/` 承担，不能用 dnsproxy 的 `[/域名/]`** | 17767 条 `[/域名/]` 会让 dnsproxy 为每域名注册一条 reserved 上游，资源耗尽 → `connection timed out` | 有 |
| 4 | **不得过滤 `xn--`** | dnsmasq 原生支持 punycode；过滤后 58 条 IDNA 域名失去分流，全部解析失败 | 有 |
| 5 | **不配 `--fallback`、不用 `--ipv6-disabled`** | 前者回落污染上游并缓存；后者连国内 AAAA 一起砍 | 有 |
| 6 | ~~`-N tag:gfw` 不能写成裸 `-N`~~ | **作废**（chinadns-ng 已移除） | — |
| 7 | **不得出现 `114.114.114.114`** | 明文上游绕过加密链路 | 有 |
| 8 | **`init.d/dnsproxy` 必须保留 `dnschain_takes_over` 让位逻辑** | 两个 procd 实例抢 `:5353`，后起的静默失败 | 有 |
| 9 | **`applechina.conf` 必须保持 173 条且全部指向 `127.0.0.1#5353`** | 明文 `114.114.114.114` 绕过 dnsproxy，Apple 域名不走加密链路 | 有 |
| 10 | **两个实例端口不能相同**（`entry_port` ≠ `foreign_port`） | 后起的实例静默失败 | 有（init 的 preflight） |
| 11 | **SSR-Plus 的 `ipv6_support` 必须为 1** | 国外域名拿到真实 AAAA 却直连 → 被 RST | 有（reconcile + selftest 第 7 项） |
| 12 | **`dnsmasq.filter_aaaa` 必须为 0** | 连国内 AAAA 一起砍（v0.10.0 起国外 AAAA 保留） | 有（selftest 第 7 项） |

另有两条通用约束：

- **`dnschain` 不删、不重写 SSR-Plus 生成的任何文件**（`gfw_list.conf` 里的 `server=/域名/#5335` 保留原样；框架自己生成 `dnschain-split.conf` 指向 `:5336`。实测 dnsmasq 对同一域名的多条 `server=` 会全部作为候选，`:5335` 无监听时自动重试其它候选）。
- **所有脚本必须 POSIX sh（dash）兼容**（CI 用 `sh -n` + 禁 bash 语法双检）。

---

## 3. 约束 13–52：域名归属与自动改道（v0.13.0）

设计依据：`docs/adr/0006-domain-routing-and-reroute.md`。
落地校验：`sh tools/verify-dnschain-domains.sh`（**129 条断言，CI 会跑**，`build-openwrt.yml:449`）。

| # | 约束 | 违反的后果 | 断言 |
|---|---|---|---|
| 13 | **自定义列表优先于 gfw 名单**（`custom-*` 先于 `db-foreign` 判定） | 用户写了「走直连」却不生效，且无从解释 | 有 |
| 14 | **未覆盖域名的首选链必须是 `domestic`** | 与 dnsmasq 默认上游不一致 →「不配置」与「配置了」行为不同 | 有 |
| 15 | **同一个域名只能有一处 `server=` 声明**：观测域名必须从静态片段里排除 | dnsmasq 把两条当**候选**（不是覆盖）→ 改道退化成随机走一条，两条链都通时完全看不出来 | 有（selftest 第 18 项） |
| 16 | **改道只走 `--servers-file` + SIGHUP，绝不 restart dnsmasq** | 改道可能每分钟发生，restart 每次约 3 秒解析中断 | 有（改道循环内禁 restart） |
| 17 | **`dhcp.@dnsmasq[0].serversfile` 必须下发且进程真带 `--servers-file`** | 只写文件不生效：页面显示「已改道」，实际没生效 | 有（selftest 第 19 项 + 页面「改道通道」） |
| 18 | **超时状态必须走 stdout，不能靠函数内变量** | `out=$(f)` 在子 shell 里跑，父 shell 读不到变量 → 超时被静默当成「返回空」 | 有 |
| 19 | **超时必须用完成标记文件，不能只用 `kill -0` 判活** | 子进程退出成僵尸，`kill -0` 仍成功 → 白等满整个超时 | 有（dash 单测含超时用例） |
| 20 | **`nftset` 目标集必须先 `nft list set` 探测再写** | SSR-Plus 未启用时 `ss_spec` 表不存在，dnsmasq 每解析一个域名都写集合失败、日志刷错 | 有 |
| 21 | **页面不得嵌套 `<form>`**（CBI 已把整页包在 `<form method="post">` 里） | 浏览器丢掉内层标签 →「解释」按钮实际提交外层表单（= 触发保存） | 有 |
| 22 | **同一页每个 SVG 的 marker id 前缀必须唯一**。判定链路图由**同一函数渲染两次**（概览 tab + 域名 tab），必须由调用方传不同的 `id_prefix`（`dcrt-ov` / `dcrt-dm`），状态图默认 `dcst` | CBI 的 tab 是 CSS 隐藏、**不是懒加载**，两个 tab 都进同一份 HTML。id 是文档级全局的，同名则 `url(#dcrt-a-ok)` 全部解析到第一个定义 —— 实测修复前有 5 组重复 id，配色一变就静默串掉，浏览器不报错 | 有（契约 4 条 + 图示 3 条） |
| 23 | **图示动态文本必须 HTML 转义** | 域名或原因含 `& < >` 时整张图解析失败（页面一片空白） | 有 |
| 24 | **`[[:space:]]` 不是 `[[ ]]`**：CI 的 bash 语法断言必须写成「`[[` 后紧跟空白」 | 直接 `grep '\[\['` 会命中 POSIX 字符类 → CI 永远红（v0.13.0 实测踩过） | 有 |
| 25 | **UCI section 名在文件内必须全局唯一**（与类型无关） | `config domains 'foreign'` 与 `config upstream 'foreign'` 同名 → uci 报 `section of different type overwrites`，**整个配置文件读不出来**，页面空白 + 服务起不来 | 有 |
| 26 | **`servers-file` 必须放在 ujail 已挂载目录**（`/var/run/dnsmasq/`），且文件 `0644` | dnsmasq 降权到 uid 453 运行，白名单外的路径**既不报错也不生效** → SIGHUP 成功、日志干净，改道却完全没发生 | 有（selftest 第 19 项） |
| 27 | **`dc_dnsmasq_pid` 必须选「持有 :53 socket」的进程**，不能取 `pidof` 第一个 | `pidof dnsmasq` 返回 3 个 PID，第一个是辅助子进程（`wchan=anon_pipe_read`、5 个 fd），对它 SIGHUP 是空操作 | 有 |
| 28 | **排除文件为空时不得直接 `grep -Fvxf`** | BusyBox `grep -Fvxf <空文件>` 返回 rc=1 且**输出零行** → 把输入全吞掉 → 分流片段变 0 字节 → preflight 拒绝启动 | 有（`dc_exclude`） |
| 29 | **归属判定必须做后缀匹配**（与 `server=/域名/` 语义一致）；自定义列表保持精确匹配 | 名单只写 `google.com` 时 `www.google.com` 被判 `uncovered` → 首选 domestic → 改道拉去直连 → **拿到污染答案**（实测 `31.13.92.37`，是 Facebook 的 IP） | 有 |
| 30 | **探测函数必须支持显式端口**，不能只认链路名 | 传 `127.0.0.1#59999` 会落到兜底分支探 `:5353`（活的）→ 死端口判为 `OK` → 「链路挂了却不改道」 | 有 |
| 31 | **改道等待期间不得更新 `last`**（用 `dc_health_write_keep_last`） | 每轮刷 `last=now` → `now-last` 恒为 0 → `min_dwell` 永不满足 → **回切被永久阻塞**（实测 ok 计数涨到 12、阈值 3，状态一直 `recover-wait`） | 有 |
| 32 | **被 `require` 的模块文件不得依赖全局 `translate`**，必须 `require "luci.i18n"` | 只有 CBI 模型文件享有 dispatcher 注入；模块里写裸 `translate` 会在 `cfgvalue()` 期间抛 nil value → **整页 500**。本地测试预置了 `translate` 桩，所以本地全绿、路由器 500 | 有 |
| 33 | **清缓存必须用 `dc_dnsmasq_pid`（按 `:53` socket 反查），不得用 `pidof dnsmasq` 第一个**。Lua 侧只调 `dnschain-health flush`，不自己找 PID | `pidof dnsmasq` 返回 3 个 PID，**第一个是 ujail 辅助子进程**（实测 `wchan=anon_pipe_read`、5 个 fd、0 个 `socket:53`）。对它 SIGHUP 是**空操作**，按钮点了完全无效，页面却报「已清空」——静默失效 | 有（契约 3 条） |
| 34 | **`dc_health_cycle` 必须有互斥锁**（`mkdir` 原子锁 + 死锁自动清理） | daemon 每 `interval` 秒跑一轮，页面「立即探测一轮」随时可触发。并发时 `dc_health_upsert` 的「读旧文件 → 过滤 → 写临时 → mv」不是原子的，后完成的进程会用少了对方新增行的副本覆盖 → **状态文件丢行** → 页面汇总对不上 | 有（契约 1 条） |
| 35 | **状态文件写盘只能有一处实现**（`dc_health_upsert`） | `dc_health_write` 与 `dc_health_write_keep_last` 原先各复制一整段写盘逻辑，只差 `last` 取值。改一处忘另一处 → 两个入口写出**格式不同**的状态文件，而 `status`/页面都按 7 字段解析 | 有（契约 1 条） |
| 36 | **selftest 缓存指纹必须覆盖所有影响结论的输入**（端口/进程/`ss_spec`/开关 + `filter_aaaa` + `ipv6_support` + gfw 行数 + 上游列表） | 漏项的症状是「改完配置看自检，60 秒内还是旧结论」，用户以为改动没生效。另：BusyBox **没有 `stat`**，取 mtime 必须用 `date -r <file> +%s` | 有（契约 2 条） |
| 37 | **tab 切换必须修正滚动位置** | 各 tab 高度差数倍（分流约 3000px、概览约 900px）。只切 `hidden` 不管滚动时，从长 tab 滚到底再切短 tab，`scrollY` 仍停在旧值 → 屏幕只剩页脚，看起来像「页面空了」 | — |
| 38 | **`dc_health_cycle` 的取锁必须在「实例就绪检查」之后** | 原顺序是「取锁 → 检查实例 → 不就绪就 `return`」，那条 `return` 不释放锁。daemon 是常驻进程、`$$` 恒定 → 某轮撞上 dnsproxy 未监听就永久自锁，后续每轮都打印「SKIP 已有一轮探测在跑」→ **改道功能完全停止而日志显示正常**。实测：同进程连跑 3 轮，第 2/3 轮全被自己的锁挡住 | 有（契约 1 条） |
| 39 | **禁止 `n=$(grep -c PAT f \|\| echo 0)`**。无匹配时 `grep -c` 既打印 `0` 又返回 rc=1，`\|\| echo 0` 再追加一个 → 得到 `"0\n0"`，`[ "$n" -eq 0 ]` 算术比较报错返回假 → **判据恒假**。用 `dc_count_lines`（awk 实现，恒输出单个整数） | 实测 `v=$(grep -c '^x' /tmp/t \|\| echo 0); [ "$v" -eq 0 ]` → rc=2。后果：nftset 归零自愈永不触发、`dc_prev_nftset_count` 返回脏值 | 有（契约 1 条） |
| 40 | **nftset 归零自愈必须在 `reconcile_invariants` 里**，不能放 `reconcile_lists` | `reconcile_lists` 在「名单指纹未变」时直接 `return 0`，而 nftset 归零与名单无关（SSR-Plus 重建窗口造成）→ 放那里等于**永不检查**。实测确认原位置从不触发 | 有（契约 1 条） |
| 41 | **一次配置应用只能重启 dnsmasq 一次**。`reload_service` 用标记文件 `/var/run/dnschain/.dnsmasq-dirty` 抑制中间步骤，末尾统一重启 | 原调用链 `reload_service → reload_dnsmasq` + `stop → stop_service → reload_dnsmasq` + `start → start_service → reload_dnsmasq` = **3 次**（实测主进程出现 4 个不同 PID），每次约 3 秒中断 → 一次保存断 9 秒以上。更糟的是中间那次跑在「分流片段已被写成停止注释」的状态下。⚠️ 不能用环境变量传递：procd 的 stop/start 会重新 exec，变量跨不过去（实测只减到 2 次） | 有 |
| 42 | **`stop_service` 必须清空 `watch.servers`，且在重启 dnsmasq 之前** | 该文件在 tmpfs、不会随 stop 消失，且 `serversfile` 仍指着它。stop 后重启 dnsmasq 会重读它 → 里面的 `server=/x/127.0.0.1#5336` 指向已停端口 → **关掉框架后这些域名稳定解析失败**，日志干净。清成注释占位而非删除（同 `update_dot_reject` 的理由） | 有 |
| 43 | **`uci-defaults` 里的 `serversfile` 必须引用库常量 `DNSCHAIN_WATCH_SERVERS`**，不得硬编码 | 原写死 `/var/etc/dnschain/watch.servers`，而库与 init 用 `/var/run/dnsmasq/`。平时 init 会纠正，但服务未启用/`preflight` 失败/首刷后先看页面时 UCI 里就是错路径 → dnsmasq（uid 453）读不到该目录，**既不报错也不生效** | 有（契约 1 条） |
| 44 | **`dc_run_timeout` 成功路径必须删 `.done` 标记文件** | 原只在入口 `rm -f`，而 `mktemp` 每次新路径 → 入口删不到别人的；成功返回两处又只 `wait`+`echo 0`+`return`。实测每次成功探测泄漏 1 个文件；健康 cycle 一轮约 48 次 × 每 60 秒 → **每天约 7 万个空文件**堆进 tmpfs，最终 `mktemp` 失败 → 探测全 FAIL → 误判双链都挂 | 有 |
| 45 | **页面配置项必须有 shell 消费者，否则明示「仅作记录」** | 实测 11 个键（`cache.enabled`/`cache.size`/`lists.black_source`/`lists.import_interval`/`selftest.auto_rollback`/`selftest.interval`/`main.intercept_doh`/`foreign.via_proxy`/`foreign.cert_verify`/`aaaa.*`/`ssr.mode`）有 Lua 定义但零消费者 —— 用户改了不生效，且无从察觉。`cache.size` 与 `lists.black_source` 已接上消费者；其余在页面明示「仅作记录」 | 有（契约 1 条） |
| 46 | **Lua 里禁止用 `[^—]` 这类「排除多字节字符」的字符类**。Lua 字符类按**字节**工作，`[^—]` 实际排除 `E2 80 94` 三个字节 | `—`(U+2014) 的 UTF-8 是 E2 80 94。凡名称含 `一`(E4 B8 80)、`上`、`下` 等第三字节为 0x80 的常用汉字，匹配**直接失败**。实测自检 20 项里 **7 项**解析失败（整行进 name、detail 为空），另有 10 项 name 尾随空格。改用 `find(sep, 1, true)` 字节精确匹配 | 有（lua 断言） |
| 47 | **URL 端口解析必须先判方括号 IPv6** | `:%[?([0-9]+)%]?$` 对不带端口的 IPv6 字面量会把末段当端口：`https://[2606:4700::1111]/` → `1111`（应 443）、`tls://[2400:3200::1]` → `1`（应 853）。后果：端口校验误拒或误判合规，国外解析静默失败 | 有（lua 断言） |
| 48 | **图示的未知/空 `state` 必须归入 `unknown` 档，保证行数守恒** | 原 `r.state or "unknown"` 只兜 nil，空串与未知值会落进不在 `STATUS_ORDER` 的键 → `present` 与 `n_all` 都不遍历它 → **域名在导图里凭空消失**，根节点还写「观测 1 个」。实测 3 行进 1 个 | 有（图示断言） |
| 49 | **`status_layout` 与 `status_map` 必须共用同一套布局计算**（`layout_plan`） | 原两者口径不同：`status_layout` 用 `pairs(rows)` 数**行数**，`status_map` 画**档位数**（最多 5 档，both-bad 恒占一档）；`NH` 也一个硬编码 60、一个随 hint 折行增长。实测 5 档各 1 个域名：实际高 386，报告 406 —— CI 几何断言验的是不存在的布局 | 有（图示断言） |
| 50 | **「分流规则条数」必须数 `dnschain-split.conf` 的 `server=` 行**，不是 `foreign-split.conf` 的行数 | 后者是「数据库国外 − 自定义国内 − 观测域名」的**纯域名清单**（不含 `server=` 前缀），页面标签「条 server=/域名/」名不副实。实测加 1 个自定义国外域名后：前者 23714、后者 23715，页面数字偏小 | 有（lua 断言） |
| 51 | **`apply` 的输出必须解析全部 5 条正常出口 + `ERROR=` 失败出口** | `cmd_apply` 出口：`DNSMASQ=restarted/skipped×2/sighup/unchanged` + `ERROR=`。原实现只处理 `restarted`，最常见的 `unchanged`（只改阈值、片段未变）用户点保存后**看不到任何提示**；按钮侧反过来无条件拼 `✓`，`ERROR` 时显示「✓ 已应用」+ 错误正文 | 有（lua 断言） |
| 52 | **`dc_get` 的第一个参数是 UCI section 的「名字」，不是「类型」**。`config ssr 'compat'` 要写 `dc_get compat mode`，不是 `dc_get ssr mode` | 配置文件里 `config <类型> '<名字>'`，而 `uci get dnschain.<名字>.<选项>` 只认名字。写类型时查的是「名字恰好等于该类型的 section」，通常不存在 → 恒返回空 → 恒走兜底值 → **用户的选择被静默推翻**。实测：`compat.mode=7` 时 `dc_get ssr mode` 返回空、函数返回 `0`；改 `dc_get compat mode` 才返回 `7`。本仓库已两次踩（`upstream`→`cn/foreign`、`ssr`→`compat`） | 有（契约 5 条，含反向断言） |

---

## 4. 改道判定的一句话规则

**首选链不通、且另一条链通 → 切到另一条。**

两条需求规则（国外不通改直连 / 国内不通改代理）是这同一判定的两个实例，
因为首选已由归属决定。**双链都不通时不改道** —— 那是链路故障，
改道只会掩盖问题，页面标 `both-bad` 红档。

---

## 5. 改这一块之后必须跑

```sh
sh tools/verify-dnschain-domains.sh          # 129 条契约断言（CI 也跑，build-openwrt.yml:449）
python3 tools/check-dnschain-lua.py          # 121 条：语法 + 模型 + 真实渲染页面
python3 tools/render-dnschain-diagrams.py    # 44 条：图示纯几何
python3 tools/extract-dnschain-i18n.py       # 中文文案完整性（缺译会中英混排）
sh tools/verify-dnschain-ci-sim.sh           # 复现 CI 的目录场景
```

⚠️ **只有第一个被 CI 调用**。其余四个是纯本地工具，`build-openwrt.yml` 里零调用点 ——
「CI 会拦住」这个假设对它们不成立，必须自己跑。

Windows 上跑 Python 脚本要设 `PYTHONIOENCODING=utf-8`，否则脚本里的 `✓` 会触发
`UnicodeEncodeError: 'gbk' codec`。

`tools/check-dnschain-lua.py` 用 lupa（真实 Lua 解释器）**执行**每个
`cfgvalue()`，而不只是 `luac -p` —— 拼错的方法名、nil 索引、未定义变量
都只在渲染时才暴露，语法检查抓不到。

---

## 6. 两条实测补充

**853 拒绝的优先级**（2026-10-20，路由器上）：裸 chain + `priority -151` 单独 `nft -f`
会报语法错误（缺 table 上下文，属预期）；经 fw4 include 到 `table inet fw4` 内部后
**语法有效**，`nft list` 显示 `priority mangle - 1`，即先于 `ss_spec_mangle` 的 `mangle(-150)`。

**`dns-forward-max` 必须显式抬高**：dnsmasq 默认仅 **150** 个并发转发槽，
而本固件 `noresolv=1` 无兜底、且有 23701 个域名指向 `:5335`。
MosDNS 上游挂死时这些查询会在槽内挂到超时（实测单查询挂满 15 秒），
槽位耗尽会连带拖垮**国内**解析。现值为 `1024`，
写在 `files/etc/uci-defaults/99-gaming-optimize`；验证方式是看
`/var/etc/dnsmasq.conf.cfg01411c` 里是否出现 `dns-forward-max=1024`。

---

## 7. 已删除的例外清单（勿加回）

v0.8.0 删除了 dnsproxy 的「24 个硬编码国外域名 → `127.0.0.1:5335`」例外清单。
该清单 24/24 全部命中 `gfw_list.conf`，属重复声明；而 SSR-Plus **禁用**时
它是纯故障源（`:5335` 无监听 → `connection refused` → 回落 `1.12.12.12`
→ 污染答案，实测 `youtube.com → 31.13.92.37`、`wikipedia.org → 31.13.94.36`）。
**不要把它加回去。** 详见 `CHANGELOG.md` v0.8.0。
