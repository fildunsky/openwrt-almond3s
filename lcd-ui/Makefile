include $(TOPDIR)/rules.mk

PKG_NAME:=lcd-ui
PKG_RELEASE:=17
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/lcd-ui
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=LCD dashboard for Securifi Almond 3S
  DEPENDS:=@TARGET_ramips_mt7621 +kmod-lcd-almond3s +ucode +ucode-mod-fs \
	+ucode-mod-socket +ucode-mod-ubus +ucode-mod-uci +ucode-mod-uloop +qrencode
endef

define Package/lcd-ui/description
 Userspace stack for the Almond 3S display: lcd_render draws into /dev/lcd on
 behalf of clients on a unix socket, touch_poll latches SX8650 events,
 data_collector gathers LTE/WiFi/VPN/battery stats and lcd_ui.uc drives the UI.
 lcdshot dumps the framebuffer as a PPM image for debugging the layout.
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/lcd_render $(PKG_BUILD_DIR)/lcd_render.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/touch_poll $(PKG_BUILD_DIR)/touch_poll.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/data_collector $(PKG_BUILD_DIR)/data_collector.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/lcdshot $(PKG_BUILD_DIR)/lcdshot.c
endef

define Package/lcd-ui/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/lcd_render $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/touch_poll $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/data_collector $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/lcdshot $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/lcd_ui.uc $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/lcd_ui.init $(1)/etc/init.d/lcd_ui
	$(INSTALL_DIR) $(1)/etc/lcd/scripts
	$(INSTALL_BIN) ./files/weather_fetch.sh $(1)/etc/lcd/scripts/weather_fetch.sh
	$(INSTALL_BIN) ./files/svcping.sh $(1)/etc/lcd/scripts/svcping.sh
	$(INSTALL_BIN) ./files/screen.sh $(1)/etc/lcd/scripts/screen.sh
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/lcd.config $(1)/etc/config/lcd
endef

define Package/lcd-ui/conffiles
/etc/config/lcd
endef

define Package/lcd-ui/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
grep -q weather_fetch /etc/crontabs/root 2>/dev/null || \
	echo "*/15 * * * * /etc/lcd/scripts/weather_fetch.sh" >> /etc/crontabs/root
grep -q svcping /etc/crontabs/root 2>/dev/null || \
	echo "*/10 * * * * /etc/lcd/scripts/svcping.sh" >> /etc/crontabs/root
/etc/init.d/cron reload >/dev/null 2>&1
/etc/lcd/scripts/weather_fetch.sh >/dev/null 2>&1 &
exit 0
endef

$(eval $(call BuildPackage,lcd-ui))
