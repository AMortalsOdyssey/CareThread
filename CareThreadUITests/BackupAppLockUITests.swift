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

    func testDefaultArchiveNeedsNoPasswordAndOptionalEncryptionStaysAvailable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-M8ResetLock",
            "-M8OpenBackup"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["m8.backup.screen"]
                .firstMatch
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.buttons["m8.backup.export"].exists)
        XCTAssertFalse(app.secureTextFields["m8.backup.password"].exists)
        keepScreenshot("batch2-backup-default")

        let optionalPassword = app.descendants(matching: .any)[
            "m8.backup.optionalPassword"
        ].firstMatch
        XCTAssertTrue(optionalPassword.waitForExistence(timeout: 5))
        optionalPassword.tap()
        let password = app.secureTextFields["m8.backup.password"]
        XCTAssertTrue(reveal(password, in: app, maximumSwipes: 4))
        XCTAssertTrue(
            reveal(
                app.buttons["m8.backup.encryptedExport"],
                in: app,
                maximumSwipes: 4
            )
        )
        keepScreenshot("batch2-backup-optional-password")
    }

    func testBackupTransferCardOpensNearbyTransfer() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-M8ResetLock",
            "-M8OpenBackup"
        ]
        app.launch()

        XCTAssertTrue(
            app.buttons["m8.backup.transfer"].waitForExistence(timeout: 10)
        )
        app.buttons["m8.backup.transfer"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["nearbySync.root"]
                .firstMatch
                .waitForExistence(timeout: 10)
        )
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

    func testStandardSettingsExplainTheSystemLevelLock() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-M8ResetLock",
            "-M8LockResult", "success",
            "-M8OpenAppLock"
        ]
        app.launch()

        let notice = app.descendants(matching: .any)[
            "m8.lock.systemNotice"
        ].firstMatch
        XCTAssertTrue(reveal(notice, in: app, maximumSwipes: 4))
        XCTAssertEqual(
            notice.label,
            "iOS 18 及以上还可以在桌面长按 CareThread 图标，选\"需要 Face ID\"，给它再加一道系统锁。"
        )
        keepScreenshot("batch2-standard-system-lock-notice")
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

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
