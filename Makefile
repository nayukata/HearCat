# システム音声(相手)のキャプチャは、バイナリが安定した署名を持たないと無音で失敗する。
# そのため app は「ビルド → .app 組み立て → 署名」を必ず通す。
# 署名証明書はマシンごとに異なるため、ハッシュを直書きせず自動検出する(可搬性のため)。
IDENTITY := $(shell security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $$2; exit}')

CONFIG ?= debug
BUILD_DIR := .build/$(CONFIG)
APP := $(BUILD_DIR)/sharingan.app

.PHONY: build app run cli clean

build:
ifeq ($(CONFIG),release)
	swift build -c release
else
	swift build
endif

# SwiftPM は .app バンドルを作れないため、ここで組み立てる。
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BUILD_DIR)/SharinganApp $(APP)/Contents/MacOS/sharingan
	cp Sources/SharinganApp/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign $(IDENTITY) $(APP)

# アプリを起動する(開発用)。
run: app
	open -g $(APP)

# CLI はアプリへ命令を送るだけなので署名不要。
cli: build
	@echo "CLI: $(BUILD_DIR)/sharingan"

clean:
	swift package clean
