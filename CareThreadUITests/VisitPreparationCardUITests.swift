import XCTest

final class VisitPreparationCardUITests: XCTestCase {
    func testOpensOnePageVisitPreparationCardFromBrief() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-M7OpenBrief"
        ]
        app.launch()

        let entry = app.buttons["m7.preparation.entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["m7.preparation"]
                .firstMatch.waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["m7.preparation.onePage"]
                .firstMatch.exists
        )
        XCTAssertTrue(
            app.switches["m7.preparation.section.basicInfo"].exists
        )
        XCTAssertTrue(
            app.switches["m7.preparation.section.allergies"].exists
        )
        XCTAssertTrue(app.buttons["m7.preparation.export"].exists)
        XCTAssertTrue(app.buttons["m7.preparation.export"].isEnabled)
    }
}
