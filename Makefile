# システム音声(相手)のキャプチャは、バイナリが安定した署名を持たないと無音で失敗する。
# そのため app は「ビルド → .app 組み立て → 署名」を必ず通す。
# 署名証明書はマシンごとに異なるため、ハッシュを直書きせず自動検出する(可搬性のため)。
IDENTITY := $(shell security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $$2; exit}')

CONFIG ?= debug
BUILD_DIR := .build/$(CONFIG)
APP := $(BUILD_DIR)/HearCat.app

.PHONY: build app run cli dist check-dist-identity check-notary-profile appcast icon ogp clean

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
	# 設定画面の「agent skill を導入」ボタンが、これらを ~/.agents/skills/ と ~/.local/bin/ へ配置する。
	# skill は複数あるので Resources 配下にディレクトリごと持つ(バンドルの階層を維持したまま複製する)。
	mkdir -p $(APP)/Contents/Resources/skills
	cp -R distribution/hearcat $(APP)/Contents/Resources/skills/hearcat
	cp -R distribution/hearcat-clean $(APP)/Contents/Resources/skills/hearcat-clean
	cp Sources/HearCatApp/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	# SwiftPM のリソースバンドル(同梱フォント)。HCFont.registerBundledFonts() が
	# Bundle.main.resourceURL(= ここ)を自前で探して読む(Bundle.module は使わない。
	# Bundle.module はビルド時の絶対パスに依存し配布後は必ず見つからず fatalError するため)。
	cp -R $(BUILD_DIR)/hearcat_HearCatApp.bundle $(APP)/Contents/Resources/
	cp $(BUILD_DIR)/hearcat $(APP)/Contents/MacOS/hearcat-cli
	# Sparkle(自動更新)。SwiftPM は実行ファイルに @loader_path 相対の rpath を埋め込む
	# (= 実行ファイルと同じ階層で探す)ため、Contents/Frameworks/ に置いた上で
	# rpath を標準的な @executable_path/../Frameworks に書き換える。
	mkdir -p $(APP)/Contents/Frameworks
	rm -rf $(APP)/Contents/Frameworks/Sparkle.framework
	ditto $(BUILD_DIR)/Sparkle.framework $(APP)/Contents/Frameworks/Sparkle.framework
	install_name_tool -rpath @loader_path @executable_path/../Frameworks $(APP)/Contents/MacOS/HearCat
	# 同梱する実行ファイルは、バンドル本体より先に個別署名しないと署名検証が壊れる。
	# Sparkle.framework 同梱物(SPM 配布物内では ad-hoc 署名のまま)は、
	# 内側から外側へ: XPC サービス → Autoupdate → Updater.app → framework 本体 の順。
	codesign --force --sign $(IDENTITY) $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
	codesign --force --sign $(IDENTITY) $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
	codesign --force --sign $(IDENTITY) $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
	codesign --force --sign $(IDENTITY) $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
	codesign --force --sign $(IDENTITY) $(APP)/Contents/Frameworks/Sparkle.framework
	codesign --force --sign $(IDENTITY) $(APP)/Contents/MacOS/hearcat-cli
	codesign --force --sign $(IDENTITY) $(APP)

# アプリを起動する(開発用)。
run: app
	open -g $(APP)

# CLI はアプリへ命令を送るだけなので署名不要。
cli: build
	@echo "CLI: $(BUILD_DIR)/hearcat"

# 配布用 dmg を作る。Developer ID 署名 + Apple 公証(notarization)まで一気通貫で行う。
# 他の Mac でシステム音声キャプチャを動かすには Developer ID 署名 + 公証が実質必須なため、
# 証明書やプロファイルが無くてもフォールバックはせず、ここでエラーにして止める
# (`make app` など開発用ビルドの挙動には影響しない)。
DIST_IDENTITY := $(shell security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $$2; exit}')
DMG := .build/HearCat.dmg

# 公証で使うキーチェーンプロファイル名。`NOTARY_PROFILE=<名前> make dist` で上書きできる。
# 事前に `xcrun notarytool store-credentials <名前>` で Apple ID / Team ID / App用パスワードを
# キーチェーンへ登録しておく必要がある。
NOTARY_PROFILE ?= HearCat

dist: check-dist-identity check-notary-profile
	$(MAKE) app CONFIG=release
	# make app が Apple Development 証明書で仮署名した分を、公証に通る
	# Developer ID + hardened runtime で内側から外側へ改めて署名し直す。
	codesign --force --options runtime --sign $(DIST_IDENTITY) .build/release/HearCat.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
	codesign --force --options runtime --sign $(DIST_IDENTITY) .build/release/HearCat.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
	codesign --force --options runtime --sign $(DIST_IDENTITY) .build/release/HearCat.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
	codesign --force --options runtime --sign $(DIST_IDENTITY) .build/release/HearCat.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
	codesign --force --options runtime --sign $(DIST_IDENTITY) .build/release/HearCat.app/Contents/Frameworks/Sparkle.framework
	codesign --force --options runtime --sign $(DIST_IDENTITY) .build/release/HearCat.app/Contents/MacOS/hearcat-cli
	codesign --force --options runtime --sign $(DIST_IDENTITY) .build/release/HearCat.app
	rm -rf .build/dmg-root $(DMG)
	mkdir -p .build/dmg-root
	cp -R .build/release/HearCat.app .build/dmg-root/
	ln -s /Applications .build/dmg-root/Applications
	hdiutil create -volname HearCat -srcfolder .build/dmg-root -ov -format UDZO $(DMG)
	@echo "公証を申請中(数分かかる場合があります)..."
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)
	xcrun stapler validate $(DMG)
	spctl -a -vv -t open --context context:primary-signing-identifier $(DMG)
	@echo "配布物: $(DMG)(Developer ID 署名 + 公証 + staple 済み)"

# Developer ID Application 証明書が無ければフォールバックせずここで止める。
check-dist-identity:
	@if [ -z "$(DIST_IDENTITY)" ]; then \
		echo "エラー: Developer ID Application 証明書が見つかりません。" >&2; \
		echo "  Apple Developer Program で証明書を作成し、Keychain Access に登録してください。" >&2; \
		echo "  確認: security find-identity -v -p codesigning" >&2; \
		exit 1; \
	fi

# 公証用キーチェーンプロファイルが未登録なら止める。
check-notary-profile:
	@xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1 || { \
		echo "エラー: 公証用キーチェーンプロファイル '$(NOTARY_PROFILE)' が未登録です。" >&2; \
		echo "  次のコマンドで登録してから再実行してください:" >&2; \
		echo "  xcrun notarytool store-credentials $(NOTARY_PROFILE) --apple-id <Apple ID> --team-id <Team ID> --password <App用パスワード>" >&2; \
		echo "  (プロファイル名を変える場合は NOTARY_PROFILE=<名前> make dist)" >&2; \
		exit 1; \
	}

# Sparkle(自動更新)の appcast.xml を dmg から生成する。
# generate_appcast / generate_keys などの CLI ツールは、SwiftPM が取得するバイナリ配布物
# (xcframework のみ)には含まれないため、GitHub Releases の tar.xz から別途取得する。
# Package.swift の Sparkle バージョンとズレないよう、上げたら両方直す。
SPARKLE_VERSION := 2.9.4
SPARKLE_TOOLS_DIR := .build/sparkle-tools

$(SPARKLE_TOOLS_DIR)/generate_appcast:
	mkdir -p $(SPARKLE_TOOLS_DIR)
	curl -fsSL -o $(SPARKLE_TOOLS_DIR)/Sparkle-$(SPARKLE_VERSION).tar.xz \
		https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-$(SPARKLE_VERSION).tar.xz
	tar -xf $(SPARKLE_TOOLS_DIR)/Sparkle-$(SPARKLE_VERSION).tar.xz -C $(SPARKLE_TOOLS_DIR) bin/generate_appcast bin/generate_keys bin/sign_update
	mv $(SPARKLE_TOOLS_DIR)/bin/* $(SPARKLE_TOOLS_DIR)/
	rm -rf $(SPARKLE_TOOLS_DIR)/bin $(SPARKLE_TOOLS_DIR)/Sparkle-$(SPARKLE_VERSION).tar.xz

APP_VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/HearCatApp/Info.plist)

# dmg 一式を蓄積する場所。generate_appcast は「このディレクトリに残っている dmg」を元に
# 複数バージョン分の appcast を作る(既定で直近3件を保持)ため、.build 配下ではなく
# `make clean` (swift package clean) の影響を受けないここに置く。gitignore 済み。
SPARKLE_ARCHIVE_DIR := dist-archive

# ダウンロード URL は GitHub Releases (タグ v<バージョン>) に dmg を置く前提
# (README に記載の配布方針に合わせた)。その Release 作成 / dmg アップロード自体は
# 手動(このターゲットの範囲外)。
GITHUB_REPO := nayukata/HearCat

# `make dist` の dmg から appcast.xml を作り、LP (web/public/) に配置する。
# 秘密鍵は generate_keys が Keychain に保存したものを自動で使う。
#
# --maximum-versions 1: appcast には現在バージョンだけを載せる。generate_appcast の
# --download-url-prefix は一括で全 dmg に同じ prefix を付けるため、これを指定せず
# 過去バージョンも appcast に含めると、たとえば旧 0.1.0 のエントリまで最新タグ
# v<APP_VERSION> の URL を指してしまい、Sparkle のロールバック提示や履歴表示から
# ダウンロードすると 404 になる。過去版のロールバックが必要になったら、その時に
# 個別バージョンの appcast を生成して静的にホストする方針。
appcast: dist $(SPARKLE_TOOLS_DIR)/generate_appcast
	mkdir -p $(SPARKLE_ARCHIVE_DIR)
	cp $(DMG) $(SPARKLE_ARCHIVE_DIR)/HearCat-$(APP_VERSION).dmg
	$(SPARKLE_TOOLS_DIR)/generate_appcast \
		--download-url-prefix https://github.com/$(GITHUB_REPO)/releases/download/v$(APP_VERSION)/ \
		--maximum-versions 1 \
		$(SPARKLE_ARCHIVE_DIR)
	cp $(SPARKLE_ARCHIVE_DIR)/appcast.xml web/public/appcast.xml
	@echo "appcast.xml を web/public/ に配置しました。"
	@echo "GitHub Releases の v$(APP_VERSION) タグに $(SPARKLE_ARCHIVE_DIR)/HearCat-$(APP_VERSION).dmg をアップロードしてから、"
	@echo "web/ をデプロイ(pnpm run deploy)してください。"

# アプリアイコンを生成し直す(デザイン変更時のみ。生成物はリポジトリに入っている)。
icon:
	swift scripts/make_icon.swift Sources/HearCatApp/AppIcon.icns

# OGP 画像を生成し直す(同上)。
ogp:
	swift scripts/make_ogp.swift web/public/ogp.png

clean:
	swift package clean
