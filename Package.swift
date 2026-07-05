// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sharingan",
    platforms: [.macOS("26.0")],
    targets: [
        // 音声キャプチャ・文字起こし・録音・セッション管理・IPC の共通部品。
        // アプリ(常駐エンジン)と CLI(操作窓口)の両方から使う。
        .target(
            name: "SharinganKit",
            path: "Sources/SharinganKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // アプリへ IPC で命令を送るだけの薄い CLI。音声には触らない。
        .executableTarget(
            name: "sharingan",
            dependencies: ["SharinganKit"],
            path: "Sources/SharinganCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // メニューバー常駐のエンジン本体。録音/文字起こし/履歴/再生/要約の UI を持つ。
        // .app バンドルの組み立てと署名は Makefile の app ターゲットが行う。
        .executableTarget(
            name: "SharinganApp",
            dependencies: ["SharinganKit"],
            path: "Sources/SharinganApp",
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
