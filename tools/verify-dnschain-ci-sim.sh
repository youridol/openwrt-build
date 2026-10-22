#!/bin/sh
# ============================================================
# verify-dnschain-ci-sim.sh — 在本地复现 CI 的工作目录执行契约校验
# ------------------------------------------------------------
# 为什么需要这个脚本：
#   `Verify dnschain framework contracts` 步骤的 working-directory 是 `lede`，
#   而 `files/` 是 CI 在前置步骤用 `cp -r ../openwrt-build/files ./` 复制进去的。
#   直接在仓库根跑那段校验会**误报通过或误报失败**：
#     - 在仓库根跑：files/ 存在 → 检查通过，但没验证 lede/ 场景
#     - 在 lede/ 跑但没复制 files/ → 全部 FAIL，与真实 CI 不符
#   v0.9.0 首次构建就是因为「文档检查用了 docs/ 而不是 ../openwrt-build/docs/」
#   而失败，本地在仓库根跑完全看不出来。
#
# 用法：sh tools/verify-dnschain-ci-sim.sh
# 退出码：0 = CI 会通过；非 0 = CI 会失败
#
# 约束（AGENTS §6 第 11 条）：必须 POSIX sh（dash）兼容。
# ============================================================

set -e

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT INT TERM

echo "仓库根: $REPO_ROOT"

# 复现 CI 的目录结构：lede/ 与 openwrt-build/ 同级
mkdir -p "$TMPD/lede" "$TMPD/openwrt-build"
cp -a "$REPO_ROOT/." "$TMPD/openwrt-build/"

cd "$TMPD/lede"

# 复现 CI 的前置步骤：把 overlay 复制进 lede/files/
if [ -d ../openwrt-build/files ]; then
	cp -r ../openwrt-build/files ./
	echo "已复制 files/ 到 lede/"
else
	echo "FAIL: 仓库根没有 files/ 目录" >&2
	exit 1
fi

# 从 workflow 里抽出 dnschain 校验步骤的脚本体
WF="$TMPD/openwrt-build/.github/workflows/build-openwrt.yml"
[ -f "$WF" ] || { echo "FAIL: 找不到 $WF" >&2; exit 1; }

python3 - "$WF" > "$TMPD/check.sh" <<'PY'
import re, sys, io
# 显式 UTF-8 输出：workflow 的注释里有 ⚠️ 之类的字符，
# 在 Windows 上 Python 默认用 GBK 写 stdout，会直接
# UnicodeEncodeError 崩掉 —— 而 CI 是 Linux（默认 UTF-8）看不出这个问题。
# 本地复跑 CI 校验正是这个脚本的用途，所以必须在这里兜住。
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
src = open(sys.argv[1], encoding='utf-8').read()
m = re.search(
    r'- name: Verify dnschain framework contracts\n.*?run: \|\n(.*?)(?=\n      - name:|\Z)',
    src, re.S)
if not m:
    sys.exit("FAIL: workflow 里找不到 dnschain 校验步骤")
# YAML 块标量的缩进是 10 个空格
print('\n'.join(ln[10:] if ln.startswith(' ' * 10) else ln.lstrip()
                for ln in m.group(1).split('\n')))
PY

echo "工作目录: $(pwd)"
echo "----------------------------------------"
sh "$TMPD/check.sh"
rc=$?
echo "----------------------------------------"

# ── 同步跑一遍 v0.13.0 的域名分流与改道契约 ──────────────────
#
# 为什么不只靠上面那段：上面那段是从 workflow 里抽出来的
# `Verify dnschain framework contracts` 步骤，而域名/改道契约
# 在**另一个**步骤里（它调用 tools/verify-dnschain-domains.sh）。
# 本地要一次跑全，否则会出现「CI 模拟通过但真 CI 挂在下一步」。
if [ -f "$TMPD/openwrt-build/tools/verify-dnschain-domains.sh" ]; then
	echo "── 域名分流与改道契约（独立步骤）─────────────"
	# 该脚本用仓库根相对路径，故在 openwrt-build 副本里跑
	(
		cd "$TMPD/openwrt-build" || exit 1
		sh tools/verify-dnschain-domains.sh
	)
	rc2=$?
	echo "----------------------------------------"
	if [ "$rc2" -ne 0 ]; then
		echo "域名分流与改道契约校验失败（真实 CI 会失败）" >&2
		[ "$rc" -eq 0 ] && rc=$rc2
	fi
fi

if [ "$rc" -eq 0 ]; then
	echo "CI 模拟校验通过（真实 CI 应能通过）"
else
	echo "CI 模拟校验失败（真实 CI 会失败，见上方 FAIL 行）" >&2
fi
exit "$rc"