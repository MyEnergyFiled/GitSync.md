import Foundation
import CryptoKit

enum HugoPreviewPathError: LocalizedError, Equatable, Sendable {
    case invalidRelativePath
    case outsideWorkspace

    var errorDescription: String? {
        switch self {
        case .invalidRelativePath:
            return String(localized: "The preview path is invalid.")
        case .outsideWorkspace:
            return String(localized: "The preview path leaves the preview workspace.")
        }
    }
}

struct HugoPreviewWorkspace: Sendable {
    let rootURL: URL
    let outputURL: URL
    let resourceURL: URL
    let cacheURL: URL
    let overlayURL: URL

    init(repositoryID: UUID, themeID: String, baseURL: URL? = nil) throws {
        let cacheRoot = baseURL ?? FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("HugoPreview", isDirectory: true)
        let themeHash = Self.hash(themeID)
        let root = cacheRoot
            .appendingPathComponent(repositoryID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("0.134.3-standard", isDirectory: true)
            .appendingPathComponent(themeHash, isDirectory: true)
        self.rootURL = root
        self.outputURL = root.appendingPathComponent("public", isDirectory: true)
        self.resourceURL = root.appendingPathComponent("resources", isDirectory: true)
        self.cacheURL = root.appendingPathComponent("file-cache", isDirectory: true)
        self.overlayURL = root.appendingPathComponent("overlay", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: overlayURL, withIntermediateDirectories: true)
    }

    func openRequest(
        repositoryRoot: URL,
        selectedTheme: String?,
        overlayFiles: [HugoOverlayFile]
    ) throws -> HugoOpenSessionRequest {
        for file in overlayFiles {
            _ = try materializedOverlayURL(for: file.repositoryRelativePath)
        }
        return HugoOpenSessionRequest(
            repositoryRoot: repositoryRoot.standardizedFileURL.path,
            outputDirectory: outputURL.path,
            resourceDirectory: resourceURL.path,
            cacheDirectory: cacheURL.path,
            overlayDirectory: overlayURL.path,
            selectedTheme: selectedTheme,
            overlayFiles: overlayFiles
        )
    }

    func materializeOverlay(_ file: HugoOverlayFile) throws -> URL {
        let destination = try materializedOverlayURL(for: file.repositoryRelativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try file.contents.write(to: destination, options: .atomic)
        return destination
    }

    func materializedOverlayURL(for relativePath: String) throws -> URL {
        guard Self.isSafeRepositoryRelativePath(relativePath) else {
            throw HugoPreviewPathError.invalidRelativePath
        }
        let candidate = overlayURL.appendingPathComponent(relativePath).standardizedFileURL
        guard Self.contains(candidate, within: overlayURL.standardizedFileURL) else {
            throw HugoPreviewPathError.outsideWorkspace
        }
        return candidate
    }

    static func isSafeRepositoryRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.contains("\0"),
              !path.hasPrefix("/"),
              !path.contains("://") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return !components.isEmpty && !components.contains { $0 == ".." || $0 == "." }
    }

    private static func contains(_ candidate: URL, within root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
