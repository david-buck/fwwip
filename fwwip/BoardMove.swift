import Foundation

nonisolated enum BoardMoveError: Error, LocalizedError {
    case unavailable(String), conflict, rejected, unverified
    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .conflict: "The card or board changed. Refresh and review it before moving again."
        case .rejected: "Fieldwerk refused the move, possibly because of a concurrent edit or access change. Refresh and review the card."
        case .unverified: "The move could not be verified. Refresh and check the task in Fieldwerk before trying again."
        }
    }
}

nonisolated struct MoveMemo: Decodable {
    struct Edge: Decodable, Equatable { let fields: [String: BoardValue] }
    struct Membership: Decodable { let id: String }
    let id: String
    let version: Int
    let archived_at: String?
    let fields: [String: BoardValue]
    let collection_fields: [String: Edge]
    let collections: [Membership]
    let markdown: String?
    let visibility: String?
    let sharing: BoardValue?
}

@MainActor protocol BoardMoveAccess {
    func currentMoveBoard(collection: String) async throws -> BoardDefinition
    func moveMemo(id: String) async throws -> MoveMemo
    func setMoveField(id: String, field: String, destination: String, version: Int) async throws
}

nonisolated enum BoardMove {
    static func limitation(_ snapshot: BoardSnapshot) -> String? {
        guard snapshot.definition.group_by_scope == "memo" else {
            return "Move this card in Fieldwerk. Collection-specific fields have no version protection."
        }
        guard snapshot.groupFieldType == "select" else { return "Move this board’s grouping field in Fieldwerk." }
        guard snapshot.definition.group_by?.lowercased() != "project" else {
            return "Reassign projects in Fieldwerk so the task’s home membership can be reconciled."
        }
        return nil
    }

    @MainActor static func move(id: String, source: String, destination: String, collection: String,
                                snapshot: BoardSnapshot, access: any BoardMoveAccess) async throws {
        if let reason = limitation(snapshot) { throw BoardMoveError.unavailable(reason) }
        guard source != destination, snapshot.columns.contains(where: { $0.id == destination }),
              let field = snapshot.definition.group_by else { throw BoardMoveError.conflict }
        // Revalidate the selected view immediately before reading the memo/version.
        guard try await access.currentMoveBoard(collection: collection) == snapshot.definition else { throw BoardMoveError.conflict }
        let before = try await access.moveMemo(id: id)
        guard before.id == id, before.archived_at == nil, before.version > 0,
              before.collections.contains(where: { $0.id == collection }),
              before.fields[field] == nil || before.fields[field]?.string != nil,
              (before.fields[field]?.string ?? "") == source else { throw BoardMoveError.conflict }
        // Never introduce or silently clean up canonical/collection property drift.
        guard !before.collection_fields.values.contains(where: { $0.fields[field] != nil }) else {
            throw BoardMoveError.unavailable("This card has a collection override for \(field). Resolve it in Fieldwerk before moving here.")
        }
        try await access.setMoveField(id: id, field: field, destination: destination, version: before.version)
        let after = try await access.moveMemo(id: id)
        let expected: BoardValue? = destination.isEmpty ? nil : .string(destination)
        guard after.id == id, after.archived_at == nil, after.version > before.version,
              after.fields[field] == expected,
              before.fields.filter({ $0.key != field }) == after.fields.filter({ $0.key != field }),
              Set(before.collections.map(\.id)) == Set(after.collections.map(\.id)),
              before.collection_fields == after.collection_fields,
              before.markdown == after.markdown, before.visibility == after.visibility,
              before.sharing == after.sharing else { throw BoardMoveError.unverified }
    }
}
