#
# Copyright (C) 2026 openwrt-build
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-dnschain
PKG_VERSION:=1.10.0
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
 DNS 分流框架控制页面（服务 → DNS 分流）。
 设计依据：docs/adr/0003-dns-chain-framework.md
           docs/adr/0006-domain-routing-and-reroute.md
 运行时组件（init/config/脚本）由 files/ overlay 提供。
 v0.13.0 起含「域名」tab：自定义国内外域名列表、判定链路图、
 改道状态图与明细表（链路健康探测与自动改道）。
 v0.16.4 起含「分诊结果」：未知目标的试直连/试代理/标 dead 与落库，
 表格带序号、时间戳与 IP 段，已入库的行折叠留档。
 v0.24.0 起含「自动补全」：从客户机实际收发学出域名归属与 IP 段，
 补上数据库覆盖不到的 70%（ADR-0010）。
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
