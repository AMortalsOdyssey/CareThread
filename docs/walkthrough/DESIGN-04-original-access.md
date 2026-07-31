# DESIGN-04 一步查看原文

- 修复前反例：旧演示种子没有附件，记录卡片的“查看原文”承诺在截图中不可见；旧证据将“代码存在入口”误写成“演示数据可见”，本轮明确记为 FAIL。
- 修复后视觉证据：`05-records-*` 的每条演示记录都显示“查看原文”，`06-record-detail-*` 显示原件入口，`07-original-ocr-*` 展示原件/识别文字切换；`04-capture-confirmation-*` 保持页级原件入口。
- 自动化：`DesignSpecConformanceTests.originalIsOneStepReachable` 反查卡片、详情和确认页的直接入口与“查看原文”文案。
- 数据可见性：`SeedServiceTests.test_seedDemo_whenEmpty_insertsSixRecords` 断言六条故事线记录全部挂有附件；截图清单将记录卡片、详情和原件页绑定到同一个干净源码提交。
- 源码：`RecordLibraryView`、`RecordDetailView`、`CaptureConfirmationView` 均直接设置目标原件，不经过二级管理页。
- 结果：修复前 FAIL → 修复后 FIXED；卡片、详情、核对页到原文均为一步操作且在演示数据中真实可见，缺失原件走 B9 的明确恢复路径。
