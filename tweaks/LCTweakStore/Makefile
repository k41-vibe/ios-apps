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
# rpath はここで足さない。LiveContainer が取り込み時に LCPatchAddRPath で足すので、
# 両方が足すと LC_RPATH が重複し、iOS 26 の dyld が
#   duplicate LC_RPATH '@executable_path/../../Tweaks'
# として読み込みを拒む(実機 2026-09-18)。

include $(THEOS_MAKE_PATH)/tweak.mk
