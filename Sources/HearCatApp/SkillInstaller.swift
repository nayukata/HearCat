import Foundation

/// agent skill と CLI をワンクリックで導入する。
/// SKILL.md と CLI 本体はアプリバンドルに同梱されている(Makefile がコピーする)。
enum SkillInstaller {
    /// エージェント非依存の共通置き場。ここへは常に配置する。
    /// (VS Code / Copilot / Warp などが対応するユーザーレベルの標準ディレクトリ)
    static var universalSkillDirectory: URL {
        home.appendingPathComponent(".agents/skills/hearcat")
    }

    /// 固有の skills ディレクトリを持つ主要エージェント。
    /// `~/.<名前>` が存在する(=そのエージェントを使っている)場合にだけ追加で配置する。
    private static let agentDirectoryNames = ["claude", "codex", "cursor", "copilot", "gemini"]

    static var cliDestination: URL {
        home.appendingPathComponent(".local/bin/hearcat")
    }

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// SKILL.md の配置先一覧(共通置き場 + 検出されたエージェント)。
    static func skillDestinations() -> [URL] {
        var dirs = [universalSkillDirectory]
        for name in agentDirectoryNames {
            let agentRoot = home.appendingPathComponent(".\(name)")
            if FileManager.default.fileExists(atPath: agentRoot.path) {
                dirs.append(agentRoot.appendingPathComponent("skills/hearcat"))
            }
        }
        return dirs
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

    /// SKILL.md を各エージェントの skills ディレクトリへ、CLI を ~/.local/bin/hearcat へ配置する。
    /// 戻り値は SKILL.md を配置した数。
    @discardableResult
    static func install() throws -> Int {
        guard let skillSource = Bundle.main.url(forResource: "SKILL", withExtension: "md") else {
            throw InstallError.notBundled("SKILL.md")
        }
        guard let cliSource = Bundle.main.url(forAuxiliaryExecutable: "hearcat-cli") else {
            throw InstallError.notBundled("CLI")
        }
        let fm = FileManager.default

        let destinations = skillDestinations()
        for dir in destinations {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try replace(at: dir.appendingPathComponent("SKILL.md"), with: skillSource)
        }

        try fm.createDirectory(
            at: cliDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try replace(at: cliDestination, with: cliSource)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliDestination.path)

        removeLegacyArtifacts()

        return destinations.count
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
