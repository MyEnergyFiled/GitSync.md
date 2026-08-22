import Foundation
import XCTest
import CryptoKit
import Clibgit2
import libgit2
@testable import Sync_md

final class SyncMDTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = git_libgit2_init()
    }

    func testSmoke() {
        XCTAssertTrue(true)
    }

    func testGitOperationCoordinatorSerializesOperationsForSameRepository() async {
        let coordinator = GitOperationCoordinator()
        let probe = GitOperationConcurrencyProbe()
        let repoID = UUID()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await coordinator.withOperation(repoID: repoID) {
                        await probe.enter()
                        try? await Task.sleep(for: .milliseconds(20))
                        await probe.leave()
                    }
                }
            }
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.completed, 8)
        XCTAssertEqual(snapshot.maximumConcurrent, 1)
    }

    func testGitOperationCoordinatorAllowsDifferentRepositoriesToProgress() async {
        let coordinator = GitOperationCoordinator()
        let probe = GitOperationConcurrencyProbe()
        let repositoryIDs = [UUID(), UUID()]

        await withTaskGroup(of: Void.self) { group in
            for repoID in repositoryIDs {
                group.addTask {
                    await coordinator.withOperation(repoID: repoID) {
                        await probe.enter()
                        try? await Task.sleep(for: .milliseconds(100))
                        await probe.leave()
                    }
                }
            }
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.completed, 2)
        XCTAssertEqual(snapshot.maximumConcurrent, 2)
    }

    func testRepositoryFileDestinationAcceptsDirectChildName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("notes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = try RepositoryFileDestinationValidator.destinationURL(
            for: "  文章.md  ",
            in: directory,
            repositoryRootURL: root
        )

        XCTAssertEqual(destination, directory.appendingPathComponent("文章.md"))
    }

    func testRepositoryFileDestinationRejectsTraversalAndGitMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for name in ["../outside.md", "nested/file.md", #"nested\file.md"#, ".", "..", ".git", ".GIT"] {
            XCTAssertThrowsError(
                try RepositoryFileDestinationValidator.destinationURL(
                    for: name,
                    in: root,
                    repositoryRootURL: root
                ),
                name
            ) { error in
                XCTAssertEqual(error as? RepositoryFileDestinationError, .invalidName)
            }
        }
    }

    func testRepositoryFileDestinationRejectsSymlinkOutsideRepository() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let outsideRoot = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
        let linkedDirectory = repositoryRoot.appendingPathComponent("linked", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: outsideRoot)

        XCTAssertThrowsError(
            try RepositoryFileDestinationValidator.destinationURL(
                for: "escaped.md",
                in: linkedDirectory,
                repositoryRootURL: repositoryRoot
            )
        ) { error in
            XCTAssertEqual(error as? RepositoryFileDestinationError, .outsideRepository)
        }
    }

    func testRepositoryExistingFileRejectsSymlinkOutsideRepository() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let images = repositoryRoot.appendingPathComponent("images", isDirectory: true)
        let outsideFile = temporaryRoot.appendingPathComponent("outside.jpg")
        let linkedFile = images.appendingPathComponent("linked.jpg")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data([0x01]).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: outsideFile)

        XCTAssertThrowsError(try RepositoryFileDestinationValidator.existingFileURL(
            linkedFile,
            in: images,
            repositoryRootURL: repositoryRoot
        )) { error in
            XCTAssertEqual(error as? RepositoryFileDestinationError, .outsideRepository)
        }
    }

    func testRepositoryExistingFileAcceptsRegularChild() throws {
        let repositoryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let images = repositoryRoot.appendingPathComponent("images", isDirectory: true)
        let image = images.appendingPathComponent("cover.jpg")
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data([0x01]).write(to: image)

        XCTAssertEqual(
            try RepositoryFileDestinationValidator.existingFileURL(
                image,
                in: images,
                repositoryRootURL: repositoryRoot
            ),
            image.resolvingSymlinksInPath()
        )
    }

    func testRepositoryExistingDirectoryRejectsSymlinkOutsideRepository() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let outsideDirectory = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
        let linkedDirectory = repositoryRoot.appendingPathComponent("linked", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: outsideDirectory)

        XCTAssertThrowsError(try RepositoryFileDestinationValidator.existingDirectoryURL(
            linkedDirectory,
            in: repositoryRoot,
            repositoryRootURL: repositoryRoot
        )) { error in
            XCTAssertEqual(error as? RepositoryFileDestinationError, .outsideRepository)
        }
    }

    func testRepositoryExistingDirectoryAcceptsRegularChild() throws {
        let repositoryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = repositoryRoot.appendingPathComponent("notes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertEqual(
            try RepositoryFileDestinationValidator.existingDirectoryURL(
                directory,
                in: repositoryRoot,
                repositoryRootURL: repositoryRoot
            ),
            directory.resolvingSymlinksInPath()
        )
    }

    func testRepositoryFileRenameDestinationKeepsEditorFileInsideRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let articleDirectory = root.appendingPathComponent("content/posts/article", isDirectory: true)
        let source = articleDirectory.appendingPathComponent("index.md")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: articleDirectory, withIntermediateDirectories: true)

        let destination = try RepositoryFileDestinationValidator.destinationURL(
            forRenaming: source,
            to: "renamed.md",
            repositoryRootURL: root
        )
        XCTAssertEqual(destination, articleDirectory.appendingPathComponent("renamed.md"))

        for name in ["../outside.md", "nested/file.md", ".git"] {
            XCTAssertThrowsError(
                try RepositoryFileDestinationValidator.destinationURL(
                    forRenaming: source,
                    to: name,
                    repositoryRootURL: root
                ),
                name
            ) { error in
                XCTAssertEqual(error as? RepositoryFileDestinationError, .invalidName)
            }
        }
    }

    @MainActor
    func testAppStateRefusesToRemoveRepositoryDuringGitOperation() async {
        let state = AppState(loadPersistedState: false)
        let repo = RepoConfig(
            repoURL: "https://github.com/example/notes.git",
            branch: "main",
            authorName: "Test User",
            authorEmail: "test@example.com",
            vaultFolderName: "SyncMD-OperationGuard-\(UUID().uuidString)"
        )
        state.repos = [repo]
        state.isSyncing = true
        state.syncingRepoID = repo.id

        XCTAssertFalse(state.removeRepo(id: repo.id))
        XCTAssertEqual(state.repos.map(\.id), [repo.id])
        XCTAssertTrue(state.showError)
        XCTAssertTrue(state.lastError?.contains("current Git operation") == true)
    }

    @MainActor
    func testAppStateRefusesToMoveRepositoryDuringGitOperation() async {
        let state = AppState(loadPersistedState: false)
        let repo = RepoConfig(
            repoURL: "https://github.com/example/notes.git",
            branch: "main",
            authorName: "Test User",
            authorEmail: "test@example.com",
            vaultFolderName: "SyncMD-OperationGuard-\(UUID().uuidString)"
        )
        state.repos = [repo]
        state.isSyncing = true
        state.syncingRepoID = repo.id

        XCTAssertThrowsError(
            try state.moveVaultLocation(
                for: repo.id,
                to: FileManager.default.temporaryDirectory,
                bookmark: Data("bookmark".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? AppState.MoveVaultError, .operationInProgress)
        }
        XCTAssertEqual(state.repos.map(\.id), [repo.id])
    }

    @MainActor
    func testSaveReposReportsPersistenceFailure() async {
        let writer = RepoPersistenceWriterStub(shouldFail: true)
        let state = AppState(
            reposPersistenceWriter: writer,
            loadPersistedState: false
        )

        let result = state.saveRepos()

        guard case .failure(.saveFailed) = result else {
            return XCTFail("Expected repository persistence to fail")
        }
        XCTAssertEqual(writer.persistCallCount, 1)
        XCTAssertTrue(state.showError)
        XCTAssertEqual(state.lastError, RepoPersistenceError.saveFailed.message)
    }

    func testKeychainServiceErrorKeepsDiagnosticsOutOfUserMessage() {
        let error = KeychainServiceError(operation: .save, status: errSecMissingEntitlement)

        XCTAssertEqual(error.errorDescription, String(localized: "Secure credential access failed."))
        XCTAssertFalse(error.errorDescription?.contains("OSStatus") == true)
        XCTAssertTrue(error.diagnosticDescription.contains("operation=save"))
        XCTAssertTrue(error.diagnosticDescription.contains("status="))
    }

    @MainActor
    func testRemoveRepositoryPreservesRecordWhenLocalDeletionFails() async throws {
        let repo = RepoConfig(
            repoURL: "https://example.com/delete-failure.git",
            branch: "main",
            authorName: "Test User",
            authorEmail: "test@example.com",
            vaultFolderName: "SyncMD-DeleteFailure-\(UUID().uuidString)",
            authMethod: .none
        )
        let vaultURL = repo.defaultVaultURL
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let writer = RepoPersistenceWriterStub()
        let remover = RepositoryFileRemoverStub(shouldFail: true)
        let state = AppState(
            reposPersistenceWriter: writer,
            repositoryFileRemover: remover,
            loadPersistedState: false
        )
        state.repos = [repo]

        XCTAssertFalse(state.removeRepo(id: repo.id, deleteLocalFiles: true))
        XCTAssertEqual(state.repos.map(\.id), [repo.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultURL.path))
        XCTAssertEqual(remover.removeCallCount, 1)
        XCTAssertEqual(writer.persistCallCount, 0)
        XCTAssertTrue(state.showError)
    }

    @MainActor
    func testRemoveRepositoryRestoresRecordWhenSettingsSaveFails() async {
        let repo = RepoConfig(
            repoURL: "https://example.com/save-failure.git",
            branch: "main",
            authorName: "Test User",
            authorEmail: "test@example.com",
            vaultFolderName: "SyncMD-SaveFailure-\(UUID().uuidString)",
            authMethod: .none
        )
        let writer = RepoPersistenceWriterStub(shouldFail: true)
        let state = AppState(
            reposPersistenceWriter: writer,
            loadPersistedState: false
        )
        state.repos = [repo]

        XCTAssertFalse(state.removeRepo(id: repo.id))
        XCTAssertEqual(state.repos.map(\.id), [repo.id])
        XCTAssertEqual(writer.persistCallCount, 1)
        XCTAssertTrue(state.showError)
    }

    func testGitHubOAuthCredentialRefreshesBeforeAccessTokenExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let credential = GitHubOAuthCredential(
            accessToken: "access",
            expiresIn: 600,
            refreshToken: "refresh",
            refreshTokenExpiresIn: 3_600,
            now: now
        )

        XCTAssertFalse(credential.requiresRefresh(at: now, leeway: 300))
        XCTAssertTrue(
            credential.requiresRefresh(at: now.addingTimeInterval(300), leeway: 300)
        )
        XCTAssertEqual(credential.usableRefreshToken(at: now), "refresh")
    }

    func testGitHubOAuthCredentialRejectsExpiredRefreshToken() {
        let now = Date(timeIntervalSince1970: 1_000)
        let credential = GitHubOAuthCredential(
            accessToken: "access",
            expiresIn: 1,
            refreshToken: "refresh",
            refreshTokenExpiresIn: 1,
            now: now
        )

        XCTAssertTrue(credential.requiresRefresh(at: now.addingTimeInterval(2)))
        XCTAssertNil(credential.usableRefreshToken(at: now.addingTimeInterval(2)))
    }

    func testLongGitOperationProgressUsesSafeCancellationBoundaries() {
        var progress = GitLongOperationProgress(kind: .pull, stage: .transferring)
        XCTAssertTrue(progress.canCancel)
        XCTAssertEqual(progress.fraction, 0.38)

        progress.cancellationRequested = true
        XCTAssertFalse(progress.canCancel)
        XCTAssertTrue(progress.message.contains("safe stopping point"))

        progress = GitLongOperationProgress(kind: .push, stage: .uploading)
        XCTAssertFalse(progress.canCancel, "Push upload has an ambiguous remote outcome and must not be interrupted")
        XCTAssertEqual(progress.fraction, 0.86)
    }

    func testCancellationRequestChangesOnlySafeOperationStage() {
        var progress = GitLongOperationProgress(kind: .clone, stage: .transferring)

        XCTAssertTrue(progress.requestCancellationIfSafe())
        XCTAssertTrue(progress.cancellationRequested)
        XCTAssertFalse(progress.canCancel)

        progress = GitLongOperationProgress(kind: .push, stage: .uploading)
        XCTAssertFalse(progress.requestCancellationIfSafe())
        XCTAssertFalse(progress.cancellationRequested)
    }

    func testGitFailureGuidanceClassifiesAuthenticationAndRemoteRejection() {
        let authentication = GitFailureGuidance.classify(
            error: GitHubError.apiError(403, "Resource not accessible by token")
        )
        XCTAssertEqual(authentication.category, .authentication)
        XCTAssertTrue(authentication.presentationMessage.contains("Suggested action"))

        let rejected = GitFailureGuidance.classify(
            message: "Push failed: protected branch hook declined"
        )
        XCTAssertEqual(rejected.category, .remoteRejected)
    }

    func testGitFailureGuidanceClassifiesNetworkAndRepositoryCorruption() {
        let network = GitFailureGuidance.classify(
            error: URLError(.networkConnectionLost)
        )
        XCTAssertEqual(network.category, .network)

        let corrupted = GitFailureGuidance.classify(
            error: LocalGitError.repositoryCorrupted("object database is corrupt")
        )
        XCTAssertEqual(corrupted.category, .repositoryCorrupted)
    }

    func testGitFailureGuidanceFallsBackToGeneralAdvice() {
        let guidance = GitFailureGuidance.classify(message: "Unexpected Git state")

        XCTAssertEqual(guidance.category, .general)
        XCTAssertFalse(guidance.recoverySuggestion.isEmpty)
    }

    func testAutomatedPullPolicyRequiresProtectedData() {
        let reason = AutomatedPullPolicy.blockReason(
            isProtectedDataAvailable: false,
            isCloned: true,
            requiresExternalStorage: false,
            hasExternalStorageAccess: true
        )

        XCTAssertEqual(reason, .protectedDataUnavailable)
    }

    func testAutomatedPullPolicyRequiresExternalFolderAccess() {
        let reason = AutomatedPullPolicy.blockReason(
            isProtectedDataAvailable: true,
            isCloned: true,
            requiresExternalStorage: true,
            hasExternalStorageAccess: false
        )

        XCTAssertEqual(reason, .externalStorageUnavailable)
    }

    func testAutomatedPullPolicyAllowsAccessibleClone() {
        let reason = AutomatedPullPolicy.blockReason(
            isProtectedDataAvailable: true,
            isCloned: true,
            requiresExternalStorage: true,
            hasExternalStorageAccess: true
        )

        XCTAssertNil(reason)
    }

    func testCloneValidationSkipsTemporarilyUnavailableExternalFolder() {
        XCTAssertFalse(
            AutomatedPullPolicy.shouldValidateCloneDirectory(
                requiresExternalStorage: true,
                hasExternalStorageAccess: false
            )
        )
        XCTAssertTrue(
            AutomatedPullPolicy.shouldValidateCloneDirectory(
                requiresExternalStorage: true,
                hasExternalStorageAccess: true
            )
        )
        XCTAssertTrue(
            AutomatedPullPolicy.shouldValidateCloneDirectory(
                requiresExternalStorage: false,
                hasExternalStorageAccess: false
            )
        )
    }

    func testLegacyLogEntryDecodesWithoutRepositoryContext() throws {
        let id = UUID()
        let payload: [String: Any] = [
            "id": id.uuidString,
            "date": 0.0,
            "level": "info",
            "category": "clone",
            "message": "legacy",
            "detail": NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let entry = try JSONDecoder().decode(LogEntry.self, from: data)

        XCTAssertEqual(entry.id, id)
        XCTAssertNil(entry.repoID)
        XCTAssertNil(entry.repoName)
        XCTAssertNil(entry.operationID)
    }

    func testDebugLoggerRedactsCredentialsAndPrivateKeys() {
        let input = "Authorization: Bearer github_pat_abcdefghijklmnop https://secret@example.com/repo.git?token=ghp_abcdefghijk -----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n-----END OPENSSH PRIVATE KEY-----"
        let output = DebugLogger.redact(input)

        XCTAssertFalse(output.contains("github_pat_abcdefghijklmnop"))
        XCTAssertFalse(output.contains("ghp_abcdefghijk"))
        XCTAssertFalse(output.contains("secret@example.com"))
        XCTAssertFalse(output.contains("OPENSSH PRIVATE KEY"))
        XCTAssertTrue(output.contains("<redacted"))
    }

    @MainActor
    func testFeedbackUsesHugoInkBrand() throws {
        let url = try XCTUnwrap(FeedbackHelper.mailtoURL())
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let subject = components.queryItems?.first(where: { $0.name == "subject" })?.value

        XCTAssertEqual(subject, "HugoInk Feedback")
        XCTAssertTrue(FeedbackHelper.diagnosticsBlock.contains("App: HugoInk "))
    }


    @MainActor
    func testDraftStoreRoundTripsAndRemovesEditorText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileEditorDraftStore(directoryURL: directory)
        let repoID = UUID()
        let fileURL = directory.appendingPathComponent("content/posts/test/index.md")

        try await store.save(content: "draft text", repoID: repoID, fileURL: fileURL)
        let savedDraft = try await store.draft(repoID: repoID, fileURL: fileURL)
        XCTAssertEqual(savedDraft?.content, "draft text")

        try await store.remove(repoID: repoID, fileURL: fileURL)
        let removedDraft = try await store.draft(repoID: repoID, fileURL: fileURL)
        XCTAssertNil(removedDraft)
    }

    @MainActor
    func testDraftStoreSerializesConcurrentIndependentDraftWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileEditorDraftStore(directoryURL: directory)
        let repoID = UUID()
        let firstURL = directory.appendingPathComponent("content/posts/first/index.md")
        let secondURL = directory.appendingPathComponent("content/posts/second/index.md")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await store.save(content: "first draft", repoID: repoID, fileURL: firstURL)
            }
            group.addTask {
                try await store.save(content: "second draft", repoID: repoID, fileURL: secondURL)
            }
            try await group.waitForAll()
        }

        let first = try await store.draft(repoID: repoID, fileURL: firstURL)
        let second = try await store.draft(repoID: repoID, fileURL: secondURL)
        XCTAssertEqual(first?.content, "first draft")
        XCTAssertEqual(second?.content, "second draft")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("editor-drafts"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, 2)
    }

    @MainActor
    func testDraftStoreMigratesLegacyCombinedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repoID = UUID()
        let fileURL = directory.appendingPathComponent("content/posts/legacy/index.md")
        let legacyDraft = FileEditorDraft(
            repoID: repoID,
            filePath: fileURL.standardizedFileURL.path,
            content: "legacy draft",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let legacyFileURL = directory.appendingPathComponent("editor-drafts.json")
        try JSONEncoder().encode([legacyDraft]).write(to: legacyFileURL, options: .atomic)

        let store = FileEditorDraftStore(directoryURL: directory)
        let migrated = try await store.draft(repoID: repoID, fileURL: fileURL)

        XCTAssertEqual(migrated, legacyDraft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFileURL.path))
    }

    func testHugoBundleNameValidationRequiresEnglishSlug() {
        XCTAssertTrue(HugoContentService.isValidBundleName("my-first-post"))
        XCTAssertTrue(HugoContentService.isValidBundleName("post-2026"))
        XCTAssertFalse(HugoContentService.isValidBundleName("My Post"))
        XCTAssertFalse(HugoContentService.isValidBundleName("中文目录"))
        XCTAssertFalse(HugoContentService.isValidBundleName("double--dash"))
        XCTAssertFalse(HugoContentService.isValidBundleName("../post"))
    }

    func testEditorDraftAutosaveDelayUsesSupportedValuesAndSafeDefault() {
        XCTAssertEqual(EditorDraftAutosaveSettings.supportedDelaySeconds, [1, 2, 3, 5])
        XCTAssertEqual(EditorDraftAutosaveSettings.normalizedDelaySeconds(1), 1)
        XCTAssertEqual(EditorDraftAutosaveSettings.normalizedDelaySeconds(5), 5)
        XCTAssertEqual(
            EditorDraftAutosaveSettings.normalizedDelaySeconds(0),
            EditorDraftAutosaveSettings.defaultDelaySeconds
        )
        XCTAssertEqual(EditorDraftAutosaveSettings.defaultDelaySeconds, 2)
    }

    func testHugoArticleValidationFindsMissingAndOversizedImages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("content/posts/test", isDirectory: true)
        let images = bundle.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let fileURL = bundle.appendingPathComponent("index.md")
        try Data([0, 1, 2, 3]).write(to: images.appendingPathComponent("large.jpg"))
        let markdown = "![exists](images/large.jpg)\n![missing](images/missing.jpg)"

        let result = HugoContentService.validateArticleBundle(
            markdown: markdown,
            fileURL: fileURL,
            repositoryRoot: root,
            oversizedThreshold: 3
        )

        XCTAssertEqual(result.missingImagePaths, ["images/missing.jpg"])
        XCTAssertEqual(result.oversizedImageNames, ["large.jpg"])
        XCTAssertFalse(result.isValid)
    }

    func testHugoArticleValidationReportsMissingFrontMatter() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("index.md")

        let result = HugoContentService.validateArticleBundle(
            markdown: "Body without Front Matter",
            fileURL: fileURL,
            repositoryRoot: fileURL.deletingLastPathComponent()
        )

        XCTAssertEqual(result.frontMatterIssues, [.missingOrIncomplete])
        XCTAssertFalse(result.isValid)
    }

    func testHugoArticleValidationReportsMissingTitleAndInvalidDate() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("index.md")
        let markdown = "---\ntitle: \"\"\ndate: someday\ndraft: false\n---\n\nBody"

        let result = HugoContentService.validateArticleBundle(
            markdown: markdown,
            fileURL: fileURL,
            repositoryRoot: fileURL.deletingLastPathComponent()
        )

        XCTAssertEqual(result.frontMatterIssues, [.missingTitle, .invalidDate])
        XCTAssertFalse(result.isValid)
    }

    func testHugoArticleValidationAcceptsValidFrontMatter() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("index.md")
        let markdown = "---\ntitle: \"Post\"\ndate: 2026-08-16T12:00:00+08:00\ndraft: false\n---\n\nBody"

        let result = HugoContentService.validateArticleBundle(
            markdown: markdown,
            fileURL: fileURL,
            repositoryRoot: fileURL.deletingLastPathComponent()
        )

        XCTAssertTrue(result.frontMatterIssues.isEmpty)
        XCTAssertTrue(result.isValid)
    }

    func testHugoArticleValidationTreatsOversizedImageAsWarning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("content/posts/test", isDirectory: true)
        let images = bundle.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let fileURL = bundle.appendingPathComponent("index.md")
        try Data([0, 1, 2, 3]).write(to: images.appendingPathComponent("large.jpg"))
        let markdown = "---\ntitle: \"Post\"\ndraft: false\n---\n\n![image](images/large.jpg)"

        let result = HugoContentService.validateArticleBundle(
            markdown: markdown,
            fileURL: fileURL,
            repositoryRoot: root,
            oversizedThreshold: 3
        )

        XCTAssertEqual(result.oversizedImageNames, ["large.jpg"])
        XCTAssertTrue(result.isValid)
    }

    func testHugoArticleValidationRejectsImagesDirectorySymlinkOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let bundle = repositoryRoot.appendingPathComponent("content/posts/test", isDirectory: true)
        let linkedImages = bundle.appendingPathComponent("images", isDirectory: true)
        let outsideImages = temporaryRoot.appendingPathComponent("outside-images", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideImages, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: outsideImages.appendingPathComponent("private.jpg"))
        try fileManager.createSymbolicLink(at: linkedImages, withDestinationURL: outsideImages)
        let markdown = "---\ntitle: \"Post\"\ndraft: false\n---\n\n![image](images/private.jpg)"

        let result = HugoContentService.validateArticleBundle(
            markdown: markdown,
            fileURL: bundle.appendingPathComponent("index.md"),
            repositoryRoot: repositoryRoot,
            oversizedThreshold: 3
        )

        XCTAssertEqual(result.missingImagePaths, ["images/private.jpg"])
        XCTAssertTrue(result.oversizedImageNames.isEmpty)
        XCTAssertFalse(result.isValid)
    }

    func testArticleImageFormatsIncludeBitmapFiles() {
        for name in ["photo.jpg", "photo.HEIC", "photo.bmp", "photo.tif", "photo.tiff"] {
            XCTAssertTrue(HugoContentService.isSupportedArticleImage(URL(fileURLWithPath: name)), name)
        }
        XCTAssertFalse(HugoContentService.isSupportedArticleImage(URL(fileURLWithPath: "notes.txt")))
    }

    @MainActor
    func testRepositoryDeduplicationPrefersClonedRecord() async {
        let failed = RepoConfig(
            repoURL: "https://github.com/Owner/Notes.git",
            branch: "main",
            authorName: "",
            authorEmail: "",
            vaultFolderName: "failed"
        )
        let cloned = RepoConfig(
            repoURL: "https://github.com/owner/notes/",
            branch: "main",
            authorName: "Writer",
            authorEmail: "writer@example.com",
            vaultFolderName: "notes",
            gitState: GitState(commitSHA: "abc123", treeSHA: "", branch: "main", blobSHAs: [:], lastSyncDate: .now)
        )

        let result = AppState.deduplicatedRepos([failed, cloned, failed])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, cloned.id)
        XCTAssertTrue(result.first?.isCloned == true)
    }

    @discardableResult
    private func commitLocalFixtureChanges(
        using service: LocalGitService,
        message: String,
        authorName: String = "SyncMD Tests",
        authorEmail: String = "tests@example.com"
    ) async throws -> String {
        // Fixture setup should never depend on an expected push failure from a
        // repository without an origin remote. Keep local-git tests deterministic
        // by committing only the staged index when the test is not exercising push.
        try await service.commitLocal(
            message: message,
            authorName: authorName,
            authorEmail: authorEmail
        )
    }

    func testFixtureFactoryBuildsDeterministicCleanDirtyDivergedAndConflictedStates() throws {
        for state in GitFixtureState.allCases {
            let fixtureA = try GitFixtureFactory.make(state: state)
            defer { fixtureA.cleanup() }

            let fixtureB = try GitFixtureFactory.make(state: state)
            defer { fixtureB.cleanup() }

            XCTAssertEqual(fixtureA.snapshot(), fixtureB.snapshot(), "Fixture state \(state.rawValue) should be deterministic")
            XCTAssertEqual(fixtureA.repoInfo.changeCount, state.expectedChangeCount)
            XCTAssertEqual(fixtureB.repoInfo.changeCount, state.expectedChangeCount)
        }
    }

    @MainActor
    func testAppStateDetectChangesUsesInjectedGitRepositoryFactory() async throws {
        let fixture = try GitFixtureFactory.make(state: .dirty)
        defer { fixture.cleanup() }

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        appState.detectChanges(repoID: fixture.repoConfig.id)

        for _ in 0..<20 {
            if appState.changeCounts[fixture.repoConfig.id] == fixture.repoInfo.changeCount {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(appState.changeCounts[fixture.repoConfig.id], fixture.repoInfo.changeCount)
    }

    @MainActor
    func testAppStatePromptsBeforeStagingAutoLFSCandidate() async throws {
        let fixture = try GitFixtureFactory.make(state: .dirty)
        defer { fixture.cleanup() }
        fixture.repository.lfsAutoTrackingCandidatesResult = [
            GitLFSAutoTrackingCandidate(
                path: "Video.mov",
                sizeBytes: 12_000_000,
                patterns: ["*.mov", "*.MOV"],
                reason: .knownBinaryExtension("mov")
            )
        ]

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.stageFile(repoID: fixture.repoConfig.id, path: "Video.mov")

        XCTAssertNotNil(appState.pendingLFSAutoTrackingConfirmation)
        XCTAssertTrue(fixture.repository.stagedPaths.isEmpty)
        XCTAssertEqual(fixture.repository.lfsAutoTrackingCandidatePathRequests, [["Video.mov"]])

        await appState.confirmPendingLFSAutoTracking(useLFS: true)

        XCTAssertNil(appState.pendingLFSAutoTrackingConfirmation)
        XCTAssertEqual(fixture.repository.stagedPaths, ["Video.mov"])
        XCTAssertEqual(fixture.repository.lfsAutoTrackStageFlags, [true])
    }

    func testPullPlanClassifierDistinguishesFastForwardBlockedAndDiverged() {
        XCTAssertEqual(
            LocalGitService.classifyPullAction(ahead: 0, behind: 3, hasLocalChanges: false),
            .fastForward
        )
        XCTAssertEqual(
            LocalGitService.classifyPullAction(ahead: 0, behind: 1, hasLocalChanges: true),
            .blockedByLocalChanges
        )
        XCTAssertEqual(
            LocalGitService.classifyPullAction(ahead: 2, behind: 2, hasLocalChanges: false),
            .diverged
        )
        XCTAssertEqual(
            LocalGitService.classifyPullAction(ahead: 4, behind: 0, hasLocalChanges: false),
            .upToDate
        )
    }

    func testGitRemoteURLParsesGitHubSelfHostedAndSSHRemotes() {
        let gitHubShortcut = GitRemoteURL.parse("owner/repo")
        XCTAssertEqual(gitHubShortcut?.cloneURLString, "https://github.com/owner/repo.git")
        XCTAssertEqual(gitHubShortcut?.repoName, "repo")
        XCTAssertEqual(gitHubShortcut?.ownerName, "owner")
        XCTAssertEqual(gitHubShortcut?.isGitHub, true)

        let selfHosted = GitRemoteURL.parse("https://git.example.com/team/notes.git")
        XCTAssertEqual(selfHosted?.repoName, "notes")
        XCTAssertEqual(selfHosted?.ownerName, "team")
        XCTAssertEqual(selfHosted?.isGitHub, false)
        XCTAssertEqual(selfHosted?.cloneURLString, "https://git.example.com/team/notes.git")

        let ssh = GitRemoteURL.parse("git@git.example.com:team/notes.git")
        XCTAssertEqual(ssh?.repoName, "notes")
        XCTAssertEqual(ssh?.ownerName, "team")
        XCTAssertEqual(ssh?.username, "git")
        XCTAssertEqual(ssh?.isSSH, true)
    }

    func testGitHubRepoParserRequiresExactGitHubHostAndTwoPathComponents() {
        let https = GitHubService.parseRepoURL("https://github.com/example/notes.git")
        XCTAssertEqual(https?.owner, "example")
        XCTAssertEqual(https?.repo, "notes")

        let ssh = GitHubService.parseRepoURL("git@github.com:example/notes.git")
        XCTAssertEqual(ssh?.owner, "example")
        XCTAssertEqual(ssh?.repo, "notes")

        let shortcut = GitHubService.parseRepoURL("example/notes")
        XCTAssertEqual(shortcut?.owner, "example")
        XCTAssertEqual(shortcut?.repo, "notes")

        XCTAssertNil(GitHubService.parseRepoURL("https://notgithub.com/example/notes.git"))
        XCTAssertNil(GitHubService.parseRepoURL("https://github.com.evil.example/example/notes.git"))
        XCTAssertNil(GitHubService.parseRepoURL("https://github.com/group/example/notes.git"))
    }

    func testGitRemoteCredentialsTransportPayloadRoundTripsAndSupportsLegacyPAT() {
        let credentials = GitRemoteCredentials.sshKey(
            username: "git",
            privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nkey\n-----END OPENSSH PRIVATE KEY-----",
            publicKey: "ssh-ed25519 AAAA test",
            passphrase: "secret"
        )

        let decoded = GitRemoteCredentials.fromTransportPayload(credentials.transportPayload)
        XCTAssertEqual(decoded, credentials)

        let legacy = GitRemoteCredentials.fromTransportPayload("ghp_legacy")
        XCTAssertEqual(legacy.method, .gitHubPAT)
        XCTAssertEqual(legacy.username, "x-access-token")
        XCTAssertEqual(legacy.password, "ghp_legacy")
    }

    @MainActor
    func testAppStatePullBlockedByLocalChangesDoesNotMutateRepoState() async throws {
        let fixture = try GitFixtureFactory.make(state: .dirty)
        defer { fixture.cleanup() }

        fixture.repository.pullPlanResult = PullPlan(
            action: .blockedByLocalChanges,
            branch: "main",
            localCommitSHA: fixture.repoConfig.gitState.commitSHA,
            remoteCommitSHA: "9999999999999999999999999999999999999999",
            hasLocalChanges: true,
            aheadBy: 0,
            behindBy: 1
        )

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.pull(repoID: fixture.repoConfig.id)

        XCTAssertEqual(appState.repos.first?.gitState.commitSHA, fixture.repoConfig.gitState.commitSHA)
        XCTAssertEqual(appState.pullOutcomeByRepo[fixture.repoConfig.id]?.kind, .blockedByLocalChanges)
    }

    @MainActor
    func testAppStatePullFastForwardUpdatesCommitAndOutcome() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let newCommit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        fixture.repository.pullPlanResult = PullPlan(
            action: .fastForward,
            branch: "main",
            localCommitSHA: fixture.repoConfig.gitState.commitSHA,
            remoteCommitSHA: newCommit,
            hasLocalChanges: false,
            aheadBy: 0,
            behindBy: 1
        )
        fixture.repository.pullResult = .success(LocalPullResult(updated: true, newCommitSHA: newCommit))

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.pull(repoID: fixture.repoConfig.id)

        XCTAssertEqual(appState.repos.first?.gitState.commitSHA, newCommit)
        XCTAssertEqual(appState.pullOutcomeByRepo[fixture.repoConfig.id]?.kind, .fastForwarded)
    }

    @MainActor
    func testAppStatePullUpdatesRepositoryByIDAfterArrayReordering() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let newCommit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        fixture.repository.pullPlanResult = PullPlan(
            action: .fastForward,
            branch: "main",
            localCommitSHA: fixture.repoConfig.gitState.commitSHA,
            remoteCommitSHA: newCommit,
            hasLocalChanges: false,
            aheadBy: 0,
            behindBy: 1
        )
        fixture.repository.pullResult = .success(LocalPullResult(updated: true, newCommitSHA: newCommit))
        let gate = AsyncTestGate()
        fixture.repository.beforePullPlan = {
            await gate.wait()
        }

        let untouchedCommit = "cccccccccccccccccccccccccccccccccccccccc"
        let otherRepo = RepoConfig(
            repoURL: "https://example.com/other.git",
            branch: "main",
            authorName: "Other User",
            authorEmail: "other@example.com",
            vaultFolderName: "SyncMD-Other-\(UUID().uuidString)",
            authMethod: .none,
            gitState: GitState(
                commitSHA: untouchedCommit,
                treeSHA: "",
                branch: "main",
                blobSHAs: [:],
                lastSyncDate: .distantPast
            )
        )

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            gitOperationCoordinator: GitOperationCoordinator(),
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig, otherRepo]

        let pullTask = Task {
            await appState.pull(repoID: fixture.repoConfig.id, showsProgressDelay: false)
        }
        for _ in 0..<100 {
            if await gate.isWaiting { break }
            await Task.yield()
        }
        let operationDidSuspend = await gate.isWaiting
        XCTAssertTrue(operationDidSuspend)

        appState.repos.swapAt(0, 1)
        await gate.open()
        let pullSucceeded = await pullTask.value
        XCTAssertTrue(pullSucceeded)

        XCTAssertEqual(appState.repo(id: fixture.repoConfig.id)?.gitState.commitSHA, newCommit)
        XCTAssertEqual(appState.repo(id: otherRepo.id)?.gitState.commitSHA, untouchedCommit)
    }

    @MainActor
    func testAppStatePushCurrentBranchPushesAheadCommitWithoutNewChanges() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        fixture.repository.repoInfoResult = LocalRepoInfo(
            branch: "main",
            commitSHA: fixture.repoConfig.gitState.commitSHA,
            changeCount: 0,
            syncState: .upToDate,
            statusEntries: []
        )

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]
        appState.syncStateByRepo[fixture.repoConfig.id] = .ahead

        let succeeded = await appState.pushCurrentBranch(repoID: fixture.repoConfig.id)

        XCTAssertTrue(succeeded)
        XCTAssertTrue(fixture.repository.didPushCurrentBranch)
        XCTAssertEqual(appState.syncStateByRepo[fixture.repoConfig.id], .upToDate)
    }

    func testSSHHostKeyTrustRequestFormatsUnknownAndChangedHostMessages() {
        let unknown = SSHHostKeyTrustRequest(
            repoID: UUID(),
            operation: .clone,
            trustError: .unknownHostKey(host: "forgejo.lan", port: 2222, fingerprint: "SHA256:unknown")
        )
        XCTAssertEqual(unknown.title, "Trust SSH Host?")
        XCTAssertEqual(unknown.confirmButtonTitle, "Trust Host")
        XCTAssertEqual(unknown.host, "forgejo.lan")
        XCTAssertEqual(unknown.port, 2222)
        XCTAssertEqual(unknown.fingerprintToTrust, "SHA256:unknown")
        XCTAssertTrue(unknown.message.contains("forgejo.lan:2222"))
        XCTAssertTrue(unknown.message.contains("SHA256:unknown"))
        XCTAssertTrue(unknown.message.contains("Only trust it"))

        let changed = SSHHostKeyTrustRequest(
            repoID: UUID(),
            operation: .pull,
            trustError: .changedHostKey(
                host: "forgejo.lan",
                port: 22,
                expectedFingerprint: "SHA256:old",
                actualFingerprint: "SHA256:new"
            )
        )
        XCTAssertEqual(changed.title, "SSH Host Key Changed")
        XCTAssertEqual(changed.confirmButtonTitle, "Trust New Key")
        XCTAssertEqual(changed.host, "forgejo.lan")
        XCTAssertEqual(changed.port, 22)
        XCTAssertEqual(changed.fingerprintToTrust, "SHA256:new")
        XCTAssertTrue(changed.message.contains("Previously trusted"))
        XCTAssertTrue(changed.message.contains("SHA256:old"))
        XCTAssertTrue(changed.message.contains("SHA256:new"))
        XCTAssertTrue(changed.message.contains("Do not trust"))
    }

    @MainActor
    func testAppStateCloneUnknownSSHHostKeyPromptsInsteadOfShowingGenericError() async throws {
        let repoInfo = LocalRepoInfo(branch: "main", commitSHA: "1111111111111111111111111111111111111111", changeCount: 0)
        let repository = FakeGitRepository(repoInfoResult: repoInfo)
        let trustError = GitLFSSSHHostKeyTrustError.unknownHostKey(
            host: "forgejo.example.com",
            port: 22,
            fingerprint: "SHA256:clone-unknown"
        )
        repository.cloneResults = [.failure(LocalGitError.sshHostKeyTrustRequired(trustError))]
        let repo = RepoConfig(
            repoURL: "git@forgejo.example.com:team/notes.git",
            branch: "main",
            authorName: "Test User",
            authorEmail: "test@example.com",
            vaultFolderName: "SyncMD-SSHHostKey-\(UUID().uuidString)",
            authMethod: .sshKey,
            authUsername: "git"
        )
        let trustURL = FileManager.default.temporaryDirectory.appendingPathComponent("SyncMD-Trust-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: trustURL) }
        let appState = AppState(
            gitRepositoryFactory: { _ in repository },
            sshHostKeyTrustStore: GitLFSSSHHostKeyFileTrustStore(fileURL: trustURL),
            loadPersistedState: false
        )
        appState.repos = [repo]

        await appState.clone(repoID: repo.id)

        XCTAssertEqual(repository.cloneRemoteURLs, ["git@forgejo.example.com:team/notes.git"])
        XCTAssertEqual(appState.pendingSSHHostKeyTrustRequest?.repoID, repo.id)
        XCTAssertEqual(appState.pendingSSHHostKeyTrustRequest?.operation, .clone)
        XCTAssertEqual(appState.pendingSSHHostKeyTrustRequest?.trustError, trustError)
        XCTAssertFalse(appState.showError)
        XCTAssertNil(appState.lastError)
    }

    @MainActor
    func testCloneRefusesToDeleteNonEmptyDestination() async throws {
        let repository = FakeGitRepository(repoInfoResult: LocalRepoInfo(
            branch: "main",
            commitSHA: "1111111111111111111111111111111111111111",
            changeCount: 0
        ))
        let repo = RepoConfig(
            repoURL: "https://github.com/example/protected.git",
            branch: "main",
            authorName: "Test User",
            authorEmail: "test@example.com",
            vaultFolderName: "SyncMD-Protected-\(UUID().uuidString)",
            authMethod: .none
        )
        let destination = repo.defaultVaultURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let markerFile = destination.appendingPathComponent("uncommitted.md")
        try Data("do not delete".utf8).write(to: markerFile)
        defer { try? FileManager.default.removeItem(at: destination) }

        let appState = AppState(gitRepositoryFactory: { _ in repository }, loadPersistedState: false)
        appState.repos = [repo]
        await appState.clone(repoID: repo.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: markerFile.path))
        XCTAssertTrue(repository.cloneRemoteURLs.isEmpty)
        XCTAssertTrue(appState.showError)
    }

    @MainActor
    func testTrustingPendingSSHHostKeyPersistsFingerprintAndRetriesClone() async throws {
        let repoInfo = LocalRepoInfo(branch: "main", commitSHA: "2222222222222222222222222222222222222222", changeCount: 0)
        let repository = FakeGitRepository(repoInfoResult: repoInfo)
        let trustedFingerprint = "SHA256:clone-trusted-\(UUID().uuidString)"
        let trustError = GitLFSSSHHostKeyTrustError.unknownHostKey(
            host: "forgejo-retry.example.com",
            port: 2222,
            fingerprint: trustedFingerprint
        )
        let clonedCommit = "3333333333333333333333333333333333333333"
        repository.cloneResults = [
            .failure(LocalGitError.sshHostKeyTrustRequired(trustError)),
            .success(LocalCloneResult(commitSHA: clonedCommit, branch: "main", fileCount: 7))
        ]
        let repo = RepoConfig(
            repoURL: "ssh://git@forgejo-retry.example.com:2222/team/notes.git",
            branch: "main",
            authorName: "Test User",
            authorEmail: "test@example.com",
            vaultFolderName: "SyncMD-SSHHostKey-Retry-\(UUID().uuidString)",
            authMethod: .sshKey,
            authUsername: "git"
        )
        let trustURL = FileManager.default.temporaryDirectory.appendingPathComponent("SyncMD-Trust-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: trustURL) }
        let trustStore = GitLFSSSHHostKeyFileTrustStore(fileURL: trustURL)
        let appState = AppState(
            gitRepositoryFactory: { _ in repository },
            sshHostKeyTrustStore: trustStore,
            loadPersistedState: false
        )
        appState.repos = [repo]

        await appState.clone(repoID: repo.id)
        XCTAssertNotNil(appState.pendingSSHHostKeyTrustRequest)

        await appState.trustPendingSSHHostKeyAndRetry()

        XCTAssertNil(appState.pendingSSHHostKeyTrustRequest)
        XCTAssertEqual(repository.cloneRemoteURLs.count, 2)
        XCTAssertEqual(trustStore.trustedFingerprint(forHost: "forgejo-retry.example.com", port: 2222), trustedFingerprint)
        XCTAssertEqual(appState.repos.first?.gitState.commitSHA, clonedCommit)
        XCTAssertFalse(appState.showError)
    }

    @MainActor
    func testCancelPendingSSHHostKeyTrustDoesNotPersistOrRetry() async throws {
        let repoInfo = LocalRepoInfo(branch: "main", commitSHA: "4444444444444444444444444444444444444444", changeCount: 0)
        let repository = FakeGitRepository(repoInfoResult: repoInfo)
        let trustError = GitLFSSSHHostKeyTrustError.unknownHostKey(
            host: "forgejo-cancel.example.com",
            port: 22,
            fingerprint: "SHA256:cancelled"
        )
        repository.cloneResults = [.failure(LocalGitError.sshHostKeyTrustRequired(trustError))]
        let repo = RepoConfig(
            repoURL: "git@forgejo-cancel.example.com:team/notes.git",
            branch: "main",
            authorName: "Test User",
            authorEmail: "test@example.com",
            vaultFolderName: "SyncMD-SSHHostKey-Cancel-\(UUID().uuidString)",
            authMethod: .sshKey,
            authUsername: "git"
        )
        let trustURL = FileManager.default.temporaryDirectory.appendingPathComponent("SyncMD-Trust-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: trustURL) }
        let trustStore = GitLFSSSHHostKeyFileTrustStore(fileURL: trustURL)
        let appState = AppState(
            gitRepositoryFactory: { _ in repository },
            sshHostKeyTrustStore: trustStore,
            loadPersistedState: false
        )
        appState.repos = [repo]

        await appState.clone(repoID: repo.id)
        appState.cancelPendingSSHHostKeyTrust()

        XCTAssertNil(appState.pendingSSHHostKeyTrustRequest)
        XCTAssertEqual(repository.cloneRemoteURLs.count, 1)
        XCTAssertNil(trustStore.trustedFingerprint(forHost: "forgejo-cancel.example.com", port: 22))
    }

    @MainActor
    func testAppStatePullSSHHostKeyFailurePromptsAndRetryUsesTrustedFingerprint() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }
        let trustError = GitLFSSSHHostKeyTrustError.unknownHostKey(
            host: "forgejo-pull.example.com",
            port: 22,
            fingerprint: "SHA256:pull"
        )
        fixture.repository.pullPlanError = LocalGitError.sshHostKeyTrustRequired(trustError)
        let trustURL = FileManager.default.temporaryDirectory.appendingPathComponent("SyncMD-Trust-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: trustURL) }
        let trustStore = GitLFSSSHHostKeyFileTrustStore(fileURL: trustURL)
        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            sshHostKeyTrustStore: trustStore,
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        let firstResult = await appState.pull(repoID: fixture.repoConfig.id)
        XCTAssertFalse(firstResult)
        XCTAssertEqual(appState.pendingSSHHostKeyTrustRequest?.operation, .pull)
        XCTAssertEqual(appState.pendingSSHHostKeyTrustRequest?.trustError, trustError)
        XCTAssertEqual(appState.pullOutcomeByRepo[fixture.repoConfig.id]?.kind, .failed)

        fixture.repository.pullPlanError = nil
        fixture.repository.pullPlanResult = PullPlan(
            action: .upToDate,
            branch: "main",
            localCommitSHA: fixture.repoConfig.gitState.commitSHA,
            remoteCommitSHA: fixture.repoConfig.gitState.commitSHA,
            hasLocalChanges: false,
            aheadBy: 0,
            behindBy: 0
        )
        await appState.trustPendingSSHHostKeyAndRetry()

        XCTAssertNil(appState.pendingSSHHostKeyTrustRequest)
        XCTAssertEqual(fixture.repository.pullPlanCallCount, 2)
        XCTAssertEqual(trustStore.trustedFingerprint(forHost: "forgejo-pull.example.com", port: 22), "SHA256:pull")
        XCTAssertEqual(appState.pullOutcomeByRepo[fixture.repoConfig.id]?.kind, .upToDate)
    }

    @MainActor
    func testAppStatePushCurrentBranchSSHHostKeyFailurePromptsAndRetry() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }
        let trustError = GitLFSSSHHostKeyTrustError.changedHostKey(
            host: "forgejo-push.example.com",
            port: 2200,
            expectedFingerprint: "SHA256:old-push",
            actualFingerprint: "SHA256:new-push"
        )
        fixture.repository.pushCurrentBranchResult = .failure(LocalGitError.sshHostKeyTrustRequired(trustError))
        fixture.repository.repoInfoResult = LocalRepoInfo(
            branch: "main",
            commitSHA: fixture.repoConfig.gitState.commitSHA,
            changeCount: 0,
            syncState: .upToDate,
            statusEntries: []
        )
        let trustURL = FileManager.default.temporaryDirectory.appendingPathComponent("SyncMD-Trust-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: trustURL) }
        let trustStore = GitLFSSSHHostKeyFileTrustStore(fileURL: trustURL)
        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            sshHostKeyTrustStore: trustStore,
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]
        appState.syncStateByRepo[fixture.repoConfig.id] = .ahead

        let firstResult = await appState.pushCurrentBranch(repoID: fixture.repoConfig.id)
        XCTAssertFalse(firstResult)
        XCTAssertEqual(appState.pendingSSHHostKeyTrustRequest?.operation, .pushCurrentBranch)
        XCTAssertEqual(appState.pendingSSHHostKeyTrustRequest?.trustError, trustError)

        fixture.repository.pushCurrentBranchResult = .success(())
        await appState.trustPendingSSHHostKeyAndRetry()

        XCTAssertNil(appState.pendingSSHHostKeyTrustRequest)
        XCTAssertEqual(fixture.repository.pushCurrentBranchCallCount, 2)
        XCTAssertEqual(trustStore.trustedFingerprint(forHost: "forgejo-push.example.com", port: 2200), "SHA256:new-push")
        XCTAssertEqual(appState.syncStateByRepo[fixture.repoConfig.id], .upToDate)
    }

    @MainActor
    func testAppStateCommitAndPushSSHHostKeyFailurePreservesCommitMessageOnRetry() async throws {
        let fixture = try GitFixtureFactory.make(state: .dirty)
        defer { fixture.cleanup() }
        let trustError = GitLFSSSHHostKeyTrustError.unknownHostKey(
            host: "forgejo-commit-push.example.com",
            port: 22,
            fingerprint: "SHA256:commit-push"
        )
        fixture.repository.commitAndPushResult = .failure(LocalGitError.sshHostKeyTrustRequired(trustError))
        let trustURL = FileManager.default.temporaryDirectory.appendingPathComponent("SyncMD-Trust-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: trustURL) }
        let trustStore = GitLFSSSHHostKeyFileTrustStore(fileURL: trustURL)
        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            sshHostKeyTrustStore: trustStore,
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        let firstResult = await appState.push(repoID: fixture.repoConfig.id, message: "sync notes")
        XCTAssertFalse(firstResult)
        XCTAssertEqual(appState.pendingSSHHostKeyTrustRequest?.operation, .pushCommit(message: "sync notes"))
        XCTAssertEqual(appState.pendingSSHHostKeyTrustRequest?.trustError, trustError)
        XCTAssertEqual(fixture.repository.commitAndPushMessages, ["sync notes"])

        fixture.repository.commitAndPushResult = .success(LocalPushResult(commitSHA: "5555555555555555555555555555555555555555"))
        await appState.trustPendingSSHHostKeyAndRetry()

        XCTAssertNil(appState.pendingSSHHostKeyTrustRequest)
        XCTAssertEqual(fixture.repository.commitAndPushMessages, ["sync notes", "sync notes"])
        XCTAssertEqual(trustStore.trustedFingerprint(forHost: "forgejo-commit-push.example.com", port: 22), "SHA256:commit-push")
        XCTAssertEqual(appState.repos.first?.gitState.commitSHA, "5555555555555555555555555555555555555555")
    }

    @MainActor
    func testAppStateRetryPushReusesStagingWhenCommitWasNotCreated() async throws {
        let fixture = try GitFixtureFactory.make(state: .dirty)
        defer { fixture.cleanup() }
        fixture.repository.commitAndPushResult = .failure(LocalGitError.pushFailed("network down"))
        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]
        appState.syncStateByRepo[fixture.repoConfig.id] = .ahead

        let firstResult = await appState.push(repoID: fixture.repoConfig.id, message: "publish article")

        XCTAssertFalse(firstResult)
        XCTAssertEqual(fixture.repository.commitAndPushMessages, ["publish article"])

        fixture.repository.commitAndPushResult = .success(
            LocalPushResult(commitSHA: "6666666666666666666666666666666666666666")
        )
        let retryResult = await appState.retryPush(repoID: fixture.repoConfig.id, message: "publish article")

        XCTAssertTrue(retryResult)
        XCTAssertEqual(fixture.repository.commitAndPushMessages, ["publish article", "publish article"])
        XCTAssertEqual(fixture.repository.pushCurrentBranchCallCount, 0)
    }

    @MainActor
    func testAppStateRetryPushDoesNotCreateDuplicateCommitAfterPushFailure() async throws {
        let fixture = try GitFixtureFactory.make(state: .dirty)
        defer { fixture.cleanup() }
        let localCommitSHA = "7777777777777777777777777777777777777777"
        fixture.repository.commitAndPushFailureCommitSHA = localCommitSHA
        fixture.repository.commitAndPushResult = .failure(LocalGitError.pushFailed("network down"))
        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        let firstResult = await appState.push(repoID: fixture.repoConfig.id, message: "publish article")

        XCTAssertFalse(firstResult)
        XCTAssertEqual(appState.repos.first?.gitState.commitSHA, localCommitSHA)
        XCTAssertEqual(appState.syncStateByRepo[fixture.repoConfig.id], .ahead)

        fixture.repository.pushCurrentBranchResult = .success(())
        fixture.repository.repoInfoResult = LocalRepoInfo(
            branch: "main",
            commitSHA: localCommitSHA,
            changeCount: 0,
            syncState: .upToDate,
            statusEntries: []
        )
        let retryResult = await appState.retryPush(repoID: fixture.repoConfig.id, message: "publish article")

        XCTAssertTrue(retryResult)
        XCTAssertEqual(fixture.repository.commitAndPushMessages, ["publish article"])
        XCTAssertEqual(fixture.repository.pushCurrentBranchCallCount, 1)
    }

    @MainActor
    func testAppStateNonSSHHostKeyErrorsStillShowRegularErrorAlert() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }
        fixture.repository.pullPlanError = LocalGitError.fetchFailed("network down")
        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        let result = await appState.pull(repoID: fixture.repoConfig.id)

        XCTAssertFalse(result)
        XCTAssertNil(appState.pendingSSHHostKeyTrustRequest)
        XCTAssertTrue(appState.showError)
        XCTAssertEqual(appState.lastError, LocalGitError.fetchFailed("network down").localizedDescription)
    }

    @MainActor
    func testAppStatePullWithRebaseUpdatesCommitAndOutcome() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let rebasedCommit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        fixture.repository.pullPlanResult = PullPlan(
            action: .diverged,
            branch: "main",
            localCommitSHA: fixture.repoConfig.gitState.commitSHA,
            remoteCommitSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            hasLocalChanges: false,
            aheadBy: 1,
            behindBy: 1
        )
        fixture.repository.rebaseResult = .success(LocalPullResult(updated: true, newCommitSHA: rebasedCommit))

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.pullWithRebase(repoID: fixture.repoConfig.id)

        XCTAssertEqual(appState.repos.first?.gitState.commitSHA, rebasedCommit)
        XCTAssertEqual(appState.pullOutcomeByRepo[fixture.repoConfig.id]?.kind, .rebased)
    }

    @MainActor
    func testAppStatePullWithRebaseConflictStoresOutcome() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        fixture.repository.pullPlanResult = PullPlan(
            action: .diverged,
            branch: "main",
            localCommitSHA: fixture.repoConfig.gitState.commitSHA,
            remoteCommitSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            hasLocalChanges: false,
            aheadBy: 1,
            behindBy: 1
        )
        fixture.repository.rebaseResult = .failure(LocalGitError.rebaseConflictsDetected)
        fixture.repository.conflictSessionResult = ConflictSession(kind: .rebase, unmergedPaths: ["README.md"])

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.pullWithRebase(repoID: fixture.repoConfig.id)

        XCTAssertEqual(appState.pullOutcomeByRepo[fixture.repoConfig.id]?.kind, .rebaseConflicts)
        XCTAssertEqual(appState.conflictSessionByRepo[fixture.repoConfig.id]?.kind, .rebase)
    }

    @MainActor
    func testAppStateLoadUnifiedDiffStoresDiffByRepo() async throws {
        let fixture = try GitFixtureFactory.make(state: .dirty)
        defer { fixture.cleanup() }

        let expectedDiff = UnifiedDiffResult(
            files: [
                GitFileDiff(
                    path: "Inbox.md",
                    oldPath: "Inbox.md",
                    newPath: "Inbox.md",
                    changeType: .modified,
                    isBinary: false,
                    patch: "diff --git a/Inbox.md b/Inbox.md\n"
                )
            ],
            rawPatch: "diff --git a/Inbox.md b/Inbox.md\n"
        )
        fixture.repository.diffResult = expectedDiff

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.loadUnifiedDiff(repoID: fixture.repoConfig.id)

        XCTAssertEqual(appState.diffByRepo[fixture.repoConfig.id], expectedDiff)
    }

    @MainActor
    func testAppStateLoadCommitHistoryStoresAndPaginatesByRepo() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let pageData = [
            GitCommitSummary(
                oid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                shortOID: "aaaaaaa",
                message: "Third",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                authoredDate: Date(timeIntervalSince1970: 300)
            ),
            GitCommitSummary(
                oid: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                shortOID: "bbbbbbb",
                message: "Second",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                authoredDate: Date(timeIntervalSince1970: 200)
            ),
            GitCommitSummary(
                oid: "cccccccccccccccccccccccccccccccccccccccc",
                shortOID: "ccccccc",
                message: "First",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                authoredDate: Date(timeIntervalSince1970: 100)
            )
        ]

        fixture.repository.commitHistoryResult = pageData

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.loadCommitHistory(repoID: fixture.repoConfig.id, pageSize: 2, reset: true)

        XCTAssertEqual(appState.commitHistoryByRepo[fixture.repoConfig.id]?.map(\.oid), [
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        ])
        XCTAssertEqual(appState.commitHistoryHasMoreByRepo[fixture.repoConfig.id], true)

        await appState.loadCommitHistory(repoID: fixture.repoConfig.id, pageSize: 2, reset: false)

        XCTAssertEqual(appState.commitHistoryByRepo[fixture.repoConfig.id]?.count, 3)
        XCTAssertEqual(appState.commitHistoryHasMoreByRepo[fixture.repoConfig.id], false)
    }

    @MainActor
    func testAppStateSaveApplyPopStashDelegatesToGitRepository() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.saveStash(repoID: fixture.repoConfig.id, message: "WIP", includeUntracked: true)
        await appState.applyStash(repoID: fixture.repoConfig.id, index: 0, reinstateIndex: false)
        await appState.popStash(repoID: fixture.repoConfig.id, index: 0, reinstateIndex: false)

        XCTAssertEqual(fixture.repository.savedStashes.count, 1)
        XCTAssertEqual(fixture.repository.savedStashes.first?.message, "WIP")
        XCTAssertEqual(fixture.repository.appliedStashIndices, [0])
        XCTAssertEqual(fixture.repository.poppedStashIndices, [0])
    }

    @MainActor
    func testAppStateTagLifecycleDelegatesToGitRepository() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        // Create lightweight
        await appState.createTag(repoID: fixture.repoConfig.id, name: "v1.0")
        XCTAssertEqual(fixture.repository.createdTags.count, 1)
        XCTAssertEqual(fixture.repository.createdTags.first?.name, "v1.0")
        XCTAssertNil(fixture.repository.createdTags.first?.message)

        // Create annotated
        await appState.createTag(repoID: fixture.repoConfig.id, name: "v2.0", message: "Release 2")
        XCTAssertEqual(fixture.repository.createdTags.count, 2)
        XCTAssertEqual(fixture.repository.createdTags[1].message, "Release 2")

        // Push
        await appState.pushTag(repoID: fixture.repoConfig.id, name: "v1.0")
        XCTAssertEqual(fixture.repository.pushedTagNames, ["v1.0"])

        // Delete
        await appState.deleteTag(repoID: fixture.repoConfig.id, name: "v1.0")
        XCTAssertEqual(fixture.repository.deletedTagNames, ["v1.0"])
    }

    @MainActor
    func testAppStateLoadTagsStoresTagsByRepo() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        fixture.repository.tagsResult = [
            GitTag(name: "refs/tags/v1.0", oid: "aabb", kind: .lightweight, message: nil, targetOID: "ccdd"),
            GitTag(name: "refs/tags/v2.0", oid: "eeff", kind: .annotated, message: "Release 2", targetOID: "1122")
        ]

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.loadTags(repoID: fixture.repoConfig.id)

        XCTAssertEqual(appState.tagsByRepo[fixture.repoConfig.id]?.count, 2)
        XCTAssertEqual(appState.tagsByRepo[fixture.repoConfig.id]?.first?.shortName, "v1.0")
    }

    @MainActor
    func testAppStateDropStashDelegatesToGitRepository() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        fixture.repository.stashEntriesResult = [
            GitStashEntry(index: 0, oid: "aabbcc", message: "WIP: feature")
        ]

        await appState.dropStash(repoID: fixture.repoConfig.id, index: 0)

        XCTAssertEqual(fixture.repository.droppedStashIndices, [0])
        XCTAssertTrue(fixture.repository.stashEntriesResult.isEmpty)
    }

    @MainActor
    func testAppStateLoadCommitDetailStoresByRepoAndOID() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        fixture.repository.commitDetailResultByOID[oid] = GitCommitDetail(
            oid: oid,
            message: "Add README",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com",
            authoredDate: Date(timeIntervalSince1970: 100),
            committerName: "SyncMD Tests",
            committerEmail: "tests@example.com",
            committedDate: Date(timeIntervalSince1970: 100),
            parentOIDs: [],
            changedFiles: [
                GitCommitFileChange(path: "README.md", oldPath: nil, newPath: "README.md", changeType: .added)
            ]
        )

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.loadCommitDetail(repoID: fixture.repoConfig.id, oid: oid)

        XCTAssertEqual(appState.commitDetailByRepo[fixture.repoConfig.id]?[oid]?.message, "Add README")
    }

    @MainActor
    func testAppStateStageAndUnstageDelegateToGitRepository() async throws {
        let fixture = try GitFixtureFactory.make(state: .dirty)
        defer { fixture.cleanup() }

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.stageFile(repoID: fixture.repoConfig.id, path: "Inbox.md")
        await appState.unstageFile(repoID: fixture.repoConfig.id, path: "Inbox.md")

        XCTAssertEqual(fixture.repository.stagedPaths, ["Inbox.md"])
        XCTAssertEqual(fixture.repository.unstagedPaths, ["Inbox.md"])
    }

    @MainActor
    func testStageArticleBundleStagesCurrentLeafBundleAndRepositoryConfiguration() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }
        fixture.repository.repoInfoResult = LocalRepoInfo(
            branch: "main",
            commitSHA: fixture.repoConfig.gitState.commitSHA,
            changeCount: 5,
            syncState: .unknown,
            statusEntries: [
                GitStatusEntry(path: "content/posts/one/index.md", indexStatus: nil, workTreeStatus: .modified),
                GitStatusEntry(path: "content/posts/one/images/cover.jpg", indexStatus: nil, workTreeStatus: .untracked),
                GitStatusEntry(path: "content/posts/two/index.md", indexStatus: nil, workTreeStatus: .modified),
                GitStatusEntry(path: ".gitsync-hugo.json", indexStatus: nil, workTreeStatus: .modified),
                GitStatusEntry(path: "README.md", indexStatus: nil, workTreeStatus: .modified)
            ]
        )
        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]
        let articleURL = appState.vaultURL(for: fixture.repoConfig.id)
            .appendingPathComponent("content/posts/one/index.md")

        let staged = await appState.stageArticleBundle(repoID: fixture.repoConfig.id, fileURL: articleURL)

        XCTAssertTrue(staged)
        XCTAssertEqual(fixture.repository.stagedPaths, [
            "content/posts/one/index.md",
            "content/posts/one/images/cover.jpg",
            ".gitsync-hugo.json"
        ])
    }

    @MainActor
    func testStageArticleBundleDoesNotStageRepositoryConfigurationWithoutArticleChanges() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }
        fixture.repository.repoInfoResult = LocalRepoInfo(
            branch: "main",
            commitSHA: fixture.repoConfig.gitState.commitSHA,
            changeCount: 1,
            syncState: .unknown,
            statusEntries: [
                GitStatusEntry(path: ".gitsync-hugo.json", indexStatus: nil, workTreeStatus: .modified)
            ]
        )
        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]
        let articleURL = appState.vaultURL(for: fixture.repoConfig.id)
            .appendingPathComponent("content/posts/one/index.md")

        let staged = await appState.stageArticleBundle(repoID: fixture.repoConfig.id, fileURL: articleURL)

        XCTAssertFalse(staged)
        XCTAssertTrue(fixture.repository.stagedPaths.isEmpty)
    }

    @MainActor
    func testArticleBundleChangeDetectionIgnoresOtherArticles() async {
        let entries = [
            GitStatusEntry(path: "content/posts/one/images/cover.jpg", indexStatus: .added, workTreeStatus: nil),
            GitStatusEntry(path: "content/posts/two/index.md", indexStatus: nil, workTreeStatus: .modified)
        ]

        XCTAssertEqual(
            AppState.articleBundleEntries(in: entries, bundlePath: "content/posts/one").map(\.path),
            ["content/posts/one/images/cover.jpg"]
        )
        XCTAssertEqual(
            AppState.articleBundleEntries(in: entries, bundlePath: "content/posts/two").map(\.path),
            ["content/posts/two/index.md"]
        )
        XCTAssertTrue(AppState.articleBundleEntries(in: entries, bundlePath: "content/posts/three").isEmpty)
    }

    @MainActor
    func testAppStateLoadBranchesStoresInventoryByRepo() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let expected = BranchInventory(
            local: [
                GitBranchInfo(
                    name: "refs/heads/main",
                    shortName: "main",
                    scope: .local,
                    isCurrent: true,
                    upstreamShortName: "origin/main",
                    aheadBy: 0,
                    behindBy: 0
                )
            ],
            remote: [
                GitBranchInfo(
                    name: "refs/remotes/origin/main",
                    shortName: "origin/main",
                    scope: .remote,
                    isCurrent: false,
                    upstreamShortName: nil,
                    aheadBy: nil,
                    behindBy: nil
                )
            ],
            detachedHeadOID: nil
        )

        fixture.repository.branchInventoryResult = expected

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.loadBranches(repoID: fixture.repoConfig.id)

        XCTAssertEqual(appState.branchesByRepo[fixture.repoConfig.id], expected)
    }

    @MainActor
    func testAppStateCreateSwitchDeleteBranchDelegatesToGitRepository() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.createBranch(repoID: fixture.repoConfig.id, name: "feature")
        await appState.switchBranch(repoID: fixture.repoConfig.id, name: "feature")
        await appState.deleteBranch(repoID: fixture.repoConfig.id, name: "feature")

        XCTAssertEqual(fixture.repository.createdBranches, ["feature"])
        XCTAssertEqual(fixture.repository.switchedBranches, ["feature"])
        XCTAssertEqual(fixture.repository.deletedBranches, ["feature"])
    }

    @MainActor
    func testAppStateMergeBranchUpdatesCommitFromResult() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let mergedSHA = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        fixture.repository.mergeResult = MergeResult(kind: .fastForwarded, sourceBranch: "feature", newCommitSHA: mergedSHA)

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.mergeBranch(repoID: fixture.repoConfig.id, from: "feature")

        XCTAssertEqual(appState.repos.first?.gitState.commitSHA, mergedSHA)
    }

    @MainActor
    func testAppStateRevertCommitUpdatesCommitOnSuccessfulRevert() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let revertedSHA = "dddddddddddddddddddddddddddddddddddddddd"
        fixture.repository.revertResult = RevertResult(
            kind: .reverted,
            targetOID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            newCommitSHA: revertedSHA
        )

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.revertCommit(repoID: fixture.repoConfig.id, oid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", message: "Revert")

        XCTAssertEqual(appState.repos.first?.gitState.commitSHA, revertedSHA)
    }

    @MainActor
    func testAppStateCompleteMergeUpdatesCommitFromResult() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let finalizedSHA = "cccccccccccccccccccccccccccccccccccccccc"
        fixture.repository.mergeFinalizeResult = MergeFinalizeResult(newCommitSHA: finalizedSHA)

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.completeMerge(repoID: fixture.repoConfig.id, message: "Resolve merge")

        XCTAssertEqual(appState.repos.first?.gitState.commitSHA, finalizedSHA)
    }

    @MainActor
    func testAppStateAbortMergeDelegatesToGitRepository() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.abortMerge(repoID: fixture.repoConfig.id)

        XCTAssertTrue(fixture.repository.didAbortMerge)
    }

    @MainActor
    func testAppStateLoadConflictSessionStoresByRepo() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        fixture.repository.conflictSessionResult = ConflictSession(
            kind: .merge,
            unmergedPaths: ["README.md", "notes/today.md"]
        )

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.loadConflictSession(repoID: fixture.repoConfig.id)

        XCTAssertEqual(appState.conflictSessionByRepo[fixture.repoConfig.id]?.kind, .merge)
        XCTAssertEqual(appState.conflictSessionByRepo[fixture.repoConfig.id]?.unmergedPaths, ["README.md", "notes/today.md"])
    }

    @MainActor
    func testAppStateResolveConflictFileDelegatesToGitRepository() async throws {
        let fixture = try GitFixtureFactory.make(state: .clean)
        defer { fixture.cleanup() }

        fixture.repository.conflictSessionResult = ConflictSession(kind: .merge, unmergedPaths: ["README.md"])

        let appState = AppState(
            gitRepositoryFactory: { _ in fixture.repository },
            loadPersistedState: false
        )
        appState.repos = [fixture.repoConfig]

        await appState.resolveConflictFile(repoID: fixture.repoConfig.id, path: "README.md", strategy: .ours)

        XCTAssertEqual(fixture.repository.resolvedConflicts.count, 1)
        XCTAssertEqual(fixture.repository.resolvedConflicts.first?.path, "README.md")
        XCTAssertEqual(fixture.repository.resolvedConflicts.first?.strategy, .ours)
    }

    func testLocalGitServiceListBranchesReportsCurrentLocalBranch() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-BranchInventory-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)

        let readme = repoURL.appendingPathComponent("README.md")
        try "# Branch Test\n".write(to: readme, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")

        do {
            _ = try await service.commitAndPush(
                message: "Initial commit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
            XCTFail("Expected push to fail without origin remote")
        } catch {
            // Expected.
        }

        let repoInfo = try await service.repoInfo()
        let inventory = try await service.listBranches()

        XCTAssertTrue(inventory.remote.isEmpty)
        XCTAssertTrue(inventory.local.contains(where: { $0.shortName == repoInfo.branch && $0.isCurrent }))
    }

    func testLocalGitServiceCommitAndPushReportsMissingAuthorEmail() async throws {
        let fm = FileManager.default
        let repoURL = try makeTemporaryGitRepository(prefix: "SyncMD-MissingAuthorEmail")
        defer { try? fm.removeItem(at: repoURL) }

        let service = LocalGitService(localURL: repoURL)
        let readme = repoURL.appendingPathComponent("README.md")
        try "# Identity Test\n".write(to: readme, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")

        do {
            _ = try await service.commitAndPush(
                message: "Initial commit",
                authorName: "SyncMD Tests",
                authorEmail: " ",
                pat: ""
            )
            XCTFail("Expected missing author email to be reported before libgit2 signature creation")
        } catch LocalGitError.invalidAuthorIdentity(let message) {
            XCTAssertTrue(message.contains("Author Email"), message)
        } catch {
            XCTFail("Expected invalidAuthorIdentity, got \(error)")
        }
    }

    func testLocalGitServiceCommitHistoryReturnsDeterministicPages() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-HistoryPages-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let file = repoURL.appendingPathComponent("README.md")

        for idx in 1...3 {
            try "commit \(idx)\n".write(to: file, atomically: true, encoding: .utf8)
            try await service.stage(path: "README.md")
            do {
                _ = try await service.commitAndPush(
                    message: "Commit \(idx)",
                    authorName: "SyncMD Tests",
                    authorEmail: "tests@example.com",
                    pat: ""
                )
            } catch {
                // Expected push failure; commit still created.
            }
        }

        let firstPage = try await service.commitHistory(limit: 2, skip: 0)
        let secondPage = try await service.commitHistory(limit: 2, skip: 2)

        XCTAssertEqual(firstPage.count, 2)
        XCTAssertEqual(secondPage.count, 1)
        XCTAssertEqual(firstPage.first?.message, "Commit 3")
        XCTAssertEqual(firstPage.last?.message, "Commit 2")
        XCTAssertEqual(secondPage.first?.message, "Commit 1")
    }

    func testLocalGitServiceCommitDetailIncludesParentAndChangedFiles() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-CommitDetail-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let file = repoURL.appendingPathComponent("README.md")

        try "initial\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Initial",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch {
            // Expected push failure.
        }

        try "updated\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Update README",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch {
            // Expected push failure.
        }

        let latest = try await service.commitHistory(limit: 1, skip: 0)
        let oid = try XCTUnwrap(latest.first?.oid)

        let detail = try await service.commitDetail(oid: oid)
        XCTAssertEqual(detail.oid, oid)
        XCTAssertEqual(detail.message, "Update README")
        XCTAssertEqual(detail.parentOIDs.count, 1)
        XCTAssertTrue(detail.changedFiles.contains(where: { $0.path == "README.md" && $0.changeType == .modified }))
    }

    func testLocalGitServiceStashSaveAndApplyRoundtrip() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-StashRoundtrip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let file = repoURL.appendingPathComponent("README.md")

        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Initial",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        try "work in progress\n".write(to: file, atomically: true, encoding: .utf8)

        _ = try await service.saveStash(
            message: "WIP",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com",
            includeUntracked: true
        )

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "base\n")

        let stashes = try await service.listStashes()
        XCTAssertEqual(stashes.count, 1)
        XCTAssertTrue(stashes[0].message.contains("WIP"))

        let applyResult = try await service.applyStash(index: 0, reinstateIndex: false)
        XCTAssertEqual(applyResult.kind, .applied)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "work in progress\n")
    }

    func testLocalGitServiceStashPopRemovesEntry() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-StashPop-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let file = repoURL.appendingPathComponent("README.md")

        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Initial",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        try "stash me\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await service.saveStash(
            message: "stash",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com",
            includeUntracked: true
        )

        let beforePop = try await service.listStashes()
        XCTAssertEqual(beforePop.count, 1)

        let popResult = try await service.popStash(index: 0, reinstateIndex: false)
        XCTAssertEqual(popResult.kind, .applied)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "stash me\n")

        let afterPop = try await service.listStashes()
        XCTAssertTrue(afterPop.isEmpty)
    }

    func testLocalGitServiceStashDropRemovesWithoutApplying() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-StashDrop-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let file = repoURL.appendingPathComponent("README.md")

        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Initial",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        try "drop me\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await service.saveStash(
            message: "to be dropped",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com",
            includeUntracked: true
        )

        let beforeDrop = try await service.listStashes()
        XCTAssertEqual(beforeDrop.count, 1)
        // File should be back to base after stashing
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "base\n")

        try await service.dropStash(index: 0)

        let afterDrop = try await service.listStashes()
        XCTAssertTrue(afterDrop.isEmpty)
        // File stays at base — stash was discarded, not applied
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "base\n")
    }

    func testLocalGitServiceTagLightweightCreateListDelete() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-TagLW-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let file = repoURL.appendingPathComponent("README.md")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do { _ = try await service.commitAndPush(message: "Initial", authorName: "T", authorEmail: "t@t.com", pat: "") } catch {}

        // Create lightweight
        let tag = try await service.createTag(name: "v1.0", targetOID: nil, message: nil, authorName: "T", authorEmail: "t@t.com")
        XCTAssertEqual(tag.shortName, "v1.0")
        XCTAssertEqual(tag.kind, .lightweight)

        // List
        let tags = try await service.listTags()
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags.first?.shortName, "v1.0")

        // Delete
        try await service.deleteTag(name: "v1.0")
        let afterDelete = try await service.listTags()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testLocalGitServiceTagAnnotatedCreateListDelete() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-TagAnnotated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let file = repoURL.appendingPathComponent("README.md")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do { _ = try await service.commitAndPush(message: "Initial", authorName: "T", authorEmail: "t@t.com", pat: "") } catch {}

        // Create annotated
        let tag = try await service.createTag(name: "v2.0-annotated", targetOID: nil, message: "Release 2.0", authorName: "T", authorEmail: "t@t.com")
        XCTAssertEqual(tag.shortName, "v2.0-annotated")
        XCTAssertEqual(tag.kind, .annotated)
        XCTAssertEqual(tag.message, "Release 2.0")

        // List
        let tags = try await service.listTags()
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags.first?.kind, .annotated)
        XCTAssertEqual(tags.first?.message, "Release 2.0")

        // Delete
        try await service.deleteTag(name: "v2.0-annotated")
        let afterDelete = try await service.listTags()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testLocalGitServiceTagDuplicateThrows() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-TagDup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let file = repoURL.appendingPathComponent("README.md")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do { _ = try await service.commitAndPush(message: "Initial", authorName: "T", authorEmail: "t@t.com", pat: "") } catch {}

        _ = try await service.createTag(name: "v1.0", targetOID: nil, message: nil, authorName: "T", authorEmail: "t@t.com")

        do {
            _ = try await service.createTag(name: "v1.0", targetOID: nil, message: nil, authorName: "T", authorEmail: "t@t.com")
            XCTFail("Expected tagAlreadyExists error")
        } catch LocalGitError.tagAlreadyExists(let name) {
            XCTAssertEqual(name, "v1.0")
        }
    }

    func testLocalGitServiceDeleteNonexistentTagThrows() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-TagMissing-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let file = repoURL.appendingPathComponent("README.md")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do { _ = try await service.commitAndPush(message: "Initial", authorName: "T", authorEmail: "t@t.com", pat: "") } catch {}

        do {
            try await service.deleteTag(name: "nonexistent")
            XCTFail("Expected tagNotFound error")
        } catch LocalGitError.tagNotFound(let name) {
            XCTAssertEqual(name, "nonexistent")
        }
    }

    func testLocalGitServiceRevertCommitCleanPathCreatesRevertCommit() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-RevertClean-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let file = repoURL.appendingPathComponent("README.md")

        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Initial",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        try "change\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Change README",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        let targetOID = try await service.repoInfo().commitSHA

        let revert = try await service.revertCommit(
            oid: targetOID,
            message: "Revert README change",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com"
        )

        XCTAssertEqual(revert.kind, .reverted)
        XCTAssertEqual(revert.targetOID, targetOID)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "base\n")

        let session = try await service.conflictSession()
        XCTAssertEqual(session, .none)
    }

    func testLocalGitServiceRevertCommitConflictPathReturnsConflictResult() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-RevertConflict-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let file = repoURL.appendingPathComponent("README.md")

        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Initial",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Commit A",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }
        let commitAOID = try await service.repoInfo().commitSHA

        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Commit B",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        let revert = try await service.revertCommit(
            oid: commitAOID,
            message: "",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com"
        )

        XCTAssertEqual(revert.kind, .conflicts)
        XCTAssertEqual(revert.targetOID, commitAOID)
        XCTAssertNil(revert.newCommitSHA)

        let session = try await service.conflictSession()
        XCTAssertEqual(session.kind, .revert)
        XCTAssertTrue(session.unmergedPaths.contains("README.md"))
    }

    func testLocalGitServiceSwitchBranchBlockedWhenDirtyWorkingTree() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-BranchSwitchDirty-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)

        let readme = repoURL.appendingPathComponent("README.md")
        try "initial\n".write(to: readme, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")

        do {
            _ = try await service.commitAndPush(
                message: "Initial commit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch {
            // Expected push failure; commit still created.
        }

        try await service.createBranch(name: "feature")

        try "dirty worktree\n".write(to: readme, atomically: true, encoding: .utf8)

        do {
            try await service.switchBranch(name: "feature")
            XCTFail("Expected switch to be blocked when working tree is dirty")
        } catch let error as LocalGitError {
            guard case .checkoutBlockedByLocalChanges = error else {
                XCTFail("Unexpected error: \(error.localizedDescription)")
                return
            }
        }
    }

    func testLocalGitServiceCreateSwitchDeleteBranchLifecycle() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-BranchLifecycle-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)

        let readme = repoURL.appendingPathComponent("README.md")
        try "initial\n".write(to: readme, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")

        do {
            _ = try await service.commitAndPush(
                message: "Initial commit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch {
            // Expected push failure; commit still created.
        }

        let current = try await service.repoInfo().branch

        try await service.createBranch(name: "feature")
        var inventory = try await service.listBranches()
        XCTAssertTrue(inventory.local.contains(where: { $0.shortName == "feature" }))

        try await service.switchBranch(name: "feature")
        let switchedInfo = try await service.repoInfo()
        XCTAssertEqual(switchedInfo.branch, "feature")

        try await service.switchBranch(name: current)
        try await service.deleteBranch(name: "feature")

        inventory = try await service.listBranches()
        XCTAssertFalse(inventory.local.contains(where: { $0.shortName == "feature" }))
    }

    func testLocalGitServiceMergeBranchFastForward() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-MergeFF-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)

        let file = repoURL.appendingPathComponent("README.md")
        try "initial\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Initial",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch {
            // Expected push failure; commit still created.
        }

        let mainBranch = try await service.repoInfo().branch

        try await service.createBranch(name: "feature")
        try await service.switchBranch(name: "feature")

        try "feature change\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Feature commit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch {
            // Expected push failure; commit still created.
        }

        let featureSHA = try await service.repoInfo().commitSHA

        try await service.switchBranch(name: mainBranch)
        let mergeResult = try await service.mergeBranch(name: "feature", authorName: "Tester", authorEmail: "tests@example.com")

        XCTAssertEqual(mergeResult.kind, .fastForwarded)
        XCTAssertEqual(mergeResult.newCommitSHA, featureSHA)
        let postMergeInfo = try await service.repoInfo()
        XCTAssertEqual(postMergeInfo.commitSHA, featureSHA)
    }

    func testLocalGitServiceMergeBranchCreatesMergeCommitWhenDiverged() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-MergeCommit-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)

        let mainFile = repoURL.appendingPathComponent("Main.md")
        let featureFile = repoURL.appendingPathComponent("Feature.md")

        try "base\n".write(to: mainFile, atomically: true, encoding: .utf8)
        try await service.stage(path: "Main.md")
        do {
            _ = try await service.commitAndPush(
                message: "Initial",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch {
            // Expected push failure; commit still created.
        }

        let mainBranch = try await service.repoInfo().branch

        try await service.createBranch(name: "feature")
        try await service.switchBranch(name: "feature")

        try "feature side\n".write(to: featureFile, atomically: true, encoding: .utf8)
        try await service.stage(path: "Feature.md")
        do {
            _ = try await service.commitAndPush(
                message: "Feature commit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch {
            // Expected push failure; commit still created.
        }

        try await service.switchBranch(name: mainBranch)

        try "main side\n".write(to: mainFile, atomically: true, encoding: .utf8)
        try await service.stage(path: "Main.md")
        do {
            _ = try await service.commitAndPush(
                message: "Main commit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch {
            // Expected push failure; commit still created.
        }

        let mergeResult = try await service.mergeBranch(name: "feature", authorName: "Tester", authorEmail: "tests@example.com")

        XCTAssertEqual(mergeResult.kind, .mergeCommitted)
        let mergedInfo = try await service.repoInfo()
        XCTAssertEqual(mergedInfo.branch, mainBranch)
    }

    func testLocalGitServiceConflictSessionReportsMergeConflicts() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-MergeConflictSession-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)

        let file = repoURL.appendingPathComponent("README.md")
        try "line\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Initial",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch {
            // Expected push failure; commit still created.
        }

        let mainBranch = try await service.repoInfo().branch

        try await service.createBranch(name: "feature")
        try await service.switchBranch(name: "feature")
        try "feature\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Feature edit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch {
            // Expected push failure; commit still created.
        }

        try await service.switchBranch(name: mainBranch)
        try "main\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Main edit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch {
            // Expected push failure; commit still created.
        }

        do {
            _ = try await service.mergeBranch(name: "feature", authorName: "Tester", authorEmail: "tests@example.com")
            XCTFail("Expected conflict during merge")
        } catch {
            guard let gitError = error as? LocalGitError else {
                XCTFail("Expected LocalGitError")
                return
            }
            if case .mergeConflictsDetected = gitError {
                // expected
            } else {
                XCTFail("Expected mergeConflictsDetected, got \(gitError)")
            }
        }

        let conflictSession = try await service.conflictSession()
        XCTAssertEqual(conflictSession.kind, .merge)
        XCTAssertTrue(conflictSession.unmergedPaths.contains("README.md"))
    }

    func testLocalGitServiceResolveConflictWithTheirsClearsConflictState() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-ResolveConflictTheirs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)

        let file = repoURL.appendingPathComponent("README.md")
        try "line\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Initial",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        let mainBranch = try await service.repoInfo().branch

        try await service.createBranch(name: "feature")
        try await service.switchBranch(name: "feature")
        try "feature\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Feature edit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        try await service.switchBranch(name: mainBranch)
        try "main\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Main edit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        do {
            _ = try await service.mergeBranch(name: "feature", authorName: "Tester", authorEmail: "tests@example.com")
            XCTFail("Expected merge conflict")
        } catch { }

        try await service.resolveConflict(path: "README.md", strategy: .theirs)

        let session = try await service.conflictSession()
        XCTAssertFalse(session.unmergedPaths.contains("README.md"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "feature\n")

        let repoInfo = try await service.repoInfo()
        XCTAssertFalse(repoInfo.statusEntries.contains(where: { $0.path == "README.md" && $0.isConflicted }))
    }

    func testLocalGitServiceResolveConflictManualClearsConflictState() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-ResolveConflictManual-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)

        let file = repoURL.appendingPathComponent("README.md")
        try "line\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Initial",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        let mainBranch = try await service.repoInfo().branch

        try await service.createBranch(name: "feature")
        try await service.switchBranch(name: "feature")
        try "feature\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Feature edit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        try await service.switchBranch(name: mainBranch)
        try "main\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Main edit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        do {
            _ = try await service.mergeBranch(name: "feature", authorName: "Tester", authorEmail: "tests@example.com")
            XCTFail("Expected merge conflict")
        } catch { }

        try "manual resolution\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.resolveConflict(path: "README.md", strategy: .manual)

        let session = try await service.conflictSession()
        XCTAssertFalse(session.unmergedPaths.contains("README.md"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "manual resolution\n")

        let repoInfo = try await service.repoInfo()
        XCTAssertFalse(repoInfo.statusEntries.contains(where: { $0.path == "README.md" && $0.isConflicted }))
    }

    func testLocalGitServiceResolveConflictWithContentRejectsUnsafeKeepPaths() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryURL = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let outsideFile = temporaryRoot.appendingPathComponent("outside.txt")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideFile)
        var repository: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repository, repositoryURL.path, 0), 0)
        if let repository { git_repository_free(repository) }
        let service = LocalGitService(localURL: repositoryURL)

        for unsafePath in ["../outside.txt", outsideFile.path, ".git/index"] {
            do {
                try await service.resolveConflictWithContent(
                    path: unsafePath,
                    content: Data("changed".utf8),
                    additionalPathsToRemove: []
                )
                XCTFail("Expected unsafe path to be rejected: \(unsafePath)")
            } catch {
                guard let gitError = error as? LocalGitError else {
                    XCTFail("Expected conflictPathNotFound, got \(error)")
                    return
                }
                guard case .conflictPathNotFound = gitError else {
                    XCTFail("Expected conflictPathNotFound, got \(error)")
                    return
                }
            }
        }

        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "outside")
    }

    func testLocalGitServiceResolveConflictWithContentValidatesRemovalPathsBeforeWriting() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryURL = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let insideFile = repositoryURL.appendingPathComponent("README.md")
        let outsideFile = temporaryRoot.appendingPathComponent("outside.txt")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideFile)
        var repository: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repository, repositoryURL.path, 0), 0)
        if let repository { git_repository_free(repository) }
        let service = LocalGitService(localURL: repositoryURL)

        do {
            try await service.resolveConflictWithContent(
                path: "README.md",
                content: Data("resolved".utf8),
                additionalPathsToRemove: ["../outside.txt"]
            )
            XCTFail("Expected traversal removal path to be rejected")
        } catch {
            guard let gitError = error as? LocalGitError else {
                XCTFail("Expected conflictPathNotFound, got \(error)")
                return
            }
            guard case .conflictPathNotFound = gitError else {
                XCTFail("Expected conflictPathNotFound, got \(error)")
                return
            }
        }

        XCTAssertFalse(fileManager.fileExists(atPath: insideFile.path))
        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "outside")
    }

    func testLocalGitServiceCompleteMergeCreatesCommitAndCleansState() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-CompleteMerge-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)

        let file = repoURL.appendingPathComponent("README.md")
        try "line\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Initial",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        let mainBranch = try await service.repoInfo().branch

        try await service.createBranch(name: "feature")
        try await service.switchBranch(name: "feature")
        try "feature\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Feature edit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        try await service.switchBranch(name: mainBranch)
        try "main\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Main edit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
        } catch { }

        do {
            _ = try await service.mergeBranch(name: "feature", authorName: "Tester", authorEmail: "tests@example.com")
            XCTFail("Expected merge conflict")
        } catch { }

        try "resolved content\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.resolveConflict(path: "README.md", strategy: .manual)

        let result = try await service.completeMerge(
            message: "Resolve conflict",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com"
        )

        XCTAssertEqual(result.newCommitSHA.count, 40)

        let session = try await service.conflictSession()
        XCTAssertEqual(session, .none)

        let info = try await service.repoInfo()
        XCTAssertEqual(info.changeCount, 0)
        XCTAssertEqual(info.commitSHA, result.newCommitSHA)
    }

    func testLocalGitServiceAbortMergeRestoresHeadAndClearsState() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-AbortMerge-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)

        let file = repoURL.appendingPathComponent("README.md")
        try "line\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        try await commitLocalFixtureChanges(using: service, message: "Initial")

        let mainBranch = try await service.repoInfo().branch

        try await service.createBranch(name: "feature")
        try await service.switchBranch(name: "feature")
        try "feature\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        try await commitLocalFixtureChanges(using: service, message: "Feature edit")

        try await service.switchBranch(name: mainBranch)
        try "main\n".write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        try await commitLocalFixtureChanges(using: service, message: "Main edit")

        do {
            _ = try await service.mergeBranch(name: "feature", authorName: "Tester", authorEmail: "tests@example.com")
            XCTFail("Expected merge conflict")
        } catch LocalGitError.mergeConflictsDetected {
            let conflictSession = try await service.conflictSession()
            XCTAssertEqual(conflictSession.kind, .merge)
            XCTAssertTrue(conflictSession.unmergedPaths.contains("README.md"))
        } catch {
            XCTFail("Expected mergeConflictsDetected, got: \(error)")
            throw error
        }

        try await service.abortMerge()

        let session = try await service.conflictSession()
        XCTAssertEqual(session, .none)

        let fileContents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(fileContents, "main\n")

        let info = try await service.repoInfo()
        XCTAssertEqual(info.changeCount, 0)
    }

    func testLocalGitServiceCommitAndPushUsesStagedIndexOnly() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-StagedOnly-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)

        let fileA = repoURL.appendingPathComponent("A.md")
        let fileB = repoURL.appendingPathComponent("B.md")

        try "alpha\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "bravo\n".write(to: fileB, atomically: true, encoding: .utf8)

        try await service.stage(path: "A.md")
        try await service.stage(path: "B.md")

        do {
            _ = try await service.commitAndPush(
                message: "Initial commit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
            XCTFail("Expected push to fail without origin remote")
        } catch {
            // Expected: commit succeeds, push fails due missing origin.
        }

        let cleanInfo = try await service.repoInfo()
        XCTAssertEqual(cleanInfo.changeCount, 0)

        try "alpha changed\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "bravo changed\n".write(to: fileB, atomically: true, encoding: .utf8)

        try await service.stage(path: "A.md")

        do {
            _ = try await service.commitAndPush(
                message: "Commit staged only",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
            XCTFail("Expected push to fail without origin remote")
        } catch {
            // Expected push failure.
        }

        let info = try await service.repoInfo()
        XCTAssertEqual(info.changeCount, 1, "Unstaged file should remain modified after commit")

        let remaining = info.statusEntries.first { $0.path == "B.md" }
        XCTAssertEqual(remaining?.workTreeStatus, .modified)
        XCTAssertNil(remaining?.indexStatus)
        XCTAssertFalse(info.statusEntries.contains { $0.path == "A.md" }, "Staged file should be committed and clean")
    }

    func testLocalGitServiceStagesDeletionsRenamesAndMoves() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-StageDeletions-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)

        let keep = repoURL.appendingPathComponent("keep.md")
        let doomed = repoURL.appendingPathComponent("doomed.md")
        let renameOld = repoURL.appendingPathComponent("old-name.md")
        let subdir = repoURL.appendingPathComponent("subdir", isDirectory: true)
        try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
        let moveOld = subdir.appendingPathComponent("mover.md")

        try "keep\n".write(to: keep, atomically: true, encoding: .utf8)
        try "doomed\n".write(to: doomed, atomically: true, encoding: .utf8)
        try "rename me\n".write(to: renameOld, atomically: true, encoding: .utf8)
        try "move me\n".write(to: moveOld, atomically: true, encoding: .utf8)

        try await service.stage(path: "keep.md")
        try await service.stage(path: "doomed.md")
        try await service.stage(path: "old-name.md")
        try await service.stage(path: "subdir/mover.md")

        try await commitLocalFixtureChanges(using: service, message: "Initial")

        let cleanInfo = try await service.repoInfo()
        XCTAssertEqual(cleanInfo.changeCount, 0)

        // Deletion: remove a tracked file from disk.
        try fm.removeItem(at: doomed)

        // Rename: remove the old file and create a new file with a new name.
        try fm.removeItem(at: renameOld)
        let renameNew = repoURL.appendingPathComponent("new-name.md")
        try "rename me\n".write(to: renameNew, atomically: true, encoding: .utf8)

        // Move to a different folder: same as rename across directories.
        try fm.removeItem(at: moveOld)
        let moveNewDir = repoURL.appendingPathComponent("other", isDirectory: true)
        try fm.createDirectory(at: moveNewDir, withIntermediateDirectories: true)
        let moveNew = moveNewDir.appendingPathComponent("mover.md")
        try "move me\n".write(to: moveNew, atomically: true, encoding: .utf8)

        // Staging the old halves (files no longer on disk) must succeed and
        // record the removal in the index. Before the fix, stage() called
        // git_index_add_bypath which requires the file to exist, so these
        // calls silently failed and the commit kept the old paths.
        try await service.stage(path: "doomed.md")
        try await service.stage(path: "old-name.md")
        try await service.stage(path: "subdir/mover.md")

        // Staging the new halves adds the new paths to the index.
        try await service.stage(path: "new-name.md")
        try await service.stage(path: "other/mover.md")

        try await commitLocalFixtureChanges(using: service, message: "Delete, rename, move")

        let afterInfo = try await service.repoInfo()
        XCTAssertEqual(afterInfo.changeCount, 0, "All deletions/renames/moves should be committed and the working tree clean")
        XCTAssertFalse(afterInfo.statusEntries.contains { $0.path == "doomed.md" })
        XCTAssertFalse(afterInfo.statusEntries.contains { $0.path == "old-name.md" })
        XCTAssertFalse(afterInfo.statusEntries.contains { $0.path == "new-name.md" })
        XCTAssertFalse(afterInfo.statusEntries.contains { $0.path == "subdir/mover.md" })
        XCTAssertFalse(afterInfo.statusEntries.contains { $0.path == "other/mover.md" })

        // Verify the HEAD tree actually reflects the deletions/renames/moves
        // by inspecting the latest commit's changed files.
        let latest = try await service.commitHistory(limit: 1, skip: 0)
        let oid = try XCTUnwrap(latest.first?.oid)
        let detail = try await service.commitDetail(oid: oid)

        let deletedPaths = detail.changedFiles
            .filter { $0.changeType == .deleted }
            .map(\.path)
            .sorted()
        XCTAssertTrue(deletedPaths.contains("doomed.md"), "Deleted file must appear as deleted in commit detail")

        // Rename/move may appear either as add+delete or as a rename delta
        // depending on libgit2's similarity detection. In both cases the new
        // path must be present in the commit's change set and the old path must
        // not still be tracked in HEAD.
        let changedPaths = Set(detail.changedFiles.map(\.path))
        XCTAssertTrue(changedPaths.contains("new-name.md"), "Renamed file's new path must appear in commit")
        XCTAssertFalse(changedPaths.contains("old-name.md") && !deletedPaths.contains("old-name.md"),
                       "old-name.md may only appear in commit as a deletion, not still tracked")
        XCTAssertTrue(changedPaths.contains("other/mover.md"), "Moved file's new path must appear in commit")
        XCTAssertFalse(changedPaths.contains("subdir/mover.md") && !deletedPaths.contains("subdir/mover.md"),
                       "subdir/mover.md may only appear in commit as a deletion, not still tracked")
    }

    func testLocalGitServiceDiscardChangesRejectsPathsOutsideWorktree() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryURL = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let outsideFile = temporaryRoot.appendingPathComponent("outside.txt")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideFile)
        var repository: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repository, repositoryURL.path, 0), 0)
        if let repository { git_repository_free(repository) }
        let metadataURL = repositoryURL.appendingPathComponent(".git/config")
        let originalMetadata = try Data(contentsOf: metadataURL)
        let service = LocalGitService(localURL: repositoryURL)

        for unsafePath in ["../outside.txt", outsideFile.path, ".git/config"] {
            do {
                try await service.discardChanges(path: unsafePath)
                XCTFail("Expected unsafe discard path to be rejected: \(unsafePath)")
            } catch {
                XCTAssertEqual(error as? RepositoryFileDestinationError, .outsideRepository)
            }
        }

        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "outside")
        XCTAssertEqual(try Data(contentsOf: metadataURL), originalMetadata)
    }

    func testLocalGitServiceStageAndUnstageRejectPathsOutsideWorktree() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryURL = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let outsideFile = temporaryRoot.appendingPathComponent("outside.txt")
        let linkedFile = repositoryURL.appendingPathComponent("linked.txt")
        let safeFile = repositoryURL.appendingPathComponent("safe.txt")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideFile)
        try Data("safe".utf8).write(to: safeFile)
        try fileManager.createSymbolicLink(at: linkedFile, withDestinationURL: outsideFile)
        var repository: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repository, repositoryURL.path, 0), 0)
        if let repository { git_repository_free(repository) }
        let metadataURL = repositoryURL.appendingPathComponent(".git/config")
        let originalMetadata = try Data(contentsOf: metadataURL)
        let service = LocalGitService(localURL: repositoryURL)

        let unsafePaths = ["../outside.txt", outsideFile.path, ".git/config", "linked.txt"]
        for unsafePath in unsafePaths {
            do {
                try await service.stage(path: unsafePath)
                XCTFail("Expected unsafe stage path to be rejected: \(unsafePath)")
            } catch {
                XCTAssertEqual(error as? RepositoryFileDestinationError, .outsideRepository)
            }

            do {
                try await service.unstage(path: unsafePath)
                XCTFail("Expected unsafe unstage path to be rejected: \(unsafePath)")
            } catch {
                XCTAssertEqual(error as? RepositoryFileDestinationError, .outsideRepository)
            }

            do {
                try await service.stage(path: "safe.txt", oldPath: unsafePath)
                XCTFail("Expected unsafe renamed stage path to be rejected: \(unsafePath)")
            } catch {
                XCTAssertEqual(error as? RepositoryFileDestinationError, .outsideRepository)
            }

            do {
                try await service.unstage(path: "safe.txt", oldPath: unsafePath)
                XCTFail("Expected unsafe renamed unstage path to be rejected: \(unsafePath)")
            } catch {
                XCTAssertEqual(error as? RepositoryFileDestinationError, .outsideRepository)
            }
        }

        var reopenedRepository: OpaquePointer?
        defer { if let reopenedRepository { git_repository_free(reopenedRepository) } }
        XCTAssertEqual(git_repository_open(&reopenedRepository, repositoryURL.path), 0)
        var index: OpaquePointer?
        defer { if let index { git_index_free(index) } }
        XCTAssertEqual(git_repository_index(&index, reopenedRepository), 0)
        let safeIndexEntry = "safe.txt".withCString { git_index_get_bypath(index, $0, 0) }
        XCTAssertNil(safeIndexEntry)
        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "outside")
        XCTAssertEqual(try Data(contentsOf: metadataURL), originalMetadata)
    }

    func testLocalGitServiceUnifiedDiffShowsStagedOnlyJSONChanges() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-JSONDiff-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let configDir = repoURL.appendingPathComponent("config", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        let file = configDir.appendingPathComponent("settings.json")

        try """
        {
          "theme": "light"
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        try await service.stage(path: "config/settings.json")
        do {
            _ = try await service.commitAndPush(
                message: "Initial config",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
            XCTFail("Expected push to fail without origin remote")
        } catch {
            // Expected: commit succeeds, push fails due missing origin.
        }

        try """
        {
          "theme": "dark"
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "config/settings.json")

        let diff = try await service.unifiedDiff(path: "config/settings.json")

        XCTAssertEqual(diff.files.count, 1)
        XCTAssertEqual(diff.files.first?.path, "config/settings.json")
        XCTAssertEqual(diff.files.first?.changeType, .modified)
        XCTAssertFalse(diff.rawPatch.isEmpty)
        XCTAssertTrue(diff.rawPatch.contains("diff --git a/config/settings.json b/config/settings.json"))
        XCTAssertTrue(diff.rawPatch.contains("-  \"theme\": \"light\""))
        XCTAssertTrue(diff.rawPatch.contains("+  \"theme\": \"dark\""))
    }

    func testLocalGitServiceUnifiedDiffShowsUntrackedJSONChanges() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-UntrackedJSONDiff-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let readme = repoURL.appendingPathComponent("README.md")
        try "# SyncMD\n".write(to: readme, atomically: true, encoding: .utf8)
        try await service.stage(path: "README.md")
        do {
            _ = try await service.commitAndPush(
                message: "Initial commit",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
            XCTFail("Expected push to fail without origin remote")
        } catch {
            // Expected: commit succeeds, push fails due missing origin.
        }

        let configDir = repoURL.appendingPathComponent("config", isDirectory: true)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        let file = configDir.appendingPathComponent("settings.json")
        try """
        {
          "theme": "dark"
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        let diff = try await service.unifiedDiff(path: "config/settings.json")

        XCTAssertEqual(diff.files.count, 1)
        XCTAssertEqual(diff.files.first?.path, "config/settings.json")
        XCTAssertEqual(diff.files.first?.changeType, .added)
        XCTAssertFalse(diff.rawPatch.isEmpty)
        XCTAssertTrue(diff.rawPatch.contains("diff --git a/config/settings.json b/config/settings.json"))
        XCTAssertTrue(diff.rawPatch.contains("--- /dev/null"))
        XCTAssertTrue(diff.rawPatch.contains("+++ b/config/settings.json"))
        XCTAssertTrue(diff.rawPatch.contains("+  \"theme\": \"dark\""))
    }

    func testLocalGitServiceUnifiedDiffUsesHeadAsBaseForStagedAndUnstagedChanges() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-JSONMixedDiff-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        let service = LocalGitService(localURL: repoURL)
        let file = repoURL.appendingPathComponent("settings.json")

        try """
        {
          "theme": "light"
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        try await service.stage(path: "settings.json")
        do {
            _ = try await service.commitAndPush(
                message: "Initial settings",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
            XCTFail("Expected push to fail without origin remote")
        } catch {
            // Expected: commit succeeds, push fails due missing origin.
        }

        try """
        {
          "theme": "dark"
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        try await service.stage(path: "settings.json")

        try """
        {
          "theme": "solarized"
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        let diff = try await service.unifiedDiff(path: "settings.json")

        XCTAssertEqual(diff.files.count, 1)
        XCTAssertFalse(diff.rawPatch.isEmpty)
        XCTAssertTrue(diff.rawPatch.contains("-  \"theme\": \"light\""))
        XCTAssertTrue(diff.rawPatch.contains("+  \"theme\": \"solarized\""))
        XCTAssertFalse(diff.rawPatch.contains("\"dark\""))
    }

    func testGitLFSPointerParsesAndSerializesCanonicalPointers() throws {
        let oid = String(repeating: "a", count: 64)
        let text = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:\(oid)
        size 12345

        """

        let pointer = try XCTUnwrap(GitLFSPointer(data: Data(text.utf8)))

        XCTAssertEqual(pointer.oid, oid)
        XCTAssertEqual(pointer.size, 12_345)
        XCTAssertEqual(pointer.serializedString, text)
    }

    func testGitLFSAttributesMatchCommonGitattributesPatterns() {
        let attributes = GitLFSAttributes(text: """
        *.pdf filter=lfs diff=lfs merge=lfs -text lockable
        Attachments/** filter=lfs diff=lfs merge=lfs -text
        notes/*.png filter=lfs
        Secrets/** lockable
        Legacy/** -lockable
        *.md text
        """)

        XCTAssertTrue(attributes.isLFSTracked(path: "Manual.pdf"))
        XCTAssertTrue(attributes.isLFSTracked(path: "Attachments/2026/report.pdf"))
        XCTAssertTrue(attributes.isLFSTracked(path: "notes/diagram.png"))
        XCTAssertFalse(attributes.isLFSTracked(path: "notes/screens/deep.png"))
        XCTAssertFalse(attributes.isLFSTracked(path: "README.md"))
        XCTAssertTrue(attributes.isLockable(path: "Manual.pdf"))
        XCTAssertTrue(attributes.isLockable(path: "Secrets/plan.md"))
        XCTAssertFalse(attributes.isLockable(path: "Legacy/archive.pdf"))
        XCTAssertFalse(attributes.isLockable(path: "README.md"))
    }

    func testGitLFSHydrateDownloadsPointerFilesThroughBatchAPI() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-LFSHydrate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        try """
        [remote "origin"]
            url = https://github.com/example/vault.git
        """.write(to: repoURL.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

        let realData = Data("actual pdf bytes\n".utf8)
        let oid = GitLFSPointer.sha256Hex(for: realData)
        let pointer = GitLFSPointer(oid: oid, size: Int64(realData.count))
        let docsURL = repoURL.appendingPathComponent("Docs", isDirectory: true)
        try fm.createDirectory(at: docsURL, withIntermediateDirectories: true)
        let lfsFileURL = docsURL.appendingPathComponent("Manual.pdf")
        try Data(pointer.serializedString.utf8).write(to: lfsFileURL)

        let transport = MockGitLFSTransport { request, body in
            if request.url?.absoluteString == "https://github.com/example/vault.git/info/lfs/objects/batch" {
                let bodyString = String(data: try XCTUnwrap(body), encoding: .utf8) ?? ""
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertTrue(bodyString.contains("\"operation\":\"download\""))
                XCTAssertTrue(bodyString.contains(oid))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic eC1hY2Nlc3MtdG9rZW46Z2hwX3Rlc3Q=")
                let response = """
                {"transfer":"basic","objects":[{"oid":"\(oid)","size":\(realData.count),"actions":{"download":{"href":"https://lfs.example.test/objects/\(oid)","header":{"X-LFS-Test":"download"}}}}]}
                """
                return (Data(response.utf8), 200)
            }

            if request.url?.absoluteString == "https://lfs.example.test/objects/\(oid)" {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-LFS-Test"), "download")
                return (realData, 200)
            }

            XCTFail("Unexpected LFS request: \(request.url?.absoluteString ?? "<nil>")")
            return (Data(), 404)
        }

        let service = GitLFSService(
            localURL: repoURL,
            credentials: .gitHubPAT("ghp_test"),
            transport: transport
        )

        let result = try await service.hydrateWorktree()

        XCTAssertEqual(result.downloadedCount, 1)
        XCTAssertEqual(try Data(contentsOf: lfsFileURL), realData)
    }

    func testGitLFSHydrateCanBeLimitedToChangedPaths() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-LFSHydrateScoped-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        try """
        [remote "origin"]
            url = https://github.com/example/vault.git
        """.write(to: repoURL.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

        let changedData = Data("changed lfs data\n".utf8)
        let unchangedData = Data("unchanged lfs data\n".utf8)
        let changedPointer = GitLFSPointer(oid: GitLFSPointer.sha256Hex(for: changedData), size: Int64(changedData.count))
        let unchangedPointer = GitLFSPointer(oid: GitLFSPointer.sha256Hex(for: unchangedData), size: Int64(unchangedData.count))
        try changedPointer.serializedString.write(to: repoURL.appendingPathComponent("Changed.pdf"), atomically: true, encoding: .utf8)
        try unchangedPointer.serializedString.write(to: repoURL.appendingPathComponent("Unchanged.pdf"), atomically: true, encoding: .utf8)

        let transport = MockGitLFSTransport { request, body in
            if request.url?.absoluteString == "https://github.com/example/vault.git/info/lfs/objects/batch" {
                let bodyString = String(data: try XCTUnwrap(body), encoding: .utf8) ?? ""
                XCTAssertTrue(bodyString.contains(changedPointer.oid))
                XCTAssertFalse(bodyString.contains(unchangedPointer.oid))
                return (Data("""
                {"transfer":"basic","objects":[{"oid":"\(changedPointer.oid)","size":\(changedData.count),"actions":{"download":{"href":"https://lfs.example.test/objects/\(changedPointer.oid)"}}}]}
                """.utf8), 200)
            }

            if request.url?.absoluteString == "https://lfs.example.test/objects/\(changedPointer.oid)" {
                return (changedData, 200)
            }

            XCTFail("Unexpected LFS request: \(request.url?.absoluteString ?? "<nil>")")
            return (Data(), 404)
        }

        let result = try await GitLFSService(
            localURL: repoURL,
            credentials: .gitHubPAT("ghp_test"),
            transport: transport
        ).hydrateWorktree(candidatePaths: ["Changed.pdf"])

        XCTAssertEqual(result.checkedOutCount, 1)
        XCTAssertEqual(try Data(contentsOf: repoURL.appendingPathComponent("Changed.pdf")), changedData)
        XCTAssertNotNil(GitLFSPointer(data: try Data(contentsOf: repoURL.appendingPathComponent("Unchanged.pdf"))))
    }

    func testGitLFSIgnoresLFSConfigSymlinkOutsideRepository() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryURL = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let outsideConfig = temporaryRoot.appendingPathComponent("outside-lfsconfig")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(
            at: repositoryURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try """
        [remote "origin"]
            url = https://github.com/example/vault.git
        """.write(to: repositoryURL.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try """
        [lfs]
            url = https://untrusted.example.test/lfs
        """.write(to: outsideConfig, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(
            at: repositoryURL.appendingPathComponent(".lfsconfig"),
            withDestinationURL: outsideConfig
        )

        let data = Data("trusted endpoint data\n".utf8)
        let pointer = GitLFSPointer(oid: GitLFSPointer.sha256Hex(for: data), size: Int64(data.count))
        try pointer.serializedString.write(
            to: repositoryURL.appendingPathComponent("Manual.pdf"),
            atomically: true,
            encoding: .utf8
        )
        let transport = MockGitLFSTransport { request, _ in
            if request.url?.absoluteString == "https://github.com/example/vault.git/info/lfs/objects/batch" {
                XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
                return (Data("""
                {"objects":[{"oid":"\(pointer.oid)","size":\(pointer.size),"actions":{"download":{"href":"https://objects.example.test/\(pointer.oid)"}}}]}
                """.utf8), 200)
            }
            if request.url?.absoluteString == "https://objects.example.test/\(pointer.oid)" {
                return (data, 200)
            }
            XCTFail("Unexpected LFS request: \(request.url?.absoluteString ?? "<nil>")")
            return (Data(), 500)
        }

        let result = try await GitLFSService(
            localURL: repositoryURL,
            credentials: .gitHubPAT("ghp_test"),
            transport: transport
        ).hydrateWorktree()

        XCTAssertEqual(result.checkedOutCount, 1)
        XCTAssertEqual(try Data(contentsOf: repositoryURL.appendingPathComponent("Manual.pdf")), data)
    }

    func testGitLFSDoesNotForwardGitCredentialsToDifferentConfiguredHost() async throws {
        let fileManager = FileManager.default
        let repositoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("SyncMD-LFSConfiguredHost-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: repositoryURL) }
        try fileManager.createDirectory(
            at: repositoryURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try """
        [remote "origin"]
            url = https://github.com/example/vault.git
        """.write(to: repositoryURL.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try """
        [lfs]
            url = https://lfs.example.test/custom
        """.write(to: repositoryURL.appendingPathComponent(".lfsconfig"), atomically: true, encoding: .utf8)

        let data = Data("custom endpoint data\n".utf8)
        let pointer = GitLFSPointer(oid: GitLFSPointer.sha256Hex(for: data), size: Int64(data.count))
        try pointer.serializedString.write(
            to: repositoryURL.appendingPathComponent("asset.bin"),
            atomically: true,
            encoding: .utf8
        )
        let transport = MockGitLFSTransport { request, _ in
            if request.url?.absoluteString == "https://lfs.example.test/custom/info/lfs/objects/batch" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (Data("""
                {"objects":[{"oid":"\(pointer.oid)","size":\(pointer.size),"actions":{"download":{"href":"https://lfs.example.test/objects/\(pointer.oid)"}}}]}
                """.utf8), 200)
            }
            if request.url?.absoluteString == "https://lfs.example.test/objects/\(pointer.oid)" {
                return (data, 200)
            }
            XCTFail("Unexpected LFS request: \(request.url?.absoluteString ?? "<nil>")")
            return (Data(), 500)
        }

        let result = try await GitLFSService(
            localURL: repositoryURL,
            credentials: .gitHubPAT("ghp_test"),
            transport: transport
        ).hydrateWorktree()

        XCTAssertEqual(result.checkedOutCount, 1)
        XCTAssertEqual(try Data(contentsOf: repositoryURL.appendingPathComponent("asset.bin")), data)
    }

    func testGitLFSHydrateRejectsCandidateOutsideRepository() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryURL = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let outsideURL = temporaryRoot.appendingPathComponent("outside.pdf")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)

        let outsideData = Data("outside file must not be hydrated\n".utf8)
        let pointer = GitLFSPointer(
            oid: GitLFSPointer.sha256Hex(for: outsideData),
            size: Int64(outsideData.count)
        )
        let pointerData = Data(pointer.serializedString.utf8)
        try pointerData.write(to: outsideURL)

        let transport = MockGitLFSTransport { request, _ in
            XCTFail("Unexpected LFS request: \(request.url?.absoluteString ?? "<nil>")")
            return (Data(), 500)
        }

        do {
            _ = try await GitLFSService(
                localURL: repositoryURL,
                credentials: .gitHubPAT("ghp_test"),
                transport: transport
            ).hydrateWorktree(candidatePaths: ["../outside.pdf"])
            XCTFail("Expected path outside the repository to be rejected")
        } catch {
            XCTAssertEqual(error as? RepositoryFileDestinationError, .outsideRepository)
        }

        XCTAssertEqual(try Data(contentsOf: outsideURL), pointerData)
    }

    func testGitLFSBatchErrorsIncludeServerMessage() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-LFSBatchError-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        try "ref: refs/heads/main\n".write(to: repoURL.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try """
        [remote "origin"]
            url = https://github.com/example/vault.git
        """.write(to: repoURL.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

        let pointer = GitLFSPointer(oid: String(repeating: "a", count: 64), size: 12_706_707)
        try pointer.serializedString.write(to: repoURL.appendingPathComponent("video.mp4"), atomically: true, encoding: .utf8)

        let transport = MockGitLFSTransport { request, body in
            XCTAssertEqual(request.url?.absoluteString, "https://github.com/example/vault.git/info/lfs/objects/batch")
            let bodyString = String(data: try XCTUnwrap(body), encoding: .utf8) ?? ""
            XCTAssertTrue(bodyString.contains("refs"))
            XCTAssertTrue(bodyString.contains("heads"))
            XCTAssertTrue(bodyString.contains("main"))
            return (Data("""
            {"message":"Repository is over its Git LFS data quota.","request_id":"abc123"}
            """.utf8), 422)
        }

        do {
            _ = try await GitLFSService(
                localURL: repoURL,
                credentials: .gitHubPAT("ghp_test"),
                transport: transport
            ).hydrateWorktree()
            XCTFail("Expected Git LFS batch error")
        } catch LocalGitError.lfsFailed(let message) {
            XCTAssertTrue(message.contains("HTTP 422"))
            XCTAssertTrue(message.contains("data quota"))
            XCTAssertTrue(message.contains("abc123"))
        }
    }

    func testGitLFSBatchUsesGitSuffixForGitHubHTTPSRemoteWithoutGitSuffix() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-LFSGitHubSuffix-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        try """
        [remote "origin"]
            url = https://github.com/example/vault
        """.write(to: repoURL.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

        let realData = Data("large binary fixture\n".utf8)
        let oid = GitLFSPointer.sha256Hex(for: realData)
        let pointer = GitLFSPointer(oid: oid, size: Int64(realData.count))
        try pointer.serializedString.write(to: repoURL.appendingPathComponent("video.mp4"), atomically: true, encoding: .utf8)

        let transport = MockGitLFSTransport { request, _ in
            if request.url?.absoluteString == "https://github.com/example/vault.git/info/lfs/objects/batch" {
                let response = """
                {"transfer":"basic","objects":[{"oid":"\(oid)","size":\(realData.count),"actions":{"download":{"href":"https://lfs.example.test/objects/\(oid)"}}}]}
                """
                return (Data(response.utf8), 200)
            }

            if request.url?.absoluteString == "https://lfs.example.test/objects/\(oid)" {
                return (realData, 200)
            }

            XCTFail("Unexpected LFS request: \(request.url?.absoluteString ?? "<nil>")")
            return (Data(), 404)
        }

        let result = try await GitLFSService(
            localURL: repoURL,
            credentials: .gitHubPAT("ghp_test"),
            transport: transport
        ).hydrateWorktree()

        XCTAssertEqual(result.checkedOutCount, 1)
        XCTAssertEqual(try Data(contentsOf: repoURL.appendingPathComponent("video.mp4")), realData)
    }

    func testGitLFSBatchHTMLErrorsAreSummarized() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-LFSHTMLBatchError-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        try """
        [remote "origin"]
            url = https://github.com/example/vault.git
        """.write(to: repoURL.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

        let pointer = GitLFSPointer(oid: String(repeating: "c", count: 64), size: 42)
        try pointer.serializedString.write(to: repoURL.appendingPathComponent("asset.bin"), atomically: true, encoding: .utf8)

        let transport = MockGitLFSTransport { _, _ in
            let html = """
            <!DOCTYPE html>
            <html>
              <head><title>Oh no &middot; GitHub</title></head>
              <body>large diagnostic page that should not be shown verbatim</body>
            </html>
            """
            return (Data(html.utf8), 422)
        }

        do {
            _ = try await GitLFSService(
                localURL: repoURL,
                credentials: .gitHubPAT("ghp_test"),
                transport: transport
            ).hydrateWorktree()
            XCTFail("Expected Git LFS batch error")
        } catch LocalGitError.lfsFailed(let message) {
            XCTAssertTrue(message.contains("HTTP 422"))
            XCTAssertTrue(message.contains("Server returned an HTML error page"))
            XCTAssertTrue(message.contains("Oh no · GitHub"))
            XCTAssertFalse(message.contains("<!DOCTYPE html>"))
            XCTAssertFalse(message.contains("<html>"))
            XCTAssertFalse(message.contains("large diagnostic page"))
        }
    }

    func testLocalGitServiceCloneSucceedsWithWarningWhenLFSHydrationFails() async throws {
        let fm = FileManager.default
        let sourceURL = try makeTemporaryGitRepository(prefix: "SyncMD-LFSCloneSource")
        let cloneParentURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-LFSCloneParent-\(UUID().uuidString)", isDirectory: true)
        let cloneURL = cloneParentURL.appendingPathComponent("clone", isDirectory: true)
        defer {
            try? fm.removeItem(at: sourceURL)
            try? fm.removeItem(at: cloneParentURL)
        }

        let pointer = GitLFSPointer(oid: String(repeating: "b", count: 64), size: 42)
        try pointer.serializedString.write(to: sourceURL.appendingPathComponent("asset.bin"), atomically: true, encoding: .utf8)
        let sourceService = LocalGitService(localURL: sourceURL)
        try await sourceService.stage(path: "asset.bin")
        _ = try await sourceService.commitLocal(
            message: "Add pointer fixture",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com"
        )

        try fm.createDirectory(at: cloneParentURL, withIntermediateDirectories: true)
        let cloneService = LocalGitService(localURL: cloneURL)
        let result = try await cloneService.clone(remoteURL: sourceURL.path, pat: "")

        XCTAssertEqual(result.fileCount, 1)
        XCTAssertTrue(result.lfsWarning?.contains("Git LFS") == true)
        XCTAssertTrue(cloneService.hasGitDirectory)
        XCTAssertNotNil(GitLFSPointer(data: try Data(contentsOf: cloneURL.appendingPathComponent("asset.bin"))))
    }

    func testGitLFSSSHAuthRequestBuildsAuthenticateCommandsForPrivateRemotes() throws {
        let sshURL = try XCTUnwrap(GitRemoteURL.parse("ssh://git@example.com:2222/owner/vault.git"))
        let download = try GitLFSSSHAuthRequest(
            remote: sshURL,
            credentials: .sshKey(username: "", privateKey: "test-key"),
            operation: .download
        )

        XCTAssertEqual(download.username, "git")
        XCTAssertEqual(download.host, "example.com")
        XCTAssertEqual(download.port, 2222)
        XCTAssertEqual(download.repositoryPath, "owner/vault.git")
        XCTAssertEqual(download.command, "git-lfs-authenticate 'owner/vault.git' download")

        let scpURL = try XCTUnwrap(GitRemoteURL.parse("git@github.com:owner/repo.git"))
        let upload = try GitLFSSSHAuthRequest(
            remote: scpURL,
            credentials: .sshKey(username: "deploy", privateKey: "test-key"),
            operation: .upload
        )

        XCTAssertEqual(upload.username, "deploy")
        XCTAssertEqual(upload.host, "github.com")
        XCTAssertEqual(upload.port, 22)
        XCTAssertEqual(upload.repositoryPath, "owner/repo.git")
        XCTAssertEqual(upload.command, "git-lfs-authenticate 'owner/repo.git' upload")
    }

    func testGitLFSHydrateUsesSSHLFSAuthenticateForPrivateSSHRemote() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-LFSSSHHydrate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        try """
        [remote "origin"]
            url = git@github.com:example/vault.git
        """.write(to: repoURL.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

        let realData = Data("private ssh lfs bytes\n".utf8)
        let oid = GitLFSPointer.sha256Hex(for: realData)
        let pointer = GitLFSPointer(oid: oid, size: Int64(realData.count))
        let fileURL = repoURL.appendingPathComponent("Manual.pdf")
        try Data(pointer.serializedString.utf8).write(to: fileURL)

        let ssh = MockGitLFSSSHAuthenticator { request, credentials in
            XCTAssertEqual(request.host, "github.com")
            XCTAssertEqual(request.username, "git")
            XCTAssertEqual(request.command, "git-lfs-authenticate 'example/vault.git' download")
            XCTAssertEqual(credentials.method, .sshKey)
            return GitLFSAccess(
                href: URL(string: "https://lfs.github.test/example/vault.git/info/lfs")!,
                headers: ["Authorization": "RemoteAuth download"],
                expiresAt: Date(timeIntervalSince1970: 4_000)
            )
        }

        let transport = MockGitLFSTransport { request, body in
            if request.url?.absoluteString == "https://lfs.github.test/example/vault.git/info/lfs/objects/batch" {
                let bodyString = String(data: try XCTUnwrap(body), encoding: .utf8) ?? ""
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "RemoteAuth download")
                XCTAssertTrue(bodyString.contains("\"operation\":\"download\""))
                return (Data("""
                {"objects":[{"oid":"\(oid)","size":\(realData.count),"actions":{"download":{"href":"https://objects.example.test/\(oid)"}}}]}
                """.utf8), 200)
            }

            if request.url?.absoluteString == "https://objects.example.test/\(oid)" {
                return (realData, 200)
            }

            XCTFail("Unexpected LFS request: \(request.url?.absoluteString ?? "<nil>")")
            return (Data(), 404)
        }

        let service = GitLFSService(
            localURL: repoURL,
            credentials: .sshKey(username: "git", privateKey: "test-private-key"),
            transport: transport,
            sshAuthenticator: ssh,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let result = try await service.hydrateWorktree()

        XCTAssertEqual(result.downloadedCount, 1)
        XCTAssertEqual(ssh.requests.map(\.operation), [.download])
        XCTAssertEqual(try Data(contentsOf: fileURL), realData)
    }

    func testGitLFSUploadUsesSeparateSSHLFSAuthenticateOperationAndHeaders() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-LFSSSHUpload-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        try """
        [remote "origin"]
            url = ssh://git@example.com:2222/owner/vault.git
        """.write(to: repoURL.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

        let data = Data("upload me\n".utf8)
        let pointer = GitLFSPointer(oid: GitLFSPointer.sha256Hex(for: data), size: Int64(data.count))
        let objectURL = repoURL
            .appendingPathComponent(".git/lfs/objects", isDirectory: true)
            .appendingPathComponent(String(pointer.oid.prefix(2)), isDirectory: true)
            .appendingPathComponent(String(pointer.oid.dropFirst(2).prefix(2)), isDirectory: true)
            .appendingPathComponent(pointer.oid)
        try fm.createDirectory(at: objectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: objectURL)

        let ssh = MockGitLFSSSHAuthenticator { request, _ in
            XCTAssertEqual(request.host, "example.com")
            XCTAssertEqual(request.port, 2222)
            XCTAssertEqual(request.command, "git-lfs-authenticate 'owner/vault.git' upload")
            return GitLFSAccess(
                href: URL(string: "https://lfs.example.test/owner/vault.git/info/lfs")!,
                headers: ["Authorization": "RemoteAuth upload"]
            )
        }

        let transport = MockGitLFSTransport { request, body in
            XCTAssertEqual(request.url?.absoluteString, "https://lfs.example.test/owner/vault.git/info/lfs/objects/batch")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "RemoteAuth upload")
            let bodyString = String(data: try XCTUnwrap(body), encoding: .utf8) ?? ""
            XCTAssertTrue(bodyString.contains("\"operation\":\"upload\""))
            XCTAssertTrue(bodyString.contains(pointer.oid))
            return (Data("""
            {"objects":[{"oid":"\(pointer.oid)","size":\(pointer.size)}]}
            """.utf8), 200)
        }

        let uploaded = try await GitLFSService(
            localURL: repoURL,
            credentials: .sshKey(username: "git", privateKey: "test-private-key"),
            transport: transport,
            sshAuthenticator: ssh
        ).uploadObjects([pointer])

        XCTAssertEqual(uploaded, 0)
        XCTAssertEqual(ssh.requests.map(\.operation), [.upload])
    }

    func testGitLFSBatchRefreshesSSHAccessAfterAuthFailure() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-LFSSSHRefresh-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        try """
        [remote "origin"]
            url = git@example.com:owner/vault.git
        """.write(to: repoURL.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

        let realData = Data("refresh token bytes\n".utf8)
        let oid = GitLFSPointer.sha256Hex(for: realData)
        let pointer = GitLFSPointer(oid: oid, size: Int64(realData.count))
        let fileURL = repoURL.appendingPathComponent("asset.bin")
        try Data(pointer.serializedString.utf8).write(to: fileURL)

        var batchAttempts = 0
        var authHeaders: [String] = []
        let ssh = MockGitLFSSSHAuthenticator { _, _ in
            let token = "Bearer token-\(authHeaders.count + 1)"
            return GitLFSAccess(
                href: URL(string: "https://lfs.example.test/owner/vault.git/info/lfs")!,
                headers: ["Authorization": token],
                expiresAt: Date(timeIntervalSince1970: 4_000)
            )
        }

        let transport = MockGitLFSTransport { request, _ in
            if request.url?.absoluteString == "https://lfs.example.test/owner/vault.git/info/lfs/objects/batch" {
                batchAttempts += 1
                authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                if batchAttempts == 1 {
                    return (Data(), 401)
                }
                return (Data("""
                {"objects":[{"oid":"\(oid)","size":\(realData.count),"actions":{"download":{"href":"https://objects.example.test/\(oid)"}}}]}
                """.utf8), 200)
            }

            if request.url?.absoluteString == "https://objects.example.test/\(oid)" {
                return (realData, 200)
            }

            XCTFail("Unexpected LFS request: \(request.url?.absoluteString ?? "<nil>")")
            return (Data(), 404)
        }

        let result = try await GitLFSService(
            localURL: repoURL,
            credentials: .sshKey(username: "git", privateKey: "test-private-key"),
            transport: transport,
            sshAuthenticator: ssh,
            now: { Date(timeIntervalSince1970: 1_000) }
        ).hydrateWorktree()

        XCTAssertEqual(result.downloadedCount, 1)
        XCTAssertEqual(ssh.requests.count, 2)
        XCTAssertEqual(authHeaders, ["Bearer token-1", "Bearer token-2"])
    }

    func testLocalGitServiceStagesLFSTrackedFilesAsPointersAndKeepsHydratedWorktreeClean() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-LFSStage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        try "*.pdf filter=lfs diff=lfs merge=lfs -text\n".write(
            to: repoURL.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )
        let docsURL = repoURL.appendingPathComponent("Docs", isDirectory: true)
        try fm.createDirectory(at: docsURL, withIntermediateDirectories: true)
        let pdfURL = docsURL.appendingPathComponent("Manual.pdf")
        let pdfData = Data("%PDF-1.7\nactual binary-ish content\n".utf8)
        try pdfData.write(to: pdfURL)

        let service = LocalGitService(localURL: repoURL)
        try await service.stageAll()
        _ = try await service.commitLocal(
            message: "Add LFS PDF",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com"
        )

        let committedBlob = try headBlobString(repoURL: repoURL, path: "Docs/Manual.pdf")
        let committedPointer = try XCTUnwrap(GitLFSPointer(data: Data(committedBlob.utf8)))

        XCTAssertEqual(committedPointer.oid, GitLFSPointer.sha256Hex(for: pdfData))
        XCTAssertEqual(committedPointer.size, Int64(pdfData.count))
        XCTAssertEqual(try Data(contentsOf: pdfURL), pdfData)

        let repoInfo = try await service.repoInfo()
        XCTAssertEqual(repoInfo.changeCount, 0)
    }

    func testLocalGitServiceTreatsExistingHydratedLFSObjectMirrorAsClean() async throws {
        let fm = FileManager.default
        let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-LFSMirrorClean-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repoURL) }

        var repo: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repo, repoURL.path, 0), 0)
        if let repo { git_repository_free(repo) }

        try "*.pdf filter=lfs diff=lfs merge=lfs -text\n".write(
            to: repoURL.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )

        let data = Data("previously hydrated pdf bytes\n".utf8)
        let pointer = GitLFSPointer(oid: GitLFSPointer.sha256Hex(for: data), size: Int64(data.count))
        try pointer.serializedString.write(to: repoURL.appendingPathComponent("Manual.pdf"), atomically: true, encoding: .utf8)

        let service = LocalGitService(localURL: repoURL)
        try await service.stageAll()
        _ = try await service.commitLocal(
            message: "Add LFS pointer",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com"
        )

        let objectURL = lfsObjectURL(repoURL: repoURL, pointer: pointer)
        try fm.createDirectory(at: objectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: objectURL)
        try data.write(to: repoURL.appendingPathComponent("Manual.pdf"))

        let mirrorDate = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: mirrorDate], ofItemAtPath: objectURL.path)
        try fm.setAttributes([.modificationDate: mirrorDate], ofItemAtPath: repoURL.appendingPathComponent("Manual.pdf").path)

        let repoInfo = try await service.repoInfo()

        XCTAssertEqual(repoInfo.changeCount, 0)
    }

    func testLocalGitServiceReportsAutoLFSCandidatesWithoutModifyingGitattributes() async throws {
        let fm = FileManager.default
        let repoURL = try makeTemporaryGitRepository(prefix: "SyncMD-LFSCandidate")
        defer { try? fm.removeItem(at: repoURL) }

        let mediaURL = repoURL.appendingPathComponent("Media", isDirectory: true)
        try fm.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        let movieURL = mediaURL.appendingPathComponent("clip.mov")
        try Data(repeating: 0xAA, count: 4096).write(to: movieURL)

        let service = LocalGitService(localURL: repoURL)
        let candidates = try await service.lfsAutoTrackingCandidates(paths: ["Media/clip.mov"])

        XCTAssertEqual(candidates.map(\.path), ["Media/clip.mov"])
        XCTAssertEqual(candidates.first?.patterns, ["*.mov", "*.MOV"])
        XCTAssertFalse(fm.fileExists(atPath: repoURL.appendingPathComponent(".gitattributes").path))

        try await service.stage(path: "Media/clip.mov")
        _ = try await service.commitLocal(
            message: "Stage without LFS confirmation",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com"
        )

        XCTAssertEqual(try Data(contentsOf: movieURL), Data(repeating: 0xAA, count: 4096))
        XCTAssertNil(GitLFSPointer(data: Data(try headBlobString(repoURL: repoURL, path: "Media/clip.mov").utf8)))
        XCTAssertFalse(fm.fileExists(atPath: repoURL.appendingPathComponent(".gitattributes").path))
    }

    func testGitLFSAutoTrackingRejectsFilesOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryURL = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let outsideURL = temporaryRoot.appendingPathComponent("outside.mov")
        let linkedURL = repositoryURL.appendingPathComponent("linked.mov")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 4096).write(to: outsideURL)
        try fileManager.createSymbolicLink(at: linkedURL, withDestinationURL: outsideURL)

        for path in ["../outside.mov", "linked.mov"] {
            XCTAssertThrowsError(
                try GitLFSService.autoTrackingCandidates(
                    repositoryURL: repositoryURL,
                    candidatePaths: [path]
                )
            ) { error in
                XCTAssertEqual(error as? RepositoryFileDestinationError, .outsideRepository)
            }
        }
    }

    func testGitLFSAttributesDoesNotLoadSymlinkOutsideRepository() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryURL = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let outsideAttributes = temporaryRoot.appendingPathComponent("outside-attributes")
        let linkedAttributes = repositoryURL.appendingPathComponent(".gitattributes")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try "*.pdf filter=lfs diff=lfs merge=lfs -text\n".write(
            to: outsideAttributes,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.createSymbolicLink(at: linkedAttributes, withDestinationURL: outsideAttributes)

        let attributes = GitLFSAttributes.load(from: repositoryURL)

        XCTAssertFalse(attributes.isLFSTracked(path: "private.pdf"))
    }

    func testLocalGitServiceDoesNotWriteGitattributesThroughSymlinkOutsideRepository() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryURL = temporaryRoot.appendingPathComponent("repository", isDirectory: true)
        let outsideAttributes = temporaryRoot.appendingPathComponent("outside-attributes")
        let linkedAttributes = repositoryURL.appendingPathComponent(".gitattributes")
        let designURL = repositoryURL.appendingPathComponent("Design", isDirectory: true)
        let figURL = designURL.appendingPathComponent("mockup.fig")
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: designURL, withIntermediateDirectories: true)
        var repository: OpaquePointer?
        XCTAssertEqual(git_repository_init(&repository, repositoryURL.path, 0), 0)
        if let repository { git_repository_free(repository) }
        try "outside\n".write(to: outsideAttributes, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(at: linkedAttributes, withDestinationURL: outsideAttributes)
        try Data(repeating: 0xFA, count: 256).write(to: figURL)
        let service = LocalGitService(localURL: repositoryURL)

        do {
            try await service.stage(path: "Design/mockup.fig", oldPath: nil, lfsAutoTrack: true)
            XCTFail("Expected symbolic link to be rejected")
        } catch {
            XCTAssertEqual(error as? RepositoryFileDestinationError, .outsideRepository)
        }

        XCTAssertEqual(try String(contentsOf: outsideAttributes, encoding: .utf8), "outside\n")
    }

    func testLocalGitServiceAutoTracksPDFAsLFSWithoutExistingGitattributes() async throws {
        let fm = FileManager.default
        let repoURL = try makeTemporaryGitRepository(prefix: "SyncMD-AutoLFSPDF")
        defer { try? fm.removeItem(at: repoURL) }

        let docsURL = repoURL.appendingPathComponent("Docs", isDirectory: true)
        try fm.createDirectory(at: docsURL, withIntermediateDirectories: true)
        let pdfURL = docsURL.appendingPathComponent("Manual.pdf")
        var pdfData = Data("%PDF-1.7\n".utf8)
        pdfData.append(Data(repeating: 0xA5, count: 1024))
        try pdfData.write(to: pdfURL)

        let service = LocalGitService(localURL: repoURL)
        try await service.stageAll(lfsAutoTrack: true)
        _ = try await service.commitLocal(
            message: "Auto-track PDF",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com"
        )

        let committedBlob = try headBlobString(repoURL: repoURL, path: "Docs/Manual.pdf")
        let pointer = try XCTUnwrap(GitLFSPointer(data: Data(committedBlob.utf8)))
        XCTAssertEqual(pointer.oid, GitLFSPointer.sha256Hex(for: pdfData))
        XCTAssertEqual(pointer.size, Int64(pdfData.count))
        XCTAssertEqual(try Data(contentsOf: pdfURL), pdfData)
        XCTAssertTrue(fm.fileExists(atPath: lfsObjectURL(repoURL: repoURL, pointer: pointer).path))

        let attributes = try headBlobString(repoURL: repoURL, path: ".gitattributes")
        XCTAssertTrue(attributes.contains("*.pdf filter=lfs diff=lfs merge=lfs -text"))
    }

    func testLocalGitServiceAutoTracksUppercaseMOVAndAppendsGitattributesRule() async throws {
        let fm = FileManager.default
        let repoURL = try makeTemporaryGitRepository(prefix: "SyncMD-AutoLFSMOV")
        defer { try? fm.removeItem(at: repoURL) }

        try "*.mp4 filter=lfs diff=lfs merge=lfs -text\n".write(
            to: repoURL.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )

        let videosURL = repoURL.appendingPathComponent("raw/assets/videos", isDirectory: true)
        try fm.createDirectory(at: videosURL, withIntermediateDirectories: true)
        let movURL = videosURL.appendingPathComponent("IMG_3617.MOV")
        var movData = Data("ftypqt  ".utf8)
        movData.append(Data(repeating: 0xCC, count: 4096))
        try movData.write(to: movURL)

        let service = LocalGitService(localURL: repoURL)
        try await service.stageAll(lfsAutoTrack: true)
        _ = try await service.commitLocal(
            message: "Auto-track MOV",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com"
        )

        let committedBlob = try headBlobString(repoURL: repoURL, path: "raw/assets/videos/IMG_3617.MOV")
        let pointer = try XCTUnwrap(GitLFSPointer(data: Data(committedBlob.utf8)))
        XCTAssertEqual(pointer.oid, GitLFSPointer.sha256Hex(for: movData))
        XCTAssertEqual(pointer.size, Int64(movData.count))
        XCTAssertEqual(try Data(contentsOf: movURL), movData)

        let attributes = try headBlobString(repoURL: repoURL, path: ".gitattributes")
        XCTAssertTrue(attributes.contains("*.mp4 filter=lfs diff=lfs merge=lfs -text"))
        XCTAssertTrue(attributes.contains("*.MOV filter=lfs diff=lfs merge=lfs -text"))
    }

    func testLocalGitServiceAutoTracksUnknownLargeBinaryWithExactPathRule() async throws {
        let fm = FileManager.default
        let repoURL = try makeTemporaryGitRepository(prefix: "SyncMD-AutoLFSUnknownLarge")
        defer { try? fm.removeItem(at: repoURL) }

        let blobsURL = repoURL.appendingPathComponent("raw/assets/blobs", isDirectory: true)
        try fm.createDirectory(at: blobsURL, withIntermediateDirectories: true)
        let blobURL = blobsURL.appendingPathComponent("session.capture")
        let largeData = Data(repeating: 0, count: Int(GitLFSAutoTrackingPolicy.default.largeFileThresholdBytes) + 1)
        try largeData.write(to: blobURL)

        let service = LocalGitService(localURL: repoURL)
        try await service.stageAll(lfsAutoTrack: true)
        _ = try await service.commitLocal(
            message: "Auto-track large binary",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com"
        )

        let committedBlob = try headBlobString(repoURL: repoURL, path: "raw/assets/blobs/session.capture")
        let pointer = try XCTUnwrap(GitLFSPointer(data: Data(committedBlob.utf8)))
        XCTAssertEqual(pointer.oid, GitLFSPointer.sha256Hex(for: largeData))
        XCTAssertEqual(pointer.size, Int64(largeData.count))
        XCTAssertEqual(try Data(contentsOf: blobURL), largeData)
        XCTAssertTrue(fm.fileExists(atPath: lfsObjectURL(repoURL: repoURL, pointer: pointer).path))

        let attributes = try headBlobString(repoURL: repoURL, path: ".gitattributes")
        XCTAssertTrue(attributes.contains("/raw/assets/blobs/session.capture filter=lfs diff=lfs merge=lfs -text"))
    }

    func testLocalGitServiceDoesNotAutoTrackSmallMarkdownFile() async throws {
        let fm = FileManager.default
        let repoURL = try makeTemporaryGitRepository(prefix: "SyncMD-NoAutoLFSText")
        defer { try? fm.removeItem(at: repoURL) }

        let note = "# Notes\nThis should stay as normal Git text.\n"
        try note.write(to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let service = LocalGitService(localURL: repoURL)
        try await service.stageAll()
        _ = try await service.commitLocal(
            message: "Add markdown",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com"
        )

        let committedBlob = try headBlobString(repoURL: repoURL, path: "README.md")
        XCTAssertEqual(committedBlob, note)
        XCTAssertNil(GitLFSPointer(data: Data(committedBlob.utf8)))
        XCTAssertFalse(fm.fileExists(atPath: repoURL.appendingPathComponent(".gitattributes").path))
    }

    func testLocalGitServiceStagesAndCommitsGitattributesForAutoLFSRule() async throws {
        let fm = FileManager.default
        let repoURL = try makeTemporaryGitRepository(prefix: "SyncMD-AutoLFSAttributes")
        defer { try? fm.removeItem(at: repoURL) }

        let designURL = repoURL.appendingPathComponent("Design", isDirectory: true)
        try fm.createDirectory(at: designURL, withIntermediateDirectories: true)
        let figURL = designURL.appendingPathComponent("mockup.fig")
        try Data(repeating: 0xFA, count: 256).write(to: figURL)

        let service = LocalGitService(localURL: repoURL)
        try await service.stage(path: "Design/mockup.fig", oldPath: nil, lfsAutoTrack: true)
        _ = try await service.commitLocal(
            message: "Add design asset",
            authorName: "SyncMD Tests",
            authorEmail: "tests@example.com"
        )

        let attributes = try headBlobString(repoURL: repoURL, path: ".gitattributes")
        XCTAssertTrue(attributes.contains("*.fig filter=lfs diff=lfs merge=lfs -text"))
        XCTAssertNotNil(GitLFSPointer(data: Data(try headBlobString(repoURL: repoURL, path: "Design/mockup.fig").utf8)))
    }

    func testLocalGitServicePrePushValidationBlocksLargeStagedNonLFSBlob() async throws {
        let fm = FileManager.default
        let repoURL = try makeTemporaryGitRepository(prefix: "SyncMD-LFSPrePushBlock")
        defer { try? fm.removeItem(at: repoURL) }

        let bypassURL = repoURL.appendingPathComponent("Bypass", isDirectory: true)
        try fm.createDirectory(at: bypassURL, withIntermediateDirectories: true)
        let largePath = "Bypass/large.customblob"
        let largeURL = repoURL.appendingPathComponent(largePath)
        let largeData = Data(repeating: 0, count: Int(GitLFSAutoTrackingPolicy.default.largeFileThresholdBytes) + 1)
        try largeData.write(to: largeURL)
        try stagePathBypassingLocalGitService(repoURL: repoURL, path: largePath)

        let service = LocalGitService(localURL: repoURL)
        do {
            _ = try await service.commitAndPush(
                message: "Bypass LFS",
                authorName: "SyncMD Tests",
                authorEmail: "tests@example.com",
                pat: ""
            )
            XCTFail("Expected pre-push validation to block the large non-LFS blob")
        } catch LocalGitError.lfsFailed(let message) {
            XCTAssertTrue(message.contains(largePath))
            XCTAssertTrue(message.contains("Git LFS"))
        }
    }

    func testGitLFSSSHHostKeyTrustStoreAcceptsPersistedTrustedHostKey() throws {
        let trustURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncMD-HostKeys-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: trustURL) }

        let store = GitLFSSSHHostKeyFileTrustStore(fileURL: trustURL)
        try store.trust(fingerprint: "SHA256:trusted", host: "GitHub.com", port: 22)

        let reloaded = GitLFSSSHHostKeyFileTrustStore(fileURL: trustURL)
        XCTAssertNoThrow(try reloaded.validate(fingerprint: "SHA256:trusted", host: "github.com", port: 22))
    }

    func testGitLFSSSHHostKeyTrustStoreRejectsUnknownHostKeyWithFingerprintDetails() throws {
        let trustURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncMD-HostKeys-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: trustURL) }

        let store = GitLFSSSHHostKeyFileTrustStore(fileURL: trustURL)

        XCTAssertThrowsError(try store.validate(fingerprint: "SHA256:new-key", host: "git.example.com", port: 2222)) { error in
            guard let trustError = error as? GitLFSSSHHostKeyTrustError,
                  case let .unknownHostKey(host, port, fingerprint) = trustError else {
                return XCTFail("Expected unknown host-key trust error, got \(error)")
            }
            XCTAssertEqual(host, "git.example.com")
            XCTAssertEqual(port, 2222)
            XCTAssertEqual(fingerprint, "SHA256:new-key")
            XCTAssertTrue(error.localizedDescription.contains("SHA256:new-key"))
            XCTAssertTrue(error.localizedDescription.contains("git.example.com:2222"))
        }
    }

    func testGitLFSSSHHostKeyTrustStoreRejectsChangedHostKey() throws {
        let trustURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncMD-HostKeys-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: trustURL) }

        let store = GitLFSSSHHostKeyFileTrustStore(fileURL: trustURL)
        try store.trust(fingerprint: "SHA256:old-key", host: "git.example.com", port: 22)

        XCTAssertThrowsError(try store.validate(fingerprint: "SHA256:new-key", host: "git.example.com", port: 22)) { error in
            guard let trustError = error as? GitLFSSSHHostKeyTrustError,
                  case let .changedHostKey(host, port, expected, actual) = trustError else {
                return XCTFail("Expected changed host-key trust error, got \(error)")
            }
            XCTAssertEqual(host, "git.example.com")
            XCTAssertEqual(port, 22)
            XCTAssertEqual(expected, "SHA256:old-key")
            XCTAssertEqual(actual, "SHA256:new-key")
            XCTAssertTrue(error.localizedDescription.contains("changed"))
            XCTAssertTrue(error.localizedDescription.contains("SHA256:old-key"))
            XCTAssertTrue(error.localizedDescription.contains("SHA256:new-key"))
        }
    }

    func testGitLFSSSHHostKeyTrustStoreKeepsHostPortsDistinct() throws {
        let trustURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncMD-HostKeys-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: trustURL) }

        let store = GitLFSSSHHostKeyFileTrustStore(fileURL: trustURL)
        try store.trust(fingerprint: "SHA256:port-22", host: "git.example.com", port: 22)

        XCTAssertNoThrow(try store.validate(fingerprint: "SHA256:port-22", host: "git.example.com", port: 22))
        XCTAssertThrowsError(try store.validate(fingerprint: "SHA256:port-22", host: "git.example.com", port: 2222)) { error in
            guard let trustError = error as? GitLFSSSHHostKeyTrustError,
                  case .unknownHostKey = trustError else {
                return XCTFail("Expected unknown host-key trust error for distinct port, got \(error)")
            }
        }

        try store.trust(fingerprint: "SHA256:port-2222", host: "git.example.com", port: 2222)
        XCTAssertNoThrow(try store.validate(fingerprint: "SHA256:port-2222", host: "git.example.com", port: 2222))
        XCTAssertThrowsError(try store.validate(fingerprint: "SHA256:port-2222", host: "git.example.com", port: 22)) { error in
            guard let trustError = error as? GitLFSSSHHostKeyTrustError,
                  case .changedHostKey = trustError else {
                return XCTFail("Expected changed host-key trust error for the separately-pinned port, got \(error)")
            }
        }
    }

    func testGitLFSCreateLockPostsLocksAPI() async throws {
        let repoURL = try makeLFSLockingRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let transport = MockGitLFSTransport { request, body in
            XCTAssertEqual(request.url?.absoluteString, "https://git.example.com/team/vault.git/info/lfs/locks")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.git-lfs+json")
            let bodyData = try XCTUnwrap(body)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(json["path"] as? String, "Docs/Manual.pdf")
            let ref = try XCTUnwrap(json["ref"] as? [String: Any])
            XCTAssertEqual(ref["name"] as? String, "refs/heads/main")
            return (Data("""
            {"lock":{"id":"lock-1","path":"Docs/Manual.pdf","locked_at":"2026-05-14T12:00:00Z","owner":{"name":"Cody"}}}
            """.utf8), 200)
        }

        let lock = try await GitLFSService(
            localURL: repoURL,
            credentials: .httpsToken(username: "cody", password: "secret"),
            transport: transport
        ).createLock(path: "Docs/Manual.pdf", refName: "refs/heads/main")

        XCTAssertEqual(lock?.id, "lock-1")
        XCTAssertEqual(lock?.path, "Docs/Manual.pdf")
        XCTAssertEqual(lock?.owner?.name, "Cody")
        XCTAssertEqual(lock?.lockedAt, ISO8601DateFormatter().date(from: "2026-05-14T12:00:00Z"))
    }

    func testGitLFSListLocksUsesLocksAPI() async throws {
        let repoURL = try makeLFSLockingRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let transport = MockGitLFSTransport { request, body in
            XCTAssertNil(body)
            XCTAssertEqual(request.httpMethod, "GET")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "/team/vault.git/info/lfs/locks")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "path" })?.value, "Docs/Manual.pdf")
            return (Data("""
            {"locks":[{"id":"lock-1","path":"Docs/Manual.pdf","locked_at":"2026-05-14T12:00:00Z","owner":{"name":"Cody"}}],"next_cursor":"next-page"}
            """.utf8), 200)
        }

        let result = try await GitLFSService(
            localURL: repoURL,
            credentials: .none,
            transport: transport
        ).listLocks(path: "Docs/Manual.pdf")

        XCTAssertEqual(result.locks.map(\.id), ["lock-1"])
        XCTAssertEqual(result.nextCursor, "next-page")
    }

    func testGitLFSUnlockLockPostsUnlockAPI() async throws {
        let repoURL = try makeLFSLockingRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let transport = MockGitLFSTransport { request, body in
            XCTAssertEqual(request.url?.absoluteString, "https://git.example.com/team/vault.git/info/lfs/locks/lock-1/unlock")
            XCTAssertEqual(request.httpMethod, "POST")
            let bodyString = String(data: try XCTUnwrap(body), encoding: .utf8) ?? ""
            XCTAssertTrue(bodyString.contains("\"force\":true"))
            return (Data("""
            {"lock":{"id":"lock-1","path":"Docs/Manual.pdf","locked_at":"2026-05-14T12:00:00Z","owner":{"name":"Cody"}}}
            """.utf8), 200)
        }

        let lock = try await GitLFSService(
            localURL: repoURL,
            credentials: .none,
            transport: transport
        ).unlockLock(id: "lock-1", force: true)

        XCTAssertEqual(lock?.id, "lock-1")
        XCTAssertEqual(lock?.path, "Docs/Manual.pdf")
    }

    func testGitLFSVerifyLocksReturnsOursAndTheirs() async throws {
        let repoURL = try makeLFSLockingRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let transport = MockGitLFSTransport { request, body in
            XCTAssertEqual(request.url?.absoluteString, "https://git.example.com/team/vault.git/info/lfs/locks/verify")
            XCTAssertEqual(request.httpMethod, "POST")
            let bodyData = try XCTUnwrap(body)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let ref = try XCTUnwrap(json["ref"] as? [String: Any])
            XCTAssertEqual(ref["name"] as? String, "refs/heads/main")
            return (Data("""
            {"ours":[{"id":"ours-1","path":"Mine.pdf","locked_at":"2026-05-14T12:00:00Z","owner":{"name":"Cody"}}],"theirs":[{"id":"theirs-1","path":"Theirs.pdf","locked_at":"2026-05-14T12:01:00Z","owner":{"name":"Alex"}}],"next_cursor":"cursor-2"}
            """.utf8), 200)
        }

        let result = try await GitLFSService(
            localURL: repoURL,
            credentials: .none,
            transport: transport
        ).verifyLocks(refName: "refs/heads/main")

        XCTAssertTrue(result.lockingSupported)
        XCTAssertEqual(result.ours.map(\.path), ["Mine.pdf"])
        XCTAssertEqual(result.theirs.map(\.owner?.name), ["Alex"])
        XCTAssertEqual(result.nextCursor, "cursor-2")
    }

    func testGitLFSPushVerificationBlocksChangedFileLockedBySomeoneElse() async throws {
        let repoURL = try makeLFSLockingRepo(attributes: "*.pdf filter=lfs diff=lfs merge=lfs -text lockable\n")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let transport = MockGitLFSTransport { request, _ in
            XCTAssertEqual(request.url?.absoluteString, "https://git.example.com/team/vault.git/info/lfs/locks/verify")
            return (Data("""
            {"ours":[],"theirs":[{"id":"theirs-1","path":"Docs/Manual.pdf","locked_at":"2026-05-14T12:01:00Z","owner":{"name":"Alex"}}]}
            """.utf8), 200)
        }

        let service = GitLFSService(localURL: repoURL, credentials: .none, transport: transport)

        do {
            try await service.verifyPushAllowed(
                changedPaths: ["Docs/Manual.pdf", "README.md"],
                refName: "refs/heads/main"
            )
            XCTFail("Expected push verification to reject another user's lock")
        } catch LocalGitError.lfsFailed(let message) {
            XCTAssertTrue(message.contains("Docs/Manual.pdf"))
            XCTAssertTrue(message.contains("Alex"))
        }
    }

    func testGitLFSUnsupportedLockingDegradesCleanly() async throws {
        let repoURL = try makeLFSLockingRepo(attributes: "*.pdf filter=lfs diff=lfs merge=lfs -text lockable\n")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        var requestCount = 0
        let transport = MockGitLFSTransport { _, _ in
            requestCount += 1
            return (Data(), 501)
        }
        let service = GitLFSService(localURL: repoURL, credentials: .none, transport: transport)

        let result = try await service.verifyLocks(refName: "refs/heads/main")
        XCTAssertFalse(result.lockingSupported)
        XCTAssertTrue(GitLFSAttributes.load(from: repoURL).isLockable(path: "Docs/Manual.pdf"))
        try await service.verifyPushAllowed(changedPaths: ["Docs/Manual.pdf"], refName: "refs/heads/main")
        XCTAssertEqual(requestCount, 2)
    }

}
