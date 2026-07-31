import Foundation

enum LegalDocumentKind: String, CaseIterable, Identifiable {
    case privacyPolicy
    case termsOfService

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacyPolicy:
            "隐私政策"
        case .termsOfService:
            "用户协议"
        }
    }

    var resourceName: String {
        switch self {
        case .privacyPolicy:
            "PRIVACY_POLICY"
        case .termsOfService:
            "TERMS_OF_SERVICE"
        }
    }
}

enum LegalDocumentLoadError: LocalizedError, Equatable {
    case resourceMissing(String)
    case unreadable(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing:
            "内置文档没有随 App 安装，请重新安装后再试。"
        case .unreadable:
            "这份内置文档暂时无法读取，请重新打开后再试。"
        case .empty:
            "这份内置文档内容为空，请重新安装后再试。"
        }
    }
}

/// Reads the immutable, bundled legal Markdown without using any network API.
struct LegalDocumentLoader {
    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func load(_ kind: LegalDocumentKind) throws -> String {
        guard let url = bundle.url(
            forResource: kind.resourceName,
            withExtension: "md"
        ) else {
            throw LegalDocumentLoadError.resourceMissing(kind.resourceName)
        }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LegalDocumentLoadError.empty(kind.resourceName)
            }
            return content
        } catch let error as LegalDocumentLoadError {
            throw error
        } catch {
            throw LegalDocumentLoadError.unreadable(kind.resourceName)
        }
    }
}

enum LegalAgreement {
    static let acceptedTermsVersionKey = "carethread.acceptedTermsVersion"
    static let currentTermsVersion = "2026-07-31"
    static let currentChangeSummary =
        "隐私政策和用户协议现已内置到 App。资料仍只保存在本机，CareThread 仍不提供医学判断；请继续自行保管与备份资料。"

    static func requiresUpdateNotice(
        onboardingCompleted: Bool,
        acceptedVersion: String
    ) -> Bool {
        onboardingCompleted && acceptedVersion != currentTermsVersion
    }
}

enum PermissionKind: String, CaseIterable {
    case camera
    case photos
    case notifications
    case calendar
    case biometrics
    case localNetwork
}

/// Compliance contract used by acceptance tests and About copy. It deliberately
/// contains no authorization API: every request remains attached to the
/// corresponding user action in its feature adapter.
enum PermissionFallbackPolicy {
    static let requestedAtLaunch: Set<PermissionKind> = []

    static func coreRemainsAvailableWhenDenied(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .camera, .photos, .notifications, .calendar, .biometrics,
             .localNetwork:
            true
        }
    }

    static func fallbackDescription(for permission: PermissionKind) -> String {
        switch permission {
        case .camera:
            "可以改用相册、文件或手动录入。"
        case .photos:
            "可以改用拍照、文件或手动录入。"
        case .notifications:
            "计划照常保存，只是不发送本地提醒。"
        case .calendar:
            "复查计划仍保存在 CareThread，只是不写入系统日历。"
        case .biometrics:
            "不开启应用锁，其他资料管理功能照常可用。"
        case .localNetwork:
            "可以继续使用存档导出与导入。"
        }
    }
}
