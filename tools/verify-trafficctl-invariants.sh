#!/bin/bash
# luci-app-trafficctl 本地不变量校验。
#
# 由 CI 步骤 `Verify luci-app-trafficctl local invariants` 调用；也可在本地直接跑：
#     sh tools/verify-trafficctl-invariants.sh
#
# 为什么需要这些断言
# ------------------
# `package/luci-app-trafficctl/` 是 vendored 副本（源自 YusDyr/luci-app-trafficctl）。
# 我们对其做了三项**上游至今没有**的改动，它们在「同步上游」时最容易被覆盖掉，
# 而覆盖后**界面不报错、构建也成功**，属静默功能失效：
#
#   1. `trafficctl-bytes-nft.sh` 的重写 —— 上游仍用本内核不支持的
#      `flags dynamic` map + `update @bytes_in { … counter }`，且只挂 forward
#      单钩子。丢掉它 → 速率列恒为 `—`。
#   2. 刷新默认值 / 1s·2s 档位 / `refresh_interval` 端到端接线 ——
#      丢掉它 → 冷启动不再自动刷新。
#   3. Telegram 全链路**已移除**（v0.7.0）：视图 / menu.d 登记 / acl.d 授权 /
#      rpcd 三方法 / init.d 服务 / 两个脚本 / UCI 段 / hotplug 通知 / 日志分类。
#      回退它 → 一个能改防火墙的长轮询 bot 又回到固件里跑（且日志分类开关
#      会变成一个永不产生输出的死开关）。
#   4. `po/zh-cn` —— 丢掉它 → 中文界面变英文。
#
# 另外校验「从 UPSTREAM 记录的 tag 克隆上游 → 重放全部 patch → 结果与 vendored
# 包逐字节一致」，这是「日后能跟进上游」的核心保证。
#
# 退出码 0 = 全部通过；1 = 有失败项（CI 据此中止）。
#
# 【必须保持 POSIX sh 兼容】CI 用 `sh tools/verify-trafficctl-invariants.sh` 调用，
# 而 ubuntu runner 的 /bin/sh 是 dash。bash 专有语法（进程替换 `<(...)`、`[[ ]]`、
# 数组、`local`）在这里**不是运行时失败，而是解析期 Syntax error**，整步直接
# exit 2、编译根本不会开始。v0.8.4 的 tag 构建与 10-18/10-19 的定时构建正是栽在
# 进程替换 `<(...)` 上（报 `Syntax error: "(" unexpected`）。
# 因此：新增断言时只用 POSIX 语法；需要临时文件就写进下面的 $TMPD。

set -u

# 临时目录：替代 bash 的进程替换。退出时统一清理。
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT INT TERM HUP

PKG=package/luci-app-trafficctl
V="$PKG/htdocs/luci-static/resources/view/trafficctl"
S="$V/status.js"
# 设置页与页面共用件（v0.6.0 新增）
SET="$V/settings.js"
CSS="$V/status.css"
COMMON="$PKG/htdocs/luci-static/resources/trafficctl/common.js"
PO="$PKG/po/zh-cn/luci-app-trafficctl.po"
B="$PKG/root/usr/local/bin/trafficctl-bytes-nft.sh"
PATCHDIR=patches/luci-app-trafficctl

fail=0
note() { printf '%s\n' "$*"; }
ok()   { printf 'OK   %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fail=1; }

# ─────────────────────────────────────────────────────────────
# Python 解释器探测。
#
# 为什么不能只写 `python3`：在 Windows 上 `python3` 常常存在但**不可用** ——
# 那是 Microsoft Store 的占位符，执行后只打印
#   「Python was not found; run without arguments to install ...」
# 并以非 0 退出。于是 `command -v python3` 判定「有 Python」，
# 而实际检查永远失败，报出来的却是「中文翻译不完整」这种与根因无关的结论。
# 故这里逐个候选**实际执行**一次 --version，只认真正能跑的解释器。
PY=""
for cand in python3 python py; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if [ "$cand" = "py" ]; then
        "$cand" -3 -c 'import sys' >/dev/null 2>&1 && { PY="$cand -3"; break; }
    else
        "$cand" -c 'import sys' >/dev/null 2>&1 && { PY="$cand"; break; }
    fi
done

# ─────────────────────────────────────────────────────────────
note "=== 1. 包存在性与 vendored 版本 ==="
[ -d "$PKG" ] || { bad "缺少 $PKG"; exit 1; }
note "    PKG_VERSION = $(sed -n 's/^PKG_VERSION:=//p' "$PKG/Makefile")"
note "    UPSTREAM    = $(cat "$PATCHDIR/UPSTREAM" 2>/dev/null || echo '(缺失)')"

# ─────────────────────────────────────────────────────────────
note ""
note "=== 2. nft 字节计数后端必须是本内核可用的写法 ==="
# 只看**非注释行**：脚本头部注释会引用上游的错误写法做说明，
# 把注释也算进来会永远误报。
B_CODE="$(grep -v '^[[:space:]]*#' "$B" 2>/dev/null || true)"
if [ -z "$B_CODE" ]; then
    bad "无法读取 $B"
else
    # 2a. 禁止上游那套不支持的内核语法
    if printf '%s\n' "$B_CODE" | grep -qE "type ipv4_addr[[:space:]]*:[[:space:]]*counter"; then
        bad "检测到 'type ipv4_addr : counter' 的 map（本内核报 Not supported）"
        printf '%s\n' "$B_CODE" | grep -nE "type ipv4_addr[[:space:]]*:[[:space:]]*counter"
    fi
    if printf '%s\n' "$B_CODE" | grep -qE "update @bytes_(in|out)"; then
        bad "仍在使用本内核不支持的 'update @bytes_… { … counter }'"
        printf '%s\n' "$B_CODE" | grep -nE "update @bytes_(in|out)"
    fi
    if printf '%s\n' "$B_CODE" | grep -qE "nft add map"; then
        bad "仍在使用 'nft add map'（应改用 set + add @set）"
        printf '%s\n' "$B_CODE" | grep -nE "nft add map"
    fi
    # 2b. 必须是 set + add @set 的受支持写法
    printf '%s\n' "$B_CODE" | grep -qE "^[[:space:]]*type ipv4_addr[[:space:]]*$" \
        && ok "set 使用 'type ipv4_addr'（受支持）" \
        || bad "未找到受支持的 set 定义"
    printf '%s\n' "$B_CODE" | grep -qE "add @bytes_in[[:space:]]*\{ ip daddr counter \}" \
        && ok "使用 'add @bytes_in { ip daddr counter }'" \
        || bad "未找到受支持的 add @set 计数写法"
    # 2c. 三钩子齐备（代理流量走 INPUT/OUTPUT，不经 forward）
    for h in mon_forward mon_input mon_output; do
        grep -q "$h" "$B" \
            && ok "挂载 hook: $h" \
            || bad "缺少 hook $h（代理流量将统计不到）"
    done
    # 2d. @lan 限定地址归属
    grep -q "@lan" "$B" \
        && ok "使用 @lan 限定 LAN 网段" \
        || bad "未用 @lan 限定，集合会被非 LAN 地址污染"
    # 2e. 单事务原子重建（AGENTS.md 红线 8）
    grep -q "nft -c -f" "$B" \
        && ok "提交前先 nft -c -f 校验" \
        || bad "缺少 nft -c -f 预校验，并发会重复建规则导致速率翻倍"
    # 2f. 上游 JSON 契约字段（trafficctl-totals.sh 会消费）
    for fld in bytes_tcp bytes_udp '"src":"nft"' degraded; do
        grep -q "$fld" "$B" \
            && ok "JSON 字段: $fld" \
            || bad "缺少 JSON 字段 $fld（trafficctl-totals.sh 会失真）"
    done
fi

# ─────────────────────────────────────────────────────────────
note ""
note "=== 3. 中文翻译必须存在且完整 ==="
[ -f "$PKG/po/zh-cn/luci-app-trafficctl.po" ] \
    && ok "po/zh-cn 存在" \
    || bad "缺少 po/zh-cn/luci-app-trafficctl.po"
[ -f "$PKG/po/templates/luci-app-trafficctl.pot" ] \
    && ok "pot 模板存在" \
    || bad "缺少 pot 模板"
if [ -n "$PY" ]; then
    if $PY tools/check-trafficctl-i18n.py >/tmp/.tc_i18n.log 2>&1; then
        tail -1 /tmp/.tc_i18n.log
        ok "中文翻译完整（$PY）"
    else
        cat /tmp/.tc_i18n.log
        bad "中文翻译不完整"
    fi
    rm -f /tmp/.tc_i18n.log
else
    note "警告：未找到可用的 Python，跳过翻译覆盖率检查"
fi

# ─────────────────────────────────────────────────────────────
note ""
note "=== 4. 刷新逻辑与 tab 结构（本地 UI 改动）==="
grep -q "optRefresh" "$S" \
    && ok "默认刷新逻辑 optRefresh 存在" \
    || bad "缺少 optRefresh：冷启动将不再自动刷新"
# 刷新档位定义已随「表格与速率」卡片迁到设置页（v0.6.0），devices 页不再有
# 该 chip；两处都查一遍，任一存在即可 —— 只查 status.js 会在迁移后误报。
grep -q "{v:'1',l:'1s'}" "$S" "$SET" \
    && ok "刷新档位含 1s" \
    || bad "刷新档位缺少 1s（要求最低 1 秒）"
# 轮询必须防重入：summary 实测约 1.9s，而档位可设 1s。
# 若退回 `setInterval(runQuery, …)` 这种「不看上一拍是否回来」的写法，
# 请求会层层堆积 → rpcd 不断 fork trafficctl-summary.sh → 路由器 load 飙升、
# 页面反而卡住甚至 XHR 超时。
# 说明：本文件自身会**解释**那个错误写法，故注释行要先剥掉再判断，
# 否则永远误报（这个坑在别处也踩过，见 AGENTS.md 第 9 节）。
S_CODE="$(grep -v '^[[:space:]]*//' "$S")"
if printf '%s\n' "$S_CODE" | grep -qE 'setInterval\(tick,'; then
    ok "轮询经由 tick（带防重入）"
else
    bad "轮询未走 tick：1s 档位会让请求堆积，压垮路由器"
fi
if printf '%s\n' "$S_CODE" | grep -qE 'setInterval\(runQuery,'; then
    bad "存在 setInterval(runQuery, …)：缺少防重入，1s 档位会堆积请求"
    printf '%s\n' "$S_CODE" | grep -nE 'setInterval\(runQuery,'
else
    ok "无 setInterval(runQuery, …)（已改为 setInterval(tick, …)）"
fi
grep -q "queryInFlight" "$S" \
    && ok "存在 queryInFlight 重入锁" \
    || bad "缺少 queryInFlight 重入锁"
grep -q "document.hidden" "$S" \
    && ok "页面不可见时跳过轮询" \
    || bad "缺少 document.hidden 判断（后台标签页仍会压路由器）"
# runQuery 及其两个分支必须 return promise，否则锁在发起请求时就复位，
# 形同虚设（仍会堆积）。
for pat in 'return callTrafficctl()' 'return callDevice(ip, proto)' \
           'p = runAll()' 'p = runSingle(ip)'; do
    grep -qF "$pat" "$S" \
        && ok "runQuery 链路含 '${pat}'" \
        || bad "缺少 '${pat}'：防重入锁会在请求完成前就复位"
done
grep -q "refresh_interval" "$PKG/root/usr/libexec/rpcd/luci.trafficctl" \
    && ok "rpcd 处理 refresh_interval" \
    || bad "rpcd 未处理 refresh_interval"
# 设置区不得有**内层** tab：两级 tab 会让人分不清哪一层在切页。
if grep -qE "tc-settings-tabs|tc-stab|selectSettingsTab" "$S"; then
    bad "status.js 仍有内层 tab"
    grep -nE "tc-settings-tabs|tc-stab|selectSettingsTab" "$S"
else
    ok "设置区无内层 tab"
fi

# ── v0.7.0：Telegram 全链路移除 ─────────────────────────────────────
# 移除要**真的移除**：只清界面引用、把实现留在固件里，等于功能还在后台跑
# （一个长轮询进程 + 一个能改防火墙的 rpc 方法）。故逐层断言其缺席。
for _f in \
    "htdocs/luci-static/resources/view/trafficctl/telegram.js" \
    "root/etc/init.d/trafficctl-telegram" \
    "root/usr/local/bin/trafficctl-telegram.sh" \
    "root/usr/local/bin/trafficctl-telegram-test.sh"
do
    [ -e "$PKG/$_f" ] \
        && bad "Telegram 实现文件仍在：$_f" \
        || ok "已删除 $_f"
done
# menu.d 不得再登记该 tab（登记还在 → 侧边栏出现一个点不开的页）。
if grep -q "trafficctl/telegram" "$PKG/root/usr/share/luci/menu.d/luci-app-trafficctl.json"; then
    bad "menu.d 仍登记 Telegram 页：会多出一个打不开的 tab"
else
    ok "menu.d 已无 Telegram 页"
fi
# rpcd 的三个方法必须连签名一起消失 —— 只删实现留签名，前端仍能调用到空分支。
for _m in telegram_config_get telegram_config_set telegram_test; do
    if grep -q "\"$_m\"" "$PKG/root/usr/libexec/rpcd/luci.trafficctl"; then
        bad "rpcd 仍声明 $_m"
    else
        ok "rpcd 已无 $_m"
    fi
done
# acl.d 不得再授权这些方法（授权留着等于给一个已不存在的接口留通道）。
if grep -qE "telegram_config_get|telegram_config_set|telegram_test" \
        "$PKG/root/usr/share/rpcd/acl.d/luci-app-trafficctl.json"; then
    bad "acl.d 仍授权 Telegram 方法"
else
    ok "acl.d 已无 Telegram 授权"
fi
# UCI：config 段与日志分类开关都不该再有（分段留着＝继续保存一个永不生效的 token）。
if grep -qE "^config telegram|option log_telegram" "$PKG/root/etc/config/trafficctl"; then
    bad "config 仍有 telegram 段或 log_telegram 选项"
else
    ok "config 已无 telegram 段与 log_telegram"
fi
# 后端读写的字段名同理：留着就会去读一个不存在的选项。
if grep -q "log_telegram" "$PKG/root/usr/libexec/rpcd/luci.trafficctl"; then
    bad "rpcd 仍读写 log_telegram"
else
    ok "rpcd 已无 log_telegram"
fi
# 前端 rpc 声明（少一个参数位会让后续实参整体错位）。
if grep -q "log_telegram" "$COMMON"; then
    bad "common.js 的 loggingSet 仍带 log_telegram 参数位"
else
    ok "common.js 已无 log_telegram 参数位"
fi
# hotplug 不得再为已下线的通知写标记文件。
if grep -q "trafficctl_tg_newdev\|telegram_known.json" \
        "$PKG/root/etc/hotplug.d/dhcp/99-trafficctl-newdevice"; then
    bad "hotplug 仍写 Telegram 新设备标记"
else
    ok "hotplug 已无 Telegram 通知分支"
fi
# 日志分类映射不得再指向 telegram（没有来源，永不命中）。
if grep -q 'category="telegram"' "$PKG/root/usr/local/bin/trafficctl-fw.sh"; then
    bad "trafficctl-fw.sh 仍有 telegram 日志分类"
else
    ok "trafficctl-fw.sh 已无 telegram 分类"
fi
# 打包：postinst 不得再启动已删除的服务；prerm 必须停它（respawn 型，
# 文件删掉后仍可能反复重启）。停机放在 prerm 是因为 opkg 顺序为
# prerm → 删文件 → postinst，到 postinst 时 init.d 脚本已不在。
if grep -q "trafficctl-telegram start" "$PKG/Makefile"; then
    bad "Makefile postinst 仍启动 telegram 服务"
else
    ok "Makefile postinst 已不再启动 telegram"
fi
if awk '/define Package\/\$\(PKG_NAME\)\/prerm/,/^endef/' "$PKG/Makefile" \
        | grep -q "trafficctl-telegram stop"; then
    ok "Makefile prerm 停用 telegram 服务（respawn 型，必须在删文件前停）"
else
    bad "Makefile prerm 未停用 telegram 服务：文件删除后它会反复重启"
fi
# 已生成的 .po/.pot 里不该再留 Telegram 的孤儿条目。
if grep -q '^msgid "Telegram' "$PO" 2>/dev/null; then
    bad "po 仍留 Telegram 孤儿条目"
else
    ok "po 已无 Telegram 孤儿条目"
fi

# ── 设置页与共用件（v0.6.0）──────────────────────────────────────────
# 这四项是本仓库相对上游的结构性改动，被覆盖后同样**不报错**：配置会重新
# 挤回设备页、软件卸载的橙黄横幅会回来、两个页面各持一份 rpc/控件定义。
[ -f "$SET" ] \
    && ok "settings.js 存在（设置页独立成 tab）" \
    || bad "缺少 settings.js：配置会退回设备页内联"
[ -f "$COMMON" ] \
    && ok "common.js 存在（页面共用件）" \
    || bad "缺少 common.js：设备页与设置页将各持一份定义"
grep -q "trafficctl/settings" "$PKG/root/usr/share/luci/menu.d/luci-app-trafficctl.json" \
    && ok "menu.d 已登记 settings 页" \
    || bad "menu.d 未登记 settings 页（设置 tab 不会出现）"
# status.js 必须挂上共用模块，否则 T.* 未定义、整页 JS 崩。
grep -qE "^'require trafficctl/common as T'" "$S" \
    && ok "status.js 引用 common.js" \
    || bad "status.js 未引用 trafficctl/common（T.* 将为 undefined，页面崩）"
grep -qE "^'require trafficctl/common as T'" "$SET" \
    && ok "settings.js 引用 common.js" \
    || bad "settings.js 未引用 trafficctl/common（T.* 将为 undefined，页面崩）"
# 每个视图都必须自己注入 status.css：LuCI 只自动加载与**视图同名**的样式，
# 而 htdocs 下没有 trafficctl/settings.css，故这份样式不会自动带上。
# 漏注入时页面**不报错**，只是所有 tc-* 类失效 —— 卡片没边框、chip 没底色、
# 控件挤成一片。v0.6.1 就是这么坏的，所以在此加断言。
#
# 注意：v0.7.0 移除 Telegram 后已无 telegram.js，故这里不再收录它。
# 早先脚本仍引用 $T，而 T 从未定义，在 set -u 下会 exit 1（已修）。
for f in "$S" "$SET" "$V/host.js"; do
    [ -f "$f" ] || continue
    grep -qF "trafficctl/status.css" "$f" \
        && ok "$(basename "$f") 注入 status.css" \
        || bad "$(basename "$f") 未注入 status.css（该页全部 tc-*/tg-* 样式会失效，且不报错）"
done
# 设置页容器必须是 grid：多列（column-count）会把每张卡片压成半宽，
# 「表格与速率」的 4 组档位被迫换成两行 —— 这正是 v0.6.1 修的「多余换行」。
if grep -qE '\.tc-settings-body\s*\{' "$CSS"; then
    if awk '/\.tc-settings-body[[:space:]]*\{/,/\}/' "$CSS" | grep -q 'column-count'; then
        bad ".tc-settings-body 仍用 column-count：卡片会被压成半宽，档位折行"
    else
        ok ".tc-settings-body 未用 column-count（卡片宽度可预期）"
    fi
fi
grep -q 'tc-card--wide' "$CSS" \
    && ok "存在 .tc-card--wide（宽卡片可独占整行）" \
    || bad "缺少 .tc-card--wide：内容多的卡片无法独占整行"
# 切断面板必须嵌在速率限制卡片里，且不得回到「独立顶层子节点」的形态。
grep -q 'tc-cut--embedded' "$S" \
    && ok "切断面板用嵌入形态（tc-cut--embedded）" \
    || bad "切断面板未用嵌入形态：会退回与速率限制并列的独立卡片"
grep -q 'CUT_BASE' "$S" \
    && ok "切断面板基类为常量（重绘不会丢失嵌入类）" \
    || bad "切断面板基类不是常量：renderCut 重设 className 会抹掉 --embedded"
# 软件卸载**不得**再弹橙黄横幅：它不损失任何功能，却每次开页都公告一遍，
# 用户明确要求移除。硬件卸载的告警必须保留（那说的是速率统计真的失效）。
if grep -q "Software flow offloading is active" "$S"; then
    bad "status.js 仍有「软件流量卸载已激活」横幅文案（用户要求移除）"
    grep -n "Software flow offloading is active" "$S"
else
    ok "无软件卸载橙黄横幅文案"
fi
grep -qE "mode === 'software' \|\| mode === 'software-counter'\) return null" "$S" \
    && ok "软件卸载模式直接返回 null（不出横幅）" \
    || bad "软件卸载未短路：橙黄横幅会重新出现"
grep -q "Hardware flow offloading is active" "$S" \
    && ok "硬件卸载告警保留（速率统计确会失效）" \
    || bad "硬件卸载告警被一并删除：该模式速率确实不更新，必须告知"
# 「表格与速率」档位（v0.6.2 起在**设备页**设备表上方，不再在设置页）。
# 判据反转：这些 chip 必须存在于 status.js，且**不得**在 settings.js 留副本 ——
# 两处各定义一份时同一档位会显示不同默认值，正是最初要消除的「重复」。
for pat in 'var pollIntervalPick' 'var avgWindowPick' 'var avgMethodPick' 'var refreshPick' 'var defaultsBtn'; do
    printf '%s\n' "$S_CODE" | grep -qF "$pat" \
        && ok "status.js 含 '${pat}'（档位在设备表上方）" \
        || bad "status.js 缺少 '${pat}'：设备表的刷新/测速档位不见了"
    if grep -qF "$pat" "$SET"; then
        bad "settings.js 仍有 '${pat}'：与设备页重复（同一档位两处默认值会漂移）"
    fi
done
# 四组档位收在 ☰ 菜单里（v0.6.4），不再是常驻平铺条。
# v0.6.6 起类名改为通用构件（.tc-menu / .tc-menu-panel），☰ 与「可见列」
# 共用同一套 —— 断言随之更新，否则会去查已不存在的旧类名而永远失败。
grep -q 'tc-menu-panel' "$S" \
    && ok "档位收在 ☰ 菜单里（tc-menu-panel）" \
    || bad "缺少 tc-menu-panel：档位未收进菜单"
if grep -qE "var panel = E\('div', \{'class':'tc-menu-panel tc-hidden'\}\)" "$S"; then
    ok "弹出面板默认收起（冷启动不占版面）"
else
    bad "弹出面板未默认收起：菜单的意义就是默认不占版面"
fi
# 四个 picker 必须都挂进 ☰ 面板，漏一个就是「档位不见了」。
# 面板内容以 speedMenuPanel.appendChild 追加，故取该追加块为范围。
for _pk in pollIntervalPick avgWindowPick avgMethodPick refreshPick; do
    if awk '/speedMenuPanel\.appendChild/,/\]\)\);/' "$S" | grep -q "$_pk"; then
        ok "档位面板含 $_pk"
    else
        bad "档位面板缺少 $_pk：该档位在界面上消失了"
    fi
done
# 原来的平铺条若被留着，会同时出现「一条平铺档位 + 一个 ☰」。
if grep -q 'tc-table-speed-bar' "$S"; then
    bad "仍有 tc-table-speed-bar 平铺条：与 ☰ 菜单重复"
else
    ok "无遗留的平铺档位条"
fi
# 冷启动默认轮询必须三处一致：前端 siteDefaults、UCI config、rpcd 兜底。
# 三处任一不同，就会出现「界面上显示 1s、实际路由器下发 2s」这类漂移。
grep -qE 'siteDefaults = \{ pollInterval: 1,' "$COMMON" \
    && ok "前端冷启动 pollInterval=1" \
    || bad "common.js 的 siteDefaults.pollInterval 不是 1"
_CFG="$PKG/root/etc/config/trafficctl"
[ -f "$_CFG" ] && grep -qE "^	option poll_interval '1'$" "$_CFG" \
    && ok "UCI 冷启动 poll_interval=1" \
    || bad "root/etc/config/trafficctl 的 poll_interval 不是 1"
_RPCD="$PKG/root/usr/libexec/rpcd/luci.trafficctl"
[ -f "$_RPCD" ] && grep -q '"${poll:-1}"' "$_RPCD" \
    && ok "rpcd 兜底 poll 默认 1" \
    || bad "rpcd 的 \${poll:-N} 兜底不是 1：config 缺失时会下发旧值"
# 1 秒档位下必须防重入（否则请求层层堆积、rpcd 不断 fork）。
# 三个闸门变量都要在，且必须用「赋值 = false」解锁（只 .then 不解锁
# 会在一次错误后永久停摆）。
for _g in pollBytesInFlight pollDropsInFlight pollShapeInFlight; do
    if grep -q "var $_g = false" "$S" && grep -q "$_g = false;" "$S"; then
        ok "字节轮询有防重入闸（$_g）"
    else
        bad "缺少防重入闸 $_g：1 秒档位下请求会叠加"
    fi
done
# 速率条必须排在设备表容器**之前**（用户要求「设备列表的上方」）。
# 注意判据是 render 树里的顺序，不是变量定义行号 —— connsDiv 的 var 声明
# 在文件上方（1885），而它被放进返回树的位置才决定渲染次序。
_SPEEDBAR_LINE="$(grep -n '^\s*tableSpeedBar,$' "$S" | head -1 | cut -d: -f1)"
_CONNS_LINE="$(grep -n '^\s*connsDiv,$' "$S" | head -1 | cut -d: -f1)"
if [ -n "$_SPEEDBAR_LINE" ] && [ -n "$_CONNS_LINE" ] && [ "$_SPEEDBAR_LINE" -lt "$_CONNS_LINE" ]; then
    ok "速率条排在设备表之前（render 树顺序正确）"
else
    bad "速率条未排在设备表之前（speedbar=$_SPEEDBAR_LINE conns=$_CONNS_LINE）"
fi
# 设备选择与「目标」必须同处一行（v0.6.2 布局要求）。
grep -q 'tc-picker-row' "$S" \
    && ok "设备选择已并入速率限制面板（tc-picker-row）" \
    || bad "缺少 tc-picker-row：搜索框未与目标同行"
grep -q 'scopeSlot' "$S" \
    && ok "目标行与设备选择同排（scopeSlot）" \
    || bad "缺少 scopeSlot：目标未与搜索框同排"
# 「视图与表格」必须并入速率限制面板，而不是独立卡片。
grep -q 'tc-rate-panel__tail' "$S" \
    && ok "View & Table 并入速率限制面板（panelTail）" \
    || bad "缺少 tc-rate-panel__tail：View & Table 未并入速率面板"
if grep -qE "T\.mkCollapsible\('View & Table'" "$S"; then
    ok "View & Table 仍以可折叠卡片呈现"
fi

# ── 设备表两行式布局与列契约（v0.6.3）──────────────────────────────
# 参照爱快设备列表：IP/MAC、终端类型/厂商、操作各占一列、列内上下两行。
grep -q 'tc-cell-stack' "$S" \
    && ok "存在两行式单元格（tc-cell-stack）" \
    || bad "缺少 tc-cell-stack：IP/MAC 与 类型/厂商 未做成两行"
grep -q '_tydev' "$S" \
    && ok "存在「终端类型 / 厂商」列（_tydev）" \
    || bad "缺少 _tydev 列"
grep -q '_total_up\|_total_dn' "$S" \
    && ok "累计上行 / 累计下行已分列" \
    || bad "缺少累计上行/下行列"
# 操作列必须两行：两个子元素都是 <a>（inline），若不显式 display:block
# 就会并成一行「Details限制」—— 实测踩过。
grep -qE '^\.tc-actions a \{ display: block' "$CSS" \
    && ok "操作列两行式（.tc-actions a 为 block）" \
    || bad "操作列未设 display:block：两个 <a> 会并成一行"
# 表格必须 fixed 布局。auto 布局下 width 只是建议值，实测数字列被拉成
# 几百像素空槽、同时另一些列被压到内容宽以下而溢出 153px。
grep -qE 'table-layout: *fixed' "$CSS" \
    && ok "设备表用 table-layout:fixed（列宽才是硬约束）" \
    || bad "设备表未用 fixed 布局：列宽不可控，宽度与溢出都会漂移"
# 默认隐藏只能有一处声明（TC_COL_DEFAULT_HIDDEN）。两处必然漂移：
# 芯片显示已打开而表格不渲染该列。
if grep -q 'TC_COL_DEFAULT_HIDDEN' "$S" && grep -q 'function isColHidden' "$S"; then
    ok "默认隐藏列由 isColHidden + TC_COL_DEFAULT_HIDDEN 统一判定"
else
    bad "缺少 isColHidden/TC_COL_DEFAULT_HIDDEN：默认隐藏列会出现两份真相"
fi
# 列开关必须**显式写布尔值**，不能 delete —— delete 会回落到默认隐藏，
# 于是「打开」看起来毫无作用（勾是勾了、表格里却没有这一列）。实测踩过。
# v0.6.8 起是复选框，写的是 `self._hiddenCols[ct.key] = !cb.checked`
# （勾上 = !true = false = 不隐藏）。两个方向都写显式值。
if grep -qE 'self\._hiddenCols\[ct\.key\] = !cb\.checked' "$S"; then
    ok "列开关写显式布尔（不用 delete）"
elif grep -qE 'self\._hiddenCols\[ct\.key\] = (false|true)' "$S"; then
    ok "列开关写显式布尔（不用 delete）"
else
    bad "列开关用了 delete：默认隐藏的列将永远打不开"
fi
# colChipDefs 必须恰好等于 cols 里**默认隐藏**的那一批（v0.6.8 起）。
#   此前断言「两边键集完全相等」；改为复选框后，清单只含默认隐藏列 ——
#   默认显示的列（IP/MAC、连接数、四个速率列、类型厂商、名称、操作、
#   TCP、UDP、互联网、限制）不再列进来（它们本来就看得见）。
#   两侧都必须能抽出，否则说明抽取逻辑失效（曾因 grep 到另一处 `var cols = [`
#   而误判，故按行号区间抽取设备表那一处）。
_COLS_START=$(grep -n 'function buildSummaryTable' "$S" | head -1 | cut -d: -f1)
_COLS_KEYS=$(awk -v s="$_COLS_START" 'NR>s && /^\tvar cols = \[/{f=1} f{print} f && /^\t\];/{exit}' "$S" \
    | grep -oE "key:'[^']+'" | sed "s/key:'//;s/'//" | sort -u)
_CHIP_KEYS=$(awk '/^\t\tvar colChipDefs = \[/,/^\t\t\];/' "$S" \
    | grep -oE "key:'[^']+'" | sed "s/key:'//;s/'//" | sort -u)
# 默认隐藏键集，从 TC_COL_DEFAULT_HIDDEN 抽取。
_HIDDEN_KEYS=$(awk '/^var TC_COL_DEFAULT_HIDDEN = \{/,/\};/' "$S" \
    | grep -oE '[A-Za-z_][A-Za-z0-9_]*: *true' | sed 's/: *true//' | sort -u)
if [ -z "$_COLS_KEYS" ] || [ -z "$_CHIP_KEYS" ] || [ -z "$_HIDDEN_KEYS" ]; then
    bad "列键集抽取失败（cols/chip/默认隐藏 三者之一为空）"
elif [ "$_CHIP_KEYS" = "$_HIDDEN_KEYS" ]; then
    ok "可见列清单 == 默认隐藏列集（$(printf '%s\n' "$_CHIP_KEYS" | grep -c .) 项）"
else
    bad "可见列清单与默认隐藏列集不一致 —— 会出现「能开关但没有列」或「有列但开关缺失」"
    # 用临时文件代替进程替换（dash 不支持 `<(...)`，见文件头说明）。
    printf '%s\n' "$_HIDDEN_KEYS" > "$TMPD/hidden.keys"
    printf '%s\n' "$_CHIP_KEYS" > "$TMPD/chip.keys"
    diff "$TMPD/hidden.keys" "$TMPD/chip.keys" || true
fi
# 清单里的每个 key 都必须在 cols 里存在（否则开关点了没反应）。
_MISSING=""
for _k in $_CHIP_KEYS; do
    printf '%s\n' "$_COLS_KEYS" | grep -qx "$_k" || _MISSING="$_MISSING $_k"
done
if [ -z "$_MISSING" ]; then
    ok "可见列的每个开关都对应表里真实存在的列"
else
    bad "以下开关没有对应列：$_MISSING"
fi
# 默认显示的列**不得**出现在清单里（用户要求：默认已显示的不纳入可见列）。
_LEAK=""
# comm 需要两个已排序的**文件**；dash 没有进程替换，故先落盘。
printf '%s\n' "$_COLS_KEYS" > "$TMPD/cols.keys"
printf '%s\n' "$_HIDDEN_KEYS" > "$TMPD/hidden2.keys"
for _k in $(comm -23 "$TMPD/cols.keys" "$TMPD/hidden2.keys"); do
    printf '%s\n' "$_CHIP_KEYS" | grep -qx "$_k" && _LEAK="$_LEAK $_k"
done
if [ -z "$_LEAK" ]; then
    ok "默认显示的列未出现在可见列清单里"
else
    bad "默认显示的列被列进了可见列清单：$_LEAK"
fi
# v0.6.8：TCP / UDP / 互联网 / 限制 必须默认显示。
for _k in tcp udp blocked _throttle_kbit; do
    if printf '%s\n' "$_HIDDEN_KEYS" | grep -qx "$_k"; then
        bad "$_k 仍默认隐藏：应默认显示"
    else
        ok "$_k 默认显示"
    fi
done
# 分页（参照图底部「每页 N 条」）。
grep -q 'tc-pager' "$S" \
    && ok "设备表有分页条（tc-pager）" \
    || bad "缺少分页条"
if grep -q 'sortSummaryRows' "$S"; then
    ok "分页前先按当前排序列排序（否则第一页不是最快设备）"
else
    bad "缺少 sortSummaryRows：分页切片会与表内排序不一致"
fi
# 页面上不得出现字面 undefined（var 提升把未赋值变量当文本节点渲染过）。
# 只查真实代码行，跳过解释该坑的注释行。
if grep -vE '^\s*(//|\*)' "$S" | grep -qE "E\('[a-z]+',[^)]*,\s*\w+\)"; then
    : # 该模式太宽泛，不做断言；实际由浏览器实测保证
fi

# 按钮组与两个弹出菜单（v0.6.6）。
grep -q 'tc-menu-group' "$S" \
    && ok "存在按钮组（tc-menu-group）" \
    || bad "缺少 tc-menu-group：两个菜单未并成一组"
grep -q 'function mkPopupMenu' "$S" \
    && ok "弹出面板由工厂统一构造（mkPopupMenu）" \
    || bad "缺少 mkPopupMenu：两个菜单各写一份必然漂移"
# 按钮组顺序必须是「可见列 | ☰」。取 tc-menu-group 那一处的实参列表为范围
# （awk 从 `tc-menu-group` 所在行读到该语句的 `]);`）。
_GRP=$(awk "/class':'tc-menu-group'/,/\]\);/" "$S")
if printf '%s\n' "$_GRP" | grep -q 'visibleColsMenu.bar' && \
   printf '%s\n' "$_GRP" | grep -q 'speedMenu.bar'; then
    _VC=$(printf '%s\n' "$_GRP" | grep -n 'visibleColsMenu.bar' | head -1 | cut -d: -f1)
    _SM=$(printf '%s\n' "$_GRP" | grep -n 'speedMenu.bar' | head -1 | cut -d: -f1)
    if [ "$_VC" -lt "$_SM" ]; then
        ok "按钮组顺序为「可见列 | ☰」"
    else
        bad "按钮组顺序不是「可见列 | ☰」"
    fi
else
    bad "按钮组未同时含可见列与 ☰ 两个菜单"
fi
# 同一时刻只允许一个面板展开（两个浮层贴着同一按钮组，同时开会互相盖住）。
grep -q 'popupMenus.forEach(function(m) { if (m !== api) m.setOpen(false); })' "$S" \
    && ok "两个菜单互斥（开一个自动关另一个）" \
    || bad "两个菜单未互斥：会同时展开并互相遮挡"
# ── v0.6.9：三个开关移除、picker 行重排、限速改进弹层 ────────────────
# 「统计 / 连接 / 活动日志」三个开关必须已移除，三者恒开。
for _t in tm-stats tm-conns tm-activity; do
    if grep -q "mkToggle('$_t'" "$S"; then
        bad "开关 $_t 仍存在：用户要求移除（该区块应恒开）"
    else
        ok "$_t 开关已移除（恒开）"
    fi
done
# 恒开意味着容器不得再带初始 tc-hidden 门。
if grep -qE "var statsDiv  = E\('div', \{ 'class': opts\.showStats" "$S"; then
    bad "statsDiv 仍随 showStats 隐藏"
else
    ok "statsDiv / connsDiv / activityDiv 不再随选项隐藏"
fi
# 活动日志的内容必须在首屏主动加载（原先挂在开关回调里）。
if grep -q 'activityDiv._loaded = true;' "$S" && grep -q 'loadActivityPanel(activityDiv);' "$S"; then
    ok "活动日志内容在首屏主动加载"
else
    bad "活动日志内容无人加载：开关移除后这一段会永远空白"
fi
# picker 行顺序必须是「所有设备 | 搜索框」。
if grep -qE "E\('div', \{'class':'tc-picker-row__device'\}, \[allBtn, searchSelect\.el\]\)" "$S"; then
    ok "picker 行顺序为「所有设备 | 搜索框」"
else
    bad "picker 行顺序不对：所有设备应在搜索框左侧"
fi
# 最近设备 chip 行必须已移除。
if grep -q 'tc-recent-container' "$S"; then
    bad "最近设备 chip 容器仍在：用户要求移除"
else
    ok "最近设备 chip 行已移除"
fi
# 框 1/框 2 的组件必须已移除：目标/共享/网段 + 速率档位行。
if grep -q 'tc-scope-row' "$S"; then
    bad "目标/共享/网段行（tc-scope-row）仍在：用户要求移除"
else
    ok "目标/共享/网段行已移除"
fi
if grep -qE "rateLimitRow = E\('div', \{" "$S" && \
   awk "/var rateLimitRow = E\('div', \{/,/\]\);/" "$S" | grep -q 'rateChipsRow'; then
    bad "速率档位行仍在速率限制卡片里：应移入「限制」弹层"
else
    ok "速率档位行已移出卡片（不再常驻）"
fi
# 「限制」链接必须打开弹层（而不是只选中设备）。
if grep -q 'openLimitPopup' "$S" && grep -q 'tc-limit-popup' "$S"; then
    ok "设备表「限制」链接打开限速弹层（tc-limit-popup）"
else
    bad "「限制」未接弹层：限速入口缺失"
fi
# 限速应用的目标必须来自弹层（_limitIp），不得再读已删除的 scopeInput。
# 注意**剥掉注释行**再判 —— 解释「已删除哪些变量」的注释里必然还写着这
# 些名字，直接 grep 会永久误报（本仓库验证纪律第 6 条）。
if grep -q '_limitIp' "$S" && \
   ! grep -vE '^[[:space:]]*(//|\*|/\*)' "$S" | grep -q 'scopeInput'; then
    ok "限速目标取自弹层（_limitIp），无 scopeInput 残留"
else
    bad "限速目标仍依赖已删除的 scopeInput"
fi
# 弹层挂在 body 上，必须随实例摘除 DOM 与两个 document 监听器。
if grep -q '_limitPopupDocClick' "$S" && grep -q '_limitPopupDocKey' "$S" && \
   awk '/handleTeardown: function/,/^\t\}$/' "$S" | grep -q '_limitPopup'; then
    ok "「限制」弹层的监听器与 DOM 随 handleTeardown 摘除"
else
    bad "「限制」弹层未随 teardown 摘除：切页后会留着监听器与游离 DOM"
fi
# 弹层定位必须先量真实高度（写死估值会把它放到视口外，实测踩过）。
if awk '/limitPopup.classList.remove\(.tc-hidden.\);/,/limitPopup.style.top/' "$S" | grep -q 'offsetHeight'; then
    ok "弹层显示后才量高度并据此定位（避免落到视口外）"
else
    bad "弹层定位用固定估值：小视口下会落到屏幕外"
fi
# 已有的网段限制列表必须保留 —— 它是既有全局限速唯一可删的地方。
if grep -q 'renderSubnetLimits' "$S" && grep -q 'tc-subnet-limits' "$S"; then
    ok "已有的网段限制列表保留（旧的全局限速仍可删）"
else
    bad "网段限制列表被删：此前设过的全局限速将无法移除"
fi

# 视图开关必须**直接展示**，不再裹在可折叠卡片里。
grep -q 'tc-view-toggles' "$S" \
    && ok "视图开关行直接展示（tc-view-toggles）" \
    || bad "缺少 tc-view-toggles：开关又藏回折叠卡片了"
if grep -q "mkCollapsible(_('View & Table')" "$S"; then
    bad "「视图与表格」可折叠卡片又回来了：开关会被藏起来"
else
    ok "已无可折叠的「视图与表格」卡片"
fi
# 「可见列」按钮必须同时承载设备列、连接表列与连接表筛选 —— 漏一个就是
# 那部分开关再也点不到。
for _part in colChipsContainer connColChipsContainer connFiltersRow; do
    if awk '/var visibleColsMenu = mkPopupMenu/,/^$/' "$S" | grep -q "$_part"; then
        ok "可见列面板含 $_part"
    else
        bad "可见列面板缺少 $_part：对应的开关将无处可点"
    fi
done
# 列宽必须按**每列最小预算**算，否则列一多就被摊薄到不可读
# （实测 20 列时图表/限制/丢弃/队列被压到 11px、MAC 折三行）。
grep -q 'COL_MIN_PX' "$S" \
    && ok "列宽按每列最小预算计算（COL_MIN_PX）" \
    || bad "缺少 COL_MIN_PX：多列开启时会被摊薄到不可读"
if grep -qE 'tblEl\.style\.minWidth' "$S"; then
    ok "表格按列预算抬高 min-width（超宽时横向滚动而非硬挤）"
else
    bad "未按列预算设置 min-width：多列时列宽会被压到 11px"
fi
# CSS 里不得再残留按类名写死的列宽百分比 —— JS 已用内联样式接管，
# 两处共存必然矛盾（内联赢，CSS 成为无人察觉的死规则）。
if grep -qE 'tc-table \.th\[data-col="[^"]+"\][^}]*\{[^}]*width: *[0-9.]+%' "$CSS"; then
    bad "CSS 里仍有写死的列宽百分比：与 JS 的列预算矛盾"
else
    ok "列宽只有一处定义（JS 列预算）"
fi

# ── v0.6.7：卡片合并、全宽图表、例行轮询静默、按钮行距 ──────────────
# 统计条与上联概览必须在**同一张卡片**里（此前是两块独立的内容）。
grep -q "var overviewCard = E('div', { 'class': 'tc-overview tc-hidden' }, \[statsDiv, overviewDiv\])" "$S" \
    && ok "统计条与上联概览合进同一张卡片" \
    || bad "统计条与概览未合并：又变回两块独立内容"
# 定义顺序：statsDiv 必须先于 overviewCard 定义，否则 var 提升拿到 undefined
# → E(...) 的 children 里混入 undefined → 整页空白（本仓库踩过两次）。
_ORDER_STATS=$(grep -n 'var statsDiv' "$S" | head -1 | cut -d: -f1)
_ORDER_CARD=$(grep -n 'var overviewCard = ' "$S" | head -1 | cut -d: -f1)
if [ -n "$_ORDER_STATS" ] && [ -n "$_ORDER_CARD" ] && [ "$_ORDER_STATS" -lt "$_ORDER_CARD" ]; then
    ok "statsDiv 先于 overviewCard 定义（避开 var 提升）"
else
    bad "statsDiv 定义在 overviewCard 之后：var 提升会让 children 混入 undefined"
fi
# 两个开关独立：卡片只在**至少一个子块有内容**时显示，否则会留空边框。
grep -q 'function updateOverviewCard' "$S" \
    && ok "卡片可见性由子块内容决定（updateOverviewCard）" \
    || bad "缺少 updateOverviewCard：关掉两个开关会留下一个空边框"
if grep -A4 'function updateOverviewCard' "$S" | grep -q 'firstChild'; then
    ok "卡片可见性判据含 firstChild（首帧空内容不画边框）"
else
    bad "卡片可见性只看 tc-hidden：首帧会画出空边框"
fi
# 上联图必须按容器实宽绘制（写死宽度会只占左半）。
grep -q 'graphWidth' "$S" \
    && ok "上联图按容器实宽绘制（graphWidth）" \
    || bad "上联图宽度写死：不能全宽显示"
grep -q "window.addEventListener('resize', self._onResize)" "$S" \
    && ok "窗口尺寸变化时按新宽度重绘" \
    || bad "未监听 resize：拉宽窗口后图表停在旧宽度"
if grep -q '_onResize.*removeEventListener\|removeEventListener..resize' "$S"; then
    ok "resize 监听器随实例摘除"
else
    bad "resize 监听器未摘除：离开页面后仍在收事件"
fi
# 例行轮询不得再往状态行写「扫描中 / 运行中」（1 秒档位下会一直闪）。
if grep -q "setStatus(statusDiv, 'loading', _('Scanning all devices" "$S"; then
    bad "例行轮询仍在写「扫描所有设备中…」：1 秒档位下会一直闪"
else
    ok "例行轮询不再写「扫描所有设备中…」"
fi
if grep -q "setStatus(statusDiv, 'loading', _('Running" "$S"; then
    bad "例行轮询仍在写「运行中…」：1 秒档位下会一直闪"
else
    ok "例行轮询不再写「运行中…」"
fi
# 例行成功轮询不得直接 setStatus（会覆盖动作消息），必须走 setRoutineStatus。
if grep -q "setStatus(statusDiv, 'ok', '✓ ' + _('Done'))" "$S"; then
    bad "例行成功轮询仍直接 setStatus：会覆盖限速/切断等动作消息"
else
    ok "例行成功轮询走 setRoutineStatus（不覆盖动作消息）"
fi
# 动作类反馈必须仍走 setStatus —— 全改掉会让「切断成功」也没有提示。
if grep -q "setStatus(statusDiv, 'loading', _('Removing limit on')" "$S"; then
    ok "动作类反馈仍用 setStatus（限速/切断/WiFi 的提示保留）"
else
    bad "动作类反馈被误改成静默：用户看不到操作结果"
fi
# 按钮组与表格之间要有行距（实测曾为 0，按钮贴着表头）。
if grep -A12 '^\.tc-menu-group {' "$CSS" | grep -q 'margin: 8px 0 12px'; then
    ok "按钮组与表格之间有行距（下方 12px）"
else
    bad "按钮组下边距为 0：按钮贴住表头"
fi

# ── v0.6.8：可见列复选框、概览常显并前置 ────────────────────────────
# 可见列必须是**复选框**，且一行一个（标签包裹 input）。
grep -q "var colChipsContainer = E('div', {'class':'tc-col-checks'})" "$S" \
    && ok "可见列用复选框容器（tc-col-checks）" \
    || bad "可见列未改为复选框"
if grep -q "tc-col-check__box" "$S" && grep -q "'type': 'checkbox'" "$S"; then
    ok "可见列每项是 checkbox"
else
    bad "可见列不是复选框：又改回 chip 了"
fi
# 复选框必须写显式布尔，不能用 delete（delete 会回落默认隐藏 → 勾选无效）。
if awk '/var colChipsContainer = /,/^\t\t\}\);/' "$S" | grep -q 'delete self._hiddenCols'; then
    bad "可见列用了 delete：勾选会回落默认隐藏，看起来没反应"
else
    ok "可见列不用 delete（勾选状态持久有效）"
fi
# CSS 必须有一行一个的排版（flex column），不能是 inline chip。
if grep -A6 '^\.tc-col-checks {' "$CSS" | grep -q 'flex-direction: column'; then
    ok "复选框容器竖排（一行一个）"
else
    bad "复选框容器未竖排：会横向挤成一片"
fi
# 概览开关必须已移除，且概览常显。
if grep -q "mkToggle('tm-overview'" "$S"; then
    bad "「概览」开关仍存在：用户要求移除"
else
    ok "「概览」开关已移除"
fi
if grep -q 'overviewCheck' "$S"; then
    bad "overviewCheck 仍有残留引用"
else
    ok "无 overviewCheck 残留引用"
fi
# 常显 → 三处判据都不得再依赖 showOverview。
if grep -n 'showOverview' "$S" | grep -vE '^\s*[0-9]+:\s*//' | grep -q 'showOverview'; then
    bad "仍有代码依赖 showOverview（应只看 isAllMode）"
else
    ok "概览判据只看 isAllMode（常显）"
fi
# 概览卡片必须在速率限制**之前**渲染。
# 注意：grep 模式里的 `\t` 在单引号内只是**字面反斜杠 t**，不是制表符 ——
# 必须用 awk 的 tab 变量或实际制表符。这里用 awk 取行号。
_OV_POS=$(awk '/^[ \t]*overviewCard,[ \t]*$/{print NR; exit}' "$S")
_RL_POS=$(awk '/^[ \t]*rateLimitRow,[ \t]*$/{print NR; exit}' "$S")
if [ -n "$_OV_POS" ] && [ -n "$_RL_POS" ] && [ "$_OV_POS" -lt "$_RL_POS" ]; then
    ok "概览卡片渲染在速率限制之前"
else
    bad "概览卡片未前置（概览=$_OV_POS 速率限制=$_RL_POS）"
fi

# 表头与单元格居中（v0.6.5）。三处真正的表格都要加 --center；
# 扩展统计面板（「标签 — 数值」两栏行）**不得**加，加了就读不成列表。
# 只数**真实代码行**（含 `class':` 的行）—— 直接 grep 类名会把解释该类的
# 注释行也算进去（实测数出 4 处，实际只有 3 处）。
_CENTERED=$(grep -cE "class':\s*'table tc-table[^']*tc-table--center" "$S")
if [ "$_CENTERED" -eq 3 ]; then
    ok "设备表/连接表/分组表均居中（$_CENTERED 处）"
else
    bad "带 tc-table--center 的表格是 $_CENTERED 处（应为 3）：漏加或误加"
fi
if grep -qE "class': 'table tc-table--center' \}, rows\)" "$S"; then
    bad "扩展统计面板被误加居中：它是「标签—数值」两栏行，居中就读不成列表"
else
    ok "扩展统计面板未被居中（保持左对齐的键值行）"
fi
grep -q 'tc-table--center .th' "$CSS" && grep -q 'tc-table--center .td' "$CSS" \
    && ok "居中规则限定在 .tc-table--center 作用域内" \
    || bad "居中规则缺失或未限定作用域（会波及表格外）"
# 两行式单元格的子项对齐由容器 align-items 决定，光给 .td 设 text-align 管不到。
grep -q 'tc-table--center .td.tc-cell-stack' "$CSS" \
    && ok "两行式单元格的子项也对齐（align-items）" \
    || bad "两行式单元格的子项未对齐：IP/MAC 与 类型/厂商 会左贴"

# 选择器不得退回带 td 前缀的写法（元素是 div.td，永不匹配）
# （telegram.js 已于 v0.7.0 移除，故这里只查 status.js）
if grep -qE "querySelector(All)?\('td\[data-|closest\('td\[data-" "$S"; then
    bad "$S 出现 td[data-…] 前缀选择器（元素是 div.td，永不匹配）"
    grep -nE "querySelector(All)?\('td\[data-|closest\('td\[data-" "$S"
fi
ok "无 td[data-…] 前缀选择器"

# ─────────────────────────────────────────────────────────────
note ""
note "=== 4b. LUCI_DEPENDS 不得含本目标不可满足的包 ==="
# hostapd-utils 在 lede 里声明为 DEPENDS:=@<某个 hostapd/wpad 变体> + VARIANT:=*，
# 即**只有选中 hostapd/wpad 变体时该符号才存在**。本目标是 x86_64 无 WiFi 硬件
# （实测路由器上无 /sys/class/ieee80211、无 hostapd/wpad 二进制），故永远不可满足。
# 危害不止「少装一个可选件」：kconfig 会把 luci-app-trafficctl **整包**判为不可选，
# 连带 LuciTranslation 生成的 luci-i18n-trafficctl-zh-cn（DEPENDS:=$(PKG_NAME)）
# 一起从 .config 消失。症状隐蔽 —— 构建不报错、界面变英文、只有 i18n 断言会挂。
# v0.4.7/v0.4.8 两次构建均由此失败。
MK="$PKG/Makefile"
if grep -qE '^LUCI_DEPENDS:.*hostapd-utils' "$MK"; then
    bad "Makefile 的 LUCI_DEPENDS 含 hostapd-utils（x86_64 不可满足，会让整包消失）"
    grep -nE '^LUCI_DEPENDS:' "$MK"
else
    ok "LUCI_DEPENDS 未含 hostapd-utils"
fi
# 反向确认：剩余依赖行必须存在且非空
if grep -qE '^LUCI_DEPENDS:=\+' "$MK"; then
    ok "LUCI_DEPENDS 形如 ':=+…'（$(sed -n 's/^LUCI_DEPENDS:=//p' "$MK")）"
else
    bad "LUCI_DEPENDS 缺失或格式异常"
    grep -nE '^LUCI_DEPENDS' "$MK" || echo "       (没有 LUCI_DEPENDS 行)"
fi

# ─────────────────────────────────────────────────────────────
note ""
note "=== 5. 文件模式与上游一致（29 × 100755 + 11 × 100644）==="
# patch 里记录的是索引模式；若副本模式漂移，重放时会打印
#   warning: xxx has type 100755, expected 100644
n755=$(git ls-files -s "$PKG" | awk '$1=="100755"' | wc -l | tr -d ' ')
n644=$(git ls-files -s "$PKG" | awk '$1=="100644"' | wc -l | tr -d ' ')
note "    100755 = $n755，100644 = $n644"
[ "$n755" = "26" ] \
    && ok "100755 数量正确（26）" \
    || bad "100755 数量为 $n755，应为 26（同步上游时执行位丢了）"
# 这几个文件必须**不可**执行
for f in htdocs/luci-static/resources/view/trafficctl/status.js \
         htdocs/luci-static/resources/view/trafficctl/status.css \
         Makefile \
         root/etc/config/trafficctl \
         root/usr/share/luci/menu.d/luci-app-trafficctl.json; do
    m=$(git ls-files -s "$PKG/$f" | awk '{print $1}')
    [ "$m" = "100644" ] \
        && ok "$f = 100644" \
        || bad "$f 模式为 ${m:-未跟踪}，应为 100644"
done

# ─────────────────────────────────────────────────────────────
note ""
note "=== 6. patch 里不得含伪 mode 变更 ==="
n=$(grep -h '^old mode\|^new mode' "$PATCHDIR"/*.patch 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = "0" ] \
    && ok "无 old/new mode 行" \
    || bad "有 $n 行 mode 变更（Windows 挂载点权限漂移所致，重跑 regen 工具）"

# ─────────────────────────────────────────────────────────────
note ""
note "=== 7. patch 可在上游基线上重放，并复现 vendored 包 ==="
UP_TAG="$(cat "$PATCHDIR/UPSTREAM" 2>/dev/null || true)"
if [ -z "$UP_TAG" ]; then
    bad "缺少 $PATCHDIR/UPSTREAM（记录基线 tag）"
else
    note "    基线 tag: $UP_TAG"
    PATCHES_ABS="$(cd "$PATCHDIR" && pwd)"
    UPTMP="$(mktemp -d)"
    CLONE_OK=0
    if [ -n "${TCTL_UPSTREAM_LOCAL:-}" ] && [ -d "$TCTL_UPSTREAM_LOCAL" ]; then
        # 本地已有一份上游 clone（离线/自测用），避免联网
        mkdir -p "$UPTMP/up/luci-app-trafficctl"
        cp -r "$TCTL_UPSTREAM_LOCAL"/* "$UPTMP/up/luci-app-trafficctl/" 2>/dev/null
        note "    使用本地基线：$TCTL_UPSTREAM_LOCAL"
        CLONE_OK=1
    elif git clone --depth 1 --branch "$UP_TAG" \
           https://github.com/YusDyr/luci-app-trafficctl.git "$UPTMP/up" 2>&1 | tail -2; then
        CLONE_OK=1
    fi

    if [ "$CLONE_OK" = "1" ]; then
        REPLAY="$UPTMP/replay"
        mkdir -p "$REPLAY"
        cp -r "$UPTMP/up/luci-app-trafficctl/." "$REPLAY/"
        # 统一 LF（上游 checkout 可能是 CRLF）
        find "$REPLAY" -type f -exec sed -i 's/\r$//' {} +
        # 按 vendored 包在 git 索引里的模式钉死权限：
        # 不这样做时 `git add -A` 会按文件系统现状记录模式（Windows /mnt 下
        # 一律 0777 → 记成 100755），与 patch 记录的模式不符 → 打印告警。
        _fixmodes() {
            [ -n "$PY" ] || { note "    (无可用 Python，跳过按索引修正文件模式)"; return 0; }
            $PY - "$1" "$PKG" <<'PYEOF'
import os, subprocess, sys
from pathlib import Path
repo, pkg = Path(sys.argv[1]), sys.argv[2]
r = subprocess.run(['git', 'ls-files', '-s', '--', pkg],
                   capture_output=True, text=True)
modes = {}
for line in r.stdout.splitlines():
    p = line.split(None, 3)
    if len(p) < 4:
        continue
    modes[p[3].split(pkg + '/', 1)[-1]] = p[0]
n = 0
for f in repo.rglob('*'):
    if not f.is_file():
        continue
    rel = str(f.relative_to(repo))
    want = modes.get(rel, '100644') == '100755'
    cur = os.stat(f).st_mode
    if bool(cur & 0o111) != want:
        os.chmod(f, (cur | 0o111) if want else (cur & ~0o111))
        n += 1
print(f'    已按索引修正 {n} 个文件权限')
PYEOF
        }
        _fixmodes "$REPLAY"
        ( cd "$REPLAY" && git init -q \
          && git -c core.autocrlf=false add -A \
          && git -c user.email=ci@local -c user.name=ci commit -qm base ) >/dev/null 2>&1
        applied=1
        for p in "$PATCHES_ABS"/*.patch; do
            [ -f "$p" ] || continue
            # 必须显式 core.autocrlf=false。git 会从**全局**配置继承
            # core.autocrlf=true（本机 Windows 默认即是），此时 `git apply`
            # 会把补丁内容落成 CRLF，于是重放结果与 LF 的 vendored 包
            # 逐字节不一致 —— 报出来的是一堆「文件 differ」，而差异只是行尾，
            # 极易被误判成「patch 内容错了」并往错误方向排查。
            # 本脚本的 git add 已经钉了该设置，apply 这里此前漏钉。
            if ( cd "$REPLAY" && git -c core.autocrlf=false apply --check -p1 "$p" 2>/dev/null ); then
                out="$( cd "$REPLAY" && git -c core.autocrlf=false apply -p1 "$p" 2>&1 )"
                if [ -n "$out" ]; then
                    bad "$(basename "$p") 套用有告警："
                    printf '%s\n' "$out" | sed 's/^/       /'
                else
                    ok "套用 $(basename "$p") 无告警"
                fi
            else
                bad "$(basename "$p") 无法套用到上游 $UP_TAG"
                ( cd "$REPLAY" && git -c core.autocrlf=false apply --check -p1 "$p" ) || true
                applied=0
            fi
        done
        if [ "$applied" = "1" ]; then
            # 与 vendored 包比对。排除：
            #   - .git（重放用的临时仓库）
            #   - LICENSE / README.md（来自上游**仓库根**，不在包目录内）
            if diff -rq -x .git -x LICENSE -x README.md "$REPLAY" "$PKG" 2>&1 | grep . ; then
                bad "patch 重放结果与 vendored 包不一致（见上方差异）"
                # 差异**全部**是行尾时，把它说清楚：这条路径 90% 会是
                # core.autocrlf 造成的假象，而不是 patch 内容错。先按行尾
                # 再比一次，命中即直接给出结论，省掉一轮误排查。
                if diff -rq -x .git -x LICENSE -x README.md "$REPLAY" "$PKG" 2>/dev/null \
                     | sed -n 's/^Files \(.*\) and \(.*\) differ$/\1/p' \
                     | while read -r f; do
                           rel="${f#"$REPLAY"/}"
                           # 去掉 CR 后再比 —— 用临时文件代替进程替换（dash 不支持）。
                           tr -d '\r' < "$f" > "$TMPD/cr_a"
                           tr -d '\r' < "$PKG/$rel" > "$TMPD/cr_b"
                           cmp -s "$TMPD/cr_a" "$TMPD/cr_b" || exit 1
                       done; then
                    note "        ^ 上述差异去掉 CR 后完全相同 → 仅为行尾差异（core.autocrlf）。"
                fi
            else
                ok "重放结果与 vendored 包逐字节一致"
            fi
        fi
    else
        bad "无法获取上游 $UP_TAG（检查 tag 是否存在或网络）"
    fi
    rm -rf "$UPTMP"
fi

# ─────────────────────────────────────────────────────────────
note ""
if [ "$fail" != "0" ]; then
    note "trafficctl 本地不变量校验失败 —— 见上方 FAIL 行"
    note "提示：若这是「同步上游」导致的，请重跑"
    note "      python3 tools/regen-trafficctl-patches.py <上游包目录>"
    note "      并确认本地改动已重新落地（见 AGENTS.md 红线 9）"
    exit 1
fi
note "trafficctl 本地不变量校验通过"
exit 0
