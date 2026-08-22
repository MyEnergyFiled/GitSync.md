import Foundation

struct HugoContentMapping: Codable, Identifiable, Hashable {
    var directory: String
    var archetype: String
    var id: String { directory }
}

enum HugoFrontMatterFieldType: String, Codable, CaseIterable, Identifiable {
    case text
    case boolean
    case number

    var id: String { rawValue }
}

struct HugoFrontMatterFieldConfiguration: Codable, Identifiable, Hashable {
    let id: UUID
    var key: String
    var label: String
    var type: HugoFrontMatterFieldType

    init(key: String, label: String, type: HugoFrontMatterFieldType) {
        id = UUID()
        self.key = key
        self.label = label
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case label
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        key = try container.decode(String.self, forKey: .key)
        label = try container.decode(String.self, forKey: .label)
        type = try container.decode(HugoFrontMatterFieldType.self, forKey: .type)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(label, forKey: .label)
        try container.encode(type, forKey: .type)
    }
}

struct HugoRepositoryConfiguration: Codable {
    var contentMappings: [HugoContentMapping] = []
    var frontMatterFields: [HugoFrontMatterFieldConfiguration] = []

    init(
        contentMappings: [HugoContentMapping] = [],
        frontMatterFields: [HugoFrontMatterFieldConfiguration] = []
    ) {
        self.contentMappings = contentMappings
        self.frontMatterFields = frontMatterFields
    }

    private enum CodingKeys: String, CodingKey {
        case contentMappings
        case frontMatterFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentMappings = try container.decodeIfPresent([HugoContentMapping].self, forKey: .contentMappings) ?? []
        frontMatterFields = try container.decodeIfPresent(
            [HugoFrontMatterFieldConfiguration].self,
            forKey: .frontMatterFields
        ) ?? []
    }
}

enum HugoFrontMatterIssue: Hashable {
    case missingOrIncomplete
    case missingTitle
    case invalidDate
}

struct HugoArticleValidation: Equatable {
    var frontMatterIssues: [HugoFrontMatterIssue] = []
    var missingImagePaths: [String] = []
    var oversizedImageNames: [String] = []

    var isValid: Bool { frontMatterIssues.isEmpty && missingImagePaths.isEmpty }
}

struct HugoArticleMoveResult: Equatable {
    let destinationFileURL: URL
    let updatedImageReferenceCount: Int
}

enum HugoArticleCreationError: LocalizedError, Equatable {
    case invalidDestination
    case destinationExists
    case invalidArchetype

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            return String(localized: "Choose a directory below content/.")
        case .destinationExists:
            return String(localized: "A content bundle with this folder name already exists.")
        case .invalidArchetype:
            return String(localized: "Choose an existing archetype template.")
        }
    }
}

enum HugoArticleAccessError: LocalizedError, Equatable {
    case invalidArticle

    var errorDescription: String? {
        String(localized: "The selected article is not a valid Hugo leaf bundle.")
    }
}

enum HugoArticleMoveError: LocalizedError {
    case invalidSource
    case invalidDestination
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return String(localized: "The selected article is not a valid Hugo leaf bundle.")
        case .invalidDestination:
            return String(localized: "Choose a valid content directory and article directory name.")
        case .destinationExists:
            return String(localized: "An article directory with this name already exists.")
        }
    }
}

enum HugoContentService {
    static let configurationFile = ".gitsync-hugo.json"
    static let supportedArticleImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff"
    ]
    static let builtInFrontMatterKeys: Set<String> = ["title", "date", "draft", "tags", "cover"]

    static func isSupportedArticleImage(_ url: URL) -> Bool {
        supportedArticleImageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isValidFrontMatterFieldKey(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
            && !builtInFrontMatterKeys.contains(value.lowercased())
    }

    static func isValidFrontMatterNumber(_ value: String) -> Bool {
        value.range(of: #"^-?(?:\d+(?:\.\d+)?|\.\d+)$"#, options: .regularExpression) != nil
    }

    static func newArticleBundleDirectory(
        contentDirectory: String,
        bundleName: String,
        repositoryRoot: URL
    ) throws -> URL {
        let relativeDirectory = contentDirectory.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        guard isValidBundleName(bundleName),
              relativeDirectory == "content" || relativeDirectory.hasPrefix("content/"),
              !relativeDirectory.contains(".."),
              !relativeDirectory.contains("\\"),
              relativeDirectory.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw HugoArticleCreationError.invalidDestination
        }

        let fileManager = FileManager.default
        let root = repositoryRoot.standardizedFileURL
        let contentRoot = root.appendingPathComponent("content", isDirectory: true).standardizedFileURL
        let directory = root.appendingPathComponent(relativeDirectory, isDirectory: true).standardizedFileURL
        let bundleDirectory = directory
            .appendingPathComponent(bundleName, isDirectory: true)
            .standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedContentRoot = contentRoot.resolvingSymlinksInPath()
        let resolvedDirectory = directory.resolvingSymlinksInPath()
        let resolvedBundleDirectory = resolvedDirectory
            .appendingPathComponent(bundleName, isDirectory: true)
            .standardizedFileURL

        guard isURL(resolvedContentRoot, containedIn: resolvedRoot),
              isURL(resolvedDirectory, containedIn: resolvedContentRoot),
              isURL(resolvedBundleDirectory, containedIn: resolvedContentRoot) else {
            throw HugoArticleCreationError.invalidDestination
        }
        guard !fileManager.fileExists(atPath: bundleDirectory.path) else {
            throw HugoArticleCreationError.destinationExists
        }
        return bundleDirectory
    }

    static func archetypeURL(for relativePath: String, in repositoryRoot: URL) throws -> URL {
        let prefix = "archetypes/"
        guard relativePath.hasPrefix(prefix) else {
            throw HugoArticleCreationError.invalidArchetype
        }
        let name = String(relativePath.dropFirst(prefix.count))
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains("\\"),
              name != ".",
              name != "..",
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              ["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) else {
            throw HugoArticleCreationError.invalidArchetype
        }

        let root = repositoryRoot.standardizedFileURL
        let archetypesRoot = root.appendingPathComponent("archetypes", isDirectory: true).standardizedFileURL
        let candidate = archetypesRoot.appendingPathComponent(name).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedArchetypesRoot = archetypesRoot.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard isURL(resolvedArchetypesRoot, containedIn: resolvedRoot),
              isURL(resolvedCandidate, containedIn: resolvedArchetypesRoot),
              let values = try? resolvedCandidate.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            throw HugoArticleCreationError.invalidArchetype
        }
        return candidate
    }

    static func articleIndexURL(_ fileURL: URL, in repositoryRoot: URL) throws -> URL {
        let root = repositoryRoot.standardizedFileURL
        let contentRoot = root.appendingPathComponent("content", isDirectory: true).standardizedFileURL
        let candidate = fileURL.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedContentRoot = contentRoot.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()

        guard candidate.lastPathComponent == "index.md",
              isURL(resolvedContentRoot, containedIn: resolvedRoot),
              isURL(resolvedCandidate, containedIn: resolvedContentRoot),
              let values = try? resolvedCandidate.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            throw HugoArticleAccessError.invalidArticle
        }
        return candidate
    }

    static func articleIndexFiles(in repositoryRoot: URL) -> [URL] {
        let root = repositoryRoot.standardizedFileURL
        let contentRoot = root.appendingPathComponent("content", isDirectory: true).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedContentRoot = contentRoot.resolvingSymlinksInPath()
        var contentIsDirectory: ObjCBool = false
        guard isURL(resolvedContentRoot, containedIn: resolvedRoot),
              FileManager.default.fileExists(
                  atPath: contentRoot.path,
                  isDirectory: &contentIsDirectory
              ), contentIsDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: contentRoot,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else { return [] }

        return enumerator.compactMap { value in
            guard let url = value as? URL,
                  url.lastPathComponent == "index.md" else { return nil }
            return try? articleIndexURL(url, in: root)
        }
    }

    static func localPreviewAssetURL(
        for reference: String,
        bundleURL: URL,
        repositoryRoot: URL
    ) -> URL? {
        guard !reference.hasPrefix("/"), !reference.hasPrefix("//"),
              reference.range(
                  of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
                  options: .regularExpression
              ) == nil else { return nil }
        let path = reference.split(separator: "#", maxSplits: 1).first.map(String.init) ?? reference
        let pathWithoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        guard !pathWithoutQuery.isEmpty else { return nil }
        let decodedPath = pathWithoutQuery.removingPercentEncoding ?? pathWithoutQuery
        let target = bundleURL.appendingPathComponent(decodedPath).standardizedFileURL
        let resolvedRoot = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedTarget = target.resolvingSymlinksInPath()
        guard isURL(resolvedTarget, containedIn: resolvedRoot) else { return nil }
        return target
    }

    static func moveArticleBundle(
        indexFileURL: URL,
        toContentDirectory destinationParentURL: URL,
        bundleName: String,
        repositoryRoot: URL
    ) throws -> HugoArticleMoveResult {
        let fileManager = FileManager.default
        let root = repositoryRoot.standardizedFileURL
        let contentRoot = root.appendingPathComponent("content", isDirectory: true).standardizedFileURL
        let sourceFileURL = indexFileURL.standardizedFileURL
        let sourceBundleURL = sourceFileURL.deletingLastPathComponent().standardizedFileURL
        let destinationParentURL = destinationParentURL.standardizedFileURL
        let destinationBundleURL = destinationParentURL
            .appendingPathComponent(bundleName, isDirectory: true)
            .standardizedFileURL
        let destinationFileURL = destinationBundleURL.appendingPathComponent("index.md")

        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedContentRoot = contentRoot.resolvingSymlinksInPath()
        let resolvedSourceFileURL = sourceFileURL.resolvingSymlinksInPath()
        let resolvedSourceBundleURL = sourceBundleURL.resolvingSymlinksInPath()
        let resolvedDestinationParentURL = destinationParentURL.resolvingSymlinksInPath()
        let resolvedDestinationBundleURL = resolvedDestinationParentURL
            .appendingPathComponent(bundleName, isDirectory: true)
            .standardizedFileURL

        guard sourceFileURL.lastPathComponent == "index.md",
              isURL(resolvedContentRoot, containedIn: resolvedRoot),
              isURL(resolvedSourceBundleURL, containedIn: resolvedContentRoot),
              isURL(resolvedSourceFileURL, containedIn: resolvedSourceBundleURL),
              fileManager.fileExists(atPath: sourceFileURL.path) else {
            throw HugoArticleMoveError.invalidSource
        }
        var destinationParentIsDirectory: ObjCBool = false
        guard isValidBundleName(bundleName),
              isURL(resolvedDestinationParentURL, containedIn: resolvedContentRoot),
              isURL(resolvedDestinationBundleURL, containedIn: resolvedContentRoot),
              !isURL(resolvedDestinationParentURL, containedIn: resolvedSourceBundleURL),
              resolvedDestinationBundleURL != resolvedSourceBundleURL,
              fileManager.fileExists(
                  atPath: destinationParentURL.path,
                  isDirectory: &destinationParentIsDirectory
              ), destinationParentIsDirectory.boolValue else {
            throw HugoArticleMoveError.invalidDestination
        }
        guard !fileManager.fileExists(atPath: destinationBundleURL.path) else {
            throw HugoArticleMoveError.destinationExists
        }

        let markdown = try String(contentsOf: sourceFileURL, encoding: .utf8)
        let rewritten = updatingRelativeImageReferences(
            in: markdown,
            sourceBundleURL: sourceBundleURL,
            destinationBundleURL: destinationBundleURL,
            repositoryRoot: root
        )

        try fileManager.moveItem(at: sourceBundleURL, to: destinationBundleURL)
        do {
            if rewritten.markdown != markdown {
                try rewritten.markdown.write(to: destinationFileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            try? fileManager.moveItem(at: destinationBundleURL, to: sourceBundleURL)
            throw error
        }

        return HugoArticleMoveResult(
            destinationFileURL: destinationFileURL,
            updatedImageReferenceCount: rewritten.updatedCount
        )
    }

    static func updatingRelativeImageReferences(
        in markdown: String,
        sourceBundleURL: URL,
        destinationBundleURL: URL,
        repositoryRoot: URL
    ) -> (markdown: String, updatedCount: Int) {
        let patterns = [
            #"(?i)(!\[[^\]]*\]\(\s*<?)([^\s)>]+)(>?\s*(?:[\"'][^)]*[\"'])?\))"#,
            #"(?i)(<img\b[^>]*\bsrc\s*=\s*[\"'])([^\"']+)([\"'])"#,
            #"(?im)^(\s*cover\s*[:=]\s*[\"']?)([^\"'\s]+)([\"']?\s*)$"#
        ]
        var output = markdown
        var updatedCount = 0

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(
                in: output,
                range: NSRange(output.startIndex..., in: output)
            )
            for match in matches.reversed() {
                guard match.numberOfRanges > 2,
                      let valueRange = Range(match.range(at: 2), in: output) else { continue }
                let value = String(output[valueRange])
                guard let replacement = movedRelativeImageReference(
                    value,
                    sourceBundleURL: sourceBundleURL,
                    destinationBundleURL: destinationBundleURL,
                    repositoryRoot: repositoryRoot
                ), replacement != value else { continue }
                output.replaceSubrange(valueRange, with: replacement)
                updatedCount += 1
            }
        }
        return (output, updatedCount)
    }

    private static func movedRelativeImageReference(
        _ value: String,
        sourceBundleURL: URL,
        destinationBundleURL: URL,
        repositoryRoot: URL
    ) -> String? {
        guard !value.hasPrefix("/"), !value.hasPrefix("#"), !value.hasPrefix("//"),
              value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil else {
            return nil
        }
        let suffixIndex = value.firstIndex(where: { $0 == "?" || $0 == "#" })
        let encodedPath = suffixIndex.map { String(value[..<$0]) } ?? value
        let suffix = suffixIndex.map { String(value[$0...]) } ?? ""
        guard !encodedPath.isEmpty else { return nil }

        let decodedPath = encodedPath.removingPercentEncoding ?? encodedPath
        let targetURL = sourceBundleURL.appendingPathComponent(decodedPath).standardizedFileURL
        let root = repositoryRoot.standardizedFileURL
        guard isURL(targetURL, containedIn: root) else { return nil }

        // Assets inside the article bundle move together, so their relative paths stay valid.
        if isURL(targetURL, containedIn: sourceBundleURL) { return nil }

        let relativePath = relativePath(from: destinationBundleURL, to: targetURL)
        let encodedRelativePath = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? relativePath
        return encodedRelativePath + suffix
    }

    private static func isURL(_ url: URL, containedIn directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return path == directoryPath || path.hasPrefix(directoryPath + "/")
    }

    private static func relativePath(from directory: URL, to target: URL) -> String {
        let sourceComponents = directory.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var commonCount = 0
        while commonCount < sourceComponents.count,
              commonCount < targetComponents.count,
              sourceComponents[commonCount] == targetComponents[commonCount] {
            commonCount += 1
        }
        let parents = Array(repeating: "..", count: sourceComponents.count - commonCount)
        return (parents + targetComponents.dropFirst(commonCount)).joined(separator: "/")
    }

    static func loadConfiguration(from root: URL) -> HugoRepositoryConfiguration {
        let repositoryRoot = root.standardizedFileURL
        guard let directory = try? RepositoryFileDestinationValidator.validatedDirectoryURL(
            repositoryRoot,
            repositoryRootURL: repositoryRoot
        ),
              let url = try? RepositoryFileDestinationValidator.existingFileURL(
                  directory.appendingPathComponent(configurationFile),
                  in: directory,
                  repositoryRootURL: repositoryRoot
              ),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(HugoRepositoryConfiguration.self, from: data) else {
            return HugoRepositoryConfiguration()
        }
        return value
    }

    static func saveConfiguration(_ configuration: HugoRepositoryConfiguration, to root: URL) throws {
        let repositoryRoot = root.standardizedFileURL
        let directory = try RepositoryFileDestinationValidator.validatedDirectoryURL(
            repositoryRoot,
            repositoryRootURL: repositoryRoot
        )
        let url = try RepositoryFileDestinationValidator.destinationURL(
            for: configurationFile,
            in: directory,
            repositoryRootURL: repositoryRoot
        )
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try RepositoryFileDestinationValidator.existingFileURL(
                url,
                in: directory,
                repositoryRootURL: repositoryRoot
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }

    static func contentDirectories(in root: URL) -> [String] {
        let content = root.appendingPathComponent("content", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: content, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )) ?? []
        var result = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map { "content/\($0.lastPathComponent)" }
        if FileManager.default.fileExists(atPath: content.path) { result.insert("content", at: 0) }
        return Array(Set(result)).sorted()
    }

    static func archetypes(in root: URL) -> [String] {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("archetypes", isDirectory: true).standardizedFileURL
        guard isURL(directory.resolvingSymlinksInPath(), containedIn: resolvedRoot) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        )) ?? []).compactMap { url in
            let relativePath = "archetypes/\(url.lastPathComponent)"
            guard (try? archetypeURL(for: relativePath, in: root)) != nil else { return nil }
            return relativePath
        }.sorted()
    }

    static func suggestedArchetype(for directory: String, available: [String]) -> String? {
        let section = URL(fileURLWithPath: directory).lastPathComponent
        return available.first { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent == section }
            ?? available.first { $0 == "archetypes/default.md" }
            ?? available.first
    }

    static func render(template: String, title: String, filename: String, section: String, bundleName: String? = nil, date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        let datetime = formatter.string(from: date)
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let slug = slugify(bundleName ?? (base.isEmpty ? title : base))
        var output = template
        let replacements = [
            "{{ title }}": title, "{{title}}": title,
            "{{ date }}": datetime, "{{date}}": datetime,
            "{{ datetime }}": datetime, "{{datetime}}": datetime,
            "{{ slug }}": slug, "{{slug}}": slug,
            "{{ filename }}": filename, "{{filename}}": filename,
            "{{ section }}": section, "{{section}}": section,
            "{{ year }}": String(format: "%04d", day.year ?? 0),
            "{{ month }}": String(format: "%02d", day.month ?? 0),
            "{{ day }}": String(format: "%02d", day.day ?? 0),
            "{{ .Date }}": datetime,
            "{{.Date}}": datetime,
            "{{ .File.ContentBaseName }}": base,
            "{{.File.ContentBaseName}}": base,
        ]
        for (key, value) in replacements { output = output.replacingOccurrences(of: key, with: value) }
        // Common Hugo default archetype expression.
        let pattern = #"\{\{\s*replace\s+\.File\.ContentBaseName\s+[`\"]-[`\"]\s+[`\"]\s*[`\"]\s*\|\s*title\s*\}\}"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(output.startIndex..., in: output)
            let display = title.isEmpty ? base.replacingOccurrences(of: "-", with: " ").capitalized : title
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: display)
        }
        return output
    }

    static func validateArticleBundle(
        markdown: String,
        fileURL: URL,
        oversizedThreshold: Int64 = 10 * 1024 * 1024
    ) -> HugoArticleValidation {
        let matter = MarkdownFrontMatter(markdown: markdown)
        var frontMatterIssues: [HugoFrontMatterIssue] = []
        if !matter.hasFrontMatter {
            frontMatterIssues.append(.missingOrIncomplete)
        } else {
            if matter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                frontMatterIssues.append(.missingTitle)
            }
            if !matter.date.isEmpty, publicationDate(from: matter.date) == nil {
                frontMatterIssues.append(.invalidDate)
            }
        }

        let bundleURL = fileURL.deletingLastPathComponent()
        let pattern = #"images/[^\s)\]\}"']+"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(markdown.startIndex..., in: markdown)
        let references = regex?.matches(in: markdown, range: range).compactMap { match -> String? in
            guard let valueRange = Range(match.range, in: markdown) else { return nil }
            return String(markdown[valueRange]).removingPercentEncoding
        } ?? []
        let uniqueReferences = Array(Set(references)).sorted()
        let missing = uniqueReferences.filter { path in
            path.contains("..") || !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(path).path)
        }

        let imagesURL = bundleURL.appendingPathComponent("images", isDirectory: true)
        let imageFiles = (try? FileManager.default.contentsOfDirectory(
            at: imagesURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: .skipsHiddenFiles
        )) ?? []
        let oversized = imageFiles.compactMap { url -> String? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  Int64(values.fileSize ?? 0) > oversizedThreshold else { return nil }
            return url.lastPathComponent
        }.sorted()

        return HugoArticleValidation(
            frontMatterIssues: frontMatterIssues,
            missingImagePaths: missing,
            oversizedImageNames: oversized
        )
    }

    static func updatingDraftStatus(in markdown: String, isDraft: Bool) -> String {
        var matter = MarkdownFrontMatter(markdown: markdown)
        matter.draft = isDraft
        return matter.applying(to: markdown)
    }

    static func publicationDate(from value: String) -> Date? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !value.isEmpty else { return nil }

        for fractional in [true, false] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = fractional
                ? [.withInternetDateTime, .withFractionalSeconds]
                : [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
        }

        for pattern in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd HH:mm:ss.SSSZ",
            "yyyy-MM-dd HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    static func publicationDateValue(for date: Date, preserving existingValue: String? = nil) -> String {
        let existing = existingValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)

        if existing.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }

        let dateTimePattern = #"^\d{4}-\d{2}-\d{2}([T ])\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$"#
        if existing.range(of: dateTimePattern, options: .regularExpression) != nil {
            let separator = existing.contains("T") ? "'T'" : " "
            let fractionDigits = existing.range(of: #"(?<=\.)\d+"#, options: .regularExpression)
                .map { existing[$0].count } ?? 0
            let suffix = existing.range(of: #"(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression)
                .map { String(existing[$0]) }
            let fraction = fractionDigits > 0 ? "." + String(repeating: "S", count: fractionDigits) : ""
            formatter.dateFormat = "yyyy-MM-dd\(separator)HH:mm:ss\(fraction)"

            if let suffix {
                formatter.timeZone = publicationTimeZone(from: suffix) ?? .current
                if suffix == "Z" {
                    formatter.dateFormat += "'Z'"
                } else {
                    formatter.dateFormat += "'\(suffix)'"
                }
            } else {
                formatter.timeZone = .current
            }
            return formatter.string(from: date)
        }

        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.string(from: date)
    }

    static func updatingPublicationDate(in markdown: String, date: Date?) -> String {
        var matter = MarkdownFrontMatter(markdown: markdown)
        matter.date = date.map { publicationDateValue(for: $0, preserving: matter.date) } ?? ""
        return matter.applying(to: markdown)
    }

    private static func publicationTimeZone(from suffix: String) -> TimeZone? {
        if suffix == "Z" { return TimeZone(secondsFromGMT: 0) }
        let compact = suffix.replacingOccurrences(of: ":", with: "")
        guard compact.count == 5,
              let hours = Int(compact.dropFirst().prefix(2)),
              let minutes = Int(compact.suffix(2)) else { return nil }
        let sign = compact.first == "-" ? -1 : 1
        return TimeZone(secondsFromGMT: sign * ((hours * 60 + minutes) * 60))
    }

    static func isValidBundleName(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    static func slugify(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\p{Han}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

struct MarkdownFrontMatter {
    var title = ""
    var date = ""
    var draft = false
    var tags = ""
    var cover = ""
    var body = ""
    var delimiter = "---"
    var hasFrontMatter = false
    var customValues: [String: String] = [:]
    private var originalCustomValues: [String: String] = [:]

    init(markdown: String) {
        body = markdown
        let lines = markdown.components(separatedBy: .newlines)
        guard let first = lines.first, first == "---" || first == "+++",
              let end = lines.dropFirst().firstIndex(of: first) else { return }
        hasFrontMatter = true
        delimiter = first
        let header = lines[1..<end]
        body = lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .newlines)
        for line in header {
            let separator: Character = delimiter == "+++" ? "=" : ":"
            let parts = line.split(separator: separator, maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "title": title = value
            case "date": date = value
            case "draft": draft = ["true", "yes", "1"].contains(value.lowercased())
            case "tags": tags = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            case "cover": cover = value
            default:
                customValues[key] = value
                originalCustomValues[key] = value
            }
        }
    }

    func applying(
        to original: String,
        customFields: [HugoFrontMatterFieldConfiguration] = []
    ) -> String {
        let lines = original.components(separatedBy: .newlines)
        var extra: [String] = []
        var originalDateValue: String?
        let modifiedConfiguredKeys = Set(customFields.compactMap { field -> String? in
            guard customValues[field.key] != originalCustomValues[field.key] else { return nil }
            if field.type == .number,
               let value = customValues[field.key],
               !value.isEmpty,
               !HugoContentService.isValidFrontMatterNumber(value) {
                return nil
            }
            return field.key
        })
        if let first = lines.first, first == "---" || first == "+++",
           let end = lines.dropFirst().firstIndex(of: first) {
            let header = lines[1..<end]
            let separator: Character = delimiter == "+++" ? "=" : ":"
            if let dateLine = header.first(where: { line in
                line.split(separator: separator, maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespaces) == "date"
            }) {
                let parts = dateLine.split(separator: separator, maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    originalDateValue = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            extra = header.filter {
                let separator: Character = delimiter == "+++" ? "=" : ":"
                let key = $0.split(separator: separator, maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
                return !HugoContentService.builtInFrontMatterKeys.contains(key)
                    && !modifiedConfiguredKeys.contains(key)
            }
        }
        let assignment = delimiter == "+++" ? " = " : ": "
        var header = ["title\(assignment)\"\(title)\""]
        if !date.isEmpty {
            let trimmedDate = date.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let quote = originalDateValue.flatMap { value -> Character? in
                guard let first = value.first, value.last == first, (first == "\"" || first == "'") else { return nil }
                return first
            }
            let formattedDate = quote.map { "\($0)\(trimmedDate)\($0)" } ?? trimmedDate
            header.append("date\(assignment)\(formattedDate)")
        }
        header.append("draft\(assignment)\(draft ? "true" : "false")")
        if !tags.isEmpty { header.append("tags\(assignment)[\(tags)]") }
        if !cover.isEmpty { header.append("cover\(assignment)\"\(cover)\"") }
        for field in customFields {
            guard modifiedConfiguredKeys.contains(field.key) else { continue }
            guard let rawValue = customValues[field.key] else { continue }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty || field.type == .boolean else { continue }
            switch field.type {
            case .text:
                let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
                header.append("\(field.key)\(assignment)\"\(escaped)\"")
            case .boolean:
                let enabled = ["true", "yes", "1"].contains(value.lowercased())
                header.append("\(field.key)\(assignment)\(enabled ? "true" : "false")")
            case .number:
                header.append("\(field.key)\(assignment)\(value)")
            }
        }
        header.append(contentsOf: extra)
        return ([delimiter] + header + [delimiter, "", body]).joined(separator: "\n")
    }
}

struct HugoArticlePreviewDocument: Equatable {
    let title: String
    let date: String
    let draft: Bool
    let tags: [String]
    let cover: String
    let body: String

    init(markdown: String) {
        let matter = MarkdownFrontMatter(markdown: markdown)
        title = matter.title
        date = matter.date
        draft = matter.draft
        tags = matter.tags.split(separator: ",").map { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }.filter { !$0.isEmpty }
        cover = matter.cover
        body = matter.body
    }
}

struct HugoArticlePreviewSnapshot: Equatable {
    let document: HugoArticlePreviewDocument
    let hasUnsavedChanges: Bool

    init(markdown: String, savedMarkdown: String) {
        document = HugoArticlePreviewDocument(markdown: markdown)
        hasUnsavedChanges = markdown != savedMarkdown
    }
}

enum HugoPreviewBlock: Equatable {
    case markdown(String)
    case heading(level: Int, text: String)
    case quote(String)
    case divider
    case image(alt: String, path: String)
    case code(language: String, content: String)
    case table(headers: [String], rows: [[String]])
    case shortcode(String)
}

enum HugoPreviewParser {
    static func blocks(from markdown: String) -> [HugoPreviewBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var result: [HugoPreviewBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.markdown(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("```") {
                flushParagraph()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !lines[index].hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                result.append(.code(language: language, content: codeLines.joined(separator: "\n")))
            } else if let heading = heading(from: line) {
                flushParagraph()
                result.append(.heading(level: heading.level, text: heading.text))
            } else if let quote = quote(from: line) {
                flushParagraph()
                result.append(.quote(quote))
            } else if ["---", "***", "___"].contains(line.trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                result.append(.divider)
            } else if let image = image(from: line) {
                flushParagraph()
                result.append(.image(alt: image.alt, path: image.path))
            } else if containsShortcode(line) {
                flushParagraph()
                result.append(.shortcode(line.trimmingCharacters(in: .whitespaces)))
            } else if index + 1 < lines.count,
                      line.contains("|"),
                      isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let headers = tableCells(line)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                result.append(.table(headers: headers, rows: rows))
                continue
            } else if line.isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph()
        return result
    }

    private static func image(from line: String) -> (alt: String, path: String)? {
        let pattern = #"^\s*!\[([^]]*)\]\(\s*<?([^\s)>]+)>?(?:\s+[\"'][^)]*[\"'])?\s*\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let altRange = Range(match.range(at: 1), in: line),
              let pathRange = Range(match.range(at: 2), in: line) else { return nil }
        return (String(line[altRange]), String(line[pathRange]))
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let pattern = #"^\s*(#{1,6})\s+(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let markerRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line) else { return nil }
        return (line[markerRange].count, String(line[textRange]))
    }

    private static func quote(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func containsShortcode(_ line: String) -> Bool {
        (line.contains("{{<") && line.contains(">}}"))
            || (line.contains("{{%") && line.contains("%}}"))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy {
            $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }
}
