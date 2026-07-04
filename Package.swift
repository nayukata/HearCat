// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sharingan",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "sharingan",
            path: "Sources/sharingan",
            // Info.plist はソースではなく linker で __info_plist セクションに埋め込むため、
            // SPM のソース走査からは除外する。
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                // TCC 用の usage description を CLI バイナリに埋め込む。
                // .app バンドルでない実行ファイルでもマイク許可ダイアログが正しく出るようにするため。
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/sharingan/Info.plist",
                ])
            ]
        )
    ]
)
