# HearCat ランディングページ

HearCat（Mac 用のリアルタイム日本語文字起こしアプリ）の紹介サイト。Astro 7 + Tailwind v4 で構築し、Cloudflare Workers（Static Assets）にデプロイする。

## 開発

```sh
pnpm install
pnpm dev
```

`http://localhost:4321` で確認できる。

## ビルド

```sh
pnpm build
```

`dist/` に静的ファイルが出力される。

## プレビュー

```sh
pnpm preview
```

`build` 後に `wrangler dev` でビルド成果物をローカル起動して確認する。

## デプロイ

```sh
pnpm run deploy
```

`build` 後に `wrangler deploy` で Cloudflare Workers へ公開する。事前に Cloudflare アカウントでの認証（`wrangler login` など）が必要。

## 構成

- `src/pages/` — ページ
- `src/components/` — セクションごとのコンポーネント
- `src/layouts/` — 共通レイアウト
- `src/styles/global.css` — Tailwind の設定とグローバルスタイル
