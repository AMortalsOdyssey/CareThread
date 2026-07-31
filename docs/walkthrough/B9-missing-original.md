# B9 原件缺失恢复

- `OriginalViewer` 和 `ElderOriginalViewer` 在文件不可读时显示“原件暂时无法读取”、恢复说明与“从备份恢复原件”按钮。
- 两个按钮均直接进入按当前成员隔离的 `BackupRestoreView(patientID:)`，标识分别为 `m3.viewer.recoverOriginal`、`elder.original.recoverOriginal`。
- 自动化：`DesignSpecConformanceTests.missingOriginalProvidesBackupRecoveryEntry`；Vault 缺失文件与备份完整性测试覆盖错误而非崩溃。
- 结果：标准版和大字版均有明确错误、可执行恢复入口；不会把缺失原件伪装成空白内容。
