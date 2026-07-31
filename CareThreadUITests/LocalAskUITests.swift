import XCTest

final class LocalAskUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testStandardAskHasFreeInputPresetsFixedDisclaimerAndSourceLink() {
        let app = launch(mode: "standard")

        let entry = app.buttons["m45.home.ask"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()

        XCTAssertTrue(
            element("localAsk.screen", in: app).waitForExistence(timeout: 8)
        )
        XCTAssertTrue(disclaimer(in: app).exists)
        XCTAssertTrue(app.textFields["localAsk.input"].exists)
        for preset in [
            "currentMedication", "nextFollowUp", "latestResult",
            "recentHospitals"
        ] {
            XCTAssertTrue(
                element("localAsk.chip.\(preset)", in: app).exists
            )
        }

        let hospitals = element("localAsk.chip.recentHospitals", in: app)
        let presets = app.scrollViews["localAsk.presets"]
        XCTAssertTrue(presets.exists)
        for _ in 0..<4 where !hospitals.isHittable {
            presets.swipeLeft()
        }
        XCTAssertTrue(hospitals.isHittable)
        hospitals.tap()
        XCTAssertTrue(
            element("localAsk.hospitals", in: app).waitForExistence(timeout: 8)
        )
        let source = firstElement(withIdentifierPrefix: "localAsk.source.", in: app)
        scrollUntilHittable(source, in: app)
        XCTAssertTrue(source.isHittable)
        source.tap()
        XCTAssertTrue(
            element("m3.detail", in: app).waitForExistence(timeout: 8)
        )

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(disclaimer(in: app).waitForExistence(timeout: 5))
    }

    func testElderAskHasExactlyFourLargePresetsAndNoFreeInputAtAX2() {
        let app = launch(mode: "elder", accessibilitySize: true)

        let entry = app.buttons["elder.today.ask"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()

        XCTAssertTrue(
            element("localAsk.screen", in: app).waitForExistence(timeout: 8)
        )
        XCTAssertFalse(app.textFields["localAsk.input"].exists)
        let identifiers = [
            "currentMedication", "nextFollowUp", "latestResult",
            "recentHospitals"
        ]
        for identifier in identifiers {
            XCTAssertTrue(
                element("localAsk.elder.\(identifier)", in: app)
                    .waitForExistence(timeout: 5)
            )
        }

        let last = element("localAsk.elder.recentHospitals", in: app)
        scrollUntilHittable(last, in: app)
        XCTAssertTrue(last.isHittable)
        XCTAssertTrue(last.label.contains("最近去过哪些医院？"))
        last.tap()
        XCTAssertTrue(
            element("localAsk.results", in: app).waitForExistence(timeout: 8)
        )
        XCTAssertTrue(disclaimer(in: app).exists)
    }

    func testElderEachLargePresetReturnsItsStructuredSectionAtAX2() {
        let cases: [(
            preset: String,
            label: String,
            resultIdentifier: String,
            prefix: Bool,
            expectedTexts: [String],
            fallbackPrefix: String?,
            destinationIdentifier: String?
        )] = [
            (
                "currentMedication",
                "我在吃什么药？",
                "localAsk.medication.",
                true,
                ["优甲乐", "75µg · 每日 1 次"],
                "localAsk.medicationSource.",
                "m45.medication.detail"
            ),
            (
                "nextFollowUp",
                "下次什么时候复查？",
                "localAsk.followUps",
                false,
                ["2026年8月15日", "甲状腺功能、颈部超声"],
                "localAsk.followUpSource.",
                "m45.followup.editor"
            ),
            (
                "latestResult",
                "上次检查结果怎么样？",
                "localAsk.metric.",
                true,
                ["TSH · 1 条记录", "0.08 mIU/L", "↓ 原记录标记：偏低"],
                nil,
                nil
            ),
            (
                "recentHospitals",
                "最近去过哪些医院？",
                "localAsk.hospitals",
                false,
                ["医院记录 · 2 家", "四川大学华西医院", "成都市第三人民医院"],
                nil,
                nil
            )
        ]
        let allResultIdentifiers: [(value: String, prefix: Bool)] = [
            ("localAsk.medication.", true),
            ("localAsk.followUps", false),
            ("localAsk.metric.", true),
            ("localAsk.hospitals", false)
        ]

        for testCase in cases {
            let app = launch(mode: "elder", accessibilitySize: true)
            let entry = app.buttons["elder.today.ask"]
            XCTAssertTrue(entry.waitForExistence(timeout: 10))
            entry.tap()

            let button = element(
                "localAsk.elder.\(testCase.preset)",
                in: app
            )
            XCTAssertTrue(button.waitForExistence(timeout: 8))
            XCTAssertEqual(button.label, testCase.label)
            scrollUntilHittable(button, in: app)
            waitUntilEnabled(button)
            XCTAssertTrue(button.isHittable)
            button.tap()

            let result = testCase.prefix
                ? firstElement(
                    withIdentifierPrefix: testCase.resultIdentifier,
                    in: app
                )
                : element(testCase.resultIdentifier, in: app)
            XCTAssertTrue(
                result.waitForExistence(timeout: 8),
                "\(testCase.preset) 未返回预期结构化结果"
            )
            for expectedText in testCase.expectedTexts {
                let text = app.staticTexts[expectedText]
                XCTAssertTrue(
                    text.waitForExistence(timeout: 5),
                    "\(testCase.preset) 缺少精确事实：\(expectedText)"
                )
            }
            for other in allResultIdentifiers
            where other.value != testCase.resultIdentifier {
                XCTAssertFalse(
                    resultElement(
                        identifier: other.value,
                        prefix: other.prefix,
                        in: app
                    ).exists,
                    "\(testCase.preset) 不应混入结构：\(other.value)"
                )
            }
            XCTAssertTrue(disclaimer(in: app).exists)
            if let fallbackPrefix = testCase.fallbackPrefix,
               let destinationIdentifier = testCase.destinationIdentifier {
                let fallback = firstElement(
                    withIdentifierPrefix: fallbackPrefix,
                    in: app
                )
                scrollUntilHittable(fallback, in: app)
                XCTAssertTrue(fallback.isHittable)
                fallback.tap()
                XCTAssertTrue(
                    element(destinationIdentifier, in: app)
                        .waitForExistence(timeout: 8)
                )
                if testCase.preset == "currentMedication" {
                    XCTAssertTrue(app.staticTexts["优甲乐"].exists)
                    XCTAssertTrue(
                        app.staticTexts["75µg"].waitForExistence(timeout: 5),
                        "用药精确回跳详情应显示原记录剂量 75µg"
                    )
                } else {
                    let items = element("m45.followup.items", in: app)
                    XCTAssertTrue(items.waitForExistence(timeout: 5))
                    XCTAssertEqual(
                        items.value as? String,
                        "甲状腺功能、颈部超声"
                    )
                }
            }
            app.terminate()
        }
    }

    private func launch(
        mode: String,
        accessibilitySize: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", mode
        ]
        if accessibilitySize {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXL"
            ]
        }
        app.launch()
        return app
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func disclaimer(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "CareThread 不做医学判断"
            )
        ).firstMatch
    }

    private func firstElement(
        withIdentifierPrefix prefix: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        ).firstMatch
    }

    private func resultElement(
        identifier: String,
        prefix: Bool,
        in app: XCUIApplication
    ) -> XCUIElement {
        prefix
            ? firstElement(withIdentifierPrefix: identifier, in: app)
            : element(identifier, in: app)
    }

    private func waitUntilEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval = 8
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed
        )
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<8 where !element.isHittable {
            app.swipeUp()
        }
    }

}
