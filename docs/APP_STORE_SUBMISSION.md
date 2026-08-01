# CareThread App Store 提交说明

本页是提交人员的唯一操作清单。CareThread 当前定位为无账号、无云端、无互联网服务器、完全本地的个人就医资料整理工具，不是医疗服务或医疗器械。

## 1. 当前发布状态与提交前必做项

法律正文与官网的发布阻断已解除，自动化门禁已通过：

- `docs/legal`、App 本地资源与官网两页已统一为 2026-08-01 版本：存档默认不加密、可选至少 12 位口令；PhotosPicker 只读取用户明确选择的项目；联系邮箱为 `jianghaibo@multiego.me`。
- `LegalAgreement.currentTermsVersion` 已更新，旧版本用户只看到不可下滑关闭的变更摘要，不重跑首次引导。
- 法律/权限单测 6/6、UI 3/3；最终 `Scripts/acceptance.sh` 退出 0，法律四文件哈希、关键事实、权限逐字与官网零运行时脚本门禁全部 PASS。
- Cloudflare Pages 项目 `carethread` 以 `website/` 为站点根、无构建命令和环境变量；正式域名为：
  - 首页：`https://carethread.8xd.io/`
  - 隐私政策：`https://carethread.8xd.io/privacy`
  - 用户协议：`https://carethread.8xd.io/terms`
- `CareThreadPDFBranding.officialWebsiteURL` 已指向上述首页，PDF 二维码说明已恢复为“扫码访问官网”；二维码载荷仍由离线 Core Image 生成，不会在导出时联网。
- 正式提交前仍必须由用户完成真机清单：真机安装、双机换机、真实病历 OCR、大字版真人试用、锁屏/Face ID/通知/微信/48MP/内存压力，并最终确定上架地区路线。
- 用 Archive 的 Privacy Report 再核对一次 App 本体和 ZIPFoundation 的隐私清单；不得只凭源码文件判断最终归档。

重新部署官网时，从仓库根目录执行：

```bash
opencli wrangler pages deploy website \
  --project-name carethread \
  --branch main \
  --commit-hash <完整提交 SHA> \
  --commit-message "Deploy CareThread static website"
```

随后必须重新验证三条 HTTPS 路径、同源 CSS/图片，并运行 `Scripts/acceptance.sh` 的协议版本锁定与官网零第三方资源检查。

## 2. App Store Connect 隐私政策 URL

发布前验证通过后填写：

`https://carethread.8xd.io/privacy`

支持 URL 可填写首页：

`https://carethread.8xd.io/`

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
| 照片 | 通过系统照片选择器读取你明确选中的报告截图。所选照片只会保存在这台手机上。 |
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
- About 标准版和大字版入口、可选官网外链、反馈邮箱 `jianghaibo@multiego.me`、版本号与 MIT/ZIPFoundation 许可均可见；协议正文始终读取 App 本地资源，官网链接不作为正文来源。
- 零第三方依赖新增；运行时网络能力仍只有既有局域网换机传输。
