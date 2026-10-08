# CCS21 Codex / Antigravity 白屏一键修复

适用范围：Windows 上的 CCS 21.0.1（Theia），已安装 Codex 与 **Google Antigravity 1.6.0 的本仓库 CCS21 适配版**。本工具是非官方兼容修复，按 2026-10-08 本机验证过的文件结构作严格检查；扩展或 CCS 升级后如结构不符，会停止修改。

## 下载与运行

1. 下载 [`repair_ccs21_codex_antigravity.cmd`](./repair_ccs21_codex_antigravity.cmd?raw=1)。如尚未安装本仓库的 [Antigravity 1.6.0 CCS21 适配版 VSIX](./google.google-antigravity-1.6.0-ccs21-patched.vsix?raw=1)，先在 CCS21 的扩展界面使用 **Install from VSIX…** 安装。这个 `.cmd` 不下载或安装扩展，也不下载后端可执行文件。
2. 保存 CCS21 中未保存的工作，双击 `.cmd`。安装目录可由当前账户修改时无需管理员权限；允许脚本正常关闭并重启 CCS21。关闭过程最多等待 120 秒，若 CCS21 仍在运行，脚本不会强行结束进程。
3. 等待窗口显示修复完成和备份目录，再打开 Codex、Antigravity 面板确认。仅做只读检查时，在命令行运行 `repair_ccs21_codex_antigravity.cmd --check`。

本次发布的 CMD SHA-256：`59a85af432dd15c6b045cf593bad9d53d15e769633b31f26842749c59f4c3425`。

如果 Codex 缺少 Windows 后端，脚本会在修改前要求本机 VS Code 已安装**同版本的官方 `openai.chatgpt` win32-x64 扩展**；它只从该扩展复制缺失的后端文件，并核对扩展版本、发布者及清单哈希。没有匹配来源时会停止，不会从不明网址下载二进制。

## 做了什么

脚本先定位 CCS21 安装和最近使用的用户配置，验证 Antigravity 的适配入口、Codex 的版本与 Theia ASAR 目标代码。之后正常关闭 CCS21，按需执行：

| 对象 | 处理方式 |
| --- | --- |
| CCS21 `resources/app.asar` | 修复 Theia `WebviewView` 的 `show` 方法绑定；只对已识别的单一代码位置作等长改动，重算 ASAR 完整性哈希并验证其余字节未变。已修复时跳过。 |
| Antigravity `ccs-embed-proxy.cjs` | 保留后端既有 CSP 规则，仅向 `frame-ancestors` 添加当前精确的 Theia webview 来源和必要的 `file:`；将该精确来源加入 `/main.js` 的初始化来源校验。代理只监听本机回环地址，代码不使用通配来源。 |
| Codex `bin/windows-x86_64` | 仅在 `codex.exe` 缺失时，从本机同版本官方 VS Code 扩展复制 Windows 后端。 |
| 当前 CCS21 配置的缓存 | 将六类 Electron 缓存及 Theia `localization-cache` 移到备份目录，让 CCS21 重建。 |

每次运行的备份和 `repair-result.txt` 保存在 `%LOCALAPPDATA%\CCS21RepairBackups\<时间-随机编号>`。原始 `app.asar` 在需要修改时先完整复制并校验 SHA-256；已有代理和 Codex 后端目录在替换前备份；缓存通过移动保留。脚本不会删除工程、workspace、源码、CCS 项目配置或用户设置，也不会关闭 CCS12 和 VS Code。脚本不额外加入 `--no-sandbox`、禁用 Web 安全性或关闭 TLS 校验等启动参数。

## 验证与范围

2026-10-08 在 CCS 21.0.1、Antigravity 1.6.0、Codex 26.51002.51308 的已适配安装上执行完整双击流程：备份、缓存迁移和 CCS21 重启成功；原工作区、Extension Host、Codex 后端及 `agy.exe` 后端均重新运行。此前已在该环境目视确认两个聊天面板、Webview 和命令打开；本次脚本复测核验了进程及后端，未重新进行面板目视操作。其他版本及长期稳定性尚未验证，不能保证达到 VS Code 的稳定性水平。

如脚本提示版本、ASAR 签名或扩展入口不匹配，请保留终端提示和备份目录，停止尝试覆盖其他版本。若需回退，先关闭 CCS21，再从该次备份恢复被修改的 `app.asar` 或代理文件；缓存备份也保留在同目录。原工作区和项目文件无需回退。

本工具不代表 Texas Instruments、Google 或 OpenAI 官方支持。
