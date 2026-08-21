import Foundation

/// 会議の終わりの挨拶から、録音を止めてよさそうな頃合いを見つける。
///
/// 音量の無音監視だけでは、会議が終わった後もそのまま鳴り続ける音(別のアプリの音、
/// 退出し忘れた通話の雑談)を止められない。「お疲れ様でした」「失礼します」が
/// 出た時点で確かめれば、そこで止められる。
///
/// 判定は、直近の確定文をまとめて見て点数をつける方式。1文だけでは決められないため。
/// 「以上です」は各自の報告の終わりにも出るし、「よろしくお願いします」は依頼の締めにも出る。
/// 逆に「終わりにしたいと思います」は、それ1つで会議全体の終わりを指す。
///
/// 点の付け方は、手元の会議 19本(13〜60分、発話 6,381行)を数えて決めた。
/// この標本で 18本を捉え、会話が続いたのに出してしまったのは 1本。
/// 標本と同じ場でのチューニングなので、初めての場ではこれより落ちる前提で扱う。
public struct ClosingDetector {
    /// 直近の確定文を見る幅。会議の終わりの挨拶は、複数人が続けて言うため
    /// 数十秒に散らばる(実測で最大 45 秒)。広げすぎると会議中の言葉を巻き込む。
    public static let window: TimeInterval = 60
    /// 会議が始まってから、この時間は判定しない。開始直後の「お疲れ様です」
    /// 「よろしくお願いします」は始まりの挨拶で、終わりのそれと言葉が重なる。
    public static let warmUp: TimeInterval = 240
    /// 知らせた後も会話がこれだけ続いたら、まだ終わっていないとみなす。
    /// 締めの言葉の後に別の相談が始まることが実際にある(実測で 3.5 分続いた回がある)。
    public static let resumeAfter: TimeInterval = 90
    public static let threshold = 2.5

    /// それ1つで会議全体の終わりを指す言い方。
    private static let strongClosing = ["終わりにし", "これで終わり", "お開きに"]
    /// 会議を締める言い方に使う動詞。ただしこれだけでは足りない。
    /// 「シートベルトを締めてくださいね」「窓を閉めて」のように、会議と関係なく使う。
    private static let closingVerbs = ["締め", "閉め"]
    /// 締める動詞の直前に置かれる、区切りを示す言葉。会議を締める時はこれが付く。
    private static let closingLeadIns = [
        "一旦", "ここで", "この場", "今日は", "本日は", "では", "じゃあ", "じゃ",
        "そろそろ", "会議を", "会議は",
    ]
    /// 締める動詞から前へ遡って区切りの言葉を探す幅。実際の言い回しは
    /// 「じゃあ一旦今日は締めて」のように間に語を挟むため、隣接では足りない。
    private static let leadInReach = 12
    /// 終わりが近いことは示すが、それだけでは決められない言い方。
    /// 各自の報告の区切りや、議題の切り替えでも出る。
    private static let weakClosing = [
        "今日は以上", "以上となります", "以上です", "そんなとこ", "そんなところ",
        "他大丈夫", "他は大丈夫", "大丈夫そうですか", "他いかがでしょう", "何かありますでしょうか",
    ]
    /// 別れの挨拶。同じ種類を何度数えても終わりの証拠は増えないので、種類の数で見る。
    /// 「お疲れ様です」を「お疲れ様でした」と分けているのは、前者が始まりの挨拶でも
    /// 使われるため(後者はほぼ終わりにしか出ない)。
    private static let farewells: [(name: String, forms: [String])] = [
        ("失礼します", ["失礼します", "失礼いたします"]),
        ("お疲れ様でした", ["お疲れ様でした", "お疲れさまでした", "あざした"]),
        ("ありがとうございました", ["ありがとうございました"]),
        ("次回のあいさつ", ["また来週", "また明日", "また後ほど", "また何かあり", "引き続き"]),
        ("お疲れ様です", ["お疲れ様です", "お疲れさまです"]),
        ("よろしくお願い", ["よろしくお願い"]),
    ]

    /// 判定の結果。
    public enum Signal: Equatable {
        /// 変わりなし。
        case none
        /// 終わりの挨拶が出た。
        case closing
        /// 終わりの挨拶の後、会話が続いている。会議は終わっていない。
        case resumed
    }

    private var recent: [(text: String, at: Date)] = []
    private var firedAt: Date?

    public init() {}

    /// 確定した1文を渡す。返り値が .closing なら、その場で確かめてよい頃合い。
    /// - Parameters:
    ///   - startedAt: セッションを始めた時刻。始まりの挨拶を避けるために使う。
    public mutating func note(_ text: String, at now: Date, startedAt: Date) -> Signal {
        recent.append((text, now))
        recent.removeAll { now.timeIntervalSince($0.at) > Self.window }

        if let firedAt {
            guard now.timeIntervalSince(firedAt) > Self.resumeAfter else { return .none }
            // 前の締めで貯めた点は捨てる。捨てないと、間が空いた後の一言だけで
            // すぐまた閾値に届いてしまう。
            self.firedAt = nil
            recent = [(text, now)]
            // 間を置いてもう一度はっきり締めたのなら、会話が戻ったのではなく締め直し。
            if Self.score(of: [text]) >= Self.threshold {
                self.firedAt = now
                return .closing
            }
            return .resumed
        }

        guard now.timeIntervalSince(startedAt) > Self.warmUp else { return .none }
        guard Self.score(of: recent.map(\.text)) >= Self.threshold else { return .none }
        firedAt = now
        return .closing
    }

    /// 会議全体の終わりを宣言している文か。
    private static func declaresClosing(_ text: String) -> Bool {
        if strongClosing.contains(where: text.contains) { return true }
        for verb in closingVerbs {
            for range in text.ranges(of: verb) {
                let start =
                    text.index(range.lowerBound, offsetBy: -leadInReach, limitedBy: text.startIndex)
                    ?? text.startIndex
                let head = String(text[start..<range.lowerBound])
                if closingLeadIns.contains(where: head.contains) { return true }
            }
        }
        return false
    }

    /// 直近の文の並びに対する点数。判定の内訳を確かめられるよう公開している。
    public static func score(of texts: [String]) -> Double {
        var total = 0.0
        if texts.contains(where: declaresClosing) {
            total += 2.5
        }
        if texts.contains(where: { text in weakClosing.contains { text.contains($0) } }) {
            total += 0.5
        }
        for (_, forms) in farewells {
            let count = texts.reduce(0) { sum, text in
                sum + forms.reduce(0) { $0 + text.occurrences(of: $1) }
            }
            guard count > 0 else { continue }
            total += 1.0
            // 複数人が順に言う、あるいは一人が繰り返すのは終わり際に特有の形。
            if count >= 2 { total += 0.5 }
        }
        return total
    }
}

extension String {
    /// 重なりのない出現回数。
    fileprivate func occurrences(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var cursor = startIndex
        while let found = range(of: needle, range: cursor..<endIndex) {
            count += 1
            cursor = found.upperBound
        }
        return count
    }
}
