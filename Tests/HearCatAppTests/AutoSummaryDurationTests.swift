import Foundation
import Testing

@testable import HearCatApp

struct AutoSummaryDurationTests {
    @Test func 五分未満は自動要約しない() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(!AppModel.shouldAutoSummarize(startedAt: start, endedAt: start.addingTimeInterval(299)))
        #expect(AppModel.shouldAutoSummarize(startedAt: start, endedAt: start.addingTimeInterval(300)))
        #expect(AppModel.shouldAutoSummarize(startedAt: start, endedAt: start.addingTimeInterval(3600)))
    }

    @Test func 長さが分からなければ要約する() {
        #expect(AppModel.shouldAutoSummarize(startedAt: nil, endedAt: Date()))
    }
}
