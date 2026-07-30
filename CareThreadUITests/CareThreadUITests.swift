import XCTest

final class CareThreadUITests: XCTestCase {
    func test_standardRoot_whenLaunched_showsHomeTab() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "-displayMode", "standard"]
        app.launch()
        XCTAssertTrue(app.otherElements["standardRoot"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["首页"].exists)
    }
}

