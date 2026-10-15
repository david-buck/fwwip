import XCTest
@testable import FWWIPCore

final class WorkModelTests: XCTestCase {
    func testUnknownDoesNotBecomeNoActionOrNeedsYou() {
        let unknown = WorkItem(id: "canonical-id", title: "Work", project: "Home", state: "Unknown",
                               update: nil, attention: .unknown, taskURL: nil, conversationURL: nil)
        XCTAssertNil(unknown.update)
        XCTAssertFalse(unknown.attention.needsYou)
        XCTAssertNotEqual(unknown.attention, .noAction(""))
        XCTAssertEqual(WorkFilter.needsYou.apply(to: [unknown]), [])
    }

    func testActionFilterPreservesCanonicalIdentityAndEvidence() {
        let result = WorkFilter.needsYou.apply(to: SampleWork.items)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first, SampleWork.items.first)
        XCTAssertEqual(WorkFilter.all.apply(to: SampleWork.items), SampleWork.items)
        XCTAssertEqual(result.first?.update?.occurredAt, Date(timeIntervalSince1970: 1_792_060_200))
        XCTAssertTrue(SampleWork.items.allSatisfy { $0.taskURL == nil && $0.conversationURL == nil })
    }

    func testUnconnectedReaderCannotReturnSampleAsLive() async {
        do {
            _ = try await UnconnectedFieldwerkReader().currentWork()
            XCTFail("Unauthenticated reads must not return fixture work")
        } catch {
            XCTAssertTrue(error is FieldwerkReadError)
        }
    }
}
