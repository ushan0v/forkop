include $(TOPDIR)/rules.mk

PKG_NAME:=forkop

FORKOP_SOURCE_VERSION:=$(or $(FORKOP_PACKAGE_VERSION),$(FORKOP_VERSION))
FORKOP_HAS_RELEASE_VERSION:=$(if $(filter dev,$(FORKOP_SOURCE_VERSION)),,$(FORKOP_SOURCE_VERSION))
FORKOP_COMPILED_VERSION:=$(if $(FORKOP_HAS_RELEASE_VERSION),$(FORKOP_SOURCE_VERSION),$(or $(FORKOP_SOURCE_VERSION),dev))
FORKOP_RELEASE_VERSION_VALID:=$(if $(FORKOP_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(FORKOP_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' && printf '1'),1)

ifeq ($(FORKOP_RELEASE_VERSION_VALID),)
$(error FORKOP_PACKAGE_VERSION and FORKOP_VERSION must use x.y.z format)
endif

PKG_VERSION:=$(or $(FORKOP_HAS_RELEASE_VERSION),0.0.0)
PKG_RELEASE:=

PKG_MAINTAINER:=ushan0v <ushan0v@users.noreply.github.com>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/forkop
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+ca-bundle +kmod-inet-diag +kmod-netlink-diag +kmod-tun +curl +ucode +ucode-mod-fs +ucode-mod-uci +kmod-nft-tproxy +coreutils-base64 +coreutils-sort +bind-dig +nftables +kmod-nft-nat +ip-full
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2
	TITLE:=Forkop backend service
	URL:=https://github.com/ushan0v/forkop
	PKGARCH:=all
endef

define Package/forkop/description
	Rule-based Forkop backend with hybrid sing-box + zapret orchestration
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/forkop/prerm
#!/usr/bin/ucode

if (getenv("IPKG_INSTROOT") == null || getenv("IPKG_INSTROOT") == "")
	system("/usr/bin/forkop package_prerm >/dev/null 2>&1");

exit(0);
endef

define Package/forkop/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0
FORKOP_LIB=/usr/lib/forkop ucode -L /usr/lib/forkop /usr/lib/forkop/config/migration.uc migrate
endef

define Package/forkop/conffiles
/etc/config/forkop
endef

define Package/forkop/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/forkop $(1)/etc/init.d/forkop

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/forkop $(1)/etc/config/forkop

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/forkop $(1)/usr/bin/forkop

	$(INSTALL_DIR) $(1)/usr/lib/forkop
	$(CP) ./files/usr/lib/. $(1)/usr/lib/forkop/

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(FORKOP_COMPILED_VERSION)/g' $(1)/usr/lib/forkop/core/constants.uc
endef

$(eval $(call BuildPackage,forkop))
