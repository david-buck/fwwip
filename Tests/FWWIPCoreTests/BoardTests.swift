import XCTest
@testable import FWWIPCore

final class BoardTests: XCTestCase {
    private func definition(order: [String] = ["Triage", "Review", "Closed"], hidden: [String] = [],
                            scope: String = "memo", sort: [String: String]? = nil) throws -> BoardDefinition {
        var object: [String: Any] = ["id": "board", "name": "Work board", "display": "board", "group_by": "status",
            "group_by_scope": scope, "columns": ["order": order, "hidden": hidden], "where": [], "position": 1]
        if let sort { object["sort"] = sort }
        return try JSONDecoder().decode(BoardDefinition.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func card(_ id: String, status: String, edge: String? = nil) throws -> FieldwerkCard {
        var object: [String: Any] = ["id": id, "title": id, "url": "https://my.fieldwerk.ai/m/\(id)", "fields": ["status": status]]
        if let edge { object["collection_fields"] = ["status": edge] }
        return try JSONDecoder().decode(FieldwerkCard.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testConfiguredEmptyColumnsAndNotSetAreRetainedWithoutHardcodedStatuses() throws {
        let snapshot = try BoardSnapshot(definition: definition(), cards: [card("a", status: "Review")])
        XCTAssertEqual(snapshot.columns.map(\.id), ["Triage", "Review", "Closed", ""])
        XCTAssertNil(snapshot.itemsByColumn["Triage"])
        XCTAssertEqual(snapshot.itemsByColumn["Review"]?.map(\.id), ["a"])
    }
    func testOnlyExplicitHiddenColumnsAreHiddenAndNewValuesAreNotLost() throws {
        let snapshot = try BoardSnapshot(definition: definition(hidden: ["Review"]), cards: [card("a", status: "Other")])
        XCTAssertEqual(snapshot.columns.map(\.id), ["Triage", "Closed", "Other", ""])
    }
    func testGroupingRetainsEndpointOrderAndDoesNotUseTabPositionAsRank() throws {
        let rows = try [card("z", status: "Review"), card("a", status: "Triage"), card("b", status: "Review")]
        let snapshot = try BoardSnapshot(definition: definition(), cards: rows)
        XCTAssertEqual(snapshot.itemsByColumn["Review"]?.map(\.id), ["z", "b"])
        XCTAssertEqual(snapshot.itemsByColumn["Triage"]?.map(\.id), ["a"])
    }
    func testColumnScopeUsesItsOwnLayerAndMemoScopeUsesCanonicalLayer() throws {
        var row = try card("a", status: "Edge", edge: "Edge")
        try row.useCanonicalFields(Data("{\"fields\":{\"status\":\"Own\"}}".utf8))
        let memo = try BoardSnapshot(definition: definition(order: ["Own", "Edge"]), cards: [row])
        let collection = try BoardSnapshot(definition: definition(order: ["Own", "Edge"], scope: "collection"), cards: [row])
        XCTAssertEqual(memo.itemsByColumn["Own"]?.map(\.id), ["a"])
        XCTAssertEqual(collection.itemsByColumn["Edge"]?.map(\.id), ["a"])
    }
    func testCycleWrapsAndStaleSelectionRevalidates() {
        let columns = [BoardColumn(id: "A"), BoardColumn(id: "B"), BoardColumn(id: "")]
        XCTAssertEqual(ColumnSelection.cycledID(current: "A", direction: -1, columns: columns), "")
        XCTAssertEqual(ColumnSelection.cycledID(current: "", direction: 1, columns: columns), "A")
        XCTAssertEqual(ColumnSelection.resolvedID(preferredID: "removed", columns: columns), "A")
        XCTAssertEqual(ColumnSelection.resolvedID(preferredID: "", columns: columns), "")
        XCTAssertNil(ColumnSelection.cycledID(current: nil, direction: 1, columns: []))
    }
    func testCustomSortIsAnActualUnsupportedConfigurationNotMissingManualRanks() throws {
        XCTAssertNoThrow(try BoardSnapshot(definition: definition(), cards: []))
        XCTAssertThrowsError(try BoardSnapshot(definition: definition(sort: ["field": "priority", "direction": "asc"]), cards: []))
    }
    @MainActor
    func testColumnPreferencePersistsAndContextChangeClearsStaleCards() async throws {
        let domain = "FWWIPTests." + UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { prefs.removePersistentDomain(forName: domain) }
        prefs.set("workspace", forKey: "FWWIP.selectedWorkspaceID.v1")
        prefs.set(["workspace": "collection"], forKey: "FWWIP.collectionSelections.v1")
        let snapshot = try BoardSnapshot(definition: definition(), cards: [card("a", status: "Review")])
        let model = PanelModel(preferences: prefs)
        model.applySnapshot(snapshot); model.chooseColumn("Review")
        XCTAssertEqual(model.items.map(\.id), ["a"])
        let reopened = PanelModel(preferences: prefs); reopened.applySnapshot(snapshot)
        XCTAssertEqual(reopened.selectedColumnID, "Review")
        await reopened.chooseWorkspace("different")
        XCTAssertNil(reopened.snapshot); XCTAssertNil(reopened.selectedColumnID)
        XCTAssertTrue(reopened.items.isEmpty)
    }
}
