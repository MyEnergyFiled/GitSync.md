import Foundation
import XCTest
import CryptoKit
import Clibgit2
import libgit2
@testable import Sync_md

func makeLFSLockingRepo(attributes: String = "") throws -> URL {
    let fm = FileManager.default
    let repoURL = fm.temporaryDirectory.appendingPathComponent("SyncMD-LFSLocking-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: repoURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
    try """
    [remote "origin"]
        url = https://git.example.com/team/vault.git
    """.write(to: repoURL.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
    if !attributes.isEmpty {
        try attributes.write(to: repoURL.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    }
    return repoURL
}

final class MockGitLFSTransport: GitLFSHTTPTransport, @unchecked Sendable {
    typealias Handler = (URLRequest, Data?) throws -> (Data, Int)

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func response(for request: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse) {
        let (data, statusCode) = try handler(request, body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

final class MockGitLFSSSHAuthenticator: GitLFSSSHAuthenticator, @unchecked Sendable {
    typealias Handler = (GitLFSSSHAuthRequest, GitRemoteCredentials) async throws -> GitLFSAccess

    private let handler: Handler
    private(set) var requests: [GitLFSSSHAuthRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func authenticate(request: GitLFSSSHAuthRequest, credentials: GitRemoteCredentials) async throws -> GitLFSAccess {
        requests.append(request)
        return try await handler(request, credentials)
    }
}

func makeTemporaryGitRepository(prefix: String) throws -> URL {
    let fm = FileManager.default
    let repoURL = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)

    var repo: OpaquePointer?
    let code = git_repository_init(&repo, repoURL.path, 0)
    if let repo { git_repository_free(repo) }
    guard code == 0 else {
        throw NSError(domain: "SyncMDTests.GitRepositoryInit", code: Int(code))
    }
    return repoURL
}

func stagePathBypassingLocalGitService(repoURL: URL, path: String) throws {
    var repo: OpaquePointer?
    defer { if let repo { git_repository_free(repo) } }
    XCTAssertEqual(git_repository_open(&repo, repoURL.path), 0)

    var index: OpaquePointer?
    defer { if let index { git_index_free(index) } }
    XCTAssertEqual(git_repository_index(&index, repo), 0)
    XCTAssertEqual(path.withCString { git_index_add_bypath(index, $0) }, 0)
    XCTAssertEqual(git_index_write(index), 0)
}

func lfsObjectURL(repoURL: URL, pointer: GitLFSPointer) -> URL {
    repoURL
        .appendingPathComponent(".git/lfs/objects", isDirectory: true)
        .appendingPathComponent(String(pointer.oid.prefix(2)), isDirectory: true)
        .appendingPathComponent(String(pointer.oid.dropFirst(2).prefix(2)), isDirectory: true)
        .appendingPathComponent(pointer.oid)
}

func headBlobString(repoURL: URL, path: String) throws -> String {
    var repo: OpaquePointer?
    defer { if let repo { git_repository_free(repo) } }
    XCTAssertEqual(git_repository_open(&repo, repoURL.path), 0)

    var head: OpaquePointer?
    defer { if let head { git_reference_free(head) } }
    XCTAssertEqual(git_repository_head(&head, repo), 0)

    guard let headOID = git_reference_target(head) else {
        throw LocalGitError.repositoryCorrupted("HEAD missing")
    }

    var oid = headOID.pointee
    var commit: OpaquePointer?
    defer { if let commit { git_commit_free(commit) } }
    XCTAssertEqual(git_commit_lookup(&commit, repo, &oid), 0)

    var tree: OpaquePointer?
    defer { if let tree { git_tree_free(tree) } }
    XCTAssertEqual(git_commit_tree(&tree, commit), 0)

    var entry: OpaquePointer?
    defer { if let entry { git_tree_entry_free(entry) } }
    XCTAssertEqual(path.withCString { git_tree_entry_bypath(&entry, tree, $0) }, 0)

    guard let entryOID = git_tree_entry_id(entry) else {
        throw LocalGitError.repositoryCorrupted("Tree entry missing OID")
    }

    var blobOID = entryOID.pointee
    var blob: OpaquePointer?
    defer { if let blob { git_blob_free(blob) } }
    XCTAssertEqual(git_blob_lookup(&blob, repo, &blobOID), 0)

    let size = Int(git_blob_rawsize(blob))
    guard let raw = git_blob_rawcontent(blob) else { return "" }
    return String(decoding: Data(bytes: raw, count: size), as: UTF8.self)
}

enum GitFixtureState: String, CaseIterable {
    case clean
    case dirty
    case diverged
    case conflicted

    var commitSHA: String {
        switch self {
        case .clean: "1111111111111111111111111111111111111111"
        case .dirty: "2222222222222222222222222222222222222222"
        case .diverged: "3333333333333333333333333333333333333333"
        case .conflicted: "4444444444444444444444444444444444444444"
        }
    }

    var expectedChangeCount: Int {
        switch self {
        case .clean: 0
        case .dirty: 2
        case .diverged: 3
        case .conflicted: 4
        }
    }
}

struct GitFixtureFactory {
    static func make(state: GitFixtureState) throws -> GitFixture {
        let fm = FileManager.default
        let rootURL = fm.temporaryDirectory.appendingPathComponent("SyncMDTests-\(state.rawValue)-\(UUID().uuidString)", isDirectory: true)
        let gitURL = rootURL.appendingPathComponent(".git", isDirectory: true)
        try fm.createDirectory(at: gitURL, withIntermediateDirectories: true)

        try "ref: refs/heads/main\n".write(
            to: gitURL.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "state=\(state.rawValue)\n".write(
            to: gitURL.appendingPathComponent("FIXTURE_STATE"),
            atomically: true,
            encoding: .utf8
        )
        try "# Inbox\n- sync notes\n".write(
            to: rootURL.appendingPathComponent("Inbox.md"),
            atomically: true,
            encoding: .utf8
        )

        switch state {
        case .clean:
            break
        case .dirty:
            try "# Local edits\n- changed\n".write(
                to: rootURL.appendingPathComponent("LocalEdits.md"),
                atomically: true,
                encoding: .utf8
            )
            try "staged=1\nuntracked=1\n".write(
                to: gitURL.appendingPathComponent("STATUS"),
                atomically: true,
                encoding: .utf8
            )
        case .diverged:
            try "local=ahead\nremote=ahead\n".write(
                to: gitURL.appendingPathComponent("DIVERGED"),
                atomically: true,
                encoding: .utf8
            )
            try "# Diverged\nlocal branch differs\n".write(
                to: rootURL.appendingPathComponent("Diverged.md"),
                atomically: true,
                encoding: .utf8
            )
        case .conflicted:
            try "<<<<<<< ours\nlocal\n=======\nremote\n>>>>>>> theirs\n".write(
                to: rootURL.appendingPathComponent("Conflict.md"),
                atomically: true,
                encoding: .utf8
            )
            try "conflicts=1\n".write(
                to: gitURL.appendingPathComponent("MERGE_STATE"),
                atomically: true,
                encoding: .utf8
            )
        }

        let repoID = UUID()
        let repoConfig = RepoConfig(
            id: repoID,
            repoURL: "https://example.com/syncmd-fixture.git",
            branch: "main",
            authorName: "Fixture",
            authorEmail: "fixture@example.com",
            vaultFolderName: rootURL.lastPathComponent,
            customVaultBookmarkData: nil,
            customLocationIsParent: false,
            gitState: GitState(
                commitSHA: state.commitSHA,
                treeSHA: "",
                branch: "main",
                blobSHAs: [:],
                lastSyncDate: Date(timeIntervalSince1970: 0)
            )
        )

        let repoInfo = LocalRepoInfo(
            branch: "main",
            commitSHA: state.commitSHA,
            changeCount: state.expectedChangeCount
        )

        return GitFixture(
            rootURL: rootURL,
            repoConfig: repoConfig,
            repoInfo: repoInfo,
            repository: FakeGitRepository(repoInfoResult: repoInfo)
        )
    }
}

struct GitFixture {
    let rootURL: URL
    let repoConfig: RepoConfig
    let repoInfo: LocalRepoInfo
    let repository: FakeGitRepository

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func snapshot() -> [String: String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return [:]
        }

        var result: [String: String] = [:]
        for case let fileURL as URL in enumerator {
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDirectory else { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "<binary>"
            result[relativePath] = content
        }
        return result
    }
}

actor GitOperationConcurrencyProbe {
    private var current = 0
    private var maximum = 0
    private var completedCount = 0

    func enter() {
        current += 1
        maximum = max(maximum, current)
    }

    func leave() {
        current -= 1
        completedCount += 1
    }

    func snapshot() -> (completed: Int, maximumConcurrent: Int) {
        (completedCount, maximum)
    }
}

actor AsyncTestGate {
    private(set) var isWaiting = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

final class RepoPersistenceWriterStub: RepoPersistenceWriting {
    private let shouldFail: Bool
    private(set) var persistCallCount = 0

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func persist(_ repos: [RepoConfig]) -> Result<Void, PersistenceDependencyFailure> {
        persistCallCount += 1
        if shouldFail {
            return .failure(PersistenceDependencyFailure(diagnostic: "fixture write failure"))
        }
        return .success(())
    }
}

final class RepositoryFileRemoverStub: RepositoryFileRemoving {
    private let shouldFail: Bool
    private(set) var removeCallCount = 0

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func removeItem(at url: URL) -> Result<Void, PersistenceDependencyFailure> {
        removeCallCount += 1
        if shouldFail {
            return .failure(PersistenceDependencyFailure(diagnostic: "fixture removal failure"))
        }
        return .success(())
    }
}

final class FakeGitRepository: GitRepositoryProtocol, @unchecked Sendable {
    var hasGitDirectoryValue: Bool = true
    var repoInfoResult: LocalRepoInfo
    var pullPlanResult: PullPlan
    var pullResult: Result<LocalPullResult, Error>
    var rebaseResult: Result<LocalPullResult, Error>?
    var continueRebaseResult: Result<LocalPullResult, Error>?
    var didAbortRebase = false
    var diffResult: UnifiedDiffResult = .empty
    var commitHistoryResult: [GitCommitSummary] = []
    var commitDetailResultByOID: [String: GitCommitDetail] = [:]
    var stashEntriesResult: [GitStashEntry] = []
    var savedStashes: [(message: String, includeUntracked: Bool)] = []
    var appliedStashIndices: [Int] = []
    var poppedStashIndices: [Int] = []
    var droppedStashIndices: [Int] = []
    var discardedPaths: [String] = []
    var didDiscardAllChanges = false
    var tagsResult: [GitTag] = []
    var createdTags: [(name: String, message: String?)] = []
    var deletedTagNames: [String] = []
    var pushedTagNames: [String] = []
    var branchInventoryResult: BranchInventory = .empty
    var createdBranches: [String] = []
    var switchedBranches: [String] = []
    var deletedBranches: [String] = []
    var mergeResult: MergeResult = MergeResult(kind: .upToDate, sourceBranch: "main", newCommitSHA: "")
    var revertResult: RevertResult = RevertResult(kind: .reverted, targetOID: "", newCommitSHA: nil)
    var mergeFinalizeResult: MergeFinalizeResult = MergeFinalizeResult(newCommitSHA: "")
    var didPushCurrentBranch = false
    var didAbortMerge = false
    var conflictSessionResult: ConflictSession = .none
    var resolvedConflicts: [(path: String, strategy: ConflictResolutionStrategy)] = []
    var stagedPaths: [String] = []
    var lfsAutoTrackStageFlags: [Bool] = []
    var unstagedPaths: [String] = []
    var lfsAutoTrackingCandidatesResult: [GitLFSAutoTrackingCandidate] = []
    var lfsAutoTrackingCandidatePathRequests: [[String]?] = []
    var cloneResults: [Result<LocalCloneResult, Error>] = []
    var cloneRemoteURLs: [String] = []
    var setRemoteURLCalls: [(name: String, url: String)] = []
    var pullPlanError: Error?
    var beforePullPlan: (() async -> Void)?
    var pullPlanCallCount = 0
    var pushCurrentBranchResult: Result<Void, Error>?
    var pushCurrentBranchCallCount = 0
    var commitAndPushResult: Result<LocalPushResult, Error>?
    var commitAndPushMessages: [String] = []
    var commitAndPushFailureCommitSHA: String?

    init(repoInfoResult: LocalRepoInfo) {
        self.repoInfoResult = repoInfoResult
        self.pullPlanResult = PullPlan(
            action: .upToDate,
            branch: repoInfoResult.branch,
            localCommitSHA: repoInfoResult.commitSHA,
            remoteCommitSHA: repoInfoResult.commitSHA,
            hasLocalChanges: repoInfoResult.changeCount > 0,
            aheadBy: 0,
            behindBy: 0
        )
        self.pullResult = .success(LocalPullResult(updated: false, newCommitSHA: repoInfoResult.commitSHA))
    }

    var hasGitDirectory: Bool {
        hasGitDirectoryValue
    }

    func clone(remoteURL: String, pat: String) async throws -> LocalCloneResult {
        cloneRemoteURLs.append(remoteURL)
        if !cloneResults.isEmpty {
            switch cloneResults.removeFirst() {
            case .success(let result):
                return result
            case .failure(let error):
                throw error
            }
        }
        return LocalCloneResult(commitSHA: repoInfoResult.commitSHA, branch: repoInfoResult.branch, fileCount: 1)
    }

    func setRemoteURL(name: String, url: String) async throws {
        setRemoteURLCalls.append((name: name, url: url))
    }

    func pullPlan(pat: String) async throws -> PullPlan {
        pullPlanCallCount += 1
        if let beforePullPlan { await beforePullPlan() }
        if let pullPlanError { throw pullPlanError }
        return pullPlanResult
    }

    func pull(pat: String) async throws -> LocalPullResult {
        switch pullResult {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    func pullFastForward(branch: String, pat: String) async throws -> LocalPullResult {
        try await pull(pat: pat)
    }

    func pullRebase(branch: String, pat: String, authorName: String, authorEmail: String) async throws -> LocalPullResult {
        switch rebaseResult ?? pullResult {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    func unifiedDiff(path: String?) async throws -> UnifiedDiffResult {
        diffResult
    }

    func listBranches() async throws -> BranchInventory {
        branchInventoryResult
    }

    func createBranch(name: String) async throws {
        createdBranches.append(name)
    }

    func switchBranch(name: String) async throws {
        switchedBranches.append(name)
    }

    func deleteBranch(name: String) async throws {
        deletedBranches.append(name)
    }

    func mergeBranch(name: String, authorName: String, authorEmail: String) async throws -> MergeResult {
        mergeResult
    }

    func pushCurrentBranch(pat: String) async throws {
        didPushCurrentBranch = true
        pushCurrentBranchCallCount += 1
        if let pushCurrentBranchResult {
            switch pushCurrentBranchResult {
            case .success:
                return
            case .failure(let error):
                throw error
            }
        }
    }

    func fetchRemote(pat: String) async throws {}

    func revertCommit(oid: String, message: String, authorName: String, authorEmail: String) async throws -> RevertResult {
        revertResult
    }

    func completeMerge(message: String, authorName: String, authorEmail: String) async throws -> MergeFinalizeResult {
        mergeFinalizeResult
    }

    func abortMerge() async throws {
        didAbortMerge = true
    }

    func continueRebase(pat: String, authorName: String, authorEmail: String) async throws -> LocalPullResult {
        switch continueRebaseResult ?? rebaseResult ?? pullResult {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    func abortRebase() async throws {
        didAbortRebase = true
    }

    func conflictSession() async throws -> ConflictSession {
        conflictSessionResult
    }

    func resolveConflict(path: String, strategy: ConflictResolutionStrategy) async throws {
        resolvedConflicts.append((path: path, strategy: strategy))
    }

    func conflictDetail(path: String) async throws -> ConflictFileDetail {
        ConflictFileDetail(lookupPath: path, ancestor: nil, ours: nil, theirs: nil)
    }

    func resolveConflictWithContent(
        path: String,
        content: Data,
        additionalPathsToRemove: [String]
    ) async throws {
        resolvedConflicts.append((path: path, strategy: .manual))
    }

    func commitLocal(message: String, authorName: String, authorEmail: String) async throws -> String {
        repoInfoResult.commitSHA
    }

    func lfsAutoTrackingCandidates(paths: [String]?) async throws -> [GitLFSAutoTrackingCandidate] {
        lfsAutoTrackingCandidatePathRequests.append(paths)
        return lfsAutoTrackingCandidatesResult
    }

    func stageAll() async throws {
        try await stageAll(lfsAutoTrack: false)
    }

    func stageAll(lfsAutoTrack: Bool) async throws {
        stagedPaths.append("*")
        lfsAutoTrackStageFlags.append(lfsAutoTrack)
    }

    func stage(path: String, oldPath: String?) async throws {
        try await stage(path: path, oldPath: oldPath, lfsAutoTrack: false)
    }

    func stage(path: String, oldPath: String?, lfsAutoTrack: Bool) async throws {
        stagedPaths.append(path)
        if let oldPath { stagedPaths.append(oldPath) }
        lfsAutoTrackStageFlags.append(lfsAutoTrack)
    }

    func unstage(path: String, oldPath: String?) async throws {
        unstagedPaths.append(path)
        if let oldPath { unstagedPaths.append(oldPath) }
    }

    func discardChanges(path: String) async throws {
        discardedPaths.append(path)
    }

    func discardAllChanges() async throws {
        didDiscardAllChanges = true
    }

    func commitAndPush(
        message: String,
        authorName: String,
        authorEmail: String,
        pat: String
    ) async throws -> LocalPushResult {
        commitAndPushMessages.append(message)
        if let commitAndPushResult {
            switch commitAndPushResult {
            case .success(let result):
                return result
            case .failure(let error):
                if let commitSHA = commitAndPushFailureCommitSHA {
                    repoInfoResult = LocalRepoInfo(
                        branch: repoInfoResult.branch,
                        commitSHA: commitSHA,
                        changeCount: 0,
                        syncState: .ahead,
                        statusEntries: []
                    )
                }
                throw error
            }
        }
        return LocalPushResult(commitSHA: repoInfoResult.commitSHA)
    }

    func listStashes() async throws -> [GitStashEntry] {
        stashEntriesResult
    }

    func saveStash(message: String, authorName: String, authorEmail: String, includeUntracked: Bool) async throws -> GitStashEntry {
        savedStashes.append((message: message, includeUntracked: includeUntracked))
        let entry = GitStashEntry(index: stashEntriesResult.count, oid: UUID().uuidString.replacingOccurrences(of: "-", with: ""), message: message)
        stashEntriesResult.insert(entry, at: 0)
        return entry
    }

    func applyStash(index: Int, reinstateIndex: Bool) async throws -> StashApplyResult {
        appliedStashIndices.append(index)
        return StashApplyResult(kind: .applied, index: index)
    }

    func popStash(index: Int, reinstateIndex: Bool) async throws -> StashApplyResult {
        poppedStashIndices.append(index)
        if index < stashEntriesResult.count {
            stashEntriesResult.remove(at: index)
        }
        return StashApplyResult(kind: .applied, index: index)
    }

    func dropStash(index: Int) async throws {
        droppedStashIndices.append(index)
        if index < stashEntriesResult.count {
            stashEntriesResult.remove(at: index)
        }
    }

    func listTags() async throws -> [GitTag] { tagsResult }

    func createTag(name: String, targetOID: String?, message: String?, authorName: String, authorEmail: String) async throws -> GitTag {
        createdTags.append((name: name, message: message))
        let tag = GitTag(name: "refs/tags/\(name)", oid: UUID().uuidString.replacingOccurrences(of: "-", with: ""), kind: message == nil ? .lightweight : .annotated, message: message, targetOID: "deadbeef")
        tagsResult.append(tag)
        return tag
    }

    func deleteTag(name: String) async throws {
        deletedTagNames.append(name)
        tagsResult.removeAll { $0.shortName == name }
    }

    func pushTag(name: String, pat: String) async throws {
        pushedTagNames.append(name)
    }

    func commitHistory(limit: Int, skip: Int) async throws -> [GitCommitSummary] {
        guard limit > 0 else { return [] }
        guard skip < commitHistoryResult.count else { return [] }
        let upperBound = min(commitHistoryResult.count, skip + limit)
        return Array(commitHistoryResult[skip..<upperBound])
    }

    func commitDetail(oid: String) async throws -> GitCommitDetail {
        if let detail = commitDetailResultByOID[oid] {
            return detail
        }
        throw LocalGitError.libgit2("Commit not found: \(oid)")
    }

    func repoInfo() async throws -> LocalRepoInfo {
        repoInfoResult
    }
}
