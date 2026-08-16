import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

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
    case split = "Split"
    var id: String { rawValue }
    var title: String { String(localized: String.LocalizationValue(rawValue)) }
}

struct FileEditorView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showImageImporter = false
    @State private var imageMessage: String?
    @State private var editorSelection = NSRange(location: 0, length: 0)
    @State private var images: [URL] = []
    @State private var showImageLibrary = false
    @State private var showDiscardConfirm = false
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var isDiscardingEdits = false
    @State private var pendingRecoveredDraft: String?
    @State private var showDraftRecovery = false
    @State private var showQuickPublish = false
    @State private var quickCommitMessage = ""
    @State private var isQuickPublishing = false
    @State private var publishValidation = HugoArticleValidation()
    @State private var canRetryPublish = false
    @State private var publishFailureMessage: String?
    @State private var showPublicationDateEditor = false
    @State private var publicationDateDraft = Date()
    @State private var persistenceMessage = String(localized: "File loaded")

    private let draftStore = FileEditorDraftStore()

    init(repoID: UUID, fileURL: URL) {
        self.repoID = repoID
        self.fileURL = fileURL
        self._liveURL = State(initialValue: fileURL)
    }

    private var fileName: String { liveURL.lastPathComponent }
    private var logRepoName: String? { state.repo(id: repoID)?.displayName }
    private var pendingContent: String {
        isMarkdown && editorMode == .properties ? frontMatter.applying(to: content) : content
    }
    private var isDirty: Bool { pendingContent != originalContent }
    private var canQuickPublish: Bool {
        isDirty || canRetryPublish
            || state.hasArticleBundleChanges(repoID: repoID, fileURL: liveURL)
            || state.syncStateByRepo[repoID] == .ahead
    }
    private var language: SyntaxLanguage { SyntaxLanguage.detect(fileExtension: liveURL.pathExtension) }
    private var isMarkdown: Bool { ["md", "markdown"].contains(liveURL.pathExtension.lowercased()) }
    private var isArticleBundle: Bool { isMarkdown && fileName.lowercased() == "index.md" }
    private var isArticleDraft: Bool {
        editorMode == .properties
            ? frontMatter.draft
            : MarkdownFrontMatter(markdown: content).draft
    }
    private var articleDateValue: String {
        editorMode == .properties
            ? frontMatter.date
            : MarkdownFrontMatter(markdown: content).date
    }

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
                    if isArticleBundle {
                        articlePublicationBar
                    }
                    editorContent
                }
            }

            if showDeleteConfirm {
                BConfirmModal(
                    title: String(localized: "Delete \"\(fileName)\"?"),
                    message: String(localized: "This will be reflected in git status as a deletion."),
                    confirmLabel: String(localized: "Delete"),
                    isDestructive: true,
                    onConfirm: performDelete,
                    onCancel: { showDeleteConfirm = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if showDiscardConfirm {
                BConfirmModal(
                    title: String(localized: "Discard Changes?"),
                    message: String(localized: "Your unsaved edits will be lost."),
                    confirmLabel: String(localized: "Discard"),
                    isDestructive: true,
                    onConfirm: {
                        showDiscardConfirm = false
                        isDiscardingEdits = true
                        draftSaveTask?.cancel()
                        try? draftStore.remove(repoID: repoID, fileURL: liveURL)
                        dismiss()
                    },
                    onCancel: { showDiscardConfirm = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if showDraftRecovery {
                ArticleDraftRecoveryModal(
                    onRestore: restorePendingDraft,
                    onUseFile: discardPendingDraft
                )
                .zIndex(30)
            }

            if showQuickPublish {
                ArticleQuickPublishModal(
                    message: $quickCommitMessage,
                    validation: publishValidation,
                    hasUnsavedChanges: isDirty,
                    canRetry: canRetryPublish,
                    failureMessage: publishFailureMessage,
                    isPublishing: isQuickPublishing,
                    progress: isQuickPublishing ? state.syncProgress : persistenceMessage,
                    onPublish: {
                        Task {
                            if canRetryPublish {
                                await retryQuickPublish()
                            } else {
                                await quickPublish()
                            }
                        }
                    },
                    onCancel: { if !isQuickPublishing { showQuickPublish = false } }
                )
                .zIndex(30)
            }

            if showRenameModal {
                BRenameModal(
                    title: String(localized: "Rename File"),
                    text: $renameText,
                    onConfirm: performRename,
                    onCancel: { showRenameModal = false; renameText = "" }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isBinary {
                VStack(spacing: 0) {
                    persistenceBar
                    if isMarkdown && editorMode == .source {
                        markdownFormattingBar
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            Group {
                if showSaveToast {
                    BToast(message: String(localized: "Saved"), systemImage: "checkmark")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.15), value: showSaveToast)
        }
        .animation(.easeOut(duration: 0.15), value: showDeleteConfirm)
        .animation(.easeOut(duration: 0.15), value: showRenameModal)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isDirty)
        .toolbar {
            if isDirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showDiscardConfirm = true } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                }
            }
            ToolbarItem(placement: .principal) {
                Text(fileName.uppercased())
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.brutalText)
                    .tracking(2)
                    .lineLimit(1)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if isMarkdown && !isBinary {
                        Menu {
                            Button {
                                showPhotoPicker = true
                            } label: {
                                Label("Choose from Photos", systemImage: "photo.on.rectangle")
                            }
                            Button {
                                showImageImporter = true
                            } label: {
                                Label("Choose Image File", systemImage: "folder")
                            }
                            Button {
                                loadImages()
                                showImageLibrary = true
                            } label: {
                                Label("Manage Images", systemImage: "photo.stack")
                            }
                        } label: {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.brutalText)
                        }
                    }
                    if !isBinary {
                        Button("Save") { _ = performSave() }
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
        .sheet(isPresented: $showImageLibrary) {
            HugoImageLibraryView(
                images: $images,
                isReferenced: { isImageReferenced($0.lastPathComponent) },
                onInsert: { insertMarkdownImage(named: $0.lastPathComponent) },
                onRename: renameImage,
                onReplace: replaceImage,
                onDelete: deleteImage
            )
        }
        .sheet(isPresented: $showPublicationDateEditor) {
            ArticlePublicationDateSheet(
                date: $publicationDateDraft,
                hasDate: !articleDateValue.isEmpty,
                onSave: {
                    updateArticlePublicationDate(publicationDateDraft)
                    showPublicationDateEditor = false
                },
                onClear: {
                    updateArticlePublicationDate(nil)
                    showPublicationDateEditor = false
                },
                onCancel: { showPublicationDateEditor = false }
            )
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .fileImporter(isPresented: $showImageImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let source) = result else { return }
            importImageFile(source)
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .alert("Error", isPresented: Binding(
            get: { imageMessage != nil },
            set: { if !$0 { imageMessage = nil } }
        )) {
            Button("OK", role: .cancel) { imageMessage = nil }
        } message: {
            Text(imageMessage ?? "")
        }
        .onAppear {
            loadContent()
            loadImages()
            state.detectChanges(repoID: repoID)
        }
        .onChange(of: pendingContent) { _, newValue in
            if canRetryPublish {
                canRetryPublish = false
                publishFailureMessage = nil
            }
            scheduleDraftSave(newValue)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveDraftImmediately() }
        }
        .onDisappear {
            draftSaveTask?.cancel()
            if !isDiscardingEdits { saveDraftImmediately() }
        }
        .onChange(of: editorMode) { oldMode, newMode in
            if oldMode == .properties { content = frontMatter.applying(to: content) }
            if newMode == .properties { frontMatter = MarkdownFrontMatter(markdown: content) }
        }
    }

    private var articlePublicationBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isArticleDraft ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            Text(isArticleDraft ? String(localized: "Draft") : String(localized: "Published"))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalText)
            Spacer()
            Button {
                publicationDateDraft = HugoContentService.publicationDate(from: articleDateValue) ?? Date()
                showPublicationDateEditor = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: articleDateValue.isEmpty ? "calendar.badge.plus" : "calendar")
                    if !articleDateValue.isEmpty {
                        Text(articleDateValue)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalTextMid)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Date")
            Picker("", selection: Binding(
                get: { isArticleDraft },
                set: updateArticleDraft
            )) {
                Text("Draft").tag(true)
                Text("Published").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .accessibilityLabel(Text(isArticleDraft ? String(localized: "Draft") : String(localized: "Published")))
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.brutalSurface)
        .overlay(alignment: .top) { Rectangle().fill(Color.brutalBorder).frame(height: 1) }
    }

    private func updateArticleDraft(_ isDraft: Bool) {
        if editorMode == .properties {
            frontMatter.draft = isDraft
        } else {
            content = HugoContentService.updatingDraftStatus(in: content, isDraft: isDraft)
        }
        persistenceMessage = isDraft ? String(localized: "Draft") : String(localized: "Published")
    }

    private func updateArticlePublicationDate(_ date: Date?) {
        if editorMode == .properties {
            frontMatter.date = date.map {
                HugoContentService.publicationDateValue(for: $0, preserving: frontMatter.date)
            } ?? ""
        } else {
            content = HugoContentService.updatingPublicationDate(in: content, date: date)
        }
        persistenceMessage = String(localized: "Date")
    }

    @ViewBuilder
    private var editorContent: some View {
        if !isMarkdown || editorMode == .source {
            CodeEditorView(text: $content, selection: $editorSelection, language: language)
                .padding(.horizontal, 8)
        } else if editorMode == .preview {
            markdownPreview
        } else if editorMode == .split {
            GeometryReader { geometry in
                if geometry.size.width >= 760 {
                    HStack(spacing: 0) {
                        CodeEditorView(text: $content, selection: $editorSelection, language: language)
                            .padding(.horizontal, 8)
                            .frame(width: geometry.size.width / 2)
                        Rectangle().fill(Color.brutalBorder).frame(width: 1)
                        markdownPreview
                    }
                } else {
                    VStack(spacing: 0) {
                        CodeEditorView(text: $content, selection: $editorSelection, language: language)
                            .padding(.horizontal, 8)
                        Rectangle().fill(Color.brutalBorder).frame(height: 1)
                        markdownPreview
                    }
                }
            }
        } else {
            Form {
                Section("Front Matter") {
                    TextField("Title", text: $frontMatter.title)
                    TextField("Date", text: $frontMatter.date)
                        .textInputAutocapitalization(.never)
                    Toggle("Draft", isOn: $frontMatter.draft)
                    TextField("Tags (comma separated)", text: $frontMatter.tags)
                    TextField("Cover image", text: $frontMatter.cover)
                        .textInputAutocapitalization(.never)
                    if !images.isEmpty {
                        Menu("Choose Cover Image") {
                            Button("No Cover") { frontMatter.cover = "" }
                            ForEach(images, id: \.path) { image in
                                Button(image.lastPathComponent) {
                                    frontMatter.cover = "images/\(image.lastPathComponent)"
                                }
                            }
                        }
                    }
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

    private var markdownPreview: some View {
        let parsed = MarkdownFrontMatter(markdown: content)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !parsed.title.isEmpty {
                    Text(parsed.title)
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.brutalText)
                }
                HugoMarkdownPreview(markdownBody: parsed.body, bundleURL: liveURL.deletingLastPathComponent())
            }
            .padding(24)
        }
    }

    private var persistenceBar: some View {
        HStack(spacing: 10) {
            if isQuickPublishing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: isDirty ? "doc.badge.clock" : "checkmark.circle")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text((isQuickPublishing ? state.syncProgress : persistenceMessage).uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalTextMid)
                .lineLimit(1)
            Spacer()
            if isMarkdown && fileName.lowercased() == "index.md" && state.repo(id: repoID)?.isCloned == true {
                Button {
                    prepareQuickPublish()
                } label: {
                    Text(String(localized: "Save, Commit & Push").uppercased())
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(canQuickPublish ? Color.brutalAccent : Color.brutalTextFaint)
                }
                .buttonStyle(.plain)
                .disabled(isQuickPublishing || !canQuickPublish)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color.brutalSurface)
        .overlay(alignment: .top) { Rectangle().fill(Color.brutalBorder).frame(height: 1) }
    }

    private var markdownFormattingBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                formattingButton("↶") { UIApplication.shared.sendAction(Selector(("undo:")), to: nil, from: nil, for: nil) }
                formattingButton("↷") { UIApplication.shared.sendAction(Selector(("redo:")), to: nil, from: nil, for: nil) }
                formattingButton("H1") { applyMarkdown(prefix: "# ", placeholder: "Heading") }
                formattingButton("B") { applyMarkdown(prefix: "**", suffix: "**", placeholder: "bold") }
                formattingButton("I") { applyMarkdown(prefix: "*", suffix: "*", placeholder: "italic") }
                formattingButton("LINK") { applyMarkdown(prefix: "[", suffix: "](https://)", placeholder: "text") }
                formattingButton("CODE") { applyMarkdown(prefix: "`", suffix: "`", placeholder: "code") }
                formattingButton("QUOTE") { applyMarkdown(prefix: "> ", placeholder: "Quote") }
                formattingButton("LIST") { applyMarkdown(prefix: "- ", placeholder: "Item") }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.brutalSurface)
        .overlay(alignment: .top) { Rectangle().fill(Color.brutalBorder).frame(height: 1) }
    }

    private func formattingButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.brutalText)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.brutalBg)
            .overlay { Rectangle().stroke(Color.brutalBorder, lineWidth: 1) }
    }

    private func applyMarkdown(prefix: String, suffix: String = "", placeholder: String) {
        let source = content as NSString
        let location = min(editorSelection.location, source.length)
        let length = min(editorSelection.length, source.length - location)
        let selected = length > 0 ? source.substring(with: NSRange(location: location, length: length)) : placeholder
        let insertion = prefix + selected + suffix
        content = source.replacingCharacters(in: NSRange(location: location, length: length), with: insertion)
        let selectedLocation = location + (prefix as NSString).length
        editorSelection = NSRange(location: selectedLocation, length: (selected as NSString).length)
    }

    private func appendMarkdown(_ insertion: String) {
        let source = content as NSString
        let location = min(editorSelection.location, source.length)
        let length = min(editorSelection.length, source.length - location)
        content = source.replacingCharacters(in: NSRange(location: location, length: length), with: insertion)
        editorSelection = NSRange(location: location + (insertion as NSString).length, length: 0)
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
        if let draft = draftStore.draft(repoID: repoID, fileURL: liveURL), draft.content != text {
            pendingRecoveredDraft = draft.content
            showDraftRecovery = true
            persistenceMessage = String(localized: "Unsaved draft found")
        } else {
            try? draftStore.remove(repoID: repoID, fileURL: liveURL)
            persistenceMessage = String(localized: "File loaded")
        }
        if isMarkdown { frontMatter = MarkdownFrontMatter(markdown: content) }
    }

    private func restorePendingDraft() {
        guard let draft = pendingRecoveredDraft else { return }
        content = draft
        if isMarkdown { frontMatter = MarkdownFrontMatter(markdown: draft) }
        pendingRecoveredDraft = nil
        showDraftRecovery = false
        persistenceMessage = String(localized: "Recovered unsaved draft")
        DebugLogger.shared.info(
            "editor", "Recovered unsaved draft", detail: fileName,
            repoID: repoID, repoName: logRepoName
        )
    }

    private func discardPendingDraft() {
        pendingRecoveredDraft = nil
        showDraftRecovery = false
        try? draftStore.remove(repoID: repoID, fileURL: liveURL)
        persistenceMessage = String(localized: "Using saved file")
        DebugLogger.shared.info(
            "editor", "Discarded recovered draft", detail: fileName,
            repoID: repoID, repoName: logRepoName
        )
    }

    private func scheduleDraftSave(_ value: String) {
        draftSaveTask?.cancel()
        guard value != originalContent else {
            try? draftStore.remove(repoID: repoID, fileURL: liveURL)
            return
        }
        persistenceMessage = String(localized: "Saving draft…")
        let targetURL = liveURL
        draftSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            do {
                try draftStore.save(content: value, repoID: repoID, fileURL: targetURL)
                persistenceMessage = String(localized: "Draft saved locally")
            } catch {
                persistenceMessage = String(localized: "Draft save failed")
                DebugLogger.shared.error(
                    "editor", "Draft save failed", detail: error.localizedDescription,
                    repoID: repoID, repoName: logRepoName
                )
            }
        }
    }

    private func saveDraftImmediately() {
        guard isDirty else { return }
        do {
            try draftStore.save(content: pendingContent, repoID: repoID, fileURL: liveURL)
        } catch {
            persistenceMessage = String(localized: "Draft save failed")
            DebugLogger.shared.error(
                "editor", "Immediate draft save failed", detail: error.localizedDescription,
                repoID: repoID, repoName: logRepoName
            )
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run {
                selectedPhoto = nil
                imageMessage = String(localized: "Could not read the selected image.")
            }
            return
        }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        await MainActor.run {
            selectedPhoto = nil
            storeImage(data: data, preferredName: "image.\(ext)")
        }
    }

    private func importImageFile(_ source: URL) {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: source) else {
            imageMessage = String(localized: "Could not read the selected image.")
            return
        }
        storeImage(data: data, preferredName: source.lastPathComponent)
    }

    private func storeImage(data: Data, preferredName: String) {
        let directory = liveURL.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: preferredName)
            let stem = HugoContentService.slugify(source.deletingPathExtension().lastPathComponent)
            let base = stem.isEmpty ? "image" : stem
            let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
            var destination = directory.appendingPathComponent("\(base).\(ext)")
            var suffix = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = directory.appendingPathComponent("\(base)-\(suffix).\(ext)")
                suffix += 1
            }
            try data.write(to: destination, options: .atomic)
            invalidatePublishRetry()
            loadImages()
            insertMarkdownImage(named: destination.lastPathComponent)
            state.detectChanges(repoID: repoID)
            imageMessage = String(localized: "Image added to images/ and inserted into Markdown.")
        } catch {
            imageMessage = error.localizedDescription
        }
    }

    private func insertMarkdownImage(named name: String) {
        let markdown = "![\(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent)](images/\(name))"
        if editorMode == .properties {
            frontMatter.body += (frontMatter.body.isEmpty ? "" : "\n\n") + markdown
        } else if editorMode == .source || editorMode == .split {
            appendMarkdown(markdown)
        } else {
            let end = (content as NSString).length
            editorSelection = NSRange(location: end, length: 0)
            editorMode = .source
            appendMarkdown((content.hasSuffix("\n") ? "" : "\n") + markdown)
        }
    }

    private var imageDirectory: URL {
        liveURL.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
    }

    private func loadImages() {
        images = ((try? FileManager.default.contentsOfDirectory(
            at: imageDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []).filter(HugoContentService.isSupportedArticleImage)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func isImageReferenced(_ name: String) -> Bool {
        content.contains("images/\(name)") || frontMatter.body.contains("images/\(name)")
    }

    private func renameImage(_ image: URL, _ requestedName: String) {
        let raw = URL(fileURLWithPath: requestedName)
        let ext = raw.pathExtension.isEmpty ? image.pathExtension : raw.pathExtension.lowercased()
        let stem = HugoContentService.slugify(raw.deletingPathExtension().lastPathComponent)
        guard !stem.isEmpty else { return }
        let destination = imageDirectory.appendingPathComponent("\(stem).\(ext)")
        guard destination != image, !FileManager.default.fileExists(atPath: destination.path) else { return }
        do {
            try FileManager.default.moveItem(at: image, to: destination)
            invalidatePublishRetry()
            replaceImageReference(from: image.lastPathComponent, to: destination.lastPathComponent)
            loadImages()
            state.detectChanges(repoID: repoID)
        } catch { imageMessage = error.localizedDescription }
    }

    private func replaceImage(_ image: URL, _ source: URL) {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: source)
            let sourceExtension = source.pathExtension.lowercased()
            let destination = sourceExtension.isEmpty || sourceExtension == image.pathExtension.lowercased()
                ? image
                : image.deletingPathExtension().appendingPathExtension(sourceExtension)
            try data.write(to: destination, options: .atomic)
            invalidatePublishRetry()
            if destination != image {
                try FileManager.default.removeItem(at: image)
                replaceImageReference(from: image.lastPathComponent, to: destination.lastPathComponent)
            }
            loadImages()
            state.detectChanges(repoID: repoID)
        } catch { imageMessage = error.localizedDescription }
    }

    private func deleteImage(_ image: URL) {
        do {
            try FileManager.default.removeItem(at: image)
            invalidatePublishRetry()
            loadImages()
            state.detectChanges(repoID: repoID)
        } catch { imageMessage = error.localizedDescription }
    }

    private func replaceImageReference(from oldName: String, to newName: String) {
        content = content.replacingOccurrences(of: "images/\(oldName)", with: "images/\(newName)")
        frontMatter.body = frontMatter.body.replacingOccurrences(of: "images/\(oldName)", with: "images/\(newName)")
    }

    private func invalidatePublishRetry() {
        canRetryPublish = false
        publishFailureMessage = nil
    }

    @discardableResult
    private func performSave(operationID: String? = nil, removeDraft: Bool = true) -> Bool {
        content = pendingContent
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        guard let data = content.data(using: .utf8) else { return false }
        do {
            try data.write(to: liveURL, options: .atomic)
            originalContent = content
            draftSaveTask?.cancel()
            if removeDraft {
                try? draftStore.remove(repoID: repoID, fileURL: liveURL)
            } else {
                try? draftStore.save(content: content, repoID: repoID, fileURL: liveURL)
            }
            state.detectChanges(repoID: repoID)
            persistenceMessage = String(localized: "File saved · not committed")
            DebugLogger.shared.info(
                "editor", "File saved", detail: fileName,
                repoID: repoID, repoName: logRepoName, operationID: operationID
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                showSaveToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    showSaveToast = false
                }
            }
            return true
        } catch {
            imageMessage = error.localizedDescription
            persistenceMessage = String(localized: "Save failed · draft preserved")
            DebugLogger.shared.error(
                "editor", "File save failed", detail: error.localizedDescription,
                repoID: repoID, repoName: logRepoName, operationID: operationID
            )
            saveDraftImmediately()
            return false
        }
    }

    private func prepareQuickPublish() {
        publishValidation = HugoContentService.validateArticleBundle(
            markdown: pendingContent,
            fileURL: liveURL
        )
        if !isDirty,
           !state.hasArticleBundleChanges(repoID: repoID, fileURL: liveURL),
           state.syncStateByRepo[repoID] == .ahead {
            canRetryPublish = true
            publishFailureMessage = String(localized: "A local commit is waiting to be pushed.")
        }
        showQuickPublish = true
    }

    private func quickPublish() async {
        guard !isQuickPublishing else { return }
        let operationID = String(UUID().uuidString.prefix(8)).lowercased()
        DebugLogger.shared.info(
            "publish", "Starting article publish", detail: fileName,
            repoID: repoID, repoName: logRepoName, operationID: operationID
        )
        let validation = HugoContentService.validateArticleBundle(
            markdown: pendingContent,
            fileURL: liveURL
        )
        publishValidation = validation
        guard validation.isValid else {
            persistenceMessage = String(localized: "Publish blocked · check article")
            DebugLogger.shared.warning(
                "publish", "Publish blocked by article validation",
                detail: "\(validation.frontMatterIssues.count) Front Matter issues, \(validation.missingImagePaths.count) missing images",
                repoID: repoID, repoName: logRepoName, operationID: operationID
            )
            return
        }
        guard performSave(operationID: operationID, removeDraft: false) else { return }
        isQuickPublishing = true
        persistenceMessage = String(localized: "Saving file…")

        let staged = await state.stageArticleBundle(repoID: repoID, fileURL: liveURL, operationID: operationID)
        guard staged else {
            isQuickPublishing = false
            persistenceMessage = String(localized: "No article changes to commit")
            try? draftStore.remove(repoID: repoID, fileURL: liveURL)
            return
        }

        persistenceMessage = String(localized: "Article staged · pushing…")
        let pushed = await state.push(repoID: repoID, message: quickCommitMessage, operationID: operationID)
        isQuickPublishing = false
        if pushed {
            finishSuccessfulPublish()
        } else {
            preserveFailedPublish()
        }
    }

    private func retryQuickPublish() async {
        guard !isQuickPublishing else { return }
        let operationID = String(UUID().uuidString.prefix(8)).lowercased()
        isQuickPublishing = true
        persistenceMessage = String(localized: "Retrying push…")
        let pushed = await state.retryPush(
            repoID: repoID,
            message: quickCommitMessage,
            operationID: operationID
        )
        isQuickPublishing = false
        if pushed {
            finishSuccessfulPublish()
        } else {
            preserveFailedPublish()
        }
    }

    private func preserveFailedPublish() {
        try? draftStore.save(content: content, repoID: repoID, fileURL: liveURL)
        canRetryPublish = true
        publishFailureMessage = state.lastError ?? String(localized: "Push failed · file remains saved")
        persistenceMessage = String(localized: "Push failed · retry available")
    }

    private func finishSuccessfulPublish() {
        try? draftStore.remove(repoID: repoID, fileURL: liveURL)
        canRetryPublish = false
        publishFailureMessage = nil
        quickCommitMessage = ""
        showQuickPublish = false
        persistenceMessage = String(localized: "Pushed to GitHub")
    }

    private func performDelete() {
        try? draftStore.remove(repoID: repoID, fileURL: liveURL)
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
            let previousURL = liveURL
            try FileManager.default.moveItem(at: previousURL, to: dest)
            invalidatePublishRetry()
            if isDirty {
                try? draftStore.save(content: pendingContent, repoID: repoID, fileURL: dest)
            }
            try? draftStore.remove(repoID: repoID, fileURL: previousURL)
            liveURL = dest
            state.detectChanges(repoID: repoID)
        } catch {}
    }
}



private struct ArticlePublicationDateSheet: View {
    @Binding var date: Date
    let hasDate: Bool
    let onSave: () -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Date",
                    selection: $date,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)

                if hasDate {
                    Button("Clear Date", role: .destructive, action: onClear)
                }
            }
            .navigationTitle("Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ArticleDraftRecoveryModal: View {
    let onRestore: () -> Void
    let onUseFile: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Unsaved Draft Found").uppercased())
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .tracking(2)
                    Text(String(localized: "GitSync.md preserved newer editor text. Restore it or use the version currently saved in the repository."))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.brutalTextMid)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                BDivider()
                VStack(spacing: 8) {
                    BPrimaryButton(title: String(localized: "Restore Draft"), action: onRestore)
                    BGhostButton(title: String(localized: "Use Saved File"), action: onUseFile)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .padding(16)
            }
            .background(Color.brutalBg)
            .overlay(Rectangle().strokeBorder(Color.brutalBorder, lineWidth: 2))
            .padding(.horizontal, 28)
        }
    }
}

private struct ArticleQuickPublishModal: View {
    @Binding var message: String
    let validation: HugoArticleValidation
    let hasUnsavedChanges: Bool
    let canRetry: Bool
    let failureMessage: String?
    let isPublishing: Bool
    let progress: String
    let onPublish: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { onCancel() }
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Save, Commit & Push").uppercased())
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .tracking(2)
                    Text(String(localized: "This saves and stages the current article bundle. Any files already staged in Git will also be included."))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.brutalTextMid)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                BDivider()
                if let failureMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Push failed · retry available"))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.brutalError)
                        Text(failureMessage)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.brutalTextMid)
                        Text(String(localized: "Your content and publish selection remain local. Retry will not create a duplicate commit."))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.brutalTextMid)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    BDivider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        validationRow(
                            title: String(localized: "Front Matter"),
                            items: validation.frontMatterIssues.map(frontMatterIssueText),
                            color: validation.frontMatterIssues.isEmpty ? .green : Color.brutalError,
                            isPassed: validation.frontMatterIssues.isEmpty
                        )
                        validationRow(
                            title: String(localized: "Missing image files:"),
                            items: validation.missingImagePaths,
                            color: validation.missingImagePaths.isEmpty ? .green : Color.brutalError,
                            isPassed: validation.missingImagePaths.isEmpty
                        )
                        if !validation.oversizedImageNames.isEmpty {
                            validationRow(
                                title: String(localized: "These images exceed 10 MB and may take longer to push:"),
                                items: validation.oversizedImageNames,
                                color: .orange,
                                isPassed: false
                            )
                        }
                        if hasUnsavedChanges {
                            validationRow(
                                title: String(localized: "Unsaved editor changes will be saved before publishing."),
                                items: [],
                                color: .orange,
                                isPassed: false
                            )
                        }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 260)
                BDivider()
                TextField(String(localized: "Commit message…"), text: $message, axis: .vertical)
                    .font(.system(size: 14, design: .monospaced))
                    .lineLimit(1...3)
                    .padding(14)
                    .disabled(isPublishing)
                if isPublishing {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(progress)
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                VStack(spacing: 8) {
                    BPrimaryButton(
                        title: canRetry ? String(localized: "Retry Push") : String(localized: "Save, Commit & Push"),
                        action: onPublish
                    )
                        .disabled(isPublishing || !validation.isValid)
                    BGhostButton(title: String(localized: "Cancel"), action: onCancel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .disabled(isPublishing)
                }
                .padding(16)
            }
            .background(Color.brutalBg)
            .overlay(Rectangle().strokeBorder(Color.brutalBorder, lineWidth: 2))
            .padding(.horizontal, 28)
        }
    }

    private func frontMatterIssueText(_ issue: HugoFrontMatterIssue) -> String {
        switch issue {
        case .missingOrIncomplete:
            return String(localized: "Front Matter is missing or incomplete.")
        case .missingTitle:
            return String(localized: "Title is missing.")
        case .invalidDate:
            return String(localized: "Publication date format is not recognized.")
        }
    }

    private func validationRow(title: String, items: [String], color: Color, isPassed: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isPassed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.brutalText)
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.brutalTextMid)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HugoMarkdownPreview: View {
    let markdownBody: String
    let bundleURL: URL

    var bodyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(markdownBody.components(separatedBy: .newlines).enumerated()), id: \.offset) { item in
                let line = item.element
                if let image = localImage(from: line) {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(uiImage: image.value)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !image.alt.isEmpty {
                            Text(image.alt)
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.brutalTextFaint)
                        }
                    }
                } else if line.isEmpty {
                    Color.clear.frame(height: 6)
                } else if let attributed = try? AttributedString(markdown: line) {
                    Text(attributed)
                        .font(.system(size: 17, design: .serif))
                        .foregroundStyle(Color.brutalText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(line)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    var body: some View { bodyView }

    private func localImage(from line: String) -> (value: UIImage, alt: String)? {
        let pattern = #"^!\[([^]]*)\]\((images/[^)]+)\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.range.location != NSNotFound,
              let altRange = Range(match.range(at: 1), in: line),
              let pathRange = Range(match.range(at: 2), in: line) else { return nil }
        let path = String(line[pathRange]).removingPercentEncoding ?? String(line[pathRange])
        guard !path.contains("..") else { return nil }
        let url = bundleURL.appendingPathComponent(path)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return (image, String(line[altRange]))
    }
}

private struct HugoImageLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var images: [URL]
    let isReferenced: (URL) -> Bool
    let onInsert: (URL) -> Void
    let onRename: (URL, String) -> Void
    let onReplace: (URL, URL) -> Void
    let onDelete: (URL) -> Void

    @State private var renameTarget: URL?
    @State private var renameName = ""
    @State private var deleteTarget: URL?
    @State private var replaceTarget: URL?
    @State private var showReplacementImporter = false

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if images.isEmpty {
                    ContentUnavailableView(
                        "No Images",
                        systemImage: "photo.stack",
                        description: Text("Import an image from the editor toolbar first.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(images, id: \.path) { image in
                                imageCard(image)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(Color.brutalBg)
            .navigationTitle("Images")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Rename Image", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("image-name.jpg", text: $renameName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Rename") {
                if let target = renameTarget { onRename(target, renameName) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Use an English file name. Markdown references will be updated automatically.")
        }
        .alert("Delete Image?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget { onDelete(target) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            if let target = deleteTarget, isReferenced(target) {
                Text("This image is referenced by the article. Deleting it will leave a broken Markdown link.")
            } else {
                Text("This removes the image from the article bundle.")
            }
        }
        .fileImporter(isPresented: $showReplacementImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let source) = result, let target = replaceTarget else { return }
            onReplace(target, source)
            replaceTarget = nil
        }
    }

    private func imageCard(_ imageURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let value = UIImage(contentsOfFile: imageURL.path) {
                    Image(uiImage: value)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.brutalTextFaint)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .clipped()
            .background(Color.brutalSurface)

            Text(imageURL.lastPathComponent)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.brutalText)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Button {
                    onInsert(imageURL)
                    dismiss()
                } label: {
                    Label("Insert", systemImage: "plus.square.on.square")
                }
                Spacer()
                Menu {
                    Button {
                        renameTarget = imageURL
                        renameName = imageURL.lastPathComponent
                    } label: { Label("Rename", systemImage: "pencil") }
                    Button {
                        replaceTarget = imageURL
                        showReplacementImporter = true
                    } label: { Label("Replace", systemImage: "arrow.triangle.2.circlepath") }
                    Button(role: .destructive) {
                        deleteTarget = imageURL
                    } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .padding(10)
        .background(Color.brutalSurface)
        .overlay { Rectangle().stroke(Color.brutalBorder, lineWidth: 1) }
    }
}
