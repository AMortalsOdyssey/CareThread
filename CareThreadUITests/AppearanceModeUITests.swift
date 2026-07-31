import XCTest

final class AppearanceModeUITests: XCTestCase {
    func testStandardThemeChangesImmediatelyAndPersistsAfterRelaunch() {
        let app = launch(mode: "standard")
        openStandardAppearance(in: app)

        let dark = app.buttons["深色"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        dark.tap()
        XCTAssertTrue(
            waitUntilSelected(app.buttons["深色"])
        )
        app.terminate()
        let relaunched = launch(mode: "standard")
        openStandardAppearance(in: relaunched)
        XCTAssertTrue(
            waitUntilSelected(relaunched.buttons["深色"])
        )

        relaunched.buttons["跟随系统"].tap()
        XCTAssertTrue(
            waitUntilSelected(relaunched.buttons["跟随系统"])
        )
    }

    func testElderSettingsExposeThreeLargeSharedThemeButtons() {
        let app = launch(mode: "elder")
        let settings = app.buttons["elder.today.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        app.swipeUp()

        XCTAssertTrue(
            element("elder.appearance.system", in: app)
                .waitForExistence(timeout: 5)
        )
        app.swipeUp()
        XCTAssertTrue(
            element("elder.appearance.light", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element("elder.appearance.dark", in: app)
                .waitForExistence(timeout: 5)
        )
    }

    private func launch(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", mode
        ]
        app.launch()
        return app
    }

    private func openStandardAppearance(in app: XCUIApplication) {
        XCTAssertTrue(
            app.descendants(matching: .any)["standardRoot"].firstMatch
                .waitForExistence(timeout: 8)
        )
        app.tabBars.buttons["管理"].tap()
        let row = app.buttons["m45.manage.appearance"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(
            app.navigationBars["外观主题"].waitForExistence(timeout: 5)
        )
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func waitUntilSelected(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate(format: "selected == true")
        return XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: predicate,
                    object: element
                )
            ],
            timeout: timeout
        ) == .completed
    }
}
