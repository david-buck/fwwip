import XCTest
@testable import FWWIPCore

final class OptimisticMoveTests: XCTestCase {
    private func board(value: String = "Next") throws -> BoardSnapshot {
        let definition = try JSONDecoder().decode(BoardDefinition.self, from: Data(#"{"id":"board","name":"Work board","display":"board","where":[],"group_by":"status","group_by_scope":"memo","columns":{"order":["Next","Doing","Waiting"],"hidden":[]}}"#.utf8))
        let data = try JSONSerialization.data(withJSONObject: ["id": "fixture", "title": "Synthetic card",
            "url": "https://my.fieldwerk.ai/m/fixture", "fields": ["status": value]])
        return try BoardSnapshot(definition: definition, cards: [JSONDecoder().decode(FieldwerkCard.self, from: data)], groupFieldType: "select")
    }
    private func placement(_ revision: Int, from: String, to: String, in board: BoardSnapshot) throws -> PendingPlacement {
        let item = try XCTUnwrap(board.itemsByColumn.values.flatMap { $0 }.first)
        return PendingPlacement(id: UUID(), revision: revision, item: item, field: "status", source: from, destination: to)
    }
    func testPlacementImmediatelyChangesColumnCountAndStatusWithoutMutatingAuthoritativeBase() throws {
        let base = try board(); var state = OptimisticBoardState(); state.replaceBase(base)
        state.enqueue(try placement(1, from: "Next", to: "Doing", in: base))
        XCTAssertEqual(state.snapshot?.itemsByColumn["Doing"]?.map(\.id), ["fixture"])
        XCTAssertEqual(state.snapshot?.itemsByColumn["Next"]?.count, 0)
        XCTAssertEqual(state.snapshot?.itemsByColumn["Doing"]?.first?.state, "Doing")
        XCTAssertEqual(state.base?.itemsByColumn["Next"]?.count, 1)
    }
    func testRapidMovesKeepLatestPlacementWhenEarlierRequestCompletes() throws {
        let base = try board(); var state = OptimisticBoardState(); state.replaceBase(base)
        let first = try placement(1, from: "Next", to: "Doing", in: base)
        let second = try placement(2, from: "Doing", to: "Waiting", in: base)
        state.enqueue(first); state.enqueue(second); state.finish(first.id, succeeded: true)
        XCTAssertEqual(state.snapshot?.itemsByColumn["Waiting"]?.count, 1)
        XCTAssertEqual(state.snapshot?.itemsByColumn["Doing"]?.count ?? 0, 0)
        XCTAssertEqual(state.pending.map(\.id), [second.id])
    }
    func testOldFailureAndAuthoritativeRefetchCannotRollBackNewerPendingAction() throws {
        let base = try board(); var state = OptimisticBoardState(); state.replaceBase(base)
        let first = try placement(1, from: "Next", to: "Doing", in: base)
        let second = try placement(2, from: "Doing", to: "Waiting", in: base)
        state.enqueue(first); state.enqueue(second); state.finish(first.id, succeeded: false)
        state.replaceBase(try board(value: "Next"))
        XCTAssertEqual(state.snapshot?.itemsByColumn["Waiting"]?.count, 1)
        // Only the newer request's own failure may remove its projection.
        state.finish(second.id, succeeded: false)
        XCTAssertEqual(state.snapshot?.itemsByColumn["Next"]?.count, 1)
        XCTAssertTrue(state.pending.isEmpty)
    }
    func testLateOrDuplicateCompletionCannotReplaceNewerConfirmedPlacement() throws {
        let base = try board(); var state = OptimisticBoardState(); state.replaceBase(base)
        let first = try placement(1, from: "Next", to: "Doing", in: base)
        let second = try placement(2, from: "Doing", to: "Waiting", in: base)
        state.enqueue(first); state.enqueue(second)
        state.finish(second.id, succeeded: true)
        XCTAssertEqual(state.snapshot?.itemsByColumn["Waiting"]?.count, 1)
        state.finish(first.id, succeeded: true)
        state.finish(first.id, succeeded: false)
        XCTAssertEqual(state.snapshot?.itemsByColumn["Waiting"]?.count, 1)
        XCTAssertEqual(state.snapshot?.itemsByColumn["Doing"]?.count ?? 0, 0)
    }
    func testFailureWithoutNewerActionRollsBackToLastAuthoritativeRead() throws {
        let base = try board(); var state = OptimisticBoardState(); state.replaceBase(base)
        let move = try placement(1, from: "Next", to: "Doing", in: base)
        state.enqueue(move); state.finish(move.id, succeeded: false)
        XCTAssertEqual(state.snapshot?.itemsByColumn["Next"]?.count, 1)
        XCTAssertNil(state.snapshot?.itemsByColumn["Doing"])
    }
    func testFailureReturnsToAuthoritativeColumnOnlyForStillCurrentIntentAndSelection() throws {
        let base = try board(); var state = OptimisticBoardState(); state.replaceBase(base)
        let move = try placement(1, from: "Next", to: "Doing", in: base)
        XCTAssertEqual(state.rollbackColumn(for: move, selected: "Doing", latestRevision: 1), "Next")
        XCTAssertNil(state.rollbackColumn(for: move, selected: "Waiting", latestRevision: 1))
        XCTAssertNil(state.rollbackColumn(for: move, selected: "Doing", latestRevision: 2))
        state.replaceBase(try board(value: "Waiting"))
        XCTAssertEqual(state.rollbackColumn(for: move, selected: "Doing", latestRevision: 1), "Waiting")
    }
}
