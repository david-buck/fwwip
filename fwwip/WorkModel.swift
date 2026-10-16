import Foundation

/// A projection of a canonical card, never a second task record.
nonisolated struct WorkItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let project: String
    let state: String
    let update: MeaningfulUpdate?
    let attention: Attention
    let taskURL: URL?
    let conversationURL: URL?
    var verifiedAt: Date? = nil
    var evidenceURL: URL? = nil

    func inColumn(field: String, value: String) -> Self {
        WorkItem(id: id, title: title, project: project, state: field == "status" ? value : state,
                 update: update, attention: attention, taskURL: taskURL, conversationURL: conversationURL,
                 verifiedAt: verifiedAt, evidenceURL: evidenceURL)
    }
}

nonisolated struct MeaningfulUpdate: Equatable, Sendable {
    let text: String
    let occurredAt: Date
    /// Where the assertion came from; activity timestamps alone are not evidence.
    let source: String
}

nonisolated enum Attention: Equatable, Sendable {
    case needsYou(String)
    case noAction(String)
    case unknown

    var needsYou: Bool {
        if case .needsYou = self { true } else { false }
    }
}

nonisolated enum WorkFilter: String, CaseIterable, Identifiable {
    case all, needsYou
    var id: Self { self }

    func apply(to items: [WorkItem]) -> [WorkItem] {
        self == .all ? items : items.filter { $0.attention.needsYou }
    }
}

/// Static test fixtures. No sample controls or fixtures appear in the normal app UI.
nonisolated enum SampleWork {
    static let items: [WorkItem] = [
        WorkItem(
            id: "sample-panel", title: "A quiet window into current work", project: "Example project · Mac app",
            state: "In progress",
            update: MeaningfulUpdate(
                text: "The first panel is ready to review. Work, the latest update, and the next decision now sit together.",
                occurredAt: Date(timeIntervalSince1970: 1_792_060_200), source: "Example authored progress note"
            ),
            attention: .needsYou("Review the panel and decide what should count as a meaningful update."),
            taskURL: nil, conversationURL: nil
        ),
        WorkItem(
            id: "sample-docs", title: "Make the handoff easier to follow", project: "Example project · Documentation",
            state: "In progress",
            update: MeaningfulUpdate(
                text: "The draft now includes the setup steps and a short review checklist.",
                occurredAt: Date(timeIntervalSince1970: 1_792_055_400), source: "Example authored progress note"
            ),
            attention: .noAction("The draft is still being prepared. No decision is requested."),
            taskURL: nil, conversationURL: nil
        ),
        WorkItem(
            id: "sample-unknown", title: "Check the next milestone", project: "Example project · Planning",
            state: "Status unverified", update: nil, attention: .unknown,
            taskURL: nil, conversationURL: nil
        )
    ]
}
