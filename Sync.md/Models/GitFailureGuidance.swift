import Foundation

enum GitFailureCategory: String, Equatable, Sendable {
    case authentication
    case network
    case remoteRejected
    case repositoryCorrupted
    case general

    var title: String {
        switch self {
        case .authentication:
            return String(localized: "Authentication Failed")
        case .network:
            return String(localized: "Network Interrupted")
        case .remoteRejected:
            return String(localized: "Remote Rejected the Operation")
        case .repositoryCorrupted:
            return String(localized: "Repository May Be Corrupted")
        case .general:
            return String(localized: "Git Operation Failed")
        }
    }

    var recoverySuggestion: String {
        switch self {
        case .authentication:
            return String(localized: "Check the repository credentials and sign in again if needed. For GitHub tokens, confirm access to this repository and Contents read/write permission.")
        case .network:
            return String(localized: "Check the network and VPN, then retry. Your local files and commits are unchanged.")
        case .remoteRejected:
            return String(localized: "Pull the latest remote changes and check branch protection or repository permissions before retrying. Local commits are retained.")
        case .repositoryCorrupted:
            return String(localized: "Stop writing to this repository, back up working files, and clone into a new folder. Keep the original folder until recovery is complete.")
        case .general:
            return String(localized: "Review the error details and debug log. Retry only after confirming the repository is in a safe state.")
        }
    }
}

struct GitFailureGuidance: Equatable, Sendable {
    let category: GitFailureCategory
    let detail: String

    var title: String { category.title }
    var recoverySuggestion: String { category.recoverySuggestion }

    var presentationMessage: String {
        "\(detail)\n\n\(String(localized: "Suggested action")): \(recoverySuggestion)"
    }

    static func classify(error: Error) -> GitFailureGuidance {
        if let localError = error as? LocalGitError,
           case .repositoryCorrupted = localError {
            return guidance(category: .repositoryCorrupted, error: error)
        }

        if let gitHubError = error as? GitHubError {
            switch gitHubError {
            case .unauthorized:
                return guidance(category: .authentication, error: error)
            case .rateLimited:
                return guidance(category: .network, error: error)
            case .conflict:
                return guidance(category: .remoteRejected, error: error)
            case .apiError(let status, _):
                if status == 401 || status == 403 {
                    return guidance(category: .authentication, error: error)
                }
                if status == 409 || status == 422 {
                    return guidance(category: .remoteRejected, error: error)
                }
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           networkErrorCodes.contains(nsError.code) {
            return guidance(category: .network, error: error)
        }

        return classify(message: error.localizedDescription)
    }

    static func classify(message: String) -> GitFailureGuidance {
        let normalized = message.lowercased()
        let category: GitFailureCategory

        if containsAny(normalized, keywords: corruptionKeywords) {
            category = .repositoryCorrupted
        } else if containsAny(normalized, keywords: authenticationKeywords) {
            category = .authentication
        } else if containsAny(normalized, keywords: remoteRejectionKeywords) {
            category = .remoteRejected
        } else if containsAny(normalized, keywords: networkKeywords) {
            category = .network
        } else {
            category = .general
        }

        return GitFailureGuidance(category: category, detail: message)
    }

    private static func guidance(category: GitFailureCategory, error: Error) -> GitFailureGuidance {
        GitFailureGuidance(category: category, detail: error.localizedDescription)
    }

    private static func containsAny(_ message: String, keywords: [String]) -> Bool {
        keywords.contains { message.contains($0) }
    }

    private static let networkErrorCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorCallIsActive,
        NSURLErrorDataNotAllowed
    ]

    private static let corruptionKeywords = [
        "repository corrupted", "repository is corrupted", "corrupt object",
        "object database is corrupt", "invalid object", "bad object", "index file corrupt"
    ]

    private static let authenticationKeywords = [
        "authentication failed", "unauthorized", "invalid or expired token", "invalid credentials",
        "permission denied (publickey)", "could not read username", "http 401", "http 403",
        "api error (401)", "api error (403)"
    ]

    private static let remoteRejectionKeywords = [
        "non-fast-forward", "protected branch", "pre-receive hook", "remote rejected",
        "rejected the operation", "remote contains work", "branch protection", "failed to push some refs"
    ]

    private static let networkKeywords = [
        "network connection was lost", "not connected to the internet", "could not resolve host",
        "could not connect", "connection reset", "connection timed out", "operation timed out",
        "temporary failure in name resolution", "dns lookup failed", "network is unreachable"
    ]
}
