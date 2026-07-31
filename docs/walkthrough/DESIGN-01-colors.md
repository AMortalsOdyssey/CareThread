# DESIGN-01 颜色 token 走查

- 设备：iPhone 16 / iOS 26.5 模拟器；源码提交 `5b535e4a8c93fc7e8b980f4f1fa62c393dd7d9e8`。
- 方法：逐屏查看 `docs/screenshots/` 的 46 张 Light/Dark PNG，并反查 `CTColor.swift` 与 Assets 的双外观定义。
- 10 处抽样：页面底色 `bgBase`、卡片 `bgElevated`、内嵌区 `bgInset`、分隔线 `separator`、边框 `outline`、主文字 `inkPrimary`、次文字 `inkSecondary`、主操作 `primary`、警告卡 `warningContainer`、检验类型 `lab`。
- 结果：两种外观均保持文字/背景层级、主操作和警告语义；未发现裸色导致的错误反转、低对比占位或类型色失义。
