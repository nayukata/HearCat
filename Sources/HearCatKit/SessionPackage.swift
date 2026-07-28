@preconcurrency import AVFoundation
import Foundation

/// セッション1件を1ファイル(.hearcat)にまとめて、別の Mac の HearCat へ渡すための箱。
///
/// 中身は zip で、直下に固定名のエントリだけを置く(セッションディレクトリ名は日時や
/// セッション名に依存して揺れるため、パッケージ内では名前に意味を持たせない)。
/// 元の名前・日時・所属グループは manifest.json 側が持ち、取り込み側がそこから
/// ディレクトリ名を組み立て直す。
///
/// 取り込みは「展開したものをそのまま置く」ことをしない。一時ディレクトリへ展開したあと、
/// 既知のエントリだけを新しく作ったセッションディレクトリへ複製する。これで、
/// 細工されたパッケージに「../」を含むパスやシンボリックリンク、未知のファイルが
/// 入っていても、sessions ディレクトリの外や既存の記録には一切届かない。
public enum SessionPackage {
    public static let fileExtension = "hearcat"
    /// Info.plist の書類型宣言(UTExportedTypeDeclarations)と一致させること。
    public static let typeIdentifier = "dev.nayukata.hearcat.session"

    /// パッケージの素性を書いたファイル。成果物より先に読む。
    /// 成果物そのものの名前は SessionInfo.Artifact.portableFileName に従う
    /// (箱の中の名前が、書き出した側のセッション名で揺れないように)。
    private static let manifestEntry = "manifest.json"

    /// パッケージの素性。項目を足す時は formatVersion を上げず、省略可能(Optional)にすること
    /// (古いアプリが新しいパッケージを読めなくなるのを避けるため)。
    /// formatVersion を上げるのは、既存項目の意味が変わる時だけ。
    public struct Manifest: Codable, Sendable {
        public static let currentVersion = 1

        public let formatVersion: Int
        /// セッション名。未設定のセッションは空文字。
        public let sessionName: String
        public let startDate: Date
        /// 書き出した側でのグループ名。取り込み側は入れ先を自分で選ぶため、これは参考情報
        /// (新規グループを作る場合の既定値として使う)。
        public let folder: String?
        public let includesAudio: Bool
        /// 要約を生成したエンジン。SummaryEngine の rawValue。
        public let summaryEngine: String?
        /// 書き出したアプリの版。不具合の切り分け用で、読み取り側の分岐には使わない。
        public let appVersion: String?
    }

    /// 取り込み前に中身を確認するために開いた状態のパッケージ。
    /// 一時ディレクトリを抱えているため、install するか discard するかのどちらかを必ず通すこと。
    public struct Opened: Sendable {
        public let manifest: Manifest
        /// 展開済みのセッション。一時ディレクトリを指すだけで、中身は保存済みの
        /// セッションとまったく同じ API で読める(transcriptURL / audioURL /
        /// summaryURL / summaryEngine)。取り込み前の確認画面が、履歴と別の見方を
        /// 用意せずに済むようにするため、専用の型を作らずこれを渡す。
        public let session: SessionInfo
        /// 同梱された録音の長さ。録音が無いか、長さを読めなければ nil。
        /// 「録音が入っているか」は session.audioURL で判定すること。
        public let audioDuration: TimeInterval?
        /// 文字起こしの本文の文字数。中身が空でないことを取り込み前に見せるために使う
        /// (画面の再描画のたびに全文を読み直さないよう、開いた時点で数えておく)。
        public let transcriptCharacterCount: Int

        /// 取り込まずに閉じる。展開した一時ファイルを消す。
        public func discard() {
            try? FileManager.default.removeItem(at: session.directory)
        }
    }

    public enum PackageError: LocalizedError {
        case nothingToExport
        case archiveFailed(String)
        case extractFailed(String)
        case manifestMissing
        case unsupportedVersion(Int)
        case emptyPackage

        public var errorDescription: String? {
            switch self {
            case .nothingToExport:
                return "書き出せる文字起こしも録音もありません"
            case .archiveFailed(let detail):
                return "書き出しに失敗しました (\(detail))"
            case .extractFailed(let detail):
                return "ファイルを開けませんでした (\(detail))"
            case .manifestMissing:
                return "HearCat のセッションファイルではないようです"
            case .unsupportedVersion(let version):
                return "このファイル (形式 \(version)) は、より新しい HearCat で作られています。アプリを更新してください"
            case .emptyPackage:
                return "文字起こしも録音も入っていません"
            }
        }
    }

    // MARK: - 書き出し

    /// 書き出しファイルの既定の名前(拡張子なし)。保存パネルの初期値に使う。
    public static func suggestedFileName(for session: SessionInfo) -> String {
        let datePart = session.startDate.formatted(
            .dateTime.year().month(.twoDigits).day(.twoDigits))
        let base = session.name.isEmpty ? datePart : "\(datePart) \(session.name)"
        return SessionStore.storedName(for: base)
    }

    /// セッションを .hearcat として書き出す。destination に既にファイルがあれば置き換える
    /// (保存パネルが上書き確認を済ませている前提)。
    public static func export(
        _ session: SessionInfo, includeAudio: Bool, to destination: URL
    ) throws {
        // URL 系はどれも実体の存在確認を伴うため、1回だけ引いて使い回す。
        let audio = includeAudio ? session.audioURL : nil
        let engine = session.summaryEngine
        guard session.transcriptURL != nil || session.audioURL != nil else {
            throw PackageError.nothingToExport
        }
        let fm = FileManager.default
        let staging = try makeStagingDirectory()
        defer { try? fm.removeItem(at: staging) }

        for artifact in SessionInfo.Artifact.allCases {
            // 録音は含めない指定があり得る。それ以外は入っているものをそのまま詰める。
            if artifact == .audio, audio == nil { continue }
            guard let source = session.url(of: artifact) else { continue }
            try place(source, at: staging.appendingPathComponent(artifact.portableFileName))
        }

        let manifest = Manifest(
            formatVersion: Manifest.currentVersion,
            sessionName: session.name,
            startDate: session.startDate,
            folder: session.folder,
            includesAudio: audio != nil,
            summaryEngine: engine?.rawValue,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        try Self.encoder.encode(manifest)
            .write(to: staging.appendingPathComponent(manifestEntry), options: .atomic)

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        // --sequesterRsrc: 拡張属性を __MACOSX 側へ寄せる(素の unzip でも中身が読める形にする)。
        // --keepParent は付けない。中身をアーカイブ直下に置き、パッケージ内の名前を
        // セッションディレクトリ名から独立させる。
        let result = try run(
            "/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, destination.path])
        guard result.status == 0 else {
            throw PackageError.archiveFailed(result.message)
        }
    }

    // MARK: - 取り込み

    /// パッケージを一時ディレクトリへ展開し、素性を確かめて返す。
    /// この時点では sessions ディレクトリに何も書かない(取り込むかどうかはユーザーが決める)。
    public static func open(_ url: URL) throws -> Opened {
        let fm = FileManager.default
        let staging = try makeStagingDirectory()
        // 開くのに失敗した場合は、展開した一時ファイルをここで片付ける。
        // 成功した場合の後始末は Opened の受け取り手(install または discard)に渡る。
        do {
            let result = try run("/usr/bin/ditto", ["-x", "-k", url.path, staging.path])
            guard result.status == 0 else {
                throw PackageError.extractFailed(result.message)
            }

            let manifestURL = staging.appendingPathComponent(manifestEntry)
            guard isRegularFile(manifestURL),
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? Self.decoder.decode(Manifest.self, from: data)
            else {
                throw PackageError.manifestMissing
            }
            guard manifest.formatVersion <= Manifest.currentVersion else {
                throw PackageError.unsupportedVersion(manifest.formatVersion)
            }

            // 展開先をそのままセッションとして扱う。パッケージ内の名前(transcript.md /
            // audio.m4a)は SessionInfo が旧形式として読める名前なので、変換を挟まずに
            // 中身を引ける。ここから先「何が入っているか」は manifest ではなく実体で
            // 決まる(手を加えられたパッケージでも、表示と中身が食い違わないように)。
            let session = SessionInfo(
                id: SessionStore.relativeID(for: staging),
                directory: staging,
                startDate: manifest.startDate,
                name: manifest.sessionName,
                folder: manifest.folder)
            let transcript = session.transcriptURL
            guard transcript != nil || session.audioURL != nil else {
                throw PackageError.emptyPackage
            }
            let text = transcript.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

            return Opened(
                manifest: manifest,
                session: session,
                audioDuration: session.audioURL.flatMap(duration(ofAudio:)),
                transcriptCharacterCount: text.contains(where: { !$0.isWhitespace })
                    ? text.count : 0)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// 開いたパッケージを sessions ディレクトリへ取り込む。folder に入れ先のグループ名を渡す
    /// (nil で未分類)。既存のセッションとディレクトリ名がぶつかる場合は別名で作るため、
    /// 取り込みが既存の記録を上書きすることはない。
    @discardableResult
    public static func install(_ opened: Opened, intoFolder folder: String?) throws -> SessionInfo {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: opened.session.directory) }

        let created = try SessionStore.createUniqueSessionDirectory(
            startDate: opened.manifest.startDate,
            name: opened.manifest.sessionName,
            folder: folder)
        let directory = created.directory
        do {
            try moveKnownEntries(from: opened.session.directory, to: directory)
        } catch {
            // 途中で失敗した中途半端なセッションを残さない。
            try? fm.removeItem(at: directory)
            throw error
        }

        return SessionInfo(
            id: SessionStore.relativeID(for: directory),
            directory: directory,
            startDate: opened.manifest.startDate,
            name: created.name,
            // ディスク上の実際のグループ名を返す(入力をそのまま返すと、
            // 使えない文字を含む名前で実体とずれる)。
            folder: created.folder)
    }

    /// 展開結果から、既知の成果物の通常ファイルだけを宛先セッションディレクトリへ移す。
    /// 「展開したものを丸ごと置く」のではなくここを通すことが、細工されたパッケージ
    /// (相対パスで外を指すエントリ、シンボリックリンク、未知のファイル)への防御になっている。
    /// 展開元はこの後どのみち捨てるので、複製ではなく移動でよい(数十 MB の録音を
    /// もう一度書き直さずに済む)。名前は宛先のディレクトリ名に合わせて揃える。
    static func moveKnownEntries(from staging: URL, to directory: URL) throws {
        let dirName = directory.lastPathComponent
        for artifact in SessionInfo.Artifact.allCases {
            guard let source = entry(artifact, in: staging) else { continue }
            try FileManager.default.moveItem(
                at: source,
                to: directory.appendingPathComponent(
                    artifact.fileName(inDirectoryNamed: dirName)))
        }
    }

    // MARK: - 下請け

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func makeStagingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearCatPackage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 書き出し用の一時ディレクトリへ成果物を置く。同じボリュームならハードリンクで済むため、
    /// 数十 MB の録音のバイト列を圧縮前にもう一度書き写さずに済む
    /// (リンクできない場合だけ複製に落ちる)。
    private static func place(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        do {
            try fm.linkItem(at: source, to: destination)
        } catch {
            try fm.copyItem(at: source, to: destination)
        }
    }

    /// パッケージ直下の成果物。展開結果から読むときは必ずこれを通す。
    private static func entry(_ artifact: SessionInfo.Artifact, in directory: URL) -> URL? {
        regularFile(directory, artifact.portableFileName)
    }

    /// 直下の通常ファイル(シンボリックリンクでもディレクトリでもない)だけを返す。
    /// ditto はアーカイブ内のシンボリックリンクをそのまま復元するため、この判定が
    /// 「リンク先を辿って外のファイルを取り込む」経路を塞ぐ。
    private static func regularFile(_ directory: URL, _ name: String) -> URL? {
        let url = directory.appendingPathComponent(name)
        return isRegularFile(url) ? url : nil
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func duration(ofAudio url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
            return nil
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// 外部コマンドを同期実行する。ditto は macOS 標準で、zip の作成と展開の両方を扱える。
    private static func run(
        _ path: String, _ arguments: [String]
    ) throws -> (status: Int32, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, message.isEmpty ? "終了コード \(process.terminationStatus)" : message)
    }
}
