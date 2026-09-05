include $(TOPDIR)/rules.mk

PKG_NAME:=nes-almond3s
PKG_RELEASE:=5
PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=src/LICENSE.quicknes

# Цель по умолчанию собирает с -Os и в сжатом наборе инструкций MIPS16 - худшее
# сочетание для интерпретатора 6502, который здесь и есть горячий код. Замер по
# числу исполненных инструкций: один только MIPS16 стоит +24%, а вместе с -Os
# против -O3 набегает треть. Место нам неважно, скорость важна.
PKG_BUILD_FLAGS:=no-mips16

include $(INCLUDE_DIR)/package.mk

ifeq ($(ARCH),mipsel)
  NES_TUNE:=-mtune=1004kc
else
  NES_TUNE:=
endif

# Almond+ (cortina/arm) — нативная панель 480x320; Almond 3S (mt7621/mipsel) — 320x240.
ifeq ($(ARCH),arm)
  NES_LCD:=-DLCD_W=480 -DLCD_H=320
else
  NES_LCD:=
endif

define Package/nes-almond3s
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=NES emulator for the Securifi Almond 3S display
  DEPENDS:=@(TARGET_ramips_mt7621||TARGET_cortina) +TARGET_ramips_mt7621:kmod-lcd-almond3s +TARGET_cortina:kmod-lcd-almondplus
endef

define Package/nes-almond3s/description
 QuickNES (https://github.com/libretro/QuickNES_Core, GPL-2.0) with a platform
 layer for the Almond 3S: the frame goes straight to /dev/lcd, the 256x240 NES
 screen is centred on the 320x240 panel and the side margins carry on-screen
 buttons. Input comes from the touchscreen, a USB keyboard or a phone browser
 over Wi-Fi.
 Game images are not included; put .nes files into /etc/almond3s/roms and pick
 them in the Games page of lcd-ui-almond3s.
endef

# Без libstdc++ у обоих бинарей: ядру нужны только new и delete, они свои в
# almond_cxx, а keygrab и вовсе чистый C. Иначе пакет требовал бы libstdcpp -
# это лишние ~400 КБ в образе ради ничего.
define Build/Compile
	$(TARGET_CXX) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -Os -w $(NES_LCD) \
		-nostdlib++ -static-libgcc -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables \
		-o $(PKG_BUILD_DIR)/keygrab $(PKG_BUILD_DIR)/keygrab.cpp
	$(TARGET_CXX) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-O3 $(NES_TUNE) $(NES_LCD) -funroll-loops -D_GNU_SOURCE -DNO_UNALIGNED_ACCESS \
		-fno-exceptions -fno-rtti -w \
		-I$(PKG_BUILD_DIR) -I$(PKG_BUILD_DIR)/nes_emu \
		-nostdlib++ -static-libgcc -lpthread \
		-o $(PKG_BUILD_DIR)/nes-quick \
		$(PKG_BUILD_DIR)/nes_emu/*.cpp \
		$(PKG_BUILD_DIR)/core_quicknes.cpp \
		$(PKG_BUILD_DIR)/almond_platform.cpp \
		$(PKG_BUILD_DIR)/almond_cxx.cpp \
		$(PKG_BUILD_DIR)/pad_file.cpp
	$(TARGET_CXX) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -Os -w $(NES_LCD) \
		-nostdlib++ -static-libgcc -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables \
		-o $(PKG_BUILD_DIR)/almond3s-pad $(PKG_BUILD_DIR)/almond_pad.cpp
endef

define Package/nes-almond3s/install
	$(INSTALL_DIR) $(1)/usr/libexec/almond3s
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/nes-quick $(1)/usr/libexec/almond3s/nes-quick
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/keygrab $(1)/usr/libexec/almond3s/keygrab
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/almond3s-pad $(1)/usr/libexec/almond3s/almond3s-pad
	$(INSTALL_DIR) $(1)/etc/almond3s/roms
endef

$(eval $(call BuildPackage,nes-almond3s))
