#!/usr/bin/env bash
# sharingan をローカルに導入する。
# システム音声(相手)のキャプチャには安定した署名が必須のため、各マシンで
# その利用者自身の証明書を使ってビルド＆署名する(署名済みバイナリの配布はしない)。
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${SHARINGAN_BIN:-$HOME/.local/bin}"
APP_DIR="${SHARINGAN_APP:-$HOME/Applications}"
mkdir -p "$BIN_DIR" "$APP_DIR"

echo "==> release ビルドと .app の組み立て(署名込み)"
make -C "$DIR" app CONFIG=release

IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $2; exit}')"
if [ -z "${IDENTITY}" ]; then
  echo "エラー: codesigning 用の証明書が見つかりません。" >&2
  echo "Xcode > Settings > Accounts でアカウントを追加し、Apple Development 証明書を作成してください。" >&2
  exit 1
fi

echo "==> ${APP_DIR}/sharingan.app へ配置"
# 起動中の旧アプリが残っていると差し替え後も旧プロセスが生き続けるため、先に終了させる。
osascript -e 'quit app id "dev.nayukata.sharingan"' >/dev/null 2>&1 || true
rm -rf "$APP_DIR/sharingan.app"
cp -R "$DIR/.build/release/sharingan.app" "$APP_DIR/sharingan.app"

echo "==> ${BIN_DIR}/sharingan へ CLI を配置"
install -m 0755 "$DIR/.build/release/sharingan" "$BIN_DIR/sharingan"

echo "完了: $APP_DIR/sharingan.app / $BIN_DIR/sharingan"
echo "初回は「sharingan start」かアプリ起動時に、マイク・音声認識の許可ダイアログが出ます。"
case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *) echo "注意: PATH に $BIN_DIR が含まれていません。シェル設定に追加してください。" >&2 ;;
esac
