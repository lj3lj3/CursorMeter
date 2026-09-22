import AppKit
@preconcurrency import UserNotifications

// MARK: - App Entry Point

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {

    // MARK: - Properties

    private var viewModel = UsageViewModel()
    private var statusItem: NSStatusItem!
    private var statusMenu: StatusBarMenu!
    private(set) var settingsWindow: NSWindow?
    private var loginWindow: LoginWindow?
    private var eventMonitor: Any?
    private var jumpCoordinator: JumpEffectCoordinator?
    private var activityWatcher: CursorActivityWatcher?
    private let notificationManager = NotificationManager()

    // MARK: - NSApplicationDelegate Entry Point

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // #83: app-status notification seams. Wired here (not defaulted in the
        // view model) so a nil seam in the SPM test host can never reach
        // UNUserNotificationCenter.
        viewModel.updateAvailableNotifier = { [manager = notificationManager] version, releaseURL in
            await manager.notifyUpdateAvailable(version: version, releaseURL: releaseURL)
        }
        viewModel.refreshFailingNotifier = { [manager = notificationManager] in
            await manager.notifyRefreshFailing()
        }
        viewModel.refreshFailingWithdrawer = { [manager = notificationManager] in
            manager.withdrawRefreshFailing()
        }
        // #112: failures during system sleep / dark wake must not count
        // toward the connection-trouble notification. Display power stays
        // off through dark wake and NSWorkspace sleep events can be missed
        // entirely (app launched lid-closed), so a direct state query beats
        // observer flags. CGDisplayIsAsleep: macOS 10.2+, not deprecated.
        viewModel.displayAsleepChecker = { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

        // #54: IDE credential source. Wired here (nil default in the view
        // model) so the SPM test host can never read the real state.vscdb.
        let authReader = CursorAppAuthReader()
        viewModel.ideCredentialProvider = { authReader.read() }

        // #88: IDE app presence + launcher for the sign-in inducement.
        viewModel.ideAppPresenceCheck = { Self.cursorIDEAppURL() != nil }
        viewModel.ideAppLauncher = { completion in
            guard let appURL = Self.cursorIDEAppURL() else {
                completion(false)
                return
            }
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { app, _ in
                // Hoist to Bool before crossing into the task — the callback's
                // NSRunningApplication is not Sendable under strict checking.
                let success = app != nil
                Task { @MainActor in completion(success) }
            }
        }

        UNUserNotificationCenter.current().delegate = self

        setupStatusItem()
        setupStatusMenu()
        setupKeyboardShortcut()
        setupJumpCoordinator()

        viewModel.checkExistingSession()
        observeStatusItem()
        observePopover()
        observeSettings()

        activityWatcher = CursorActivityWatcher { [weak self] in
            self?.viewModel.noteActivity()
        }
        syncActivityWatcher()
        observeActivityRefreshSetting()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        jumpCoordinator?.stop()
        jumpCoordinator = nil
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem()

        // No click action: with `statusItem.menu` set, AppKit opens the menu
        // and manages the button's highlighted state itself — wiring our own
        // action here would fight both.
    }

    private func updateStatusItem() {
        // Skip while the jump coordinator is showing an emoji glyph — otherwise
        // a subsequent viewModel mutation (weekly fetch, isLoading flip, etc.)
        // would clobber the emoji before its restore timer fires.
        if jumpCoordinator?.isSwapping == true { return }
        statusItem?.button?.image = currentRingImage()
    }

    /// Builds the ring/idle image that should currently occupy the menu bar slot,
    /// based on the latest `UsageDisplayData` and the user's display-mode setting.
    /// Pure read of view-model state — no side effects. Reused by the
    /// `JumpEffectCoordinator` to restore the slot after an emoji swap.
    private func currentRingImage() -> NSImage {
        guard let data = viewModel.usageData else {
            return viewModel.authState == .loginRequired
                ? CircularProgressIcon.loginRequiredImage()
                : CircularProgressIcon.idleImage()
        }
        let mode = UsageViewModel.effectiveMenuBarDisplayMode(
            isPercentOnly: data.isPercentOnly,
            setting: viewModel.menuBarDisplayMode,
            iconStyle: viewModel.menuBarIconStyle)
        switch mode {
        case 2:
            return CircularProgressIcon.menuBarImageWithPercent(
                percent: data.percentUsed, style: viewModel.menuBarIconStyle)
        case 1:
            return CircularProgressIcon.menuBarImageWithText(
                percent: data.percentUsed,
                style: viewModel.menuBarIconStyle,
                usedText: data.menuBarUsedText,
                limitText: data.menuBarLimitText
            )
        default:
            return CircularProgressIcon.menuBarImage(
                percent: data.percentUsed, style: viewModel.menuBarIconStyle)
        }
    }

    // MARK: - Status menu

    private func setupStatusMenu() {
        statusMenu = StatusBarMenu(
            viewModel: viewModel,
            onLogin: { [weak self] in self?.showLogin() },
            onSettings: { [weak self] in self?.openSettings() }
        )
        statusMenu.attach(to: statusItem)
    }

    private func showStatusMenu() {
        statusMenu.show()
    }

    // MARK: - Settings Window

    func openSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsVC = SettingsTabViewController(viewModel: viewModel)
        let window = NSWindow(contentViewController: settingsVC)
        // No manual title: the toolbar-style tab controller propagates the
        // selected tab's title, and AppKit owns window.toolbar (#99).
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // #93: drop the strong reference on close so ARC tears down the whole
    // window + VC graph (~12 MB retained otherwise; reopen builds fresh anyway).
    // Detaching the content VC matters too: AppKit's last-key-window bookkeeping
    // can hold the closed window shell until another window becomes key, and the
    // heavy view tree must not ride along on that reference.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === settingsWindow else { return }
        settingsWindow = nil
        closing.contentViewController = nil
    }

    // MARK: - Login Window

    func showLogin() {
        let window = LoginWindow()
        loginWindow = window
        window.open { [weak self] cookieHeader in
            guard let self else { return }
            if let cookieHeader {
                viewModel.onLoginSuccess(cookieHeader: cookieHeader)
            }
            loginWindow = nil
        }
    }

    // MARK: - Keyboard Shortcut (Cmd+,)

    private func setupKeyboardShortcut() {
        // Local monitor fires when the app is active (e.g., popover is open).
        // .accessory policy apps do not show a menu bar, so we use an event monitor
        // rather than an NSMenuItem to handle Cmd+,.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Cmd+, (comma key, key code 43)
            if event.modifierFlags.contains(.command), event.keyCode == 43 {
                openSettings()
                return nil // Consume the event
            }
            return event
        }
    }

    // MARK: - Jump Effect Coordinator

    private func setupJumpCoordinator() {
        let coordinator = JumpEffectCoordinator(
            statusItem: statusItem,
            viewModel: viewModel,
            notifier: notificationManager,
            restoreImage: { [weak self] in
                self?.currentRingImage() ?? CircularProgressIcon.idleImage()
            }
        )
        jumpCoordinator = coordinator
        coordinator.start()
    }

    // MARK: - ViewModel Observation

    // Two separate tracking blocks so a weekly-chart-only mutation doesn't
    // force the menu-bar ring to re-rasterize, and a refresh-interval change
    // doesn't redraw the popover for no reason. Each block re-arms itself
    // after onChange because `withObservationTracking` is one-shot.
    private func observeStatusItem() {
        withObservationTracking {
            _ = viewModel.usageData
            _ = viewModel.menuBarDisplayMode
            _ = viewModel.menuBarIconStyle
            _ = viewModel.authState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusItem()
                self.observeStatusItem()
            }
        }
    }

    // #54: the settings window is pull-based; this is its only push signal.
    private func observeSettings() {
        withObservationTracking {
            _ = viewModel.activeAuthSource
            _ = viewModel.authState
            _ = viewModel.weeklyChartAvailable
            _ = viewModel.weeklyData
            _ = viewModel.weeklyChartMetric
            // #107: the Ratio menu item is added/removed based on
            // usageData.isPercentOnly — an open Settings window must rebuild
            // when the plan shape changes (account switch, upgrade).
            _ = viewModel.usageData
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                (self.settingsWindow?.contentViewController as? SettingsTabViewController)?.updateUI()
                self.observeSettings()
            }
        }
    }

    // #92: activity-driven refresh. The watcher's lifecycle follows the toggle;
    // start()/stop() are idempotent so this can run on every setting change.
    private func syncActivityWatcher() {
        if viewModel.activityRefreshEnabled {
            activityWatcher?.start()
        } else {
            activityWatcher?.stop()
        }
    }

    private func observeActivityRefreshSetting() {
        withObservationTracking {
            _ = viewModel.activityRefreshEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncActivityWatcher()
                self.observeActivityRefreshSetting()
            }
        }
    }

    // MARK: - Cursor IDE app lookup (#88)

    /// Cursor's bundle id (ToDesktop-packaged; verified locally 2026-07-18),
    /// with a by-name fallback in case a future repackage changes it.
    private static func cursorIDEAppURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.todesktop.230313mzl4w4u92") {
            return url
        }
        let byName = URL(fileURLWithPath: "/Applications/Cursor.app")
        return FileManager.default.fileExists(atPath: byName.path) ? byName : nil
    }



    // MARK: - UNUserNotificationCenterDelegate

    /// Routes a clicked notification via the pure `clickAction` router (#79, #83):
    /// session-expired → login window, update-available → GitHub release page
    /// (host-validated), refresh-failing → popover. Threshold/usage-jump keep
    /// the default no-op since the app has no main window to activate into.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = NotificationManager.clickAction(
            forNotificationIdentifier: response.notification.request.identifier,
            userInfo: response.notification.request.content.userInfo
        )
        switch action {
        case .openLoginWindow:
            Task { @MainActor [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                // #90: browser login is deprecated — with the opt-in off,
                // route expiry recovery to the popover's IDE guidance instead.
                if self.viewModel.browserLoginEnabled {
                    self.showLogin()
                } else {
                    self.showStatusMenu()
                }
            }
        case .openReleaseURL(let url):
            Task { @MainActor in
                ExternalURL.openGitHub(url)
            }
        case .openPopover:
            Task { @MainActor [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.showStatusMenu()
            }
        case .none:
            break
        }
        completionHandler()
    }

    private func observePopover() {
        withObservationTracking {
            _ = viewModel.usageData
            _ = viewModel.isLoading
            _ = viewModel.errorMessage
            _ = viewModel.authState
            // Tracks the underlying stored result; the computed `availableUpdate`
            // does not participate in @Observable change tracking on its own.
            _ = viewModel.lastUpdateCheckResult
            _ = viewModel.refreshInterval
            _ = viewModel.weeklyData
            _ = viewModel.weeklyChartAvailable
            _ = viewModel.weeklyChartEnabled
            _ = viewModel.weeklyChartStyle
            _ = viewModel.weeklyChartMetric
            _ = viewModel.consecutiveFailureCount
            _ = viewModel.weeklyLastUpdated
            _ = viewModel.weeklyConsecutiveFailureCount
            _ = viewModel.lastSuccessAt
            _ = viewModel.ideCredentialAvailable
            _ = viewModel.browserLoginEnabled
            _ = viewModel.planUsageUnit
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The menu refreshes its content in menuWillOpen, so no layout
                // pass is needed here — only the re-arm, or updates would stop
                // forever after the first change.
                self.observePopover()
            }
        }
    }
}
