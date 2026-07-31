import Foundation
import Testing
@testable import CareThread

struct LegalAndPermissionComplianceTests {
    @Test("引导同意版本与协议更新提示策略稳定")
    func agreementVersionPolicy() {
        #expect(!LegalAgreement.currentTermsVersion.isEmpty)
        #expect(
            !LegalAgreement.requiresUpdateNotice(
                onboardingCompleted: false,
                acceptedVersion: ""
            )
        )
        #expect(
            !LegalAgreement.requiresUpdateNotice(
                onboardingCompleted: true,
                acceptedVersion: LegalAgreement.currentTermsVersion
            )
        )
        #expect(
            LegalAgreement.requiresUpdateNotice(
                onboardingCompleted: true,
                acceptedVersion: "2026-01-01"
            )
        )
    }

    @Test("启动权限清单为空且六项拒绝均有核心降级")
    func deniedPermissionsKeepCoreAvailable() {
        #expect(PermissionFallbackPolicy.requestedAtLaunch.isEmpty)
        #expect(PermissionKind.allCases.count == 6)
        for permission in PermissionKind.allCases {
            #expect(
                PermissionFallbackPolicy.coreRemainsAvailableWhenDenied(permission),
                "Missing denied fallback for \(permission.rawValue)"
            )
            #expect(
                !PermissionFallbackPolicy.fallbackDescription(for: permission).isEmpty
            )
        }
    }

    @Test("启动视图不包含权限请求且录入保留无权限路径")
    func startupSourceContainsNoAuthorizationRequest() throws {
        let root = repositoryRoot
        let startup = try [
            "CareThread/App/CareThreadApp.swift",
            "CareThread/App/RootView.swift"
        ].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        for forbidden in [
            "requestAuthorization(",
            "requestAccess(",
            "requestFullAccessToEvents(",
            "evaluatePolicy("
        ] {
            #expect(!startup.contains(forbidden))
        }

        let capture = try String(
            contentsOf: root.appendingPathComponent(
                "CareThread/Features/Capture/CaptureFlow.swift"
            ),
            encoding: .utf8
        )
        #expect(capture.contains("case files"))
        #expect(capture.contains("case manual"))
    }

    @Test("Privacy manifest 固定声明零追踪与零收集")
    func privacyManifestRemainsZeroCollection() throws {
        let url = repositoryRoot.appendingPathComponent(
            "CareThread/Resources/PrivacyInfo.xcprivacy"
        )
        let data = try Data(contentsOf: url)
        let root = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        #expect(root["NSPrivacyTracking"] as? Bool == false)
        #expect((root["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((root["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
    }

    @Test("法律正文原文件直接进入资源阶段而非复制改写")
    func immutableLegalSourcesAreBundledDirectly() throws {
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        for kind in LegalDocumentKind.allCases {
            let relativePath = "docs/legal/\(kind.resourceName).md"
            #expect(project.contains("path: \(relativePath)"))
            let content = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(content.contains(kind.title))
            #expect(content.count > 1_000)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
