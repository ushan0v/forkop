include $(TOPDIR)/rules.mk

PKG_NAME:=nexroute

NEXROUTE_SOURCE_VERSION:=$(or $(NEXROUTE_PACKAGE_VERSION),$(NEXROUTE_VERSION))
NEXROUTE_HAS_RELEASE_VERSION:=$(if $(filter dev,$(NEXROUTE_SOURCE_VERSION)),,$(NEXROUTE_SOURCE_VERSION))
NEXROUTE_COMPILED_VERSION:=$(if $(NEXROUTE_HAS_RELEASE_VERSION),$(NEXROUTE_SOURCE_VERSION),$(or $(NEXROUTE_SOURCE_VERSION),dev))
NEXROUTE_RELEASE_VERSION_VALID:=$(if $(NEXROUTE_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(NEXROUTE_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' && printf '1'),1)

ifeq ($(NEXROUTE_RELEASE_VERSION_VALID),)
$(error NEXROUTE_PACKAGE_VERSION and NEXROUTE_VERSION must use x.y.z format)
endif

PKG_VERSION:=$(or $(NEXROUTE_HAS_RELEASE_VERSION),0.0.0)
PKG_RELEASE:=

PKG_MAINTAINER:=filippxda26 <filippxda26@users.noreply.github.com>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/nexroute
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+ca-bundle +kmod-inet-diag +kmod-netlink-diag +kmod-tun +curl +ucode +ucode-mod-fs +ucode-mod-uci +kmod-nft-tproxy +coreutils-base64 +bind-dig +nftables +kmod-nft-nat +ip-full
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2
	TITLE:=Nexroute backend service
	URL:=https://github.com/filippxda26/Nexroute
	PKGARCH:=all
endef

define Package/nexroute/description
	Rule-based Nexroute backend with hybrid sing-box + zapret orchestration
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/nexroute/prerm
#!/usr/bin/ucode

if (getenv("IPKG_INSTROOT") == null || getenv("IPKG_INSTROOT") == "")
	system("/usr/bin/nexroute package_prerm " + (ARGV[0] || "") + " >/dev/null 2>&1");

exit(0);
endef

define Package/nexroute/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0
NEXROUTE_LIB=/usr/lib/nexroute ucode -L /usr/lib/nexroute /usr/lib/nexroute/config/migration.uc migrate || exit $$?
/usr/bin/nexroute package_postinst
endef

define Package/nexroute/conffiles
/etc/config/nexroute
endef

define Package/nexroute/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/nexroute $(1)/etc/init.d/nexroute

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/nexroute $(1)/etc/config/nexroute

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/nexroute $(1)/usr/bin/nexroute

	$(INSTALL_DIR) $(1)/usr/lib/nexroute
	$(CP) ./files/usr/lib/. $(1)/usr/lib/nexroute/

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(NEXROUTE_COMPILED_VERSION)/g' $(1)/usr/lib/nexroute/core/constants.uc
endef

$(eval $(call BuildPackage,nexroute))
