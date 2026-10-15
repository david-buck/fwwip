import Foundation
import CryptoKit
import Security

nonisolated enum OAuthIssue: Error, LocalizedError, Equatable {
    case invalidDiscovery, invalidRegistration, invalidCallback, invalidToken, cancelled, timedOut
    case network(Int), rejected(String), listenerFailure(String), portUnavailable, storageStatus(Int32), storage, expiredCleanup, signedOut, noWorkspace, noBacklog
    var errorDescription: String? {
        switch self {
        case .invalidDiscovery: "Fieldwerk’s connection metadata did not pass validation."
        case .invalidRegistration: "Fieldwerk did not confirm FWWIP’s public client and exact callback. No alternate callback was tried."
        case .invalidCallback: "The sign-in callback failed validation. Please start a new sign-in."
        case .invalidToken: "Fieldwerk returned an unusable token or an unexpected scope. Please sign in again."
        case .cancelled: "Sign-in was cancelled."
        case .timedOut: "Sign-in timed out. Please try again when ready."
        case .network(let code): "Fieldwerk request failed (HTTP \(code))."
        case .rejected(let code): "Fieldwerk rejected the request: \(code)."
        case .listenerFailure(let code): "FWWIP could not start its loopback sign-in listener (\(code)). No client was registered."
        case .portUnavailable: "FWWIP’s local sign-in port is unavailable. Close any other FWWIP sign-in and try again."
        case .storageStatus(let status): "macOS rejected FWWIP’s private Keychain operation (OSStatus \(status))."
        case .storage: "FWWIP could not access its own Keychain item. No task data was saved."
        case .expiredCleanup: "Sign-in expired, but saved-token removal failed. Use Remove saved sign-in to retry."
        case .signedOut: "Sign in to Fieldwerk to load your work."
        case .noWorkspace: "Choose a Fieldwerk workspace to load work."
        case .noBacklog: "This workspace has no accessible Backlog collection."
        }
    }
}

nonisolated enum OAuthPolicy {
    static let issuer = URL(string: "https://mcp.fieldwerk.ai")!
    static let resource = issuer.absoluteString
    static let endpoint = URL(string: "https://mcp.fieldwerk.ai/mcp")!
    // Fixed so registration, authorization, exchange and future sessions use exactly the same URI.
    static let callback = URL(string: "http://127.0.0.1:53682/oauth/callback")!
    static let scope = "memos:rw"
    static let keychainService = "devplaceholder.LSYURHCQ.fwwip.fieldwerk.oauth"
    static let persistenceFlag = "FWWIP.approvedDeviceKeychain.v1"
    static let clientKey = "FWWIP.publicClient.v1"

    static func trusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == issuer.host && (url.port == nil || url.port == 443)
        && url.user == nil && url.password == nil && url.fragment == nil && url.query == nil
    }
}

nonisolated struct OAuthDiscovery: Codable, Sendable {
    let issuer: URL
    let authorization_endpoint: URL
    let token_endpoint: URL
    let registration_endpoint: URL
    let revocation_endpoint: URL?
    let response_types_supported: [String]
    let grant_types_supported: [String]
    let code_challenge_methods_supported: [String]
    let token_endpoint_auth_methods_supported: [String]
    let scopes_supported: [String]

    func validated() throws -> Self {
        guard issuer == OAuthPolicy.issuer,
              [authorization_endpoint, token_endpoint, registration_endpoint].allSatisfy(OAuthPolicy.trusted),
              revocation_endpoint.map(OAuthPolicy.trusted) ?? true,
              response_types_supported.contains("code"), grant_types_supported.contains("authorization_code"),
              code_challenge_methods_supported.contains("S256"),
              token_endpoint_auth_methods_supported.contains("none"),
              scopes_supported.contains(OAuthPolicy.scope) else { throw OAuthIssue.invalidDiscovery }
        return self
    }
}

nonisolated struct PublicOAuthClient: Codable, Sendable, Equatable {
    let client_id: String
    let redirect_uris: [String]
    let token_endpoint_auth_method: String?
    let client_secret: String?

    func validated() throws -> Self {
        guard !client_id.isEmpty, client_id.utf8.count < 4096,
              redirect_uris == [OAuthPolicy.callback.absoluteString],
              token_endpoint_auth_method == "none", client_secret == nil else { throw OAuthIssue.invalidRegistration }
        return self
    }
}

nonisolated struct PKCEAttempt: Sendable {
    let verifier: String
    let state: String
    var challenge: String { Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    init() throws {
        verifier = try Self.random()
        state = try Self.random()
    }
    init(verifier: String, state: String) { self.verifier = verifier; self.state = state }
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw OAuthIssue.invalidToken }
        return base64url(Data(bytes))
    }
    func authorizationURL(metadata: OAuthDiscovery, client: PublicOAuthClient) throws -> URL {
        _ = try metadata.validated(); _ = try client.validated()
        var parts = URLComponents(url: metadata.authorization_endpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: client.client_id),
            .init(name: "redirect_uri", value: OAuthPolicy.callback.absoluteString),
            .init(name: "scope", value: OAuthPolicy.scope), .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "resource", value: OAuthPolicy.resource)
        ]
        return parts.url!
    }
    func code(from url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", parts.port == 53682,
              parts.percentEncodedPath == "/oauth/callback", parts.user == nil, parts.password == nil,
              parts.fragment == nil else { throw OAuthIssue.invalidCallback }
        let items = parts.queryItems ?? []
        func single(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard let returnedState = single("state"), Self.constantEqual(returnedState, state),
              items.filter({ $0.name == "iss" }).count <= 1,
              (!items.contains(where: { $0.name == "iss" }) || single("iss") == OAuthPolicy.resource) else { throw OAuthIssue.invalidCallback }
        if items.contains(where: { $0.name == "error" }) {
            guard let code = single("error"), !items.contains(where: { $0.name == "code" }),
                  code.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil else { throw OAuthIssue.invalidCallback }
            if code == "access_denied" { throw OAuthIssue.cancelled }
            throw OAuthIssue.rejected(code)
        }
        guard let code = single("code"), !code.isEmpty, code.utf8.count < 8192 else { throw OAuthIssue.invalidCallback }
        return code
    }
    private static func constantEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

nonisolated struct OAuthTokenReply: Decodable, Sendable {
    let access_token: String
    let token_type: String
    let expires_in: Double
    let refresh_token: String?
    let scope: String?
    func session(previousRefresh: String? = nil, now: Date = .now) throws -> OAuthTokens {
        guard !access_token.isEmpty, access_token.utf8.count < 65536,
              access_token.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }),
              refresh_token.map({ !$0.isEmpty && $0.utf8.count < 65536 && $0.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e } }) ?? true,
              token_type.lowercased() == "bearer", expires_in.isFinite, expires_in > 0,
              expires_in <= 366 * 86400,
              scope.map({ Set($0.split(separator: " ").map(String.init)) == [OAuthPolicy.scope] }) ?? true else {
            throw OAuthIssue.invalidToken
        }
        return OAuthTokens(access: access_token, refresh: refresh_token ?? previousRefresh,
                           expiresAt: now.addingTimeInterval(expires_in))
    }
}

nonisolated struct OAuthTokens: Codable, Sendable {
    let access: String
    let refresh: String?
    let expiresAt: Date
    func needsRefresh(at date: Date = .now) -> Bool { expiresAt.timeIntervalSince(date) <= 60 }
}

nonisolated enum OAuthForm {
    static func encode(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
}
