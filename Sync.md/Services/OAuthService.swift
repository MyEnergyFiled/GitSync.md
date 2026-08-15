import Foundation
import UIKit

enum OAuthError: LocalizedError {
    case noToken
    case cancelled
    case failed(String)

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .noToken: return String(localized: "No access token received from GitHub.")
        case .cancelled: return String(localized: "Sign-in was cancelled.")
        case .failed(let message): return message
        }
    }
}

/// GitHub Device Flow implemented entirely on-device.
/// Requests go directly to github.com; no OAuth proxy or client secret is used.
@MainActor
final class OAuthService {
    static let shared = OAuthService()

    private let clientID = "Iv23likGTprMGI5771G2"
    private let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    private init() {}

    func signIn() async throws -> String {
        let device = try await requestDeviceCode()
        try await presentDeviceCode(device.userCode)

        UIPasteboard.general.string = device.userCode
        guard await UIApplication.shared.open(device.verificationURI) else {
            throw OAuthError.failed("Could not open the GitHub authorization page.")
        }

        return try await pollForAccessToken(device)
    }

    private func requestDeviceCode() async throws -> DeviceCodeResponse {
        let data = try await postForm(
            to: deviceCodeURL,
            fields: ["client_id": clientID]
        )
        do {
            return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        } catch {
            throw OAuthError.failed("GitHub returned an invalid device authorization response.")
        }
    }

    private func pollForAccessToken(_ device: DeviceCodeResponse) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
        var interval = max(device.interval, 5)

        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()

            let data = try await postForm(
                to: accessTokenURL,
                fields: [
                    "client_id": clientID,
                    "device_code": device.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            )
            let response: TokenResponse
            do {
                response = try JSONDecoder().decode(TokenResponse.self, from: data)
            } catch {
                throw OAuthError.failed("GitHub returned an invalid access token response.")
            }

            if let token = response.accessToken, !token.isEmpty {
                return token
            }

            switch response.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "access_denied":
                throw OAuthError.cancelled
            case "expired_token":
                throw OAuthError.failed("The GitHub authorization code expired. Please try again.")
            case "device_flow_disabled":
                throw OAuthError.failed("Device Flow is disabled in the GitHub App settings.")
            case let error?:
                throw OAuthError.failed(response.errorDescription ?? error)
            case nil:
                throw OAuthError.noToken
            }
        }

        throw OAuthError.failed("The GitHub authorization code expired. Please try again.")
    }

    private func postForm(to url: URL, fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = fields
            .map { key, value in
                "\(formEncode(key))=\(formEncode(value))"
            }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)

        let startedAt = Date()
        let endpoint = url == deviceCodeURL ? "/login/device/code" : "/login/oauth/access_token"
        let data: Data
        let http: HTTPURLResponse
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OAuthError.failed("GitHub authorization returned an invalid response.")
            }
            data = responseData
            http = httpResponse
        } catch {
            await DebugLogger.logHTTP(
                category: "oauth-network",
                method: "POST",
                endpoint: endpoint,
                statusCode: nil,
                duration: Date().timeIntervalSince(startedAt),
                error: error
            )
            throw error
        }

        let duration = Date().timeIntervalSince(startedAt)
        if url == deviceCodeURL || !(200..<300).contains(http.statusCode) || duration >= 2 {
            await DebugLogger.logHTTP(
                category: "oauth-network",
                method: "POST",
                endpoint: endpoint,
                statusCode: http.statusCode,
                duration: duration,
                responseBytes: data.count,
                requestID: http.value(forHTTPHeaderField: "x-github-request-id")
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OAuthError.failed("GitHub authorization request failed.")
        }
        return data
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func presentDeviceCode(_ code: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let presenter = Self.topViewController() else {
                continuation.resume(throwing: OAuthError.failed("Could not present GitHub authorization."))
                return
            }

            let alert = UIAlertController(
                title: "Connect GitHub",
                message: "Code: \(code)\n\nThe code has been copied. Paste it on the GitHub page, approve access, then return to GitSync.md.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(throwing: OAuthError.cancelled)
            })
            alert.addAction(UIAlertAction(title: "Open GitHub", style: .default) { _ in
                continuation.resume()
            })
            presenter.present(alert, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController

        var current = root
        while let presented = current?.presentedViewController {
            current = presented
        }
        return current
    }
}

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case error
        case errorDescription = "error_description"
    }
}
