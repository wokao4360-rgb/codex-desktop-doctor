# Changelog

## v0.1.5 - 2026-05-03

- Makes the standalone CMD and key PowerShell diagnostics bilingual Chinese/English.
- Moves the most important success path and `auth_mode` decision tree to the top of README.
- Keeps README short and focused on the one-file download, double-click flow, and OAuth failure branch.
- Adds smoke coverage that API key auth warnings include Chinese guidance.

## v0.1.4 - 2026-05-03

- Diagnoses `auth_mode` from `auth.json`.
- Warns when Codex is logged in with an API key, because plugins/connectors/skills UI still require ChatGPT/OAuth login.
- One-click CMD now prints the OAuth reminder after repair so users know what to do if plugins stay grey.
- README clarifies that the tool repairs config but cannot create ChatGPT/OAuth credentials by itself.

## v0.1.3 - 2026-05-03

- Changes the public release format to one standalone `CodexDesktopDoctor.cmd` asset.
- The standalone CMD embeds the PowerShell doctor, so users no longer need to download a zip, extract files, or `cd` into a folder.
- Double-click default is now one-click `RepairPluginUi`.
- Removes extra root helper CMD files and simplifies the README to essential usage only.

## v0.1.2 - 2026-05-03

- Adds diagnosis for `state_5.sqlite` rollout/cwd path styles (`C:\...` vs `\\?\C:\...`).
- Adds targeted `RepairSessionVisibility -ThreadId <id>` repair for one broken thread.
- Adds `-ThreadPathStyle Auto|Normal|Extended` to fix `cannot resume running thread ... mismatched path` errors without broad SQLite rewrites.
- Documents the safe first fix: close and reopen Codex Desktop before attempting targeted path repair.
- Adds smoke tests for extended-path preservation, forced extended paths, and thread-id filtering.

## v0.1.1 - 2026-05-03

- Clarifies that users must run commands from the extracted project directory or pass the full script path.
- Adds root helper launchers: `CodexDesktopDoctor.cmd`, `Run-Diagnose.cmd`, and `Run-RepairPluginUi.cmd`.
- Fixes Windows PowerShell 5.1 compatibility for the SQLite thread-count diagnosis.
## v0.1.0 - 2026-05-03

- First public release.
- Repairs Codex Desktop plugin UI state without binding users to Cockpit/Cocktail.
- Defaults to the currently active `model_provider`, so cc switch-style and other provider switchers keep their own `base_url`.
- Adds optional explicit provider creation for Cockpit/Cocktail or custom OpenAI-compatible gateways.
- Adds Cloudflare MCP repair and OAuth refresh helper.
- Adds session visibility repair from rollout jsonl files into `state_5.sqlite`.
- Adds bilingual README and smoke tests.
