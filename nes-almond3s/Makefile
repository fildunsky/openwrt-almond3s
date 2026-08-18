include $(TOPDIR)/rules.mk

PKG_NAME:=nes-almond3s
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0 AND GPL-2.0-or-later
PKG_LICENSE_FILES:=src/LICENSE src/LICENSE.quicknes

# Цель по умолчанию собирает с -Os и в сжатом наборе инструкций MIPS16 - худшее
# сочетание для интерпретатора 6502, который здесь и есть горячий код. Замер по
# числу исполненных инструкций: один только MIPS16 стоит +24%, а вместе с -Os
# против -O3 набегает треть. Место нам неважно, скорость важна.
PKG_BUILD_FLAGS:=no-mips16

include $(INCLUDE_DIR)/package.mk

define Package/nes-almond3s
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=NES emulator for the Securifi Almond 3S display
  DEPENDS:=@TARGET_ramips_mt7621 +kmod-lcd-almond3s +libstdcpp
endef

define Package/nes-almond3s/description
 InfoNES (https://github.com/jay-kumogata/InfoNES, Apache-2.0) with a platform
 layer for the Almond 3S: the frame goes straight to /dev/lcd, the 256x240 NES
 screen is centred on the 320x240 panel and the side margins carry on-screen
 buttons. Input comes from the touchscreen or a USB keyboard.
 Game images are not included; put .nes files into /etc/almond3s/roms and pick
 them in the Games page of lcd-ui-almond3s.
endef

# -fcommon: ядро InfoNES объявляет глобалы в заголовках без extern, а gcc 10+
# собирает с -fno-common и падает на многократном определении.
# Статическая libstdc++: тянуть ради этого библиотеку в образ смысла нет.
define Build/Compile
	$(TARGET_CXX) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-O3 -mtune=1004kc -funroll-loops \
		-fcommon -w -I$(PKG_BUILD_DIR) -I$(PKG_BUILD_DIR)/mapper \
		-static-libstdc++ -static-libgcc \
		-o $(PKG_BUILD_DIR)/nes \
		$(PKG_BUILD_DIR)/InfoNES.cpp \
		$(PKG_BUILD_DIR)/InfoNES_Mapper.cpp \
		$(PKG_BUILD_DIR)/InfoNES_pAPU.cpp \
		$(PKG_BUILD_DIR)/K6502.cpp \
		$(PKG_BUILD_DIR)/core_infones.cpp \
		$(PKG_BUILD_DIR)/almond_platform.cpp \
		$(PKG_BUILD_DIR)/almond_pad.cpp
	$(TARGET_CXX) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -Os -w \
		-o $(PKG_BUILD_DIR)/keygrab $(PKG_BUILD_DIR)/keygrab.cpp
	$(TARGET_CXX) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-O3 -mtune=1004kc -funroll-loops -D_GNU_SOURCE -DNO_UNALIGNED_ACCESS \
		-fno-exceptions -fno-rtti -w \
		-I$(PKG_BUILD_DIR) -I$(PKG_BUILD_DIR)/nes_emu \
		-nostdlib++ -static-libgcc -lpthread \
		-o $(PKG_BUILD_DIR)/nes-quick \
		$(PKG_BUILD_DIR)/nes_emu/*.cpp \
		$(PKG_BUILD_DIR)/core_quicknes.cpp \
		$(PKG_BUILD_DIR)/almond_platform.cpp \
		$(PKG_BUILD_DIR)/almond_cxx.cpp \
		$(PKG_BUILD_DIR)/almond_pad.cpp
endef

define Package/nes-almond3s/install
	$(INSTALL_DIR) $(1)/usr/libexec/almond3s
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/nes $(1)/usr/libexec/almond3s/nes
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/nes-quick $(1)/usr/libexec/almond3s/nes-quick
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/keygrab $(1)/usr/libexec/almond3s/keygrab
	$(INSTALL_DIR) $(1)/etc/almond3s/roms
endef

$(eval $(call BuildPackage,nes-almond3s))
