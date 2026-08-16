import Foundation

struct HugoTemplatePreviewContext: Equatable {
    let title: String
    let date: String
    let draft: Bool
    let contentHTML: String
    let siteTitle: String
    let language: String
    let contentType: String
    let section: String
    let layout: String
    let permalink: String
    let params: [String: String]
}

struct HugoCompatibilityRenderResult: Equatable {
    let html: String
    let issues: [String]
}

enum HugoTemplateCompatibilityService {
    static func renderTemplate(
        _ template: String,
        context: HugoTemplatePreviewContext
    ) -> HugoCompatibilityRenderResult {
        let pattern = #"\{\{[-%]?\s*(.*?)\s*[-%]?\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return HugoCompatibilityRenderResult(html: template, issues: [])
        }
        var output = template
        var issues: [String] = []
        let matches = regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
        for match in matches.reversed() {
            guard let expressionRange = Range(match.range(at: 1), in: output),
                  let fullRange = Range(match.range(at: 0), in: output) else { continue }
            let expression = String(output[expressionRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement: String
            if expression.hasPrefix("define ") || expression == "end" {
                replacement = ""
            } else if let resolved = resolve(expression: expression, context: context) {
                replacement = resolved
            } else {
                let message = String(
                    format: String(localized: "Unsupported Hugo template expression: %@"),
                    expression
                )
                issues.append(message)
                replacement = placeholder(message, source: "{{ \(expression) }}")
            }
            output.replaceSubrange(fullRange, with: replacement)
        }
        let sanitized = sanitizeThemeHTML(output)
        if sanitized.removedUnsafeMarkup {
            issues.append(String(localized: "Unsafe theme markup was removed from the preview."))
        }
        return HugoCompatibilityRenderResult(html: sanitized.html, issues: Array(issues.reversed()))
    }

    static func renderShortcode(
        _ source: String,
        resourceResolver: (String) -> String?
    ) -> HugoCompatibilityRenderResult {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let inner = trimmed
            .replacingOccurrences(of: "{{<", with: "")
            .replacingOccurrences(of: ">}}", with: "")
            .replacingOccurrences(of: "{{%", with: "")
            .replacingOccurrences(of: "%}}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = inner.split(whereSeparator: \.isWhitespace).map(String.init)
        let name = components.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "shortcode"
        let attributes = shortcodeAttributes(in: inner)

        switch name.lowercased() {
        case "figure":
            let sourcePath = attributes["src"] ?? positionalValue(components, at: 1)
            guard let sourcePath, let resource = resourceResolver(sourcePath) else {
                let message = String(
                    format: String(localized: "Missing shortcode image: %@"),
                    sourcePath ?? "src"
                )
                return HugoCompatibilityRenderResult(
                    html: placeholder(message, source: source),
                    issues: [message]
                )
            }
            let alt = attributes["alt"] ?? attributes["title"] ?? ""
            let caption = attributes["caption"] ?? attributes["title"] ?? ""
            return HugoCompatibilityRenderResult(
                html: #"<figure class="gitsync-shortcode-figure"><img src="\#(resource)" alt="\#(escapeHTML(alt))"><figcaption>\#(escapeHTML(caption))</figcaption></figure>"#,
                issues: []
            )
        case "youtube", "vimeo":
            let identifier = positionalValue(components, at: 1) ?? attributes["id"] ?? ""
            let message = String(
                format: String(localized: "External %@ embed disabled in preview: %@"),
                name,
                identifier
            )
            return HugoCompatibilityRenderResult(html: placeholder(message, source: source), issues: [message])
        case "ref", "relref":
            let target = positionalValue(components, at: 1) ?? attributes["path"] ?? ""
            return HugoCompatibilityRenderResult(
                html: #"<span class="gitsync-placeholder">\#(escapeHTML(name)): \#(escapeHTML(target))</span>"#,
                issues: []
            )
        case "highlight":
            let language = positionalValue(components, at: 1) ?? "text"
            return HugoCompatibilityRenderResult(
                html: #"<pre class="gitsync-placeholder"><code>highlight: \#(escapeHTML(language))</code></pre>"#,
                issues: []
            )
        default:
            let message = String(
                format: String(localized: "Unsupported Hugo shortcode: %@"),
                name
            )
            return HugoCompatibilityRenderResult(html: placeholder(message, source: source), issues: [message])
        }
    }

    private static func resolve(
        expression: String,
        context: HugoTemplatePreviewContext
    ) -> String? {
        let value = expression.split(separator: "|", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? expression
        if value.hasPrefix(".Date.Format") { return escapeHTML(context.date) }
        if value.hasPrefix(".Params.") {
            let key = String(value.dropFirst(".Params.".count)).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            return context.params[key].map(escapeHTML)
        }
        switch value {
        case ".Title": return escapeHTML(context.title)
        case ".Content": return context.contentHTML
        case ".Date": return escapeHTML(context.date)
        case ".Draft": return context.draft ? "true" : "false"
        case ".Site.Title": return escapeHTML(context.siteTitle)
        case ".Site.Language.Lang", ".Language.Lang": return escapeHTML(context.language)
        case ".Type": return escapeHTML(context.contentType)
        case ".Section": return escapeHTML(context.section)
        case ".Layout": return escapeHTML(context.layout)
        case ".Permalink", ".RelPermalink": return escapeHTML(context.permalink)
        case ".WordCount": return String(context.contentHTML.split(whereSeparator: \.isWhitespace).count)
        case ".ReadingTime":
            let words = context.contentHTML.split(whereSeparator: \.isWhitespace).count
            return String(max(1, Int(ceil(Double(words) / 200.0))))
        case ".Summary":
            return String(context.contentHTML.prefix(280))
        default: return nil
        }
    }

    private static func shortcodeAttributes(in value: String) -> [String: String] {
        let pattern = #"([A-Za-z][A-Za-z0-9_-]*)\s*=\s*[\"']([^\"']*)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var result: [String: String] = [:]
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let keyRange = Range(match.range(at: 1), in: value),
                  let valueRange = Range(match.range(at: 2), in: value) else { continue }
            result[String(value[keyRange]).lowercased()] = String(value[valueRange])
        }
        return result
    }

    private static func positionalValue(_ components: [String], at index: Int) -> String? {
        guard components.indices.contains(index), !components[index].contains("=") else { return nil }
        return components[index].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func placeholder(_ message: String, source: String) -> String {
        #"<div class="gitsync-placeholder"><strong>\#(escapeHTML(message))</strong><br><code>\#(escapeHTML(source))</code></div>"#
    }

    private static func sanitizeThemeHTML(_ html: String) -> (html: String, removedUnsafeMarkup: Bool) {
        var output = html
        let original = html
        for pattern in [
            #"(?is)<script\b[^>]*>.*?</script\s*>"#,
            #"(?is)<(?:iframe|object|embed)\b[^>]*>.*?</(?:iframe|object|embed)\s*>"#,
            #"(?is)<(?:iframe|object|embed)\b[^>]*/?>"#,
            #"(?i)\s+on[a-z]+\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#
        ] {
            output = output.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        output = output.replacingOccurrences(
            of: #"(?i)javascript\s*:"#,
            with: "blocked:",
            options: .regularExpression
        )
        return (output, output != original)
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
