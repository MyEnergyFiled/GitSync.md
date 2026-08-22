import SwiftUI
import UIKit

struct HugoArticleListDestination: Hashable {
    let repoID: UUID
}

struct HugoArticle: Identifiable {
    let fileURL: URL
    let relativePath: String
    let title: String
    let date: String
    let draft: Bool
    let coverURL: URL?
    let modifiedAt: Date
    var id: String { fileURL.path }
}

private enum HugoArticleFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case drafts = "Drafts"
    case published = "Published"
    var id: String { rawValue }
    var title: String { String(localized: String.LocalizationValue(rawValue)) }
}

enum HugoArticleSort: String, CaseIterable, Identifiable {
    case publicationDate = "Publication Date"
    case modified = "Modified Time"
    case title = "Title"
    case directory = "Directory"
    case draftStatus = "Draft Status"
    var id: String { rawValue }
    var label: String { String(localized: String.LocalizationValue(rawValue)) }

    func areInIncreasingOrder(_ lhs: HugoArticle, _ rhs: HugoArticle) -> Bool {
        switch self {
        case .publicationDate:
            let left = HugoContentService.publicationDate(from: lhs.date) ?? .distantPast
            let right = HugoContentService.publicationDate(from: rhs.date) ?? .distantPast
            if left != right { return left > right }
        case .modified:
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        case .title:
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .directory:
            let comparison = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .draftStatus:
            if lhs.draft != rhs.draft { return lhs.draft && !rhs.draft }
        }
        return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }
}

struct HugoArticleListView: View {
    @Environment(AppState.self) private var state
    let repoID: UUID

    @State private var articles: [HugoArticle] = []
    @State private var filter: HugoArticleFilter = .all
    @State private var sort: HugoArticleSort = .publicationDate
    @State private var query = ""
    @State private var errorMessage: String?
    @State private var showFrontMatterFields = false
    @State private var showSiteConfiguration = false
    @State private var articleToMove: HugoArticle?

    private var root: URL { state.vaultURL(for: repoID) }
    private var visibleArticles: [HugoArticle] {
        articles.filter { article in
            let matchesFilter = filter == .all || (filter == .drafts ? article.draft : !article.draft)
            let matchesQuery = query.isEmpty
                || article.title.localizedCaseInsensitiveContains(query)
                || article.relativePath.localizedCaseInsensitiveContains(query)
                || article.date.localizedCaseInsensitiveContains(query)
                || (article.draft ? String(localized: "Draft") : String(localized: "Published"))
                    .localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesQuery
        }.sorted(by: sort.areInIncreasingOrder)
    }

    var body: some View {
        Group {
            if articles.isEmpty {
                ContentUnavailableView(
                    "No Hugo Articles",
                    systemImage: "doc.richtext",
                    description: Text("Create content as an index.md leaf bundle to see it here.")
                )
            } else {
                List {
                    Picker("Article filter", selection: $filter) {
                        ForEach(HugoArticleFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.brutalSurface)

                    ForEach(visibleArticles) { article in
                        HStack(spacing: 10) {
                            NavigationLink(value: FileEditorDestination(repoID: repoID, fileURL: article.fileURL)) {
                                articleRow(article)
                            }
                            Button {
                                togglePublicationStatus(for: article)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text(article.draft ? String(localized: "Draft") : String(localized: "Published"))
                                }
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(article.draft ? Color.orange : Color.green)
                                .padding(.horizontal, 8)
                                .frame(height: 30)
                                .overlay { Rectangle().stroke(Color.brutalBorder, lineWidth: 1) }
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(
                                article.draft ? String(localized: "Draft") : String(localized: "Published")
                            ))
                            Menu {
                                Button {
                                    articleToMove = article
                                } label: {
                                    Label("Move or Rename", systemImage: "folder.badge.gearshape")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 30, height: 30)
                            }
                            .accessibilityLabel(Text("Article actions"))
                        }
                        .listRowBackground(Color.brutalBg)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.brutalBg)
        .navigationTitle("Articles")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search articles")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(HugoArticleSort.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    Divider()
                    Button {
                        showFrontMatterFields = true
                    } label: {
                        Label("Front Matter Fields", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        showSiteConfiguration = true
                    } label: {
                        Label("Site Configuration", systemImage: "gearshape.2")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .navigationDestination(for: FileEditorDestination.self) { destination in
            FileEditorView(repoID: destination.repoID, fileURL: destination.fileURL)
        }
        .onAppear(perform: loadArticles)
        .sheet(isPresented: $showFrontMatterFields) {
            HugoFrontMatterFieldsView(root: root) {
                state.detectChanges(repoID: repoID)
            }
        }
        .sheet(isPresented: $showSiteConfiguration) {
            HugoSiteConfigurationView(
                configuration: HugoSiteConfigurationService.discover(in: root)
            )
        }
        .sheet(item: $articleToMove) { article in
            HugoArticleMoveView(root: root, article: article) { _ in
                loadArticles()
                state.detectChanges(repoID: repoID)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func articleRow(_ article: HugoArticle) -> some View {
        HStack(spacing: 12) {
            cover(for: article)
            VStack(alignment: .leading, spacing: 5) {
                Text(article.title.isEmpty ? article.fileURL.deletingLastPathComponent().lastPathComponent : article.title)
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(Color.brutalText)
                    .lineLimit(2)
                Text(article.relativePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.brutalTextFaint)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(article.draft ? String(localized: "Draft") : String(localized: "Published"))
                        .foregroundStyle(article.draft ? Color.orange : Color.green)
                    if !article.date.isEmpty { Text(article.date) }
                }
                .font(.caption.monospaced())
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func cover(for article: HugoArticle) -> some View {
        if let url = article.coverURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipped()
        } else {
            Image(systemName: "doc.richtext")
                .foregroundStyle(Color.brutalTextFaint)
                .frame(width: 64, height: 64)
                .background(Color.brutalSurface)
        }
    }

    private func loadArticles() {
        articles = HugoContentService.articleIndexFiles(in: root).compactMap { url in
            guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let matter = MarkdownFrontMatter(markdown: markdown)
            let modifiedAt = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let coverURL = matter.cover.isEmpty
                ? nil
                : HugoContentService.localPreviewAssetURL(
                    for: matter.cover,
                    bundleURL: url.deletingLastPathComponent(),
                    repositoryRoot: root
                )
            return HugoArticle(
                fileURL: url,
                relativePath: relativePath,
                title: matter.title,
                date: matter.date,
                draft: matter.draft,
                coverURL: coverURL,
                modifiedAt: modifiedAt
            )
        }
    }

    private func togglePublicationStatus(for article: HugoArticle) {
        do {
            let fileURL = try HugoContentService.articleIndexURL(article.fileURL, in: root)
            let markdown = try String(contentsOf: fileURL, encoding: .utf8)
            let updated = HugoContentService.updatingDraftStatus(
                in: markdown,
                isDraft: !article.draft
            )
            try updated.write(to: fileURL, atomically: true, encoding: .utf8)
            loadArticles()
            state.detectChanges(repoID: repoID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct HugoArticleMoveView: View {
    @Environment(\.dismiss) private var dismiss
    let root: URL
    let article: HugoArticle
    let onMove: (HugoArticleMoveResult) -> Void

    @State private var targetDirectory: String
    @State private var bundleName: String
    @State private var errorMessage: String?

    init(root: URL, article: HugoArticle, onMove: @escaping (HugoArticleMoveResult) -> Void) {
        self.root = root
        self.article = article
        self.onMove = onMove
        let bundleURL = article.fileURL.deletingLastPathComponent()
        let parentPath = bundleURL.deletingLastPathComponent().path
            .replacingOccurrences(of: root.path + "/", with: "")
        _targetDirectory = State(initialValue: parentPath)
        _bundleName = State(initialValue: bundleURL.lastPathComponent)
    }

    private var availableDirectories: [String] {
        let configured = HugoContentService.loadConfiguration(from: root).contentMappings.map(\.directory)
        let current = article.fileURL.deletingLastPathComponent().deletingLastPathComponent().path
            .replacingOccurrences(of: root.path + "/", with: "")
        return Array(Set(HugoContentService.contentDirectories(in: root) + configured + [current]))
            .filter { HugoContentService.contentDirectoryURL(for: $0, in: root) != nil }
            .sorted()
    }

    private var destinationBundleURL: URL {
        root.appendingPathComponent(targetDirectory, isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true)
            .standardizedFileURL
    }

    private var sourceBundleURL: URL {
        article.fileURL.deletingLastPathComponent().standardizedFileURL
    }

    private var canMove: Bool {
        HugoContentService.isValidBundleName(bundleName)
            && !targetDirectory.isEmpty
            && destinationBundleURL != sourceBundleURL
            && !FileManager.default.fileExists(atPath: destinationBundleURL.path)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Content Directory", selection: $targetDirectory) {
                        ForEach(availableDirectories, id: \.self) { directory in
                            Text(directory).tag(directory)
                        }
                    }
                    TextField("Article Directory Name", text: $bundleName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Destination")
                } footer: {
                    Text("Use lowercase letters, numbers, and hyphens. Relative image paths outside the article bundle will be updated automatically.")
                }

                Section("New Path") {
                    Text(destinationBundleURL.path.replacingOccurrences(of: root.path + "/", with: ""))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                if destinationBundleURL == sourceBundleURL {
                    Section {
                        Label("Choose a different directory or name.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(Color.brutalTextFaint)
                    }
                } else if FileManager.default.fileExists(atPath: destinationBundleURL.path) {
                    Section {
                        Label("An article directory with this name already exists.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(Color.brutalError)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(Color.brutalError)
                    }
                }
            }
            .navigationTitle("Move or Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move", action: moveArticle)
                        .disabled(!canMove)
                }
            }
        }
    }

    private func moveArticle() {
        do {
            let result = try HugoContentService.moveArticleBundle(
                indexFileURL: article.fileURL,
                toContentDirectory: root.appendingPathComponent(targetDirectory, isDirectory: true),
                bundleName: bundleName,
                repositoryRoot: root
            )
            onMove(result)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
