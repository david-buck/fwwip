import Foundation

nonisolated enum BoardValue: Decodable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([BoardValue]), object([String: BoardValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([BoardValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: BoardValue].self)) }
    }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var json: Any {
        switch self {
        case .string(let v): v
        case .number(let v): v
        case .bool(let v): v
        case .array(let v): v.map(\.json)
        case .object(let v): v.mapValues(\.json)
        case .null: NSNull()
        }
    }
}

nonisolated struct BoardDefinition: Decodable, Equatable, Sendable, Identifiable {
    struct Columns: Decodable, Equatable, Sendable { let order: [String]; let hidden: [String] }
    let id: String
    let name: String
    let display: String
    let notebook: String?
    let group_by: String?
    let group_by_scope: String?
    let columns: Columns?
    let sort: BoardValue?
    let `where`: [BoardValue]
    let url: URL?
    let position: Int?
    let include_files: Bool?

    static func preferred(in views: [Self]) -> Self? {
        let boards = views.filter { $0.display == "board" && $0.notebook == nil }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        return boards.first(where: { $0.name == "Active work" }) ?? boards.first(where: { $0.name == "Work board" }) ?? boards.first
    }
    var safeURL: URL? {
        guard let url, url.scheme == "https", url.host == "my.fieldwerk.ai", url.user == nil,
              url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return url
    }
}

nonisolated struct BoardColumn: Identifiable, Equatable, Sendable {
    let id: String
    var label: String { id.isEmpty ? "Not set" : id }
}

nonisolated struct BoardSnapshot: Equatable, Sendable {
    let definition: BoardDefinition
    let columns: [BoardColumn]
    let itemsByColumn: [String: [WorkItem]]
    let groupFieldType: String?

    init(definition: BoardDefinition, cards: [FieldwerkCard], definedOptions: [String] = [], groupFieldType: String? = nil) throws {
        self.definition = definition
        self.groupFieldType = groupFieldType
        guard let field = definition.group_by, !field.isEmpty, field.lowercased() != "notebook" else {
            throw FieldwerkReadError.unsupportedBoard("This board's grouping is not supported yet.", definition.safeURL)
        }
        guard definition.sort == nil else {
            throw FieldwerkReadError.unsupportedBoard("This board has a custom sort that FWWIP does not support yet.", definition.safeURL)
        }
        var keys: [String] = []
        var seenKeys = Set<String>()
        func append(_ key: String) { if seenKeys.insert(key).inserted { keys.append(key) } }
        // Keep every configured empty column, as requested; hide only explicitly hidden columns.
        for key in definition.columns?.order ?? [] { append(key) }
        if definition.group_by_scope != "memo" { for key in definedOptions { append(key) } }
        var grouped: [String: [WorkItem]] = [:]
        var seenCards = Set<String>()
        for card in cards where card.archived_at == nil && seenCards.insert(card.id).inserted {
            let key = card.groupValue(field: field, scope: definition.group_by_scope)
            append(key)
            grouped[key, default: []].append(try card.projected())
        }
        append("")
        let hidden = Set(definition.columns?.hidden ?? [])
        columns = keys.filter { !hidden.contains($0) }.map { BoardColumn(id: $0) }
        itemsByColumn = grouped
    }
}

nonisolated enum ColumnSelection {
    static func resolvedID(preferredID: String?, columns: [BoardColumn]) -> String? {
        if let preferredID, columns.contains(where: { $0.id == preferredID }) { return preferredID }
        return columns.first?.id
    }
    static func cycledID(current: String?, direction: Int, columns: [BoardColumn]) -> String? {
        guard !columns.isEmpty else { return nil }
        let index = columns.firstIndex(where: { $0.id == current }) ?? 0
        return columns[((index + direction) % columns.count + columns.count) % columns.count].id
    }
}

nonisolated struct WorkSlice {
    static let size = 50
    let items: [WorkItem]
    let remainingCount: Int
    init(items: [WorkItem], visibleCount: Int = Self.size) {
        self.items = Array(items.prefix(visibleCount))
        remainingCount = max(0, items.count - self.items.count)
    }
}
