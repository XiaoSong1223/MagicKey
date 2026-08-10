# MagicKey 菜单栏应用
#
# 用 swiftc 直接编译并手工组装 .app bundle，不走 SwiftPM。
# 原因见 ../prototype/Makefile：本机 CLT 的 PackageDescription 新旧文件混装，
# swift build 链接失败。v0.1 没有外部依赖，swiftc 完全够用。
# 引入 Sparkle 等依赖前需重装一次 Command Line Tools。

APP     := MagicKey
BUNDLE  := $(APP).app
CONTENTS:= $(BUNDLE)/Contents

CORE    := ../Core/Log.swift ../Core/Driver.swift ../Core/StateGuard.swift ../Core/Effects.swift \
           ../Core/PulseSource.swift ../Core/AudioActivity.swift ../Core/AudioTap.swift ../Core/OnsetDetector.swift ../Core/BeatPulseSource.swift
SOURCES := $(CORE) $(wildcard Sources/*.swift)
RESOURCES := Resources/AppIcon.icns \
             Resources/StatusKeyActive.png Resources/StatusKeyActive@2x.png \
             Resources/StatusKeyInactive.png Resources/StatusKeyInactive@2x.png

SWIFTC  := swiftc
TARGET  := arm64-apple-macos14.0
FLAGS   := -swift-version 5 -parse-as-library -target $(TARGET) \
           -framework SwiftUI -framework AppKit -framework ServiceManagement

.PHONY: all run debug install uninstall clean

all: $(BUNDLE)

$(BUNDLE): $(SOURCES) Resources/Info.plist $(RESOURCES)
	@rm -rf $(BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@cp $(RESOURCES) $(CONTENTS)/Resources/
	$(SWIFTC) -O $(FLAGS) $(SOURCES) -o $(CONTENTS)/MacOS/$(APP)
	@codesign --force --sign - $(BUNDLE) 2>/dev/null || \
	  echo "⚠️  ad-hoc 签名失败，开机自启可能不可用"
	@echo "✅ 已生成 $(BUNDLE)"

debug: $(SOURCES) Resources/Info.plist $(RESOURCES)
	@rm -rf $(BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@cp $(RESOURCES) $(CONTENTS)/Resources/
	$(SWIFTC) -Onone -g $(FLAGS) $(SOURCES) -o $(CONTENTS)/MacOS/$(APP)
	@codesign --force --sign - $(BUNDLE) 2>/dev/null || true

# 直接跑 bundle 里的可执行文件——日志会打到终端，方便调试。
# 仍然在 bundle 内，所以 Info.plist（LSUIElement 等）照常生效。
run: $(BUNDLE)
	./$(CONTENTS)/MacOS/$(APP)

install: $(BUNDLE)
	@pkill -x $(APP) 2>/dev/null || true
	rm -rf /Applications/$(BUNDLE)
	cp -R $(BUNDLE) /Applications/
	open /Applications/$(BUNDLE)
	@echo "✅ 已安装到 /Applications 并启动"

uninstall:
	@pkill -x $(APP) 2>/dev/null || true
	rm -rf /Applications/$(BUNDLE)

clean:
	rm -rf $(BUNDLE)
