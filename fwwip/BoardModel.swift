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
    private(set) var itemsByColumn: [String: [WorkItem]]
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

    func applying(_ placements: [PendingPlacement]) -> Self {
        var result = self
        for placement in placements where placement.field == definition.group_by {
            for key in result.itemsByColumn.keys {
                result.itemsByColumn[key]?.removeAll { $0.id == placement.item.id }
            }
            result.itemsByColumn[placement.destination, default: []].insert(
                placement.item.inColumn(field: placement.field, value: placement.destination), at: 0)
        }
        return result
    }
}

nonisolated struct PendingPlacement: Identifiable {
    let id: UUID
    let revision: Int
    let item: WorkItem
    let field: String
    let source: String
    let destination: String
}

nonisolated struct BoardContext: Hashable {
    let workspace: String
    let collection: String
    let board: String
}

nonisolated struct BoardReadGate {
    struct Scope: Hashable { let workspace: String; let collection: String }
    struct Ticket { let scope: Scope; let sequence: Int; let revision: Int }
    private var sequences: [Scope: Int] = [:]
    private var revisions: [Scope: Int] = [:]
    mutating func begin(_ scope: Scope) -> Ticket {
        sequences[scope, default: 0] += 1
        return Ticket(scope: scope, sequence: sequences[scope]!, revision: revisions[scope, default: 0])
    }
    mutating func confirmedWrite(_ scope: Scope) { revisions[scope, default: 0] += 1 }
    func accepts(_ ticket: Ticket) -> Bool {
        sequences[ticket.scope] == ticket.sequence && revisions[ticket.scope, default: 0] == ticket.revision
    }
}

/// FIFO for each canonical memo, with bounded parallelism across distinct memos.
nonisolated struct CardWriteSchedule {
    struct Slot: Identifiable { let id: UUID; let memo: String; let context: BoardContext }
    private(set) var pending: [Slot] = []
    private(set) var active: Set<UUID> = []
    mutating func enqueue(_ slot: Slot) { pending.append(slot) }
    mutating func takeAvailable(limit: Int) -> [UUID] {
        var cards = Set(pending.filter { active.contains($0.id) }.map(\.memo))
        var result: [UUID] = []
        for slot in pending where active.count < limit {
            guard !active.contains(slot.id), cards.insert(slot.memo).inserted else { continue }
            active.insert(slot.id); result.append(slot.id)
        }
        return result
    }
    mutating func finish(_ id: UUID) { active.remove(id); pending.removeAll { $0.id == id } }
}

/// Authoritative reads plus ordered, transient UI projections; never persisted.
nonisolated struct OptimisticBoardState {
    private(set) var base: BoardSnapshot?
    private(set) var pending: [PendingPlacement] = []
    private var confirmedRevisions: [String: Int] = [:]
    var snapshot: BoardSnapshot? {
        base?.applying(pending.filter { $0.revision > (confirmedRevisions[$0.item.id] ?? -1) })
    }
    mutating func replaceBase(_ snapshot: BoardSnapshot) { base = snapshot }
    mutating func enqueue(_ placement: PendingPlacement) { pending.append(placement) }
    mutating func finish(_ id: UUID, succeeded: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let placement = pending.remove(at: index)
        if succeeded, placement.revision > (confirmedRevisions[placement.item.id] ?? -1) {
            base = base?.applying([placement]); confirmedRevisions[placement.item.id] = placement.revision
        }
    }
    func rollbackColumn(for placement: PendingPlacement, selected: String?, latestRevision: Int?) -> String? {
        guard latestRevision == placement.revision, selected == placement.destination else { return nil }
        return base?.itemsByColumn.first(where: { $0.value.contains { $0.id == placement.item.id } })?.key
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
