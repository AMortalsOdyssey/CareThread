import XCTest

final class CareThreadUITests: XCTestCase {
    func testB1EmptyDatabaseShowsEveryStandardTabEmptyState() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-uiTestEmpty",
            "-displayMode", "standard"
        ]
        app.launch()

        XCTAssertTrue(
            element("standardRoot", in: app).waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.tabBars.buttons["首页"].exists)
        XCTAssertTrue(
            element("m45.home.empty", in: app).waitForExistence(timeout: 8)
        )

        app.tabBars.buttons["时间线"].tap()
        XCTAssertTrue(
            app.staticTexts[
                "录入第一份资料后，你的病程线会从这里开始。"
            ].waitForExistence(timeout: 8)
        )

        app.tabBars.buttons["录入"].tap()
        XCTAssertTrue(
            element("m45.more", in: app).waitForExistence(timeout: 5)
        )
        app.buttons["完成"].tap()
        XCTAssertFalse(
            element("m45.more", in: app).waitForExistence(timeout: 2)
        )

        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(
            element("m3.records.library", in: app)
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts[
                "这里会存放你的所有报告和病历，按时间排好。"
            ].waitForExistence(timeout: 5)
        )

        app.tabBars.buttons["管理"].tap()
        XCTAssertTrue(
            element("m45.manage", in: app).waitForExistence(timeout: 8)
        )
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}
