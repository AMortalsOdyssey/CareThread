import XCTest

final class MemberProfileQuestionsUITests: XCTestCase {
    private func launchMembers() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-MemberOpenManagement"
        ]
        app.launch()
        return app
    }

    func testMemberAddAndSwitchFlow() {
        let app = launchMembers()
        XCTAssertTrue(
            element("member.management", in: app)
                .waitForExistence(timeout: 5)
        )
        app.buttons["member.add"].tap()
        let name = app.textFields["member.create.displayName"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.tap()
        name.typeText("虚构家人乙")
        tapKeyboardDone("member.create.keyboard.done", in: app)
        app.buttons["member.create.save"].tap()
        XCTAssertTrue(
            app.staticTexts["已添加并切换到 虚构家人乙"]
                .waitForExistence(timeout: 3)
        )
    }

    func testEveryProfileBusinessFieldCanBeEdited() {
        let app = launchMembers()
        let management = element("member.management", in: app)
        XCTAssertTrue(management.waitForExistence(timeout: 5))
        let firstMember = element("member.row.index.0", in: app)
        XCTAssertTrue(firstMember.waitForExistence(timeout: 3))
        firstMember.tap()
        let displayName = app.textFields["member.profile.displayName"]
        XCTAssertTrue(displayName.waitForExistence(timeout: 3))
        displayName.tap()
        displayName.clearAndType("虚构新称")
        app.textFields["member.profile.reportName"].tap()
        app.textFields["member.profile.reportName"]
            .clearAndType("测试姓名")
        app.textFields["member.profile.conditions"].tap()
        app.textFields["member.profile.conditions"]
            .typeText("虚构情况")
        app.textFields["member.profile.allergies"].tap()
        app.textFields["member.profile.allergies"]
            .typeText("虚构过敏")
        tapKeyboardDone("member.profile.keyboard.done", in: app)
        app.buttons["member.profile.save"].tap()
        let feedback = element("member.profile.feedback", in: app)
        for _ in 0..<4 where !feedback.exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            feedback.waitForExistence(timeout: 3)
        )
        XCTAssertEqual(feedback.label, "资料已保存")
    }

    func testQuestionPersistsAfterLeavingAndReopeningProfile() {
        let app = launchMembers()
        XCTAssertTrue(
            element("member.management", in: app)
                .waitForExistence(timeout: 5)
        )
        let firstMember = element("member.row.index.0", in: app)
        XCTAssertTrue(firstMember.waitForExistence(timeout: 3))
        firstMember.tap()
        let questionsLink = element("member.profile.questions", in: app)
        for _ in 0..<4 where !questionsLink.exists {
            app.swipeUp()
        }
        XCTAssertTrue(questionsLink.waitForExistence(timeout: 3))
        questionsLink.tap()
        app.buttons["member.question.add"].tap()
        let question = app.textFields["member.question.text"]
        XCTAssertTrue(question.waitForExistence(timeout: 2))
        question.tap()
        question.typeText("下次需要带哪些虚构资料？")
        let note = app.textFields["member.question.note"]
        note.tap()
        note.typeText("准备虚构资料")
        tapKeyboardDone("member.question.keyboard.done", in: app)
        app.buttons["member.question.save"].tap()
        XCTAssertTrue(
            app.staticTexts["下次需要带哪些虚构资料？"]
                .waitForExistence(timeout: 3)
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let reopenedQuestionsLink = element(
            "member.profile.questions",
            in: app
        )
        XCTAssertTrue(reopenedQuestionsLink.waitForExistence(timeout: 3))
        reopenedQuestionsLink.tap()
        XCTAssertTrue(
            app.staticTexts["下次需要带哪些虚构资料？"]
                .waitForExistence(timeout: 3)
        )
    }
}

private func tapKeyboardDone(
    _ identifier: String,
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let done = app.buttons[identifier]
    XCTAssertTrue(
        done.waitForExistence(timeout: 2),
        "Keyboard Done button did not appear: \(identifier)",
        file: file,
        line: line
    )
    done.tap()
}

private func element(
    _ identifier: String,
    in app: XCUIApplication
) -> XCUIElement {
    app.descendants(matching: .any)
        .matching(identifier: identifier)
        .firstMatch
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        let existingCharacterCount = (value as? String)?.count ?? 0
        press(forDuration: 1)
        let application = XCUIApplication()
        let selectAll = application.menuItems["Select All"]
        let localizedSelectAll = application.menuItems["全选"]
        if selectAll.waitForExistence(timeout: 1) {
            selectAll.tap()
            typeText(XCUIKeyboardKey.delete.rawValue)
        } else if localizedSelectAll.waitForExistence(timeout: 0.5) {
            localizedSelectAll.tap()
            typeText(XCUIKeyboardKey.delete.rawValue)
        } else {
            let deletes = String(
                repeating: XCUIKeyboardKey.delete.rawValue,
                count: max(existingCharacterCount, 1)
            )
            typeText(deletes)
        }
        typeText(text)
    }
}
