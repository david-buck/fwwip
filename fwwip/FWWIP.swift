import SwiftUI
import AppKit
import Observation

@main
struct FWWIPApp: App {
    @NSApplicationDelegateAdaptor(PanelAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            Toggle("Always on Top", isOn: Binding(
                get: { appDelegate.staysOnTop },
                set: { appDelegate.staysOnTop = $0 }
            ))
            .padding(24)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Move Card") { appDelegate.undoMove() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!appDelegate.canUndoMove)
                Button("Redo Move Card") { appDelegate.redoMove() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!appDelegate.canRedoMove)
            }
            CommandGroup(after: .windowArrangement) {
                Toggle("Always on Top", isOn: Binding(
                    get: { appDelegate.staysOnTop },
                    set: { appDelegate.staysOnTop = $0 }
                ))
            }
        }
    }
}

@MainActor
final class WorkPanel: NSPanel {
    var cardUndoManager: UndoManager?
    override var undoManager: UndoManager? { cardUndoManager ?? super.undoManager }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
@Observable
final class PanelAppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    @ObservationIgnored private var panel: WorkPanel?
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private let model = PanelModel()
    var canUndoMove: Bool { model.canUndoMove }
    var canRedoMove: Bool { model.canRedoMove }
    func undoMove() { model.undoMove() }
    func redoMove() { model.redoMove() }
    var staysOnTop = true {
        didSet { panel?.level = staysOnTop ? .floating : .normal }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = WorkPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 660),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        panel.title = "FWWIP"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 400, height: 450)
        panel.maxSize = NSSize(width: 560, height: 1200)
        panel.cardUndoManager = model.moveHistory.manager
        panel.contentView = NSHostingView(rootView: ContentView(model: model))
        let toolbar = NSToolbar(identifier: "FWWIPPanelToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        panel.toolbar = toolbar
        panel.toolbarStyle = .unifiedCompact
        panel.center()
        self.panel = panel

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menuIcon = NSImage(named: "MenuBarIcon")
        menuIcon?.size = NSSize(width: 18, height: 18)
        menuIcon?.isTemplate = true
        item.button?.image = menuIcon
        item.button?.setAccessibilityLabel("FWWIP")
        item.button?.toolTip = "FWWIP"
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show FWWIP", action: #selector(showPanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FWWIP", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        showPanel()
    }

    @objc private func showPanel() {
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("FWWIPPanelActions")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier.rawValue == "FWWIPPanelActions" else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Panel actions"
        let view = NSHostingView(rootView: PanelToolbarActions(model: model, owner: self))
        view.frame = NSRect(x: 0, y: 0, width: 68, height: 28)
        item.view = view
        return item
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct PanelToolbarActions: View {
    let model: PanelModel
    @Bindable var owner: PanelAppDelegate

    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!model.isConnected || model.isBusy)
            .help("Refresh work")
            .accessibilityLabel("Refresh work")
            Toggle(isOn: $owner.staysOnTop) {
                Image(systemName: owner.staysOnTop ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .help("Always on Top")
            .accessibilityLabel("Always on Top")
        }
        .buttonStyle(.borderless)
        .frame(width: 68, height: 28)
    }
}
