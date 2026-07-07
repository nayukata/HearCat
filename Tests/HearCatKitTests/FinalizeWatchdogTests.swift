import Foundation
import Testing

@testable import HearCatKit

struct FinalizeWatchdogTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// #expect 内で mutating メソッドを直接呼べないため、結果を受けてから検証する。
    private func request(_ watchdog: inout FinalizeWatchdog, after seconds: TimeInterval) -> Bool {
        watchdog.shouldRequestFinalize(now: base.addingTimeInterval(seconds))
    }

    @Test func 暫定が静止したら強制確定を要求する() {
        var watchdog = FinalizeWatchdog()
        watchdog.noteVolatile("こんにちは", at: base)

        #expect(!request(&watchdog, after: 1))
        #expect(request(&watchdog, after: 2.1))
    }

    @Test func 実音声が流れている間は暫定が静止しても切らない() {
        // 認識器はチャンク処理のため、発話中でも暫定が2〜3秒止まることがある。
        // 実音声が続いている=まだ喋っている間に文の途中で確定しないこと。
        var watchdog = FinalizeWatchdog()
        watchdog.noteVolatile("あれだけ頑張って", at: base)
        watchdog.noteVoicedAudio(throughFrame: 48_000, at: base.addingTimeInterval(2))

        #expect(!request(&watchdog, after: 2.5))
    }

    @Test func 実音声が鳴り続ける環境では長めの静止で切る() {
        // ゲーム音などが常時鳴っていて「音の静まり」が来ない環境でも、
        // 暫定が noisyStallAfter 秒静止したら区切る(でないと確定が数十秒遅れる)。
        var watchdog = FinalizeWatchdog()
        watchdog.noteVolatile("まあまあすごい", at: base)
        var fed = 0
        for second in stride(from: 0.0, through: 7.0, by: 0.5) {
            fed += 8000
            watchdog.noteVoicedAudio(throughFrame: fed, at: base.addingTimeInterval(second))
        }

        #expect(!request(&watchdog, after: 5.5))
        #expect(request(&watchdog, after: 6.1))
    }

    @Test func 暫定が更新され続ける間は要求しない() {
        var watchdog = FinalizeWatchdog()
        watchdog.noteVolatile("こん", at: base)
        watchdog.noteVolatile("こんにち", at: base.addingTimeInterval(1.5))
        watchdog.noteVolatile("こんにちは", at: base.addingTimeInterval(3))

        #expect(!request(&watchdog, after: 4))
    }

    @Test func 暫定が出ないまま認識器が休眠しても要求する() {
        // 「なるほど」事件の再現: 実音声を送ったのに暫定が1つも来ない。
        var watchdog = FinalizeWatchdog()
        watchdog.noteVoicedAudio(throughFrame: 48_000, at: base)

        #expect(!request(&watchdog, after: 1))
        #expect(request(&watchdog, after: 2.1))
    }

    @Test func 音声が流れ続けている間は暫定なしでも要求しない() {
        var watchdog = FinalizeWatchdog()
        watchdog.noteVoicedAudio(throughFrame: 48_000, at: base)
        watchdog.noteVoicedAudio(throughFrame: 96_000, at: base.addingTimeInterval(1.5))

        #expect(!request(&watchdog, after: 2.5))
    }

    @Test func 確定済み範囲の音声には要求しない() {
        var watchdog = FinalizeWatchdog()
        watchdog.noteVoicedAudio(throughFrame: 48_000, at: base)
        watchdog.noteFinal(throughFrame: 60_000)

        #expect(!request(&watchdog, after: 10))
    }

    @Test func 要求後は結果が来るまで連打しないが5秒で再要求する() {
        var watchdog = FinalizeWatchdog()
        watchdog.noteVolatile("こんにちは", at: base)

        #expect(request(&watchdog, after: 2.1))
        #expect(!request(&watchdog, after: 3))
        #expect(request(&watchdog, after: 7.2))
    }

    @Test func 要求後に確定が届いたら再要求しない() {
        var watchdog = FinalizeWatchdog()
        watchdog.noteVoicedAudio(throughFrame: 48_000, at: base)
        #expect(request(&watchdog, after: 2.1))
        watchdog.noteFinal(throughFrame: 50_000)

        #expect(!request(&watchdog, after: 20))
    }

    @Test func 破棄された確定でも確定済み範囲が進む() {
        // 記号だけの確定は表示からは捨てられるが、watchdog が「未確定の音声が残ってる」と
        // 誤解して要求し続けないよう、確定済み範囲は進めること。
        var watchdog = FinalizeWatchdog()
        watchdog.noteVoicedAudio(throughFrame: 48_000, at: base)
        watchdog.noteFinal(throughFrame: 48_000)

        #expect(!request(&watchdog, after: 5))
    }

    @Test func 暫定なし経路は3回空振りしたら諦める() {
        // 咳など、認識器が文字にしない音への要求を無限に繰り返さない。
        var watchdog = FinalizeWatchdog()
        watchdog.noteVoicedAudio(throughFrame: 48_000, at: base)

        var requests = 0
        for second in stride(from: 0.0, through: 60.0, by: 0.5) {
            if request(&watchdog, after: second) {
                requests += 1
            }
        }
        #expect(requests == FinalizeWatchdog.maxSilentAttempts)
    }

    @Test func 諦めた後の新しい音声には再び要求する() {
        var watchdog = FinalizeWatchdog()
        watchdog.noteVoicedAudio(throughFrame: 48_000, at: base)
        for second in stride(from: 0.0, through: 60.0, by: 0.5) {
            _ = request(&watchdog, after: second)
        }
        watchdog.noteVoicedAudio(throughFrame: 96_000, at: base.addingTimeInterval(70))

        #expect(request(&watchdog, after: 72.1))
    }
}
