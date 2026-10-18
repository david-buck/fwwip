import XCTest
@testable import FWWIPCore

final class SelectionTests: XCTestCase {
    private func item(_ id: String) -> WorkItem {
        WorkItem(id: id, title: id, project: "Example", state: "Next", taskURL: nil)
    }

    func testShowMoreUsesActualRemainingCards() {
        let fifty = (0..<50).map { item("item\($0)") }
        XCTAssertEqual(WorkSlice(items: fifty).items.count, 50)
        XCTAssertEqual(WorkSlice(items: fifty).remainingCount, 0)
        let all = fifty + [item("extra")]
        XCTAssertEqual(WorkSlice(items: all).items.count, 50)
        XCTAssertEqual(WorkSlice(items: all).remainingCount, 1)
        XCTAssertEqual(WorkSlice(items: all, visibleCount: 100).items.count, 51)
    }

    @MainActor
    func testWorkspacePreferenceSurvivesModelRecreation() throws {
        let domain = "FWWIPTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        let first = PanelModel(preferences: preferences)
        first.selectedWorkspaceID = "explicit-second-choice"
        let reopened = PanelModel(preferences: preferences)
        XCTAssertEqual(reopened.selectedWorkspaceID, "explicit-second-choice")
    }

    func testCollectionSelectionRevalidatesAndKeepsBacklogDefault() {
        let choices = [CollectionChoice(id: "one", name: "Project home"), CollectionChoice(id: "backlog", name: "Backlog")]
        XCTAssertEqual(CollectionSelection.resolvedID(preferredID: "one", collections: choices), "one")
        XCTAssertEqual(CollectionSelection.resolvedID(preferredID: "other-workspace", collections: choices), "backlog")
        XCTAssertEqual(CollectionSelection.resolvedID(preferredID: nil, collections: [choices[0]]), "one")
        XCTAssertNil(CollectionSelection.resolvedID(preferredID: "one", collections: []))
    }

    @MainActor
    func testWorkspaceChangeClearsCollectionWhileKeepingPerWorkspacePreferences() async throws {
        let domain = "FWWIPTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        preferences.set("old-workspace", forKey: "FWWIP.selectedWorkspaceID.v1")
        preferences.set(["old-workspace": "old-collection"], forKey: "FWWIP.collectionSelections.v1")
        let model = PanelModel(preferences: preferences)
        XCTAssertEqual(model.selectedCollectionID, "old-collection")
        await model.chooseWorkspace("new-workspace")
        XCTAssertNil(model.selectedCollectionID)
        XCTAssertTrue(model.collections.isEmpty)
        XCTAssertTrue(model.liveItems.isEmpty)
        XCTAssertEqual(model.remainingCount, 0)
        XCTAssertEqual(PanelModel(preferences: preferences).selectedWorkspaceID, "new-workspace")
        XCTAssertEqual(preferences.dictionary(forKey: "FWWIP.collectionSelections.v1")?["old-workspace"] as? String, "old-collection")
    }
}
