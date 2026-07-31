# CareThread 官网（静态站点）

> 正式站点：<https://carethread.8xd.io/>

纯静态站点，无构建步骤、无 JS 框架、无外部请求。可直接作为 Cloudflare Pages 的产物目录部署。

## 部署与重新部署

- Cloudflare Pages 项目：`carethread`
- 生产分支标记：`main`
- 产物目录：`website/`（无构建命令、无环境变量）
- 自定义域：`carethread.8xd.io`

重新部署已提交的站点版本：

    opencli wrangler pages deploy website --project-name carethread --branch main --commit-hash <完整提交 SHA> --commit-message "Deploy CareThread static website"

部署后必须分别检查 `/`、`/privacy`、`/terms` 的 HTTPS 状态、同源样式和图片资源。

## 结构与路径

| 文件 | 部署后路径 |
| --- | --- |
| `index.html` | `/` |
| `privacy/index.html` | `/privacy` |
| `terms/index.html` | `/terms` |
| `assets/site.css` | `/assets/site.css` |
| `assets/logo.svg` | `/assets/logo.svg`（同时作 favicon） |
| `assets/screens/*.png` | 产品截图，明暗各 6 张 |

链接一律使用绝对路径（`/privacy`、`/assets/...`），因此**必须以站点根目录形式部署**，直接用 `file://` 打开会丢样式。本地预览：

    cd website && python3 -m http.server 8788

## 设计约定

- 配色、字号、间距全部取自 App 设计规范（交付包 `02_设计规范.md`）的同一套 token，站点与 App 视觉同源。
- 深色模式跟随系统（`prefers-color-scheme`），App 截图用 `<picture>` 同步切换明暗两版。
- 站内无任何第三方脚本、字体、分析或追踪；全部资源同源。
- 移动端隐藏页内锚点导航（`.nav-links a.anchor`），仅保留两个法律页入口，避免 390px 下撑破布局。
- Logo 为横向"一线串三点"：竖版（App 图标那版）在 26px 导航尺寸下会读成字母，故小尺寸单独采用横向构图。

## 内容同源要求

`/privacy` 与 `/terms` 的正文必须与仓库 `docs/legal/PRIVACY_POLICY.md`、`docs/legal/TERMS_OF_SERVICE.md` **保持一致**。修改时两处同改，并同步更新页面顶部与 Markdown 内的"最后更新"日期。

App 内展示的协议全文是打包进 App 的本地副本（不联网读取本站），因此**协议改动需要三处同步**：Markdown 源文件、本站页面、App 内资源。

## 联系方式

jianghaibo@multiego.me
