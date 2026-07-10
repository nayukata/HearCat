#!/usr/bin/env bash
# HearCat をコマンド 1 行で導入する:
#   curl -fsSL https://raw.githubusercontent.com/nayukata/HearCat/main/bootstrap.sh | bash
# ソース一式を tarball で取得して install.sh に委譲する(git 不要)。
# ビルド成果物は install.sh が ~/Applications と ~/.local/bin へ配置するので、
# 展開したソースは終了時に破棄する。
set -euo pipefail

TARBALL_URL="https://github.com/nayukata/HearCat/archive/refs/heads/main.tar.gz"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> ソース一式を取得"
curl -fsSL "$TARBALL_URL" | tar -xz -C "$WORK" --strip-components=1

bash "$WORK/install.sh"
