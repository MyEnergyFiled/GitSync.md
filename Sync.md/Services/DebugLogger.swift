import Foundation
import Observation
import UIKit

/// Severity level for debug log entries.
enum LogLevel: String, Codable, Sendable, CaseIterable {
    case info
    case warning
    case error
}

/// A single timestamped log entry. Optional context fields keep decoding
/// compatible with logs written by older app versions.
struct LogEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let level: LogLevel
    let category: String
    let message: String
    let detail: String?
    let repoID: UUID?
    let repoName: String?
    let operationID: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        level: LogLevel,
        category: String,
        message: String,
        detail: String? = nil,
        repoID: UUID? = nil,
        repoName: String? = nil,
        operationID: String? = nil
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
        self.detail = detail
        self.repoID = repoID
        self.repoName = repoName
        self.operationID = operationID
    }
}

/// Singleton in-memory log buffer with persistence and export-time privacy
/// protection. Callers may attach repository and operation context without
/// placing credentials or user content in the message itself.
@MainActor
@Observable
final class DebugLogger {
    static let shared = DebugLogger()

    private(set) var entries: [LogEntry] = []
    private let maxEntries = 500
    private let legacyStorageKey = "debug_log_entries"
    private let maxLogFileBytes: UInt64 = 1_048_576
    private let rotatedFileCount = 2
    private let sessionID = String(UUID().uuidString.prefix(8)).lowercased()
    @ObservationIgnored private let persistenceQueue = DispatchQueue(label: "md.gitsync.debug-log.persistence", qos: .utility)
    @ObservationIgnored private let logDirectoryURL: URL
    @ObservationIgnored private let logFileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        logDirectoryURL = support.appendingPathComponent("SyncMD/Logs", isDirectory: true)
        logFileURL = logDirectoryURL.appendingPathComponent("debug-log.jsonl")
        load()
    }

    // MARK: - Public API

    func log(
        _ level: LogLevel,
        category: String,
        _ message: String,
        detail: String? = nil,
        repoID: UUID? = nil,
        repoName: String? = nil,
        operationID: String? = nil
    ) {
        let entry = LogEntry(
            level: level,
            category: category,
            message: Self.redact(message),
            detail: detail.map(Self.redact),
            repoID: repoID,
            repoName: repoName.map(Self.redact),
            operationID: operationID
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        persist(entry)
    }

    func info(_ category: String, _ message: String, detail: String? = nil, repoID: UUID? = nil, repoName: String? = nil, operationID: String? = nil) {
        log(.info, category: category, message, detail: detail, repoID: repoID, repoName: repoName, operationID: operationID)
    }

    func warning(_ category: String, _ message: String, detail: String? = nil, repoID: UUID? = nil, repoName: String? = nil, operationID: String? = nil) {
        log(.warning, category: category, message, detail: detail, repoID: repoID, repoName: repoName, operationID: operationID)
    }

    func error(_ category: String, _ message: String, detail: String? = nil, repoID: UUID? = nil, repoName: String? = nil, operationID: String? = nil) {
        log(.error, category: category, message, detail: detail, repoID: repoID, repoName: repoName, operationID: operationID)
    }

    func clear() {
        entries.removeAll()
        let directory = logDirectoryURL
        let current = logFileURL
        let rotatedCount = rotatedFileCount
        persistenceQueue.async {
            let fm = FileManager.default
            try? fm.removeItem(at: current)
            for index in 1...rotatedCount {
                try? fm.removeItem(at: directory.appendingPathComponent("debug-log.jsonl.\(index)"))
            }
        }
    }

    /// Formats entries with a diagnostic environment header. Values are
    /// redacted again during export to protect legacy persisted entries.
    func exportText(filter: LogLevel? = nil, selectedEntries: [LogEntry]? = nil) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
        let source = selectedEntries ?? entries
        let filtered = filter == nil ? source : source.filter { $0.level == filter }
        let body = filtered.map { entry in
            var context: [String] = []
            if let repoName = entry.repoName { context.append("repo=\(Self.redact(repoName))") }
            if let repoID = entry.repoID { context.append("repoID=\(repoID.uuidString.prefix(8))") }
            if let operationID = entry.operationID { context.append("op=\(operationID)") }
            let suffix = context.isEmpty ? "" : " [\(context.joined(separator: " "))]"
            var line = "[\(iso.string(from: entry.date))] [\(entry.level.rawValue.uppercased())] [\(entry.category)]\(suffix) \(Self.redact(entry.message))"
            if let detail = entry.detail {
                line += "\n  → \(Self.redact(detail))"
            }
            return line
        }.joined(separator: "\n")
        return diagnosticHeader(entryCount: filtered.count) + (body.isEmpty ? "" : "\n\n" + body)
    }

    nonisolated static func redact(_ value: String) -> String {
        var output = value
        let rules: [(String, String, NSRegularExpression.Options)] = [
            (#"(?i)(authorization:\s*(?:bearer|token|basic)\s+)[^\s]+"#, "$1<redacted>", []),
            (#"(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,})\b"#, "<redacted-token>", []),
            (#"(?i)([?&](?:access_token|token|client_secret|password)=)[^&\s]+"#, "$1<redacted>", []),
            (#"(?i)(https?://)[^/@\s]+@"#, "$1<redacted>@", []),
            (#"(?i)(\"(?:password|privateKey|passphrase|token)\"\s*:\s*\")[^\"]+"#, "$1<redacted>", []),
            (#"-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----"#, "<redacted-private-key>", [.dotMatchesLineSeparators])
        ]
        for (pattern, replacement, options) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            output = regex.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..., in: output),
                withTemplate: replacement
            )
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
        if let documents, !documents.isEmpty {
            output = output.replacingOccurrences(of: documents, with: "<APP_DOCUMENTS>")
        }
        return output
    }

    nonisolated static func logHTTP(
        category: String,
        method: String,
        endpoint: String,
        statusCode: Int?,
        duration: TimeInterval,
        responseBytes: Int = 0,
        requestID: String? = nil,
        error: Error? = nil
    ) async {
        let elapsed = String(format: "%.2fs", duration)
        var detail = "\(method) \(endpoint)"
        if let statusCode { detail += " · HTTP \(statusCode)" }
        detail += " · \(elapsed) · \(responseBytes) bytes"
        if let requestID, !requestID.isEmpty { detail += " · request \(requestID)" }
        if let error { detail += " · \(error.localizedDescription)" }
        await MainActor.run {
            if error != nil {
                shared.error(category, "Network request failed", detail: detail)
            } else if let statusCode, statusCode >= 400 {
                shared.warning(category, "HTTP request failed", detail: detail)
            } else {
                shared.info(category, "HTTP request complete", detail: detail)
            }
        }
    }

    // MARK: - Persistence

    private func diagnosticHeader(entryCount: Int) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let language = Locale.preferredLanguages.first ?? Locale.current.identifier
        return [
            "# HugoInk Debug Log",
            "App: \(version) (\(build))",
            "System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "Device: \(UIDevice.current.model)",
            "Language: \(language)",
            "Session: \(sessionID)",
            "Entries: \(entryCount)"
        ].joined(separator: "\n")
    }

    private func persist(_ entry: LogEntry) {
        guard var data = try? JSONEncoder().encode(entry) else { return }
        data.append(0x0A)
        let directory = logDirectoryURL
        let current = logFileURL
        let maxBytes = maxLogFileBytes
        let rotatedCount = rotatedFileCount
        persistenceQueue.async {
            Self.append(data, directory: directory, current: current, maxBytes: maxBytes, rotatedCount: rotatedCount)
        }
    }

    private func rewritePersistedEntries() {
        let snapshot = entries
        let directory = logDirectoryURL
        let current = logFileURL
        let rotatedCount = rotatedFileCount
        persistenceQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 1...rotatedCount {
                try? fm.removeItem(at: directory.appendingPathComponent("debug-log.jsonl.\(index)"))
            }
            let data = snapshot.compactMap { entry -> Data? in
                guard var encoded = try? JSONEncoder().encode(entry) else { return nil }
                encoded.append(0x0A)
                return encoded
            }.reduce(into: Data(), { $0.append($1) })
            try? data.write(to: current, options: .atomic)
        }
    }

    private func load() {
        let fileEntries = loadFileEntries()
        if !fileEntries.isEmpty {
            entries = Array(fileEntries.suffix(maxEntries)).map(Self.sanitizedEntry)
            rewritePersistedEntries()
            return
        }

        guard let data = UserDefaults.standard.data(forKey: legacyStorageKey),
              let decoded = try? JSONDecoder().decode([LogEntry].self, from: data) else { return }
        entries = Array(decoded.suffix(maxEntries)).map(Self.sanitizedEntry)
        rewritePersistedEntries()
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
    }

    private func loadFileEntries() -> [LogEntry] {
        let decoder = JSONDecoder()
        let urls = (stride(from: rotatedFileCount, through: 1, by: -1).map {
            logDirectoryURL.appendingPathComponent("debug-log.jsonl.\($0)")
        }) + [logFileURL]
        return urls.flatMap { url -> [LogEntry] in
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                try? decoder.decode(LogEntry.self, from: Data(line.utf8))
            }
        }
    }

    nonisolated private static func sanitizedEntry(_ entry: LogEntry) -> LogEntry {
        LogEntry(
            id: entry.id,
            date: entry.date,
            level: entry.level,
            category: entry.category,
            message: redact(entry.message),
            detail: entry.detail.map(redact),
            repoID: entry.repoID,
            repoName: entry.repoName.map(redact),
            operationID: entry.operationID
        )
    }

    nonisolated private static func append(
        _ data: Data,
        directory: URL,
        current: URL,
        maxBytes: UInt64,
        rotatedCount: Int
    ) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let currentBytes = ((try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init)) ?? 0
        if currentBytes + UInt64(data.count) > maxBytes {
            if rotatedCount > 0 {
                for index in stride(from: rotatedCount, through: 1, by: -1) {
                    let destination = directory.appendingPathComponent("debug-log.jsonl.\(index)")
                    try? fm.removeItem(at: destination)
                    let source = index == 1
                        ? current
                        : directory.appendingPathComponent("debug-log.jsonl.\(index - 1)")
                    if fm.fileExists(atPath: source.path) {
                        try? fm.moveItem(at: source, to: destination)
                    }
                }
            } else {
                try? fm.removeItem(at: current)
            }
        }
        if !fm.fileExists(atPath: current.path) {
            fm.createFile(atPath: current.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: current) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never crash or block the user operation it observes.
        }
    }

}
