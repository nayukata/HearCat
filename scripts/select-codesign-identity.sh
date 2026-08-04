#!/bin/sh
# 署名に実際に使える証明書を選ぶ。security find-identity -v は失効済みの
# 証明書も valid として載せることがあるため(チームを抜けた後に残った古い
# 証明書など)、一時ファイルへのテスト署名が通る最初の 1 件を採用する。
set -eu

candidates=$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $2}')
[ -n "$candidates" ] || exit 1

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for id in $candidates; do
  cp /bin/ls "$tmp"
  if codesign --force --sign "$id" "$tmp" >/dev/null 2>&1 \
    && codesign --verify "$tmp" >/dev/null 2>&1; then
    echo "$id"
    exit 0
  fi
done
exit 1
