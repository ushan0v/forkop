include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-nexroute

NEXROUTE_SOURCE_VERSION:=$(or $(NEXROUTE_PACKAGE_VERSION),$(NEXROUTE_VERSION))
NEXROUTE_HAS_RELEASE_VERSION:=$(if $(filter dev,$(NEXROUTE_SOURCE_VERSION)),,$(NEXROUTE_SOURCE_VERSION))
NEXROUTE_COMPILED_VERSION:=$(if $(NEXROUTE_HAS_RELEASE_VERSION),$(NEXROUTE_SOURCE_VERSION),$(or $(NEXROUTE_SOURCE_VERSION),dev))
NEXROUTE_RELEASE_VERSION_VALID:=$(if $(NEXROUTE_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(NEXROUTE_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' && printf '1'),1)

ifeq ($(NEXROUTE_RELEASE_VERSION_VALID),)
$(error NEXROUTE_PACKAGE_VERSION and NEXROUTE_VERSION must use x.y.z format)
endif

PKG_VERSION:=$(or $(NEXROUTE_HAS_RELEASE_VERSION),0.0.0)
PKG_RELEASE:=
PKG_PO_VERSION:=$(PKG_VERSION)

LUCI_TITLE:=LuCI Nexroute app
LUCI_DEPENDS:=+luci-base +nexroute
LUCI_PKGARCH:=all
LUCI_LANG.ru:=Русский (Russian)
LUCI_LANG.en:=English
LUCI_MAINTAINER:=filippxda26 <filippxda26@users.noreply.github.com>
LUCI_DESCRIPTION:=Rule-based Nexroute LuCI app with hybrid sing-box + zapret orchestration
LUCI_MINIFY_JS:=0

PKG_LICENSE:=GPL-2.0-or-later
LUCI_LANGUAGES:=en ru

define Build/Prepare/$(PKG_NAME)
	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(NEXROUTE_COMPILED_VERSION)/g' $(PKG_BUILD_DIR)/htdocs/luci-static/resources/view/nexroute/main.js
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
