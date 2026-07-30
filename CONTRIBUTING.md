# Contributing to CareThread

感谢你愿意帮助 CareThread。项目保存的是高度敏感的健康资料，因此提交内容必须可审计、可复现，并且不能包含任何真实病历、身份信息、账号、密钥或设备日志。

## 当前贡献阶段

在 CareThread 的个人与公司贡献者协议（ICLA/CCLA）正式发布前：

- 欢迎提交 issue、虚构数据的缺陷复现、可用性反馈和需求描述；
- 暂不合并外部代码、测试、设计、文案或其他具有著作权的实质作品；
- 提前提交的 pull request 可能被关闭，但问题与复现信息会被保留并由维护者独立实现。

这项限制用于保持清晰的知识产权链，确保项目未来能够持续开源、商业发行或整体转让；它不改变仓库现有代码的 MIT 许可。

## 协议开放后的提交要求

贡献通道开放后，每位贡献者必须：

1. 签署届时仓库公布的 ICLA；代表公司提交时同时完成 CCLA 或雇主授权；
2. 为每个 commit 添加 Developer Certificate of Origin 1.1 的 `Signed-off-by`：

   ```text
   Signed-off-by: Your Name <your-email@example.com>
   ```

3. 说明第三方素材、生成式工具辅助内容和对应许可证；
4. 只使用虚构测试资料，不上传真实健康信息；
5. 通过仓库的构建、测试、离线边界和隐私扫描。

提交贡献并不授予 CareThread 名称、App 图标或官方发行身份的使用权。代码许可见 [LICENSE](LICENSE)，品牌边界见 [TRADEMARKS.md](TRADEMARKS.md)。
