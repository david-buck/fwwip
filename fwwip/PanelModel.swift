import Foundation
import AppKit
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
    private(set) var backgroundFailureMessage: String?
    private var backgroundFailureContext: BoardContext?
    let moveHistory = CardMoveHistory()
    private(set) var boardURL: URL?
    var isWriting: Bool { !writeSchedule.pending.isEmpty }
    var pendingCount: Int { writeSchedule.pending.count }
    private(set) var isLoadingWork = false
    private var boardStates: [BoardContext: OptimisticBoardState] = [:]
    private var currentContext: BoardContext?
    private var readGate = BoardReadGate()
    private var contextErrors: [BoardContext: String] = [:]
    private var contextErrorRevisions: [BoardContext: Int] = [:]
    private var contextIntents: [BoardContext: Int] = [:]
    private var readGeneration = 0
    private enum MutationKind { case move(BoardSnapshot), inverse(MoveHistoryEntry, Bool) }
    private struct Mutation { let placement: PendingPlacement; let context: BoardContext; let kind: MutationKind }
    private var mutations: [UUID: Mutation] = [:]
    private var writeSchedule = CardWriteSchedule()
    private var mutationRevision = 0
    private var latestMoveIntent = 0
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
        errorMessage = nil
        if let currentContext { contextErrors[currentContext] = nil }
        do { try await loadWork() }
        catch { recordReadFailure(error, prefix: "Refresh failed. ") }
    }
    private func clearWork() {
        currentContext = nil
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
    var canUndoMove: Bool { isConnected && !isBusy && moveHistory.canUndo }
    var canRedoMove: Bool { isConnected && !isBusy && moveHistory.canRedo }
    func undoMove() { guard canUndoMove else { return }; moveHistory.undo() }
    func redoMove() { guard canRedoMove else { return }; moveHistory.redo() }

    private func enqueueInverse(_ entry: MoveHistoryEntry, undo: Bool, context: BoardContext) {
        let receipt = entry.receipt
        enqueue(item: entry.item, field: receipt.field,
                source: (undo ? receipt.writtenValue : receipt.previousValue) ?? "",
                destination: (undo ? receipt.previousValue : receipt.writtenValue) ?? "",
                context: context, kind: .inverse(entry, undo))
    }
    func move(_ item: WorkItem, to destination: String) async {
        guard !isBusy, isConnected, let snapshot, let context = currentContext,
              let source = selectedColumnID, source != destination,
              snapshot.columns.contains(where: { $0.id == destination }),
              columnItems.contains(where: { $0.id == item.id }), let field = snapshot.definition.group_by else { return }
        if let reason = moveLimitation { errorMessage = reason; return }
        moveHistory.clear()
        enqueue(item: item, field: field, source: source, destination: destination,
                context: context, kind: .move(snapshot))
        latestMoveIntent = mutationRevision
    }
    private func enqueue(item: WorkItem, field: String, source: String, destination: String,
                         context: BoardContext, kind: MutationKind) {
        mutationRevision += 1
        let placement = PendingPlacement(id: UUID(), revision: mutationRevision, item: item,
                                         field: field, source: source, destination: destination)
        mutations[placement.id] = Mutation(placement: placement, context: context, kind: kind)
        writeSchedule.enqueue(.init(id: placement.id, memo: item.id, context: context))
        boardStates[context]?.enqueue(placement)
        contextIntents[context] = placement.revision
        contextErrors[context] = nil
        updateVisibleContext(context)
        if currentContext == context { chooseColumn(destination) }
        startAvailableWrites()
    }
    private func startAvailableWrites() {
        for id in writeSchedule.takeAvailable(limit: 3) {
            guard let mutation = mutations[id] else { continue }
            Task { [self] in await perform(mutation) }
        }
    }
    private func updateVisibleContext(_ context: BoardContext) {
        guard currentContext == context else { return }
        snapshot = boardStates[context]?.snapshot
        errorMessage = contextErrors[context]
    }
    private func perform(_ mutation: Mutation) async {
        let placement = mutation.placement, context = mutation.context
        defer {
            mutations[placement.id] = nil; writeSchedule.finish(placement.id)
            startAvailableWrites()
        }
        do {
            switch mutation.kind {
            case .move(let board):
                let receipt = try await BoardMove.move(id: placement.item.id, source: placement.source,
                    destination: placement.destination, collection: context.collection, snapshot: board, access: reader)
                // Completion order across independent cards cannot replace a newer user action's history.
                if placement.revision == latestMoveIntent {
                    moveHistory.record(receipt, item: placement.item, onRequest: { [weak self] entry, undo in
                        self?.enqueueInverse(entry, undo: undo, context: context)
                    })
                }
            case .inverse(let entry, let undo):
                let confirmed = try await undo ? BoardMove.undo(entry.receipt, access: reader)
                    : BoardMove.redo(entry.receipt, access: reader)
                moveHistory.complete(entry, confirmed: confirmed)
            }
            boardStates[context]?.finish(placement.id, succeeded: true)
            readGate.confirmedWrite(.init(workspace: context.workspace, collection: context.collection))
            if contextIntents[context] == placement.revision {
                switch mutation.kind {
                case .move: announce("Moved \(placement.item.title) to \(placement.destination.isEmpty ? "Not set" : placement.destination).")
                case .inverse(_, let undo): announce(undo ? "Move undone." : "Move redone.")
                }
            }
            updateVisibleContext(context)
            do { try await refreshContext(context) }
            catch { setContextFailure(error, context: context, revision: placement.revision, prefix: "Change verified; refresh failed. ") }
        } catch {
            if case .inverse(let entry, _) = mutation.kind { moveHistory.fail(entry) }
            boardStates[context]?.finish(placement.id, succeeded: false)
            let prefix: String
            switch mutation.kind {
            case .move: prefix = "Move not confirmed. "
            case .inverse(_, let undo): prefix = undo ? "Undo not confirmed. " : "Redo not confirmed. "
            }
            setContextFailure(error, context: context, revision: placement.revision, prefix: prefix)
            // Refetch only this context. Newer optimistic placements remain over that base.
            do {
                try await refreshContext(context)
                if currentContext == context,
                   let column = boardStates[context]?.rollbackColumn(for: placement, selected: selectedColumnID,
                                                                     latestRevision: contextIntents[context]) {
                    chooseColumn(column)
                }
            }
            catch { setContextFailure(error, context: context, revision: placement.revision, prefix: prefix + "Refresh failed. ") }
        }
    }
    private func setContextFailure(_ error: Error, context: BoardContext, revision: Int, prefix: String) {
        guard revision >= contextErrorRevisions[context, default: -1] else { return }
        contextErrorRevisions[context] = revision
        let earlier = revision < contextIntents[context, default: revision] ? "Earlier change: " : ""
        contextErrors[context] = earlier + prefix + error.localizedDescription
        if currentContext != context {
            backgroundFailureContext = context
            backgroundFailureMessage = "A background change failed. Return to its collection to review."
        }
        announce(prefix + error.localizedDescription)
        updateVisibleContext(context)
    }
    private func announce(_ message: String) {
        guard let application = NSApp else { return }
        NSAccessibility.post(element: application, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    private func refreshContext(_ context: BoardContext) async throws {
        let ticket = readGate.begin(.init(workspace: context.workspace, collection: context.collection))
        let loaded: BoardSnapshot
        do { loaded = try await reader.work(in: CollectionChoice(id: context.collection, name: "")) }
        catch { guard readGate.accepts(ticket) else { return }; throw error }
        guard readGate.accepts(ticket) else { return }
        if loaded.definition.id == context.board {
            boardStates[context]?.replaceBase(loaded)
            updateVisibleContext(context)
            if currentContext == context { lastFetchedAt = .now }
        } else if currentContext == context { applySnapshot(loaded) }
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
        readGeneration += 1
        let generation = readGeneration
        isLoadingWork = true
        defer { if generation == readGeneration { isLoadingWork = false } }
        do {
            let fetchedWorkspaces = try await reader.workspaces()
            guard generation == readGeneration else { return }
            workspaces = fetchedWorkspaces
            let workspaceID = WorkspaceSelection.resolvedID(preferredID: selectedWorkspaceID, workspaces: workspaces)
            if workspaceID != selectedWorkspaceID { collections = []; selectedCollectionID = nil; clearWork() }
            selectedWorkspaceID = workspaceID
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
                clearWork(); serviceMessage = "No available workspaces."; return
            }
            let fetchedCollections = try await reader.collections(in: workspace)
            guard generation == readGeneration, selectedWorkspaceID == workspace.id else { return }
            collections = fetchedCollections
            let collectionID = CollectionSelection.resolvedID(preferredID: collectionSelections[workspace.id], collections: collections)
            if collectionID != selectedCollectionID { clearWork() }
            selectedCollectionID = collectionID; collectionSelections[workspace.id] = collectionID
            preferences.set(collectionSelections, forKey: Self.collectionKey)
            guard let collection = collections.first(where: { $0.id == collectionID }) else {
                clearWork(); serviceMessage = "No available collections."; return
            }
            let ticket = readGate.begin(.init(workspace: workspace.id, collection: collection.id))
            let loaded = try await reader.work(in: collection)
            guard generation == readGeneration, selectedWorkspaceID == workspace.id, selectedCollectionID == collection.id else { return }
            let context = BoardContext(workspace: workspace.id, collection: collection.id, board: loaded.definition.id)
            guard readGate.accepts(ticket) else {
                if let base = boardStates[context]?.base { applySnapshot(base) }
                try await refreshContext(context)
                return
            }
            applySnapshot(loaded)
        } catch {
            guard generation == readGeneration else { return }
            throw error
        }
    }
    func applySnapshot(_ loaded: BoardSnapshot) {
        guard let workspace = selectedWorkspaceID, let collection = selectedCollectionID else { return }
        let context = BoardContext(workspace: workspace, collection: collection, board: loaded.definition.id)
        var state = boardStates[context] ?? OptimisticBoardState()
        state.replaceBase(loaded); boardStates[context] = state; currentContext = context
        snapshot = state.snapshot; boardURL = loaded.definition.safeURL
        if backgroundFailureContext == context { backgroundFailureMessage = nil; backgroundFailureContext = nil }
        errorMessage = contextErrors[context]
        let preferred = selectionKey.flatMap { columnSelections[$0] }
        selectedColumnID = ColumnSelection.resolvedID(preferredID: preferred, columns: loaded.columns)
        if let key = selectionKey, let selectedColumnID {
            columnSelections[key] = selectedColumnID; preferences.set(columnSelections, forKey: Self.columnKey)
        }
        visibleCount = WorkSlice.size; lastFetchedAt = .now
        serviceMessage = "Loaded the selected Fieldwerk board."
    }
    func logout() async {
        guard !isBusy, !isWriting else { return }
        isBusy = true
        defer { isBusy = false }
        clearWork(); workspaces = []; collections = []; selectedCollectionID = nil
        moveHistory.clear()
        isConnected = false; approvalReady = false; errorMessage = nil; reader.reset()
        do {
            let revoked = try await session.logout()
            serviceMessage = revoked ? "Signed out. FWWIP’s saved tokens were removed." : "Signed out locally. Revoke FWWIP in Fieldwerk’s connected apps; remote revocation could not be confirmed."
        } catch {
            serviceMessage = "Signed out of this window, but saved-token removal failed. \(error.localizedDescription)"; errorMessage = serviceMessage
        }
    }
}
