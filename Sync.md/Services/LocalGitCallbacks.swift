import Foundation
import Clibgit2
import libgit2

// MARK: - libgit2 Helpers

/// Get the last libgit2 error message.
func git2ErrorMessage(fallback: String? = nil) -> String {
    if let err = git_error_last(), let message = err.pointee.message {
        let trimmed = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.lowercased() != "no error" {
            return trimmed
        }
    }

    if let fallback {
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }

    return String(localized: "Unknown git error")
}

/// Call a libgit2 function and throw if it returns an error code.
@discardableResult
func git2Check(_ code: Int32, context: String = "", fallback: String? = nil) throws -> Int32 {
    guard code >= 0 else {
        let msg = git2ErrorMessage(fallback: fallback)
        let full = context.isEmpty ? msg : "\(context): \(msg)"
        throw LocalGitError.libgit2(full)
    }
    return code
}

/// Like `git2Check`, but preserves SSH host-key trust failures captured by the
/// transport callback instead of flattening them into a generic libgit2 error.
@discardableResult
func git2TransportCheck(
    _ code: Int32,
    context: String = "",
    fallback: String? = nil,
    credentialContext: CredentialContext,
    wrapping: (String) -> LocalGitError
) throws -> Int32 {
    guard code >= 0 else {
        if let sshHostKeyTrustError = credentialContext.sshHostKeyTrustError {
            throw LocalGitError.sshHostKeyTrustRequired(sshHostKeyTrustError)
        }
        let msg = credentialContext.callbackErrorMessage ?? git2ErrorMessage(fallback: fallback)
        let full = context.isEmpty ? msg : "\(context): \(msg)"
        throw wrapping(full)
    }
    return code
}

struct GitSignatureIdentity {
    let name: String
    let email: String
}

func validatedGitSignatureIdentity(authorName: String, authorEmail: String) throws -> GitSignatureIdentity {
    let name = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
    let email = authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !name.isEmpty else {
        throw LocalGitError.invalidAuthorIdentity(String(localized: "Author Name is required."))
    }
    guard !email.isEmpty else {
        throw LocalGitError.invalidAuthorIdentity(String(localized: "Author Email is required."))
    }
    let forbiddenNameCharacters = CharacterSet(charactersIn: "<>\n\r")
    guard name.rangeOfCharacter(from: forbiddenNameCharacters) == nil else {
        throw LocalGitError.invalidAuthorIdentity(String(localized: "Author Name cannot contain line breaks or angle brackets."))
    }

    let forbiddenEmailCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>"))
    guard email.contains("@"), email.rangeOfCharacter(from: forbiddenEmailCharacters) == nil else {
        throw LocalGitError.invalidAuthorIdentity(String(localized: "Author Email must look like you@example.com."))
    }

    return GitSignatureIdentity(name: name, email: email)
}

func createGitSignature(
    _ signature: inout UnsafeMutablePointer<git_signature>?,
    authorName: String,
    authorEmail: String
) throws {
    let identity = try validatedGitSignatureIdentity(authorName: authorName, authorEmail: authorEmail)
    guard git_signature_now(&signature, identity.name, identity.email) >= 0 else {
        throw LocalGitError.invalidAuthorIdentity(
            git2ErrorMessage(fallback: "Author Name or Author Email was rejected by Git.")
        )
    }
}

/// Convert a `git_oid` pointer to a 40-char hex string.
func oidToHex(_ oid: UnsafePointer<git_oid>) -> String {
    // SHA-1 hex is 40 chars + null terminator
    let bufSize = 41
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bufSize)
    defer { buf.deallocate() }
    git_oid_tostr(buf, bufSize, oid)
    return String(cString: buf)
}

/// Build a `git_strarray` from a single string. The caller must keep `cStr` alive.
func makeStrarray(_ cStr: UnsafeMutablePointer<CChar>, into arr: inout git_strarray, storage: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
    storage.pointee = cStr
    arr.strings = storage
    arr.count = 1
}

// MARK: - Credential Callback

/// Context passed through libgit2's credential callback payload.
class CredentialContext {
    let credentials: GitRemoteCredentials
    let remoteURL: String?
    let hostKeyTrustStore: any GitLFSSSHHostKeyTrustStore
    var didAttemptUsername = false
    var didAttemptUserPass = false
    var didAttemptSSHKey = false
    var didAttemptDefault = false
    private(set) var callbackErrorMessage: String?
    private(set) var sshHostKeyTrustError: GitLFSSSHHostKeyTrustError?

    init(
        credentials: GitRemoteCredentials,
        remoteURL: String? = nil,
        hostKeyTrustStore: any GitLFSSSHHostKeyTrustStore = GitLFSSSHHostKeyFileTrustStore.default
    ) {
        self.credentials = credentials
        self.remoteURL = remoteURL
        self.hostKeyTrustStore = hostKeyTrustStore
    }

    func resetAttempts() {
        didAttemptUsername = false
        didAttemptUserPass = false
        didAttemptSSHKey = false
        didAttemptDefault = false
        callbackErrorMessage = nil
        sshHostKeyTrustError = nil
    }

    func recordCallbackError(_ message: String) {
        callbackErrorMessage = message
    }

    func recordSSHHostKeyTrustError(_ error: GitLFSSSHHostKeyTrustError) {
        sshHostKeyTrustError = error
        callbackErrorMessage = error.localizedDescription
    }

    func failCredential(_ message: String) -> Int32 {
        recordCallbackError(message)
        return GIT_EUSER.rawValue
    }
}

func credentialMethodDescription(_ method: GitAuthMethod) -> String {
    switch method {
    case .gitHubPAT:
        return String(localized: "GitHub token")
    case .none:
        return String(localized: "no credentials")
    case .httpsToken:
        return String(localized: "HTTPS username/token")
    case .sshKey:
        return String(localized: "SSH key")
    }
}

func credentialTypesDescription(_ allowedTypes: UInt32) -> String {
    var names: [String] = []
    if allowedTypes & GIT_CREDENTIAL_USERNAME.rawValue != 0 { names.append(String(localized: "username")) }
    if allowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 { names.append(String(localized: "username/password")) }
    if allowedTypes & GIT_CREDENTIAL_SSH_KEY.rawValue != 0 || allowedTypes & GIT_CREDENTIAL_SSH_MEMORY.rawValue != 0 { names.append(String(localized: "SSH key")) }
    if allowedTypes & GIT_CREDENTIAL_DEFAULT.rawValue != 0 { names.append(String(localized: "default system credentials")) }
    return names.isEmpty ? String(localized: "credentials") : names.joined(separator: ", ")
}

func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string, !string.isEmpty else { return body(nil) }
    return string.withCString { body($0) }
}

func preferredUsername(from ctx: CredentialContext, usernameFromURL: UnsafePointer<CChar>?) -> String {
    let configured = ctx.credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
    if !configured.isEmpty { return configured }
    if let usernameFromURL { return String(cString: usernameFromURL) }
    if ctx.credentials.method == .sshKey { return "git" }
    if ctx.credentials.method == .gitHubPAT { return "x-access-token" }
    return ""
}

func acquireCredential(
    cred: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>?,
    usernameFromURL: UnsafePointer<CChar>?,
    allowedTypes: UInt32,
    context ctx: CredentialContext
) -> Int32 {
    let credentials = ctx.credentials
    let username = preferredUsername(from: ctx, usernameFromURL: usernameFromURL)
    let requestedCredentials = credentialTypesDescription(allowedTypes)

    if allowedTypes & GIT_CREDENTIAL_USERNAME.rawValue != 0, usernameFromURL == nil, !username.isEmpty {
        if ctx.didAttemptUsername {
            return ctx.failCredential(String(localized: "The remote rejected the username '\(username)'. Check the repository credentials."))
        }
        ctx.didAttemptUsername = true
        let code = git_credential_username_new(cred, username)
        if code < 0 {
            ctx.recordCallbackError(git2ErrorMessage(fallback: String(localized: "Could not create username credentials for '\(username)'.")))
        }
        return code
    }

    if allowedTypes & GIT_CREDENTIAL_SSH_MEMORY.rawValue != 0 || allowedTypes & GIT_CREDENTIAL_SSH_KEY.rawValue != 0 {
        guard credentials.method == .sshKey else {
            return ctx.failCredential(String(localized: "The remote requested SSH credentials, but this repository is configured for \(credentialMethodDescription(credentials.method))."))
        }
        guard !credentials.privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ctx.failCredential(String(localized: "The remote requested an SSH key, but no private key is saved for this repository."))
        }
        guard !username.isEmpty else {
            return ctx.failCredential(String(localized: "The remote requested an SSH key, but no SSH username is configured."))
        }
        if ctx.didAttemptSSHKey {
            return ctx.failCredential(String(localized: "The remote rejected the saved SSH key. Check that the key has access to this repository and that the passphrase is correct."))
        }
        ctx.didAttemptSSHKey = true

        // `libssh2_userauth_publickey_frommemory` accepts a nil public key and
        // derives it from the private key. Prefer that path because Forgejo and
        // OpenSSH commonly expose public keys in authorized_keys format
        // (`ecdsa-sha2-nistp256 AAAA... comment`), while libssh2's memory API
        // can treat that text as malformed key material and the server rejects
        // authentication before it ever checks the private-key signature.
        let passphrase = credentials.passphrase.isEmpty ? nil : credentials.passphrase

        let code = username.withCString { usernameC in
            credentials.privateKey.withCString { privateKeyC in
                withOptionalCString(passphrase) { passphraseC in
                    git_credential_ssh_key_memory_new(
                        cred,
                        usernameC,
                        nil,
                        privateKeyC,
                        passphraseC
                    )
                }
            }
        }
        if code < 0 {
            ctx.recordCallbackError(git2ErrorMessage(fallback: String(localized: "Could not load the saved SSH key. Check the key format and passphrase.")))
        }
        return code
    }

    if allowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 {
        guard credentials.method == .gitHubPAT || credentials.method == .httpsToken else {
            return ctx.failCredential(String(localized: "The remote requested HTTPS username/password credentials, but this repository is configured for \(credentialMethodDescription(credentials.method))."))
        }
        guard !credentials.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if credentials.method == .gitHubPAT {
                return ctx.failCredential(String(localized: "GitHub authentication is selected, but no GitHub token is saved. Sign in again or reconnect GitHub."))
            }
            return ctx.failCredential(String(localized: "The remote requested HTTPS credentials, but no token or password is saved for this repository."))
        }
        if ctx.didAttemptUserPass {
            return ctx.failCredential(String(localized: "The remote rejected the saved token/password. Check that it has access to this repository."))
        }
        ctx.didAttemptUserPass = true

        let effectiveUsername = username.isEmpty ? "x-access-token" : username
        let code = git_credential_userpass_plaintext_new(cred, effectiveUsername, credentials.password)
        if code < 0 {
            ctx.recordCallbackError(git2ErrorMessage(fallback: String(localized: "Could not create HTTPS credentials.")))
        }
        return code
    }

    if allowedTypes & GIT_CREDENTIAL_DEFAULT.rawValue != 0 {
        if ctx.didAttemptDefault {
            return ctx.failCredential(String(localized: "The remote rejected the default system credentials."))
        }
        ctx.didAttemptDefault = true
        let code = git_credential_default_new(cred)
        if code < 0 {
            ctx.recordCallbackError(git2ErrorMessage(fallback: String(localized: "Could not load default system credentials.")))
        }
        return code
    }

    if credentials.method == .none {
        return ctx.failCredential(String(localized: "The remote requested authentication (\(requestedCredentials)), but no credentials are configured for this repository."))
    }
    return ctx.failCredential(String(localized: "The remote requested \(requestedCredentials), but the saved \(credentialMethodDescription(credentials.method)) credentials are not compatible."))
}

/// libgit2 credential callback for HTTPS/PAT and SSH-key authentication.
nonisolated func credentialCallback(
    cred: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>?,
    url: UnsafePointer<CChar>?,
    usernameFromURL: UnsafePointer<CChar>?,
    allowedTypes: UInt32,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let payload else { return GIT_EUSER.rawValue }
    let ctx = Unmanaged<CredentialContext>.fromOpaque(payload).takeUnretainedValue()
    return acquireCredential(
        cred: cred,
        usernameFromURL: usernameFromURL,
        allowedTypes: allowedTypes,
        context: ctx
    )
}

nonisolated func sshSHA256Fingerprint(from cert: UnsafeMutablePointer<git_cert>) -> String? {
    let hostKey = UnsafeMutableRawPointer(cert).assumingMemoryBound(to: git_cert_hostkey.self).pointee
    guard hostKey.type.rawValue & GIT_CERT_SSH_SHA256.rawValue != 0 else { return nil }

    let digest = withUnsafeBytes(of: hostKey.hash_sha256) { bytes in
        Data(bytes.prefix(32))
    }
    let base64 = digest.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    return "SHA256:\(base64)"
}

nonisolated func sshHostAndPort(for callbackHost: String, remoteURL: String?) -> (host: String, port: Int) {
    if let remoteURL,
       let remote = GitRemoteURL.parse(remoteURL),
       remote.isSSH,
       let host = remote.host,
       !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return (GitLFSSSHHostKeyFileTrustStore.normalizeHost(host), remote.sshPort ?? 22)
    }
    return (GitLFSSSHHostKeyFileTrustStore.normalizeHost(callbackHost), 22)
}

/// Host-key/certificate callback. HTTPS keeps libgit2's platform certificate
/// validation. SSH remotes are pinned through HugoInk's known-hosts store:
/// first use is blocked until the user explicitly trusts the displayed
/// SHA-256 host-key fingerprint, and later key changes are rejected.
nonisolated func certificateCheckCallback(
    cert: UnsafeMutablePointer<git_cert>?,
    valid: Int32,
    host: UnsafePointer<CChar>?,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    let hostName = host.map { String(cString: $0) } ?? String(localized: "the remote host")
    guard let payload, let cert else { return GIT_ECERTIFICATE.rawValue }

    let ctx = Unmanaged<CredentialContext>.fromOpaque(payload).takeUnretainedValue()
    if cert.pointee.cert_type == GIT_CERT_HOSTKEY_LIBSSH2 {
        guard ctx.credentials.method == .sshKey else {
            ctx.recordCallbackError(String(localized: "SSH host key verification failed for \(hostName). Configure this repository with SSH key credentials or use HTTPS."))
            return GIT_ECERTIFICATE.rawValue
        }
        guard let fingerprint = sshSHA256Fingerprint(from: cert) else {
            ctx.recordCallbackError(String(localized: "SSH host key verification failed for \(hostName). The server did not provide a SHA-256 host-key fingerprint."))
            return GIT_ECERTIFICATE.rawValue
        }

        let (trustedHost, trustedPort) = sshHostAndPort(for: hostName, remoteURL: ctx.remoteURL)
        do {
            try ctx.hostKeyTrustStore.validate(fingerprint: fingerprint, host: trustedHost, port: trustedPort)
            return 0
        } catch let error as GitLFSSSHHostKeyTrustError {
            ctx.recordSSHHostKeyTrustError(error)
            return GIT_ECERTIFICATE.rawValue
        } catch {
            ctx.recordCallbackError(error.localizedDescription)
            return GIT_ECERTIFICATE.rawValue
        }
    }

    if valid != 0 { return 0 }
    ctx.recordCallbackError(String(localized: "TLS certificate verification failed for \(hostName). Check your network or the remote's certificate."))
    return GIT_ECERTIFICATE.rawValue
}

// MARK: - Push Callbacks

/// Context for push operations — combines credentials with per-ref rejection tracking.
///
/// `git_remote_push` returns 0 on network success even when the remote rejects
/// individual refs (non-fast-forward, protected branch, pre-receive hook). The
/// only way to detect those rejections is via the `push_update_reference`
/// callback, which is called once per ref with a non-nil `status` string when
/// that ref was rejected.
final class PushContext: CredentialContext {
    var rejectedRefs: [(refname: String, reason: String)] = []
}

nonisolated func pushCredentialCallback(
    cred: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>?,
    url: UnsafePointer<CChar>?,
    usernameFromURL: UnsafePointer<CChar>?,
    allowedTypes: UInt32,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let payload else { return GIT_EUSER.rawValue }
    let ctx = Unmanaged<PushContext>.fromOpaque(payload).takeUnretainedValue()
    return acquireCredential(
        cred: cred,
        usernameFromURL: usernameFromURL,
        allowedTypes: allowedTypes,
        context: ctx
    )
}

nonisolated func pushUpdateReferenceCallback(
    refname: UnsafePointer<CChar>?,
    status: UnsafePointer<CChar>?,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let payload else { return 0 }
    let ctx = Unmanaged<PushContext>.fromOpaque(payload).takeUnretainedValue()

    // A non-nil status means the remote rejected this ref update.
    if let status {
        let refnameString = refname.map { String(cString: $0) } ?? "(unknown)"
        let reason = String(cString: status)
        ctx.rejectedRefs.append((refname: refnameString, reason: reason))
    }
    return 0
}

final class DiffPrintCollector {
    var output: String = ""
}

nonisolated func diffPrintCallback(
    delta: UnsafePointer<git_diff_delta>?,
    hunk: UnsafePointer<git_diff_hunk>?,
    line: UnsafePointer<git_diff_line>?,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let payload, let line else { return 0 }
    let collector = Unmanaged<DiffPrintCollector>.fromOpaque(payload).takeUnretainedValue()

    // libgit2 strips the +/-/space origin from content; prepend it so the
    // emitted text is a well-formed unified diff that parsers can classify.
    let origin = UInt8(bitPattern: line.pointee.origin)
    switch origin {
    case UInt8(ascii: "F"), UInt8(ascii: "H"), UInt8(ascii: "B"):
        break
    default:
        collector.output.append(Character(Unicode.Scalar(origin)))
    }

    let length = Int(line.pointee.content_len)
    if let content = line.pointee.content, length > 0 {
        let data = Data(bytes: content, count: length)
        collector.output += String(decoding: data, as: UTF8.self)
    }

    return 0
}

final class StashListCollector {
    var entries: [GitStashEntry] = []
}

nonisolated func stashForeachCallback(
    index: Int,
    message: UnsafePointer<CChar>?,
    stashID: UnsafePointer<git_oid>?,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let payload, let stashID else { return 0 }
    let collector = Unmanaged<StashListCollector>.fromOpaque(payload).takeUnretainedValue()

    let oidHex = oidToHex(stashID)
    let entryMessage = message.map { String(cString: $0) } ?? ""
    collector.entries.append(GitStashEntry(index: Int(index), oid: oidHex, message: entryMessage))
    return 0
}
