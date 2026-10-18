import XCTest
@testable import FWWIPCore

@MainActor final class TrashTests: XCTestCase {
    func testTrashToolsRemainOutsideGenericReadBoundary() {
        XCTAssertTrue(RPCCodec.readTools.contains("list_my_memos"))
        for tool in ["delete_memo", "restore_memo", "empty_trash"] { XCTAssertFalse(RPCCodec.readTools.contains(tool)) }
    }
    private func memo(version: Int = 4, archived: Bool = false, edge: String = "Waiting") throws -> MoveMemo {
        try JSONDecoder().decode(MoveMemo.self, from: JSONSerialization.data(withJSONObject: [
            "id": "fixture", "version": version, "archived_at": archived ? "2026-10-16T00:00:00Z" as Any : NSNull(),
            "markdown": "Synthetic body", "visibility": "link", "sharing": ["link_access": "none"],
            "fields": ["status": "Next", "untouched": true],
            "collection_fields": ["collection": ["fields": ["status": edge, "note": "Keep"]]],
            "collections": [["id": "collection"], ["id": "home"]]
        ]))
    }
    func testTrashRequiresClaimedOwnershipAndVerifiesAbsenceWithoutChangingFields() async throws {
        let before = try memo(); let fake = FakeTrashAccess(before)
        let receipt = try await BoardTrash.trash(id: "fixture", collection: "collection", access: fake)
        XCTAssertTrue(receipt.isTrashed); XCTAssertNil(fake.current)
        XCTAssertEqual(fake.events, ["read", "owner", "read", "trash", "read"])
        XCTAssertEqual(receipt.live.fields, before.fields)
        XCTAssertEqual(receipt.live.collection_fields, before.collection_fields)
        XCTAssertEqual(receipt.column(field: "status", scope: "memo"), "Next")
        XCTAssertEqual(receipt.column(field: "status", scope: "collection"), "Waiting")
    }
    func testUnclaimedOrNotOwnedMemoNeverReachesDelete() async throws {
        let fake = FakeTrashAccess(try memo()); fake.owned = false
        do { _ = try await BoardTrash.trash(id: "fixture", collection: "collection", access: fake); XCTFail("Must refuse hard-delete risk") } catch {}
        XCTAssertEqual(fake.trashCalls, 0); XCTAssertNotNil(fake.current)
    }
    func testAlreadyTrashedMemoIsNotDeletedAgain() async throws {
        let fake = FakeTrashAccess(try memo())
        _ = try await BoardTrash.trash(id: "fixture", collection: "collection", access: fake)
        do { _ = try await BoardTrash.trash(id: "fixture", collection: "collection", access: fake); XCTFail("No second delete") } catch {}
        XCTAssertEqual(fake.trashCalls, 1)
    }
    func testChangedMemoDuringOwnerCheckBlocksTrash() async throws {
        let fake = FakeTrashAccess(try memo()); fake.changeDuringOwnerCheck = try memo(version: 5)
        do { _ = try await BoardTrash.trash(id: "fixture", collection: "collection", access: fake); XCTFail("Must stop on change") } catch {}
        XCTAssertEqual(fake.trashCalls, 0)
    }
    func testRejectedOrUnverifiedTrashIsNotSuccessAndIsNeverRetried() async throws {
        for reject in [true, false] {
            let fake = FakeTrashAccess(try memo()); fake.rejectTrash = reject; fake.keepLiveAfterTrash = !reject
            do { _ = try await BoardTrash.trash(id: "fixture", collection: "collection", access: fake); XCTFail("Must fail") } catch {}
            XCTAssertEqual(fake.trashCalls, 1); XCTAssertNotNil(fake.current)
        }
    }
    func testUndoAndRedoUseActualRestoreOperationAndPreserveArchiveState() async throws {
        for archived in [false, true] {
            let original = try memo(archived: archived); let fake = FakeTrashAccess(original)
            let trashed = try await BoardTrash.trash(id: "fixture", collection: "collection", access: fake)
            let restored = try await BoardTrash.undo(trashed, access: fake)
            XCTAssertFalse(restored.isTrashed); XCTAssertEqual(fake.keepArchived, [archived])
            XCTAssertTrue(BoardTrash.sameLive(original, try XCTUnwrap(fake.current)))
            let redone = try await BoardTrash.redo(restored, access: fake)
            XCTAssertTrue(redone.isTrashed); XCTAssertNil(fake.current)
            XCTAssertEqual(fake.trashCalls, 2); XCTAssertEqual(fake.restoreCalls, 1)
        }
    }
    func testUndoRefusesAnExternalRestoreWithoutOverwritingIt() async throws {
        let fake = FakeTrashAccess(try memo())
        let trashed = try await BoardTrash.trash(id: "fixture", collection: "collection", access: fake)
        fake.current = try memo(version: 5)
        do { _ = try await BoardTrash.undo(trashed, access: fake); XCTFail("Must preserve external changes") } catch {}
        XCTAssertEqual(fake.restoreCalls, 0); XCTAssertEqual(fake.current?.version, 5)
    }
    func testRedoRefusesChangesAfterRestore() async throws {
        let fake = FakeTrashAccess(try memo())
        let trashed = try await BoardTrash.trash(id: "fixture", collection: "collection", access: fake)
        let restored = try await BoardTrash.undo(trashed, access: fake)
        fake.current = try memo(version: 5)
        do { _ = try await BoardTrash.redo(restored, access: fake); XCTFail("Must preserve newer edit") } catch {}
        XCTAssertEqual(fake.trashCalls, 1)
    }
    func testFailedRestoreLeavesTrashAndNoAutomaticRetry() async throws {
        let fake = FakeTrashAccess(try memo())
        let trashed = try await BoardTrash.trash(id: "fixture", collection: "collection", access: fake)
        fake.rejectRestore = true
        do { _ = try await BoardTrash.undo(trashed, access: fake); XCTFail("Must fail") } catch {}
        XCTAssertNil(fake.current); XCTAssertEqual(fake.restoreCalls, 1)
    }
    func testNativeTrashHistoryRestoresThenRedoesAndFailedInverseClearsHistory() async throws {
        let fake = FakeTrashAccess(try memo())
        let receipt = try await BoardTrash.trash(id: "fixture", collection: "collection", access: fake)
        let history = CardMoveHistory(); var request: (TrashHistoryEntry, Bool)?
        history.recordTrash(receipt, item: SampleWork.items[0], field: "status", column: "Next",
                            onRequest: { request = ($0, $1) })
        XCTAssertEqual(history.actionName, "Trash Card"); XCTAssertEqual(history.manager.undoActionName, "Trash Card")
        history.undo()
        let undo = try XCTUnwrap(request); XCTAssertTrue(undo.1)
        let restored = try await BoardTrash.undo(undo.0.receipt, access: fake)
        history.completeTrash(undo.0, receipt: restored); XCTAssertTrue(history.canRedo)
        history.redo()
        let redo = try XCTUnwrap(request); XCTAssertFalse(redo.1)
        let redone = try await BoardTrash.redo(redo.0.receipt, access: fake)
        history.completeTrash(redo.0, receipt: redone); XCTAssertTrue(history.canUndo)
        history.undo(); history.failTrash(try XCTUnwrap(request).0)
        XCTAssertFalse(history.canUndo); XCTAssertFalse(history.canRedo)
        XCTAssertFalse(history.manager.canUndo); XCTAssertFalse(history.manager.canRedo)
    }
}

@MainActor private final class FakeTrashAccess: BoardTrashAccess {
    var current: MoveMemo?
    let original: MoveMemo
    var owned = true
    var rejectTrash = false
    var rejectRestore = false
    var keepLiveAfterTrash = false
    var changeDuringOwnerCheck: MoveMemo?
    var events: [String] = []
    var trashCalls = 0
    var restoreCalls = 0
    var keepArchived: [Bool] = []
    init(_ memo: MoveMemo) { current = memo; original = memo }
    func trashMemo(id: String) async throws -> MoveMemo? { events.append("read"); return current }
    func ownsClaimedMemo(id: String, collection: String) async throws -> Bool {
        events.append("owner")
        if let changeDuringOwnerCheck { current = changeDuringOwnerCheck }
        return owned
    }
    func sendToTrash(id: String) async throws {
        events.append("trash"); trashCalls += 1
        if rejectTrash { throw CardTrashError.rejected }
        if !keepLiveAfterTrash { current = nil }
    }
    func restoreFromTrash(id: String, keepArchived: Bool) async throws {
        events.append("restore"); restoreCalls += 1; self.keepArchived.append(keepArchived)
        if rejectRestore { throw CardTrashError.rejected }
        current = original
    }
}
