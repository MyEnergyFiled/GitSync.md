import Foundation

#if HUGO_RUNTIME_AVAILABLE
import Hugobridge

/// Swift adapter for the generated gomobile bindings. The generated API only
/// receives JSON strings, byte arrays, integer handles, and NSError failures.
final class HugoEmbeddedRuntime: HugoRuntimeProviding, @unchecked Sendable {
    private let bridge: HugoRuntime

    init() {
        bridge = HugoNewRuntime()
    }

    func version() async throws -> HugoRuntimeVersion {
        let json = bridge.runtimeVersion()
        return try decode(json, as: HugoRuntimeVersion.self)
    }

    func openSession(_ request: HugoOpenSessionRequest) async throws -> HugoSessionID {
        let json = try encode(request)
        return HugoSessionID(try bridge.openSession(json))
    }

    func build(_ request: HugoBuildRequest, in session: HugoSessionID) async throws -> HugoBuildResult {
        let json = try encode(request)
        let response = try bridge.build(Int64(session), requestJSON: json)
        return try decode(response, as: HugoBuildResult.self)
    }

    func readOutput(path: String, in session: HugoSessionID) async throws -> Data {
        try bridge.readOutput(Int64(session), path: path)
    }

    func listOutput(in session: HugoSessionID) async throws -> [String] {
        let json = try bridge.listOutput(Int64(session))
        return try decode(json, as: [String].self)
    }

    func invalidate(_ request: HugoBuildRequest, in session: HugoSessionID) async throws {
        _ = try bridge.invalidate(Int64(session), requestJSON: encode(request))
    }

    func closeSession(_ session: HugoSessionID) async {
        _ = try? bridge.closeSession(Int64(session))
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw HugoRuntimeError.malformedResponse
        }
        return string
    }

    private func decode<T: Decodable>(_ value: String, as type: T.Type) throws -> T {
        guard let data = value.data(using: .utf8) else {
            throw HugoRuntimeError.malformedResponse
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
#endif
