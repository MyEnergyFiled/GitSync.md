import Foundation

struct HugoContentMapping: Codable, Identifiable, Hashable {
    var directory: String
    var archetype: String
    var id: String { directory }
}

struct HugoRepositoryConfiguration: Codable {
    var contentMappings: [HugoContentMapping] = []
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

enum HugoContentService {
    static let configurationFile = ".gitsync-hugo.json"
    static let supportedArticleImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff"
    ]

    static func isSupportedArticleImage(_ url: URL) -> Bool {
        supportedArticleImageExtensions.contains(url.pathExtension.lowercased())
    }

    static func loadConfiguration(from root: URL) -> HugoRepositoryConfiguration {
        let url = root.appendingPathComponent(configurationFile)
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(HugoRepositoryConfiguration.self, from: data) else {
            return HugoRepositoryConfiguration()
        }
        return value
    }

    static func saveConfiguration(_ configuration: HugoRepositoryConfiguration, to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(
            to: root.appendingPathComponent(configurationFile), options: .atomic
        )
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
        let directory = root.appendingPathComponent("archetypes", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []).filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
            .map { "archetypes/\($0.lastPathComponent)" }.sorted()
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
            default: break
            }
        }
    }

    func applying(to original: String) -> String {
        let lines = original.components(separatedBy: .newlines)
        var extra: [String] = []
        var originalDateValue: String?
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
                return !["title", "date", "draft", "tags", "cover"].contains(key)
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
        header.append(contentsOf: extra)
        return ([delimiter] + header + [delimiter, "", body]).joined(separator: "\n")
    }
}
