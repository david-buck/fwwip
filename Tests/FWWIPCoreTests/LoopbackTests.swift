import XCTest
@testable import FWWIPCore

final class LoopbackTests: XCTestCase {
    @MainActor func testCallbackRoundTripAndCleanup() async throws {
        let listener = LoopbackLogin()
        defer { listener.cancel() }
        try await listener.start(attempt: PKCEAttempt(verifier: "test-verifier", state: "integration-state"))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let http = URLSession(configuration: config)
        defer { http.invalidateAndCancel() }
        let (_, response) = try await http.data(from: URL(string: "http://127.0.0.1:53682/oauth/callback?code=integration-code&state=integration-state")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let code = try await listener.waitForCode()
        XCTAssertEqual(code, "integration-code")
        try await Task.sleep(for: .milliseconds(50))
        let replacement = LoopbackLogin()
        try await replacement.start(attempt: PKCEAttempt())
        replacement.cancel()
    }
    @MainActor func testInvalidStateClosesListenerAndReleasesPort() async throws {
        let listener = LoopbackLogin()
        defer { listener.cancel() }
        try await listener.start(attempt: PKCEAttempt(verifier: "test-verifier", state: "expected-state"))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let http = URLSession(configuration: config)
        defer { http.invalidateAndCancel() }
        let (_, response) = try await http.data(from: URL(string: "http://127.0.0.1:53682/oauth/callback?code=synthetic-code&state=wrong-state")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        do { _ = try await listener.waitForCode(); XCTFail("Invalid state must fail the attempt") }
        catch { XCTAssertEqual(error as? OAuthIssue, .invalidCallback) }
        try await Task.sleep(for: .milliseconds(50))
        let replacement = LoopbackLogin()
        try await replacement.start(attempt: PKCEAttempt())
        replacement.cancel()
    }
    @MainActor func testOSReportsOneIPv4LoopbackListener() async throws {
        let listener = LoopbackLogin()
        defer { listener.cancel() }
        try await listener.start(attempt: PKCEAttempt())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(ProcessInfo.processInfo.processIdentifier), "-iTCP:53682", "-sTCP:LISTEN", "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let addresses = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("n") }
        XCTAssertEqual(addresses.map(String.init), ["n127.0.0.1:53682"])
    }
    @MainActor func testCancellationReleasesPort() async throws {
        let listener = LoopbackLogin()
        try await listener.start(attempt: PKCEAttempt())
        listener.cancel()
        do { _ = try await listener.waitForCode(); XCTFail("Cancellation must complete the wait") }
        catch { XCTAssertEqual(error as? OAuthIssue, .cancelled) }
        try await Task.sleep(for: .milliseconds(50))
        let replacement = LoopbackLogin()
        try await replacement.start(attempt: PKCEAttempt())
        replacement.cancel()
    }
    @MainActor func testTimeoutReleasesPort() async throws {
        let listener = LoopbackLogin(timeoutDuration: .milliseconds(50))
        try await listener.start(attempt: PKCEAttempt())
        do { _ = try await listener.waitForCode(); XCTFail("Timeout must complete the wait") }
        catch { XCTAssertEqual(error as? OAuthIssue, .timedOut) }
        try await Task.sleep(for: .milliseconds(50))
        let replacement = LoopbackLogin()
        try await replacement.start(attempt: PKCEAttempt())
        replacement.cancel()
    }
}
