import SwiftUI
import Combine
import UIKit
import WebKit

@MainActor
final class HugoRealPreviewModel: ObservableObject {
    @Published private(set) var snapshot = HugoPreviewStateSnapshot(
        phase: .idle,
        runtimeVersion: nil,
        generation: 0
    )

    private let runtime: HugoRuntimeService
    private let coordinator: HugoPreviewBuildCoordinator
    private let server = HugoPreviewHTTPServer()
    private var session: HugoSessionID?
    private var workspace: HugoPreviewWorkspace?
    private var repositoryRoot: URL?
    private var selectedTheme: String?

    init(runtime: HugoRuntimeService = .shared) {
        self.runtime = runtime
        self.coordinator = HugoPreviewBuildCoordinator(runtime: runtime)
    }

    func build(_ request: HugoBuildRequest, repositoryID: UUID) async {
        snapshot = HugoPreviewStateSnapshot(
            phase: .openingRuntime,
            runtimeVersion: snapshot.runtimeVersion,
            generation: request.generation
        )
        do {
            let version = try await runtime.version()
            guard version.version == HugoRuntimeVersion.required.version,
                  version.isExtended == HugoRuntimeVersion.required.isExtended else {
                throw HugoRuntimeError.failure(HugoPreviewFailure(
                    kind: .versionMismatch,
                    summary: String(localized: "This preview requires Hugo 0.134.3 Standard."),
                    diagnostic: "Runtime reported \(version.version)",
                    isRetryable: false
                ))
            }
            snapshot = HugoPreviewStateSnapshot(
                phase: .indexingSite,
                runtimeVersion: version,
                generation: request.generation
            )
            let root = URL(fileURLWithPath: request.repositoryRoot, isDirectory: true)
            let configuration = HugoSiteConfigurationService.discover(in: root)
            if let selectedTheme = request.selectedTheme,
               !HugoThemeDiscoveryService.discover(
                   in: root,
                   configuredThemes: configuration.themes,
                   runtimeVersion: version.version
               ).contains(where: { $0.directoryName == selectedTheme }) {
                throw HugoRuntimeError.failure(HugoPreviewFailure(
                    kind: .themeNotFound,
                    summary: String(localized: "The selected Hugo theme was not found in this repository."),
                    isRetryable: false
                ))
            }
            let capabilities = HugoPreviewCapabilityService.report(
                repositoryRoot: root,
                selectedTheme: request.selectedTheme,
                configuration: configuration,
                runtime: version
            )
            switch capabilities.status {
            case .requiresNewerHugo:
                throw HugoRuntimeError.failure(HugoPreviewFailure(
                    kind: .themeIncompatible,
                    summary: String(localized: "This theme requires a newer Hugo version."),
                    diagnostic: capabilities.details.joined(separator: " "),
                    isRetryable: false
                ))
            case .requiresExtendedHugo:
                throw HugoRuntimeError.failure(HugoPreviewFailure(
                    kind: .versionMismatch,
                    summary: String(localized: "This theme requires Hugo Extended."),
                    isRetryable: false
                ))
            case .requiresExternalExecutable:
                throw HugoRuntimeError.failure(HugoPreviewFailure(
                    kind: .externalToolUnavailable,
                    summary: String(localized: "This theme requires an external build tool that iOS cannot run."),
                    diagnostic: capabilities.details.joined(separator: " "),
                    isRetryable: false
                ))
            case .supported, .requiresNetwork, .unknown:
                break
            }
            let opened = try await coordinator.openSession(
                repositoryID: repositoryID,
                repositoryRoot: root,
                selectedTheme: request.selectedTheme,
                overlayFiles: request.overlayFiles
            )
            workspace = opened.workspace
            session = opened.session
            repositoryRoot = root
            selectedTheme = request.selectedTheme
            let origin = try await server.start(outputDirectory: opened.workspace.outputURL)
            let buildRequest = HugoBuildRequest(
                mode: request.mode,
                repositoryRoot: request.repositoryRoot,
                articleRepositoryRelativePath: request.articleRepositoryRelativePath,
                selectedTheme: request.selectedTheme,
                baseURL: origin.absoluteString,
                environment: request.environment,
                buildDrafts: request.buildDrafts,
                buildFuture: request.buildFuture,
                buildExpired: request.buildExpired,
                overlayFiles: request.overlayFiles,
                generation: request.generation
            )
            let key = await coordinator.sessionKey(
                repositoryRoot: root,
                theme: request.selectedTheme,
                workspace: opened.workspace
            )
            snapshot = HugoPreviewStateSnapshot(
                phase: .building,
                runtimeVersion: version,
                generation: request.generation
            )
            let result = try await coordinator.buildLatest(
                request: buildRequest,
                session: opened.session,
                sessionKey: key
            )
            await HugoPreviewCache.shared.touch(opened.workspace)
            guard result.generation == request.generation else {
                throw HugoRuntimeError.failure(HugoPreviewFailure(
                    kind: .cancelled,
                    summary: String(localized: "A newer preview build is available."),
                    isRetryable: true
                ))
            }
            let entry = result.entryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard HugoPreviewWorkspace.isSafeRepositoryRelativePath(entry) else {
                throw HugoRuntimeError.failure(HugoPreviewFailure(
                    kind: .outputMissing,
                    summary: String(localized: "Hugo did not return a safe preview entry path."),
                    isRetryable: true
                ))
            }
            let entryURL = origin.appendingPathComponent(entry)
            snapshot = HugoPreviewStateSnapshot(
                phase: .ready(entryURL),
                runtimeVersion: version,
                generation: request.generation
            )
        } catch is CancellationError {
            snapshot = HugoPreviewStateSnapshot(
                phase: .failed(HugoPreviewFailure(
                    kind: .cancelled,
                    summary: String(localized: "Preview build cancelled."),
                    isRetryable: true
                )),
                runtimeVersion: snapshot.runtimeVersion,
                generation: request.generation
            )
        } catch let error as HugoRuntimeError {
            let failure: HugoPreviewFailure
            switch error {
            case .unavailable:
                failure = HugoPreviewFailure(
                    kind: .runtimeUnavailable,
                    summary: String(localized: "The embedded Hugo runtime is not installed."),
                    diagnostic: String(localized: "Link HugoRuntime.xcframework built from Hugo 0.134.3."),
                    isRetryable: false
                )
            case .failure(let value):
                failure = value
            case .malformedResponse:
                failure = HugoPreviewFailure(
                    kind: .internalRuntimeError,
                    summary: String(localized: "The embedded Hugo runtime returned an invalid response."),
                    isRetryable: true
                )
            }
            snapshot = HugoPreviewStateSnapshot(
                phase: .failed(failure),
                runtimeVersion: snapshot.runtimeVersion,
                generation: request.generation
            )
        } catch {
            snapshot = HugoPreviewStateSnapshot(
                phase: .failed(HugoPreviewFailure(
                    kind: .internalRuntimeError,
                    summary: String(localized: "Hugo preview failed."),
                    diagnostic: error.localizedDescription,
                    isRetryable: true
                )),
                runtimeVersion: snapshot.runtimeVersion,
                generation: request.generation
            )
        }
    }

    func stop() {
        Task {
            await server.stop()
            if let repositoryRoot, let workspace {
                await coordinator.closeSession(
                    repositoryRoot: repositoryRoot,
                    selectedTheme: selectedTheme,
                    workspace: workspace
                )
            }
        }
        session = nil
        workspace = nil
    }

    func suspendListener() {
        Task { await server.stop() }
    }

    func buildLinkedPage(
        _ url: URL,
        from request: HugoBuildRequest,
        repositoryID: UUID
    ) async {
        guard let root = repositoryRoot,
              let relativePath = linkedArticlePath(for: url, repositoryRoot: root) else {
            return
        }
        let linkedRequest = HugoBuildRequest(
            mode: request.mode,
            repositoryRoot: request.repositoryRoot,
            articleRepositoryRelativePath: relativePath,
            selectedTheme: request.selectedTheme,
            baseURL: request.baseURL,
            environment: request.environment,
            buildDrafts: request.buildDrafts,
            buildFuture: request.buildFuture,
            buildExpired: request.buildExpired,
            overlayFiles: request.overlayFiles,
            generation: snapshot.generation &+ 1
        )
        await build(linkedRequest, repositoryID: repositoryID)
    }

    private func linkedArticlePath(for url: URL, repositoryRoot: URL) -> String? {
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return nil }
        var route = components.dropFirst().joined(separator: "/")
        if route.hasSuffix("/index.html") {
            route.removeLast("/index.html".count)
        } else if route.hasSuffix(".html") {
            route.removeLast(".html".count)
        }
        route = route.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !route.isEmpty else { return nil }
        let candidates = [
            "content/\(route)/index.md",
            "content/\(route)/_index.md",
            "content/\(route).md"
        ]
        return candidates.first { relativePath in
            let candidate = repositoryRoot.appendingPathComponent(relativePath).standardizedFileURL
            guard candidate.path.hasPrefix(repositoryRoot.standardizedFileURL.path + "/"),
                  let values = try? candidate.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return false }
            return candidate.resolvingSymlinksInPath().path.hasPrefix(
                repositoryRoot.resolvingSymlinksInPath().path + "/"
            )
        }
    }
}

struct HugoRealPreviewView: View {
    let request: HugoBuildRequest
    let repositoryID: UUID
    let device: HugoPreviewDevice
    @StateObject private var model: HugoRealPreviewModel

    init(
        request: HugoBuildRequest,
        repositoryID: UUID,
        device: HugoPreviewDevice
    ) {
        self.request = request
        self.repositoryID = repositoryID
        self.device = device
        self._model = StateObject(wrappedValue: HugoRealPreviewModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            content
        }
        .task(id: request.generation) {
            await model.build(request, repositoryID: repositoryID)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification
        )) { _ in
            model.suspendListener()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification
        )) { _ in
            Task { await model.build(request, repositoryID: repositoryID) }
        }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.snapshot.phase {
        case .ready(let url):
            HugoRealPreviewWebView(url: url) { linkedURL in
                Task {
                    await model.buildLinkedPage(
                        linkedURL,
                        from: request,
                        repositoryID: repositoryID
                    )
                }
            }
                .frame(width: device.width)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 10) {
                Label(failure.summary, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                if let diagnostic = failure.diagnostic {
                    Text(diagnostic)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.brutalTextMid)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            ProgressView(String(localized: "Building with Hugo 0.134.3…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
            Text("Hugo 0.134.3")
                .font(.caption.monospaced().bold())
            Spacer()
            if case .ready = model.snapshot.phase {
                Text(String(localized: "Ready"))
            } else if case .failed = model.snapshot.phase {
                Text(String(localized: "Failed"))
            } else {
                Text(String(localized: "Building"))
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(Color.brutalTextMid)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(Color.brutalSurface)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.brutalBorder).frame(height: 1) }
    }
}

struct HugoRealPreviewWebView: UIViewRepresentable {
    let url: URL
    let onLocalNavigation: (URL) -> Void

    init(url: URL, onLocalNavigation: @escaping (URL) -> Void = { _ in }) {
        self.url = url
        self.onLocalNavigation = onLocalNavigation
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.setAllowedURL(url)
        context.coordinator.onLocalNavigation = onLocalNavigation
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .clear
        webView.isOpaque = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.setAllowedURL(url)
        context.coordinator.onLocalNavigation = onLocalNavigation
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var allowedPathPrefix = ""
        var allowedPort: Int?
        var onLocalNavigation: ((URL) -> Void)?

        func setAllowedURL(_ url: URL) {
            allowedPathPrefix = Self.tokenPathPrefix(for: url)
            allowedPort = url.port
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme == "http",
               url.host == "127.0.0.1",
               url.port == allowedPort,
               let requestedPath = url.path.removingPercentEncoding,
               requestedPath == allowedPathPrefix || requestedPath.hasPrefix(allowedPathPrefix + "/") {
                if navigationAction.navigationType == .linkActivated,
                   let loadedURL,
                   loadedURL.path != url.path {
                    onLocalNavigation?(url)
                    decisionHandler(.cancel)
                } else {
                    decisionHandler(.allow)
                }
            } else if url.scheme == "http" || url.scheme == "https" {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
            } else {
                decisionHandler(.cancel)
            }
        }

        private static func tokenPathPrefix(for url: URL) -> String {
            guard let token = url.path.split(separator: "/").first, !token.isEmpty else {
                return ""
            }
            return "/" + token
        }
    }
}
