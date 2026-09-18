# Cygnus SQX Bridge — StrategyQuant X Build 142

Local Windows bridge between StrategyQuant X and the Director/RARA control plane.

## Verified local transport

This branch targets **StrategyQuant X Pro Build 142.2396**. Build 142 does not expose the newer MCP server used by the original bridge. The verified transport is the official `sqcli.exe` command-line interface.

Default path on Rubén's PC:

`C:\OI\sqcli.exe`

Verified local command:

`sqcli.exe -project action=list`

The bridge therefore uses **direct process execution of sqcli.exe**, not MCP and not the unverified local HTTP `/call` path.

## Architecture

`Director/Supabase -> sqx-bridge control plane -> outbound HTTPS -> CygnusSQXBridge.exe on Windows -> C:\OI\sqcli.exe -> StrategyQuant X -> result -> Director/RARA`

There is no inbound Internet listener on the PC and no broker/live-trading authority.

## Initial allowlist

Read-only by default:

- `list_projects` -> `sqcli.exe -project action=list`
- `list_databanks` -> `sqcli.exe -databank action=list project=<project>`

Optional local project control, disabled by default:

- `run_project` -> `sqcli.exe -project action=start name=<project>`
- `stop_project` -> `sqcli.exe -project action=stop name=<project>`

The project start/stop commands are documented by StrategyQuant, but remain gated behind the local checkbox until research automation is explicitly approved.

`list_strategies` and `get_strategy_stats` are intentionally not advertised by this Build-142 adapter yet. They will only be added after an exact CLI mapping is validated.

## Single-instance rule

StrategyQuant Build 142 refuses a second engine instance. During bridge operation the normal graphical StrategyQuant X application must be **closed**. The bridge invokes `sqcli.exe` itself.

If SQX reports another instance is running, the bridge fails closed and logs an actionable error instead of retrying blindly.

## Pairing/security

1. Control plane creates a one-time pairing code.
2. Windows bridge exchanges it for a long-lived random token.
3. Token is stored in Windows Credential Manager via `keyring`.
4. Cloud stores only SHA-256 hashes of pairing codes/tokens.
5. Local command names are hard allowlisted; no arbitrary shell command is accepted.
6. Project start/stop is disabled locally by default.
7. No broker credentials and no live-money execution are implemented.

## Control plane

Supabase project: `ContentFlow AI` (`koqpyfvnprmirqviafzq`)

Edge Function: `sqx-bridge`

Tables:

- `trading_sqx_bridge_devices`
- `trading_sqx_bridge_pairing_codes`
- `trading_sqx_bridge_commands`
- `trading_sqx_bridge_events`

Command lifecycle:

`QUEUED -> CLAIMED -> SUCCEEDED | FAILED`

## Windows build/install

GitHub Actions builds a single-file `CygnusSQXBridge.exe`.

1. Close StrategyQuant X graphical UI.
2. Run `CygnusSQXBridge.exe`.
3. Confirm `C:\OI\sqcli.exe` (or correct path).
4. Enter the one-time pairing code.
5. Click **Probar SQX** if needed; PASS must return the actual project list.
6. Keep project start/stop disabled for the first end-to-end certification.

The first certification command from the Director must be `list_projects`. Success requires the command to travel cloud -> Windows -> SQCLI -> cloud and return the real project list for RARA validation.
