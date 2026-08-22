import Foundation

extension AppState {

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

    func loadState() {
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
                recordDuplicateReposCleaned(decoded.count - repos.count)
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

    func migrateRepoAccountOwnershipIfNeeded() {
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

    func applyGitHubAccount(_ account: GitHubAccount) {
        gitHubUsername = account.login
        gitHubDisplayName = account.displayName
        gitHubAvatarURL = account.avatarURL
        defaultAuthorName = account.displayName.isEmpty ? account.login : account.displayName
        defaultAuthorEmail = account.email
    }

    @discardableResult
    func saveRepos() -> Result<Void, RepoPersistenceError> {
        switch reposPersistenceWriter.persist(repos) {
        case .success:
            return .success(())
        case .failure(let failure):
            DebugLogger.shared.error(
                "persistence",
                "Could not save repository settings",
                detail: failure.diagnostic
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

}
