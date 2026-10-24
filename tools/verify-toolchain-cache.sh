#!/bin/sh
# ============================================================
# verify-toolchain-cache.sh — 判断「还原出来的工具链缓存」能否直接复用
# ------------------------------------------------------------
# 为什么需要一个单独的校验脚本，而不是「解包完就往下走」：
#
#   工具链缓存是「解包一份别人的 staging_dir/build_dir」。
#   一旦这份缓存不完整（上传中途失败、分片被手工删掉一部分、
#   指纹撞车但内容其实不同），症状**不是构建失败**，而是：
#
#     · staging_dir 里缺几个 .so → 编译某个包时莫名其妙 undefined reference
#     · stamp 缺失 → timestamp.pl 判定要重编 → 静默回退到完整重编（慢但绿）
#     · 交叉 gcc 存在但 target libc 头文件缺 → 编译到一半才炸
#
#   这三种都很难从「构建输出」反推回「缓存坏了」。所以在信任缓存之前
#   先做一次确定性校验，把判断收敛到这里。
#
# 判据（全部满足才算命中）：
#   1. staging_dir/toolchain-* 目录存在
#   2. 里面有可执行的交叉 gcc，且 `--version` 能跑通
#   3. 交叉 gcc 能真的编译一个最小 C 程序（不是只有二进制存在）
#   4. 工具链 stamp `.gcc_final_installed` 存在
#   5. staging_dir/host/bin 里有 make / sed / tar 这类必备宿主工具
#
# 用法：
#   sh tools/verify-toolchain-cache.sh <lede-dir>
#
# 退出码：
#   0  = 缓存可用，可以跳过工具链编译
#   11 = 缓存不可用（调用方应回退到完整编译，并**不要**当作错误退出）
#
# 约束（AGENTS.md §6 第 11 条）：必须 POSIX sh（dash）兼容。
# ============================================================

set -eu

PROG=$(basename "$0")
RC_UNUSABLE=11

LEDE="${1:-}"
[ -n "$LEDE" ] || {
	echo "用法: $PROG <lede-dir>" >&2
	exit 2
}
[ -d "$LEDE" ] || {
	echo "!!! $PROG: lede 目录不存在: $LEDE" >&2
	exit 2
}

fail() {
	echo "    FAIL $*"
	exit "$RC_UNUSABLE"
}

ok() {
	echo "    OK   $*"
}

echo "=== 校验工具链缓存可用性（$LEDE）==="

# ── 1. 工具链目录 ────────────────────────────────────────────
TC=$(find "$LEDE/staging_dir" -maxdepth 1 -type d -name 'toolchain-*' 2>/dev/null | head -1)
[ -n "$TC" ] || fail "没有 staging_dir/toolchain-* 目录"
ok "工具链目录 $TC"

# ── 2. 交叉 gcc 可执行 ──────────────────────────────────────
CC=$(find "$TC/bin" -maxdepth 1 \( -type f -o -type l \) -name '*-openwrt-linux*-gcc' 2>/dev/null | head -1)
[ -n "$CC" ] || fail "$TC/bin 里没有交叉 gcc"
[ -x "$CC" ] || fail "交叉 gcc 没有执行位: $CC"
ok "交叉 gcc $CC"

# ── 3. gcc 能跑 ─────────────────────────────────────────────
#
# 这一步能抓到「二进制存在但依赖的 .so 缺失」——只检查文件存在是抓不到的。
# 例：缓存里 staging_dir/toolchain-*/lib/libisl.so 缺了，gcc --version 会
# 报 error while loading shared libraries，而 ls 看起来一切正常。
if ! VER=$("$CC" --version 2>&1 | head -1); then
	echo "    FAIL 交叉 gcc 无法执行（多半是缓存的 staging_dir 缺 .so）：" >&2
	"$CC" --version 2>&1 | head -5 >&2 || true
	exit "$RC_UNUSABLE"
fi
case "$VER" in
*GCC* | *gcc*) ok "gcc --version → $VER" ;;
*) fail "gcc --version 输出不含 GCC: $VER" ;;
esac

# ── 4. 真的能编译一个程序 ───────────────────────────────────
#
# 只跑 --version 不够：它不链接、不碰 target libc 头文件。
# 这里编一个最简 C 程序，能同时验证「编译器 + 链接器 + crt 对象 + libc」。
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT INT TERM
printf 'int main(void){return 0;}\n' > "$TMPD/t.c"
if ! "$CC" "$TMPD/t.c" -o "$TMPD/t" 2>"$TMPD/err"; then
	echo "    FAIL 交叉 gcc 无法编译最小程序：" >&2
	head -20 "$TMPD/err" >&2 || true
	exit "$RC_UNUSABLE"
fi
[ -s "$TMPD/t" ] || fail "编译产物为空"
ok "交叉 gcc 能编译并链接最小 C 程序"

# ── 5. 工具链 stamp ────────────────────────────────────────
#
# .gcc_final_installed 是 lede 的 toolchain 完成标记
# （toolchain/Makefile: $(TOOLCHAIN_DIR)/stamp/.gcc_final_installed）。
# 缺它 → timestamp.pl 判定 toolchain/compile 未完成 → 完整重编。
STAMP="$TC/stamp/.gcc_final_installed"
[ -f "$STAMP" ] || fail "缺工具链完成标记 $STAMP（会导致工具链被完整重编）"
ok "工具链 stamp 存在"

# ── 6. 宿主工具完成标记 ────────────────────────────────────
#
# ⚠️ 不要检查 staging_dir/host/bin 里有没有 make/sed/tar ——
#    lede **不**自建这三个（tools/Makefile 的 tools-y 列表里没有它们），
#    它们来自 runner 的系统环境。第一版校验写了这个，会永久误判缓存不可用。
#
#    正确的判据是 tools/ 编译的完成标记
#    （tools/Makefile: $(STAGING_DIR_HOST)/stamp/.tools_compile$(tools_enabled)），
#    名字带一串 y/n 后缀，故用通配匹配。
HOSTDIR="$LEDE/staging_dir/host"
[ -d "$HOSTDIR" ] || fail "缺 staging_dir/host（宿主工具没缓存上）"
TOOLS_STAMP=$(find "$HOSTDIR/stamp" -maxdepth 1 -name '.tools_compile*' 2>/dev/null | head -1)
[ -n "$TOOLS_STAMP" ] || fail "缺宿主工具完成标记 staging_dir/host/stamp/.tools_compile*（宿主工具会被完整重编）"
ok "宿主工具 stamp 存在（$(basename "$TOOLS_STAMP")）"

# staging_dir/host/bin 必须非空：它是后续所有编译步骤的 PATH 首段
N_HOSTBIN=$(find "$HOSTDIR/bin" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$N_HOSTBIN" -ge 10 ] || fail "staging_dir/host/bin 只有 $N_HOSTBIN 个文件（明显偏少，缓存不完整）"
ok "宿主工具 $N_HOSTBIN 个"
echo "=== 结论：工具链缓存可用，将跳过工具链编译 ==="
exit 0
