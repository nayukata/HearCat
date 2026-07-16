import Foundation
import FoundationModels

/// 文字起こしをオンデバイス LLM (Apple Intelligence / FoundationModels) で要約する。
/// オンデバイスモデルはコンテキストが小さい(公称値は非公開、通説で約4096トークン)ため、
/// 「区間ごとに要約 → 縮むまで繰り返す」で入力を縮めたあと、統合は単目的の小さな
/// モデル呼び出しの列に分解している。
///   1. 区間要約で話題ラベルを付ける(SectionPoint.topic)
///   2. コード側でラベルごとに要点を束ねる(groupPointsByTopic)
///   3. [A] ラベル一覧の番号を議題ごとに仕分ける(ClusterPlan、見出しの生成・雑談判定はしない)
///   4. [B] クラスタごとに実データ(要点)から見出し・本文・決定事項候補・宿題候補・雑談判定を
///      生成する(TopicBody)
///   5. [E1][E2] 話題単位で集めた候補を、会議全体を見て選別する(RefinedDecisions / RefinedTodos)
///   6. [C] 生成済みの話題見出しと選別後の決定事項の件数からコードで概要を組み立てる(モデル呼び出しなし)
///
/// 「全部を1回の統合呼び出しに通す」設計はやめている。入力が閾値をわずかに超えるだけで
/// 破壊的な再圧縮が走って統合が見る情報が激減したり(v4.1の実測: 3123文字が閾値3000を
/// 123文字超えただけで895文字まで圧縮された)、1回の出力に複数の目的を詰め込んで決定事項が
/// 話題まとめの丸写しになったりする(v4以前の実測)。単目的の呼び出しに分解することで、
/// この手の崖を構造的に無くしている。
///
/// [A]で見出しと雑談判定までモデルに発明させると、ラベル名だけを見て中身と不一致な見出しを
/// 付けたり(例: AIツール雑談に「セキュリティと規制対応」)、isChitchat が一度も発火しなかったり
/// する実測不具合があった(v6)。見出し・雑談判定は実データ(要点そのもの)を見る[B]に接地させている。
/// ただし isChitchat の判定自体も誤爆することがあり、業務の話題が丸ごと消える実測不具合が
/// あった(v7)ため、[B]で雑談と判定されたセクションも捨てずに末尾へ回している(v8、詳細は
/// resolveTopicSections 参照)。[C]の概要生成は4回連続で話題見出しの羅列にしかならず、モデルに
/// 書かせる価値が無かったため、v8 でモデル呼び出しをやめてコードで機械的に組み立てている。
///
/// 決定事項・宿題はかつて全要点一括の別呼び出し([D1][D2])で抽出していたが、入力(全要点)が
/// 2900文字規模になり、出力が話題まとめとほぼ同文の段落になってしまう実測不具合があった(v8)。
/// v9 では話題単位の本文生成([B])に統合し、網羅性は上がったが、話題ごとの直接出力を
/// そのまま最終出力にすると単語だけの項目・雑談混入・プロンプト文の復唱が実測で発生した(v10)。
/// 話題ごと抽出は網羅係、全体一括抽出は品質係という得意不得意の違いがあるため、v11 では
/// 両方を組み合わせている。[B]の decisions/todos は最終出力ではなく「候補」として集め、
/// 会議全体を見て選別する[E1][E2]に渡す。選別が両方とも失敗した場合は情報を失わないよう
/// 候補リストをそのまま採用する。
///
/// v11 と v11.1 は仕様差が小さいのに抽出・選別の品質が実行ごとに大きくブレた(同じ入力でも
/// 選別が過剰に刈って決定事項が1件だけになったり、担当欄にタスク文がまるごと複製される
/// 壊れ方をしたりした)。主因はサンプリングの非決定性と判断し、v12 では全モデル呼び出しの
/// GenerationOptions に `sampling: .greedy` を指定して決定的デコードに切り替えている。
/// 同一入力に対する再現性を優先する。
///
/// greedy 化で出力が決定的になったことで、v12 の固定出力に残る不良を正確に切り分けられる
/// ようになった。v13 ではその不良4種に対策している: (1) 出来事の記述(「〜について議論
/// されました」等)がコード側の正規表現フィルタでも落ちきらず候補に残る、(2) 候補だけでは
/// 雑談かどうか判別できず雑談項目が決定/TODOに残る(→ 候補に発生元の話題見出しをタグ付けして
/// 選別に文脈を渡す。ActionCandidate 参照)、(3) 担当欄に不正確な当てずっぽうやタスク文の複製が
/// 出る(→ 敬称パターンでのガード)、(4) 同じ宿題が担当違いで重複して出る(→ task 完全一致での
/// マージ)。
///
/// 最終要約・区間要約とも自由文プロンプトではなく @Generable の構造化生成を使う。
/// Markdown への整形はアプリ側で行うため、見出しの粒度や重複はモデルの気まぐれに左右されない。
public enum TranscriptSummarizer {
    public enum SummarizerError: LocalizedError {
        case unavailable(String)
        case guardrailBlocked
        case generationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            case .guardrailBlocked:
                return "Apple のオンデバイスモデルの安全機能により、この内容は要約できませんでした。政治・医療・暴力表現などを含む話題で起こることがあります"
            case .generationFailed(let reason): return reason
            }
        }
    }

    /// 区間要約の要点1件。話題ラベルを持たせることで、複数区間・複数ラウンドをまたいでも
    /// 同じ話題の要点を統合段で1つにまとめられるようにする。
    @Generable
    fileprivate struct SectionPoint {
        @Guide(description: "この要点が属する話題を表す短い名詞句。粗めの粒度にし、近い内容は必ず同じラベルにまとめる。1区間でラベルは多くても3〜4種類に抑える")
        var topic: String

        @Guide(description: "要点。1〜2文で、何がどう話されたかまで簡潔に書く")
        var point: String
    }

    /// 区間要約の結果。箇条書きの生テキストではなく配列で受け取り、整形はアプリ側で行う。
    /// points の件数は .count で構造的に縛る。上限がないと1441字の入力に対し出力が
    /// 4089トークンまで暴走し、コンテキスト超過を起こした実測がある(下限を切ると逆に1点だけの手抜きになる)。
    @Generable
    fileprivate struct SectionSummary {
        @Guide(description: "この区間で話された内容の要点", .count(2...8))
        var points: [SectionPoint]
    }

    /// [A] クラスタ分けの結果。話題ラベルの「番号」を議題ごとのグループに仕分けるだけで、
    /// 見出しの生成や雑談判定はしない(ラベル名だけからそれらを発明させると中身と不一致な
    /// 見出しが付いたり isChitchat が発火しなかったりする実測不具合があった。詳細はファイル
    /// 冒頭の doc コメント参照)。見出し・雑談判定は実データを見る[B]の仕事にしている。
    /// groups の件数下限(4)は v4.1 で撤廃した話題セクション数の下限とは性質が違う。
    /// クラスタ分けはグループの中身(本文)を生成せず、実在する要点の番号を仕分けるだけなので、
    /// 下限を強制しても情報を捏造する動機にはならない(本文は後段の[B]が実データからしか作らない)。
    @Generable
    fileprivate struct ClusterPlan {
        @Guide(
            description: "話題の番号のグループ分け。すべての番号をいずれかのグループに割り当てる。"
                + "1つのグループに詰め込まず、議題ごとに分ける",
            .count(4...10)
        )
        var groups: [ClusterGroup]
    }

    @Generable
    fileprivate struct ClusterGroup {
        @Guide(description: "このグループに属する話題の番号。1グループ6個まで", .maximumCount(6))
        var memberIndexes: [Int]
    }

    /// [B] クラスタ1つぶんの本文生成の結果。見出し・決定事項・宿題・雑談判定もここで
    /// 実データ(要点)から生成する(理由はファイル冒頭の doc コメント参照)。
    /// v14実測: v13.1で精度側(選別[E1][E2]・正規表現フィルタ)が頑丈になった一方、候補出し
    /// (この構造体)が精度寄りすぎて、会議で実際に決定された事項(画像はPDFに結合する方針、
    /// データ連携1000人はバックエンドで制限、健康診断のダイアログ形式化 等)が候補段階で
    /// 拾われず決定事項が2件に痩せた。精度は選別側に任せられるため候補出しを網羅優先に振ったが、
    /// v14.1実測: 網羅寄りのガイドが「合意されていない論点(ファイル名をどうするか)」を
    /// 「決定の形(日付で整理することにする)」に書き換える捏造を1件生んだ。そこで精度寄り
    /// (v13.1相当)に戻したところ、今度は文言の微差だけで greedy の固定出力全体が別物に
    /// 引き直され、別の不良(決定が壊れた断片1個、「〜について議論されました。」の接頭辞汚染)が
    /// 出た(v14.1実測)。v14.2 では decisions/todos のガイド文言と respondTopicBody の依頼文を
    /// v11 時点の実測確認済みの文言に byte 単位で戻し、既知の良い出力を再現させている。
    /// 【重要】この2フィールドの description と依頼文は、実測で確認済みの文言から絶対に変更しない
    /// こと。ガイド文言のごく微小な差でも greedy の固定出力全体が引き直される。
    /// v15実測: body のガイドに「受け身の文末(〜されました)を繰り返さず、自然な日本語で書く」を
    /// 足して Atnd 7/6 で検証したが、受け身連発の段落は1字も変わらず(greedy がその継続を強く
    /// 好み、文体指示に反応しない)、一方で決定事項の入れ替わり・TODO の 7件→3件の痩せ・
    /// 「〜する可能性」の曖昧化が出たため戻した。本文の文体はガイドでは動かせない。
    /// 見出しの出来事語尾はコード側の stripEventSuffixFromTitle で対処している。
    @Generable
    fileprivate struct TopicBody {
        @Guide(description: "この話題の見出し。要点の内容から付ける短い名詞句。「〜について議論されました」のような文にせず、名詞句で書く")
        var title: String

        @Guide(
            description: "この話題の内容を1〜3文のつながった文章でまとめる。結論・決まったこと・数値を優先し、経緯は最小限にする。"
                + "断片の羅列にしない。要点にある具体的な事実だけで書き、一般論や意義の説明を書かない"
        )
        var body: String

        @Guide(description: "この話題で明示的に合意・決定した事項。それぞれ50字以内の1文。完了報告や状況描写は含めない。なければ空配列", .maximumCount(2))
        var decisions: [String]

        @Guide(
            description: "この話題でこれからやると決まった・頼まれた作業。それぞれ「誰が何をする」の形の50字以内の1文。完了済みの事柄や感想は含めない。なければ空配列",
            .maximumCount(2)
        )
        var todos: [String]

        @Guide(description: "業務と関係ない雑談なら true")
        var isChitchat: Bool
    }

    /// 話題ごとのまとまり。クラスタの見出し(title)と本文生成呼び出しの結果(body)から
    /// コード側で組み立てる。モデルに1回で生成させる構造ではなくなったので @Generable ではない。
    fileprivate struct TopicSection {
        var title: String
        var body: String
    }

    /// 決定事項・宿題の候補1件。発生元の話題見出し(topic)を保持し、選別([E1][E2])の
    /// 入力で「-【話題見出し】候補文」の形式に使う。候補だけでは雑談かどうか判別できず、
    /// 雑談項目が決定/TODOに残った実測不具合(v12)があったため、出所の文脈を選別に渡す。
    fileprivate struct ActionCandidate {
        var topic: String
        var text: String
    }

    /// [E1] 決定事項の選別結果。TopicBody.decisions を話題横断で集めた「候補」を入力に、
    /// 会議全体を見て実際に決定されたものだけを残す(理由はファイル冒頭 doc コメント参照)。
    @Generable
    fileprivate struct RefinedDecisions {
        @Guide(
            description: "会議で実際に合意・決定された事項だけを残したもの。各項目は「何を」「どうすると決めたか」が"
                + "単独で伝わる1文。単語だけの項目は禁止。該当なしなら空配列",
            .maximumCount(8)
        )
        var decisions: [String]
    }

    /// [E2] 宿題の選別結果。TopicBody.todos を話題横断で集めた「候補」を入力に、
    /// 会議全体を見て実際に約束された宿題だけを残す。担当は構造で分離させ、
    /// Markdown 整形時に「- {task}(担当: {assignee})」の形に組み立てる。
    @Generable
    fileprivate struct RefinedTodos {
        @Guide(description: "会議で約束された宿題だけを残したもの。該当なしなら空配列", .maximumCount(8))
        var todos: [TodoItem]
    }

    @Generable
    fileprivate struct TodoItem {
        @Guide(description: "担当者の人名。文中に人名が無ければ「不明」")
        var assignee: String

        @Guide(description: "やる作業の内容。「〜する」の形の1文")
        var task: String
    }

    /// content 中の話題ラベルごとに要点を束ねた1グループ。登場順を保つ。
    fileprivate struct TopicGroup {
        var topic: String
        var points: [String]
    }

    /// 1回のプロンプトに入れる本文の最大文字数。指示文と応答分の余白を残した控えめな値。
    /// チャンク分割自体はこの値で行う(1回のモデル呼び出しに渡す量の上限)。
    private static let chunkLimit = 2500

    /// 圧縮ループを継続するかどうかの閾値。v4.1 では旧 meetingInputLimit(3000)をわずか
    /// 123文字超えただけで破壊的な2回目の圧縮が走り、統合が見る情報が895文字まで枯渇する
    /// 実測不具合があった。v5 以降の統合処理(クラスタ分け・話題単位の本文/決定事項/宿題生成・
    /// 概要)はどれも入力が小さい単目的呼び出しなので、閾値を大きく取り(12000)、2回目以降の
    /// 圧縮ラウンドは超長時間会議でしか走らないようにしている。
    private static let reduceThreshold = 12000

    /// 出力トークンの上限。.count/.maximumCount と二重に効かせて暴走を止める保険。
    /// topic フィールドが増えた分、区間要約側は 600 → 800 に引き上げている。
    private static let sectionMaxResponseTokens = 800

    /// クラスタ分け([A])の出力トークン上限。話題ラベルの番号一覧だけの短い入出力なので低く抑える。
    private static let clusterMaxResponseTokens = 600

    /// 話題1グループぶんの本文生成([B])の出力トークン上限。本文(1〜3文)に加え決定事項・宿題
    /// (各最大2件)のフィールドが増えた分、300 → 400 に引き上げている。
    private static let bodyMaxResponseTokens = 400

    /// 決定事項・宿題の選別([E1][E2])の出力トークン上限。最大8件の短い文なので低く抑える。
    private static let refineMaxResponseTokens = 500

    /// guardrail 等で落ちた区間を分割サルベージする際の下限サイズと再帰深さの上限。
    /// これより細かく割っても文脈が失われて要約の質が落ちるだけなので、ここで諦める。
    private static let minSplitFragmentSize = 300
    private static let maxSplitDepth = 2

    private static let instructions = """
        あなたは会議の書記です。日本語の文字起こしを読み、重要な内容を日本語で構造化してまとめます。
        文字起こしは「[時刻] 話者: 発言」の形式で、話者は「自分」と「相手」の2種類です。
        誤変換が含まれることがあるため、文脈から意味を補って読み取ってください。
        相槌・雑談・挨拶など内容のない発言は無視してください。
        同じ内容を複数の項目に重複させないでください。
        「〜について議論されました」のような中身のない要約は禁止です。何がどう議論・決定されたかを具体的に書いてください。
        項目の文中ではかぎ括弧(「」)や引用符("")を使わないでください。
        文字起こしに書かれていない事柄を推測で補って書かないでください。
        音声認識の誤変換と思われる語は、文脈から正しい語が確信できる場合のみ直してください。意味が取れない語や確信の持てない固有名詞は要約に載せないでください。
        雑談そのものは省いてよいですが、雑談の中で生まれた宿題や約束は拾ってください。
        """

    /// - Parameter log: パイプラインの進捗(チャンク数・圧縮ラウンド数・リトライ・フォールバック・スキップ)を
    ///   観察するための注入口。検証用途向けで、通常のアプリ利用では指定不要。
    public static func summarize(
        transcript: String,
        log: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        if let reason = OnDeviceModel.unavailableReason() {
            throw SummarizerError.unavailable(reason)
        }

        do {
            return try await summarize(transcript, limit: chunkLimit, reduceThreshold: reduceThreshold, log: log)
        } catch let error as LanguageModelSession.GenerationError {
            // コンテキスト上限の正確な値は非公開のため、超過したら両方の閾値を半分にして一度だけ再試行する。
            guard case .exceededContextWindowSize = error else {
                throw mapGenerationError(error)
            }
            do {
                return try await summarize(
                    transcript,
                    limit: chunkLimit / 2,
                    reduceThreshold: reduceThreshold / 2,
                    log: log
                )
            } catch let retryError as LanguageModelSession.GenerationError {
                throw mapGenerationError(retryError)
            }
        }
    }

    private static func summarize(
        _ transcript: String,
        limit: Int,
        reduceThreshold: Int,
        log: (@Sendable (String) -> Void)?
    ) async throws -> String {
        var content = transcript
        var skippedSectionCount = 0
        var roundNumber = 0
        // 短い文字起こしでも話題ラベルが必ず付いた状態になるよう、圧縮ラウンドは最低1回は通す
        // (repeat-while で「1回目は無条件」を表現する)。
        repeat {
            let chunks = split(content, limit: limit)
            roundNumber += 1
            log?("圧縮ラウンド\(roundNumber): 入力\(content.count)文字を\(chunks.count)チャンクに分割")
            // 区間ごとの要約は独立だが、オンデバイスモデルは並列実行の利得がないため直列に回す。
            var partials: [String] = []
            for chunk in chunks {
                let (points, skipped) = try await resolveSection(chunk, depth: 0, log: log)
                if !points.isEmpty {
                    // 「- 【話題】要点」の形式で話題ラベルを次のラウンド・統合段まで引き継ぐ。
                    partials.append(points.map { "- 【\($0.topic)】\($0.point)" }.joined(separator: "\n"))
                    log?("区間要約完了: 入力\(chunk.count)文字 → \(points.count)件")
                }
                skippedSectionCount += skipped
            }
            if partials.isEmpty {
                throw SummarizerError.guardrailBlocked
            }
            let reduced = partials.joined(separator: "\n\n")
            // 要約しても縮まない場合は打ち切る(無限ループ防止)。超過すれば上位の再試行に回る。
            if reduced.count >= content.count {
                content = reduced
                break
            }
            content = reduced
        } while content.count > reduceThreshold

        // ここから先は「全部を1回の統合呼び出しに通す」のではなく、単目的の小さな
        // モデル呼び出しの列に分解する(理由はファイル冒頭の doc コメント参照)。
        let groups = groupPointsByTopic(content)

        log?("クラスタ分け開始: ラベル\(groups.count)種")
        let clusters = await resolveClusters(groups, log: log)

        let (sections, decisionCandidates, todoCandidates) = await resolveTopicSections(clusters, groups: groups, log: log)

        // [E1][E2] 話題単位で集めた候補を、会議全体を見て選別する(理由はファイル冒頭の doc コメント参照)。
        let (decisions, todos) = await resolveActions(
            decisionCandidates: decisionCandidates,
            todoCandidates: todoCandidates,
            log: log
        )

        // [C] 概要はモデルを呼ばずコードで組み立てる(理由はファイル冒頭の doc コメント参照)。
        let overview = buildOverview(sections: sections, decisionCount: decisions.count)

        var markdown = format(overview: overview, sections: sections, decisions: decisions, todos: todos)
        if skippedSectionCount > 0 {
            markdown += "\n\n> 一部の内容(\(skippedSectionCount)か所)は要約できませんでした。"
                + "Apple のオンデバイスモデルの安全機能により、政治・医療・暴力表現などを含む話題は要約が拒否されることがあります"
        }
        return markdown
    }

    /// content(「- 【ラベル】要点」の行の集まり)をラベルごとに束ね、登場順を保った
    /// TopicGroup の配列にする。ラベルの表記ゆれの統合はしない(完全一致でグルーピングする。
    /// 表記ゆれの吸収はクラスタ分け呼び出し([A])の仕事として残す)。
    private static func groupPointsByTopic(_ content: String) -> [TopicGroup] {
        var order: [String] = []
        var pointsByTopic: [String: [String]] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let (topic, point) = parseTopicLine(trimmed)
            if pointsByTopic[topic] == nil {
                order.append(topic)
                pointsByTopic[topic] = []
            }
            pointsByTopic[topic]?.append(point)
        }
        return order.map { TopicGroup(topic: $0, points: pointsByTopic[$0] ?? []) }
    }

    /// [A] 話題ラベルの一覧を議題ごとのクラスタにまとめる。失敗したら例外を投げずに
    /// フォールバック(1ラベル=1グループ)へ切り替える。話題まとめ自体はクラスタ分けが
    /// 粗くても本文生成([B])で吸収できるため、ここで全体を止める価値はない。
    private static func resolveClusters(_ groups: [TopicGroup], log: (@Sendable (String) -> Void)?) async -> [ClusterGroup] {
        guard !groups.isEmpty else { return [] }
        // ラベルが4種以下ならクラスタ分け呼び出し自体を省略する。ClusterPlan.groups は
        // .count(4...10) で件数下限を縛っているため、ラベルが4種に満たないと構造的に
        // 満たしようがなく、呼んでも失敗するだけ。少数ラベルはグルーピングの必要性も薄いので、
        // フォールバックと同じ「1ラベル=1グループ」をそのまま使う。
        guard groups.count > 4 else {
            log?("クラスタ分け省略(ラベル\(groups.count)種): 1ラベル=1グループとして扱う")
            return fallbackClusters(groups)
        }
        let labelList = groups.enumerated().map { "\($0.offset + 1). \($0.element.topic)" }.joined(separator: "\n")
        do {
            let plan = try await respondClusterPlan(prompt: """
                以下は会議で話された話題の一覧です。同じ議題に属する話題の番号を1つのグループにまとめてください。

                \(labelList)
                """, log: log)
            return resolveClusterIndexes(plan.groups, topicCount: groups.count)
        } catch {
            log?("クラスタ分け失敗、フォールバックに切り替え: \(error)")
            return fallbackClusters(groups)
        }
    }

    /// モデルが返した memberIndexes を検証し、範囲外・重複の番号は無視する。
    /// どのグループにも入らなかった番号は1つのグループとして末尾に足す。
    private static func resolveClusterIndexes(_ rawGroups: [ClusterGroup], topicCount: Int) -> [ClusterGroup] {
        var claimed = Set<Int>()
        var resolved: [ClusterGroup] = []
        for group in rawGroups {
            let validIndexes = group.memberIndexes.filter { $0 >= 1 && $0 <= topicCount && !claimed.contains($0) }
            guard !validIndexes.isEmpty else { continue }
            validIndexes.forEach { claimed.insert($0) }
            resolved.append(ClusterGroup(memberIndexes: validIndexes))
        }
        let leftover = (1...topicCount).filter { !claimed.contains($0) }
        if !leftover.isEmpty {
            resolved.append(ClusterGroup(memberIndexes: leftover))
        }
        return resolved
    }

    /// クラスタ分け呼び出しを省略した場合、または呼び出しが全滅した場合のフォールバック。
    /// ラベルをそのまま1ラベル=1グループにし、先頭9個までを個別グループ、残りは1つに束ねる
    /// (本文生成([B])の呼び出し回数を無闇に増やさないため)。
    private static func fallbackClusters(_ groups: [TopicGroup]) -> [ClusterGroup] {
        guard !groups.isEmpty else { return [] }
        let headCount = min(groups.count, 9)
        var result = (1...headCount).map { ClusterGroup(memberIndexes: [$0]) }
        if groups.count > headCount {
            result.append(ClusterGroup(memberIndexes: Array((headCount + 1)...groups.count)))
        }
        return result
    }

    private static func respondClusterPlan(prompt: String, log: (@Sendable (String) -> Void)?) async throws -> ClusterPlan {
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: clusterMaxResponseTokens)
        for attempt in 0..<2 {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: ClusterPlan.self, options: options)
                return response.content
            } catch let error as LanguageModelSession.GenerationError {
                guard case .decodingFailure = error else { throw error }
                log?("decodingFailure でリトライ(クラスタ分け, \(attempt + 1)回目)")
            }
        }
        throw SummarizerError.generationFailed("クラスタ分けに失敗しました")
    }

    /// [B] クラスタごとに要点(実データ)から見出し・本文・決定事項候補・宿題候補・雑談判定を生成する。
    /// isChitchat の判定は完璧ではなく、誤爆で業務の話題が丸ごと消える実測不具合があった(v7)。
    /// 情報を失うより雑談が混ざる方がマシなので、isChitchat=true のセクションも捨てずに
    /// 非雑談セクションの後ろへ回す(順序で劣後させるだけで、出力自体からは除外しない)。
    /// ただし雑談セクションの decisions 候補は集約しない(v9実測: 雑談が決定事項に混入した)。
    /// 雑談から拾う価値があるのは宿題だけなので、todos 候補だけは雑談セクション分も集約対象に含める。
    /// ここで返す decisions/todos は最終出力ではなく「候補」であり、選別([E1][E2])を経てから
    /// 出力になる(理由はファイル冒頭の doc コメント参照)。候補の前処理(サニタイズ・空項目除去・
    /// 重複除去)は cleanActionItems 参照。
    /// guardrailViolation / refusal / その他のエラーはそのクラスタだけスキップし、他のクラスタの
    /// 生成は続ける(1話題の失敗で要約全体を失敗させない)。
    private static func resolveTopicSections(
        _ clusters: [ClusterGroup],
        groups: [TopicGroup],
        log: (@Sendable (String) -> Void)?
    ) async -> (sections: [TopicSection], decisionCandidates: [ActionCandidate], todoCandidates: [ActionCandidate]) {
        var primarySections: [TopicSection] = []
        var chitchatSections: [TopicSection] = []
        var decisionCandidates: [ActionCandidate] = []
        var todoCandidates: [ActionCandidate] = []
        for cluster in clusters {
            let points = cluster.memberIndexes
                .filter { $0 >= 1 && $0 <= groups.count }
                .flatMap { groups[$0 - 1].points }
            guard !points.isEmpty else { continue }
            log?("本文生成: \(points.count)要点")
            do {
                let topicBody = try await respondTopicBody(points: points, log: log)
                // title は概要組み立て([C])と選別([E1][E2])の話題タグにもそのまま使われるため、
                // body と同じくサニタイズする。文の見出しは出来事語尾を剥がして名詞句に戻す。
                let title = stripEventSuffixFromTitle(sanitizeTrailingArtifacts(topicBody.title))
                let section = TopicSection(title: title, body: sanitizeTrailingArtifacts(topicBody.body))
                todoCandidates += topicBody.todos.map { ActionCandidate(topic: title, text: $0) }
                if topicBody.isChitchat {
                    log?("雑談として末尾へ: \(topicBody.title)")
                    chitchatSections.append(section)
                } else {
                    decisionCandidates += topicBody.decisions.map { ActionCandidate(topic: title, text: $0) }
                    primarySections.append(section)
                }
            } catch {
                log?("本文生成スキップ(失敗): \(error)")
            }
        }
        return (
            primarySections + chitchatSections,
            cleanActionItems(decisionCandidates),
            cleanActionItems(todoCandidates)
        )
    }

    /// [E1][E2] 話題単位で集めた候補を、会議全体を見て選別する。宿題側は選別後に同一タスクの
    /// 担当違い重複をマージし(mergeTodoItemsByTask)、続けて v10 由来の決定⇄宿題重複除去
    /// (完全一致は宿題側優先。宿題側は task 文字列で比較する)と各最大10件丸めを適用する。
    private static func resolveActions(
        decisionCandidates: [ActionCandidate],
        todoCandidates: [ActionCandidate],
        log: (@Sendable (String) -> Void)?
    ) async -> (decisions: [String], todos: [String]) {
        let refinedDecisions = await resolveRefinedDecisions(decisionCandidates, log: log)
        let refinedTodoItems = mergeTodoItemsByTask(await resolveRefinedTodos(todoCandidates, log: log))
        // 実測: 決定側「〜検討する。」と宿題側「〜検討する」が末尾の句点1文字の差だけで
        // 完全一致判定をすり抜けた。比較キーは末尾の句点と前後空白を除いて正規化する
        // (表示テキスト自体は変えない)。
        let todoTaskKeys = Set(refinedTodoItems.map { dedupKey($0.task) })
        let dedupedDecisions = refinedDecisions.filter { !todoTaskKeys.contains(dedupKey($0)) }
        return (
            Array(dedupedDecisions.prefix(10)),
            Array(refinedTodoItems.prefix(10)).map(formatTodoItem)
        )
    }

    /// 決定⇄宿題の重複判定に使う比較キーを作る。末尾の句点(。)を1つ取り除いてから
    /// 前後の空白をトリムする。表示に使うテキストはこの関数を通さない。
    private static func dedupKey(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        if result.hasSuffix("。") {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 候補を「-【話題見出し】候補文」形式のテキストに変換する。選別呼び出し([E1][E2])が
    /// 候補だけでは雑談かどうか判別できず、雑談項目が決定/TODOに残った実測不具合(v12)があった
    /// ため、出所の話題見出しを文脈として渡す。
    private static func formatActionCandidates(_ candidates: [ActionCandidate]) -> String {
        candidates.map { "- 【\($0.topic)】\($0.text)" }.joined(separator: "\n")
    }

    /// [E1] 決定事項の候補を選別する。decodingFailure を最大2回リトライしてもなお失敗した場合や、
    /// それ以外のエラーが出た場合はエラーにせず、選別前の候補文リストをそのまま採用する
    /// (選別に失敗しても情報は失わない)。
    private static func resolveRefinedDecisions(_ candidates: [ActionCandidate], log: (@Sendable (String) -> Void)?) async -> [String] {
        guard !candidates.isEmpty else { return [] }
        let prompt = """
            以下は会議の決定事項の候補です。実際に合意・決定されたものだけを残し、重複は1つにまとめ、
            それぞれ内容が伝わる1文に整えてください。単語だけの項目・雑談の感想・完了した作業の報告は
            捨ててください。行頭の【】はその候補が出た話題です。仕事の議題と関係ない雑談の話題
            (ツールや料金の世間話など)から出た候補は捨ててください。
            良い例: 複数の画像はバックエンドで1つのPDFに結合する方針に決定
            悪い例: 価格が210ドルになったことを確認した(雑談)、〜について議論されました(出来事の記述)

            \(formatActionCandidates(candidates))
            """
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: refineMaxResponseTokens)
        for attempt in 0..<2 {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: RefinedDecisions.self, options: options)
                return response.content.decisions
            } catch let error as LanguageModelSession.GenerationError {
                guard case .decodingFailure = error else {
                    log?("決定事項の選別失敗、候補をそのまま採用: \(error)")
                    return candidates.map(\.text)
                }
                log?("decodingFailure でリトライ(決定事項選別, \(attempt + 1)回目)")
            } catch {
                log?("決定事項の選別失敗、候補をそのまま採用: \(error)")
                return candidates.map(\.text)
            }
        }
        log?("決定事項の選別、リトライ上限到達のため候補をそのまま採用")
        return candidates.map(\.text)
    }

    /// [E2] 宿題の候補を選別する。失敗時の扱いは resolveRefinedDecisions と対称。
    /// 選別に失敗した場合、担当が分からないため assignee は「不明」で候補文をそのまま task にする。
    private static func resolveRefinedTodos(_ candidates: [ActionCandidate], log: (@Sendable (String) -> Void)?) async -> [TodoItem] {
        guard !candidates.isEmpty else { return [] }
        let prompt = """
            以下は会議の宿題の候補です。実際にやると約束された作業だけを残し、重複は1つにまとめてください。
            完了済みの事柄・感想・状況の説明は捨ててください。行頭の【】はその候補が出た話題です。
            仕事の議題と関係ない雑談の話題(ツールや料金の世間話など)から出た候補は捨ててください。
            良い例: 中山さんが会社名選択の検索機能を改善する
            悪い例: 〜がメリットとして挙げられた(感想)

            \(formatActionCandidates(candidates))
            """
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: refineMaxResponseTokens)
        for attempt in 0..<2 {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: RefinedTodos.self, options: options)
                return response.content.todos
            } catch let error as LanguageModelSession.GenerationError {
                guard case .decodingFailure = error else {
                    log?("宿題の選別失敗、候補をそのまま採用: \(error)")
                    return candidates.map { TodoItem(assignee: "不明", task: $0.text) }
                }
                log?("decodingFailure でリトライ(宿題選別, \(attempt + 1)回目)")
            } catch {
                log?("宿題の選別失敗、候補をそのまま採用: \(error)")
                return candidates.map { TodoItem(assignee: "不明", task: $0.text) }
            }
        }
        log?("宿題の選別、リトライ上限到達のため候補をそのまま採用")
        return candidates.map { TodoItem(assignee: "不明", task: $0.text) }
    }

    /// task が完全一致する TodoItem をマージし、担当を「・」区切りで併記する
    /// (実測: 0706 で同じ task が担当違いで2行出た。例: 貝村さん・中山さん)。
    private static func mergeTodoItemsByTask(_ items: [TodoItem]) -> [TodoItem] {
        var order: [String] = []
        var assigneesByTask: [String: [String]] = [:]
        for item in items {
            if assigneesByTask[item.task] == nil {
                order.append(item.task)
                assigneesByTask[item.task] = []
            }
            if assigneesByTask[item.task]?.contains(item.assignee) == false {
                assigneesByTask[item.task]?.append(item.assignee)
            }
        }
        return order.map { task in
            TodoItem(assignee: (assigneesByTask[task] ?? []).joined(separator: "・"), task: task)
        }
    }

    /// TodoItem を Markdown の1項目テキストに整形する。assignee が「さん」「君」「氏」のいずれかで
    /// 終わる場合だけ「(担当: {assignee})」を付ける。それ以外は task だけを出す。
    /// 実測で assignee が全項目「自分」になったり(候補リストに発言者情報が無くモデルが一律で
    /// 埋めていた)、task と同じ文がまるごと複製されたりする壊れ方があった。人名の敬称パターンに
    /// 絞ることで、この手の当てずっぽう・複製をまとめて弾く。
    private static func formatTodoItem(_ item: TodoItem) -> String {
        let honorificSuffixes = ["さん", "君", "氏"]
        guard honorificSuffixes.contains(where: item.assignee.hasSuffix) else { return item.task }
        return "\(item.task)(担当: \(item.assignee))"
    }

    /// decisions/todos の候補の前処理。
    /// 1. 末尾のJSON破片サニタイズ(実測: `〜できます。」],` のような混入が2会議で再発した。
    ///    構造化生成のデコードが末尾で崩れた痕跡)
    /// 2. サニタイズ後に空・空白のみになった項目を除去(実測で「- 」だけの TODO 行が出た)
    /// 3. 出来事の記述(受身過去形)を除去(実測: v12で「画像をPDFに変換して…まとめることに
    ///    ついて議論されました」のような文がTODOに残った。詳細は isEventDescription 参照)
    /// 4. 完全一致の重複除去(同じ話題から出た候補どうしのみで比較すれば十分だが、話題をまたいだ
    ///    重複も無害なので text だけで比較する)
    private static func cleanActionItems(_ items: [ActionCandidate]) -> [ActionCandidate] {
        var seen = Set<String>()
        var cleaned: [ActionCandidate] = []
        for item in items {
            var text = sanitizeTrailingArtifacts(item.text).trimmingCharacters(in: .whitespaces)
            text = stripLeadingBulletMarker(text)
            guard !text.isEmpty, !isEventDescription(text) else { continue }
            guard seen.insert(text).inserted else { continue }
            cleaned.append(ActionCandidate(topic: item.topic, text: text))
        }
        return cleaned
    }

    /// v12実測: 「〜について議論されました」「〜が挙げられた」のような、宿題でも決定事項でもない
    /// 出来事の記述(受身過去形)が候補に残った。「〜を確認する」「〜を検討する」のような能動形の
    /// 宿題は対象にせず、受身過去形の語尾だけを狙って落とす。
    /// v13.1実測: 「〜について議論した。」「〜ことを確認した。」のような能動形の出来事記述や、
    /// 「〜られること」「〜されること」のような受身+こと(何も決めていない出来事の名詞化)も
    /// 決定事項に残った。「進めてもらうこと」のような能動形+ことは対象にしない。
    private static let eventDescriptionPatterns = [
        "(について)?(議論|検討|話し合わ|共有|説明|報告)され(ました|た)。?$",
        "(が)?(挙げられた|強調された|提案されました)。?$",
        "(について)?議論した。?$",
        "ことを確認した。?$",
        "(られる|される)こと。?$",
    ]

    private static func isEventDescription(_ text: String) -> Bool {
        eventDescriptionPatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// 実測で「- 」だけの項目(箇条書き記号だけで中身が無い)が出た。末尾サニタイズと空白
    /// トリムだけではハイフンが残って空判定を素通りするため、先頭の箇条書き記号も剥がす。
    private static func stripLeadingBulletMarker(_ text: String) -> String {
        let bulletPrefixes = ["- ", "・", "* ", "• "]
        guard let prefix = bulletPrefixes.first(where: text.hasPrefix) else { return text }
        return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// 実測(Atnd 7/6 の再生成): 「名詞句で書く」のガイドに反して「アプリの改善について
    /// 議論されました」のような文の見出しが出た。見出しは概要(buildOverview)にもそのまま
    /// 並ぶため、文のままだと「〜されました、〜されました」と同じ語尾の繰り返しが目立つ。
    /// ガイド文言・依頼文は変更禁止(TopicBody の【重要】コメント参照)のため、コード側で
    /// 出来事語尾だけを剥がして名詞句に戻す。剥がした結果が空になる場合は元の見出しを使う。
    private static func stripEventSuffixFromTitle(_ title: String) -> String {
        let suffixPatterns = [
            "(について|を|が)?(議論|検討|話し合わ|共有|説明|報告)(され|し)(ました|た)。?$",
            "について。?$",
        ]
        var result = title
        for pattern in suffixPatterns {
            if let range = result.range(of: pattern, options: .regularExpression) {
                result.removeSubrange(range)
                break
            }
        }
        // 文の見出しに付く末尾の句点も剥がす(概要で「〜します。など4件」と繋がる実測があった)。
        while result.hasSuffix("。") { result.removeLast() }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    /// 構造化生成の末尾崩れ(実測: `〜できます。」],` のような混入や、v14.1実測の
    /// `〜について」:` のようなコロン混入)を刈り取る。末尾から「」」「]」「}」「,」「、」「[」
    /// 「(」半角コロン「:」全角コロン「:」および空白が続く間、繰り返し除去する。
    private static func sanitizeTrailingArtifacts(_ text: String) -> String {
        let artifactCharacters: Set<Character> = ["」", "]", "}", ",", "、", "[", "(", ":", "："]
        var result = text
        while let last = result.last, artifactCharacters.contains(last) || last.isWhitespace {
            result.removeLast()
        }
        return result
    }

    private static func respondTopicBody(
        points: [String],
        log: (@Sendable (String) -> Void)?
    ) async throws -> TopicBody {
        let prompt = """
            会議の1つの話題の要点です。見出しを付け、この話題で何がどう話され、どうなったかを1〜3文でまとめてください。
            決定事項と宿題があればそれぞれ1文で挙げてください(なければ空で)。

            \(points.map { "- \($0)" }.joined(separator: "\n"))
            """
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: bodyMaxResponseTokens)
        for attempt in 0..<2 {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: TopicBody.self, options: options)
                return response.content
            } catch let error as LanguageModelSession.GenerationError {
                guard case .decodingFailure = error else { throw error }
                log?("decodingFailure でリトライ(話題本文, \(attempt + 1)回目)")
            }
        }
        log?("自由文フォールバックに切り替え(話題本文)")
        // 自由文フォールバックでは見出し・決定事項・宿題・雑談判定をモデルに構造化させられないため、
        // 見出しは「その他」、決定事項・宿題は空配列、isChitchat は false に固定する。
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, options: options)
        return TopicBody(title: "その他", body: response.content, decisions: [], todos: [], isChitchat: false)
    }

    /// [C] セクション見出しと決定事項の件数から概要を組み立てる。実測で4回連続、モデルに
    /// 書かせても話題見出しの羅列にしかならず生成する価値が無かったため、モデル呼び出しはせず
    /// コードで機械的に組み立てる。セクションが3件以下なら「など」を付けずに全見出しを列挙する。
    private static func buildOverview(sections: [TopicSection], decisionCount: Int) -> String {
        guard !sections.isEmpty else { return "特筆すべき内容はありませんでした。" }
        let titles = sections.map(\.title)
        let topicSentence: String
        if titles.count <= 3 {
            topicSentence = "\(titles.joined(separator: "、"))について議論した。"
        } else {
            let head = titles.prefix(3).joined(separator: "、")
            topicSentence = "\(head)など\(titles.count)件の話題について議論した。"
        }
        guard decisionCount > 0 else { return topicSentence }
        return topicSentence + "決定事項は\(decisionCount)件。"
    }

    /// 1区間を要約する。guardrailViolation / refusal / exceededContextWindowSize が出た場合は
    /// 区間を丸ごと捨てる前に、行境界でほぼ半分の2断片に分けて再挑戦する。
    /// 実測: 1500字の区間内にある1文が guardrail に触れるだけで区間全体(約1500字)が
    /// 失われていた。ゲーム雑談の火力・攻撃などの語彙でも発動する程度に Apple の安全機能は
    /// 過敏なため、分割して巻き添え範囲を1文の周辺だけに縮める。
    /// 分割してもなお失敗する場合、minSplitFragmentSize 未満に割れる、または maxSplitDepth を
    /// 超える時点で打ち切り、その断片だけをスキップ扱いにする。
    private static func resolveSection(
        _ chunk: String,
        depth: Int,
        log: (@Sendable (String) -> Void)?
    ) async throws -> (points: [SectionPoint], skipped: Int) {
        do {
            let summary = try await respondSection(prompt: sectionPrompt(chunk), log: log)
            return (summary.points, 0)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .exceededContextWindowSize, .refusal:
                break
            default:
                throw error
            }
            let halves = splitInHalf(chunk)
            guard depth < maxSplitDepth, chunk.count >= minSplitFragmentSize * 2, halves.count == 2 else {
                log?("区間スキップ: depth\(depth), \(chunk.count)文字")
                return ([], 1)
            }
            log?("区間分割サルベージ: depth\(depth) → \(halves.count)断片で再挑戦")
            var points: [SectionPoint] = []
            var skipped = 0
            for half in halves {
                let result = try await resolveSection(half, depth: depth + 1, log: log)
                points += result.points
                skipped += result.skipped
            }
            return (points, skipped)
        }
    }

    private static func sectionPrompt(_ chunk: String) -> String {
        """
        会議の内容の一部です。この内容で話された要点をまとめてください。

        \(chunk)
        """
    }

    /// 行境界でできるだけ半分に近い2断片に分ける(発話の途中で切らない)。
    /// 改行のない1行だけの断片はこれ以上分割できないため、その場合は1個の配列を返す
    /// (呼び出し元がこれを検知して分割を諦める)。
    private static func splitInHalf(_ text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return [text] }
        let half = text.count / 2
        var runningCount = 0
        var splitIndex = lines.count - 1
        for (i, line) in lines.enumerated() {
            runningCount += line.count + 1
            if runningCount >= half {
                splitIndex = i
                break
            }
        }
        let first = lines[0...splitIndex].joined(separator: "\n")
        let second = lines[(splitIndex + 1)...].joined(separator: "\n")
        return second.isEmpty ? [first] : [first, second]
    }

    private static func format(overview: String, sections: [TopicSection], decisions: [String], todos: [String]) -> String {
        var parts: [String] = []
        parts.append("## 概要\n\(overview)")
        parts.append("## 話題ごとのまとめ\n" + topicSections(sections))
        parts.append("## 決定事項\n" + bulletList(decisions, emptyText: "なし"))
        parts.append("## TODO・宿題\n" + bulletList(todos, emptyText: "なし"))
        return parts.joined(separator: "\n\n")
    }

    private static func topicSections(_ sections: [TopicSection]) -> String {
        guard !sections.isEmpty else { return "なし" }
        return sections.map { "### \($0.title)\n\($0.body)" }.joined(separator: "\n\n")
    }

    private static func bulletList(_ items: [String], emptyText: String = "なし") -> String {
        guard !items.isEmpty else { return emptyText }
        return items.map { "- \($0)" }.joined(separator: "\n")
    }

    /// decodingFailure の実測: モデルが正しい points 配列をほぼ完成させたところで
    /// JSON の閉じ引用符 `"` を日本語のかぎ括弧 `」` と書き間違え、その後 JSON の外に
    /// 無関係な幻覚テキストを maximumResponseTokens まで垂れ流すケースが12区間中5区間で発生した。
    /// 中身自体は良質なことが多いため、サンプリングの非決定性に賭けて1回だけ構造化生成を
    /// リトライし、それでも駄目なら自由文で要点だけ取り出すフォールバックに落とす。
    private static func respondSection(prompt: String, log: (@Sendable (String) -> Void)?) async throws -> SectionSummary {
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: sectionMaxResponseTokens)
        for attempt in 0..<2 {
            // 呼び出しごとに新しいセッションを使う(履歴を持ち越すとコンテキストを圧迫するため)。
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: SectionSummary.self, options: options)
                return response.content
            } catch let error as LanguageModelSession.GenerationError {
                guard case .decodingFailure = error else { throw error }
                log?("decodingFailure でリトライ(区間, \(attempt + 1)回目)")
            }
        }
        log?("自由文フォールバックに切り替え(区間)")
        return try await respondSectionAsFreeText(prompt: prompt, options: options)
    }

    /// 構造化生成が2回連続で decodingFailure になった区間向けのフォールバック。
    /// 区間要約はこの後さらに統合段の入力になるだけなので、構造がやや緩くても実害がない。
    private static func respondSectionAsFreeText(prompt: String, options: GenerationOptions) async throws -> SectionSummary {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt + "\n\n箇条書きで、1行1要点、各行1〜2文、最大8行で答えてください。行頭に必ず【話題】を付けてください。",
            options: options
        )
        return SectionSummary(points: parseBulletLines(response.content))
    }

    /// フォールバック応答の "- " / "・" / "* " / "• " などの行頭記号を剥がし、
    /// 続く "【話題】" を topic として抽出する。【】が無い行は topic を「その他」にする。
    private static func parseBulletLines(_ text: String) -> [SectionPoint] {
        let bulletPrefixes = ["- ", "・", "* ", "• "]
        var points: [SectionPoint] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if let prefix = bulletPrefixes.first(where: trimmed.hasPrefix) {
                trimmed = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
            guard !trimmed.isEmpty else { continue }
            let (topic, point) = parseTopicLine(trimmed)
            points.append(SectionPoint(topic: topic, point: point))
            if points.count >= 8 { break }
        }
        return points
    }

    /// "- 【話題】要点" や "【話題】要点" 形式の1行を topic と point に分解する。
    /// 話題ラベルが無い、または壊れている行は topic を「その他」にする。
    /// 自由文フォールバックのパースと groupPointsByTopic のグルーピングの両方から使う共通処理。
    private static func parseTopicLine(_ line: String) -> (topic: String, point: String) {
        var trimmed = line
        if trimmed.hasPrefix("- ") {
            trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        guard trimmed.hasPrefix("【"), let closingIndex = trimmed.firstIndex(of: "】") else {
            return ("その他", trimmed)
        }
        let topic = trimmed[trimmed.index(after: trimmed.startIndex)..<closingIndex].trimmingCharacters(in: .whitespaces)
        let point = trimmed[trimmed.index(after: closingIndex)...].trimmingCharacters(in: .whitespaces)
        guard !topic.isEmpty, !point.isEmpty else {
            return ("その他", trimmed)
        }
        return (topic, point)
    }

    /// 行単位で limit 文字以内のかたまりに分ける(発話の途中で切らない)。
    private static func split(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [""] : chunks
    }

    /// GenerationError を英語のまま UI に漏らさず、日本語の SummarizerError に変換する。
    /// guardrailViolation は呼び出し元(区間要約/統合段)で個別ハンドリング済みのため、
    /// ここに来るのはそれ以外の全区間失敗やその他のエラーケース。
    private static func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> Error {
        switch error {
        case .guardrailViolation:
            return SummarizerError.guardrailBlocked
        case .exceededContextWindowSize:
            return SummarizerError.generationFailed("文字起こしが長すぎて要約できませんでした")
        case .assetsUnavailable:
            return SummarizerError.generationFailed("オンデバイスモデルのデータが利用できません。しばらくしてからもう一度お試しください")
        case .rateLimited:
            return SummarizerError.generationFailed("リクエストが集中しています。しばらくしてからもう一度お試しください")
        case .concurrentRequests:
            return SummarizerError.generationFailed("他の処理でモデルが使用中です。しばらくしてからもう一度お試しください")
        case .unsupportedLanguageOrLocale:
            return SummarizerError.generationFailed("この言語・ロケールには対応していません")
        case .unsupportedGuide, .decodingFailure:
            return SummarizerError.generationFailed("要約の生成に失敗しました")
        case .refusal:
            return SummarizerError.guardrailBlocked
        @unknown default:
            return SummarizerError.generationFailed("要約の生成に失敗しました")
        }
    }
}
