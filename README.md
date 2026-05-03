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

**如果报“未找到浏览器插件 / Browser plugin not found”：**

- 先关闭 Codex Desktop，再双击脚本。
- 脚本会启用 `browser-use@openai-bundled`，并尝试从 Codex Desktop 官方内置目录恢复 Browser Use 插件缓存。
- 如果输出提示找不到官方内置插件包，先更新或重装 Codex Desktop，再重新运行脚本。

## 它修什么 / What it fixes

- 本地 API / cc switch / claude-code-router / Cockpit/Cocktail 后，插件、connector、skills 变灰。
- Browser Use 显示“未找到浏览器插件”或配置丢失。
- provider 配置需要保持本地 API，但插件 UI 需要 ChatGPT/OAuth 登录态。
- Cloudflare MCP 配置问题。
- 历史会话不可见，或 `cannot resume running thread ... mismatched path`。

## 默认双击会做什么

双击默认执行核心修复：`RepairPluginUi` + `RepairBrowserUsePlugin`。

- 保留当前 `model_provider` 和 `base_url`。
- 设置当前 provider：`requires_openai_auth = true`。
- 设置 `[features] remote_control = false`。
- 启用 `[plugins."browser-use@openai-bundled"]`。
- 如 Browser Use 缓存缺失，尝试从 Codex Desktop 安装目录复制官方内置插件。
- 显示中/英文混合诊断，重点看 `auth_mode`。

## 命令行高级用法

在 `CodexDesktopDoctor.cmd` 所在目录打开终端：

```powershell
.\CodexDesktopDoctor.cmd -Action Diagnose
.\CodexDesktopDoctor.cmd -Action RepairPluginUi
.\CodexDesktopDoctor.cmd -Action RepairBrowserUsePlugin
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
