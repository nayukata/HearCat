import Foundation

/// agent skill と CLI をワンクリックで導入する。
/// skill 群と CLI 本体はアプリバンドルに同梱されている(Makefile がコピーする)。
enum SkillInstaller {
    /// 同梱・配布する skill の名前(バンドル内の Resources/skills/<名前>/SKILL.md と一致する)。
    /// 追加/廃止する時はここだけ触ればよい。
    private static let skillNames = ["hearcat", "hearcat-clean"]

    /// skill の実体を置くルート。エージェント非依存の標準ディレクトリ。
    static var universalSkillRoot: URL {
        home.appendingPathComponent(".agents/skills")
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

    /// 各エージェントの skills ディレクトリ(存在するもののみ)。
    static func agentSkillsDirectories() -> [URL] {
        var dirs: [URL] = []
        for name in agentDirectoryNames {
            let agentRoot = home.appendingPathComponent(".\(name)")
            if FileManager.default.fileExists(atPath: agentRoot.path) {
                dirs.append(agentRoot.appendingPathComponent("skills"))
            }
        }
        return dirs
    }

    static var skillInstalled: Bool {
        // 親スキル(hearcat)の SKILL.md が実体で置かれていれば「導入済み」とみなす。
        // 新設スキル(hearcat-clean)は refreshIfInstalled で自動追従させる。
        FileManager.default.fileExists(
            atPath: universalSkillRoot.appendingPathComponent("hearcat/SKILL.md").path)
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

    /// skill 群の実体を共通置き場へ、各エージェントへはリンクを、
    /// CLI を ~/.local/bin/hearcat へ配置する。
    static func install() throws {
        guard let bundledSkillsRoot = Bundle.main.url(forResource: "skills", withExtension: nil)
        else {
            throw InstallError.notBundled("skills")
        }
        guard let cliSource = Bundle.main.url(forAuxiliaryExecutable: "hearcat-cli") else {
            throw InstallError.notBundled("CLI")
        }
        let fm = FileManager.default

        try fm.createDirectory(at: universalSkillRoot, withIntermediateDirectories: true)
        for name in skillNames {
            let source = bundledSkillsRoot.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else {
                throw InstallError.notBundled("skills/\(name)")
            }
            let destination = universalSkillRoot.appendingPathComponent(name)
            try replace(at: destination, with: source)
        }

        // 各エージェントの skills 配下に、実体ディレクトリへのリンクを張る。
        for agentSkills in agentSkillsDirectories() {
            try fm.createDirectory(at: agentSkills, withIntermediateDirectories: true)
            for name in skillNames {
                let link = agentSkills.appendingPathComponent(name)
                // 旧バージョンが実体のコピーを置いていた場合も、リンクに置き換える。
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(
                    at: link, withDestinationURL: universalSkillRoot.appendingPathComponent(name))
            }
        }

        try fm.createDirectory(
            at: cliDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try replace(at: cliDestination, with: cliSource)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliDestination.path)
    }

    /// 導入済みなら黙って配置し直す(アプリ起動時に呼ぶ)。
    /// アプリ更新で同梱の skill / CLI が新しくなっても、手動の再導入なしで反映されるように。
    static func refreshIfInstalled() {
        guard skillInstalled else { return }
        try? install()
    }

    private static func replace(at destination: URL, with source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }
}
