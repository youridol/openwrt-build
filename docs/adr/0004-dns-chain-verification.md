# ADR-0004：DNS 链路全链路验证规程

- 状态：**生效**（2026-10-20）
- 适用：刷入含 `dnschain` 框架的固件后，逐项验证链路是否按 [ADR-0003](0003-dns-chain-framework.md) 工作
- 前置：路由器 `192.168.3.254`（OpenWrt 24.10.5 x86/64）、本机 Windows `192.168.3.238`
- 定位：**这是一份执行规程，不是设计文档。** 设计见 ADR-0003；本文只回答「刷完机怎么验、每项看什么、失败说明什么」

---

## 0. 使用方式

```text
按 §1 → §9 顺序执行。每一节都有「命令 / 期望 / 失败含义」三栏。
任一项 FAIL 时，先看该节的「失败含义」，再按 §10 的排查树定位。
不要跳步：后面的检查依赖前面的状态。
```

**证据纪律**（每一条都有历史教训，见 AGENTS.md §6）：

| # | 纪律 | 为什么 |
|---|---|---|
| E1 | 必须用**客户机真实地址** `192.168.3.254:53` 测，不能只测 `127.0.0.1:53` | 后者被 v2ray 抢占时前者仍正常（AGENTS §4.3） |
| E2 | DNS 结果必须分 **OK / EMPTY / NX / TIMEOUT / FAIL** 五类 | 把 `EMPTY` 当失败会得出「国内也全挂」的错误结论（AGENTS §5.1） |
| E3 | 测延迟**不能用 `date +%s%N`** | BusyBox 不支持，静默返回秒级值 → 全部显示 0ms（本轮实测踩过） |
| E4 | 判断进程存在**不能用 `pgrep -x <名字>`** | SSR-Plus 的二进制以完整路径运行，`pgrep -x` 恒为 0 |
| E5 | 改配置前先备份 `/etc/config/*` 与 `/var/etc/dnschain/*` | 回滚需要（AGENTS §6 第 10 条） |
| E6 | 结论必须来自**命令输出**，不能来自「配置里写了」 | 旧 ADR 的失败根源正是把设计意图当既成事实 |
| E7 | **overlay 文件在 ≠ 功能在**。必须分两层查：`files/` 的 overlay 与 `package/` 的 LuCI 页面 | v0.9.0 首次构建：10 个 overlay 文件全部就位，但 LuCI 页面**一个都没有**，而构建全绿 |
| E8 | 验证固件内容**不能用 `unsquashfs -l <path>`** | 该命令对**不存在的路径也返回 0**（实测），会把缺失误报成存在。用 `-ll` 列全量再 grep |

---

## 1. 刷机后首次检查（组件是否就位）

> **本节分两层。** v0.9.0 首次构建只验了第一层（overlay 文件），漏了第二层
> （LuCI 页面），结果刷完机「文件都在、页面没有」。两层都要查。

### 1.1 第一层：overlay 文件（`files/` 提供）

```sh
for f in /etc/config/dnschain \
         /etc/init.d/dnschain \
         /usr/share/dnschain/dnschain.sh \
         /usr/bin/dnschain-reconcile \
         /usr/bin/dnschain-selftest \
         /etc/uci-defaults/99-zz-dnschain \
         /etc/capabilities/dnschain-filter.json \
         /etc/ssrplus/applechina.conf; do
  [ -e "$f" ] && echo "OK   $f" || echo "MISS $f"
done
```

| 期望 | 失败含义 |
|---|---|
| 8 项全 `OK` | 有 `MISS` → overlay 未合并，或 CI 未把文件打进固件 |

### 1.2 第二层：LuCI 页面（`package/luci-app-dnschain` 提供）

**这一层必须单独查。** 它由 opkg 包安装，与 `files/` overlay 是两条独立的路径；
包没编进去时，overlay 文件依然全在。

```sh
# 包是否安装
opkg list-installed | grep -E 'luci-app-dnschain|luci-i18n-dnschain'

# 页面文件是否就位（6 个关键文件）
for f in /usr/share/luci/menu.d/luci-app-dnschain.json \
         /usr/share/rpcd/acl.d/luci-app-dnschain.json \
         /usr/lib/lua/luci/controller/dnschain.lua \
         /usr/lib/lua/luci/model/cbi/dnschain/general.lua \
         /usr/lib/lua/luci/model/cbi/dnschain/dnschain.lua \
         /usr/lib/lua/luci/i18n/dnschain.zh-cn.lmo; do
  [ -e "$f" ] && echo "OK   $f" || echo "MISS $f"
done
```

| 期望 | 失败含义 |
|---|---|
| `opkg` 有 `luci-app-dnschain` 与 `luci-i18n-dnschain-zh-cn` | 包未编入 → CI 的 `Add luci-app-dnschain` 步骤缺失，或 `.config` 里符号被依赖求解丢弃（查 CI 日志 `=== dnschain 本体与中文语言包都必须入配置 ===`） |
| 6 个文件全 `OK` | 有 `MISS` → 包装了但内容不全，检查 `package/luci-app-dnschain/` 的 `root/` 与 `luasrc/` 布局 |

**最后确认页面真的能打开**：浏览器访问 `http://192.168.3.254/cgi-bin/luci/admin/network/dns_chain`。
返回 404 或空白 → 页面没注册；能打开但显示英文 → i18n 包缺失。

### 1.3 执行位

```sh
ls -l /etc/init.d/dnschain /usr/bin/dnschain-reconcile /usr/bin/dnschain-selftest
```

| 期望 | 失败含义 |
|---|---|
| 三者均 `-rwxr-xr-x` | 缺 `x` → CI 的 `chmod +x` 清单没覆盖到，服务起不来 |

### 1.4 运行时依赖包

```sh
opkg list-installed | grep -E 'luci-app-dnschain|luci-i18n-dnschain|chinadns-ng|dnsproxy|dns2tcp'
```

| 期望 | 失败含义 |
|---|---|
| `chinadns-ng` 存在（版本 `2025.06.20-1`）、`dnsproxy` 为 `0.83.0` | 缺 `chinadns-ng` → 过滤器起不来；CI 已显式 `CONFIG_PACKAGE_chinadns-ng=y` 兜底 |
| `dnsproxy` 是 `0.83.0` 而非 `0.56.2` | 版本错 → CI 的 `Align dnsproxy feed link` 失效 |

---

## 2. 端口所有权（最容易出错的一节）

**这是全链路的地基。** `:5335` 只能有一个持有者。

### 2.1 谁在监听关键端口

```sh
netstat -lnup 2>/dev/null | grep -E ':(53|5353|5335|5337|1234)\b'
netstat -lntp 2>/dev/null | grep -E ':(53|5353|5335|5337|1234|853)\b'
```

| 期望（`primary` 档案） | 失败含义 |
|---|---|
| `:53` → dnsmasq | 被别的进程占了 → DNS 全断 |
| `:5353` → dnsproxy | 无监听 → 客户机全部无法解析 |
| `:5335` → **chinadns-ng**（框架的） | 是 `mosdns`/`dns2tcp` → SSR 模式没切到 0，框架的 `preflight` 应已拒绝启动 |
| `:1234` → v2ray | 无监听 → 国外域名全 SERVFAIL |
| `:853` **无 UDP 监听** | 有监听 → 可能误开了 dnsproxy 的 DoT 服务端（与 T2 冲突） |

### 2.2 `:5335` 的持有者到底是谁

```sh
PID=$(netstat -lnup 2>/dev/null | awk '$4 ~ /:5335$/ {print $NF}' | sed 's|/.*||' | head -1)
echo "PID=$PID"
tr '\0' ' ' < /proc/$PID/cmdline; echo
```

| 期望 | 失败含义 |
|---|---|
| cmdline 含 `chinadns-ng`，且含 `-l 5335`、`-d gfw`、`-N tag:gfw` | 含 `mosdns` → SSR 模式仍是 4；含 `-l 5337` → 框架处于 `coexist` 档案（此时 `:5335` 应属 SSR） |

### 2.3 SSR-Plus 的模式

```sh
uci -q get shadowsocksr.@global[0].pdnsd_enable    # 期望 0（primary）
uci -q get shadowsocksr.@global[0].enable_switch  # 期望 0
uci -q get shadowsocksr.@global[0].filter_aaaa    # 期望 1
uci -q get shadowsocksr.@global[0].global_server  # 期望节点名，不能是 nil
```

| 期望 | 失败含义 |
|---|---|
| `pdnsd_enable=0` | 是 `4` → `99-zz-dnschain` 未生效（uci-defaults 排序问题）或收敛器未运行 |
| `enable_switch=0` | 是 `1` → 周期性 restart，会造成 DNS 空窗（AGENTS §4.1） |
| `global_server` 非 `nil` | 是 `nil` → SSR 一条规则都不装，客户机全挂（AGENTS §4.2） |

**若 2.1/2.2/2.3 任一不符，停在这里。** 后面的检查都依赖端口归属正确。

---

## 3. 缓存层唯一性

ADR-0010 §10.5 的核心约束：缓存只在 dnsmasq。

### 3.1 三层的缓存开关

```sh
# dnsmasq：应有 cache-size
grep -E '^cache-size' /var/etc/dnsmasq.conf.* 2>/dev/null

# dnsproxy：cmdline 里**不应**有 --cache
PID=$(pidof dnsproxy)
tr '\0' '\n' < /proc/$PID/cmdline | grep -E '^--cache' && echo "FAIL dnsproxy 有缓存" || echo "OK dnsproxy 无缓存"

# 过滤器：cmdline 里**不应**有 --cache
FPID=$(netstat -lnup 2>/dev/null | awk '$4 ~ /:5335$/ {print $NF}' | sed 's|/.*||' | head -1)
tr '\0' '\n' < /proc/$FPID/cmdline | grep -E '^--cache' && echo "FAIL 过滤器有缓存" || echo "OK 过滤器无缓存"
```

| 期望 | 失败含义 |
|---|---|
| dnsmasq `cache-size=8192`；dnsproxy 与过滤器都无 `--cache` | 任一层有缓存 → 同一域名可能出现两份答案（实测经 `:53` 与直连 `:5353` 返回不同 IP） |

### 3.2 两份答案是否真的消失

```sh
echo "--- 经 dnsmasq:53 ---"
nslookup www.google.com 127.0.0.1 2>&1 | grep '^Address: [0-9]'
echo "--- 直连 dnsproxy:5353（应走过滤器，不应污染）---"
nslookup www.google.com 127.0.0.1:5353 2>&1 | grep '^Address: [0-9]'
```

| 期望 | 失败含义 |
|---|---|
| 两处都返回 Google 真实 IP（`142.251.x.x` 等），**都不是** `2001::1` / `31.13.x` / `104.244.x` | `:5353` 返回 `2001::1` → 域名分流文件没生效，dnsproxy 用国内上游直答（这是污染） |

**这是判断「框架是否真的接管」的最强单条证据。**

---

## 4. 解析正确性（四类域名）

```sh
LAN=192.168.3.254

probe() {
  local name="$1" qtype="$2"
  local out
  if [ "$qtype" = "a" ]; then out=$(nslookup "$name" "$LAN" 2>&1); else out=$(nslookup "-type=$qtype" "$name" "$LAN" 2>&1); fi
  local ans=$(echo "$out" | sed -n 's/^Address: \([0-9a-fA-F.:]*\)$/\1/p' | head -3 | tr '\n' ' ')
  echo "$name [$qtype] -> ${ans:-<EMPTY>}"
}

probe www.baidu.com a
probe www.baidu.com aaaa
probe www.taobao.com aaaa
probe www.google.com a
probe www.google.com aaaa
probe www.youtube.com a
probe www.youtube.com aaaa
probe www.wikipedia.org a
probe www.github.com a
```

| 域名 | 类型 | 期望 | 失败含义 |
|---|---|---|---|
| `www.baidu.com` | A | 真实国内 IP | 空 → dnsmasq 或 dnsproxy 挂 |
| `www.taobao.com` | AAAA | **真实 IPv6**（`240e:*`） | 空 → 国内 AAAA 被误抑制（`filter_aaaa` 或 `-N` 用错） |
| `www.google.com` | A | Google 真实 IP | `2001::1`/`31.13.x` → 污染；空 → 过滤器或代理挂 |
| `www.google.com` | AAAA | **EMPTY**（rcode=0 ancount=0） | 真实 AAAA → 抑制没生效，国外 IPv6 会直连被 RST；TIMEOUT → 会卡客户端 5 秒 |
| `www.youtube.com` | AAAA | **EMPTY** | 同上 |
| `www.wikipedia.org` | A | 真实（`103.102.x` 等） | `2001:df2:...` → 污染 |
| `www.github.com` | A | 真实 | 空 → 代理挂 |

**关键区分**：`EMPTY` 与 `TIMEOUT` 是两回事。前者是预期（客户端 1ms 回落查 A），后者是故障（卡 5 秒）。

---

## 5. 分流三层是否都生效

ADR-0003 §5 说「分三层，缺一层都会看起来配好了但实际不对」。

### 5.1 DNS 层（决定客户机拿到哪种地址）

已由 §4 覆盖。核心是：国内双栈、国外只有 A。

### 5.2 IP 层（决定 IPv4 走不走代理）

```sh
nft list chain inet ss_spec ss_spec_wan_ac
for s in blacklist whitelist china whitelist_domain music fplan bplan gmlan; do
  n=$(nft list set inet ss_spec $s 2>/dev/null | grep -cE '^\s+[0-9a-f.:]+')
  echo "$s=$n"
done
```

| 期望 | 失败含义 |
|---|---|
| 13 条规则，顺序与 ADR-0003 §5.2 一致 | 顺序变了 → SSR-Plus 版本升级，需重新核对 |
| `china` 约 1493 行元素 | 0 → `china_ssr.txt` 未加载，所有流量都会走代理 |
| `blacklist` 约 7 元素 | 更多 → 有域名派生 IP 被写入（`-A` 生效，属增强） |

**注意**：计数正则会命中 `flags interval` 与 `auto-merge` 两行元数据，空集合恒得 **2**。所以 `=2` 表示「无元素」。

### 5.3 出站层（路由器自身的 DoT 是否经代理）

```sh
nft list chain inet ss_spec ss_spec_output
```

| 期望 | 失败含义 |
|---|---|
| 端口集含 **853**、**不含 53**；只匹配 `tcp` | 不含 853 → 路由器自身 DoT 直连被墙，国外域名全超时；含 53 → 会触发 v2ray socket 堆积（AGENTS §4.3） |

**实测出站是否真的经代理**：

```sh
# 发起一次国外解析，然后看过滤器的连接
nslookup www.google.com 127.0.0.1:5335 >/dev/null 2>&1
sleep 1
netstat -antp 2>/dev/null | grep -E '8\.8\.8\.8:853|1\.1\.1\.1:853' | head -3
```

| 期望 | 失败含义 |
|---|---|
| 有 ESTABLISHED 到 `8.8.8.8:853` 或 `1.1.1.1:853` | 无连接 → 过滤器没在上游查询（可能 `-t` 参数为空），或 DoT 被墙 |

---

## 6. 双栈与 853 拒绝

### 6.1 853 拒绝规则是否在位且优先级正确

```sh
cat /etc/nftables.d/15-dnschain-reject-dot.nft
nft list chain inet fw4 dnschain_reject_dot
```

| 期望 | 失败含义 |
|---|---|
| 文件里是**裸 chain**（无 `table` 声明） | 有 `table` → fw4 整个 ruleset 不加载 → 断网（AGENTS 红线 7） |
| `nft list` 显示 `priority mangle - 1`（即 -151） | 显示别的优先级 → 可能被 tproxy 抢先 |

### 6.2 从客户机验证 853 真的被拒

**在本机（`192.168.3.238`）执行**，不是路由器：

```powershell
# PowerShell，测 853 是否被拒（期望很快失败，不是超时）
Test-NetConnection 8.8.8.8 -Port 853 -InformationLevel Quiet
```

或：

```powershell
curl -sv --max-time 5 https://8.8.8.8:853/ 2>&1 | Select-String 'refused|timed out|Connected'
```

| 期望 | 失败含义 |
|---|---|
| 快速 `refused` / 连接被重置 | 若成功建立 → 853 拒绝规则没生效，客户端可绕过 AAAA 抑制 |

### 6.3 国内 IPv6 仍然可用

**在本机执行**：

```powershell
Resolve-DnsName www.taobao.com -Type AAAA -Server 192.168.3.254
curl -6 -sI --max-time 10 https://www.taobao.com | Select-Object -First 1
```

| 期望 | 失败含义 |
|---|---|
| 解析出 `240e:*` 且 `curl -6` 有响应 | 解析出但连不上 → IPv6 出口问题；解析不出 → 国内 AAAA 被抑制了 |

---

## 7. 名单导入

### 7.1 生成物是否存在且规模正确

```sh
wc -l /var/etc/dnschain/upstreams-domains.txt /var/etc/dnschain/idna-bypass.conf
head -2 /var/etc/dnschain/upstreams-domains.txt
cat /var/run/dnschain/lists.fingerprint
```

| 期望 | 失败含义 |
|---|---|
| `upstreams-domains.txt` 约 **23593** 条（23717 域名 − 124 个 IDNA） | 0 条 → 生成失败；约 23717 条 → `xn--` 没过滤（dnsproxy 会**整体拒绝启动**） |
| `idna-bypass.conf` 约 **124** 条 | 0 条 → IDNA 域名没进 dnsmasq 旁路，这些域名会走国内上游 |
| 每行形如 `[/域名/]127.0.0.1:5335` | 端口是 5337 → 处于 `coexist` 档案 |

### 7.2 dnsproxy 真的加载了它

```sh
PID=$(pidof dnsproxy)
tr '\0' ' ' < /proc/$PID/cmdline | tr ' ' '\n' | grep -A1 '^--upstream$' | tail -1
```

| 期望 | 失败含义 |
|---|---|
| 输出 `/var/etc/dnschain/upstreams-domains.txt` | 输出的是某个 `https://` → 域名文件没进参数，分流完全不生效 |

### 7.3 自动导入是否工作

```sh
# 记下当前指纹
FP1=$(cat /var/run/dnschain/lists.fingerprint)
# 触发一次 SSR 名单更新（会下载）
/usr/bin/lua /usr/share/shadowsocksr/update.lua gfw_data >/dev/null 2>&1
# 等收敛器轮询（默认 60s）
sleep 70
FP2=$(cat /var/run/dnschain/lists.fingerprint)
[ "$FP1" != "$FP2" ] && echo "OK 自动导入已触发" || echo "未变化（名单本身可能没更新）"
wc -l /var/etc/dnschain/upstreams-domains.txt
```

| 期望 | 失败含义 |
|---|---|
| 指纹变化或行数变化；日志有 `名单源已变化，重新导入` | 无变化 → 收敛器没跑，或 `auto_import=0` |

查日志：

```sh
logread | grep dnschain | tail -20
```

---

## 8. 抗「改 LuCI 就坏」验证（本节最关键）

**这是整个框架的存在理由。** 必须实际去改 SSR-Plus 的页面，然后确认链路没坏。

### 8.1 基线：记录当前状态

```sh
echo "=== 基线 ==="
nslookup www.google.com 192.168.3.254 2>&1 | grep '^Address: [0-9]' | head -2
nslookup www.baidu.com 192.168.3.254 2>&1 | grep '^Address: [0-9]' | head -2
netstat -lnup 2>/dev/null | grep -E ':(5335|5353)\b'
```

### 8.2 故意改坏 SSR-Plus 的三个键

**在 LuCI 页面上**（或直接 uci set），依次改：

| 改动 | 命令（也可在页面操作） |
|---|---|
| 把 DNS 模式改回 MosDNS | `uci set shadowsocksr.@global[0].pdnsd_enable='4'; uci commit shadowsocksr` |
| 打开自动切换 | `uci set shadowsocksr.@global[0].enable_switch='1'; uci commit shadowsocksr` |
| 关掉 filter_aaaa | `uci set shadowsocksr.@global[0].filter_aaaa='0'; uci commit shadowsocksr` |

然后 **`/etc/init.d/shadowsocksr restart`**。

### 8.3 验证收敛器把它们改回来

```sh
sleep 5
/etc/init.d/dnschain restart      # 触发收敛
sleep 3
echo "pdnsd_enable=$(uci -q get shadowsocksr.@global[0].pdnsd_enable)   期望 0"
echo "enable_switch=$(uci -q get shadowsocksr.@global[0].enable_switch) 期望 0"
echo "filter_aaaa=$(uci -q get shadowsocksr.@global[0].filter_aaaa)     期望 1"
logread | grep dnschain | grep 归一 | tail -5
```

| 期望 | 失败含义 |
|---|---|
| 三个键都被改回；日志有 `归一: ... -> ...` | 没改回 → 收敛器未运行，或 `ssr.enforce=0` |

### 8.4 链路是否仍然正常

```sh
/usr/bin/dnschain-selftest
```

| 期望 | 失败含义 |
|---|---|
| `SUMMARY PASS=16 FAIL=0`（或 FAIL=0、SKIP≤1） | 有 FAIL → 按 §10 排查 |

### 8.5 逐项自检的输出格式

```sh
/usr/bin/dnschain-selftest | head -20
```

期望形如：

```
1 PASS fw4 劫持在位 — dns_intercept_lan 含 udp/tcp dport 53
2 PASS dnsmasq 分流目标唯一 — profile=primary，端口集合 {5335 } 合规
...
16 PASS 缓存层唯一 — dnsmasq cache-size=8192，其余两层无 --cache

SUMMARY PASS=16 FAIL=0 SKIP=0
CONCLUSION: 链路正常
```

---

## 9. 降级矩阵验证（可选，但建议做一次）

ADR-0003 §12 声称「五处故障全部不回落明文」。逐项验证：

| # | 操作 | 期望的客户机症状 | 验证命令 | 恢复 |
|---|---|---|---|---|
| 1 | `killall chinadns-ng`（procd 会重启，先看症状） | 仅 gfw 域名 SERVFAIL，**国内正常** | `nslookup www.baidu.com 192.168.3.254` 仍成功 | procd 自动 respawn |
| 2 | `killall dnsproxy` | **全部域名失败** | 两个都查一次 | procd 自动 respawn |
| 3 | `/etc/init.d/shadowsocksr stop` | 仅 gfw 域名失败，国内正常 | 同上 | `start` |
| 4 | 临时把国内上游改成不可达 | 国内域名 SERVFAIL，**不回落明文** | 查 `www.baidu.com` | 改回 |

**关键**：任何一项都**不应**看到「能解析但返回 `2001::1` / `31.13.x`」——那是回落明文的标志。

---

## 10. 失败排查树

```text
症状：客户机完全无法解析
├─ :53 有监听吗？ ── 否 → dnsmasq 挂了（§2.1）
└─ 是 → dnsmasq 的上游是 127.0.0.1#5353 吗？
   ├─ 否 → 收敛器没跑（§2.3）
   └─ 是 → :5353 有监听吗？
      ├─ 否 → dnsproxy 没起来
      │      ├─ /etc/init.d/dnsproxy start 的输出现"由 dnschain 框架托管" → 正常，看 dnschain
      │      └─ /etc/init.d/dnschain start 的输出 → 看 preflight 报错
      └─ 是 → 查 dnsproxy 日志（logread | grep dnsproxy）

症状：国内域名正常，国外域名全失败
├─ :5335 有监听吗？
│  ├─ 否 → 过滤器没起来
│  │      ├─ dnschain.main.enabled=0？ → 打开
│  │      └─ preflight 拒绝了？ → 看 logread | grep dnschain | grep ERROR
│  └─ 是 → 持有者是 chinadns-ng 吗？
│     ├─ 否 → 端口被 mosdns/dns2tcp 占了 → SSR 模式不是 0（§2.3）
│     └─ 是 → :1234 有监听吗？
│        ├─ 否 → SSR-Plus 没运行
│        └─ 是 → 过滤器的 DoT 出站通吗？（§5.3）
│           ├─ 否 → ss_spec_output 端口集不含 853，或 853 被墙
│           └─ 是 → 看过滤器日志

症状：国外域名能解析但返回 2001::1 / 31.13.x（污染）
├─ 直连 :5353 查同一个域名，也是污染吗？
│  ├─ 是 → 域名分流文件没生效
│  │      ├─ upstreams-domains.txt 是 0 条？ → 生成失败（§7.1）
│  │      ├─ dnsproxy cmdline 里没有该文件？ → 参数生成失败（§7.2）
│  │      └─ 域名不在文件里？ → 名单没覆盖（已知边界，ADR R-3）
│  └─ 否 → 是 dnsmasq 走了旧缓存 → kill -HUP $(pidof dnsmasq)

症状：国外 AAAA 返回真实地址（不是 EMPTY）
├─ 过滤器 cmdline 里有 -N 吗？
│  ├─ 没有 → 参数生成失败
│  └─ 有 → 是 -N tag:gfw 还是裸 -N？
│     └─ 裸 -N 也生效，但检查 tag 是否匹配（-d gfw 下未匹配域名也归 tag:gfw）
└─ 该域名在 gfw 名单里吗？（不在 → 走国内上游，本来就不抑制）

症状：客户机连 baidu 都解析不了，过一阵自己好
└─ 这是 v2ray 抢 :53 socket 的经典症状（AGENTS §4.3）
   netstat -lnup | grep -c '192.168.3.254:53'   # 应恒为 1
   nft list chain ip ss_spec_mangle prerouting | grep -o 'dport { [^}]*}'
   # 端口表里**不能**有 53
```

---

## 11. 回滚

### 11.1 只回退框架（保留固件）

```sh
uci set dnschain.main.enabled='0'
uci commit dnschain
/etc/init.d/dnschain stop
/etc/init.d/dnsproxy restart    # 回到按 /etc/config/dnsproxy 启动
```

回退后链路回到「dnsmasq → dnsproxy（国内 DoH）+ gfw 旁路 → mosdns」，即 ADR-0003 §2 描述的现状。

**注意**：回退后 `pdnsd_enable` 仍是 `0`，`:5335` 无人监听 → gfw 域名全失败。需同时：

```sh
uci set shadowsocksr.@global[0].pdnsd_enable='4'
uci commit shadowsocksr
/etc/init.d/shadowsocksr restart
```

### 11.2 完整回退到上一版固件

按 AGENTS §6 第 10 条：改动前应已备份到 `/root/dnschain-backup-<ts>/`。

```sh
ls -d /root/dnschain-backup-* 2>/dev/null
# 恢复：cp -a /root/dnschain-backup-<ts>/. /
```

---

## 12. 验证记录表（刷机后填写）

| # | 检查项 | 命令出处 | 结果 | 备注 |
|---|---|---|---|---|
| 1.1 | overlay 8 个文件就位 | §1.1 | ☐ PASS ☐ FAIL | |
| 1.2 | **LuCI 页面 6 个文件 + opkg 包** | §1.2 | ☐ PASS ☐ FAIL | **v0.9.0 曾整层缺失** |
| 1.3 | 执行位 | §1.3 | ☐ PASS ☐ FAIL | |
| 1.4 | 运行时依赖包版本 | §1.4 | ☐ PASS ☐ FAIL | |
| 2.1 | 端口监听 | §2.1 | ☐ PASS ☐ FAIL | |
| 2.2 | `:5335` 属 chinadns-ng | §2.2 | ☐ PASS ☐ FAIL | |
| 2.3 | SSR 三个键 | §2.3 | ☐ PASS ☐ FAIL | |
| 3.1 | 缓存层唯一 | §3.1 | ☐ PASS ☐ FAIL | |
| 3.2 | 两份答案消失 | §3.2 | ☐ PASS ☐ FAIL | **最强证据** |
| 4 | 四类域名解析 | §4 | ☐ PASS ☐ FAIL | |
| 5.2 | IP 层分流 | §5.2 | ☐ PASS ☐ FAIL | |
| 5.3 | 出站层代理 | §5.3 | ☐ PASS ☐ FAIL | |
| 6.1 | 853 规则在位 | §6.1 | ☐ PASS ☐ FAIL | |
| 6.2 | 853 从客户机被拒 | §6.2 | ☐ PASS ☐ FAIL | |
| 6.3 | 国内 IPv6 可用 | §6.3 | ☐ PASS ☐ FAIL | |
| 7.1 | 名单生成规模 | §7.1 | ☐ PASS ☐ FAIL | |
| 7.2 | dnsproxy 加载文件 | §7.2 | ☐ PASS ☐ FAIL | |
| 7.3 | 自动导入 | §7.3 | ☐ PASS ☐ FAIL | |
| 8.3 | 收敛器改回三个键 | §8.3 | ☐ PASS ☐ FAIL | **核心诉求** |
| 8.4 | 自检 16 项 | §8.4 | ☐ PASS ☐ FAIL | |
| 9 | 降级矩阵 | §9 | ☐ PASS ☐ FAIL | 可选 |

**全部 PASS 后**，才算「框架真的落地」。任一项 FAIL，按 §10 排查并在备注里记下 `logread | grep dnschain` 的相关行。

---

## 12.1 构建产物预检（刷机**前**做，不必等刷完）

刷机前就能确认产物是否完整，避免「刷完才发现页面没有」。
在**能读固件的机器上**执行（Linux 或 WSL）。

```sh
# 1. 解出 squashfs（偏移随镜像不同，用这条命令找）
IMG=openwrt-x86-64-ssrplus-vX.Y.Z-abcdef0-squashfs-combined-efi.img.gz
gunzip -c "$IMG" > /tmp/fw.img
OFF=$(python3 - <<'PY'
data = open('/tmp/fw.img','rb').read(1024*1024*16)
i = data.find(b'hsqs')
print(i if i >= 0 else -1)
PY
)
echo "squashfs 偏移: $OFF"
tail -c +$((OFF + 1)) /tmp/fw.img > /tmp/root.squashfs

# 2. 列出全部 dnschain 相关条目（含权限）
unsquashfs -ll /tmp/root.squashfs | grep -E 'dnschain|applechina'

# 3. 逐项核对（数量与权限）
unsquashfs -ll /tmp/root.squashfs | grep -cE 'dnschain'          # 期望 >= 14
unsquashfs -ll /tmp/root.squashfs | grep 'init.d/dnschain'       # 期望 -rwxr-xr-x
unsquashfs -ll /tmp/root.squashfs | grep 'rc.d/S95dnschain'      # 期望 symlink 存在
unsquashfs -ll /tmp/root.squashfs | grep 'luci/menu.d/luci-app-dnschain.json'  # 期望存在
```

**⚠️ 不要用 `unsquashfs -l <path>` 判断单个文件是否存在。**
实测该命令对**不存在的路径也返回 0**，会把缺失误报成存在
（v0.9.0 我就因此把「LuCI 页面全缺」误判成「13 项全 OK」）。
必须用 `-ll` 列全量再 grep。

| 期望条目 | 说明 |
|---|---|
| `etc/config/dnschain` | overlay |
| `etc/init.d/dnschain` | 权限 `-rwxr-xr-x` |
| `etc/rc.d/S95dnschain` + `K10dnschain` | symlink，说明已 enable |
| `etc/uci-defaults/99-zz-dnschain` | 权限 `-rwxr-xr-x` |
| `etc/capabilities/dnschain-filter.json` | |
| `etc/ssrplus/applechina.conf` | 9411 字节左右 |
| `usr/bin/dnschain-reconcile` | 权限 `-rwxr-xr-x` |
| `usr/bin/dnschain-selftest` | 权限 `-rwxr-xr-x` |
| `usr/share/dnschain/dnschain.sh` | 权限 `-rwxr-xr-x` |
| `usr/share/luci/menu.d/luci-app-dnschain.json` | **LuCI 页面（v0.9.0 曾整层缺失）** |
| `usr/share/rpcd/acl.d/luci-app-dnschain.json` | **同上** |
| `usr/lib/lua/luci/controller/dnschain.lua` | **同上** |
| `usr/lib/lua/luci/model/cbi/dnschain/general.lua` | **同上** |
| `usr/lib/lua/luci/model/cbi/dnschain/dnschain.lua` | **同上** |

任一项缺失 → 不要刷机，先查 CI 日志的
`=== dnschain 本体与中文语言包都必须入配置 ===` 与 `Add luci-app-dnschain` 两段。

---

## 13. 已知边界（不属故障，不要误判）

| # | 现象 | 原因 | 处置 |
|---|---|---|---|
| B1 | 名单外的被墙域名拿到污染答案 | 域名名单法的固有缺口（ADR R-3） | 加到 `black.list`，或点页面「立即更新 GFW 名单」 |
| B2 | 124 个 IDNA 域名不在 `upstreams-domains.txt` | dnsproxy 不认 `xn--`（ADR §2.4） | 已由 dnsmasq 的 punycode 旁路覆盖，无需处理 |
| B3 | 境外**字面 IPv6 地址**仍直连 | ADR-0002 的既有取舍 | 不在本框架范围 |
| B4 | 443 上的第三方 DoH 无法完全拦截 | 无法在不做 SNI 检查下区分 | 页面已标注「不保证」 |
| B5 | `-A` 写入的 IP 会被 `ssr-rules` 重建时 flush | 主判据是 IP 段（ADR §5.2） | 属增强项，不承诺持久 |
| B6 | 应用配置时约 1–2 秒解析中断 | dnsproxy 重载 2.36 万条域名文件 | 正常，页面有提示 |
| B7 | 拦截开关切换时约 3 秒中断 | 改 `dhcp-option` 需 restart dnsmasq | 正常，页面有提示 |
| B8 | `coexist` 档案下两条路径不收敛 | 框架不重写 SSR 的文件（ADR §7.3） | 已知代价，页面有说明 |

---

## 14. 与 ADR-0003 的对应关系

| ADR-0003 章节 | 本文对应 | 说明 |
|---|---|---|
| §2 现状基线 | §1 | 刷机后确认组件就位 |
| §4 目标链路 | §2、§3 | 端口所有权 + 缓存层 |
| §5 分流三层 | §4、§5 | DNS / IP / 出站 |
| §6 双栈与加密 | §4、§6 | AAAA 策略 + 853 |
| §7 端口档案 | §2 | `primary` / `coexist` |
| §8 页面 | §8.4 | 自检表格 |
| §9 六道闸 | §8 | 抗「改 LuCI 就坏」 |
| §10 配置要点 | §7 | 名单与参数 |
| §11 自检清单 | §8.5 | 16 项 |
| §12 降级矩阵 | §9 | 五处故障 |
| §13 落地清单 | §1 | 文件与包 |
| §14 风险 | §13 | 已知边界 |
