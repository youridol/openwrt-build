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
HEALTH=files/usr/bin/dnschain-health
INIT=files/etc/init.d/dnschain
CONF=files/etc/config/dnschain
GEN=package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua
MOD=package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua
DIA=package/luci-app-dnschain/luasrc/model/cbi/dnschain/diagrams.lua
CSS=package/luci-app-dnschain/htdocs/luci-static/resources/dnschain/dnschain.css
JS=package/luci-app-dnschain/htdocs/luci-static/resources/dnschain/dnschain.js
PO=package/luci-app-dnschain/po/zh-cn/luci-app-dnschain.po
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

# 页面上必须有两个 DynamicList 的 domain 选项（一个走直连、一个走代理）
n_dyn=$(body_of "$GEN" | grep -c 'option(DynamicList, "domain"')
if [ "$n_dyn" = "2" ]; then
	pass "页面有两个域名输入框（DynamicList domain x2）"
else
	fail "页面域名输入框数量不对：$n_dyn（应为 2）"
fi

# 两个输入框都必须挂 validate —— 缺一个就能把非法条目存进 UCI
n_val=$(body_of "$GEN" | grep -c 'o.validate = validate_domain')
if [ "$n_val" = "2" ]; then
	pass "两个输入框都挂了格式校验"
else
	fail "挂校验的输入框只有 $n_val 个（应为 2）"
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

# 脚本侧也必须有一道校验闸（用户可直接 uci set 绕过页面）
if body_of "$HEALTH" | grep -q 'dc_domain_valid'; then
	pass "脚本侧有域名格式校验（兜住直接改 UCI 的情形）"
else
	fail "脚本侧缺域名格式校验"
fi

if body_of "$HEALTH" | grep -q 'cmd_check'; then
	pass "脚本提供 check 子命令"
else
	fail "脚本缺 check 子命令"
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

# 两条需求规则的判定：首选不通 + 另一条通 → 改道
if body_of "$LIB" | grep -q 'r_other'; then
	pass "改道前会探测另一条链（避免双链故障时误判）"
else
	fail "改道判定没有探测另一条链"
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

# status 的档位里不得再有 fixed（否则自定义域名的真实状态被吞掉）
if grep -q '"fixed"' "$HEALTH"; then
	fail "dnschain-health status 仍有 fixed 档（会吞掉自定义域名的真实状态）"
else
	pass "dnschain-health status 无 fixed 档"
fi
if grep -q 'custom=' "$HEALTH"; then
	pass "汇总用 custom= 标注归属来源（而非占一档状态）"
else
	fail "汇总缺 custom= 标注"
fi

# ── 观测基准集必须「一行一个域名」──
#
# v0.14.0 实测踩过：种子集写成两行字面量，而输出用了
# `printf '%s\n' "$VAR"`（整个变量当**一个**参数）→ 8 个域名被压成
# 2 行、每行 4 个用空格连起来 → dc_watch_list 输出 2 行多域名 →
# 静态片段用 `grep -Fvxf`（逐行精确匹配）排除时**排除不掉** →
# 观测域名同时出现在静态片段与 servers-file →
# dnsmasq 把两条 server= 当候选 → 改道退化成随机走一条。
# 自检第 18 项就是查这个，实测曾 FAIL（PASS=19 FAIL=1）。
if body_of "$LIB" | grep -q "printf '%s\\\\n' \$DNSCHAIN_WATCH_SEED"; then
	pass "基准观测集逐词输出（保证一行一个域名）"
else
	fail "基准观测集输出方式会把多个域名压成一行（静态片段排除会失效）"
fi

# 种子集里不得出现「一行多个域名」的写法
seed_multi=$(body_of "$LIB" | awk '/^DNSCHAIN_WATCH_SEED=/,/^"/' \
	| grep -cE '^[a-z0-9.-]+\.[a-z]{2,} +[a-z0-9.-]+\.[a-z]{2,}')
if [ "$seed_multi" -eq 0 ]; then
	pass "基准集每行只有一个域名"
else
	fail "基准集有 $seed_multi 行含多个域名（会被当成一个 pattern）"
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

if body_of "$LIB" | grep -q 'both-bad'; then
	pass "双链都不通时标记 both-bad（不改道）"
else
	fail "缺双链故障标记"
fi
if body_of "$LIB" | grep -q 'dc_health_cycle'; then
	pass "有改道判定主循环"
else
	fail "缺改道判定主循环"
fi

# 阈值：连败、回切、最小驻留三个都必须存在
for kv in fail_threshold recover_threshold min_dwell; do
	if grep -q "option $kv" "$CONF"; then
		pass "配置含阈值 $kv"
	else
		fail "配置缺阈值 $kv"
	fi
	if body_of "$LIB" | grep -q "$kv"; then
		pass "判定循环使用 $kv"
	else
		fail "判定循环未使用 $kv"
	fi
done

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

# 这是稳定性核心：静态片段改动要 restart（约 3 秒中断），
# 改道是高频事件，必须走 --servers-file + SIGHUP。
if body_of "$LIB" | grep -q 'dc_gen_watch_servers'; then
	pass "有 watch.servers 生成函数"
else
	fail "缺 watch.servers 生成函数"
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

# 写入后必须放开读权限（mktemp 默认 0600 root:root）
if body_of "$LIB" | grep -q 'chmod 0644 "\$DNSCHAIN_WATCH_SERVERS"'; then
	pass "watch.servers 写入后 chmod 0644（降权进程可读）"
else
	fail "watch.servers 未放开读权限（dnsmasq 以 uid 453 运行，读不到）"
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

# 自检也必须能发现这个重叠
if body_of files/usr/bin/dnschain-selftest | grep -q '观测域名不与静态片段重复'; then
	pass "自检含「观测域名不与静态片段重复」项"
else
	fail "自检缺重叠检查项"
fi

echo "── 8. 自检覆盖新功能 ───────────────────────────────────"

for item in '自定义域名列表合法' '改道通道已就绪' '改道状态自洽'; do
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

# 判定链路图必须画出「归属 → 首选 → 探测 → 结论」四个阶段
for node in '自定义 · 国内' '自定义 · 国外' '数据库命中' '未覆盖' \
            '直连链路' '代理链路' '探测首选链路' '探测另一条链路' \
            '保持' '改道' '双链故障'; do
	if body_of "$DIA" | grep -q "$node"; then
		pass "判定链路图含节点「$node」"
	else
		fail "判定链路图缺节点「$node」"
	fi
done

# 需求规则必须写在图下（图能表达结构，规则要可核对）
if body_of "$DIA" | grep -q '访问国外链路不通 → 自动改走直连'; then
	pass "图下写明需求规则（国外不通改直连 / 国内不通改代理）"
else
	fail "图下没写需求规则"
fi

# 状态导图必须分五档，且问题档带「查什么」
for st in '正常' '降级中' '已改道' '双链故障' '未探测'; do
	if body_of "$DIA" | grep -q "title = translate(\"$st\")"; then
		pass "状态导图含档位「$st」"
	else
		fail "状态导图缺档位「$st」"
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
if grep -q 'dnschain-health flush' "$MOD" 2>/dev/null; then
	pass "清缓存委托给 dnschain-health flush（复用 dc_dnsmasq_pid）"
else
	fail "清缓存没有走 dnschain-health flush（会各自实现、迟早漂移）"
fi
if grep -q 'cmd_flush' "$HEALTH" 2>/dev/null; then
	pass "dnschain-health 有 flush 子命令"
else
	fail "dnschain-health 缺 flush 子命令（dc_flush_cache 会成死代码）"
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
	pass "健康探测有互斥锁（并发 cycle 不会丢状态行）"
else
	fail "健康探测无互斥锁（daemon 与手动触发并发会丢行）"
fi

# ── 状态写入必须只有一处实现（v0.14.2 瘦身）──
n_upsert=$(body_of "$LIB" | grep -c "awk -F'|' -v d=\"\$d\" '\$1 != d'")
if [ "$n_upsert" -eq 1 ]; then
	pass "状态文件写盘只有一处实现（dc_health_upsert）"
else
	fail "状态写盘有 $n_upsert 处重复实现（改一处忘另一处会写出不同格式）"
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

echo ""
if [ "$rc" -ne 0 ]; then
	echo "!!! 域名分流与改道契约校验失败" >&2
	exit 1
fi
echo "域名分流与改道契约校验通过。"
exit 0
