# Privacy Manifest 复核

复核日期：2026-07-31。

CareThread 的主应用清单位于
`CareThread/Resources/PrivacyInfo.xcprivacy`。当前固定声明为：

- 不跟踪，不包含跟踪域名；
- 不向开发者或第三方收集数据；病历只保存在用户设备，用户主动发起的附近迁移只发送到其选择的另一台 iPhone；
- `CA92.1`：`UserDefaults` / `@AppStorage` 只保存本 App 可见的显示模式、当前成员、首次引导和应用锁偏好；
- `E174.1`：备份恢复与附近迁移在写入前检查可用空间，空间不足时可观察地拒绝操作并保留现有资料；
- `C617.1`：Vault、临时导出和恢复事务只读取 App 容器中文件的时间戳、大小或元数据，用于清理过期副本与完整性检查。

对应实现证据：

- `App/RootView.swift`、`Features/Elder/*` 与 `Core/Services/AppLock/AppLockService.swift` 使用 App 内 `UserDefaults`；
- `Core/Services/Backup/BackupImporter.swift`、`Core/Services/NearbyTransfer/TransferStagingStore.swift` 和 `Core/Services/NearbySync/NearbySyncImporter.swift` 在写入前读取可用空间；
- `Core/Services/VaultShareCopyService.swift` 读取 App 临时副本的修改时间并清理过期文件。

官方依据：

- [Apple：Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Apple：Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Apple：Required reason 类型与批准理由](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [Apple：第三方 SDK 要求](https://developer.apple.com/support/third-party-SDK-requirements/)

ZIPFoundation 0.9.20 自带独立 `PrivacyInfo.xcprivacy`，Xcode 构建日志已确认其资源包进入 App；应用自身不能代替第三方包声明其 required-reason API。每次升级 Xcode、ZIPFoundation 或新增系统 API 时须重新生成归档 Privacy Report 并复核本表。
