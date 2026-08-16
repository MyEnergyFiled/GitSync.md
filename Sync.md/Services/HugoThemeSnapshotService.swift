import Foundation

struct HugoThemeSemanticSnapshot: Equatable {
    let bodyText: String
    let elementCounts: [String: Int]
}

struct HugoThemeSnapshotComparison: Equatable {
    let preview: HugoThemeSemanticSnapshot
    let reference: HugoThemeSemanticSnapshot
    let mismatches: [String]

    var isMatch: Bool { mismatches.isEmpty }
}

enum HugoThemeSnapshotService {
    private static let comparedElements = [
        "h1", "h2", "h3", "p", "strong", "em", "blockquote", "pre", "code",
        "table", "thead", "tbody", "tr", "th", "td", "figure", "img", "figcaption"
    ]

    static func compare(previewHTML: String, referenceHugoHTML: String) -> HugoThemeSnapshotComparison {
        let preview = semanticSnapshot(from: previewHTML)
        let reference = semanticSnapshot(from: referenceHugoHTML)
        var mismatches: [String] = []
        if preview.bodyText != reference.bodyText {
            mismatches.append("body-text")
        }
        for element in comparedElements where preview.elementCounts[element] != reference.elementCounts[element] {
            mismatches.append("element-count:\(element)")
        }
        return HugoThemeSnapshotComparison(
            preview: preview,
            reference: reference,
            mismatches: mismatches
        )
    }

    static func semanticSnapshot(from html: String) -> HugoThemeSemanticSnapshot {
        let body = firstCapture(in: html, pattern: #"(?is)<body\b[^>]*>(.*?)</body\s*>"#) ?? html
        var text = body.replacingOccurrences(
            of: #"(?is)<(?:script|style)\b[^>]*>.*?</(?:script|style)\s*>"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, value) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'")
        ] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var counts: [String: Int] = [:]
        for element in comparedElements {
            let pattern = "(?i)<\(element)(?:\\s|/?>)"
            let regex = try? NSRegularExpression(pattern: pattern)
            counts[element] = regex?.numberOfMatches(
                in: body,
                range: NSRange(body.startIndex..., in: body)
            ) ?? 0
        }
        return HugoThemeSemanticSnapshot(bodyText: text, elementCounts: counts)
    }

    private static func firstCapture(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}
