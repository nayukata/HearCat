import Foundation

/// AI エンジン(claude/codex)のモデル選択肢 1 件。設定画面のモデル欄と、
/// 質問パネルのエンジン切替メニューの両方から使う。
struct AgentModelOption: Equatable, Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

/// エンジンごとのモデル候補の一覧。claude は固定候補、codex は ~/.codex/models_cache.json を
/// 都度読んで作る(codex CLI 側の更新でモデルが増減し得るため、静的な一覧を持たない)。
enum AgentModelCatalog {
    static func options(for cli: AgentCLI) -> [AgentModelOption] {
        switch cli {
        case .claude:
            return [
                AgentModelOption(value: "sonnet", label: "Sonnet 5"),
                AgentModelOption(value: "opus", label: "Opus 4.8"),
                AgentModelOption(value: "fable", label: "Fable 5"),
            ]
        case .codex:
            return codexOptions()
        }
    }

    private static func codexOptions() -> [AgentModelOption] {
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: cacheURL),
            let cache = try? JSONDecoder().decode(CodexModelsCache.self, from: data)
        else { return [] }

        return cache.models
            .filter { $0.visibility == "list" }
            .map { AgentModelOption(value: $0.slug, label: $0.displayName) }
    }
}

private struct CodexModelsCache: Decodable {
    let models: [CodexModelEntry]
}

private struct CodexModelEntry: Decodable {
    let slug: String
    let displayName: String
    let visibility: String

    enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case visibility
    }
}
