import Darwin
import XCTest

final class DeviceSimulatorAcceptanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBackupSystemShareSheetOpensAndCancels() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-M8ResetLock",
            "-M8OpenBackup",
            "-M8U10"
        ]
        app.launch()

        XCTAssertTrue(
            element("m8.backup.screen", in: app)
                .waitForExistence(timeout: 10)
        )
        let export = app.buttons["m8.backup.debug.export"]
        XCTAssertTrue(reveal(export, in: app))
        export.tap()

        let share = app.buttons["m8.backup.share"]
        XCTAssertTrue(reveal(share, in: app, maximumSwipes: 4))
        share.tap()

        // iOS 26 presents the activity controller as a system-owned popover
        // without a close button. A real system action proves presentation;
        // swiping the popover down exercises the non-sharing cancel path.
        let saveToFiles = app.cells["保存到“文件”"].firstMatch
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 10))
        app.swipeDown()
        XCTAssertTrue(
            element("m8.backup.screen", in: app)
                .waitForExistence(timeout: 8)
        )
    }

    func testSystemFaceIDMatchUnlocksTheRealAppLock() {
        let app = launchRealAppLock()
        app.launch()
        print("DEVICE_SIM_FACEID_READY_MATCH")
        XCTAssertTrue(
            element("standardRoot", in: app).waitForExistence(timeout: 12)
        )
    }

    func testSystemFaceIDNomatchesKeepProtectedContentLocked() {
        let app = launchRealAppLock()
        app.launch()
        print("DEVICE_SIM_FACEID_READY_NOMATCH")

        let root = element("standardRoot", in: app)
        XCTAssertFalse(root.waitForExistence(timeout: 8))
        XCTAssertTrue(element("m8.lock.screen", in: app).exists)
        let retry = element("m8.lock.retry", in: app)
        let callbackReturned = waitUntilEnabled(retry, timeout: 2)
        print("DEVICE_SIM_FACEID_NOMATCH_CALLBACK=\(callbackReturned)")
        XCTAssertFalse(root.exists)
    }

    func testUnenrolledSimulatorCannotEnableTheRealAppLock() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-M8ResetLock",
            "-M8OpenAppLock",
            "-DeviceSimRealFaceID"
        ]
        app.launch()

        let toggle = app.switches["m8.lock.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertFalse(toggle.isEnabled)
    }

    func testPhotosPermissionAuthorized() {
        exercisePermission(service: "photos", expected: "authorized")
    }

    func testPhotosPermissionDenied() {
        exercisePermission(service: "photos", expected: "denied")
    }

    func testPhotosPermissionNotDetermined() {
        exercisePermission(service: "photos", expected: "notDetermined")
    }

    func testPhotosAddPermissionAuthorized() {
        exercisePermission(service: "photos-add", expected: "authorized")
    }

    func testPhotosAddPermissionDenied() {
        exercisePermission(service: "photos-add", expected: "denied")
    }

    func testPhotosAddPermissionNotDetermined() {
        exercisePermission(
            service: "photos-add",
            expected: "notDetermined"
        )
    }

    func testCalendarPermissionAuthorizedAndRoundTripsEvent() {
        exercisePermission(service: "calendar", expected: "authorized")
    }

    func testCalendarPermissionDenied() {
        exercisePermission(service: "calendar", expected: "denied")
    }

    func testCalendarPermissionNotDetermined() {
        exercisePermission(service: "calendar", expected: "notDetermined")
    }

    private func exercisePermission(service: String, expected: String) {
        // Register and launch the newly installed app before applying TCC.
        // Xcode 26.6 otherwise accepts simctl's command but Photos still sees
        // the pre-registration `notDetermined` state on first launch.
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "-uiTestEmpty",
            "-displayMode", "standard",
            "-M8ResetLock",
            "-DeviceSimPrimePermission", service
        ]
        app.launch()
        let primed = element("device.acceptance.permission.probe", in: app)
        XCTAssertTrue(primed.waitForExistence(timeout: 10))
        XCTAssertTrue(
            primed.label.contains("service=\(service); primed=true"),
            "Permission service was not primed: \(primed.label)"
        )
        print("DEVICE_SIM_PERMISSION_READY:\(service):\(expected)")
        fflush(stdout)
        sleep(5)
        app.terminate()
        app.launchArguments = [
            "-uiTestMode", "-uiTestEmpty",
            "-displayMode", "standard",
            "-M8ResetLock",
            "-DeviceSimProbePermission", service,
            "-DeviceSimExpectedPermission", expected
        ]
        app.launch()
        let probe = element("device.acceptance.permission.probe", in: app)
        XCTAssertTrue(
            probe.waitForExistence(timeout: 10),
            "Missing permission probe for \(service)"
        )
        XCTAssertTrue(probe.label.contains("service=\(service)"))
        XCTAssertTrue(
            probe.label.contains("status=\(expected)"),
            "Unexpected permission probe: \(probe.label)"
        )
        XCTAssertTrue(
            probe.label.contains("systemStateConsistent=true"),
            "System permission request and static state diverged: \(probe.label)"
        )
        XCTAssertTrue(
            probe.label.contains("核心功能可继续使用")
                || probe.label.contains("可继续使用核心功能")
                || probe.label.contains("核心资料仍只存在本机")
        )
        if service == "calendar" && expected == "authorized" {
            XCTAssertTrue(probe.label.contains("calendarEventRoundTrip=true"))
        }
    }

    func testStandardMedicationNotificationArrivesAndRoutes() throws {
        try exerciseNotification(
            mode: "standard",
            kind: "medication",
            body: "虚构验收 · 标准版 · 用药",
            destination: "m45.medication.list"
        )
    }

    func testStandardFollowUpNotificationArrivesAndRoutes() throws {
        try exerciseNotification(
            mode: "standard",
            kind: "followUp",
            body: "虚构验收 · 标准版 · 复查",
            destination: "m45.followup.list"
        )
    }

    func testElderMedicationNotificationArrivesAndRoutesToToday() throws {
        try exerciseNotification(
            mode: "elder",
            kind: "medication",
            body: "虚构验收 · 大字版 · 用药",
            destination: "elder.today"
        )
    }

    func testElderFollowUpNotificationArrivesAndRoutesToToday() throws {
        try exerciseNotification(
            mode: "elder",
            kind: "followUp",
            body: "虚构验收 · 大字版 · 复查",
            destination: "elder.today"
        )
    }

    func test48MPPhotoCompletesImportSurvivesMemoryWarningAndRestoresDraft()
        throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "-uiTestEmpty",
            "-displayMode", "standard",
            "-M8ResetLock",
            "-M3OpenCapture"
        ]
        app.launch()
        XCTAssertTrue(
            app.buttons["m3.source.photos"].waitForExistence(timeout: 10)
        )
        app.buttons["m3.source.photos"].tap()
        try selectFirstPhoto(in: app)
        let workbench = element("m3.workbench", in: app)
        XCTAssertTrue(workbench.waitForExistence(timeout: 90))

        // The host script repeatedly delivers real simulator memory-pressure
        // notifications while this import is running and samples RSS from the
        // simulator process. Keeping the draft on screen briefly makes that
        // externally driven event deterministic without private in-app hooks.
        sleep(5)
        XCTAssertTrue(workbench.waitForExistence(timeout: 8))

        app.buttons["m3.capture.close"].tap()
        let keepDraft = app.buttons["保留草稿"]
        XCTAssertTrue(keepDraft.waitForExistence(timeout: 5))
        keepDraft.tap()
        XCTAssertTrue(element("standardRoot", in: app).waitForExistence(timeout: 8))

        let reopenCapture = app.buttons["m45.home.quick.capture"]
        XCTAssertTrue(reopenCapture.waitForExistence(timeout: 10))
        reopenCapture.tap()
        let continueDraft = app.buttons["m3.source.continueDraft"]
        XCTAssertTrue(continueDraft.waitForExistence(timeout: 12))
        continueDraft.tap()
        XCTAssertTrue(workbench.waitForExistence(timeout: 12))
        try finishImportedRecord(in: app)
        XCTAssertTrue(
            element("m3.capture.completed", in: app)
                .waitForExistence(timeout: 90)
        )
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func launchRealAppLock() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode",
            "-displayMode", "standard",
            "-M8LockEnabled",
            "-DeviceSimRealFaceID"
        ]
        return app
    }

    private func exerciseNotification(
        mode: String,
        kind: String,
        body: String,
        destination: String
    ) throws {
        let permissionMonitor = addUIInterruptionMonitor(
            withDescription: "系统通知授权"
        ) { alert in
            for title in ["允许", "Allow"] {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        defer { removeUIInterruptionMonitor(permissionMonitor) }

        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestMode", "-uiTestEmpty",
            "-displayMode", mode,
            "-M8ResetLock",
            "-DeviceSimScheduleNotification", kind
        ]
        app.launch()
        // A harmless app interaction lets XCTest hand a first-run system
        // notification alert to the interruption monitor. Scheduling itself
        // still goes through the real UNUserNotificationCenter implementation.
        app.tap()
        let scheduled = element(
            "device.acceptance.notification.scheduled",
            in: app
        )
        XCTAssertTrue(
            scheduled.waitForExistence(timeout: 12)
        )
        XCTAssertTrue(
            scheduled.label.contains("已安排：\(body)"),
            "Notification was not authorized and scheduled: \(scheduled.label)"
        )

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(
            bundleIdentifier: "com.apple.springboard"
        )
        // Open Notification Center before the five-second trigger fires. Its
        // delivered-notification row is persistent, unlike a transient banner.
        let top = springboard.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)
        )
        let bottom = springboard.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)
        )
        top.press(forDuration: 0.1, thenDragTo: bottom)
        let notification = springboard.staticTexts[body].firstMatch
        XCTAssertTrue(
            notification.waitForExistence(timeout: 12),
            "Local notification did not arrive: \(body)"
        )
        let notificationBodyFrame = notification.frame
        let cells = springboard.cells.containing(
            .staticText,
            identifier: body
        )
        let otherContainers = springboard.otherElements.containing(
            .staticText,
            identifier: body
        )
        let notificationContainer: XCUIElement
        if cells.firstMatch.exists && cells.firstMatch.isHittable {
            notificationContainer = cells.firstMatch
        } else {
            let candidates = otherContainers.allElementsBoundByIndex.filter {
                $0.exists && $0.isHittable
            }
            guard let parent = candidates.first(where: {
                $0.identifier == "ListCell.ContentView"
                    && $0.frame.contains(notificationBodyFrame)
            }) ?? candidates.first(where: {
                $0.identifier == "ShortLook.Platter"
                    && $0.frame.contains(notificationBodyFrame)
            }) else {
                XCTFail("No hittable notification container for \(body)")
                return
            }
            notificationContainer = parent
        }
        XCTAssertTrue(notificationContainer.isHittable)
        XCTAssertTrue(
            notificationContainer.frame.contains(notificationBodyFrame)
        )
        print(
            "DEVICE_SIM_NOTIFICATION_CONTAINER_FRAME="
                + "\(notificationContainer.frame)"
        )
        notificationContainer.tap()
        XCTAssertEqual(
            app.wait(for: .runningForeground, timeout: 15),
            true,
            "Notification tap did not foreground CareThread"
        )
        XCTAssertTrue(
            element(destination, in: app).waitForExistence(timeout: 15),
            "Notification did not route to \(destination)"
        )
    }

    private func selectFirstPhoto(in app: XCUIApplication) throws {
        let picker = XCUIApplication(
            bundleIdentifier: "com.apple.mobileslideshow.photospicker"
        )
        let privateAccessOnboarding = picker.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "私密访问照片")
        ).firstMatch
        if privateAccessOnboarding.waitForExistence(timeout: 2) {
            let close = picker.buttons.matching(
                NSPredicate(format: "label == %@", "关闭")
            ).allElementsBoundByIndex.first(where: {
                $0.exists && $0.isHittable && $0.frame.minY > 150
            })
            guard let close else {
                XCTFail("PhotosPicker onboarding close button is unavailable")
                return
            }
            close.tap()
        }
        let firstCell = picker.collectionViews.cells.firstMatch
        if firstCell.waitForExistence(timeout: 2) {
            firstCell.tap()
        } else {
            // iOS 26.5 exposes PhotosPicker grid thumbnails as Image rather
            // than Cell. The host injects the size-verified fictional 48 MP
            // image immediately before this test, so the newest/first grid
            // image is the exact injected artifact rather than an arbitrary
            // image elsewhere in the picker.
            let thumbnail = picker.images.matching(
                NSPredicate(
                    format: "identifier == %@ AND label CONTAINS %@",
                    "PXGGridLayout-Info",
                    "照片"
                )
            ).firstMatch
            XCTAssertTrue(
                thumbnail.waitForExistence(timeout: 12),
                "iOS 26.5 PhotosPicker did not expose a photo thumbnail"
            )
            let thumbnailFrame = thumbnail.frame
            let pickerFrame = picker.frame
            XCTAssertGreaterThan(thumbnailFrame.width, 0)
            XCTAssertGreaterThan(thumbnailFrame.height, 0)
            XCTAssertTrue(pickerFrame.contains(thumbnailFrame))
            XCTAssertTrue(thumbnail.label.contains("照片"))
            print(
                "DEVICE_SIM_48MP_PICKER_SELECTED_LABEL=\(thumbnail.label)"
            )
            picker.coordinate(
                withNormalizedOffset: CGVector(
                    dx: thumbnailFrame.midX / pickerFrame.width,
                    dy: thumbnailFrame.midY / pickerFrame.height
                )
            ).tap()
        }
        let add = picker.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "添加")
        ).firstMatch
        XCTAssertTrue(
            add.waitForExistence(timeout: 8),
            "PhotosPicker did not expose Add after exact thumbnail coordinate tap"
        )
        XCTAssertTrue(add.isEnabled)
        XCTAssertTrue(add.isHittable)
        print("DEVICE_SIM_48MP_PICKER_ADD_LABEL=\(add.label)")
        add.tap()
    }

    private func finishImportedRecord(in app: XCUIApplication) throws {
        for _ in 0..<2 {
            let toggle = app.switches["m3.workbench.groupingConfirmed"]
            XCTAssertTrue(reveal(toggle, in: app))
            if toggle.value as? String != "1" {
                toggle.tap()
            }
            let proceed = app.buttons["m3.workbench.continue"]
            XCTAssertTrue(reveal(proceed, in: app))
            proceed.tap()
            if element("m3.confirmation", in: app)
                .waitForExistence(timeout: 90) {
                break
            }
            XCTAssertTrue(
                element("m3.workbench", in: app).waitForExistence(timeout: 15)
            )
        }
        XCTAssertTrue(
            element("m3.confirmation", in: app).waitForExistence(timeout: 15)
        )
        let save = app.buttons["m3.confirm.save"]
        XCTAssertTrue(reveal(save, in: app, maximumSwipes: 20))
        if !save.isEnabled {
            let title = app.textFields["m3.confirm.title"]
            XCTAssertTrue(reveal(title, in: app, maximumSwipes: 20))
            title.tap()
            title.clearAndType("虚构 48MP 录入验收")
            app.buttons["m3.confirm.keyboardDone"].tap()
            XCTAssertTrue(reveal(save, in: app, maximumSwipes: 20))
        }
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let override = app.buttons["确认不是重复，继续添加"]
        if override.waitForExistence(timeout: 3) {
            override.tap()
        }
    }


    private func reveal(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int = 10
    ) -> Bool {
        if element.waitForExistence(timeout: 1), element.isHittable {
            return true
        }
        for _ in 0..<maximumSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1), element.isHittable {
                return true
            }
        }
        return false
    }

    private func waitUntilEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND enabled == true"
            ),
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }
}
