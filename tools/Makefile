# MagicKey 开发工具
#
# 不走 SwiftPM——见 ../app/Makefile 的说明。

BIN     := magickey-tool
CORE    := ../Core/Log.swift ../Core/Driver.swift ../Core/StateGuard.swift ../Core/Effects.swift \
           ../Core/PulseSource.swift ../Core/AudioActivity.swift ../Core/AudioTap.swift ../Core/OnsetDetector.swift ../Core/BeatPulseSource.swift
SOURCES := $(CORE) Sources/AudioProbe.swift Sources/Analyze.swift Sources/Sequences.swift Sources/Probe.swift Sources/main.swift
SWIFTC  := swiftc
FLAGS   := -O -swift-version 5 -framework Foundation -framework AppKit -framework AVFoundation

.PHONY: all analyze preview probe clean

all: $(BIN)

$(BIN): $(SOURCES)
	$(SWIFTC) $(FLAGS) $(SOURCES) -o $(BIN)

# 分析默认呼吸曲线
analyze: $(BIN)
	./$(BIN) --analyze

# 在真实键盘上预览，Ctrl-C 停止
preview: $(BIN)
	./$(BIN) --preview

# 测本机按键节奏（定 KeyRepeatFilter 的容差）。需要人工按键，Ctrl-C 出报告。
probe: $(BIN)
	./$(BIN) --probe

clean:
	rm -f $(BIN)
	rm -rf $(BIN).dSYM
