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
                question: question, previousResult: previousResult, isResuming: false,
                hasReferenceFolder: referenceFolder != nil),
            outputPrefix: "code-impact",
            model: model)
    }

    /// 質問が無ければダイジェスト用の基本プロンプト、あれば質問特化プロンプトに切り替える。
    /// 質問特化プロンプトは、初回の質問と追加質問(previousResult 付き)の両方で共有する。
    ///
    /// isResuming は claude を `--resume` で継続実行する場合に true になる
    /// (AgentCodeImpactStream から呼ばれる)。会話側が前回までの文脈を覚えているため、
    /// previousResult は埋め込まず、代わりに resumeNote(最新の文字起こしを渡し直している旨)
    /// を添える。AgentCodeImpactStream からも呼ぶため internal。
    ///
    /// hasReferenceFolder は、資料フォルダが紐付いているか(=カレントディレクトリの資料や
    /// コードを読ませてよいか)。false の間は、資料やコードへの言及・参照ファイル行の指示を
    /// プロンプトから外し、文字起こしだけを根拠にする文言に差し替える。
    static func buildPrompt(
        question: String?, previousResult: String?, isResuming: Bool, hasReferenceFolder: Bool
    ) -> String {
        let trimmedQuestion = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedQuestion.isEmpty else {
            let base = basePrompt(hasReferenceFolder: hasReferenceFolder)
            return isResuming ? "\(base)\n\n\(resumeNote)" : base
        }

        var parts: [String] = []
        if isResuming {
            parts.append(resumeNote)
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

    /// resume 時に添える一文。文字起こしは毎回渡し直しているが、資料やコードは
    /// 前回の調査で読んだ内容を会話が覚えているため、再読は必要な場合だけでよいと伝える。
    private static let resumeNote =
        "文字起こしは最新のものを渡し直しています。前回の調査で読んだファイルの再読は必要な場合だけでよいです。"

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
            質問の目的に対して、次に確認・作業すべきことが実際にある場合だけこのセクションを出し、1〜2 行で書く (例: 誰に何を確認するか、どこを見れば確定するか)。無ければこのセクション自体を出力しない。
            ## 根拠と補足
            - 根拠となる発言 (時刻と要旨) や補足を箇条書きで書く。各 1 行・最大 4 項目。回答と同じ内容は繰り返さない\(referencedFileLine)
            無ければ「(なし)」とだけ書く。

            \(mermaidParagraph)

            \(autoExecutionNote)
            """
    }
}
