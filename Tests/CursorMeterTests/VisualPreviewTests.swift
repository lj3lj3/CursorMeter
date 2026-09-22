import XCTest
@testable import CursorMeter

/// Offscreen renderer for the menu-bar glyphs and the popover, so UI work can be
/// reviewed without clicking through the running app.
///
/// Gated on `CM_VISUAL_DIR` (same pattern as CM_WEEKLY_CAPTURE_DIR in
/// WeeklyChartStatusUITests): a no-op unless the variable is set.
///   CM_VISUAL_DIR=./tmp swift test --filter VisualPreviewTests
@MainActor
final class VisualPreviewTests: XCTestCase {

    private func outputDirectory() throws -> URL? {
        guard let dir = ProcessInfo.processInfo.environment["CM_VISUAL_DIR"] else { return nil }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ image: NSImage, name: String, to directory: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode \(name)")
            return
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func iconsStrip(dark: Bool) -> NSImage {
        let styles = MenuBarIconStyle.allCases
        let cell: CGFloat = 96
        let size = NSSize(width: cell * CGFloat(styles.count), height: cell)
        let image = NSImage(size: size)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            (dark ? NSColor(white: 0.13, alpha: 1) : NSColor.white).setFill()
            NSRect(origin: .zero, size: size).fill()
            for (index, style) in styles.enumerated() {
                // Icon-only, plus percent variant, side by side per cell.
                let icon = CircularProgressIcon.menuBarImage(percent: 96.8, style: style, size: 48)
                icon.draw(in: NSRect(x: CGFloat(index) * cell + 8, y: 40, width: 48, height: 48))
                let withText = CircularProgressIcon.menuBarImageWithPercent(percent: 96.8, style: style)
                withText.draw(in: NSRect(x: CGFloat(index) * cell + 8, y: 10, width: withText.size.width, height: 22))
            }
            image.unlockFocus()
        }
        return image
    }

    private func fixtureViewModel() -> UsageViewModel {
        let vm = UsageViewModel()
        vm.keychainDeleteHandler = {}
        vm.authState = .loggedIn
        vm.usageData = UsageDisplayData(
            email: "darylljiu@tencent.com",
            name: "刘俊",
            membershipType: "enterprise",
            planUsedCents: 117124,
            planLimitCents: 120998,
            serverPercentUsed: 96.8,
            requestsUsed: 0,
            requestsLimit: 0,
            onDemandUsedCents: 0,
            onDemandLimitCents: 13000,
            onDemandEnabled: true,
            isOnDemandActive: false,
            cycleStartDate: nil,
            resetDate: Date().addingTimeInterval(8 * 86400)
        )
        vm.weeklyChartAvailable = true
        vm.testHook_seedWeeklyData([
            DayUsage(date: Date().addingTimeInterval(-6 * 86400), requests: 4, isToday: false,
                     isOnDemand: false, onDemandCents: 0, totalChargedCents: 210, usageUnits: 4, amountCents: 210),
            DayUsage(date: Date().addingTimeInterval(-5 * 86400), requests: 9, isToday: false,
                     isOnDemand: false, onDemandCents: 0, totalChargedCents: 980, usageUnits: 9, amountCents: 980),
            DayUsage(date: Date().addingTimeInterval(-4 * 86400), requests: 5, isToday: false,
                     isOnDemand: false, onDemandCents: 0, totalChargedCents: 420, usageUnits: 5, amountCents: 420),
            DayUsage(date: Date().addingTimeInterval(-3 * 86400), requests: 3, isToday: false,
                     isOnDemand: false, onDemandCents: 0, totalChargedCents: 150, usageUnits: 3, amountCents: 150),
            DayUsage(date: Date().addingTimeInterval(-2 * 86400), requests: 11, isToday: false,
                     isOnDemand: false, onDemandCents: 0, totalChargedCents: 1210, usageUnits: 11, amountCents: 1210),
            DayUsage(date: Date().addingTimeInterval(-1 * 86400), requests: 14, isToday: false,
                     isOnDemand: false, onDemandCents: 0, totalChargedCents: 1560, usageUnits: 14, amountCents: 1560),
            DayUsage(date: Date(), requests: 2, isToday: true,
                     isOnDemand: false, onDemandCents: 0, totalChargedCents: 90, usageUnits: 2, amountCents: 90),
        ])
        return vm
    }

    private func popoverImage(dark: Bool) throws -> NSImage {
        let vm = fixtureViewModel()
        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.updateUI()
        vc.view.layoutSubtreeIfNeeded()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: vc.preferredContentSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(vc.preferredContentSize)
        vc.view.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(vc.view.bitmapImageRepForCachingDisplay(in: vc.view.bounds))
        vc.view.cacheDisplay(in: vc.view.bounds, to: bitmap)
        let image = NSImage(size: vc.view.bounds.size)
        image.addRepresentation(bitmap)
        window.contentViewController = nil
        window.close()
        return image
    }

    func testWritePreviewsWhenRequested() throws {
        guard let directory = try outputDirectory() else { return }
        _ = NSApplication.shared

        try write(iconsStrip(dark: false), name: "icons-light", to: directory)
        try write(iconsStrip(dark: true), name: "icons-dark", to: directory)
        try write(try popoverImage(dark: false), name: "popover-light", to: directory)
        try write(try popoverImage(dark: true), name: "popover-dark", to: directory)
        print("visual previews written to \(directory.path)")
    }
}
