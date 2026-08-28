import Foundation

#if HUGO_RUNTIME_AVAILABLE
import HugoRuntime

/// Swift adapter for the generated gomobile bindings. The generated API only
/// receives JSON strings, byte arrays, integer handles, and NSError failures.
final class HugoEmbeddedRuntime: HugoRuntimeProviding, @unchecked Sendable {
    private let bridge: HugoHugobridgeRuntime

    init() {
        bridge = HugoHugobridgeNewRuntime()!
    }

    func version() async throws -> HugoRuntimeVersion {
        let json = bridge.runtimeVersion()
        return try decode(json, as: HugoRuntimeVersion.self)
    }

    func openSession(_ request: HugoOpenSessionRequest) async throws -> HugoSessionID {
        let json = try encode(request)
        var handle: Int64 = 0
        try bridge.openSession(json, ret0_: &handle)
        return HugoSessionID(handle)
    }

    func build(_ request: HugoBuildRequest, in session: HugoSessionID) async throws -> HugoBuildResult {
        let json = try encode(request)
        var error: NSError?
        let response = bridge.build(Int64(session), requestJSON: json, error: &error)
        if let error { throw error }
        return try decode(response, as: HugoBuildResult.self)
    }

    func readOutput(path: String, in session: HugoSessionID) async throws -> Data {
        var error: NSError?
        guard let data = bridge.readOutput(Int64(session), path: path, error: &error) else {
            if let error { throw error }
            throw HugoRuntimeError.malformedResponse
        }
        return data
    }

    func listOutput(in session: HugoSessionID) async throws -> [String] {
        var error: NSError?
        let json = bridge.listOutput(Int64(session), error: &error)
        if let error { throw error }
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
