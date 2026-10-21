TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IVGlassPlayer

IVGlassPlayer_FILES = Tweak.xm IVGlassKit.m IVGlassOverlay.m IVPlayerWatcher.m
IVGlassPlayer_FRAMEWORKS = UIKit AVFoundation QuartzCore
IVGlassPlayer_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
