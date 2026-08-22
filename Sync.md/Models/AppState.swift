import Foundation
import SwiftUI

struct GitHubAccount: Codable, Identifiable, Equatable {
    var id: String { login.lowercased() }

    let login: String
    var displayName: String
    var avatarURL: String
    var email: String
}

struct LFSAutoTrackingConfirmationRequest: Identifiable, Equatable {
    enum Action: Equatable {
        case stageFile(path: String, oldPath: String?)
        case stageAll
    }

    let id = UUID()
    let repoID: UUID
    let action: Action
    let candidates: [GitLFSAutoTrackingCandidate]

    var message: String {
        let listed = candidates.prefix(4).map { candidate in
            "• \(candidate.path) (\(ByteCountFormatter.string(fromByteCount: candidate.sizeBytes, countStyle: .file)))"
        }.joined(separator: "\n")
        let remaining = candidates.count > 4 ? "\n• +\(candidates.count - 4) more" : ""
        return String(localized: "These files look binary or large and are safer in Git LFS:\n\n\(listed)\(remaining)\n\nUse Git LFS? This will update and stage .gitattributes.")
    }
}

struct SSHHostKeyTrustRequest: Identifiable, Equatable {
    enum Operation: Equatable {
        case clone
        case pull
        case pushCurrentBranch
        case pushCommit(message: String)
    }

    let id = UUID()
    let repoID: UUID
    let operation: Operation
    let trustError: GitLFSSSHHostKeyTrustError

    var title: String {
        switch trustError {
        case .unknownHostKey:
            return String(localized: "Trust SSH Host?")
        case .changedHostKey:
            return String(localized: "SSH Host Key Changed")
        }
    }

    var confirmButtonTitle: String {
        switch trustError {
        case .unknownHostKey:
            return String(localized: "Trust Host")
        case .changedHostKey:
            return String(localized: "Trust New Key")
        }
    }

    var message: String {
        switch trustError {
        case .unknownHostKey(let host, let port, let fingerprint):
            let portString = String(port)
            return String(localized: "\(host):\(portString) presented this SSH host key:\n\n\(fingerprint)\n\nOnly trust it if this fingerprint matches your Forgejo/Git server.")
        case .changedHostKey(let host, let port, let expectedFingerprint, let actualFingerprint):
            let portString = String(port)
            return String(localized: "\(host):\(portString) presented a different SSH host key.\n\nPreviously trusted:\n\(expectedFingerprint)\n\nNew key:\n\(actualFingerprint)\n\nDo not trust the new key unless you intentionally rotated the server's SSH host key.")
        }
    }

    var host: String {
        switch trustError {
        case .unknownHostKey(let host, _, _), .changedHostKey(let host, _, _, _):
            return host
        }
    }

    var port: Int {
        switch trustError {
        case .unknownHostKey(_, let port, _), .changedHostKey(_, let port, _, _):
            return port
        }
    }

    var fingerprintToTrust: String {
        switch trustError {
        case .unknownHostKey(_, _, let fingerprint):
            return fingerprint
        case .changedHostKey(_, _, _, let actualFingerprint):
            return actualFingerprint
        }
    }
}

enum RepoPersistenceError: LocalizedError, Equatable {
    case saveFailed

    var message: String {
        String(localized: "Repository settings could not be saved. Check available storage and try again.")
    }

    var errorDescription: String? {
        message
    }
}

private func persistenceErrorDiagnostic(_ error: Error) -> String {
    if let keychainError = error as? KeychainServiceError {
        return keychainError.diagnosticDescription
    }
    return "type=\(String(reflecting: type(of: error)))"
}

// MARK: - App State

@Observable
final class AppState {

    // MARK: - Repositories

    var repos: [RepoConfig] = []
    private(set) var duplicateReposCleanedCount = 0
    var changeCounts: [UUID: Int] = [:]
    var statusEntriesByRepo: [UUID: [GitStatusEntry]] = [:]
    var syncStateByRepo: [UUID: RepoSyncState] = [:]
    var pullOutcomeByRepo: [UUID: PullOutcomeState] = [:]
    var diffByRepo: [UUID: UnifiedDiffResult] = [:]
    var branchesByRepo: [UUID: BranchInventory] = [:]
    var conflictSessionByRepo: [UUID: ConflictSession] = [:]
    var commitHistoryByRepo: [UUID: [GitCommitSummary]] = [:]
    var commitHistoryHasMoreByRepo: [UUID: Bool] = [:]
    var commitDetailByRepo: [UUID: [String: GitCommitDetail]] = [:]
    var stashesByRepo: [UUID: [GitStashEntry]] = [:]
    var tagsByRepo: [UUID: [GitTag]] = [:]
    private(set) var indexMutationRepoIDs: Set<UUID> = []

    func isIndexMutationInProgress(repoID: UUID) -> Bool {
        indexMutationRepoIDs.contains(repoID)
    }

    func isRepositoryOperationInProgress(repoID: UUID) -> Bool {
        (isSyncing && syncingRepoID == repoID) || isIndexMutationInProgress(repoID: repoID)
    }

    // MARK: - Sync State

    var isSyncing: Bool = false
    var syncingRepoID: UUID? = nil
    var syncProgress: String = ""
    var syncProgressFraction: Double? = nil
    var gitLongOperationProgress: GitLongOperationProgress? = nil

    var canCancelSyncOperation: Bool {
        gitLongOperationProgress?.canCancel == true
    }

    var isSyncCancellationRequested: Bool {
        gitLongOperationProgress?.cancellationRequested == true
    }

    // MARK: - OAuth / Auth

    var isSignedIn: Bool = false
    var gitHubUsername: String = ""
    var gitHubDisplayName: String = ""
    var gitHubAvatarURL: String = ""
    var defaultAuthorName: String = ""
    var defaultAuthorEmail: String = ""
    var gitHubRepos: [GitHubRepo] = []
    var isLoadingRepos: Bool = false
    var gitHubAccounts: [GitHubAccount] = []
    var activeGitHubAccountLogin: String = ""

    // MARK: - Callback State (x-callback-url from Obsidian plugin)

    /// When set, the UI programmatically navigates to this repo's VaultView.
    var callbackNavigateToRepoID: UUID? = nil

    /// Result from a completed callback operation — shown briefly before redirecting.
    var callbackResult: CallbackResultState? = nil

    // MARK: - Default Save Location

    var defaultSaveLocationBookmarkData: Data? = nil
    var resolvedDefaultSaveURL: URL? = nil
    private var defaultSaveAccessingScope: Bool = false

    /// Whether onboarding (including the save-location step) has been completed.
    var hasCompletedOnboarding: Bool = false

    /// Whether the user has seen the feature onboarding slides.
    var hasSeenOnboarding: Bool = false



    // MARK: - Errors & Confirmations

    var lastError: String? = nil
    var lastErrorGuidance: GitFailureGuidance? = nil
    var showError: Bool = false
    var pendingLFSAutoTrackingConfirmation: LFSAutoTrackingConfirmationRequest? = nil
    var pendingSSHHostKeyTrustRequest: SSHHostKeyTrustRequest? = nil

    // MARK: - Security-Scoped URLs (runtime only)

    private var resolvedCustomURLs: [UUID: URL] = [:]
    private var accessingSecurityScope: Set<UUID> = []

    // MARK: - Background Status Refresh

    private var changeDetectionInFlight: Set<UUID> = []
    private var pendingChangeDetection: Set<UUID> = []
    private var lastChangeDetectionStartedAt: [UUID: Date] = [:]
    private var repoMutationGeneration: [UUID: Int] = [:]
    private var didScheduleInitialChangeDetection = false
    private var pushRetryRequiresCurrentBranch: Set<UUID> = []
    private var pushRetryRequiresCommit: Set<UUID> = []
    private var lastPushFailureByRepo: [UUID: String] = [:]
    private var gitHubTokenRefreshTasks: [String: Task<GitHubOAuthCredential, Error>] = [:]

    // MARK: - PAT / GitHub Accounts

    var pat: String {
        get {
            if let token = gitHubToken(for: activeGitHubAccountLogin), !token.isEmpty {
                return token
            }
            return keychainValue(for: "github_pat") ?? ""
        }
        set {
            if newValue.isEmpty {
                if !activeGitHubAccountLogin.isEmpty {
                    deleteGitHubCredential(for: activeGitHubAccountLogin)
                }
                deleteKeychainValue(for: "github_pat")
            } else if !activeGitHubAccountLogin.isEmpty {
                saveGitHubCredential(GitHubOAuthCredential(accessToken: newValue), for: activeGitHubAccountLogin)
            } else {
                saveKeychainValue(newValue, for: "github_pat")
            }
        }
    }

    var activeGitHubAccount: GitHubAccount? {
        gitHubAccounts.first { $0.login.caseInsensitiveCompare(activeGitHubAccountLogin) == .orderedSame }
    }

    var visibleRepos: [RepoConfig] {
        repos.filter { shouldShowRepoForActiveAccount($0) }
    }

    private static func gitHubTokenKey(for login: String) -> String {
        "github_pat_\(login.lowercased())"
    }

    private static func gitHubOAuthCredentialKey(for login: String) -> String {
        "github_oauth_credential_\(login.lowercased())"
    }

    private func keychainValue(for key: String) -> String? {
        do {
            return try KeychainService.load(key: key)
        } catch {
            if let keychainError = error as? KeychainServiceError {
                DebugLogger.shared.error(
                    "persistence",
                    "Secure credential load failed",
                    detail: keychainError.diagnosticDescription
                )
            }
            return nil
        }
    }

    @discardableResult
    private func saveKeychainValue(_ value: String, for key: String) -> Bool {
        do {
            try KeychainService.save(key: key, value: value)
            return true
        } catch {
            if let keychainError = error as? KeychainServiceError {
                DebugLogger.shared.error(
                    "persistence",
                    "Secure credential save failed",
                    detail: keychainError.diagnosticDescription
                )
            }
            showError(
                message: (error as? KeychainServiceError)?.errorDescription
                    ?? String(localized: "Secure credential access failed."),
                category: "persistence"
            )
            return false
        }
    }

    @discardableResult
    private func deleteKeychainValue(for key: String) -> Bool {
        do {
            try KeychainService.delete(key: key)
            return true
        } catch {
            if let keychainError = error as? KeychainServiceError {
                DebugLogger.shared.error(
                    "persistence",
                    "Secure credential deletion failed",
                    detail: keychainError.diagnosticDescription
                )
            }
            showError(
                message: (error as? KeychainServiceError)?.errorDescription
                    ?? String(localized: "Secure credential access failed."),
                category: "persistence"
            )
            return false
        }
    }

    private func gitHubCredential(for login: String?) -> GitHubOAuthCredential? {
        guard let login = login?.trimmingCharacters(in: .whitespacesAndNewlines), !login.isEmpty else {
            return nil
        }
        if let encoded = keychainValue(for: Self.gitHubOAuthCredentialKey(for: login)),
           let data = encoded.data(using: .utf8) {
            do {
                return try JSONDecoder().decode(GitHubOAuthCredential.self, from: data)
            } catch {
                showError(message: String(localized: "Saved GitHub credentials could not be loaded."), category: "persistence")
                DebugLogger.shared.error(
                    "persistence",
                    "Could not decode saved GitHub credential",
                    detail: persistenceErrorDiagnostic(error)
                )
            }
        }
        guard let accessToken = keychainValue(for: Self.gitHubTokenKey(for: login)),
              !accessToken.isEmpty else { return nil }
        return GitHubOAuthCredential(accessToken: accessToken)
    }

    private func saveGitHubCredential(_ credential: GitHubOAuthCredential, for login: String) {
        saveKeychainValue(credential.accessToken, for: Self.gitHubTokenKey(for: login))
        do {
            let data = try JSONEncoder().encode(credential)
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            saveKeychainValue(encoded, for: Self.gitHubOAuthCredentialKey(for: login))
        } catch {
            showError(message: String(localized: "GitHub credentials could not be encoded."), category: "persistence")
            DebugLogger.shared.error(
                "persistence",
                "Could not encode GitHub credential",
                detail: persistenceErrorDiagnostic(error)
            )
        }
    }

    private func deleteGitHubCredential(for login: String) {
        deleteKeychainValue(for: Self.gitHubTokenKey(for: login))
        deleteKeychainValue(for: Self.gitHubOAuthCredentialKey(for: login))
    }

    func gitHubToken(for login: String?) -> String? {
        gitHubCredential(for: login)?.accessToken
    }

    private func shouldShowRepoForActiveAccount(_ repo: RepoConfig) -> Bool {
        if let ownerLogin = repo.gitHubAccountLogin?.trimmingCharacters(in: .whitespacesAndNewlines), !ownerLogin.isEmpty {
            return isSignedIn && ownerLogin.caseInsensitiveCompare(activeGitHubAccountLogin) == .orderedSame
        }
        if repo.authMethod == .gitHubPAT, GitRemoteURL.parse(repo.repoURL)?.isGitHub == true {
            return isSignedIn
        }
        return true
    }

    // MARK: - Per-Repo Remote Credentials

    private static func repoCredentialKey(_ repoID: UUID, _ suffix: String) -> String {
        "repo_\(repoID.uuidString)_\(suffix)"
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    func saveRemoteCredentials(_ credentials: GitRemoteCredentials, for repoID: UUID) {
        clearRemoteCredentials(for: repoID)

        let username = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !username.isEmpty {
            saveKeychainValue(username, for: Self.repoCredentialKey(repoID, "username"))
        }
        if !credentials.password.isEmpty {
            saveKeychainValue(credentials.password, for: Self.repoCredentialKey(repoID, "password"))
        }
        if !credentials.privateKey.isEmpty {
            saveKeychainValue(credentials.privateKey, for: Self.repoCredentialKey(repoID, "ssh_private_key"))
        }
        if !credentials.publicKey.isEmpty {
            saveKeychainValue(credentials.publicKey, for: Self.repoCredentialKey(repoID, "ssh_public_key"))
        }
        if !credentials.passphrase.isEmpty {
            saveKeychainValue(credentials.passphrase, for: Self.repoCredentialKey(repoID, "ssh_passphrase"))
        }
    }

    func clearRemoteCredentials(for repoID: UUID) {
        deleteKeychainValue(for: Self.repoCredentialKey(repoID, "username"))
        deleteKeychainValue(for: Self.repoCredentialKey(repoID, "password"))
        deleteKeychainValue(for: Self.repoCredentialKey(repoID, "ssh_private_key"))
        deleteKeychainValue(for: Self.repoCredentialKey(repoID, "ssh_public_key"))
        deleteKeychainValue(for: Self.repoCredentialKey(repoID, "ssh_passphrase"))
    }

    func remoteCredentials(for repo: RepoConfig) -> GitRemoteCredentials {
        switch repo.authMethod {
        case .gitHubPAT:
            let token = gitHubToken(for: repo.gitHubAccountLogin) ?? pat
            return token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .gitHubPAT(token)
        case .none:
            return .none
        case .httpsToken:
            let username = Self.firstNonEmpty(
                keychainValue(for: Self.repoCredentialKey(repo.id, "username")),
                repo.authUsername,
                GitRemoteURL.parse(repo.repoURL)?.username
            ) ?? ""
            let password = keychainValue(for: Self.repoCredentialKey(repo.id, "password")) ?? ""
            return .httpsToken(username: username, password: password)
        case .sshKey:
            let username = Self.firstNonEmpty(
                keychainValue(for: Self.repoCredentialKey(repo.id, "username")),
                repo.authUsername,
                GitRemoteURL.parse(repo.repoURL)?.username
            ) ?? "git"
            return .sshKey(
                username: username,
                privateKey: keychainValue(for: Self.repoCredentialKey(repo.id, "ssh_private_key")) ?? "",
                publicKey: keychainValue(for: Self.repoCredentialKey(repo.id, "ssh_public_key")) ?? "",
                passphrase: keychainValue(for: Self.repoCredentialKey(repo.id, "ssh_passphrase")) ?? ""
            )
        }
    }

    @MainActor
    private func validGitHubToken(for login: String?) async throws -> String {
        let requestedLogin = login?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedLogin = requestedLogin.isEmpty ? activeGitHubAccountLogin : requestedLogin
        guard let credential = gitHubCredential(for: resolvedLogin), !credential.accessToken.isEmpty else {
            throw OAuthError.failed(String(localized: "GitHub authentication is missing. Sign in again."))
        }
        guard credential.requiresRefresh() else { return credential.accessToken }
        guard let refreshToken = credential.usableRefreshToken() else {
            throw OAuthError.failed(String(localized: "Your GitHub session expired. Sign in again to continue."))
        }

        do {
            let refreshTask: Task<GitHubOAuthCredential, Error>
            if let existingTask = gitHubTokenRefreshTasks[resolvedLogin] {
                refreshTask = existingTask
            } else {
                let newTask = Task {
                    try await OAuthService.shared.refresh(refreshToken: refreshToken)
                }
                gitHubTokenRefreshTasks[resolvedLogin] = newTask
                refreshTask = newTask
            }
            let refreshed = try await refreshTask.value
            gitHubTokenRefreshTasks.removeValue(forKey: resolvedLogin)
            saveGitHubCredential(refreshed, for: resolvedLogin)
            DebugLogger.shared.info("auth", "Refreshed GitHub access token", detail: resolvedLogin)
            return refreshed.accessToken
        } catch {
            gitHubTokenRefreshTasks.removeValue(forKey: resolvedLogin)
            DebugLogger.shared.error("auth", "GitHub token refresh failed", detail: error.localizedDescription)
            throw OAuthError.failed(
                String(localized: "Could not refresh the GitHub session. Check the network or sign in again.")
            )
        }
    }

    @MainActor
    func authPayload(for repo: RepoConfig) async throws -> String {
        guard repo.authMethod == .gitHubPAT else {
            return remoteCredentials(for: repo).transportPayload
        }
        let token = try await validGitHubToken(for: repo.gitHubAccountLogin)
        return GitRemoteCredentials.gitHubPAT(token).transportPayload
    }

    // MARK: - Dependencies

    private let gitRepositoryFactory: (URL) -> any GitRepositoryProtocol
    private let sshHostKeyTrustStore: any GitLFSSSHHostKeyTrustStore
    private let gitOperationCoordinator: GitOperationCoordinator
    private let reposPersistenceWriter: ([RepoConfig]) throws -> Void
    private let repositoryFileRemover: (URL) throws -> Void

    // MARK: - Init

    init(
        gitRepositoryFactory: @escaping (URL) -> any GitRepositoryProtocol = { LocalGitService(localURL: $0) },
        sshHostKeyTrustStore: any GitLFSSSHHostKeyTrustStore = GitLFSSSHHostKeyFileTrustStore.default,
        gitOperationCoordinator: GitOperationCoordinator = .shared,
        reposPersistenceWriter: @escaping ([RepoConfig]) throws -> Void = { try AppState.persistRepos($0) },
        repositoryFileRemover: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        loadPersistedState: Bool = true
    ) {
        self.gitRepositoryFactory = gitRepositoryFactory
        self.sshHostKeyTrustStore = sshHostKeyTrustStore
        self.gitOperationCoordinator = gitOperationCoordinator
        self.reposPersistenceWriter = reposPersistenceWriter
        self.repositoryFileRemover = repositoryFileRemover
        if loadPersistedState {
            loadState()
        }
    }

    // MARK: - Persistence

    static var persistedReposFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("SyncMD", isDirectory: true)
        return dir.appendingPathComponent("repos.json")
    }

    private static var reposFileURL: URL {
        persistedReposFileURL
    }

    static func loadPersistedRepos() -> [RepoConfig] {
        do {
            let data = try Data(contentsOf: persistedReposFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([RepoConfig].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            DebugLogger.shared.error(
                "persistence",
                "Could not load repository settings",
                detail: persistenceErrorDiagnostic(error)
            )
            return []
        }
    }

    static func persistRepos(_ repos: [RepoConfig]) throws {
        let fileURL = persistedReposFileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(repos)
        try data.write(to: fileURL, options: .atomic)
    }

    private func loadState() {
        let defaults = UserDefaults.standard
        gitHubUsername = defaults.string(forKey: "gitHubUsername") ?? ""
        gitHubDisplayName = defaults.string(forKey: "gitHubDisplayName") ?? ""
        gitHubAvatarURL = defaults.string(forKey: "gitHubAvatarURL") ?? ""
        defaultAuthorName = defaults.string(forKey: "authorName") ?? ""
        defaultAuthorEmail = defaults.string(forKey: "authorEmail") ?? ""
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        hasSeenOnboarding = defaults.bool(forKey: "hasSeenOnboarding")

        if let accountData = defaults.data(forKey: "gitHubAccounts") {
            do {
                gitHubAccounts = try JSONDecoder().decode([GitHubAccount].self, from: accountData)
            } catch {
                showError(message: String(localized: "Saved GitHub accounts could not be loaded."), category: "persistence")
                DebugLogger.shared.error(
                    "persistence",
                    "Could not decode saved GitHub accounts",
                    detail: persistenceErrorDiagnostic(error)
                )
            }
        }
        activeGitHubAccountLogin = defaults.string(forKey: "activeGitHubAccountLogin") ?? ""
        migrateLegacyGitHubAccountIfNeeded()
        restoreActiveGitHubAccount()

        // Load default save location bookmark
        defaultSaveLocationBookmarkData = defaults.data(forKey: "defaultSaveLocationBookmark")
        resolveDefaultSaveBookmark()

        // Try to load multi-repo state
        if FileManager.default.fileExists(atPath: Self.reposFileURL.path) {
            do {
                let data = try Data(contentsOf: Self.reposFileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode([RepoConfig].self, from: data)
                repos = Self.deduplicatedRepos(decoded)
                duplicateReposCleanedCount = decoded.count - repos.count
                if duplicateReposCleanedCount > 0 {
                    saveRepos()
                    DebugLogger.shared.info(
                        "repository",
                        "Merged duplicate repository records",
                        detail: "\(duplicateReposCleanedCount) records; local files preserved"
                    )
                }
            } catch {
                showError(message: String(localized: "Saved repository settings could not be loaded."), category: "persistence")
                DebugLogger.shared.error(
                    "persistence",
                    "Could not load saved repository settings",
                    detail: persistenceErrorDiagnostic(error)
                )
            }
        } else {
            // Migration from single-repo state
            migrateFromLegacy()
        }

        migrateRepoAccountOwnershipIfNeeded()

        // Resolve custom vault bookmarks
        for repo in repos {
            resolveVaultBookmark(for: repo.id)
        }

        // Validate that cloned repos still exist on disk
        validateClonedRepos()

        // Do not scan Git status synchronously during app construction. Large
        // vaults (especially hydrated Git LFS files) can make launch appear as
        // a black screen or trigger iOS watchdog kills. The first refresh is
        // scheduled after the initial UI frame in ContentView.onAppear.
    }

    private func migrateFromLegacy() {
        let defaults = UserDefaults.standard
        let legacyRepoURL = defaults.string(forKey: "repoURL") ?? ""
        let legacyIsSetUp = defaults.bool(forKey: "isSetUp")

        guard legacyIsSetUp, !legacyRepoURL.isEmpty else { return }

        let legacyGitState = GitState.loadLegacy() ?? .empty

        let config = RepoConfig(
            repoURL: legacyRepoURL,
            branch: defaults.string(forKey: "branch") ?? "main",
            authorName: defaults.string(forKey: "authorName") ?? "",
            authorEmail: defaults.string(forKey: "authorEmail") ?? "",
            vaultFolderName: defaults.string(forKey: "vaultFolderName") ?? "vault",
            customVaultBookmarkData: defaults.data(forKey: "vaultBookmark"),
            gitHubAccountLogin: activeGitHubAccountLogin.isEmpty ? nil : activeGitHubAccountLogin,
            gitState: legacyGitState
        )

        repos = [config]
        saveRepos()

        // Clean up legacy keys
        GitState.deleteLegacy()
        defaults.removeObject(forKey: "isSetUp")
        defaults.removeObject(forKey: "repoURL")
        defaults.removeObject(forKey: "branch")
        defaults.removeObject(forKey: "vaultFolderName")
        defaults.removeObject(forKey: "vaultBookmark")
    }

    private func migrateLegacyGitHubAccountIfNeeded() {
        guard gitHubAccounts.isEmpty,
              let legacyToken = keychainValue(for: "github_pat"),
              !legacyToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !gitHubUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let account = GitHubAccount(
            login: gitHubUsername,
            displayName: gitHubDisplayName.isEmpty ? gitHubUsername : gitHubDisplayName,
            avatarURL: gitHubAvatarURL,
            email: defaultAuthorEmail
        )
        gitHubAccounts = [account]
        activeGitHubAccountLogin = account.login
        saveKeychainValue(legacyToken, for: Self.gitHubTokenKey(for: account.login))
    }

    private func restoreActiveGitHubAccount() {
        if activeGitHubAccountLogin.isEmpty || gitHubToken(for: activeGitHubAccountLogin)?.isEmpty != false {
            activeGitHubAccountLogin = gitHubAccounts.first(where: { gitHubToken(for: $0.login)?.isEmpty == false })?.login ?? ""
        }

        guard let account = activeGitHubAccount,
              gitHubToken(for: account.login)?.isEmpty == false
        else {
            isSignedIn = false
            activeGitHubAccountLogin = ""
            gitHubRepos = []
            return
        }

        isSignedIn = true
        applyGitHubAccount(account)
    }

    private func migrateRepoAccountOwnershipIfNeeded() {
        guard !activeGitHubAccountLogin.isEmpty else { return }
        var didChange = false
        for idx in repos.indices {
            guard repos[idx].gitHubAccountLogin?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                  repos[idx].authMethod == .gitHubPAT,
                  GitRemoteURL.parse(repos[idx].repoURL)?.isGitHub == true
            else { continue }
            repos[idx].gitHubAccountLogin = activeGitHubAccountLogin
            didChange = true
        }
        if didChange { saveRepos() }
    }

    private func applyGitHubAccount(_ account: GitHubAccount) {
        gitHubUsername = account.login
        gitHubDisplayName = account.displayName
        gitHubAvatarURL = account.avatarURL
        defaultAuthorName = account.displayName.isEmpty ? account.login : account.displayName
        defaultAuthorEmail = account.email
    }

    @discardableResult
    func saveRepos() -> Result<Void, RepoPersistenceError> {
        do {
            try reposPersistenceWriter(repos)
            return .success(())
        } catch {
            DebugLogger.shared.error(
                "persistence",
                "Could not save repository settings",
                detail: persistenceErrorDiagnostic(error)
            )
            showError(message: RepoPersistenceError.saveFailed.message, category: "persistence")
            return .failure(.saveFailed)
        }
    }

    func saveGlobalSettings() {
        let defaults = UserDefaults.standard
        defaults.set(gitHubUsername, forKey: "gitHubUsername")
        defaults.set(gitHubDisplayName, forKey: "gitHubDisplayName")
        defaults.set(gitHubAvatarURL, forKey: "gitHubAvatarURL")
        defaults.set(defaultAuthorName, forKey: "authorName")
        defaults.set(defaultAuthorEmail, forKey: "authorEmail")
        defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        defaults.set(hasSeenOnboarding, forKey: "hasSeenOnboarding")
        defaults.set(activeGitHubAccountLogin, forKey: "activeGitHubAccountLogin")
        do {
            let accountData = try JSONEncoder().encode(gitHubAccounts)
            defaults.set(accountData, forKey: "gitHubAccounts")
        } catch {
            showError(message: String(localized: "GitHub account settings could not be saved."), category: "persistence")
            DebugLogger.shared.error(
                "persistence",
                "Could not encode GitHub account settings",
                detail: persistenceErrorDiagnostic(error)
            )
        }

        if let bookmarkData = defaultSaveLocationBookmarkData {
            defaults.set(bookmarkData, forKey: "defaultSaveLocationBookmark")
        } else {
            defaults.removeObject(forKey: "defaultSaveLocationBookmark")
        }
    }

    // MARK: - Default Save Location

    func setDefaultSaveLocation(_ url: URL) {
        clearDefaultSaveLocation()

        guard url.startAccessingSecurityScopedResource() else { return }

        guard let bookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            url.stopAccessingSecurityScopedResource()
            return
        }

        defaultSaveLocationBookmarkData = bookmark
        resolvedDefaultSaveURL = url
        defaultSaveAccessingScope = true
        saveGlobalSettings()
    }

    func clearDefaultSaveLocation() {
        if defaultSaveAccessingScope, let url = resolvedDefaultSaveURL {
            url.stopAccessingSecurityScopedResource()
            defaultSaveAccessingScope = false
        }
        resolvedDefaultSaveURL = nil
        defaultSaveLocationBookmarkData = nil
        saveGlobalSettings()
    }

    var defaultSaveDisplayPath: String {
        resolvedDefaultSaveURL?.path ?? ""
    }

    var hasDefaultSaveLocation: Bool {
        resolvedDefaultSaveURL != nil
    }

    private func resolveDefaultSaveBookmark() {
        guard let bookmarkData = defaultSaveLocationBookmarkData else { return }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        if url.startAccessingSecurityScopedResource() {
            defaultSaveAccessingScope = true
        }
        resolvedDefaultSaveURL = url

        if isStale {
            if let newBookmark = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                defaultSaveLocationBookmarkData = newBookmark
                saveGlobalSettings()
            }
        }
    }

    // MARK: - Repo Access

    func repo(id: UUID) -> RepoConfig? {
        repos.first { $0.id == id }
    }

    func repoIndex(id: UUID) -> Int? {
        repos.firstIndex { $0.id == id }
    }

    func vaultURL(for repoID: UUID) -> URL {
        if let customURL = resolvedCustomURLs[repoID] {
            // When the bookmark points to a parent directory (clone to custom
            // location), append the repo folder name — just like `git clone`.
            if let repo = repo(id: repoID), repo.customLocationIsParent {
                return customURL.appendingPathComponent(repo.vaultFolderName, isDirectory: true)
            }
            return customURL
        }
        guard let repo = repo(id: repoID) else {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        }
        return repo.defaultVaultURL
    }

    func vaultDisplayPath(for repoID: UUID) -> String {
        if let customURL = resolvedCustomURLs[repoID] {
            if let repo = repo(id: repoID), repo.customLocationIsParent {
                return customURL.appendingPathComponent(repo.vaultFolderName).path
            }
            return customURL.path
        }
        guard let repo = repo(id: repoID) else { return "" }
        return String(localized: "On My iPhone › HugoInk › \(repo.vaultFolderName)")
    }

    func isUsingCustomLocation(for repoID: UUID) -> Bool {
        resolvedCustomURLs[repoID] != nil
    }

    // MARK: - Vault Location

    func setCustomVaultLocation(_ url: URL, for repoID: UUID) {
        // Stop any previous security-scoped access for this repo
        clearCustomLocation(for: repoID)

        guard url.startAccessingSecurityScopedResource() else { return }

        guard let bookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            url.stopAccessingSecurityScopedResource()
            return
        }

        if let idx = repoIndex(id: repoID) {
            repos[idx].customVaultBookmarkData = bookmark
            saveRepos()
        }

        resolvedCustomURLs[repoID] = url
        accessingSecurityScope.insert(repoID)
    }

    func clearCustomLocation(for repoID: UUID) {
        if accessingSecurityScope.contains(repoID), let url = resolvedCustomURLs[repoID] {
            url.stopAccessingSecurityScopedResource()
            accessingSecurityScope.remove(repoID)
        }
        resolvedCustomURLs.removeValue(forKey: repoID)
        if let idx = repoIndex(id: repoID) {
            repos[idx].customVaultBookmarkData = nil
            saveRepos()
        }
    }

    /// Moves a repo's vault to a new parent directory.
    ///
    /// The caller must already hold a security-scoped resource on `newParentURL`
    /// (typically from a `fileImporter` selection). On success, ownership of
    /// that scope is transferred to `AppState` and tracked in
    /// `accessingSecurityScope`. On failure the caller is responsible for
    /// releasing it.
    func moveVaultLocation(for repoID: UUID, to newParentURL: URL, bookmark: Data) throws {
        guard !isRepositoryOperationInProgress(repoID: repoID) else {
            throw MoveVaultError.operationInProgress
        }
        guard let idx = repoIndex(id: repoID) else {
            throw MoveVaultError.repoNotFound
        }

        let repo = repos[idx]
        let currentURL = vaultURL(for: repoID)
        let destinationURL = newParentURL.appendingPathComponent(repo.vaultFolderName, isDirectory: true)

        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw MoveVaultError.destinationExists
        }

        // If the source vault lives in a user-picked custom location, we need
        // its security scope live during the move. The default in-app vault
        // (Documents directory) is always accessible without a scope.
        if resolvedCustomURLs[repoID] != nil, !accessingSecurityScope.contains(repoID) {
            throw MoveVaultError.bookmarkFailed
        }

        try FileManager.default.moveItem(at: currentURL, to: destinationURL)

        // Release the old custom-location scope (if any) now that the source
        // is gone, then hand the new parent's scope — already held by the
        // caller — over to AppState.
        clearCustomLocation(for: repoID)

        repos[idx].customVaultBookmarkData = bookmark
        repos[idx].customLocationIsParent = true
        saveRepos()

        resolvedCustomURLs[repoID] = newParentURL
        accessingSecurityScope.insert(repoID)

        detectChanges(repoID: repoID)
    }

    enum MoveVaultError: LocalizedError, Equatable {
        case repoNotFound
        case destinationExists
        case bookmarkFailed
        case operationInProgress

        var errorDescription: String? {
            switch self {
            case .repoNotFound: String(localized: "Repository not found")
            case .destinationExists: String(localized: "A folder with the same name already exists at the chosen location")
            case .bookmarkFailed: String(localized: "Could not access the selected folder")
            case .operationInProgress:
                String(localized: "Wait for the current Git operation to finish before moving or removing this repository.")
            }
        }
    }

    private func resolveVaultBookmark(for repoID: UUID) {
        guard let repo = repo(id: repoID),
              let bookmarkData = repo.customVaultBookmarkData else { return }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        if url.startAccessingSecurityScopedResource() {
            accessingSecurityScope.insert(repoID)
        }
        resolvedCustomURLs[repoID] = url

        if isStale {
            if let newBookmark = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ), let idx = repoIndex(id: repoID) {
                repos[idx].customVaultBookmarkData = newBookmark
                saveRepos()
            }
        }
    }

    // MARK: - Filesystem Validation

    /// Check all repos marked as cloned and reset any whose `.git` directory
    /// has been deleted from the filesystem (e.g. via Files app).
    func validateClonedRepos() {
        var didChange = false
        for (index, repo) in repos.enumerated() where repo.isCloned {
            // A security-scoped provider can be temporarily unavailable while
            // the device is locked or while the provider is offline. Preserve
            // the last known clone state instead of treating that as deletion.
            if !AutomatedPullPolicy.shouldValidateCloneDirectory(
                requiresExternalStorage: repo.customVaultBookmarkData != nil,
                hasExternalStorageAccess: resolvedCustomURLs[repo.id] != nil
            ) {
                continue
            }

            let vaultDir = vaultURL(for: repo.id)
            let gitService = gitRepositoryFactory(vaultDir)

            if !gitService.hasGitDirectory {
                repos[index].gitState = .empty
                changeCounts[repo.id] = 0
                statusEntriesByRepo[repo.id] = []
                syncStateByRepo[repo.id] = .unknown
                diffByRepo[repo.id] = .empty
                branchesByRepo[repo.id] = .empty
                conflictSessionByRepo[repo.id] = .none
                commitHistoryByRepo[repo.id] = []
                commitHistoryHasMoreByRepo[repo.id] = false
                commitDetailByRepo[repo.id] = [:]
                stashesByRepo[repo.id] = []
                didChange = true
            }
        }
        if didChange {
            saveRepos()
        }
    }

    // MARK: - Change Detection

    func scheduleInitialChangeDetectionIfNeeded() {
        guard !didScheduleInitialChangeDetection else { return }
        didScheduleInitialChangeDetection = true
        refreshClonedRepos(deferredBy: 0.75, skipIfRecentlyStartedWithin: 10)
    }

    func refreshClonedRepos(deferredBy delay: TimeInterval = 0, skipIfRecentlyStartedWithin interval: TimeInterval? = nil) {
        let repoIDs = repos.filter(\.isCloned).map(\.id)
        guard !repoIDs.isEmpty else { return }

        Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            for repoID in repoIDs {
                detectChanges(repoID: repoID, skipIfRecentlyStartedWithin: interval)
            }
        }
    }

    func detectChanges(repoID: UUID, skipIfRecentlyStartedWithin interval: TimeInterval? = nil) {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            // .git directory was removed — reset cloned state
            if let idx = repoIndex(id: repoID) {
                repos[idx].gitState = .empty
                saveRepos()
            }
            changeCounts[repoID] = 0
            statusEntriesByRepo[repoID] = []
            syncStateByRepo[repoID] = .unknown
            diffByRepo[repoID] = .empty
            branchesByRepo[repoID] = .empty
            conflictSessionByRepo[repoID] = .none
            commitHistoryByRepo[repoID] = []
            commitHistoryHasMoreByRepo[repoID] = false
            commitDetailByRepo[repoID] = [:]
            stashesByRepo[repoID] = []
            return
        }

        let now = Date()
        if let interval,
           let lastStartedAt = lastChangeDetectionStartedAt[repoID],
           now.timeIntervalSince(lastStartedAt) < interval {
            return
        }

        if changeDetectionInFlight.contains(repoID) {
            pendingChangeDetection.insert(repoID)
            return
        }
        changeDetectionInFlight.insert(repoID)
        lastChangeDetectionStartedAt[repoID] = now

        let startedAt = now
        let startedGeneration = repoMutationGeneration[repoID] ?? 0
        let repoName = repo.displayName
        Task(priority: .utility) {
            do {
                let info = try await gitService.repoInfo()
                let isStale = startedGeneration != (repoMutationGeneration[repoID] ?? 0)
                if !isStale {
                    changeCounts[repoID] = info.changeCount
                    statusEntriesByRepo[repoID] = info.statusEntries
                    syncStateByRepo[repoID] = info.syncState
                    diffByRepo[repoID] = .empty
                }

                let elapsed = Date().timeIntervalSince(startedAt)
                if elapsed > 2 {
                    let staleSuffix = isStale ? ", discarded stale result" : ""
                    DebugLogger.shared.info(
                        "status",
                        "Status refresh was slow",
                        detail: "\(repoName): \(String(format: "%.1f", elapsed))s, \(info.statusEntries.count) entries\(staleSuffix)"
                    )
                }
            } catch {
                let isStale = startedGeneration != (repoMutationGeneration[repoID] ?? 0)
                if !isStale {
                    DebugLogger.shared.error("status", "Status refresh failed", detail: error.localizedDescription)
                }
            }

            let shouldRunAgain = pendingChangeDetection.remove(repoID) != nil
            changeDetectionInFlight.remove(repoID)
            if shouldRunAgain {
                detectChanges(repoID: repoID)
            }
        }
    }

    func fetchRemote(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)
        guard gitService.hasGitDirectory else { return }
        do {
            try await gitService.fetchRemote(pat: try await authPayload(for: repo))
            detectChanges(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func loadUnifiedDiff(repoID: UUID, path: String? = nil) async {
        guard let repo = repo(id: repoID), repo.isCloned else {
            diffByRepo[repoID] = .empty
            return
        }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            diffByRepo[repoID] = .empty
            return
        }

        do {
            diffByRepo[repoID] = try await gitService.unifiedDiff(path: path)
        } catch {
            diffByRepo[repoID] = .empty
            showError(message: error.localizedDescription)
        }
    }

    func loadBranches(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else {
            branchesByRepo[repoID] = .empty
            return
        }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            branchesByRepo[repoID] = .empty
            return
        }

        do {
            branchesByRepo[repoID] = try await gitService.listBranches()
        } catch {
            branchesByRepo[repoID] = .empty
            showError(message: error.localizedDescription)
        }
    }

    func loadConflictSession(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else {
            conflictSessionByRepo[repoID] = .none
            return
        }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            conflictSessionByRepo[repoID] = .none
            return
        }

        do {
            conflictSessionByRepo[repoID] = try await gitService.conflictSession()
        } catch {
            conflictSessionByRepo[repoID] = .none
            showError(message: error.localizedDescription)
        }
    }

    func resolveConflictFile(repoID: UUID, path: String, strategy: ConflictResolutionStrategy) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.resolveConflict(path: path, strategy: strategy)
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }
    }

    func loadConflictDetail(repoID: UUID, path: String) async -> ConflictFileDetail? {
        guard let repo = repo(id: repoID), repo.isCloned else { return nil }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else { return nil }

        do {
            return try await gitService.conflictDetail(path: path)
        } catch {
            showError(message: error.localizedDescription)
            return nil
        }
    }

    func resolveConflictWithContent(
        repoID: UUID,
        path: String,
        content: Data,
        additionalPathsToRemove: [String] = []
    ) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.resolveConflictWithContent(
                path: path,
                content: content,
                additionalPathsToRemove: additionalPathsToRemove
            )
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }
    }

    /// Auto-commit local edits, then attempt a merge with the remote-tracking
    /// branch. This is the unblock path from the "Local edits detected" banner:
    /// the user can't pull because there are uncommitted changes, and we'd
    /// rather create a real commit + merge (so any conflicts surface in the
    /// conflict editor) than block them with no in-app way forward.
    func commitLocalAndAttemptMerge(repoID: UUID, message: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        let currentBranch = repo.gitState.branch.isEmpty ? "main" : repo.gitState.branch
        let upstreamName = "origin/\(currentBranch)"
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitMessage = trimmed.isEmpty
            ? String(localized: "Local changes from HugoInk")
            : trimmed

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Committing local changes...")
        pullOutcomeByRepo.removeValue(forKey: repoID)

        do {
            try await gitService.stageAll()
        } catch {
            isSyncing = false
            syncingRepoID = nil
            showError(message: error.localizedDescription)
            return
        }

        var didCommit = false
        do {
            let newSHA = try await gitService.commitLocal(
                message: commitMessage,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail
            )
            if mutateRepoIfPresent(id: repoID, mutate: { currentRepo in
                currentRepo.gitState.commitSHA = newSHA
                currentRepo.gitState.lastSyncDate = Date()
            }) {
                saveRepos()
            }
            clearCommitHistoryCache(for: repoID)
            didCommit = true
            DebugLogger.shared.info("merge", "Auto-committed local changes", detail: "SHA: \(newSHA)")
        } catch LocalGitError.noChanges {
            // Nothing to commit — proceed straight to the merge.
        } catch {
            isSyncing = false
            syncingRepoID = nil
            showError(message: error.localizedDescription)
            return
        }

        syncProgress = String(localized: "Merging with remote...")
        do {
            let result = try await gitService.mergeBranch(
                name: upstreamName,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail
            )

            switch result.kind {
            case .upToDate:
                detectChanges(repoID: repoID)
                if didCommit {
                    syncProgress = String(localized: "Pushing local commit...")
                    do {
                        try await gitService.pushCurrentBranch(pat: try await authPayload(for: repo))
                        setPullOutcome(
                            repoID: repoID,
                            kind: .fastForwarded,
                            message: String(localized: "Committed and pushed successfully")
                        )
                    } catch {
                        showError(message: error.localizedDescription)
                    }
                } else {
                    setPullOutcome(
                        repoID: repoID,
                        kind: .upToDate,
                        message: String(localized: "Already up to date")
                    )
                }

            case .fastForwarded, .mergeCommitted:
                if mutateRepoIfPresent(id: repoID, mutate: { currentRepo in
                    currentRepo.gitState.commitSHA = result.newCommitSHA
                    currentRepo.gitState.lastSyncDate = Date()
                }) {
                    saveRepos()
                }
                clearCommitHistoryCache(for: repoID)
                detectChanges(repoID: repoID)
                await loadBranches(repoID: repoID)

                syncProgress = String(localized: "Pushing merged changes...")
                do {
                    try await gitService.pushCurrentBranch(pat: try await authPayload(for: repo))
                    setPullOutcome(
                        repoID: repoID,
                        kind: .fastForwarded,
                        message: String(localized: "Merged and pushed successfully")
                    )
                } catch {
                    showError(message: error.localizedDescription)
                }
            }
        } catch LocalGitError.mergeConflictsDetected {
            await loadConflictSession(repoID: repoID)
            detectChanges(repoID: repoID)
            setPullOutcome(
                repoID: repoID,
                kind: .diverged,
                message: String(localized: "Merge has conflicts — tap a conflicted file to resolve")
            )
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }

        isSyncing = false
        syncingRepoID = nil
    }

    func loadStashes(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else {
            stashesByRepo[repoID] = []
            return
        }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            stashesByRepo[repoID] = []
            return
        }

        do {
            stashesByRepo[repoID] = try await gitService.listStashes()
        } catch {
            stashesByRepo[repoID] = []
            showError(message: error.localizedDescription)
        }
    }

    func saveStash(repoID: UUID, message: String = "", includeUntracked: Bool = true) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            _ = try await gitService.saveStash(
                message: message,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail,
                includeUntracked: includeUntracked
            )
            detectChanges(repoID: repoID)
            await loadStashes(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func applyStash(repoID: UUID, index: Int, reinstateIndex: Bool = false) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            _ = try await gitService.applyStash(index: index, reinstateIndex: reinstateIndex)
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
            await loadStashes(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }
    }

    func popStash(repoID: UUID, index: Int, reinstateIndex: Bool = false) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            _ = try await gitService.popStash(index: index, reinstateIndex: reinstateIndex)
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
            await loadStashes(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }
    }

    func dropStash(repoID: UUID, index: Int) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.dropStash(index: index)
            await loadStashes(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func loadTags(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else {
            tagsByRepo[repoID] = []
            return
        }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            tagsByRepo[repoID] = []
            return
        }

        do {
            tagsByRepo[repoID] = try await gitService.listTags()
        } catch {
            tagsByRepo[repoID] = []
            showError(message: error.localizedDescription)
        }
    }

    func createTag(repoID: UUID, name: String, targetOID: String? = nil, message: String? = nil) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            _ = try await gitService.createTag(
                name: name,
                targetOID: targetOID,
                message: message,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail
            )
            await loadTags(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func deleteTag(repoID: UUID, name: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.deleteTag(name: name)
            await loadTags(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func pushTag(repoID: UUID, name: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.pushTag(name: name, pat: try await authPayload(for: repo))
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func loadCommitHistory(repoID: UUID, pageSize: Int = 30, reset: Bool = false) async {
        guard let repo = repo(id: repoID), repo.isCloned else {
            commitHistoryByRepo[repoID] = []
            commitHistoryHasMoreByRepo[repoID] = false
            return
        }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            commitHistoryByRepo[repoID] = []
            commitHistoryHasMoreByRepo[repoID] = false
            return
        }

        let existing = reset ? [] : (commitHistoryByRepo[repoID] ?? [])
        let skip = existing.count

        do {
            let page = try await gitService.commitHistory(limit: pageSize, skip: skip)
            let merged = reset ? page : (existing + page)
            commitHistoryByRepo[repoID] = merged
            commitHistoryHasMoreByRepo[repoID] = page.count == pageSize
            if reset {
                commitDetailByRepo[repoID] = [:]
            }
        } catch {
            if reset {
                commitHistoryByRepo[repoID] = []
                commitHistoryHasMoreByRepo[repoID] = false
                commitDetailByRepo[repoID] = [:]
            }
            showError(message: error.localizedDescription)
        }
    }

    func loadCommitDetail(repoID: UUID, oid: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let trimmedOID = oid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOID.isEmpty else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else { return }

        do {
            let detail = try await gitService.commitDetail(oid: trimmedOID)
            var existing = commitDetailByRepo[repoID] ?? [:]
            existing[trimmedOID] = detail
            commitDetailByRepo[repoID] = existing
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func createBranch(repoID: UUID, name: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.createBranch(name: name)
            await loadBranches(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func switchBranch(repoID: UUID, name: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Switching branch...")

        do {
            try await gitService.switchBranch(name: name)
            let info = try await gitService.repoInfo()

            if mutateRepoIfPresent(id: repoID, mutate: { currentRepo in
                currentRepo.gitState.branch = info.branch
                currentRepo.gitState.commitSHA = info.commitSHA
            }) {
                saveRepos()
            }
            clearCommitHistoryCache(for: repoID)

            detectChanges(repoID: repoID)
            await loadBranches(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }

        isSyncing = false
        syncingRepoID = nil
    }

    func deleteBranch(repoID: UUID, name: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.deleteBranch(name: name)
            await loadBranches(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func mergeBranch(repoID: UUID, from branchName: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Merging branch...")

        do {
            let result = try await gitService.mergeBranch(
                name: branchName,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail
            )
            if mutateRepoIfPresent(id: repoID, mutate: { currentRepo in
                currentRepo.gitState.commitSHA = result.newCommitSHA
                currentRepo.gitState.lastSyncDate = Date()
            }) {
                saveRepos()
            }
            clearCommitHistoryCache(for: repoID)

            detectChanges(repoID: repoID)
            await loadBranches(repoID: repoID)
            await loadConflictSession(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }

        isSyncing = false
        syncingRepoID = nil
    }

    func mergeWithRemote(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        let currentBranch = repo.gitState.branch.isEmpty ? "main" : repo.gitState.branch
        let upstreamName = "origin/\(currentBranch)"

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Merging with remote...")

        do {
            let result = try await gitService.mergeBranch(
                name: upstreamName,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail
            )

            switch result.kind {
            case .upToDate:
                setPullOutcome(
                    repoID: repoID,
                    kind: .upToDate,
                    message: String(localized: "Already up to date")
                )

            case .fastForwarded, .mergeCommitted:
                if mutateRepoIfPresent(id: repoID, mutate: { currentRepo in
                    currentRepo.gitState.commitSHA = result.newCommitSHA
                    currentRepo.gitState.lastSyncDate = Date()
                }) {
                    saveRepos()
                }
                clearCommitHistoryCache(for: repoID)
                detectChanges(repoID: repoID)
                await loadBranches(repoID: repoID)

                syncProgress = String(localized: "Pushing merged changes...")
                do {
                    try await gitService.pushCurrentBranch(pat: try await authPayload(for: repo))
                    setPullOutcome(
                        repoID: repoID,
                        kind: .fastForwarded,
                        message: String(localized: "Merged and pushed successfully")
                    )
                } catch {
                    showError(message: error.localizedDescription)
                }
            }

        } catch LocalGitError.mergeConflictsDetected {
            await loadConflictSession(repoID: repoID)
            detectChanges(repoID: repoID)
            setPullOutcome(
                repoID: repoID,
                kind: .diverged,
                message: String(localized: "Merge has conflicts — tap a conflicted file to resolve")
            )
        } catch {
            showError(message: error.localizedDescription)
        }

        isSyncing = false
        syncingRepoID = nil
    }

    func revertCommit(repoID: UUID, oid: String, message: String = "") async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Reverting commit...")

        do {
            DebugLogger.shared.info("revert", "Reverting commit", detail: "OID: \(oid)")
            let result = try await gitService.revertCommit(
                oid: oid,
                message: message,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail
            )

            switch result.kind {
            case .reverted:
                if let newCommitSHA = result.newCommitSHA {
                    if mutateRepoIfPresent(id: repoID, mutate: { currentRepo in
                        currentRepo.gitState.commitSHA = newCommitSHA
                        currentRepo.gitState.lastSyncDate = Date()
                    }) {
                        saveRepos()
                    }
                    clearCommitHistoryCache(for: repoID)
                }
                syncProgress = String(localized: "Revert complete")
                DebugLogger.shared.info("revert", "Commit revert complete", detail: "new SHA: \(result.newCommitSHA ?? "nil")")
            case .conflicts:
                syncProgress = String(localized: "Revert has conflicts")
                DebugLogger.shared.warning("revert", "Commit revert produced conflicts", detail: "OID: \(oid)")
            }

            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription, category: "revert")
        }

        isSyncing = false
        syncingRepoID = nil
    }

    func completeMerge(repoID: UUID, message: String = "") async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Finalizing merge...")

        do {
            let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "Merge branch")
                : message

            let result = try await gitService.completeMerge(
                message: commitMessage,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail
            )

            if mutateRepoIfPresent(id: repoID, mutate: { currentRepo in
                currentRepo.gitState.commitSHA = result.newCommitSHA
                currentRepo.gitState.lastSyncDate = Date()
            }) {
                saveRepos()
            }
            clearCommitHistoryCache(for: repoID)

            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)

            syncProgress = String(localized: "Pushing merged changes...")
            do {
                try await gitService.pushCurrentBranch(pat: try await authPayload(for: repo))
                setPullOutcome(
                    repoID: repoID,
                    kind: .fastForwarded,
                    message: String(localized: "Merge resolved and pushed successfully")
                )
            } catch {
                showError(message: error.localizedDescription)
            }
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }

        isSyncing = false
        syncingRepoID = nil
    }

    func abortMerge(repoID: UUID) async {
        guard let _ = repoIndex(id: repoID), repo(id: repoID)?.isCloned == true else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Aborting merge...")

        do {
            try await gitService.abortMerge()
            clearCommitHistoryCache(for: repoID)
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }

        isSyncing = false
        syncingRepoID = nil
    }

    private func markRepositoryMutated(repoID: UUID) {
        repoMutationGeneration[repoID, default: 0] += 1
    }

    private func stagedStatusKind(from workTreeStatus: GitFileStatusKind) -> GitFileStatusKind {
        workTreeStatus == .untracked ? .added : workTreeStatus
    }

    private func unstagedStatusKind(from indexStatus: GitFileStatusKind) -> GitFileStatusKind {
        indexStatus == .added ? .untracked : indexStatus
    }

    private func optimisticallyStageStatusEntry(repoID: UUID, path: String) {
        guard var entries = statusEntriesByRepo[repoID],
              let entryIndex = entries.firstIndex(where: { $0.path == path }) else { return }

        let entry = entries[entryIndex]
        let indexStatus = entry.workTreeStatus.map(stagedStatusKind(from:)) ?? entry.indexStatus
        entries[entryIndex] = GitStatusEntry(
            path: entry.path,
            indexStatus: indexStatus,
            workTreeStatus: nil,
            oldPath: entry.oldPath
        )
        statusEntriesByRepo[repoID] = entries
        changeCounts[repoID] = entries.count
        diffByRepo[repoID] = .empty
    }

    private func optimisticallyStageAllStatusEntries(repoID: UUID) {
        guard let currentEntries = statusEntriesByRepo[repoID] else { return }
        let entries = currentEntries.map { entry in
            GitStatusEntry(
                path: entry.path,
                indexStatus: entry.workTreeStatus.map(stagedStatusKind(from:)) ?? entry.indexStatus,
                workTreeStatus: nil,
                oldPath: entry.oldPath
            )
        }
        statusEntriesByRepo[repoID] = entries
        changeCounts[repoID] = entries.count
        diffByRepo[repoID] = .empty
    }

    private func optimisticallyUnstageStatusEntry(repoID: UUID, path: String) {
        guard var entries = statusEntriesByRepo[repoID],
              let entryIndex = entries.firstIndex(where: { $0.path == path }) else { return }

        let entry = entries[entryIndex]
        let workTreeStatus: GitFileStatusKind?
        if entry.indexStatus == .added {
            workTreeStatus = .untracked
        } else {
            workTreeStatus = entry.workTreeStatus ?? entry.indexStatus.map(unstagedStatusKind(from:))
        }
        if let workTreeStatus {
            entries[entryIndex] = GitStatusEntry(
                path: entry.path,
                indexStatus: nil,
                workTreeStatus: workTreeStatus,
                oldPath: entry.oldPath
            )
        } else {
            entries.remove(at: entryIndex)
        }
        statusEntriesByRepo[repoID] = entries
        changeCounts[repoID] = entries.count
        diffByRepo[repoID] = .empty
    }

    func stageFile(repoID: UUID, path: String, oldPath: String? = nil) async {
        _ = await stageFile(repoID: repoID, path: path, oldPath: oldPath, lfsAutoTrack: false, promptForLFS: true)
    }

    func stageFileForAutomation(repoID: UUID, path: String, oldPath: String? = nil) async -> Bool {
        await gitOperationCoordinator.withOperation(repoID: repoID) { [self] in
            await stageFile(repoID: repoID, path: path, oldPath: oldPath, lfsAutoTrack: false, promptForLFS: false)
        }
    }

    private func stageFile(
        repoID: UUID,
        path: String,
        oldPath: String?,
        lfsAutoTrack: Bool,
        promptForLFS: Bool
    ) async -> Bool {
        guard let repo = repo(id: repoID), repo.isCloned else { return false }
        guard indexMutationRepoIDs.insert(repoID).inserted else { return false }
        defer { indexMutationRepoIDs.remove(repoID) }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return false
        }

        do {
            if promptForLFS {
                let candidates = try await gitService.lfsAutoTrackingCandidates(paths: [path])
                if !candidates.isEmpty {
                    pendingLFSAutoTrackingConfirmation = LFSAutoTrackingConfirmationRequest(
                        repoID: repoID,
                        action: .stageFile(path: path, oldPath: oldPath),
                        candidates: candidates
                    )
                    return false
                }
            }

            let startedAt = Date()
            try await gitService.stage(path: path, oldPath: oldPath, lfsAutoTrack: lfsAutoTrack)
            markRepositoryMutated(repoID: repoID)
            optimisticallyStageStatusEntry(repoID: repoID, path: path)
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 2 {
                DebugLogger.shared.info(
                    "stage",
                    "Stage file was slow",
                    detail: "\(path): \(String(format: "%.1f", elapsed))s"
                )
            }
            detectChanges(repoID: repoID)
            return true
        } catch {
            showError(message: error.localizedDescription)
            return false
        }
    }

    /// Selects changes inside the current Hugo leaf bundle (`index.md` and its
    /// sibling `images/` directory). Existing staged changes elsewhere are preserved.
    static func articleBundleEntries(
        in entries: [GitStatusEntry],
        bundlePath: String
    ) -> [GitStatusEntry] {
        let prefix = bundlePath.isEmpty ? "" : bundlePath + "/"
        return entries.filter {
            $0.path == bundlePath || $0.path.hasPrefix(prefix)
                || ($0.oldPath?.hasPrefix(prefix) == true)
        }
    }

    func hasArticleBundleChanges(repoID: UUID, fileURL: URL) -> Bool {
        guard let repo = repo(id: repoID), repo.isCloned,
              let entries = statusEntriesByRepo[repoID]
        else { return false }

        let vaultDir = vaultURL(for: repoID).standardizedFileURL
        let articleDir = fileURL.deletingLastPathComponent().standardizedFileURL
        let vaultPath = vaultDir.path.hasSuffix("/") ? vaultDir.path : vaultDir.path + "/"
        guard articleDir.path.hasPrefix(vaultPath) else { return false }

        let bundlePath = String(articleDir.path.dropFirst(vaultPath.count))
        return !Self.articleBundleEntries(in: entries, bundlePath: bundlePath).isEmpty
    }

    @discardableResult
    func stageArticleBundle(repoID: UUID, fileURL: URL, operationID: String? = nil) async -> Bool {
        guard let repo = repo(id: repoID), repo.isCloned else { return false }
        guard indexMutationRepoIDs.insert(repoID).inserted else { return false }
        defer { indexMutationRepoIDs.remove(repoID) }

        let vaultDir = vaultURL(for: repoID).standardizedFileURL
        let articleDir = fileURL.deletingLastPathComponent().standardizedFileURL
        let vaultPath = vaultDir.path.hasSuffix("/") ? vaultDir.path : vaultDir.path + "/"
        guard articleDir.path.hasPrefix(vaultPath) else { return false }

        let bundlePath = String(articleDir.path.dropFirst(vaultPath.count))
        let gitService = gitRepositoryFactory(vaultDir)
        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return false
        }

        do {
            let info = try await gitService.repoInfo()
            let bundleEntries = Self.articleBundleEntries(in: info.statusEntries, bundlePath: bundlePath)
            guard !bundleEntries.isEmpty else { return false }
            let repositoryConfigurationEntries = info.statusEntries.filter {
                $0.path == HugoContentService.configurationFile && $0.workTreeStatus != nil
            }
            let unstagedEntries = (bundleEntries + repositoryConfigurationEntries).filter {
                $0.workTreeStatus != nil
            }
            DebugLogger.shared.info(
                "publish",
                "Staging article bundle",
                detail: "\(bundlePath): \(unstagedEntries.count) unstaged, \(bundleEntries.count) article changes",
                repoID: repoID,
                repoName: repo.displayName,
                operationID: operationID
            )
            for entry in unstagedEntries {
                try await gitService.stage(path: entry.path, oldPath: entry.oldPath, lfsAutoTrack: false)
            }

            markRepositoryMutated(repoID: repoID)
            for entry in unstagedEntries {
                optimisticallyStageStatusEntry(repoID: repoID, path: entry.path)
            }
            detectChanges(repoID: repoID)
            DebugLogger.shared.info(
                "publish",
                "Article bundle staged",
                detail: bundlePath,
                repoID: repoID,
                repoName: repo.displayName,
                operationID: operationID
            )
            return true
        } catch {
            showError(message: error.localizedDescription, category: "publish", repoID: repoID, operationID: operationID)
            return false
        }
    }

    func stageAllChanges(repoID: UUID) async {
        _ = await stageAllChanges(repoID: repoID, lfsAutoTrack: false, promptForLFS: true)
    }

    /// Stages without presenting UI so App Intents and x-callback requests can
    /// use the same injected repository and per-repository operation queue.
    func stageAllChangesForAutomation(repoID: UUID) async -> Bool {
        await gitOperationCoordinator.withOperation(repoID: repoID) { [self] in
            await stageAllChanges(repoID: repoID, lfsAutoTrack: false, promptForLFS: false)
        }
    }

    private func stageAllChanges(repoID: UUID, lfsAutoTrack: Bool, promptForLFS: Bool) async -> Bool {
        guard let repo = repo(id: repoID), repo.isCloned else { return false }
        guard indexMutationRepoIDs.insert(repoID).inserted else { return false }
        defer { indexMutationRepoIDs.remove(repoID) }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return false
        }

        do {
            if promptForLFS {
                // Only inspect currently changed files. Scanning the whole vault here
                // is expensive for media-heavy Obsidian repos and can make Stage All
                // feel frozen even when most large assets are clean.
                let candidatePaths = statusEntriesByRepo[repoID]?.map(\.path) ?? []
                let candidates = try await gitService.lfsAutoTrackingCandidates(paths: candidatePaths)
                if !candidates.isEmpty {
                    pendingLFSAutoTrackingConfirmation = LFSAutoTrackingConfirmationRequest(
                        repoID: repoID,
                        action: .stageAll,
                        candidates: candidates
                    )
                    return false
                }
            }

            let startedAt = Date()
            try await gitService.stageAll(lfsAutoTrack: lfsAutoTrack)
            markRepositoryMutated(repoID: repoID)
            optimisticallyStageAllStatusEntries(repoID: repoID)
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 2 {
                DebugLogger.shared.info(
                    "stage",
                    "Stage all was slow",
                    detail: "\(String(format: "%.1f", elapsed))s"
                )
            }
            detectChanges(repoID: repoID)
            return true
        } catch {
            showError(message: error.localizedDescription)
            return false
        }
    }

    func confirmPendingLFSAutoTracking(useLFS: Bool) async {
        guard let request = pendingLFSAutoTrackingConfirmation else { return }
        pendingLFSAutoTrackingConfirmation = nil
        guard useLFS else { return }

        switch request.action {
        case .stageFile(let path, let oldPath):
            _ = await stageFile(repoID: request.repoID, path: path, oldPath: oldPath, lfsAutoTrack: true, promptForLFS: false)
        case .stageAll:
            _ = await stageAllChanges(repoID: request.repoID, lfsAutoTrack: true, promptForLFS: false)
        }
    }

    func repositoryInfoForAutomation(repoID: UUID) async throws -> LocalRepoInfo {
        try await gitOperationCoordinator.withThrowingOperation(repoID: repoID) { [self] in
            guard let repo = repo(id: repoID), repo.isCloned else {
                throw LocalGitError.notCloned
            }
            let gitService = gitRepositoryFactory(vaultURL(for: repoID))
            guard gitService.hasGitDirectory else {
                throw LocalGitError.notCloned
            }
            return try await gitService.repoInfo()
        }
    }

    func cancelPendingLFSAutoTracking() {
        pendingLFSAutoTrackingConfirmation = nil
    }

    @discardableResult
    private func handleSSHHostKeyTrustIfNeeded(
        _ error: Error,
        repoID: UUID,
        operation: SSHHostKeyTrustRequest.Operation
    ) -> Bool {
        guard case LocalGitError.sshHostKeyTrustRequired(let trustError) = error else {
            return false
        }
        pendingSSHHostKeyTrustRequest = SSHHostKeyTrustRequest(
            repoID: repoID,
            operation: operation,
            trustError: trustError
        )
        syncProgress = String(localized: "SSH host key needs trust")
        return true
    }

    func trustPendingSSHHostKeyAndRetry() async {
        guard let request = pendingSSHHostKeyTrustRequest else { return }
        do {
            try sshHostKeyTrustStore.trust(
                fingerprint: request.fingerprintToTrust,
                host: request.host,
                port: request.port
            )
            DebugLogger.shared.info(
                "security",
                "Trusted SSH host key",
                detail: "\(request.host):\(request.port) \(request.fingerprintToTrust)"
            )
        } catch {
            pendingSSHHostKeyTrustRequest = nil
            showError(message: error.localizedDescription, category: "security")
            return
        }

        let operation = request.operation
        let repoID = request.repoID
        pendingSSHHostKeyTrustRequest = nil

        switch operation {
        case .clone:
            await clone(repoID: repoID)
        case .pull:
            _ = await pull(repoID: repoID)
        case .pushCurrentBranch:
            _ = await pushCurrentBranch(repoID: repoID)
        case .pushCommit(let message):
            _ = await retryPush(repoID: repoID, message: message)
        }
    }

    func cancelPendingSSHHostKeyTrust() {
        pendingSSHHostKeyTrustRequest = nil
    }

    func unstageFile(repoID: UUID, path: String, oldPath: String? = nil) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        guard indexMutationRepoIDs.insert(repoID).inserted else { return }
        defer { indexMutationRepoIDs.remove(repoID) }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            let startedAt = Date()
            try await gitService.unstage(path: path, oldPath: oldPath)
            markRepositoryMutated(repoID: repoID)
            optimisticallyUnstageStatusEntry(repoID: repoID, path: path)
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 2 {
                DebugLogger.shared.info(
                    "stage",
                    "Unstage file was slow",
                    detail: "\(path): \(String(format: "%.1f", elapsed))s"
                )
            }
            detectChanges(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func discardAllFileChanges(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription, category: "revert")
            return
        }

        do {
            DebugLogger.shared.info("revert", "Reverting all file changes")
            try await gitService.discardAllChanges()
            detectChanges(repoID: repoID)
            DebugLogger.shared.info("revert", "Revert all complete")
        } catch {
            showError(message: error.localizedDescription, category: "revert")
        }
    }

    func discardFileChanges(repoID: UUID, path: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription, category: "revert")
            return
        }

        do {
            DebugLogger.shared.info("revert", "Reverting file changes", detail: path)
            try await gitService.discardChanges(path: path)
            detectChanges(repoID: repoID)
            DebugLogger.shared.info("revert", "File revert complete", detail: path)
        } catch {
            showError(message: error.localizedDescription, category: "revert")
        }
    }

    // MARK: - Git Operations (libgit2)

    private func beginLongGitOperation(_ kind: GitLongOperationKind, repoID: UUID) {
        isSyncing = true
        syncingRepoID = repoID
        gitLongOperationProgress = GitLongOperationProgress(kind: kind, stage: .preparing)
        syncProgress = gitLongOperationProgress?.message ?? ""
        syncProgressFraction = gitLongOperationProgress?.fraction
    }

    private func updateLongGitOperation(_ stage: GitLongOperationStage) {
        guard var progress = gitLongOperationProgress else { return }
        progress.stage = stage
        gitLongOperationProgress = progress
        syncProgress = progress.message
        syncProgressFraction = progress.fraction
    }

    func requestSyncCancellation() {
        guard var progress = gitLongOperationProgress else { return }
        guard progress.requestCancellationIfSafe() else { return }
        gitLongOperationProgress = progress
        syncProgress = progress.message
        DebugLogger.shared.info("git", "Cancellation requested", detail: progress.kind.rawValue)
    }

    private func checkLongGitOperationCancellation() throws {
        if gitLongOperationProgress?.cancellationRequested == true {
            throw GitOperationCancelled()
        }
    }

    private func finishLongGitOperation() {
        isSyncing = false
        syncingRepoID = nil
        syncProgressFraction = nil
        gitLongOperationProgress = nil
    }

    func clone(repoID: UUID) async {
        await gitOperationCoordinator.withOperation(repoID: repoID) { [self] in
            await performClone(repoID: repoID)
        }
    }

    private func performClone(repoID: UUID) async {
        guard let startingRepo = repo(id: repoID) else {
            showError(message: String(localized: "Repository not found"))
            return
        }

        let operationID = String(UUID().uuidString.prefix(8)).lowercased()
        beginLongGitOperation(.clone, repoID: repoID)
        defer { finishLongGitOperation() }

        do {
            let fm = FileManager.default

            // If the user configured a default save location after this repo
            // was first added, adopt it now so the (re-)clone lands in the
            // chosen folder instead of the in-app Documents directory.
            if startingRepo.customVaultBookmarkData == nil,
               let defaultBookmark = defaultSaveLocationBookmarkData {
                let staleVaultDir = startingRepo.defaultVaultURL
                _ = mutateRepoIfPresent(id: repoID) { currentRepo in
                    currentRepo.customVaultBookmarkData = defaultBookmark
                    currentRepo.customLocationIsParent = true
                }
                saveRepos()
                resolveVaultBookmark(for: repoID)
                if fm.fileExists(atPath: staleVaultDir.path),
                   ((try? fm.contentsOfDirectory(atPath: staleVaultDir.path)) ?? []).isEmpty {
                    try? fm.removeItem(at: staleVaultDir)
                }
            }

            guard let repo = repo(id: repoID) else {
                throw LocalGitError.notCloned
            }
            let vaultDir = vaultURL(for: repoID)

            // Never delete an existing non-empty destination. It may contain
            // uncommitted work even when persisted clone state is stale.
            if fm.fileExists(atPath: vaultDir.path) {
                let existing = try fm.contentsOfDirectory(atPath: vaultDir.path)
                guard existing.isEmpty else {
                    throw LocalGitError.cloneDestinationNotEmpty(vaultDir.path)
                }
                try fm.removeItem(at: vaultDir)
            }

            // Clone into a unique sibling and only publish it after success.
            let parentDir = vaultDir.deletingLastPathComponent()
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            let cloneWorkingDir = parentDir.appendingPathComponent(".gitsync-clone-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: cloneWorkingDir) }

            // Build a clone-friendly URL. Preserve custom remotes exactly;
            // only expand the historical GitHub owner/repo shorthand.
            let cloneURL = GitRemoteURL.cloneURLString(from: repo.repoURL) ?? repo.repoURL

            let gitService = gitRepositoryFactory(cloneWorkingDir)

            try checkLongGitOperationCancellation()
            updateLongGitOperation(.connecting)
            DebugLogger.shared.info(
                "clone", "Starting clone", detail: cloneURL,
                repoID: repoID, repoName: repo.displayName, operationID: operationID
            )
            updateLongGitOperation(.transferring)
            let result = try await gitService.clone(remoteURL: cloneURL, pat: try await authPayload(for: repo))
            try checkLongGitOperationCancellation()
            updateLongGitOperation(.checkingRepository)
            if fm.fileExists(atPath: cloneWorkingDir.path) {
                try fm.moveItem(at: cloneWorkingDir, to: vaultDir)
            } else if gitService is LocalGitService {
                throw LocalGitError.cloneFailed(String(localized: "Clone completed without creating its destination directory."))
            }
            updateLongGitOperation(.finalizing)

            guard mutateRepoIfPresent(id: repoID, mutate: { currentRepo in
                if currentRepo.branch.isEmpty {
                    currentRepo.branch = result.branch
                }
                currentRepo.gitState = GitState(
                    commitSHA: result.commitSHA,
                    treeSHA: "",
                    branch: result.branch,
                    blobSHAs: [:],
                    lastSyncDate: Date()
                )
            }) else {
                throw LocalGitError.notCloned
            }
            saveRepos()
            clearCommitHistoryCache(for: repoID)
            detectChanges(repoID: repoID)
            updateLongGitOperation(.completed)
            syncProgress = String(localized: "Clone complete! (\(result.fileCount) files)")
            DebugLogger.shared.info(
                "clone", "Clone complete", detail: "\(result.fileCount) files, branch: \(result.branch)",
                repoID: repoID, repoName: repo.displayName, operationID: operationID
            )
            if let lfsWarning = result.lfsWarning {
                showError(message: lfsWarning, category: "lfs")
            }


        } catch is GitOperationCancelled {
            syncProgress = String(localized: "Clone cancelled safely")
            DebugLogger.shared.info(
                "clone", "Clone cancelled at safe boundary",
                repoID: repoID, operationID: operationID
            )
        } catch {
            if !handleSSHHostKeyTrustIfNeeded(error, repoID: repoID, operation: .clone) {
                showError(message: error.localizedDescription, category: "clone", repoID: repoID, operationID: operationID)
            }
        }

        try? await Task.sleep(for: .seconds(1))
    }

    @discardableResult
    func pull(repoID: UUID, showsProgressDelay: Bool = true) async -> Bool {
        await gitOperationCoordinator.withOperation(repoID: repoID) { [self] in
            await performPull(repoID: repoID, showsProgressDelay: showsProgressDelay)
        }
    }

    private func performPull(repoID: UUID, showsProgressDelay: Bool) async -> Bool {
        guard let repo = repo(id: repoID) else {
            showError(message: String(localized: "Repository not found"))
            return false
        }

        beginLongGitOperation(.pull, repoID: repoID)
        defer { finishLongGitOperation() }

        pullOutcomeByRepo.removeValue(forKey: repoID)

        do {
            let vaultDir = vaultURL(for: repoID)
            let gitService = gitRepositoryFactory(vaultDir)

            guard gitService.hasGitDirectory else {
                throw LocalGitError.notCloned
            }

            try checkLongGitOperationCancellation()
            updateLongGitOperation(.connecting)
            DebugLogger.shared.info("pull", "Starting pull", detail: "branch: \(repo.branch)")
            updateLongGitOperation(.transferring)
            let plan = try await gitService.pullPlan(pat: try await authPayload(for: repo))
            try checkLongGitOperationCancellation()
            updateLongGitOperation(.checkingRepository)

            switch plan.action {
            case .upToDate:
                syncProgress = String(localized: "Already up to date!")
                DebugLogger.shared.info("pull", "Already up to date")
                setPullOutcome(
                    repoID: repoID,
                    kind: .upToDate,
                    message: String(localized: "Already up to date")
                )

            case .blockedByLocalChanges:
                syncProgress = String(localized: "Pull blocked by local changes")
                DebugLogger.shared.warning("pull", "Blocked by local changes")
                setPullOutcome(
                    repoID: repoID,
                    kind: .blockedByLocalChanges,
                    message: String(localized: "Local edits detected. Commit, stash, or discard changes before pulling.")
                )

            case .diverged:
                syncProgress = String(localized: "Pull requires merge")
                setPullOutcome(
                    repoID: repoID,
                    kind: .diverged,
                    message: String(localized: "Local and remote have diverged. Merge support is required to continue.")
                )

            case .remoteBranchMissing:
                syncProgress = String(localized: "Remote branch missing")
                setPullOutcome(
                    repoID: repoID,
                    kind: .remoteBranchMissing,
                    message: String(localized: "Remote branch '\(plan.branch)' was not found.")
                )

            case .fastForward:
                updateLongGitOperation(.applyingChanges)
                let result = try await gitService.pullFastForward(branch: plan.branch, pat: try await authPayload(for: repo))

                if !result.updated {
                    syncProgress = String(localized: "Already up to date!")
                    setPullOutcome(
                        repoID: repoID,
                        kind: .upToDate,
                        message: String(localized: "Already up to date")
                    )
                } else {
                    guard mutateRepoIfPresent(id: repoID, mutate: { currentRepo in
                        currentRepo.gitState.commitSHA = result.newCommitSHA
                        currentRepo.gitState.lastSyncDate = Date()
                    }) else {
                        throw LocalGitError.notCloned
                    }
                    saveRepos()
                    clearCommitHistoryCache(for: repoID)
                    detectChanges(repoID: repoID)
                    syncProgress = String(localized: "Pull complete!")
                    DebugLogger.shared.info("pull", "Pull complete (fast-forward)", detail: "new SHA: \(result.newCommitSHA)")
                    setPullOutcome(
                        repoID: repoID,
                        kind: .fastForwarded,
                        message: String(localized: "Pulled latest changes (fast-forward)")
                    )
                }
            }

            let pullCompletionMessage = syncProgress
            updateLongGitOperation(.completed)
            syncProgress = pullCompletionMessage

            if showsProgressDelay {
                try? await Task.sleep(for: .seconds(1))
            }
            isSyncing = false
            syncingRepoID = nil
            return true

        } catch is GitOperationCancelled {
            syncProgress = String(localized: "Pull cancelled safely")
            setPullOutcome(
                repoID: repoID,
                kind: .failed,
                message: String(localized: "Pull cancelled before applying remote changes.")
            )
            DebugLogger.shared.info("pull", "Pull cancelled at safe boundary", repoID: repoID)
        } catch let error as LocalGitError {
            switch error {
            case .pullBlockedByLocalChanges:
                syncProgress = String(localized: "Pull blocked by local changes")
                DebugLogger.shared.warning("pull", "Blocked by local changes")
                setPullOutcome(
                    repoID: repoID,
                    kind: .blockedByLocalChanges,
                    message: String(localized: "Local edits detected. Commit, stash, or discard changes before pulling.")
                )
            case .pullDiverged:
                syncProgress = String(localized: "Pull requires merge")
                DebugLogger.shared.warning("pull", "Diverged — merge required")
                setPullOutcome(
                    repoID: repoID,
                    kind: .diverged,
                    message: String(localized: "Local and remote have diverged. Merge support is required to continue.")
                )
            case .pullRemoteBranchMissing(let branch):
                syncProgress = String(localized: "Remote branch missing")
                DebugLogger.shared.warning("pull", "Remote branch missing", detail: branch)
                setPullOutcome(
                    repoID: repoID,
                    kind: .remoteBranchMissing,
                    message: String(localized: "Remote branch '\(branch)' was not found.")
                )
            default:
                if handleSSHHostKeyTrustIfNeeded(error, repoID: repoID, operation: .pull) {
                    setPullOutcome(repoID: repoID, kind: .failed, message: String(localized: "SSH host key needs trust"))
                } else {
                    setPullOutcome(repoID: repoID, kind: .failed, message: error.localizedDescription)
                    showError(message: error.localizedDescription, category: "pull")
                }
            }
        } catch {
            if handleSSHHostKeyTrustIfNeeded(error, repoID: repoID, operation: .pull) {
                setPullOutcome(repoID: repoID, kind: .failed, message: String(localized: "SSH host key needs trust"))
            } else {
                setPullOutcome(repoID: repoID, kind: .failed, message: error.localizedDescription)
                showError(message: error.localizedDescription, category: "pull")
            }
        }

        if showsProgressDelay {
            try? await Task.sleep(for: .seconds(1))
        }
        isSyncing = false
        syncingRepoID = nil
        return false
    }

    @discardableResult
    func pullWithRebase(repoID: UUID, showsProgressDelay: Bool = true) async -> Bool {
        await gitOperationCoordinator.withOperation(repoID: repoID) { [self] in
            await performPullWithRebase(repoID: repoID, showsProgressDelay: showsProgressDelay)
        }
    }

    private func performPullWithRebase(repoID: UUID, showsProgressDelay: Bool) async -> Bool {
        guard let repo = repo(id: repoID) else {
            showError(message: String(localized: "Repository not found"))
            return false
        }

        beginLongGitOperation(.pull, repoID: repoID)
        defer { finishLongGitOperation() }

        pullOutcomeByRepo.removeValue(forKey: repoID)

        do {
            let vaultDir = vaultURL(for: repoID)
            let gitService = gitRepositoryFactory(vaultDir)

            guard gitService.hasGitDirectory else {
                throw LocalGitError.notCloned
            }

            try checkLongGitOperationCancellation()
            updateLongGitOperation(.connecting)
            DebugLogger.shared.info("pull", "Starting pull with rebase", detail: "branch: \(repo.branch)")
            updateLongGitOperation(.transferring)
            let plan = try await gitService.pullPlan(pat: try await authPayload(for: repo))
            try checkLongGitOperationCancellation()
            updateLongGitOperation(.checkingRepository)

            let result: LocalPullResult
            switch plan.action {
            case .upToDate:
                syncProgress = String(localized: "Already up to date!")
                setPullOutcome(
                    repoID: repoID,
                    kind: .upToDate,
                    message: String(localized: "Already up to date")
                )
                if showsProgressDelay { try? await Task.sleep(for: .seconds(1)) }
                isSyncing = false
                syncingRepoID = nil
                return true

            case .blockedByLocalChanges:
                syncProgress = String(localized: "Rebase blocked by local changes")
                setPullOutcome(
                    repoID: repoID,
                    kind: .blockedByLocalChanges,
                    message: String(localized: "Local edits detected. Commit, stash, or discard changes before rebasing.")
                )
                if showsProgressDelay { try? await Task.sleep(for: .seconds(1)) }
                isSyncing = false
                syncingRepoID = nil
                return false

            case .remoteBranchMissing:
                syncProgress = String(localized: "Remote branch missing")
                setPullOutcome(
                    repoID: repoID,
                    kind: .remoteBranchMissing,
                    message: String(localized: "Remote branch '\(plan.branch)' was not found.")
                )
                if showsProgressDelay { try? await Task.sleep(for: .seconds(1)) }
                isSyncing = false
                syncingRepoID = nil
                return false

            case .fastForward:
                updateLongGitOperation(.applyingChanges)
                result = try await gitService.pullFastForward(branch: plan.branch, pat: try await authPayload(for: repo))

            case .diverged:
                updateLongGitOperation(.applyingChanges)
                syncProgress = String(localized: "Rebasing local commits...")
                result = try await gitService.pullRebase(
                    branch: plan.branch,
                    pat: try await authPayload(for: repo),
                    authorName: repo.authorName,
                    authorEmail: repo.authorEmail
                )
            }

            if result.updated {
                guard mutateRepoIfPresent(id: repoID, mutate: { currentRepo in
                    currentRepo.gitState.commitSHA = result.newCommitSHA
                    currentRepo.gitState.lastSyncDate = Date()
                }) else {
                    throw LocalGitError.notCloned
                }
                saveRepos()
                clearCommitHistoryCache(for: repoID)
                detectChanges(repoID: repoID)
                await loadBranches(repoID: repoID)
                syncProgress = plan.action == .diverged
                    ? String(localized: "Rebase complete!")
                    : String(localized: "Pull complete!")
                setPullOutcome(
                    repoID: repoID,
                    kind: plan.action == .diverged ? .rebased : .fastForwarded,
                    message: plan.action == .diverged
                        ? String(localized: "Rebased local commits onto origin/\(plan.branch)")
                        : String(localized: "Pulled latest changes (fast-forward)")
                )
            } else {
                syncProgress = String(localized: "Already up to date!")
                setPullOutcome(repoID: repoID, kind: .upToDate, message: String(localized: "Already up to date"))
            }

            let pullCompletionMessage = syncProgress
            updateLongGitOperation(.completed)
            syncProgress = pullCompletionMessage

            if showsProgressDelay { try? await Task.sleep(for: .seconds(1)) }
            isSyncing = false
            syncingRepoID = nil
            return true
        } catch is GitOperationCancelled {
            syncProgress = String(localized: "Pull cancelled safely")
            setPullOutcome(
                repoID: repoID,
                kind: .failed,
                message: String(localized: "Pull cancelled before applying remote changes.")
            )
        } catch LocalGitError.rebaseConflictsDetected {
            await loadConflictSession(repoID: repoID)
            detectChanges(repoID: repoID)
            setPullOutcome(
                repoID: repoID,
                kind: .rebaseConflicts,
                message: String(localized: "Rebase has conflicts — resolve them, then continue rebase")
            )
        } catch let error as LocalGitError {
            setPullOutcome(repoID: repoID, kind: .failed, message: error.localizedDescription)
            showError(message: error.localizedDescription, category: "rebase")
        } catch {
            setPullOutcome(repoID: repoID, kind: .failed, message: error.localizedDescription)
            showError(message: error.localizedDescription, category: "rebase")
        }

        if showsProgressDelay { try? await Task.sleep(for: .seconds(1)) }
        isSyncing = false
        syncingRepoID = nil
        return false
    }

    func continueRebase(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Continuing rebase...")

        do {
            let result = try await gitService.continueRebase(
                pat: try await authPayload(for: repo),
                authorName: repo.authorName,
                authorEmail: repo.authorEmail
            )
            guard mutateRepoIfPresent(id: repoID, mutate: { currentRepo in
                currentRepo.gitState.commitSHA = result.newCommitSHA
                currentRepo.gitState.lastSyncDate = Date()
            }) else {
                throw LocalGitError.notCloned
            }
            saveRepos()
            clearCommitHistoryCache(for: repoID)
            detectChanges(repoID: repoID)
            await loadBranches(repoID: repoID)
            await loadConflictSession(repoID: repoID)
            syncProgress = String(localized: "Rebase complete!")
            setPullOutcome(
                repoID: repoID,
                kind: .rebased,
                message: String(localized: "Rebase completed successfully")
            )
        } catch LocalGitError.rebaseConflictsDetected {
            await loadConflictSession(repoID: repoID)
            detectChanges(repoID: repoID)
            setPullOutcome(
                repoID: repoID,
                kind: .rebaseConflicts,
                message: String(localized: "Rebase has more conflicts — resolve them, then continue rebase")
            )
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription, category: "rebase")
        }

        isSyncing = false
        syncingRepoID = nil
    }

    func abortRebase(repoID: UUID) async {
        guard let _ = repoIndex(id: repoID), repo(id: repoID)?.isCloned == true else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Aborting rebase...")

        do {
            try await gitService.abortRebase()
            clearCommitHistoryCache(for: repoID)
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
            setPullOutcome(
                repoID: repoID,
                kind: .diverged,
                message: String(localized: "Rebase aborted. Local and remote still diverge.")
            )
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription, category: "rebase")
        }

        isSyncing = false
        syncingRepoID = nil
    }

    @discardableResult
    func pushCurrentBranch(repoID: UUID) async -> Bool {
        await gitOperationCoordinator.withOperation(repoID: repoID) { [self] in
            await performPushCurrentBranch(repoID: repoID)
        }
    }

    private func performPushCurrentBranch(repoID: UUID) async -> Bool {
        guard let repo = repo(id: repoID), repo.isCloned else { return false }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return false
        }

        beginLongGitOperation(.push, repoID: repoID)
        defer { finishLongGitOperation() }

        do {
            updateLongGitOperation(.connecting)
            await Task.yield()
            try checkLongGitOperationCancellation()
            updateLongGitOperation(.uploading)
            try await gitService.pushCurrentBranch(pat: try await authPayload(for: repo))

            let info = try? await gitService.repoInfo()
            guard mutateRepoIfPresent(id: repoID, mutate: { currentRepo in
                if let info {
                    currentRepo.gitState.branch = info.branch
                    currentRepo.gitState.commitSHA = info.commitSHA
                }
                currentRepo.gitState.lastSyncDate = Date()
            }) else {
                throw LocalGitError.notCloned
            }
            if let info {
                changeCounts[repoID] = info.changeCount
                statusEntriesByRepo[repoID] = info.statusEntries
                syncStateByRepo[repoID] = info.syncState
            }
            saveRepos()
            clearCommitHistoryCache(for: repoID)
            pushRetryRequiresCurrentBranch.remove(repoID)
            pushRetryRequiresCommit.remove(repoID)
            lastPushFailureByRepo.removeValue(forKey: repoID)
            detectChanges(repoID: repoID)
            await loadBranches(repoID: repoID)
            updateLongGitOperation(.completed)
            syncProgress = String(localized: "Push complete!")
            return true
        } catch is GitOperationCancelled {
            syncProgress = String(localized: "Push cancelled before upload")
            return false
        } catch {
            if !handleSSHHostKeyTrustIfNeeded(error, repoID: repoID, operation: .pushCurrentBranch) {
                showError(message: preferredPushFailure(error.localizedDescription, repoID: repoID), category: "push")
            }
            return false
        }
    }

    @discardableResult
    func push(repoID: UUID, message: String, operationID suppliedOperationID: String? = nil) async -> Bool {
        await gitOperationCoordinator.withOperation(repoID: repoID) { [self] in
            await performPush(repoID: repoID, message: message, operationID: suppliedOperationID)
        }
    }

    private func performPush(repoID: UUID, message: String, operationID suppliedOperationID: String?) async -> Bool {
        guard let repo = repo(id: repoID) else {
            showError(message: String(localized: "Repository not found"))
            return false
        }

        // If we're in the middle of a merge, "Commit & Push" really means
        // "complete the merge and push the merge commit". commitAndPush
        // would otherwise fail with "nothing to commit" when the conflict
        // resolution left the tree identical to HEAD — and even when it
        // didn't, we'd lose the two-parent merge topology.
        if let session = conflictSessionByRepo[repoID] {
            if session.kind == .merge {
                await completeMerge(repoID: repoID, message: message)
                return conflictSessionByRepo[repoID]?.isActive == false
            }
            if session.kind == .rebase {
                await continueRebase(repoID: repoID)
                return conflictSessionByRepo[repoID]?.isActive == false
            }
        }

        let operationID = suppliedOperationID ?? String(UUID().uuidString.prefix(8)).lowercased()
        pushRetryRequiresCurrentBranch.remove(repoID)
        pushRetryRequiresCommit.remove(repoID)
        beginLongGitOperation(.push, repoID: repoID)
        defer { finishLongGitOperation() }
        var startingCommitSHA: String?

        do {
            let vaultDir = vaultURL(for: repoID)
            let gitService = gitRepositoryFactory(vaultDir)

            guard gitService.hasGitDirectory else {
                throw LocalGitError.notCloned
            }

            updateLongGitOperation(.checkingRepository)
            startingCommitSHA = (try? await gitService.repoInfo())?.commitSHA
            try checkLongGitOperationCancellation()

            let commitMsg = message.isEmpty ? String(localized: "Update from HugoInk") : message

            updateLongGitOperation(.committing)
            DebugLogger.shared.info(
                "push", "Starting commit & push", detail: "commit message length: \(commitMsg.count)",
                repoID: repoID, repoName: repo.displayName, operationID: operationID
            )
            let result = try await gitService.commitAndPush(
                message: commitMsg,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail,
                pat: try await authPayload(for: repo)
            )

            guard mutateRepoIfPresent(id: repoID, mutate: { currentRepo in
                currentRepo.gitState.commitSHA = result.commitSHA
                currentRepo.gitState.lastSyncDate = Date()
            }) else {
                throw LocalGitError.notCloned
            }
            saveRepos()
            clearCommitHistoryCache(for: repoID)
            pushRetryRequiresCurrentBranch.remove(repoID)
            pushRetryRequiresCommit.remove(repoID)
            lastPushFailureByRepo.removeValue(forKey: repoID)
            detectChanges(repoID: repoID)
            updateLongGitOperation(.completed)
            syncProgress = String(localized: "Push complete!")
            DebugLogger.shared.info(
                "push", "Push complete", detail: "SHA: \(result.commitSHA)",
                repoID: repoID, repoName: repo.displayName, operationID: operationID
            )
            try? await Task.sleep(for: .seconds(1))
            return true

        } catch is GitOperationCancelled {
            syncProgress = String(localized: "Push cancelled before commit")
            return false
        } catch {
            let vaultDir = vaultURL(for: repoID)
            let gitService = gitRepositoryFactory(vaultDir)
            pushRetryRequiresCurrentBranch.remove(repoID)
            pushRetryRequiresCommit.insert(repoID)
            if let info = try? await gitService.repoInfo() {
                let previousCommitSHA = startingCommitSHA ?? self.repo(id: repoID)?.gitState.commitSHA ?? ""
                let didUpdateRepo = mutateRepoIfPresent(id: repoID) { currentRepo in
                    currentRepo.gitState.branch = info.branch
                    currentRepo.gitState.commitSHA = info.commitSHA
                }
                changeCounts[repoID] = info.changeCount
                statusEntriesByRepo[repoID] = info.statusEntries
                syncStateByRepo[repoID] = info.syncState
                if !previousCommitSHA.isEmpty, info.commitSHA != previousCommitSHA {
                    pushRetryRequiresCurrentBranch.insert(repoID)
                    pushRetryRequiresCommit.remove(repoID)
                } else {
                    pushRetryRequiresCurrentBranch.remove(repoID)
                    pushRetryRequiresCommit.insert(repoID)
                }
                if didUpdateRepo { saveRepos() }
            }
            if !handleSSHHostKeyTrustIfNeeded(error, repoID: repoID, operation: .pushCommit(message: message)) {
                showError(
                    message: preferredPushFailure(error.localizedDescription, repoID: repoID),
                    category: "push",
                    repoID: repoID,
                    operationID: operationID
                )
            }
        }

        try? await Task.sleep(for: .seconds(1))
        isSyncing = false
        syncingRepoID = nil
        return false
    }

    @discardableResult
    func retryPush(repoID: UUID, message: String, operationID: String? = nil) async -> Bool {
        if pushRetryRequiresCurrentBranch.contains(repoID) {
            return await pushCurrentBranch(repoID: repoID)
        }
        if pushRetryRequiresCommit.contains(repoID) {
            return await push(repoID: repoID, message: message, operationID: operationID)
        }
        if syncStateByRepo[repoID] == .ahead {
            return await pushCurrentBranch(repoID: repoID)
        }
        return await push(repoID: repoID, message: message, operationID: operationID)
    }


    // MARK: - Repo Management

    func consumeDuplicateReposCleanedCount() -> Int {
        defer { duplicateReposCleanedCount = 0 }
        return duplicateReposCleanedCount
    }

    static func deduplicatedRepos(_ source: [RepoConfig]) -> [RepoConfig] {
        var result: [RepoConfig] = []
        var indexByRemote: [String: Int] = [:]

        for repo in source {
            let key = normalizedRemoteKey(repo.repoURL)
            guard let existingIndex = indexByRemote[key] else {
                indexByRemote[key] = result.count
                result.append(repo)
                continue
            }

            // Prefer the record carrying cloned Git state. Failed clone retries
            // typically produced empty records for the same remote.
            if !result[existingIndex].isCloned && repo.isCloned {
                result[existingIndex] = repo
            }
        }
        return result
    }

    private static func normalizedRemoteKey(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTrailingSlash = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return withoutTrailingSlash.hasSuffix(".git")
            ? String(withoutTrailingSlash.dropLast(4)).lowercased()
            : withoutTrailingSlash.lowercased()
    }

    @discardableResult
    func addRepo(_ config: RepoConfig) -> UUID {
        var config = config
        if config.gitHubAccountLogin?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           config.authMethod == .gitHubPAT,
           GitRemoteURL.parse(config.repoURL)?.isGitHub == true,
           !activeGitHubAccountLogin.isEmpty {
            config.gitHubAccountLogin = activeGitHubAccountLogin
        }
        let normalizedRemote = Self.normalizedRemoteKey(config.repoURL)
        if let index = repos.firstIndex(where: {
            Self.normalizedRemoteKey($0.repoURL) == normalizedRemote
        }) {
            repos[index].authMethod = config.authMethod
            repos[index].authUsername = config.authUsername
            repos[index].gitHubAccountLogin = config.gitHubAccountLogin
            saveRepos()
            return repos[index].id
        }
        repos.append(config)
        saveRepos()
        resolveVaultBookmark(for: config.id)
        return config.id
    }

    /// Add a repository that already exists on the local filesystem.
    /// Reads git metadata from the `.git` directory and creates a RepoConfig
    /// that's immediately in "cloned" state — no network clone needed.
    func addLocalRepo(
        url: URL,
        bookmarkData: Data,
        authorName: String,
        authorEmail: String
    ) async {
        // Resolve the bookmark and start security-scoped access
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            showError(message: String(localized: "Could not resolve folder bookmark."))
            return
        }

        guard resolvedURL.startAccessingSecurityScopedResource() else {
            showError(message: String(localized: "Could not access the selected folder."))
            return
        }

        let gitService = gitRepositoryFactory(resolvedURL)

        guard gitService.hasGitDirectory else {
            resolvedURL.stopAccessingSecurityScopedResource()
            showError(message: String(localized: "No .git directory found. Please select a folder that contains a git repository."))
            return
        }

        do {
            let info = try await gitService.repoInfo()

            // Try to read the remote URL from the git config
            let remoteURL = Self.readGitRemoteURL(at: resolvedURL) ?? ""

            let remoteInfo = GitRemoteURL.parse(remoteURL)
            let config = RepoConfig(
                repoURL: remoteURL,
                branch: info.branch,
                authorName: authorName,
                authorEmail: authorEmail,
                vaultFolderName: resolvedURL.lastPathComponent,
                customVaultBookmarkData: bookmarkData,
                authMethod: remoteInfo?.isGitHub == true && remoteInfo?.isSSH == false && isSignedIn ? .gitHubPAT : GitAuthMethod.none,
                authUsername: remoteInfo?.username ?? "",
                gitHubAccountLogin: remoteInfo?.isGitHub == true && remoteInfo?.isSSH == false && isSignedIn ? activeGitHubAccountLogin : nil,
                gitState: GitState(
                    commitSHA: info.commitSHA,
                    treeSHA: "",
                    branch: info.branch,
                    blobSHAs: [:],
                    lastSyncDate: Date()
                )
            )

            // Track resolved URL and security scope
            resolvedCustomURLs[config.id] = resolvedURL
            accessingSecurityScope.insert(config.id)

            repos.append(config)
            saveRepos()
            detectChanges(repoID: config.id)
        } catch {
            resolvedURL.stopAccessingSecurityScopedResource()
            showError(message: String(localized: "Failed to read repository info: \(error.localizedDescription)"))
        }
    }

    /// Read the `origin` remote URL from a git repository's config.
    private static func readGitRemoteURL(at repoURL: URL) -> String? {
        let configURL = repoURL.appendingPathComponent(".git/config")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }

        // Simple parser: find [remote "origin"] section, then the url = ... line
        let lines = contents.components(separatedBy: .newlines)
        var inOriginSection = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[remote \"origin\"]") {
                inOriginSection = true
                continue
            }
            if trimmed.hasPrefix("[") {
                inOriginSection = false
                continue
            }
            if inOriginSection && trimmed.hasPrefix("url") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    @discardableResult
    func removeRepo(id: UUID, deleteLocalFiles: Bool = false) -> Bool {
        guard let originalIndex = repoIndex(id: id) else { return false }
        let repo = repos[originalIndex]
        guard !isRepositoryOperationInProgress(repoID: id) else {
            showError(
                message: String(localized: "Wait for the current Git operation to finish before moving or removing this repository.")
            )
            return false
        }
        let vaultDir = vaultURL(for: id)

        // Existing local repositories are user-owned folders that may also be
        // managed by another app. Removing HugoInk's bookmark must never
        // delete those files.
        if deleteLocalFiles,
           repo.isGitSyncManagedStorage,
           FileManager.default.fileExists(atPath: vaultDir.path) {
            do {
                try repositoryFileRemover(vaultDir)
            } catch {
                showError(
                    message: String(localized: "Local repository files could not be deleted. The repository was not removed."),
                    category: "persistence",
                    repoID: id
                )
                DebugLogger.shared.error(
                    "persistence",
                    "Local repository deletion failed; record preserved",
                    detail: persistenceErrorDiagnostic(error),
                    repoID: id,
                    repoName: repo.displayName
                )
                return false
            }
        }

        repos.remove(at: originalIndex)
        guard case .success = saveRepos() else {
            repos.insert(repo, at: min(originalIndex, repos.endIndex))
            return false
        }

        clearCustomLocation(for: id)
        clearRemoteCredentials(for: id)
        clearCachedRepoState(for: id)
        return true
    }

    private func clearCachedRepoState(for repoID: UUID) {
        changeCounts.removeValue(forKey: repoID)
        statusEntriesByRepo.removeValue(forKey: repoID)
        syncStateByRepo.removeValue(forKey: repoID)
        pullOutcomeByRepo.removeValue(forKey: repoID)
        diffByRepo.removeValue(forKey: repoID)
        branchesByRepo.removeValue(forKey: repoID)
        conflictSessionByRepo.removeValue(forKey: repoID)
        commitHistoryByRepo.removeValue(forKey: repoID)
        commitHistoryHasMoreByRepo.removeValue(forKey: repoID)
        commitDetailByRepo.removeValue(forKey: repoID)
        stashesByRepo.removeValue(forKey: repoID)
        tagsByRepo.removeValue(forKey: repoID)
    }

    /// Looks the repository up at mutation time so callers never retain an
    /// array index across an `await` suspension point.
    @discardableResult
    private func mutateRepoIfPresent(
        id: UUID,
        mutate: (inout RepoConfig) -> Void
    ) -> Bool {
        guard let index = repoIndex(id: id) else { return false }
        mutate(&repos[index])
        return true
    }

    func updateRepo(id: UUID, mutate: (inout RepoConfig) -> Void) {
        guard mutateRepoIfPresent(id: id, mutate: mutate) else { return }
        saveRepos()
    }

    @discardableResult
    func saveRepoConfiguration(
        id: UUID,
        repoURL: String,
        branch: String,
        authorName: String,
        authorEmail: String,
        authMethod: GitAuthMethod,
        credentials: GitRemoteCredentials
    ) async -> Bool {
        guard let idx = repoIndex(id: id) else {
            showError(message: String(localized: "Repository not found"))
            return false
        }

        let trimmedRepoURL = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldRepo = repos[idx]

        if oldRepo.isCloned,
           !trimmedRepoURL.isEmpty,
           trimmedRepoURL != oldRepo.repoURL.trimmingCharacters(in: .whitespacesAndNewlines) {
            let vaultDir = vaultURL(for: id)
            let gitService = gitRepositoryFactory(vaultDir)
            if gitService.hasGitDirectory {
                let cloneURL = GitRemoteURL.cloneURLString(from: trimmedRepoURL) ?? trimmedRepoURL
                do {
                    try await gitService.setRemoteURL(name: "origin", url: cloneURL)
                } catch {
                    showError(message: String(localized: "Failed to update origin remote: \(error.localizedDescription)"))
                    return false
                }
            }
        }

        guard mutateRepoIfPresent(id: id, mutate: { currentRepo in
            currentRepo.repoURL = trimmedRepoURL
            currentRepo.branch = branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "main"
                : branch.trimmingCharacters(in: .whitespacesAndNewlines)
            currentRepo.authorName = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
            currentRepo.authorEmail = authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            currentRepo.authMethod = authMethod
            currentRepo.authUsername = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
            currentRepo.gitHubAccountLogin = authMethod == .gitHubPAT ? activeGitHubAccountLogin : nil
        }) else {
            showError(message: String(localized: "Repository not found"))
            return false
        }

        switch authMethod {
        case .httpsToken, .sshKey:
            saveRemoteCredentials(credentials, for: id)
        case .gitHubPAT, .none:
            clearRemoteCredentials(for: id)
        }

        repoMutationGeneration[id, default: 0] += 1
        saveRepos()
        detectChanges(repoID: id)
        return true
    }

    // MARK: - OAuth

    func signInWithGitHub() async {
        let operationID = String(UUID().uuidString.prefix(8)).lowercased()
        DebugLogger.shared.info("auth", "Starting GitHub Device Flow", operationID: operationID)
        do {
            let credential = try await OAuthService.shared.signIn()
            try await activateGitHubAccount(credential: credential)
            DebugLogger.shared.info(
                "auth", "GitHub sign-in complete", detail: activeGitHubAccountLogin,
                operationID: operationID
            )
        } catch let oauthError as OAuthError where oauthError.isCancelled {
            DebugLogger.shared.info("auth", "GitHub sign-in cancelled", operationID: operationID)
        } catch {
            showError(message: error.localizedDescription, category: "auth", operationID: operationID)
        }
    }

    func signInWithPAT(token: String) async {
        let operationID = String(UUID().uuidString.prefix(8)).lowercased()
        DebugLogger.shared.info("auth", "Validating personal access token", operationID: operationID)
        do {
            try await activateGitHubAccount(
                credential: GitHubOAuthCredential(accessToken: token)
            )
            DebugLogger.shared.info(
                "auth", "Token sign-in complete", detail: activeGitHubAccountLogin,
                operationID: operationID
            )
        } catch {
            showError(
                message: String(localized: "Invalid token: \(error.localizedDescription)"),
                category: "auth",
                operationID: operationID
            )
        }
    }

    func switchGitHubAccount(login: String) async {
        guard let account = gitHubAccounts.first(where: { $0.login.caseInsensitiveCompare(login) == .orderedSame }),
              gitHubToken(for: account.login)?.isEmpty == false
        else { return }

        activeGitHubAccountLogin = account.login
        isSignedIn = true
        applyGitHubAccount(account)
        gitHubRepos = []
        saveGlobalSettings()
        await refreshRepos()
    }

    private func activateGitHubAccount(credential: GitHubOAuthCredential) async throws {
        syncProgress = String(localized: "Fetching profile...")
        let token = credential.accessToken
        let user = try await GitHubService.fetchUser(token: token)
        let email: String
        if let userEmail = user.email, !userEmail.isEmpty {
            email = userEmail
        } else {
            email = try await GitHubService.fetchPrimaryEmail(token: token) ?? ""
        }

        let account = GitHubAccount(
            login: user.login,
            displayName: user.name ?? user.login,
            avatarURL: user.avatar_url ?? "",
            email: email
        )

        if let existingIndex = gitHubAccounts.firstIndex(where: { $0.login.caseInsensitiveCompare(account.login) == .orderedSame }) {
            gitHubAccounts[existingIndex] = account
        } else {
            gitHubAccounts.append(account)
        }

        activeGitHubAccountLogin = account.login
        saveGitHubCredential(credential, for: account.login)
        deleteKeychainValue(for: "github_pat")
        isSignedIn = true
        applyGitHubAccount(account)

        isLoadingRepos = true
        defer { isLoadingRepos = false }
        gitHubRepos = try await GitHubService.fetchRepos(token: token)

        migrateRepoAccountOwnershipIfNeeded()
        saveGlobalSettings()
    }

    func refreshRepos() async {
        guard !activeGitHubAccountLogin.isEmpty else { return }
        isLoadingRepos = true
        defer { isLoadingRepos = false }
        do {
            let token = try await validGitHubToken(for: activeGitHubAccountLogin)
            gitHubRepos = try await GitHubService.fetchRepos(token: token)
        } catch {
            showError(message: error.localizedDescription, category: "auth")
        }
    }

    func hydrateGitHubProfileIfNeeded() async {
        guard !activeGitHubAccountLogin.isEmpty else { return }

        let needsProfile = gitHubUsername.isEmpty
            || gitHubDisplayName.isEmpty
            || defaultAuthorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || defaultAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard needsProfile else { return }

        do {
            let token = try await validGitHubToken(for: activeGitHubAccountLogin)
            let user = try await GitHubService.fetchUser(token: token)

            if gitHubUsername.isEmpty {
                gitHubUsername = user.login
            }
            if gitHubDisplayName.isEmpty {
                gitHubDisplayName = user.name ?? user.login
            }
            if gitHubAvatarURL.isEmpty {
                gitHubAvatarURL = user.avatar_url ?? ""
            }
            if defaultAuthorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaultAuthorName = user.name ?? user.login
            }
            if defaultAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let email = user.email, !email.isEmpty {
                    defaultAuthorEmail = email
                } else if let email = try await GitHubService.fetchPrimaryEmail(token: token), !email.isEmpty {
                    defaultAuthorEmail = email
                }
            }

            saveGlobalSettings()
        } catch {
            // Best-effort hydration for older sessions; keep existing values if unavailable.
        }
    }

    func signOut() {

        let login = activeGitHubAccountLogin
        if login.isEmpty {
            deleteKeychainValue(for: "github_pat")
            clearGitHubSession()
        } else {
            removeGitHubAccount(login: login)
        }
        saveGlobalSettings()
    }

    func removeGitHubAccount(login: String) {
        deleteGitHubCredential(for: login)
        gitHubAccounts.removeAll { $0.login.caseInsensitiveCompare(login) == .orderedSame }

        activeGitHubAccountLogin = gitHubAccounts.first(where: { gitHubToken(for: $0.login)?.isEmpty == false })?.login ?? ""
        if let account = activeGitHubAccount {
            isSignedIn = true
            applyGitHubAccount(account)
            gitHubRepos = []
        } else {
            clearGitHubSession()
        }
    }

    private func clearGitHubSession() {
        isSignedIn = false
        activeGitHubAccountLogin = ""
        gitHubUsername = ""
        gitHubDisplayName = ""
        gitHubAvatarURL = ""
        defaultAuthorName = ""
        defaultAuthorEmail = ""
        gitHubRepos = []
        isLoadingRepos = false
        hasCompletedOnboarding = false
    }

    // MARK: - Pull Outcome State

    private func setPullOutcome(repoID: UUID, kind: PullOutcomeKind, message: String) {
        pullOutcomeByRepo[repoID] = PullOutcomeState(kind: kind, message: message, date: Date())
    }

    private func clearCommitHistoryCache(for repoID: UUID) {
        commitHistoryByRepo.removeValue(forKey: repoID)
        commitHistoryHasMoreByRepo.removeValue(forKey: repoID)
        commitDetailByRepo.removeValue(forKey: repoID)
    }

    // MARK: - Error Handling

    private func preferredPushFailure(_ message: String, repoID: UUID) -> String {
        let currentCategory = GitFailureGuidance.classify(message: message).category
        if currentCategory == .general,
           let previous = lastPushFailureByRepo[repoID],
           GitFailureGuidance.classify(message: previous).category == .authentication {
            return previous
        }
        lastPushFailureByRepo[repoID] = message
        return message
    }

    private func showError(
        message: String,
        category: String = "general",
        repoID: UUID? = nil,
        operationID: String? = nil
    ) {
        lastError = message
        lastErrorGuidance = GitFailureGuidance.classify(message: message)
        showError = true
        DebugLogger.shared.error(
            category,
            message,
            repoID: repoID,
            repoName: repoID.flatMap { repo(id: $0)?.displayName },
            operationID: operationID
        )
    }

    var lastErrorTitle: String {
        lastErrorGuidance?.title ?? String(localized: "Error")
    }

    var lastErrorPresentation: String {
        lastErrorGuidance?.presentationMessage
            ?? lastError
            ?? String(localized: "Unknown error")
    }

}

// MARK: - Callback Result State

/// Displayed briefly in the UI after a callback operation completes,
/// before redirecting back to the calling app.
struct CallbackResultState: Equatable {
    let repoID: UUID
    let action: String
    let isSuccess: Bool
    let message: String
}
