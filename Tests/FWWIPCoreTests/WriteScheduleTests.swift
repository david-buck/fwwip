import XCTest
@testable import FWWIPCore

final class WriteScheduleTests: XCTestCase {
    private let a = BoardContext(workspace: "one", collection: "home", board: "work")
    private let b = BoardContext(workspace: "two", collection: "other", board: "work")
    func testIndependentCardsRunConcurrentlyWithBoundedLimit() {
        var schedule = CardWriteSchedule()
        let ids = (0..<5).map { _ in UUID() }
        for (n, id) in ids.enumerated() { schedule.enqueue(.init(id: id, memo: "card\(n)", context: a)) }
        XCTAssertEqual(schedule.takeAvailable(limit: 3), Array(ids.prefix(3)))
        XCTAssertTrue(schedule.takeAvailable(limit: 3).isEmpty)
        schedule.finish(ids[1])
        XCTAssertEqual(schedule.takeAvailable(limit: 3), [ids[3]])
        XCTAssertEqual(schedule.active.count, 3)
    }
    func testSameCanonicalCardIsFIFOEvenAcrossCollectionsAndInverseIntentsAreNotCoalesced() {
        var schedule = CardWriteSchedule()
        let move = UUID(), undo = UUID(), redo = UUID(), other = UUID()
        schedule.enqueue(.init(id: move, memo: "same", context: a))
        schedule.enqueue(.init(id: undo, memo: "same", context: b))
        schedule.enqueue(.init(id: redo, memo: "same", context: a))
        schedule.enqueue(.init(id: other, memo: "independent", context: b))
        XCTAssertEqual(schedule.takeAvailable(limit: 3), [move, other])
        schedule.finish(move)
        XCTAssertEqual(schedule.takeAvailable(limit: 3), [undo])
        schedule.finish(undo)
        XCTAssertEqual(schedule.takeAvailable(limit: 3), [redo])
        XCTAssertEqual(schedule.pending.map(\.id), [redo, other])
    }
    func testPendingContextIsRetainedWhileAnotherContextIsViewed() {
        var schedule = CardWriteSchedule()
        let id = UUID(); schedule.enqueue(.init(id: id, memo: "card", context: a))
        _ = schedule.takeAvailable(limit: 3)
        XCTAssertEqual(schedule.pending.first?.context, a)
        XCTAssertNotEqual(schedule.pending.first?.context, b)
    }
    func testOlderRefreshAndPreWriteRefreshCannotReplaceNewerAuthoritativeState() {
        var gate = BoardReadGate()
        let scope = BoardReadGate.Scope(workspace: "one", collection: "home")
        let older = gate.begin(scope), newer = gate.begin(scope)
        XCTAssertFalse(gate.accepts(older)); XCTAssertTrue(gate.accepts(newer))
        gate.confirmedWrite(scope)
        XCTAssertFalse(gate.accepts(newer))
        let afterWrite = gate.begin(scope)
        XCTAssertTrue(gate.accepts(afterWrite))
    }
    func testRefreshTicketsDoNotInvalidateAnIndependentWorkspace() {
        var gate = BoardReadGate()
        let first = BoardReadGate.Scope(workspace: "one", collection: "home")
        let second = BoardReadGate.Scope(workspace: "two", collection: "home")
        let ticket = gate.begin(first)
        _ = gate.begin(second); gate.confirmedWrite(second)
        XCTAssertTrue(gate.accepts(ticket))
    }
}
