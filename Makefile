# システム音声(相手)のキャプチャは、バイナリが安定した署名を持たないと無音で失敗する。
# そのため run は「ビルド → 署名 → 実行」を必ず通す。
# 署名証明書はマシンごとに異なるため、ハッシュを直書きせず自動検出する(可搬性のため)。
IDENTITY := $(shell security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $$2; exit}')
BINARY := .build/debug/sharingan

.PHONY: build sign run clean

build:
	swift build

sign: build
	codesign --force --sign $(IDENTITY) $(BINARY)

run: sign
	$(BINARY)

# 診断ログ付きで実行(音声レベル・フォーマット・認識の生結果を stderr に出す)。
debug: sign
	SHARINGAN_DEBUG=1 $(BINARY)

clean:
	swift package clean
