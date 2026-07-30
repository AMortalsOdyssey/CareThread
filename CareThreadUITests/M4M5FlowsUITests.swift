import XCTest

final class M4M5FlowsUITests: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "-displayMode", "standard"
        ] + arguments
        if arguments.contains("-M45NotificationDenied") {
            app.launchEnvironment[
                "CARETHREAD_UI_NOTIFICATION_STATUS"
            ] = "denied"
            app.launchArguments += [
                "-M45NotificationStatus", "denied"
            ]
        }
        app.launch()
        return app
    }

    func testM45HomeShowsMemberMedicationFollowUpAndQuickActions() {
        let app = launch(["-M45OpenHome"])
        XCTAssertTrue(
            element("m45.home", in: app).waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.buttons["m45.home.member"].exists)
        XCTAssertTrue(element("m45.home.followup", in: app).exists)
        XCTAssertTrue(app.buttons["m45.home.quick.capture"].exists)
        XCTAssertTrue(app.buttons["m45.home.quick.timeline"].exists)
        XCTAssertTrue(app.buttons["m45.home.quick.brief"].exists)
    }

    func testU5AddingMedicationAppearsOnHomeTodayMedication() {
        let app = launch(["-M45OpenMedication"])
        XCTAssertTrue(
            element("m45.medication.orders", in: app)
                .waitForExistence(timeout: 8)
        )
        app.buttons["m45.medication.add"].tap()
        let name = app.textFields["m45.medication.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("UI测试优甲乐")
        let dose = app.textFields["m45.medication.dose"]
        dose.tap()
        dose.typeText("75")
        app.navigationBars.buttons["保存用药"].tap()

        XCTAssertTrue(
            app.staticTexts["UI测试优甲乐"]
                .waitForExistence(timeout: 8)
        )
        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(
            app.staticTexts["UI测试优甲乐"].waitForExistence(timeout: 8)
        )
    }

    func testU6MedicalOrderPrefillsAndCreatesFollowUp() {
        let app = launch(["-M45OpenMedication"])
        XCTAssertTrue(
            element("m45.medication.orders", in: app)
                .waitForExistence(timeout: 8)
        )
        app.segmentedControls.buttons["医嘱"].tap()
        let generate = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "m45.order.generate."
            )
        ).firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        generate.tap()
        XCTAssertTrue(
            app.otherElements["m45.order.followup.editor"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.textFields["m45.order.followup.item"]
                .value as? String == ""
        )
        app.buttons["m45.order.followup.save"].tap()
        XCTAssertTrue(
            app.staticTexts["已生成复查计划"]
                .waitForExistence(timeout: 8)
        )
    }

    func testU7FollowUpCompleteOnlyMovesCardToCompletedSection() {
        let app = launch(["-M45OpenFollowUps"])
        XCTAssertTrue(
            element("m45.followup.list", in: app)
                .waitForExistence(timeout: 8)
        )
        let complete = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "m45.followup.complete."
            )
        ).firstMatch
        scrollUntilHittable(complete, in: app)
        XCTAssertTrue(complete.exists)
        complete.tap()
        let completeOnly = app.buttons["仅标记完成"]
        XCTAssertTrue(completeOnly.waitForExistence(timeout: 5))
        completeOnly.tap()
        XCTAssertTrue(app.staticTexts["已完成"].waitForExistence(timeout: 8))
    }

    func testDeniedNotificationPermissionShowsSettingsRecoveryWithoutCrash() {
        let app = launch([
            "-M45OpenMedication",
            "-M45NotificationDenied"
        ])
        XCTAssertTrue(
            element("m45.medication.orders", in: app)
                .waitForExistence(timeout: 8)
        )
        app.buttons["m45.medication.add"].tap()
        let name = app.textFields["m45.medication.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("权限测试药")
        let dose = app.textFields["m45.medication.dose"]
        dose.tap()
        dose.typeText("1")
        let reminder = app.switches["m45.medication.reminder"]
        scrollUntilHittable(reminder, in: app)
        reminder.tap()
        app.navigationBars.buttons["保存用药"].tap()
        XCTAssertTrue(
            element("m45.medication.feedback", in: app)
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.buttons["去系统设置"].exists)
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        var attempts = 10
        while (!element.exists || !element.isHittable), attempts > 0 {
            app.swipeUp()
            attempts -= 1
        }
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}
