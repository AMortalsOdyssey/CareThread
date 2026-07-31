import Foundation
import Testing
@testable import CareThread

struct ScreenshotRouteContractTests {
    @Test("截图启动参数只接受完整且已知的路由")
    func parsesOnlyKnownCompleteRouteArguments() {
        #expect(
            ScreenshotRoute.parse(
                arguments: ["CareThread", "-screenshotRoute", "home"]
            ) == .home
        )
        #expect(
            ScreenshotRoute.parse(
                arguments: [
                    "CareThread",
                    "-screenshotRoute",
                    "elder-capture-question"
                ]
            ) == .elderCaptureQuestion
        )
        #expect(
            ScreenshotRoute.parse(
                arguments: ["CareThread", "-screenshotRoute"]
            ) == nil
        )
        #expect(
            ScreenshotRoute.parse(
                arguments: [
                    "CareThread",
                    "-screenshotRoute",
                    "unknown"
                ]
            ) == nil
        )
        #expect(
            ScreenshotRoute.parse(arguments: ["CareThread"]) == nil
        )
    }

    @Test("23 条生产路由严格生成 46 张标准与长辈双外观证据")
    func routeInventoryIsCompleteAndUnique() {
        let routes = ScreenshotRoute.allCases
        #expect(routes.count == 23)
        #expect(Set(routes.map(\.rawValue)).count == 23)
        #expect(Set(routes.map(\.marker)).count == 23)
        #expect(routes.filter(\.isElder).count == 4)
        #expect(routes.filter { !$0.isElder }.count == 19)
        #expect(routes.count * AppearanceMode.allCases.filter {
            $0 != .system
        }.count == 46)
        #expect(routes.allSatisfy { !$0.featureMarker.isEmpty })
    }

    @Test("新增五条路线进入真实标准版导航壳")
    func addedRoutesDescribeProductionNavigation() {
        assert(
            .memberManagement,
            shell: "StandardRootTabView",
            presentation: "push",
            selectedTab: 4,
            tabBarExpected: true,
            featureMarker: "member.management"
        )
        assert(
            .comparison,
            shell: "StandardRootTabView",
            presentation: "sheet",
            selectedTab: 0,
            tabBarExpected: false,
            featureMarker: "m7.compare"
        )
        assert(
            .export,
            shell: "StandardRootTabView",
            presentation: "sheet",
            selectedTab: 0,
            tabBarExpected: false,
            featureMarker: "m7.brief"
        )
        assert(
            .nearbySync,
            shell: "StandardRootTabView",
            presentation: "sheet",
            selectedTab: 0,
            tabBarExpected: false,
            featureMarker: "nearbySync.root"
        )
        assert(
            .more,
            shell: "StandardRootTabView",
            presentation: "sheet",
            selectedTab: 0,
            tabBarExpected: false,
            featureMarker: "m45.more"
        )
    }

    @Test("Shell 路由表与 Swift 生产导航合同逐项一致")
    func shellRouteInventoryMatchesSwiftContract() throws {
        let script = try sourceText("Scripts/screenshot-routes.sh")
        let rows = script.split(separator: "\n").compactMap { line -> [String]? in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.first == "\"",
                  value.last == "\"",
                  value.contains("|") else {
                return nil
            }
            return String(value.dropFirst().dropLast())
                .split(separator: "|", omittingEmptySubsequences: false)
                .map(String.init)
        }
        #expect(rows.count == 23)
        #expect(rows.allSatisfy { $0.count == 9 })
        #expect(Set(rows.map { $0[0] }).count == 23)
        #expect(Set(rows.map { $0[1] }).count == 23)

        for row in rows {
            let route = try #require(ScreenshotRoute(rawValue: row[2]))
            #expect(row[3] == (route.isElder ? "elder" : "standard"))
            #expect(row[4] == route.shell)
            #expect(row[5] == route.presentation)
            #expect(
                row[6].isEmpty
                    ? route.selectedTab == nil
                    : route.selectedTab == Int(row[6])
            )
            #expect(row[7] == String(route.tabBarExpected))
            #expect(row[8] == route.featureMarker)
        }
    }

    @Test("截图入口不能绕过 Root 或直接构造功能页")
    func sourceGuardRejectsDirectScreenshotFeatureConstruction() throws {
        let app = try sourceText("CareThread/App/CareThreadApp.swift")
        let routing = try sourceText(
            "CareThread/App/ScreenshotAutomationRoute.swift"
        )
        let legacy = repositoryRoot().appendingPathComponent(
            "CareThread/App/ScreenshotRouteView.swift"
        )

        #expect(app.contains("AppLockGate"))
        #expect(app.contains("RootView()"))
        #expect(!app.contains("ScreenshotRouteView"))
        #expect(!app.contains("ScreenshotRoute.current"))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        for forbidden in [
            "HomeDashboardView(",
            "RecordDetailView(",
            "OriginalViewer(",
            "BriefWorkspaceView(",
            "ElderRootView("
        ] {
            #expect(!app.contains(forbidden))
            #expect(!routing.contains(forbidden))
        }
    }

    private func assert(
        _ route: ScreenshotRoute,
        shell: String,
        presentation: String,
        selectedTab: Int,
        tabBarExpected: Bool,
        featureMarker: String
    ) {
        #expect(route.shell == shell)
        #expect(route.presentation == presentation)
        #expect(route.selectedTab == selectedTab)
        #expect(route.tabBarExpected == tabBarExpected)
        #expect(route.featureMarker == featureMarker)
    }

    private func sourceText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
