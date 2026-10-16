import Foundation

nonisolated protocol WorkReading: Sendable {
    func currentWork() async throws -> [WorkItem]
}
nonisolated enum FieldwerkReadError: Error, LocalizedError {
    case nativeAuthorizationNotConfigured
    case unsupportedBoard(String, URL?)
    var errorDescription: String? {
        switch self {
        case .nativeAuthorizationNotConfigured: "Connect to Fieldwerk to read work."
        case .unsupportedBoard(let message, _): message
        }
    }
}
nonisolated struct UnconnectedFieldwerkReader: WorkReading {
    func currentWork() async throws -> [WorkItem] { throw FieldwerkReadError.nativeAuthorizationNotConfigured }
}

nonisolated struct WorkspaceChoice: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

nonisolated enum WorkspaceSelection {
    static func resolvedID(preferredID: String?, workspaces: [WorkspaceChoice]) -> String? {
        if let preferredID, workspaces.contains(where: { $0.id == preferredID }) { return preferredID }
        return workspaces.first?.id
    }
}

nonisolated struct CollectionChoice: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

nonisolated enum CollectionSelection {
    static func resolvedID(preferredID: String?, collections: [CollectionChoice]) -> String? {
        if let preferredID, collections.contains(where: { $0.id == preferredID }) { return preferredID }
        return collections.first(where: { $0.name == "Backlog" })?.id ?? collections.first?.id
    }
}

nonisolated struct FieldwerkCard: Decodable, Sendable {
    let id: String
    let title: String
    let url: URL
    let fields: [String: String]?
    let collectionFields: [String: String]
    private(set) var canonicalFields: [String: String]?
    let archived_at: String?
    var metadata: WIPMetadata?

    private enum CodingKeys: String, CodingKey { case id, title, url, fields, archived_at, collection_fields }
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        url = try values.decode(URL.self, forKey: .url)
        archived_at = try values.decodeIfPresent(String.self, forKey: .archived_at)
        metadata = try? values.decode(WIPMetadata.self, forKey: .fields)
        canonicalFields = nil
        if let nested = try? values.nestedContainer(keyedBy: Key.self, forKey: .collection_fields) {
            collectionFields = nested.allKeys.reduce(into: [:]) { result, key in
                if let value = try? nested.decode(String.self, forKey: key) { result[key.stringValue] = value }
            }
        } else { collectionFields = [:] }

        if let nested = try? values.nestedContainer(keyedBy: Key.self, forKey: .fields) {
            fields = nested.allKeys.reduce(into: [:]) { result, key in
                if let value = try? nested.decode(String.self, forKey: key) { result[key.stringValue] = value }
            }
        } else { fields = nil }
    }

    func projected(now: Date = .now) throws -> WorkItem {
        guard url.scheme == "https", url.host == "my.fieldwerk.ai", url.path == "/m/\(id)",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw OAuthIssue.rejected("invalid_canonical_link")
        }
        // Only explicit WIP properties supply evidence. Activity/status/sync cannot create an action request.
        let wip = metadata?.projected(now: now)
        return WorkItem(id: id, title: fields?["title"] ?? title, project: fields?["project"] ?? "Project unverified",
                        state: fields?["status"] ?? "Status unverified", update: wip?.update, attention: wip?.attention ?? .unknown,
                        taskURL: url, conversationURL: wip?.conversationURL,
                        verifiedAt: wip?.verifiedAt, evidenceURL: wip?.evidenceURL)
    }

    mutating func useCanonicalMetadata(_ data: Data) throws {
        struct CanonicalMetadata: Decodable { let fields: WIPMetadata? }
        struct RawFields: Decodable { let fields: [String: BoardValue]? }
        metadata = try JSONDecoder().decode(CanonicalMetadata.self, from: data).fields
        canonicalFields = try JSONDecoder().decode(RawFields.self, from: data).fields?.compactMapValues(\.string) ?? [:]
    }
    func groupValue(field: String, scope: String?) -> String {
        let value: String?
        switch scope {
        case "memo": value = (canonicalFields ?? fields)?[field]
        case "collection": value = collectionFields[field]
        default: value = fields?[field]
        }
        return value ?? ""
    }
}

/// A session-specific Streamable HTTP reader with a hard read-tool allowlist.
@MainActor
final class FieldwerkReader: BoardMoveAccess {
    private let session: FieldwerkSession
    private let transport: any HTTPTransport
    private var sessionID: String?
    private var nextID = 0
    private var initialized = false
    private let tokenGate = AccessTokenGate()
    init(session: FieldwerkSession, transport: any HTTPTransport = FieldwerkHTTP()) {
        self.session = session; self.transport = transport
    }
    func reset() { sessionID = nil; initialized = false }
    func workspaces() async throws -> [WorkspaceChoice] {
        struct Reply: Decodable { let workspaces: [WorkspaceChoice] }
        return try JSONDecoder().decode(Reply.self, from: await call("list_workspaces", arguments: [:])).workspaces
    }
    func collections(in workspace: WorkspaceChoice) async throws -> [CollectionChoice] {
        struct Reply: Decodable { let collections: [CollectionChoice] }
        return try JSONDecoder().decode(Reply.self, from: await call("list_collections", arguments: ["workspace": workspace.id])).collections
    }
    func work(in collection: CollectionChoice) async throws -> BoardSnapshot {
        struct FieldDefinition: Decodable {
            struct Option: Decodable { let label: String }
            let field_name: String
            let field_type: String?
            let options: [Option]?
        }
        struct Details: Decodable { let views: [BoardDefinition]; let field_definitions: [FieldDefinition] }
        let details = try JSONDecoder().decode(Details.self, from: await call("get_collection", arguments: ["collection": collection.id]))
        guard let board = BoardDefinition.preferred(in: details.views) else {
            throw FieldwerkReadError.unsupportedBoard("This collection has no board view.", nil)
        }
        guard board.sort == nil else {
            throw FieldwerkReadError.unsupportedBoard("This board has a custom sort that FWWIP does not support yet.", board.safeURL)
        }
        guard board.include_files != true else {
            throw FieldwerkReadError.unsupportedBoard("This board includes files; FWWIP currently supports memo-only boards.", board.safeURL)
        }
        struct Cards: Decodable { let memos: [FieldwerkCard] }
        var cards: [FieldwerkCard] = []
        var offset = 0
        var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            let data = try await call("list_collection_memos", arguments: [
                "collection": collection.id, "include_fields": true, "limit": 1000, "offset": offset,
                "where": board.where.map(\.json)
            ])
            let page = try JSONDecoder().decode(Cards.self, from: data).memos
            let fresh = page.filter { seen.insert($0.id).inserted }
            if page.count == 1000 && fresh.isEmpty { throw OAuthIssue.rejected("pagination_did_not_advance") }
            cards.append(contentsOf: fresh)
            offset += page.count
            if page.count < 1000 { break }
        }
        for index in cards.indices where cards[index].metadata?.isPresent == true ||
            (board.group_by_scope == "memo" && cards[index].collectionFields[board.group_by ?? ""] != nil) {
            let raw = try await call("get_memo", arguments: ["id": cards[index].id])
            try cards[index].useCanonicalMetadata(raw)
        }
        let options = details.field_definitions.first(where: { $0.field_name == board.group_by })?.options?.map(\.label) ?? []
        // The verified web BoardView retains endpoint row order and groupRowsByColumn is stable.
        return try BoardSnapshot(definition: board, cards: cards, definedOptions: options,
                                 groupFieldType: details.field_definitions.first(where: { $0.field_name == board.group_by })?.field_type)
    }
    func currentMoveBoard(collection: String) async throws -> BoardDefinition {
        struct Field: Decodable { let field_name: String; let field_type: String }
        struct Details: Decodable { let views: [BoardDefinition]; let field_definitions: [Field] }
        let details = try JSONDecoder().decode(Details.self, from: await call("get_collection", arguments: ["collection": collection]))
        guard let board = BoardDefinition.preferred(in: details.views),
              details.field_definitions.first(where: { $0.field_name == board.group_by })?.field_type == "select"
        else { throw BoardMoveError.conflict }
        return board
    }
    func moveMemo(id: String) async throws -> MoveMemo {
        try JSONDecoder().decode(MoveMemo.self, from: await call("get_memo", arguments: ["id": id]))
    }
    func setMoveField(id: String, field: String, value: String?, version: Int) async throws {
        var arguments: [String: Any] = ["id": id, "field": field, "base_version": version]
        let tool: String
        if let value { tool = "set_field"; arguments["value"] = value; arguments["value_is_literal_string"] = true }
        else { tool = "delete_field" }
        // Narrow, explicit mutation boundary. Generic call() remains read-only.
        try await initialize()
        let result = try await rpc(method: "tools/call", params: ["name": tool, "arguments": arguments])
        guard result["isError"] as? Bool != true else { throw BoardMoveError.rejected }
        let data = try RPCCodec.toolData(result)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BoardMoveError.rejected }
        if response["error"] as? String == "conflict" { throw BoardMoveError.conflict }
        guard response["ok"] as? Bool == true else { throw BoardMoveError.rejected }
    }
    func call(_ tool: String, arguments: [String: Any]) async throws -> Data {
        guard RPCCodec.readTools.contains(tool) else { throw OAuthIssue.rejected("write_tool_blocked") }
        try await initialize()
        let result = try await rpc(method: "tools/call", params: ["name": tool, "arguments": arguments])
        return try RPCCodec.toolData(result)
    }
    private func initialize() async throws {
        guard !initialized else { return }
        let result = try await rpc(method: "initialize", params: ["protocolVersion": "2025-03-26", "capabilities": [:],
            "clientInfo": ["name": "FWWIP", "version": "0.1"]])
        guard result["protocolVersion"] as? String == "2025-03-26" else { throw OAuthIssue.rejected("unsupported_mcp_version") }
        var request = try await request(body: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        request.timeoutInterval = 20
        let reply = try await transport.send(request, rpcID: nil)
        guard (200..<300).contains(reply.status) else { throw OAuthIssue.network(reply.status) }
        initialized = true
    }
    private func rpc(method: String, params: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        var reply = try await transport.send(request(body: body), rpcID: id)
        if reply.status == 401 {
            // A 401 rejected authentication before execution; retry once with the same version.
            _ = try await tokenGate.value(forceRefresh: true) { [session] force in try await session.accessToken(forceRefresh: force) }
            reply = try await transport.send(request(body: body), rpcID: id)
        }
        if let id = reply.headers["mcp-session-id"] {
            guard !id.isEmpty, id.utf8.count < 4096,
                  id.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else { throw OAuthIssue.rejected("invalid_mcp_session") }
            sessionID = id
        }
        return try RPCCodec.result(reply, id: id)
    }
    private func request(body: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: OAuthPolicy.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let token = try await tokenGate.value { [session] force in try await session.accessToken(forceRefresh: force) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

/// Concurrent card requests share a token refresh instead of racing refresh-token rotation.
@MainActor final class AccessTokenGate {
    private var pending: (id: UUID, force: Bool, task: Task<String, Error>)?
    func value(forceRefresh: Bool = false,
               fetch: @escaping @MainActor (Bool) async throws -> String) async throws -> String {
        if let pending {
            if !forceRefresh || pending.force { return try await pending.task.value }
            _ = try await pending.task.value
        }
        // Another forced caller may already have started while the first task was awaited.
        if let pending, pending.force { return try await pending.task.value }
        let id = UUID(), task = Task { try await fetch(forceRefresh) }
        pending = (id, forceRefresh, task)
        defer { if pending?.id == id { pending = nil } }
        return try await task.value
    }
}
