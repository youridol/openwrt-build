#
# Copyright (C) 2026 openwrt-build
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-dnschain
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=openwrt-build

LUCI_TITLE:=LuCI support for DNS Chain framework
# 注意: 不依赖 dnschain 包 —— 本框架的 init/config/脚本全部由
# files/ overlay 提供（不是 opkg 包），故没有可依赖的包名。
# 若写成 +dnschain，kconfig 会因符号不存在把整包判为不可选
# （参考 trafficctl 的 +hostapd-utils 事故，AGENTS §3）。
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

define Package/luci-app-dnschain
  $(call Package/luci/webtemplate)
  TITLE:=$(LUCI_TITLE)
  DEPENDS:=$(LUCI_DEPENDS)
  PKGARCH:=$(LUCI_PKGARCH)
endef

define Package/luci-app-dnschain/description
 DNS 链路框架控制页面（网络 → DNS 链路）。
 设计依据：docs/adr/0003-dns-chain-framework.md
 运行时组件（init/config/脚本）由 files/ overlay 提供。
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
