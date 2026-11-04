#!/bin/sh
# ============================================================
# verify-theme-vendor.sh — luci-theme-shadcn vendored 目录的契约校验
# ------------------------------------------------------------
# 背景（v0.26.0）：用户要求「CI/CD 编译时不要再拉上游，改用本仓库的主题」。
# 于是主题从「CI 里 git clone」改为 vendored 到 package/luci-theme-shadcn/。
#
# 这个脚本校验 vendoring 之后**无法被构建发现**的几类问题：
#
#   1. 关键文件缺失 —— 编出来白屏，构建全绿。
#   2. 二进制资源被行尾转换损坏 —— 背景图裂开，构建与运行都不报错。
#   3. 无扩展名脚本变成 CRLF —— 路由器上解析失败，默认主题不生效。
#   4. 执行位丢失 —— 30_luci-theme-shadcn 不执行，主题装了也不生效。
#
# 约束（AGENTS.md §6 第 11 条）：必须 POSIX sh（dash）兼容。
#   禁止进程替换 <(...)、[[ ]]、bash 数组、local。
#
# 用法：sh tools/verify-theme-vendor.sh
# 退出码：0 = 全部通过；1 = 有断言失败
# ============================================================

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 1

rc=0
fail() { echo "FAIL $1" >&2; rc=1; }
ok()   { echo "OK   $1"; }

PKG=package/luci-theme-shadcn

# ── 1. 包目录与关键文件 ───────────────────────────────────────
[ -d "$PKG" ] || { echo "FAIL 缺少 $PKG（主题未 vendored）" >&2; exit 1; }

for f in Makefile \
         UPSTREAM \
         root/etc/uci-defaults/30_luci-theme-shadcn \
         root/usr/share/luci/menu.d/luci-theme-shadcn.json \
         root/usr/share/rpcd/acl.d/shadcn.json \
         htdocs/luci-static/shadcn/main.css \
         htdocs/luci-static/shadcn/login.css \
         ucode/template/themes/shadcn/header.ut ; do
  if [ -f "$PKG/$f" ]; then
    ok "$f ($(wc -c < "$PKG/$f") 字节)"
  else
    fail "缺少 $PKG/$f（主题会白屏或无法启用）"
  fi
done

# ── 2. main.css 必须是预构建产物 ─────────────────────────────
# 上游把 tailwind 构建结果入库。若有人误传源码版，文件只有几 KB，
# 页面会退化成无样式，而且不报错。
if [ -f "$PKG/htdocs/luci-static/shadcn/main.css" ]; then
  sz=$(wc -c < "$PKG/htdocs/luci-static/shadcn/main.css")
  if [ "$sz" -ge 20000 ]; then
    ok "main.css $sz 字节（已预构建）"
  else
    fail "main.css 只有 $sz 字节，疑似未预构建（应 > 100KB）"
  fi
fi

# ── 3. 二进制资源未被行尾转换 ───────────────────────────────
# .gitattributes 的 `package/** text eol=lf` 会命中 png/jpeg/ico/woff2，
# 除非后面有 `*.png binary` 之类的规则把它覆盖掉。
# 转换后的二进制会被 file 识别成 data / 缺失魔数，这里逐一复核类型。
check_bin() {
  f=$1
  want=$2
  if [ ! -f "$PKG/$f" ]; then
    fail "缺少二进制资源 $PKG/$f"
    return
  fi
  desc=$(file -b "$PKG/$f" 2>/dev/null)
  case "$desc" in
    *"$want"*) ok "$f ($desc)" ;;
    *) fail "$f 类型异常（疑似被行尾转换损坏）：$desc" ;;
  esac
}

check_bin htdocs/luci-static/shadcn/images/login-bg.jpeg          "JPEG image"
check_bin htdocs/luci-static/shadcn/images/favicon.ico            "icon"
check_bin htdocs/luci-static/shadcn/images/apple-touch-icon.png   "PNG image"
check_bin htdocs/luci-static/shadcn/images/web-app-manifest-512x512.png "PNG image"
check_bin htdocs/luci-static/shadcn/inter-latin-wght-normal.woff2 "Web Open Font"

# ── 4. .gitattributes 的 binary 规则必须排在 package/** 之后 ──
# git 的规则是「后出现的覆盖先出现的」。把 *.png binary 写在 package/**
# 之上等于没写 —— 这正是最容易犯、且无法从构建结果看出来的错。
attr_check() {
  pat=$1
  # grep -n 取行号：binary 规则的行号必须大于 package/** 的行号
  bin_line=$(grep -n "^$pat[[:space:]]*binary" .gitattributes | head -1 | cut -d: -f1)
  pkg_line=$(grep -n '^package/\*\*' .gitattributes | head -1 | cut -d: -f1)
  if [ -z "$bin_line" ]; then
    fail ".gitattributes 缺少 '$pat binary' 规则（二进制会被转坏）"
  elif [ -z "$pkg_line" ]; then
    ok ".gitattributes 无 package/** 规则，$pat binary 无需排序"
  elif [ "$bin_line" -gt "$pkg_line" ]; then
    ok "$pat binary 在第 $bin_line 行，晚于 package/**（第 $pkg_line 行）"
  else
    fail "$pat binary 在第 $bin_line 行，早于 package/**（第 $pkg_line 行）→ 规则被覆盖，等于没写"
  fi
}
attr_check '*.png'
attr_check '*.jpg'
attr_check '*.ico'
attr_check '*.woff2'

# ── 5. 无扩展名脚本不得含 CRLF ──────────────────────────────
# 路由器上是 busybox ash，CRLF 会让 shebang 行变成 "#!/bin/sh\r"，
# 表现为 "not found" 或语法错误，而本地（Linux/macOS）测不出来。
for f in root/etc/uci-defaults/30_luci-theme-shadcn \
         root/etc/init.d/shadcn-dashboard \
         root/etc/config/shadcn-dashboard ; do
  if [ ! -f "$PKG/$f" ]; then
    fail "缺少 $PKG/$f"
    continue
  fi
  if grep -q "$(printf '\r')" "$PKG/$f" 2>/dev/null; then
    fail "$PKG/$f 含 CRLF（路由器上解析失败）"
  else
    ok "$f 行尾为 LF"
  fi
done

# ── 6. 执行位 ───────────────────────────────────────────────
# 缺了它 30_luci-theme-shadcn 不会执行 → 主题装了也不生效。
# 注意：git 索引里的 mode 才是权威（Windows 工作树看不出权限位）。
for f in root/etc/uci-defaults/30_luci-theme-shadcn \
         root/etc/init.d/shadcn-dashboard ; do
  if [ ! -f "$PKG/$f" ]; then
    continue
  fi
  if [ -x "$PKG/$f" ]; then
    ok "$f 有执行位"
  else
    fail "$f 缺执行位（chmod +x 或 git update-index --chmod=+x）"
  fi
done

# ── 7. UPSTREAM 必须记录 commit ─────────────────────────────
# 溯源用。CI 的产物命名和排查都要靠它，缺了就无法回答
# 「这个固件里是哪个版本的主题」。
if [ -f "$PKG/UPSTREAM" ]; then
  if sed -n 's/^commit: *//p' "$PKG/UPSTREAM" | head -1 | grep -Eq '^[0-9a-f]{40}$'; then
    ok "UPSTREAM commit=$(sed -n 's/^commit: *//p' "$PKG/UPSTREAM" | head -1)"
  else
    fail "$PKG/UPSTREAM 的 commit 行不是 40 位 sha1"
  fi
fi

# ── 8. CI 不得运行时 clone 上游 ─────────────────────────────
# 用户明确要求「编译时不要再拉上游」。若 workflows 里又出现
# clone luci-theme-shadcn，说明配方回退了。
# 注意用 grep 排除注释行，否则解释性注释会永久误报
# （AGENTS.md §6 第 6 条记的 v0.4.7 / v0.4.10 两次教训）。
for wf in .github/workflows/build-openwrt.yml .github/workflows/cache-deps.yml; do
  [ -f "$wf" ] || continue
  hits=$(grep -v '^[[:space:]]*#' "$wf" | grep -c 'clone.*luci-theme-shadcn' || true)
  if [ "$hits" = "0" ]; then
    ok "$wf 不再 clone 上游主题"
  else
    fail "$wf 仍含 $hits 处 clone luci-theme-shadcn（应改用本地 package/）"
  fi
done

echo "============================================"
if [ "$rc" = "0" ]; then
  echo "PASS luci-theme-shadcn vendoring 契约全部通过"
else
  echo "FAIL 有断言未通过，见上方 FAIL 行" >&2
fi
exit "$rc"
