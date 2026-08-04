# MagicKey 开发工具
#
# 不走 SwiftPM——见 ../app/Makefile 的说明。

BIN     := magickey-tool
CORE    := ../Core/Log.swift ../Core/Driver.swift ../Core/StateGuard.swift ../Core/Effects.swift
SOURCES := $(CORE) Sources/Analyze.swift Sources/main.swift
SWIFTC  := swiftc
FLAGS   := -O -swift-version 5 -framework Foundation -framework AppKit

.PHONY: all analyze preview clean

all: $(BIN)

$(BIN): $(SOURCES)
	$(SWIFTC) $(FLAGS) $(SOURCES) -o $(BIN)

# 分析默认呼吸曲线
analyze: $(BIN)
	./$(BIN) --analyze

# 在真实键盘上预览，Ctrl-C 停止
preview: $(BIN)
	./$(BIN) --preview

clean:
	rm -f $(BIN)
	rm -rf $(BIN).dSYM
