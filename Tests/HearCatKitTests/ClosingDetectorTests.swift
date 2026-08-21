import Foundation
import Testing

@testable import HearCatKit

/// 文言はすべて、実際の会議の文字起こしから取っている(音声認識の誤変換もそのまま)。
struct ClosingDetectorTests {
    private let start = Date(timeIntervalSince1970: 0)

    /// 開始から十分に経った時刻。始まりの挨拶を避ける待ち時間を越えるため。
    private func later(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(ClosingDetector.warmUp + seconds)
    }

    @Test func 締めの宣言だけで終わりとみなす() {
        var detector = ClosingDetector()
        #expect(
            detector.note("はいでは本日はこれで終わりにしたいと思います。", at: later(1), startedAt: start)
                == .closing)
    }

    @Test func 締めの宣言がなくても別れの挨拶が重なれば終わりとみなす() {
        // 開発の定例は締めを宣言せず、挨拶だけで終わる回が多い。
        // 挨拶は複数人が続けて言うので、1文では届かず数文で届く。
        var detector = ClosingDetector()
        #expect(
            detector.note("はいじゃあ得意なければまた引き続きよろしくお願いします。お願いします", at: later(1), startedAt: start)
                == .none)
        #expect(detector.note("お願いします。失礼します。", at: later(6), startedAt: start) == .closing)
    }

    @Test func 同じ挨拶の繰り返しも終わりの合図として数える() {
        var detector = ClosingDetector()
        #expect(
            detector.note("ですんでまた引き続き何卒よろしくお願いします。お願いします。お願いします。", at: later(1), startedAt: start)
                == .none)
        #expect(
            detector.note("はいお願います。す。じゃあ失礼します失礼します失礼します。", at: later(9), startedAt: start)
                == .closing)
    }

    @Test func 始まりの挨拶では終わりとみなさない() {
        // 「お疲れ様です」「よろしくお願いします」は会議の頭でも同じように出る。
        var detector = ClosingDetector()
        #expect(detector.note("お疲れ様です。", at: start.addingTimeInterval(40), startedAt: start) == .none)
        #expect(
            detector.note("お疲れ様です。お疲れ様です。はいよろしくお願いします。", at: start.addingTimeInterval(63), startedAt: start)
                == .none)
    }

    @Test func 議題の区切りでは終わりとみなさない() {
        // 各自の報告の締めに出る言い方。これだけでは会議全体の終わりにならない。
        var detector = ClosingDetector()
        #expect(detector.note("はい、そんなとこですかね？", at: later(1), startedAt: start) == .none)
        #expect(detector.note("も大丈夫でしょうか大丈夫です。はい。", at: later(6), startedAt: start) == .none)
        #expect(detector.note("自分の方からは以上です。", at: later(30), startedAt: start) == .none)
    }

    @Test func 離れた時刻の挨拶はまとめて数えない() {
        // 見る幅を越えた言葉が積み上がると、会議中のどこかで勝手に発火する。
        var detector = ClosingDetector()
        #expect(detector.note("ありがとうございました。", at: later(1), startedAt: start) == .none)
        #expect(
            detector.note("よろしくお願いします。", at: later(1 + ClosingDetector.window + 10), startedAt: start)
                == .none)
    }

    @Test func 締めのあとに会話が続いたら取り消す() {
        // 締めを宣言してから別の相談が始まる回が実際にある。
        var detector = ClosingDetector()
        #expect(
            detector.note("はいじゃあ今日はこれ以上なければ、これで終わりにしたいと思います。", at: later(1), startedAt: start)
                == .closing)
        let duringExtra = later(1 + ClosingDetector.resumeAfter / 2)
        #expect(detector.note("すいませんはいどうぞ。", at: duringExtra, startedAt: start) == .none)
        let afterExtra = later(1 + ClosingDetector.resumeAfter + 10)
        #expect(detector.note("えっと今テックってディレクターの人たちと。", at: afterExtra, startedAt: start) == .resumed)
    }

    @Test func 取り消したあとの締めをもう一度拾える() {
        var detector = ClosingDetector()
        #expect(detector.note("これで終わりにしたいと思います。", at: later(1), startedAt: start) == .closing)
        #expect(
            detector.note("ちょっと別件だけいいですか。", at: later(1 + ClosingDetector.resumeAfter + 10), startedAt: start)
                == .resumed)
        #expect(
            detector.note("はいでは今日はこれにて終わりにしたいと思います。", at: later(400), startedAt: start) == .closing)
    }

    @Test func 間を置いて締め直したら会話の再開とみなさない() {
        // 一度目の締めのあと少し間が空き、もう一度はっきり終わりを宣言する形。
        // ここを取り消し扱いにすると、本当に終わる場面で確認が引っ込む。
        var detector = ClosingDetector()
        #expect(detector.note("これで終わりにしたいと思います。", at: later(1), startedAt: start) == .closing)
        #expect(
            detector.note(
                "では改めて、今日はこれで終わりにしたいと思います。",
                at: later(1 + ClosingDetector.resumeAfter + 10), startedAt: start) == .closing)
    }

    @Test func 会議と関係ない締めるは終わりとみなさない() {
        // 「締めて」「閉めて」は会議の外でも使う。会議を締める言い方には
        // 区切りの言葉が先に付く。
        var detector = ClosingDetector()
        #expect(
            detector.note("乗る人しっかりシートベルト締めてくださいね。", at: later(1), startedAt: start) == .none)
        #expect(detector.note("ちょっと窓閉めてもらえますか。", at: later(30), startedAt: start) == .none)
        #expect(detector.note("じゃちょっとここで締めてお願いします。", at: later(300), startedAt: start) == .closing)
    }

    @Test func 一度知らせたら同じ締めで繰り返さない() {
        var detector = ClosingDetector()
        #expect(detector.note("じゃあ一旦締めてお疲れ様でした。", at: later(1), startedAt: start) == .closing)
        #expect(detector.note("はい、お疲れ様でした。", at: later(4), startedAt: start) == .none)
        #expect(detector.note("失礼します。", at: later(9), startedAt: start) == .none)
    }

    @Test func 点数の内訳が言い方の強さと合っている() {
        // 会議全体の終わりを指す言い方は、それ1つで閾値に届く。
        #expect(ClosingDetector.score(of: ["じゃあ一旦締めて"]) >= ClosingDetector.threshold)
        // 区切りの言い方は届かない。
        #expect(ClosingDetector.score(of: ["そんなとこですかね"]) < ClosingDetector.threshold)
        // 別れの挨拶は種類が揃って初めて届く。
        #expect(ClosingDetector.score(of: ["ありがとうございました"]) < ClosingDetector.threshold)
        #expect(
            ClosingDetector.score(of: ["ありがとうございました", "失礼します", "また来週"])
                >= ClosingDetector.threshold)
    }
}
