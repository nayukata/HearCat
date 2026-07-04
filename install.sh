#!/usr/bin/env bash
# sharingan をローカルに導入する。
# システム音声(相手)のキャプチャには安定した署名が必須のため、各マシンで
# その利用者自身の証明書を使ってビルド＆署名する(署名済みバイナリの配布はしない)。
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${SHARINGAN_BIN:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"

echo "==> release ビルド"
swift build -c release --package-path "$DIR"

echo "==> 署名(システム音声キャプチャに安定署名が必須)"
IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $2; exit}')"
if [ -z "${IDENTITY}" ]; then
  echo "エラー: codesigning 用の証明書が見つかりません。" >&2
  echo "Xcode > Settings > Accounts でアカウントを追加し、Apple Development 証明書を作成してください。" >&2
  exit 1
fi
codesign --force --sign "${IDENTITY}" "$DIR/.build/release/sharingan"

echo "==> ${BIN_DIR} へ配置"
install -m 0755 "$DIR/.build/release/sharingan" "$BIN_DIR/sharingan"
install -m 0755 "$DIR/distribution/sharingan/assets/sharingan-session.sh" "$BIN_DIR/sharingan-session"

echo "完了: $BIN_DIR/sharingan / $BIN_DIR/sharingan-session"
case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *) echo "注意: PATH に $BIN_DIR が含まれていません。シェル設定に追加してください。" >&2 ;;
esac
