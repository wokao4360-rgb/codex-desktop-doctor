# codex-desktop-doctor

[中文 README](README.md)

## Read this first

**Download one file only:** `CodexDesktopDoctor.cmd` from the [Latest Release](https://github.com/wokao4360-rgb/codex-desktop-doctor/releases/latest).

**Most common success path:**

1. Close Codex Desktop.
2. Double-click `CodexDesktopDoctor.cmd`.
3. Reopen Codex Desktop after the script finishes.

**If plugins are still grey, check `auth_mode` in the output.**

- `auth_mode: chatgpt`: good. The plugin UI login prerequisite is satisfied.
- `auth_mode: apikey`: plugins may still stay grey. In Codex Desktop, log out from API-key mode and sign in with ChatGPT/OAuth. Your local model provider/base URL can still point to your local API after login.

This tool repairs local Codex Desktop config conflicts. It cannot create ChatGPT/OAuth credentials for you.

**If you see "Browser plugin not found":**

- Close Codex Desktop, then double-click the script.
- The script enables `browser-use@openai-bundled` and tries to restore the Browser Use plugin cache from the official bundled Codex Desktop plugin directory.
- If the bundled plugin package is missing, update or reinstall Codex Desktop, then run the script again.

## What it fixes

- Plugins, connectors, or skills become grey after using local API providers, cc switch, claude-code-router, Cockpit, or Cocktail-style local API tools.
- Browser Use says "Browser plugin not found" or its local config/cache is missing.
- The model provider should stay local, but plugin UI auth still needs ChatGPT/OAuth.
- Cloudflare MCP config problems.
- Missing sessions or `cannot resume running thread ... mismatched path`.

## What double-click mode does

Double-click runs the core repair path: `RepairPluginUi` + `RepairBrowserUsePlugin`.

- Keeps your current `model_provider` and `base_url`.
- Sets the current provider to `requires_openai_auth = true`.
- Sets `[features] remote_control = false`.
- Enables `[plugins."browser-use@openai-bundled"]`.
- Restores Browser Use cache from the Codex Desktop install directory when possible.
- Prints bilingual Chinese/English diagnostics. The most important line is `auth_mode`.

## Advanced CLI usage

Open a terminal in the folder that contains `CodexDesktopDoctor.cmd`:

```powershell
.\CodexDesktopDoctor.cmd -Action Diagnose
.\CodexDesktopDoctor.cmd -Action RepairPluginUi
.\CodexDesktopDoctor.cmd -Action RepairBrowserUsePlugin
.\CodexDesktopDoctor.cmd -Action RepairCloudflareMcp -CloudflareOAuth
.\CodexDesktopDoctor.cmd -Action RepairSessionVisibility
.\CodexDesktopDoctor.cmd -Action RepairSessionVisibility -ThreadId <thread-id> -ThreadPathStyle Extended
```

`-ThreadPathStyle` can be `Auto`, `Normal`, or `Extended`.

## Safety

- Backs up files before writing.
- Does not print tokens.
- Does not upload config, credentials, sessions, or telemetry.
- Backup folder: `%USERPROFILE%\.codex\doctor-backups\...`

## Development

Source script: `scripts/CodexDesktopDoctor.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-SmokeTests.ps1
```
