import SwiftUI
import UIKit

/// A UITextView-backed editor with debounced syntax highlighting.
struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let language: SyntaxLanguage
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.isEditable = true
        tv.isScrollEnabled = true
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coord = context.coordinator
        coord.parent = self

        let textChanged = uiView.text != text
        let schemeChanged = coord.lastColorScheme != colorScheme
        guard textChanged || schemeChanged else { return }

        coord.applyHighlighting(to: uiView, overrideText: textChanged ? text : nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        var lastColorScheme: ColorScheme = .light
        private var debounce: DispatchWorkItem?
        private var isApplyingHighlight = false

        init(_ parent: CodeEditorView) { self.parent = parent }

        // Called both on external text changes and after the debounce period.
        func applyHighlighting(to textView: UITextView, overrideText: String? = nil) {
            let content = overrideText ?? textView.text ?? ""
            let theme = parent.colorScheme == .dark ? SyntaxTheme.dark : SyntaxTheme.light
            let desiredSelection = overrideText == nil ? textView.selectedRange : parent.selection
            let offset = textView.contentOffset

            isApplyingHighlight = true
            textView.attributedText = SyntaxHighlighter.highlight(content, language: parent.language, theme: theme)
            textView.typingAttributes = [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: theme.plain
            ]

            let length = (textView.text ?? "").utf16.count
            let safeLoc = min(desiredSelection.location, length)
            let safeLen = min(desiredSelection.length, length - safeLoc)
            textView.selectedRange = NSRange(location: safeLoc, length: safeLen)
            textView.setContentOffset(offset, animated: false)
            parent.selection = textView.selectedRange
            isApplyingHighlight = false
            lastColorScheme = parent.colorScheme
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
            parent.selection = textView.selectedRange

            debounce?.cancel()
            let item = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyHighlighting(to: textView)
            }
            debounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingHighlight else { return }
            parent.selection = textView.selectedRange
        }
    }
}
