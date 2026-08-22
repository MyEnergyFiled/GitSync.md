import Foundation

extension AppState {

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

    static func gitHubTokenKey(for login: String) -> String {
        "github_pat_\(login.lowercased())"
    }

    private static func gitHubOAuthCredentialKey(for login: String) -> String {
        "github_oauth_credential_\(login.lowercased())"
    }

    func keychainValue(for key: String) -> String? {
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
    func saveKeychainValue(_ value: String, for key: String) -> Bool {
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
    func deleteKeychainValue(for key: String) -> Bool {
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

    func saveGitHubCredential(_ credential: GitHubOAuthCredential, for login: String) {
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

    func deleteGitHubCredential(for login: String) {
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
    func validGitHubToken(for login: String?) async throws -> String {
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

}
