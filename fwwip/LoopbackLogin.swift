import Foundation
import Network

/// An IPv4-loopback-only listener, alive only for one user-approved sign-in.
@MainActor
final class LoopbackLogin {
    private let timeoutDuration: Duration
    init(timeoutDuration: Duration = .seconds(180)) { self.timeoutDuration = timeoutDuration }
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var completion: CheckedContinuation<String, Error>?
    private var ready: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var attempt: PKCEAttempt?
    private var result: Result<String, Error>?

    func start(attempt: PKCEAttempt) async throws {
        self.attempt = attempt
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: 53682)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw Self.listenerIssue(error) }
        self.listener = listener
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.ready?.resume(); self.ready = nil
                    case .failed(let error):
                        let issue = Self.listenerIssue(error)
                        self.ready?.resume(throwing: issue); self.ready = nil
                        self.finish(.failure(issue))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            listener.start(queue: .main)
        }
        let duration = timeoutDuration
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: duration); self?.finish(.failure(OAuthIssue.timedOut)) }
            catch { }
        }
    }
    func waitForCode() async throws -> String {
        if let result { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }
    func cancel() { finish(.failure(OAuthIssue.cancelled)) }
    private static func listenerIssue(_ error: Error) -> OAuthIssue {
        guard let error = error as? NWError else { return .portUnavailable }
        switch error {
        case .posix(let code): return .listenerFailure("POSIX \(code.rawValue)")
        case .dns(let code): return .listenerFailure("DNS \(code)")
        case .tls(let code): return .listenerFailure("TLS \(code)")
        default: return .portUnavailable
        }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        connections.append(connection)
        connection.start(queue: .main)
        receive(connection, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                var buffer = accumulated
                buffer.append(data ?? Data())
                if buffer.count > 16384 || error != nil { self.respond(connection, status: "400 Bad Request"); return }
                guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete { self.respond(connection, status: "400 Bad Request") }
                    else { self.receive(connection, accumulated: buffer) }
                    return
                }
                guard let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8),
                      let line = header.components(separatedBy: "\r\n").first else {
                    self.respond(connection, status: "400 Bad Request"); return
                }
                let words = line.split(separator: " ")
                let hosts = header.components(separatedBy: "\r\n").dropFirst().filter { $0.lowercased().hasPrefix("host:") }
                guard words.count == 3, words[0] == "GET", words[2] == "HTTP/1.1", hosts.count == 1,
                      hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:53682",
                      words[1].hasPrefix("/oauth/callback?"),
                      let url = URL(string: "http://127.0.0.1:53682\(words[1])"), let attempt = self.attempt else {
                    self.respond(connection, status: "404 Not Found"); return
                }
                do {
                    let code = try attempt.code(from: url)
                    self.respond(connection, status: "200 OK")
                    self.finish(.success(code), preserve: connection)
                } catch {
                    self.respond(connection, status: "400 Bad Request")
                    self.finish(.failure(error), preserve: connection)
                }
            }
        }
    }
    private func respond(_ connection: NWConnection, status: String) {
        let text = status == "200 OK" ? "FWWIP received the sign-in response. Return to FWWIP to check the connection." : "FWWIP could not accept this response. Return to the app."
        let body = Data(text.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor [weak self] in self?.connections.removeAll { $0 === connection } }
        })
    }
    private func finish(_ result: Result<String, Error>, preserve: NWConnection? = nil) {
        guard self.result == nil else { return }
        self.result = result
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        ready?.resume(throwing: OAuthIssue.cancelled); ready = nil
        for connection in connections where connection !== preserve { connection.cancel() }
        connections.removeAll { $0 !== preserve }
        completion?.resume(with: result); completion = nil
        attempt = nil
    }
}
