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
                Button(appDelegate.undoTitle) { appDelegate.undoMove() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!appDelegate.canUndoMove)
                Button(appDelegate.redoTitle) { appDelegate.redoMove() }
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
final class PanelAppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSMenuDelegate {
    @ObservationIgnored private var panel: WorkPanel?
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private var connectionDetailsMenu: NSMenu?
    @ObservationIgnored private var rememberSignInOnDevice = true
    @ObservationIgnored private let model = PanelModel()
    var canUndoMove: Bool { model.canUndoMove }
    var canRedoMove: Bool { model.canRedoMove }
    var undoTitle: String { model.undoTitle }
    var redoTitle: String { model.redoTitle }
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
        let detailsItem = NSMenuItem(title: "Connection details", action: nil, keyEquivalent: "")
        let detailsMenu = NSMenu()
        detailsMenu.delegate = self
        detailsItem.submenu = detailsMenu
        menu.addItem(detailsItem)
        connectionDetailsMenu = detailsMenu
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let connectionDetailsMenu, menu === connectionDetailsMenu else { return }
        menu.removeAllItems()
        addConnectionDetail(model.isConnected ? "Status: Connected" : "Status: Not connected", to: menu)
        let lastSynced = model.lastFetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
        addConnectionDetail("Last synced: \(lastSynced)", to: menu)
        menu.addItem(.separator())
        addConnectionDetail("Access: Read and write (memos:rw)", to: menu)
        addConnectionDetail("Callback: http://127.0.0.1:53682/oauth/callback", to: menu)
        addConnectionDetail("Your browser handles credentials and consent", to: menu)
        addConnectionDetail("Tokens use device-only Keychain or memory until quit; no iCloud sync", to: menu)

        menu.addItem(.separator())
        if model.isConnected {
            addAction("Sign out and change Fieldwerk connection…", to: menu,
                      selector: #selector(changeConnection), enabled: !model.isBusy && !model.isWriting)
        } else if model.isBusy {
            addConnectionDetail(model.serviceMessage, to: menu)
            addAction("Cancel sign-in", to: menu, selector: #selector(cancelConnection))
        } else if model.approvalReady {
            addConnectionDetail("FWWIP reads work and moves cards only when you choose a destination.", to: menu)
            addAction("Remember sign-in on this Mac", to: menu, selector: #selector(toggleRememberOnDevice),
                      checked: rememberSignInOnDevice)
            addConnectionDetail(rememberSignInOnDevice
                                ? "Saved in FWWIP’s device-only Keychain item."
                                : "Kept in memory until FWWIP quits.", to: menu)
            addConnectionDetail("Review the access request, then approve it in your browser.", to: menu)
            addAction("Open browser to approve", to: menu, selector: #selector(approveConnection))
        } else {
            addAction("Connect to Fieldwerk…", to: menu, selector: #selector(prepareConnection))
        }

        if !model.isConnected && model.canRemoveSavedSignIn {
            addAction("Remove saved sign-in", to: menu, selector: #selector(removeSavedSignIn),
                      enabled: !model.isBusy && !model.isWriting)
        }
        addAction("Connection guide", to: menu, selector: #selector(openConnectionGuide))

        if let error = model.errorMessage {
            menu.addItem(.separator())
            addConnectionDetail("Issue: \(error)", to: menu)
        }
        if let failure = model.backgroundFailureMessage {
            if model.errorMessage == nil { menu.addItem(.separator()) }
            addConnectionDetail("Background issue: \(failure)", to: menu)
        }
    }

    private func addConnectionDetail(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ title: String, to menu: NSMenu, selector: Selector,
                           enabled: Bool = true, checked: Bool? = nil) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        if let checked { item.state = checked ? .on : .off }
        menu.addItem(item)
    }

    @objc private func prepareConnection() { Task { await model.prepareSignIn() } }
    @objc private func approveConnection() { model.approveAndSignIn(rememberOnDevice: rememberSignInOnDevice) }
    @objc private func toggleRememberOnDevice() { rememberSignInOnDevice.toggle() }
    @objc private func cancelConnection() { model.cancelSignIn() }
    @objc private func changeConnection() { Task { await model.logout() } }
    @objc private func removeSavedSignIn() { Task { await model.logout() } }
    @objc private func openConnectionGuide() {
        NSWorkspace.shared.open(URL(string: "https://fieldwerk.ai/connect")!)
    }
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
