import AppKit

/// The status item's surface built with `NSMenu` — one of the two surfaces
/// Apple ships for menu bar extras (the other being `NSPopover`).
///
/// Unlike a hand-rolled panel, an NSMenu is drawn by the system: material,
/// corner radius, highlight, keyboard navigation and dismissal all come for
/// free, and the status button's highlighted state is managed by AppKit.
///
/// Division of labour: read-only, data-dense content rides in the header
/// item's view; anything the user can click is a real menu item, because
/// controls inside an NSMenu view don't receive events reliably.
@MainActor
final class StatusBarMenu: NSObject, NSMenuDelegate {

    private let menu = NSMenu()
    private let headerItem = NSMenuItem()
    private let logoutItem: NSMenuItem
    private let updateItem: NSMenuItem

    private let contentVC: MenuBarPopoverViewController
    private var statusItem: NSStatusItem?
    private let viewModel: UsageViewModel
    private let onLogin: () -> Void
    private let onSettings: () -> Void

    init(
        viewModel: UsageViewModel,
        onLogin: @escaping () -> Void,
        onSettings: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onLogin = onLogin
        self.onSettings = onSettings
        self.contentVC = MenuBarPopoverViewController(
            viewModel: viewModel, onLogin: onLogin, onSettings: onSettings,
            showsActionRows: false)

        logoutItem = NSMenuItem(
            title: "Log Out", action: #selector(logOut), keyEquivalent: "")
        updateItem = NSMenuItem(
            title: "", action: #selector(openUpdate), keyEquivalent: "")

        super.init()

        menu.delegate = self
        menu.autoenablesItems = false

        headerItem.view = contentVC.view
        menu.addItem(headerItem)
        menu.addItem(.separator())
        menu.addItem(item("Refresh", #selector(refresh)))
        menu.addItem(item("Open Dashboard", #selector(openDashboard)))
        // Plain "Settings", not "Settings…": AppKit decorates a menu item whose
        // title matches the system's settings command with a gear glyph, which
        // makes this row the only icon in an otherwise label-only menu.
        menu.addItem(item("Settings", #selector(openSettings)))
        menu.addItem(logoutItem)
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit CursorMeter", #selector(quit)))

        for entry in [logoutItem, updateItem] {
            entry.target = self
            entry.isHidden = true
        }
    }

    func attach(to statusItem: NSStatusItem) {
        self.statusItem = statusItem
        statusItem.menu = menu
    }

    /// Raises the menu as if the user clicked the status item — used when a
    /// notification needs to surface the app's content.
    func show() {
        statusItem?.button?.performClick(nil)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        contentVC.updateUI()
        // The item takes its height from the view's frame.
        let width = max(contentVC.preferredContentSize.width, 300)
        let height = contentVC.preferredContentSize.height
        headerItem.view?.frame = NSRect(x: 0, y: 0, width: width, height: height)

        logoutItem.isHidden = viewModel.authState != .loggedIn
        if let update = viewModel.availableUpdate {
            updateItem.title = "Update available: v\(update.version)"
            updateItem.isHidden = false
        } else {
            updateItem.isHidden = true
        }
    }

    // MARK: - Items

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func refresh() {
        Task { await viewModel.refresh() }
    }

    @objc private func openDashboard() {
        guard let url = URL(string: "https://www.cursor.com/dashboard?tab=usage") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettings() {
        onSettings()
    }

    @objc private func logOut() {
        viewModel.logout()
    }

    @objc private func openUpdate() {
        guard let raw = viewModel.availableUpdate?.htmlURL,
              let url = URL(string: raw) else { return }
        ExternalURL.openGitHub(url)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
