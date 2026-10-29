include $(TOPDIR)/rules.mk

LUCI_TITLE:=mrdark - EAPOL capture control (lab)
LUCI_DESCRIPTION:=LuCI frontend for mrdark-core: scan, pick targets, run the capture job.
LUCI_DEPENDS:=+luci-base +mrdark-core +rpcd-mod-ucode +rpcd-mod-file +ucode-mod-uci
LUCI_PKGARCH:=all
# keep the view exactly as tested; do not depend on host jsmin for this small app
LUCI_MINIFY_JS:=0

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Mr.Darkair
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
