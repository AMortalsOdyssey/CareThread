# DESIGN-08 老人版交互走查

- 视觉：`15`–`18` 四个老人版页面的 Light/Dark 八屏逐一核对；三槽导航为“今天 / 拍照存报告 / 记录”。
- XCUITest：`testU13ElderModeShowsThreeTabsAndSettingsSwitch`、`testU14TodayShowsMedicationFollowUpAndDoctorBrief`、`testU15SimplifiedFixtureCaptureSavesPendingRecord`、`testU16PendingBannerAppearsAfterElderCapture`、`testB21AccessibilitySizeKeepsPrimaryActionsHittable`。
- 静态规则：老人版源文件不含隐藏滑动、长按、上下文菜单、缩放或循环动画；主按钮不低于 60pt。
- 结果：主任务均有显式按钮和立即反馈，无 chip 堆叠、隐藏手势或只读裁剪；真实老人零指导试用仍按真机清单执行。
