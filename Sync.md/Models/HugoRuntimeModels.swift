import Foundation

typealias HugoSessionID = UInt64

struct HugoRuntimeVersion: Codable, Equatable, Sendable {
    let version: String
    let isExtended: Bool
    let goVersion: String
    let target: String

    static let required = HugoRuntimeVersion(
        version: "0.134.3",
        isExtended: false,
        goVersion: "",
        target: "ios"
    )
}

enum HugoBuildMode: String, Codable, Sendable {
    case editorPage
    case productionSite
}

struct HugoOverlayFile: Codable, Equatable, Sendable {
    let repositoryRelativePath: String
    let contents: Data
}

struct HugoOpenSessionRequest: Codable, Equatable, Sendable {
    let repositoryRoot: String
    let outputDirectory: String
    let resourceDirectory: String
    let cacheDirectory: String
    let overlayDirectory: String
    let selectedTheme: String?
    let overlayFiles: [HugoOverlayFile]
}

struct HugoBuildRequest: Codable, Equatable, Sendable {
    let mode: HugoBuildMode
    let repositoryRoot: String
    let articleRepositoryRelativePath: String?
    let selectedTheme: String?
    let baseURL: String
    let environment: String
    let buildDrafts: Bool
    let buildFuture: Bool
    let buildExpired: Bool
    let overlayFiles: [HugoOverlayFile]
    let generation: UInt64
}

struct HugoDiagnostic: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let severity: Severity
    let summary: String
    let repositoryRelativePath: String?
    let line: Int?

    enum Severity: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    init(
        severity: Severity,
        summary: String,
        repositoryRelativePath: String? = nil,
        line: Int? = nil
    ) {
        self.id = UUID()
        self.severity = severity
        self.summary = summary
        self.repositoryRelativePath = repositoryRelativePath
        self.line = line
    }
}

struct HugoBuildStatistics: Codable, Equatable, Sendable {
    let durationMilliseconds: Int
    let renderedPageCount: Int
    let outputByteCount: Int64
}

struct HugoBuildResult: Codable, Equatable, Sendable {
    let generation: UInt64
    let entryPath: String
    let renderedPaths: [String]
    let warnings: [HugoDiagnostic]
    let statistics: HugoBuildStatistics
    let cacheKey: String
    let outputDirectory: String
}

enum HugoPreviewFailureKind: String, Codable, Sendable {
    case runtimeUnavailable
    case versionMismatch
    case repositoryUnavailable
    case invalidConfiguration
    case themeNotFound
    case themeIncompatible
    case externalToolUnavailable
    case networkRequired
    case pageNotFound
    case templateError
    case resourcePipelineError
    case outputMissing
    case cancelled
    case internalRuntimeError
}

struct HugoPreviewFailure: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let kind: HugoPreviewFailureKind
    let summary: String
    let diagnostic: String?
    let repositoryRelativePath: String?
    let isRetryable: Bool

    init(
        kind: HugoPreviewFailureKind,
        summary: String,
        diagnostic: String? = nil,
        repositoryRelativePath: String? = nil,
        isRetryable: Bool = true
    ) {
        self.id = UUID()
        self.kind = kind
        self.summary = summary
        self.diagnostic = diagnostic
        self.repositoryRelativePath = repositoryRelativePath
        self.isRetryable = isRetryable
    }
}

enum HugoPreviewPhase: Equatable, Sendable {
    case idle
    case openingRuntime
    case indexingSite
    case building
    case ready(URL)
    case failed(HugoPreviewFailure)
}

enum HugoCapabilityStatus: String, Codable, Sendable {
    case supported
    case requiresNetwork
    case requiresExtendedHugo
    case requiresExternalExecutable
    case requiresNewerHugo
    case unknown
}

enum HugoCapabilityWarning: String, Codable, Equatable, Hashable, Sendable {
    case remoteResource
    case externalConverter
    case externalExecutable
    case hugoModule
    case unknownConstruct
}

struct HugoCapabilityReport: Codable, Equatable, Sendable {
    let status: HugoCapabilityStatus
    let warnings: [HugoCapabilityWarning]
    let details: [String]
}

struct HugoThemeDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let directoryName: String
    let displayName: String
    let minimumHugoVersion: String?
    let author: String?
    let license: String?
    let isCompatible: Bool
    let capabilityWarnings: [HugoCapabilityWarning]

    var isSupported: Bool {
        isCompatible && capabilityWarnings.isEmpty
    }
}

struct HugoPreviewStateSnapshot: Equatable, Sendable {
    let phase: HugoPreviewPhase
    let runtimeVersion: HugoRuntimeVersion?
    let generation: UInt64
}
