import Foundation

enum HugoThemeDiscoveryService {
    private static let maximumMetadataSize = 256 * 1024
    private static let requiredHugoVersion = "0.134.3"

    static func discover(
        in repositoryRoot: URL,
        configuredThemes: [String] = [],
        runtimeVersion: String = requiredHugoVersion
    ) -> [HugoThemeDescriptor] {
        let root = repositoryRoot.standardizedFileURL
        let themesURL = root.appendingPathComponent("themes", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: themesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { themeURL in
            guard let values = try? themeURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  isInside(themeURL, root: root) else { return nil }
            return descriptor(
                for: themeURL,
                configuredThemes: configuredThemes,
                runtimeVersion: runtimeVersion
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func descriptor(
        for themeURL: URL,
        configuredThemes: [String] = [],
        runtimeVersion: String = requiredHugoVersion
    ) -> HugoThemeDescriptor? {
        let directoryName = themeURL.lastPathComponent
        let metadataURL = ["theme.toml", "hugo.toml"].lazy
            .map { themeURL.appendingPathComponent($0) }
            .first { isRegularFile($0) }
        guard metadataURL != nil || configuredThemes.contains(directoryName) else { return nil }
        let metadata = metadataURL.flatMap(readMetadata)
        let minimum = metadata?.firstValue(for: ["min_version", "minHugoVersion", "hugoVersion"])
        let warnings = HugoThemeCapabilityScanner.scan(themeURL: themeURL)
        let compatible = minimum.map { compareVersions(runtimeVersion, $0) != .orderedAscending } ?? true
        return HugoThemeDescriptor(
            id: directoryName,
            directoryName: directoryName,
            displayName: metadata?.firstValue(for: ["name"]) ?? directoryName,
            minimumHugoVersion: minimum,
            author: metadata?.firstValue(for: ["author", "authors"]),
            license: metadata?.firstValue(for: ["license"]),
            isCompatible: compatible,
            capabilityWarnings: warnings
        )
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func components(_ value: String) -> [Int] {
            value.split(whereSeparator: { !$0.isNumber }).prefix(3).map { Int($0) ?? 0 }
        }
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func readMetadata(_ url: URL) -> [String: String]? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= maximumMetadataSize,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = unquote(String(parts[1]))
        }
        return result
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.first == value.last,
              value.first == "\"" || value.first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        return resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/")
    }
}

private extension Dictionary where Key == String, Value == String {
    func firstValue(for keys: [String]) -> String? {
        keys.lazy.compactMap { self[$0] }.first
    }
}

enum HugoThemeCapabilityScanner {
    static func scan(themeURL: URL) -> [HugoCapabilityWarning] {
        var warnings = Set<HugoCapabilityWarning>()
        guard let enumerator = FileManager.default.enumerator(
            at: themeURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= 1_048_576,
                  let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lower = text.lowercased()
            if lower.contains("resources.getremote") { warnings.insert(.remoteResource) }
            if lower.contains("postcss") || lower.contains("tailwind") || lower.contains("babel") {
                warnings.insert(.externalExecutable)
            }
            if lower.contains("asciidoctor") || lower.contains("pandoc") || lower.contains("rst2") {
                warnings.insert(.externalConverter)
            }
            if lower.contains("hugo mod") || lower.contains("go.mod") {
                warnings.insert(.hugoModule)
            }
        }
        return warnings.sorted { $0.rawValue < $1.rawValue }
    }

    static func report(
        repositoryRoot: URL,
        theme: HugoThemeDescriptor?,
        runtime: HugoRuntimeVersion
    ) -> HugoCapabilityReport {
        var warnings = Set(theme?.capabilityWarnings ?? [])
        var details: [String] = []
        if let theme, !theme.isCompatible {
            details.append("\(theme.displayName) requires Hugo \(theme.minimumHugoVersion ?? "a newer version").")
        }
        if runtime.isExtended == false,
           warnings.contains(.externalConverter) {
            details.append("This theme uses a converter that is not available in the iOS runtime.")
        }
        let status: HugoCapabilityStatus
        if theme?.isCompatible == false {
            status = .requiresNewerHugo
        } else if warnings.contains(.externalExecutable) || warnings.contains(.externalConverter) {
            status = .requiresExternalExecutable
        } else if warnings.contains(.remoteResource) || warnings.contains(.hugoModule) {
            status = .requiresNetwork
        } else {
            status = .supported
        }
        return HugoCapabilityReport(status: status, warnings: warnings.sorted { $0.rawValue < $1.rawValue }, details: details)
    }
}
