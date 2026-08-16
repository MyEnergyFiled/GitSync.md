import Foundation
import UniformTypeIdentifiers

enum HugoPreviewStyle: String, CaseIterable, Identifiable {
    case native = "Native"
    case theme = "Theme"

    var id: String { rawValue }
    var title: String { String(localized: String.LocalizationValue(rawValue)) }
}

struct HugoThemePreviewPage: Equatable {
    let html: String
    let stylesheetPaths: [String]
    let resourceSignature: String
}

enum HugoThemePreviewService {
    static let resourceScheme = "gitsync-resource"
    private static let maximumStylesheets = 32
    private static let maximumStylesheetSize = 1_048_576

    static func render(
        markdown: String,
        articleURL: URL,
        repositoryRoot: URL,
        configuration: HugoSiteConfiguration
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
        let body = renderBlocks(
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
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline' \(resourceScheme):; img-src data: \(resourceScheme):; font-src \(resourceScheme):; media-src \(resourceScheme):; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
          \(stylesheetLinks)
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
        </head>
        <body>
          <article class="gitsync-page single">
            <header>
              <h1 class="gitsync-title">\(escapeHTML(title))</h1>
              <div class="gitsync-meta">\(metadata)</div>
              <ul class="gitsync-tags">\(tags)</ul>
              \(cover)
            </header>
            <main class="gitsync-content">\(body)</main>
          </article>
        </body>
        </html>
        """
        let relativePaths = stylesheets.compactMap {
            relativePath(for: $0, repositoryRoot: repositoryRoot)
        }
        return HugoThemePreviewPage(
            html: html,
            stylesheetPaths: relativePaths,
            resourceSignature: resourceSignature(for: stylesheets)
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
              let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
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

    private static func previewAssetURL(
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
    ) -> String {
        blocks.map { block in
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
                return #"<div class="gitsync-placeholder"><strong>Hugo shortcode</strong><br><code>\#(escapeHTML(source))</code></div>"#
            }
        }.joined(separator: "\n")
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

    private static func resourceSignature(for files: [URL]) -> String {
        files.map { fileURL in
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(fileURL.path):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
        }.joined(separator: "|")
    }
}
