import Foundation

enum HugoRuntimeError: LocalizedError, Equatable, Sendable {
    case unavailable
    case malformedResponse
    case failure(HugoPreviewFailure)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "The embedded Hugo runtime is not installed.")
        case .malformedResponse:
            return String(localized: "The embedded Hugo runtime returned an invalid response.")
        case .failure(let failure):
            return failure.summary
        }
    }
}

/// The only boundary between Swift and the embedded Hugo engine.
///
/// The production implementation is supplied by the HugoRuntime XCFramework.
/// Keeping this protocol JSON-shaped prevents Hugo's internal Go objects from
/// leaking into the app and makes the coordinator testable without a runtime.
protocol HugoRuntimeProviding: Sendable {
    func version() async throws -> HugoRuntimeVersion
    func openSession(_ request: HugoOpenSessionRequest) async throws -> HugoSessionID
    func build(_ request: HugoBuildRequest, in session: HugoSessionID) async throws -> HugoBuildResult
    func readOutput(path: String, in session: HugoSessionID) async throws -> Data
    func listOutput(in session: HugoSessionID) async throws -> [String]
    func invalidate(_ request: HugoBuildRequest, in session: HugoSessionID) async throws
    func closeSession(_ session: HugoSessionID) async
}

/// Fail-closed adapter used until a verified HugoRuntime.xcframework is
/// linked into the application. It deliberately does not render a fallback.
struct UnavailableHugoRuntime: HugoRuntimeProviding {
    func version() async throws -> HugoRuntimeVersion { throw HugoRuntimeError.unavailable }

    func openSession(_ request: HugoOpenSessionRequest) async throws -> HugoSessionID {
        throw HugoRuntimeError.unavailable
    }

    func build(_ request: HugoBuildRequest, in session: HugoSessionID) async throws -> HugoBuildResult {
        throw HugoRuntimeError.unavailable
    }

    func readOutput(path: String, in session: HugoSessionID) async throws -> Data {
        throw HugoRuntimeError.unavailable
    }

    func listOutput(in session: HugoSessionID) async throws -> [String] {
        throw HugoRuntimeError.unavailable
    }

    func invalidate(_ request: HugoBuildRequest, in session: HugoSessionID) async throws {
        throw HugoRuntimeError.unavailable
    }

    func closeSession(_ session: HugoSessionID) async {}
}

/// Application-facing runtime service. A generated/native implementation can
/// be injected by the app target without changing preview UI or coordination.
actor HugoRuntimeService {
    static let shared = HugoRuntimeService()

    private let runtime: any HugoRuntimeProviding

    init(runtime: any HugoRuntimeProviding = UnavailableHugoRuntime()) {
        self.runtime = runtime
    }

    func version() async throws -> HugoRuntimeVersion {
        try await runtime.version()
    }

    func openSession(_ request: HugoOpenSessionRequest) async throws -> HugoSessionID {
        try await runtime.openSession(request)
    }

    func build(_ request: HugoBuildRequest, in session: HugoSessionID) async throws -> HugoBuildResult {
        try await runtime.build(request, in: session)
    }

    func readOutput(path: String, in session: HugoSessionID) async throws -> Data {
        try await runtime.readOutput(path: path, in: session)
    }

    func listOutput(in session: HugoSessionID) async throws -> [String] {
        try await runtime.listOutput(in: session)
    }

    func invalidate(_ request: HugoBuildRequest, in session: HugoSessionID) async throws {
        try await runtime.invalidate(request, in: session)
    }

    func closeSession(_ session: HugoSessionID) async {
        await runtime.closeSession(session)
    }
}
