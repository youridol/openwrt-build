#!/bin/sh
# ============================================================
# verify-firmware-artifact.sh — 刷机前的固件产物预检
# ------------------------------------------------------------
# 依据 docs/adr/0004-dns-chain-verification.md §12.1。
#
# 为什么需要它：
#   v0.9.0 前两轮构建都「全绿 + 产物正常」，但解包后发现
#   LuCI 页面整层缺失（dnschain 条目数 = 0）。
#   刷机后再发现要多花一次刷机；预检能在刷之前拦住。
#
# 用法：
#   sh tools/verify-firmware-artifact.sh <解压后的目录>
#
#   <目录> 里放 gh run download 下来的 .img.gz 与 .sha256。
#
# 关键实现说明（踩过的坑）：
#   1. **不要用 `unsquashfs -l <path>` 判断单文件是否存在** ——
#      实测该命令对不存在的路径也返回 0，会把「全缺」误报成「全在」。
#      必须用 `-ll` 列全量清单再 grep。
#   2. `gunzip` 解 OpenWrt 镜像会报 "trailing garbage ignored" 并返回非 0，
#      但解压结果是对的，故忽略其退出码。
#   3. `unsquashfs -d <dir> ... <path>` 在 4.5 上不按预期提取（解出 0 文件），
#      故本脚本只做清单核对，不需要真解包。
# ============================================================

set -e

DIR="$1"
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
	echo "用法: sh $0 <包含 .img.gz 的目录>" >&2
	exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

rc=0
CDIR=$(cd "$DIR" && pwd)

echo "=== 1. sha256 校验 ==="
found_sha=0
for s in "$CDIR"/*.sha256; do
	[ -f "$s" ] || continue
	found_sha=1
	img="${s%.sha256}"
	[ -f "$img" ] || { echo "FAIL 有 .sha256 但无对应镜像: $img"; rc=1; continue; }
	exp=$(awk '{print $1}' "$s")
	act=$(sha256sum "$img" | awk '{print $1}')
	if [ "$exp" = "$act" ]; then
		echo "OK   $(basename "$img")"
	else
		echo "FAIL $(basename "$img")"
		echo "     expected=$exp"
		echo "     actual  =$act"
		rc=1
	fi
done
[ "$found_sha" = 1 ] || { echo "FAIL 目录里没有 .sha256 文件"; rc=1; }

echo ""
echo "=== 2. 解压并定位 squashfs ==="
IMG=$(ls "$CDIR"/*combined-efi.img.gz 2>/dev/null | head -1)
if [ -z "$IMG" ]; then
	echo "FAIL 找不到 *combined-efi.img.gz" >&2
	exit 1
fi
echo "镜像: $(basename "$IMG")"

# gunzip 对 trailing garbage 返回非 0，但结果正确
gunzip -c "$IMG" > "$WORK/fw.img" 2>/dev/null || true
if [ ! -s "$WORK/fw.img" ]; then
	echo "FAIL 解压失败（$WORK/fw.img 为空）" >&2
	exit 1
fi

OFF=$(python3 - "$WORK/fw.img" <<'PY'
import sys
with open(sys.argv[1], 'rb') as f:
    pos = 0
    while True:
        chunk = f.read(1024 * 1024 * 8)
        if not chunk:
            print(-1)
            break
        i = chunk.find(b'hsqs')
        if i >= 0:
            print(pos + i)
            break
        pos += len(chunk)
PY
)
if [ "$OFF" -lt 0 ]; then
	echo "FAIL 镜像里找不到 squashfs magic" >&2
	exit 1
fi
echo "squashfs 偏移: $OFF"
tail -c +$((OFF + 1)) "$WORK/fw.img" > "$WORK/root.squashfs"

echo ""
echo "=== 3. 生成全量清单（-ll，含权限）==="
LIST="$WORK/list.txt"
unsquashfs -ll "$WORK/root.squashfs" > "$LIST" 2>/dev/null || true
total=$(wc -l < "$LIST")
echo "清单 $total 行"
[ "$total" -gt 100 ] || { echo "FAIL 清单过短，squashfs 可能损坏"; exit 1; }

echo ""
echo "=== 4. dnschain 相关全部条目 ==="
grep -E 'dnschain|applechina' "$LIST" | sed 's/^/  /' || echo "  (无)"

echo ""
echo "=== 5. 逐项核对 ==="
check() {
	desc="$1"; pat="$2"; want="$3"
	line=$(grep -F "$pat" "$LIST" | head -1)
	if [ -z "$line" ]; then
		echo "MISS $desc"
		rc=1
		return
	fi
	if [ -n "$want" ]; then
		perm=$(printf '%s' "$line" | awk '{print $1}')
		if [ "$perm" = "$want" ]; then
			echo "OK   $desc [$perm]"
		else
			echo "FAIL $desc 权限 $perm != $want"
			rc=1
		fi
	else
		echo "OK   $desc"
	fi
}

echo "--- overlay 层（files/ 提供）---"
check "etc/config/dnschain"            "squashfs-root/etc/config/dnschain"                  "-rw-r--r--"
check "etc/init.d/dnschain"            "squashfs-root/etc/init.d/dnschain"                  "-rwxr-xr-x"
check "etc/rc.d/S95dnschain（已enable）" "squashfs-root/etc/rc.d/S95dnschain"                "lrwxrwxrwx"
check "etc/rc.d/K10dnschain"           "squashfs-root/etc/rc.d/K10dnschain"                 "lrwxrwxrwx"
check "etc/uci-defaults/99-zz-dnschain" "squashfs-root/etc/uci-defaults/99-zz-dnschain"     "-rwxr-xr-x"
check "etc/capabilities/dnschain-filter.json" "squashfs-root/etc/capabilities/dnschain-filter.json" "-rw-r--r--"
check "etc/ssrplus/applechina.conf"    "squashfs-root/etc/ssrplus/applechina.conf"          "-rw-r--r--"
check "usr/bin/dnschain-reconcile"     "squashfs-root/usr/bin/dnschain-reconcile"           "-rwxr-xr-x"
check "usr/bin/dnschain-selftest"      "squashfs-root/usr/bin/dnschain-selftest"            "-rwxr-xr-x"
check "usr/share/dnschain/dnschain.sh" "squashfs-root/usr/share/dnschain/dnschain.sh"       "-rwxr-xr-x"

echo ""
echo "--- LuCI 层（package/luci-app-dnschain 提供）---"
echo "（v0.9.0 首次出包时这一层整层缺失，条目数=0）"
check "menu.d/luci-app-dnschain.json"  "squashfs-root/usr/share/luci/menu.d/luci-app-dnschain.json"
check "acl.d/luci-app-dnschain.json"   "squashfs-root/usr/share/rpcd/acl.d/luci-app-dnschain.json"
check "controller/dnschain.lua"        "squashfs-root/usr/lib/lua/luci/controller/dnschain.lua"
check "cbi/dnschain/general.lua"       "squashfs-root/usr/lib/lua/luci/model/cbi/dnschain/general.lua"
check "cbi/dnschain/dnschain.lua"      "squashfs-root/usr/lib/lua/luci/model/cbi/dnschain/dnschain.lua"

echo ""
echo "--- opkg 包登记 ---"
check "luci-app-dnschain.control"      "squashfs-root/usr/lib/opkg/info/luci-app-dnschain.control"
check "luci-i18n-dnschain-zh-cn.control" "squashfs-root/usr/lib/opkg/info/luci-i18n-dnschain-zh-cn.control"

echo ""
echo "=== 6. 条目总数 ==="
n=$(grep -c 'dnschain' "$LIST" || true)
echo "  dnschain 条目: $n（v0.9.0 首次出包时为 0，正常应 >= 20）"
[ "$n" -ge 15 ] || { echo "  FAIL 条目不足"; rc=1; }

echo ""
echo "=== 7. 中文翻译说明 ==="
echo "  本页面的 translate() 里直接写的是中文（msgid==msgstr 形态），"
echo "  因此不生成 .lmo 也不影响显示 —— LuCI 找不到翻译时回退到原文，"
echo "  而原文就是中文。故此处不要求 .lmo 存在。"
if grep -q 'luci-app-dnschain.*\.lmo' "$LIST"; then
	echo "  （检测到 .lmo，亦可用）"
	grep 'luci-app-dnschain.*\.lmo' "$LIST" | sed 's/^/    /'
else
	echo "  （无 .lmo，符合预期）"
fi

echo ""
if [ "$rc" -eq 0 ]; then
	echo "=== 预检通过：可以刷机 ==="
else
	echo "=== 预检失败：不要刷机，先查 CI 日志 ===" >&2
	echo "    查这两段：" >&2
	echo "      'Add luci-app-dnschain' —— 包是否复制" >&2
	echo "      '=== dnschain 本体与中文语言包都必须入配置 ===' —— 符号是否进 .config" >&2
fi
exit "$rc"
