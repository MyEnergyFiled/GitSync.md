import Foundation
import XCTest
@testable import Sync_md

final class HugoContentServiceTests: XCTestCase {
    func testArticlePreviewDocumentParsesCommonFrontMatterAndBody() {
        let markdown = """
        ---
        title: "Preview Title"
        date: 2026-08-16
        draft: false
        tags: [swift, "iOS"]
        cover: "images/cover.jpg"
        ---

        Preview body.
        """

        let document = HugoArticlePreviewDocument(markdown: markdown)

        XCTAssertEqual(document.title, "Preview Title")
        XCTAssertEqual(document.date, "2026-08-16")
        XCTAssertFalse(document.draft)
        XCTAssertEqual(document.tags, ["swift", "iOS"])
        XCTAssertEqual(document.cover, "images/cover.jpg")
        XCTAssertEqual(document.body, "Preview body.")
    }

    func testArticlePreviewSnapshotUsesCurrentContentAndMarksUnsavedChanges() {
        let saved = "---\ntitle: \"Saved\"\n---\n\nOld body"
        let current = "---\ntitle: \"Current\"\n---\n\nLive body"

        let dirty = HugoArticlePreviewSnapshot(markdown: current, savedMarkdown: saved)
        let clean = HugoArticlePreviewSnapshot(markdown: saved, savedMarkdown: saved)

        XCTAssertEqual(dirty.document.title, "Current")
        XCTAssertEqual(dirty.document.body, "Live body")
        XCTAssertTrue(dirty.hasUnsavedChanges)
        XCTAssertFalse(clean.hasUnsavedChanges)
    }

    func testPreviewParserRecognizesImagesCodeTablesAndShortcodes() {
        let markdown = """
        Intro with [link](../about.md).

        ![Cover](images/cover.jpg)

        ```swift
        let answer = 42
        ```

        | Name | Value |
        | --- | ---: |
        | answer | 42 |

        {{< figure src="images/photo.jpg" >}}
        """

        let blocks = HugoPreviewParser.blocks(from: markdown)

        XCTAssertEqual(blocks, [
            .markdown("Intro with [link](../about.md)."),
            .image(alt: "Cover", path: "images/cover.jpg"),
            .code(language: "swift", content: "let answer = 42"),
            .table(headers: ["Name", "Value"], rows: [["answer", "42"]]),
            .shortcode(#"{{< figure src="images/photo.jpg" >}}"#)
        ])
    }

    func testPreviewParserRecognizesPaperStyleHeadingsQuotesAndDividers() {
        let markdown = """
        # Main Heading

        > A quoted thought

        ---

        ## Section
        """

        XCTAssertEqual(HugoPreviewParser.blocks(from: markdown), [
            .heading(level: 1, text: "Main Heading"),
            .quote("A quoted thought"),
            .divider,
            .heading(level: 2, text: "Section")
        ])
    }

    func testPreviewAssetResolutionAllowsRepositoryRelativePathsAndRejectsEscapes() {
        let root = URL(fileURLWithPath: "/repo", isDirectory: true)
        let bundle = root.appendingPathComponent("content/posts/example", isDirectory: true)

        XCTAssertEqual(
            HugoContentService.localPreviewAssetURL(
                for: "images/cover%20photo.jpg?size=large#hero",
                bundleURL: bundle,
                repositoryRoot: root
            )?.path,
            "/repo/content/posts/example/images/cover photo.jpg"
        )
        XCTAssertEqual(
            HugoContentService.localPreviewAssetURL(
                for: "../../../static/shared.jpg",
                bundleURL: bundle,
                repositoryRoot: root
            )?.path,
            "/repo/static/shared.jpg"
        )
        XCTAssertNil(HugoContentService.localPreviewAssetURL(
            for: "../../../../outside.jpg",
            bundleURL: bundle,
            repositoryRoot: root
        ))
        XCTAssertNil(HugoContentService.localPreviewAssetURL(
            for: "https://example.com/image.jpg",
            bundleURL: bundle,
            repositoryRoot: root
        ))
    }

    func testPreviewAssetResolutionRejectsSymlinkOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let bundle = repositoryRoot.appendingPathComponent("content/post", isDirectory: true)
        let outsideImages = temporaryRoot.appendingPathComponent("outside-images", isDirectory: true)
        let linkedImages = bundle.appendingPathComponent("images", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideImages, withIntermediateDirectories: true)
        try Data([0x01]).write(to: outsideImages.appendingPathComponent("cover.png"))
        try fileManager.createSymbolicLink(at: linkedImages, withDestinationURL: outsideImages)

        XCTAssertNil(HugoContentService.localPreviewAssetURL(
            for: "images/cover.png",
            bundleURL: bundle,
            repositoryRoot: repositoryRoot
        ))
    }

    func testThemePreviewLoadsRepositoryStylesheetsAndImagesThroughIsolatedScheme() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let themeCSS = root.appendingPathComponent("themes/paper/assets/css/main.css")
        let bundle = root.appendingPathComponent("content/posts/example", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: themeCSS.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bundle.appendingPathComponent("images"), withIntermediateDirectories: true)
        try "article { color: maroon; }".write(to: themeCSS, atomically: true, encoding: .utf8)
        try Data([0x01, 0x02]).write(to: bundle.appendingPathComponent("images/cover.png"))
        let markdown = """
        ---
        title: "Theme <Preview>"
        cover: images/cover.png
        ---

        # Hello

        ![Cover](images/cover.png)
        """

        let page = HugoThemePreviewService.render(
            markdown: markdown,
            articleURL: bundle.appendingPathComponent("index.md"),
            repositoryRoot: root,
            configuration: HugoSiteConfiguration(
                configurationFiles: ["hugo.toml"],
                themes: ["paper"],
                assetDirectories: ["assets"],
                staticDirectories: ["static"],
                resourceDirectories: ["resources"]
            )
        )

        XCTAssertEqual(page.stylesheetPaths, ["themes/paper/assets/css/main.css"])
        XCTAssertTrue(page.html.contains("gitsync-resource://local/themes/paper/assets/css/main.css"))
        XCTAssertTrue(page.html.contains("gitsync-resource://local/content/posts/example/images/cover.png"))
        XCTAssertTrue(page.html.contains("Theme &lt;Preview&gt;"))
        XCTAssertTrue(page.html.contains("script-src 'none'"))
        XCTAssertFalse(page.html.contains("file://"))
    }

    func testThemePreviewResourceSchemeRejectsEscapes() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let css = root.appendingPathComponent("static/site.css")
        try fileManager.createDirectory(at: css.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "body {}".write(to: css, atomically: true, encoding: .utf8)

        let safeURL = try XCTUnwrap(URL(string: "gitsync-resource://local/static/site.css"))
        let escapeURL = try XCTUnwrap(URL(string: "gitsync-resource://local/../outside.css"))

        XCTAssertEqual(
            HugoThemePreviewService.resourceFileURL(from: safeURL, repositoryRoot: root)?.path,
            css.path
        )
        XCTAssertNil(HugoThemePreviewService.resourceFileURL(from: escapeURL, repositoryRoot: root))
        XCTAssertEqual(HugoThemePreviewService.mimeType(for: css), "text/css")
    }

    func testHugoTemplateCompatibilityResolvesCommonVariablesAndMarksUnknownExpressions() {
        let context = HugoTemplatePreviewContext(
            title: "A <Title>",
            date: "2026-08-16",
            draft: false,
            contentHTML: "<p>Rendered body</p>",
            siteTitle: "Example Site",
            language: "zh-Hans",
            contentType: "posts",
            section: "posts",
            layout: "single",
            permalink: "/posts/example/",
            params: ["featured": "yes"]
        )
        let template = """
        {{ define "main" }}
        <article lang="{{ .Site.Language.Lang }}">
          <h1>{{ .Title }}</h1>
          {{ .Content | safeHTML }}
          <span>{{ .Params.featured }}</span>
          {{ partial "author.html" . }}
        </article>
        {{ end }}
        """

        let result = HugoTemplateCompatibilityService.renderTemplate(template, context: context)

        XCTAssertTrue(result.html.contains("lang=\"zh-Hans\""))
        XCTAssertTrue(result.html.contains("A &lt;Title&gt;"))
        XCTAssertTrue(result.html.contains("<p>Rendered body</p>"))
        XCTAssertTrue(result.html.contains("<span>yes</span>"))
        XCTAssertTrue(result.html.contains("Unsupported Hugo template expression"))
        XCTAssertEqual(result.issues.count, 1)
    }

    func testHugoShortcodeCompatibilityRendersFigureAndMarksUnsupportedShortcode() {
        let figure = HugoTemplateCompatibilityService.renderShortcode(
            #"{{< figure src="images/photo.jpg" title="Photo" >}}"#
        ) { path in
            path == "images/photo.jpg" ? "gitsync-resource://local/content/photo.jpg" : nil
        }
        let unsupported = HugoTemplateCompatibilityService.renderShortcode(
            "{{< custom-widget >}}"
        ) { _ in nil }

        XCTAssertTrue(figure.html.contains("gitsync-resource://local/content/photo.jpg"))
        XCTAssertTrue(figure.html.contains("<figcaption>Photo</figcaption>"))
        XCTAssertTrue(figure.issues.isEmpty)
        XCTAssertTrue(unsupported.html.contains("Unsupported Hugo shortcode"))
        XCTAssertEqual(unsupported.issues.count, 1)
    }

    func testThemePreviewUsesRepositoryLayoutAndReportsCompatibilityIssues() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let layout = root.appendingPathComponent("layouts/_default/single.html")
        let bundle = root.appendingPathComponent("content/posts/example", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: layout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "<main><h1>{{ .Title }}</h1>{{ .Content }}{{ mystery . }}</main>"
            .write(to: layout, atomically: true, encoding: .utf8)

        let page = HugoThemePreviewService.render(
            markdown: "---\ntitle: \"Layout Title\"\n---\n\n{{< unknown >}}",
            articleURL: bundle.appendingPathComponent("index.md"),
            repositoryRoot: root,
            configuration: HugoSiteConfiguration(configurationFiles: ["hugo.toml"])
        )

        XCTAssertEqual(page.layoutPath, "layouts/_default/single.html")
        XCTAssertTrue(page.html.contains("<h1>Layout Title</h1>"))
        XCTAssertEqual(page.compatibilityIssues.count, 2)
        XCTAssertTrue(page.html.contains("Unsupported Hugo shortcode"))
        XCTAssertTrue(page.html.contains("Unsupported Hugo template expression"))
    }

    func testThemePreviewDiscoversLayoutsContentTypesLanguagesAndVariants() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let layout = root.appendingPathComponent("layouts/posts/feature.html")
        let bundle = root.appendingPathComponent("content/posts/example", isDirectory: true)
        let article = bundle.appendingPathComponent("index.md")
        let traditional = bundle.appendingPathComponent("index.zh-Hant.md")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: layout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "<article data-layout=\"{{ .Layout }}\" lang=\"{{ .Site.Language.Lang }}\">{{ .Content }}</article>"
            .write(to: layout, atomically: true, encoding: .utf8)
        try "English".write(to: article, atomically: true, encoding: .utf8)
        try "繁體內容".write(to: traditional, atomically: true, encoding: .utf8)
        let configuration = HugoSiteConfiguration(
            configurationFiles: ["hugo.toml"],
            defaultContentLanguage: "en",
            languages: ["en", "zh-Hant"]
        )

        let choices = HugoThemePreviewService.discoverChoices(
            repositoryRoot: root,
            configuration: configuration,
            articleURL: article
        )
        let page = HugoThemePreviewService.render(
            markdown: "繁體內容",
            articleURL: traditional,
            repositoryRoot: root,
            configuration: configuration,
            options: HugoThemePreviewOptions(
                layout: "feature",
                contentType: "posts",
                language: "zh-Hant",
                device: .phone
            )
        )

        XCTAssertEqual(choices.layouts, ["feature", "single"])
        XCTAssertEqual(choices.contentTypes, ["page", "posts"])
        XCTAssertEqual(choices.languages, ["en", "zh-Hant"])
        XCTAssertEqual(choices.languageVariantURLs["zh-Hant"], traditional.resolvingSymlinksInPath())
        XCTAssertEqual(page.layoutPath, "layouts/posts/feature.html")
        XCTAssertTrue(page.html.contains("data-layout=\"feature\""))
        XCTAssertTrue(page.html.contains("lang=\"zh-Hant\""))
        XCTAssertTrue(page.html.contains("繁體內容"))
        XCTAssertEqual(HugoPreviewDevice.phone.width, 390)
        XCTAssertEqual(HugoPreviewDevice.tablet.width, 768)
        XCTAssertEqual(HugoPreviewDevice.desktop.width, 1200)
    }

    func testThemePreviewRejectsLanguageVariantSymlinkOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let bundle = repositoryRoot.appendingPathComponent("content/post", isDirectory: true)
        let article = bundle.appendingPathComponent("index.md")
        let linkedVariant = bundle.appendingPathComponent("index.zh-Hant.md")
        let outsideVariant = temporaryRoot.appendingPathComponent("outside.md")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "English".write(to: article, atomically: true, encoding: .utf8)
        try "Private".write(to: outsideVariant, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(at: linkedVariant, withDestinationURL: outsideVariant)

        let choices = HugoThemePreviewService.discoverChoices(
            repositoryRoot: repositoryRoot,
            configuration: HugoSiteConfiguration(
                defaultContentLanguage: "en",
                languages: ["en", "zh-Hant"]
            ),
            articleURL: article
        )

        XCTAssertEqual(
            choices.languageVariantURLs["en"],
            article.resolvingSymlinksInPath()
        )
        XCTAssertNil(choices.languageVariantURLs["zh-Hant"])
    }

    func testThemePreviewRejectsLayoutRootSymlinkOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let themeRoot = repositoryRoot.appendingPathComponent("themes/linked", isDirectory: true)
        let linkedLayouts = themeRoot.appendingPathComponent("layouts", isDirectory: true)
        let outsideLayouts = temporaryRoot.appendingPathComponent("outside-layouts", isDirectory: true)
        let outsideLayout = outsideLayouts.appendingPathComponent("posts/private.html")
        let article = repositoryRoot.appendingPathComponent("content/posts/example/index.md")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: themeRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideLayout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: article.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<main>Private theme</main>".write(to: outsideLayout, atomically: true, encoding: .utf8)
        try "Article".write(to: article, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(at: linkedLayouts, withDestinationURL: outsideLayouts)
        let configuration = HugoSiteConfiguration(themes: ["linked"])

        let choices = HugoThemePreviewService.discoverChoices(
            repositoryRoot: repositoryRoot,
            configuration: configuration,
            articleURL: article
        )
        let page = HugoThemePreviewService.render(
            markdown: "Article",
            articleURL: article,
            repositoryRoot: repositoryRoot,
            configuration: configuration,
            options: HugoThemePreviewOptions(layout: "private", contentType: "posts")
        )

        XCTAssertEqual(choices.layouts, ["single"])
        XCTAssertNil(page.layoutPath)
        XCTAssertFalse(page.html.contains("Private theme"))
    }

    func testThemeTemplateSanitizerRemovesScriptsEventsAndFrames() {
        let context = HugoTemplatePreviewContext(
            title: "Safe",
            date: "",
            draft: false,
            contentHTML: "<p>Body</p>",
            siteTitle: "Site",
            language: "en",
            contentType: "page",
            section: "",
            layout: "single",
            permalink: "/safe/",
            params: [:]
        )
        let result = HugoTemplateCompatibilityService.renderTemplate(
            #"<main onclick="steal()">{{ .Content }}<script>steal()</script><iframe src="https://example.com"></iframe><a href="javascript:steal()">bad</a></main>"#,
            context: context
        )

        XCTAssertTrue(result.html.contains("<p>Body</p>"))
        XCTAssertFalse(result.html.lowercased().contains("<script"))
        XCTAssertFalse(result.html.lowercased().contains("onclick"))
        XCTAssertFalse(result.html.lowercased().contains("<iframe"))
        XCTAssertFalse(result.html.lowercased().contains("javascript:"))
        XCTAssertTrue(result.html.contains("blocked:"))
        XCTAssertTrue(result.issues.contains(String(localized: "Unsafe theme markup was removed from the preview.")))
    }

    func testThemeResourceSignatureChangesAndSchemeRejectsScripts() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let theme = root.appendingPathComponent("themes/paper", isDirectory: true)
        let css = theme.appendingPathComponent("assets/main.css")
        let script = theme.appendingPathComponent("assets/main.js")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: css.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "body {}".write(to: css, atomically: true, encoding: .utf8)
        try "alert(1)".write(to: script, atomically: true, encoding: .utf8)
        let configuration = HugoSiteConfiguration(
            configurationFiles: ["hugo.toml"],
            themes: ["paper"]
        )

        let original = HugoThemePreviewService.siteResourceSignature(
            repositoryRoot: root,
            configuration: configuration
        )
        try "body { color: rebeccapurple; }".write(to: css, atomically: true, encoding: .utf8)
        let updated = HugoThemePreviewService.siteResourceSignature(
            repositoryRoot: root,
            configuration: configuration
        )
        let scriptURL = try XCTUnwrap(URL(string: "gitsync-resource://local/themes/paper/assets/main.js"))

        XCTAssertNotEqual(original, updated)
        XCTAssertNil(HugoThemePreviewService.resourceFileURL(from: scriptURL, repositoryRoot: root))
    }

    func testThemePreviewSemanticSnapshotMatchesOfficialHugoBuild() throws {
        let fixture = try XCTUnwrap(
            Bundle(for: HugoContentServiceTests.self).url(
                forResource: "HugoThemePreviewFixture",
                withExtension: nil
            )
        )
        let article = fixture.appendingPathComponent("content/posts/snapshot/index.md")
        let markdown = try String(contentsOf: article, encoding: .utf8)
        let reference = try String(
            contentsOf: fixture.appendingPathComponent("expected.html"),
            encoding: .utf8
        )
        let configuration = HugoSiteConfigurationService.discover(in: fixture)
        let page = HugoThemePreviewService.render(
            markdown: markdown,
            articleURL: article,
            repositoryRoot: fixture,
            configuration: configuration,
            options: HugoThemePreviewOptions(
                layout: "snapshot",
                contentType: "posts",
                language: "en",
                device: .desktop
            )
        )

        let comparison = HugoThemeSnapshotService.compare(
            previewHTML: page.html,
            referenceHugoHTML: reference
        )

        XCTAssertEqual(page.layoutPath, "layouts/posts/snapshot.html")
        XCTAssertTrue(page.compatibilityIssues.isEmpty, page.compatibilityIssues.joined(separator: "\n"))
        XCTAssertTrue(comparison.isMatch, comparison.mismatches.joined(separator: "\n"))
        XCTAssertEqual(comparison.preview.bodyText, comparison.reference.bodyText)
    }

    func testArticleSortSupportsPublicationModifiedTitleDirectoryAndDraftState() {
        let older = HugoArticle(
            fileURL: URL(fileURLWithPath: "/repo/content/z/index.md"),
            relativePath: "content/z/index.md",
            title: "Beta",
            date: "2026-01-01",
            draft: false,
            coverURL: nil,
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
        let newerDraft = HugoArticle(
            fileURL: URL(fileURLWithPath: "/repo/content/a/index.md"),
            relativePath: "content/a/index.md",
            title: "Alpha",
            date: "2026-02-01",
            draft: true,
            coverURL: nil,
            modifiedAt: Date(timeIntervalSince1970: 20)
        )
        let values = [older, newerDraft]

        XCTAssertEqual(values.sorted(by: HugoArticleSort.publicationDate.areInIncreasingOrder).first?.title, "Alpha")
        XCTAssertEqual(values.sorted(by: HugoArticleSort.modified.areInIncreasingOrder).first?.title, "Alpha")
        XCTAssertEqual(values.sorted(by: HugoArticleSort.title.areInIncreasingOrder).first?.title, "Alpha")
        XCTAssertEqual(values.sorted(by: HugoArticleSort.directory.areInIncreasingOrder).first?.title, "Alpha")
        XCTAssertTrue(values.sorted(by: HugoArticleSort.draftStatus.areInIncreasingOrder).first?.draft == true)
    }

    func testLegacyHugoConfigurationDefaultsCustomFieldsToEmpty() throws {
        let data = try XCTUnwrap(#"{"contentMappings":[{"directory":"content/posts","archetype":"archetypes/default.md"}]}"#.data(using: .utf8))

        let configuration = try JSONDecoder().decode(HugoRepositoryConfiguration.self, from: data)

        XCTAssertEqual(configuration.contentMappings.count, 1)
        XCTAssertTrue(configuration.frontMatterFields.isEmpty)
    }

    func testHugoConfigurationRoundTripsCustomFieldsWithoutRuntimeID() throws {
        let configuration = HugoRepositoryConfiguration(
            frontMatterFields: [
                HugoFrontMatterFieldConfiguration(key: "featured", label: "Featured", type: .boolean)
            ]
        )

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(HugoRepositoryConfiguration.self, from: data)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(decoded.frontMatterFields.first?.key, "featured")
        XCTAssertEqual(decoded.frontMatterFields.first?.type, .boolean)
        XCTAssertFalse(json.contains("\"id\""))
    }

    func testHugoRepositoryConfigurationDoesNotLoadSymlinkOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let outsideConfiguration = temporaryRoot.appendingPathComponent("outside.json")
        let linkedConfiguration = repositoryRoot.appendingPathComponent(HugoContentService.configurationFile)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
        let externalValue = HugoRepositoryConfiguration(
            contentMappings: [HugoContentMapping(directory: "private", archetype: "secret.md")]
        )
        try JSONEncoder().encode(externalValue).write(to: outsideConfiguration)
        try fileManager.createSymbolicLink(at: linkedConfiguration, withDestinationURL: outsideConfiguration)

        let configuration = HugoContentService.loadConfiguration(from: repositoryRoot)

        XCTAssertTrue(configuration.contentMappings.isEmpty)
        XCTAssertTrue(configuration.frontMatterFields.isEmpty)
    }

    func testHugoRepositoryConfigurationDoesNotSaveThroughSymlinkOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let outsideConfiguration = temporaryRoot.appendingPathComponent("outside.json")
        let linkedConfiguration = repositoryRoot.appendingPathComponent(HugoContentService.configurationFile)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideConfiguration)
        try fileManager.createSymbolicLink(at: linkedConfiguration, withDestinationURL: outsideConfiguration)

        XCTAssertThrowsError(try HugoContentService.saveConfiguration(
            HugoRepositoryConfiguration(
                contentMappings: [HugoContentMapping(directory: "content/posts", archetype: "archetypes/default.md")]
            ),
            to: repositoryRoot
        ))
        XCTAssertEqual(try String(contentsOf: outsideConfiguration, encoding: .utf8), "outside")
    }

    func testHugoSiteConfigurationDiscoversTOMLSettings() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        theme = ["base", "paper"]
        defaultContentLanguage = "zh-Hans"
        assetDir = "frontend/assets"
        staticDir = ["public-assets", "shared-static"]
        resourceDir = "generated-resources"

        [languages.en]
        languageName = "English"

        [languages.zh-Hans]
        languageName = "简体中文"

        [permalinks]
        posts = "/articles/:slug/"
        """.write(to: root.appendingPathComponent("hugo.toml"), atomically: true, encoding: .utf8)

        let configuration = HugoSiteConfigurationService.discover(in: root)

        XCTAssertEqual(configuration.configurationFiles, ["hugo.toml"])
        XCTAssertEqual(configuration.themes, ["base", "paper"])
        XCTAssertEqual(configuration.defaultContentLanguage, "zh-Hans")
        XCTAssertEqual(configuration.languages, ["en", "zh-Hans"])
        XCTAssertEqual(configuration.permalinks["posts"], "/articles/:slug/")
        XCTAssertEqual(configuration.assetDirectories, ["frontend/assets"])
        XCTAssertEqual(configuration.staticDirectories, ["public-assets", "shared-static"])
        XCTAssertEqual(configuration.resourceDirectories, ["generated-resources"])
    }

    func testHugoSiteConfigurationMergesYAMLConfigFragments() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = root.appendingPathComponent("config/_default", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: config, withIntermediateDirectories: true)
        try """
        theme: newsroom
        defaultContentLanguage: en
        staticDir:
          - site-static
          - shared
        """.write(to: config.appendingPathComponent("hugo.yaml"), atomically: true, encoding: .utf8)
        try """
        en:
          languageName: English
        zh-Hant:
          languageName: 繁體中文
        """.write(to: config.appendingPathComponent("languages.yaml"), atomically: true, encoding: .utf8)
        try """
        posts: /news/:year/:slug/
        pages: /:slug/
        """.write(to: config.appendingPathComponent("permalinks.yaml"), atomically: true, encoding: .utf8)

        let configuration = HugoSiteConfigurationService.discover(in: root)

        XCTAssertEqual(configuration.themes, ["newsroom"])
        XCTAssertEqual(configuration.defaultContentLanguage, "en")
        XCTAssertEqual(configuration.languages, ["en", "zh-Hant"])
        XCTAssertEqual(configuration.permalinks["posts"], "/news/:year/:slug/")
        XCTAssertEqual(configuration.permalinks["pages"], "/:slug/")
        XCTAssertEqual(configuration.assetDirectories, ["assets"])
        XCTAssertEqual(configuration.staticDirectories, ["site-static", "shared"])
        XCTAssertEqual(configuration.resourceDirectories, ["resources"])
    }

    func testHugoSiteConfigurationRejectsResourcesOutsideRepository() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        assetDir = "../outside"
        staticDir = "/private/static"
        resourceDir = "https://example.com/resources"
        """.write(to: root.appendingPathComponent("hugo.toml"), atomically: true, encoding: .utf8)

        let configuration = HugoSiteConfigurationService.discover(in: root)

        XCTAssertTrue(configuration.isDetected)
        XCTAssertTrue(configuration.previewResourceDirectories.isEmpty)
    }

    func testFrontMatterFieldKeyValidationRejectsBuiltInAndUnsafeKeys() {
        XCTAssertTrue(HugoContentService.isValidFrontMatterFieldKey("description"))
        XCTAssertTrue(HugoContentService.isValidFrontMatterFieldKey("show_toc"))
        XCTAssertFalse(HugoContentService.isValidFrontMatterFieldKey("draft"))
        XCTAssertFalse(HugoContentService.isValidFrontMatterFieldKey("Title"))
        XCTAssertFalse(HugoContentService.isValidFrontMatterFieldKey("bad key"))
        XCTAssertFalse(HugoContentService.isValidFrontMatterFieldKey("../layout"))
        XCTAssertTrue(HugoContentService.isValidFrontMatterNumber("-12.5"))
        XCTAssertFalse(HugoContentService.isValidFrontMatterNumber("12px"))
    }

    func testMovingArticleBundlePreservesBundleImagesAndUpdatesExternalRelativeImages() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }
        let sourceBundle = root.appendingPathComponent("content/posts/old-post", isDirectory: true)
        let images = sourceBundle.appendingPathComponent("images", isDirectory: true)
        let destinationParent = root.appendingPathComponent("content", isDirectory: true)
        let sharedImages = root.appendingPathComponent("static/images", isDirectory: true)
        try fileManager.createDirectory(at: images, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sharedImages, withIntermediateDirectories: true)
        try Data([0x01]).write(to: images.appendingPathComponent("cover.jpg"))
        try Data([0x02]).write(to: sharedImages.appendingPathComponent("shared.jpg"))
        let original = """
        ---
        title: "Post"
        cover: images/cover.jpg
        ---

        ![Local](images/cover.jpg)
        ![Shared](../../../static/images/shared.jpg)
        """
        let sourceFile = sourceBundle.appendingPathComponent("index.md")
        try original.write(to: sourceFile, atomically: true, encoding: .utf8)

        let result = try HugoContentService.moveArticleBundle(
            indexFileURL: sourceFile,
            toContentDirectory: destinationParent,
            bundleName: "new-post",
            repositoryRoot: root
        )

        let output = try String(contentsOf: result.destinationFileURL, encoding: .utf8)
        XCTAssertFalse(fileManager.fileExists(atPath: sourceBundle.path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: result.destinationFileURL.deletingLastPathComponent()
                .appendingPathComponent("images/cover.jpg").path
        ))
        XCTAssertTrue(output.contains("cover: images/cover.jpg"))
        XCTAssertTrue(output.contains("![Local](images/cover.jpg)"))
        XCTAssertTrue(output.contains("![Shared](../../static/images/shared.jpg)"))
        XCTAssertEqual(result.updatedImageReferenceCount, 1)
    }

    func testRelativeImageRewriteSupportsHTMLAndPreservesRemoteURLs() {
        let root = URL(fileURLWithPath: "/repo")
        let source = root.appendingPathComponent("content/posts/old")
        let destination = root.appendingPathComponent("content/new")
        let markdown = """
        cover: ../../../static/cover.jpg
        <img src="../../../static/photo.jpg">
        ![Remote](https://example.com/photo.jpg)
        ![Anchor](#diagram)
        """

        let result = HugoContentService.updatingRelativeImageReferences(
            in: markdown,
            sourceBundleURL: source,
            destinationBundleURL: destination,
            repositoryRoot: root
        )

        XCTAssertTrue(result.markdown.contains("cover: ../../static/cover.jpg"))
        XCTAssertTrue(result.markdown.contains(#"<img src="../../static/photo.jpg">"#))
        XCTAssertTrue(result.markdown.contains("https://example.com/photo.jpg"))
        XCTAssertTrue(result.markdown.contains("![Anchor](#diagram)"))
        XCTAssertEqual(result.updatedCount, 2)
    }

    func testMovingArticleBundleRejectsExistingDestination() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }
        let content = root.appendingPathComponent("content", isDirectory: true)
        let source = content.appendingPathComponent("old", isDirectory: true)
        let destination = content.appendingPathComponent("existing", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try "Body".write(
            to: source.appendingPathComponent("index.md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try HugoContentService.moveArticleBundle(
            indexFileURL: source.appendingPathComponent("index.md"),
            toContentDirectory: content,
            bundleName: "existing",
            repositoryRoot: root
        )) { error in
            XCTAssertTrue(error is HugoArticleMoveError)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: source.appendingPathComponent("index.md").path))
    }

    func testMovingArticleBundleRejectsDestinationSymlinkOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let content = repositoryRoot.appendingPathComponent("content", isDirectory: true)
        let source = content.appendingPathComponent("old", isDirectory: true)
        let outside = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
        let linkedDestination = content.appendingPathComponent("external", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try "Body".write(
            to: source.appendingPathComponent("index.md"),
            atomically: true,
            encoding: .utf8
        )
        try fileManager.createSymbolicLink(at: linkedDestination, withDestinationURL: outside)

        XCTAssertThrowsError(try HugoContentService.moveArticleBundle(
            indexFileURL: source.appendingPathComponent("index.md"),
            toContentDirectory: linkedDestination,
            bundleName: "escaped",
            repositoryRoot: repositoryRoot
        )) { error in
            guard let moveError = error as? HugoArticleMoveError,
                  case .invalidDestination = moveError else {
                return XCTFail("Expected invalidDestination, got \(error)")
            }
        }
        XCTAssertTrue(fileManager.fileExists(atPath: source.appendingPathComponent("index.md").path))
        XCTAssertFalse(fileManager.fileExists(atPath: outside.appendingPathComponent("escaped").path))
    }

    func testNewArticleBundleDestinationRejectsSymlinkOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let content = repositoryRoot.appendingPathComponent("content", isDirectory: true)
        let outside = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
        let linkedDirectory = content.appendingPathComponent("external", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: content, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkedDirectory, withDestinationURL: outside)

        XCTAssertThrowsError(try HugoContentService.newArticleBundleDirectory(
            contentDirectory: "content/external",
            bundleName: "escaped",
            repositoryRoot: repositoryRoot
        )) { error in
            XCTAssertEqual(error as? HugoArticleCreationError, .invalidDestination)
        }
        XCTAssertFalse(fileManager.fileExists(atPath: outside.appendingPathComponent("escaped").path))
    }

    func testNewArticleBundleDestinationAcceptsDirectoryInsideRepository() throws {
        let fileManager = FileManager.default
        let repositoryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let posts = repositoryRoot.appendingPathComponent("content/posts", isDirectory: true)
        defer { try? fileManager.removeItem(at: repositoryRoot) }
        try fileManager.createDirectory(at: posts, withIntermediateDirectories: true)

        let destination = try HugoContentService.newArticleBundleDirectory(
            contentDirectory: "content/posts",
            bundleName: "safe-article",
            repositoryRoot: repositoryRoot
        )

        XCTAssertEqual(destination, posts.appendingPathComponent("safe-article", isDirectory: true))
    }

    func testContentDirectoryDiscoveryRejectsSymlinksOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let content = repositoryRoot.appendingPathComponent("content", isDirectory: true)
        let posts = content.appendingPathComponent("posts", isDirectory: true)
        let outside = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
        let linkedSection = content.appendingPathComponent("external", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: posts, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkedSection, withDestinationURL: outside)

        XCTAssertEqual(
            HugoContentService.contentDirectories(in: repositoryRoot),
            ["content", "content/posts"]
        )
        XCTAssertNil(HugoContentService.contentDirectoryURL(for: "content/external", in: repositoryRoot))
        XCTAssertNil(HugoContentService.contentDirectoryURL(for: "../outside", in: repositoryRoot))

        try fileManager.removeItem(at: content)
        try fileManager.createSymbolicLink(at: content, withDestinationURL: outside)
        XCTAssertTrue(HugoContentService.contentDirectories(in: repositoryRoot).isEmpty)
    }

    func testArchetypeValidationRejectsSymlinkOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let archetypes = repositoryRoot.appendingPathComponent("archetypes", isDirectory: true)
        let outside = temporaryRoot.appendingPathComponent("outside.md")
        let linkedArchetype = archetypes.appendingPathComponent("leak.md")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: archetypes, withIntermediateDirectories: true)
        try "private".write(to: outside, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(at: linkedArchetype, withDestinationURL: outside)

        XCTAssertFalse(
            HugoContentService.archetypes(in: repositoryRoot).contains("archetypes/leak.md")
        )
        XCTAssertThrowsError(try HugoContentService.archetypeURL(
            for: "archetypes/leak.md",
            in: repositoryRoot
        )) { error in
            XCTAssertEqual(error as? HugoArticleCreationError, .invalidArchetype)
        }
    }

    func testArchetypeValidationAcceptsRepositoryTemplate() throws {
        let fileManager = FileManager.default
        let repositoryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archetypes = repositoryRoot.appendingPathComponent("archetypes", isDirectory: true)
        let template = archetypes.appendingPathComponent("default.md")
        defer { try? fileManager.removeItem(at: repositoryRoot) }
        try fileManager.createDirectory(at: archetypes, withIntermediateDirectories: true)
        try "---\ndraft: true\n---".write(to: template, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try HugoContentService.archetypeURL(for: "archetypes/default.md", in: repositoryRoot),
            template
        )
        XCTAssertTrue(
            HugoContentService.archetypes(in: repositoryRoot).contains("archetypes/default.md")
        )
    }

    func testArticleDiscoveryRejectsContentSymlinkOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let outsideContent = temporaryRoot.appendingPathComponent("outside-content", isDirectory: true)
        let outsideArticle = outsideContent.appendingPathComponent("post/index.md")
        let linkedContent = repositoryRoot.appendingPathComponent("content", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(
            at: outsideArticle.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "outside".write(to: outsideArticle, atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkedContent, withDestinationURL: outsideContent)

        XCTAssertTrue(HugoContentService.articleIndexFiles(in: repositoryRoot).isEmpty)
        XCTAssertThrowsError(try HugoContentService.articleIndexURL(
            outsideArticle,
            in: repositoryRoot
        )) { error in
            XCTAssertEqual(error as? HugoArticleAccessError, .invalidArticle)
        }
    }

    func testArticleDiscoveryRejectsIndexSymlinkOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let articleDirectory = repositoryRoot.appendingPathComponent("content/post", isDirectory: true)
        let linkedArticle = articleDirectory.appendingPathComponent("index.md")
        let outsideArticle = temporaryRoot.appendingPathComponent("outside.md")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: articleDirectory, withIntermediateDirectories: true)
        try "outside".write(to: outsideArticle, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(at: linkedArticle, withDestinationURL: outsideArticle)

        XCTAssertTrue(HugoContentService.articleIndexFiles(in: repositoryRoot).isEmpty)
        XCTAssertThrowsError(try HugoContentService.articleIndexURL(
            linkedArticle,
            in: repositoryRoot
        )) { error in
            XCTAssertEqual(error as? HugoArticleAccessError, .invalidArticle)
        }
    }

    func testArticleDiscoveryAcceptsIndexInsideRepository() throws {
        let fileManager = FileManager.default
        let repositoryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let article = repositoryRoot.appendingPathComponent("content/posts/safe/index.md")
        defer { try? fileManager.removeItem(at: repositoryRoot) }
        try fileManager.createDirectory(
            at: article.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "safe".write(to: article, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try HugoContentService.articleIndexURL(article, in: repositoryRoot),
            article
        )
        XCTAssertEqual(HugoContentService.articleIndexFiles(in: repositoryRoot), [article])
    }

    func testRendersLeafBundleArchetype() {
        let template = """
        ---
        title: "{{ replace .File.ContentBaseName `-` ` ` | title }}"
        date: {{ .Date }}
        draft: true
        ---
        """
        let rendered = HugoContentService.render(template: template, title: "My First Post", filename: "index.md", section: "posts", bundleName: "my-first-post", date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(rendered.contains("title: \"My First Post\""))
        XCTAssertTrue(rendered.contains("1970-01-01"))
        XCTAssertFalse(rendered.contains("{{"))
    }

    func testYAMLFrontMatterPreservesUnknownFields() {
        let original = "---\ntitle: \"Old\"\ndescription: keep me\ndraft: false\n---\n\nBody"
        var matter = MarkdownFrontMatter(markdown: original)
        matter.title = "New"
        matter.body = "Updated"
        let output = matter.applying(to: original)
        XCTAssertTrue(output.contains("title: \"New\""))
        XCTAssertTrue(output.contains("description: keep me"))
        XCTAssertTrue(output.hasSuffix("Updated"))
    }

    func testTOMLFrontMatterPreservesUnknownFields() {
        let original = "+++\ntitle = \"Old\"\nlayout = \"post\"\ndraft = true\n+++\n\nBody"
        var matter = MarkdownFrontMatter(markdown: original)
        matter.draft = false
        let output = matter.applying(to: original)
        XCTAssertTrue(output.contains("draft = false"))
        XCTAssertTrue(output.contains("layout = \"post\""))
    }

    func testConfiguredYAMLTextFieldUpdatesWithoutDroppingOtherFields() {
        let original = "---\ntitle: \"Post\"\nsummary: \"Old\"\nlayout: special\nnested:\n  child: true\n---\n\nBody"
        let fields = [
            HugoFrontMatterFieldConfiguration(key: "summary", label: "Summary", type: .text)
        ]
        var matter = MarkdownFrontMatter(markdown: original)
        matter.customValues["summary"] = "New summary"

        let output = matter.applying(to: original, customFields: fields)

        XCTAssertTrue(output.contains("summary: \"New summary\""))
        XCTAssertTrue(output.contains("layout: special"))
        XCTAssertTrue(output.contains("nested:\n  child: true"))
        XCTAssertTrue(output.hasSuffix("Body"))
    }

    func testConfiguredTOMLBooleanAndNumberFieldsUseNativeValues() {
        let original = "+++\ntitle = \"Post\"\nfeatured = false\nrating = 3\n+++\n\nBody"
        let fields = [
            HugoFrontMatterFieldConfiguration(key: "featured", label: "Featured", type: .boolean),
            HugoFrontMatterFieldConfiguration(key: "rating", label: "Rating", type: .number)
        ]
        var matter = MarkdownFrontMatter(markdown: original)
        matter.customValues["featured"] = "true"
        matter.customValues["rating"] = "4.5"

        let output = matter.applying(to: original, customFields: fields)

        XCTAssertTrue(output.contains("featured = true"))
        XCTAssertTrue(output.contains("rating = 4.5"))
    }

    func testInvalidConfiguredNumberKeepsOriginalValue() {
        let original = "---\ntitle: \"Post\"\nrating: 3\n---\n\nBody"
        let fields = [
            HugoFrontMatterFieldConfiguration(key: "rating", label: "Rating", type: .number)
        ]
        var matter = MarkdownFrontMatter(markdown: original)
        matter.customValues["rating"] = "not-a-number"

        let output = matter.applying(to: original, customFields: fields)

        XCTAssertTrue(output.contains("rating: 3"))
        XCTAssertFalse(output.contains("not-a-number"))
    }

    func testUnchangedConfiguredNestedFieldRemainsVerbatim() {
        let original = "---\ntitle: \"Post\"\nparams:\n  color: blue\n---\n\nBody"
        let fields = [
            HugoFrontMatterFieldConfiguration(key: "params", label: "Params", type: .text)
        ]
        let matter = MarkdownFrontMatter(markdown: original)

        let output = matter.applying(to: original, customFields: fields)

        XCTAssertTrue(output.contains("params:\n  color: blue"))
    }

    func testUpdatingYAMLDraftStatusPreservesBodyAndUnknownFields() {
        let original = "---\ntitle: \"Post\"\ndraft: true\nlayout: special\n---\n\nBody"

        let output = HugoContentService.updatingDraftStatus(in: original, isDraft: false)

        XCTAssertTrue(output.contains("draft: false"))
        XCTAssertTrue(output.contains("layout: special"))
        XCTAssertTrue(output.hasSuffix("Body"))
    }

    func testUpdatingTOMLDraftStatusPreservesDelimiterAndUnknownFields() {
        let original = "+++\ntitle = \"Post\"\ndraft = false\nlayout = \"wide\"\n+++\n\nBody"

        let output = HugoContentService.updatingDraftStatus(in: original, isDraft: true)

        XCTAssertTrue(output.hasPrefix("+++\n"))
        XCTAssertTrue(output.contains("draft = true"))
        XCTAssertTrue(output.contains("layout = \"wide\""))
        XCTAssertTrue(output.hasSuffix("Body"))
    }

    func testPublicationDateUpdatePreservesISOOffsetAndQuotedYAMLValue() throws {
        let value = "2026-08-15T14:09:09+08:00"
        let original = "---\ntitle: \"Post\"\ndate: '\(value)'\ndraft: false\n---\n\nBody"
        let date = try XCTUnwrap(HugoContentService.publicationDate(from: value))

        let output = HugoContentService.updatingPublicationDate(
            in: original,
            date: date.addingTimeInterval(24 * 60 * 60)
        )

        XCTAssertTrue(output.contains("date: '2026-08-16T14:09:09+08:00'"))
        XCTAssertTrue(output.hasSuffix("Body"))
    }

    func testPublicationDateUpdatePreservesDateOnlyFormat() throws {
        let date = try XCTUnwrap(HugoContentService.publicationDate(from: "2026-08-15"))

        let value = HugoContentService.publicationDateValue(
            for: date.addingTimeInterval(24 * 60 * 60),
            preserving: "2026-08-15"
        )

        XCTAssertEqual(value, "2026-08-16")
    }

    func testClearingPublicationDatePreservesOtherFrontMatter() {
        let original = "+++\ntitle = \"Post\"\ndate = 2026-08-15T14:09:09Z\nlayout = \"wide\"\n+++\n\nBody"

        let output = HugoContentService.updatingPublicationDate(in: original, date: nil)

        XCTAssertFalse(output.contains("date ="))
        XCTAssertTrue(output.contains("layout = \"wide\""))
        XCTAssertTrue(output.hasSuffix("Body"))
    }

    func testCoverFieldCanBeEditedWithoutDroppingCustomFields() {
        let original = "---\ntitle: \"Post\"\ncover: \"images/old.jpg\"\nlayout: special\n---\n\nBody"
        var matter = MarkdownFrontMatter(markdown: original)
        XCTAssertEqual(matter.cover, "images/old.jpg")
        matter.cover = "images/new.jpg"
        let output = matter.applying(to: original)
        XCTAssertTrue(output.contains("cover: \"images/new.jpg\""))
        XCTAssertTrue(output.contains("layout: special"))
    }

    func testSlugifyUsesEnglishPathCharacters() {
        XCTAssertEqual(HugoContentService.slugify("My First Post!"), "my-first-post")
    }
}
