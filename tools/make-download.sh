#!/bin/sh
# ============================================================
# make-download.sh — 执行 lede 的 `make download`，并对「本地缓存
#                    与上游哈希不一致」做显式自愈
# ------------------------------------------------------------
# 为什么需要这个脚本（而不是在 YAML 里直接 make download）：
#
#   1) 哈希不一致会让 download.pl **直接 die**，而不是重新下载。
#      lede 的 scripts/download.pl 在文件已存在时：
#          if ($sum eq $file_hash) { cleanup(); exit 0; }
#          die "Hash of the local file $filename does not match ..."
#      也就是说，一旦 dl/ 里缓存了一份旧版本文件（上游换了 tarball
#      但文件名没变，例如 openssl/curl 的补丁版本重打包），
#      **每次构建都会在这里硬失败**，而且报错只在几千行日志里出现一次。
#      长期缓存 dl/ 之后这不是理论风险，是必然会发生的事件。
#
#      本脚本的处理：从日志里精确取出不匹配的文件名 → 删掉 → 重试。
#      每一次删除都打印文件名，不是静默忽略（AGENTS.md 红线 3 要求
#      「禁止静默失败」，这里做的是**显式失败 + 显式修复 + 重试**）。
#
#   2) 单个慢源会拖死整个 job。实测 2026-10-21 run 39495602665 在
#      `make download` 卡了 5h54m（nasm 从 www.nasm.us 以 556 B/s 下载），
#      直到 job 的 6h 上限被取消。故外层必须套 `timeout`。
#
# 用法：
#   sh tools/make-download.sh <lede-dir> [jobs] [timeout-sec] [max-attempts]
#   默认：jobs=2, timeout-sec=3000（50 分钟）, max-attempts=3
#
# 环境变量（由调用方决定，本脚本只透传）：
#   DOWNLOAD_MIRROR   download.pl 会把它排在镜像列表最前面
#   CURL_OPTIONS      download.pl 透传给 curl（--max-time / --retry）
#
# 退出码：0 成功；非 0 失败。失败信息包含可直接照做的排查提示。
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
JOBS="${2:-2}"
DL_TIMEOUT="${3:-3000}"
MAX_ATTEMPTS="${4:-3}"

[ -n "$LEDE" ] || die "用法: $PROG <lede-dir> [jobs] [timeout-sec] [max-attempts]"
[ -d "$LEDE" ] || die "lede 目录不存在: $LEDE"
[ -f "$LEDE/Makefile" ] || die "$LEDE 不像 lede 源码树（缺 Makefile）"
[ -f "$LEDE/.config" ] || die "$LEDE 缺 .config（make download 依赖它决定要下哪些包）"

# 日志与 dl 目录：dl 的位置由 CONFIG_DOWNLOAD_FOLDER 决定，缺省为 <topdir>/dl
DL_DIR="$LEDE/dl"
if grep -q '^CONFIG_DOWNLOAD_FOLDER=' "$LEDE/.config" 2>/dev/null; then
	CUSTOM_DL=$(sed -n 's/^CONFIG_DOWNLOAD_FOLDER="\(.*\)"$/\1/p' "$LEDE/.config" | head -1)
	if [ -n "$CUSTOM_DL" ]; then
		DL_DIR="$CUSTOM_DL"
		note "使用 .config 指定的下载目录: $DL_DIR"
	fi
fi
mkdir -p "$DL_DIR"

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT INT TERM

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
	note "第 $attempt/$MAX_ATTEMPTS 轮：make download -j$JOBS（硬超时 ${DL_TIMEOUT}s）"
	note "dl 目录: $DL_DIR"
	note "已有文件数: $(find "$DL_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')"

	# 关键：不用管道（dash 的管道退出码取最后一段），先落文件再回显。
	# `timeout` 的退出码 124 = 超时，需要与 make 自身失败区分。
	set +e
	(
		cd "$LEDE" || exit 1
		timeout "$DL_TIMEOUT" make download -j"$JOBS" V=s
	) > "$LOG" 2>&1
	rc=$?
	set -e

	# 回显日志（CI 日志里必须能看到真实下载过程，否则无法排查慢源）
	cat "$LOG"

	if [ "$rc" -eq 0 ]; then
		echo ""
		note "下载完成，压缩包数量: $(find "$DL_DIR" -maxdepth 1 -name '*.tar.*' | wc -l | tr -d ' ')"
		echo "OK   make download 成功"
		exit 0
	fi

	if [ "$rc" -eq 124 ]; then
		echo "" >&2
		echo "!!! make download 超过 ${DL_TIMEOUT}s 被强制中止。" >&2
		echo "    这说明某个上游源极慢（历史上是 www.nasm.us，556 B/s）。" >&2
		echo "    处置：把可用镜像补进 DOWNLOAD_MIRROR（分号分隔），或调大超时。" >&2
		echo "    当前 DOWNLOAD_MIRROR=${DOWNLOAD_MIRROR:-<未设置>}" >&2
		exit 1
	fi

	# ── 自愈：本地缓存哈希与上游不一致 ──────────────────────────
	# download.pl 的原文：
	#   Hash of the local file <name> does not match (file: <a>, requested: <b>) - deleting download.
	# 注意它虽然写了 "deleting download"，但实际是在 die 之前打印的，
	# 文件并没有被删除，所以必须我们自己删。
	BAD=$(sed -n 's/^Hash of the local file \(.*\) does not match.*/\1/p' "$LOG" | sort -u)

	if [ -n "$BAD" ]; then
		echo "" >&2
		BADN=$(printf '%s\n' "$BAD" | wc -l | tr -d ' ')
		echo "!!! 检测到 $BADN 个缓存文件与上游哈希不一致：" >&2
		printf '%s\n' "$BAD" | sed 's/^/      /' >&2
		echo "    这些文件是缓存镜像里的旧版本（上游重打包但文件名未变）。" >&2
		echo "    逐个删除后重试；下载会从镜像/上游重新获取正确版本。" >&2

		n=0
		for f in $BAD; do
			# 只允许删除 dl 目录下的普通文件，避免文件名注入导致误删
			case "$f" in
			*/* | .*)
				echo "    SKIP 可疑文件名（含路径分隔符或以点开头）: [$f]" >&2
				continue
				;;
			esac
			if [ -f "$DL_DIR/$f" ]; then
				rm -f "$DL_DIR/$f"
				echo "    已删除 $DL_DIR/$f"
				n=$((n + 1))
			else
				echo "    SKIP 文件不存在: $DL_DIR/$f" >&2
			fi
		done

		if [ "$n" -eq 0 ]; then
			echo "!!! 日志报告哈希不一致，但没能删掉任何文件 —— 无法自愈，构建中止" >&2
			exit 1
		fi
		note "已清理 $n 个失效缓存文件，进入下一轮重试"
		attempt=$((attempt + 1))
		continue
	fi

	# ── 其它失败：原样抛出，不猜原因 ────────────────────────────
	echo "" >&2
	echo "!!! make download 失败（exit=$rc），日志末 40 行：" >&2
	tail -40 "$LOG" >&2
	echo "" >&2
	echo "    常见原因：某个 PKG_SOURCE_URL 全部镜像都不可用、磁盘写满、" >&2
	echo "    或某个包的 PKG_HASH 与上游实际内容不符（后者见上文的哈希提示）。" >&2
	exit 1
done

echo "!!! 已重试 $MAX_ATTEMPTS 轮仍然失败，构建中止" >&2
exit 1
