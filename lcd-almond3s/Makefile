include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=lcd-almond3s
PKG_RELEASE:=46
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define KernelPackage/lcd-almond3s
  SUBMENU:=Video Support
  TITLE:=ILI9341 LCD for Securifi Almond 3S
  DEPENDS:=@TARGET_ramips_mt7621
  FILES:=$(PKG_BUILD_DIR)/almond3s_lcd.ko
  AUTOLOAD:=$(call AutoLoad,90,almond3s_lcd)
endef

define KernelPackage/lcd-almond3s/description
 Driver for the 2.8" ILI9341 panel of the Securifi Almond 3S, driven over an
 8-bit 8080-II bus bit-banged on MT7621 GPIO 13-18 and 22-27. Exposes an
 RGB565 framebuffer at /dev/lcd.
endef

# Версия драйвера - дата сборки, её видно на экране в «Инфо». Именно дата
# сборки, а не SOURCE_DATE_EPOCH: тот берётся из даты коммита дерева OpenWrt и
# не меняется, сколько драйвер ни правь, - на экране был бы вечный 2026-06-29.
PKG_BUILD_DATE:=$(shell date -u +%Y-%m-%d)

define Build/Compile
	$(KERNEL_MAKE) M="$(PKG_BUILD_DIR)" \
		EXTRA_CFLAGS="-DLCD_DRV_BUILD=\\\"$(PKG_BUILD_DATE)\\\"" \
		modules
endef

$(eval $(call KernelPackage,lcd-almond3s))
