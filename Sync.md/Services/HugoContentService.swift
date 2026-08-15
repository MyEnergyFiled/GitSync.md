import Foundation

struct HugoContentMapping: Codable, Identifiable, Hashable {
    var directory: String
    var archetype: String
    var id: String { directory }
}

struct HugoRepositoryConfiguration: Codable {
    var contentMappings: [HugoContentMapping] = []
}

enum HugoContentService {
    static let configurationFile = ".gitsync-hugo.json"

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

    init(markdown: String) {
        body = markdown
        let lines = markdown.components(separatedBy: .newlines)
        guard let first = lines.first, first == "---" || first == "+++",
              let end = lines.dropFirst().firstIndex(of: first) else { return }
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
        if let first = lines.first, first == "---" || first == "+++",
           let end = lines.dropFirst().firstIndex(of: first) {
            extra = lines[1..<end].filter {
                let separator: Character = delimiter == "+++" ? "=" : ":"
                let key = $0.split(separator: separator, maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
                return !["title", "date", "draft", "tags", "cover"].contains(key)
            }
        }
        let assignment = delimiter == "+++" ? " = " : ": "
        var header = ["title\(assignment)\"\(title)\""]
        if !date.isEmpty { header.append("date\(assignment)\(date)") }
        header.append("draft\(assignment)\(draft ? "true" : "false")")
        if !tags.isEmpty { header.append("tags\(assignment)[\(tags)]") }
        if !cover.isEmpty { header.append("cover\(assignment)\"\(cover)\"") }
        header.append(contentsOf: extra)
        return ([delimiter] + header + [delimiter, "", body]).joined(separator: "\n")
    }
}
