# HearCat

会議の声が、いま文字になる。

Mac のマイク（自分）とシステム音声（通話相手など）を、macOS 26 の `SpeechAnalyzer` でリアルタイムに日本語文字起こし・録音するメニューバー常駐アプリ。音声もテキストも Mac の外に送らない。文字起こしファイルを AI（Claude Code などの agent skill 対応アシスタント）に読ませて、会議中の質疑応答に使える。

構成は2つ:

- **HearCat.app**: 常駐エンジン。音声キャプチャ・文字起こし・録音・履歴の閲覧/再生/削除・オンデバイス LLM による要約
- **hearcat CLI**: アプリへの命令送信と、記録ファイルの読み書きを担う窓口。AI（agent skill）はこれ経由でセッションを触る

ランディングページは `web/` に Astro で置いてある（`pnpm build` で `web/dist/` に静的サイトが出て、Cloudflare Workers Static Assets で配信する）

## 必要環境

- macOS 26 以降（`SpeechAnalyzer` / Core Audio プロセスタップを使用）
- Swift 6 / Xcode 26（ソースからビルドする場合）
- 要約機能は Apple Intelligence が有効な Apple Silicon 機のみ

## 導入

### コマンド 1 行で入れる（git 不要）

```sh
curl -fsSL https://raw.githubusercontent.com/nayukata/HearCat/main/bootstrap.sh | bash
```

ソース一式を一時ディレクトリに取得して `install.sh` を実行する。

### ソースからビルドする

```sh
./install.sh
```

どちらの方法でも `~/Applications/HearCat.app` と `~/.local/bin/hearcat` が入る。システム音声のキャプチャに安定した署名が必須のため、各マシンで利用者自身の Apple Development 証明書によりビルド＆署名する。

### 配布用 dmg を作る

```sh
make dist    # .build/HearCat.dmg ができる
```

他の Mac へ配布してシステム音声キャプチャまで動かすには、Developer ID Application 証明書での署名と Apple の公証（notarization）が実質必須:

1. Apple Developer Program に加入し、Developer ID Application 証明書を作る（`make dist` が自動検出して署名に使う）
2. 公証を通す:
   ```sh
   xcrun notarytool submit .build/HearCat.dmg --keychain-profile <プロファイル名> --wait
   xcrun stapler staple .build/HearCat.dmg
   ```
3. dmg を GitHub Releases などに置き、LP のダウンロードボタンからそこへリンクを貼る（現状の LP はソースからのビルド前提なので dmg 配布動線は未実装）

## 使い方

メニューバーの猫アイコンからパネルを開いて「録音 ＋ 文字起こしを開始」、または:

```sh
hearcat start                   # セッション開始(録音+文字起こし。アプリ未起動なら起動する)
hearcat set record off          # 録音だけ止める(文字起こしは続く)
hearcat set transcribe off      # 文字起こしだけ止める
hearcat status                  # 状態確認
hearcat latest                  # 最新の文字起こしファイルのパス
hearcat stop                    # 停止して保存
hearcat sessions                # セッション一覧 (id / 日時 / 名前 / フォルダ の TSV)
hearcat read [<session>]        # 原文を stdout に出す(--summary / --cleaned / --tail N)
hearcat write-cleaned [<session>]  # 標準入力の清書を cleaned.md に書く(原文には触れない)
```

- セッションごとに `~/Library/Application Support/HearCat/sessions/<日時 [名前]>/` へ `<同名>.md`（文字起こし）・`<同名>.m4a`（モノラル: 自分と相手を自然にミックス）・`summary.md`（要約）がまとまる。フォルダに入れているセッションは `.../sessions/<フォルダ名>/<日時 [名前]>/` になる。
- 確定した発話が `[時刻] 話者: 本文` の形式で文字起こしファイルへ追記される。話者は `自分`（マイク）と `相手`（システム音声）
- 喋っている途中の暫定テキストは、パネルの「履歴」→「ライブ」でリアルタイムに見える（ファイルには確定分のみ）
- 実験的機能として、疑問文には「？」が付く。語尾の形（「〜ですか」等）と発話末尾のピッチ上昇（「大丈夫？」型）から推定する。
- カレンダーに登録した予定があれば、セッション名はその予定名で自動命名される。設定でオフにでき、macOS のカレンダーに追加した Google アカウントの予定も対象。
- 履歴サイドバーの検索欄で、セッション名・文字起こし・要約の本文を横断検索できる。
- 文字起こしに残った時刻をクリックすると、その位置から音声が再生される。
- セッションはドラッグ &amp; ドロップでフォルダに整理できる。右クリックから名前変更・フォルダ移動・削除ができる。Cmd/Shift+クリックで複数選択し、Delete キー か右クリックの「N 件を削除」でまとめて削除できる。
- 要約生成は、対象セッションの詳細ペインの「要約を生成」ボタンから行う（Apple Intelligence が有効な Apple Silicon 機のみ）。

### 設定（パネル → 設定）

- **ホットキー**: セッション開始/停止・録音・文字起こし・履歴ウィンドウ・設定を、他のアプリを使っている時でもキー1発で操作できる。録音/文字起こしのキーはセッション外で押すとその機能だけオンでセッションを開始する（デッドゾーンなし）
- **録音の音量**: 自分（マイク）と相手（システム音声）のミックスバランス。セッション中の変更もすぐ反映される
- **セッション名**: カレンダーの予定名を自動でセッション名にするかを切り替える。オンだと初回にカレンダーへのアクセス許可を求める
- **AI エージェント連携**: ワンクリックで 2 種類の skill（基本操作の `hearcat` と清書の `hearcat-clean`）と CLI を導入する（下記）

初回起動時:

- マイクと音声認識の許可ダイアログが出る。許可する。
- 日本語（ja-JP）の認識モデルが未ダウンロードなら自動で取得する（時間がかかる場合あり）

## AI で質疑応答する

設定画面の「AI エージェント連携」→「導入する」で、2 種類の skill の実体が共通の置き場（`~/.agents/skills/hearcat/` と `~/.agents/skills/hearcat-clean/`）に置かれ、使用中の各エージェント（`~/.claude` や `~/.codex` など）の skills フォルダには実体へのシンボリックリンクが張られる。CLI は `~/.local/bin/hearcat` へ配置される。Claude Code / Codex / Copilot / Gemini / Cursor など agent skill 対応の AI アシスタントが、`hearcat` CLI でセッションを制御し、`hearcat read` で得た文字起こしを読んで質疑応答できるようになる。

- **hearcat**: 録音の開始/停止、状態確認、文字起こしの読み出し、過去セッション参照など基本操作を担う。
- **hearcat-clean**: 音声認識の誤変換を、agent 側の LLM が会話の文脈から直して `cleaned.md` に書き戻す。書き込みは `hearcat write-cleaned` 経由に限定され、原文 `<session-id>.md` には物理的に届かない。

skill なしでも、`hearcat read` の内容を AI に渡せば同じことができる。

## 開発

```sh
make app    # debug ビルド + .app 組み立て + 署名
make run    # ビルドして起動
make dist   # 配布用 dmg
make icon   # アプリアイコンを生成し直す(デザイン変更時のみ)
```

## 権限メモ

- **マイク**: `NSMicrophoneUsageDescription`
- **音声認識**: `NSSpeechRecognitionUsageDescription`
- **システム音声**: `NSAudioCaptureUsageDescription`。画面録画の許可は不要。
  - システム音声のキャプチャは、バイナリが安定した署名を持たないと**無音のまま失敗**する。相手側が文字起こしされない場合は署名を確認する。
- **カレンダー**: `NSCalendarsFullAccessUsageDescription`。セッション名の自動命名を使うときのみ。オフにしていれば要求されない。App Sandbox を有効にする場合は `com.apple.security.personal-information.calendars` の entitlement も必要（現在は非サンドボックス構成）

## ライセンス

[PolyForm Noncommercial License 1.0.0](./LICENSE) を採用しています。個人利用・研究・非営利団体での利用は自由、商用利用と商用再配布は禁止です。
