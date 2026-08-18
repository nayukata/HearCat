import AppKit
import SwiftUI
import WebKit

/// mermaid コード 1 ブロックを WKWebView で描画する。エージェント出力(信頼できない入力)を
/// 扱うため、外部リクエストは一切発生させず(`loadHTMLString(_:baseURL: nil)`)、
/// プログラムによる loadHTMLString 以外のナビゲーション(リンククリック等)はすべて拒否する。
/// 外観(ライブ/ダーク)切替時は再度 loadHTMLString で組み直すため、許可は初回限りにしない。
///
/// 描画結果の実寸は `@Binding var height` で呼び出し側へ返す。呼び出し側はこれで
/// `.frame(height:)` を組み、内容ぴったりの高さにする(縦スクロールは発生させない)。
/// 構文エラー等で描画に失敗した場合は `@Binding var failed` を立てるだけで、
/// 失敗時の見た目(コード表示へのフォールバック)は呼び出し側が決める。
struct MermaidDiagramView: NSViewRepresentable {
    let code: String
    @Binding var height: CGFloat
    @Binding var failed: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "mermaid")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // パネルの背景(HCColor.panel)を透かして見せるため、WebView 自体の背景描画を切る。
        webView.setValue(false, forKey: "drawsBackground")
        let isDark = colorScheme == .dark
        if let js = Self.mermaidJS {
            context.coordinator.lastRenderedIsDark = isDark
            webView.loadHTMLString(Self.html(code: code, js: js, isDark: isDark), baseURL: nil)
        } else {
            // 同梱 JS が読めない環境(配布物が壊れている等)。描画失敗として扱う。
            // makeNSView は view update 中に呼ばれるため、state の変更は次のループへ逃がす。
            Task { @MainActor in failed = true }
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // code は View の生成時にしか変わらない(呼び出し側は結果が変わるたびに
        // `.id()` で作り直す)ため、ここでは binding の参照先だけ最新にしておく。
        context.coordinator.parent = self
        // 外観切替(ライブ/ダーク)は View の再生成を伴わないため、前回描画した外観と
        // 違う場合だけここで組み直す。
        let isDark = colorScheme == .dark
        if context.coordinator.lastRenderedIsDark != isDark, let js = Self.mermaidJS {
            context.coordinator.lastRenderedIsDark = isDark
            nsView.loadHTMLString(Self.html(code: code, js: js, isDark: isDark), baseURL: nil)
        }
    }

    /// WKNavigationDelegate 側の `decidePolicyFor` は `@MainActor` 付きで宣言されているため
    /// そのまま `@MainActor` を付けて適合させる。一方 WKScriptMessageHandler 側の
    /// `didReceive` には isolation の指定が無い(が実際は必ずメインスレッドから呼ばれる)ため、
    /// CodeImpactOverlay.swift の NSAnimationContext 完了ハンドラと同じく
    /// `MainActor.assumeIsolated` で明示する。
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MermaidDiagramView
        /// 直近で描画した外観。updateNSView がここと現在の colorScheme を比べて
        /// 再ロードの要否を決める。
        var lastRenderedIsDark: Bool?

        init(parent: MermaidDiagramView) {
            self.parent = parent
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            // loadHTMLString(baseURL: nil) のロード先は about:blank のみ。JS からの遷移は
            // プログラム由来のロードと同じ種別(.other)になり種別では区別できないため、
            // 行き先で判定し、外部への遷移は種別を問わず拒否する。
            let url = navigationAction.request.url
            let isBlank = url == nil || url?.absoluteString == "about:blank"
            decisionHandler(isBlank ? .allow : .cancel)
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            MainActor.assumeIsolated {
                guard
                    let body = message.body as? [String: Any],
                    let status = body["status"] as? String
                else {
                    parent.failed = true
                    return
                }
                if status == "ok", let scrollHeight = body["height"] as? Double {
                    parent.height = max(scrollHeight, 1)
                } else {
                    parent.failed = true
                }
            }
        }
    }

    // MARK: - リソース解決

    /// 2.6MB あるので、読み込んだ JS 文字列はプロセス内で 1 回だけ読んで static にキャッシュする。
    /// static let は遅延初期化かつスレッドセーフなので、明示的なロックは不要。
    private static let mermaidJS: String? = {
        guard let url = mermaidResourceURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// リソースバンドルの探索は DesignTokens.swift の `hcResourceBundleURL()` に集約されている
    /// (探索順序の理由もそちら参照)。ここではそのバンドル配下の mermaid.min.js を指すだけ。
    private static var mermaidResourceURL: URL? {
        hcResourceBundleURL()?.appendingPathComponent("Mermaid/mermaid.min.js")
    }

    // MARK: - HTML 組み立て

    private static func html(code: String, js: String, isDark: Bool) -> String {
        // 16 進直書きは既存の流儀に合わせる(HTML は Swift 側の HCColor を参照できないため)。
        // textBody(本文トークン)のダーク/ライト両側の値と揃える。
        let textColor = isDark ? "#D8DDE0" : "#2D3133"
        let mermaidTheme = isDark ? "dark" : "default"
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          html, body {
            margin: 0;
            padding: 0;
            background: transparent;
            color: \(textColor);
            overflow-x: auto;
            overflow-y: hidden;
          }
          pre.mermaid { margin: 0; }
        </style>
        </head>
        <body>
        <pre class="mermaid">\(escapeHTML(code))</pre>
        <script>\(js)</script>
        <script>
        (async () => {
          try {
            mermaid.initialize({
              startOnLoad: false,
              theme: "\(mermaidTheme)",
              darkMode: \(isDark),
              securityLevel: "strict",
              fontFamily: "-apple-system"
            });
            await mermaid.run();
            window.webkit.messageHandlers.mermaid.postMessage({
              status: "ok",
              height: document.body.scrollHeight
            });
          } catch (e) {
            window.webkit.messageHandlers.mermaid.postMessage({ status: "error" });
          }
        })();
        </script>
        </body>
        </html>
        """
    }

    /// mermaid コードは信頼できないエージェント出力なので、`<pre>` に埋め込む前に必ずエスケープする。
    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
