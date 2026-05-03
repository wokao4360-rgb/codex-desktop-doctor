# codex-desktop-doctor

Windows-first repair toolkit for **OpenAI Codex Desktop** local setups.

中文：这是一个面向 Codex Desktop 的本地修复工具，重点解决「切换本地 API / OAuth 登录后插件变灰」「MCP 授权失效」「历史会话不可见」这些真实桌面端问题。

> It is **not Cockpit-only**. Cockpit/Cocktail is only one example. By default the doctor repairs the **currently active `model_provider`** in `%USERPROFILE%\.codex\config.toml` and does **not** overwrite its `base_url`. This makes it usable with cc switch-style tools, claude-code-router-style tools, custom OpenAI-compatible local gateways, and other provider switchers.

## 下载 / Download

普通用户建议直接去 **Releases** 下载 zip：

- [Latest Release](https://github.com/wokao4360-rgb/codex-desktop-doctor/releases/latest)

解压后先进入解压目录，再运行：

```powershell
cd "你的解压目录\codex-desktop-doctor"
powershell -ExecutionPolicy Bypass -File .\scripts\CodexDesktopDoctor.ps1 -Action Diagnose
```

也可以直接双击解压目录里的：

- `Run-Diagnose.cmd`：只诊断
- `Run-RepairPluginUi.cmd`：修插件 UI 灰掉

如果你不想 `cd`，就必须写脚本的完整路径，例如：

```powershell
powershell -ExecutionPolicy Bypass -File "D:\Projects\codex-desktop-doctor\scripts\CodexDesktopDoctor.ps1" -Action Diagnose
```

## 它能修什么 / What It Fixes

- Codex Desktop 使用本地 API provider 后，插件 UI / connectors / skills 变灰。
- cc switch、claude-code-router、Cockpit/Cocktail 或其他 OpenAI-compatible provider 写入配置后，ChatGPT OAuth 和本地 provider 状态打架。
- Cloudflare MCP OAuth token 过期，或 OAuth 注册/刷新被 Cloudflare `1010 browser_signature_banned` 拦截。
- rollout jsonl 还在，但 Codex Desktop 历史会话列表不显示，因为 `state_5.sqlite` 里的 thread 元数据丢失或 provider 不一致。

## 设计原则 / Safety Model

- `Diagnose` 只读。
- 写操作先备份。
- 不打印 token。
- `.credentials.json` 备份默认脱敏，避免复制 access_token / refresh_token。
- 会话可见性修复以本地 rollout jsonl 为事实源。

## 快速开始 / Quick Start

### 1. 先诊断，不写文件

进入项目/解压目录后：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\CodexDesktopDoctor.ps1 -Action Diagnose
```

或者从任意目录用完整路径：

```powershell
powershell -ExecutionPolicy Bypass -File "D:\Projects\codex-desktop-doctor\scripts\CodexDesktopDoctor.ps1" -Action Diagnose
```

诊断会列出当前 active provider，以及所有 `[model_providers.*]` 的 `base_url` 和 `requires_openai_auth` 状态。

### 2. 通用修复：cc switch / claude-code-router / 其他 provider switcher

如果你的工具已经把 provider 写进 Codex Desktop 配置，只需要运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\CodexDesktopDoctor.ps1 -Action RepairPluginUi
```

这会：

- 保持当前 `model_provider` 不变。
- 保持当前 `base_url` 不变。
- 只把当前 provider 的 `requires_openai_auth` 修成 `true`。
- 把 `[features] remote_control` 修成 `false`，避免部分插件 UI 状态异常。

### 3. 显式创建或切换 provider：仅当你确定要这么做

Cockpit/Cocktail 只是示例，不是默认绑定：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\CodexDesktopDoctor.ps1 `
  -Action RepairPluginUi `
  -ProviderName codex_local_access `
  -ProviderBaseUrl http://127.0.0.1:53528/v1 `
  -LocalTokenEnvVar CODEX_LOCAL_ACCESS_TOKEN `
  -ProviderWireApi responses
```

其他 OpenAI-compatible 网关也一样，把 `ProviderName / ProviderBaseUrl / LocalTokenEnvVar` 换成你的即可。

如果你还想迁移环境变量：

```powershell
-FixEnv
```

如果 `CODEX_API_KEY` 和目标 env key 都存在且内容不同，脚本会停止，不会直接清空。确认要覆盖时再加：

```powershell
-ForceEnvMigration
```

### 4. 修 Cloudflare MCP

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\CodexDesktopDoctor.ps1 `
  -Action RepairCloudflareMcp `
  -CloudflareOAuth
```

默认使用偏只读的最小 scope。如果需要 Workers / Pages / D1 / DNS / AI 写权限：

```powershell
-CloudflareScopePreset Broad
```

### 5. 修历史会话不可见

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\CodexDesktopDoctor.ps1 -Action RepairSessionVisibility
```

默认使用当前 active provider。也可以显式指定：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\CodexDesktopDoctor.ps1 `
  -Action RepairSessionVisibility `
  -ProviderName your_provider_name
```

## Actions

| Action | 写文件 | Purpose |
| --- | --- | --- |
| `Diagnose` | No | Reports config, provider, credential, MCP, and session metadata health. |
| `RepairPluginUi` | Yes | Repairs the active/local provider so plugin UI can coexist with ChatGPT OAuth. |
| `RepairCloudflareMcp` | Yes | Adds the official Cloudflare MCP server and compatible `User-Agent`; optionally refreshes OAuth. |
| `RepairSessionVisibility` | Yes | Rebuilds missing thread rows and aligns provider metadata in `state_5.sqlite`. |
| `RepairAll` | Yes | Runs plugin UI, Cloudflare MCP config, and session visibility repair. OAuth still requires `-CloudflareOAuth`. |

## 重要说明 / Important Notes

- 运行写入类修复前，最好先关闭 Codex Desktop；修完后重启 Codex Desktop。
- `RepairSessionVisibility` 需要 Python 3，因为 SQLite 更新使用 Python 内置 `sqlite3`。
- Cloudflare OAuth 会打开普通浏览器标签页。
- 备份目录：`<codex-home>\doctor-backups\...`
- 配置和 SQLite 备份是原始本地备份；credential 备份默认脱敏。
- 本工具不上传 credentials、sessions 或 telemetry。

## Files Touched

根据 action 不同，可能读取或修改：

- `%USERPROFILE%\.codex\config.toml`
- `%USERPROFILE%\.codex\.credentials.json`
- `%USERPROFILE%\.codex\state_5.sqlite`
- `%USERPROFILE%\.codex\sessions\**\*.jsonl`
- `%USERPROFILE%\.codex\archived_sessions\*.jsonl`

## Why Cloudflare Needs Special Handling

The official Cloudflare MCP endpoint can reject some non-browser OAuth clients with Cloudflare error 1010. Codex's MCP OAuth client may then fail registration or token refresh even though `curl` succeeds. The doctor adds a static MCP HTTP `User-Agent` header and, when requested, performs OAuth with the same compatible request shape.

## Development

Run smoke checks:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-SmokeTests.ps1
```

No secrets or local `.codex` backups should be committed.
