import Foundation

/// A projection of a canonical card, never a second task record.
nonisolated struct WorkItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let project: String
    let state: String
    let taskURL: URL?

    func inColumn(field: String, value: String) -> Self {
        WorkItem(id: id, title: title, project: project, state: field == "status" ? value : state,
                 taskURL: taskURL)
    }
}


nonisolated enum SampleWork {
    static let items = [
        WorkItem(id: "sample-panel", title: "A quiet window into current work",
                 project: "Example project · Mac app", state: "Next", taskURL: nil),
        WorkItem(id: "sample-docs", title: "Make the handoff easier to follow",
                 project: "Example project · Documentation", state: "Doing", taskURL: nil),
        WorkItem(id: "sample-unknown", title: "Check the next milestone",
                 project: "Example project · Planning", state: "Waiting", taskURL: nil)
    ]
}
