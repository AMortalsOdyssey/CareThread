import XCTest

final class ScreenshotNavigationUITests: XCTestCase {
    private struct RouteExpectation {
        let route: String
        let mode: String
        let rootIdentifier: String?
        let featureIdentifier: String
        let selectedTabLabel: String?
    }

    func testScreenshotHomeUsesProductionStandardShell() {
        let app = launch(route: "home", mode: "standard")
        assertExists("standardRoot", in: app)
        assertExists("m45.home", in: app)
        assertExists("screenshot.route.home", in: app)
        assertExists("screenshot.actualAppearance.light", in: app)
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        XCTAssertTrue(app.tabBars.buttons["首页"].isSelected)
    }

    func testScreenshotRecordDetailUsesRecordsNavigationStack() {
        let app = launch(route: "record-detail", mode: "standard")
        assertExists("standardRoot", in: app)
        assertExists("m3.detail", in: app)
        assertExists("screenshot.route.record-detail", in: app)
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        XCTAssertTrue(app.tabBars.buttons["记录"].isSelected)
    }

    func testScreenshotExportUsesLoadedProductionBriefSheet() {
        let app = launch(route: "export", mode: "standard")
        assertExists("standardRoot", in: app)
        assertExists("m7.brief", in: app)
        assertExists("m7.brief.paper", in: app)
        assertExists("screenshot.route.export", in: app)
    }

    func testScreenshotNearbySyncUsesProductionSheet() {
        let app = launch(route: "nearby-sync", mode: "standard")
        assertExists("standardRoot", in: app)
        assertExists("nearbySync.root", in: app)
        assertExists("screenshot.route.nearby-sync", in: app)
    }

    func testScreenshotElderTodayUsesProductionThreeTabShell() {
        let app = launch(route: "elder-today", mode: "elder")
        assertExists("elder.root", in: app)
        assertExists("elder.today", in: app)
        assertExists("screenshot.route.elder-today", in: app)
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        XCTAssertTrue(app.tabBars.buttons["今天"].isSelected)
    }

    func testScreenshotElderBriefUsesLoadedProductionSheet() {
        let app = launch(route: "elder-brief", mode: "elder")
        assertExists("elder.root", in: app)
        assertExists("elder.brief", in: app)
        assertExists("screenshot.route.elder-brief", in: app)
    }

    func testScreenshotLockUsesRealFailedPrivacyGate() {
        let app = launch(route: "lock", mode: "standard")
        assertExists("m8.lock.screen", in: app)
        assertExists("m8.lock.retry", in: app)
        assertExists("screenshot.route.lock", in: app)
    }

    func testAllScreenshotRoutesExposeRealFeatureAndNavigationEvidence() {
        let expectations = [
            RouteExpectation(
                route: "onboarding",
                mode: "standard",
                rootIdentifier: nil,
                featureIdentifier: "onboarding.localPrivacy",
                selectedTabLabel: nil
            ),
            standard("home", "m45.home", tab: "首页"),
            standard("capture-source", "m3.capture.host"),
            standard("capture-confirmation", "m3.confirmation"),
            standard("records", "m3.records.library", tab: "记录"),
            standard("record-detail", "m3.detail", tab: "记录"),
            RouteExpectation(
                route: "original-ocr",
                mode: "standard",
                rootIdentifier: nil,
                featureIdentifier: "m3.viewer",
                selectedTabLabel: nil
            ),
            standard("medications", "m45.medication.list", tab: "管理"),
            standard("followups", "m45.followup.list", tab: "管理"),
            standard("timeline", "m6.timeline", tab: "时间线"),
            standard("brief", "m7.brief"),
            standard("manage", "m45.manage", tab: "管理"),
            standard("backup", "m8.backup.screen", tab: "管理"),
            elder("elder-today", "elder.today", tab: "今天"),
            elder("elder-capture-question", "elder.capture.typeQuestion"),
            elder("elder-records", "elder.records", tab: "记录"),
            elder("elder-brief", "elder.brief"),
            standard("member-management", "member.management", tab: "管理"),
            standard("comparison", "m7.compare"),
            standard("export", "m7.brief"),
            standard("nearby-sync", "nearbySync.root"),
            standard("more", "m45.more"),
            RouteExpectation(
                route: "lock",
                mode: "standard",
                rootIdentifier: nil,
                featureIdentifier: "m8.lock.screen",
                selectedTabLabel: nil
            )
        ]

        XCTAssertEqual(expectations.count, 23)
        for expectation in expectations {
            XCTContext.runActivity(named: expectation.route) { _ in
                let app = launch(
                    route: expectation.route,
                    mode: expectation.mode
                )
                if let rootIdentifier = expectation.rootIdentifier {
                    assertExists(rootIdentifier, in: app)
                }
                assertExists(expectation.featureIdentifier, in: app)
                assertExists(
                    "screenshot.route.\(expectation.route)",
                    in: app
                )
                if expectation.route != "lock" {
                    assertExists(
                        "screenshot.actualAppearance.light",
                        in: app
                    )
                }
                if let tab = expectation.selectedTabLabel {
                    XCTAssertTrue(
                        app.tabBars.buttons[tab].isSelected,
                        "\(expectation.route) 未选中预期 Tab：\(tab)"
                    )
                }
                app.terminate()
            }
        }
    }

    private func launch(
        route: String,
        mode: String
    ) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = [
            "-uiTestMode",
            "-displayMode", mode,
            "-screenshotRoute", route,
            "-screenshotAppearance", "light",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN"
        ]
        switch route {
        case "onboarding":
            arguments.append("-resetOnboarding")
        case "elder-capture-question":
            arguments.append("-ScreenshotElderCaptureQuestion")
        case "lock":
            arguments.append(contentsOf: [
                "-M8LockEnabled",
                "-M8LockResult", "failure"
            ])
        default:
            break
        }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func standard(
        _ route: String,
        _ feature: String,
        tab: String? = nil
    ) -> RouteExpectation {
        RouteExpectation(
            route: route,
            mode: "standard",
            rootIdentifier: "standardRoot",
            featureIdentifier: feature,
            selectedTabLabel: tab
        )
    }

    private func elder(
        _ route: String,
        _ feature: String,
        tab: String? = nil
    ) -> RouteExpectation {
        RouteExpectation(
            route: route,
            mode: "elder",
            rootIdentifier: "elder.root",
            featureIdentifier: feature,
            selectedTabLabel: tab
        )
    }

    private func assertExists(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            app.descendants(matching: .any)[identifier].firstMatch
                .waitForExistence(timeout: timeout),
            "缺少真实导航证据：\(identifier)",
            file: file,
            line: line
        )
    }
}
