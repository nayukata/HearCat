# システム音声(相手)のキャプチャは、バイナリが安定した署名を持たないと無音で失敗する。
# そのため app は「ビルド → .app 組み立て → 署名」を必ず通す。
# 署名証明書はマシンごとに異なるため、ハッシュを直書きせず自動検出する(可搬性のため)。
IDENTITY := $(shell security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $$2; exit}')

CONFIG ?= debug
BUILD_DIR := .build/$(CONFIG)
APP := $(BUILD_DIR)/HearCat.app

.PHONY: build app run cli dist icon clean

build:
ifeq ($(CONFIG),release)
	swift build -c release
else
	swift build
endif

# SwiftPM は .app バンドルを作れないため、ここで組み立てる。
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BUILD_DIR)/HearCatApp $(APP)/Contents/MacOS/HearCat
	cp Sources/HearCatApp/Info.plist $(APP)/Contents/Info.plist
	# 設定画面の「agent skill を導入」ボタンが、この2つを ~/.claude/skills/ と ~/.local/bin/ へ配置する。
	cp distribution/hearcat/SKILL.md $(APP)/Contents/Resources/SKILL.md
	cp Sources/HearCatApp/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp $(BUILD_DIR)/hearcat $(APP)/Contents/MacOS/hearcat-cli
	# 同梱する実行ファイルは、バンドル本体より先に個別署名しないと署名検証が壊れる。
	codesign --force --sign $(IDENTITY) $(APP)/Contents/MacOS/hearcat-cli
	codesign --force --sign $(IDENTITY) $(APP)

# アプリを起動する(開発用)。
run: app
	open -g $(APP)

# CLI はアプリへ命令を送るだけなので署名不要。
cli: build
	@echo "CLI: $(BUILD_DIR)/hearcat"

# 配布用 dmg を作る。Developer ID 証明書があればそれで署名し直す(公証は README 参照)。
# 他の Mac でシステム音声キャプチャを動かすには Developer ID 署名 + 公証が実質必須。
DIST_IDENTITY := $(shell security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $$2; exit}')
DMG := .build/HearCat.dmg

dist:
	$(MAKE) app CONFIG=release
ifneq ($(DIST_IDENTITY),)
	codesign --force --options runtime --sign $(DIST_IDENTITY) .build/release/HearCat.app/Contents/MacOS/hearcat-cli
	codesign --force --options runtime --sign $(DIST_IDENTITY) .build/release/HearCat.app
else
	@echo "注意: Developer ID Application 証明書が見つからないため、開発用署名のままです。"
	@echo "      この dmg は他の Mac ではシステム音声(相手)を取得できません。"
endif
	rm -rf .build/dmg-root $(DMG)
	mkdir -p .build/dmg-root
	cp -R .build/release/HearCat.app .build/dmg-root/
	ln -s /Applications .build/dmg-root/Applications
	hdiutil create -volname HearCat -srcfolder .build/dmg-root -ov -format UDZO $(DMG)
	@echo "配布物: $(DMG)"

# アプリアイコンを生成し直す(デザイン変更時のみ。生成物はリポジトリに入っている)。
icon:
	swift scripts/make_icon.swift Sources/HearCatApp/AppIcon.icns

clean:
	swift package clean
