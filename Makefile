# システム音声(相手)のキャプチャは、バイナリが安定した署名を持たないと無音で失敗する。
# そのため app は「ビルド → .app 組み立て → 署名」を必ず通す。
# 署名証明書はマシンごとに異なるため、ハッシュを直書きせず自動検出する(可搬性のため)。
IDENTITY := $(shell security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $$2; exit}')

CONFIG ?= debug
BUILD_DIR := .build/$(CONFIG)
APP := $(BUILD_DIR)/HearCat.app

.PHONY: build app run cli dist check-identity check-dist-identity check-notary-profile icon ogp clean

build:
ifeq ($(CONFIG),release)
	swift build -c release
else
	swift build
endif

# SwiftPM は .app バンドルを作れないため、ここで組み立てる。
app: check-identity build
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
	# 同梱する実行ファイルは、バンドル本体より先に個別署名しないと署名検証が壊れる。
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

# codesigning 証明書が無ければフォールバックせずここで止める。
# システム音声(相手)のキャプチャは無署名だと無音で失敗するため、無署名では組み立てない。
check-identity:
	@if [ -z "$(IDENTITY)" ]; then \
		echo "エラー: codesigning 用の証明書が見つかりません。" >&2; \
		echo "  システム音声(相手)のキャプチャは、安定した署名が無いと無音で失敗するため、無署名では組み立てません。" >&2; \
		echo "  次の手順で Apple Development 証明書を作成してください (無料の Apple ID で可):" >&2; \
		echo "    1. Xcode を開き、メニューの Xcode > Settings... > Accounts で Apple ID を追加する" >&2; \
		echo "    2. 追加したアカウントを選び、Manage Certificates... > 左下の + > Apple Development を選ぶ" >&2; \
		echo "    3. もう一度このコマンドを実行する" >&2; \
		echo "  作成できたかの確認: security find-identity -v -p codesigning" >&2; \
		exit 1; \
	fi

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

# アプリアイコンを生成し直す(デザイン変更時のみ。生成物はリポジトリに入っている)。
icon:
	swift scripts/make_icon.swift Sources/HearCatApp/AppIcon.icns

# OGP 画像を生成し直す(同上)。
ogp:
	swift scripts/make_ogp.swift web/public/ogp.png

clean:
	swift package clean
