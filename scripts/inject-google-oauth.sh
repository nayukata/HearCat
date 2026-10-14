#!/bin/sh
# Google Drive 連携のクライアント ID / シークレットを、組み立て中の .app の Info.plist へ注入する。
# 値はリポジトリに入れず、git 管理外の .google-oauth.env から読む:
#   GOOGLE_OAUTH_CLIENT_ID=...
#   GOOGLE_OAUTH_CLIENT_SECRET=...
# ファイルが無い、またはどちらかが空なら何も注入しない(アプリ側は連携を無効にする)。
# 値は画面に出さない。
set -eu

plist=${1:?usage: inject-google-oauth.sh <Info.plist> [env-file]}
envfile=${2:-.google-oauth.env}

if [ ! -f "$envfile" ]; then
  echo "==> $envfile が無いため、Google Drive 連携は無効のままにします"
  exit 0
fi

# source せずに読む(ファイルの中身をシェルとして実行しないため)。`export ` 付きの行も読む。前後の空白・引用符・改行は落とす。
read_value() {
  sed -n "s/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}$1=//p" "$envfile" | head -n 1 | tr -d "\"' \r\t"
}
id=$(read_value GOOGLE_OAUTH_CLIENT_ID)
secret=$(read_value GOOGLE_OAUTH_CLIENT_SECRET)

if [ -z "$id" ] || [ -z "$secret" ]; then
  echo "==> $envfile の GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET が空のため、Google Drive 連携は無効のままにします"
  exit 0
fi

# PlistBuddy のコマンド文字列に埋め込むため、想定外の文字は受け付けない。
case "$id$secret" in
  *[!A-Za-z0-9._-]*)
    echo "エラー: $envfile の値に使えない文字が含まれています (英数字と . _ - のみ)" >&2
    exit 1
    ;;
esac

/usr/libexec/PlistBuddy -c "Add :HearCatGoogleClientID string $id" "$plist"
/usr/libexec/PlistBuddy -c "Add :HearCatGoogleClientSecret string $secret" "$plist"
echo "==> Google Drive 連携の資格情報を注入しました"
