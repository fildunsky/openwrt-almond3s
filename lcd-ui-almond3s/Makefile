include $(TOPDIR)/rules.mk

PKG_NAME:=lcd-ui-almond3s
PKG_RELEASE:=769
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/lcd-ui-almond3s
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=LCD dashboard for Securifi Almond 3S
  DEPENDS:=@(TARGET_ramips_mt7621||TARGET_cortina) \
	+TARGET_ramips_mt7621:kmod-lcd-almond3s +TARGET_cortina:kmod-lcd-almondplus \
	+libmbedtls +ucode +ucode-mod-fs \
	+ucode-mod-socket +ucode-mod-ubus +ucode-mod-uci +ucode-mod-uloop +qrencode
endef

define Package/lcd-ui-almond3s/description
 Userspace stack for the Almond 3S display: the renderer draws into /dev/lcd on
 behalf of clients on a unix socket, almond3s-lcd latches SX8650 events and
 controls backlight/LED/buzzer, the collector gathers LTE/WiFi/VPN/battery
 stats and ui.uc drives the interface.
 lcdshot dumps the framebuffer as a PPM image for debugging the layout.
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/render $(PKG_BUILD_DIR)/render.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/almond3s-lcd $(PKG_BUILD_DIR)/almond3s-lcd.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/collector $(PKG_BUILD_DIR)/collector.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/lcdshot $(PKG_BUILD_DIR)/lcdshot.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/almond3s-zig $(PKG_BUILD_DIR)/almond3s-zig.c \
		-lmbedcrypto
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/almond3s-mqtt $(PKG_BUILD_DIR)/almond3s-mqtt.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/almond3s-zwave $(PKG_BUILD_DIR)/almond3s-zwave.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-std=c99 -I$(PKG_BUILD_DIR)/vterm/include \
		-o $(PKG_BUILD_DIR)/almond3s-term \
		$(PKG_BUILD_DIR)/almond3s-term.c $(PKG_BUILD_DIR)/vterm/src/*.c \
		-lutil
endef

define Package/lcd-ui-almond3s/install
	# В /usr/bin только то, чем пользуется человек: управляющая утилита и
	# снимок экрана. Остальное - служебное, ему в общем каталоге не место.
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/almond3s-lcd $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/lcdshot $(1)/usr/bin/almond3s-lcdshot
	$(INSTALL_DIR) $(1)/usr/libexec/almond3s
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/render $(1)/usr/libexec/almond3s/render
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/collector $(1)/usr/libexec/almond3s/collector
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/almond3s-term $(1)/usr/libexec/almond3s/almond3s-term
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/almond3s-zig $(1)/usr/libexec/almond3s/almond3s-zig
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/almond3s-zwave $(1)/usr/libexec/almond3s/almond3s-zwave
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/almond3s-mqtt $(1)/usr/libexec/almond3s/almond3s-mqtt
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/ui.uc $(1)/usr/libexec/almond3s/ui.uc
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/almond3s-lcd.init $(1)/etc/init.d/almond3s-lcd
	$(INSTALL_BIN) ./files/almond3s-mqtt.init $(1)/etc/init.d/almond3s-mqtt
	$(INSTALL_DIR) $(1)/etc/almond3s/scripts
	$(INSTALL_BIN) ./files/netfetch.sh $(1)/etc/almond3s/scripts/netfetch.sh
	$(INSTALL_BIN) ./files/zig_join.sh $(1)/etc/almond3s/scripts/zig_join.sh
	$(INSTALL_BIN) ./files/weather_fetch.sh $(1)/etc/almond3s/scripts/weather_fetch.sh
	$(INSTALL_BIN) ./files/almond_update.sh $(1)/etc/almond3s/scripts/almond_update.sh
	$(INSTALL_BIN) ./files/weather_geo.sh $(1)/etc/almond3s/scripts/weather_geo.sh
	$(INSTALL_BIN) ./files/svcping.sh $(1)/etc/almond3s/scripts/svcping.sh
	$(INSTALL_BIN) ./files/screen.sh $(1)/etc/almond3s/scripts/screen.sh
	$(INSTALL_BIN) ./files/night_wifi.sh $(1)/etc/almond3s/scripts/night_wifi.sh
	$(INSTALL_BIN) ./files/reboot.sh $(1)/etc/almond3s/scripts/reboot.sh
	$(INSTALL_BIN) ./files/poweroff.sh $(1)/etc/almond3s/scripts/poweroff.sh
	$(INSTALL_BIN) ./files/lte_reset.sh $(1)/etc/almond3s/scripts/lte_reset.sh
	$(INSTALL_BIN) ./files/alarm_set.sh $(1)/etc/almond3s/scripts/alarm_set.sh
	$(INSTALL_BIN) ./files/alarm_play.sh $(1)/etc/almond3s/scripts/alarm_play.sh
	$(INSTALL_BIN) ./files/alarm_stop.sh $(1)/etc/almond3s/scripts/alarm_stop.sh
	$(INSTALL_BIN) ./files/vpn_clash.sh $(1)/etc/almond3s/scripts/vpn_clash.sh
	$(INSTALL_BIN) ./files/nes_run.sh $(1)/etc/almond3s/scripts/nes_run.sh
	$(INSTALL_DIR) $(1)/etc/almond3s/roms
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/almond3s.config $(1)/etc/config/almond3s
	# Нарисованные в редакторе иконки: кладём в /etc/almond3s/icons, откуда
	# micon_load_custom их подхватывает и перекрывает вшитый пиксель-арт. Как
	# conffiles - переживают апгрейд и правки пользователя.
	$(INSTALL_DIR) $(1)/etc/almond3s/icons
	$(INSTALL_CONF) ./icons-user/*.txt $(1)/etc/almond3s/icons/
endef

define Package/lcd-ui-almond3s/conffiles
/etc/config/almond3s
/etc/almond3s/icons/editor.txt
/etc/almond3s/icons/display.txt
/etc/almond3s/icons/traffic.txt
/etc/almond3s/icons/wifi.txt
/etc/almond3s/icons/eth.txt
endef

define Package/lcd-ui-almond3s/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0

# Демон Zigbee живёт своей сессией и переживает перезапуск службы - это нужно,
# чтобы аппарат не выпадал из сети на время игры. Но обновление он пережить не
# должен, иначе останется работать старым кодом: снимаем его здесь, обратно
# поднимет сторож в ui.uc.
killall almond3s-zig 2>/dev/null

# Переносим настройки со старых имён: пакет раньше звался lcd-ui и держал
# конфиг в /etc/config/lcd, а данные - в /etc/lcd. Без переноса пользователь
# молча теряет яркость, поворот, город и калибровку батареи.
[ -f /etc/config/lcd ] && [ ! -f /etc/config/almond3s ] && \
	mv /etc/config/lcd /etc/config/almond3s
for _f in bat_cal bat_log.txt; do
	[ -f "/etc/lcd/$$_f" ] && [ ! -f "/etc/almond3s/$$_f" ] && \
		mv "/etc/lcd/$$_f" "/etc/almond3s/$$_f"
done
sed -i 's|/etc/lcd/scripts/|/etc/almond3s/scripts/|g' /etc/crontabs/root 2>/dev/null
rm -rf /etc/lcd/scripts 2>/dev/null
grep -q weather_fetch /etc/crontabs/root 2>/dev/null || \
	echo "*/15 * * * * /etc/almond3s/scripts/weather_fetch.sh" >> /etc/crontabs/root
grep -q svcping /etc/crontabs/root 2>/dev/null || \
	echo "*/10 * * * * /etc/almond3s/scripts/svcping.sh" >> /etc/crontabs/root
/etc/init.d/cron reload >/dev/null 2>&1
/etc/almond3s/scripts/weather_fetch.sh >/dev/null 2>&1 &
# Заводим секцию будильника, если её нет: config - conffile, при апгрейде новая
# секция не подмешивается в существующий пользовательский конфиг (уходит в
# .apk-new), поэтому создаём её здесь с дефолтами.
if ! uci -q get almond3s.mqtt >/dev/null 2>&1; then
	uci set almond3s.mqtt=mqtt
	uci set almond3s.mqtt.enabled='0'
	uci set almond3s.mqtt.host=''
	uci set almond3s.mqtt.port='1883'
	uci set almond3s.mqtt.prefix='almond3s'
	uci set almond3s.mqtt.period='60'
	uci set almond3s.mqtt.control='off'
	uci set almond3s.mqtt.homed_prefix='homed'
	uci set almond3s.mqtt.retain='0'
	uci commit almond3s
fi
if ! uci -q get almond3s.alarm >/dev/null 2>&1; then
	uci set almond3s.alarm=alarm
	uci set almond3s.alarm.enabled='0'
	uci set almond3s.alarm.hour='7'
	uci set almond3s.alarm.minute='0'
	uci set almond3s.alarm.sound='tone'
	uci set almond3s.alarm.sound_args='988 130 988 267 838 130 838 535'
	uci set almond3s.alarm.sound_label='звонок'
	uci set almond3s.alarm.volume='1'
	uci set almond3s.alarm.mode='once'
	uci set almond3s.alarm.repeat='0'
	uci commit almond3s
fi
# Синхронизируем cron-запись будильника с сохранённым конфигом (ставит запись,
# если он включён; убирает - если нет). Так настройка переживает апгрейд.
[ -x /etc/almond3s/scripts/alarm_set.sh ] && /etc/almond3s/scripts/alarm_set.sh >/dev/null 2>&1
# Перезапускаем службу: без этого в памяти остаётся старая, файлы уже
# новые, а на экране прежнее поведение - выглядит как «обновление не приехало».
[ -x /etc/init.d/almond3s-lcd ] && /etc/init.d/almond3s-lcd restart >/dev/null 2>&1
exit 0
endef

$(eval $(call BuildPackage,lcd-ui-almond3s))
