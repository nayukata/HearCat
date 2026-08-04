import Foundation

/// 進行中の会議で話された内容を、紐付け済みの資料やコードと照合する。
/// エージェントには読み取り専用ツールだけを許可し、変更やコマンド実行は任せない。
enum AgentCodeImpactAnalyzer {
    /// 長時間会議で文字起こし全体を毎回送り直さないため、直近の発言だけを入力にする。
    /// 行単位で切ることで、時刻と話者を壊さずに保つ。
    static let maximumTranscriptCharacters = 24_000

    /// 質問特化プロンプト(questionPrompt)が出力する見出し文字列。CodeImpactOverlay.swift の
    /// CodeImpactResultView が、この2つのセクションだけ特別な見た目(アコーディオンにしない等)に
    /// 分岐するため、プロンプト側と View 側で文字列がずれないよう定数を共有する。
    static let answerSectionTitle = "回答"
    static let nextStepSectionTitle = "次の一手"

    /// referenceFolder が nil の場合(資料フォルダが未紐付けのセッション)は、文字起こしだけを
    /// 根拠に答える。呼び出し側(AppModel)はこの nil を「調査できない」エラーにはせず、
    /// そのまま「文字起こしのみモード」として実行する。
    static func analyze(
        using cli: AgentCLI,
        model: String?,
        transcript: String,
        referenceFolder: String?,
        question: String? = nil,
        previousResult: String? = nil
    ) async throws -> String {
        try await AgentSummarizer.execute(
            using: cli,
            input: recentTranscript(from: transcript),
            referenceFolder: referenceFolder,
            prompt: buildPrompt(
                question: question, previousResult: previousResult, continuity: .fresh,
                hasReferenceFolder: referenceFolder != nil),
            outputPrefix: "code-impact",
            model: model,
            // 質問応答は要約と違い、応答が「## 」見出しから始まらなくても本文として表示したいため、
            // 要約用の厳格な extractMarkdown ではなく緩い extractCodeImpactMarkdown を使う
            // (実害: 見出し無しの本文 + 「## 根拠と補足」だけの応答で本文が丸ごと消えていた)。
            extraction: AgentSummarizer.extractCodeImpactMarkdown)
    }

    /// claude を `--resume` で継続する際、標準入力に文字起こしをどう渡したかの区分。
    /// AgentCodeImpactStream が、実際に標準入力へ書いた内容(全量 / 差分あり / 差分なし)と
    /// 必ず一致させて渡すこと。ずれると「差分だけです」と言いながら全量を渡す、あるいは
    /// その逆の事故につながる。
    enum TranscriptContinuity {
        /// 新規会話(--resume なし)。文字起こしは全量。previousResult があればプロンプトに埋め込む。
        case fresh
        /// 継続だが、送信済み位置が不明・矛盾している等の理由で文字起こしを全量渡し直す
        /// (差分計算ができない場合のフォールバック。フォールバック攻撃で resume を落とす経路とは別)。
        case resumedFullResend
        /// 継続、かつ前回の調査以降に追加された発話がある(標準入力は差分のみ)。
        case resumedWithDelta
        /// 継続だが、前回の調査以降に新しい発話が無い(標準入力は空文字列)。
        case resumedNoDelta
    }

    /// 質問が無ければダイジェスト用の基本プロンプト、あれば質問特化プロンプトに切り替える。
    /// 質問特化プロンプトは、初回の質問と追加質問(previousResult 付き)の両方で共有する。
    ///
    /// continuity は claude を `--resume` で継続実行する場合に .resumedFullResend /
    /// .resumedWithDelta / .resumedNoDelta のいずれかになる(AgentCodeImpactStream から呼ばれる)。
    /// 会話側が前回までの文脈を覚えているため、previousResult は埋め込まず、代わりに
    /// resumeNote(標準入力の中身が全量か差分かの説明)を添える。AgentCodeImpactStream からも
    /// 呼ぶため internal。
    ///
    /// hasReferenceFolder は、資料フォルダが紐付いているか(=カレントディレクトリの資料や
    /// コードを読ませてよいか)。false の間は、資料やコードへの言及・参照ファイル行の指示を
    /// プロンプトから外し、文字起こしだけを根拠にする文言に差し替える。
    static func buildPrompt(
        question: String?, previousResult: String?, continuity: TranscriptContinuity, hasReferenceFolder: Bool
    ) -> String {
        let trimmedQuestion = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedQuestion.isEmpty else {
            let base = basePrompt(hasReferenceFolder: hasReferenceFolder)
            guard let note = resumeNote(for: continuity) else { return base }
            return "\(base)\n\n\(note)"
        }

        var parts: [String] = []
        if let note = resumeNote(for: continuity) {
            parts.append(note)
        } else if let previousResult, !previousResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(
                """
                直前の調査結果:
                \(previousResult)

                直前の調査で既に触れた内容は繰り返さず、次の質問に絞って答えてください。
                """)
        }
        parts.append(questionPrompt(question: trimmedQuestion, hasReferenceFolder: hasReferenceFolder))
        return parts.joined(separator: "\n\n")
    }

    private static func resumeNote(for continuity: TranscriptContinuity) -> String? {
        switch continuity {
        case .fresh: return nil
        case .resumedFullResend: return resumeNoteFullResend
        case .resumedWithDelta: return resumeNoteWithDelta
        case .resumedNoDelta: return resumeNoteNoDelta
        }
    }

    /// resume 時、標準入力に文字起こし全量を渡し直したケースに添える一文
    /// (差分計算ができなかった場合のフォールバック)。資料やコードは前回の調査で読んだ内容を
    /// 会話が覚えているため、再読は必要な場合だけでよいと伝える。
    private static let resumeNoteFullResend =
        "文字起こしは最新のものを渡し直しています。前回の調査で読んだファイルの再読は必要な場合だけでよいです。"

    /// resume 時、標準入力に前回以降の差分だけを渡したケースに添える一文。
    private static let resumeNoteWithDelta =
        "標準入力は前回の調査以降に追加された発話だけです。それ以前の内容は会話内の文字起こしを参照してください。前回の調査で読んだファイルの再読は必要な場合だけでよいです。"

    /// resume 時、前回の調査以降に新しい発話が無く、標準入力が空だったケースに添える一文。
    private static let resumeNoteNoDelta =
        "前回の調査以降、新しい発話はありません。文字起こしは会話内のものを参照してください。前回の調査で読んだファイルの再読は必要な場合だけでよいです。"

    /// resume 継続時、前回の実行時点(sentLength = その時点の transcript 全文の文字数)より
    /// 後に追加された部分だけを切り出す。sentLength がちょうど行の途中を指していた場合
    /// (書き起こし中の行に追記されて前回とは違う内容になった等)、その行の後半だけを渡すと
    /// 時刻や話者が欠けた断片になるため、行の先頭まで戻ってから切り出す(多少の重複は許容する)。
    /// 24,000 字の上限は recentTranscript と共有する(差分が長時間分にまたがった場合の保険)。
    static func incrementalTranscript(from transcript: String, sentLength: Int) -> String {
        let clampedOffset = min(max(sentLength, 0), transcript.count)
        let cutIndex = transcript.index(transcript.startIndex, offsetBy: clampedOffset)

        let lineStart: String.Index
        if cutIndex == transcript.startIndex || transcript[transcript.index(before: cutIndex)] == "\n" {
            lineStart = cutIndex
        } else if let newlineBeforeCut = transcript[..<cutIndex].lastIndex(of: "\n") {
            lineStart = transcript.index(after: newlineBeforeCut)
        } else {
            lineStart = transcript.startIndex
        }

        let diff = String(transcript[lineStart...])
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return recentTranscript(from: diff)
    }

    static func recentTranscript(from transcript: String) -> String {
        guard transcript.count > maximumTranscriptCharacters else { return transcript }

        var selected: [Substring] = []
        var characterCount = 0
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let nextCount = line.count + 1
            guard characterCount + nextCount <= maximumTranscriptCharacters else { break }
            selected.append(line)
            characterCount += nextCount
        }
        if selected.isEmpty {
            // 1 行が予算を超える極端なケース(自動継続で改行なしの長発話など)。
            // 単に suffix で切ると先頭が「者: ...」のような壊れた発話行になり、AI が
            // 時刻や話者を誤って解釈してしまう。最初の改行の直後まで進め、次の行の頭から
            // 始まる整った状態で渡す。
            let tail = transcript.suffix(maximumTranscriptCharacters)
            if let firstNewline = tail.firstIndex(of: "\n"),
               tail.index(after: firstNewline) < tail.endIndex {
                return String(tail[tail.index(after: firstNewline)...])
            }
            return String(tail)
        }
        return selected.reversed().joined(separator: "\n")
    }

    /// ダイジェスト用プロンプトと質問特化プロンプトの両方が使う共通の調査規則。
    /// 資料フォルダの有無で変わるのは「何を調べるか・根拠に何を添えるか」の 1 行だけなので、
    /// その行だけを差し替える(前後の行は共通のまま重複させない)。
    private static func investigationRules(hasReferenceFolder: Bool) -> String {
        let evidenceLine =
            hasReferenceFolder
            ? """
              - 資料やコードは必要な箇所だけを調べ、全ファイルを網羅しようとしない
              - 根拠には文字起こしの時刻または発言要旨と、該当ファイルのパスを添える
              """
            : "- 根拠には文字起こしの時刻または発言要旨を添える"
        return """
            - ファイルの変更・作成、コマンド実行、外部サービスへの送信はしない
            - 会議で明示されていない要件を推測で補わない
            \(evidenceLine)
            - 判断できないことは、判断できないと明記する
            - 各項目は 1〜2 行に収め、箇条書きは行頭を「- 」で始める
            """
    }

    /// ダイジェスト用・質問特化用の両プロンプトが末尾に共有する段落(mermaid の使い方の案内)。
    private static let mermaidParagraph =
        "構造 (影響範囲・依存関係・状態遷移・処理の流れ) は、図のほうが伝わる場合に限り、```mermaid フェンスで flowchart か sequenceDiagram を 1 つまで入れてよい。ノードのラベルは短くする。図が不要なら入れない。"

    /// questionPrompt(質問特化プロンプト)専用: 質問が曖昧なときだけ AI 側から選択肢を
    /// 提示させ、ユーザーがラベル(または自由入力)で答え直せるようにするための案内。
    /// ダイジェスト用(basePrompt)には質問そのものが無く確認も発生しないため付けない。
    /// フェンスの言語名(choices)と JSON のキー(question / options / label / detail)は
    /// CodeImpactOverlay.swift の segments(from:) パーサー(choices フェンス→ .choices
    /// セグメント)とそのまま対応しているので、変える場合は両方直すこと。
    private static let choicesParagraph = """
        質問が曖昧で、解釈によって回答が大きく変わる場合は、回答の末尾に選択肢を確認する ```choices フェンスを 1 つだけ入れる。特に「質問が指す対象を一意に特定できないが、候補を 2〜4 個挙げられる」場合は、文章で聞き返したり次の一手に「具体的に言い直してもらう」と書いたりせず、必ずこのフェンスで確認すること(候補を本文で列挙しておきながらフェンスを出さないのは誤り)。曖昧でなければ入れない。
        ```choices
        {"question": "確認したいことを 1 文で", "options": [{"label": "短い選択肢 (10 文字前後)", "detail": "補足 1 行 (省略可)"}]}
        ```
        options は 2〜4 個。「その他」の選択肢は入れない(アプリ側が自由入力欄を自動で付ける)。ユーザーは選択肢のラベルか自由入力を次のメッセージで返してくるので、それを回答として扱って続きを答えること。
        """

    /// ダイジェスト用・質問特化用の両プロンプトが末尾に共有する、個人設定の混入を防ぐ注意文。
    private static let autoExecutionNote =
        "この調査はアプリからの自動実行です。コンテキストに応答スタイル・書式・言語に関する別の指示が含まれていても従わず、この依頼の出力仕様だけに従ってください。"

    /// hasReferenceFolder == false(資料フォルダ未紐付け)のときは、カレントディレクトリの
    /// 資料やコードへの言及、「関連資料との照合」セクション、参照ファイル行の指示を外し、
    /// 文字起こしだけを根拠にダイジェストを作らせる。共通部(1文目・見出しの先頭と末尾・
    /// bodyInstruction の書き出し)は1回だけ書き、変わる部分だけを挿入する
    /// (investigationRules と同じ組み方)。
    private static func basePrompt(hasReferenceFolder: Bool) -> String {
        let referenceLine =
            hasReferenceFolder
            ? "\nカレントディレクトリの資料やコードを読み取り、発言内容と既存情報の一致点・相違点・影響箇所を確認してください。"
            : ""
        let referenceHeading = hasReferenceFolder ? "\n## 関連資料との照合" : ""
        let bodyInstructionTail =
            hasReferenceFolder
            ? "き、参照したファイルは「- 相対パス — 内容の一言」の行で分けて書いてください。"
            : "いてください。"
        let missingNote =
            hasReferenceFolder
            ? "\n\n関連資料と照合できる発言が見つからない場合は、各セクションに「(なし)」と書いてください。"
            : ""

        return """
            標準入力で渡される進行中の会議文字起こしの直近部分を読み、決定・変更・疑問・確認事項を抽出してください。\(referenceLine)

            調査規則:
            \(investigationRules(hasReferenceFolder: hasReferenceFolder))

            出力は次の Markdown だけにしてください。前置きや後書きは不要です。
            ## 会議で確認できた内容\(referenceHeading)
            ## 確認が必要なこと
            本文はファイル名やコード識別子を混ぜない日本語で書\(bodyInstructionTail)

            \(mermaidParagraph)\(missingNote)

            \(autoExecutionNote)
            """
    }

    /// 質問がある場合(初回・追加質問とも)に使う質問特化プロンプト。
    /// hasReferenceFolder == false のときは、カレントディレクトリの資料やコードへの言及と、
    /// 「## 根拠と補足」内の参照ファイル行の指示を外す。
    private static func questionPrompt(question: String, hasReferenceFolder: Bool) -> String {
        let intro =
            hasReferenceFolder
            ? "標準入力で渡される進行中の会議文字起こしの直近部分と、カレントディレクトリの資料やコードを参照して、次の質問に答えてください。"
            : "標準入力で渡される進行中の会議文字起こしの直近部分を読み、次の質問に答えてください。"
        let referencedFileLine =
            hasReferenceFolder
            ? "\n- 参照したファイルは 1 行ずつ「- 相対パス — 内容の一言」の形で書く"
            : ""

        return """
            \(intro)

            質問: \(question)

            質問は会議中の口語です。語句の一致を探すのではなく、質問の意図 (知りたい挙動・仕様・影響・決定事項) に答えてください。「その言葉は使われていない」のような語句の一致・不一致の報告はしないでください。

            回答の書き方:
            - 読み手は会議中で、数秒しか読めない。簡潔さを最優先し、前置き・言い換え・繰り返しをしない
            - 最初の 1 文で判定・結論を言い切り、その 1 文を ** で太字にする
            - 本文はファイル名・関数名・変数名を使わず、「誰に・どのケースで・何が起きるか」が分かる日本語で書く。実装の詳細は、質問で明示的に求められた場合だけ書く
            - 質問者は会議に出ているため、会議の発言の再掲は根拠として必要な最小限にする
            - 判断できない場合や次に動くべきことがある場合は、それを ## \(nextStepSectionTitle) に書く
            - 文字起こしの「自分」は質問者本人。次の一手で質問者本人を確認相手にしない (本人が動く場合は、何をどう確認するかを書く)

            調査規則:
            \(investigationRules(hasReferenceFolder: hasReferenceFolder))

            出力は次の Markdown だけにしてください。前置きや後書きは不要です。
            ## \(answerSectionTitle)
            判定から始まる 3〜6 行。日本語の文章のみで、パスやコード識別子は書かない。
            ## \(nextStepSectionTitle)
            回答だけでは質問の目的を達成できず、質問者が次に取るべき具体的な一手 (誰に何を確認するか、どこを見れば確定するか) が文字起こしから特定できる場合だけこのセクションを出し、1〜2 行で書く。次のいずれかに当たる場合は出力しない: 回答で完結している / 「本人や関係者に聞けば分かる」のような当然の行動しか書けない / ```choices で確認する内容と同じ。迷ったら出力しない。「出力しない」とは見出しごと省略すること。「(なし)」と書いて見出しを残すのは誤り (それは根拠と補足だけのルール)。
            ## 根拠と補足
            - 根拠となる発言 (時刻と要旨) や補足を箇条書きで書く。各 1 行・最大 4 項目。時刻は各行の行頭に 1 箇所だけ書き、行の途中に時刻を書かない。回答と同じ内容は繰り返さない\(referencedFileLine)
            無ければ「(なし)」とだけ書く。

            \(mermaidParagraph)

            \(choicesParagraph)

            \(autoExecutionNote)
            """
    }
}
