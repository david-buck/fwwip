import XCTest
@testable import FWWIPCore

@MainActor final class MoveTests: XCTestCase {
    private func board(field: String = "priority", scope: String = "memo") throws -> BoardDefinition {
        try JSONDecoder().decode(BoardDefinition.self, from: JSONSerialization.data(withJSONObject: [
            "id": "view", "name": "Work board", "display": "board", "group_by": field,
            "group_by_scope": scope, "where": [], "columns": ["order": ["Low", "High"], "hidden": []]
        ]))
    }
    private func memo(version: Int = 7, value: String? = "Low", edge: Bool = false, archived: Bool = false,
                      unrelatedOverride: String? = nil) throws -> MoveMemo {
        var fields: [String: Any] = ["project": "Personal Projects", "untouched": true]
        if let value { fields["priority"] = value }
        return try JSONDecoder().decode(MoveMemo.self, from: JSONSerialization.data(withJSONObject: [
            "id": "fixture", "version": version, "fields": fields,
            "archived_at": archived ? "2026-10-15T00:00:00Z" as Any : NSNull(),
            "collection_fields": edge ? ["collection": ["fields": ["priority": "Low"]]] :
                unrelatedOverride.map { ["collection": ["fields": ["note": $0]]] } ?? [:],
            "collections": [["id": "collection"], ["id": "home"]]
        ]))
    }
    private func run(_ fake: FakeMoveAccess, snapshot: BoardSnapshot? = nil, destination: String = "High") async throws {
        let snapshot = try snapshot ?? BoardSnapshot(definition: fake.board, cards: [], groupFieldType: "select")
        _ = try await BoardMove.move(id: "fixture", source: "Low", destination: destination,
                                 collection: "collection", snapshot: snapshot, access: fake)
    }
    func testActualGroupingFieldAndFreshVersionUsedAndReadBackRequired() async throws {
        let fake = try FakeMoveAccess(board: board(), reads: [memo(), memo(version: 8, value: "High")])
        try await run(fake)
        XCTAssertEqual(fake.events, ["board", "read", "write", "read"])
        XCTAssertEqual(fake.writes.first?.field, "priority")
        XCTAssertEqual(fake.writes.first?.version, 7)
        XCTAssertEqual(fake.writes.first?.destination, "High")
    }
    func testStaleDisplayedColumnAndArchivedMemoNeverWrite() async throws {
        for before in try [memo(value: "High"), memo(archived: true)] {
            let fake = try FakeMoveAccess(board: board(), reads: [before])
            do { try await run(fake); XCTFail("Must reject stale/archived memo") } catch {}
            XCTAssertTrue(fake.writes.isEmpty)
        }
    }
    func testCollectionOverrideIsPreservedAndBlocksMove() async throws {
        let fake = try FakeMoveAccess(board: board(), reads: [memo(edge: true)])
        do { try await run(fake); XCTFail("Must not create drift") } catch {}
        XCTAssertTrue(fake.writes.isEmpty)
    }
    func testChangedBoardRejectsBeforeMemoOrWrite() async throws {
        let snapshot = try BoardSnapshot(definition: board(), cards: [], groupFieldType: "select")
        let fake = try FakeMoveAccess(board: board(field: "status"), reads: [])
        do { try await run(fake, snapshot: snapshot); XCTFail("Must reject changed grouping") } catch {}
        XCTAssertEqual(fake.events, ["board"])
    }
    func testWriteConflictIsNotRetriedOrReportedAsSuccess() async throws {
        let fake = try FakeMoveAccess(board: board(), reads: [memo()]); fake.rejectWrite = true
        do { try await run(fake); XCTFail("Must report rejection") } catch {}
        XCTAssertEqual(fake.events, ["board", "read", "write"])
    }
    func testUnchangedOrWrongReadBackIsNotSuccess() async throws {
        for after in try [memo(), memo(version: 8, value: "Low")] {
            let fake = try FakeMoveAccess(board: board(), reads: [memo(), after])
            do { try await run(fake); XCTFail("Must verify actual result") } catch {}
        }
    }
    func testNotSetRemovesFieldAndVerifiesAbsence() async throws {
        let fake = try FakeMoveAccess(board: board(), reads: [memo(), memo(version: 8, value: nil)])
        try await run(fake, destination: "")
        XCTAssertNil(fake.writes.first?.destination)
    }
    func testProjectAndCollectionScopedBoardsHaveExplicitLimitations() throws {
        for definition in try [board(field: "project"), board(scope: "collection")] {
            let snapshot = try BoardSnapshot(definition: definition, cards: [], groupFieldType: "select")
            XCTAssertNotNil(BoardMove.limitation(snapshot))
        }
    }

    func testVerifiedMoveRegistersNativeUndoAndRestoresOnlyPriorField() async throws {
        let fake = try FakeMoveAccess(board: board(), reads: [memo(), memo(version: 8, value: "High"),
                                                              memo(version: 8, value: "High"), memo(version: 9)])
        let history = CardMoveHistory()
        var receipt: VerifiedMove?
        let snapshot = try BoardSnapshot(definition: fake.board, cards: [], groupFieldType: "select")
        try await history.move(id: "fixture", item: SampleWork.items[0], source: "Low", destination: "High", collection: "collection",
                               snapshot: snapshot, access: fake, onUndo: { receipt = $0 })
        XCTAssertTrue(history.isAvailable); XCTAssertTrue(history.manager.canUndo)
        XCTAssertEqual(history.manager.undoActionName, "Move Card")
        history.undo()
        XCTAssertFalse(history.isAvailable); XCTAssertFalse(history.manager.canUndo)
        let saved = try XCTUnwrap(receipt)
        XCTAssertEqual(saved.scope, .memo); XCTAssertEqual(saved.previousValue, "Low")
        XCTAssertEqual(saved.confirmed.version, 8)
        try await BoardMove.undo(saved, access: fake)
        XCTAssertEqual(fake.writes.map(\.field), ["priority", "priority"])
        XCTAssertEqual(fake.writes.map(\.version), [7, 8])
        XCTAssertEqual(fake.writes.map(\.destination), ["High", "Low"])
    }
    func testFailedOrUnverifiedMoveNeverRegistersUndo() async throws {
        for reject in [true, false] {
            let fake = try FakeMoveAccess(board: board(), reads: [memo(), memo()]); fake.rejectWrite = reject
            let history = CardMoveHistory()
            let snapshot = try BoardSnapshot(definition: fake.board, cards: [], groupFieldType: "select")
            do {
                try await history.move(id: "fixture", item: SampleWork.items[0], source: "Low", destination: "High", collection: "collection",
                                       snapshot: snapshot, access: fake, onUndo: { _ in XCTFail("No undo expected") })
                XCTFail("Move must fail")
            } catch {}
            XCTAssertFalse(history.isAvailable); XCTAssertFalse(history.manager.canUndo)
        }
    }
    func testUndoDistinguishesAbsentPropertyFromLiteralEmptyString() async throws {
        for prior: String? in [nil, ""] {
            let fake = try FakeMoveAccess(board: board(), reads: [memo(value: prior), memo(version: 8, value: "High"),
                memo(version: 8, value: "High"), memo(version: 9, value: prior)])
            let snapshot = try BoardSnapshot(definition: fake.board, cards: [], groupFieldType: "select")
            let receipt = try await BoardMove.move(id: "fixture", source: "", destination: "High", collection: "collection",
                                                  snapshot: snapshot, access: fake)
            XCTAssertEqual(receipt.previousValue, prior)
            try await BoardMove.undo(receipt, access: fake)
            XCTAssertEqual(fake.writes.last?.destination, prior)
        }
    }
    func testMoveToNotSetCanBeUndone() async throws {
        let fake = try FakeMoveAccess(board: board(), reads: [memo(), memo(version: 8, value: nil),
                                                              memo(version: 8, value: nil), memo(version: 9)])
        let snapshot = try BoardSnapshot(definition: fake.board, cards: [], groupFieldType: "select")
        let receipt = try await BoardMove.move(id: "fixture", source: "Low", destination: "", collection: "collection",
                                              snapshot: snapshot, access: fake)
        XCTAssertNil(receipt.writtenValue)
        try await BoardMove.undo(receipt, access: fake)
        XCTAssertEqual(fake.writes.last?.destination, "Low")
    }
    func testUndoRefusesAnyInterveningRemoteVersionEvenIfDestinationMatches() async throws {
        let fake = try FakeMoveAccess(board: board(), reads: [memo(), memo(version: 8, value: "High"),
                                                              memo(version: 9, value: "High")])
        let snapshot = try BoardSnapshot(definition: fake.board, cards: [], groupFieldType: "select")
        let receipt = try await BoardMove.move(id: "fixture", source: "Low", destination: "High", collection: "collection",
                                              snapshot: snapshot, access: fake)
        do { try await BoardMove.undo(receipt, access: fake); XCTFail("Must refuse remote edit") } catch {}
        XCTAssertEqual(fake.writes.count, 1)
    }
    func testUndoPreservesUnrelatedCollectionOverridesAndRejectsChangesWithoutMemoVersionBump() async throws {
        for changed in [false, true] {
            let before = try memo(unrelatedOverride: "Keep")
            let after = try memo(version: 8, value: "High", unrelatedOverride: "Keep")
            let current = try memo(version: 8, value: "High", unrelatedOverride: changed ? "Changed" : "Keep")
            let restored = try memo(version: 9, unrelatedOverride: "Keep")
            let fake = try FakeMoveAccess(board: board(), reads: [before, after, current, restored])
            let snapshot = try BoardSnapshot(definition: fake.board, cards: [], groupFieldType: "select")
            let receipt = try await BoardMove.move(id: "fixture", source: "Low", destination: "High", collection: "collection",
                                                  snapshot: snapshot, access: fake)
            XCTAssertEqual(receipt.confirmed.collection_fields, after.collection_fields)
            if changed {
                do { try await BoardMove.undo(receipt, access: fake); XCTFail("Must preserve changed override") } catch {}
                XCTAssertEqual(fake.writes.count, 1)
            } else { try await BoardMove.undo(receipt, access: fake); XCTAssertEqual(fake.writes.count, 2) }
        }
    }
    func testUndoWriteRaceAndBadReadBackAreFailuresWithoutRetry() async throws {
        for reject in [true, false] {
            let fake = try FakeMoveAccess(board: board(), reads: [memo(), memo(version: 8, value: "High"),
                memo(version: 8, value: "High"), memo(version: 9, value: "High")])
            let snapshot = try BoardSnapshot(definition: fake.board, cards: [], groupFieldType: "select")
            let receipt = try await BoardMove.move(id: "fixture", source: "Low", destination: "High", collection: "collection",
                                                  snapshot: snapshot, access: fake)
            fake.rejectWrite = reject
            do { try await BoardMove.undo(receipt, access: fake); XCTFail("Must fail safely") } catch {}
            XCTAssertEqual(fake.writes.count, 2)
            XCTAssertEqual(fake.writes.last?.version, 8)
        }
    }
    func testCollectionScopedUndoCannotFallBackToMemoWrite() async throws {
        let confirmed = try memo(version: 8, value: "High", edge: true)
        let receipt = VerifiedMove(field: "priority", scope: .collection("collection"), previousValue: "Low",
                                   writtenValue: "High", confirmed: confirmed)
        let fake = try FakeMoveAccess(board: board(), reads: [])
        do { try await BoardMove.undo(receipt, access: fake); XCTFail("Edge undo has no CAS") } catch {}
        XCTAssertTrue(fake.events.isEmpty)
    }
    func testNativeUndoRedoUsesEachConfirmedVersionAndDisablesPendingInverse() async throws {
        let fake = try FakeMoveAccess(board: board(), reads: [memo(), memo(version: 8, value: "High"),
            memo(version: 8, value: "High"), memo(version: 9), memo(version: 9), memo(version: 10, value: "High")])
        let snapshot = try BoardSnapshot(definition: fake.board, cards: [], groupFieldType: "select")
        let receipt = try await BoardMove.move(id: "fixture", source: "Low", destination: "High", collection: "collection",
                                              snapshot: snapshot, access: fake)
        let history = CardMoveHistory()
        var requested: (MoveHistoryEntry, Bool)?
        history.record(receipt, item: SampleWork.items[0], onRequest: { requested = ($0, $1) })
        history.undo()
        let undo = try XCTUnwrap(requested)
        XCTAssertTrue(undo.1); XCTAssertFalse(history.canUndo); XCTAssertFalse(history.canRedo)
        history.redo() // Pending inverse cannot be dispatched twice.
        let undone = try await BoardMove.undo(undo.0.receipt, access: fake)
        history.complete(undo.0, confirmed: undone)
        XCTAssertTrue(history.canRedo); XCTAssertFalse(history.canUndo)
        history.redo()
        let redo = try XCTUnwrap(requested); XCTAssertFalse(redo.1)
        let redone = try await BoardMove.redo(redo.0.receipt, access: fake)
        history.complete(redo.0, confirmed: redone)
        XCTAssertTrue(history.canUndo); XCTAssertFalse(history.canRedo)
        XCTAssertEqual(fake.writes.map(\.version), [7, 8, 9])
        XCTAssertEqual(fake.writes.map(\.destination), ["High", "Low", "High"])
    }
    func testFailedInverseAndNewMoveClearRedoWithoutPhantomHistory() async throws {
        let fake = try FakeMoveAccess(board: board(), reads: [memo(), memo(version: 8, value: "High")])
        let snapshot = try BoardSnapshot(definition: fake.board, cards: [], groupFieldType: "select")
        let receipt = try await BoardMove.move(id: "fixture", source: "Low", destination: "High", collection: "collection",
                                              snapshot: snapshot, access: fake)
        let history = CardMoveHistory(); var entry: MoveHistoryEntry?
        history.record(receipt, item: SampleWork.items[0], onRequest: { entry = $0; _ = $1 })
        history.undo(); history.fail(try XCTUnwrap(entry))
        XCTAssertFalse(history.manager.canUndo); XCTAssertFalse(history.manager.canRedo)
        history.record(receipt, item: SampleWork.items[0], onRequest: { entry = $0; _ = $1 })
        history.undo(); history.complete(try XCTUnwrap(entry), confirmed: receipt.confirmed)
        XCTAssertTrue(history.canRedo)
        history.clear() // New move intent clears redo before its write.
        history.complete(try XCTUnwrap(entry), confirmed: receipt.confirmed) // Old completion cannot revive it.
        XCTAssertFalse(history.canUndo); XCTAssertFalse(history.canRedo)
    }
    func testRedoOfMoveFromAbsentFieldUsesFreshUndoVersion() async throws {
        let fake = try FakeMoveAccess(board: board(), reads: [memo(value: nil), memo(version: 8, value: "High"),
            memo(version: 8, value: "High"), memo(version: 9, value: nil),
            memo(version: 9, value: nil), memo(version: 10, value: "High")])
        let snapshot = try BoardSnapshot(definition: fake.board, cards: [], groupFieldType: "select")
        let receipt = try await BoardMove.move(id: "fixture", source: "", destination: "High", collection: "collection",
                                              snapshot: snapshot, access: fake)
        let undone = try await BoardMove.undo(receipt, access: fake)
        try await BoardMove.redo(receipt.confirming(undone), access: fake)
        XCTAssertEqual(fake.writes.map(\.destination), ["High", nil, "High"])
    }
}

@MainActor private final class FakeMoveAccess: BoardMoveAccess {
    struct Write { let field: String; let destination: String?; let version: Int }
    let board: BoardDefinition
    var reads: [MoveMemo]
    var events: [String] = []
    var writes: [Write] = []
    var rejectWrite = false
    init(board: BoardDefinition, reads: [MoveMemo]) { self.board = board; self.reads = reads }
    func currentMoveBoard(collection: String) async throws -> BoardDefinition { events.append("board"); return board }
    func moveMemo(id: String) async throws -> MoveMemo { events.append("read"); return reads.removeFirst() }
    func setMoveField(id: String, field: String, value: String?, version: Int) async throws {
        events.append("write"); writes.append(Write(field: field, destination: value, version: version))
        if rejectWrite { throw BoardMoveError.rejected }
    }
}
