import Foundation

/// 1つのバージョンに入った変更。種別(追加・変更・修正)ごとにまとめる。
struct ReleaseNote: Equatable, Identifiable {
    /// 変更1件。題は変わった対象(画面や機能の名前)、本文はそれで何が起きるか。
    struct Change: Equatable {
        let title: String?
        let detail: String
    }

    struct Group: Equatable, Identifiable {
        let kind: String
        let changes: [Change]
        var id: String { kind }
    }

    let version: String
    /// そのバージョンを一言でまとめる行。無いこともある。
    let summary: String?
    let groups: [Group]
    var id: String { version }
}

/// 取得の結果。画面はこの3つだけを見て描く。
enum ReleaseNotesState: Equatable {
    case loading
    case loaded([ReleaseNote])
    case failed
}

/// 変更履歴 (CHANGELOG.md) を読み、バージョンごとの箇条書きに直す。
///
/// まだ手元に無い新しいバージョンの内容も見せたいので、まず GitHub の main を読む。
/// 通信できないときのために .app へ同梱した写しへ落とす(同梱側には、そのバージョンまでの履歴が入っている)。
enum ReleaseNotes {
    /// 画面に出す件数。古いものまで並べると、更新の判断に要る直近の変更が埋もれる。
    static let displayCount = 5

    /// UpdateCheck が読む Info.plist と同じ CDN 配信。GitHub API のレート制限に掛からない。
    private static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/nayukata/HearCat/main/CHANGELOG.md"
    )!

    static func load() async -> ReleaseNotesState {
        if let markdown = await fetchRemote() {
            let notes = parse(markdown)
            if !notes.isEmpty { return .loaded(Array(notes.prefix(displayCount))) }
        }
        if let markdown = bundledMarkdown() {
            let notes = parse(markdown)
            if !notes.isEmpty { return .loaded(Array(notes.prefix(displayCount))) }
        }
        return .failed
    }

    private static func fetchRemote() async -> String? {
        var request = URLRequest(url: remoteURL)
        // 最新の履歴を見に行くので、手元に残った古い応答を使わせない。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            http.statusCode == 200
        else { return nil }

        return String(data: data, encoding: .utf8)
    }

    private static func bundledMarkdown() -> String? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// `## バージョン` `### 種別` `- **題** 本文` を拾う。バージョンの見出しの直後にある地の文は、
    /// そのバージョンの一言としてまとめて扱う。それ以外の行(前書きなど)は捨てる。
    static func parse(_ markdown: String) -> [ReleaseNote] {
        var notes: [ReleaseNote] = []
        var version: String?
        var summary: String?
        var groups: [ReleaseNote.Group] = []
        var kind: String?
        var changes: [ReleaseNote.Change] = []

        func closeGroup() {
            if let kind, !changes.isEmpty {
                groups.append(ReleaseNote.Group(kind: kind, changes: changes))
            }
            kind = nil
            changes = []
        }

        func closeVersion() {
            closeGroup()
            if let version, !groups.isEmpty {
                notes.append(ReleaseNote(version: version, summary: summary, groups: groups))
            }
            version = nil
            summary = nil
            groups = []
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") {
                closeGroup()
                kind = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("## ") {
                closeVersion()
                version = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- "), version != nil, kind != nil {
                changes.append(change(from: String(line.dropFirst(2))))
            } else if !line.isEmpty, !line.hasPrefix("#"), version != nil, kind == nil {
                summary = line
            }
        }
        closeVersion()

        return notes
    }

    /// `**題** 本文` を題と本文に割る。太字が無い行は本文だけとして扱う。
    private static func change(from text: String) -> ReleaseNote.Change {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("**"), let close = trimmed.range(of: "**", range: trimmed.index(trimmed.startIndex, offsetBy: 2)..<trimmed.endIndex) else {
            return ReleaseNote.Change(title: nil, detail: trimmed)
        }
        let title = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let detail = String(trimmed[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return ReleaseNote.Change(title: nil, detail: trimmed) }
        return ReleaseNote.Change(title: title, detail: detail)
    }
}
