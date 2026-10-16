import SwiftUI

struct ContentView: View {
    let model: PanelModel
    @State private var showConnection = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isConnected {
                WorkspaceHeader(model: model, showConnection: { showConnection = true })
                WorkList(model: model).id("\(model.selectedColumnID ?? "none")/\(model.filter.rawValue)")
            } else {
                DisconnectedView(isBusy: model.isBusy, error: model.errorMessage,
                                 showConnection: { showConnection = true })
            }
        }
        .frame(minWidth: 400, idealWidth: 440, maxWidth: 560, minHeight: 420, idealHeight: 660)
        .background(.regularMaterial)
        .task { await model.restore() }
        .sheet(isPresented: $showConnection) {
            ConnectionView(model: model, dismiss: { showConnection = false })
        }
    }
}

private struct WorkspaceHeader: View {
    let model: PanelModel
    let showConnection: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Picker("Workspace", selection: Binding(
                get: { model.selectedWorkspaceID },
                set: { id in Task { await model.chooseWorkspace(id) } }
            )) {
                if model.workspaces.isEmpty { Text("No workspaces").tag(String?.none) }
                ForEach(model.workspaces) { workspace in
                    Text(workspace.name).tag(Optional(workspace.id))
                }
            }
            .labelsHidden()
            .buttonSizing(.flexible)
            .frame(maxWidth: .infinity)
            .disabled(model.isBusy)

            Picker("Collection", selection: Binding(
                get: { model.selectedCollectionID },
                set: { id in Task { await model.chooseCollection(id) } }
            )) {
                if model.collections.isEmpty { Text("No collections").tag(String?.none) }
                ForEach(model.collections) { collection in
                    Text(collection.name).tag(Optional(collection.id))
                }
            }
            .labelsHidden()
            .buttonSizing(.flexible)
            .frame(maxWidth: .infinity)
            .disabled(model.isBusy)

            ColumnNavigation(model: model)
            HStack(alignment: .firstTextBaseline) {
                if let fetchedAt = model.lastFetchedAt {
                    Text("Fetched \(fetchedAt, format: .dateTime.hour().minute())")
                        .foregroundStyle(.secondary)
                } else if model.isBusy || model.isLoadingWork {
                    Text("Loading work…").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Needs you (\(model.actionCount))", isOn: Binding(
                    get: { model.filter == .needsYou },
                    set: { model.filter = $0 ? .needsYou : .all }
                ))
                .toggleStyle(.button)
                .disabled(model.snapshot == nil)
                .help("Show confirmed requests in this column")
                Button("Details", action: showConnection).buttonStyle(.link)
            }
            .font(.caption)
            if let failure = model.backgroundFailureMessage {
                Text(failure).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
    }
}

private struct ColumnNavigation: View {
    let model: PanelModel
    var body: some View {
        HStack(spacing: 12) {
            Button { model.cycleColumn(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous column")
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .help("Previous column (⌥⌘←)")
            VStack(spacing: 3) {
                Text(model.boardName).font(.caption).foregroundStyle(.secondary)
                Text(model.columnLabel).font(.headline)
                if model.snapshot != nil {
                    Group {
                        if model.columnCount == 1 { Text("1 card") }
                        else { Text("\(model.columnCount) cards") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            Button { model.cycleColumn(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next column")
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .help("Next column (⌥⌘→)")
        }
        .disabled(model.isBusy || model.columns.count < 2)
        .frame(maxWidth: .infinity)
    }
}

private struct WorkList: View {
    let model: PanelModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.items) { item in
                    WorkCard(item: item, destinations: model.columns.filter { $0.id != model.selectedColumnID },
                             moveLimitation: model.moveLimitation, isBusy: model.isBusy,
                             move: { destination in Task { await model.move(item, to: destination) } })
                }
                if model.items.isEmpty && !model.isBusy {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.isLoadingWork ? "Loading work…" : model.snapshot == nil ? "No work loaded."
                             : model.filter == .needsYou ? "No confirmed requests for you in this column."
                             : "No cards in this column.")
                            .font(.callout).foregroundStyle(.secondary)
                        if model.snapshot == nil, let url = model.boardURL { Link("Open in Fieldwerk", destination: url) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
                }
                if model.remainingCount > 0 {
                    Button("Show more (\(model.remainingCount) remaining)") { model.loadMore() }
                        .disabled(model.isBusy).padding(.vertical, 8)
                }
                if model.isBusy || model.isLoadingWork { ProgressView().controlSize(.small).padding(8) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

private struct DisconnectedView: View {
    let isBusy: Bool
    let error: String?
    let showConnection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to Fieldwerk").font(.title2).fontWeight(.semibold)
            Text("Open your browser to approve FWWIP and see your current work.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if isBusy { ProgressView().controlSize(.small) }
            Button("Connect to Fieldwerk", action: showConnection)
                .buttonStyle(.borderedProminent).disabled(isBusy)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct WorkCard: View {
    let item: WorkItem
    let destinations: [BoardColumn]
    let moveLimitation: String?
    let isBusy: Bool
    let move: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.project).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 5)
                    Text(item.state).font(.caption).foregroundStyle(.secondary)
                }
                Text(item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            if let update = item.update {
                VStack(alignment: .leading, spacing: 6) {
                    Text(update.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(update.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                        .help(update.source)
                }
            } else {
                Text("Progress update not recorded.").font(.caption).foregroundStyle(.secondary)
            }
            AttentionView(attention: item.attention)
            if let verifiedAt = item.verifiedAt {
                Text("Verified \(verifiedAt, format: .dateTime.month(.abbreviated).day().hour().minute())")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                SourceLink(title: "Task", icon: "arrow.up.right", url: item.taskURL)
                if let evidenceURL = item.evidenceURL {
                    SourceLink(title: "Evidence", icon: "checkmark.seal", url: evidenceURL)
                }
                if let conversationURL = item.conversationURL {
                    SourceLink(title: "Conversation", icon: "bubble.left", url: conversationURL)
                }
                Spacer(minLength: 0)
                Menu("Move to") {
                    if let moveLimitation { Text(moveLimitation) }
                    else {
                        ForEach(destinations) { column in
                            Button(column.label) { move(column.id) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isBusy)
                .accessibilityLabel("Move \(item.title) to column")
            }.font(.caption)
        }
        .padding(16)
        .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
    }
}

private struct AttentionView: View {
    let attention: Attention

    var body: some View {
        switch attention {
        case .needsYou(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("Needs you", systemImage: "hand.raised.fill").fontWeight(.semibold)
                Text(reason)
            }
            .font(.caption).fixedSize(horizontal: false, vertical: true)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
        case .noAction(let reason):
            Label("No action needed: \(reason)", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unknown:
            Text("Action status not recorded.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SourceLink: View {
    let title: LocalizedStringResource
    let icon: String
    let url: URL?

    var body: some View {
        if let url {
            Link(destination: url) { Label { Text(title) } icon: { Image(systemName: icon) } }
        } else {
            Label { Text(title) } icon: { Image(systemName: icon) }
                .foregroundStyle(.tertiary)
                .help("No verified link is recorded.")
        }
    }
}

private struct ConnectionView: View {
    let model: PanelModel
    let dismiss: () -> Void
    @State private var rememberOnDevice = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.isConnected ? "Fieldwerk connection" : "Connect to Fieldwerk")
                .font(.title2).fontWeight(.semibold)
            if model.isConnected {
                Text("Signed in to Fieldwerk.").foregroundStyle(.secondary)
                if let error = model.errorMessage { Text(error).font(.callout) }
                Button("Sign out and remove saved tokens") { Task { await model.logout() } }
                    .disabled(model.isBusy)
            } else {
                Text("Approve FWWIP in your browser.").foregroundStyle(.secondary)
                if let error = model.errorMessage { Text(error).font(.callout) }
                if model.approvalReady {
                    SignInApprovalDetails(rememberOnDevice: $rememberOnDevice)
                    Button("Open browser") { model.approveAndSignIn(rememberOnDevice: rememberOnDevice) }
                        .buttonStyle(.borderedProminent).disabled(model.isBusy)
                } else if !model.isBusy {
                    Button("Prepare connection") { Task { await model.prepareSignIn() } }
                }
                if model.canRemoveSavedSignIn {
                    Button("Remove saved sign-in") { Task { await model.logout() } }.disabled(model.isBusy)
                }
            }
            if model.isBusy {
                ProgressView().controlSize(.small)
                if !model.isConnected {
                    Text(model.serviceMessage).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Cancel sign-in") { model.cancelSignIn() }
                }
            }
            HStack {
                Link("Connection guide", destination: URL(string: "https://fieldwerk.ai/connect")!)
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }.font(.caption)
        }
        .padding(26).frame(width: 400)
        .task {
            if !model.isConnected && !model.approvalReady { await model.prepareSignIn() }
        }
    }
}

private struct SignInApprovalDetails: View {
    @Binding var rememberOnDevice: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fieldwerk grants read and write access. FWWIP reads your work and moves cards when you choose a destination.")
            Toggle("Remember sign-in on this Mac", isOn: $rememberOnDevice)
            Text(rememberOnDevice ? "Saved in FWWIP’s device-only Keychain item." : "Kept in memory until FWWIP quits.")
                .foregroundStyle(.secondary)
            DisclosureGroup("Connection details") {
                Text("Public client: FWWIP. Scope: memos:rw; Fieldwerk advertises no read-only scope. Callback: http://127.0.0.1:53682/oauth/callback. Your browser handles credentials and consent. No iCloud token sync.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .font(.callout)
    }
}

#Preview { ContentView(model: PanelModel()) }
