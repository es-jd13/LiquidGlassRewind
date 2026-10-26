export TARGET = iphone:clang:latest:12.0
export ARCHS = arm64

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidGlassRewind

LiquidGlassRewind_FILES = Tweak.xm
LiquidGlassRewind_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
LiquidGlassRewind_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
