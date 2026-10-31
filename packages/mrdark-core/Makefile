#
# mrdark-core - automated EAPOL handshake capture core (lab tool)
#
include $(TOPDIR)/rules.mk

PKG_NAME:=mrdark-core
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=Mr.Darkair

include $(INCLUDE_DIR)/package.mk

define Package/mrdark-core
  SECTION:=utils
  CATEGORY:=Utilities
  SUBMENU:=Wireless
  TITLE:=mrdark core - automated EAPOL capture (lab)
  DEPENDS:=+aircrack-ng +tcpdump +iw +ucode +ucode-mod-fs +uci
  # shell/ucode only: the same APK works on every OpenWrt 25 architecture
  PKGARCH:=all
endef

define Package/mrdark-core/description
 mrdark-core drives a single 2.4 GHz radio in monitor mode, performs a
 controlled deauth + capture cycle per selected BSSID, validates the captured
 802.11 4-way handshake (M1..M4 pairing) and stores the artefacts. Intended
 for authorised laboratory testing only. Runtime state lives in /tmp, only
 verified artefacts are written to /root/cap.
endef

define Package/mrdark-core/conffiles
/etc/config/mrdark
endef

# Nothing to compile: the package ships shell/ucode files only, and they are
# installed verbatim from ./files by Package/mrdark-core/install.  Without this
# override Build/Compile/Default would run "make -C $(PKG_BUILD_DIR)" in an
# empty directory and fail with "No targets specified and no makefile found".
define Build/Compile
endef

define Package/mrdark-core/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/libexec/mrdark
	$(INSTALL_CONF) ./files/etc/config/mrdark $(1)/etc/config/mrdark
	$(INSTALL_BIN) ./files/etc/init.d/mrdark $(1)/etc/init.d/mrdark
	$(INSTALL_BIN) ./files/etc/uci-defaults/90_mrdark $(1)/etc/uci-defaults/90_mrdark
	$(INSTALL_BIN) ./files/usr/bin/mrdark $(1)/usr/bin/mrdark
	$(INSTALL_BIN) ./files/usr/libexec/mrdark/lib.sh $(1)/usr/libexec/mrdark/lib.sh
	$(INSTALL_BIN) ./files/usr/libexec/mrdark/worker.sh $(1)/usr/libexec/mrdark/worker.sh
	$(INSTALL_BIN) ./files/usr/libexec/mrdark/scan.sh $(1)/usr/libexec/mrdark/scan.sh
	$(INSTALL_BIN) ./files/usr/libexec/mrdark/attempt.sh $(1)/usr/libexec/mrdark/attempt.sh
	$(INSTALL_BIN) ./files/usr/libexec/mrdark/archive.sh $(1)/usr/libexec/mrdark/archive.sh
	$(INSTALL_BIN) ./files/usr/libexec/mrdark/cleanup.sh $(1)/usr/libexec/mrdark/cleanup.sh
	$(INSTALL_BIN) ./files/usr/libexec/mrdark/radio.sh $(1)/usr/libexec/mrdark/radio.sh
	$(INSTALL_BIN) ./files/usr/libexec/mrdark/status.sh $(1)/usr/libexec/mrdark/status.sh
	$(INSTALL_BIN) ./files/usr/libexec/mrdark/mrdark-verify $(1)/usr/libexec/mrdark/mrdark-verify
	$(INSTALL_BIN) ./files/usr/libexec/mrdark/mrdark-status.uc $(1)/usr/libexec/mrdark/mrdark-status.uc
	$(INSTALL_BIN) ./files/usr/libexec/mrdark/mrdark-net.uc $(1)/usr/libexec/mrdark/mrdark-net.uc
endef

$(eval $(call BuildPackage,mrdark-core))
