import XCTest
@testable import FWWIPCore

final class MetadataTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_080_000)
    private var complete: [String: Any] { [
        "project": "Example", "status": "Doing", "kind": "Task",
        "wip_update": "The bounded local fix passed its acceptance checks.",
        "wip_occurred_at": "2026-10-15T06:00:00Z",
        "wip_verified_at": "2026-10-15T06:05:00Z",
        "wip_evidence_url": "https://my.fieldwerk.ai/m/example",
        "wip_needs_user": true,
        "wip_action_reason": "Review the local comparison before selecting the next change.",
        "wip_action_recipient": "David",
        "wip_conversation_url": "https://chatgpt.com/c/example",
        "wip_conversation_verified_at": "2026-10-15T06:05:00Z"
    ] }
    private func card(_ fields: [String: Any], id: String = "example") throws -> FieldwerkCard {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "title": "Work", "url": "https://my.fieldwerk.ai/m/\(id)", "fields": fields])
        return try JSONDecoder().decode(FieldwerkCard.self, from: data)
    }

    func testCompleteExplicitMetadataProjectsEvidenceAndRequest() throws {
        let item = try card(complete).projected(now: now)
        XCTAssertEqual(item.update?.text, complete["wip_update"] as? String)
        XCTAssertLessThan(try XCTUnwrap(item.update?.occurredAt), try XCTUnwrap(item.verifiedAt))
        XCTAssertTrue(item.attention.needsYou)
        XCTAssertEqual(item.evidenceURL?.absoluteString, complete["wip_evidence_url"] as? String)
        XCTAssertEqual(item.conversationURL?.absoluteString, complete["wip_conversation_url"] as? String)
        XCTAssertEqual(item.state, "Doing")
    }
    func testMissingAndStringBooleanCannotCreateAction() throws {
        XCTAssertEqual(try card(["status": "Waiting", "sync": "Needs review"]).projected(now: now).attention, .unknown)
        var fields = complete; fields["wip_needs_user"] = "true"
        XCTAssertEqual(try card(fields).projected(now: now).attention, .unknown)
        fields = complete; fields.removeValue(forKey: "wip_action_reason")
        XCTAssertEqual(try card(fields).projected(now: now).attention, .unknown)
        fields = complete; fields["wip_action_recipient"] = "Someone else"
        XCTAssertEqual(try card(fields).projected(now: now).attention, .unknown)
    }
    func testNoActionRequiresExplicitEvidenceAndReason() throws {
        var fields = complete; fields["wip_needs_user"] = false
        XCTAssertEqual(try card(fields).projected(now: now).attention, .noAction(fields["wip_action_reason"] as! String))
        fields.removeValue(forKey: "wip_verified_at")
        XCTAssertEqual(try card(fields).projected(now: now).attention, .unknown)
    }
    func testInvalidOrFutureEvidenceCannotAssertProgress() throws {
        for (key, value) in [("wip_verified_at", "tomorrow"), ("wip_verified_at", "2099-01-01T00:00:00Z"),
                             ("wip_evidence_url", "file:///tmp/evidence"), ("wip_evidence_url", "https://user:secret@example.com/proof")] {
            var fields = complete; fields[key] = value
            let item = try card(fields).projected(now: now)
            XCTAssertNil(item.update); XCTAssertEqual(item.attention, .unknown)
        }
        var fields = complete; fields["wip_occurred_at"] = "2026-10-15T07:00:00Z"
        XCTAssertNil(try card(fields).projected(now: now).update)
    }
    func testConversationNeedsItsOwnVerificationAndHTTPS() throws {
        for (key, value) in [("wip_conversation_verified_at", "not a date"),
                             ("wip_conversation_url", "javascript:alert(1)"),
                             ("wip_conversation_url", "https://user:password@example.com/chat")] {
            var fields = complete; fields[key] = value
            XCTAssertNil(try card(fields).projected(now: now).conversationURL)
        }
        var fields = complete; fields.removeValue(forKey: "wip_conversation_verified_at")
        XCTAssertNil(try card(fields).projected(now: now).conversationURL)
    }
    func testShowMoreUsesActualRemainingCards() throws {
        let fifty = try (0..<50).map { try card([:], id: "item\($0)").projected(now: now) }
        XCTAssertEqual(WorkSlice(items: fifty).items.count, 50)
        XCTAssertEqual(WorkSlice(items: fifty).remainingCount, 0)
        let all = fifty + [try card([:], id: "extra").projected(now: now)]
        XCTAssertEqual(WorkSlice(items: all).items.count, 50)
        XCTAssertEqual(WorkSlice(items: all).remainingCount, 1)
        XCTAssertEqual(WorkSlice(items: all, visibleCount: 100).items.count, 51)
    }
    func testWorkspaceSelectionKeepsValidChoiceAndFallsBackOnlyWhenNeeded() {
        let choices = [WorkspaceChoice(id: "first", name: "One"), WorkspaceChoice(id: "saved", name: "Two")]
        XCTAssertEqual(WorkspaceSelection.resolvedID(preferredID: "saved", workspaces: choices), "saved")
        XCTAssertEqual(WorkspaceSelection.resolvedID(preferredID: nil, workspaces: choices), "first")
        XCTAssertEqual(WorkspaceSelection.resolvedID(preferredID: "removed", workspaces: choices), "first")
        XCTAssertNil(WorkspaceSelection.resolvedID(preferredID: "saved", workspaces: []))
    }
    func testCanonicalMemoCannotInheritAnActionFromCollectionOverlay() throws {
        var listed = try card(complete)
        XCTAssertTrue(try listed.projected(now: now).attention.needsYou)
        try listed.useCanonicalMetadata(Data("{\"fields\":{}}".utf8))
        let canonical = try listed.projected(now: now)
        XCTAssertEqual(canonical.attention, .unknown)
        XCTAssertNil(canonical.update)
        XCTAssertNil(canonical.conversationURL)
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
