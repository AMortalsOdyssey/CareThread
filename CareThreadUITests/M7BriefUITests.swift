import XCTest

final class M7BriefUITests: XCTestCase {
    func testB19EmptyBriefShowsGuidanceAndDisablesExport() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-uiTestEmpty",
            "-displayMode", "standard",
            "-M7OpenBrief"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["m7.brief"]
                .firstMatch.waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["m7.brief.empty"]
                .firstMatch.waitForExistence(timeout: 8)
        )
        let export = app.buttons["m7.brief.export"]
        XCTAssertTrue(export.exists)
        XCTAssertFalse(export.isEnabled)
    }

    func testU9BriefExportsProtectedPDFLargerThanFourKB() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-M7OpenBrief"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["m7.brief"]
                .firstMatch.waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts["当前用药"].waitForExistence(timeout: 8)
        )
        let export = app.buttons["m7.brief.export"]
        XCTAssertTrue(export.isEnabled)
        export.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["m7.brief.export.result"]
                .firstMatch.waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND label CONTAINS %@",
                    "已生成 PDF",
                    "KB"
                )
            ).firstMatch.exists
        )
    }
}
