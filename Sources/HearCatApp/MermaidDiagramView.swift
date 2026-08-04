import AppKit
import SwiftUI
import WebKit

/// mermaid コード 1 ブロックを WKWebView で描画する。エージェント出力(信頼できない入力)を
/// 扱うため、外部リクエストは一切発生させず(`loadHTMLString(_:baseURL: nil)`)、
/// 最初のロード以外のナビゲーション(リンククリック等)はすべて拒否する。
///
/// 描画結果の実寸は `@Binding var height` で呼び出し側へ返す。呼び出し側はこれで
/// `.frame(height:)` を組み、内容ぴったりの高さにする(縦スクロールは発生させない)。
/// 構文エラー等で描画に失敗した場合は `@Binding var failed` を立てるだけで、
/// 失敗時の見た目(コード表示へのフォールバック)は呼び出し側が決める。
struct MermaidDiagramView: NSViewRepresentable {
    let code: String
    @Binding var height: CGFloat
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "mermaid")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // パネルの背景(HCColor.mistDark)を透かして見せるため、WebView 自体の背景描画を切る。
        webView.setValue(false, forKey: "drawsBackground")
        if let js = Self.mermaidJS {
            webView.loadHTMLString(Self.html(code: code, js: js), baseURL: nil)
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
    }

    /// WKNavigationDelegate 側の `decidePolicyFor` は `@MainActor` 付きで宣言されているため
    /// そのまま `@MainActor` を付けて適合させる。一方 WKScriptMessageHandler 側の
    /// `didReceive` には isolation の指定が無い(が実際は必ずメインスレッドから呼ばれる)ため、
    /// CodeImpactOverlay.swift の NSAnimationContext 完了ハンドラと同じく
    /// `MainActor.assumeIsolated` で明示する。
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MermaidDiagramView
        private var hasAllowedInitialLoad = false

        init(parent: MermaidDiagramView) {
            self.parent = parent
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            // 最初の loadHTMLString だけを通し、以降のナビゲーション(リンククリック等、
            // エージェント出力に紛れ込んだ信頼できない内容からの遷移)はすべて止める。
            if !hasAllowedInitialLoad, navigationAction.navigationType == .other {
                hasAllowedInitialLoad = true
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
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

    private static func html(code: String, js: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          html, body {
            margin: 0;
            padding: 0;
            background: transparent;
            color: #D8DDE0;
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
              theme: "dark",
              darkMode: true,
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
