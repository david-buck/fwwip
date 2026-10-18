import XCTest
@testable import FWWIPCore

final class WorkModelTests: XCTestCase {
    func testUnconnectedReaderCannotReturnLiveWork() async {
        do {
            _ = try await UnconnectedFieldwerkReader().currentWork()
            XCTFail("Unauthenticated reads must not return live work")
        } catch {
            XCTAssertTrue(error is FieldwerkReadError)
        }
    }
}
