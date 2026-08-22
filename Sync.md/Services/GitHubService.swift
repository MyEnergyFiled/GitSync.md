import Foundation

// MARK: - Service Errors

enum GitHubError: LocalizedError {
    case invalidURL
    case unauthorized
    case notFound(String)
    case rateLimited
    case conflict(String)
    case apiError(Int, String)
    case decodingError(String)
    case noChanges

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid repository URL")
        case .unauthorized:
            return String(localized: "Invalid or expired token. Sign out and sign in again.")
        case .notFound(let detail):
            return String(localized: "Not found: \(detail)")
        case .rateLimited:
            return String(localized: "GitHub API rate limit exceeded. Try again later.")
        case .conflict(let message):
            return String(localized: "Conflict: \(message)")
        case .apiError(let code, let message):
            return String(localized: "GitHub API error (\(code)): \(message)")
        case .decodingError(let message):
            return String(localized: "Failed to parse response: \(message)")
        case .noChanges:
            return String(localized: "No changes to push")
        }
    }
}

// MARK: - GitHub Account API

/// Account-level GitHub REST API used for sign-in and repository discovery.
/// Repository clone, pull, and push operations are handled by LocalGitService.
final class GitHubService: Sendable {
    private init() {}

    static func parseRepoURL(_ urlString: String) -> (owner: String, repo: String)? {
        guard let remote = GitRemoteURL.parse(urlString),
              remote.isGitHub,
              remote.pathComponents.count == 2,
              let owner = remote.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !owner.isEmpty else {
            return nil
        }
        let repo = remote.repoName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { return nil }
        return (owner, repo)
    }

    private static func diagnosedData(
        for request: URLRequest,
        session: URLSession,
        endpoint: String
    ) async throws -> (Data, HTTPURLResponse) {
        let startedAt = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                await DebugLogger.logHTTP(
                    category: "github-network",
                    method: request.httpMethod ?? "GET",
                    endpoint: endpoint,
                    statusCode: nil,
                    duration: Date().timeIntervalSince(startedAt),
                    responseBytes: data.count,
                    error: GitHubError.apiError(0, String(localized: "Invalid response"))
                )
                throw GitHubError.apiError(0, String(localized: "Invalid response"))
            }
            await DebugLogger.logHTTP(
                category: "github-network",
                method: request.httpMethod ?? "GET",
                endpoint: endpoint,
                statusCode: http.statusCode,
                duration: Date().timeIntervalSince(startedAt),
                responseBytes: data.count,
                requestID: http.value(forHTTPHeaderField: "x-github-request-id")
            )
            return (data, http)
        } catch {
            if error is GitHubError { throw error }
            await DebugLogger.logHTTP(
                category: "github-network",
                method: request.httpMethod ?? "GET",
                endpoint: endpoint,
                statusCode: nil,
                duration: Date().timeIntervalSince(startedAt),
                error: error
            )
            throw error
        }
    }
}

struct GitHubUser: Codable {
    let login: String
    let name: String?
    let email: String?
    let avatar_url: String?
}

struct GitHubRepo: Codable, Identifiable {
    let id: Int
    let name: String
    let fullName: String
    let description: String?
    let isPrivate: Bool
    let htmlURL: String
    let defaultBranch: String
    let updatedAt: String?
    let owner: Owner

    struct Owner: Codable {
        let login: String
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, owner
        case fullName = "full_name"
        case isPrivate = "private"
        case htmlURL = "html_url"
        case defaultBranch = "default_branch"
        case updatedAt = "updated_at"
    }
}

extension GitHubService {
    static func fetchUser(token: String) async throws -> GitHubUser {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await diagnosedData(
            for: request,
            session: .shared,
            endpoint: "/user"
        )
        guard response.statusCode == 200 else { throw GitHubError.unauthorized }
        return try JSONDecoder().decode(GitHubUser.self, from: data)
    }

    static func fetchRepos(token: String, page: Int = 1) async throws -> [GitHubRepo] {
        var components = URLComponents(string: "https://api.github.com/user/repos")!
        components.queryItems = [
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await diagnosedData(
            for: request,
            session: .shared,
            endpoint: "/user/repos"
        )
        guard response.statusCode == 200 else { throw GitHubError.unauthorized }
        return try JSONDecoder().decode([GitHubRepo].self, from: data)
    }

    static func fetchPrimaryEmail(token: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://api.github.com/user/emails")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await diagnosedData(
            for: request,
            session: .shared,
            endpoint: "/user/emails"
        )
        guard response.statusCode == 200 else { return nil }
        struct Email: Codable {
            let email: String
            let primary: Bool
        }
        let emails = try JSONDecoder().decode([Email].self, from: data)
        return emails.first(where: { $0.primary })?.email ?? emails.first?.email
    }
}
