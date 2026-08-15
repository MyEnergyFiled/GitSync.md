import Foundation
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
final class DebugLogger {
    static let shared = DebugLogger()

    private(set) var entries: [LogEntry] = []
    private let maxEntries = 500
    private let storageKey = "debug_log_entries"
    private let sessionID = String(UUID().uuidString.prefix(8)).lowercased()

    private init() {
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
        save()
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
        save()
    }

    /// Formats entries with a diagnostic environment header. Values are
    /// redacted again during export to protect legacy persisted entries.
    func exportText(filter: LogLevel? = nil) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
        let filtered = filter == nil ? entries : entries.filter { $0.level == filter }
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
        return diagnosticHeader() + (body.isEmpty ? "" : "\n\n" + body)
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

    // MARK: - Persistence

    private func diagnosticHeader() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let language = Locale.preferredLanguages.first ?? Locale.current.identifier
        return [
            "# GitSync.md Debug Log",
            "App: \(version) (\(build))",
            "System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "Device: \(UIDevice.current.model)",
            "Language: \(language)",
            "Session: \(sessionID)",
            "Entries: \(entries.count)"
        ].joined(separator: "\n")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([LogEntry].self, from: data) else { return }
        entries = decoded.map { entry in
            LogEntry(
                id: entry.id,
                date: entry.date,
                level: entry.level,
                category: entry.category,
                message: Self.redact(entry.message),
                detail: entry.detail.map(Self.redact),
                repoID: entry.repoID,
                repoName: entry.repoName,
                operationID: entry.operationID
            )
        }
        save()
    }
}
