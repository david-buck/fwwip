import Foundation

nonisolated enum CardTrashError: Error, LocalizedError {
    case notRecoverable, conflict, rejected, unverified
    var errorDescription: String? {
        switch self {
        case .notRecoverable: "Trash is available only for a claimed memo you own."
        case .conflict: "The card changed or is already in Trash. Refresh and review it before trying again."
        case .rejected: "Fieldwerk refused Trash or restore. Check ownership, lock state and the recovery window."
        case .unverified: "The Trash operation could not be verified. Check Fieldwerk before trying again."
        }
    }
}

@MainActor protocol BoardTrashAccess {
    func trashMemo(id: String) async throws -> MoveMemo?
    func ownsClaimedMemo(id: String, collection: String) async throws -> Bool
    func sendToTrash(id: String) async throws
    func restoreFromTrash(id: String, keepArchived: Bool) async throws
}

nonisolated struct VerifiedTrash {
    let live: MoveMemo
    let collection: String
    let isTrashed: Bool
    func column(field: String, scope: String?) -> String {
        let own = live.fields[field]?.string
        let edge = live.collection_fields[collection]?.fields[field]?.string
        switch scope {
        case "memo": return own ?? ""
        case "collection": return edge ?? ""
        default: return edge ?? own ?? ""
        }
    }
}

@MainActor final class TrashHistoryEntry {
    var receipt: VerifiedTrash
    let item: WorkItem
    let field: String
    let column: String
    init(receipt: VerifiedTrash, item: WorkItem, field: String, column: String) {
        self.receipt = receipt; self.item = item; self.field = field; self.column = column
    }
}

nonisolated enum BoardTrash {
    @MainActor static func trash(id: String, collection: String, access: any BoardTrashAccess) async throws -> VerifiedTrash {
        guard let before = try await access.trashMemo(id: id), before.id == id,
              before.collections.contains(where: { $0.id == collection }) else { throw CardTrashError.conflict }
        // delete_memo hard-deletes unclaimed memos. Owner-only account listing is a mandatory gate.
        guard try await access.ownsClaimedMemo(id: id, collection: collection) else { throw CardTrashError.notRecoverable }
        // Recheck after ownership lookup; never send a second delete for an already-trashed memo.
        guard let checked = try await access.trashMemo(id: id), sameLive(before, checked) else { throw CardTrashError.conflict }
        try await access.sendToTrash(id: id)
        guard try await access.trashMemo(id: id) == nil else { throw CardTrashError.unverified }
        return VerifiedTrash(live: checked, collection: collection, isTrashed: true)
    }

    @MainActor static func undo(_ receipt: VerifiedTrash, access: any BoardTrashAccess) async throws -> VerifiedTrash {
        guard receipt.isTrashed, try await access.trashMemo(id: receipt.live.id) == nil else { throw CardTrashError.conflict }
        try await access.restoreFromTrash(id: receipt.live.id, keepArchived: receipt.live.archived_at != nil)
        guard let restored = try await access.trashMemo(id: receipt.live.id), sameLive(receipt.live, restored) else {
            throw CardTrashError.unverified
        }
        return VerifiedTrash(live: restored, collection: receipt.collection, isTrashed: false)
    }

    @MainActor static func redo(_ receipt: VerifiedTrash, access: any BoardTrashAccess) async throws -> VerifiedTrash {
        guard !receipt.isTrashed, let current = try await access.trashMemo(id: receipt.live.id),
              sameLive(receipt.live, current) else { throw CardTrashError.conflict }
        return try await trash(id: current.id, collection: receipt.collection, access: access)
    }

    static func sameLive(_ a: MoveMemo, _ b: MoveMemo) -> Bool {
        a.id == b.id && a.version == b.version && a.fields == b.fields && a.markdown == b.markdown &&
        a.collection_fields == b.collection_fields && Set(a.collections.map(\.id)) == Set(b.collections.map(\.id)) &&
        a.visibility == b.visibility && a.sharing == b.sharing && (a.archived_at == nil) == (b.archived_at == nil)
    }
}
