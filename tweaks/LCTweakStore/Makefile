TARGET := iphone:clang:latest:15.0
ARCHS = arm64
# LiveContainer が同梱する CydiaSubstrate は @rpath 参照なので rootless でないと解決できない。
# ROOTLESS=1 は theos の変数ではないので、ここで対応付ける
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LCTweakStore

$(TWEAK_NAME)_FILES = $(shell find Sources -type f \( -iname \*.x -o -iname \*.xm -o -iname \*.m \))
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# LiveContainer が取り込み時に足している 2 本。自分で置く dylib にも要る
$(TWEAK_NAME)_LDFLAGS = -Wl,-rpath,@executable_path/../../Tweaks -Wl,-rpath,@loader_path

include $(THEOS_MAKE_PATH)/tweak.mk
