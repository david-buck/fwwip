import XCTest
@testable import FWWIPCore

@MainActor final class MoveTests: XCTestCase {
    private func board(field: String = "priority", scope: String = "memo") throws -> BoardDefinition {
        try JSONDecoder().decode(BoardDefinition.self, from: JSONSerialization.data(withJSONObject: [
            "id": "view", "name": "Work board", "display": "board", "group_by": field,
            "group_by_scope": scope, "where": [], "columns": ["order": ["Low", "High"], "hidden": []]
        ]))
    }
    private func memo(version: Int = 7, value: String? = "Low", edge: Bool = false, archived: Bool = false) throws -> MoveMemo {
        var fields: [String: Any] = ["project": "Personal Projects", "untouched": true]
        if let value { fields["priority"] = value }
        return try JSONDecoder().decode(MoveMemo.self, from: JSONSerialization.data(withJSONObject: [
            "id": "fixture", "version": version, "fields": fields,
            "archived_at": archived ? "2026-10-15T00:00:00Z" as Any : NSNull(),
            "collection_fields": edge ? ["collection": ["fields": ["priority": "Low"]]] : [:],
            "collections": [["id": "collection"], ["id": "home"]]
        ]))
    }
    private func run(_ fake: FakeMoveAccess, snapshot: BoardSnapshot? = nil, destination: String = "High") async throws {
        let snapshot = try snapshot ?? BoardSnapshot(definition: fake.board, cards: [], groupFieldType: "select")
        try await BoardMove.move(id: "fixture", source: "Low", destination: destination,
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
        XCTAssertEqual(fake.writes.first?.destination, "")
    }
    func testProjectAndCollectionScopedBoardsHaveExplicitLimitations() throws {
        for definition in try [board(field: "project"), board(scope: "collection")] {
            let snapshot = try BoardSnapshot(definition: definition, cards: [], groupFieldType: "select")
            XCTAssertNotNil(BoardMove.limitation(snapshot))
        }
    }
}

@MainActor private final class FakeMoveAccess: BoardMoveAccess {
    struct Write { let field: String; let destination: String; let version: Int }
    let board: BoardDefinition
    var reads: [MoveMemo]
    var events: [String] = []
    var writes: [Write] = []
    var rejectWrite = false
    init(board: BoardDefinition, reads: [MoveMemo]) { self.board = board; self.reads = reads }
    func currentMoveBoard(collection: String) async throws -> BoardDefinition { events.append("board"); return board }
    func moveMemo(id: String) async throws -> MoveMemo { events.append("read"); return reads.removeFirst() }
    func setMoveField(id: String, field: String, destination: String, version: Int) async throws {
        events.append("write"); writes.append(Write(field: field, destination: destination, version: version))
        if rejectWrite { throw BoardMoveError.rejected }
    }
}
