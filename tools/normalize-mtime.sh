#!/bin/sh
# ============================================================
# normalize-mtime.sh — 把源码树的 mtime 归一到固定时刻
# ------------------------------------------------------------
# 为什么必须做这一步（否则工具链缓存等于没做）：
#
#   lede 判断「工具链要不要重编」用的是 scripts/timestamp.pl：
#       timestamp.pl -n <stamp> toolchain <另一个 stamp>
#   它的判据是「这些路径里最新的那个文件，是不是就是 stamp 自己」。
#   只要 `toolchain/` 下有任何一个文件比 stamp 新，就重编。
#
#   而 CI 每次都是**全新 git clone**：checkout 会把所有文件的 mtime
#   写成"现在"。于是刚解包出来的 stamp（mtime 是上一次构建时刻）
#   必然比源码旧 → 工具链被判定过期 → **完整重编**。
#   也就是说：不做 mtime 归一，缓存下来的工具链 100% 不会被复用，
#   而流程看起来一切正常（只是慢），这是最难发现的一类失效。
#
#   同理，host-build.mk 的 stamp 名字里含 find_md5：
#       find ... -printf "%p%T@\n" | sort | mkhash md5
#   %T@ 就是 mtime。mtime 每次都不一样 → 哈希每次都不同 → stamp 文件名
#   每次都不同 → 宿主工具也必然重编。
#
#   把源码 mtime 固定成同一个时刻之后：
#     - timestamp.pl 的「谁最新」判断变成确定的（stamp 比源码新 → 跳过）
#     - find_md5 在不同 run 之间一致（同一份内容 → 同一个 stamp 文件名）
#     - 顺带让构建更可重现
#
# ⚠️ 关键：**预热 job 与构建 job 必须用同一份归一规则**，否则两边的
#    find_md5 不同，缓存照样不命中。故两个工作流都调用本脚本。
#
# 哪些目录不动：
#   .git/         —— git 自己的索引依赖真实 mtime，改了会让 git status 变慢/变脏
#   dl/           —— 内容由哈希校验，mtime 无意义；且解包时间就是"下载时间"
#   build_dir/    —— 里面是 stamp 与中间产物，必须保留其真实 mtime
#   staging_dir/  —— 同上，工具链 stamp 就在这里
#   bin/ tmp/ logs/ —— 纯产物/临时
#   feeds/*/.git  —— feed 是 git 仓库，同 .git 理由
#
# 用法：
#   sh tools/normalize-mtime.sh <lede-dir> [epoch]
#   默认 epoch = 2000-01-01 00:00:00 UTC
#
# 退出码：0 成功；非 0 失败。
#
# 约束（AGENTS.md §6 第 11 条）：必须 POSIX sh（dash）兼容。
# ============================================================

set -eu

PROG=$(basename "$0")

die() {
	echo "!!! $PROG: $*" >&2
	exit 1
}

note() {
	echo ">>> $PROG: $*"
}

LEDE="${1:-}"
EPOCH="${2:-2000-01-01 00:00:00}"

[ -n "$LEDE" ] || die "用法: $PROG <lede-dir> [epoch]"
[ -d "$LEDE" ] || die "lede 目录不存在: $LEDE"
[ -d "$LEDE/toolchain" ] || die "$LEDE 不像 lede 源码树（缺 toolchain/）"

note "把 $LEDE 的源码 mtime 归一到 [$EPOCH]"

# 统计归一前的"最新源码时间"，用于日志可读性（不参与判定）
NEWEST_BEFORE=$(find "$LEDE/toolchain" -type f -printf '%TY-%Tm-%Td %TH:%TM:%TS\n' 2>/dev/null |
	LC_ALL=C sort | tail -1 || true)
note "归一前 toolchain/ 最新 mtime: ${NEWEST_BEFORE:-<空>}"

# 用 -prune 显式排除，不用 -not -path 逐个匹配（后者对深层 .git 很啰嗦）
# 注意：-prune 必须放在 -o 之前，且被剪枝的目录本身不会再被 touch
#
# 这里刻意对**所有类型**都设时间（-print0 + xargs touch），
# 而不是只 touch 普通文件：符号链接的时间也参与部分判断。
find "$LEDE" \
	\( -name '.git' -o -name 'dl' -o -name 'build_dir' -o -name 'staging_dir' \
	-o -name 'bin' -o -name 'tmp' -o -name 'logs' \) -prune \
	-o -print0 |
	xargs -0 -r touch -h -d "$EPOCH" --

NEWEST_AFTER=$(find "$LEDE/toolchain" -type f -printf '%TY-%Tm-%Td %TH:%TM:%TS\n' 2>/dev/null |
	LC_ALL=C sort | tail -1 || true)
note "归一后 toolchain/ 最新 mtime: ${NEWEST_AFTER:-<空>}"

# 自检：归一后 toolchain/ 里不应还有比 epoch 新的文件。
# 若有，说明排除规则漏了某个目录，工具链缓存会静默失效 —— 必须显式失败。
STRAY=$(find "$LEDE/toolchain" -type f -newermt "$EPOCH + 1 day" 2>/dev/null | head -5 || true)
if [ -n "$STRAY" ]; then
	echo "!!! 归一失败：toolchain/ 下仍有较新的文件（工具链缓存会静默失效）：" >&2
	printf '%s\n' "$STRAY" >&2
	exit 1
fi

echo "OK   mtime 归一完成（源码树已固定为 $EPOCH）"
