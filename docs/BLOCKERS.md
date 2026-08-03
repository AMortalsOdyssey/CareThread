# CareThread 阻塞记录

当前没有代码、法律正文、官网部署或自动化验收阻塞。

2026-08-03 已按产品真实行为形成唯一法律版本：导出存档默认不加密，可选至少 12 位口令；系统照片选择器只读取用户明确选择的项目，不请求整个照片库权限；联系邮箱统一为 `founder@8xd.io`。`docs/legal` 是 App 直接打包的本地正文源，官网两页与 App 版本号同步到 2026-08-03。法律聚焦测试 6/6、UI 3/3，全量验收的四文件哈希、关键事实与权限逐字门禁全部 PASS。

Cloudflare Pages 正式域名为 `https://carethread.8xd.io/`。`/` 最终 HTTPS 200，`/privacy` 与 `/terms` 规范到尾斜杠后最终 HTTPS 200，CSS 与 Logo 均为 200。部署后发现 Cloudflare 邮箱混淆会注入解码脚本，已用局部 `email_off` 标记关闭；线上 HTML 与去除该构建标记后的仓库正文哈希一致，且无 `<script>`、`cdn-cgi` 或邮箱解码器。

源码与证据基线 `e8df13c` 的 `Scripts/acceptance.sh` 已退出 0：720/720 单元与集成测试、60/60 UI、23/23 边界、46 张截图、法律/权限、依赖、零联网、隐私与走查证据全部 PASS。最终截图 manifest 绑定干净源码 `7334a17`。设备整批复验在显式指定 iPhone 17 主模拟器与 iPhone 16 第二模拟器后退出 0，汇总 `PASS FAIL=0 RESIDUAL=4`，107/107 聚焦测试与双模拟器换机页面均通过。

仍未闭环的只是不能由模拟器代替的真机证据：完整照片库 TCC、3/4 通知点击置前、通知冷启动、48MP `PhotosPicker` 返回与 RSS，以及双机 AWDL、微信分享、锁屏文件保护/通知视觉、Jetsam/热压力、真实病历 OCR 和长辈版真人试用。它们不是当前代码阻塞，也不得被写成模拟器 PASS；完整清单见 [`PROGRESS.md`](PROGRESS.md) 末尾。
