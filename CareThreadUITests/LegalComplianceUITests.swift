import XCTest

final class LegalComplianceUITests: XCTestCase {
    func testOnboardingThirdScreenOpensOfflineDocumentsAndRecordsAgreement() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-uiTestEmpty",
            "-resetOnboarding"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["onboarding.skip"].waitForExistence(timeout: 8))
        app.buttons["onboarding.skip"].tap()
        app.buttons["onboarding.mode.standard"].tap()
        app.buttons["onboarding.next"].tap()
        XCTAssertTrue(
            element("onboarding.legalConsent", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["先说清三件事"].exists)

        app.buttons["onboarding.legal.privacyPolicy"].tap()
        assertBundledDocument(.privacy, in: app)
        app.navigationBars.buttons["完成"].tap()

        app.buttons["onboarding.legal.termsOfService"].tap()
        assertBundledDocument(.terms, in: app)
        app.navigationBars.buttons["完成"].tap()

        app.buttons["onboarding.complete"].tap()
        XCTAssertTrue(element("standardRoot", in: app).waitForExistence(timeout: 8))
    }

    func testStandardAndLargeTypeAboutExposeRequiredItems() {
        let standard = launch(mode: "standard")
        standard.tabBars.buttons["管理"].tap()
        XCTAssertTrue(element("m45.manage", in: standard).waitForExistence(timeout: 8))
        standard.swipeUp()
        let standardAbout = standard.buttons["m45.manage.about"]
        XCTAssertTrue(standardAbout.waitForExistence(timeout: 5))
        standardAbout.tap()
        assertAbout("about.standard", in: standard)
        standard.terminate()

        let largeType = launch(mode: "elder")
        largeType.buttons["elder.today.settings"].tap()
        XCTAssertTrue(element("elder.settings", in: largeType).waitForExistence(timeout: 8))
        let about = largeType.buttons["elder.settings.about"]
        largeType.swipeUp()
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()
        assertAbout("elder.about", in: largeType)
    }

    func testVersionChangeShowsSummaryWithoutRestartingOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-LegalPresentUpdate"
        ]
        app.launch()
        XCTAssertTrue(element("legal.update", in: app).waitForExistence(timeout: 8))
        XCTAssertFalse(element("onboarding.root", in: app).exists)
        XCTAssertTrue(element("legal.update.summary", in: app).exists)
        app.buttons["legal.update.acknowledge"].tap()
        XCTAssertTrue(element("standardRoot", in: app).waitForExistence(timeout: 8))
    }

    private func launch(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", mode
        ]
        app.launch()
        return app
    }

    private func assertAbout(_ identifier: String, in app: XCUIApplication) {
        XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 8))
        for required in [
            "about.legal.privacyPolicy",
            "about.legal.termsOfService",
            "about.medicalDisclaimer",
            "about.version",
            "about.openSource",
            "about.feedback"
        ] {
            XCTAssertTrue(
                scrollUntilExists(element(required, in: app), in: app),
                "Missing required About item: \(required)"
            )
        }
    }

    private enum DocumentExpectation {
        case privacy
        case terms
    }

    private func assertBundledDocument(
        _ expected: DocumentExpectation,
        in app: XCUIApplication
    ) {
        let identifier: String
        let sentence: String
        switch expected {
        case .privacy:
            identifier = "legal.document.privacyPolicy"
            sentence = "CareThread 不收集你的任何信息。"
        case .terms:
            identifier = "legal.document.termsOfService"
            sentence = "CareThread 是一款个人就医资料整理工具。"
        }
        XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("legal.document.content", in: app).exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", sentence)).firstMatch.exists)
        XCTAssertFalse(element("legal.document.error", in: app).exists)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func scrollUntilExists(
        _ target: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        if target.exists { return true }
        for _ in 0..<6 {
            app.swipeUp()
            if target.exists { return true }
        }
        return false
    }
}
