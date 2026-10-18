import Foundation

nonisolated struct HTTPReply: Sendable {
    let data: Data
    let status: Int
    let headers: [String: String]
}

nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, rpcID: Int?) async throws -> HTTPReply
}

nonisolated final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated final class FieldwerkHTTP: HTTPTransport {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 40
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    func send(_ request: URLRequest, rpcID: Int? = nil) async throws -> HTTPReply {
        guard let url = request.url, OAuthPolicy.trusted(url) else { throw OAuthIssue.invalidDiscovery }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw OAuthIssue.network(0) }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
        }
        var data = Data()
        if headers["content-type"]?.contains("text/event-stream") == true, let rpcID {
            var event: [String] = []
            var totalBytes = 0
            for try await line in bytes.lines {
                try Task.checkCancellation()
                totalBytes += line.utf8.count + 1
                guard totalBytes < 2_000_000 else { throw OAuthIssue.network(413) }
                if line.isEmpty {
                    if !event.isEmpty {
                        let payload = Data(event.joined(separator: "\n").utf8)
                        if RPCCodec.matches(payload, id: rpcID) { data = payload; break }
                        event.removeAll()
                    }
                } else if line.hasPrefix("data:") {
                    event.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                }
            }
            if data.isEmpty, !event.isEmpty {
                let payload = Data(event.joined(separator: "\n").utf8)
                if RPCCodec.matches(payload, id: rpcID) { data = payload }
            }
        } else {
            for try await byte in bytes {
                data.append(byte)
                guard data.count < 2_000_000 else { throw OAuthIssue.network(413) }
            }
        }
        return HTTPReply(data: data, status: response.statusCode, headers: headers)
    }
}

nonisolated enum RPCCodec {
    static let readTools: Set<String> = ["list_workspaces", "list_collections", "list_collection_memos", "get_memo", "list_views", "get_collection", "list_my_memos"]
    static func matches(_ data: Data, id: Int) -> Bool {
        struct Identity: Decodable { let id: Int; let jsonrpc: String }
        guard let identity = try? JSONDecoder().decode(Identity.self, from: data) else { return false }
        return identity.id == id && identity.jsonrpc == "2.0"
    }
    static func result(_ reply: HTTPReply, id: Int) throws -> [String: Any] {
        guard (200..<300).contains(reply.status) else { throw OAuthIssue.network(reply.status) }
        guard matches(reply.data, id: id),
              let object = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
              object["error"] == nil, let result = object["result"] as? [String: Any] else { throw OAuthIssue.rejected("invalid_mcp_response") }
        return result
    }
    static func toolData(_ result: [String: Any]) throws -> Data {
        guard result["isError"] as? Bool != true else { throw OAuthIssue.rejected("fieldwerk_read_failed") }
        if let structured = result["structuredContent"] as? [String: Any] {
            return try JSONSerialization.data(withJSONObject: structured)
        }
        guard let content = result["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { throw OAuthIssue.rejected("invalid_tool_data") }
        return data
    }
}
