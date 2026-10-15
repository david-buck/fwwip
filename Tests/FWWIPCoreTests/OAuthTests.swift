import XCTest
@testable import FWWIPCore

private let metadataJSON = Data(#"{"issuer":"https://mcp.fieldwerk.ai","authorization_endpoint":"https://mcp.fieldwerk.ai/oauth/authorize","token_endpoint":"https://mcp.fieldwerk.ai/oauth/token","revocation_endpoint":"https://mcp.fieldwerk.ai/oauth/revoke","registration_endpoint":"https://mcp.fieldwerk.ai/oauth/register","response_types_supported":["code"],"grant_types_supported":["authorization_code","refresh_token"],"code_challenge_methods_supported":["S256"],"token_endpoint_auth_methods_supported":["none"],"scopes_supported":["memos:rw"]}"#.utf8)

final class OAuthTests: XCTestCase {
    func testPKCEMatchesRFC7636Vector() throws {
        let attempt = PKCEAttempt(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "test")
        XCTAssertEqual(attempt.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let random = try PKCEAttempt(), another = try PKCEAttempt()
        XCTAssertEqual(random.verifier.count, 43)
        XCTAssertEqual(random.state.count, 43)
        XCTAssertNotEqual(random.verifier, another.verifier)
        XCTAssertNotEqual(random.state, another.state)
    }
    func testAuthorizationRequestBindsResourceCallbackClientStateAndPKCE() throws {
        let metadata = try JSONDecoder().decode(OAuthDiscovery.self, from: metadataJSON).validated()
        let client = PublicOAuthClient(client_id: "example-client", redirect_uris: [OAuthPolicy.callback.absoluteString], token_endpoint_auth_method: "none", client_secret: nil)
        let attempt = PKCEAttempt(verifier: "verifier", state: "state")
        let url = try attempt.authorizationURL(metadata: metadata, client: client)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        XCTAssertEqual(url.host, "mcp.fieldwerk.ai")
        XCTAssertEqual(values["resource"], "https://mcp.fieldwerk.ai")
        XCTAssertEqual(values["redirect_uri"], OAuthPolicy.callback.absoluteString)
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["code_challenge"], attempt.challenge)
        XCTAssertEqual(values["scope"], "memos:rw")
        XCTAssertEqual(values["state"], "state")
    }
    func testCallbackAcceptsOnlyExactBoundRedirectAndSingleValues() throws {
        let attempt = PKCEAttempt(verifier: "verifier", state: "expected")
        let prefix = OAuthPolicy.callback.absoluteString
        XCTAssertEqual(try attempt.code(from: URL(string: prefix + "?code=ok&state=expected")!), "ok")
        let invalid = [
            "http://localhost:53682/oauth/callback?code=ok&state=expected",
            "http://127.0.0.1:53683/oauth/callback?code=ok&state=expected",
            "http://127.0.0.1:53682/other?code=ok&state=expected",
            "http://user@127.0.0.1:53682/oauth/callback?code=ok&state=expected",
            prefix + "?code=ok&state=wrong", prefix + "?code=ok&state=expected&state=expected",
            prefix + "?code=ok&code=other&state=expected", prefix + "?code=&state=expected",
            prefix + "?code=ok&state=expected#fragment", prefix + "?code=ok&state=expected&iss=https://evil.example",
            prefix + "?code=ok&state=expected&iss", prefix + "?code=ok&state=expected&error=access_denied"
        ]
        for url in invalid { XCTAssertThrowsError(try attempt.code(from: URL(string: url)!)) }
        XCTAssertThrowsError(try attempt.code(from: URL(string: prefix + "?error=access_denied&state=expected")!)) {
            XCTAssertEqual($0 as? OAuthIssue, .cancelled)
        }
        XCTAssertThrowsError(try attempt.code(from: URL(string: prefix + "?error=invalid_redirect_uri&state=expected")!)) {
            XCTAssertEqual($0 as? OAuthIssue, .rejected("invalid_redirect_uri"))
        }
    }
    func testDiscoveryAndEndpointsCannotRedirectCredentials() throws {
        XCTAssertNoThrow(try JSONDecoder().decode(OAuthDiscovery.self, from: metadataJSON).validated())
        for value in ["http://mcp.fieldwerk.ai/oauth/token", "https://mcp.fieldwerk.ai.evil.example/token", "https://user@mcp.fieldwerk.ai/token", "https://mcp.fieldwerk.ai:444/token", "https://mcp.fieldwerk.ai/token?query=x"] {
            XCTAssertFalse(OAuthPolicy.trusted(URL(string: value)!))
        }
        let foreign = String(decoding: metadataJSON, as: UTF8.self).replacingOccurrences(of: "https://mcp.fieldwerk.ai/oauth/token", with: "https://evil.example/token")
        XCTAssertThrowsError(try JSONDecoder().decode(OAuthDiscovery.self, from: Data(foreign.utf8)).validated())
        let noPKCE = String(decoding: metadataJSON, as: UTF8.self).replacingOccurrences(of: "S256", with: "plain")
        XCTAssertThrowsError(try JSONDecoder().decode(OAuthDiscovery.self, from: Data(noPKCE.utf8)).validated())
    }
    func testRegistrationMustConfirmPublicClientAndExactApprovedCallback() throws {
        let callback = OAuthPolicy.callback.absoluteString
        XCTAssertNoThrow(try PublicOAuthClient(client_id: "id", redirect_uris: [callback], token_endpoint_auth_method: "none", client_secret: nil).validated())
        for client in [
            PublicOAuthClient(client_id: "", redirect_uris: [callback], token_endpoint_auth_method: "none", client_secret: nil),
            PublicOAuthClient(client_id: "id", redirect_uris: ["http://127.0.0.1:1/oauth/callback"], token_endpoint_auth_method: "none", client_secret: nil),
            PublicOAuthClient(client_id: "id", redirect_uris: [callback], token_endpoint_auth_method: "client_secret_basic", client_secret: nil),
            PublicOAuthClient(client_id: "id", redirect_uris: [callback], token_endpoint_auth_method: "none", client_secret: "unexpected")
        ] { XCTAssertThrowsError(try client.validated()) }
    }
    func testExpiryRefreshRotationAndScopeValidation() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let reply = OAuthTokenReply(access_token: "test-access", token_type: "Bearer", expires_in: 120, refresh_token: nil, scope: "memos:rw")
        let session = try reply.session(previousRefresh: "previous-test-refresh", now: now)
        XCTAssertEqual(session.refresh, "previous-test-refresh")
        XCTAssertFalse(session.needsRefresh(at: now))
        XCTAssertTrue(session.needsRefresh(at: now.addingTimeInterval(61)))
        let rotated = OAuthTokenReply(access_token: "new-test-access", token_type: "Bearer", expires_in: 300, refresh_token: "rotated-test-refresh", scope: nil)
        XCTAssertEqual(try rotated.session(previousRefresh: "old").refresh, "rotated-test-refresh")
        for scope in ["admin", "memos:rw admin", ""] {
            XCTAssertThrowsError(try OAuthTokenReply(access_token: "test", token_type: "Bearer", expires_in: 300, refresh_token: nil, scope: scope).session())
        }
        XCTAssertThrowsError(try OAuthTokenReply(access_token: "test\r\nInjected: header", token_type: "Bearer", expires_in: 300, refresh_token: nil, scope: nil).session())
        XCTAssertThrowsError(try OAuthTokenReply(access_token: "test", token_type: "Bearer", expires_in: 300, refresh_token: "", scope: nil).session())
        XCTAssertThrowsError(try OAuthTokenReply(access_token: "test", token_type: "Basic", expires_in: 300, refresh_token: nil, scope: nil).session())
        XCTAssertThrowsError(try OAuthTokenReply(access_token: "test", token_type: "Bearer", expires_in: 0, refresh_token: nil, scope: nil).session())
    }
    func testFormEncodingDoesNotReinterpretCodes() {
        let data = OAuthForm.encode(["code": "a+b&c= d"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "code=a%2Bb%26c%3D%20d")
    }
    func testRPCRejectsNotificationsWrongIDsBooleansAndErrors() throws {
        XCTAssertTrue(RPCCodec.matches(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8), id: 1))
        for json in [#"{"jsonrpc":"2.0","id":2,"result":{}}"#, #"{"jsonrpc":"2.0","id":true,"result":{}}"#, #"{"jsonrpc":"2.0","method":"notice"}"#] {
            XCTAssertFalse(RPCCodec.matches(Data(json.utf8), id: 1))
        }
        let error = HTTPReply(data: Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-1}}"#.utf8), status: 200, headers: [:])
        XCTAssertThrowsError(try RPCCodec.result(error, id: 1))
        XCTAssertThrowsError(try RPCCodec.toolData(["isError": true, "content": []]))
    }
    func testLiveProjectionKeepsCanonicalIdentityAndUnknownEvidence() throws {
        let data = Data(#"{"id":"canonical","title":"Heading fallback","url":"https://my.fieldwerk.ai/m/canonical","updated_at":"2026-10-15T10:00:00Z","fields":{"title":"Authored title","project":"Personal","status":"Doing","sync":"No action","estimate":3,"labels":["x"]}}"#.utf8)
        let item = try JSONDecoder().decode(FieldwerkCard.self, from: data).projected()
        XCTAssertEqual(item.id, "canonical")
        XCTAssertEqual(item.title, "Authored title")
        XCTAssertEqual(item.state, "Doing")
        XCTAssertNil(item.update)
        XCTAssertEqual(item.attention, .unknown)
        XCTAssertNil(item.conversationURL)
        let badLink = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "https://my.fieldwerk.ai/m/canonical", with: "https://evil.example/m/canonical")
        XCTAssertThrowsError(try JSONDecoder().decode(FieldwerkCard.self, from: Data(badLink.utf8)).projected())
    }
    @MainActor func testPreparationDoesNotRegisterGrantOrStoreAnything() async throws {
        let mock = FakeHTTP(replies: [
            HTTPReply(data: Data(#"{"resource":"https://mcp.fieldwerk.ai","authorization_servers":["https://mcp.fieldwerk.ai"],"scopes_supported":["memos:rw"]}"#.utf8), status: 200, headers: [:]),
            HTTPReply(data: metadataJSON, status: 200, headers: [:])
        ])
        _ = try await FieldwerkSession(transport: mock).prepare()
        let requests = await mock.recorded()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil && $0.value(forHTTPHeaderField: "Authorization") == nil })
    }
    @MainActor func testReadToolBoundaryRejectsWritesBeforeNetworkOrLogin() async throws {
        let mock = FakeHTTP(replies: [])
        let reader = FieldwerkReader(session: FieldwerkSession(transport: mock), transport: mock)
        do {
            _ = try await reader.call("set_field", arguments: [:])
            XCTFail("Write tool must be blocked")
        } catch { XCTAssertEqual(error as? OAuthIssue, .rejected("write_tool_blocked")) }
        let requests = await mock.recorded()
        XCTAssertTrue(requests.isEmpty)
    }
}

private actor FakeHTTP: HTTPTransport {
    private var replies: [HTTPReply]
    private var requests: [URLRequest] = []
    init(replies: [HTTPReply]) { self.replies = replies }
    func send(_ request: URLRequest, rpcID: Int?) async throws -> HTTPReply {
        requests.append(request)
        guard !replies.isEmpty else { throw OAuthIssue.network(0) }
        return replies.removeFirst()
    }
    func recorded() -> [URLRequest] { requests }
}
