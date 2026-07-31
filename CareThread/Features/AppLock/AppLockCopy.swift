import Foundation

enum AppLockCopy {
    static let navigationTitle = "应用锁"
    static let title = "保护健康资料"
    static let description = "开启后，CareThread 在冷启动或进入后台后会锁定。认证由系统完成，生物识别不可用时可使用设备密码。"
    static let toggle = "启用应用锁"
    static let unavailable = "请先为这台 iPhone 设置设备密码，才能开启应用锁。"
    static let enabled = "应用锁已开启"
    static let disabled = "应用锁未开启"
    static let sensitiveNotice = "锁屏能减少他人直接看到资料的风险，但导出的备份仍需由你妥善保管。"
    static let systemLockNotice = "iOS 18 及以上还可以在桌面长按 CareThread 图标，选\"需要 Face ID\"，给它再加一道系统锁。"
    static let enableReason = "确认开启 CareThread 应用锁"
    static let unlockReason = "解锁并查看本机健康资料"
    static let unlockTitle = "解锁 CareThread"
    static let unlockDescription = "资料仍安全保存在这台手机上。"
    static let retry = "重试"
    static let failed = "没有完成解锁，可以重试。"
    static let cancel = "取消"
    static let useDevicePasscode = "使用设备密码"
}
