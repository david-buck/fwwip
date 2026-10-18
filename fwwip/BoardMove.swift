import Foundation
import Observation

nonisolated enum BoardMoveError: Error, LocalizedError {
    case unavailable(String), conflict, rejected, unverified
    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .conflict: "The card or board changed. Refresh and review it before trying again."
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
    /// nil removes the property; an empty string remains an actual string value.
    func setMoveField(id: String, field: String, value: String?, version: Int) async throws
}

nonisolated struct VerifiedMove {
    enum Scope: Equatable { case memo, collection(String) }
    let field: String
    let scope: Scope
    let previousValue: String?
    let writtenValue: String?
    let confirmed: MoveMemo
    func confirming(_ memo: MoveMemo) -> Self {
        Self(field: field, scope: scope, previousValue: previousValue, writtenValue: writtenValue, confirmed: memo)
    }
}

@MainActor final class MoveHistoryEntry {
    var receipt: VerifiedMove
    let item: WorkItem
    init(receipt: VerifiedMove, item: WorkItem) { self.receipt = receipt; self.item = item }
}

/// One in-memory native undo entry, created only by a verified remote move.
@MainActor @Observable final class CardMoveHistory {
    @ObservationIgnored let manager = UndoManager()
    private(set) var isAvailable = false
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var actionName = "Move Card"
    @ObservationIgnored private var entry: MoveHistoryEntry?
    @ObservationIgnored private var trashEntry: TrashHistoryEntry?
    init() { manager.groupsByEvent = false; manager.levelsOfUndo = 1 }

    func move(id: String, item: WorkItem, source: String, destination: String, collection: String,
              snapshot: BoardSnapshot, access: any BoardMoveAccess,
              onUndo: @escaping @MainActor (VerifiedMove) -> Void) async throws {
        let receipt = try await BoardMove.move(id: id, source: source, destination: destination,
                                              collection: collection, snapshot: snapshot, access: access)
        record(receipt, item: item, onRequest: { entry, _ in onUndo(entry.receipt) })
    }
    func record(_ receipt: VerifiedMove, item: WorkItem,
                onRequest: @escaping @MainActor (MoveHistoryEntry, Bool) -> Void) {
        clear()
        let entry = MoveHistoryEntry(receipt: receipt, item: item)
        self.entry = entry
        manager.beginUndoGrouping()
        register(entry, undo: true, onRequest: onRequest)
        manager.endUndoGrouping()
        updateAvailability()
    }
    private func register(_ entry: MoveHistoryEntry, undo: Bool,
                          onRequest: @escaping @MainActor (MoveHistoryEntry, Bool) -> Void) {
        manager.registerUndo(withTarget: self) { history in
            history.isAvailable = false; history.canUndo = false; history.canRedo = false
            // Native UndoManager must receive its inverse synchronously. It stays disabled
            // until the remote inverse is verified; failure discards both stacks.
            history.register(entry, undo: !undo, onRequest: onRequest)
            onRequest(entry, undo)
        }
        manager.setActionName("Move Card")
    }
    func complete(_ entry: MoveHistoryEntry, confirmed: MoveMemo) {
        guard self.entry === entry else { return } // A newer move invalidated this history.
        entry.receipt = entry.receipt.confirming(confirmed)
        updateAvailability()
    }
    func fail(_ entry: MoveHistoryEntry) { if self.entry === entry { clear() } }
    func recordTrash(_ receipt: VerifiedTrash, item: WorkItem, field: String, column: String,
                     onRequest: @escaping @MainActor (TrashHistoryEntry, Bool) -> Void) {
        clear(); actionName = "Trash Card"
        let entry = TrashHistoryEntry(receipt: receipt, item: item, field: field, column: column)
        trashEntry = entry
        manager.beginUndoGrouping()
        registerTrash(entry, undo: true, onRequest: onRequest)
        manager.endUndoGrouping(); updateAvailability()
    }
    private func registerTrash(_ entry: TrashHistoryEntry, undo: Bool,
                               onRequest: @escaping @MainActor (TrashHistoryEntry, Bool) -> Void) {
        manager.registerUndo(withTarget: self) { history in
            history.isAvailable = false; history.canUndo = false; history.canRedo = false
            history.registerTrash(entry, undo: !undo, onRequest: onRequest)
            onRequest(entry, undo)
        }
        manager.setActionName("Trash Card")
    }
    func completeTrash(_ entry: TrashHistoryEntry, receipt: VerifiedTrash) {
        guard trashEntry === entry else { return }
        entry.receipt = receipt; updateAvailability()
    }
    func failTrash(_ entry: TrashHistoryEntry) { if trashEntry === entry { clear() } }
    private func updateAvailability() {
        canUndo = manager.canUndo; canRedo = manager.canRedo; isAvailable = canUndo || canRedo
    }
    func undo() { guard canUndo else { return }; manager.undo() }
    func redo() { guard canRedo else { return }; manager.redo() }
    func clear() {
        manager.removeAllActions(); entry = nil; trashEntry = nil; actionName = "Move Card"
        isAvailable = false; canUndo = false; canRedo = false
    }
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
                                snapshot: BoardSnapshot, access: any BoardMoveAccess) async throws -> VerifiedMove {
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
        let value = destination.isEmpty ? nil : destination
        try await access.setMoveField(id: id, field: field, value: value, version: before.version)
        let after = try await access.moveMemo(id: id)
        try verify(before: before, after: after, field: field, value: value)
        return VerifiedMove(field: field, scope: .memo, previousValue: before.fields[field]?.string,
                            writtenValue: value, confirmed: after)
    }

    @discardableResult @MainActor static func undo(_ receipt: VerifiedMove, access: any BoardMoveAccess) async throws -> MoveMemo {
        try await restore(receipt, value: receipt.previousValue, access: access)
    }
    @discardableResult @MainActor static func redo(_ receipt: VerifiedMove, access: any BoardMoveAccess) async throws -> MoveMemo {
        try await restore(receipt, value: receipt.writtenValue, access: access)
    }
    @MainActor private static func restore(_ receipt: VerifiedMove, value: String?, access: any BoardMoveAccess) async throws -> MoveMemo {
        // Collection edges have no version counter; never approximate a protected undo with an edge write.
        guard receipt.scope == .memo else { throw BoardMoveError.unavailable("Undo this collection-specific change in Fieldwerk.") }
        let current = try await access.moveMemo(id: receipt.confirmed.id)
        guard current.archived_at == nil, current.id == receipt.confirmed.id,
              current.version == receipt.confirmed.version,
              current.fields == receipt.confirmed.fields,
              unchangedContext(current, receipt.confirmed) else { throw BoardMoveError.conflict }
        try await access.setMoveField(id: current.id, field: receipt.field,
                                     value: value, version: current.version)
        let restored = try await access.moveMemo(id: current.id)
        try verify(before: current, after: restored, field: receipt.field, value: value)
        return restored
    }

    private static func unchangedContext(_ before: MoveMemo, _ after: MoveMemo) -> Bool {
        Set(before.collections.map(\.id)) == Set(after.collections.map(\.id)) &&
        before.collection_fields == after.collection_fields && before.markdown == after.markdown &&
        before.visibility == after.visibility && before.sharing == after.sharing
    }
    private static func verify(before: MoveMemo, after: MoveMemo, field: String, value: String?) throws {
        let expected = value.map(BoardValue.string)
        guard after.id == before.id, after.archived_at == nil, after.version > before.version,
              after.fields[field] == expected,
              before.fields.filter({ $0.key != field }) == after.fields.filter({ $0.key != field }),
              unchangedContext(before, after) else { throw BoardMoveError.unverified }
    }
}
