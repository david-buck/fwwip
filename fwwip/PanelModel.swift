import Foundation
import Observation

@MainActor @Observable
final class PanelModel {
    var filter: WorkFilter = .all { didSet { visibleCount = WorkSlice.size } }
    var selectedWorkspaceID: String? {
        didSet {
            if let selectedWorkspaceID { preferences.set(selectedWorkspaceID, forKey: Self.workspaceKey) }
            else { preferences.removeObject(forKey: Self.workspaceKey) }
        }
    }
    private(set) var workspaces: [WorkspaceChoice] = []
    private(set) var collections: [CollectionChoice] = []
    private(set) var selectedCollectionID: String?
    private(set) var selectedColumnID: String?
    private(set) var snapshot: BoardSnapshot?
    private(set) var lastFetchedAt: Date?
    private(set) var isConnected = false
    private(set) var isBusy = false
    private(set) var approvalReady = false
    private(set) var serviceMessage = "Sign in to Fieldwerk to load your work."
    private(set) var errorMessage: String?
    private(set) var moveMessage: String?
    private(set) var boardURL: URL?
    private var visibleCount = WorkSlice.size
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var collectionSelections: [String: String]
    @ObservationIgnored private var columnSelections: [String: String]
    private static let workspaceKey = "FWWIP.selectedWorkspaceID.v1"
    private static let collectionKey = "FWWIP.collectionSelections.v1"
    private static let columnKey = "FWWIP.columnSelections.v1"
    private let session = FieldwerkSession()
    @ObservationIgnored private lazy var reader = FieldwerkReader(session: session)
    private var loginTask: Task<Void, Never>?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        collectionSelections = preferences.dictionary(forKey: Self.collectionKey) as? [String: String] ?? [:]
        columnSelections = preferences.dictionary(forKey: Self.columnKey) as? [String: String] ?? [:]
        selectedWorkspaceID = preferences.string(forKey: Self.workspaceKey)
        selectedCollectionID = selectedWorkspaceID.flatMap { collectionSelections[$0] }
    }

    var columns: [BoardColumn] { snapshot?.columns ?? [] }
    var boardName: String { snapshot?.definition.name ?? "Columns" }
    var columnLabel: String { columns.first(where: { $0.id == selectedColumnID })?.label ?? "No columns" }
    private var columnItems: [WorkItem] { selectedColumnID.flatMap { snapshot?.itemsByColumn[$0] } ?? [] }
    private var filteredItems: [WorkItem] { filter.apply(to: columnItems) }
    var items: [WorkItem] { WorkSlice(items: filteredItems, visibleCount: visibleCount).items }
    var remainingCount: Int { WorkSlice(items: filteredItems, visibleCount: visibleCount).remainingCount }
    var columnCount: Int { columnItems.count }
    var filteredCount: Int { filteredItems.count }
    var liveItems: [WorkItem] { columns.flatMap { snapshot?.itemsByColumn[$0.id] ?? [] } }
    var actionCount: Int { columnItems.filter { $0.attention.needsYou }.count }
    var canRemoveSavedSignIn: Bool { isConnected || UserDefaults.standard.bool(forKey: OAuthPolicy.persistenceFlag) }
    private var selectionKey: String? {
        guard let workspace = selectedWorkspaceID, let collection = selectedCollectionID, let board = snapshot?.definition.id else { return nil }
        return "\(workspace)/\(collection)/\(board)"
    }

    func restore() async {
        guard !isBusy else { return }
        do {
            if try session.restorePreviouslyApprovedSession() { isConnected = true; await refresh() }
        } catch { serviceMessage = error.localizedDescription; errorMessage = serviceMessage }
    }
    func prepareSignIn() async {
        guard !isBusy else { return }
        isBusy = true; approvalReady = false; errorMessage = nil
        defer { isBusy = false }
        do {
            _ = try await session.prepare()
            approvalReady = true
            serviceMessage = session.hasRegisteredClient
                ? "Fieldwerk discovery verified. FWWIP’s existing registered client will be reused."
                : "Fieldwerk discovery verified. Review the exact access request below."
        } catch { serviceMessage = error.localizedDescription; errorMessage = serviceMessage }
    }
    func approveAndSignIn(rememberOnDevice: Bool) {
        guard approvalReady, !isBusy else { return }
        approvalReady = false; isBusy = true; errorMessage = nil
        serviceMessage = "Checking FWWIP’s approved sign-in setup, then opening Fieldwerk in your browser…"
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.loginTask = nil }
            do {
                try await self.session.signInAfterApproval(rememberOnDevice: rememberOnDevice)
                self.isConnected = true; self.filter = .all; self.reader.reset()
                self.serviceMessage = "Signed in. Loading workspaces…"
                try await self.loadWork()
            } catch { self.recordReadFailure(error) }
        }
    }
    func cancelSignIn() { loginTask?.cancel(); session.cancelSignIn() }
    func refresh() async {
        guard !isBusy, isConnected else { return }
        isBusy = true; errorMessage = nil; moveMessage = nil
        defer { isBusy = false }
        do { try await loadWork() }
        catch { recordReadFailure(error, prefix: "Refresh failed. ") }
    }
    private func clearWork() {
        moveMessage = nil
        snapshot = nil; selectedColumnID = nil; lastFetchedAt = nil; boardURL = nil; visibleCount = WorkSlice.size
    }
    func chooseWorkspace(_ id: String?) async {
        guard !isBusy, id != selectedWorkspaceID else { return }
        selectedWorkspaceID = id; selectedCollectionID = nil; collections = []; clearWork()
        await refresh()
    }
    func chooseCollection(_ id: String?) async {
        guard !isBusy, id != selectedCollectionID,
              collections.contains(where: { $0.id == id }), let workspaceID = selectedWorkspaceID else { return }
        selectedCollectionID = id; collectionSelections[workspaceID] = id
        preferences.set(collectionSelections, forKey: Self.collectionKey)
        clearWork(); await refresh()
    }
    func chooseColumn(_ id: String?) {
        guard !isBusy, let id, columns.contains(where: { $0.id == id }) else { return }
        selectedColumnID = id; visibleCount = WorkSlice.size
        if let key = selectionKey { columnSelections[key] = id; preferences.set(columnSelections, forKey: Self.columnKey) }
    }
    func cycleColumn(_ direction: Int) { chooseColumn(ColumnSelection.cycledID(current: selectedColumnID, direction: direction, columns: columns)) }
    func loadMore() { visibleCount += WorkSlice.size }

    var moveLimitation: String? { snapshot.flatMap { BoardMove.limitation($0) } }
    func move(_ item: WorkItem, to destination: String) async {
        guard !isBusy, isConnected, let snapshot, let collection = selectedCollectionID,
              let source = selectedColumnID, columnItems.contains(where: { $0.id == item.id }) else { return }
        isBusy = true; errorMessage = nil; moveMessage = "Moving card…"
        defer { isBusy = false }
        do {
            try await BoardMove.move(id: item.id, source: source, destination: destination,
                                     collection: collection, snapshot: snapshot, access: reader)
            // Success is shown only after canonical read-back AND a fresh board read.
            try await loadWork()
            moveMessage = "Moved to \(destination.isEmpty ? "Not set" : destination)."
        } catch {
            moveMessage = nil
            recordReadFailure(error, prefix: "Move not confirmed. ")
        }
    }

    private func recordReadFailure(_ error: Error, prefix: String = "") {
        serviceMessage = prefix + error.localizedDescription; errorMessage = serviceMessage
        if case FieldwerkReadError.unsupportedBoard(_, let url) = error { clearWork(); boardURL = url }
        if let issue = error as? OAuthIssue {
            switch issue {
            case .signedOut, .expiredCleanup, .rejected("invalid_grant"), .rejected("invalid_client"), .network(401):
                isConnected = false; clearWork()
            default: break
            }
        }
    }
    private func loadWork() async throws {
        workspaces = try await reader.workspaces()
        let workspaceID = WorkspaceSelection.resolvedID(preferredID: selectedWorkspaceID, workspaces: workspaces)
        if workspaceID != selectedWorkspaceID { collections = []; selectedCollectionID = nil; clearWork() }
        selectedWorkspaceID = workspaceID
        guard let workspace = workspaces.first(where: { $0.id == selectedWorkspaceID }) else {
            clearWork(); serviceMessage = "No available workspaces."; return
        }
        collections = try await reader.collections(in: workspace)
        let collectionID = CollectionSelection.resolvedID(preferredID: collectionSelections[workspace.id], collections: collections)
        if collectionID != selectedCollectionID { clearWork() }
        selectedCollectionID = collectionID; collectionSelections[workspace.id] = collectionID
        preferences.set(collectionSelections, forKey: Self.collectionKey)
        guard let collection = collections.first(where: { $0.id == collectionID }) else {
            clearWork(); serviceMessage = "No available collections."; return
        }
        let loaded = try await reader.work(in: collection)
        applySnapshot(loaded)
    }
    func applySnapshot(_ loaded: BoardSnapshot) {
        snapshot = loaded; boardURL = loaded.definition.safeURL
        let preferred = selectionKey.flatMap { columnSelections[$0] }
        selectedColumnID = ColumnSelection.resolvedID(preferredID: preferred, columns: loaded.columns)
        if let key = selectionKey, let selectedColumnID {
            columnSelections[key] = selectedColumnID; preferences.set(columnSelections, forKey: Self.columnKey)
        }
        visibleCount = WorkSlice.size; lastFetchedAt = .now
        serviceMessage = "Loaded the selected Fieldwerk board."
    }
    func logout() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        clearWork(); workspaces = []; collections = []; selectedCollectionID = nil
        isConnected = false; approvalReady = false; errorMessage = nil; reader.reset()
        do {
            let revoked = try await session.logout()
            serviceMessage = revoked ? "Signed out. FWWIP’s saved tokens were removed." : "Signed out locally. Revoke FWWIP in Fieldwerk’s connected apps; remote revocation could not be confirmed."
        } catch {
            serviceMessage = "Signed out of this window, but saved-token removal failed. \(error.localizedDescription)"; errorMessage = serviceMessage
        }
    }
}
