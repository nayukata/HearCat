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

### 更新する

導入と同じコマンドをもう一度実行すると新しいものに入れ替わる。アプリの設定の「アップデート」に、そのコマンド・更新の有無・「今すぐアップデート」のボタン・直近 5 件ぶんの変更履歴が出る。

新しいバージョンが出ていないかは、毎日 11 時に自動で確認する。11 時を過ぎてから Mac を開いた日は、その時点で確認する。見つかると画面右上にお知らせが出て、そこから更新用のコマンドをコピーできる（録音中は割り込まない）。確認するのは公開されている `Info.plist` のバージョン番号だけで、こちらからは何も送らない。設定のトグルで止められる。

何が変わったかは、アプリの「アップデート」と [CHANGELOG.md](CHANGELOG.md) の両方で読める。

## リリースの手順

`Sources/HearCatApp/Info.plist` の `CFBundleShortVersionString` を基準にする。アプリは設定の「アップデート」画面から main にある同じファイルを読み、手元より新しければ「新しい 0.10.1 があります」と表示する。変更履歴も同じく main の [CHANGELOG.md](CHANGELOG.md) を読む。

そのため、**アプリの中身を変えて main に入れるときは必ずバージョンを上げる**。上げ忘れると、実際には古いのに利用者の画面には「最新です」と出てしまう。README や設計メモだけの変更は、アプリの中身が変わらないので上げなくてよい。

### 番号の決め方

- 機能の追加や画面の作り替えが入るなら真ん中を上げる（0.10.1 → 0.11.0）
- 直しと細かい調整だけなら末尾を上げる（0.10.0 → 0.10.1）
- `CFBundleVersion`（内部の通し番号）は毎回 1 ずつ増やす
- `1.0.0` は、配布方式を「各自でビルド」から「署名済みバイナリの配布」へ切り替えたときに使う。それまでは `0.x.y` の範囲で上げる

### 手順

1. 前回のリリース以降のコミットを全部出す。`git log --oneline <前回リリースのコミット>..HEAD`
2. **その全部を [CHANGELOG.md](CHANGELOG.md) に書く。** 1 つでも落とすと、更新した利用者に説明のない変更が届く。書き方は CHANGELOG.md 冒頭の決まりに従う
3. `Info.plist` の 2 つの番号を上げる
4. `swift test` と `make app` を通す
5. 変更履歴とバージョンは同じコミットに入れる（更新を促しておいて中身が分からない状態にしない）
6. main へ push する。push した時点で、全利用者の設定画面に新しいバージョンと変更履歴が出る
7. 手元へ入れるのは `./install.sh`。実行前に `hearcat status` でセッション中でないことを確かめる（記録中に入れ替えると録音が途切れる）

### 変更履歴を書くとき

- 読み手は利用者。内部の作りではなく、画面で何が起きるかを書く
- 設定の「アップデート」画面には、新しい順に 5 件ぶんが出る
- 1 項目の形と文体の決まりは CHANGELOG.md の冒頭にまとめてある

### 配布用 dmg を作る

他の Mac へ配布してシステム音声キャプチャまで動かすには、Developer ID Application 証明書での署名と Apple の公証（notarization）が実質必須。`make dist` が「ビルド → 署名 → dmg 作成 → 公証申請 → staple → 検証」まで一気通貫で行う。フォールバックはなく、証明書または公証用プロファイルが無い場合はエラーで止まる（開発用の `make app` には影響しない）。

事前準備（初回のみ）:

1. Apple Developer Program に加入し、Developer ID Application 証明書を作って Keychain Access に登録する（`make dist` が自動検出する）
2. 公証用のキーチェーンプロファイルを作る:
   ```sh
   xcrun notarytool store-credentials HearCat --apple-id <Apple ID> --team-id <Team ID> --password <App用パスワード>
   ```
   プロファイル名を `HearCat` 以外にした場合は `make dist` 実行時に `NOTARY_PROFILE=<名前>` を指定する。

実行:

```sh
make dist    # .build/HearCat.dmg ができる（署名 + 公証 + staple 済み）
```

dmg を GitHub Releases などに置き、LP のダウンロードボタンからそこへリンクを貼る（現状の LP はソースからのビルド前提なので dmg 配布動線は未実装）。

## 使い方

メニューバーの猫アイコンからパネルを開いて「録音 ＋ 文字起こしを開始」、または:

```sh
hearcat start                   # セッション開始(録音+文字起こし。アプリ未起動なら起動する)
hearcat set record off          # 録音だけ止める(文字起こしは続く)
hearcat set transcribe off      # 文字起こしだけ止める
hearcat set autostart on        # ログイン時の自動起動を有効にする(設定画面からも可)
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
- 要約は既定でセッション停止時に自動生成される（Apple Intelligence が有効な Apple Silicon 機のみ。無効な環境や、すでに要約があるセッションでは何もしない）。自動/手動の切り替え設定はない。詳細ペインの「要約を生成／要約を再生成」ボタンは、自動生成に失敗した場合のリカバリや、内容を作り直したいときに使う。

### 設定（パネル → 設定）

- **ホットキー**: セッション開始/停止・録音・文字起こし・履歴ウィンドウ・設定を、他のアプリを使っている時でもキー1発で操作できる。録音/文字起こしのキーはセッション外で押すとその機能だけオンでセッションを開始する（デッドゾーンなし）
- **録音の音量**: 自分（マイク）と相手（システム音声）のミックスバランス。セッション中の変更もすぐ反映される
- **セッション名**: カレンダーの予定名を自動でセッション名にするかを切り替える。オンだと初回にカレンダーへのアクセス許可を求める
- **自動停止**: マイクとシステム音声の両方が5分間無音のとき、セッションを自動で終了する（既定オン）。停止し忘れの保険で、オフにもできる
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
