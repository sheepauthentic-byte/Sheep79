SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CXX := xcrun --sdk iphoneos clang++
CXXFLAGS := -dynamiclib -arch arm64 -isysroot $(SDK) -miphoneos-version-min=13.0 -std=c++17 -fobjc-arc -O2 -I./include
LDFLAGS := -L./lib -ldobby -framework UIKit -framework Foundation -framework JavaScriptCore -install_name @executable_path/Frameworks/XSamkokMod.dylib

all:
	mkdir -p output
	$(CXX) $(CXXFLAGS) Tweak.mm $(LDFLAGS) -o output/XSamkokMod.dylib
	codesign -f -s - output/XSamkokMod.dylib

clean:
	rm -rf output
