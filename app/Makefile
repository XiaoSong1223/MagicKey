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

# 键盘音效的采样。**整目录拷**，不像上面那样逐个列——一套包 12 个文件，
# 三套就是 36 个，列出来的唯一作用是漏掉新加的那个然后在运行时静默变哑。
# 目录结构（Sounds/<包名>/{press,release}/*.mp3）是 KeySoundPack 直接依赖的，
# 拷的时候必须原样保留，所以是 cp -R 而不是 cp。
# 展开成文件列表只为了当依赖：改一个 mp3 也要触发重新打包。
SOUNDS_DIR   := Resources/Sounds
SOUND_FILES  := $(shell find $(SOUNDS_DIR) -type f 2>/dev/null)

SWIFTC  := swiftc
TARGET  := arm64-apple-macos14.0

# Liquid Glass（glassEffect / GlassEffectContainer）只存在于 macOS 26 SDK。
# 用**构建时的 SDK 版本**决定要不要编那段代码——注意这和 deployment target
# 是两回事：SDK 26 + target 14.0 完全合法，玻璃代码由 @available(macOS 26.0)
# 在运行时再挡一层，14/15 上走 material 回退。
#
# 用 CommandLineTools（SDK ≤ 15.x）构建时这个标志不会定义，那段代码整个不编译，
# 界面自动是回退外观。
SDK_MAJOR  := $(shell xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1)
GLASS_FLAG := $(shell [ "$(SDK_MAJOR)" -ge 26 ] 2>/dev/null && echo -D LIQUID_GLASS_SDK)

# AVFoundation：键盘音效的播放（AVAudioEngine + 预载 PCM buffer）
# IOKit：      查「输入监控」授权（IOHIDCheckAccess / IOHIDRequestAccess）
FLAGS   := -swift-version 5 -parse-as-library -target $(TARGET) $(GLASS_FLAG) \
           -framework SwiftUI -framework AppKit -framework ServiceManagement \
           -framework AVFoundation -framework IOKit

# UI 探针：复用 app 的**真实**视图和状态类型，只把入口换掉。
# 排除 MagicKeyApp.swift（它带 @main），加上 Probe/UIProbe.swift。
#
# `-D UI_PROBE` 开启 Engine 的探针构造器——正式目标不带这个标志，
# 所以那段代码不会进入发布的二进制。
# 编成裸可执行文件而不是 .app：无 bundle 就没有 bundle id，
# 既不会被控制中心的 blocked list 认领，UserDefaults 也落在单独的域里，
# 不会污染正在运行的那个 MagicKey 的设置。
PROBE_BIN     := magickey-uiprobe
PROBE_SOURCES := $(CORE) $(filter-out Sources/MagicKeyApp.swift,$(wildcard Sources/*.swift)) \
                 Probe/UIProbe.swift

.PHONY: all run debug install uninstall clean probe-ui

all: $(BUNDLE)

$(BUNDLE): $(SOURCES) Resources/Info.plist $(RESOURCES) $(SOUND_FILES)
	@rm -rf $(BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@cp $(RESOURCES) $(CONTENTS)/Resources/
	@cp -R $(SOUNDS_DIR) $(CONTENTS)/Resources/
	$(SWIFTC) -O $(FLAGS) $(SOURCES) -o $(CONTENTS)/MacOS/$(APP)
	@codesign --force --sign - $(BUNDLE) 2>/dev/null || \
	  echo "⚠️  ad-hoc 签名失败，开机自启可能不可用"
	@echo "✅ 已生成 $(BUNDLE)"

debug: $(SOURCES) Resources/Info.plist $(RESOURCES) $(SOUND_FILES)
	@rm -rf $(BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@cp $(RESOURCES) $(CONTENTS)/Resources/
	@cp -R $(SOUNDS_DIR) $(CONTENTS)/Resources/
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

# 面板高度 / 无障碍标签 / 运行状态的回归检查。可与正在运行的 MagicKey 并行。
probe-ui: $(PROBE_BIN)
	./$(PROBE_BIN)

$(PROBE_BIN): $(PROBE_SOURCES)
	$(SWIFTC) -Onone -g $(FLAGS) -D UI_PROBE $(PROBE_SOURCES) -o $(PROBE_BIN)

clean:
	rm -rf $(BUNDLE) $(PROBE_BIN) $(PROBE_BIN).dSYM
