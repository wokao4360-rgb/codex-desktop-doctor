# codex-desktop-doctor

## 先看这里 / Read this first

**只下载一个文件：** [Latest Release](https://github.com/wokao4360-rgb/codex-desktop-doctor/releases/latest) 里的 `CodexDesktopDoctor.cmd`。

**最常见成功流程：**

1. 关闭 Codex Desktop。
2. 双击 `CodexDesktopDoctor.cmd`。
3. 看到完成提示后，重新打开 Codex Desktop。

**如果插件还是灰：看输出里的 `auth_mode`。**

- `auth_mode: chatgpt`：登录态对了，插件前置条件已满足。
- `auth_mode: apikey`：还会灰。请在 Codex Desktop 里退出 API key 登录，再用 ChatGPT/OAuth 登录。登录后本地模型 provider 仍可继续指向你的本地 API。

这个工具修的是 Codex Desktop 本地配置冲突，不会替你生成 ChatGPT/OAuth 登录态。

## 它修什么 / What it fixes

- 本地 API / cc switch / claude-code-router / Cockpit/Cocktail 后，插件、connector、skills 变灰。
- provider 配置需要保持本地 API，但插件 UI 需要 ChatGPT/OAuth 登录态。
- Cloudflare MCP 配置问题。
- 历史会话不可见，或 `cannot resume running thread ... mismatched path`。

## 默认双击会做什么

双击默认执行 `RepairPluginUi`：

- 保留当前 `model_provider` 和 `base_url`。
- 设置当前 provider：`requires_openai_auth = true`。
- 设置 `[features] remote_control = false`。
- 显示中/英文混合诊断，重点看 `auth_mode`。

## 命令行高级用法

在 `CodexDesktopDoctor.cmd` 所在目录打开终端：

```powershell
.\CodexDesktopDoctor.cmd -Action Diagnose
.\CodexDesktopDoctor.cmd -Action RepairPluginUi
.\CodexDesktopDoctor.cmd -Action RepairCloudflareMcp -CloudflareOAuth
.\CodexDesktopDoctor.cmd -Action RepairSessionVisibility
.\CodexDesktopDoctor.cmd -Action RepairSessionVisibility -ThreadId <thread-id> -ThreadPathStyle Extended
```

`-ThreadPathStyle` 可选：`Auto|Normal|Extended`。

## 安全说明 / Safety

- 写文件前会备份。
- 不打印 token。
- 不上传配置、凭据、会话或遥测。
- 备份目录：`%USERPROFILE%\.codex\doctor-backups\...`

## 开发 / Development

源码脚本：`scripts/CodexDesktopDoctor.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-SmokeTests.ps1
```
