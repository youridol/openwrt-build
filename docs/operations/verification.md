# 验证与排障

本文分两部分：仓库内可跑的本地校验（§1），以及路由器端的只读取证与排障顺序（§2–§6）。所有命令与结果都是本机实跑记录；命令是否存在于仓库已逐条核对。

## 1. 仓库内可跑的本地校验

### 1.0 运行环境

本机是 Windows + pwsh 7。两个注意点：

| 问题 | 现象 | 处置 |
|---|---|---|
| `sh` 不在 Windows PATH | `Get-Command sh` 返回空 | 用 WSL 的 `bash.exe`（`C:\WINDOWS\system32\bash.exe`）转调；其 `/bin/sh` 是 **dash**（`readlink -f /bin/sh` → `/usr/bin/dash`），与 CI runner 一致，可直接验证 dash 兼容性 |
| Python 默认 stdout 编码是 GBK | 脚本里有 `✓` 等字符时抛 `UnicodeEncodeError: 'gbk' codec can't encode character '\u2713'` | 先设 `$env:PYTHONIOENCODING='utf-8'` |

GBK 报错是实跑复现的（`python tools/check-dnschain-lua.py`，退出码 1），尾部输出：

```
Traceback (most recent call last):
  File "Y:\openwrt-build\tools\check-dnschain-lua.py", line 908, in <module>
    sys.exit(main())
  File "Y:\openwrt-build\tools\check-dnschain-lua.py", line 900, in main
    test_v0144_fixes()
  File "Y:\openwrt-build\tools\check-dnschain-lua.py", line 802, in test_v0144_fixes
    ok("应用按钮不再无条件打 ✓")
  File "Y:\openwrt-build\tools\check-dnschain-lua.py", line 36, in ok
    print("  ok   %s" % msg)
UnicodeEncodeError: 'gbk' codec can't encode character '\u2713' in position 18: illegal multibyte sequence
```

（第 802 行那条断言的中文在 GBK 控制台里显示为乱码，这是编码失败的另一面；断言原文是 `tools/check-dnschain-lua.py:802` 的 `ok("应用按钮不再无条件打 ✓")`。）

设了 `PYTHONIOENCODING=utf-8` 之后 `PASS=121 FAIL=0`。这个坑只在 Windows 上出现，CI 是 Linux 默认 UTF-8，看不出问题 —— 所以本地跑必须设。

### 1.1 `sh tools/verify-dnschain-domains.sh`

- 作用：域名分流与自动改道的契约校验，11 个分组（`tools/verify-dnschain-domains.sh:55`、`:64`、`:75`、`:95`、`:172`、`:398`、`:460`、`:568`、`:578`、`:787`、`:814`）。
- 实跑结果：**129 条 OK / 0 FAIL**，末行「域名分流与改道契约校验通过。」
- 退出码 0 = 全过（`:17`）；任一 FAIL 置 `rc=1`（`:40`）。
- 在仓库根直接跑即可，脚本自己 `cd` 到仓库根（`:20-21`）。
- CI 也跑它，但用 `../openwrt-build/` 前缀（`build-openwrt.yml:449`），因为那一步的 `working-directory` 是 `lede`。

### 1.2 `python tools/check-dnschain-lua.py`

- 作用：用 lupa（**真实 Lua 解释器**）跑语法检查 + 模型单测 + 真实渲染页面每个 `cfgvalue()`（`tools/check-dnschain-lua.py:3-15`）。
- 检查 3 个文件：controller、`dnschain.lua`、`general.lua`（`:23-27`）。
- 实跑结果：**PASS=121 FAIL=0**。
- 前置：`$env:PYTHONIOENCODING='utf-8'`（见 §1.0）。
- 为什么不用 `luac -p`：本机没有 luac，且静态检查抓不到「拼错的方法名、nil 索引、未定义变量」—— 那些只在渲染时暴露（`:5-6`）。

### 1.3 `python tools/render-dnschain-diagrams.py`

- 作用：两张思维导图（判定链路图 + 状态思维导图）的纯几何校验，并输出可打开的 HTML 预览（`tools/render-dnschain-diagrams.py:462`）。
- 实跑结果：**PASS=44 FAIL=0**，末行 `已输出 tools\out\dnschain-diagrams.html`。
- 输出路径由脚本决定；该 HTML 是生成物，已被 `.gitignore` 排除（`.gitignore:58-62`，规则为 `/tools/out/`）。
- 退出码：`0 if FAIL == 0 else 1`（`:667`）。

### 1.4 `python tools/extract-dnschain-i18n.py`

- 作用：从 4 个 Lua 文件提取 `translate()` 的中文，与 PO 比对，报告缺失（`tools/extract-dnschain-i18n.py:19-28`）。
- 实跑结果：`OK 无缺失（426 条中文文案已在 PO 中）`。
- 只报告不改写；`--write` 才追加缺失条目（`:10-12`）。

### 1.5 `python tools/check-trafficctl-i18n.py`

- 作用：校验 trafficctl 的中文翻译覆盖率；`--write-pot` 可重生成 pot 模板。
- 实跑结果：

```
界面字符串 376 条；po 502 条；pot 376 条
po 缺失 0；po 空译文 0；pot 缺失 0
中文翻译完整
```

### 1.6 `sh tools/verify-dnschain-ci-sim.sh`

- 作用：在本地复现 CI 的工作目录结构（`lede/` 与 `openwrt-build/` 同级），把 `files/` 复制进 `lede/`，再从 workflow 里**抽出** `Verify dnschain framework contracts` 的脚本体执行，最后补跑 `verify-dnschain-domains.sh`（`tools/verify-dnschain-ci-sim.sh:20-97`）。
- 实跑结果：末行「CI 模拟校验通过（真实 CI 应能通过）」，退出码 0。
- 为什么需要它：那段校验的 `working-directory` 是 `lede`，在仓库根直接跑会**误报通过或误报失败**（`:7-12`）。
- 它自带 Python UTF-8 兜底，因为 workflow 注释里有 `⚠️`（`:47-53`）。

### 1.7 `sh tools/verify-trafficctl-invariants.sh`

- 作用：trafficctl 本地不变量校验，7 个分组（`:78`、`:85`、`:136`、`:158`、`:846`、`:871`、`:902`）。
- 实跑结果：末行「trafficctl 本地不变量校验通过」，退出码 0。分组 7 实际跑通了「克隆上游 tag → 重放 6 个 patch → 与 vendored 包逐字节比对」。
- **前提**：分组 7 需要 `git clone --depth 1 --branch "$UP_TAG"` 上游仓库（`:917`），即需要**网络**；也可用 `TCTL_UPSTREAM_LOCAL` 指向本地基线目录跳过克隆（`:911-915`）。无网络时该分组会失败，前 6 组仍可跑。
- CI 用 `sh` 调用（`build-openwrt.yml:556`），且在此之前先 `sh -n` 预检（`:529`），因为 bash 专有语法在 dash 里是**解析期**错误。

### 1.8 `sh tools/verify-firmware-artifact.sh`

- 作用：刷机前的固件产物预检（`tools/verify-firmware-artifact.sh:3-25`）。
- **前提**：必须给一个目录参数，里面放 `gh run download` 下来的 `.img.gz` 与 `.sha256`（`:13-15`、`:29-33`）。无参数时实跑输出用法并以 **exit 2** 退出：

```
用法: sh tools/verify-firmware-artifact.sh <包含 .img.gz 的目录>
```

- 因此它**不能**在没有产物的仓库里跑，也不在 CI 里执行（`build-openwrt.yml` 无引用）。
- 它核对的 18 个条目与期望权限见 `:136-159`，含 `etc/init.d/dnschain` = `-rwxr-xr-x`、`etc/rc.d/S95dnschain` / `K10dnschain` 为符号链接（`:138-139`）。

### 1.9 八个脚本的定位对比

| 脚本 | CI 是否执行 | 需要网络 | 需要固件产物 | 本次实跑结论 |
|---|---|---|---|---|
| `verify-dnschain-domains.sh` | 是（`:449`） | 否 | 否 | 129 OK / 0 FAIL |
| `verify-trafficctl-invariants.sh` | 是（`:556`） | **是**（分组 7） | 否 | 通过 |
| `verify-dnschain-ci-sim.sh` | 否 | 否 | 否 | 通过 |
| `check-dnschain-lua.py` | **否** | 否 | 否 | 121 / 0 |
| `render-dnschain-diagrams.py` | **否** | 否 | 否 | 44 / 0 |
| `extract-dnschain-i18n.py` | **否** | 否 | 否 | 426 条无缺失 |
| `check-trafficctl-i18n.py` | **否** | 否 | 否 | 376/502/376，缺 0 |
| `verify-firmware-artifact.sh` | **否** | 否 | **是** | 无参数，exit 2 |

中间四个 Python 脚本在 CI 里零引用（`grep -n "check-dnschain\|render-dnschain\|extract-dnschain\|check-trafficctl" .github/workflows/build-openwrt.yml` 无输出）。它们的结论在 CI 里没有强制力，只能靠本地自觉跑。

## 2. 路由器端只读取证方法

### 2.1 连接通道

Windows 自带 `ssh.exe` 对这台路由器的 dropbear（老 KEX）无密钥会 `Permission denied`。可用通道是 PuTTY 的 `plink.exe`：

```
plink.exe -batch -ssh -hostkey <当前指纹> -P 22 root@192.168.3.254 -pw <pw> "<单行命令>"
```

三个要点：

1. **hostkey 每次刷机都会变**，不要照抄旧值。先不带 `-hostkey` 跑一次，plink 会把当前指纹打印出来，再拿该指纹重试。
2. `-hostkey` 值含 `+` / `/`，**必须加引号**，否则被 shell 误解析。
3. 传文件用 `pscp -scp`，**不能**用默认 SFTP —— 目标固件没有 `sftp-server`。

### 2.2 不要照抄 `rt.ps1` 的 base64 写法

工作目录里的 `Y:\openwrt\rt.ps1` 用的是「PowerShell 侧 base64 编码 → 远端 `base64 -d | sh`」：

```powershell
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Cmd))
& plink.exe ... "echo $b64 | base64 -d | sh"
```

**目标固件没有 `base64`**（BusyBox 未编入该 applet），这条通道会失败。

正确做法：直接传**单行命令**，用 `;` 分隔多条，避免复杂引号（嵌套引号在 Windows 侧与远端 shell 各解析一次，极易出错）。需要多行逻辑时拆成多次调用，或用 `for`/`while` 单行形式。

### 2.3 只读取证命令清单

| 目的 | 命令 |
|---|---|
| 端口归属 | `netstat -lnup`、`netstat -lntp` |
| 运行时产物 | `ls -l /var/etc/dnschain/`、`wc -l /var/etc/dnschain/*`、`wc -c /var/etc/dnschain/*` |
| 分流片段 | `wc -l /tmp/dnsmasq.d/dnschain-split.conf`；`grep -c '^server='`；`grep -c '^nftset='` |
| dnsmasq 生效配置 | `ls -1t /var/etc/dnsmasq.conf.* \| head -1`；再 `grep -c '^server=127.0.0.1#5353$'`、`grep '^servers-file='`、`grep '^dns-forward-max='`、`grep '^conf-dir='` |
| 健康状态 | `wc -l /var/run/dnschain/health.state`；`cat /var/run/dnschain/health.state` |
| 端口集 | `nft list chain inet ss_spec ss_spec_output` |
| IPv6 代理 | `ip -6 rule`、`ip -6 route show table 999`、`nft list table inet ss_spec` |
| 自检 | `/usr/bin/dnschain-selftest`、`/usr/bin/dnschain-selftest -f`（强制重算） |

判定某个 dnsmasq 配置文件是**真正在用**的那份，看进程 argv 的 `-C` 参数，不要用通配符猜：

```
tr '\0' '\n' < /proc/$(pidof dnsmasq | awk '{print $NF}')/cmdline | grep -A1 '^-C$'
```

（自检第 3 项就是这么做的，`files/usr/bin/dnschain-selftest:173-179`。）

## 3. DNS 排障顺序

### 3.1 五种结果必须先分清

`dc_dns_class` 把一次查询归入五类之一（`files/usr/share/dnschain/dnschain.sh:1364-1425`）：

| 判定 | 条件 | 是否故障 | 代码依据 |
|---|---|---|---|
| `OK` | 有 `Address:` 行且地址计数 > 0 | 否 | `:1406-1419` |
| `EMPTY` | 有 `Address:` 但地址计数为 0（NODATA，rcode=0 ancount=0） | **否** | `:1421-1422` |
| `NX` | 输出含 `NXDOMAIN` 或 `does not exist` | 否（域名不存在） | `:1401` |
| `TIMEOUT` | 硬超时命中，或输出含 `timed out` / `no servers could be reached` / `can't resolve` | **是**（会卡住客户端） | `:1398`、`:1402-1403` |
| `FAIL` | 其它 | **是** | `:1423` |

地址计数用 awk 而不是 `grep -vc`：grep 无匹配时退出码为 1，`|| echo 0` 会追加第二个 0，得到 `"0\n0"`，随后的 `[ -gt ]` 直接报错（`:1376-1378`）。同样的坑在 `dc_count_lines` 的注释里再讲一遍（`:986-1013`）。

**`EMPTY` 不是故障**。它是 NODATA 的合法答复：明确告知「没有此类型记录」，客户端会立刻回落查 A，不会等待。只有收不到任何包才是 `TIMEOUT`，那才会卡住 5 秒。把 `EMPTY` 当失败会得出「国内也全挂」这种完全错误的结论。

### 3.2 排障顺序

按下列顺序，前一步不通就不要往下走：

1. **先确认是「哪条链」**。测三处，不要只测一处：
   - `LAN 地址:53`（客户机实际路径，取自 `uci -q get network.lan.ipaddr`）
   - `127.0.0.1:5353`（国内实例）
   - `127.0.0.1:5336`（国外实例）
2. **`LAN:53` 不通但 `:5353` 通** → 问题在 dnsmasq 侧：上游没配、`noresolv=1` 但没有 `server=`、或 `:53` 被别的进程抢走（见 §5.2）。
3. **`:5353` 不通** → dnsproxy 国内实例没起或 preflight 失败。看 `logread | grep dnschain`，preflight 失败会打印具体原因（`files/etc/init.d/dnschain:175-212`）。
4. **国内域名 OK、国外域名 `TIMEOUT`/`FAIL`** → 查国外实例与代理：`:5336` 是否在监听、`ss_spec` 是否在、`:1234` 是否在监听。自检第 13 项一次给出这三个量（`dnschain-selftest:310-318`）。
5. **国外域名拿到污染 IP** → 查是否走了直连。判据是「两条链答案是否一致」（`dc_explain_domain` 的 `ANSWER_DOMESTIC` / `ANSWER_FOREIGN`，`dnschain.sh:1878-1884`、`:1902-1904`）。
6. **只有特定域名失败** → 查归属。`dnschain-health explain <域名>` 输出 `CLASS`/`PREFERRED`/`ACTIVE`/`PROBE_*`/`DECISION`/`REASON`（`dnschain.sh:1835-1936`）。
7. **改完配置结论不变** → 自检有 60 秒缓存，加 `-f` 强制重算（`dnschain-selftest:598-600`）。

### 3.3 一个具体例子

`www.google.com` 的 `AAAA` 在 v0.10.0 之后期望是 **`OK`**（国外 AAAA 保留，因为 IPv6 流量代理已启用）。若得到 `EMPTY`，自检第 11 项直接判 FAIL 并提示「被抑制了（应为 OK）——检查 ipv6_support 与 chinadns-ng 是否残留」（`dnschain-selftest:290`）。这与 v0.9.x 的期望完全相反，改代码前务必确认版本。

## 4. 代理排障

### 4.1 `ss_spec_output` 只匹配 tcp，且端口集固定

`dc_output_ports` 用 `sed -n 's/.*tcp dport { \([^}]*\) }.*/\1/p'` 只抽 **tcp** 的端口集（`dnschain.sh:510-515`）。它被两处使用：

- preflight 校验上游端口是否在集合内（`init.d/dnschain:172-181`）
- 收敛器校验集合本身（`dnschain-reconcile:197-207`）：含 `53` 报错、不含 `853` 也报错

这意味着：**改了 dports 之后，上游端口可能突然「越界」**，框架会拒绝启动。反之若 `ss_spec_output` 读不到（SSR-Plus 未启用 / nft 未就绪），校验**不阻断**，只记 `WARN`（`dnschain.sh:1948-1951`）—— 这是刻意的降级，不要让「校验通过」被误读成「端口合规」。

### 4.2 `pidof` 对 SSR-Plus 的二进制无效

SSR-Plus 的二进制以**完整路径**运行（`/var/etc/ssrplus/bin/v2ray`、`.../mosdns`），所以：

- `pgrep -x xray`、`pgrep -x mosdns` **恒为 0**，会误判成「后端没起」。
- 正确做法是 `pgrep -f '/var/etc/ssrplus/bin/'`，或遍历 `/proc/*/cmdline`。

但 `pgrep -f` 会**匹配到诊断命令自身**：执行 `pgrep -f "ssr-switch start"` 时，它会把执行该命令的 `ash -c` 也算进去。遍历 `/proc/*/cmdline` 时必须 `grep -v "ash -c"` 排除。

### 4.3 `netstat` 对多 socket 归因不可靠

同一个地址端口可能有多个 socket，`netstat` 只显示其中一条的进程。要确认 socket 属于谁，用 `/proc/net/udp` 的 inode 反查 `/proc/<pid>/fd`：

```sh
# 取 :53 的所有 socket inode（$2 是 local_address，形如 FE03A8C0:0035，小端 hex）
INODES=$(awk 'NR > 1 && $2 ~ /:0035$/ { print $10 }' /proc/net/udp)
for pid in <候选PID...>; do
  n=0
  for ino in $INODES; do
    ls -l "/proc/$pid/fd" 2>/dev/null | grep -q "socket:\[$ino\]" && n=$((n + 1))
  done
  echo "PID $pid 持有 :53 socket 数 = $n"
done
```

这正是 `dc_dnsmasq_pid` 的实现方式（`dnschain.sh:454-491`），它优先按 socket 反查，取不到才回落到 `pidof` 的**最后一个**（最老、最可能是真 worker），再回落到 pidfile。

为什么要这么绕：本固件的 dnsmasq 是「ujail → dnsmasq → 子进程」三层，`pidof dnsmasq` 返回 3 个 PID，**第一个是 ujail 辅助子进程**（`wchan=anon_pipe_read`、5 个 fd、0 个 `socket:53`）。对它 SIGHUP 是**空操作** —— 改道/清缓存都会静默失效（`dnschain.sh:428-453`）。

## 5. 常见误判清单

| # | 误判 | 真相 | 证据 |
|---|---|---|---|
| 1 | 把 `EMPTY` 当超时/故障 | `EMPTY` 是 rcode=0 ancount=0 的合法 NODATA，客户端立刻回落；只有收不到包才是 `TIMEOUT` | `dnschain.sh:1371`、`:1421-1422`；自检第 11 项把 `EMPTY` 判 FAIL 是因为该场景期望 `OK`，不是通用规则（`dnschain-selftest:290`） |
| 2 | 只测 `127.0.0.1:53` 不测 LAN 地址 | 客户机用的是 LAN 地址上的 `:53`，两者可能一个通一个不通（`netstat` 可见 `192.168.3.254:53` 独立监听） | 自检第 1 项取 `network.lan.ipaddr` 而非回环（`dnschain-selftest:89-94`、`:117`） |
| 3 | `pgrep -f` 命中诊断命令自身 | 执行 `pgrep -f "ssr-switch start"` 会把 `ash -c` 也算进去，虚报成 2 个进程 | §4.2；遍历 `/proc/*/cmdline` 需 `grep -v "ash -c"` |
| 4 | `ps w \| grep -c <脚本名>` 虚高 | BusyBox 的 `ps w` 会折行长命令行，且脚本**自身的 cmdline 含搜索关键字** → 曾报出「2532 个进程」而真实只有 8 个 | AGENTS.md §6.6；正确做法是遍历 `/proc/[0-9]*/cmdline` 只匹配 exec 名 + 第一个参数 |
| 5 | CI 日志先 grep 关键字 | `gh run view --log` 里**源码回显占绝大部分**，每条 run 脚本都以 `N\t<原文>` 重印一遍，真实输出夹在中间 → 会同时命中回显，误判成「没输出」或「输出正常」 | AGENTS.md §6.8；正确做法是先定位真实执行的第一条输出（不带行号前缀），再顺序原样打印后续几十行 |
| 6 | `grep -c PAT \|\| echo 0` 得到 `"0\n0"` | `grep -c` 无匹配时既打印 `0` 又返回 rc=1，`\|\| echo 0` 再追加一个 → 变量含换行 → `[ "$n" -eq 0 ]` 算术比较报错返回假 → **判据恒假** | `dnschain.sh:986-1013`（含实测 `[0\n0]`）；自检第 12 项因此改用 awk（`dnschain-selftest:296-302`）；`verify-dnschain-domains.sh:318-321` 有反向断言 |
| 7 | `[[:space:]]` 被当成 `[[ ]]` | 直接 `grep '\[\['` 会命中 POSIX 字符类，那是完全合法的 POSIX 语法 → CI 永远红 | `build-openwrt.yml:1103-1112`（判据改成「`[[` 后紧跟空白」）；`dnschain.sh` 里确实有 `sed -e 's/^[[:space:]]*//'` |
| 8 | Lua 里 `[^—]` 按字节排除 | Lua 字符类按**字节**工作，`—`(U+2014) 是 `E2 80 94`，`[^—]` 实际排除这三个字节 → 凡名称含 `一`(E4 B8 **80**)、`上`、`下` 等第三字节为 0x80 的汉字，匹配直接失败。实测 20 项里 **7 项**解析失败、另有 10 项 name 尾随空格 | `dnschain.lua:482-496`（改用 `find(..., true)` 字节精确匹配） |
| 9 | 用 `grep -c 'dnsmasq restart'` 断言「应为 0」 | 会命中 `echolog "restart: skip dnsmasq restart in stop()"` 这条**日志文本**，永久误报。正确判据是排除 `echolog` 行后统计真实调用 | AGENTS.md §4.4；文本来源 `99-gaming-optimize:501` |
| 10 | `nc -z` 判代理节点可用性 | Cloudflare 前置节点对裸 TCP 不响应，但 TLS 握手正常 → 误判「节点挂了」。判据应看 `netstat -antp` 是否有 ESTABLISHED，或直接测经代理的解析结果 | AGENTS.md §4.4 |
| 11 | 把 `sh` 换成 `bash` 自测 | CI 的 `/bin/sh` 是 dash，bash 专有语法（进程替换、`[[ ]]`、数组）在 dash 里是**解析期**错误，脚本一行未执行即 exit 2 | `build-openwrt.yml:520-536`；本地用 WSL 的 `/bin/sh`（dash）验证（§1.0） |
| 12 | 用 `stat -c %Y` 取文件 mtime | BusyBox **没有 `stat`**，`age` 恒为空 → 缓存永不命中。要用 `date -r <file> +%s` | `dnschain-selftest:603-607`；`verify-dnschain-domains.sh:347` 有反向断言 |
| 13 | 用 `pidof dnsmasq` 第一个 PID 发 SIGHUP | 第一个是 ujail 辅助子进程，SIGHUP 是空操作 | `dnschain.sh:428-453`；`dnschain-health:298-308` |
| 14 | 在仓库根跑 CI 那段校验就当通过 | 那段校验的 `working-directory` 是 `lede`，仓库根跑会误报 | `tools/verify-dnschain-ci-sim.sh:7-12`；要跑 `verify-dnschain-ci-sim.sh` |

## 6. 改动后的回归清单

改 DNS 分流、改道、上游、代理端口的任何一处，都按下列顺序回归。前一组不过就不要进下一组。

### 6.1 本地静态校验（不需要路由器）

```sh
sh tools/verify-dnschain-domains.sh          # 期望 129 OK / 0 FAIL
sh tools/verify-dnschain-ci-sim.sh           # 期望「CI 模拟校验通过」
sh tools/verify-trafficctl-invariants.sh     # 需要网络（克隆上游 tag）
PYTHONIOENCODING=utf-8 python tools/check-dnschain-lua.py        # 期望 PASS=121 FAIL=0
PYTHONIOENCODING=utf-8 python tools/render-dnschain-diagrams.py  # 期望 PASS=44 FAIL=0
PYTHONIOENCODING=utf-8 python tools/extract-dnschain-i18n.py     # 期望「无缺失」
PYTHONIOENCODING=utf-8 python tools/check-trafficctl-i18n.py     # 期望「中文翻译完整」
```

改了 `.sh` 还要单独过一遍 dash 解析：`sh -n <脚本>`（CI 也是这么做的，`build-openwrt.yml:1070`）。

### 6.2 路由器端：自检 20 项

```sh
/usr/bin/dnschain-selftest -f      # -f 绕过 60 秒缓存
```

期望：`FAIL=0`。`SKIP` 可以接受，但要知道哪一项 skip 了 —— 第 12 项（DoH 出站）空闲时必然 SKIP，第 20 项（改道状态自洽）在还没探测过时 SKIP（`dnschain-selftest:306`、`:569`）。

### 6.3 路由器端：分域名回归

| 类别 | 域名 | 期望 | 判据 |
|---|---|---|---|
| 国内 A | `www.baidu.com` | `OK` 且非污染 IP | 自检第 8 项（`dnschain-selftest:256-261`）；污染前缀 `2001::1`/`31.13.*`/`157.240.*`/`104.244.*`（`:78-84`） |
| 国内 AAAA | `www.taobao.com` | `OK`（必须保留，不能 `EMPTY`） | 自检第 9 项（`:264-270`） |
| 国内 A | `www.qq.com` | `OK` | 与 baidu 同路径 |
| 国外 A | `www.google.com` | `OK` 且非污染 | 自检第 10 项（`:273-280`） |
| 国外 AAAA | `www.google.com` | `OK`（v0.10.0 起保留，`EMPTY` 即 FAIL） | 自检第 11 项（`:282-293`） |
| 国外 A | `www.youtube.com` | `OK` | 走代理出口 |
| 国外 A | `github.com` | `OK`（观测域名，走 `watch.servers`） | 自检第 18 项保证它不与静态片段重复（`:441-463`） |

### 6.4 路由器端：DNS 加密链路

| 检查 | 期望 | 证据来源 |
|---|---|---|
| 两个 dnsproxy 实例在监听 | `:5353`（含 `::1`）与 `:5336`（仅 `127.0.0.1`）各 1 个 | 自检第 4 项（`dnschain-selftest:189-201`）；参数见 `dnschain.sh:340-343`、`:388-390` |
| dnsproxy 参数无 `--cache`/`--fallback`/`--ipv6-disabled` | 三项都无 | 自检第 5 项（`:203-218`） |
| dnsmasq 唯一默认上游恰好 1 条 | `server=127.0.0.1#5353` 恰好 1 条 | 自检第 3 项（`:162-187`） |
| 无明文旁路 | conf-dir 内无「非 `127.0.0.1` 的 IP」`server=` | 自检第 15 项（`:371-402`） |
| 缓存只在 dnsmasq 一层 | dnsmasq `cache-size > 0` 且 dnsproxy 无 `--cache` | 自检第 16 项（`:404-416`） |
| 国外 DoH 出站 | 有到 DoH 上游的 ESTABLISHED（空闲时 SKIP 属正常） | 自检第 12 项（`:295-307`） |
| 改道通道已就绪 | UCI 配了 `serversfile`、文件可读、生效配置里有 `servers-file=`、目录在 ujail 白名单 | 自检第 19 项（`:465-541`） |

### 6.5 路由器端：改道功能

| 检查 | 命令 | 期望 |
|---|---|---|
| 观测列表非空 | `/usr/bin/dnschain-health status` | 有 `ROW` 行，末行 `SUM total=N …` |
| 一轮探测能跑 | `/usr/bin/dnschain-health cycle` | 末行 `CYCLE ok=… switch=… bad=… wait=…`（`dnschain.sh:1764-1765`） |
| 状态文件段数 | `awk -F'\|' '{print NF}' /var/run/dnschain/health.state \| sort -u` | 恒为 **7** |
| 改道只 SIGHUP 不重启 | 改一个观测域名的 `active` 后看 dnsmasq PID | PID **不变**（`dnschain.sh:1755-1761`） |
| 清缓存 | `/usr/bin/dnschain-health flush` | 输出 `OK=已清空 dnsmasq 缓存（零中断）`（`dnschain-health:309-316`） |
| 回切不被永久阻塞 | 改道后等 `min_dwell`（默认 120 秒）+ 3 轮成功 | 状态从 `recover-wait:` 变成 `recover:`（`dnschain.sh:1737-1741`） |

### 6.6 路由器端：代理与分流

| 检查 | 命令 | 期望 |
|---|---|---|
| 代理表在 | `nft list tables \| grep -c ss_spec` | 2（自检第 13 项要求恰好 2，`dnschain-selftest:310`） |
| `:1234` 在监听 | `netstat -lntp \| grep :1234` | 1 个 |
| `global_server` 非空非 nil | `uci -q get shadowsocksr.@global[0].global_server` | 节点名（`nil` 会让 SSR-Plus 一条规则都不装，`dnschain-reconcile:116-119`） |
| 端口集不含 53 | `nft list chain inet ss_spec ss_spec_output` | 集合里无 `53`（`dnschain-reconcile:200-202`） |
| 端口集含 853 | 同上 | 有 `853`（`dnschain-reconcile:203-206`） |
| nftset 行数非 0 | `grep -c '^nftset=' /tmp/dnsmasq.d/dnschain-split.conf` | 与 `server=` 行数相等且 > 0 |
| `pdnsd_enable` | `uci -q get shadowsocksr.@global[0].pdnsd_enable` | `0`（或用户显式选的 `7`，`dnschain-reconcile:61-69`） |
| `ipv6_support` | `uci -q get shadowsocksr.@global[0].ipv6_support` | `1` |
| `dnsmasq.filter_aaaa` | `uci -q get dhcp.@dnsmasq[0].filter_aaaa` | `0`（**读这个键，不是 `shadowsocksr.filter_aaaa`**，`dnschain-selftest:233-240`） |

### 6.7 一次改动的完整回归脚本

把 §6.1–§6.6 串起来，路由器端可以一条命令跑完自检并打印关键量：

```sh
/usr/bin/dnschain-selftest -f; echo ---; /usr/bin/dnschain-health status; echo ---; netstat -lnup | grep -E ':(53|5353|5336|1234) '; echo ---; uci -q get shadowsocksr.@global[0].pdnsd_enable; uci -q get shadowsocksr.@global[0].ipv6_support; uci -q get dhcp.@dnsmasq[0].filter_aaaa; echo ---; grep -c '^server=' /tmp/dnsmasq.d/dnschain-split.conf; grep -c '^nftset=' /tmp/dnsmasq.d/dnschain-split.conf
```

注意用 `;` 分隔、单行传递（§2.2），不要用多行 heredoc。

## 7. 本文未覆盖的内容

以下项目在仓库内没有对应的自动化手段，只能人工判断，故不写成「验证步骤」：

- 客户端真实浏览器访问国外站点的结果（Cloudflare 机器人挑战会让 `curl` 得到 `403 Cf-Mitigated: challenge`，那是反爬不是网络故障）。
- 上行带宽实测（本机无可用上传端点，trafficctl 的上行速率列只能靠 conntrack 字节差，冷启动首帧显示 `—`）。
- NAT1（fullcone）与软件 flow offloading 的交互（上游未文档化该组合）。
- 固件解包后的完整清单核对需要先有产物（`tools/verify-firmware-artifact.sh` 的输入），仓库内无法生成。
