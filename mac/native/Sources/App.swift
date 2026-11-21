// AI Session Viewer (Claude Code + Antigravity 統合ネイティブアプリ)
// データ読み取りはSwift(Engine.swift)、UIはバンドル内のindex.htmlを
// WKWebViewで表示し、JSブリッジ(webkit.messageHandlers.api)でAPIを提供する。
import AppKit
import SwiftUI
import WebKit

@main
struct NativeApp: App {
    var body: some Scene {
        WindowGroup("AI Session Viewer") {
            WebView()
                .frame(minWidth: 1060, minHeight: 660)
        }
    }
}

final class ApiBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    let allowedURL: URL?
    private let queue = DispatchQueue(label: "api", qos: .userInitiated)

    init(allowedURL: URL?) {
        self.allowedURL = allowedURL?.standardizedFileURL
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // バンドル内の index.html (メインフレーム) からの呼び出しのみ許可する
        guard message.frameInfo.isMainFrame,
              let allowedURL,
              let requestURL = message.frameInfo.request.url?.standardizedFileURL,
              requestURL == allowedURL else { return }

        guard let body = message.body as? [String: Any],
              let id = body["id"] as? Int,
              let path = body["path"] as? String else { return }

        queue.async { [weak self] in
            let result = Engine.handle(path: path)
            let json = (try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{\"error\":\"serialize failed\"}"
            DispatchQueue.main.async {
                self?.webView?.callAsyncJavaScript(
                    "window.__apiResolve(id, JSON.parse(json));",
                    arguments: ["id": id, "json": json],
                    in: nil,
                    in: .page,
                    completionHandler: nil
                )
            }
        }
    }
}

final class WebNavigationGuard: NSObject, WKNavigationDelegate, WKUIDelegate {
    let allowedURL: URL?

    init(allowedURL: URL?) {
        self.allowedURL = allowedURL?.standardizedFileURL
    }

    private func openExternallyIfSafe(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // バンドル内 index.html の初回ロードのみ許可し、外部遷移は完全に禁止する
        if let allowedURL, url.standardizedFileURL == allowedURL {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            openExternallyIfSafe(url)
        }
        decisionHandler(.cancel)
    }

    // target="_blank" リンクは WebView 内で開かずデフォルトブラウザへ逃がす
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            openExternallyIfSafe(url)
        }
        return nil
    }
}

struct WebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let indexURL = Bundle.main.url(forResource: "index", withExtension: "html")
        let bridge = ApiBridge(allowedURL: indexURL)
        let navGuard = WebNavigationGuard(allowedURL: indexURL)
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "api")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = navGuard
        webView.uiDelegate = navGuard

        bridge.webView = webView
        context.coordinator.bridge = bridge
        context.coordinator.navGuard = navGuard

        if let indexURL {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var bridge: ApiBridge?
        var navGuard: WebNavigationGuard?
    }
}
