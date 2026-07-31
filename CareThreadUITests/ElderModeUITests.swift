import XCTest

final class ElderModeUITests: XCTestCase {
    private func launch(
        _ arguments: [String] = [],
        empty: Bool = false,
        accessibilitySize: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "elder"
        ] + arguments
        if empty {
            app.launchArguments.append("-uiTestEmpty")
        }
        if accessibilitySize {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        }
        app.launch()
        return app
    }

    func testU13ElderModeShowsThreeTabsAndSettingsSwitch() {
        let app = launch()
        XCTAssertTrue(
            element("elder.root", in: app).waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.tabBars.buttons["今天"].exists)
        XCTAssertTrue(app.tabBars.buttons["拍照存报告"].exists)
        XCTAssertTrue(app.tabBars.buttons["记录"].exists)
        app.buttons["elder.today.settings"].tap()
        XCTAssertTrue(
            element("elder.settings", in: app)
                .waitForExistence(timeout: 5)
        )
        let systemLockNotice = element(
            "elder.settings.systemLockNotice",
            in: app
        )
        XCTAssertTrue(systemLockNotice.waitForExistence(timeout: 5))
        XCTAssertEqual(
            systemLockNotice.label,
            "iOS 18 及以上还可以在桌面长按 CareThread 图标，选\"需要 Face ID\"，给它再加一道系统锁。"
        )
        let standardMode = app.buttons["elder.settings.standard"]
        scrollUntilHittable(standardMode, in: app)
        standardMode.tap()
        XCTAssertTrue(
            element("elder.mode.confirmation", in: app)
                .waitForExistence(timeout: 5)
        )
    }

    func testU14TodayShowsMedicationFollowUpAndDoctorBrief() {
        let app = launch()
        XCTAssertTrue(
            element("elder.today.medication", in: app)
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.staticTexts["优甲乐"].exists)
        XCTAssertTrue(app.staticTexts["08:00"].exists)
        XCTAssertTrue(
            element("elder.today.followUp", in: app).exists
        )
        app.buttons["elder.today.doctor"].tap()
        XCTAssertTrue(
            app.staticTexts["把这一页拿给医生看"]
                .waitForExistence(timeout: 8)
        )
    }

    func testU15SimplifiedFixtureCaptureSavesPendingRecord() {
        let app = launch(["-M9OpenCapture"])
        let fixture = app.buttons["elder.capture.fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 8))
        fixture.tap()
        XCTAssertTrue(
            element("elder.capture.typeQuestion", in: app)
                .waitForExistence(timeout: 5)
        )
        app.buttons["elder.capture.type.lab"].tap()
        app.buttons["elder.capture.today"].tap()
        XCTAssertTrue(
            app.staticTexts["存好了 ✓"]
                .waitForExistence(timeout: 60)
        )
        app.buttons["elder.capture.backToday"].tap()
        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(
            app.staticTexts["等家人核对"]
                .waitForExistence(timeout: 8)
        )
    }

    func testU16PendingBannerAppearsAfterElderCapture() {
        let app = launch(["-M9OpenCapture"])
        XCTAssertTrue(
            app.buttons["elder.capture.fixture"]
                .waitForExistence(timeout: 8)
        )
        app.buttons["elder.capture.fixture"].tap()
        app.buttons["elder.capture.type.lab"].tap()
        app.buttons["elder.capture.today"].tap()
        XCTAssertTrue(
            app.staticTexts["存好了 ✓"]
                .waitForExistence(timeout: 60)
        )
        app.buttons["elder.capture.backToday"].tap()
        XCTAssertTrue(
            element("elder.today.pending", in: app)
                .waitForExistence(timeout: 8)
        )
    }

    func testB21AccessibilitySizeKeepsPrimaryActionsHittable() {
        let app = launch(accessibilitySize: true)
        let medicationTime = app.staticTexts["08:00"]
        XCTAssertTrue(medicationTime.waitForExistence(timeout: 8))
        XCTAssertEqual(medicationTime.label, "08:00")

        let doctor = app.buttons["elder.today.doctor"]
        scrollUntilHittable(doctor, in: app)
        XCTAssertTrue(
            doctor.waitForExistence(timeout: 8)
        )
        XCTAssertTrue(doctor.isHittable)
        XCTAssertEqual(doctor.label, "给医生看")

        app.tabBars.buttons["拍照存报告"].tap()
        XCTAssertTrue(
            app.buttons["elder.capture.fixture"]
                .waitForExistence(timeout: 5)
        )
        app.buttons["elder.capture.fixture"].tap()

        let choices: [(id: String, label: String)] = [
            ("lab", "化验单"),
            ("examination", "检查报告"),
            ("outpatient", "病历"),
            ("discharge", "出院小结"),
            ("prescription", "药单处方"),
            ("other", "其他")
        ]
        for choice in choices {
            let button = app.buttons["elder.capture.type.\(choice.id)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            scrollUntilHittable(button, in: app)
            XCTAssertTrue(button.isHittable, "\(choice.label) 在 AX 字号下不可点击")
            XCTAssertEqual(button.label, choice.label)
            XCTAssertGreaterThanOrEqual(button.frame.height, 60)
        }
    }

    func testB22EmptyLibraryShowsMedicationAndRecordsEmptyStates() {
        let app = launch(empty: true)
        XCTAssertTrue(
            app.staticTexts[
                "还没有记录用药，请家人帮忙添加。"
            ].waitForExistence(timeout: 8)
        )
        let captureHint = app.buttons["elder.today.captureHint"]
        XCTAssertTrue(captureHint.waitForExistence(timeout: 5))
        XCTAssertTrue(captureHint.isHittable)
        XCTAssertEqual(captureHint.label, "拍照存报告")
        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(
            element("elder.records.empty", in: app)
                .waitForExistence(timeout: 5)
        )
    }

    func testO07ElderRecordDetailCanOpenFullEditFields() {
        let app = launch()
        app.tabBars.buttons["记录"].tap()

        let firstRecord = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "elder.records.card."
            )
        ).firstMatch
        XCTAssertTrue(firstRecord.waitForExistence(timeout: 8))
        firstRecord.tap()
        XCTAssertTrue(
            element("elder.record.detail", in: app)
                .waitForExistence(timeout: 5)
        )

        let edit = app.buttons["elder.record.edit"]
        scrollUntilHittable(edit, in: app)
        XCTAssertTrue(edit.isHittable)
        XCTAssertGreaterThanOrEqual(edit.frame.height, 60)
        edit.tap()

        XCTAssertTrue(
            element("m3.edit.sheet", in: app)
                .waitForExistence(timeout: 5)
        )
        for identifier in [
            "m3.edit.title",
            "m3.edit.hospital",
            "m3.edit.doctor",
            "m3.edit.summary"
        ] {
            let field = element(identifier, in: app)
            scrollUntilHittable(field, in: app)
            XCTAssertTrue(
                field.exists && field.isHittable,
                "\(identifier) 在大字版更正资料页不可达"
            )
        }
    }

    func testOnboardingSkipRequiresModeChoice() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-resetOnboarding",
            "-uiTestEmpty"
        ]
        app.launch()
        XCTAssertTrue(
            element("onboarding.root", in: app)
                .waitForExistence(timeout: 8)
        )
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(
            element("onboarding.modeChoice", in: app).exists
        )
        XCTAssertFalse(app.buttons["onboarding.skip"].exists)
        XCTAssertTrue(
            app.buttons["onboarding.mode.standard"].exists
        )
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 12
    ) {
        var remaining = attempts
        while (!element.exists || !element.isHittable), remaining > 0 {
            app.swipeUp()
            remaining -= 1
        }
    }
}
