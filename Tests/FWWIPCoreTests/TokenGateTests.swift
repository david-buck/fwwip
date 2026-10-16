import XCTest
@testable import FWWIPCore

@MainActor final class TokenGateTests: XCTestCase {
    func testConcurrentRequestsShareOneRefreshWithoutRealCredentials() async throws {
        let gate = AccessTokenGate()
        var calls = 0
        let fetch: @MainActor (Bool) async throws -> String = { _ in
            calls += 1
            await Task.yield()
            return "synthetic-token"
        }
        let tasks = (0..<3).map { _ in Task { try await gate.value(forceRefresh: true, fetch: fetch) } }
        for task in tasks { let value = try await task.value; XCTAssertEqual(value, "synthetic-token") }
        XCTAssertEqual(calls, 1)
    }
    func testFailedRefreshDoesNotPoisonNextRequest() async throws {
        let gate = AccessTokenGate()
        do { _ = try await gate.value { _ in throw OAuthIssue.network(503) }; XCTFail("Must fail") } catch {}
        let value = try await gate.value { _ in "synthetic-recovered-token" }
        XCTAssertEqual(value, "synthetic-recovered-token")
    }
}
