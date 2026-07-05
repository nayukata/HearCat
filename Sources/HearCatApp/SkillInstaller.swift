import Foundation

/// agent skill と CLI をワンクリックで導入する。
/// SKILL.md と CLI 本体はアプリバンドルに同梱されている(Makefile がコピーする)。
enum SkillInstaller {
    /// skill の実体を置く唯一の場所。エージェント非依存の標準ディレクトリ。
    static var universalSkillDirectory: URL {
        home.appendingPathComponent(".agents/skills/hearcat")
    }

    /// 固有の skills ディレクトリを持つ主要エージェント。
    /// Claude Code などは ~/.agents を探索しないため、`~/.<名前>` が存在する
    /// (=そのエージェントを使っている)場合は実体へのリンクを張って見つけられるようにする。
    private static let agentDirectoryNames = ["claude", "codex", "cursor", "copilot", "gemini"]

    static var cliDestination: URL {
        home.appendingPathComponent(".local/bin/hearcat")
    }

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// 実体へのリンクを張る先(検出されたエージェントの skills ディレクトリ)。
    static func agentLinkDestinations() -> [URL] {
        var links: [URL] = []
        for name in agentDirectoryNames {
            let agentRoot = home.appendingPathComponent(".\(name)")
            if FileManager.default.fileExists(atPath: agentRoot.path) {
                links.append(agentRoot.appendingPathComponent("skills/hearcat"))
            }
        }
        return links
    }

    static var skillInstalled: Bool {
        FileManager.default.fileExists(
            atPath: universalSkillDirectory.appendingPathComponent("SKILL.md").path)
    }

    static var cliInstalled: Bool {
        let candidates = [
            cliDestination.path,
            "/usr/local/bin/hearcat",
            "/opt/homebrew/bin/hearcat",
        ]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    enum InstallError: LocalizedError {
        case notBundled(String)

        var errorDescription: String? {
            switch self {
            case .notBundled(let name):
                return "アプリに \(name) が同梱されていません。install.sh か make app で組み立て直してください。"
            }
        }
    }

    /// SKILL.md の実体を共通置き場へ、各エージェントへはリンクを、
    /// CLI を ~/.local/bin/hearcat へ配置する。
    static func install() throws {
        guard let skillSource = Bundle.main.url(forResource: "SKILL", withExtension: "md") else {
            throw InstallError.notBundled("SKILL.md")
        }
        guard let cliSource = Bundle.main.url(forAuxiliaryExecutable: "hearcat-cli") else {
            throw InstallError.notBundled("CLI")
        }
        let fm = FileManager.default

        try fm.createDirectory(at: universalSkillDirectory, withIntermediateDirectories: true)
        try replace(
            at: universalSkillDirectory.appendingPathComponent("SKILL.md"), with: skillSource)

        for link in agentLinkDestinations() {
            try fm.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 旧バージョンが実体のコピーを置いていた場合も、リンクに置き換える。
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: universalSkillDirectory)
        }

        try fm.createDirectory(
            at: cliDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try replace(at: cliDestination, with: cliSource)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliDestination.path)

        removeLegacyArtifacts()
    }

    /// 導入済みなら黙って配置し直す(アプリ起動時に呼ぶ)。
    /// アプリ更新で同梱の SKILL.md / CLI が新しくなっても、手動の再導入なしで反映されるように。
    static func refreshIfInstalled() {
        guard skillInstalled else { return }
        try? install()
    }

    /// 旧名(sharingan)時代に配置した skill と CLI を消す。名前が変わった残骸は動かないだけなので掃除する。
    private static func removeLegacyArtifacts() {
        let fm = FileManager.default
        var legacy = [home.appendingPathComponent(".agents/skills/sharingan")]
        for name in agentDirectoryNames {
            legacy.append(home.appendingPathComponent(".\(name)/skills/sharingan"))
        }
        legacy.append(home.appendingPathComponent(".local/bin/sharingan"))
        for url in legacy where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
    }

    private static func replace(at destination: URL, with source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }
}
