#!/bin/sh
# ============================================================
# lede-fingerprint.sh — 计算「工具链 / 宿主工具能否复用缓存」的指纹
# ------------------------------------------------------------
# 为什么不用 git commit 而用内容哈希：
#   lede master 每天都有提交（多在 feeds / target 的其它地方）。
#   若用 `git rev-parse HEAD` 做缓存键，几乎永不命中 —— 缓存等于没做。
#   而交叉工具链只由 `toolchain/`、`target/linux/generic/`（内核头文件）、
#   `include/{toolchain,host-build,download,unpack}.mk` 以及 `.config` 里
#   的编译器/libc/binutils 选项决定。宿主工具只由 `tools/` 与
#   `include/{host-build,download,unpack,depends}.mk` 决定。
#   对这些**内容**做哈希，才能「该命中时命中、该失效时失效」。
#
#   为什么不用 `git log -1 -- <path>`：CI 的 actions/checkout 默认
#   fetch-depth=1（浅克隆）。浅克隆上 `git log -1 -- toolchain` 在 HEAD
#   未触及该路径时**返回空**，于是「空指纹 == 空指纹」，任何版本都被
#   判成命中 —— 这正是「静默用旧工具链」的最坏形态。内容哈希没有这个
#   陷阱，且与克隆深度无关。
#
# 用法：
#   sh tools/lede-fingerprint.sh <lede-dir>
#
# 输出（KEY=VALUE，供调用方 grep/sed 取值，**不要** source）：
#   LEDE_COMMIT=<sha 或 unknown>     仅用于人读的溯源，不参与命中判定
#   TOOLCHAIN_FP=<64 位十六进制>
#   HOST_FP=<64 位十六进制>
#
# 退出码：0 成功；非 0 失败（缺目录 / 缺 sha256sum）。
#
# 约束（AGENTS.md §6 第 11 条）：必须 POSIX sh（dash）兼容。
# ============================================================

set -eu

PROG=$(basename "$0")

die() {
	echo "!!! $PROG: $*" >&2
	exit 1
}

LEDE="${1:-}"
[ -n "$LEDE" ] || die "用法: $PROG <lede-dir>"
[ -d "$LEDE" ] || die "lede 目录不存在: $LEDE"
[ -d "$LEDE/toolchain" ] || die "$LEDE 不像 lede 源码树（缺 toolchain/）"
[ -d "$LEDE/tools" ] || die "$LEDE 不像 lede 源码树（缺 tools/）"
command -v sha256sum >/dev/null 2>&1 || die "缺 sha256sum（coreutils）"

# 内容指纹：把一组路径下所有普通文件「按路径排序 + 逐个 sha256sum」串起来再哈希。
#
# 几个刻意的选择：
#   - 先 cd 到 lede 根再用相对路径：否则绝对路径进哈希，workspace 一变
#     指纹就全变，缓存永不命中。
#   - 不用 `find -printf '%T@'`（mtime）：tar 解包会改变 mtime，
#     内容没变却让指纹漂移，缓存反复失效。
#   - 空集合也输出确定的哈希（sha256 of 空串），不输出空行 ——
#     空指纹会让「键相等」变成无意义的恒真。
fp_files() {
	(
		cd "$LEDE" || exit 1
		# $* 是相对路径列表（允许通配）；不存在的路径由 find 报错到
		# /dev/null 后跳过，不影响其它路径。
		# shellcheck disable=SC2086
		find $* -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
			sha256sum "$f"
		done
	) | sha256sum | cut -d' ' -f1
}

# .config 里与「编译器 / libc / binutils / 目标架构 / 宿主工具集」相关的行。
#
# 为什么不直接哈希整个 .config：加一个普通包（如 luci-app-xxx）就会
# 让工具链缓存失效 —— 那是纯浪费。这里只取真正影响工具链与宿主工具的
# 符号前缀，且 `sort` 后再哈希（.config 的行序会因 defconfig 变动）。
cfg_slice() {
	_CFG="$LEDE/.config"
	if [ ! -f "$_CFG" ]; then
		# .config 还不存在（首次预热时可能如此）：输出空串参与哈希，
		# 让「有无 .config」本身也成为一个确定的状态。
		echo "<no-config>"
		return 0
	fi
	grep -E '^CONFIG_(GCC|LIBC|BINUTILS|ARCH|CPU_TYPE|SOFT_FLOAT|USE_MUSL|USE_UCLIBC|EXTERNAL_TOOLCHAIN|TARGET_BOARD|TARGET_SUBTARGET|TARGET_ARCH_PACKAGES|TARGET_OPTIMIZATION|TARGET_SUFFIX|USE_MOLD|MOLD|BUILD_ALL_HOST_TOOLS|DWARVES|CCACHE|KERNEL_ARCH|SELINUX|SECCOMP)[=_ ]' \
		"$_CFG" 2>/dev/null | LC_ALL=C sort || echo "<no-toolchain-symbols>"
}

TOOLCHAIN_FP=$(
	{
		fp_files toolchain target/linux/generic include/toolchain.mk \
			include/host-build.mk include/download.mk include/unpack.mk
		cfg_slice
	} | sha256sum | cut -d' ' -f1
)

HOST_FP=$(
	{
		fp_files tools include/host-build.mk include/download.mk \
			include/unpack.mk include/depends.mk
		cfg_slice
	} | sha256sum | cut -d' ' -f1
)

if [ -d "$LEDE/.git" ]; then
	LEDE_COMMIT=$(git -C "$LEDE" rev-parse HEAD 2>/dev/null || echo unknown)
else
	LEDE_COMMIT=unknown
fi

echo "LEDE_COMMIT=$LEDE_COMMIT"
echo "TOOLCHAIN_FP=$TOOLCHAIN_FP"
echo "HOST_FP=$HOST_FP"
