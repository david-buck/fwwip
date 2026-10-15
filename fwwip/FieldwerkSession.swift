import Foundation
import AppKit

/// Registration and storage are reached only through the explicit native approval button.
@MainActor
final class FieldwerkSession {
    private let transport: any HTTPTransport
    private let vault = KeychainSession()
    private var tokens: OAuthTokens?
    private var client: PublicOAuthClient?
    private var metadata: OAuthDiscovery?
    private var callback: LoopbackLogin?
    private var remembersSession = false

    init(transport: any HTTPTransport = FieldwerkHTTP()) { self.transport = transport }

    var hasRegisteredClient: Bool {
        guard let data = UserDefaults.standard.data(forKey: OAuthPolicy.clientKey) else { return false }
        return (try? JSONDecoder().decode(PublicOAuthClient.self, from: data).validated()) != nil
    }

    func prepare() async throws -> OAuthDiscovery {
        var request = URLRequest(url: URL(string: "https://mcp.fieldwerk.ai/.well-known/oauth-protected-resource")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let resource = try await checked(request)
        guard let object = try JSONSerialization.jsonObject(with: resource) as? [String: Any],
              object["resource"] as? String == OAuthPolicy.resource,
              object["authorization_servers"] as? [String] == [OAuthPolicy.resource],
              (object["scopes_supported"] as? [String])?.contains(OAuthPolicy.scope) == true else { throw OAuthIssue.invalidDiscovery }
        request.url = URL(string: "https://mcp.fieldwerk.ai/.well-known/oauth-authorization-server")!
        let data = try await checked(request)
        let metadata = try JSONDecoder().decode(OAuthDiscovery.self, from: data).validated()
        self.metadata = metadata
        return metadata
    }

    /// Invoking this method is an explicit user-approved registration/access/storage action.
    func signInAfterApproval(rememberOnDevice: Bool) async throws {
        let metadata: OAuthDiscovery
        if let prepared = self.metadata { metadata = try prepared.validated() }
        else { throw OAuthIssue.invalidDiscovery }
        // This runs only after the explicit storage approval, before any registration or browser round-trip.
        if rememberOnDevice { try vault.verifyPrivateStorage() }
        let attempt = try PKCEAttempt()
        let callback = LoopbackLogin()
        self.callback = callback
        defer { callback.cancel(); self.callback = nil }
        try await callback.start(attempt: attempt)
        try Task.checkCancellation()

        var registered: PublicOAuthClient?
        if let data = UserDefaults.standard.data(forKey: OAuthPolicy.clientKey) {
            registered = try? JSONDecoder().decode(PublicOAuthClient.self, from: data).validated()
        }
        if registered == nil {
            var request = URLRequest(url: metadata.registration_endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_name": "FWWIP", "redirect_uris": [OAuthPolicy.callback.absoluteString],
                "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                "token_endpoint_auth_method": "none", "scope": OAuthPolicy.scope
            ])
            // Exactly one registration attempt. Network uncertainty is surfaced, never automatically retried.
            let data = try await checked(request)
            do { registered = try JSONDecoder().decode(PublicOAuthClient.self, from: data).validated() }
            catch { throw OAuthIssue.invalidRegistration }
            UserDefaults.standard.set(try JSONEncoder().encode(registered!), forKey: OAuthPolicy.clientKey)
        }
        guard let client = registered else { throw OAuthIssue.invalidRegistration }
        self.client = client
        try Task.checkCancellation()
        let url = try attempt.authorizationURL(metadata: metadata, client: client)
        guard NSWorkspace.shared.open(url) else { throw OAuthIssue.cancelled }
        let code = try await callback.waitForCode()
        let received = try await exchange(metadata: metadata, values: [
            "grant_type": "authorization_code", "client_id": client.client_id,
            "redirect_uri": OAuthPolicy.callback.absoluteString,
            "code": code, "code_verifier": attempt.verifier, "resource": OAuthPolicy.resource
        ])
        let fresh = try received.session()
        if Task.isCancelled {
            await revoke(fresh, metadata: metadata)
            throw OAuthIssue.cancelled
        }
        remembersSession = rememberOnDevice
        if rememberOnDevice {
            do { try vault.save(fresh) }
            catch {
                await revoke(fresh, metadata: metadata)
                throw error
            }
            UserDefaults.standard.set(true, forKey: OAuthPolicy.persistenceFlag)
        } else {
            // Explicit memory-only choice removes any older FWWIP token item.
            if UserDefaults.standard.bool(forKey: OAuthPolicy.persistenceFlag) { try vault.delete() }
            UserDefaults.standard.removeObject(forKey: OAuthPolicy.persistenceFlag)
        }
        tokens = fresh
    }

    func restorePreviouslyApprovedSession() throws -> Bool {
        guard UserDefaults.standard.bool(forKey: OAuthPolicy.persistenceFlag),
              let data = UserDefaults.standard.data(forKey: OAuthPolicy.clientKey) else { return false }
        client = try JSONDecoder().decode(PublicOAuthClient.self, from: data).validated()
        tokens = try vault.load()
        remembersSession = tokens != nil
        return tokens != nil
    }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let saved = tokens else { throw OAuthIssue.signedOut }
        if !saved.needsRefresh() && !forceRefresh { return saved.access }
        guard let refresh = saved.refresh, let client else { throw OAuthIssue.signedOut }
        let metadata: OAuthDiscovery
        if let known = self.metadata { metadata = known } else { metadata = try await prepare() }
        do {
            let reply = try await exchange(metadata: metadata, values: [
                "grant_type": "refresh_token", "refresh_token": refresh,
                "client_id": client.client_id, "resource": OAuthPolicy.resource
            ])
            let fresh = try reply.session(previousRefresh: refresh)
            tokens = fresh
            if remembersSession { try vault.save(fresh) }
            return fresh.access
        } catch let issue as OAuthIssue {
            // Do not discard credentials on a transient network failure. Invalid grants require new consent.
            if case .rejected(let code) = issue, code == "invalid_grant" || code == "invalid_client" {
                tokens = nil
                if remembersSession {
                    do { try vault.delete() }
                    catch { throw OAuthIssue.expiredCleanup }
                }
                remembersSession = false
                UserDefaults.standard.removeObject(forKey: OAuthPolicy.persistenceFlag)
            }
            throw issue
        }
    }

    func logout() async throws -> Bool {
        cancelSignIn()
        let previous = tokens
        tokens = nil
        // Attempt both local deletion and remote revocation, even if one fails.
        var storageFailed = false
        if remembersSession || UserDefaults.standard.bool(forKey: OAuthPolicy.persistenceFlag) {
            do { try vault.delete() } catch { storageFailed = true }
        }
        if !storageFailed {
            remembersSession = false
            UserDefaults.standard.removeObject(forKey: OAuthPolicy.persistenceFlag)
        }
        var revoked = previous == nil
        if let previous {
            do {
                let metadata: OAuthDiscovery
                if let known = self.metadata { metadata = known } else { metadata = try await prepare() }
                revoked = await revoke(previous, metadata: metadata)
            } catch { revoked = false }
        }
        if storageFailed { throw OAuthIssue.storage }
        return revoked
    }

    func cancelSignIn() { callback?.cancel() }

    private func exchange(metadata: OAuthDiscovery, values: [String: String]) async throws -> OAuthTokenReply {
        var request = URLRequest(url: metadata.token_endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthForm.encode(values)
        return try JSONDecoder().decode(OAuthTokenReply.self, from: await checked(request))
    }
    @discardableResult private func revoke(_ tokens: OAuthTokens, metadata: OAuthDiscovery) async -> Bool {
        guard let endpoint = metadata.revocation_endpoint, let client else { return false }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthForm.encode(["token": tokens.refresh ?? tokens.access,
            "token_type_hint": tokens.refresh == nil ? "access_token" : "refresh_token", "client_id": client.client_id])
        do { _ = try await checked(request); return true } catch { return false }
    }
    private func checked(_ request: URLRequest) async throws -> Data {
        let reply = try await transport.send(request, rpcID: nil)
        guard (200..<300).contains(reply.status) else {
            if let object = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
               let error = object["error"] as? String,
               error.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil { throw OAuthIssue.rejected(error) }
            throw OAuthIssue.network(reply.status)
        }
        return reply.data
    }
}
