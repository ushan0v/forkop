include $(TOPDIR)/rules.mk

PKG_NAME:=podkop-plus

PODKOP_RELEASE_VERSION:=$(or $(PODKOP_PACKAGE_VERSION),$(PODKOP_VERSION),dev)
PODKOP_LEGACY_RELEASE:=$(findstring -,$(PODKOP_RELEASE_VERSION))
PODKOP_BASE_VERSION:=$(or $(PODKOP_BASE_VERSION),$(if $(PODKOP_LEGACY_RELEASE),$(word 1,$(subst -, ,$(PODKOP_RELEASE_VERSION))),$(PODKOP_RELEASE_VERSION)))
PODKOP_FORK_RELEASE:=$(or $(PODKOP_FORK_RELEASE),$(if $(PODKOP_LEGACY_RELEASE),$(word 2,$(subst -, ,$(PODKOP_RELEASE_VERSION))),))
PODKOP_COMPILED_VERSION:=$(if $(PODKOP_FORK_RELEASE),$(PODKOP_BASE_VERSION)-$(PODKOP_FORK_RELEASE),$(PODKOP_BASE_VERSION))
PODKOP_SDK_VERSION:=$(if $(filter apk,$(PODKOP_PACKAGE_FORMAT)),$(PODKOP_BASE_VERSION),$(PODKOP_COMPILED_VERSION))
PODKOP_SDK_RELEASE:=$(if $(filter apk,$(PODKOP_PACKAGE_FORMAT)),$(PODKOP_FORK_RELEASE),)

PKG_VERSION:=$(PODKOP_SDK_VERSION)
PKG_RELEASE:=$(PODKOP_SDK_RELEASE)

PKG_MAINTAINER:=ushan0v <ushan0v@users.noreply.github.com>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/podkop-plus
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+sing-box +curl +ucode +ucode-mod-fs +kmod-nft-tproxy +coreutils-base64 +coreutils-sort +bind-dig +nftables +kmod-nft-nat +kmod-nft-offload
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2
	TITLE:=Podkop Plus backend service
	URL:=https://github.com/ushan0v/podkop-plus
	PKGARCH:=all
endef

define Package/podkop-plus/description
	Rule-based Podkop Plus backend with hybrid sing-box + zapret orchestration
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/podkop-plus/preinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0

if [ ! -f /etc/config/podkop-plus ] && [ -f /etc/config/podkop_plus ]; then
	cp /etc/config/podkop_plus /etc/config/podkop-plus || exit 1
	chmod 0644 /etc/config/podkop-plus 2>/dev/null || true
fi

exit 0
endef

define Package/podkop-plus/prerm
#!/bin/sh

grep -q "105 podkopplus" /etc/iproute2/rt_tables && sed -i "/105 podkopplus/d" /etc/iproute2/rt_tables

/etc/init.d/podkop-plus stop >/dev/null 2>&1 || true
/usr/bin/podkop-plus restore_dnsmasq >/dev/null 2>&1 || true
if [ -r /usr/lib/podkop-plus/dnsmasq_failsafe_restore.sh ]; then
	sh /usr/lib/podkop-plus/dnsmasq_failsafe_restore.sh >/dev/null 2>&1 || true
else
	uci -q delete dhcp.podkop_plus >/dev/null 2>&1 || true
	uci -q del_list 'dhcp.@dnsmasq[0].notinterface=br-lan' >/dev/null 2>&1 || true
	uci -q del_list 'dhcp.@dnsmasq[0].server=127.0.0.42' >/dev/null 2>&1 || true
	uci -q set 'dhcp.@dnsmasq[0].noresolv=0' >/dev/null 2>&1 || true
	uci -q set 'dhcp.@dnsmasq[0].cachesize=150' >/dev/null 2>&1 || true
	uci -q commit dhcp >/dev/null 2>&1 || true
	[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
fi

exit 0
endef

define Package/podkop-plus/conffiles
/etc/config/podkop-plus
endef

define Package/podkop-plus/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/podkop $(1)/etc/init.d/podkop-plus

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/podkop $(1)/etc/config/podkop-plus

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/podkop $(1)/usr/bin/podkop-plus

	$(INSTALL_DIR) $(1)/usr/lib/podkop-plus
	$(CP) ./files/usr/lib/* $(1)/usr/lib/podkop-plus/

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PODKOP_COMPILED_VERSION)/g' $(1)/usr/lib/podkop-plus/constants.sh
endef

$(eval $(call BuildPackage,podkop-plus))
