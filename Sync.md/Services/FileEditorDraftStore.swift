import Foundation

struct FileEditorDraft: Codable, Equatable {
    let repoID: UUID
    let filePath: String
    var content: String
    var updatedAt: Date
}

/// Persists editor text independently from Git and the working tree so an
/// interrupted save, commit, or push cannot discard the user's latest text.
struct FileEditorDraftStore {
    private let fileURL: URL

    init(directoryURL: URL? = nil) {
        let root = directoryURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("SyncMD", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("editor-drafts.json")
    }

    func draft(repoID: UUID, fileURL: URL) -> FileEditorDraft? {
        load().first { $0.repoID == repoID && $0.filePath == fileURL.standardizedFileURL.path }
    }

    func save(content: String, repoID: UUID, fileURL: URL, now: Date = Date()) throws {
        var drafts = load()
        let path = fileURL.standardizedFileURL.path
        drafts.removeAll { $0.repoID == repoID && $0.filePath == path }
        drafts.append(FileEditorDraft(repoID: repoID, filePath: path, content: content, updatedAt: now))
        try persist(drafts)
    }

    func remove(repoID: UUID, fileURL: URL) throws {
        var drafts = load()
        let path = fileURL.standardizedFileURL.path
        drafts.removeAll { $0.repoID == repoID && $0.filePath == path }
        try persist(drafts)
    }

    private func load() -> [FileEditorDraft] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([FileEditorDraft].self, from: data)) ?? []
    }

    private func persist(_ drafts: [FileEditorDraft]) throws {
        let data = try JSONEncoder().encode(drafts)
        try data.write(to: fileURL, options: .atomic)
    }
}
