import Foundation

/// 進行中の会議で話された内容を、紐付け済みの資料やコードと照合する。
/// エージェントには読み取り専用ツールだけを許可し、変更やコマンド実行は任せない。
enum AgentCodeImpactAnalyzer {
    /// 長時間会議で文字起こし全体を毎回送り直さないため、直近の発言だけを入力にする。
    /// 行単位で切ることで、時刻と話者を壊さずに保つ。
    static let maximumTranscriptCharacters = 24_000

    /// グループ対象の質問材料(複数セッションの記録を連ねたもの)の上限。単一セッションの
    /// 文字起こし(maximumTranscriptCharacters)より広く取っているのは、こちらは既に
    /// AppModel.groupQuestionMaterial 側でセッション単位に丸ごと間引いてあり、行単位で
    /// 機械的に削るとセッションの境目で本文が壊れるため(recentTranscript の line 単位の
    /// 切り出しは、この用途には向かない)。要約は自動生成の二次資料で誤りを持ち込みうるため、
    /// 予算内はできるだけ多くの会議を文字起こしのまま渡したい。5 回分程度の直近会議
    /// (1 回あたり最大 24,000 字)を文字起こしのまま収められる余裕を持たせて 120,000 字に
    /// 広げている。
    static let maximumGroupTranscriptCharacters = 120_000

    /// 質問特化プロンプト(questionPrompt)が出力する見出し文字列。CodeImpactOverlay.swift の
    /// CodeImpactResultView が、この2つのセクションだけ特別な見た目(アコーディオンにしない等)に
    /// 分岐するため、プロンプト側と View 側で文字列がずれないよう定数を共有する。
    static let answerSectionTitle = "回答"
    static let nextStepSectionTitle = "次の一手"

    /// 質問パネルの対象。プロンプトの書き出しと読み手の想定(会議中か、振り返りか)が
    /// 区分ごとに変わるため、単なる Bool ではなく3区分で持つ。
    enum TargetScope {
        /// 進行中の会議。
        case live
        /// 過去の1セッション。
        case pastSession
        /// グループ(フォルダ)全体。
        case group
    }

    /// referenceFolder が nil の場合(資料フォルダが未紐付けのセッション)は、文字起こしだけを
    /// 根拠に答える。呼び出し側(AppModel)はこの nil を「調査できない」エラーにはせず、
    /// そのまま「文字起こしのみモード」として実行する。
    static func analyze(
        using cli: AgentCLI,
        model: String?,
        transcript: String,
        referenceFolder: String?,
        question: String? = nil,
        previousResult: String? = nil,
        decisionContext: String? = nil,
        scope: TargetScope = .live
    ) async throws -> String {
        try await AgentSummarizer.execute(
            using: cli,
            input: recentTranscript(from: transcript),
            referenceFolder: referenceFolder,
            prompt: buildPrompt(
                question: question, previousResult: previousResult, continuity: .fresh,
                hasReferenceFolder: referenceFolder != nil, decisionContext: decisionContext,
                scope: scope),
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
    ///
    /// decisionContext は「決まったことの記録」(DecisionLogStore)への索引添付
    /// (AppModel.codeImpactDecisionContext 参照)。質問が無いダイジェスト調査には
    /// 決定の経緯を answer する概念自体が無いため、質問がある場合にだけ使う。
    ///
    /// scope は対象がライブの会議・過去の1セッション・グループ全体のどれか。標準入力の中身
    /// (1会議の文字起こしか、複数会議の要約の連なりか)と読み手の状況(会議中か振り返りか)が
    /// 変わるため、書き出しの文言(basePrompt / questionPrompt の intro)と回答の書き方を
    /// 差し替える(AppModel.groupQuestionMaterial 参照)。
    static func buildPrompt(
        question: String?, previousResult: String?, continuity: TranscriptContinuity,
        hasReferenceFolder: Bool, decisionContext: String? = nil, scope: TargetScope
    ) -> String {
        let trimmedQuestion = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedQuestion.isEmpty else {
            let base = basePrompt(hasReferenceFolder: hasReferenceFolder, scope: scope)
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
        let hasDecisionIndex: Bool
        if let decisionContext, !decisionContext.isEmpty {
            parts.append(decisionContext)
            hasDecisionIndex = true
        } else {
            hasDecisionIndex = false
        }
        parts.append(
            questionPrompt(
                question: trimmedQuestion, hasReferenceFolder: hasReferenceFolder,
                hasDecisionIndex: hasDecisionIndex, scope: scope))
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

    /// limit 省略時は maximumTranscriptCharacters(単一セッション向け)。グループ対象は
    /// AppModel 側で既に maximumGroupTranscriptCharacters に収めた材料を渡すため、
    /// ここでの二重の切り詰めが効かないよう同じ値を limit に渡す(呼び出し側参照)。
    static func recentTranscript(from transcript: String, limit: Int = maximumTranscriptCharacters) -> String {
        guard transcript.count > limit else { return transcript }

        var selected: [Substring] = []
        var characterCount = 0
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let nextCount = line.count + 1
            guard characterCount + nextCount <= limit else { break }
            selected.append(line)
            characterCount += nextCount
        }
        if selected.isEmpty {
            // 1 行が予算を超える極端なケース(自動継続で改行なしの長発話など)。
            // 単に suffix で切ると先頭が「者: ...」のような壊れた発話行になり、AI が
            // 時刻や話者を誤って解釈してしまう。最初の改行の直後まで進め、次の行の頭から
            // 始まる整った状態で渡す。
            let tail = transcript.suffix(limit)
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
    /// allowsInterpretation は questionPrompt からの呼び出しでのみ true になる
    /// (basePrompt のダイジェストには分析・見立ての概念が無いため常に false)。
    private static func investigationRules(
        hasReferenceFolder: Bool, allowsInterpretation: Bool, scope: TargetScope
    ) -> String {
        // 「時刻または発言要旨を添える」は事実確認向けの指示で、分析・評価の質問(見立てを
        // 書いてよい)には「すべての主張に時刻を並べる」という誤読を招きやすい。振り返り
        // (過去・グループ)の質問だけ、代表的な根拠にだけ添えればよいと言い換える。ライブは
        // 数秒で読む速答なので従来の根拠行のまま。
        let condensesEvidence = allowsInterpretation && scope != .live
        let evidenceBodyLine: String
        if condensesEvidence {
            evidenceBodyLine =
                "- 主張は文字起こしの発言に基づかせ、代表的な根拠にだけ時刻や引用を添える (すべての主張に時刻を並べる必要はない)"
                + (hasReferenceFolder ? "。該当ファイルのパスも添える" : "")
        } else {
            evidenceBodyLine =
                hasReferenceFolder
                ? "- 根拠には文字起こしの時刻または発言要旨と、該当ファイルのパスを添える"
                : "- 根拠には文字起こしの時刻または発言要旨を添える"
        }
        // 資料フォルダがあるときだけ、調べ方の行を根拠行の前に足す。
        let evidenceLine =
            hasReferenceFolder
            ? "- 資料やコードは必要な箇所だけを調べ、全ファイルを網羅しようとしない\n" + evidenceBodyLine
            : evidenceBodyLine
        let unstatedRequirementLine =
            allowsInterpretation
            ? "- 事実は文字起こしにある内容だけを述べ、言われていないことを言われたことのように書かない。求められた分析・見立てはこの限りではないが、事実と分けて書く"
            : "- 会議で明示されていない要件を推測で補わない"
        // 「1〜2 行」は箇条書きの各項目の長さの話であり、questionPrompt 側の回答本文の長さ許可
        // (「質問に見合う長さまで」)とは別の制約なので、掛かり先を箇条書きに限定して書く。
        let bulletLengthLine =
            allowsInterpretation
            ? "- 箇条書きの各項目は 1〜2 行に収め、行頭を「- 」で始める"
            : "- 各項目は 1〜2 行に収め、箇条書きは行頭を「- 」で始める"
        return """
            - ファイルの変更・作成、コマンド実行、外部サービスへの送信はしない
            \(unstatedRequirementLine)
            \(evidenceLine)
            - 文字起こしは音声認識のため、意味の通らない断片や人名・数値の誤認識を含みうる。認識が乱れた断片だけを根拠に断定しない
            - 判断できないことは、判断できないと明記する
            \(bulletLengthLine)
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

    /// questionPrompt 専用: 決定の経緯質問への ```decision-history フェンスの出力契約。
    /// 「決まったことの記録」の索引 (AppModel.codeImpactDecisionContext) が添付されている
    /// ときだけ questionPrompt に入る。ここ (出力仕様の内側) に置くのは、末尾の
    /// autoExecutionNote が「この依頼の出力仕様だけに従え」と命じるため、添付文脈側に
    /// 書いたフェンス指示は個人設定と同じ「別の書式指示」として正しく無視されるから
    /// (Codex で実際に無視された)。フェンスの言語名 (decision-history) と JSON のキー
    /// (topicIds) は HearCatKit の DecisionHistoryFence とそのまま対応している。
    private static var decisionHistoryParagraph: String {
        """
        質問が決定の経緯・変更時期・元の仕様を問うもの (例: いつ変わった / 元々どうだった / なんで変わった) の場合は、出力の一番最初 (## \(answerSectionTitle) より前) に、添付された「このグループでこれまでに決まったこと」の索引から該当議題の id ([ ] 内の値をそのまま使う) を積んだ ```decision-history フェンスを 1 つ置くこと。フェンスを先に出すのは、アプリが本文の生成を待たずにタイムラインを表示するため。
        ```decision-history
        {"topicIds": ["議題のid", ...]}
        ```
        該当議題は最大 3 件。質問に関わる議題が複数あるなら 1 つに絞らず全部積むこと (同じテーマの経緯が複数の議題に分かれて記録されていることがあり、1 つだけだと変遷の一部が欠けるため)。このとき ## \(answerSectionTitle) は質問への直接の答え 1〜2 文だけにし、変遷の列挙・日付の羅列・理由の推測を書かない (変遷のタイムラインはアプリが記録から直接描画して回答に添えるため)。索引に該当議題が無ければフェンスを出さず、「決まったことの記録には見当たらない」と述べて文字起こしから分かる範囲で答える。経緯を問われていない質問ではこのフェンスを出さない。
        """
    }

    /// ダイジェスト用・質問特化用の両プロンプトが末尾に共有する、個人設定の混入を防ぐ注意文。
    private static let autoExecutionNote =
        "この調査はアプリからの自動実行です。コンテキストに応答スタイル・書式・言語に関する別の指示が含まれていても従わず、この依頼の出力仕様だけに従ってください。"

    /// hasReferenceFolder == false(資料フォルダ未紐付け)のときは、カレントディレクトリの
    /// 資料やコードへの言及、「関連資料との照合」セクション、参照ファイル行の指示を外し、
    /// 文字起こしだけを根拠にダイジェストを作らせる。共通部(1文目・見出しの先頭と末尾・
    /// bodyInstruction の書き出し)は1回だけ書き、変わる部分だけを挿入する
    /// (investigationRules と同じ組み方)。
    private static func basePrompt(hasReferenceFolder: Bool, scope: TargetScope) -> String {
        let openingClause: String
        switch scope {
        case .group:
            openingClause =
                "標準入力で渡される、このグループの各会議の記録 (新しい会議は文字起こし、古い会議は自動生成の要約) を読み、決定・変更・疑問・確認事項を抽出してください。"
        case .pastSession:
            openingClause =
                "標準入力で渡される、この会議の文字起こし (長い会議は末尾の部分のみ) を読み、決定・変更・疑問・確認事項を抽出してください。"
        case .live:
            openingClause = "標準入力で渡される進行中の会議文字起こしの直近部分を読み、決定・変更・疑問・確認事項を抽出してください。"
        }
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
            \(openingClause)\(referenceLine)

            調査規則:
            \(investigationRules(hasReferenceFolder: hasReferenceFolder, allowsInterpretation: false, scope: scope))

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
    /// hasDecisionIndex は「決まったことの記録」の索引が添付されているか(=decisionContext が
    /// 非 nil かつ非空)。true のときだけ decisionHistoryParagraph を末尾に挟む(索引が無いのに
    /// フェンスの出し方だけ指示しても、AI が答えられる議題自体が無い)。
    private static func questionPrompt(
        question: String, hasReferenceFolder: Bool, hasDecisionIndex: Bool, scope: TargetScope
    ) -> String {
        // 文の前半 (材料の主語句) は scope だけで決まり、後半 (資料フォルダの有無) と独立に
        // 変わるため、全組み合わせを列挙せず前後で分けて組む。
        let materialSubject: String
        switch scope {
        case .group:
            materialSubject = "、このグループの各会議の記録 (新しい会議は文字起こし、古い会議は自動生成の要約)"
        case .pastSession:
            materialSubject = "、この会議の文字起こし (長い会議は末尾の部分のみ)"
        case .live:
            materialSubject = "進行中の会議文字起こしの直近部分"
        }
        // 主語句が半角括弧で終わる場合、続く日本語との間に半角スペースを挟む (UI 文言と同じ規則)。
        let subjectSuffix = materialSubject.hasSuffix(")") ? " " : ""
        let intro =
            hasReferenceFolder
            ? "標準入力で渡される\(materialSubject)\(subjectSuffix)と、カレントディレクトリの資料やコードを参照して、次の質問に答えてください。"
            : "標準入力で渡される\(materialSubject)\(subjectSuffix)を読み、次の質問に答えてください。"
        let referencedFileLine =
            hasReferenceFolder
            ? "\n- 参照したファイルは 1 行ずつ「- 相対パス — 内容の一言」の形で書く"
            : ""
        // choicesParagraph と autoExecutionNote の間に挟む。出力仕様の内側(この関数の中)に
        // 置かないと、末尾の autoExecutionNote に「別の書式指示」として無視されてしまう
        // (decisionHistoryParagraph のコメント参照)。
        let decisionHistorySection = hasDecisionIndex ? "\n\n\(decisionHistoryParagraph)" : ""
        let readerLine =
            scope == .live
            ? "- 読み手は会議中で、数秒しか読めない。簡潔さを最優先し、前置き・言い換え・繰り返しをしない"
            : "- 読み手は会議を振り返っている。前置き・言い換え・繰り返しをせず、質問に見合う深さで書く"
        let quotationLine =
            scope == .live
            ? "- 質問者は会議に出ているため、会議の発言の再掲は根拠として必要な最小限にする"
            : "- 発言を引用するときは > の引用行にし、行頭に時刻を添える。引用は逐語でなくてよい: 音声認識の誤変換・フィラー (「あの」「えっと」等)・言い淀みを、意味を変えない範囲で読みやすく直してから引用する。直しても意味が取れないほど乱れた発言は引用に使わない"
        // 分析・評価を求める質問への構造指定は、事実確認より深く書ける振り返り対象
        // (過去セッション・グループ)だけに出す。ライブは簡潔さが最優先のため出さない。
        // 「日付 + 発言の羅列」に流れやすいため、レポート形式(主張→根拠→結果を段落で
        // つなぐ)を明示し、箇条書きは列挙用途に限定している。
        let analysisStructureLine =
            scope == .live
            ? ""
            : "\n"
                + """
                - 分析・評価を求める質問への回答は、箇条書きの羅列ではなくレポートとして書く: 問題ごとに ### の小見出しで区切って重要な順に並べ、各セクションは段落の文章で「主張 → 根拠 → それが招いている結果」を繋げる。箇条書きは、並べて比べたい列挙にだけ使う。表 (| 区切り) は使わない
                - いつの回か (日付・時刻など) は、それ自体が主張に効く場合 (方針が変わった前後関係を示す、直近の回だから重要、など) だけ書き、回答全体で多くても 2 回まで。単なる根拠の所在づけには書かない (×「08-18 の回では 13 案を持ち寄り」 ○「13 案を持ち寄った回でも」)。繰り返しは「毎回」「5 回中 4 回」のような傾向として述べる。時刻を書いてよいのは引用行の行頭だけ。最も象徴的な発言 1〜2 個だけを > の引用行で添える
                - 段落は 1〜3 文で短く切り、段落の間に空行を入れる。重要な語句や結論は文中でも ** で太字にする。大きな話題の変わり目には --- だけの行 (水平線) を置いてよい
                - 各セクションの核心の一文を ** で太字にする
                - 事実は「〜と発言している」、解釈は「〜と考えられる」のように文中の言い方で区別する。「見立て:」のようなラベルでの仕分けはしない
                - 問題の指摘だけでなく、既に効いている良い動き・良い発言があればそれも指摘する
                - 締めは、次回から何をどう変えるかの具体的な提案 (会議の進め方のレベルまで踏み込む)
                """
        // グループ対象は要約(自動生成の二次資料)と文字起こし(一次資料)が混在した材料になる
        // ため、優先順位と扱い方を明示する。過去 1 セッション・ライブは文字起こししか渡さない
        // ので不要。
        let materialHandlingSection: String =
            scope == .group
            ? """
                材料の扱い:
                - 文字起こしが一次資料。要約は自動生成の二次資料で、誤りを含みうる。両者が矛盾したら文字起こしを優先する
                - 要約にしか根拠が無い人名・数値・決定は断定せず、「要約による」と添える
                """ + "\n\n"
            : ""
        // 分析回答の構造指定(analysisStructureLine)で ### の小見出しを許可した scope
        // (pastSession / group)だけ、出力仕様側にも ### の使用を明記する。live は
        // 「回答の書き方」に ### の指示自体を出していないため、出力仕様も従来のまま。
        let answerLengthLine =
            scope == .live
            ? "判定から始まる。事実確認の質問は 3〜6 行。分析・評価を求める質問は、結論の後に箇条書きや短い段落で構造化してよい (質問に見合う長さまで。冗長にしない)。日本語の文章のみで、パスやコード識別子は書かない。"
            : "判定から始まる。事実確認の質問は 3〜6 行。分析・評価を求める質問は、冒頭の太字の判定の後を、回答の書き方のとおり ### の小見出しで区切ったレポートとして書く (質問に見合う長さまで)。日本語の文章のみで、パスやコード識別子は書かない。"
        // 分析・評価を求める質問が「日付 + 発言の羅列」に流れる問題への対策として、
        // analysisStructureLine の指示だけでは抽象的すぎるため、形だけの例を 1 つ示す
        // (内容は空の題材で、小見出し・段落構成・引用の使い方だけを見せる)。
        let analysisExampleSection: String =
            scope == .live
            ? ""
            : """
                分析・評価の回答の、途中の 1 セクションの書き方の例 (形だけの参考。冒頭の太字の判定はこの例より前に単独で置く。内容・小見出しは質問と文字起こしに合わせる):
                ### 探索と評価が同じ時間に同居している
                **新しい案を出す時間と案を絞る時間が分かれていないこと**が、毎回の結論未達の主因になっている。

                5 回の定例すべてで、絞り込みの途中に新しい案の紹介が挟まり、議論が発散したまま時間切れになっている。

                > 16:05:43 相手: もうどう話していいか、結構迷走しつつある

                この状態は参加者にも自覚されている。ただし対処は時間を短くする方向に向かっており、**発散そのものを抑える進行の工夫はまだ試されていない**と考えられる。
                """ + "\n\n"

        // 「根拠は本文に織り込み済み」はレポート型 (非ライブ) の前提。ライブは発言の再掲を
        // 最小限にする速答なので、この前置きを付けない。
        let evidenceNoteLeadIn =
            scope == .live
            ? ""
            : "分析・評価の回答では根拠は本文に織り込み、ここには本文に入れなかった補足だけを書く。"

        return """
            \(intro)

            質問: \(question)

            質問は会議中の口語です。語句の一致を探すのではなく、質問の意図 (知りたい挙動・仕様・影響・決定事項) に答えてください。「その言葉は使われていない」のような語句の一致・不一致の報告はしないでください。

            回答の書き方:
            \(readerLine)
            - 最初の 1 文で判定・結論を言い切り、その 1 文を ** で太字にする
            - 質問が分析・評価・改善案を求めるもの (例: 問題点を分析して / どう思う / どこがまずい) なら、文字起こしを根拠にした見立てを書いてよい。事実 (実際の発言) と見立て (そこから言えること) が読み分けられる書き方にする\(analysisStructureLine)
            - 本文はファイル名・関数名・変数名を使わず、「誰に・どのケースで・何が起きるか」が分かる日本語で書く。実装の詳細は、質問で明示的に求められた場合だけ書く
            \(quotationLine)
            - 判断できない場合や次に動くべきことがある場合は、それを ## \(nextStepSectionTitle) に書く
            - 文字起こしの「自分」は質問者本人。次の一手で質問者本人を確認相手にしない (本人が動く場合は、何をどう確認するかを書く)

            \(materialHandlingSection)調査規則:
            \(investigationRules(hasReferenceFolder: hasReferenceFolder, allowsInterpretation: true, scope: scope))

            \(analysisExampleSection)出力は次の Markdown だけにしてください。前置きや後書きは不要です。
            ## \(answerSectionTitle)
            \(answerLengthLine)
            ## \(nextStepSectionTitle)
            回答だけでは質問の目的を達成できず、質問者が次に取るべき具体的な一手 (誰に何を確認するか、どこを見れば確定するか) が文字起こしから特定できる場合だけこのセクションを出し、1〜2 行で書く。次のいずれかに当たる場合は出力しない: 回答で完結している / 「本人や関係者に聞けば分かる」のような当然の行動しか書けない / ```choices で確認する内容と同じ。迷ったら出力しない。「出力しない」とは見出しごと省略すること。「(なし)」と書いて見出しを残すのは誤り (それは根拠と補足だけのルール)。
            ## 根拠と補足
            - \(evidenceNoteLeadIn)根拠となる発言 (時刻と要旨) や補足を箇条書きで書く。各 1 行・最大 4 項目 (分析の質問では最大 8 項目)。時刻は各行の行頭に 1 箇所だけ書き、行の途中に時刻を書かない。回答と同じ内容は繰り返さない\(referencedFileLine)
            無ければ「(なし)」とだけ書く。

            \(mermaidParagraph)

            \(choicesParagraph)\(decisionHistorySection)

            \(autoExecutionNote)
            """
    }
}
