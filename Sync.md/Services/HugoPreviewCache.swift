import Foundation

actor HugoPreviewCache {
    static let shared = HugoPreviewCache()

    private let rootURL: URL
    private var lastAccess: [URL: Date] = [:]

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("HugoPreview", isDirectory: true)
    }

    func touch(_ workspace: HugoPreviewWorkspace) {
        lastAccess[workspace.rootURL] = Date()
        try? FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: workspace.rootURL.path
        )
    }

    func remove(repositoryID: UUID) {
        let repositoryURL = rootURL.appendingPathComponent(
            repositoryID.uuidString.lowercased(),
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: repositoryURL)
        lastAccess = lastAccess.filter { !$0.key.path.hasPrefix(repositoryURL.path + "/") }
    }

    func removeAllExcept(_ workspace: HugoPreviewWorkspace) {
        for entry in workspaceRoots() where entry.standardizedFileURL != workspace.rootURL.standardizedFileURL {
            try? FileManager.default.removeItem(at: entry)
            lastAccess.removeValue(forKey: entry.standardizedFileURL)
        }
    }

    func evict(maxBytes: Int64) {
        let entries = workspaceRoots()
        var candidates = entries.map { ($0, directorySize($0)) }
        var total = candidates.reduce(Int64(0)) { $0 + $1.1 }
        candidates.sort { lastAccess[$0.0, default: .distantPast] < lastAccess[$1.0, default: .distantPast] }
        while total > maxBytes, let candidate = candidates.first {
            candidates.removeFirst()
            try? FileManager.default.removeItem(at: candidate.0)
            total -= candidate.1
        }
    }

    private func workspaceRoots() -> [URL] {
        guard let repositories = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for repository in repositories {
            guard isDirectory(repository) else { continue }
            guard let namespaces = try? FileManager.default.contentsOfDirectory(
                at: repository,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for namespace in namespaces where isDirectory(namespace) {
                guard let themes = try? FileManager.default.contentsOfDirectory(
                    at: namespace,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                result.append(contentsOf: themes.filter(isDirectory))
            }
        }
        return result
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
            return false
        }
        return values.isDirectory == true
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.reduce(Int64(0)) { total, element in
            guard let fileURL = element as? URL,
                  let values = try? fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return total }
            return total + Int64(values.fileAllocatedSize ?? 0)
        }
    }
}
