import Foundation
import CryptoKit

actor HugoPreviewBuildCoordinator {
    static let shared = HugoPreviewBuildCoordinator()

    private let runtime: HugoRuntimeService
    private var sessions: [String: HugoSessionID] = [:]
    private var pendingBuilds: [String: Task<HugoBuildResult, Error>] = [:]
    private var latestGeneration: [String: UInt64] = [:]

    init(runtime: HugoRuntimeService = .shared) {
        self.runtime = runtime
    }

    func openSession(
        repositoryID: UUID,
        repositoryRoot: URL,
        selectedTheme: String?,
        overlayFiles: [HugoOverlayFile]
    ) async throws -> (workspace: HugoPreviewWorkspace, session: HugoSessionID) {
        let workspace = try HugoPreviewWorkspace(
            repositoryID: repositoryID,
            themeID: selectedTheme ?? "default"
        )
        for overlay in overlayFiles {
            _ = try workspace.materializeOverlay(overlay)
        }
        let key = sessionKey(repositoryRoot: repositoryRoot, theme: selectedTheme, workspace: workspace)
        if let session = sessions[key] {
            return (workspace, session)
        }
        let request = try workspace.openRequest(
            repositoryRoot: repositoryRoot,
            selectedTheme: selectedTheme,
            overlayFiles: overlayFiles
        )
        let session = try await runtime.openSession(request)
        sessions[key] = session
        return (workspace, session)
    }

    func buildLatest(
        request: HugoBuildRequest,
        session: HugoSessionID,
        sessionKey: String,
        debounceNanoseconds: UInt64 = 400_000_000
    ) async throws -> HugoBuildResult {
        pendingBuilds[sessionKey]?.cancel()
        latestGeneration[sessionKey] = request.generation
        let runtime = self.runtime
        let task = Task<HugoBuildResult, Error> {
            try await Task.sleep(nanoseconds: debounceNanoseconds)
            try Task.checkCancellation()
            let result = try await runtime.build(request, in: session)
            try Task.checkCancellation()
            return result
        }
        pendingBuilds[sessionKey] = task
        defer {
            if latestGeneration[sessionKey] == request.generation {
                pendingBuilds.removeValue(forKey: sessionKey)
            }
        }
        let result = try await task.value
        guard latestGeneration[sessionKey] == request.generation else {
            throw HugoRuntimeError.failure(HugoPreviewFailure(
                kind: .cancelled,
                summary: String(localized: "A newer preview build is available."),
                isRetryable: true
            ))
        }
        return result
    }

    func invalidate(_ request: HugoBuildRequest, in session: HugoSessionID) async throws {
        try await runtime.invalidate(request, in: session)
    }

    func closeSession(
        repositoryRoot: URL,
        selectedTheme: String?,
        workspace: HugoPreviewWorkspace
    ) async {
        let key = sessionKey(repositoryRoot: repositoryRoot, theme: selectedTheme, workspace: workspace)
        pendingBuilds[key]?.cancel()
        pendingBuilds.removeValue(forKey: key)
        if let session = sessions.removeValue(forKey: key) {
            await runtime.closeSession(session)
        }
    }

    func closeSessions(for repositoryRoot: URL) async {
        let prefix = repositoryRoot.standardizedFileURL.path
        let matchingKeys = sessions.keys.filter { $0.hasPrefix(prefix + "|") }
        for key in matchingKeys {
            pendingBuilds[key]?.cancel()
            pendingBuilds.removeValue(forKey: key)
            if let session = sessions.removeValue(forKey: key) {
                await runtime.closeSession(session)
            }
        }
    }

    func sessionKey(
        repositoryRoot: URL,
        theme: String?,
        workspace: HugoPreviewWorkspace
    ) -> String {
        let identity = [
            repositoryRoot.standardizedFileURL.path,
            theme ?? "default",
            workspace.rootURL.path,
            "hugo-0.134.3-standard"
        ].joined(separator: "|")
        return identity
    }

    nonisolated static func contentSignature(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
