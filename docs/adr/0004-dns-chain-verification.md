# ADR-0004：DNS 分流全链路验证规程

- 状态：**生效**（2026-10-20；2026-10-23 按 v0.10.0–v0.14.8 代码逐项更正）
- 适用：刷入含 `dnschain` 框架的固件后，逐项验证链路是否按
  [ADR-0003](0003-dns-chain-framework.md) 工作
- 前置：路由器 `192.168.3.254`（OpenWrt 24.10.5 x86/64）、本机 Windows `192.168.3.238`
- 定位：**这是一份执行规程，不是设计文档。** 设计见 ADR-0003；
  本文只回答「刷完机怎么验、每项看什么、失败说明什么」

> **v0.10.0 起的两条根本变化，先读再执行：**
>
> 1. **`chinadns-ng` 已移除。` :5335` 必须无监听。**
>    （`files/usr/bin/dnschain-selftest:220-231`）
> 2. **自检是 20 项，不是 16 项。**
>    （`files/usr/bin/dnschain-selftest` 的 `emit 1` … `emit 20`）
>
> 本文所有与 v0.9.x 不同的判据都标注了 **【已更正】** 并给出代码证据。

---

## 0. 使用方式

```text
按 §1 → §12 顺序执行。每一节都有「命令 / 期望 / 失败含义」三栏。
任一项 FAIL 时，先看该节的「失败含义」，再按 §11 的排查树定位。
不要跳步：后面的检查依赖前面的状态。
```

**证据纪律**（每一条都有历史教训，见 `AGENTS.md` §6）：

| # | 纪律 | 为什么 |
|---|---|---|
| E1 | 必须用**客户机真实地址** `192.168.3.254:53` 测，不能只测 `127.0.0.1:53` | 两者可能给出不同答案（`AGENTS.md` §4.3） |
| E2 | DNS 结果必须分 **OK / EMPTY / NX / TIMEOUT / FAIL** 五类 | 把 `EMPTY` 当失败会得出「国内也全挂」的错误结论（`AGENTS.md` §6 第 2 项，`:673`） |
| E3 | 测延迟**不能用 `date +%s%N`** | BusyBox 不支持，静默返回秒级值 → 全部显示 0ms |
| E4 | 判断进程存在**不能用 `pgrep -x <名字>`** | SSR-Plus 的二进制以完整路径运行，`pgrep -x` 恒为 0 |
| E5 | 改配置前先备份 `/etc/config/*` 与 `/var/etc/dnschain/*` | 回滚需要（`AGENTS.md` §6 第 10 条） |
| E6 | 结论必须来自**命令输出**，不能来自「配置里写了」 | 旧 ADR 的失败根源正是把设计意图当既成事实 |
| E7 | **overlay 文件在 ≠ 功能在**。必须分两层查：`files/` 的 overlay 与 `package/` 的 LuCI 页面 | v0.9.0 首次构建：overlay 全部就位，但 LuCI 页面**一个都没有**，而构建全绿 |
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
         /usr/bin/dnschain-health \
         /etc/uci-defaults/99-zz-dnschain \
         /etc/capabilities/dnschain-filter.json \
         /etc/ssrplus/applechina.conf; do
  [ -e "$f" ] && echo "OK   $f" || echo "MISS $f"
done
```

| 期望 | 失败含义 |
|---|---|
| 9 项全 `OK` | 有 `MISS` → overlay 未合并，或 CI 未把文件打进固件 |

**【已更正】** 原文清单是 8 项，漏了 `/usr/bin/dnschain-health`。
该脚本是 v0.13.0 新增的健康探测与改道后端，也是页面所有按钮的实际执行者
（`package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua:428`、`:452`、`:467`、`:508`、`:846`、`:865`、`:872`）。
缺它时页面按钮会静默无反应。

**两个文件的实际用途**（原文只列名未说明）：

| 文件 | 用途 | 现状 |
|---|---|---|
| `/etc/capabilities/dnschain-filter.json` | 声明 `CAP_NET_ADMIN`/`CAP_NET_BIND_SERVICE`/`CAP_NET_RAW` | **无消费者**。两个 procd 实例都没引用它（`files/etc/init.d/dnschain:274-317` 只做 jail-mount）；唯一引用 `/etc/capabilities/` 的是 `files/etc/init.d/dnsproxy:319`（用 `dnsproxy.json`）。属 chinadns-ng 时代遗留 |
| `/etc/ssrplus/applechina.conf` | Apple 域名的独立解析路径 | **173 条 `server=` 全部指向 `127.0.0.1#5353`**，191 行中 18 行注释；含 `114.114.114.114` 的只有第 4 行那条注释 |

### 1.2 第二层：LuCI 页面（`package/luci-app-dnschain` 提供）

**这一层必须单独查。** 它由 opkg 包安装，与 `files/` overlay 是两条独立路径；
包没编进去时，overlay 文件依然全在。

```sh
opkg list-installed | grep -E 'luci-app-dnschain|luci-i18n-dnschain'

for f in /usr/share/luci/menu.d/luci-app-dnschain.json \
         /usr/share/rpcd/acl.d/luci-app-dnschain.json \
         /usr/lib/lua/luci/controller/dnschain.lua \
         /usr/lib/lua/luci/model/cbi/dnschain/general.lua \
         /usr/lib/lua/luci/model/cbi/dnschain/dnschain.lua; do
  [ -e "$f" ] && echo "OK   $f" || echo "MISS $f"
done
```

| 期望 | 失败含义 |
|---|---|
| `opkg` 有 `luci-app-dnschain` 与 `luci-i18n-dnschain-zh-cn` | 包未编入 → CI 的 `Add luci-app-dnschain` 步骤缺失，或 `.config` 里符号被依赖求解丢弃（查 CI 日志 `=== dnschain 本体与中文语言包都必须入配置 ===`，`.github/workflows/build-openwrt.yml:857-883`） |
| 5 个文件全 `OK` | 有 `MISS` → 包装了但内容不全，检查 `package/luci-app-dnschain/` 的 `root/` 与 `luasrc/` 布局 |

**关于 `.lmo`（中文翻译二进制）：本页不需要它。** 本页 `translate()` 里直接写中文
（`msgid` 与 `msgstr` 都是中文），`po2lmo` 不产出有效映射表 → 没有 `.lmo`；
LuCI 找不到翻译时回退到原文，而原文就是中文。

| 包 | `translate()` 参数 | 需要 `.lmo` |
|---|---|---|
| `luci-app-trafficctl` | 英文 | **是** |
| `luci-app-dnschain` | 中文 | 否（回退到原文） |

**最后确认页面真的能打开**：浏览器访问
`http://192.168.3.254/cgi-bin/luci/admin/services/dns_chain`。

**【已更正】** 原文写 `admin/network/dns_chain`。v0.12.1 起页面移到
**服务 → DNS 分流**，`order=20`，紧接 ShadowSocksR Plus+（`order=10`）下一行：

- `package/luci-app-dnschain/root/usr/share/luci/menu.d/luci-app-dnschain.json:2`
  （`"admin/services/dns_chain"`）
- `package/luci-app-dnschain/luasrc/controller/dnschain.lua:37-39`
  （`entry({"admin", "services", "dns_chain"}, …)`）

访问旧路径 `admin/network/dns_chain` 返回 404 属**正常**，不是故障。

### 1.3 执行位

```sh
ls -l /etc/init.d/dnschain \
      /usr/bin/dnschain-reconcile \
      /usr/bin/dnschain-selftest \
      /usr/bin/dnschain-health \
      /usr/share/dnschain/dnschain.sh
```

| 期望 | 失败含义 |
|---|---|
| 五项均 `-rwxr-xr-x` | 缺 `x` → CI 的 `chmod +x` 清单没覆盖到，服务起不来 |

**【已更正】** 原文要求三个脚本，且未说明执行位的来源。实际：

- **仓库 git 索引里只有 `files/usr/bin/dnschain-health` 是 `100755`**，
  其余四个（`dnschain-reconcile`、`dnschain-selftest`、`dnschain.sh`、
  `etc/init.d/dnschain`）是 `100644`。
  验证方式：`git ls-files -s files/usr/bin/dnschain-* files/usr/share/dnschain/dnschain.sh files/etc/init.d/dnschain`
- 执行位完全依赖 CI 的 `chmod +x` 清单兜住：
  `.github/workflows/build-openwrt.yml:986-992`
- 因此**若 CI 那一步被跳过或改动，固件里的脚本不可执行**。这条属已知脆弱点
  （ADR-0003 §14 R-8）。

### 1.4 运行时依赖包

```sh
opkg list-installed | grep -E 'luci-app-dnschain|luci-i18n-dnschain|dnsproxy|dnsmasq'
```

| 期望 | 失败含义 |
|---|---|
| `dnsproxy` 为 `0.83.0` 而非 `0.56.2` | 版本错 → CI 的 `Align dnsproxy feed link` 失效 |
| `dnsmasq` 为 `dnsmasq-full` | 精简版缺 `nftset` 支持 → `nftset=` 行无效 |

**【已更正】** 原文要求「`chinadns-ng` 存在（版本 `2025.06.20-1`）」。
**该要求已作废**：框架不依赖 chinadns-ng，`:5335` 必须无监听（§2.1）。

⚠️ 注意仓库里仍有一处矛盾：`.github/workflows/build-openwrt.yml:687` 仍写
`CONFIG_PACKAGE_chinadns-ng=y`，而同文件 `:864-867` 明确写「不再要求」。
两者并存说明该 `=y` 是残留（SSR-Plus 的 `INCLUDE_ChinaDNS_NG` 本来也会带入二进制）。
**二进制在不在都不影响框架**，但不要因此以为框架需要它。

---

## 2. 端口所有权（最容易出错的一节）

**这是全链路的地基。**

### 2.1 谁在监听关键端口

```sh
netstat -lnup 2>/dev/null | grep -E ':(53|5353|5336|1234)\b'
netstat -lntp 2>/dev/null | grep -E ':(53|5353|5336|1234|853)\b'
```

| 期望 | 失败含义 |
|---|---|
| `:53` → dnsmasq | 被别的进程占了 → DNS 全断 |
| `:5353` → dnsproxy（实例 1） | 无监听 → 客户机全部无法解析 |
| `:5336` → dnsproxy（实例 2） | 无监听 → 国外域名全失败（国内正常） |
| `:1234` → v2ray / xray | 无监听 → 国外域名全 SERVFAIL |
| `:853` **无 UDP 监听** | 有监听 → 可能误开了 dnsproxy 的 DoT 服务端（与 T2 冲突） |

**【已更正】** 原文的 grep 集合是 `(53|5353|5335|5337|1234)`，两处都错：

1. **漏了 `5336`** —— 国外实例端口（`files/etc/config/dnschain:50`）。
   漏掉它时「国外域名全失败」会被误判成「代理挂了」。
2. **`5335` 与 `5337` 都不该出现**。`5335` 是已移除的 chinadns-ng 端口，
   它出现反而是故障（§2.2）；`5337` 全仓库不存在（只有 PO 里的历史文案）。

### 2.2 `:5335` 必须无监听

```sh
netstat -lnup 2>/dev/null | grep ':5335' && echo "FAIL :5335 有监听" || echo "OK :5335 空闲"
```

| 期望 | 失败含义 |
|---|---|
| **无输出**（`OK :5335 空闲`） | 有监听 → 有进程占用了已移除组件的端口，会污染国外解析（自检第 6 项 FAIL） |

**【已更正】** 原文 §2.2 整节在查「`:5335` 的持有者是不是 chinadns-ng」、
期望 `cmdline 含 chinadns-ng、-l 5335、-d gfw、-N tag:gfw`。
**该判据已完全反转**：`:5335` 现在必须是空的。

判据实现：`files/usr/bin/dnschain-selftest:220-231`
（`dc_port_owner 5335 udp` 为空 → PASS）。

若 `:5335` 被占，看是谁：

```sh
PID=$(netstat -lnup 2>/dev/null | awk '$4 ~ /:5335$/ {print $NF}' | sed 's|/.*||' | head -1)
tr '\0' ' ' < /proc/$PID/cmdline; echo
```

常见占用者：SSR-Plus 的 `pdnsd_enable` 不是 `0`/`7`（它会起 mosdns 或 dns2tcp 绑该端口）。
自检第 7 项会同时报出 `pdnsd_enable` 的实际值（`files/usr/bin/dnschain-selftest:245-246`）。

### 2.3 SSR-Plus 的模式与三个强制键

```sh
uci -q get shadowsocksr.@global[0].pdnsd_enable    # 期望 0 或 7
uci -q get shadowsocksr.@global[0].enable_switch  # 期望 0
uci -q get shadowsocksr.@global[0].ipv6_support   # 期望 1
uci -q get shadowsocksr.@global[0].filter_aaaa    # 期望 0（偏好值）
uci -q get dhcp.@dnsmasq[0].filter_aaaa           # 期望 0（实际生效值）
uci -q get shadowsocksr.@global[0].global_server  # 期望节点名，不能是 nil
```

| 键 | 期望 | 失败含义 |
|---|---|---|
| `pdnsd_enable` | `0` 或 `7` | 是 `4` → `99-zz-dnschain` 未生效（排序问题）或未点「一键归一」 |
| `enable_switch` | `0` | 是 `1` → 周期性 restart，会造成 DNS 空窗（`AGENTS.md` §4.1） |
| `ipv6_support` | `1` | 不是 `1` → 国外 AAAA 会拿到真实值却直连 → 被 RST |
| `dhcp.@dnsmasq[0].filter_aaaa` | `0` | 不是 `0` → AAAA 被砍，自检第 11 项 FAIL |
| `global_server` | 非 `nil` | 是 `nil` → SSR 一条规则都不装，客户机全挂（`AGENTS.md` §4.2） |

**【已更正】** 原文 §2.3 只查 `filter_aaaa` 并期望 `1`。实际：

- 期望值是 **`0`**（`files/etc/uci-defaults/99-zz-dnschain:75-80`、
  `files/usr/bin/dnschain-reconcile:97-98`）。
- **必须读 `dhcp.@dnsmasq[0].filter_aaaa`**，`shadowsocksr` 那个是用户偏好，
  会被 `ipv6_support=1` 覆盖（自检第 7 项只读前者，
  `files/usr/bin/dnschain-selftest:243-252`；页面「实际生效值」并列显示两者，
  `general.lua:1444-1454`）。
- 原文漏了 `ipv6_support` 这一项。

**若 2.1/2.2/2.3 任一不符，停在这里。** 后面的检查都依赖端口归属正确。

---

## 3. 缓存层唯一性

ADR-0003 §10.5 的核心约束：缓存只在 dnsmasq。

> **【已更正】** 原文引用「ADR-0010 §10.5」。仓库只有 `0001`–`0006`，
> 没有 ADR-0010。正确出处是 **ADR-0003 §10.5**。

### 3.1 两层的缓存开关

```sh
# dnsmasq：应有 cache-size
grep -E '^cache-size' /var/etc/dnsmasq.conf.* 2>/dev/null

# 两个 dnsproxy 实例都**不应**有 --cache
for port in 5353 5336; do
  PID=$(netstat -lnup 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print $NF}' | sed 's|/.*||' | head -1)
  echo "--- :$port pid=$PID ---"
  [ -n "$PID" ] && tr '\0' '\n' < /proc/$PID/cmdline | grep -E '^--cache' \
    && echo "FAIL :$port 有缓存" || echo "OK :$port 无缓存"
done
```

| 期望 | 失败含义 |
|---|---|
| dnsmasq `cache-size=8192`（或页面配置值）；两个实例都无 `--cache` | 任一实例有缓存 → 同一域名可能出现两份答案 |

**【已更正】** 原文 §3.1 用 `PID=$(pidof dnsproxy)` 取单实例。
**实际有两个 dnsproxy 实例**，`pidof dnsproxy` 返回 2 个 PID，
`/proc/$PID/cmdline` 会因 `$PID` 含空格而报错或只读到第一个。

仓库自己的正确写法是 `dc_port_owner`（按端口反查 PID）：

```sh
# files/usr/share/dnschain/dnschain.sh:101-117
dc_port_owner() {
  pid=$(netstat -lnup 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print $NF}' \
        | sed 's|/.*||' | head -1)
}
```

自检第 5 项用的是 `dc_port_owner "$entry" udp`
（`files/usr/bin/dnschain-selftest:204`）。

### 3.2 两份答案是否真的消失

```sh
echo "--- 经 dnsmasq:53 ---"
nslookup www.google.com 127.0.0.1 2>&1 | grep '^Address: [0-9]'
echo "--- 直连国内实例 :5353 ---"
nslookup www.google.com 127.0.0.1:5353 2>&1 | grep '^Address: [0-9]'
echo "--- 直连国外实例 :5336 ---"
nslookup www.google.com 127.0.0.1:5336 2>&1 | grep '^Address: [0-9]'
```

| 期望 | 失败含义 |
|---|---|
| 三处都不返回 `2001::1` / `31.13.x` / `104.244.x` / `157.240.x` | 直连 `:5353` 返回污染值 → 该实例用了国内上游答国外域名（这是污染） |

**这是判断「框架是否真的接管」的最强单条证据。**

**【已更正】** 原文只测 `:5353` 一处。现行有两个实例，**必须分别测**：
`:5336` 是国外域名的真正出口，只测 `:5353` 会漏掉国外实例的配置错误。

污染值判据（自检用的同一份，`files/usr/bin/dnschain-selftest:77-84`）：

```sh
is_polluted() {
  case "$1" in
    2001::1|2001:0:0:0:0:0:0:1) return 0 ;;
    31.13.*|157.240.*|104.244.*) return 0 ;;
    *) return 1 ;;
  esac
}
```

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
| `www.baidu.com` | A | 真实国内 IP | 空 → dnsmasq 或国内实例挂 |
| `www.taobao.com` | AAAA | **真实 IPv6**（`240e:*`） | 空 → 国内 AAAA 被误砍 |
| `www.google.com` | A | Google 真实 IP（`142.251.x`） | `2001::1`/`31.13.x`/`104.244.x` → 污染；空 → 国外实例或代理挂 |
| `www.google.com` | AAAA | **真实 AAAA**（`2001:4860:x`） | **`EMPTY` → 被抑制了（v0.10.0 起这是故障）**；`TIMEOUT` → 会卡客户端 5 秒 |
| `www.youtube.com` | AAAA | **真实 AAAA** | 同上 |
| `www.wikipedia.org` | A | 真实（`103.102.x` 等） | `2001:df2:...` → 污染 |
| `www.github.com` | A | 真实 | 空 → 代理挂 |

**【已更正】** 原文 §4 期望国外 AAAA 为 **EMPTY**（抑制）。**语义已反转**：
v0.10.0 起国外 AAAA 必须为 `OK`，`EMPTY` 判 FAIL
（`files/usr/bin/dnschain-selftest:282-293`，其中 `:290` 明确写
「被抑制了（应为 OK）——检查 ipv6_support 与 chinadns-ng 是否残留」）。

**仍然有效的区分**：`EMPTY`（rcode=0 ancount=0，合法答复）与 `TIMEOUT`
（完全无响应，卡客户端 5 秒）是两回事。现在两者对国外 AAAA 都是故障，
但**故障原因不同**：`EMPTY` = 被抑制，`TIMEOUT` = 链路不通。

---

## 5. 分流三层是否都生效

ADR-0003 §5 说「分三层，缺一层都会看起来配好了但实际不对」。

### 5.1 DNS 层（决定客户机拿到哪种地址）

已由 §4 覆盖。核心是：**国内双栈、国外也双栈**（国外 IPv6 经代理）。

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
| `ss_spec_wan_ac` 的规则顺序与 ADR-0003 §5.2 一致 | 顺序变了 → SSR-Plus 版本升级，需重新核对 |
| `blacklist` 元素数 > 0 且**随访问国外站点增长** | 恒为 0 → `nftset=` 没生效（见下） |
| `china` 元素数 > 0 | 0 → `china_ssr.txt` 未加载，所有流量都会走代理 |

**注意**：计数正则会命中 `flags interval` 与 `auto-merge` 两行元数据，
空集合恒得 **2**。所以 `=2` 表示「无元素」。

**【已更正】** 原文 §5.2 写「`china` 约 1493 行元素」，而 ADR-0003 原文写
「3794（源 4318 条 CIDR，auto-merge 后）」。**两个数字互相冲突，且都不可复现**：

- `ss_spec` 表由**上游 SSR-Plus** 生成，本仓库没有规则文件
  （全仓库对 `ss_spec` 只有读取与注释）。
- 元素数随 `china_ssr.txt` 版本与 nft 的区间合并行为变化。
- 页面读的是 `nft list set` 的实时值（`dnschain.lua:346-353`）。

**处置**：两个常量都删除，改为「读实时值，只判 > 0 与是否增长」。
同理，ADR-0003 里的 `whitelist_domain` 95、`blacklist` 7 等数字也只是某时点快照。

**`nftset=` 是否真的在工作**（最直接的判据）：

```sh
# 记下当前条数
n1=$(nft list set inet ss_spec blacklist 2>/dev/null | grep -cE '^\s+[0-9a-f.:]+')
# 访问几个国外站点
for d in www.google.com www.youtube.com www.wikipedia.org; do nslookup "$d" 192.168.3.254 >/dev/null 2>&1; done
sleep 2
n2=$(nft list set inet ss_spec blacklist 2>/dev/null | grep -cE '^\s+[0-9a-f.:]+')
echo "before=$n1 after=$n2"
```

| 期望 | 失败含义 |
|---|---|
| `after > before`（或原本已含这些 IP） | 不增长 → `dnschain-split.conf` 里缺 `nftset=` 行，或 `ss_spec` 表不存在 |

**已知故障形态**：在 SSR-Plus 页面点「保存并应用」时 `ss_spec` 表短暂消失，
若此时框架生成分流片段，会写出「23714 条 `server=` 但 0 条 `nftset=`」的片段
（`files/usr/share/dnschain/dnschain.sh:957-971` 记录了实测）。
现行有两道兜底：生成时沿用上一版 `nftset` 行（`:1082-1103`），
收敛器每轮自愈（`files/usr/bin/dnschain-reconcile:164-189`）。

自检第 16 项与第 2 项都不直接查 `nftset` 条数，所以**这一项必须手工验**。

### 5.3 出站层（路由器自身的 DoH 是否经代理）

```sh
nft list chain inet ss_spec ss_spec_output
```

| 期望 | 失败含义 |
|---|---|
| 端口集含 **443**、**不含 53**；只匹配 `tcp` | 不含 443 → 路由器自身 DoH 直连被墙，国外域名全超时；含 53 → 会触发 v2ray socket 堆积（`AGENTS.md` §4.3） |

**实测出站是否真的经代理**：

```sh
# 发起一次国外解析，然后看国外实例的连接
nslookup www.google.com 127.0.0.1:5336 >/dev/null 2>&1
sleep 1
netstat -antp 2>/dev/null | grep -E ':443' | grep -E 'dns\.google|cloudflare-dns' | head -3
```

| 期望 | 失败含义 |
|---|---|
| 有到 DoH 上游的 `ESTABLISHED` | 无连接 → 国外实例没在上游查询，或 DoH 被墙 |

**【已更正】** 原文 §5.3 测的是「过滤器到 `8.8.8.8:853` 或 `1.1.1.1:853` 的 ESTABLISHED」。
国外上游已改成 DoH（443），**853 上不会有任何连接**。判据改为查 443 上的
DoH 上游连接；自检第 12 项在无活跃连接时判 SKIP（空闲正常），
不是 FAIL（`files/usr/bin/dnschain-selftest:295-307`）。

---

## 6. 双栈与 853 拒绝

### 6.1 853 拒绝规则是否在位且优先级正确

```sh
cat /etc/nftables.d/15-dnschain-reject-dot.nft
nft list chain inet fw4 dnschain_reject_dot
```

| 期望 | 失败含义 |
|---|---|
| 文件里是**裸 chain**（无 `table` 声明） | 有 `table` → fw4 整个 ruleset 不加载 → 断网（`AGENTS.md` 红线 7） |
| `nft list` 显示 `priority mangle - 1`（即 -151） | 显示别的优先级 → 会被 tproxy（`mangle` = -150）抢先 |

生成代码：`files/etc/init.d/dnschain:233-269`（chain 体在 `:250-254`）。
关闭时不删文件、只清成注释占位（`:256-263`）。

### 6.2 从客户机验证 853 真的被拒

**在本机（`192.168.3.238`）执行**，不是路由器：

```powershell
Test-NetConnection 8.8.8.8 -Port 853 -InformationLevel Quiet
```

或：

```powershell
curl -sv --max-time 5 https://8.8.8.8:853/ 2>&1 | Select-String 'refused|timed out|Connected'
```

| 期望 | 失败含义 |
|---|---|
| 快速 `refused` / 连接被重置 | 若成功建立 → 853 拒绝规则没生效，客户端可绕过 AAAA 策略 |

### 6.3 国内与国外 IPv6 都可用

**在本机执行**：

```powershell
Resolve-DnsName www.taobao.com -Type AAAA -Server 192.168.3.254
curl -6 -sI --max-time 10 https://www.taobao.com | Select-Object -First 1

Resolve-DnsName www.google.com -Type AAAA -Server 192.168.3.254
curl -6 -sI --max-time 10 https://www.google.com | Select-Object -First 1
```

| 期望 | 失败含义 |
|---|---|
| 国内：解析出 `240e:*` 且 `curl -6` 有响应 | 解析出但连不上 → IPv6 出口问题；解析不出 → 国内 AAAA 被砍了 |
| 国外：解析出真实 AAAA 且 `curl -6` 有响应（302） | 解析出但连不上 → IPv6 代理链没装（`ipv6_support` 不是 1） |

**【已更正】** 原文 §6.3 只测国内 IPv6（`www.taobao.com`）。国外 IPv6 现在是
**必须能用**的（经代理），所以要一并测。

---

## 7. 名单与分流产物

### 7.1 生成物是否存在且规模合理

```sh
ls -l /var/etc/dnschain/
wc -l /var/etc/dnschain/db-domains.txt \
      /var/etc/dnschain/foreign-split.conf \
      /var/etc/dnschain/custom-domestic.txt \
      /var/etc/dnschain/custom-foreign.txt
grep -c '^server=' /tmp/dnsmasq.d/dnschain-split.conf
grep -c '^nftset=' /tmp/dnsmasq.d/dnschain-split.conf
cat /var/run/dnschain/lists.fingerprint
```

| 产物 | 期望 | 失败含义 |
|---|---|---|
| `db-domains.txt` | > 0（量级 1.7 万–2.4 万） | 0 → gfw 名单未就绪或生成失败 |
| `foreign-split.conf` | > 0，且**是纯域名清单**（无 `server=` 前缀） | 0 → preflight 会拒绝启动（`files/etc/init.d/dnschain:193-198`） |
| `custom-domestic.txt` / `custom-foreign.txt` | 可以为 0（默认空） | — |
| `dnschain-split.conf` 的 `server=` 行数 | > 0，全部指向 `:5336` | 出现别的端口 → 自检第 2 项 FAIL |
| `dnschain-split.conf` 的 `nftset=` 行数 | **> 0**（`ss_spec` 存在时） | 0 → 国外流量不进代理（§5.2） |

**【已更正】** 原文 §7.1 要求
`/var/etc/dnschain/upstreams-domains.txt` 约 23593 条、`idna-bypass.conf` 约 124 条，
并期望每行形如 `[/域名/]127.0.0.1:5335`。**三个判据全部作废**：

1. **`upstreams-domains.txt` 不再生成，无消费者。** 它是 v0.9.x 单实例方案的产物。
   路由器上该文件可能存在（上一次运行残留），但 dnsproxy 参数里没有它。
   CI 反向断言禁止库脚本再生成 `[/域名/]` 形式
   （`.github/workflows/build-openwrt.yml:1168-1176`）。
2. **`idna-bypass.conf` 不再生成**（`dnschain.lua:12` 的注释记录了该删除）。
   v0.10.0 起 `xn--` 域名并入主分流、**不过滤**（`files/usr/share/dnschain/dnschain.sh:299-308`）。
3. 分流形式的权威判据是 `dnschain-split.conf` 的 `server=/域名/127.0.0.1#5336`。

### 7.2 两个实例真的加载了正确上游

```sh
for port in 5353 5336; do
  PID=$(netstat -lnup 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print $NF}' | sed 's|/.*||' | head -1)
  echo "--- :$port pid=$PID ---"
  [ -n "$PID" ] && tr '\0' '\n' < /proc/$PID/cmdline | grep -E '^--(upstream|timeout|upstream-mode)$' -A1
done
```

| 期望 | 失败含义 |
|---|---|
| `:5353` 的上游是 `tls://223.5.5.5` 等国内加密池 | 上游不对 → 参数文件生成错误 |
| `:5336` 的上游是 `https://dns.google/dns-query` 等 **DoH** | 出现 `tls://` → preflight 本应拒绝启动（`files/etc/init.d/dnschain:200-212`） |
| 两者 `--timeout` 都是 `8s` | 是 `5s` → 旧参数文件残留，需重新生成 |

**【已更正】** 原文 §7.2 查「`--upstream` 后面是不是 `upstreams-domains.txt`」。
`--upstream` 只接 URL，不接文件路径；该判据不成立。

**【已更正】** 原文 §10.1（ADR-0003）写 `--timeout 5s`，实际是 `8s`
（`files/usr/share/dnschain/dnschain.sh:358-359`、`:404-405`）。

### 7.3 自动导入是否工作

```sh
FP1=$(cat /var/run/dnschain/lists.fingerprint)
/usr/bin/lua /usr/share/shadowsocksr/update.lua gfw_data >/dev/null 2>&1
# 手动触发一次收敛（注意：没有定时轮询，见下）
/usr/bin/dnschain-reconcile
FP2=$(cat /var/run/dnschain/lists.fingerprint)
[ "$FP1" != "$FP2" ] && echo "OK 名单已重新导入" || echo "未变化（名单本身可能没更新）"
```

| 期望 | 失败含义 |
|---|---|
| 指纹变化或日志有 `名单源已变化，重新导入` | 无变化 → 名单本身没更新，或 `lists.auto_import=0` |

**【已更正】** 原文 §7.3 写「等收敛器轮询（默认 60s），`sleep 70`」。
**`import_interval` 没有消费者，不存在轮询**：

- `reconcile_lists` 只在被调用时比对一次指纹
  （`files/usr/bin/dnschain-reconcile:245-310`）。
- 收敛器**没有任何自动触发点**（ADR-0003 §9.2 的 N1）：init 不调用它、
  无 procd 触发器、无 cron。它只由页面按钮执行
  （`dnschain.lua:451-469`）。
- `selftest.interval` 同样无消费者，页面自陈「仓库里没有定时调度」
  （`general.lua:1823-1828`）。

所以「自动导入」目前是**手动导入**。`sleep 70` 只会白等。

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
netstat -lnup 2>/dev/null | grep -E ':(5336|5353)\b'
```

### 8.2 故意改坏 SSR-Plus 的三个键

**在 LuCI 页面上**（或直接 `uci set`），依次改：

| 改动 | 命令（也可在页面操作） |
|---|---|
| 把 DNS 模式改回 MosDNS | `uci set shadowsocksr.@global[0].pdnsd_enable='4'; uci commit shadowsocksr` |
| 打开自动切换 | `uci set shadowsocksr.@global[0].enable_switch='1'; uci commit shadowsocksr` |
| 关掉 ipv6 代理 | `uci set shadowsocksr.@global[0].ipv6_support='0'; uci commit shadowsocksr` |

然后 **`/etc/init.d/shadowsocksr restart`**。

**【已更正】** 原文第三项改的是 `filter_aaaa='0'`（当时期望值是 `1`）。
现行期望值是 `0`，改它没有验证价值；真正该改坏的是 `ipv6_support`（期望 `1`）。

### 8.3 验证收敛器把它们改回来

```sh
/usr/bin/dnschain-reconcile
echo "pdnsd_enable=$(uci -q get shadowsocksr.@global[0].pdnsd_enable)   期望 0"
echo "enable_switch=$(uci -q get shadowsocksr.@global[0].enable_switch) 期望 0"
echo "ipv6_support=$(uci -q get shadowsocksr.@global[0].ipv6_support)   期望 1"
echo "filter_aaaa=$(uci -q get shadowsocksr.@global[0].filter_aaaa)     期望 0"
logread | grep dnschain | grep 归一 | tail -5
```

| 期望 | 失败含义 |
|---|---|
| 四个键都被改回；日志有 `归一: … -> …` | 没改回 → 收敛器执行失败（看它的 ERROR 行），或 `ssr.compat.enforce=0` |

**【已更正】** 原文 §8.3 用 `/etc/init.d/dnschain restart` 来「触发收敛」。
**该操作不触发收敛器**：`init.d/dnschain` 全文没有 `reconcile` 调用。
必须直接执行 `/usr/bin/dnschain-reconcile`，或在页面点「一键归一」。

不变量集与行号见 ADR-0003 §9.2（`files/usr/bin/dnschain-reconcile:51-237`）。

### 8.4 链路是否仍然正常

```sh
/usr/bin/dnschain-selftest -f
```

| 期望 | 失败含义 |
|---|---|
| `SUMMARY PASS=20 FAIL=0 SKIP=0`（或 FAIL=0、SKIP≤2） | 有 FAIL → 按 §11 排查 |

**【已更正】** 原文期望 `PASS=16`。实际是 **20 项**（v0.13.0 加了第 17–20 项，
`files/usr/bin/dnschain-selftest:5-6`）。SKIP 可能出现在第 12 项（无活跃 DoH 连接）
与第 20 项（还没有探测数据）。

### 8.5 逐项自检的输出格式

```sh
/usr/bin/dnschain-selftest -f | head -24
```

期望形如（项目名与证据取自 `files/usr/bin/dnschain-selftest` 的实际 `emit` 文案）：

```
1 PASS 客户机 DNS 路径可达 — 192.168.3.254:53 应答 OK
2 PASS 框架分流规则正确 — dnschain-split.conf 全部指向 :5336
3 PASS dnsmasq 唯一默认上游 — server=127.0.0.1#5353 恰好 1 条
4 PASS dnsproxy 在监听 — 127.0.0.1:5353 应答 OK
5 PASS dnsproxy 参数一致 — 无 --cache、无 --fallback、无 --ipv6-disabled
6 PASS 无 chinadns-ng 残留 — :5335 无监听（v0.10.0 已移除该组件）
7 PASS 端口所有权无冲突 — pdnsd_enable=0、ipv6_support=1、dnsmasq.filter_aaaa=0
8 PASS 国内 A 正确 — 192.168.3.254 查 www.baidu.com -> …
9 PASS 国内 AAAA 保留 — www.taobao.com -> 240e:…
10 PASS 国外 A 正确 — www.google.com -> 142.251.…
11 PASS 国外 AAAA 保留 — 返回真实 AAAA（IPv6 经代理出站）
12 SKIP 国外 DoH 出站 — 当前无活跃连接（空闲时正常，可忽略）
13 PASS 代理与分流在位 — ss_spec 表 2 个、:1234 在监听、global_server=…
14 PASS fw4 规则可加载 — fw4 check 通过（复用缓存，输入未变）
15 PASS 无明文旁路 — conf-dir 内无非 127.0.0.1 的 server=
16 PASS 缓存层唯一 — dnsmasq cache-size=8192，dnsproxy 无 --cache
17 PASS 自定义域名列表合法 — 国内 0 条、国外 0 条，格式全部通过
18 PASS 观测域名不与静态片段重复 — watch.servers 与 dnschain-split.conf 无交集
19 PASS 改道通道已就绪 — servers-file=/var/run/dnsmasq/watch.servers（已进 dnsmasq 配置，且在 ujail 白名单内）
20 SKIP 改道状态自洽 — 还没有探测数据（等一轮 interval 或从页面手动触发）

SUMMARY PASS=18 FAIL=0 SKIP=2
CONCLUSION: 链路正常
```

**【已更正】** 原文 §8.5 的样例是 16 项、第 1 项写「dns_intercept_lan 含 udp/tcp dport 53」、
第 2 项写「profile=primary，端口集合 {5335 } 合规」、第 16 项写「其余两层无 --cache」。
三项都与实现不符：

| 项 | 原文样例 | 实际 |
|---|---|---|
| 1 | `dns_intercept_lan 含 udp/tcp dport 53` | `LAN 地址:53 应答 <class>`（`:99-122`） |
| 2 | `profile=primary，端口集合 {5335 } 合规` | `dnschain-split.conf 全部指向 :5336`（`:124-160`） |
| 16 | `其余两层无 --cache` | 只查 `dnsproxy.args` 文件（不是进程 argv，`:404-416`） |
| 4 | （原文无此行） | 项名写「127.0.0.1 与 ::1」，但 `v6`（`[::1]` 探测）算出后**从不使用**，只按 `v4` 判定（`:191-198`） |

**第 4 项的这个缺陷意味着：国外实例只监听 `127.0.0.1`（不监听 `::1`，
`files/usr/share/dnschain/dnschain.sh:389-392`），而国内实例监听两者。
自检第 4 项名义上覆盖 `::1`，实际没有。若要验 IPv6 回环，需手工：**

```sh
nslookup www.baidu.com '[::1]:5353'
```

---

## 9. 降级矩阵验证（可选，但建议做一次）

ADR-0003 §12 声称「任何一处故障都不回落明文」。逐项验证：

| # | 操作 | 期望的客户机症状 | 验证命令 | 恢复 |
|---|---|---|---|---|
| 1 | `killall dnsproxy`（两个实例都会被 procd 重启，先看症状） | **全部域名失败** | 查 baidu 与 google 各一次 | procd 自动 respawn |
| 2 | `/etc/init.d/shadowsocksr stop` | 仅国外域名失败，国内正常 | 同上 | `start` |
| 3 | 临时把国内上游改成不可达 | 国内域名 SERVFAIL，**不回落明文** | 查 `www.baidu.com` | 改回 |
| 4 | 把 `:5336` 的上游改成 `tls://` 后重启 dnschain | **框架拒绝启动**（preflight 硬校验） | `logread \| grep dnschain \| grep ERROR` | 改回 DoH |

**【已更正】** 原文第 1 项是 `killall chinadns-ng`。该进程已不存在，
现在要杀的是 `dnsproxy`（两个实例）。

**关键**：任何一项都**不应**看到「能解析但返回 `2001::1` / `31.13.x`」——
那是回落明文的标志。

第 4 项是新增的：它验证 preflight 的硬校验真的会拦住错误配置
（`files/etc/init.d/dnschain:200-212`）。

---

## 10. `dnschain-health` 子命令与输出格式

**本节为新增。** `dnschain-health` 是页面所有按钮的后端
（`package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua:428`、`:452`、`:467`、`:508`、`:846`、`:865`、`:872`），
验证手册必须覆盖它，否则页面按钮失效时无从定位。

### 10.1 八个子命令

| 子命令 | 作用 | 输出格式 | 证据 |
|---|---|---|---|
| `cycle` | 跑一轮探测与判定（默认子命令） | `CYCLE ok=n switch=n bad=n wait=n`；前置不满足时 `SKIP …` | `files/usr/bin/dnschain-health:351`、`files/usr/share/dnschain/dnschain.sh:1587-1770` |
| `daemon` | 常驻循环，每 `interval` 秒跑一轮 cycle | 无标准输出；日志走 `dnschain_log` | `dnschain-health:318-338` |
| `status` | 打印状态表 + 汇总 | `ROW domain\|class\|pref\|active\|fail\|ok\|last\|result\|chain_state` + `SUM total=… normal=… degraded=… rerouted=… both_bad=… custom=…` | `dnschain-health:76-124` |
| `explain <域名>` | 解释单域名的归属与判定 | 12 个 `KEY=VALUE` 行，见 §10.3 | `dnschain-health:37-43`、`dnschain.sh:1835-1936` |
| `check` | 校验自定义列表格式 | 每行 `BAD <域名> <原因>`，末行 `OK` 或 `FAIL bad=<n>` | `dnschain-health:135-181` |
| `apply` | 重建派生文件并让 dnsmasq 生效 | `SPLIT=<n> <n>` + `DNSMASQ=restarted\|sighup\|unchanged\|skipped（原因）` + `OK`；失败时 `ERROR=…` | `dnschain-health:205-264` |
| `reset` | 清空健康状态并重建 `watch.servers` | `OK 已清空健康状态` | `dnschain-health:272-278` |
| `flush` | 发 SIGHUP 清 dnsmasq 缓存 | `OK=已清空 dnsmasq 缓存（零中断）` 或 `ERROR=…` | `dnschain-health:309-316` |

用法错误时打印：

```
用法: dnschain-health {cycle|daemon|status|explain <域名>|check|apply|reset|flush}
```

（`dnschain-health:360`）

### 10.2 `status` 的 5 档状态

`chain_state` 字段的取值与判定（`dnschain-health:102-112`）：

| 值 | 判定条件 | 含义 |
|---|---|---|
| `unknown` | `result` 为空 | 还没有探测数据 |
| `both-bad` | `result` 以 `both-bad` 开头 | 两条链都不通，必须人介入 |
| `rerouted` | `result` 以 `switch:` / `fallback:` / `recover-wait:` 开头 | 已改道（含等待回切） |
| `degraded` | `result` 以 `probe:` 开头 | 首选链已开始失败，但还没到改道阈值 |
| `ok` | 其余非空值 | 当前链可达 |

**`custom` 不是一档状态**，只是「归属由用户补全」的计数
（`dnschain-health:63-74`、`:99-100`）。

验证方式：

```sh
/usr/bin/dnschain-health status
```

| 期望 | 失败含义 |
|---|---|
| 每个观测域名一行 `ROW`，末尾一行 `SUM` | 无任何 `ROW` → `health.watch` 与内置基准集都为空（不应发生，`dc_watch_list` 有回落） |
| `SUM` 里 `total` = 实际 `ROW` 行数 | 不等 → 状态文件有重复行（并发写入未加锁的旧故障，已修） |

### 10.3 `explain` 的 12 个输出键

```sh
/usr/bin/dnschain-health explain www.google.com
```

输出顺序与含义（`files/usr/share/dnschain/dnschain.sh:1835-1936`）：

| 键 | 含义 | 取值 |
|---|---|---|
| `DOMAIN` | 规范化后的域名 | 小写、去尾点 |
| `CLASS` | 归属 | `custom-domestic` / `custom-foreign` / `db-foreign` / `uncovered` / `invalid` |
| `PREFERRED` | 首选链路 | `domestic` / `foreign` |
| `ACTIVE` | 当前链路 | `domestic` / `foreign` |
| `WATCH` | 是否在观测列表里 | `0` / `1` |
| `CUSTOM` | 归属是否由用户补全 | `0` / `1`（**不表示不参与改道**） |
| `PROBE_DOMESTIC` | 直连链探测结果 | `OK` / `EMPTY` / `NX` / `TIMEOUT` / `FAIL` |
| `PROBE_FOREIGN` | 代理链探测结果 | 同上 |
| `ANSWER_DOMESTIC` | 直连链解析出的首个地址 | 地址或空 |
| `ANSWER_FOREIGN` | 代理链解析出的首个地址 | 地址或空 |
| `DECISION` | 判定 | `keep-domestic` / `keep-foreign` / `reroute-domestic` / `reroute-foreign` / `both-bad` / `reject` |
| `REASON` | 中文原因 | 一句完整说明 |

`CLASS=invalid` 时只输出 `DOMAIN` / `CLASS` / `DECISION=reject` / `REASON`，
其余键缺省（`:1845-1849`）。

| 期望 | 失败含义 |
|---|---|
| 12 个键齐全（`invalid` 时 4 个） | 缺键 → 脚本异常；页面「单域名解释」会把缺失显示为「—」 |

**`DECISION` 必须与 `dc_health_cycle` 的实际动作一致**。两者用的是同一套规则，
但 `explain` 是即时双链探测、`cycle` 是按阈值累计 —— 单次不一致属正常
（`cycle` 需要连续 `fail_threshold` 轮才改道）。

### 10.4 `apply` 的出口必须全解析

页面 `apply_message()` 要求覆盖 5 条正常出口 + `ERROR=` 失败出口
（`general.lua:1926-1978`）。验证方式：

```sh
/usr/bin/dnschain-health apply; echo "rc=$?"
# 不改任何配置再跑一次 → 应输出 unchanged
/usr/bin/dnschain-health apply; echo "rc=$?"
```

| 期望 | 失败含义 |
|---|---|
| 第一次可能是 `restarted`/`sighup`/`unchanged`，第二次必是 `unchanged` | 第二次仍 `restarted` → MD5 比对失效，每次保存都会断 3 秒 |

---

## 11. 失败排查树

```text
症状：客户机完全无法解析
├─ :53 有监听吗？ ── 否 → dnsmasq 挂了（§2.1）
└─ 是 → dnsmasq 的上游是 127.0.0.1#5353 吗？
   ├─ 否 → 收敛器没跑（§8.3）或 99-zz-dnschain 未生效（§2.3）
   └─ 是 → :5353 有监听吗？
      ├─ 否 → 国内实例没起来
      │      ├─ /etc/init.d/dnsproxy start 的输出现「由 dnschain 框架托管」→ 正常，看 dnschain
      │      └─ /etc/init.d/dnschain start 的输出 → 看 preflight 报错
      └─ 是 → 查 dnsproxy 日志（logread | grep dnsproxy）

症状：国内域名正常，国外域名全失败
├─ :5336 有监听吗？
│  ├─ 否 → 国外实例没起来
│  │      ├─ dnschain.main.enabled=0？ → 打开
│  │      └─ preflight 拒绝了？ → logread | grep dnschain | grep ERROR
│  └─ 是 → :5335 有监听吗？
│     ├─ 是 → 有进程占了已移除组件的端口 → 查 pdnsd_enable（§2.2/§2.3）
│     └─ 否 → :1234 有监听吗？
│        ├─ 否 → SSR-Plus 没运行
│        └─ 是 → 国外实例的 DoH 出站通吗？（§5.3）
│           ├─ 否 → ss_spec_output 端口集不含 443，或 443 被墙
│           └─ 是 → 看国外实例日志

症状：国外域名能解析但返回 2001::1 / 31.13.x（污染）
├─ 直连 :5336 查同一个域名，也是污染吗？
│  ├─ 是 → 国外实例的上游不是 DoH，或上游本身被污染
│  │      ├─ cmdline 里有 tls:// 吗？ → preflight 本应拦住（§9 第 4 项）
│  │      └─ 上游是 https:// 但仍污染？ → 代理没生效，查 router_proxy
│  └─ 否 → 是 dnsmasq 走了旧缓存 → dnschain-health flush

症状：国外 AAAA 返回空（不是真实地址）
├─ dnschain-health 第 11 项 FAIL
│  ├─ ipv6_support 不是 1？ → §2.3
│  ├─ dnsmasq.filter_aaaa 不是 0？ → §2.3
│  └─ :5335 有监听（旧 chinadns-ng 残留）？ → §2.2
└─ 该域名不在 gfw 名单里 → 走默认上游（国内实例），AAAA 本来就有

症状：客户机连 baidu 都解析不了，过一阵自己好
└─ 这是 v2ray 抢 :53 socket 的经典症状（AGENTS.md §4.3）
   netstat -lnup | grep -c '192.168.3.254:53'   # 应恒为 1
   nft list chain ip ss_spec_mangle prerouting | grep -o 'dport { [^}]*}'
   # 端口表里**不能**有 53

症状：页面按钮点了没反应（无提示、无日志）
├─ /usr/bin/dnschain-health 存在且可执行吗？ → §1.1/§1.3
├─ 手动跑对应子命令看输出 → §10
└─ rpcd 的 ACL 是否放行该脚本？
   （package/luci-app-dnschain/root/usr/share/rpcd/acl.d/luci-app-dnschain.json:22、:34）

症状：改了配置但自检 60 秒内还是旧结论
└─ 自检结果有 60 秒缓存（files/usr/bin/dnschain-selftest:595-596）
   用 /usr/bin/dnschain-selftest -f 强制重算
```

---

## 12. 回滚

### 12.1 只回退框架（保留固件）

```sh
uci set dnschain.main.enabled='0'
uci commit dnschain
/etc/init.d/dnschain stop
/etc/init.d/dnsproxy restart    # 回到按 /etc/config/dnsproxy 启动
```

回退后链路回到「dnsmasq → dnsproxy（国内 DoH）+ gfw 旁路 → `:5335`（无监听）」。

**注意**：回退后 `pdnsd_enable` 仍是 `0`，`:5335` 无人监听 → gfw 域名会失败。
需同时：

```sh
uci set shadowsocksr.@global[0].pdnsd_enable='4'
uci commit shadowsocksr
/etc/init.d/shadowsocksr restart
```

**`stop_service` 会把 `watch.servers` 清成注释占位**（在重启 dnsmasq 之前），
否则关掉框架后观测域名会稳定解析失败
（`files/etc/init.d/dnschain:438-455`）。回退后不必手工清理。

### 12.2 完整回退到上一版固件

按 `AGENTS.md` §6 第 10 条：改动前应已备份到 `/root/dnschain-backup-<ts>/`。

```sh
ls -d /root/dnschain-backup-* 2>/dev/null
# 恢复：cp -a /root/dnschain-backup-<ts>/. /
```

---

## 12.1 构建产物预检（刷机**前**做，不必等刷完）

### 一键执行（推荐）

```sh
gh run download <run-id> -D /tmp/fw
sh tools/verify-firmware-artifact.sh /tmp/fw/<artifact 目录>
```

脚本做 7 项检查：sha256、定位 squashfs、列全量清单、**overlay 层 10 项**、
**LuCI 层 5 项**、opkg 包登记 2 项、条目总数
（`tools/verify-firmware-artifact.sh:135-165`）。

输出末尾会明确给出 `=== 预检通过：可以刷机 ===` 或
`=== 预检失败：不要刷机，先查 CI 日志 ===`（`:180-187`）。

**【已更正】** 原文 §12.1 说「overlay 层 10 项」——实际是 10 项
（`:136-145`），但清单里**没有 `usr/bin/dnschain-health`**。
该脚本是 v0.13.0 新增的页面后端，预检脚本未同步。
刷机后需按 §1.1 手工确认它存在。

### 手工执行（脚本不可用时）

```sh
IMG=openwrt-x86-64-ssrplus-vX.Y.Z-abcdef0-squashfs-combined-efi.img.gz
gunzip -c "$IMG" > /tmp/fw.img 2>/dev/null || true
OFF=$(python3 - <<'PY'
with open('/tmp/fw.img','rb') as f:
    pos = 0
    while True:
        c = f.read(1024*1024*8)
        if not c: print(-1); break
        i = c.find(b'hsqs')
        if i >= 0: print(pos + i); break
        pos += len(c)
PY
)
tail -c +$((OFF + 1)) /tmp/fw.img > /tmp/root.squashfs

unsquashfs -ll /tmp/root.squashfs > /tmp/list.txt
grep -E 'dnschain|applechina' /tmp/list.txt
grep -c 'dnschain' /tmp/list.txt            # 期望 >= 15
```

**【已更正】** 原文 §12.1 手工段写「期望 >= 20」。
脚本的实际阈值是 **`>= 15`**（`tools/verify-firmware-artifact.sh:165`）：

```sh
n=$(grep -c 'dnschain' "$LIST" || true)
[ "$n" -ge 15 ] || { echo "  FAIL 条目不足"; rc=1; }
```

注意脚本自己的提示文字写「正常应 >= 20」（`:164`），而判定用 `>= 15` ——
提示与判定不一致。验证时以 `>= 15` 为准，但**低于 20 时值得手工核对**
是否缺了 `dnschain-health` 或某个 LuCI 文件。

**⚠️ 不要用 `unsquashfs -l <path>` 判断单个文件是否存在。**
实测该命令对**不存在的路径也返回 0**，会把缺失误报成存在。
必须用 `-ll` 列全量再 grep。

| 期望条目 | 说明 |
|---|---|
| `etc/config/dnschain` | overlay |
| `etc/init.d/dnschain` | 权限 `-rwxr-xr-x` |
| `etc/rc.d/S95dnschain` + `K10dnschain` | symlink，说明已 enable |
| `etc/uci-defaults/99-zz-dnschain` | 权限 `-rwxr-xr-x` |
| `etc/capabilities/dnschain-filter.json` | 无消费者（§1.1） |
| `etc/ssrplus/applechina.conf` | 173 条 `server=` 指向 `127.0.0.1#5353` |
| `usr/bin/dnschain-reconcile` | 权限 `-rwxr-xr-x`（靠 CI chmod） |
| `usr/bin/dnschain-selftest` | 同上 |
| `usr/bin/dnschain-health` | 同上；**预检脚本未覆盖，需手工确认** |
| `usr/share/dnschain/dnschain.sh` | 同上 |
| `usr/share/luci/menu.d/luci-app-dnschain.json` | **LuCI 页面（v0.9.0 曾整层缺失）** |
| `usr/share/rpcd/acl.d/luci-app-dnschain.json` | 同上 |
| `usr/lib/lua/luci/controller/dnschain.lua` | 同上 |
| `usr/lib/lua/luci/model/cbi/dnschain/general.lua` | 同上 |
| `usr/lib/lua/luci/model/cbi/dnschain/dnschain.lua` | 同上 |

任一项缺失 → 不要刷机，先查 CI 日志的
`=== dnschain 本体与中文语言包都必须入配置 ===` 与 `Add luci-app-dnschain` 两段
（`.github/workflows/build-openwrt.yml:857-883`）。

---

## 13. 验证记录表（刷机后填写）

| # | 检查项 | 命令出处 | 结果 | 备注 |
|---|---|---|---|---|
| 1.1 | overlay 9 个文件就位（含 `dnschain-health`） | §1.1 | ☐ PASS ☐ FAIL | |
| 1.2 | LuCI 页面 5 个文件 + opkg 包 | §1.2 | ☐ PASS ☐ FAIL | **v0.9.0 曾整层缺失** |
| 1.3 | 执行位（5 个脚本） | §1.3 | ☐ PASS ☐ FAIL | 依赖 CI chmod |
| 1.4 | 运行时依赖包版本 | §1.4 | ☐ PASS ☐ FAIL | 不再要求 chinadns-ng |
| 2.1 | 端口监听（含 `:5336`） | §2.1 | ☐ PASS ☐ FAIL | |
| 2.2 | `:5335` **无监听** | §2.2 | ☐ PASS ☐ FAIL | 语义已反转 |
| 2.3 | SSR 五个键 + dnsmasq 的 filter_aaaa | §2.3 | ☐ PASS ☐ FAIL | |
| 3.1 | 缓存层唯一（两个实例都无 `--cache`） | §3.1 | ☐ PASS ☐ FAIL | |
| 3.2 | 三处答案一致、无污染 | §3.2 | ☐ PASS ☐ FAIL | **最强证据** |
| 4 | 四类域名解析（国外 AAAA 期望 OK） | §4 | ☐ PASS ☐ FAIL | 语义已反转 |
| 5.2 | IP 层分流 + `nftset` 增长 | §5.2 | ☐ PASS ☐ FAIL | |
| 5.3 | 出站层 443 经代理 | §5.3 | ☐ PASS ☐ FAIL | 不再是 853 |
| 6.1 | 853 规则在位 | §6.1 | ☐ PASS ☐ FAIL | |
| 6.2 | 853 从客户机被拒 | §6.2 | ☐ PASS ☐ FAIL | |
| 6.3 | 国内 + 国外 IPv6 均可用 | §6.3 | ☐ PASS ☐ FAIL | |
| 7.1 | 名单与分流产物规模 | §7.1 | ☐ PASS ☐ FAIL | 无 `upstreams-domains.txt` |
| 7.2 | 两实例上游正确（DoH / 8s） | §7.2 | ☐ PASS ☐ FAIL | |
| 7.3 | 名单导入（手动触发） | §7.3 | ☐ PASS ☐ FAIL | 无轮询 |
| 8.3 | 收敛器改回四个键 | §8.3 | ☐ PASS ☐ FAIL | **核心诉求** |
| 8.4 | 自检 **20** 项 | §8.4 | ☐ PASS ☐ FAIL | |
| 9 | 降级矩阵（含 preflight 硬校验） | §9 | ☐ PASS ☐ FAIL | 可选 |
| 10 | `dnschain-health` 八个子命令 | §10 | ☐ PASS ☐ FAIL | 页面按钮后端 |

**全部 PASS 后**，才算「框架真的落地」。任一项 FAIL，按 §11 排查并在备注里记下
`logread | grep dnschain` 的相关行。

---

## 14. 已知边界（不属故障，不要误判）

| # | 现象 | 原因 | 处置 |
|---|---|---|---|
| B1 | 名单外的被墙域名拿到污染答案 | 域名名单法的固有缺口（ADR-0003 R-2） | 加到自定义国外域名，或点页面「更新 GFW 名单」 |
| B2 | SSR-Plus 的 `gfw_list.conf` 仍指向 `:5335`（无监听） | 框架不重写 SSR 的文件（ADR-0003 §9.1） | dnsmasq 把多条 `server=` 当候选，会自动重试；属隐式行为 |
| B3 | 境外**字面 IPv6 地址**仍可能不经代理 | 由 SSR-Plus 的 IPv6 规则覆盖，不在框架范围 | — |
| B4 | 443 上的第三方 DoH 无法完全拦截 | 无法在不做 SNI 检查下区分 | 页面已标注「不保证」 |
| B5 | `ss_spec` 重建窗口内 `nftset` 行可能短暂丢失 | SSR-Plus 重建表 | 有两道兜底（§5.2） |
| B6 | 应用配置时约 1–2 秒解析中断 | 静态片段变了要 restart dnsmasq | 正常，页面有提示 |
| B7 | 拦截开关切换时约 3 秒中断 | 改 `dhcp-option` 需 restart dnsmasq | 正常，页面有提示 |
| B8 | **开机不会自动归一** | 收敛器无自动触发点（ADR-0003 R-7） | 改完 SSR-Plus 页面后手动点「一键归一」 |
| B9 | **自检结果 60 秒内可能仍是旧的** | 结果缓存（`files/usr/bin/dnschain-selftest:595-596`） | 用 `-f` 强制重算 |
| B10 | `dnschain-filter.json` 存在但无消费者 | chinadns-ng 时代遗留 | 不要据此推断有权限约束 |
| B11 | 多个 UCI 键改了不生效（`via_proxy`、`cert_verify`、`intercept_doh`、`filter_https_rr`、`cache.enabled`、`import_interval`、`selftest.*`） | 无 shell 消费者 | 页面已标注「仅作记录」 |

---

## 15. 与 ADR-0003 的对应关系

| ADR-0003 章节 | 本文对应 | 说明 |
|---|---|---|
| §2 现状基线 | §1 | 刷机后确认组件就位 |
| §4 组件职责 | §2、§3 | 端口所有权 + 缓存层 |
| §5 分流三层 | §4、§5 | DNS / IP / 出站 |
| §6 双栈与加密 | §4、§6 | AAAA 策略 + 853 |
| §7 SSR-Plus 模式映射 | §2.3 | 不再有端口档案 |
| §8 页面 | §1.2、§8.5、§10 | 地址、自检表格、按钮后端 |
| §9 六道闸 | §8 | 抗「改 LuCI 就坏」 |
| §10 配置要点 | §7 | 名单与参数 |
| §11 自检清单（20 项） | §8.5 | 20 项 |
| §12 降级矩阵 | §9 | 故障点 |
| §13 落地清单 | §1、§12.1 | 文件与包 |
| §14 风险 | §14 | 已知边界 |

---

## 16. 本次修订的断言计数

| 类别 | 条数 | 说明 |
|---|---|---|
| 已失效标注 | 10 | 页面地址、chinadns-ng 依赖、`:5335` 持有者判据、国外 AAAA 期望值、`upstreams-domains.txt`、`idna-bypass.conf`、收敛器触发方式、853 出站判据、`filter_aaaa` 期望值、自检第 4 项的 `::1` 假覆盖 |
| 行号更正 | 4 | `build-openwrt.yml` 执行位清单、`dnsproxy` 的 tls/CA 行号、`china` 元素数、`>= 20` → `>= 15` |
| 事实更正 | 12 | 自检 16→20、overlay 8→9 项、端口 grep 漏 5336、`pidof` 单实例→双实例、三处答案比对、IP 层数字冲突、ADR-0010→ADR-0003、`dnschain-health` 缺失、`nftset` 需手工验、`filter_aaaa` 双键、`apply` 出口、预检脚本未覆盖 `dnschain-health` |
| 新增章节 | 2 | §10 `dnschain-health` 子命令、§5.2 `nftset` 增长验证 |
