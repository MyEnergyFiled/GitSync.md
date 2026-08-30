import Foundation

enum HugoPreviewStyle: String, CaseIterable, Identifiable {
    case native = "Quick Preview"
    case theme = "Hugo Theme"

    var id: String { rawValue }
    var title: String { String(localized: String.LocalizationValue(rawValue)) }
}

enum HugoPreviewDevice: String, CaseIterable, Identifiable {
    case phone = "Phone"
    case tablet = "Tablet"
    case desktop = "Desktop"

    var id: String { rawValue }
    var title: String { String(localized: String.LocalizationValue(rawValue)) }
    var width: CGFloat {
        switch self {
        case .phone: return 390
        case .tablet: return 768
        case .desktop: return 1200
        }
    }
}

struct HugoThemePreviewOptions: Equatable {
    var layout = "single"
    var contentType = "page"
    var language = "en"
    var device: HugoPreviewDevice = .tablet
    var selectedTheme: String?
}

struct HugoThemePreviewChoices: Equatable {
    var layouts: [String] = ["single"]
    var contentTypes: [String] = ["page"]
    var languages: [String] = ["en"]
    var languageVariantURLs: [String: URL] = [:]
}

enum HugoThemePreviewService {
    static func siteResourceSignature(
        repositoryRoot: URL,
        configuration: HugoSiteConfiguration
    ) -> String {
        let root = repositoryRoot.standardizedFileURL
        var searchRoots = [root.appendingPathComponent("layouts", isDirectory: true)]
        searchRoots.append(contentsOf: configuration.themes.map {
            root.appendingPathComponent("themes/\($0)", isDirectory: true)
        })
        searchRoots.append(contentsOf: configuration.previewResourceDirectories.map {
            root.appendingPathComponent($0, isDirectory: true)
        })
        var entries: [String] = []
        for relative in configuration.configurationFiles {
            let fileURL = root.appendingPathComponent(relative)
            if let signature = fileSignature(fileURL, repositoryRoot: root) {
                entries.append(signature)
            }
        }
        for searchRoot in searchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                    .contentModificationDateKey, .fileSizeKey
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                if entries.count >= 2_048 { break }
                guard let signature = fileSignature(fileURL, repositoryRoot: root) else { continue }
                entries.append(signature)
            }
        }
        return entries.sorted().joined(separator: "|")
    }

    static func discoverChoices(
        repositoryRoot: URL,
        configuration: HugoSiteConfiguration,
        articleURL: URL
    ) -> HugoThemePreviewChoices {
        let root = repositoryRoot.standardizedFileURL
        let layoutRoots = previewLayoutRoots(repositoryRoot: root, configuration: configuration)
        var layouts: Set<String> = ["single"]
        var contentTypes: Set<String> = ["page"]
        for layoutRoot in layoutRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: layoutRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "html" {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let name = fileURL.deletingPathExtension().lastPathComponent
                if !["baseof", "list"].contains(name) { layouts.insert(name) }
                let relative = fileURL.path.replacingOccurrences(of: layoutRoot.path + "/", with: "")
                if let first = relative.split(separator: "/").first.map(String.init),
                   !["_default", "partials", "shortcodes"].contains(first) {
                    contentTypes.insert(first)
                }
            }
        }

        let contentRoot = root.appendingPathComponent("content", isDirectory: true)
        if let safeContentRoot = try? RepositoryFileDestinationValidator.validatedDirectoryURL(
            contentRoot, repositoryRootURL: root
        ), let entries = try? FileManager.default.contentsOfDirectory(
            at: safeContentRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                contentTypes.insert(entry.lastPathComponent)
            }
        }

        let defaultLanguage = configuration.defaultContentLanguage ?? configuration.languages.first ?? "en"
        let articleDirectory = try? RepositoryFileDestinationValidator.validatedDirectoryURL(
            articleURL.deletingLastPathComponent(), repositoryRootURL: root
        )
        let safeArticleURL = articleDirectory.flatMap {
            try? RepositoryFileDestinationValidator.existingFileURL(
                articleURL, in: $0, repositoryRootURL: root
            )
        }
        var variants: [String: URL] = [:]
        if let safeArticleURL { variants[defaultLanguage] = safeArticleURL }
        let baseArticleURL = safeArticleURL ?? articleURL
        let baseName = baseArticleURL.deletingPathExtension().lastPathComponent
            .split(separator: ".").first.map(String.init)
            ?? baseArticleURL.deletingPathExtension().lastPathComponent
        if let articleDirectory,
           let siblings = try? FileManager.default.contentsOfDirectory(
               at: articleDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
           ) {
            for sibling in siblings where ["md", "markdown"].contains(sibling.pathExtension.lowercased()) {
                guard let safeSibling = try? RepositoryFileDestinationValidator.existingFileURL(
                    sibling, in: articleDirectory, repositoryRootURL: root
                ) else { continue }
                let stem = safeSibling.deletingPathExtension().lastPathComponent
                let components = stem.split(separator: ".").map(String.init)
                if components.count == 2, components[0] == baseName {
                    variants[components[1]] = safeSibling
                } else if stem == baseName {
                    variants[defaultLanguage] = safeSibling
                }
            }
        }
        let languages = Set(configuration.languages + [defaultLanguage] + Array(variants.keys))
        return HugoThemePreviewChoices(
            layouts: layouts.sorted(),
            contentTypes: contentTypes.sorted(),
            languages: languages.sorted(),
            languageVariantURLs: variants
        )
    }

    private static func previewLayoutRoots(
        repositoryRoot: URL,
        configuration: HugoSiteConfiguration
    ) -> [URL] {
        let candidates = [repositoryRoot.appendingPathComponent("layouts", isDirectory: true)]
            + configuration.themes.map {
                repositoryRoot.appendingPathComponent("themes/\($0)/layouts", isDirectory: true)
            }
        return candidates.compactMap {
            try? RepositoryFileDestinationValidator.validatedDirectoryURL(
                $0, repositoryRootURL: repositoryRoot
            )
        }
    }

    private static func relativePath(for fileURL: URL, repositoryRoot: URL) -> String? {
        let root = repositoryRoot.resolvingSymlinksInPath().standardizedFileURL
        let file = fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        return String(file.path.dropFirst(root.path.count + 1))
    }

    private static func fileSignature(_ fileURL: URL, repositoryRoot: URL) -> String? {
        guard let relative = relativePath(for: fileURL, repositoryRoot: repositoryRoot),
              let values = try? fileURL.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
              ), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return "\(relative):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
    }
}
