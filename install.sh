#!/usr/bin/env bash
# hearcat をローカルに導入する。
# システム音声(相手)のキャプチャには安定した署名が必須のため、各マシンで
# その利用者自身の証明書を使ってビルド＆署名する(署名済みバイナリの配布はしない)。
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${HEARCAT_BIN:-$HOME/.local/bin}"
APP_DIR="${HEARCAT_APP:-$HOME/Applications}"
mkdir -p "$BIN_DIR" "$APP_DIR"

# Xcode 開発者ツール(CLT) が未導入だと swift 自体が動かないため、先に確保する。
# `xcode-select --install` は GUI ダイアログを開いて即戻るので、完了はポーリングで待つ。
if ! xcode-select -p >/dev/null 2>&1; then
  echo "==> Xcode 開発者ツールが未導入です。表示されたダイアログから「インストール」を押してください。"
  xcode-select --install >/dev/null 2>&1 || true
  until xcode-select -p >/dev/null 2>&1; do
    sleep 5
  done
  echo "==> Xcode 開発者ツールの導入を確認しました"
fi

# Swift 6 は Xcode 26 に含まれる。CLT だけでは足りない環境がある。
if ! command -v swift >/dev/null 2>&1; then
  echo "エラー: swift コマンドが見つかりません。App Store から Xcode 26 を導入してください。" >&2
  exit 1
fi

# 開発者ツールの向き先が CommandLineTools だと、FoundationModels の @Generable
# マクロ(Xcode 26 の SDK に同梱)が展開されずビルドが落ちる。フルの Xcode を指す。
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
case "$DEV_DIR" in
  */CommandLineTools*)
    echo "エラー: 開発者ツールが CommandLineTools を指しています。" >&2
    echo "  現在: $DEV_DIR" >&2
    echo "  Xcode 26 に含まれる FoundationModels のマクロが展開されずビルドが失敗します。" >&2
    echo "  下のコマンドでフルの Xcode.app を選び直してから、もう一度 install を実行してください:" >&2
    echo "    sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
    ;;
esac

echo "==> release ビルドと .app の組み立て(署名込み)"
make -C "$DIR" app CONFIG=release

IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $2; exit}')"
if [ -z "${IDENTITY}" ]; then
  echo "エラー: codesigning 用の証明書が見つかりません。" >&2
  echo "Xcode > Settings > Accounts でアカウントを追加し、Apple Development 証明書を作成してください。" >&2
  exit 1
fi

# WWDR 中間 CA の期限内チェック。Apple Development 証明書は WWDR CA で
# 署名検証されるため、旧世代(2023年2月失効)しか無いと codesign 自体は通っても
# 実質無効な署名になり、システム音声のキャプチャ許可が下りない。
# 実測: この Mac には G3(2030) / G6(2036) / 旧(2023失効) が同居。期限内が1枚
# でもあれば OK と判定する。
wwdr_pem="$(mktemp)"
security find-certificate -a -c "Apple Worldwide Developer Relations Certification Authority" -p 2>/dev/null > "$wwdr_pem"
wwdr_dir="$(mktemp -d)"
awk -v dir="$wwdr_dir" 'BEGIN{n=0} /BEGIN CERT/{n++; f=dir"/"n".pem"} {print > f} /END CERT/{close(f)}' "$wwdr_pem"
wwdr_ok=1
for c in "$wwdr_dir"/*.pem; do
  [ -f "$c" ] || continue
  if openssl x509 -in "$c" -noout -checkend 0 >/dev/null 2>&1; then
    wwdr_ok=0
    break
  fi
done
rm -rf "$wwdr_pem" "$wwdr_dir"
if [ "$wwdr_ok" -ne 0 ]; then
  echo "エラー: 期限内の WWDR 中間証明書が Keychain に見つかりません。" >&2
  echo "  Apple Development 証明書は WWDR CA の中間証明書で検証されるため、" >&2
  echo "  期限内の中間証明書が無いと署名が実質無効になります。" >&2
  echo "  Apple 公式 PKI ページから WWDR G3 以降を1枚ダウンロードし、" >&2
  echo "  ダブルクリックで Keychain に追加してください:" >&2
  echo "    https://www.apple.com/certificateauthority/" >&2
  exit 1
fi

echo "==> ${APP_DIR}/HearCat.app へ配置"
# 起動中の旧アプリが残っていると差し替え後も旧プロセスが生き続けるため、先に終了させる。
osascript -e 'quit app id "dev.nayukata.hearcat"' >/dev/null 2>&1 || true
rm -rf "$APP_DIR/HearCat.app"
cp -R "$DIR/.build/release/HearCat.app" "$APP_DIR/HearCat.app"

echo "==> ${BIN_DIR}/hearcat へ CLI を配置"
install -m 0755 "$DIR/.build/release/hearcat" "$BIN_DIR/hearcat"

echo "完了: $APP_DIR/HearCat.app / $BIN_DIR/hearcat"
echo "初回は「hearcat start」かアプリ起動時に、マイク・音声認識の許可ダイアログが出ます。"
case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *) echo "注意: PATH に $BIN_DIR が含まれていません。シェル設定に追加してください。" >&2 ;;
esac
