#!/bin/sh
# ============================================================
# verify-toolchain-reuse.sh — 判定「还原出来的工具链树」会不会被 lede 直接复用
# ------------------------------------------------------------
# 与 verify-toolchain-cache.sh 的分工（两者都必要，别合并）：
#
#   verify-toolchain-cache.sh 问的是「树**完整**吗」
#     —— 交叉 gcc 在不在、能不能真编一个程序、stamp 全不全。
#
#   本脚本问的是「lede 会不会**跳过**它」
#     —— timestamp.pl 的判据是「stamp 是不是这批路径里最新的」。
#
# 为什么必须分开问：缓存完整 ≠ 会被复用。两者都成立才安全；
# 只成立前者时，会出现本仓库最难查的一类失败（见下方实证）。
#
# ── 实证：run 41442544890 / job 125267693362（2026-11-02，失败）───────────
#
#   还原工具链缓存**成功**（197096 个文件，含已安装的 musl sysroot），
#   但 lede 仍判定要重编 binutils —— 于是出现：
#
#     · 宿主 gcc 编译 binutils 的 gas，命令行里带
#         -I .../staging_dir/toolchain-x86_64_gcc-13.3.0_musl/include
#       此时该目录**已被还原出来**（含 musl 的 sys/types.h → endian.h）；
#     · 于是 binutils 的目标文件混入 musl 头语义，而宿主 gcc 自身是
#       glibc + -D_FORTIFY_SOURCE=2（日志 12:46:37 / 12:47:38 两处
#       "checking whether to add -D_FORTIFY_SOURCE=2 ... yes"）；
#     · 链接 as-new 时 libiberty.a / libbfd.a 里的 __sprintf_chk、
#       __fprintf_chk、__snprintf_chk、__realpath_chk、__vsprintf_chk、
#       fopen64 / ftello64 / fseeko64 全部 undefined reference
#       → make[7]: *** [Makefile:1313: as-new] Error 1
#       → ERROR: toolchain/binutils failed to build.
#       → make: *** [toplevel.mk:231: toolchain/compile] Error 2
#
#   对照：全新克隆的 run（124364502482 / 125011369755）**不会**这样。
#   原因是编译顺序 —— 干净树里 toolchain/binutils 编译时
#   staging_dir/toolchain-*/include 还是**空**的（musl 在后面才安装）：
#       11-01 成功 run：binutils/compile 在日志 72771 行，
#                        musl/compile  在日志 92810 行 → 晚 20000 行。
#   所以「sysroot 已就绪 + 工具链仍需重编」是**唯一**危险组合，
#   也正是缓存还原带来而全新克隆不会有的组合。
#
# 判据（三条，全部基于 lede 自己的规则，不猜）：
#   A. 是否存在已安装的目标 sysroot
#        = staging_dir/toolchain-*/include/sys/types.h
#   B. 工具链是否**真的**会被跳过
#        = stamp/.toolchain_compile 存在，且 toolchain/ 下没有比它更新的文件
#        （与 build-openwrt.yml 的复核口径完全一致）
#   C. 重编时会不会踩到 A
#        = A 为真 且 B 为假 → 危险
#
# 用法：
#   sh tools/verify-toolchain-reuse.sh <lede-dir>
#
# 退出码（调用方必须穷举，不要用 `|| true` —— AGENTS.md 红线 3）：
#   0  = 会被复用，可安全跳过工具链编译
#   11 = 危险：sysroot 已就绪但工具链仍要重编。
#        调用方必须先删 staging_dir 与 build_dir/toolchain-* 再编译
#        （与 build-openwrt.yml 的「缓存不可用就回退完整编译」同策略）。
#        直接带着这棵树编译 → 宿主 binutils 混用 musl 头 + glibc fortify → 必挂。
#   12 = 无 sysroot（或树本来就空）：重编是**安全**的，等价于全新克隆的
#        编译顺序，不需要删任何东西。
#   2  = 用法 / 前置条件错误
#
# 约束（AGENTS.md §6 第 11 条）：必须 POSIX sh（dash）兼容。
#   CI 的 /bin/sh 是 dash；bash 专有语法会在解析期直接 exit 2。
# ============================================================

set -eu

PROG=$(basename "$0")
RC_REUSABLE=0
RC_POISONED=11
RC_NO_SYSROOT=12

LEDE="${1:-}"
if [ -z "$LEDE" ]; then
	echo "用法: $PROG <lede-dir>" >&2
	exit 2
fi
if [ ! -d "$LEDE" ]; then
	echo "!!! $PROG: lede 目录不存在: $LEDE" >&2
	exit 2
fi

echo "=== 判定工具链树能否被复用（$LEDE）==="

# ── A. 目标 sysroot 是否已就绪 ──────────────────────────────
#
# sys/types.h 是 musl 安装时一定会落地的头文件，也是日志里
# 「In file included from .../sys/types.h:70」那条污染链的入口。
# 用它而不是「目录存在」：空目录也会存在，而空目录是**安全**的。
TC=$(find "$LEDE/staging_dir" -maxdepth 1 -type d -name 'toolchain-*' 2>/dev/null | head -1)
SYSROOT=""
if [ -n "$TC" ] && [ -f "$TC/include/sys/types.h" ]; then
	SYSROOT="$TC/include/sys/types.h"
fi

if [ -n "$SYSROOT" ]; then
	echo "    YES 目标 sysroot 已就绪: $SYSROOT"
else
	echo "    NO  目标 sysroot 未安装（staging_dir/toolchain-*/include/sys/types.h 不存在）"
fi

# ── B. 工具链是否会被 lede 跳过 ─────────────────────────────
#
# 与 build-openwrt.yml 的复核口径一致：直接比 mtime，不调 timestamp.pl
# （后者只返回布尔值，排障时看不到是哪个文件导致重编）。
SKIP=0
REASON=""
if [ -z "$TC" ]; then
	SKIP=0
	REASON="没有 staging_dir/toolchain-* 目录"
else
	STAMP="$TC/stamp/.toolchain_compile"
	if [ ! -f "$STAMP" ]; then
		SKIP=0
		REASON="缺 stamp/.toolchain_compile"
	else
		STAMP_TS=$(stat -c %Y "$STAMP")
		NEWER=$(find "$LEDE/toolchain" -type f -newermt "@$STAMP_TS" 2>/dev/null | head -3)
		if [ -z "$NEWER" ]; then
			SKIP=1
		else
			SKIP=0
			REASON="toolchain/ 里有比 stamp 更新的文件"
			printf '          %s\n' $NEWER
		fi
	fi
fi

# ── C. 组合判定 ────────────────────────────────────────────
if [ -n "$SYSROOT" ] && [ "$SKIP" -eq 1 ]; then
	echo "    YES 工具链会被跳过（$TC/stamp/.toolchain_compile 最新）"
	echo "=== 结论：会复用缓存，可跳过工具链编译（exit $RC_REUSABLE）==="
	exit "$RC_REUSABLE"
fi

if [ -n "$SYSROOT" ]; then
	echo "    NO  工具链仍会被重编：$REASON" >&2
	echo "" >&2
	echo "!!! 危险组合：目标 sysroot 已就绪，但工具链仍要重编。" >&2
	echo "    在此状态下编译 toolchain/binutils，宿主 gas 会同时吃到" >&2
	echo "      -I $TC/include   （musl 头）" >&2
	echo "      宿主 gcc 自带的 glibc + -D_FORTIFY_SOURCE=2" >&2
	echo "    结果：as-new 链接时 __*_chk / fopen64 / ftello64 全部" >&2
	echo "    undefined reference → ERROR: toolchain/binutils failed to build." >&2
	echo "" >&2
	echo "    调用方必须删除 staging_dir 与 build_dir/toolchain-* 后重编" >&2
	echo "    （等价于全新克隆，那里 sysroot 在 binutils 编译时还是空的）。" >&2
	echo "=== 结论：危险，必须先回退为干净树（exit $RC_POISONED）===" >&2
	exit "$RC_POISONED"
fi

# 无 sysroot：重编安全（等价于全新克隆的编译顺序）
if [ "$SKIP" -eq 1 ]; then
	echo "    note 工具链 stamp 最新，但 sysroot 未安装 —— 树不完整，按重编处理"
fi
echo "    SAFE 无 sysroot，重编不会混用 musl 头与 glibc fortify"
echo "=== 结论：可原地重编，无需删除（exit $RC_NO_SYSROOT）==="
exit "$RC_NO_SYSROOT"
