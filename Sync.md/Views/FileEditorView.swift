import SwiftUI

// MARK: - Navigation Destination

struct FileEditorDestination: Hashable {
    let repoID: UUID
    let fileURL: URL
}

// MARK: - View

private enum MarkdownEditorMode: String, CaseIterable, Identifiable {
    case source = "Source"
    case preview = "Preview"
    case properties = "Properties"
    var id: String { rawValue }
    var title: String { String(localized: String.LocalizationValue(rawValue)) }
}

struct FileEditorView: View {
    @Environment(AppState.self) private var state
    let repoID: UUID
    let fileURL: URL

    @Environment(\.dismiss) private var dismiss

    @State private var liveURL: URL
    @State private var content: String = ""
    @State private var originalContent: String = ""
    @State private var isBinary = false
    @State private var showDeleteConfirm = false
    @State private var showRenameModal = false
    @State private var renameText: String = ""
    @State private var showSaveToast = false
    @State private var editorMode: MarkdownEditorMode = .source
    @State private var frontMatter = MarkdownFrontMatter(markdown: "")

    init(repoID: UUID, fileURL: URL) {
        self.repoID = repoID
        self.fileURL = fileURL
        self._liveURL = State(initialValue: fileURL)
    }

    private var fileName: String { liveURL.lastPathComponent }
    private var pendingContent: String {
        isMarkdown && editorMode == .properties ? frontMatter.applying(to: content) : content
    }
    private var isDirty: Bool { pendingContent != originalContent }
    private var language: SyntaxLanguage { SyntaxLanguage.detect(fileExtension: liveURL.pathExtension) }
    private var isMarkdown: Bool { ["md", "markdown"].contains(liveURL.pathExtension.lowercased()) }

    var body: some View {
        ZStack {
            Color.brutalBg.ignoresSafeArea()

            if isBinary {
                binaryState
            } else {
                VStack(spacing: 0) {
                    if isMarkdown {
                        Picker("Editor mode", selection: $editorMode) {
                            ForEach(MarkdownEditorMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.brutalSurface)
                    }
                    editorContent
                }
            }

            if showDeleteConfirm {
                BConfirmModal(
                    title: "Delete \"\(fileName)\"?",
                    message: "This will be reflected in git status as a deletion.",
                    confirmLabel: "Delete",
                    isDestructive: true,
                    onConfirm: performDelete,
                    onCancel: { showDeleteConfirm = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if showRenameModal {
                BRenameModal(
                    title: "Rename File",
                    text: $renameText,
                    onConfirm: performRename,
                    onCancel: { showRenameModal = false; renameText = "" }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .overlay(alignment: .bottom) {
            Group {
                if showSaveToast {
                    BToast(message: "Saved", systemImage: "checkmark")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.15), value: showSaveToast)
        }
        .animation(.easeOut(duration: 0.15), value: showDeleteConfirm)
        .animation(.easeOut(duration: 0.15), value: showRenameModal)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(fileName.uppercased())
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.brutalText)
                    .tracking(2)
                    .lineLimit(1)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if !isBinary {
                        Button("Save") { performSave() }
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(isDirty ? Color.brutalAccent : Color.brutalTextFaint)
                            .disabled(!isDirty)
                    }
                    Button {
                        renameText = fileName
                        showRenameModal = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.brutalText)
                    }
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.brutalError)
                    }
                }
            }
        }
        .onAppear { loadContent() }
        .onChange(of: editorMode) { oldMode, newMode in
            if oldMode == .properties { content = frontMatter.applying(to: content) }
            if newMode == .properties { frontMatter = MarkdownFrontMatter(markdown: content) }
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        if !isMarkdown || editorMode == .source {
            CodeEditorView(text: $content, language: language)
                .padding(.horizontal, 8)
        } else if editorMode == .preview {
            let parsed = MarkdownFrontMatter(markdown: content)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !parsed.title.isEmpty {
                        Text(parsed.title)
                            .font(.system(size: 28, weight: .bold, design: .serif))
                            .foregroundStyle(Color.brutalText)
                    }
                    if let attributed = try? AttributedString(markdown: parsed.body) {
                        Text(attributed)
                            .font(.system(size: 17, design: .serif))
                            .foregroundStyle(Color.brutalText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(parsed.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(24)
            }
        } else {
            Form {
                Section("Front Matter") {
                    TextField("Title", text: $frontMatter.title)
                    TextField("Date", text: $frontMatter.date)
                        .textInputAutocapitalization(.never)
                    Toggle("Draft", isOn: $frontMatter.draft)
                    TextField("Tags (comma separated)", text: $frontMatter.tags)
                }
                Section("Body") {
                    TextEditor(text: $frontMatter.body)
                        .font(.system(size: 15, design: .serif))
                        .frame(minHeight: 320)
                }
                Section {
                    Text("Unrecognized Front Matter fields are preserved when saving.")
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.brutalTextFaint)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.brutalBg)
        }
    }

    // MARK: - Binary Fallback

    private var binaryState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("🔒")
                .font(.system(size: 44))
            Text("Binary File")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalText)
                .tracking(1)
            Text("This file cannot be edited as text")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.brutalTextFaint)
            Spacer()
        }
    }

    // MARK: - Operations

    private func loadContent() {
        guard let data = try? Data(contentsOf: liveURL),
              let text = String(data: data, encoding: .utf8) else {
            isBinary = true
            return
        }
        content = text
        originalContent = text
        if isMarkdown { frontMatter = MarkdownFrontMatter(markdown: text) }
    }

    private func performSave() {
        content = pendingContent
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        guard let data = content.data(using: .utf8) else { return }
        try? data.write(to: liveURL, options: .atomic)
        originalContent = content
        state.detectChanges(repoID: repoID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showSaveToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                showSaveToast = false
            }
        }
    }

    private func performDelete() {
        try? FileManager.default.removeItem(at: liveURL)
        state.detectChanges(repoID: repoID)
        dismiss()
    }

    private func performRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        showRenameModal = false
        renameText = ""
        guard !trimmed.isEmpty, trimmed != liveURL.lastPathComponent else { return }
        let dest = liveURL.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        do {
            try FileManager.default.moveItem(at: liveURL, to: dest)
            liveURL = dest
            state.detectChanges(repoID: repoID)
        } catch {}
    }
}
