#!/bin/sh
# ============================================================
# gen-openwrt-config.sh — 生成 lede 的 .config（唯一配方来源）
# ------------------------------------------------------------
# 为什么要把这段从 YAML 里抽出来：
#   .config 决定了「要下载哪些源码包」。原先它内联在
#   build-openwrt.yml 的两个步骤里（Generate base .config /
#   Enable required packages）。加入「定时预热 dl 镜像」后，
#   预热任务必须生成**同一份** .config —— 否则会出现
#   「预热任务以为不需要某包 → 镜像里永远没有它 → 每次构建
#     都要回落到慢速第三方源」这种长期隐性的失效。
#   两处各写一份配方必然漂移（本仓库的 chinadns-ng 注释与
#   实现相反，就是同类漂移的实例），故抽成单一脚本。
#
# 用法：
#   cd lede && TARGET=x86_64 sh ../openwrt-build/tools/gen-openwrt-config.sh
#
# 前置条件：
#   - 当前目录是 lede 源码树根
#   - 已执行过 feeds update/install，已复制本地包、已拉取主题与 dnsproxy
#   - .config 不存在（本脚本是追加写，重复执行会写出重复行）
#
# 约束（AGENTS.md §6 第 11 条）：必须 POSIX sh（dash）兼容。
# ============================================================

set -e

TARGET="${TARGET:-x86_64}"

if [ ! -f Makefile ] || [ ! -d include ] || [ ! -d toolchain ]; then
	echo "!!! 当前目录不像 lede 源码树（缺 Makefile / include / toolchain）" >&2
	echo "    请在 lede/ 目录内执行本脚本" >&2
	exit 1
fi

if [ -e .config ]; then
	echo "!!! .config 已存在，本脚本会重复追加，拒绝执行" >&2
	echo "    如确需重建，先删除 .config（不要用本脚本覆盖已有配置）" >&2
	exit 1
fi

# ------------------------------------------------------------------
# 1. 目标平台
# ------------------------------------------------------------------
if [ "$TARGET" = "x86_64" ]; then
	cat >> .config <<EOF
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_DEVICE_generic=y
EOF
else
	echo "请在此处添加其他目标平台的 base 配置"
	exit 1
fi
make defconfig

# ------------------------------------------------------------------
# 2. 启用的包
#
# 这一段决定「make download 要下哪些源码」，因此它同时是
# 「dl 镜像里该有哪些文件」的定义。改动这里之后，下一次
# cache-deps 定时任务才会把新增的源码包补进镜像。
# ------------------------------------------------------------------

# SSR-Plus 相关
echo "CONFIG_PACKAGE_luci-app-ssr-plus=y" >> .config
echo "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Iptables_Transparent_Proxy=y" >> .config
echo "# CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Nftables_Transparent_Proxy is not set" >> .config
echo "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Xray=y" >> .config
echo "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_ChinaDNS_NG=y" >> .config
echo "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_MosDNS=y" >> .config
echo "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Shadow_TLS=y" >> .config
echo "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Kcptun=y" >> .config
echo "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_NaiveProxy=y" >> .config
echo "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Shadowsocks_Simple_Obfs=y" >> .config
echo "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Shadowsocks_V2ray_Plugin=y" >> .config
echo "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_ShadowsocksR_Libev_Client=y" >> .config
echo "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_ShadowsocksR_Libev_Server=y" >> .config

# 启用 trafficctl 及其中文语言包
# i18n 包名由 luci.mk 推导，不是「luci-i18n-<PKG_NAME>-<lang>」：
#   LUCI_NAME   = 目录名            = luci-app-trafficctl
#   LUCI_TYPE   = 第 2 段           = app
#   LUCI_BASENAME = patsubst luci-app-%,%,LUCI_NAME = trafficctl
#   LuciTranslation 生成 Package/luci-i18n-$(LUCI_BASENAME)-zh-cn
# 故正确符号为 luci-i18n-trafficctl-zh-cn。
# 原写 luci-i18n-luci-app-trafficctl-zh-cn 从不匹配任何符号，
# 被 confdata.c 静默忽略 → 中文包实际从未编入（本次修正）。
echo "CONFIG_PACKAGE_luci-app-trafficctl=y" >> .config
echo "CONFIG_PACKAGE_luci-i18n-trafficctl-zh-cn=y" >> .config

# 启用 dnschain 控制页面及其中文语言包（v0.9.0）
# 包名推导规则同 trafficctl：LUCI_BASENAME=dnschain
#   → 语言包符号为 luci-i18n-dnschain-zh-cn
echo "CONFIG_PACKAGE_luci-app-dnschain=y" >> .config
echo "CONFIG_PACKAGE_luci-i18n-dnschain-zh-cn=y" >> .config

# chinadns-ng：由 SSR-Plus 的 INCLUDE_ChinaDNS_NG 带入，这里显式再声明一次，
# 避免 SSR-Plus 的 INCLUDE 开关将来被关掉时静默失去该二进制。
#
# ⚠️ 注意：v0.10.0 起 dnschain 框架**已不再依赖** chinadns-ng
# （框架改用双 dnsproxy 实例，见 docs/adr/0005-remove-chinadns-ng.md）。
# 保留这一行的唯一理由是「SSR-Plus 侧仍会用到它」，不是「框架需要它」。
# 旧注释写成「dnschain 运行时依赖」，与实现意图相反，已按实况更正。
echo "CONFIG_PACKAGE_chinadns-ng=y" >> .config

# ── LuCI 主题：shadcn 为默认 ────────────────────────────────
#
# 只写 =y 不够：LuCI 的默认主题由 luci.main.mediaurlbase 决定，
# 而 lede 默认把它指向 bootstrap。两者并存时若 mediaurlbase
# 仍指向 bootstrap，shadcn 装了也看不到。故需要：
#   (a) shadcn =y
#   (b) 默认值在 uci-defaults 里无条件写（见 99-zzz-luci-theme-shadcn）
#
# ⚠️ **不要试图关掉 bootstrap**（v0.9.1 首次构建踩过）：
# lede 的 collections/luci/Makefile（标准 LuCI 集合包）里有
#   LUCI_DEPENDS:=+uhttpd ... +luci-mod-admin-full +luci-theme-bootstrap ...
# 即它**硬依赖** bootstrap。写 `# CONFIG_PACKAGE_luci-theme-bootstrap
# is not set` 会被下一条 make defconfig 的依赖求解再次选回 =y，
# 于是断言 `bootstrap 仍被启用` 失败，构建中止
# （run 39549176947 就是这样挂的）。
#
# 正确的做法是**保留 bootstrap 但切换默认**：
# 代价只是固件多约 300KB，换来的是可回退 ——
# 万一 shadcn 在真机上有兼容问题，把 mediaurlbase 改回
# /luci-static/bootstrap 即可，不需要重新编译。
echo "CONFIG_PACKAGE_luci-theme-shadcn=y" >> .config
# 其余非默认主题仍可关（它们不在集合包的依赖里）
for t in material openwrt openwrt-2020 argon design; do
	echo "# CONFIG_PACKAGE_luci-theme-$t is not set" >> .config
done

# ALL_DOH: dnsproxy + luci-app-dnsproxy + CA 证书（https-dns-proxy 已彻底移除）
# 二进制来自 helloworld feed(0.83.0)，init/config 来自 openwrt-build/files
echo "CONFIG_PACKAGE_dnsproxy=y" >> .config
echo "CONFIG_PACKAGE_luci-app-dnsproxy=y" >> .config
echo "CONFIG_PACKAGE_ca-bundle=y" >> .config
echo "CONFIG_PACKAGE_ca-certificates=y" >> .config

# === 游戏网络优化内核模块 ===
# TCP BBR 拥塞控制
echo "CONFIG_PACKAGE_kmod-tcp-bbr=y" >> .config
# Fullcone NAT (游戏 UDP NAT 穿透)
echo "CONFIG_PACKAGE_iptables-mod-fullconenat=y" >> .config

# === SQM / cake 上行整形（控制 50Mbps 上行瓶颈的排队时延）===
# 实测现固件缺 tc 与 sch_cake.ko，导致 pppoe-wan 为 noqueue、无任何队列管理。
# sqm-scripts 来自 coolsnowwolf/packages feed（v1.6.0 依赖 iptables 而非
# nftables，与本固件 fw3/iptables 后端匹配）；tc 来自 iproute2 的 tc-tiny
# （默认变体，提供 /sbin/tc）；kmod-sched-core 为 tc 的依赖。
echo "CONFIG_PACKAGE_sqm-scripts=y" >> .config
echo "CONFIG_PACKAGE_luci-app-sqm=y" >> .config
echo "CONFIG_PACKAGE_kmod-sched-cake=y" >> .config
echo "CONFIG_PACKAGE_kmod-ifb=y" >> .config
echo "CONFIG_PACKAGE_kmod-sched-core=y" >> .config
echo "CONFIG_PACKAGE_tc-tiny=y" >> .config

# === luci-app-trafficctl 的显式依赖 ===
# 上游 1.21.4 的 LUCI_DEPENDS 为
#   +conntrack +luci-base +rpcd +curl +tc +iw +hostapd-utils
#
# 本仓库已在 package/luci-app-trafficctl/Makefile 里**去掉
# +hostapd-utils**（见该文件的注释）。原因：hostapd-utils 在 lede 中
# 声明为 `DEPENDS:=@<某个 hostapd/wpad 变体>` + `VARIANT:=*`，
# 而本目标是 x86_64 无 WiFi 硬件 → 该符号永远不可满足 →
# 依赖求解把 luci-app-trafficctl **整包**判定为不可选，连带
# luci-i18n-trafficctl-zh-cn（DEPENDS:=$(PKG_NAME)）一起从 .config
# 消失。症状是构建不报错、界面变英文、i18n 断言失败。
#
# 这里仍然显式写出 iw 与 conntrack：它们真实存在且可用
# （conntrack 实测 opkg 提供 1.4.7-1；iw 见 log 中的 OK 行），
# 显式声明可避免「依赖靠自动解析、顺序一变就丢」。
# hostapd-utils 不再写入 —— 本目标无 WiFi，且它已不是依赖项。
echo "CONFIG_PACKAGE_iw=y" >> .config
echo "CONFIG_PACKAGE_conntrack=y" >> .config

# === 显式排除不用的文件服务 ===
# 实测这两个服务对用户无用：vsftpd 监听 0.0.0.0:21 但无实际用途；
# ksmbd 未配置任何 share（仅 globals），445 端口空转。
# 注意: 必须在 make defconfig 之前写入，否则依赖解析会把它们重新选上。
echo "# CONFIG_PACKAGE_vsftpd is not set" >> .config
echo "# CONFIG_PACKAGE_luci-app-vsftpd is not set" >> .config
echo "# CONFIG_PACKAGE_luci-i18n-vsftpd-zh-cn is not set" >> .config
echo "# CONFIG_PACKAGE_ksmbd-server is not set" >> .config
echo "# CONFIG_PACKAGE_luci-app-ksmbd is not set" >> .config
echo "# CONFIG_PACKAGE_luci-i18n-ksmbd-zh-cn is not set" >> .config
echo "# CONFIG_PACKAGE_autosamba is not set" >> .config

make defconfig

echo ">>> .config 生成完成（TARGET=$TARGET）"
echo "    行数: $(wc -l < .config)"
echo "    =y 符号数: $(grep -c '=y$' .config || true)"
