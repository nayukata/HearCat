import Testing

@testable import HearCatApp

struct PromisePromptTests {
    private func prompt(includesPriorMeetings: Bool, scope: AgentCodeImpactAnalyzer.TargetScope = .pastSession)
        -> String
    {
        AgentCodeImpactAnalyzer.buildPrompt(
            question: "宿題はどうなった?", priorConversation: nil, continuity: .fresh,
            hasReferenceFolder: false, meetingDate: "2026-10-06",
            includesPriorMeetings: includesPriorMeetings, scope: scope)
    }

    @Test func 前の会議を足さないと従来どおりweightsがあり約束の案内は無い() {
        let text = prompt(includesPriorMeetings: false)
        #expect(text.contains("```weights"))
        #expect(!text.contains("```promises"))
        #expect(!text.contains("at と due の基準は質問の対象の会議"))
        #expect(!text.contains("材料の扱い:"))
    }

    @Test func 前の会議を足すとweightsが消え約束と材料の扱いの案内が入る() {
        let text = prompt(includesPriorMeetings: true)
        #expect(!text.contains("```weights"))
        #expect(text.contains("```promises"))
        #expect(text.contains("at と due の基準は質問の対象の会議"))
        #expect(text.contains("材料の扱い:"))
        #expect(text.contains("前の会議の発言は時刻を書かず"))
    }

    @Test func ライブでも前の会議を足すと材料の扱いが入る() {
        let text = prompt(includesPriorMeetings: true, scope: .live)
        #expect(text.contains("材料の扱い:"))
        #expect(!text.contains("```weights"))
    }

    @Test func グループ対象は従来どおり約束の案内があり対象の会議の主役文は無い() {
        let text = prompt(includesPriorMeetings: false, scope: .group)
        #expect(text.contains("```promises"))
        #expect(!text.contains("質問の対象は、見出しの識別子が一番大きい"))
    }
}
