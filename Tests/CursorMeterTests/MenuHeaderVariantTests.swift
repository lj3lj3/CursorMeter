import XCTest
@testable import CursorMeter

/// The NSMenu-hosted variant of the popover content (menu bar extra style).
///
/// Regression guard: the menu variant drops the fixed-width constraint during
/// layout, and building that path used to hit an implicitly-unwrapped nil —
/// crashing the app at launch before any window appeared.
@MainActor
final class MenuHeaderVariantTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func test_menuVariant_buildsWithoutActionRows() {
        let vm = UsageViewModel()
        vm.keychainDeleteHandler = {}
        vm.authState = .loggedIn

        let vc = MenuBarPopoverViewController(
            viewModel: vm, onLogin: {}, onSettings: {}, showsActionRows: false)
        _ = vc.view                 // must not trap (loadView path)
        // NSMenu sizes the item view by frame, not by constraint — mirror that.
        vc.view.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        vc.view.layoutSubtreeIfNeeded()
        vc.updateUI()

        XCTAssertNil(vc.testHook_authRowButton(), "menu variant has no in-view auth row")
        XCTAssertGreaterThan(vc.preferredContentSize.height, 0,
                             "menu variant must publish a height for the item view")
        XCTAssertFalse(vc.view.subviews.isEmpty)
    }

    func test_popoverVariant_keepsActionRows() {
        let vm = UsageViewModel()
        vm.keychainDeleteHandler = {}
        vm.authState = .loggedIn

        let vc = MenuBarPopoverViewController(
            viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.updateUI()

        XCTAssertNotNil(vc.testHook_authRowButton())
    }
}
