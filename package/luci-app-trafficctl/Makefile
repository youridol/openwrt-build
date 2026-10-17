include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-trafficctl
PKG_VERSION:=1.21.4
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Denis Iusupov <yusdyr@gmail.com>

LUCI_TITLE:=LuCI Traffic Control
LUCI_DESCRIPTION:=Per-device traffic monitoring, rate limiting (nft/iptables), \
 traffic shaping (tc/HTB), internet blocking, and WiFi MAC filtering.

# 【本仓库补丁（相对上游 1.21.4）】去掉 `+hostapd-utils`
#
# 上游在这里写的是：
#   LUCI_DEPENDS:=+conntrack +luci-base +rpcd +curl +tc +iw +hostapd-utils
#
# 其中 hostapd-utils 在 lede 里声明为
#   DEPENDS:=@$(subst $(space),||,$(foreach pkg,$(HOSTAPD_PROVIDERS),PACKAGE_$(pkg)))
#   VARIANT:=*
# 即「只有选中了某个 hostapd/wpad 变体时该符号才存在」。本固件目标是
# **x86_64 且无 WiFi 硬件**（实测路由器上无 /sys/class/ieee80211、无 hostapd/wpad
# 二进制），因此 PACKAGE_hostapd-utils 永远无法满足。
#
# 后果比「装不上这个可选件」严重得多：OpenWrt 的依赖求解会把
# luci-app-trafficctl 判定为不可满足 → 该符号连同它的中文语言包子包
# （LuciTranslation 生成 luci-i18n-trafficctl-zh-cn，DEPENDS:=$(PKG_NAME)）
# **一起从 .config 消失**。表现为构建成功、界面却是英文、且
# `Verify SQM / i18n` 断言以「无任何 trafficctl i18n 符号」失败。
# v0.4.7/v0.4.8 两次构建都栽在这里（v0.4.6 及更早的 Makefile 没有这串依赖，
# 所以从未暴露）。
#
# hostapd_cli 只用于「WiFi 拒绝列表立即生效」，属可选增强：
# root/usr/local/bin/trafficctl-fw.sh 用它之前先做 `command -v hostapd_cli`
# 检测，缺失时回落到 ubus 封禁并在界面提示。本目标无 WiFi，该功能本就不适用。
# 故这里改为**不声明**该依赖；WiFi 路由器若需要可自行 opkg install hostapd-utils。
LUCI_DEPENDS:=+conntrack +luci-base +rpcd +curl +tc +iw
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# Only list files that ship in the package and may be user-edited.
# shapes.json is runtime state created by scripts; it survives sysupgrade via
# root/lib/upgrade/keep.d/ instead.
define Package/$(PKG_NAME)/conffiles
/etc/config/trafficctl
endef

# The config holds the metrics token, so it must not be world-readable before
# the first save from the UI applies the same mode.
#
# rpcd only learns about a plugin when it starts, so without the restart below
# every ubus call lands on "Object not found" (-32000) and the dashboard is
# empty until the router is rebooted. build-ipk.sh and build-apk.sh have always
# done this in their own postinst; this Makefile did not, and the RELEASED
# packages are the ones built from here through the SDK — so the bug only ever
# reached the people installing the published artifacts.
#
# Guarded on IPKG_INSTROOT: when it is set the package is being unpacked into
# an image being built, where there is no running rpcd to talk to.
define Package/$(PKG_NAME)/postinst
#!/bin/sh
chmod 0600 "$${IPKG_INSTROOT}/etc/config/trafficctl" 2>/dev/null || true
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/rpcd restart 2>/dev/null || true
	# 【v0.7.0】Telegram 全链路已移除。升级安装时 opkg 会按旧文件清单
	#   删掉 init.d/脚本，但**不会**动下面三样，因为它们不归包的文件清单管：
	#     · /etc/config/trafficctl 的 config telegram 段（conffile，整份保留）
	#     · /etc/rc.d/S*trafficctl-telegram 开机软链（软链本身在，目标是空）
	#     · /etc/trafficctl/telegram_known.json（在 keep.d 里，跨 sysupgrade 保留）
	#   留着等于把一个已无处可填、也永不生效的 bot token 继续留在盘上。
	#   本段幂等：全新安装时这些都不存在，是空操作。
	if [ -x /etc/init.d/trafficctl-telegram ]; then
		/etc/init.d/trafficctl-telegram stop 2>/dev/null || true
		/etc/init.d/trafficctl-telegram disable 2>/dev/null || true
	fi
	# 正在跑的长轮询进程不归 init.d 管时就杀不掉，故按可执行名单独收一次。
	#   只匹配脚本自身的 exec 名，不用宽泛的 pgrep -f（那会命中本脚本的
	#   命令行文本，属本仓库在「验证纪律」里记过的坑）。
	killall trafficctl-telegram.sh 2>/dev/null || true
	rm -f /etc/rc.d/*trafficctl-telegram 2>/dev/null || true
	rm -f /etc/trafficctl/telegram_known.json 2>/dev/null || true
	if uci -q get trafficctl.telegram >/dev/null 2>&1; then
		uci -q delete trafficctl.telegram
		# log_telegram 是日志分类开关，其分类来源已随 Telegram 消失。
		uci -q delete trafficctl.logging.log_telegram
		uci commit trafficctl 2>/dev/null || true
		logger -t trafficctl "postinst: removed the obsolete Telegram config section (v0.7.0)"
	fi
	logger -t trafficctl "postinst: trafficctl-telegram removed; any bot process stopped"
fi
exit 0
endef

# Fail open on removal. A global internet cut left engaged by a package that is
# going away is a lockout with no UI left to undo it — the drop rule would sit
# in nftables with nothing on the router admitting to owning it.
#
# 【v0.7.0】Telegram 停机也放在这里，而不是 postinst：opkg 的顺序是
#   prerm → 按旧文件清单删除 → postinst。等到 postinst 时 init.d 脚本已经
#   没了，procd 服务也就无从「stop」——而它是 respawn 型，二进制被删后仍可能
#   反复重启。必须在文件还在的这一刻停。
define Package/$(PKG_NAME)/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	if [ -x /usr/local/bin/trafficctl-cut.sh ]; then
		/usr/local/bin/trafficctl-cut.sh release >/dev/null 2>&1 || true
	fi
	if [ -x /etc/init.d/trafficctl-telegram ]; then
		/etc/init.d/trafficctl-telegram stop 2>/dev/null || true
		/etc/init.d/trafficctl-telegram disable 2>/dev/null || true
	fi
fi
exit 0
endef

# call BuildPackage - OpenWrt buildroot will pick up the standard LuCI layout
$(eval $(call BuildPackage,$(PKG_NAME)))
