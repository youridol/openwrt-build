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
#   3. Telegram 提升为页面级独立 tab（telegram.js + menu.d）—— 丢掉它 → 变回
#      超长折叠小节，且 status.js 会出现内层 tab（两级 tab 让人分不清层级）。
#   4. `po/zh-cn` —— 丢掉它 → 中文界面变英文。
#
# 另外校验「从 UPSTREAM 记录的 tag 克隆上游 → 重放全部 patch → 结果与 vendored
# 包逐字节一致」，这是「日后能跟进上游」的核心保证。
#
# 退出码 0 = 全部通过；1 = 有失败项（CI 据此中止）。

set -u

PKG=package/luci-app-trafficctl
V="$PKG/htdocs/luci-static/resources/view/trafficctl"
S="$V/status.js"
T="$V/telegram.js"
B="$PKG/root/usr/local/bin/trafficctl-bytes-nft.sh"
PATCHDIR=patches/luci-app-trafficctl

fail=0
note() { printf '%s\n' "$*"; }
ok()   { printf 'OK   %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fail=1; }

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
if command -v python3 >/dev/null 2>&1; then
    if python3 tools/check-trafficctl-i18n.py >/tmp/.tc_i18n.log 2>&1; then
        tail -1 /tmp/.tc_i18n.log
        ok "中文翻译完整"
    else
        cat /tmp/.tc_i18n.log
        bad "中文翻译不完整"
    fi
    rm -f /tmp/.tc_i18n.log
else
    note "警告：无 python3，跳过翻译覆盖率检查"
fi

# ─────────────────────────────────────────────────────────────
note ""
note "=== 4. 刷新逻辑与 tab 结构（本地 UI 改动）==="
grep -q "optRefresh" "$S" \
    && ok "默认刷新逻辑 optRefresh 存在" \
    || bad "缺少 optRefresh：冷启动将不再自动刷新"
grep -q "{v:'1',l:'1s'}" "$S" \
    && ok "刷新档位含 1s" \
    || bad "刷新档位缺少 1s（要求最低 1 秒）"
grep -q "refresh_interval" "$PKG/root/usr/libexec/rpcd/luci.trafficctl" \
    && ok "rpcd 处理 refresh_interval" \
    || bad "rpcd 未处理 refresh_interval"
# Telegram 必须是**页面级** tab（telegram.js + menu.d），而不是 status.js 内层 tab
if grep -qE "tc-settings-tabs|tc-stab|selectSettingsTab" "$S"; then
    bad "status.js 仍有内层 tab（Telegram 应提升为页面级）"
    grep -nE "tc-settings-tabs|tc-stab|selectSettingsTab" "$S"
else
    ok "设置区无内层 tab"
fi
[ -f "$T" ] \
    && ok "telegram.js 存在（独立视图）" \
    || bad "缺少 telegram.js"
grep -q "function loadTelegramUI" "$T" 2>/dev/null \
    && ok "telegram.js 含 loadTelegramUI" \
    || bad "telegram.js 缺少 loadTelegramUI"
grep -q "telegram" "$PKG/root/usr/share/luci/menu.d/luci-app-trafficctl.json" \
    && ok "menu.d 已登记 telegram 页" \
    || bad "menu.d 未登记 telegram 页（页面级 tab 不会出现）"
# 选择器不得退回带 td 前缀的写法（元素是 div.td，永不匹配）
for f in "$S" "$T"; do
    if grep -qE "querySelector(All)?\('td\[data-|closest\('td\[data-" "$f"; then
        bad "$f 出现 td[data-…] 前缀选择器（元素是 div.td，永不匹配）"
        grep -nE "querySelector(All)?\('td\[data-|closest\('td\[data-" "$f"
    fi
done
ok "无 td[data-…] 前缀选择器"

# ─────────────────────────────────────────────────────────────
note ""
note "=== 5. 文件模式与上游一致（29 × 100755 + 11 × 100644）==="
# patch 里记录的是索引模式；若副本模式漂移，重放时会打印
#   warning: xxx has type 100755, expected 100644
n755=$(git ls-files -s "$PKG" | awk '$1=="100755"' | wc -l | tr -d ' ')
n644=$(git ls-files -s "$PKG" | awk '$1=="100644"' | wc -l | tr -d ' ')
note "    100755 = $n755，100644 = $n644"
[ "$n755" = "29" ] \
    && ok "100755 数量正确（29）" \
    || bad "100755 数量为 $n755，应为 29（同步上游时执行位丢了）"
# 这几个文件必须**不可**执行
for f in htdocs/luci-static/resources/view/trafficctl/status.js \
         htdocs/luci-static/resources/view/trafficctl/status.css \
         htdocs/luci-static/resources/view/trafficctl/telegram.js \
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
            python3 - "$1" "$PKG" <<'PYEOF'
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
            if ( cd "$REPLAY" && git apply --check -p1 "$p" 2>/dev/null ); then
                out="$( cd "$REPLAY" && git apply -p1 "$p" 2>&1 )"
                if [ -n "$out" ]; then
                    bad "$(basename "$p") 套用有告警："
                    printf '%s\n' "$out" | sed 's/^/       /'
                else
                    ok "套用 $(basename "$p") 无告警"
                fi
            else
                bad "$(basename "$p") 无法套用到上游 $UP_TAG"
                ( cd "$REPLAY" && git apply --check -p1 "$p" ) || true
                applied=0
            fi
        done
        if [ "$applied" = "1" ]; then
            # 与 vendored 包比对。排除：
            #   - .git（重放用的临时仓库）
            #   - LICENSE / README.md（来自上游**仓库根**，不在包目录内）
            if diff -rq -x .git -x LICENSE -x README.md "$REPLAY" "$PKG" 2>&1 | grep . ; then
                bad "patch 重放结果与 vendored 包不一致（见上方差异）"
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
