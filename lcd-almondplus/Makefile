include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=lcd-almondplus
PKG_RELEASE:=4
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define KernelPackage/lcd-almondplus
  SUBMENU:=Video Support
  TITLE:=ILI9486 LCD for Securifi Almond+
  DEPENDS:=@TARGET_cortina
  FILES:=$(PKG_BUILD_DIR)/almondplus_lcd.ko
  AUTOLOAD:=$(call AutoLoad,90,almondplus_lcd)
endef

define KernelPackage/lcd-almondplus/description
 Driver for the 3.5" 480x320 ILI9486 panel of the Securifi Almond+, driven
 over a 16-bit 8080 bus bit-banged on CS75xx GPIO bank 4. Exposes an RGB565
 framebuffer at /dev/lcd with the Almond 3S protocol and relays SX8650 touch
 events from the input layer.
endef

PKG_BUILD_DATE:=$(shell date -u +%Y-%m-%d)

define Build/Compile
	$(KERNEL_MAKE) M="$(PKG_BUILD_DIR)" \
		LCD_DRV_BUILD="$(PKG_BUILD_DATE)" \
		modules
endef

$(eval $(call KernelPackage,lcd-almondplus))
