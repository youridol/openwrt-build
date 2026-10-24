#!/bin/sh
# ============================================================
# cache-release.sh — 用 GitHub Release 资产做「构建缓存」的存取
# ------------------------------------------------------------
# 为什么用 Release 资产，而不是 actions/cache：
#
#   | 维度 | actions/cache | Release 资产（本脚本） |
#   |---|---|---|
#   | 单仓库配额 | 10 GB，超了按最后访问时间淘汰 | 无总量上限 |
#   | 过期 | **一周未被访问即淘汰** | 只有手动/脚本删除 |
#   | 单文件大小 | 无明确限制但需 tar 打包 | 2 GB（故分片 1900M） |
#   | 下载来源 | GitHub 内部缓存服务 | GitHub CDN（不占外部带宽） |
#   | 可否精确控制版本 | 只能靠 key 前缀匹配 | 资产名 + meta 文件，完全可控 |
#
#   本项目的 dl/ 是 GB 级，且构建不是每天都跑 —— 放在 actions/cache 里
#   既装不下、又会被「一周未访问」淘汰掉。Release 资产两个问题都没有。
#
#   ⚠️ 代价：Release 资产不能原地修改，只能「先传新、再删旧」。
#      故本脚本的 save 是「上传 → 清理陈旧 → 最后上传 meta」的顺序，
#      meta 文件是提交点：只要 meta 还没更新，读者看到的就还是旧的一致状态。
#
# 用法：
#   sh tools/cache-release.sh save    <tag> <asset-dir> [保留的 part 数=0 表示全部保留]
#   sh tools/cache-release.sh restore <tag> <dest-dir> [pattern ...]
#   sh tools/cache-release.sh list    <tag>
#   sh tools/cache-release.sh purge   <tag>          # 删除整个缓存 Release
#
# 环境变量：
#   GH_TOKEN / GITHUB_TOKEN  必填（contents: write 才能上传）
#   GH_REPO                  必填，形如 owner/repo
#                            （CI 的 workspace 根可能没有 .git，gh 无法自推仓库）
#
# 退出码：0 成功；非 0 失败。restore 找不到 Release 时返回 10
#         （调用方据此区分「没有缓存」与「缓存坏了」）。
#
# 约束（AGENTS.md §6 第 11 条）：必须 POSIX sh（dash）兼容。
# ============================================================

set -eu

PROG=$(basename "$0")
RC_NO_CACHE=10

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
  $PROG save    <tag> <asset-dir> [保留 part 数，0=全部保留]
  $PROG restore <tag> <dest-dir> [pattern ...]
  $PROG list    <tag>
  $PROG purge   <tag>
EOF
	exit 2
}

require_env() {
	[ -n "${GH_REPO:-}" ] || die "缺 GH_REPO（形如 owner/repo）。CI 的 workspace 根可能没有 .git，gh 无法自推仓库"
	command -v gh >/dev/null 2>&1 || die "缺 gh（GitHub CLI）"
}

# Release 是否存在：0=存在 1=不存在 2=其它错误
release_state() {
	_tag="$1"
	out=$(gh release view "$_tag" --repo "$GH_REPO" 2>&1) && return 0
	lc=$(printf '%s' "$out" | tr 'A-Z' 'a-z')
	case "$lc" in
	*"release not found"* | *"not found"* | *"http 404"* | *"could not find"*) return 1 ;;
	esac
	echo "!!! gh release view 失败（不是「不存在」）：" >&2
	printf '%s\n' "$out" >&2
	return 2
}

ensure_release() {
	_tag="$1"
	set +e
	release_state "$_tag"
	st=$?
	set -e
	case "$st" in
	0) return 0 ;;
	1)
		note "创建缓存 Release: $_tag"
		# ⚠️ 并发安全：warm-dl 与 warm-toolchain 是**并行**的两个 job，
		# 首次运行时两边会同时发现「Release 不存在」并同时创建 ——
		# 后到的那次会以 "already exists" 失败。
		# 故这里不把创建失败当作致命错误，而是重新检查一次状态：
		# 若此时 Release 已存在，说明是另一路建好的，直接继续。
		if ! gh release create "$_tag" --repo "$GH_REPO" \
			--title "构建缓存 · $_tag" \
			--notes "由 .github/workflows/cache-deps.yml 自动维护的构建缓存资产。

**这不是发版。** 里面的 dl/ 与工具链分片供 CI 复用，用于跳过
「每次全新克隆都重新下载源码包 / 重建交叉工具链」。

- 资产由 \`tools/dir-mirror.sh\` 打包，\`tools/cache-release.sh\` 上传。
- 分片上限 1900 MB（Release 单文件上限 2 GB）。
- 删除该 Release 只会让下一次构建变慢，不会损坏任何固件产物。" \
			--prerelease; then
			note "创建返回非零（可能是另一路并发创建），复查状态"
			set +e
			release_state "$_tag"
			st2=$?
			set -e
			[ "$st2" -eq 0 ] || die "创建 Release 失败且复查仍不存在: $_tag"
			note "Release 已由另一路创建，继续"
		fi
		;;
	*)
		die "无法确定 Release 状态: $_tag"
		;;
	esac
}

cmd_save() {
	TAG="${1:-}"
	DIR="${2:-}"
	KEEP_PARTS="${3:-0}"
	[ -n "$TAG" ] && [ -n "$DIR" ] || usage
	[ -d "$DIR" ] || die "资产目录不存在: $DIR"

	require_env
	ensure_release "$TAG"

	# ── 1. 上传分片（不含 meta）──────────────────────────────
	#
	# 顺序刻意的：分片先传，meta 最后传。
	# meta 记录 PARTS，是「一致性提交点」；若先传 meta，
	# 中途失败会让读者看到一个指向不存在分片的 meta。
	uploaded=0
	for f in "$DIR"/*.part-*; do
		[ -f "$f" ] || continue
		name=$(basename "$f")
		note "上传 $name ($(wc -c < "$f" | tr -d ' ') 字节)"
		gh release upload "$TAG" "$f" --repo "$GH_REPO" --clobber
		uploaded=$((uploaded + 1))
	done
	[ "$uploaded" -gt 0 ] || die "资产目录里没有分片: $DIR"

	# ── 2. 删除**同一种缓存**的陈旧分片 ──────────────────────
	#
	# ⚠️ 关键：只能删「本目录这批资产所属的 NAME」的分片，
	#    绝不能按「凡是不在本目录里的 .part-* 就删」来做 ——
	#    那会把**别的缓存种类**（例如同一个 Release 里的 toolchain-*/host-*）
	#    一起删掉。第一版正是这么写的，是个会造成缓存互删的真 bug。
	#
	#    判定依据：本目录里的 *.meta 文件的 NAME 字段。
	#    同一个 NAME 的资产才属于「同一代缓存」。
	#
	# 为什么要删：上一轮可能有更多分片（如 part-07），本轮只剩 5 个。
	# 不删的话，解包端会数到 7 个分片、与 meta 的 5 不符而拒绝解包。
	NAMES=""
	for m in "$DIR"/*.meta; do
		[ -f "$m" ] || continue
		n=$(sed -n 's/^NAME=//p' "$m" | head -1)
		[ -n "$n" ] || die "meta 缺少 NAME 字段: $m"
		NAMES="$NAMES $n"
	done
	[ -n "$NAMES" ] || die "资产目录里没有 *.meta，拒绝提交（没有 meta 的镜像无法安全解包）"

	existing=$(gh release view "$TAG" --repo "$GH_REPO" --json assets --jq '.assets[].name')
	for name in $existing; do
		[ -f "$DIR/$name" ] && continue
		owned=0
		for n in $NAMES; do
			case "$name" in
			"$n".part-* | "$n".tar.* | "$n".meta) owned=1 ;;
			esac
		done
		[ "$owned" = "1" ] || continue
		note "删除陈旧资产 $name"
		gh release delete-asset "$TAG" "$name" --repo "$GH_REPO" --yes
	done

	# ── 3. 最后上传 meta（提交点）────────────────────────────
	for f in "$DIR"/*.meta; do
		[ -f "$f" ] || continue
		name=$(basename "$f")
		note "上传 $name（提交点）"
		gh release upload "$TAG" "$f" --repo "$GH_REPO" --clobber
	done

	# ── 4. 可选：只保留最近 N 个分片（用于分片过多的老缓存收尾）──
	if [ "$KEEP_PARTS" != "0" ]; then
		note "KEEP_PARTS=$KEEP_PARTS 已指定，但本脚本不做历史版本裁剪"
		note "（缓存是「整体替换」语义，历史分片在第 2 步已按目录内容清理）"
	fi

	echo "OK   缓存已保存: $TAG（上传 $uploaded 个分片）"
	gh release view "$TAG" --repo "$GH_REPO" --json assets \
		--jq '.assets[] | "    \(.name)  \(.size) bytes"'
}

cmd_restore() {
	TAG="${1:-}"
	DEST="${2:-}"
	shift 2 2>/dev/null || true
	[ -n "$TAG" ] && [ -n "$DEST" ] || usage

	require_env

	set +e
	release_state "$TAG"
	st=$?
	set -e
	case "$st" in
	0) : ;;
	1)
		note "缓存 Release 不存在: $TAG（首次运行属正常，将回落到上游下载）"
		exit "$RC_NO_CACHE"
		;;
	*) die "无法确定 Release 状态: $TAG" ;;
	esac

	mkdir -p "$DEST"

	if [ "$#" -eq 0 ]; then
		note "下载全部资产 → $DEST"
		gh release download "$TAG" --repo "$GH_REPO" --dir "$DEST" --clobber
	else
		for p in "$@"; do
			note "下载资产 pattern=$p → $DEST"
			# 某个 pattern 没有匹配不算失败（不同缓存种类资产名不同）
			gh release download "$TAG" --repo "$GH_REPO" --dir "$DEST" \
				--pattern "$p" --clobber || note "pattern $p 无匹配，跳过"
		done
	fi

	n=$(find "$DEST" -maxdepth 1 -type f | wc -l | tr -d ' ')
	[ "$n" -gt 0 ] || {
		note "下载后目录为空: $DEST"
		exit "$RC_NO_CACHE"
	}
	echo "OK   缓存已下载: $TAG（$n 个文件）"
}

cmd_list() {
	TAG="${1:-}"
	[ -n "$TAG" ] || usage
	require_env
	set +e
	release_state "$TAG"
	st=$?
	set -e
	case "$st" in
	0) : ;;
	1)
		echo "（不存在）$TAG"
		exit "$RC_NO_CACHE"
		;;
	*) die "无法确定 Release 状态: $TAG" ;;
	esac
	gh release view "$TAG" --repo "$GH_REPO" --json assets \
		--jq '.assets[] | "\(.name)\t\(.size)\t\(.createdAt)"'
}

cmd_purge() {
	TAG="${1:-}"
	[ -n "$TAG" ] || usage
	require_env
	set +e
	release_state "$TAG"
	st=$?
	set -e
	case "$st" in
	0)
		note "删除缓存 Release: $TAG"
		# 不带 --cleanup-tag：缓存 Release 的 tag 不需要保留，
		# 但删 tag 需要额外的 refs 权限，且没有收益。
		gh release delete "$TAG" --repo "$GH_REPO" --yes
		echo "OK   已删除: $TAG"
		;;
	1) note "缓存 Release 不存在，无需删除: $TAG" ;;
	*) die "无法确定 Release 状态: $TAG" ;;
	esac
}

case "${1:-}" in
save) shift; cmd_save "$@" ;;
restore) shift; cmd_restore "$@" ;;
list) shift; cmd_list "$@" ;;
purge) shift; cmd_purge "$@" ;;
-h | --help | help) usage ;;
*) usage ;;
esac
