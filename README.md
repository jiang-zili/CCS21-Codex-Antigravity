# Google Antigravity 1.6.0 — CCS21 修复版
[下载修复版 VSIX](./google.google-antigravity-1.6.0-ccs21-patched.vsix?raw=1)

SHA-256：`44781ae719c077daf59e065d0ce60523192cc2023bce259a448e3294ab53e655`

这是基于本机已验证版本重新打包的非官方、无签名 VSIX。扩展 ID 保持 `google.google-antigravity`，版本保持 `1.6.0`，便于替换同版本安装。它不是 Google 发布的官方修复。

## 已修复问题

CCStudio 21 的 Theia 页面打开 Antigravity 聊天侧栏及设置页时出现 “Couldn't load this view”。后端的 `frame-ancestors` 未允许 CCS 的 Theia webview 来源和顶层 `file:` 页面。

扩展检测到本机 Theia webview 时，启动仅监听 `127.0.0.1` 随机端口的临时代理；只对后端 HTML 响应的 `frame-ancestors` 加入当前 webview 的准确来源和 `file:`。HTTP、身份验证、CSRF 和 WebSocket 流量原样转发，代理随扩展关闭。端口及来源在运行时计算，不依赖打包机器路径。

`file:` 允许本机其他 HTML 页面在知道该临时代理地址时嵌入它。这是本次 CCS 适配所需的权限范围；不会修改 Google 后端程序或 CCS 本体。

## 安装

1. 在 CCS21 扩展界面选择 “Install from VSIX…”（从 VSIX 安装），选择本目录的 `.vsix` 文件。
2. 如果 CCS 拒绝覆盖相同版本，先卸载已有 Google Antigravity，再安装这个文件。
3. 执行 “Reload Window”（重新加载窗口），打开 Antigravity 侧栏及 Settings。

已在 CCS 21.0.1、Google Antigravity 扩展 1.6.0、agy 后端 1.2.14 上确认聊天输入框与设置页恢复显示。没有发送测试消息，也未验证其他 CCS/扩展版本或完整代理任务执行。

扩展更新或重新安装官方版本会覆盖适配；恢复官方版可卸载本包后从扩展市场安装。此 VSIX 不包含本机 Google 登录信息、聊天记录、项目文件或 agy 后端可执行文件；使用时仍需扩展正常下载后端并完成登录。

## 打包内容和许可证

- 保留原扩展文件及 `LICENSE.txt`、`ThirdPartyNotices.txt`。
- `extension.js` 含已验证的 `renderIframe` 适配；新增 `ccs-embed-proxy.cjs`。
- 包显示名标记为 “Google Antigravity (CCS21 patched)”，扩展 ID 与版本保持原值。
- 原 VSIX 数字签名及原 `extension.js` 签名已失效，因此从此修复包中移除。安装目录没有被本次打包修改。
- 原源映射与修改后的 JavaScript 不完全匹配，移除了修复包中的 `sourceMappingURL` 注释；原映射文件仍作为上游内容保留。

原版权、许可证和第三方声明保留在包内。Google Antigravity 是 Google 的产品名称；本适配包不表示 Google 或 Texas Instruments 背书。
