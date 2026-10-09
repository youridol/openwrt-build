#!/bin/sh
# 同步 luci-app-trafficctl 到指定上游版本，并把本地改动重新落地。
#
# 背景
# ----
# 本仓库把 `YusDyr/luci-app-trafficctl` 整包 **vendored** 到
# `package/luci-app-trafficctl/`（CI 直接 cp 该目录，不联网）。
# 相对上游的差分固化在 `patches/luci-app-trafficctl/*.patch`。
#
# 「升级上游」的正确流程不是「覆盖后重算 patch」—— 那样会把本地改动一起
# 覆盖掉，重算出来的是**空 patch**。正确流程是：
#
#   1. 备份当前包目录（含本地改动）与当前 patch；
#   2. 用新上游覆盖包目录；
#   3. 把**旧 baseline 的 patch** 套到新上游上 —— 成功则本地改动被重新落地，
#      冲突则明确中止并保留现场，由人决定怎么改；
#   4. 用「新上游 vs 已套用 patch 的工作树」重算 patch（交给唯一实现
#      tools/regen-trafficctl-patches.py，内含回放校验）；
#   5. 更新 UPSTREAM 并复跑不变量校验。
#
# 注意：**改代码就改 package/ 下的文件**，改完跑
#   python3 tools/regen-trafficctl-patches.py <上游包目录>
# 让 patch 跟上；本脚本只用于「换上游版本」。
#
# 用法
# ----
#   sh tools/sync-trafficctl.sh v1.21.5
#
# 退出码 0 = 同步成功；非 0 = 失败（不做部分写入）。

set -eu

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

# ── 0. 前置检查：必须干净，否则回滚困难 ─────────────────────────────
echo "=== 0. 前置检查 ==="
if [ -n "$(git status --porcelain -- "$PKG" "$PATCHDIR")" ]; then
    echo "错误：$PKG 或 $PATCHDIR 有未提交改动。请先提交或 stash。" >&2
    git status --porcelain -- "$PKG" "$PATCHDIR" >&2
    exit 1
fi
OLD_TAG="$(cat "$PATCHDIR/UPSTREAM" 2>/dev/null || echo '(未知)')"
echo "  当前 baseline: $OLD_TAG"
echo "  目标 baseline: $TAG"
echo "  工作树：干净"

echo ""
echo "=== 1. 克隆上游 $TAG ==="
git clone --depth 1 --branch "$TAG" \
    https://github.com/YusDyr/luci-app-trafficctl.git "$CLONE/up"
echo "  HEAD: $(git -C "$CLONE/up" rev-parse HEAD)"
SRC="$CLONE/up/luci-app-trafficctl"
[ -d "$SRC" ] || { echo "错误：上游 $TAG 下找不到包目录 luci-app-trafficctl/" >&2; exit 1; }

# ── 2. 备份当前状态（本地改动 + 旧 patch）───────────────────────────
echo ""
echo "=== 2. 备份当前状态 ==="
cp -r "$PKG" "$CLONE/pkg-local"
cp -r "$PATCHDIR" "$CLONE/patches-old"
echo "  已备份包目录与 $(ls "$PATCHDIR"/*.patch | wc -l) 个 patch 到临时目录"

# ── 3. 保留本地专有文件（不在上游包目录里的）───────────────────────
echo ""
echo "=== 3. 记录本地专有文件 ==="
#   LICENSE / README.md —— 来自上游**仓库根**，不在包目录内
#   po/zh-cn/           —— 本地新增的中文翻译（已含在 0003 patch 里，此处兜底）
KEEP="LICENSE README.md po/zh-cn/luci-app-trafficctl.po"
for f in $KEEP; do
    if [ -f "$PKG/$f" ]; then
        mkdir -p "$CLONE/keep/$(dirname "$f")"
        cp "$PKG/$f" "$CLONE/keep/$f"
        echo "  保留 $f"
    fi
done

# ── 4. 用新上游覆盖包目录，再套旧 patch ────────────────────────────
echo ""
echo "=== 4. 覆盖为新上游并套用现有 patch ==="
find "$PKG" -mindepth 1 -delete
cp -r "$SRC"/. "$PKG"/
find "$PKG" -type f -exec sed -i 's/\r$//' {} +
for f in $KEEP; do
    if [ -f "$CLONE/keep/$f" ]; then
        mkdir -p "$PKG/$(dirname "$f")"
        cp "$CLONE/keep/$f" "$PKG/$f"
    fi
done
# 模式：按 git 索引恢复（上游索引在 clone 里可得）
git -C "$CLONE/up" ls-files -s luci-app-trafficctl \
  | awk '$1=="100755"{print $4}' | sed 's|^luci-app-trafficctl/||' > "$CLONE/x755"
n755=0
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$PKG/$rel" ] || continue
    chmod +x "$PKG/$rel"; n755=$((n755+1))
done < "$CLONE/x755"
# 其余去掉执行位
for f in $(find "$PKG" -type f); do
    rel="${f#$PKG/}"
    if ! grep -qxF "$rel" "$CLONE/x755"; then chmod -x "$f" 2>/dev/null || true; fi
done
echo "  包目录现有 $(find "$PKG" -type f | wc -l) 个文件（$n755 个可执行）"

# 套用旧 patch。用 `git apply --3way` 需要 blob 在库里，这里改用
# `git apply` 并保留 .rej，失败时明确中止。
APPLIED=0
for p in "$CLONE"/patches-old/*.patch; do
    [ -f "$p" ] || continue
    if ( cd "$PKG" && git apply --check -p1 "$p" 2>/dev/null ); then
        ( cd "$PKG" && git apply -p1 "$p" )
        echo "  OK   套用 $(basename "$p")"
        APPLIED=$((APPLIED+1))
    else
        echo "  FAIL $(basename "$p") 无法套用到 $TAG" >&2
        ( cd "$PKG" && git apply -p1 --reject "$p" ) >/dev/null 2>&1 || true
        echo "" >&2
        echo "！！！本地改动与新上游冲突，无法自动迁移。" >&2
        echo "当前状态：$PKG 已是 $TAG 原样 + 部分 patch。" >&2
        echo "请手工处理（.rej 文件标出冲突处），完成后依次：" >&2
        echo "  python3 tools/regen-trafficctl-patches.py $CLONE/up" >&2
        echo "  printf '%s\\n' $TAG > $PATCHDIR/UPSTREAM" >&2
        echo "  sh tools/verify-trafficctl-invariants.sh" >&2
        echo "" >&2
        echo "回滚：git checkout -- $PKG && git clean -fd $PKG" >&2
        exit 1
    fi
done
echo "  共套用 $APPLIED 个 patch"

# ── 5. 重算 patch（唯一实现，含回放校验）───────────────────────────
echo ""
echo "=== 5. 重算 patch ==="
python3 tools/regen-trafficctl-patches.py "$CLONE/up"

echo ""
echo "=== 6. 更新 UPSTREAM 并复跑不变量校验 ==="
printf '%s\n' "$TAG" > "$PATCHDIR/UPSTREAM"
echo "  $PATCHDIR/UPSTREAM = $TAG"
TCTL_UPSTREAM_LOCAL="$SRC" sh tools/verify-trafficctl-invariants.sh

echo ""
echo "同步完成（$OLD_TAG → $TAG）。请接着："
echo "  1) 更新 AGENTS.md 里 trafficctl 的版本号与本地改动清单"
echo "  2) 更新 CHANGELOG.md"
echo "  3) python3 tools/check-trafficctl-i18n.py --write-pot（若上游新增了字符串）"
echo "  4) sh -n 各 shell 脚本；node --check 三个视图 js"
echo "  5) 本地确认无误后 git add / commit"
