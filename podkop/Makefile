include $(TOPDIR)/rules.mk

PKG_NAME:=podkop-plus

PODKOP_SOURCE_VERSION:=$(or $(PODKOP_PACKAGE_VERSION),$(PODKOP_VERSION))
PODKOP_HAS_RELEASE_VERSION:=$(if $(filter dev,$(PODKOP_SOURCE_VERSION)),,$(PODKOP_SOURCE_VERSION))
PODKOP_IS_APK:=$(or $(filter apk,$(PODKOP_PACKAGE_FORMAT)),$(CONFIG_USE_APK))
PODKOP_RELEASE_VERSION:=$(or $(PODKOP_HAS_RELEASE_VERSION),0.0.0)
PODKOP_LEGACY_RELEASE:=$(findstring -,$(PODKOP_RELEASE_VERSION))
PODKOP_BASE_VERSION:=$(or $(PODKOP_BASE_VERSION),$(if $(PODKOP_LEGACY_RELEASE),$(word 1,$(subst -, ,$(PODKOP_RELEASE_VERSION))),$(PODKOP_RELEASE_VERSION)))
PODKOP_FORK_RELEASE:=$(or $(PODKOP_FORK_RELEASE),$(if $(PODKOP_LEGACY_RELEASE),$(word 2,$(subst -, ,$(PODKOP_RELEASE_VERSION))),))
PODKOP_COMPILED_VERSION:=$(if $(PODKOP_HAS_RELEASE_VERSION),$(if $(PODKOP_FORK_RELEASE),$(PODKOP_BASE_VERSION)-$(PODKOP_FORK_RELEASE),$(PODKOP_BASE_VERSION)),$(or $(PODKOP_SOURCE_VERSION),dev))
PODKOP_SDK_VERSION:=$(if $(PODKOP_HAS_RELEASE_VERSION),$(if $(PODKOP_IS_APK),$(PODKOP_BASE_VERSION),$(PODKOP_COMPILED_VERSION)),$(PODKOP_BASE_VERSION))
PODKOP_SDK_RELEASE:=$(if $(PODKOP_IS_APK),$(PODKOP_FORK_RELEASE),)

PKG_VERSION:=$(PODKOP_SDK_VERSION)
PKG_RELEASE:=$(PODKOP_SDK_RELEASE)

PKG_MAINTAINER:=ushan0v <ushan0v@users.noreply.github.com>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/podkop-plus
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+ca-bundle +kmod-inet-diag +kmod-netlink-diag +kmod-tun +curl +ucode +ucode-mod-fs +kmod-nft-tproxy +coreutils-base64 +coreutils-sort +bind-dig +nftables +kmod-nft-nat +kmod-nft-offload
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
podkop_dont_touch_dhcp="$$(uci -q get 'podkop-plus.settings.dont_touch_dhcp' 2>/dev/null)"
case "$$podkop_dont_touch_dhcp" in
	1|true|yes|on)
		;;
	*)
		/usr/bin/podkop-plus restore_dnsmasq >/dev/null 2>&1 || true
		if [ -r /usr/lib/podkop-plus/dnsmasq_failsafe_restore.sh ]; then
			sh /usr/lib/podkop-plus/dnsmasq_failsafe_restore.sh >/dev/null 2>&1 || true
		else
			podkop_backup_notinterfaces="$$(uci -q get 'dhcp.@dnsmasq[0].podkop_notinterface' 2>/dev/null)"
			uci -q delete dhcp.podkop_plus >/dev/null 2>&1 || true
			if [ -n "$$podkop_backup_notinterfaces" ]; then
				uci -q delete 'dhcp.@dnsmasq[0].notinterface' >/dev/null 2>&1 || true
				for podkop_value in $$podkop_backup_notinterfaces; do
					uci -q add_list "dhcp.@dnsmasq[0].notinterface=$$podkop_value" >/dev/null 2>&1 || true
				done
			else
				uci -q del_list 'dhcp.@dnsmasq[0].notinterface=br-lan' >/dev/null 2>&1 || true
			fi
			uci -q delete 'dhcp.@dnsmasq[0].podkop_notinterface' >/dev/null 2>&1 || true
			podkop_backup_servers="$$(uci -q get 'dhcp.@dnsmasq[0].podkop_server' 2>/dev/null)"
			if [ -n "$$podkop_backup_servers" ]; then
				uci -q delete 'dhcp.@dnsmasq[0].server' >/dev/null 2>&1 || true
				for podkop_value in $$podkop_backup_servers; do
					uci -q add_list "dhcp.@dnsmasq[0].server=$$podkop_value" >/dev/null 2>&1 || true
				done
			else
				uci -q del_list 'dhcp.@dnsmasq[0].server=127.0.0.42' >/dev/null 2>&1 || true
			fi
			uci -q delete 'dhcp.@dnsmasq[0].podkop_server' >/dev/null 2>&1 || true
			podkop_noresolv="$$(uci -q get 'dhcp.@dnsmasq[0].podkop_noresolv' 2>/dev/null)"
			if [ -n "$$podkop_noresolv" ]; then
				uci -q set "dhcp.@dnsmasq[0].noresolv=$$podkop_noresolv" >/dev/null 2>&1 || true
			else
				uci -q set 'dhcp.@dnsmasq[0].noresolv=0' >/dev/null 2>&1 || true
			fi
			uci -q delete 'dhcp.@dnsmasq[0].podkop_noresolv' >/dev/null 2>&1 || true
			podkop_cachesize="$$(uci -q get 'dhcp.@dnsmasq[0].podkop_cachesize' 2>/dev/null)"
			if [ -n "$$podkop_cachesize" ]; then
				uci -q set "dhcp.@dnsmasq[0].cachesize=$$podkop_cachesize" >/dev/null 2>&1 || true
			else
				uci -q set 'dhcp.@dnsmasq[0].cachesize=150' >/dev/null 2>&1 || true
			fi
			uci -q delete 'dhcp.@dnsmasq[0].podkop_cachesize' >/dev/null 2>&1 || true
			uci -q commit dhcp >/dev/null 2>&1 || true
			[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
		fi
		;;
esac

if [ -r /etc/init.d/sing-box ] && grep -q "Podkop Plus managed sing-box service for binary variants" /etc/init.d/sing-box 2>/dev/null; then
	/etc/init.d/sing-box stop >/dev/null 2>&1 || true
	/etc/init.d/sing-box disable >/dev/null 2>&1 || true
	rm -f /etc/init.d/sing-box /usr/bin/sing-box /usr/lib/libcronet.so
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
