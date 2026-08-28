import Foundation
@preconcurrency import Network
import UniformTypeIdentifiers

actor HugoPreviewHTTPServer {
    private let queue = DispatchQueue(label: "com.myenergyfiled.gitsync.hugo-preview-http")
    private var listener: NWListener?
    private var outputDirectory: URL?
    private var token = ""

    func start(outputDirectory: URL) async throws -> URL {
        if let listener, let port = listener.port?.rawValue, self.outputDirectory == outputDirectory {
            return try origin(port: port)
        }
        stop()
        let port = NWEndpoint.Port(rawValue: 0)!
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port
        )
        let listener = try NWListener(using: parameters)
        self.listener = listener
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.token = UUID().uuidString.lowercased()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.run { continuation.resume() }
                case .failed(let error):
                    gate.run { continuation.resume(throwing: error) }
                case .cancelled:
                    gate.run { continuation.resume(throwing: URLError(.cancelled)) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            listener.start(queue: self.queue)
        }
        guard let port = listener.port?.rawValue else { throw URLError(.cannotGetHostFromURL) }
        return try origin(port: port)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        outputDirectory = nil
        token = ""
    }

    nonisolated static func relativeOutputPath(for path: String, token: String) -> String? {
        guard let decodedPath = path.removingPercentEncoding,
              !token.isEmpty,
              decodedPath == "/\(token)" || decodedPath.hasPrefix("/\(token)/"),
              !decodedPath.contains("\0") else { return nil }
        let relative = String(decodedPath.dropFirst(token.count + 1))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard HugoPreviewWorkspace.isSafeRepositoryRelativePath(relative.isEmpty ? "index.html" : relative) else {
            return nil
        }
        return relative.isEmpty ? "index.html" : relative
    }

    private func origin(port: UInt16) throws -> URL {
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)/") else {
            throw URLError(.badURL)
        }
        return url
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(from: connection, buffer: Data())
    }

    private func receive(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task {
                guard let self else { return }
                if let error {
                    connection.cancel()
                    _ = error
                    return
                }
                let next = buffer + (data ?? Data())
                if next.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                    await self.respond(to: connection, request: next)
                } else if next.count < 65_536 {
                    await self.receive(from: connection, buffer: next)
                } else {
                    await self.send(connection: connection, status: 400, body: Data("Bad Request".utf8))
                }
            }
        }
    }

    private func respond(to connection: NWConnection, request: Data) {
        guard let text = String(data: request, encoding: .utf8),
              let requestLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            send(connection: connection, status: 400, body: Data("Bad Request".utf8))
            return
        }
        let fields = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD" else {
            send(connection: connection, status: 405, body: Data("Method Not Allowed".utf8), headOnly: fields.first == "HEAD")
            return
        }
        let headOnly = fields[0] == "HEAD"
        guard let url = URL(string: "http://127.0.0.1\(fields[1])"),
              let decodedPath = url.path.removingPercentEncoding,
              let fileURL = fileURL(for: decodedPath) else {
            send(connection: connection, status: 404, body: Data("Not Found".utf8), headOnly: headOnly)
            return
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            send(
                connection: connection,
                status: 200,
                body: data,
                mimeType: UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType,
                headOnly: headOnly
            )
        } catch {
            send(connection: connection, status: 404, body: Data("Not Found".utf8), headOnly: headOnly)
        }
    }

    private func fileURL(for path: String) -> URL? {
        guard let outputDirectory,
              let relative = Self.relativeOutputPath(for: path, token: token) else { return nil }
        let candidates: [URL]
        if relative == "index.html" {
            candidates = [outputDirectory.appendingPathComponent("index.html")]
        } else {
            candidates = [
                outputDirectory.appendingPathComponent(relative),
                outputDirectory.appendingPathComponent(relative).appendingPathComponent("index.html"),
                outputDirectory.appendingPathComponent(relative + ".html")
            ]
        }
        let root = outputDirectory.resolvingSymlinksInPath().standardizedFileURL
        return candidates.first { candidate in
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/"),
                  let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= 52_428_800 else { return false }
            return true
        }
    }

    private func send(
        connection: NWConnection,
        status: Int,
        body: Data,
        mimeType: String? = "text/plain; charset=utf-8",
        headOnly: Bool = false
    ) {
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : (status == 405 ? "Method Not Allowed" : "Bad Request"))
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\nContent-Type: \(mimeType ?? "application/octet-stream")\r\n\r\n".utf8)
        if !headOnly { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didRun = false

    func run(_ body: () -> Void) {
        lock.lock()
        guard !didRun else {
            lock.unlock()
            return
        }
        didRun = true
        lock.unlock()
        body()
    }
}
