import XCTest

final class NearbySyncFlowUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard"
        ]
        app.launch()
        return app
    }

    func testNearbyTransferOpensFromMoreWithLocalOnlyDisclosure() {
        let app = launch()
        XCTAssertTrue(
            app.tabBars.buttons["录入"].waitForExistence(timeout: 8)
        )
        app.tabBars.buttons["录入"].tap()
        let transfer = app.buttons["m45.more.transfer"]
        XCTAssertTrue(reveal(transfer, in: app))
        XCTAssertTrue(transfer.isHittable)
        transfer.tap()
        XCTAssertTrue(
            element("nearbySync.root", in: app).waitForExistence(timeout: 8)
        )
        XCTAssertTrue(element("nearbySync.privacy", in: app).exists)
        XCTAssertTrue(app.buttons["nearbySync.begin"].exists)
        XCTAssertFalse(app.staticTexts["iCloud"].exists)
    }

    func testNearbySetupOffersSingleOrAllMemberScopeAndLargeAction() {
        let app = launch()
        XCTAssertTrue(
            app.tabBars.buttons["录入"].waitForExistence(timeout: 8)
        )
        app.tabBars.buttons["录入"].tap()
        let transfer = app.buttons["m45.more.transfer"]
        XCTAssertTrue(reveal(transfer, in: app))
        XCTAssertTrue(transfer.isHittable)
        transfer.tap()
        XCTAssertTrue(
            element("nearbySync.root", in: app).waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.switches["nearbySync.allMembers"].exists)
        XCTAssertTrue(app.buttons["nearbySync.member"].exists)
        let begin = app.buttons["nearbySync.begin"]
        XCTAssertTrue(begin.exists)
        XCTAssertGreaterThanOrEqual(begin.frame.height, 44)
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func reveal(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int = 8
    ) -> Bool {
        if element.waitForExistence(timeout: 1), element.isHittable {
            return true
        }
        for _ in 0..<maximumSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1), element.isHittable {
                return true
            }
        }
        return false
    }
}
