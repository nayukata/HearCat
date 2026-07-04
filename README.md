# sharingan

Mac のマイク（自分）と システム音声（通話相手など）を、macOS 26 の `SpeechAnalyzer` でリアルタイムに日本語文字起こしし、`transcripts/` に追記し続ける CLI。追記されたファイルを AI（Claude Code など）に読ませて、会話の質疑応答に使う。

## 必要環境

- macOS 26 以降（`SpeechAnalyzer` / Core Audio プロセスタップを使用）
- Swift 6 / Xcode 26

## 使い方

実行：

```sh
swift run sharingan
```

- 起動すると `transcripts/<日時>.md` が作られ、確定した発話が `[時刻] 話者: 本文` の形式で追記される。
- 話者は `自分`（マイク）と `相手`（システム音声）の2種類。
- 停止は `Ctrl-C`。末尾の発話を確定してからファイルを閉じる。

初回起動時：

- マイクと音声認識の許可ダイアログが出る。許可する。
- 日本語（ja-JP）の認識モデルが未ダウンロードなら自動で取得する（時間がかかる場合あり）。

## AI で質疑応答する

録音中に別ターミナルで、このディレクトリを対象に AI を開き、最新の `transcripts/<日時>.md` を参照させる。例：「相手がさっき言っていた見積もりの話をまとめて」。

## 権限メモ

- **マイク**：`NSMicrophoneUsageDescription`
- **音声認識**：`NSSpeechRecognitionUsageDescription`
- **システム音声**：`NSAudioCaptureUsageDescription`。画面録画の許可は不要。
  - システム音声のキャプチャは、バイナリが安定した署名を持たないと**無音のまま失敗**する。相手側が文字起こしされない場合は署名を確認する。
