#!/bin/sh
# ============================================================
# dir-mirror.sh — 把任意目录（或目录清单）打成可分片传输的镜像包，或反向还原
# ------------------------------------------------------------
# 用途：把 OpenWrt 构建的两类「下载/编译成本」搬到 GitHub 内部网络上复用
#
#   ① dl/         —— 上游源码包（含工具链源码）。全新克隆每次都要重下。
#                    实测 2026-10-21 run 39495602665 卡在 `make download`
#                    5h54m（nasm 从 www.nasm.us 以 556 B/s 下载），
#                    被 job 6h 上限取消。
#   ② staging_dir —— 编译好的交叉工具链（+ build_dir/toolchain-*）。
#                    每次重建约 30-45 分钟。
#
# 为什么用「分片 + Release 资产」而不是 actions/cache：
#   - actions/cache 单仓库上限 10GB，且「一周未被访问即淘汰」；
#     本项目的 dl/ 就有 GB 级，装不下、也扛不住淘汰。
#   - GitHub Release 资产**没有总量上限、没有下载带宽上限**，
#     单文件上限 2GB —— 故必须分片（默认 1900M，留出余量）。
#   - Release 资产由 GitHub 自家 CDN 提供；在 Actions 里用内置
#     GITHUB_TOKEN 下载，流量不出 GitHub，不受外部源限速。
#
# 用法：
#   sh tools/dir-mirror.sh pack   <name> <src-root> <out-dir> <part-size> [path ...]
#   sh tools/dir-mirror.sh unpack <name> <in-dir>   <dest-root> [meta]
#   sh tools/dir-mirror.sh count  <dir>
#   sh tools/dir-mirror.sh info   <meta>
#
#   pack   ：把 <src-root> 下的 [path ...]（缺省为整个目录 "."）打成
#            <name>.tar.<zst|gz>.part-NN，写到 <out-dir>，
#            并写 <name>.meta（含压缩器、分片数、文件数）。
#            path 参数允许通配（如 'build_dir/toolchain-*'），无匹配的跳过。
#   unpack ：读 <in-dir> 的 <name>.meta 与全部分片，解到 <dest-root>。
#            分片数与 meta 不符即失败（不猜、不续）。
#   count  ：统计目录里的普通文件数。
#   info   ：打印 meta 内容。
#
# 退出码：0 成功；非 0 失败。失败必须让调用方显式失败（AGENTS.md 红线 3）。
#
# 约束（AGENTS.md §6 第 11 条）：必须 POSIX sh（dash）兼容。
#   CI 的 /bin/sh 是 dash；bash 专有语法会在**解析期**直接报错，
#   脚本一行未执行即 exit 2。故本文件不用 [[ ]]、数组、进程替换。
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

usage() {
	cat >&2 <<EOF
用法:
  $PROG pack   <name> <src-root> <out-dir> <part-size> [path ...]
  $PROG unpack <name> <in-dir>   <dest-root> [meta]
  $PROG count  <dir>
  $PROG info   <meta>
EOF
	exit 2
}

count_files() {
	_dir="$1"
	[ -d "$_dir" ] || { echo 0; return 0; }
	find "$_dir" -type f 2>/dev/null | wc -l | tr -d ' '
}

pick_compress() {
	if command -v zstd >/dev/null 2>&1; then
		echo zstd
	elif command -v gzip >/dev/null 2>&1; then
		echo gzip
	else
		die "zstd 与 gzip 都不可用，无法压缩"
	fi
}

meta_get() {
	# meta_get <meta> <KEY> —— 只取第一处，不做 source（避免执行外部内容）
	[ -f "$1" ] || die "找不到 meta 文件: $1"
	sed -n "s/^$2=//p" "$1" | head -1
}

cmd_pack() {
	NAME="${1:-}"
	SRC="${2:-}"
	OUT="${3:-}"
	PART_SIZE="${4:-1900M}"
	shift 4 2>/dev/null || true
	[ -n "$NAME" ] && [ -n "$SRC" ] && [ -n "$OUT" ] || usage
	[ -d "$SRC" ] || die "源根目录不存在: $SRC"

	# 收集实际存在的路径；允许通配，也允许部分路径不存在。
	#
	# ⚠️ 通配必须在 **$SRC 目录内** 展开：调用方给的是相对 src-root 的
	#    模式（如 'staging_dir/toolchain-*'），若在当前工作目录展开，
	#    匹配结果取决于调用者所在目录 —— 在仓库根跑就永远匹配不到，
	#    表现为「指定的路径一个都不存在」。故用子 shell cd 进 $SRC。
	#    （实测踩过：第一版在仓库根展开，glob 全部落空。）
	#
	# ⚠️ 循环体末尾必须有 `|| true`（或等价写法）：
	#    本函数在 `set -eu` 下运行，而 `matches=$(...)` 的退出码
	#    就是**命令替换里最后一条命令**的退出码。原写法
	#       for m in $p; do [ -e "$m" ] && printf ...; done
	#    在「最后一个 glob 没匹配到」时 `[ -e ]` 返回 1 →
	#    整个赋值返回 1 → `set -e` 让**脚本静默退出**，
	#    连 die 都来不及打印。CI 里表现为「打包 host 时退出码 1、
	#    日志里没有任何错误信息」（run 40068902057 就是这样挂的）。
	#    这里用显式 `exit 0` 收尾，保证命令替换恒返回 0。
	PICKED=""
	if [ "$#" -eq 0 ]; then
		PICKED="."
	else
		for p in "$@"; do
			# shellcheck disable=SC2013
			# 故意不加引号：让 $p 里的 * 在 cd 后的目录里按 glob 展开
			matches=$(
				cd "$SRC" || exit 1
				for m in $p; do
					[ -e "$m" ] && printf '%s\n' "$m"
				done
				exit 0
			)
			if [ -n "$matches" ]; then
				PICKED="$PICKED $(printf '%s' "$matches" | tr '\n' ' ')"
			fi
		done
		# 去掉首尾多余空格
		PICKED=$(printf '%s' "$PICKED" | sed 's/^ *//; s/ *$//')
	fi
	[ -n "$PICKED" ] || die "指定的路径一个都不存在（src-root=$SRC, args=$*）"

	mkdir -p "$OUT"

	COMP=$(pick_compress)
	ARCHIVE="$OUT/$NAME.tar"
	case "$COMP" in
	zstd) ARCHIVE="$ARCHIVE.zst" ;;
	gzip) ARCHIVE="$ARCHIVE.gz" ;;
	esac

	note "打包 $SRC [$PICKED ] → $ARCHIVE（压缩器 $COMP）"

	# 用管道直出压缩文件，不落中间 tar（dl/ 与 tar 同时占盘会撑爆 runner）
	# shellcheck disable=SC2086
	case "$COMP" in
	zstd)
		tar -C "$SRC" -cf - $PICKED | zstd -T0 -3 -q -o "$ARCHIVE"
		;;
	gzip)
		tar -C "$SRC" -cf - $PICKED | gzip -9 > "$ARCHIVE"
		;;
	esac

	[ -s "$ARCHIVE" ] || die "压缩结果为空: $ARCHIVE"
	ARCH_BYTES=$(wc -c < "$ARCHIVE" | tr -d ' ')
	note "压缩完成: $ARCH_BYTES 字节"

	# 清掉上一轮分片（同 out 目录重复 pack 时避免新旧分片混在一起）
	rm -f "$OUT/$NAME.tar.zst".part-* "$OUT/$NAME.tar.gz".part-* 2>/dev/null || true

	note "按 $PART_SIZE 分片"
	# -d 数字后缀、-a 2 两位（part-00..part-99；>100 片会自动进位到 3 位）
	split -b "$PART_SIZE" -d -a 2 "$ARCHIVE" "$ARCHIVE.part-"

	PARTS=$(find "$OUT" -maxdepth 1 -name "$NAME.tar.*.part-*" -type f | wc -l | tr -d ' ')
	[ "$PARTS" -gt 0 ] || die "分片失败：没有产出任何 part 文件"

	# 文件数按实际打包的路径统计
	FILES=0
	for m in $PICKED; do
		if [ -d "$SRC/$m" ]; then
			n=$(count_files "$SRC/$m")
			FILES=$((FILES + n))
		elif [ -f "$SRC/$m" ]; then
			FILES=$((FILES + 1))
		fi
	done
	[ "$FILES" -gt 0 ] || die "待打包内容里没有任何普通文件，拒绝打包空镜像"

	{
		echo "FORMAT=1"
		echo "NAME=$NAME"
		echo "COMPRESS=$COMP"
		echo "PARTS=$PARTS"
		echo "FILES=$FILES"
		echo "ARCHIVE_BYTES=$ARCH_BYTES"
	} > "$OUT/$NAME.meta"

	# 压缩包本体不再需要（分片已包含全部内容）
	rm -f "$ARCHIVE"

	note "分片数=$PARTS 文件数=$FILES"
	ls -l "$OUT" | sed 's/^/    /'
	echo "OK   镜像打包完成: $NAME"
}

cmd_unpack() {
	NAME="${1:-}"
	IN="${2:-}"
	DEST="${3:-}"
	META="${4:-$IN/$NAME.meta}"
	[ -n "$NAME" ] && [ -n "$IN" ] && [ -n "$DEST" ] || usage
	[ -d "$IN" ] || die "输入目录不存在: $IN"

	COMP=$(meta_get "$META" COMPRESS)
	EXPECT_PARTS=$(meta_get "$META" PARTS)
	EXPECT_FILES=$(meta_get "$META" FILES)
	[ -n "$COMP" ] || die "meta 缺少 COMPRESS: $META"
	[ -n "$EXPECT_PARTS" ] || die "meta 缺少 PARTS: $META"

	# split -d 保证 part-00..part-NN 字典序即自然序
	PARTS=$(find "$IN" -maxdepth 1 -name "$NAME.tar.*.part-*" -type f | sort)
	[ -n "$PARTS" ] || die "输入目录里没有 $NAME 的分片: $IN"

	ACTUAL_PARTS=$(printf '%s\n' "$PARTS" | wc -l | tr -d ' ')
	if [ "$ACTUAL_PARTS" != "$EXPECT_PARTS" ]; then
		die "分片数不符：meta 写 $EXPECT_PARTS，实际 $ACTUAL_PARTS（镜像不完整，拒绝解包）"
	fi

	mkdir -p "$DEST"

	note "解包 $ACTUAL_PARTS 个分片 → $DEST（压缩器 $COMP）"
	# shellcheck disable=SC2086
	case "$COMP" in
	zstd)
		cat $PARTS | zstd -dc | tar -C "$DEST" -xf -
		;;
	gzip)
		cat $PARTS | gzip -dc | tar -C "$DEST" -xf -
		;;
	*)
		die "未知压缩器: $COMP"
		;;
	esac

	note "解包完成（meta 记录文件数 $EXPECT_FILES）"
	echo "OK   镜像解包完成: $NAME"
}

cmd_count() {
	DIR="${1:-}"
	[ -n "$DIR" ] || usage
	[ -d "$DIR" ] || die "目录不存在: $DIR"
	count_files "$DIR"
}

cmd_info() {
	META="${1:-}"
	[ -n "$META" ] || usage
	[ -f "$META" ] || die "找不到 meta 文件: $META"
	cat "$META"
}

case "${1:-}" in
pack) shift; cmd_pack "$@" ;;
unpack) shift; cmd_unpack "$@" ;;
count) shift; cmd_count "$@" ;;
info) shift; cmd_info "$@" ;;
-h | --help | help) usage ;;
*) usage ;;
esac
