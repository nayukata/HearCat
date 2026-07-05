# sharingan

Mac のマイク（自分）とシステム音声（通話相手など）を、macOS 26 の `SpeechAnalyzer` でリアルタイムに日本語文字起こし・録音するメニューバー常駐アプリ。文字起こしファイルを AI（Claude Code など）に読ませて、会議中の質疑応答に使う。

構成は2つ:

- **sharingan.app**: 常駐エンジン。音声キャプチャ・文字起こし・録音・履歴の閲覧/再生/削除・オンデバイス LLM による要約
- **sharingan CLI**: アプリへ命令を送る窓口。AI（agent skill）はこれを使う

## 必要環境

- macOS 26 以降（`SpeechAnalyzer` / Core Audio プロセスタップを使用）
- Swift 6 / Xcode 26
- 要約機能は Apple Intelligence が有効な Apple Silicon 機のみ

## 導入

```sh
./install.sh
```

`~/Applications/sharingan.app` と `~/.local/bin/sharingan` が入る。システム音声のキャプチャに安定した署名が必須のため、各マシンで利用者自身の Apple Development 証明書によりビルド＆署名する（署名済みバイナリは配布しない）。

## 使い方

メニューバーの目のアイコンから「セッションを開始」、または:

```sh
sharingan start                   # セッション開始(録音+文字起こし。アプリ未起動なら起動する)
sharingan set record off          # 録音だけ止める(文字起こしは続く)
sharingan set transcribe off      # 文字起こしだけ止める
sharingan status                  # 状態確認
sharingan latest                  # 最新の文字起こしファイルのパス
sharingan stop                    # 停止して保存
```

- セッションごとに `~/Library/Application Support/sharingan/sessions/<日時>/` へ `transcript.md`・`audio.m4a`（ステレオ: 左=自分、右=相手）・`summary.md` がまとまる。
- 確定した発話が `[時刻] 話者: 本文` の形式で `transcript.md` に追記される。話者は `自分`（マイク）と `相手`（システム音声）。
- 喋っている途中の暫定テキストは、アプリの「履歴を開く」→「ライブ」でリアルタイムに見える（ファイルには確定分のみ）。
- 過去セッションの閲覧・再生・削除・要約生成も「履歴を開く」から。

初回起動時:

- マイクと音声認識の許可ダイアログが出る。許可する。
- 日本語（ja-JP）の認識モデルが未ダウンロードなら自動で取得する（時間がかかる場合あり）。

## AI で質疑応答する

`distribution/sharingan/` の agent skill を導入すると、Claude Code が `sharingan` CLI でセッションを制御し、`sharingan latest` で得た transcript を読んで質疑応答できる。skill なしでも、`sharingan latest` のパスを AI に読ませれば同じことができる。

## 開発

```sh
make app    # debug ビルド + .app 組み立て + 署名
make run    # ビルドして起動
```

## 権限メモ

- **マイク**: `NSMicrophoneUsageDescription`
- **音声認識**: `NSSpeechRecognitionUsageDescription`
- **システム音声**: `NSAudioCaptureUsageDescription`。画面録画の許可は不要。
  - システム音声のキャプチャは、バイナリが安定した署名を持たないと**無音のまま失敗**する。相手側が文字起こしされない場合は署名を確認する。
