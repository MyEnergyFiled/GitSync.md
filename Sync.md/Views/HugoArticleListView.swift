import SwiftUI
import UIKit

struct HugoArticleListDestination: Hashable {
    let repoID: UUID
}

private struct HugoArticle: Identifiable {
    let fileURL: URL
    let relativePath: String
    let title: String
    let date: String
    let draft: Bool
    let coverURL: URL?
    var id: String { fileURL.path }
}

private enum HugoArticleFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case drafts = "Drafts"
    case published = "Published"
    var id: String { rawValue }
    var title: String { String(localized: String.LocalizationValue(rawValue)) }
}

private enum HugoArticleSort: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case title = "Title"
    var id: String { rawValue }
    var label: String { String(localized: String.LocalizationValue(rawValue)) }
}

struct HugoArticleListView: View {
    @Environment(AppState.self) private var state
    let repoID: UUID

    @State private var articles: [HugoArticle] = []
    @State private var filter: HugoArticleFilter = .all
    @State private var sort: HugoArticleSort = .newest
    @State private var query = ""
    @State private var errorMessage: String?
    @State private var showFrontMatterFields = false

    private var root: URL { state.vaultURL(for: repoID) }
    private var visibleArticles: [HugoArticle] {
        articles.filter { article in
            let matchesFilter = filter == .all || (filter == .drafts ? article.draft : !article.draft)
            let matchesQuery = query.isEmpty
                || article.title.localizedCaseInsensitiveContains(query)
                || article.relativePath.localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesQuery
        }.sorted {
            sort == .title
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : $0.date > $1.date
        }
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
        let contentURL = root.appendingPathComponent("content", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: contentURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            articles = []
            return
        }

        articles = enumerator.compactMap { value -> HugoArticle? in
            guard let url = value as? URL,
                  url.lastPathComponent == "index.md",
                  let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let matter = MarkdownFrontMatter(markdown: markdown)
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let coverURL = matter.cover.isEmpty
                ? nil
                : url.deletingLastPathComponent().appendingPathComponent(matter.cover)
            return HugoArticle(
                fileURL: url,
                relativePath: relativePath,
                title: matter.title,
                date: matter.date,
                draft: matter.draft,
                coverURL: coverURL
            )
        }
    }

    private func togglePublicationStatus(for article: HugoArticle) {
        do {
            let markdown = try String(contentsOf: article.fileURL, encoding: .utf8)
            let updated = HugoContentService.updatingDraftStatus(
                in: markdown,
                isDraft: !article.draft
            )
            try updated.write(to: article.fileURL, atomically: true, encoding: .utf8)
            loadArticles()
            state.detectChanges(repoID: repoID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
