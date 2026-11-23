# language: Makefile, file: Makefile
TARGET := iphone:clang:latest:13.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XSamkokMod

XSamkokMod_FILES := Tweak.mm
XSamkokMod_CFLAGS := -fobjc-arc -std=c++17 -I./include
XSamkokMod_LDFLAGS := -L./lib -ldobby -framework UIKit -framework Foundation -framework JavaScriptCore

include $(THEOS_MAKE_PATH)/tweak.mk
