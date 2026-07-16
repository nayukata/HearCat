// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hearcat",
    platforms: [.macOS("26.0")],
    targets: [
        // 音声キャプチャ・文字起こし・録音・セッション管理・IPC の共通部品。
        // アプリ(常駐エンジン)と CLI(操作窓口)の両方から使う。
        .target(
            name: "HearCatKit",
            path: "Sources/HearCatKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // アプリへ IPC で命令を送るだけの薄い CLI。音声には触らない。
        .executableTarget(
            name: "hearcat",
            dependencies: ["HearCatKit"],
            path: "Sources/HearCatCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // オンデバイス要約 (FoundationModels) の共通部品。
        // アプリと検証用 CLI (summarize-lab) の両方から使う。
        .target(
            name: "HearCatSummarize",
            path: "Sources/HearCatSummarize",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // メニューバー常駐のエンジン本体。録音/文字起こし/履歴/再生/要約の UI を持つ。
        // .app バンドルの組み立てと署名は Makefile の app ターゲットが行う。
        .executableTarget(
            name: "HearCatApp",
            dependencies: ["HearCatKit", "HearCatSummarize"],
            path: "Sources/HearCatApp",
            exclude: ["Info.plist", "AppIcon.icns"],
            // 同梱フォント(Noto Sans JP)。起動時に HCFont.registerBundledFonts() が登録する。
            resources: [.copy("Resources/Fonts")],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // オンデバイス要約の品質検証用 CLI。アプリを起動せず繰り返し実行できるようにする。
        // 開発検証専用で .app には同梱しない。
        .executableTarget(
            name: "summarize-lab",
            dependencies: ["HearCatSummarize"],
            path: "Sources/SummarizeLab",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "HearCatKitTests",
            dependencies: ["HearCatKit"],
            path: "Tests/HearCatKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
