# CareThread App Store 提交说明

本页是提交人员的唯一操作清单。CareThread 当前定位为无账号、无云端、无互联网服务器、完全本地的个人就医资料整理工具，不是医疗服务或医疗器械。

## 1. 发布前阻断项

以下项目未关闭前，不得提交审核：

- **法律正文与当前备份行为不一致。** `docs/legal/PRIVACY_POLICY.md` 第 75–81 行及 `TERMS_OF_SERVICE.md` 第 59–66 行写的是“备份导出默认使用至少 12 位密码加密”；当前产品主路径则是默认导出明文存档、口令加密仅为折叠的可选项。两份正文已被本轮任务明确锁定，代码也不得回退。必须由产品负责人完成法律复核，形成新版本正文、更新“最后更新”日期与 `LegalAgreement.currentTermsVersion`，再重新跑法律页和版本变更测试。
- **照片权限描述需要与系统选择器口径统一。** 当前录入使用 `PhotosPicker` 系统选择器读取用户明确选择的图片，没有调用 `PHPhotoLibrary.requestAuthorization` 请求整个照片库权限；隐私政策第 52–65 行和 `NSPhotoLibraryUsageDescription` 仍按“从相册导入时申请照片权限”表述。它没有扩大数据访问，但属于事实口径差异。下一次法律正文修订时应由产品/法务决定改成“通过系统照片选择器读取你明确选择的图片”，并在归档上确认实际权限行为；本轮不改已锁定正文。
- GitHub Pages 尚需在仓库设置中启用 `main` 分支 `/docs` 目录，并实测下列两个 URL 在未登录、无缓存环境返回 HTTP 200 且手机可完整阅读：
  - 隐私政策：`https://amortalsodyssey.github.io/CareThread/privacy.html`
  - 用户协议：`https://amortalsodyssey.github.io/CareThread/terms.html`
- Pages 验证成功后，才可把 `CareThreadPDFBranding.officialWebsiteURL` 改为 `https://amortalsodyssey.github.io/CareThread/`，并把 PDF 二维码说明恢复为“扫码访问官网”。在站点实际上线前不得宣称二维码已经指向官网。
- 用 Archive 的 Privacy Report 再核对一次 App 本体和 ZIPFoundation 的隐私清单；不得只凭源码文件判断最终归档。

## 2. App Store Connect 隐私政策 URL

发布前验证通过后填写：

`https://amortalsodyssey.github.io/CareThread/privacy.html`

支持 URL 可填写首页：

`https://amortalsodyssey.github.io/CareThread/`

## 3. App 隐私问卷

“App 隐私”中对“您或您的第三方合作伙伴是否从此 App 收集数据”选择：

**否，我们不会从此 App 收集数据。**

因此不勾选健康与健身、联系方式、标识符、使用数据、诊断、位置、用户内容或其他任何数据类别，也不声明追踪。理由：资料保存在 App 私有本地存储；App 没有账号、分析、广告、崩溃上报或互联网服务端。用户主动通过系统分享面板导出的文件，不是开发者收集。

不得把以下本地处理误填成“收集”：本机 OCR、SwiftData 存储、本地通知、写入系统日历、Face ID/Touch ID 的系统验证结果、用户主动发起的同一局域网换机直传。若未来增加任何服务器、统计 SDK、远程诊断、云同步或 AI 服务，必须重新回答问卷并更新隐私政策后才能发布。

## 4. 权限用途说明

以下文字必须与构建内 `Info.plist` 一致：

| 权限 | 用途说明 |
| --- | --- |
| 相机 | 拍摄纸质报告需要使用相机。照片只会保存在这台手机上。 |
| 照片 | 从相册导入报告截图需要访问照片。所选照片只会保存在这台手机上。 |
| 日历 | 只有在你主动选择“加入系统日历”时，CareThread 才会把复查安排写入日历。 |
| Face ID | 用面容 ID 保护你的健康资料。 |
| 本地网络 | 在你主动发起换机时，通过本地网络把所选家人的资料加密传到另一台 iPhone。 |

通知权限没有 `Info.plist` 用途字段。它只在用户主动打开某条用药或复查提醒时由系统询问。六项权限均不得在启动时预取；拒绝后浏览、编辑、原件查看、时间线与本地导出等核心能力继续可用。

## 5. 审核备注建议

可在 Review Notes 使用以下说明，并按最终构建实际入口补充截图或演示路径：

> CareThread is a fully local personal medical-record organizer, not a medical service or medical device. It has no account system, analytics, advertising, cloud backend, or internet server communication. OCR and all data processing run on device. The app does not diagnose, recommend treatment, or provide medication advice. Permissions are requested only after the user starts the related feature, and denying a permission does not block the core record-management experience. The only network-related feature is a user-initiated, encrypted transfer directly between two iPhones on the same local Wi-Fi network; cellular data is prohibited and no server is involved. Reviewers can use the built-in fictional sample flow; no real medical information is required.

建议附中文补充：

> 本 App 仅整理用户自己的既有资料，不作医学判断。审核无需注册或登录，也无需提供真实病历；可使用内置虚构样张走完整录入、核对与导出流程。

## 6. 审核路径

1. 首次启动阅读第三屏的三项说明，离线打开隐私政策和用户协议，点击“我已了解，开始使用”。
2. 选择标准版，使用虚构样张完成本机 OCR、字段核对、原件查看与 PDF 导出。
3. 在“管理 → 关于 CareThread”查看隐私政策、用户协议、医疗免责、版本、开源许可与反馈入口。
4. 如需验证大字版，在“管理”切换；在“大字版 → 设置 → 关于与免责”查看同一内容。
5. 权限只在相应按钮触发后出现。拒绝相机或照片后可用文件/手动录入；拒绝通知或日历后计划仍保存；不开应用锁不影响使用；拒绝本地网络后仍可导出和导入存档。

## 7. 最终核对

- App 内两份全文在飞行模式可完整滚动阅读，且与审核 URL 的已批准正文一致。
- `acceptedTermsVersion` 在首次同意后写入；法律版本变化只弹变更摘要，不重跑整个引导。
- `PrivacyInfo.xcprivacy` 仍为 `NSPrivacyTracking=false`、追踪域名空、收集数据类型空。
- 启动过程没有系统权限弹窗；相机、照片、通知、日历、生物识别和本地网络各自只由用户动作触发。
- About 标准版和大字版入口、反馈邮箱 `jianghaibo@multiego.me`、版本号与 MIT/ZIPFoundation 许可均可见。
- 零第三方依赖新增；运行时网络能力仍只有既有局域网换机传输。
