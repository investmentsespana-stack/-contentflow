# Cygnus SQX Bridge

Local Windows bridge between StrategyQuant X and the Director/RARA control plane.

## Purpose

- Connect only to StrategyQuant X MCP on the same PC, normally `http://localhost:8080/mcp`.
- Poll the Cygnus control plane using outbound HTTPS only.
- Execute only an explicit allowlist of StrategyQuant MCP tools.
- Return structured results and audit every command.
- Never expose the PC to inbound Internet traffic.
- Never place live trades or connect to brokerage execution.

## Current SQX MCP allowlist

Read-only by default:
- `list_projects`
- `list_strategies`
- `list_databanks`
- `get_strategy_stats`

Optional local control, disabled by default:
- `run_project`
- `stop_project`

The bridge checks that the requested tool is actually advertised by the local SQX MCP server before calling it.

## Security model

1. A one-time pairing code is created in the control plane.
2. The Windows app exchanges it for a random long-lived bridge token.
3. The token is stored with Windows Credential Manager through `keyring`, not in the Git repository.
4. The cloud stores only SHA-256 hashes of pairing codes and bridge tokens.
5. The local bridge accepts no arbitrary shell command and no arbitrary MCP tool name.
6. Start/stop of SQX research projects requires an explicit local checkbox in the app.
7. RLS is enabled on all bridge tables; the Edge Function uses custom bearer-token authentication.

## Control plane

Supabase Edge Function: `sqx-bridge`

Tables:
- `trading_sqx_bridge_devices`
- `trading_sqx_bridge_pairing_codes`
- `trading_sqx_bridge_commands`
- `trading_sqx_bridge_events`

Command lifecycle:

`QUEUED -> CLAIMED -> SUCCEEDED | FAILED`

## Windows build

GitHub Actions builds a single-file Windows executable using PyInstaller. The user only needs to:

1. Open StrategyQuant X.
2. Confirm the MCP URL shown in **gear -> MCP Server...**.
3. Run `CygnusSQXBridge.exe`.
4. Enter the one-time pairing code.
5. Leave project start/stop disabled until research automation is explicitly approved.

No terminal is required for normal installation or operation.
