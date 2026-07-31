# B18 通知权限拒绝

- XCUITest `testDeniedNotificationPermissionShowsSettingsRecoveryWithoutCrash` 注入 denied 权限状态，新增带提醒的虚构用药并保存。
- 保存业务资料成功；界面显示权限反馈和“去系统设置”恢复按钮，流程没有崩溃或卡死。
- 通知与系统日历适配器测试继续覆盖拒绝、取消、幂等替换和资料保存解耦。
- 结果：拒绝权限不会阻止病历/用药落库，也不会反复弹出系统请求。
