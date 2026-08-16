import Foundation

struct HugoSiteConfiguration: Equatable {
    var configurationFiles: [String] = []
    var themes: [String] = []
    var defaultContentLanguage: String?
    var languages: [String] = []
    var permalinks: [String: String] = [:]
    var assetDirectories: [String] = []
    var staticDirectories: [String] = []
    var resourceDirectories: [String] = []

    var isDetected: Bool { !configurationFiles.isEmpty }

    var previewResourceDirectories: [String] {
        Array(Set(assetDirectories + staticDirectories + resourceDirectories)).sorted()
    }
}

enum HugoSiteConfigurationService {
    private static let rootConfigurationNames = [
        "hugo.toml", "hugo.yaml", "hugo.yml", "hugo.json",
        "config.toml", "config.yaml", "config.yml", "config.json"
    ]
    private static let supportedExtensions: Set<String> = ["toml", "yaml", "yml", "json"]
    private static let maximumConfigurationSize = 1_048_576

    static func discover(in repositoryRoot: URL) -> HugoSiteConfiguration {
        let root = repositoryRoot.standardizedFileURL
        let files = configurationFiles(in: root)
        var accumulator = Accumulator()

        for fileURL in files {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= maximumConfigurationSize,
                  let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let relativePath = relativePath(for: fileURL, root: root)
            accumulator.configurationFiles.append(relativePath)
            let scope = fragmentScope(for: fileURL)

            switch fileURL.pathExtension.lowercased() {
            case "toml":
                parseTOML(text, scope: scope, into: &accumulator)
            case "yaml", "yml":
                parseYAML(text, scope: scope, into: &accumulator)
            case "json":
                parseJSON(data, scope: scope, into: &accumulator)
            default:
                break
            }
        }

        return accumulator.configuration
    }

    private static func configurationFiles(in root: URL) -> [URL] {
        let fileManager = FileManager.default
        var result = rootConfigurationNames.compactMap { name -> URL? in
            let candidate = root.appendingPathComponent(name)
            return safeConfigurationFile(candidate, root: root) ? candidate : nil
        }
        let configRoot = root.appendingPathComponent("config", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: configRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let fileURL as URL in enumerator {
                guard supportedExtensions.contains(fileURL.pathExtension.lowercased()),
                      safeConfigurationFile(fileURL, root: root) else { continue }
                result.append(fileURL)
            }
        }
        return result.sorted {
            relativePath(for: $0, root: root).localizedStandardCompare(
                relativePath(for: $1, root: root)
            ) == .orderedAscending
        }
    }

    private static func safeConfigurationFile(_ fileURL: URL, root: URL) -> Bool {
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return false }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
        return resolvedFile.path.hasPrefix(resolvedRoot.path + "/")
    }

    private static func relativePath(for fileURL: URL, root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return fileURL.path.hasPrefix(prefix) ? String(fileURL.path.dropFirst(prefix.count)) : fileURL.lastPathComponent
    }

    private static func fragmentScope(for fileURL: URL) -> String? {
        guard fileURL.pathComponents.contains("config") else { return nil }
        let name = fileURL.deletingPathExtension().lastPathComponent.lowercased()
        return ["languages", "permalinks"].contains(name) ? name : nil
    }

    private static func parseTOML(_ text: String, scope: String?, into accumulator: inout Accumulator) {
        var section: [String] = scope.map { [$0] } ?? []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = strippingComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                let components = dottedComponents(name)
                section = scope.map { [$0] + components } ?? components
                accumulator.observe(path: section)
                continue
            }
            guard let assignment = split(line, at: "=") else { continue }
            let keyPath = dottedComponents(assignment.left)
            let path = section + keyPath
            accumulator.observe(path: path)
            accumulator.apply(values: stringValues(from: assignment.right), at: path)
        }
    }

    private static func parseYAML(_ text: String, scope: String?, into accumulator: inout Accumulator) {
        var stack: [(indent: Int, key: String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let uncommented = strippingComment(from: rawLine)
            let content = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, content != "---" else { continue }
            let indent = uncommented.prefix { $0 == " " || $0 == "\t" }.reduce(0) {
                $0 + ($1 == "\t" ? 4 : 1)
            }
            while stack.last.map({ $0.indent >= indent }) == true { stack.removeLast() }
            let base = (scope.map { [$0] } ?? []) + stack.map { $0.key }

            if content.hasPrefix("- ") {
                guard base.last != nil else { continue }
                accumulator.apply(values: stringValues(from: String(content.dropFirst(2))), at: base)
                continue
            }
            guard let assignment = split(content, at: ":") else { continue }
            let key = unquoted(assignment.left.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !key.isEmpty else { continue }
            let path = base + dottedComponents(key)
            accumulator.observe(path: path)
            let value = assignment.right.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                stack.append((indent, key))
            } else {
                accumulator.apply(values: stringValues(from: value), at: path)
            }
        }
    }

    private static func parseJSON(_ data: Data, scope: String?, into accumulator: inout Accumulator) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return }
        visitJSON(object, path: scope.map { [$0] } ?? [], accumulator: &accumulator)
    }

    private static func visitJSON(_ value: Any, path: [String], accumulator: inout Accumulator) {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                let childPath = path + dottedComponents(key)
                accumulator.observe(path: childPath)
                if let child = dictionary[key] {
                    visitJSON(child, path: childPath, accumulator: &accumulator)
                }
            }
        } else if let array = value as? [Any] {
            let values = array.compactMap { scalarString($0) }
            accumulator.apply(values: values, at: path)
        } else if let scalar = scalarString(value) {
            accumulator.apply(values: [scalar], at: path)
        }
    }

    private static func scalarString(_ value: Any) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func dottedComponents(_ value: String) -> [String] {
        value.split(separator: ".").map {
            unquoted(String($0).trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { !$0.isEmpty }
    }

    private static func stringValues(from rawValue: String) -> [String] {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        let listValue = value.hasPrefix("[") && value.hasSuffix("]")
            ? String(value.dropFirst().dropLast())
            : value
        return splitList(listValue).map {
            unquoted($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { !$0.isEmpty }
    }

    private static func splitList(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" && quote != nil {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = quote == character ? nil : (quote ?? character)
                current.append(character)
            } else if character == "," && quote == nil {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }

    private static func split(_ line: String, at separator: Character) -> (left: String, right: String)? {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\" && quote != nil { escaped = true; continue }
            if character == "\"" || character == "'" {
                quote = quote == character ? nil : (quote ?? character)
            } else if character == separator && quote == nil {
                return (String(line[..<index]), String(line[line.index(after: index)...]))
            }
        }
        return nil
    }

    private static func strippingComment(from line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped { result.append(character); escaped = false; continue }
            if character == "\\" && quote != nil { result.append(character); escaped = true; continue }
            if character == "\"" || character == "'" {
                quote = quote == character ? nil : (quote ?? character)
            } else if character == "#" && quote == nil {
                break
            }
            result.append(character)
        }
        return result
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return value }
        return String(value.dropFirst().dropLast())
    }

    private struct Accumulator {
        var configurationFiles: [String] = []
        var themes: [String] = []
        var defaultContentLanguage: String?
        var languages: [String] = []
        var permalinks: [String: String] = [:]
        var assetDirectories: [String]?
        var staticDirectories: [String]?
        var resourceDirectories: [String]?

        var configuration: HugoSiteConfiguration {
            let detected = !configurationFiles.isEmpty
            return HugoSiteConfiguration(
                configurationFiles: configurationFiles,
                themes: themes.sorted(),
                defaultContentLanguage: defaultContentLanguage,
                languages: languages.sorted(),
                permalinks: permalinks,
                assetDirectories: assetDirectories ?? (detected ? ["assets"] : []),
                staticDirectories: staticDirectories ?? (detected ? ["static"] : []),
                resourceDirectories: resourceDirectories ?? (detected ? ["resources"] : [])
            )
        }

        mutating func observe(path: [String]) {
            let normalized = path.map(normalize)
            guard let languageIndex = normalized.firstIndex(of: "languages"),
                  normalized.indices.contains(languageIndex + 1) else { return }
            Self.appendUnique(path[languageIndex + 1], to: &languages)
        }

        mutating func apply(values: [String], at path: [String]) {
            guard let key = path.last, !values.isEmpty else { return }
            let normalizedPath = path.map(normalize)
            let normalizedKey = normalize(key)

            switch normalizedKey {
            case "theme", "themes":
                for value in values { Self.appendUnique(value, to: &themes) }
            case "defaultcontentlanguage":
                defaultContentLanguage = values[0]
                Self.appendUnique(values[0], to: &languages)
            case "assetdir":
                assetDirectories = safeDirectories(values)
            case let key where key == "staticdir" || staticDirectoryKey(key):
                var existing = staticDirectories ?? []
                for value in safeDirectories(values) { Self.appendUnique(value, to: &existing) }
                staticDirectories = existing
            case "resourcedir":
                resourceDirectories = safeDirectories(values)
            default:
                break
            }

            if let permalinkIndex = normalizedPath.firstIndex(of: "permalinks"),
               normalizedPath.indices.contains(permalinkIndex + 1),
               normalizedPath.count == permalinkIndex + 2 {
                permalinks[path[permalinkIndex + 1]] = values[0]
            }
        }

        private func safeDirectories(_ values: [String]) -> [String] {
            values.filter { value in
                !value.isEmpty && !value.hasPrefix("/") && !value.contains("://")
                    && !value.split(separator: "/").contains("..")
            }
        }

        private func normalize(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        private func staticDirectoryKey(_ value: String) -> Bool {
            guard value.hasPrefix("staticdir") else { return false }
            let suffix = value.dropFirst("staticdir".count)
            return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
        }

        private static func appendUnique(_ value: String, to values: inout [String]) {
            guard !value.isEmpty, !values.contains(value) else { return }
            values.append(value)
        }
    }
}
