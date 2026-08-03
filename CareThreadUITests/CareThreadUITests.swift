import XCTest

final class CareThreadUITests: XCTestCase {
    func testRecordSearchStaysLocalAndNeverRequestsLocalNetwork() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard"
        ]
        app.launch()

        XCTAssertTrue(
            element("standardRoot", in: app).waitForExistence(timeout: 8)
        )
        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(
            element("m3.records.library", in: app)
                .waitForExistence(timeout: 8)
        )

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.focusAndType("甲状腺")
        XCTAssertTrue(
            app.staticTexts["甲状腺功能五项"]
                .waitForExistence(timeout: 8)
        )

        // Local-network access belongs exclusively to the user-initiated
        // Nearby Transfer flow. Focusing or typing in the local record search
        // must never surface that authorization prompt, even asynchronously.
        let permissionCopy = NSPredicate(
            format: "label CONTAINS %@",
            "主动发起换机"
        )
        let appPermissionText = app.staticTexts.matching(permissionCopy)
            .firstMatch
        let springboard = XCUIApplication(
            bundleIdentifier: "com.apple.springboard"
        )
        let systemPermissionText = springboard.staticTexts
            .matching(permissionCopy)
            .firstMatch
        let appPrompt = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: appPermissionText
        )
        appPrompt.isInverted = true
        let systemPrompt = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: systemPermissionText
        )
        systemPrompt.isInverted = true
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [appPrompt, systemPrompt],
                timeout: 2
            ),
            .completed
        )
    }

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

    func testUITestDataNeverSurvivesIntoFreshLaunchOrOnboarding() {
        let writer = XCUIApplication()
        writer.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-M45OpenMedication"
        ]
        writer.launch()
        XCTAssertTrue(
            writer.buttons["m45.medication.add"]
                .waitForExistence(timeout: 8)
        )
        writer.buttons["m45.medication.add"].tap()
        let name = writer.textFields["m45.medication.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.focusAndType("不得残留的自动化用药")
        writer.textFields["m45.medication.dose"].focusAndType("1")
        writer.navigationBars.buttons["保存用药"].tap()
        XCTAssertTrue(
            writer.staticTexts["不得残留的自动化用药"]
                .waitForExistence(timeout: 5)
        )
        writer.terminate()

        let fresh = XCUIApplication()
        fresh.launchArguments = [
            "-uiTestMode",
            "-uiTestEmpty",
            "-resetOnboarding"
        ]
        fresh.launch()
        XCTAssertTrue(
            fresh.buttons["onboarding.skip"].waitForExistence(timeout: 8)
        )
        fresh.buttons["onboarding.skip"].tap()
        fresh.buttons["onboarding.mode.standard"].tap()
        fresh.buttons["onboarding.next"].tap()
        XCTAssertTrue(
            element("onboarding.legalConsent", in: fresh)
                .waitForExistence(timeout: 5)
        )
        fresh.buttons["onboarding.complete"].tap()
        XCTAssertTrue(
            element("standardRoot", in: fresh)
                .waitForExistence(timeout: 8)
        )
        XCTAssertFalse(fresh.staticTexts["不得残留的自动化用药"].exists)
        fresh.tabBars.buttons["管理"].tap()
        fresh.buttons["m45.manage.medication"].tap()
        XCTAssertTrue(
            fresh.staticTexts[
                "记下正在吃的药，复诊时不用再翻药盒。"
            ].waitForExistence(timeout: 8)
        )
        XCTAssertFalse(fresh.staticTexts["不得残留的自动化用药"].exists)
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}
