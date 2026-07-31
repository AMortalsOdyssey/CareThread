import XCTest

final class M8BackupAppLockUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testU10BackupRoundTripRestoresRecordCount() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-M8ResetLock",
            "-M8OpenBackup",
            "-M8U10"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["m8.backup.screen"]
                .firstMatch
                .waitForExistence(timeout: 10)
        )
        let count = app.staticTexts["m8.backup.debug.count"]
        XCTAssertTrue(reveal(count, in: app, maximumSwipes: 5))
        let initial = count.label
        XCTAssertNotEqual(initial, "当前记录：0")

        app.buttons["m8.backup.debug.export"].tap()
        XCTAssertTrue(
            app.buttons["m8.backup.share"].waitForExistence(timeout: 30)
        )
        app.buttons["m8.backup.debug.clear"].tap()
        XCTAssertEqual(count.label, "当前记录：0")
        app.buttons["m8.backup.debug.restore"].tap()
        XCTAssertTrue(
            app.staticTexts["m8.backup.success"].waitForExistence(timeout: 30)
        )
        XCTAssertEqual(count.label, initial)
    }

    func testLockFailureShowsRetryThenUnlocks() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-M8LockEnabled",
            "-M8LockResult", "failure"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["m8.lock.screen"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )
        let retry = app.descendants(matching: .any)["m8.lock.retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["standardRoot"]
                .firstMatch
                .waitForExistence(timeout: 8)
        )
    }

    func testEnableAppLockRequiresConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-M8ResetLock",
            "-M8LockResult", "success",
            "-M8OpenAppLock"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["m8.lock.settings"]
                .firstMatch
                .waitForExistence(timeout: 10)
        )
        let toggle = app.switches["m8.lock.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // The identifier belongs to the full SwiftUI row. Tap the actual
        // switch affordance at the trailing edge, not the row's text center.
        toggle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)
        ).tap()
        // SwiftUI confirmationDialog is bridged to UIAlertController; iOS
        // preserves the action label but does not propagate its SwiftUI ID.
        let confirm = app.buttons["m8.lock.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(
            app.staticTexts["应用锁已开启"].waitForExistence(timeout: 5)
        )
    }

    private func reveal(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int
    ) -> Bool {
        if element.waitForExistence(timeout: 1) { return true }
        for _ in 0..<maximumSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) { return true }
        }
        return false
    }
}
