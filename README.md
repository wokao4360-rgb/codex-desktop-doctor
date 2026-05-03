# codex-desktop-doctor

Codex Desktop 本地修复工具。普通用户只需要下载一个文件，双击运行。

## 下载

去 [Latest Release](https://github.com/wokao4360-rgb/codex-desktop-doctor/releases/latest) 下载：

- `CodexDesktopDoctor.cmd`

用法：

1. 关闭 Codex Desktop。
2. 双击 `CodexDesktopDoctor.cmd`。
3. 等窗口提示完成。
4. 重新打开 Codex Desktop。

双击默认执行：`RepairPluginUi`。

它会保留你当前的 `model_provider` 和 `base_url`，只修复插件 UI 常见冲突项：

- 当前 provider 的 `requires_openai_auth = true`
- `[features] remote_control = false`

注意：如果输出里显示 `auth_mode: apikey`，插件仍会灰。脚本不能替你生成 ChatGPT/OAuth 登录态；需要在 Codex Desktop 里退出 API key 登录，然后用 ChatGPT/OAuth 重新登录。登录后模型 provider 仍可继续指向你的本地 API。

## 适合修什么

- 使用本地 API / cc switch / claude-code-router / Cockpit/Cocktail 后，Codex 插件、connector、skills 变灰。
- ChatGPT/OAuth 已登录，但本地模型 provider 还要继续走自己的 OpenAI-compatible API。
- 诊断当前是不是被 API key 登录态卡住。
- Cloudflare MCP 配置或会话列表需要手动修时，也可以用同一个文件带参数运行。

## 高级用法

在 `CodexDesktopDoctor.cmd` 所在目录打开终端。

只诊断，不写文件：

```powershell
.\CodexDesktopDoctor.cmd -Action Diagnose
```

修插件 UI：

```powershell
.\CodexDesktopDoctor.cmd -Action RepairPluginUi
```

修 Cloudflare MCP 配置：

```powershell
.\CodexDesktopDoctor.cmd -Action RepairCloudflareMcp
```

需要重新走 Cloudflare OAuth：

```powershell
.\CodexDesktopDoctor.cmd -Action RepairCloudflareMcp -CloudflareOAuth
```

修历史会话可见性：

```powershell
.\CodexDesktopDoctor.cmd -Action RepairSessionVisibility
```

修 `cannot resume running thread ... mismatched path`：

```powershell
.\CodexDesktopDoctor.cmd -Action RepairSessionVisibility -ThreadId <thread-id> -ThreadPathStyle Extended
```

可选：`-ThreadPathStyle Auto|Normal|Extended`。

## 安全说明

- 写文件前会备份。
- 不打印 token。
- 不上传任何配置、凭据、会话或遥测。
- 备份目录：`%USERPROFILE%\.codex\doctor-backups\...`

## 开发

源码脚本在 `scripts/CodexDesktopDoctor.ps1`。

运行测试：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-SmokeTests.ps1
```
