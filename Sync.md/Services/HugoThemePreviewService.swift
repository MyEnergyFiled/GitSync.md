import Foundation
import UniformTypeIdentifiers

enum HugoPreviewStyle: String, CaseIterable, Identifiable {
    case native = "Native"
    case theme = "Theme"

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
}

struct HugoThemePreviewChoices: Equatable {
    var layouts: [String] = ["single"]
    var contentTypes: [String] = ["page"]
    var languages: [String] = ["en"]
    var languageVariantURLs: [String: URL] = [:]
}

struct HugoThemePreviewPage: Equatable {
    let html: String
    let stylesheetPaths: [String]
    let layoutPath: String?
    let compatibilityIssues: [String]
    let resourceSignature: String
}

enum HugoThemePreviewService {
    static let resourceScheme = "gitsync-resource"
    private static let maximumStylesheets = 32
    private static let maximumStylesheetSize = 1_048_576
    private static let maximumResourceSize = 20_971_520
    private static let allowedResourceExtensions: Set<String> = [
        "css", "woff", "woff2", "ttf", "otf", "eot",
        "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "heif", "ico",
        "mp3", "m4a", "wav", "ogg", "mp4", "m4v", "webm"
    ]

    static func render(
        markdown: String,
        articleURL: URL,
        repositoryRoot: URL,
        configuration: HugoSiteConfiguration,
        options: HugoThemePreviewOptions = HugoThemePreviewOptions()
    ) -> HugoThemePreviewPage {
        let document = HugoArticlePreviewDocument(markdown: markdown)
        let stylesheets = discoverStylesheets(
            repositoryRoot: repositoryRoot,
            configuration: configuration
        )
        let stylesheetLinks = stylesheets.compactMap { fileURL -> String? in
            guard let resource = resourceURL(for: fileURL, repositoryRoot: repositoryRoot) else { return nil }
            return #"<link rel="stylesheet" href="\#(resource)">"#
        }.joined(separator: "\n")
        let renderedBlocks = renderBlocks(
            HugoPreviewParser.blocks(from: document.body),
            bundleURL: articleURL.deletingLastPathComponent(),
            repositoryRoot: repositoryRoot,
            configuration: configuration
        )
        let title = document.title.isEmpty
            ? articleURL.deletingPathExtension().lastPathComponent
            : document.title
        let tags = document.tags.map { #"<li>\#(escapeHTML($0))</li>"# }.joined()
        let metadata = [document.date, document.draft ? String(localized: "Draft") : String(localized: "Published")]
            .filter { !$0.isEmpty }
            .map { #"<span>\#(escapeHTML($0))</span>"# }
            .joined()
        let cover = previewAssetURL(
            for: document.cover,
            bundleURL: articleURL.deletingLastPathComponent(),
            repositoryRoot: repositoryRoot,
            configuration: configuration
        ).flatMap { resourceURL(for: $0, repositoryRoot: repositoryRoot) }
            .map { #"<img class="gitsync-cover" src="\#($0)" alt="">"# } ?? ""
        let fallbackArticle = """
        <article class="gitsync-page single">
          <header>
            <h1 class="gitsync-title">\(escapeHTML(title))</h1>
            <div class="gitsync-meta">\(metadata)</div>
            <ul class="gitsync-tags">\(tags)</ul>
            \(cover)
          </header>
          <main class="gitsync-content">\(renderedBlocks.html)</main>
        </article>
        """
        let layout = discoverLayout(
            repositoryRoot: repositoryRoot,
            configuration: configuration,
            layout: options.layout,
            contentType: options.contentType
        )
        let section = articleSection(articleURL: articleURL, repositoryRoot: repositoryRoot)
        let matter = MarkdownFrontMatter(markdown: markdown)
        let context = HugoTemplatePreviewContext(
            title: title,
            date: document.date,
            draft: document.draft,
            contentHTML: renderedBlocks.html,
            siteTitle: repositoryRoot.lastPathComponent,
            language: options.language,
            contentType: options.contentType,
            section: section,
            layout: options.layout,
            permalink: previewPermalink(
                section: options.contentType,
                articleURL: articleURL,
                title: title,
                params: matter.customValues,
                configuration: configuration
            ),
            params: matter.customValues
        )
        let renderedLayout = layout.map {
            HugoTemplateCompatibilityService.renderTemplate($0.template, context: context)
        }
        let pageContent = renderedLayout?.html ?? fallbackArticle
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline' \(resourceScheme):; img-src data: \(resourceScheme):; font-src \(resourceScheme):; media-src \(resourceScheme):; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
          <style>
            :root { color-scheme: light dark; }
            html, body { margin: 0; min-height: 100%; }
            body { font: 17px/1.65 ui-serif, Georgia, serif; background: #f1efe9; color: #211f1b; }
            .gitsync-page { box-sizing: border-box; width: min(100% - 32px, 820px); margin: 16px auto; padding: clamp(24px, 5vw, 64px); background: #fffdf7; }
            .gitsync-title { font-size: clamp(2rem, 7vw, 3.25rem); line-height: 1.08; }
            .gitsync-meta, .gitsync-tags { display: flex; flex-wrap: wrap; gap: 8px 14px; padding: 0; list-style: none; opacity: .72; }
            .gitsync-cover, .gitsync-content img { display: block; max-width: 100%; height: auto; }
            .gitsync-content pre { overflow-x: auto; padding: 14px; background: rgba(127,127,127,.12); }
            .gitsync-content table { display: block; overflow-x: auto; border-collapse: collapse; }
            .gitsync-content th, .gitsync-content td { padding: 8px; border: 1px solid currentColor; }
            .gitsync-placeholder { padding: 12px; border: 1px dashed currentColor; opacity: .72; }
          </style>
          \(stylesheetLinks)
        </head>
        <body data-gitsync-layout="\(escapeHTML(options.layout))" data-gitsync-type="\(escapeHTML(options.contentType))" lang="\(escapeHTML(options.language))">
          \(pageContent)
        </body>
        </html>
        """
        let relativePaths = stylesheets.compactMap {
            relativePath(for: $0, repositoryRoot: repositoryRoot)
        }
        return HugoThemePreviewPage(
            html: html,
            stylesheetPaths: relativePaths,
            layoutPath: layout?.relativePath,
            compatibilityIssues: renderedBlocks.issues + (renderedLayout?.issues ?? []),
            resourceSignature: siteResourceSignature(
                repositoryRoot: repositoryRoot,
                configuration: configuration
            )
        )
    }

    static func resourceFileURL(from requestURL: URL, repositoryRoot: URL) -> URL? {
        guard requestURL.scheme == resourceScheme, requestURL.host == "local" else { return nil }
        let decoded = requestURL.path.removingPercentEncoding ?? requestURL.path
        let relative = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return nil }
        let root = repositoryRoot.resolvingSymlinksInPath().standardizedFileURL
        let fileURL = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard fileURL.path.hasPrefix(root.path + "/"),
              allowedResourceExtensions.contains(fileURL.pathExtension.lowercased()),
              let values = try? fileURL.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= maximumResourceSize else { return nil }
        return fileURL
    }

    static func resourceURL(for fileURL: URL, repositoryRoot: URL) -> String? {
        guard let relative = relativePath(for: fileURL, repositoryRoot: repositoryRoot) else { return nil }
        let encoded = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
        return "\(resourceScheme)://local/\(encoded)"
    }

    static func mimeType(for fileURL: URL) -> String {
        UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

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
            if let signature = fileSignature(fileURL, repositoryRoot: root) { entries.append(signature) }
        }
        for searchRoot in searchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey
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
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else { continue }
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
            contentRoot,
            repositoryRootURL: root
        ), let entries = try? FileManager.default.contentsOfDirectory(
            at: safeContentRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                contentTypes.insert(entry.lastPathComponent)
            }
        }

        let defaultLanguage = configuration.defaultContentLanguage ?? configuration.languages.first ?? "en"
        let articleDirectory = try? RepositoryFileDestinationValidator.validatedDirectoryURL(
            articleURL.deletingLastPathComponent(),
            repositoryRootURL: root
        )
        let safeArticleURL = articleDirectory.flatMap {
            try? RepositoryFileDestinationValidator.existingFileURL(
                articleURL,
                in: $0,
                repositoryRootURL: root
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
            at: articleDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for sibling in siblings where ["md", "markdown"].contains(sibling.pathExtension.lowercased()) {
                guard let safeSibling = try? RepositoryFileDestinationValidator.existingFileURL(
                    sibling,
                    in: articleDirectory,
                    repositoryRootURL: root
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

    private static func discoverStylesheets(
        repositoryRoot: URL,
        configuration: HugoSiteConfiguration
    ) -> [URL] {
        let root = repositoryRoot.standardizedFileURL
        var searchRoots = configuration.themes.map {
            root.appendingPathComponent("themes/\($0)", isDirectory: true)
        }
        searchRoots.append(contentsOf: configuration.assetDirectories.map {
            root.appendingPathComponent($0, isDirectory: true)
        })
        searchRoots.append(contentsOf: configuration.staticDirectories.map {
            root.appendingPathComponent($0, isDirectory: true)
        })
        var files: [URL] = []
        for searchRoot in searchRoots where files.count < maximumStylesheets {
            guard let enumerator = FileManager.default.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "css" {
                guard let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                ), values.isRegularFile == true,
                   values.isSymbolicLink != true,
                   (values.fileSize ?? 0) <= maximumStylesheetSize,
                   relativePath(for: fileURL, repositoryRoot: root) != nil else { continue }
                files.append(fileURL)
                if files.count == maximumStylesheets { break }
            }
        }
        return Array(Set(files.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
    }

    static func previewAssetURL(
        for reference: String,
        bundleURL: URL,
        repositoryRoot: URL,
        configuration: HugoSiteConfiguration
    ) -> URL? {
        guard !reference.isEmpty else { return nil }
        if reference.hasPrefix("/"), !reference.hasPrefix("//") {
            let relative = String(reference.dropFirst())
            for directory in configuration.staticDirectories {
                let candidate = repositoryRoot.appendingPathComponent(directory, isDirectory: true)
                    .appendingPathComponent(relative).standardizedFileURL
                if relativePath(for: candidate, repositoryRoot: repositoryRoot) != nil,
                   FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil
        }
        return HugoContentService.localPreviewAssetURL(
            for: reference,
            bundleURL: bundleURL,
            repositoryRoot: repositoryRoot
        )
    }

    private static func renderBlocks(
        _ blocks: [HugoPreviewBlock],
        bundleURL: URL,
        repositoryRoot: URL,
        configuration: HugoSiteConfiguration
    ) -> HugoCompatibilityRenderResult {
        var issues: [String] = []
        let html = blocks.map { block in
            switch block {
            case .markdown(let value):
                return "<p>\(renderInline(value))</p>"
            case .heading(let level, let text):
                return "<h\(level)>\(escapeHTML(text))</h\(level)>"
            case .quote(let value):
                return "<blockquote>\(escapeHTML(value))</blockquote>"
            case .divider:
                return "<hr>"
            case .image(let alt, let path):
                guard let fileURL = previewAssetURL(
                    for: path,
                    bundleURL: bundleURL,
                    repositoryRoot: repositoryRoot,
                    configuration: configuration
                ), let resource = resourceURL(for: fileURL, repositoryRoot: repositoryRoot) else {
                    return #"<div class="gitsync-placeholder">Missing image: \#(escapeHTML(path))</div>"#
                }
                return #"<figure><img src="\#(resource)" alt="\#(escapeHTML(alt))"><figcaption>\#(escapeHTML(alt))</figcaption></figure>"#
            case .code(let language, let content):
                return #"<pre><code class="language-\#(escapeHTML(language))">\#(escapeHTML(content))</code></pre>"#
            case .table(let headers, let rows):
                let header = headers.map { "<th>\(escapeHTML($0))</th>" }.joined()
                let body = rows.map { row in
                    "<tr>\(row.map { "<td>\(escapeHTML($0))</td>" }.joined())</tr>"
                }.joined()
                return "<table><thead><tr>\(header)</tr></thead><tbody>\(body)</tbody></table>"
            case .shortcode(let source):
                let rendered = HugoTemplateCompatibilityService.renderShortcode(source) { reference in
                    previewAssetURL(
                        for: reference,
                        bundleURL: bundleURL,
                        repositoryRoot: repositoryRoot,
                        configuration: configuration
                    ).flatMap { resourceURL(for: $0, repositoryRoot: repositoryRoot) }
                }
                issues.append(contentsOf: rendered.issues)
                return rendered.html
            }
        }.joined(separator: "\n")
        return HugoCompatibilityRenderResult(html: html, issues: issues)
    }

    private static func discoverLayout(
        repositoryRoot: URL,
        configuration: HugoSiteConfiguration,
        layout: String,
        contentType: String
    ) -> (relativePath: String, template: String)? {
        let candidates = previewLayoutRoots(
            repositoryRoot: repositoryRoot,
            configuration: configuration
        ).flatMap { root in
            [
                root.appendingPathComponent("\(contentType)/\(layout).html"),
                root.appendingPathComponent("_default/\(layout).html"),
                root.appendingPathComponent("\(contentType)/single.html"),
                root.appendingPathComponent("_default/single.html")
            ]
        }
        for candidate in candidates {
            guard let relative = relativePath(for: candidate, repositoryRoot: repositoryRoot),
                  let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 1_048_576,
                  let template = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            return (relative, template)
        }
        return nil
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
                $0,
                repositoryRootURL: repositoryRoot
            )
        }
    }

    private static func articleSection(articleURL: URL, repositoryRoot: URL) -> String {
        guard let relative = relativePath(for: articleURL, repositoryRoot: repositoryRoot) else { return "" }
        let components = relative.split(separator: "/").map(String.init)
        guard components.first == "content", components.count > 2 else { return "" }
        return components[1]
    }

    private static func previewPermalink(
        section: String,
        articleURL: URL,
        title: String,
        params: [String: String],
        configuration: HugoSiteConfiguration
    ) -> String {
        let slug = params["slug"]?.nilIfEmpty
            ?? HugoContentService.slugify(title)
            .nilIfEmpty
            ?? articleURL.deletingLastPathComponent().lastPathComponent
        let pattern = configuration.permalinks[section] ?? "/\(section)/:slug/"
        return pattern
            .replacingOccurrences(of: ":slug", with: slug)
            .replacingOccurrences(of: ":section", with: section)
    }

    private static func renderInline(_ value: String) -> String {
        var escaped = escapeHTML(value).replacingOccurrences(of: "\n", with: "<br>")
        for (pattern, template) in [
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"(?<!\*)\*([^*]+)\*(?!\*)"#, "<em>$1</em>")
        ] {
            escaped = escaped.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return escaped
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
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
              ), values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        return "\(relative):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
