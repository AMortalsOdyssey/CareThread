# CareThread 实施进度

## M0 骨架与基建

- 状态：完成
- 基线：Xcode 16.4、Swift 5 语言模式、iOS 17.0+、iPhone 16 / iOS 18.6。
- 已创建 XcodeGen 工程、标准版五槽与老人版三槽根结构、完整设计 token 骨架、Light/Dark 颜色资产入口、验证脚本。
- 验证：`Scripts/verify.sh` 退出码 0；Swift Testing 1/1、XCUITest 1/1；Computer Use 打开模拟器核对五槽 Tab 壳与暖纸白/医用青 token 生效。

## 真机验收（开发完成后由用户执行）

- [ ] VisionKit 相机扫描、自动裁边与多页连拍
- [ ] FaceID 解锁与冷启动/回前台 60 秒锁定
- [ ] 标准版与老人版通知真实到达及点击落点
- [ ] 真实病历、手写处方、化验单与发票 OCR 体感
- [ ] 备份 ZIP 在 Mac 解包可读、就诊摘要 PDF 打印效果
- [ ] 老人版真人零指导完成一次“拍照存报告”和一次“看今天的药”
