#!/bin/sh
# ============================================================
# verify-dnschain-domains.sh — 域名分流与自动改道的契约校验
# ------------------------------------------------------------
# 依据 docs/adr/0006-domain-routing-and-reroute.md。
#
# 为什么单独一个脚本（不塞进 workflow 的 YAML）：
#   这些约束**无法被 shell / Lua 语法检查发现**，而且违反后症状隐蔽：
#   页面照常打开、链路照常工作，只是某个域名悄悄走错了链。
#   抽出来后本地可以 `sh tools/verify-dnschain-domains.sh` 直接复现，
#   CI 与本地跑同一份逻辑，不会出现「本地过了 CI 挂」。
#
# 约束（AGENTS §6 第 11 条）：必须 POSIX sh（dash）兼容。
#   禁止进程替换 <(...)、[[ ]]、bash 数组。
#
# 用法：sh tools/verify-dnschain-domains.sh
# 退出码：0 = 全部通过
# ============================================================

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 1

rc=0

LIB=files/usr/share/dnschain/dnschain.sh
HEALTH=files/usr/bin/dnschain-selftest   # v0.21.0：原 dnschain-health 已删除
INIT=files/etc/init.d/dnschain
CONF=files/etc/config/dnschain
GEN=package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua
MOD=package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua
DIA=package/luci-app-dnschain/luasrc/model/cbi/dnschain/diagrams.lua
CSS=package/luci-app-dnschain/htdocs/luci-static/resources/dnschain/dnschain.css
JS=package/luci-app-dnschain/htdocs/luci-static/resources/dnschain/dnschain.js
DNSCHAIN_SH=files/usr/share/dnschain/dnschain.sh
RECONCILE=files/usr/bin/dnschain-reconcile
PO=package/luci-app-dnschain/po/zh-cn/luci-app-dnschain.po
# v0.16.5 性能断言用（第 12 节）
DATA=package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua
GENERAL=package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua
TRIAGE=files/usr/bin/dnschain-triage
# v0.18.0 tab 结构断言用（第 13 节，ADR-0007）
DIAG=package/luci-app-dnschain/luasrc/model/cbi/dnschain/diagnosis.lua
SELFTEST=files/usr/bin/dnschain-selftest
MODEL=package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua
UCI_DEF=files/etc/uci-defaults/99-zz-dnschain
GAMING=files/etc/uci-defaults/99-gaming-optimize
RECONCILE=files/usr/bin/dnschain-reconcile

pass() { echo "OK   $1"; }
fail() { echo "FAIL $1" >&2; rc=1; }

# 先剥注释再判断 —— 否则「解释错误写法的注释」会让断言永久误报
# （v0.4.7 的 nft 守卫踩过这个坑，AGENTS §6 第 6 条）。
body_of() {
	grep -v '^[[:space:]]*#' "$1" 2>/dev/null
}

# Lua 文件的注释是 `--`，不是 `#`。剥法不同，故单独一个函数。
# 只剥**整行**注释；行尾注释保留（行尾注释里出现被禁模式的情况极少，
# 而按行尾切分容易把字符串里的 `--` 也切掉，风险更大）。
lua_body_of() {
	grep -v '^[[:space:]]*--' "$1" 2>/dev/null
}

echo "── 1. 文件存在 ──────────────────────────────────────────"
for f in "$LIB" "$HEALTH" "$INIT" "$CONF" "$GEN" "$MOD" "$DIA" "$CSS" "$JS" "$PO"; do
	if [ -f "$f" ]; then
		pass "存在 $f"
	else
		fail "缺少 $f"
	fi
done

echo "── 2. POSIX sh（dash）兼容 ──────────────────────────────"
for f in "$LIB" "$HEALTH" "$INIT" files/usr/bin/dnschain-reconcile \
         files/usr/bin/dnschain-selftest "$UCI_DEF"; do
	[ -f "$f" ] || continue
	if sh -n "$f" 2>/dev/null; then
		pass "dash 语法通过: $f"
	else
		fail "dash 语法错误: $f"
	fi
done

echo "── 3. 禁止 bash 专有语法 ────────────────────────────────"
for f in "$LIB" "$HEALTH" "$INIT" "$UCI_DEF"; do
	[ -f "$f" ] || continue
	b=$(body_of "$f")

	if printf '%s\n' "$b" | grep -qE '<\(|>\('; then
		fail "$f 含进程替换 <(...) / >(...)（dash 解析期错误）"
	fi
	# 注意：只查 `[[ ` 与 `]]` 作为**独立词**的形态。
	# 直接 grep '\[\[' 会命中 POSIX 字符类 [[:space:]] —— 那是合法的，
	# 实测已误报过一次（AGENTS §6 第 6 条「先剥注释再判断」的同类陷阱）。
	if printf '%s\n' "$b" | grep -qE '(^|[^[:alnum:]_])\[\[[[:space:]]'; then
		fail "$f 含 [[ ]]（dash 不支持）"
	fi
	if printf '%s\n' "$b" | grep -qE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\('; then
		fail "$f 含 bash 数组赋值"
	fi
done
[ "$rc" -eq 0 ] && pass "无 bash 专有语法"

echo "── 4. 需求 1：两个自定义输入框 ──────────────────────────"

# 两个 list 必须在**不同的** config 段里 —— 同一个段会让写回互相覆盖
if grep -q "^config domains 'dom_domestic'" "$CONF"; then
	pass "配置含 domains 'dom_domestic' 段"
else
	fail "配置缺 domains 'dom_domestic' 段"
fi
if grep -q "^config domains 'dom_foreign'" "$CONF"; then
	pass "配置含 domains 'dom_foreign' 段"
else
	fail "配置缺 domains 'dom_foreign' 段"
fi

# ⚠️ section 名必须在整个文件内唯一（与类型无关）
#
# UCI 的 section 名是**文件级唯一**的，不是「类型 + 名」唯一。
# v0.13.0 首次部署时写成 `config domains 'foreign'`，而文件上方已有
# `config upstream 'foreign'` → uci 直接报
#     Parse error (section of different type overwrites prior section
#     with same name)
# 并且**整个配置文件都读不出来**，框架所有 uci 取值全部失败。
# 症状是「页面空白 + 服务起不来」，而报错只提 section 重名。
# 这类错误 shell/Lua 语法检查都发现不了，只能显式断言。
dup=$(grep -E "^config [a-z_]+ '[^']+'" "$CONF" \
	| sed "s/^config [a-z_]* '\([^']*\)'/\1/" | sort | uniq -d)
if [ -z "$dup" ]; then
	pass "配置 section 名全局唯一（无 UCI 重名冲突）"
else
	fail "配置 section 名重复：$dup（uci 会整文件解析失败）"
fi

# 页面上必须有两个多行域名输入框（一个走直连、一个走代理）
#
# v0.20.0：从 DynamicList 改为 TextValue 多行文本框（用户要求「每一行一个域名」）。
# 断言随之改为检查 make_domain_textarea 的调用次数。
n_dyn=$(body_of "$GEN" | grep -c 'make_domain_textarea(s, "domain"')
if [ "$n_dyn" = "2" ]; then
	pass "页面有两个多行域名输入框（TextValue domain x2）"
else
	fail "页面域名输入框数量不对：$n_dyn（应为 2）"
fi

# 多行框的 write 必须逐行调 validate_domain —— 缺了就能把非法条目存进 UCI
#
# v0.20.0：校验从「option 级 o.validate」下移到「write 里逐行校验」，
# 因为一个大框里有多行，必须在拆分后逐行判。断言改为检查 write 内的调用。
n_val=$(body_of "$GEN" | grep -c 'validate_domain(t)')
if [ "$n_val" = "1" ]; then
	pass "多行输入框在 write 里逐行做格式校验"
else
	fail "write 里的逐行校验调用数为 $n_val（应为 1 处）"
fi

# write 必须显式 save + commit —— 只调 map:set 时值会停在 staging 丢失
if body_of "$GEN" | grep -q 'uci:commit(self.map.config)'; then
	pass "多行输入框写入后显式 commit"
else
	fail "多行输入框缺 commit（值会停在 staging 丢失）"
fi

# write 必须返回真值 —— 否则 LuCI 认为无改动，一个字节都不写
if body_of "$GEN" | grep -qE '^		return true$'; then
	pass "多行输入框的 write 返回真值"
else
	fail "多行输入框的 write 未返回真值（LuCI 会跳过落盘）"
fi

# 校验函数必须真的拦非法形态（不能只写个空函数）
for pat in '不能含空格' '只能包含字母、数字、点与连字符' '至少要有两级' '顶级域至少 2 位'; do
	if body_of "$GEN" | grep -q "$pat"; then
		pass "校验覆盖：$pat"
	else
		fail "校验缺少：$pat"
	fi
done

# 已录入清单必须能看、能改（DynamicList 自带增删）、能清（rmempty）
if body_of "$GEN" | grep -q 'o.rmempty = true'; then
	pass "域名条目可清除（rmempty）"
else
	fail "域名条目缺 rmempty，无法清除"
fi

# v0.21.0：dnschain-health 已删除，脚本侧的域名校验闸改在库文件里
# （dc_domain_valid，由 dc_list_normalize 调用，兜住直接改 UCI 的情形）。
if body_of "$LIB" | grep -q 'dc_domain_valid'; then
	pass "库文件有域名格式校验（兜住直接改 UCI 的情形）"
else
	fail "库文件缺域名格式校验"
fi

# selftest 现在承担 flush / explain / apply 三个子命令
if body_of "$SELFTEST" | grep -q 'flush)'; then
	pass "dnschain-selftest 提供 flush 子命令"
else
	fail "dnschain-selftest 缺 flush 子命令"
fi

echo "── 5. 需求 2/3/4：改道规则与判定 ────────────────────────"

# 归属优先级：自定义 > 数据库 > 未覆盖
if body_of "$LIB" | grep -q 'dc_domain_class'; then
	pass "有归属判定函数 dc_domain_class"
else
	fail "缺归属判定函数"
fi

# 自定义国内必须在数据库之前判定（否则用户写的不生效）
# 用 awk 取两个 grep 的行号比大小，避免依赖 grep -n 的排序
l_custom=$(body_of "$LIB" | grep -n 'custom-domestic"; return 0' | head -1 | cut -d: -f1)
l_db=$(body_of "$LIB" | grep -n 'db-foreign"' | head -1 | cut -d: -f1)
if [ -n "$l_custom" ] && [ -n "$l_db" ] && [ "$l_custom" -lt "$l_db" ]; then
	pass "自定义列表优先于数据库判定（行 $l_custom < $l_db）"
else
	fail "自定义列表未优先于数据库（custom=$l_custom db=$l_db）"
fi

# 未覆盖域名的首选链必须是 domestic（= dnsmasq 默认上游）
# 这是需求第 3 条「未录入的域名默认走直连」的实现依据
if body_of "$LIB" | grep -q 'custom-foreign|db-foreign) echo "foreign"'; then
	pass "首选链映射：自定义国外/数据库 → 代理"
else
	fail "首选链映射缺失或形态变了"
fi
if body_of "$LIB" | grep -q '^\s*\*)                         echo "domestic"'; then
	pass "首选链映射：未覆盖 → 直连（与 dnsmasq 默认上游一致）"
else
	fail "未覆盖域名的首选链不是 domestic"
fi

# v0.21.0：自动改道已删除（由 dnsproxy --fallback 承担），
# 下面几条改道判定断言随之失效。改为反向断言：不得再出现改道循环。
if body_of "$LIB" | grep -q 'dc_health_cycle'; then
	fail "dc_health_cycle 已删除，但仍存在"
else
	pass "改道判定主循环已删除（改由 --fallback 承担）"
fi

# ── v0.14.0 语义矫正：自定义列表是「补全归属」，不是「改道开关」 ──
#
# 需求原文：自定义输入框「只作为补全追加到数据库而不是直接改道」，
# 且「针对数据库未覆盖的域名，实现链路健康检测与自动改道」。
# 合起来 = 补全只决定首选链，仍然参与改道。
#
# 旧实现把自定义域名当 fixed，命中就 continue 跳过改道 —— 下面两条
# 断言专门防止它回来。
if body_of "$LIB" | grep -q 'if dc_domain_fixed "$d"; then'; then
	fail "改道循环里仍有「自定义域名跳过改道」的分支（与需求 2/3 冲突）"
else
	pass "改道循环对所有观测域名一视同仁（无 fixed 例外）"
fi

# health_cycle 里不得出现 fixed: 结果前缀（那是「跳过改道」的标记）
if body_of "$LIB" | grep -q '"fixed:\$res"'; then
	fail "仍在写 fixed: 健康结果（表示跳过改道）"
else
	pass "不再写 fixed: 健康结果"
fi

# dc_explain_domain 不得把自定义域名短路成「不改道」
if body_of "$LIB" | grep -q 'decision="fixed"'; then
	fail "解释逻辑仍把自定义域名短路成 fixed（页面会与实际行为矛盾）"
else
	pass "解释逻辑与改道循环走同一套判定"
fi

# v0.21.0：dnschain-health status 已删除。档位断言在 §8 统一验（用 $DIA）。

# ── 观测基准集必须「一行一个域名」──
#
# v0.14.0 实测踩过：种子集写成两行字面量，而输出用了
# `printf '%s\n' "$VAR"`（整个变量当**一个**参数）→ 8 个域名被压成
# v0.22.0：观测列表恒为空，基准集已删除。
#
# 原因（这是删 watch.servers 的连带修复）：观测域名原本被 dc_exclude 从
# split.conf 剔掉，只在 watch.servers 里出现。watch.servers 删除后，
# 这个剔除动作变成**纯粹的数据丢失** —— 实测 github.com 因在观测列表里
# 而被剔出 split.conf，结果 `nslookup github.com 127.0.0.1` 超时，
# 而 api.github.com（不在观测列表）正常。
#
# 现在 dc_watch_list 返回空，剔除 0 条。断言反向化，防止基准集被加回来。
# ⚠️ 必须先剥注释：dc_watch_list 上方的说明里写着 DNSCHAIN_WATCH_SEED
#    这个名字（解释为什么删掉它），不剥会永久误报。
if sed 's/#.*//' "$LIB" 2>/dev/null | grep -q 'DNSCHAIN_WATCH_SEED'; then
	fail "观测基准集仍在（会把域名剔出 split.conf 导致解析失败）"
else
	pass "观测基准集已删除（dc_watch_list 恒返回空）"
fi
if body_of "$LIB" | awk '/^dc_watch_list\(\)/,/^}/' | grep -qE 'echo "\$d"'; then
	fail "dc_watch_list 仍在输出域名（应从 split.conf 剔除 0 条）"
else
	pass "dc_watch_list 不输出任何域名"
fi

# ── nftset 重建窗口兜底（v0.14.1）──
#
# 实测故障：在 SSR-Plus 页面点「保存并应用」后，ssrplus 重建规则，
# `ss_spec` 表短暂消失。若 dnschain 恰在此窗口跑 apply，会生成
# **23714 条 server= 但 0 条 nftset=** 的片段 ——
# 国外域名能解析，但解析出的 IP 不进 blacklist → 流量不走代理 →
# **国外链路整条断掉**，而日志干净、页面看着正常。
#
# 故必须有两层保护：片段生成时兜底 + reconcile 时自愈。
if body_of "$LIB" | grep -q 'dc_ss_spec_present'; then
	pass "有 ss_spec 整体存在性探测（区分「未启用」与「重建中」）"
else
	fail "缺 dc_ss_spec_present（无法区分重建窗口与未启用）"
fi

if body_of "$LIB" | grep -q 'keep_prev_nft'; then
	pass "分流片段生成有 nftset 兜底（重建窗口内不丢代理链路）"
else
	fail "分流片段生成缺 nftset 兜底（SSR-Plus 重建期间会把代理链路打掉）"
fi

# ⚠️ v0.14.3：自愈逻辑从 reconcile_lists 移到 reconcile_invariants。
#
#   原因：reconcile_lists 在「名单指纹未变」时直接 return 0，
#   而 nftset 归零与名单变化无关（那是 SSR-Plus 重建窗口造成的）——
#   放在那里等于「名单不变就永不检查」，实测确认自愈从不触发。
#   invariants 每次收敛都跑，才是正确位置。
if grep -q 'nft_now' "files/usr/bin/dnschain-reconcile" 2>/dev/null \
   && grep -q 'dc_ss_spec_present' "files/usr/bin/dnschain-reconcile" 2>/dev/null; then
	pass "reconcile 会检测并修复「nftset 行数为 0」的坏片段"
else
	fail "reconcile 不检测 nftset 归零（坏片段不会自愈）"
fi

# 自愈必须在 invariants 里（不能放 lists —— 那里名单不变就不跑）
if awk '/^reconcile_invariants\(\)/,/^}/' "files/usr/bin/dnschain-reconcile" 2>/dev/null | grep -q 'nft_now'; then
	pass "nftset 自愈在 invariants 里（每次收敛都检查）"
else
	fail "nftset 自愈不在 invariants（名单不变时永不检查）"
fi

# grep -c 双输出陷阱：不得再出现 `grep -c ... || echo 0`
# （无匹配时得到 "0\n0"，算术比较报错 → 判据恒假）
if sed 's/#.*//' "files/usr/bin/dnschain-reconcile" 2>/dev/null | grep -q 'grep -c.*|| echo 0'; then
	fail "reconcile 仍有 grep -c || echo 0（会得到 0\\n0，判据恒假）"
else
	pass "reconcile 不用 grep -c || echo 0（避免双输出）"
fi

# ── selftest 结果缓存（v0.14.1 性能）──
#
# 自检 20 项含 4 处真实 DNS 查询，实测 3.5 秒；页面每次刷新都跑一遍
# → 用户感知「切换页面太慢」。加 60 秒缓存后降到 0.2 秒。
# 但缓存必须有失效指纹，否则会掩盖真实故障。
if grep -q 'selftest.cache' "$ROOT/files/usr/bin/dnschain-selftest" 2>/dev/null \
   || grep -q 'selftest.cache' "files/usr/bin/dnschain-selftest" 2>/dev/null; then
	pass "自检结果有磁盘缓存"
else
	fail "自检无磁盘缓存（页面每次刷新都跑完整 20 项）"
fi

if grep -q 'selftest_fingerprint' "files/usr/bin/dnschain-selftest" 2>/dev/null; then
	pass "自检缓存有失效指纹（状态变化会重跑，不会掩盖故障）"
else
	fail "自检缓存缺失效指纹（会掩盖真实故障）"
fi

# BusyBox 没有 stat 命令 —— 用 stat 取 mtime 会让缓存永不命中。
#
# ⚠️ 必须先剥掉注释行再判断：文件里有一段解释「为什么不能用 stat」
#    的注释本身就含 `stat -c %Y`，直接 grep 会永久误报
#    （AGENTS §6 第 6 条踩过同类坑）。
if sed 's/#.*//' "files/usr/bin/dnschain-selftest" 2>/dev/null | grep -q 'stat -c %Y'; then
	fail "自检缓存用 stat 取 mtime（BusyBox 无 stat，缓存永不命中）"
else
	pass "自检缓存不用 stat（BusyBox 兼容）"
fi

# v0.21.0：both-bad 标记与三个阈值随健康改道一起删除。
# 反向断言：库文件里不得再有改道循环。
if body_of "$LIB" | grep -q 'dc_health_cycle'; then
	fail "改道判定主循环仍在（应已删除）"
else
	pass "改道判定主循环已删除"
fi

# 探测必须有超时与重试（需求第 5 条）
if body_of "$LIB" | grep -q 'dc_run_timeout'; then
	pass "有硬超时实现（BusyBox nslookup 无 -timeout）"
else
	fail "缺硬超时实现"
fi
if body_of "$LIB" | grep -q 'dc_probe_chain'; then
	pass "有带重试的单域名探测"
else
	fail "缺带重试的探测"
fi

# 超时状态必须走 stdout 而不是变量 —— 命令替换在子 shell 里跑，
# 变量赋值父 shell 看不到，超时会被静默当成「返回空」
if body_of "$LIB" | grep -q 'DC_TIMEOUT_HIT'; then
	fail "仍用 DC_TIMEOUT_HIT 变量传状态（命令替换是子 shell，父 shell 读不到）"
else
	pass "超时状态不依赖子 shell 里的变量"
fi

echo "── 6. 改道只 SIGHUP，不重启 dnsmasq ─────────────────────"

# v0.21.0：watch.servers 通道已删除 —— 它与 dnschain-split.conf 是两套
# 并存的 server= 源，同域名两处都有规则时 dnsmasq 当候选而非覆盖，
# 会把正确分流覆盖成错误的（实测 www.wikipedia.org 拿到污染答案）。
if body_of "$LIB" | grep -q 'dc_gen_watch_servers'; then
	fail "dc_gen_watch_servers 已删除，但仍存在"
else
	pass "watch.servers 通道已删除（消除双写冲突）"
fi
if body_of "$LIB" | grep -q 'dc_reload_servers_file'; then
	pass "有 servers-file 重载（SIGHUP）"
else
	fail "缺 servers-file 重载"
fi
if body_of "$LIB" | grep -q 'kill -HUP'; then
	pass "重载用 SIGHUP（不重启）"
else
	fail "重载没用 SIGHUP"
fi

# ⚠️ SIGHUP 必须发给**真 worker**，不能是 pidof 的第一个
#
# 本固件 dnsmasq 是 ujail 三层结构，`pidof dnsmasq` 返回 3 个 PID，
# 第一个是辅助子进程（wchan=anon_pipe_read、只有 5 个 fd），
# 对它发 SIGHUP 是空操作 —— 已在路由器实测（/etc/hosts 探针）：
#   HUP→辅助子进程：探针无解析结果
#   HUP→真 worker  ：立刻返回探针地址
# 取错 PID 会让改道静默失效（页面显示已改道、实际没换上游）。
if body_of "$LIB" | grep -q "awk 'NR > 1 && \$2 ~ /:0035\$/\|/proc/net/udp"; then
	pass "dnsmasq PID 按「持有 :53 socket」判定（不是 pidof 第一个）"
else
	fail "dnsmasq PID 仍取 pidof 第一个（SIGHUP 会发错进程，改道静默失效）"
fi

# 反向断言：不得再出现「取 pidof 第一个」的写法
if body_of "$LIB" | grep -qE "pidof dnsmasq.*awk '\{ ?print \\\$1"; then
	fail "仍存在 pidof-first 取法（会拿到辅助子进程）"
else
	pass "无 pidof-first 取法残留"
fi

# 健康循环里**不得**出现 dnsmasq restart
if body_of "$LIB" | sed -n '/^dc_health_cycle/,/^}/p' | grep -qE 'init\.d/dnsmasq (restart|reload)'; then
	fail "改道循环里重启了 dnsmasq（会造成 3 秒解析中断）"
else
	pass "改道循环不重启 dnsmasq"
fi

# init 必须把 serversfile 下发给 dnsmasq
if body_of "$INIT" | grep -q 'serversfile'; then
	pass "init 下发 dhcp.@dnsmasq[0].serversfile"
else
	fail "init 没下发 serversfile —— 改道写了文件也不会被读"
fi

# 首刷默认值也要配（否则新刷机后改道永远不生效）
if body_of "$UCI_DEF" | grep -q 'serversfile'; then
	pass "uci-defaults 首刷即配 serversfile"
else
	fail "uci-defaults 没配 serversfile"
fi

echo "── 7. 观测域名不得与静态片段重复 ───────────────────────"

# 同一域名若同时出现在静态片段与 servers-file 里，dnsmasq 会把两条
# server= 当作**候选**（不是后者覆盖前者），改道退化成随机走一条。
if body_of "$LIB" | grep -q 'dc_exclude "\$watch_f"'; then
	pass "生成静态片段时排除观测域名"
else
	fail "静态片段未排除观测域名（改道会退化成随机走一条）"
fi

# ⚠️ 排除必须走 dc_exclude，不能直接 grep -Fvxf
#
# BusyBox grep 在 **pattern 文件为空** 时返回 rc=1 且**输出零行** ——
# 不是「一条都不排除」，而是「把输入全吞掉」。
# 实测：printf "a\nb\nc\n" | grep -Fvxf /tmp/empty → 0 行
#
# 这个坑**必然触发**：custom-domestic.txt 默认是空文件（用户还没录
# 自定义域名），而 db-domains.txt 有 23715 条 → foreign-split.conf
# 变成 0 字节 → preflight 判「国外分流为空」→ 拒绝启动。
# 实测症状：dnschain restart 后「ERROR: foreign-split.conf 为空」
# 且 dnsproxy 不再监听，整条链路起不来。
if body_of "$LIB" | grep -q '^dc_exclude()'; then
	pass "有 dc_exclude 包装（空排除文件时不吞输入）"
else
	fail "缺 dc_exclude：空排除文件会让 grep -Fvxf 吞掉整个名单"
fi

# 反向断言：dc_exclude 之外不得再有裸 grep -Fvxf
# （dc_exclude 内部那两行是合法的，故排除函数体范围）
bare=$(body_of "$LIB" \
	| sed -n '/^dc_exclude()/,/^}/!p' \
	| grep -c 'grep -Fvxf' || true)
if [ "$bare" = "0" ]; then
	pass "dc_exclude 之外无裸 grep -Fvxf"
else
	fail "仍有 $bare 处裸 grep -Fvxf（空排除文件时会吞掉输入）"
fi

# ⚠️ servers-file 必须放在 ujail 已挂载的目录里
#
# 本固件的 dnsmasq 由 ujail 降权到 uid 453（dnsmasq 用户）运行，
# 只能看到 init.d/dnsmasq 里 `procd_add_jail_mount` 声明过的路径：
#   -r /tmp/dnsmasq.d      -rw /var/run/dnsmasq/      ...
#
# v0.13.0 首次部署时放在 /var/etc/dnschain/ 下（既不在白名单、
# 文件又是 0600 root:root），结果是：
#   · dnsmasq 读不到 → servers-file 一条都没加载
#   · SIGHUP 成功返回、日志干净 → 改道完全无效且无迹可寻
#   · 实测症状：github.com 经 :53 稳定超时（走 gfw_list 里指向死端口
#     :5335 的旧声明），而直连 :5336 / :5353 都正常
#
# 实测判据（放在 /var/run/dnsmasq/ 之后）：
#   指向不存在的 :59999 → 立即超时；还原 → 立即恢复。
if body_of "$LIB" | grep -q 'DNSCHAIN_WATCH_SERVERS="/var/run/dnsmasq/'; then
	pass "servers-file 位于 ujail 已挂载目录（/var/run/dnsmasq/）"
else
	fail "servers-file 不在 ujail 挂载目录（dnsmasq 读不到，改道静默失效）"
fi

# 反向断言：不得指回 /var/etc/dnschain/
if body_of "$LIB" | grep -q 'DNSCHAIN_WATCH_SERVERS="${DNSCHAIN_RUN_DIR}'; then
	fail "servers-file 指回 /var/etc/dnschain/（不在 ujail 白名单）"
else
	pass "servers-file 未指回非挂载目录"
fi

# v0.21.0：watch.servers 通道已删除，chmod 断言随之失效。
# 反向断言：不得再有生成它的代码。
if body_of "$LIB" | grep -q 'DNSCHAIN_WATCH_SERVERS'; then
	# 允许保留常量定义（init/stop 清理遗留文件时仍引用它），
	# 但不得再有「写入并 chmod」的动作
	if body_of "$LIB" | grep -q 'chmod 0644 "\$DNSCHAIN_WATCH_SERVERS"'; then
		fail "仍在写 watch.servers（通道应已删除）"
	else
		pass "watch.servers 只保留常量（供清理遗留文件），不再写入"
	fi
else
	pass "watch.servers 常量与写入逻辑均已删除"
fi

# ⚠️ 探测函数必须支持「显式端口」形式
#
# dc_probe_chain 原来只认 foreign|domestic 两个链路名，其它一律落到
# `*)` 分支取 entry_port。于是传 `127.0.0.1#59999` 这种指定端口探测
# 会被**静默改成**探测 :5353，而 :5353 是活的 → 死端口被判为 OK。
#
# 这是最危险的一类错误：探测判据本身撒谎，于是「链路挂了却不改道」，
# 正是需求 2 要防的场景。实测：dc_probe_chain … 127.0.0.1#59999 → OK。
if body_of "$LIB" | sed -n '/^dc_probe_chain()/,/^}/p' | grep -q "tr '#' ':'"; then
	pass "探测函数支持显式端口（不会静默改探默认端口）"
else
	fail "探测函数不认显式端口（死端口会被误判为可达）"
fi

# 链路名必须显式列出 domestic，不能只靠 `*)` 兜底
if body_of "$LIB" | sed -n '/^dc_probe_chain()/,/^}/p' | grep -q 'domestic)'; then
	pass "探测函数显式处理 domestic 链路名"
else
	fail "探测函数未显式处理 domestic（会落到兜底分支）"
fi

# 空排除文件时 dc_exclude 必须原样放行
if body_of "$LIB" | sed -n '/^dc_exclude()/,/^}/p' | grep -q 'cat'; then
	pass "dc_exclude 空列表时走 cat 放行"
else
	fail "dc_exclude 空列表时没有放行路径"
fi

# v0.22.0：watch.servers 已删除，第 18 项从「观测域名不与静态片段重复」
# 改为「旧 watch.servers 已清理」（防升级残留把链路搞坏）。
if body_of files/usr/bin/dnschain-selftest | grep -q '旧 watch.servers 已清理'; then
	pass "自检含「旧 watch.servers 已清理」项"
else
	fail "自检缺「旧 watch.servers 已清理」项"
fi

echo "── 8. 自检覆盖新功能 ───────────────────────────────────"

# v0.22.0：「改道通道已就绪」改为「改道通道已清理」；
# 「改道状态自洽」随改道状态文件一起删除。
for item in '自定义域名列表合法' '改道通道已清理'; do
	if body_of files/usr/bin/dnschain-selftest | grep -q "$item"; then
		pass "自检含「$item」"
	else
		fail "自检缺「$item」"
	fi
done

echo "── 9. 图示（思维链路图 / 状态思维导图）────────────────"

if [ -f "$DIA" ]; then
	pass "图示模块独立成文件（可被本地脚本渲染核对）"
else
	fail "图示没有独立模块"
fi

# 判定链路图必须画出「最新分流链路标准」的三步
#
# ⚠️ v0.16.4 起这张图按用户给的「最新分流链路标准」重画：
#     入口条件（不在任何库） → ① 试直连 → ② 试代理 → ③ 标记 dead
#   旧图（v0.13.0）画的是「归属 → 首选链探测 → 保持/改道」，
#   那是健康探测与自动改道，与分诊标准不是一回事。
#   断言随之改为新图的节点 —— 这些字符串就是「图与标准一一对应」的落点，
#   改图必须同步改这里，否则断言会静默失去意义。
for node in '未知目标' '不在任何库' '① 试直连' '② 试代理' '③ 标记 dead' \
            '已有归属' '不加入任何集合' \
            'IP → china 集合' 'IP → blacklist 集合' \
            'custom-domestic.txt' 'custom-foreign.txt'; do
	if body_of "$DIA" | grep -q "$node"; then
		pass "判定链路图含节点「$node」"
	else
		fail "判定链路图缺节点「$node」"
	fi
done

# 标准里的两条硬约束必须写在图下（图能表达结构，规则要可核对）：
#   ① IP 一律转 IP 段入库，不写单个 /32
#   ② dead 不进任何集合
if body_of "$DIA" | grep -q '不写单个 /32'; then
	pass "图下写明「IP 一律转 IP 段入库」"
else
	fail "图下没写「IP 一律转 IP 段入库」"
fi

if body_of "$DIA" | grep -q 'dead 不进任何集合'; then
	pass "图下写明「dead 不进任何集合」"
else
	fail "图下没写「dead 不进任何集合」"
fi

# 分流去向图必须分两档（v0.21.0：五档健康状态 → 两档分流去向）
for st in '走直连' '走代理'; do
	if body_of "$DIA" | grep -q "title = translate(\"$st\")"; then
		pass "分流去向图含档位「$st」"
	else
		fail "分流去向图缺档位「$st」"
	fi
done

# 每条连线必须是贝塞尔（直角折线在分叉处像断链）
if body_of "$DIA" | grep -q 'd="M %d %d C %d %d, %d %d, %d %d"'; then
	pass "图示用贝塞尔 C 指令"
else
	fail "图示缺贝塞尔曲线"
fi

# 控制点必须防交叉（否则曲线自交成扭结）
if body_of "$DIA" | grep -q 'local cap = math.floor((x2 - x1) / 2)'; then
	pass "曲线控制点有交叉保护"
else
	fail "曲线缺控制点交叉保护"
fi

# 节点必须有填充（否则连线从节点内部透出，像断链）
if body_of "$DIA" | grep -q 'fill="var(--dc-surface)"'; then
	pass "节点有填充（连线不会透出）"
else
	fail "节点 fill 不是 --dc-surface"
fi

# ── 连线不得带箭头（v0.15.0 用户要求）──
#
# 历史：v0.14.2 起每张图按状态色定义 5 个 <marker>，连线用 marker-end
# 引用，靠 id 前缀区分同页多图。
#
# v0.15.0 按用户要求**移除全部箭头**：思维导图的语义是「从主干生长出
# 分支」，靠曲线形状与颜色即可表达走向；箭头在密集分支处互相压盖，
# 反而看不清。移除后连 marker 一起没有了 —— 重复 id 的根因随之消失。
#
# 断言改为反向条件（必须**不存在**），并保留 id_prefix 参数化能力
# （它现在落在无副作用的 data-dc-figure 上）。
if lua_body_of "$DIA" | grep -q '<marker'; then
	fail "判定链路图/状态图仍生成 <marker>（v0.15.0 要求移除箭头）"
else
	pass "两张图都不生成 <marker>（箭头已移除）"
fi

if lua_body_of "$DIA" | grep -q 'marker-end'; then
	fail "diagrams.lua 仍有 marker-end 引用（箭头未清干净）"
else
	pass "diagrams.lua 无 marker-end 引用"
fi

if lua_body_of "$GEN" | grep -q 'marker-end\|dc-a-ok'; then
	fail "general.lua 内联链路图仍有箭头（marker-end / dc-a-ok）"
else
	pass "general.lua 内联链路图无箭头"
fi

if lua_body_of "$DIA" | grep -q 'rawget(opts, "id_prefix")'; then
	pass "判定链路图图身份可由调用方指定（id_prefix）"
else
	fail "判定链路图不支持 id_prefix"
fi
if lua_body_of "$DIA" | grep -q 'id_prefix or "dcst"'; then
	pass "状态导图图身份可指定且默认 dcst"
else
	fail "状态导图 id_prefix 默认值缺失"
fi

# 前缀默认值仍须存在（防止 rawget 回落成空串导致 data-dc-figure=""）
if lua_body_of "$DIA" | grep -q 'or "dcrt"'; then
	pass "判定链路图 id_prefix 默认 dcrt"
else
	fail "判定链路图 id_prefix 默认值缺失"
fi

# ── 清缓存必须走正确 PID（v0.14.2）──
#
# 实测 bug：Lua 侧原先用 `pidof dnsmasq | awk '{print $1}'` 取 PID。
# 而 `pidof dnsmasq` 返回 3 个 PID，第一个是 **ujail 辅助子进程**
# （实测 wchan=anon_pipe_read、5 个 fd、0 个 socket:53），
# 对它 SIGHUP 是**空操作** —— 按钮点了完全无效，页面却报「已清空」。
#
# 修法：Lua 委托给 `dnschain-health flush`，后者用 dc_dnsmasq_pid
# （按 :53 socket inode 反查）定位真正的进程。
# ⚠️ 必须先剥注释行：修复说明的注释里本身含 `pidof dnsmasq`，
#    直接 grep 会永久误报（AGENTS §6 第 6 条同类坑，本仓库踩过多次）。
if sed 's/--.*//' "$MOD" 2>/dev/null | grep -q 'pidof dnsmasq'; then
	fail "Lua 侧仍用 pidof dnsmasq 取 PID（第一个是 ujail 辅助进程，SIGHUP 无效）"
else
	pass "Lua 侧不用 pidof dnsmasq（避免选错 PID）"
fi
if grep -q 'dnschain-selftest flush' "$MOD" 2>/dev/null; then
	pass "清缓存委托给 dnschain-selftest flush（复用 dc_dnsmasq_pid）"
else
	fail "清缓存没有走 dnschain-selftest flush（会各自实现、迟早漂移）"
fi
if body_of "$SELFTEST" | grep -q 'flush)'; then
	pass "dnschain-selftest 有 flush 子命令"
else
	fail "dnschain-selftest 缺 flush 子命令（dc_flush_cache 会成死代码）"
fi

# ── dnsmasq 日志不能是 /dev/null（v0.14.8）──
#
# 上游 `99-default-settings` 每次构建把 /etc/dnsmasq.conf 写成
# log-facility=/dev/null，而生成的配置 conf-file= 引用它 → 日志全丢。
# 实测 logqueries=1 但 logread 里 dnsmasq 恒为 0 条。
#
# ⚠️ 不能用 UCI dhcp.@dnsmasq[0].logfacility 修：init.d/dnsmasq 会再写一条，
# 与 conf-file 里的重复 → `illegal repeated keyword` → dnsmasq 起不来。
# 也不能用 /dev/log（ujail 未挂载）。可用的是 syslog。
# ⚠️ 必须先剥注释再判（AGENTS §6 第 6 条）：这两段代码里都有
#    「不能用 UCI logfacility / 不能用 /dev/log」的说明性注释，
#    直接 grep 会命中注释，让断言永久误报。
_udef_code=$(sed 's/#.*//' "$GAMING" 2>/dev/null)
_recon_code=$(sed 's/#.*//' "$RECONCILE" 2>/dev/null)

if printf '%s\n' "$_udef_code" | grep -q "log-facility=syslog"; then
	pass "uci-defaults 把 dnsmasq 日志改为 syslog"
else
	fail "uci-defaults 未修正 dnsmasq 日志（/dev/null 会丢弃全部日志）"
fi
if printf '%s\n' "$_recon_code" | grep -q "log-facility=syslog"; then
	pass "收敛器会自愈 dnsmasq 日志配置"
else
	fail "收敛器未自愈 dnsmasq 日志配置（被上游覆盖后日志再丢）"
fi
# 反向断言：不得用 UCI logfacility（会与 conf-file 重复导致 dnsmasq 起不来）
if printf '%s\n' "$_udef_code" "$_recon_code" | grep -q "dnsmasq\[0\]\.logfacility"; then
	fail "用了 UCI logfacility —— 会与 conf-file 重复导致 dnsmasq 起不来"
else
	pass "未用 UCI logfacility（避免重复关键字）"
fi

# ── section 名必须与 config 里的**名字**一致（不是类型）（v0.14.5）──
#
# 配置文件里 `config ssr 'compat'` —— 类型是 ssr、**名字是 compat**。
# `dc_get <name> <option>` 走 `uci get dnschain.<name>.<option>`，
# 所以必须写 `dc_get compat mode`。
#
# 实测踩过：写成 `dc_get ssr mode` 查的是「名字为 ssr 的 section」，
# 它不存在 → 恒返回空 → 恒走兜底 "0" → 页面选「7 — 模块内置 DNS」
# 被静默推翻。v0.14.4 的 M2 修复正是因为名字仍错而**没真正生效**。
for _bad in "ssr enforce" "ssr mode" "ssr require_ipv6"; do
	if sed 's/#.*//' "$LIB" 2>/dev/null | grep -q "dc_get $_bad" \
	   || sed 's/#.*//' "$RECONCILE" 2>/dev/null | grep -q "dc_get $_bad"; then
		fail "用了错误的 section 名（dc_get $_bad）—— 应为 compat"
	else
		pass "未使用错误的 section 名（dc_get $_bad）"
	fi
done
if grep -q 'dc_get compat mode' "$LIB" 2>/dev/null; then
	pass "dc_ssr_mode_for_profile 读 compat.mode（名字正确）"
else
	fail "dc_ssr_mode_for_profile 未读 compat.mode"
fi
if grep -q 'dc_get compat enforce' "$RECONCILE" 2>/dev/null; then
	pass "reconcile 读 compat.enforce"
else
	fail "reconcile 未读 compat.enforce"
fi

# ── health cycle 必须有互斥锁（v0.14.2）──
#
# daemon 每 interval 秒跑一轮，页面按钮随时可触发。并发时
# dc_health_upsert 的「读-过滤-写- mv」不原子，会丢状态行。
if body_of "$LIB" | grep -q '\.cycle\.lock'; then
	fail "健康探测的互斥锁仍在（dc_health_cycle 应已删除）"
else
	pass "健康探测已删除（互斥锁一并移除）"
fi

# ── v0.21.0：状态写盘逻辑随改道一起删除 ──
if body_of "$LIB" | grep -q 'dc_health_upsert'; then
	fail "dc_health_upsert 已删除，但仍存在"
else
	pass "状态文件写盘逻辑已删除（无改道状态需要维护）"
fi

# 动态文本必须转义（域名/原因含 & < > 会让整个 SVG 解析失败）
if body_of "$DIA" | grep -q 's = s:gsub("&", "&amp;")'; then
	pass "图示文本有 HTML 转义"
else
	fail "图示文本未转义（含 & < > 时整张图会空白）"
fi

echo "── 10. 页面不得嵌套 <form> ─────────────────────────────"

# CBI 的 map 模板已把整页包在 <form method="post"> 里。
# 内层 <form> 是非法 HTML，浏览器会丢掉内层标签 —— 于是内层按钮
# 实际提交的是外层表单（= 触发保存）。实测：点「解释」看到「配置已保存」。
#
# ⚠️ 必须用 lua_body_of：general.lua 的注释里**写着**这件事
# （「这里不能用 <form>」），用 body_of 会把注释行算进去，永久误报。
if lua_body_of "$GEN" | grep -q '<form'; then
	fail "页面里有嵌套 <form>（点按钮会触发保存而不是查询）"
else
	pass "页面无嵌套 <form>"
fi

if body_of "$JS" | grep -q 'bindExplain'; then
	pass "解释按钮由 JS 绑定（自己跳转，不提交表单）"
else
	fail "解释按钮没有 JS 绑定"
fi

# Enter 键也必须拦住，否则在输入框里回车会触发外层保存
if body_of "$JS" | grep -q "ev.key === 'Enter'"; then
	pass "输入框拦截 Enter（不触发外层保存）"
else
	fail "输入框没拦 Enter（回车会保存配置）"
fi

echo "── 11. 中文文案完整 ───────────────────────────────────"

for s in '自定义域名' '判定链路' '改道状态' '改道明细' '观测与阈值'; do
	if grep -qF "msgid \"$s\"" "$PO"; then
		pass "PO 含「$s」"
	else
		fail "PO 缺「$s」"
	fi
done

# 图示模块的文案也要进 PO（漏了图内文字会中英混排）
if grep -qF 'msgid "改道状态思维导图"' "$PO"; then
	pass "PO 含图示文案"
else
	fail "PO 缺图示文案（图内文字会中英混排）"
fi

echo "── 12. 性能不变量（v0.21.0 重写）────────────────────────"
#
# 原 §12 锁的是分诊的三项性能修复（集合快照、IP 段批量化、覆盖判定）。
# 分诊功能整体删除后，这些断言失去对象 —— 改为锁**删除本身**，
# 防止有人把分诊加回来（它每轮 logread + 最多 12 个并发探测）。
for _f in "files/usr/bin/dnschain-triage" "files/usr/bin/dnschain-health"; do
	if [ -e "$_f" ]; then
		fail "$_f 应已删除（分诊/改道功能移除）"
	else
		pass "$_f 已删除"
	fi
done

# 页面侧不得再出现分诊/改道的数据采集（它们曾是整页 55 秒的主因）
if body_of "$DATA" | grep -q 'dnschain-triage'; then
	fail "数据层仍在调 dnschain-triage"
else
	pass "数据层不再调 dnschain-triage"
fi
# ⚠️ 必须先剥注释：dnschain.lua 里保留了「v0.21.0 起入口从
#    dnschain-health 挪到 selftest」这类说明性注释，不剥会永久误报
#    （AGENTS §6 第 6 条记载的同类坑，本仓库踩过多次）。
if sed 's/--.*//' "$DATA" 2>/dev/null | grep -q 'dnschain-health'; then
	fail "数据层仍在调 dnschain-health"
else
	pass "数据层不再调 dnschain-health"
fi

# 库文件里不得再有每轮 logread（分诊的数据源）
if body_of "$LIB" | grep -q 'logread'; then
	fail "库文件仍在 logread（分诊的数据源应已删除）"
else
	pass "库文件不再 logread（每轮 cycle 少一次采集）"
fi

# 自检缓存必须保留（它是页面响应速度的关键，与分诊无关）
if body_of "$DATA" | grep -qF '.selftest.cache'; then
	pass "数据层保留自检跨请求缓存 .selftest.cache"
else
	fail "数据层缺自检缓存（切 tab 会重跑完整自检）"
fi

# 按钮必须能绕过缓存
if body_of "$GENERAL" | grep -q 'ds.selftest(true)'; then
	pass "「立即重新自检」绕过缓存"
else
	fail "「立即重新自检」未绕过缓存（点了看到旧结果）"
fi


echo "── 13. tab 结构不变量（v0.18.0，ADR-0007）────────────────"

# ① SECTION_TAB 里每个 section 标题都要能在 general.lua 找到 m:section 声明
#
#    这条防的是「登记了但没建」与「建了但没登记」两种漂移：
#    前者导致 SECTION_TAB 有死键，后者导致该 section 不被 JS 归组
#    （会渲染在所有 tab 之外，看起来像页面错乱）。
#
#    ⚠️ 只比对**标题字符串**是否出现在 m:section(...) 那一行里。
#       不解析 Lua，避免引入脆弱的正则。
# v0.22.0：18 → 16 个 section。删除「DNS 分流状态」「分诊结果」「观测与阈值」
# （健康改道与分诊整体移除），新增「DNS 分流去向」（原「DNS 分流状态」改名
# 并改为静态两档）。
_sec_missing=""
for _t in "当前状态" "DNS 分流去向" "自检" "操作" \
          "自定义域名 · 国内（补全归属）" "自定义域名 · 国外（补全归属）" \
          "已录入清单" \
          "国内上游" "国外上游" "双栈策略" "端口与实例" "缓存" \
          "名单规模" "SSR-Plus 兼容" "拦截与框架开关" "DHCP 下发 DNS（明文）"; do
	if ! body_of "$GENERAL" | grep -qF "translate(\"$_t\")"; then
		_sec_missing="$_sec_missing $_t"
	fi
done
if [ -z "$_sec_missing" ]; then
	pass "SECTION_TAB 的 16 个 section 都有 m:section 声明"
else
	fail "SECTION_TAB 有 section 无声明:$_sec_missing"
fi

# v0.22.0：每个 section 都必须登记进 SECTION_TAB，否则 dnschain.js 的
# activate() 会走 `if (!sec.tab) { sec.el.hidden = false }` ——
# 该 section 在**所有 tab 里都显示**。
# 实测：漏登记「DNS 分流去向」导致这张图在 4 个 tab 全都渲染。
for _t in "DNS 分流去向" "已录入清单" "名单规模"; do
	if body_of "$GENERAL" | grep -qF "[translate(\"$_t\")]"; then
		pass "section「$_t」已登记进 SECTION_TAB（不会在所有 tab 都显示）"
	else
		fail "section「$_t」未登记进 SECTION_TAB（会在所有 tab 都显示）"
	fi
done

# ①a2 v0.19.0：两个 section 已删除，不得再作为 m:section 出现
#
#   「判定链路」—— 规则图与分流去向图语义重叠，整节删除
#   「域名操作」—— 唯一按钮与页底「保存并应用」重复，整节删除
for _gone in "判定链路" "域名操作"; do
	if body_of "$GENERAL" | grep -qE "^s = m:section\([^)]*translate\(\"$_gone\"\)"; then
		fail "旧 section「$_gone」仍在（v0.19.0 应已删除）"
	else
		pass "旧 section「$_gone」已删除"
	fi
done

# ①b v0.19.0：「改道状态」+「改道明细」已合并为「DNS 分流状态」
#
#     用户指出「其实改道就是 DNS 分流」—— 代码里成立：dc_health_cycle
#     决定域名走哪条链，写进 watch.servers 的就是 server=/域名/...#port。
#     合并后这两个旧 section 标题不得再作为 m:section 出现，
#     否则会出现「同一件事两块」的老问题。
for _old in "改道状态" "改道明细"; do
	if body_of "$GENERAL" | grep -qE "^s = m:section\([^)]*translate\(\"$_old\"\)"; then
		fail "旧 section「$_old」仍在（应与「DNS 分流状态」合并）"
	else
		pass "旧 section「$_old」已合并"
	fi
done

# ①c v0.21.0：「分流明细」整节已删除（随健康改道移除），
# 改为反向断言，防止有人把那张 8 行表加回来。
if body_of "$GENERAL" | grep -qF '个观测域名，全部分流正常'; then
	fail "分流明细表仍存在（应随改道功能删除）"
else
	pass "分流明细表已删除（首屏不再被全绿表占满）"
fi

# ② TAB_ORDER（JS）与 TAB_LABELS（Lua）的 tab id 集合必须一致
#
#    漏改 JS 会让 tab 顺序错乱或某个 tab 不出现；
#    漏改 Lua 会让 tab 显示成 id 原文（如 "overview"）。
# v0.19.0：6 个 tab 重划为 4 个（overview/resolve/split/proxy/dhcp → status/upstream/lists）
for _id in status domains upstream lists; do
	# ⚠️ TAB_LABELS 里各 id 的等号对齐空格数可能不同，
	#    所以不能用固定字符串匹配，用「id 后跟可选空格再跟 =」的正则。
	if body_of "$GENERAL" | grep -qE "^[[:space:]]*${_id}[[:space:]]*=[[:space:]]*translate"; then
		:
	else
		fail "TAB_LABELS 缺 tab id「$_id」"
	fi
	if body_of "$JS" | grep -qF "'$_id'"; then
		:
	else
		fail "TAB_ORDER 缺 tab id「$_id」（漏改 JS 会导致该 tab 不出现）"
	fi
done
pass "TAB_ORDER（JS）与 TAB_LABELS（Lua）的 4 个 tab id 都存在"

# ②b 旧 tab id 不得残留（否则会出现空 tab 或归组失败）
for _old in overview resolve split proxy dhcp; do
	if body_of "$JS" | grep -qF "'$_old'"; then
		fail "TAB_ORDER 残留旧 tab id「$_old」（v0.19.0 应已合并）"
	else
		:
	fi
done
pass "TAB_ORDER 无旧 tab id 残留"

# ③ diagnosis.lua 必须存在兜底阶段（新增自检项不能静默消失）
if [ -f "$DIAG" ]; then
	pass "diagnosis.lua 存在"
else
	fail "缺 diagnosis.lua（归组与证据推导无处安放）"
fi

if body_of "$DIAG" | grep -qF 'FALLBACK_LABEL'; then
	pass "diagnosis.lua 有兜底阶段常量"
else
	fail "diagnosis.lua 缺兜底阶段（新增检查项会从图中消失）"
fi

if body_of "$DIAG" | grep -qF '未归入链路阶段'; then
	pass "兜底阶段会标注「未归入链路阶段（共 N 项）」"
else
	fail "兜底阶段没标注未归组数量（维护者不知道要去归组）"
fi

# ④ 规则未命中时必须诚实说「未识别」，不能编造原因
if body_of "$DIAG" | grep -qF '未识别的失败模式'; then
	pass "规则未命中时输出「未识别的失败模式」"
else
	fail "规则未命中时未诚实标注（会生成看起来合理但可能错误的诊断）"
fi

# ⑤ 两个重复按钮已合并：import_lists 不得再存在
#
#    它曾与 reconcile_now 逐字相同（都是 dnschain-reconcile）。
#    留着这个函数名，后来者会再接一个重复入口回来。
if body_of "$DATA" | grep -q 'function M.import_lists'; then
	fail "M.import_lists 仍存在（与 M.reconcile_now 重复，会引出第二个入口）"
else
	pass "重复的 M.import_lists 已删除"
fi

if body_of "$GENERAL" | grep -qF 'translate("手动导入名单")'; then
	fail "「手动导入名单」按钮仍存在（与「一键归一」执行同一命令）"
else
	pass "「手动导入名单」按钮已合并"
fi

# ⑥ 「已录入清单」必须有独立 section 且已进 SECTION_TAB
if body_of "$GENERAL" | grep -qF 'm:section(TypedSection, "dnschain", translate("已录入清单"))'; then
	pass "「已录入清单」是独立 section"
else
	fail "「已录入清单」未拆成独立 section（会挂在「国外」下面，语义错）"
fi

if body_of "$GENERAL" | grep -qF '[translate("已录入清单")]'; then
	pass "「已录入清单」已登记进 SECTION_TAB"
else
	fail "「已录入清单」未登记进 SECTION_TAB（JS 归组时找不到）"
fi

# ⑦ 链路拓扑图必须取代旧的两张图（不重复渲染）
if body_of "$GENERAL" | grep -qF '_live_diag_map'; then
	pass "页面用链路拓扑图（_live_diag_map）"
else
	fail "页面缺链路拓扑图"
fi

# ⚠️ 判据必须**剥掉注释**再查：general.lua 里有一句
#    「解析链路（_chain_graph）拓扑图 + 端口存活色」的解释性注释，
#    不剥注释会让这条断言永久误报（AGENTS §6 第 7 条记载的坑）。
if body_of "$GENERAL" | grep -qF 's:option(DummyValue, "_chain_graph"'; then
	fail "旧的「解析链路」图仍在（与链路拓扑重复）"
else
	pass "旧的「解析链路」图已删除"
fi

# ⑧ selftest 必须输出 AT / DUR / RUN（用户要的时间戳与序列号）
if body_of "$SELFTEST" | grep -qF 'AT=${_at}' && \
   body_of "$SELFTEST" | grep -qF 'DUR=${_dur}s' && \
   body_of "$SELFTEST" | grep -qF 'RUN=${_run_no}'; then
	pass "selftest 的 SUMMARY 输出 AT / DUR / RUN"
else
	fail "selftest 的 SUMMARY 缺 AT / DUR / RUN（用户无法判断结论新旧）"
fi


echo "── 14. 客户机链路诊断与分级自愈（v0.23.0，ADR-0009）───────"

DIAG="files/usr/bin/dnschain-client-diag"
CFG="files/etc/config/dnschain"

# ① 脚本存在且有执行位
if [ -f "$DIAG" ]; then
	pass "客户机诊断脚本存在"
else
	fail "缺少 $DIAG"
fi

# ② 配置 section 与关键键齐全
_dk=""
for _k in enabled autofix_enabled interval fail_threshold fail_window \
          retain_sec retain_max autofix_interval; do
	if ! body_of "$CFG" | grep -qE "^[[:space:]]*option $_k "; then
		_dk="$_dk $_k"
	fi
done
if [ -z "$_dk" ]; then
	pass "client_diag 的 8 个配置键齐全"
else
	fail "client_diag 缺配置键:$_dk"
fi

# ③ 「不算失败」的四类必须显式出现在代码里
#
#    这四类是 ADR-0009 §3.4 的核心：误判会让结论完全相反
#    （v0.4.0 时代把空答复当失败，得出「国内也全挂」的错误结论）。
_nd=""
#    duplicate 在代码里靠「只认 f[5]=="is" 的 reply」排除 ——
#    `reply query is duplicate` 的第 5 字段是 "query" 不是 "is"，
#    因此天然不进任何判定分支。故查该白名单判据。
for _t in 'NODATA-IPv6' 'NXDOMAIN' 'f[5] == "is"' 'CNAME'; do
	if ! body_of "$DIAG" | grep -qF "$_t"; then
		_nd="$_nd [$_t]"
	fi
done
if [ -z "$_nd" ]; then
	pass "四类「不算失败」都在代码里显式排除"
else
	fail "客户机诊断漏了「不算失败」的判据:$_nd"
fi

# ④ 失败判据只认 servfail / noreply
if body_of "$DIAG" | grep -qE 'servfail\|noreply\) return 0'; then
	pass "失败判据只认 servfail / noreply"
else
	fail "失败判据不明确（应只认 servfail 与 noreply）"
fi

# ⑤ 分级自愈 L1/L2/L3 都在
_lv=""
for _n in 1 2 3; do
	if ! body_of "$DIAG" | grep -qE "^[[:space:]]*$_n\)"; then
		_lv="$_lv L$_n"
	fi
done
if [ -z "$_lv" ]; then
	pass "分级自愈 L1/L2/L3 三档齐全"
else
	fail "分级自愈缺档:$_lv"
fi

# ⑥ 自动路径必须检查时间窗（手动路径不检查）
if body_of "$DIAG" | grep -qF '_diag_window_ok || return 0'; then
	pass "自动自愈受时间窗约束（防重启循环）"
else
	fail "自动自愈没有时间窗检查（故障持续时会反复重启 dnsmasq）"
fi

# ⑦ 手动 heal 不得检查时间窗
if body_of "$DIAG" | sed -n '/^cmd_heal()/,/^}/p' | grep -qF '_diag_window_ok'; then
	fail "手动 heal 被时间窗挡住（用户明知可断网却点不动）"
else
	pass "手动 heal 不受时间窗限制"
fi

# ⑧ 手写优先：自动列表必须被手写列表排除
if body_of "$LIB" | grep -qF 'dc_exclude "$DNSCHAIN_CUSTOM_DOM"' && \
   body_of "$LIB" | grep -qF 'dom_auto_domestic'; then
	pass "自动列表服从手写优先（生成时排除手写已声明域名）"
else
	fail "自动列表没有排除手写列表（会造成同一域名两条 server=，dnsmasq 当候选）"
fi

# ⑨ 自动列表的排除必须走 dc_exclude，不能用 grep -Fvxf
if body_of "$LIB" | sed -n '/^dc_gen_custom_lists()/,/^}/p' | grep -qF 'grep -Fvxf'; then
	fail "自动列表用了 grep -Fvxf（BusyBox 下空文件会吞掉全部输入）"
else
	pass "自动列表用 dc_exclude 排除（空文件安全）"
fi

# ⑩ 客户机识别不得用 MAC
#    这条判据查「页面/模型层有没有把 MAC 当身份」，不查 diag 脚本 ——
#    diag 脚本只输出 IP，压根不碰 MAC，无需声明。
if body_of "$MODEL" | grep -qF '不用 MAC' || \
   body_of "$GENERAL" | grep -qF '不用 MAC'; then
	pass "客户机识别不用 MAC（随机 MAC 不能作设备身份）"
else
	fail "客户机识别没有声明不用 MAC"
fi

# ⑪ init 不得再启动已删除的 dnschain-health
if body_of "$INIT" | grep -qE 'command /usr/bin/dnschain-health'; then
	fail "init 仍在启动已删除的 dnschain-health（v0.22.0 遗留缺陷）"
else
	pass "init 不再启动已删除的 dnschain-health"
fi

# ⑫ 新守护必须被 procd 托管
if body_of "$INIT" | grep -qF 'dnschain-client-diag daemon'; then
	pass "客户机诊断守护由 procd 托管"
else
	fail "客户机诊断守护没有被 procd 托管"
fi

# ⑬ 保留时长与条目上限必须可配（用户明确要求）
if body_of "$DIAG" | grep -qF 'dc_get client_diag retain_sec' && \
   body_of "$DIAG" | grep -qF 'dc_get client_diag retain_max'; then
	pass "保留时长与条目上限均可配置"
else
	fail "保留时长或条目上限写死（用户要求可自定义）"
fi

# ⑭ ACL 必须放行新脚本
ACLF="package/luci-app-dnschain/root/usr/share/rpcd/acl.d/luci-app-dnschain.json"
if grep -qF 'dnschain-client-diag' "$ACLF" 2>/dev/null; then
	pass "ACL 已放行客户机诊断脚本"
else
	fail "ACL 未放行 dnschain-client-diag（页面调用会 403）"
fi

# ⑮ 页面 section 必须登记进 SECTION_TAB（否则在所有 tab 都显示）
if body_of "$GENERAL" | grep -qF '[translate("客户机链路诊断")]'; then
	pass "客户机诊断 section 已登记进 SECTION_TAB"
else
	fail "客户机诊断 section 未登记进 SECTION_TAB（会在所有 tab 都显示）"
fi


# ⑯ 新 section 不得使用裸 esc（它只是 emit_tab_meta 内的局部函数）
#
#    实测踩过：v0.23.0 的客户机诊断 section 用了裸 `esc(`，而 `esc`
#    只在 `emit_tab_meta` 与「单域名解释」两个 cfgvalue 内部局部定义，
#    全局不可见 → 打开页面直接 Runtime error:
#        attempt to call global 'esc' (a nil value)
#    整页 500。渲染测试用 pcall 捕获后只记 ok=False，而该 section 在
#    测试数据下走了「无数据提前返回」分支，所以没抓到。
_esc_bad=""
_dstart=$(grep -n '客户机链路诊断（v0.23.0' "$GENERAL" | head -1 | cut -d: -f1)
_dend=$(grep -n '^-- ── 国内上游 ──' "$GENERAL" | head -1 | cut -d: -f1)
if [ -n "$_dstart" ] && [ -n "$_dend" ]; then
	if sed -n "${_dstart},${_dend}p" "$GENERAL" | grep -vE '^\s*--' | grep -qE '(^|[^.[:alnum:]_])esc\('; then
		_esc_bad="yes"
	fi
fi
if [ -z "$_esc_bad" ]; then
	pass "客户机诊断 section 使用 dg.esc（裸 esc 是局部函数，全局不可见）"
else
	fail "客户机诊断 section 用了裸 esc（打开页面会 Runtime error: attempt to call global 'esc'）"
fi


# ⑰ 查询流水必须记全部查询（含成功），不能只记失败
#
#    实测踩过：首版 `_diag_is_fail "$st" || continue` 在写流水之前就跳过了，
#    成功查询全丢 → 用户看不到「这台设备刚才查了什么」。
#    判据：daemon 的消费循环里必须调 _diag_record_flow，且它不在
#    `_diag_is_fail` 的条件分支内（即对每条查询都记）。
#    ⚠️ 不能按具体的管道形态匹配（曾用 `_diag_stream | while`，
#    后来管道改成 `tail -f | while` 就失配了）。
if body_of "$DIAG" | grep -qF '_diag_record_flow' && \
   body_of "$DIAG" | sed -n '/while IFS=.|. read -r ip dom up st ans/,/^	done/p' \
     | grep -B2 '_diag_record_flow' | grep -qv '_diag_is_fail'; then
	pass "查询流水记录全部查询（含成功）"
else
	fail "查询流水只在失败时记录（用户看不到成功查询的完整链路）"
fi

# ⑱ flow 子命令必须存在且兼容「只给条数」的调用形态
if body_of "$DIAG" | grep -qE '^\s*flow\)' && \
   body_of "$DIAG" | sed -n '/^cmd_flow()/,/^}/p' | grep -qF 'limit="$ip"'; then
	pass "flow 子命令兼容两种调用形态（flow <IP> <N> / flow <N>）"
else
	fail "flow 子命令缺参数兼容（Lua 侧 IP 为空时拼出 flow 200 会零输出）"
fi

# ⑲ 九个可配置项必须在页面上有输入框
#
#    用户明确要求「可自定义时间和条目数量」。只在脚本里 dc_get 读、
#    页面无入口 = 用户改不了。
_ui_missing=""
for _k in enabled autofix_enabled interval fail_threshold fail_window \
          flow_retain_sec flow_retain_max retain_sec retain_max autofix_interval; do
	if ! body_of "$GENERAL" | grep -qE "option\((Flag|Value), \"$_k\""; then
		_ui_missing="$_ui_missing $_k"
	fi
done
if [ -z "$_ui_missing" ]; then
	pass "10 个诊断配置项都有页面输入框"
else
	fail "诊断配置项缺页面输入框:$_ui_missing（用户改不了）"
fi

# ⑳ 流水与失败记录必须 chmod 644
#
#    mktemp 建的文件是 0600，rpcd 以受限身份读 → 页面显示「还没有查询流水」
#    而数据其实在。实测踩过。
if body_of "$DIAG" | grep -qF 'chmod 644 "$DIAG_FLOW_LOG"'; then
	pass "查询流水文件放开读权限（否则 LuCI 读不到）"
else
	fail "查询流水文件没 chmod 644（页面会显示空列表而数据其实在）"
fi


# ㉑ 自动刷新必须用 MutationObserver 等待 section 出现
#
#    实测踩过：直接在 readyState 后调 startAutoRefresh()，而 LuCI 的
#    CBI 内容是异步渲染的 —— 那时 section 还没进 DOM，输入框查不到、
#    刷新逻辑静默失效（页面看起来正常，只是永远不刷新）。
if body_of "$JS" | grep -qF 'MutationObserver' && \
   body_of "$JS" | grep -qF 'bootAutoRefresh'; then
	pass "自动刷新用 MutationObserver 等 section 就绪"
else
	fail "自动刷新没有等 section 就绪（LuCI 异步渲染会导致它静默失效）"
fi

# ㉒ init 必须包 try/catch，否则一处抛错会拖死自动刷新
if body_of "$JS" | grep -qF 'safeInit'; then
	pass "init 有 try/catch 兜底（不拖死自动刷新）"
else
	fail "init 没有兜底（任何一步抛错都会让自动刷新不启动）"
fi

# ㉓ classList 访问必须防 undefined（SVG 元素没有 classList）
#
#    实测踩过：markBlockRows 对 SVG 子元素调 classList 抛
#    "Cannot read properties of undefined (reading 'classList')"，
#    整个 init 中断 → 自动刷新不启动，而控制台只有这一条错。
_noclasslist_bad=""
#    判据要点（两个坑都踩过）：
#      ① 必须先剥掉注释行 —— 注释里写着「el.classList.contains() 会抛」
#         这类说明文字，不剥会让断言永久误报（AGENTS.md 第 6 条）。
#      ② 防护与调用的距离不固定（有的隔 4 行），窗口取 6 行。
body_of "$JS" | grep -vE '^[[:space:]]*\*|^[[:space:]]*/\*|^[[:space:]]*//' \
  | grep -nE '\.classList\.contains|\.classList\.add' | while IFS=: read -r ln rest; do
	ctx=$(body_of "$JS" | grep -vE '^[[:space:]]*\*|^[[:space:]]*/\*|^[[:space:]]*//' | sed -n "$((ln-6)),${ln}p")
	case "$ctx" in
		*'!el.classList'*|*'!row.classList'*|*'!box.classList'*) ;;
		*) echo "$ln" ;;
	esac
done > /tmp/.cls-bad.$$
if [ -s /tmp/.cls-bad.$$ ]; then
	_noclasslist_bad="yes"
fi
rm -f /tmp/.cls-bad.$$
if [ -z "$_noclasslist_bad" ]; then
	pass "classList 访问都有 undefined 防护（SVG 元素没有 classList）"
else
	fail "有 classList 访问缺防护（SVG 子元素会让 init 抛错）"
fi

# ㉔ 手动刷新按钮必须存在
if body_of "$GENERAL" | grep -qE 'option\(Button, "_flow_refresh"'; then
	pass "有「立即刷新」手动按钮"
else
	fail "缺手动刷新按钮（用户要求「手动刷新」）"
fi

# ㉕ 刷新间隔必须可配且传进页面
if body_of "$GENERAL" | grep -qE 'option\(Value, "flow_refresh"' && \
   body_of "$CFG" | grep -qE '^\s*option flow_refresh '; then
	pass "刷新间隔可配置（flow_refresh）"
else
	fail "刷新间隔不可配置"
fi


# ㉖ 必须是两级结构：第一级在线主机 → 第二级单机链路
#
#    用户明确要求「选定点击主机后转到第二级，按选中的主机实时刷新整个链路状态」。
if body_of "$GENERAL" | grep -qE 'option\(DummyValue, "_client_hosts"' && \
   body_of "$GENERAL" | grep -qF 'dc_host=' && \
   body_of "$GENERAL" | grep -qE 'option\(DummyValue, "_client_flow"'; then
	pass "两级结构（在线主机 → 单机链路）"
else
	fail "缺两级结构（用户要求点主机后进第二级）"
fi

# ㉗ 第二级必须能显示「从哪里来 / 到哪里去」
if body_of "$GENERAL" | grep -qF 'where_to' && \
   body_of "$GENERAL" | grep -qF 'translate("到哪里去")'; then
	pass "第二级显示「到哪里去」"
else
	fail "第二级缺「到哪里去」列"
fi

# ㉘ 域名必须可下钻到链路详情（trace）
if body_of "$GENERAL" | grep -qF 'dc_dom=' && \
   body_of "$MODEL" | grep -qF 'function M.client_diag_trace'; then
	pass "域名可下钻看完整链路（trace）"
else
	fail "域名不能下钻看链路详情"
fi

# ㉙ 搜索功能必须存在（脚本 + 模型 + 页面）
if body_of "$DIAG" | grep -qE '^\s*search\)' && \
   body_of "$MODEL" | grep -qF 'function M.client_diag_search' && \
   body_of "$GENERAL" | grep -qF 'dc_q'; then
	pass "搜索功能完整（脚本 + 模型 + 页面）"
else
	fail "搜索功能不完整（用户要求按域名关键词搜索）"
fi

# ㉚ hosts 必须以 ARP 在线表为准，不能只靠历史记录
if body_of "$DIAG" | grep -qF 'ip neigh show'; then
	pass "在线主机取自 ARP 邻居表（不是只靠历史记录）"
else
	fail "在线主机没查 ARP（会把已下线主机也列为在线）"
fi

# ㉛ 刷新必须保留 dc_host / dc_q 参数
#
#    实测踩过：自动刷新不带 search 时每次跳回第一级，
#    用户正在看的第二级详情被踢掉。
if body_of "$JS" | grep -qF 'location.pathname + location.search'; then
	pass "刷新保留 URL 参数（不踢回第一级）"
else
	fail "刷新丢了 URL 参数（会自动跳回第一级）"
fi


# ㉜ 必须有「强制直连 CIDR」机制（v0.23.1）
#
#    实测教训：SSR-Plus 的 chnroute 数据不完整，47.239.100.208（阿里云上海）
#    不在 china/whitelist 集合里 → 被判为国外 → 走 v2ray 代理 →
#    代理出站到国内反而失败 → TLS 被关闭。
#
#    后果极隐蔽：cdn.staticsfile.org 解析到该 IP，它是 cc.sefan.pw 依赖的
#    jQuery CDN。jQuery 加载失败 → 页面 $(function(){...}) 不执行 →
#    iframe 的 src 永远不设置 → 白屏。而 DNS 查询全部返回 ok，
#    日志里看不出任何异常。
#
#    实测对照：走代理 ERR_CONNECTION_CLOSED / TLS 握手失败；
#              直连 200，0.15 秒。
if body_of "$DNSCHAIN_SH" | grep -qF 'dc_apply_direct_cidr' && \
   body_of "$CFG" | grep -qE '^\s*list direct_cidr ' && \
   body_of "$RECONCILE" | grep -qF 'dc_apply_direct_cidr'; then
	pass "有强制直连 CIDR 机制（绕过 chnroute 误判）"
else
	fail "缺强制直连 CIDR 机制（国内 IP 被误判走代理会导致 CDN 加载失败）"
fi

# ㉝ direct_cidr 必须用 uci show 解析，不能用 uci get
#
#    list 类型用 `uci get` 返回 rc=1，表现为「配置明明写了却读不到」。
#    实测踩过：函数静默返回 0，whitelist 一条都没写进去，白屏照旧。
if body_of "$DNSCHAIN_SH" | sed -n '/^dc_apply_direct_cidr()/,/^}/p' | grep -qF 'uci -q show dnschain.main'; then
	pass "direct_cidr 用 uci show 解析（list 类型 uci get 读不到）"
else
	fail "direct_cidr 用 uci get 解析（list 类型会返回 rc=1，静默失效）"
fi

# ㉞ dc_apply_direct_cidr 必须在 reconcile 末尾调用
#
#    whitelist 集合由 SSR-Plus 创建，太早写入会静默失败。
#    判据：该调用必须出现在 `return 0` 之前、且行号靠后（收敛末尾）。
#    ⚠️ 不能用「最后一次出现」—— 函数定义在 dnschain.sh 里，
#    reconcile 里只有调用，但行号需按实际文件长度判断。
_total=$(body_of "$RECONCILE" | wc -l)
_line=$(body_of "$RECONCILE" | grep -n 'dc_apply_direct_cidr' | head -1 | cut -d: -f1)
if [ -n "$_line" ] && [ "$_line" -gt $((_total / 2)) ]; then
	pass "强制直连在收敛末尾执行（whitelist 此时已存在）"
else
	fail "强制直连在收敛早期执行（whitelist 可能还不存在，写入会静默失败）"
fi

echo ""
if [ "$rc" -ne 0 ]; then
	echo "!!! 域名分流与改道契约校验失败" >&2
	exit 1
fi
echo "域名分流与改道契约校验通过。"
exit 0
