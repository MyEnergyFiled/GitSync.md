#if HUGO_RUNTIME_AVAILABLE
import Foundation
import XCTest
import WebKit
@testable import Sync_md

@MainActor
final class HugoRealPreviewRuntimeTests: XCTestCase {
    func testEmbeddedHugoRendersFixtureThroughLoopbackWebViewAndExecutesJavaScript() async throws {
        let fixture = try XCTUnwrap(
            Bundle(for: HugoRealPreviewRuntimeTests.self).url(
                forResource: "HugoRealPreviewFixture",
                withExtension: nil
            )
        )
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HugoRealPreviewRuntime-\(UUID().uuidString)", isDirectory: true)
        let workspace = try HugoPreviewWorkspace(
            repositoryID: UUID(),
            themeID: "ThemeA",
            baseURL: baseURL
        )
        let runtime = HugoRuntimeService.shared
        let server = HugoPreviewHTTPServer()
        var session: HugoSessionID?
        defer {
            Task {
                await server.stop()
                if let session {
                    await runtime.closeSession(session)
                }
                try? FileManager.default.removeItem(at: baseURL)
            }
        }

        let openRequest = try workspace.openRequest(
            repositoryRoot: fixture,
            selectedTheme: "ThemeA",
            overlayFiles: []
        )
        session = try await runtime.openSession(openRequest)
        let sessionID = try XCTUnwrap(session)
        let origin = try await server.start(outputDirectory: workspace.outputURL)
        let result = try await runtime.build(
            HugoBuildRequest(
                mode: .editorPage,
                repositoryRoot: fixture.path,
                articleRepositoryRelativePath: "content/posts/first/index.md",
                selectedTheme: "ThemeA",
                baseURL: origin.absoluteString,
                environment: "production",
                buildDrafts: true,
                buildFuture: true,
                buildExpired: true,
                overlayFiles: [],
                generation: 1
            ),
            in: sessionID
        )

        XCTAssertEqual(result.entryPath, "posts/first/index.html")
        XCTAssertTrue(result.renderedPaths.contains { $0.hasSuffix(".css") })
        XCTAssertTrue(result.renderedPaths.contains { $0.hasSuffix(".js") })

        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.websiteDataStore = .nonPersistent()
        webViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        let navigation = WebViewNavigationExpectation()
        webView.navigationDelegate = navigation
        webView.load(URLRequest(url: origin.appendingPathComponent(result.entryPath)))
        try await fulfillment(of: [navigation.finished], timeout: 15)

        let theme = try await webView.evaluateJavaScript(
            "document.documentElement.dataset.fixtureTheme"
        ) as? String
        XCTAssertEqual(theme, "theme-a")
        let title = try await webView.evaluateJavaScript("document.querySelector('h1').textContent") as? String
        XCTAssertEqual(title, "First fixture page")
    }
}

@MainActor
private final class WebViewNavigationExpectation: NSObject, WKNavigationDelegate {
    let finished = XCTestExpectation(description: "Hugo output loads in WKWebView")

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished.fulfill()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        XCTFail("Hugo output failed to load: \(error.localizedDescription)")
        finished.fulfill()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        XCTFail("Hugo output failed to load provisionally: \(error.localizedDescription)")
        finished.fulfill()
    }
}
#endif
