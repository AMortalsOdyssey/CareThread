# DESIGN-04 一步查看原文

- 视觉证据：`06-record-detail-*` 显示原件入口，`07-original-ocr-*` 展示原件/识别文字切换；核对页保持页级原件入口。
- 自动化：`DesignSpecConformanceTests.originalIsOneStepReachable` 反查卡片、详情和确认页的直接入口与“查看原文”文案。
- 源码：`RecordLibraryView`、`RecordDetailView`、`CaptureConfirmationView` 均直接设置目标原件，不经过二级管理页。
- 结果：卡片、详情、核对页到原文均为一步操作；缺失原件走 B9 的明确恢复路径。
