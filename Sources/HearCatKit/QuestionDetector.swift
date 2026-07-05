import Foundation

/// 疑問文の判定。音声認識は「大丈夫？」を「大丈夫。」のように平叙文として書くため、
/// 2つの手がかりで文末を「？」に直す:
/// 1. 語彙: 「〜ですか」「〜かな」「〜っけ」など、文末の形で疑問と判る場合(高精度)
/// 2. 韻律: 発話末尾のピッチ(基本周波数)が上昇している場合(「大丈夫？」型のイントネーション疑問文)
public enum QuestionDetector {
    // MARK: - 語彙判定

    /// 「か」で終わっていても疑問でない語(形容動詞・不定語)。
    private static let nonQuestionKaEndings = [
        "確か", "静か", "豊か", "愚か", "ほか", "他か", "なんか", "何か",
        "どこか", "いつか", "誰か", "だれか", "些か", "遥か", "はるか",
    ]

    public static func isLexicalQuestion(_ text: String) -> Bool {
        let body = trimmingTrailingPunctuation(text)
        guard !body.isEmpty else { return false }
        for ending in ["かな", "かい", "っけ", "かね", "ですか", "ますか", "のか", "でしょうか", "だろうか"]
        where body.hasSuffix(ending) {
            return true
        }
        if body.hasSuffix("か") {
            return !nonQuestionKaEndings.contains { body.hasSuffix($0) }
        }
        return false
    }

    /// 文末の句点などを「？」に置き換える。すでに「？」ならそのまま。
    public static func markAsQuestion(_ text: String) -> String {
        var body = text
        while let last = body.last, "。．.、!！".contains(last) {
            body.removeLast()
        }
        if body.hasSuffix("?") || body.hasSuffix("？") { return body }
        return body + "？"
    }

    private static func trimmingTrailingPunctuation(_ text: String) -> String {
        var body = text
        while let last = body.last, "。．.、!！?？".contains(last) {
            body.removeLast()
        }
        return body
    }

    // MARK: - 韻律判定(ピッチ上昇)

    /// 発話末尾のモノラル音声(0.5〜1秒程度)からピッチの上昇を検出する。
    /// 日本語の疑問文は最終モーラでピッチが上がるため、
    /// 「末尾の有声区間の後半」と「その前」の F0 中央値を比べる。
    public static func detectsRisingPitch(tail samples: [Float], sampleRate: Double) -> Bool {
        risingPitchAnalysis(tail: samples, sampleRate: sampleRate).rising
    }

    /// 判定の内訳つき(デバッグと閾値調整用)。
    public static func risingPitchAnalysis(
        tail samples: [Float], sampleRate: Double
    ) -> (rising: Bool, voicedFrames: Int, headF0: Double, tailF0: Double, totalVoiced: Int, windows: Int) {
        let window = Int(sampleRate * 0.030)
        let hop = Int(sampleRate * 0.010)
        guard samples.count >= window * 4 else { return (false, 0, 0, 0, 0, 0) }

        var track: [Double] = []
        var start = 0
        while start + window <= samples.count {
            let f0 = estimateF0(samples[start..<(start + window)], sampleRate: sampleRate)
            track.append(f0 ?? 0)
            start += hop
        }
        let windows = track.count
        let totalVoiced = track.filter { $0 > 0 }.count
        // 有声区間(0.05秒までの穴は促音・破裂音とみなして連結)を列挙し、
        // 発話の本体といえる長さ(0.08秒以上)を持つ最後の区間を対象にする。
        // 単純に「最後の有声フレーム」を使うと、発話後のブレスやノイズの数フレームに引きずられる。
        var runs: [[Double]] = []
        var current: [Double] = []
        var gap = 0
        for f0 in track {
            if f0 > 0 {
                current.append(f0)
                gap = 0
            } else if !current.isEmpty {
                gap += 1
                if gap > 5 {
                    runs.append(current)
                    current = []
                }
            }
        }
        if !current.isEmpty { runs.append(current) }
        guard let voiced = runs.last(where: { $0.count >= 8 }) else {
            return (false, runs.last?.count ?? 0, 0, 0, totalVoiced, windows)
        }

        // 日本語の疑問イントネーションは最後のモーラ(約50〜100ms)に集中するため、
        // 「末尾の数フレーム」と「それ以前の中央値」を比べる。区間を広く取ると上昇が薄まる。
        let tailCount = max(3, min(6, voiced.count / 4))
        let head = median(Array(voiced.dropLast(tailCount)))
        let tailF0 = median(Array(voiced.suffix(tailCount)))
        guard head > 0 else { return (false, voiced.count, head, tailF0, totalVoiced, windows) }
        // 末尾が 10% 以上高ければ上昇とみなす(半音は約6%)。
        return (tailF0 / head >= 1.10, voiced.count, head, tailF0, totalVoiced, windows)
    }

    /// 正規化自己相関による F0 推定。人の声の範囲(70〜350Hz)以外や無声は nil。
    static func estimateF0(_ samples: ArraySlice<Float>, sampleRate: Double) -> Double? {
        let x = Array(samples)
        let n = x.count
        var energy: Double = 0
        for v in x { energy += Double(v * v) }
        guard energy / Double(n) > 1e-7 else { return nil }  // ほぼ無音(タップ経由の声は小音量でも通す)

        let minLag = Int(sampleRate / 350)
        let maxLag = min(Int(sampleRate / 70), n - 1)
        guard maxLag > minLag else { return nil }

        var bestLag = 0
        var bestScore = 0.0
        for lag in minLag...maxLag {
            var cross = 0.0
            var e1 = 0.0
            var e2 = 0.0
            for i in 0..<(n - lag) {
                let a = Double(x[i])
                let b = Double(x[i + lag])
                cross += a * b
                e1 += a * a
                e2 += b * b
            }
            guard e1 > 0, e2 > 0 else { continue }
            let score = cross / (e1 * e2).squareRoot()
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        // 相関が弱ければ無声(または雑音)とみなす。
        guard bestScore >= 0.6, bestLag > 0 else { return nil }
        return sampleRate / Double(bestLag)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// 直近の音声を保持する固定長リングバッファ。
/// 確定結果の時刻範囲(audioTimeRange)から発話末尾を切り出すために使う。
struct AudioRing {
    private var storage: [Float]
    private(set) var totalWritten = 0

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: capacity)
    }

    mutating func append(_ samples: [Float]) {
        for sample in samples {
            storage[totalWritten % storage.count] = sample
            totalWritten += 1
        }
    }

    /// 累計フレーム位置 [start, end) を取り出す。すでにリングから溢れた範囲なら nil。
    func slice(start: Int, end: Int) -> [Float]? {
        guard start >= 0, start < end, end <= totalWritten,
              totalWritten - start <= storage.count else { return nil }
        var out = [Float](repeating: 0, count: end - start)
        for i in start..<end {
            out[i - start] = storage[i % storage.count]
        }
        return out
    }
}
