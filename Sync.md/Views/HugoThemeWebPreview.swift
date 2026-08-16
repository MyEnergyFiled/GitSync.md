import SwiftUI
import WebKit

struct HugoThemeWebPreview: UIViewRepresentable {
    let page: HugoThemePreviewPage
    let repositoryRoot: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(repositoryRoot: repositoryRoot)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(context.coordinator.resourceHandler, forURLScheme: HugoThemePreviewService.resourceScheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .clear
        webView.isOpaque = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let loadKey = page.html + "\u{0}" + page.resourceSignature
        guard context.coordinator.loadedHTML != loadKey else { return }
        context.coordinator.loadedHTML = loadKey
        webView.loadHTMLString(page.html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let resourceHandler: HugoPreviewResourceSchemeHandler
        var loadedHTML = ""

        init(repositoryRoot: URL) {
            resourceHandler = HugoPreviewResourceSchemeHandler(repositoryRoot: repositoryRoot)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme
            if navigationAction.navigationType == .other && (scheme == nil || scheme == "about") {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

final class HugoPreviewResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private let repositoryRoot: URL

    init(repositoryRoot: URL) {
        self.repositoryRoot = repositoryRoot
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = HugoThemePreviewService.resourceFileURL(
                  from: requestURL,
                  repositoryRoot: repositoryRoot
              ) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let response = URLResponse(
                url: requestURL,
                mimeType: HugoThemePreviewService.mimeType(for: fileURL),
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
