#
# Copyright (C) 2026 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-i18n-trafficctl-zh-cn
PKG_VERSION:=1.8.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)
PKG_USE_MIPS16:=0

# No PKG_SOURCE_URL — source is an inline .lmo compiled during CI
# make download is therefore a no-op

include $(INCLUDE_DIR)/package.mk

define Package/luci-i18n-trafficctl-zh-cn
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Chinese translation for luci-app-trafficctl
  DEPENDS:=+luci-app-trafficctl +luci-base
  PKGARCH:=all
endef

define Package/luci-i18n-trafficctl-zh-cn/description
  Simplified Chinese language support for Traffic Control LuCI application.
endef

# Pre-compiled .lmo is placed in src/ during CI (compiled from .po via po2lmo)
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(INSTALL_DATA) ./src/trafficctl.zh-cn.lmo $(PKG_BUILD_DIR)/
endef

# No source compilation needed — .lmo is pre-compiled
define Build/Compile
endef

define Package/luci-i18n-trafficctl-zh-cn/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/trafficctl.zh-cn.lmo $(1)/usr/lib/lua/luci/i18n/
endef

$(eval $(call BuildPackage,luci-i18n-trafficctl-zh-cn))
