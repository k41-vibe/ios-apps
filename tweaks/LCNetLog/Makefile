TARGET := iphone:clang:latest:15.0
ARCHS = arm64
# LiveContainer が同梱する CydiaSubstrate は @rpath 参照なので rootless でないと解決できない
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LCNetLog

$(TWEAK_NAME)_FILES = $(shell find Sources -type f \( -iname \*.x -o -iname \*.xm -o -iname \*.m \))
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation
$(TWEAK_NAME)_LIBRARIES = z
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# rpath はここで足さない。LiveContainer が取り込み時に足すので、両方が足すと
# LC_RPATH が重複し iOS 26 の dyld が読み込みを拒む

include $(THEOS_MAKE_PATH)/tweak.mk
