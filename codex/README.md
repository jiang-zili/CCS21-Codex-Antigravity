# CCS21 的 Codex 平台包修复工具

Windows x64 的 CCS21 中，Codex `openai.chatgpt` `26.930.21537` 被安装成 `alpine-arm64` 包，只有 Linux ARM64 后端。扩展寻找 Windows 后端时因此报 `ENOENT`。本工具下载同版本官方 `win32-x64` VSIX，核验后可选择替换安装。下载工具本身不修改扩展代码。

本目录只分发独立脚本和使用说明，不重新分发完整 Codex 扩展。原扩展 `LICENSE.md` 指向 [OpenAI 使用条款](https://openai.com/policies/row-terms-of-use/)。[官方扩展页面](https://marketplace.visualstudio.com/items?itemName=openai.chatgpt) · [官方 IDE 文档](https://learn.chatgpt.com/docs/codex/ide)

包含两个独立工具：`repair_codex_ccs21.py` 处理错误平台包，`apply_theia_compatibility.py` 为这个固定版本提供可选的 CCS/Theia 侧栏适配。两个工具默认均不修改安装。

需要 Python 3.9 或更新版本；只使用标准库。此版本固定为 `26.930.21537`、`win32-x64`，并固定验证 SHA-256：

```text
9eacd2fa590119245ae0a71eddf9f8f5310d070343a5586801fae99f62086251
```

[下载校验值文件](./openai.chatgpt-26.930.21537-win32-x64.vsix.sha256)。完整 VSIX 请由下面的工具从官方 Marketplace 下载；GitHub 仓库不重新分发扩展包。

## 下载和核验

默认只下载到指定本地目录，不改动 CCS。约需 537 MB 下载空间；解压安装约需 1.42 GB，备份另需现有扩展大小的空间。

```powershell
python .\repair_codex_ccs21.py --output-dir "D:\下载\Codex-CCS21"
```

使用已下载的文件进行离线核验：

```powershell
python .\repair_codex_ccs21.py --vsix "D:\下载\Codex-CCS21\openai.chatgpt-26.930.21537-win32-x64.vsix" --validate-only
```

工具核验安全 ZIP 路径、CRC、扩展 ID、版本、`TargetPlatform`、Windows x64 后端及整体 SHA-256。错误平台会被拒绝。Marketplace 的 gzip 传输会先解码再核验；TLS 验证保持启用。

## 安装

保存工作并关闭 CCS 后执行，`--install` 才会修改安装：

```powershell
python .\repair_codex_ccs21.py --vsix "D:\下载\Codex-CCS21\openai.chatgpt-26.930.21537-win32-x64.vsix" --install
```

默认目标为 `%LOCALAPPDATA%\Texas Instruments\CCS\ccs2101\0\theia\deployedPlugins\openai.chatgpt@26.930.21537`。可用 `--deployed-plugins` 指定 CCS 的 `deployedPlugins` 目录。

替换前，工具将原扩展完整备份到 `Documents\Codex\CCS21-Codex-backups` 的时间戳子目录，备份位于 CCS 扩展扫描目录外。先完成核验和暂存再替换，失败时恢复原安装。它保留全部官方包文件，不读取账户令牌、设置或聊天，不终止进程。

安装后打开 CCS，执行 `Ctrl+Shift+P` → `Reload Window`。若先前的空白侧栏位置仍被 CCS 保存，再执行 `Ctrl+Shift+P` → `View: Reset Workbench Layout`，它会重排工作台视图。然后打开 Codex，检查会话列表和输入框。已确认原安装的平台错误；安装工具本身不能证明运行成功。

## 可选 CCS/Theia 侧栏适配

正确 Windows 包可以启动后端，但 CCS/Theia 对 Codex 侧栏的支持可能重复唤醒同一 Webview：旧视图已销毁，新视图却同时初始化，页面可能一直空白或报超时。`apply_theia_compatibility.py` 只在检测到 Theia 设置的 `THEIA_PARENT_PID` 时选择主侧栏兼容路径，并延迟极短时间合并同类视图的重复初始化。普通 VS Code 不触发这段适配。它不删除超时提示，也不延长超时。

此工具先确认已安装 Windows x64 后端，只接受 `openai.chatgpt` `26.930.21537` 的确切官方源文件或已适配源文件，以 SHA-256 识别后才操作，且只替换侧栏选择与 Webview 初始化两个精确位置。其他构建、更新版本或未知修改会被拒绝。官方 `out/extension.js` SHA-256 为 `241516830f7a2fa29ae50c7f5a3a4011f4964697f8d883631ab69ef40f683bab`；适配后为 `adb104453824bf13be4492d32db850cb1e28be208192b85822bb81639d53f2ea`。

先保存工作并关闭 CCS。仅检查当前源文件：

```powershell
python .\apply_theia_compatibility.py
```

确认要应用时运行：

```powershell
python .\apply_theia_compatibility.py --apply
```

它先将原 JavaScript 备份到 `Documents\Codex\CCS21-Codex-backups\codex-theia-sidebar-时间戳\extension.js`，再原子替换该文件。脚本不会读取设置、账户令牌或聊天；不会终止 CCS。备份保持在插件扫描目录之外。

使用执行时输出的完整备份路径恢复原文件：

```powershell
python .\apply_theia_compatibility.py --restore "C:\你的文档目录\Codex\CCS21-Codex-backups\codex-theia-sidebar-时间戳\extension.js"
```

应用或恢复后均需 `Ctrl+Shift+P` → `Reload Window`。在当前 CCS 21.0.1 上，替换为官方 Windows 包、应用侧栏适配并重置工作台布局后，已看到 Codex 会话列表和输入框，Windows 后端进程已启动。启动日志仍记录 Theia 对旧视图的 `Unknown Webview` 警告；没有发送测试消息，也未验证完整聊天任务。修改后的官方 JavaScript 签名会失效，本仓库只提供独立适配脚本，不上传修改后的扩展载荷。

恢复时关闭 CCS，用时间戳备份目录替换上述相同版本扩展目录，然后重新加载 CCS。不要把备份放进 `deployedPlugins`，以免被重复扫描。

本工具为非官方 CCS 修复辅助，不表示 OpenAI 或 Texas Instruments 背书。
