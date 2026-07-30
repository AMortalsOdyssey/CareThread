import XCTest

final class M3CaptureRecordsUITests: XCTestCase {
    private func launch(
        _ arguments: [String],
        accessibilitySize: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMode", "-displayMode", "standard"] + arguments
        if accessibilitySize {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXL"
            ]
        }
        app.launch()
        return app
    }

    func testDesignStandardAX3KeepsPrimaryFlowsReachable() {
        let home = launch(["-M45OpenHome"], accessibilitySize: true)
        XCTAssertTrue(
            element("m45.home", in: home).waitForExistence(timeout: 8)
        )
        let homeCapture = home.buttons["m45.home.quick.capture"]
        scrollUntilHittable(homeCapture, in: home)
        XCTAssertTrue(homeCapture.isHittable)
        home.terminate()

        let confirmation = launch(
            ["-M3OpenCapture"],
            accessibilitySize: true
        )
        let manual = confirmation.buttons["m3.source.manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 8))
        scrollUntilHittable(manual, in: confirmation)
        XCTAssertTrue(manual.isHittable)
        manual.tap()
        XCTAssertTrue(
            confirmation.textFields["m3.confirm.title"]
                .waitForExistence(timeout: 5)
        )
        let save = confirmation.buttons["m3.confirm.save"]
        scrollUntilHittable(save, in: confirmation)
        XCTAssertTrue(save.isHittable)
        confirmation.terminate()

        let records = launch(["-M3OpenRecords"], accessibilitySize: true)
        let record = records.staticTexts["甲状腺功能五项"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.tap()
        XCTAssertTrue(
            element("m3.detail", in: records)
                .waitForExistence(timeout: 5)
        )
        let edit = records.buttons["m3.detail.edit"]
        scrollUntilHittable(edit, in: records)
        XCTAssertTrue(edit.isHittable)
    }

    func testM3SourceSheetShowsOfflineImportChoicesAndManualEntry() {
        let app = launch(["-M3OpenCapture"])

        XCTAssertTrue(app.otherElements["m3.capture.host"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["m3.source.camera"].exists)
        XCTAssertTrue(app.buttons["m3.source.photos"].exists)
        XCTAssertTrue(app.buttons["m3.source.files"].exists)
        XCTAssertTrue(app.buttons["m3.source.manual"].exists)
        XCTAssertTrue(app.buttons["m3.source.fixture"].exists)
    }

    func testM3ManualEntrySavesWithoutOriginal() {
        let app = launch(["-M3OpenCapture"])
        XCTAssertTrue(app.buttons["m3.source.manual"].waitForExistence(timeout: 8))
        app.buttons["m3.source.manual"].tap()

        let title = app.textFields["m3.confirm.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("虚构手动随访记录")
        dismissKeyboard(in: app, preferredIdentifier: "m3.confirm.keyboardDone")

        let save = app.buttons["m3.confirm.save"]
        scrollUntilHittable(save, in: app)
        save.tap()
        XCTAssertTrue(element("m3.capture.completed", in: app).waitForExistence(timeout: 8))
    }

    func testB2MissingBirthdayShowsEditableAgeAndAllowsBoundaryValue() {
        let app = launch(["-M3OpenCapture", "-M3MissingBirthdayConfirmation"])
        XCTAssertTrue(app.buttons["m3.source.manual"].waitForExistence(timeout: 8))
        app.buttons["m3.source.manual"].tap()

        let age = app.textFields["m3.confirm.manualAge"]
        scrollUntilHittable(age, in: app)
        XCTAssertTrue(age.isHittable)
        age.tap()
        age.typeText("130")
        dismissKeyboard(in: app, preferredIdentifier: "m3.confirm.keyboardDone")

        let save = app.buttons["m3.confirm.save"]
        scrollUntilHittable(save, in: app)
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(
            element("m3.capture.completed", in: app)
                .waitForExistence(timeout: 8)
        )
    }

    func testB6FutureEventDateWarnsButSaveRemainsAvailable() {
        let app = launch(["-M3OpenCapture", "-M3FutureDateConfirmation"])
        XCTAssertTrue(app.buttons["m3.source.manual"].waitForExistence(timeout: 8))
        app.buttons["m3.source.manual"].tap()

        XCTAssertTrue(
            app.staticTexts["这个日期晚于今天，请核对一下。"]
                .waitForExistence(timeout: 5)
        )

        let title = app.textFields["m3.confirm.title"]
        scrollUntilHittable(title, in: app)
        title.tap()
        title.typeText("虚构未来日期记录")
        dismissKeyboard(in: app, preferredIdentifier: "m3.confirm.keyboardDone")
        let save = app.buttons["m3.confirm.save"]
        scrollUntilHittable(save, in: app)
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(
            element("m3.capture.completed", in: app)
                .waitForExistence(timeout: 8)
        )
    }

    func testB5BlankOCRShowsBannerAndAllowsManualCompletionAndSave() {
        let app = launch([
            "-M3OpenCapture",
            "-M3BlankOCRConfirmation"
        ])

        XCTAssertTrue(
            element("m3.confirmation", in: app)
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            element("m3.confirm.ocrEmpty", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["没认出文字"].exists
        )

        let title = app.textFields["m3.confirm.title"]
        scrollUntilHittable(title, in: app)
        XCTAssertTrue(title.isHittable)
        title.tap()
        title.typeText("虚构空白图片人工补录")
        dismissKeyboard(in: app, preferredIdentifier: "m3.confirm.keyboardDone")

        let save = app.buttons["m3.confirm.save"]
        scrollUntilHittable(save, in: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(
            element("m3.capture.completed", in: app)
                .waitForExistence(timeout: 8)
        )
    }

    func testM3MultipleReportsWithMultiplePagesRequireExplicitRegroupConfirmation() {
        let app = launch(["-M3OpenCapture"])
        XCTAssertTrue(app.buttons["m3.source.fixture"].waitForExistence(timeout: 8))
        app.buttons["m3.source.fixture"].tap()

        let split = app.buttons["m3.workbench.split.0.2"]
        scrollUntilHittable(split, in: app)
        split.tap()
        XCTAssertTrue(element("m3.workbench.document.1", in: app).waitForExistence(timeout: 5))

        confirmGroupingAndContinue(in: app)
        XCTAssertTrue(element("m3.workbench", in: app).waitForExistence(timeout: 8))
        confirmGroupingAndContinue(in: app)
        XCTAssertTrue(element("m3.confirmation", in: app).waitForExistence(timeout: 8))
        let progress = element("m3.confirm.progress", in: app)
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertEqual(progress.label, "第 1 / 2 份")
    }

    func testM3NameMismatchBlocksDirectSaveAndRequiresTwoStepOverride() {
        let app = launch(["-M3OpenCapture", "-M3NameMismatch"])
        XCTAssertTrue(app.buttons["m3.source.fixture"].waitForExistence(timeout: 8))
        app.buttons["m3.source.fixture"].tap()

        let split = app.buttons["m3.workbench.split.0.2"]
        scrollUntilHittable(split, in: app)
        split.tap()
        confirmGroupingAndContinue(in: app)
        XCTAssertTrue(element("m3.workbench", in: app).waitForExistence(timeout: 8))
        confirmGroupingAndContinue(in: app)

        let override = app.buttons["m3.confirm.nameOverride"]
        XCTAssertTrue(override.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["m3.confirm.save"].exists)
        override.tap()
        let secondConfirmation = app.buttons["确认识别有误并保存"]
        XCTAssertTrue(secondConfirmation.waitForExistence(timeout: 5))
        secondConfirmation.tap()
        XCTAssertTrue(element("m3.confirmation", in: app).waitForExistence(timeout: 8))
    }

    func testM3AmbiguousNamesRequireRegroupAndNeverOfferMemberSwitch() {
        let app = launch(["-M3OpenCapture", "-M3DirectAmbiguousConfirmation"])

        let regroup = app.buttons["m3.confirm.returnToGrouping"]
        XCTAssertTrue(regroup.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["m3.confirm.switchMember"].exists)
        XCTAssertTrue(app.buttons["m3.confirm.nameOverride"].exists)
    }

    func testM3CombinedFilterAndKeysetLoadMoreRemainAvailable() {
        let app = launch(["-M3OpenRecords", "-M3StressRecords"])
        XCTAssertTrue(element("m3.records.library", in: app).waitForExistence(timeout: 10))

        let loadMore = app.buttons["m3.records.loadMore"]
        scrollUntilHittable(loadMore, in: app, attempts: 20)
        XCTAssertTrue(loadMore.exists)
        loadMore.tap()

        app.buttons["m3.records.filters"].tap()
        XCTAssertTrue(app.otherElements["m3.filters.sheet"].waitForExistence(timeout: 5))
        let lab = app.buttons["检验报告"]
        if lab.exists { lab.tap() }
        app.buttons["m3.filters.apply"].tap()
        XCTAssertTrue(element("m3.records.library", in: app).waitForExistence(timeout: 5))
    }

    func testM3EditingConfirmedFieldsKeepsMachineExtractionVisible() {
        let app = launch(["-M3OpenRecords", "-M3SeedMachineRecord"])
        XCTAssertTrue(element("m3.records.library", in: app).waitForExistence(timeout: 10))
        let rowTitle = app.staticTexts["M3 机器识别测试"]
        XCTAssertTrue(rowTitle.waitForExistence(timeout: 8))
        rowTitle.tap()

        XCTAssertTrue(app.buttons["m3.detail.edit"].waitForExistence(timeout: 5))
        app.buttons["m3.detail.edit"].tap()
        let title = app.textFields["m3.edit.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.clearAndType("M3 用户修订标题")
        dismissKeyboard(in: app, preferredIdentifier: "m3.edit.keyboardDone")
        app.buttons["m3.edit.save"].tap()

        let machineTitle = element("m3.detail.machine.title", in: app)
        scrollUntilHittable(machineTitle, in: app)
        XCTAssertTrue(machineTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(machineTitle.value as? String, "M3 机器识别测试")
    }

    private func confirmGroupingAndContinue(in app: XCUIApplication) {
        let toggle = app.switches["m3.workbench.groupingConfirmed"]
        scrollUntilHittable(toggle, in: app)
        if toggle.value as? String != "1" {
            toggle.tap()
        }
        let button = app.buttons["m3.workbench.continue"]
        scrollUntilHittable(button, in: app)
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: button
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        button.tap()
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func dismissKeyboard(
        in app: XCUIApplication,
        preferredIdentifier: String
    ) {
        let preferred = app.buttons[preferredIdentifier]
        if preferred.waitForExistence(timeout: 2) {
            preferred.tap()
            return
        }
        app.keyboards.buttons["Done"].tapIfExists()
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

private extension XCUIElement {
    func tapIfExists() {
        if exists { tap() }
    }

    func clearAndType(_ text: String) {
        tap()
        let previousValue = value as? String ?? ""
        press(forDuration: 0.8)
        let selectAll = XCUIApplication().menuItems["Select All"]
        var selectedAll = false
        if selectAll.waitForExistence(timeout: 1) {
            selectAll.tap()
            selectedAll = true
        }
        if !selectedAll, !previousValue.isEmpty {
            typeText(
                String(
                    repeating: XCUIKeyboardKey.delete.rawValue,
                    count: previousValue.count
                )
            )
        }
        typeText(text)
    }
}
