import XCTest

final class RecordOrderFullEditUITests: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "-displayMode", "standard"
        ] + arguments
        app.launch()
        return app
    }

    func testRecordEditorExposesAllBusinessSectionsAndSavesMeasurement() {
        let app = launch(["-M3OpenRecords"])
        let row = app.staticTexts["甲状腺功能五项"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["m3.detail.edit"].waitForExistence(timeout: 5))
        app.buttons["m3.detail.edit"].tap()
        XCTAssertTrue(
            app.otherElements["m3.edit.sheet"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.textFields["m3.edit.timezone"].exists)
        XCTAssertTrue(app.textFields["m3.edit.hospital"].exists)
        let diseases = app.textFields["m3.edit.diseases"]
        scrollUntilHittable(diseases, in: app)
        XCTAssertTrue(diseases.exists)

        let ageToggle = app.switches["m3.edit.ageEnabled"]
        scrollUntilHittable(ageToggle, in: app)
        XCTAssertTrue(ageToggle.exists)

        let addField = app.buttons["m3.edit.addField"]
        scrollUntilHittable(addField, in: app)
        addField.tap()
        app.swipeDown()
        let fieldName = app.textFields.matching(
            identifierPrefix: "m3.edit.field.key."
        ).firstMatch
        scrollUntilHittable(fieldName, in: app)
        fieldName.clearAndType("UI虚构字段")
        let fieldValue = app.textFields.matching(
            identifierPrefix: "m3.edit.field.value."
        ).firstMatch
        scrollUntilHittable(fieldValue, in: app)
        fieldValue.clearAndType("UI虚构值")

        let name = app.textFields.matching(
            identifierPrefix: "m3.edit.measurement.name."
        ).firstMatch
        scrollUntilHittable(name, in: app, attempts: 20)
        name.clearAndType("UI虚构指标")
        let number = app.textFields.matching(
            identifierPrefix: "m3.edit.measurement.numeric."
        ).firstMatch
        scrollUntilHittable(number, in: app)
        number.replaceExistingValue(with: "12.5")
        let keyboardDone = app.buttons["m3.edit.keyboardDone"]
        XCTAssertTrue(keyboardDone.waitForExistence(timeout: 2))
        keyboardDone.tap()

        app.buttons["m3.edit.save"].tap()
        let savedMeasurement = app.staticTexts["UI虚构指标"]
        scrollUntilHittable(savedMeasurement, in: app, attempts: 15)
        XCTAssertTrue(savedMeasurement.exists)
        let savedField = app.descendants(matching: .any)
            .matching(identifierPrefix: "m3.detail.field.")
            .matching(
                NSPredicate(
                    format: "label == %@ AND value == %@",
                    "UI虚构字段",
                    "UI虚构值"
                )
            )
            .firstMatch
        scrollBackwardUntilExists(savedField, in: app, attempts: 15)
        XCTAssertTrue(savedField.exists)
    }

    func testMedicalOrderCardEditsContentAndCompletionWithCAS() {
        let app = launch(["-M45OpenMedication"])
        XCTAssertTrue(
            app.descendants(matching: .any)["m45.medication.orders"]
                .firstMatch.waitForExistence(timeout: 8)
        )
        app.segmentedControls.buttons["医嘱"].tap()
        let edit = app.buttons.matching(
            identifierPrefix: "m45.order.edit."
        ).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()

        let content = app.textFields["m45.order.content"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        content.clearAndType("UI人工修订医嘱")
        let completed = app.switches["m45.order.completed"]
        XCTAssertTrue(completed.exists)
        if completed.value as? String != "1" {
            completed.tap()
        }
        app.buttons["m45.order.save"].tap()

        XCTAssertTrue(
            app.staticTexts["UI人工修订医嘱"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.staticTexts["完成"].exists)
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
        XCTAssertTrue(element.exists)
    }

    private func scrollBackwardUntilExists(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 12
    ) {
        var remaining = attempts
        while !element.exists, remaining > 0 {
            app.swipeDown()
            remaining -= 1
        }
        XCTAssertTrue(element.exists)
    }
}

private extension XCUIElementQuery {
    func matching(identifierPrefix: String) -> XCUIElementQuery {
        matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                identifierPrefix
            )
        )
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        press(forDuration: 0.8)
        let app = XCUIApplication()
        let englishSelectAll = app.menuItems["Select All"]
        let chineseSelectAll = app.menuItems["全选"]
        let selectAll = englishSelectAll.waitForExistence(timeout: 0.5)
            ? englishSelectAll
            : chineseSelectAll
        if selectAll.waitForExistence(timeout: 0.5) {
            selectAll.tap()
        } else {
            typeKey("a", modifierFlags: .command)
        }
        typeText(XCUIKeyboardKey.delete.rawValue)
        typeText(text)
    }

    func replaceExistingValue(with text: String) {
        tap()
        let current = value as? String ?? ""
        if !current.isEmpty {
            typeText(
                String(
                    repeating: XCUIKeyboardKey.delete.rawValue,
                    count: current.count
                )
            )
        }
        typeText(text)
    }
}
