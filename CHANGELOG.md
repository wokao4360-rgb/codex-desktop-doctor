# Changelog

## v0.1.0 - 2026-05-03

- First public release.
- Repairs Codex Desktop plugin UI state without binding users to Cockpit/Cocktail.
- Defaults to the currently active `model_provider`, so cc switch-style and other provider switchers keep their own `base_url`.
- Adds optional explicit provider creation for Cockpit/Cocktail or custom OpenAI-compatible gateways.
- Adds Cloudflare MCP repair and OAuth refresh helper.
- Adds session visibility repair from rollout jsonl files into `state_5.sqlite`.
- Adds bilingual README and smoke tests.
