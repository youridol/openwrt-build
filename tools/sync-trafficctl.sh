#!/bin/sh
# 同步 luci-app-trafficctl 到指定上游版本，并重新生成 patches/luci-app-trafficctl/*.patch
#
# 背景
# ----
# 本仓库把 `YusDyr/luci-app-trafficctl` 整包 **vendored** 到
# `package/luci-app-trafficctl/`。同时把本地改动固化成
# `patches/luci-app-trafficctl/*.patch`。此脚本做两件事：
#
#   1. 用指定上游 tag 的包目录**覆盖** `package/luci-app-trafficctl/`
#      （保留 LICENSE / README.md 与 po/zh-cn，它们不在上游包目录里）；
#   2. 把当前工作树相对该上游基线的差异，按职责重新导出成 3 个 patch。
#
# 也就是说：**改代码就改 package/ 下的文件**，改完跑本脚本让 patch 跟上。
# CI 只用 vendored 包（不联网），patch 是给「跟随上游」用的差分记录：
# 升级上游时只要重跑本脚本，patch 会自动重算，冲突会在这里暴露而不是在 CI。
#
# 用法
# ----
#   sh tools/sync-trafficctl.sh v1.21.4
#
# 退出码 0 = 同步并生成成功；非 0 = 失败（不做部分写入）。

set -e

TAG="${1:-}"
if [ -z "$TAG" ]; then
    echo "用法: sh tools/sync-trafficctl.sh <upstream-tag>" >&2
    echo "例如: sh tools/sync-trafficctl.sh v1.21.4" >&2
    exit 2
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

PKG=package/luci-app-trafficctl
PATCHDIR=patches/luci-app-trafficctl
CLONE=$(mktemp -d)
trap 'rm -rf "$CLONE"' EXIT INT TERM

echo "=== 1. 克隆上游 $TAG ==="
git clone --depth 1 --branch "$TAG" \
    https://github.com/YusDyr/luci-app-trafficctl.git "$CLONE/up"
echo "  HEAD: $(git -C "$CLONE/up" rev-parse HEAD)"

SRC="$CLONE/up/luci-app-trafficctl"
[ -d "$SRC" ] || { echo "错误：上游 $TAG 下找不到包目录 luci-app-trafficctl/" >&2; exit 1; }

echo ""
echo "=== 2. 备份当前本地包（可回滚）==="
BAK="$CLONE/local-backup"
cp -r "$PKG" "$BAK"
echo "  备份于临时目录（脚本结束时释放）：$BAK"

echo ""
echo "=== 3. 用上游基线覆盖包目录（保留本地专有文件）==="
# 记住本地专有文件（上游包目录里没有的）
KEEP="LICENSE README.md po/zh-cn/luci-app-trafficctl.po"
KEEPTMP="$CLONE/keep"
mkdir -p "$KEEPTMP"
for f in $KEEP; do
    if [ -f "$PKG/$f" ]; then
        mkdir -p "$KEEPTMP/$(dirname "$f")"
        cp "$PKG/$f" "$KEEPTMP/$f"
        echo "  保留 $f"
    fi
done

# 覆盖：先清空（保留目录本身），再从上游拷贝
find "$PKG" -mindepth 1 -delete
cp -r "$SRC"/. "$PKG"/
# 上游 checkout 在 Windows 下是 CRLF，统一转 LF（红线 1）
find "$PKG" -type f -exec sed -i 's/\r$//' {} +

# 放回保留的文件
for f in $KEEP; do
    if [ -f "$KEEPTMP/$f" ]; then
        mkdir -p "$PKG/$(dirname "$f")"
        cp "$KEEPTMP/$f" "$PKG/$f"
    fi
done
echo "  包目录现有 $(find "$PKG" -type f | wc -l) 个文件"

echo ""
echo "=== 4. 重建 patch（相对新基线）==="
mkdir -p "$PATCHDIR"
rm -f "$PATCHDIR"/*.patch

W="$CLONE/gen"
mkdir -p "$W/pkg"
cp -r "$SRC"/. "$W/pkg/"
find "$W/pkg" -type f -exec sed -i 's/\r$//' {} +

cd "$W"
G="git -c user.email=sync@local -c user.name=sync -c core.autocrlf=false"
$G init -q
$G add -A
$G commit -qm "upstream $TAG baseline"

OUT="$ROOT/$PATCHDIR"

# 每个 patch 负责一组文件；顺序即套用顺序。
emit() {  # emit <文件名> <提交说明> <文件列表...>
    _out="$1"; _desc="$2"; shift 2
    for _f in "$@"; do
        if [ -f "$ROOT/$PKG/$_f" ]; then
            mkdir -p "pkg/$(dirname "$_f")"
            cp "$ROOT/$PKG/$_f" "pkg/$_f"
        fi
    done
    $G add -A
    $G diff --cached --binary > "$OUT/$_out"
    $G commit -qm "$_desc"
    printf "  %-56s %5s 行\n" "$_out" "$(wc -l < "$OUT/$_out")"
}

emit "0001-rewrite-bytes-nft-for-this-kernel.patch" \
     "rewrite nft byte counter backend for this kernel" \
     root/usr/local/bin/trafficctl-bytes-nft.sh

emit "0002-ui-tabs-default-refresh-and-layout.patch" \
     "settings tabs, default refresh, card waterfall layout" \
     htdocs/luci-static/resources/view/trafficctl/status.js \
     htdocs/luci-static/resources/view/trafficctl/status.css \
     root/etc/config/trafficctl \
     root/usr/libexec/rpcd/luci.trafficctl

emit "0003-add-zh-cn-translation.patch" \
     "add zh-cn translation" \
     po/zh-cn/luci-app-trafficctl.po \
     po/templates/luci-app-trafficctl.pot

echo ""
echo "=== 5. 验证：干净基线上重新套用全部 patch，须与本地包一致 ==="
V="$CLONE/verify"
mkdir -p "$V/pkg"
cp -r "$SRC"/. "$V/pkg/"
find "$V/pkg" -type f -exec sed -i 's/\r$//' {} +
cd "$V"
$G init -q; $G add -A; $G commit -qm base

for p in "$OUT"/*.patch; do
    if $G apply --check "$p" 2>/dev/null; then
        $G apply "$p"
        echo "  OK   $(basename "$p")"
    else
        echo "  FAIL $(basename "$p")" >&2
        $G apply --check "$p" || true
        exit 1
    fi
done

# 与本地包比对（忽略本地专有文件）
if diff -rq pkg "$ROOT/$PKG" 2>&1 | grep -v 'LICENSE\|README.md'; then
    echo "  错误：套用 patch 的结果与本地包不一致" >&2
    exit 1
fi
echo "  一致"

echo ""
echo "=== 6. 记录上游版本 ==="
printf '%s\n' "$TAG" > "$OUT/UPSTREAM"
echo "  $OUT/UPSTREAM = $TAG"

echo ""
echo "同步完成。请接着："
echo "  1) 更新 AGENTS.md 里 trafficctl 的版本号与本地改动清单"
echo "  2) 更新 CHANGELOG.md"
echo "  3) python3 tools/check-trafficctl-i18n.py --write-pot"
echo "  4) sh -n 各 shell 脚本；node --check status.js"
