import Foundation
import CryptoKit

enum EditorDraftAutosaveSettings {
    static let delaySecondsKey = "editorDraftAutosaveDelaySeconds"
    static let defaultDelaySeconds = 2
    static let supportedDelaySeconds = [1, 2, 3, 5]

    static func normalizedDelaySeconds(_ value: Int) -> Int {
        supportedDelaySeconds.contains(value) ? value : defaultDelaySeconds
    }
}

struct FileEditorDraft: Codable, Equatable {
    let repoID: UUID
    let filePath: String
    var content: String
    var updatedAt: Date
}

/// Persists editor text independently from Git and the working tree so an
/// interrupted save, commit, or push cannot discard the user's latest text.
actor FileEditorDraftStore {
    static let shared = FileEditorDraftStore()

    private let directoryURL: URL
    private let legacyFileURL: URL
    private var didPrepareStorage = false

    init(directoryURL: URL? = nil) {
        let root = directoryURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("SyncMD", isDirectory: true)
        self.directoryURL = root.appendingPathComponent("editor-drafts", isDirectory: true)
        self.legacyFileURL = root.appendingPathComponent("editor-drafts.json")
    }

    func draft(repoID: UUID, fileURL: URL) throws -> FileEditorDraft? {
        try prepareStorage()
        let url = draftFileURL(repoID: repoID, fileURL: fileURL)
        do {
            return try JSONDecoder().decode(FileEditorDraft.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func save(content: String, repoID: UUID, fileURL: URL, now: Date = Date()) throws {
        try prepareStorage()
        let draft = FileEditorDraft(
            repoID: repoID,
            filePath: fileURL.standardizedFileURL.path,
            content: content,
            updatedAt: now
        )
        try persist(draft)
    }

    func remove(repoID: UUID, fileURL: URL) throws {
        try prepareStorage()
        do {
            try FileManager.default.removeItem(at: draftFileURL(repoID: repoID, fileURL: fileURL))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    private func prepareStorage() throws {
        guard !didPrepareStorage else { return }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: legacyFileURL.path) {
            let data = try Data(contentsOf: legacyFileURL)
            let drafts = try JSONDecoder().decode([FileEditorDraft].self, from: data)
            for draft in drafts {
                try persist(draft)
            }
            try FileManager.default.removeItem(at: legacyFileURL)
        }
        didPrepareStorage = true
    }

    private func persist(_ draft: FileEditorDraft) throws {
        let data = try JSONEncoder().encode(draft)
        let sourceURL = URL(fileURLWithPath: draft.filePath)
        try data.write(
            to: draftFileURL(repoID: draft.repoID, fileURL: sourceURL),
            options: .atomic
        )
    }

    private func draftFileURL(repoID: UUID, fileURL: URL) -> URL {
        let identity = "\(repoID.uuidString.lowercased())\u{0}\(fileURL.standardizedFileURL.path)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined() + ".json"
        return directoryURL.appendingPathComponent(filename)
    }
}
