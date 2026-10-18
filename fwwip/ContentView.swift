import SwiftUI
import AppKit

struct ContentView: View {
    let model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isConnected {
                WorkspaceHeader(model: model)
                WorkList(model: model).id(model.selectedColumnID ?? "none")
            } else {
                DisconnectedView(isBusy: model.isBusy, serviceMessage: model.serviceMessage,
                                 error: model.errorMessage)
            }
        }
        .frame(minWidth: 400, idealWidth: 440, maxWidth: 560, minHeight: 420, idealHeight: 660)
        .background(.regularMaterial)
        .task { await model.restore() }
    }
}

private struct WorkspaceHeader: View {
    let model: PanelModel

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                FullWidthPopUpSelector(
                    accessibilityLabel: "Workspace",
                    selectedTitle: model.workspaces.first { $0.id == model.selectedWorkspaceID }?.name ??
                        (model.workspaces.isEmpty ? "No workspaces" : "Select workspace"),
                    selectedID: model.selectedWorkspaceID,
                    options: model.workspaces.map { .init(id: $0.id, title: $0.name) },
                    emptyTitle: "No workspaces",
                    isDisabled: model.isBusy || model.isWriting,
                    choose: { id in Task { await model.chooseWorkspace(id) } }
                )

                FullWidthPopUpSelector(
                    accessibilityLabel: "Collection",
                    selectedTitle: model.collections.first { $0.id == model.selectedCollectionID }?.name ??
                        (model.collections.isEmpty ? "No collections" : "Select collection"),
                    selectedID: model.selectedCollectionID,
                    options: model.collections.map { .init(id: $0.id, title: $0.name) },
                    emptyTitle: "No collections",
                    isDisabled: model.isBusy || model.isWriting,
                    choose: { id in Task { await model.chooseCollection(id) } }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ColumnNavigation(model: model)
            HStack(alignment: .firstTextBaseline) {
                if let lastSyncedAt = model.lastFetchedAt {
                    Text("Last synced \(lastSyncedAt, format: .dateTime.hour().minute())")
                        .foregroundStyle(.secondary)
                } else if model.isBusy || model.isLoadingWork {
                    Text("Loading work…").foregroundStyle(.secondary)
                }
                Spacer()
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

private struct FullWidthPopUpSelector: NSViewRepresentable {
    struct Option: Identifiable {
        let id: String
        let title: String
    }

    let accessibilityLabel: String
    let selectedTitle: String
    let selectedID: String?
    let options: [Option]
    let emptyTitle: String
    let isDisabled: Bool
    let choose: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(choose: choose)
    }

    func makeNSView(context: Context) -> PopUpButtonContainer {
        let container = PopUpButtonContainer()
        let button = container.button
        button.controlSize = .regular
        button.setAccessibilityLabel(accessibilityLabel)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectItem(_:))
        return container
    }

    func updateNSView(_ container: PopUpButtonContainer, context: Context) {
        let button = container.button
        context.coordinator.choose = choose
        button.removeAllItems()
        if options.isEmpty {
            button.addItem(withTitle: emptyTitle)
            button.lastItem?.isEnabled = false
        } else {
            for option in options {
                button.addItem(withTitle: option.title)
                button.lastItem?.representedObject = option.id
            }
            if let selectedID, let index = options.firstIndex(where: { $0.id == selectedID }) {
                button.selectItem(at: index)
            } else {
                button.selectItem(at: 0)
            }
        }
        button.isEnabled = !isDisabled && !options.isEmpty
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(selectedTitle)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PopUpButtonContainer, context: Context) -> CGSize? {
        let intrinsicSize = nsView.button.intrinsicContentSize
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        return CGSize(width: proposedWidth ?? intrinsicSize.width, height: intrinsicSize.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var choose: (String) -> Void

        init(choose: @escaping (String) -> Void) {
            self.choose = choose
        }

        @objc func selectItem(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String else { return }
            choose(id)
        }
    }
}

private final class PopUpButtonContainer: NSView {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        button.intrinsicContentSize
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
                             move: { destination in Task { await model.move(item, to: destination) } },
                             trash: { model.trash(item) })
                }
                if model.items.isEmpty && !model.isBusy {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.isLoadingWork ? "Loading work…" : model.snapshot == nil ? "No work loaded."
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
    let serviceMessage: String
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to Fieldwerk").font(.title2).fontWeight(.semibold)
            Text("Use Connection details in the FWWIP menu bar menu to connect or change connections.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if isBusy {
                ProgressView().controlSize(.small)
                Text(serviceMessage).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
    let trash: () -> Void

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
            HStack(spacing: 16) {
                if let taskURL = item.taskURL {
                    Link(destination: taskURL) { Label("Task", systemImage: "arrow.up.right") }
                } else {
                    Label("Task", systemImage: "arrow.up.right")
                        .foregroundStyle(.tertiary)
                        .help("No canonical task link is available.")
                }
                Spacer(minLength: 0)
                Menu("Move to") {
                    if let moveLimitation { Text(moveLimitation) }
                    else {
                        ForEach(destinations) { column in
                            Button(column.label) { move(column.id) }
                        }
                    }
                    Divider()
                    Button("Trash", role: .destructive, action: trash)
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

#Preview { ContentView(model: PanelModel()) }
