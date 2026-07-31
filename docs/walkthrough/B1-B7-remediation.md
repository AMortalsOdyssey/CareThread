# Review B1–B7 修复前后走查

本记录保留交付包 08 §四的修复前 FAIL，不以最终通过覆盖历史。修复后证据来自提交 `57b28a6` 对应的 iPhone 16 / iOS 26.5 生产导航截图、专项测试和源码复核。

## B1 记录列表信息缩水

- 修复前：FAIL。卡片缺简要结论、状态、科室/年龄/来源和可见原件入口。
- 修复后：FIXED。`05-records-light.png` 与 `05-records-dark.png` 可见两行结论、异常提示、待确认状态、科室/年龄/来源及“查看原文”。
- 自动化：`RecordListRowTests.presentationIncludesDecisionFields` 覆盖全部决策字段；空摘要记录保持紧凑。

## B2 详情页工程元数据与摘要矛盾

- 修复前：FAIL。第一屏暴露日期精度/时区，且摘要称有指标但没有指标表。
- 修复后：FIXED。`06-record-detail-*` 使用用户话术，展示 5 项指标、2 项异常，不再暴露工程元数据。
- 自动化：`SeedServiceTests.test_seedDemo_whenEmpty_insertsSixRecords` 断言摘要、5 项结构化指标与 2 项异常一致。

## B3 演示种子质量

- 修复前：FAIL。标题包含测试术语、没有附件、结构化指标缺失。
- 修复后：FIXED。六条虚构故事线均使用真实病程话术、挂受保护演示原件；`05`–`07` 路由可连续查看卡片、详情和原件/OCR。
- 自动化：`SeedServiceTests` 覆盖唯一成员、六条记录全部带附件、指标一致性、两段剂量链及幂等。

## B4 中文环境

- 修复前：FAIL。日期控件与备份时间在非中文系统出现英文。
- 修复后：FIXED。根环境、开发语言和截图启动参数统一为简体中文；`04-capture-confirmation-*` 与 `13-backup-*` 未见英文日期。
- 自动化：`M4M5PresentationTests.managementActivityDateUsesChineseLocale` 断言固定中文时间；manifest 记录 `language=zh-Hans`、`locale=zh_CN`。

## B5 走查证据虚高

- 修复前：FAIL。旧 DESIGN-04 只证明代码入口存在，没有核对演示数据中是否可见，也没有保留反例。
- 修复后：FIXED。`DESIGN-04-original-access.md` 明确保留修复前 FAIL，并同时要求截图可见性、种子附件断言与直接入口三类证据。本文件对 B1–B7 逐项记录 FAIL → FIXED。
- 诚实边界：模拟器不能替代相机、FaceID、真实通知/日历、微信、双机无线、锁屏文件保护和长辈真人试用；这些项目仍留在 `PROGRESS.md` 真机清单。

## B6 UI 测试污染持久库

- 修复前：FAIL。`-uiTestMode` 可把测试药物写进持久 SwiftData/Vault。
- 修复后：FIXED。UI 测试只请求内存 ModelContainer，Vault 使用进程临时目录；失败也不回落正式库。
- 自动化：`DatabaseBootstrapperTests.uiTestBootstrap_neverFallsBackToPersistentStore` 断言只请求内存模式；`CareThreadUITests.testUITestDataNeverSurvivesIntoFreshLaunchOrOnboarding` 覆盖写入、终止、新装引导与空首页/空用药页。

## B7 管理页双箭头与英文活动时间

- 修复前：FAIL。NavigationLink 系统箭头与自定义箭头叠加，最近活动时间为英文。
- 修复后：FIXED。管理行仅保留 NavigationLink 系统箭头；`12-manage-*` 未见双箭头，活动时间为中文。
- 自动化：管理行显式传入 `showsChevron: false`；`managementActivityDateUsesChineseLocale` 覆盖中文时间格式。

## 本轮视觉结论

- 46/46 PNG 均为 1179×2556，46 个唯一 SHA-256；标准版 38、大字版 8，Light/Dark 各 23。
- 接触表逐屏检查通过：没有空白或错误路由，大字版四屏无裁剪，Sheet/Push/Tab 层级和选中状态合理。
- `Scripts/validate-screenshot-manifest.sh` 通过，manifest 的 `sourceTreeDirty=false`，并绑定生产源码提交、runtime、就绪标记与每图哈希。
