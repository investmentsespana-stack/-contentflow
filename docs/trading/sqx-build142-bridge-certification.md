# SQX Build 142 Bridge Certification Record

Date: 2026-09-16/17

## Local evidence already verified on Rubén's Windows PC

- StrategyQuant X Pro Build `142.2396`.
- Installation path includes `C:\OI\sqcli.exe`.
- `sqcli.exe -project action=list` returned the real StrategyQuant project inventory.
- Interactive `sqcli.exe` started the engine and reported ready.
- TCP port 5050 listened locally, but HTTP `/call?cmd=-h` did not return a usable response and is **not** used by this bridge.
- Build 142 does not expose the newer StrategyQuant MCP server expected by the original bridge.

## Adaptation implemented

Branch: `fix/sqx-build142-cli-bridge`

The Windows bridge now invokes `sqcli.exe` directly with `subprocess` and no shell interpolation.

Initial mappings:

- `list_projects` -> `-project action=list`
- `list_databanks` -> `-databank action=list project=<project>`
- `run_project` -> `-project action=start name=<project>` (locally gated)
- `stop_project` -> `-project action=stop name=<project>` (locally gated)

No arbitrary shell commands are accepted. No broker credentials or live-trading execution are present.

## Cloud control plane

Supabase project `ContentFlow AI` (`koqpyfvnprmirqviafzq`).

`sqx-bridge` Edge Function updated to v2 with pairing metadata:

- transport `sqcli_process`
- SQX build `142.2396`
- allowlist matching the local adapter
- read-only default

## Build evidence

GitHub Actions run `35176606346` completed successfully.
Artifact: `Cygnus-SQX-Bridge-Windows-Build142`.
Artifact SHA-256: `85fb6addae58b1905cd12ca9b7d6c93719b61241da950ec14e19afda6157d73c`.

## Remaining end-to-end gate

The cloud/local connection is not certified until the Windows executable is run on Rubén's PC, paired with a fresh one-time code, and a cloud `list_projects` command returns the real SQX project inventory through:

`Director/control plane -> Windows bridge -> sqcli.exe -> StrategyQuant -> command result -> Supabase/RARA`.

Until that evidence exists, status is `READY_FOR_LOCAL_PAIRING`, not `CONNECTED`.
