import XCTest

final class RecordInboxUITests: XCTestCase {
    func testPendingInboxIsReachableAndReturnsToAllRecords() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-M3OpenRecords"
        ]
        app.launch()

        let inbox = app.buttons["m3.records.pendingInbox"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 10))
        XCTAssertTrue(inbox.label.contains("待整理收件箱"))
        inbox.tap()
        XCTAssertTrue(
            app.staticTexts[
                "正在只看待核对资料，点这里返回全部"
            ].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["m3.records.pendingInbox"].isHittable
        )
        app.buttons["m3.records.pendingInbox"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "份资料还需要核对")
            ).firstMatch.waitForExistence(timeout: 5)
        )
    }
}
