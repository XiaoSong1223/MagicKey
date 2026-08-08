# MagicKey 开发工具
#
# 不走 SwiftPM——见 ../app/Makefile 的说明。

BIN     := magickey-tool
CORE    := ../Core/Log.swift ../Core/Driver.swift ../Core/StateGuard.swift ../Core/Effects.swift \
           ../Core/PulseSource.swift ../Core/AudioActivity.swift ../Core/AudioTap.swift ../Core/OnsetDetector.swift ../Core/BeatPulseSource.swift
SOURCES := $(CORE) Sources/AudioProbe.swift Sources/Analyze.swift Sources/Sequences.swift Sources/Probe.swift Sources/main.swift
SWIFTC  := swiftc
FLAGS   := -O -swift-version 5 -framework Foundation -framework AppKit -framework AVFoundation

.PHONY: all analyze preview probe probe-audio probe-file sweep clean

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

# 实时采集：走真正的 AudioTap，验证管线 + 看起音检出率
# 需要「系统录音」授权，且**必须有声音在放**——tap 由音频驱动，没声音就没有回调
probe-audio: $(BIN)
	./$(BIN) --probe-audio --live --seconds 20

# 离线定参：不碰硬件、不需要授权，全速重放，可复现
#   make probe-file FILE=drums.wav                  单跑，列出检出
#   make probe-file FILE=drums.wav TRUTH=t.json     对标准答案打分
FILE  ?=
TRUTH ?=
probe-file: $(BIN)
	@test -n "$(FILE)" || { echo "用法: make probe-file FILE=<音频文件> [TRUTH=<标准答案.json>]"; exit 2; }
	./$(BIN) --probe-audio --file $(FILE) $(if $(TRUTH),--truth $(TRUTH))

# 扫参：必须有标准答案，否则无从判断哪组更好
#   make sweep FILE=drums.wav TRUTH=drums.truth.json
sweep: $(BIN)
	@test -n "$(FILE)" -a -n "$(TRUTH)" || { echo "用法: make sweep FILE=<音频文件> TRUTH=<标准答案.json>"; exit 2; }
	./$(BIN) --probe-audio --file $(FILE) --truth $(TRUTH) --sweep

clean:
	rm -f $(BIN)
	rm -rf $(BIN).dSYM
