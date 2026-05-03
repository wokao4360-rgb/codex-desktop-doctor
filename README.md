# codex-desktop-doctor

`codex-desktop-doctor` is a Windows-first repair toolkit for OpenAI Codex Desktop local setups. It focuses on the failure modes that make plugins, MCP servers, or old conversations disappear after switching between ChatGPT OAuth, local API providers, Cockpit/Cocktail-style local gateways, and remote MCP OAuth.

The tool is intentionally conservative:

- `Diagnose` is read-only.
- Repair actions back up files before writing.
- Tokens are never printed.
- Session visibility repair uses the rollout files as the source of truth.

## What It Fixes

- Plugin UI greyed out because the active local model provider has `requires_openai_auth = false`.
- Local API provider drift after login, for example Codex Desktop switching away from a Cockpit local API provider.
- Cloudflare MCP OAuth breakage caused by expired tokens or Cloudflare `1010 browser_signature_banned` responses during OAuth registration/refresh.
- Missing conversation visibility when rollout files exist but `state_5.sqlite` metadata is missing or pinned to the wrong provider.

## Quick Start

Run a read-only diagnosis first:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\CodexDesktopDoctor.ps1 -Action Diagnose
```

Repair the common local-API plus plugin-UI case:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\CodexDesktopDoctor.ps1 `
  -Action RepairPluginUi `
  -ProviderName codex_local_access `
  -ProviderBaseUrl http://127.0.0.1:53528/v1 `
  -LocalTokenEnvVar CODEX_LOCAL_ACCESS_TOKEN `
  -FixEnv
```

If `CODEX_API_KEY` and `CODEX_LOCAL_ACCESS_TOKEN` both exist and differ, `-FixEnv` stops instead of clearing anything. Re-run with `-ForceEnvMigration` only when the current `CODEX_API_KEY` is the token you want to keep under `CODEX_LOCAL_ACCESS_TOKEN`.

Repair Cloudflare MCP configuration and run browser OAuth:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\CodexDesktopDoctor.ps1 `
  -Action RepairCloudflareMcp `
  -CloudflareOAuth
```

Cloudflare OAuth defaults to a minimal read-oriented scope set. If you need write tools such as Workers, Pages, D1, DNS edits, or AI writes, add:

```powershell
-CloudflareScopePreset Broad
```

Repair conversation visibility:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\CodexDesktopDoctor.ps1 `
  -Action RepairSessionVisibility `
  -ProviderName codex_local_access
```

## Actions

| Action | Writes files | Purpose |
| --- | --- | --- |
| `Diagnose` | No | Reports config, provider, credential, MCP, and session metadata health. |
| `RepairPluginUi` | Yes | Ensures the active/local provider still allows ChatGPT OAuth-backed plugin UI. |
| `RepairCloudflareMcp` | Yes | Adds the official Cloudflare MCP server and a compatible `User-Agent`; optionally refreshes OAuth. |
| `RepairSessionVisibility` | Yes | Rebuilds missing thread rows and aligns provider metadata in `state_5.sqlite`. |
| `RepairAll` | Yes | Runs plugin UI, Cloudflare MCP config, and session visibility repair. OAuth still requires `-CloudflareOAuth`. |

## Important Notes

- Close Codex Desktop before running write-mode repairs when possible. Some fixes may only appear after Codex Desktop restarts.
- `RepairSessionVisibility` requires Python 3 because it safely updates SQLite using Python's built-in `sqlite3`.
- Cloudflare OAuth opens a normal browser tab. Approve the Cloudflare page, then return to the terminal.
- The script writes backups under `<codex-home>\doctor-backups\...`.
- Config and SQLite backups are raw local backups. Credential backups are redacted by default so access tokens and refresh tokens are not duplicated into `doctor-backups`.
- Cloudflare OAuth stores the new MCP credential in Codex Desktop's normal local `.credentials.json`; keep that file private.

## Files Touched

Depending on the selected action, the tool may read or modify:

- `%USERPROFILE%\.codex\config.toml`
- `%USERPROFILE%\.codex\.credentials.json`
- `%USERPROFILE%\.codex\state_5.sqlite`
- `%USERPROFILE%\.codex\sessions\**\*.jsonl`
- `%USERPROFILE%\.codex\archived_sessions\*.jsonl`

It does not upload credentials, sessions, or telemetry.

## Why Cloudflare Needs Special Handling

The official Cloudflare MCP endpoint can reject some non-browser OAuth clients with Cloudflare error 1010. Codex's MCP OAuth client may then fail registration or token refresh even though `curl` succeeds. The doctor adds a static MCP HTTP `User-Agent` header and, when requested, performs OAuth with the same compatible request shape.

## Development

Run the smoke checks:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-SmokeTests.ps1
```

No secrets or local `.codex` backups should be committed.
