# Cygnus SQX VPS Bridge

Headless bridge for running StrategyQuant on a VPS while keeping the existing Supabase control plane and Director/RARA orchestration.

## Security model

- No inbound Internet listener is opened on the VPS.
- The agent polls the existing Supabase `sqx-bridge` Edge Function over outbound HTTPS.
- StrategyQuant MCP is contacted only on `127.0.0.1:8080/mcp` by default.
- There is no arbitrary shell execution.
- Local allowlist: `list_projects`, `list_strategies`, `list_databanks`, `get_strategy_stats`, `run_project`, `stop_project`.
- Project start/stop is disabled by default. Enable only with `CYGNUS_ALLOW_PROJECT_CONTROL=1`.
- Live broker execution is not implemented.

## Deployment layout

- Agent: `/opt/cygnus-sqx-vps-bridge/vps_agent.py`
- Private config/token: `/etc/cygnus-sqx-vps-bridge/`
- Service: `cygnus-sqx-vps-bridge.service`
- Linux service account: `cygnus`

## Pairing

The bridge reuses the existing one-time-code pairing flow. Pair only when StrategyQuant MCP is actually reachable on the VPS. The permanent bearer token is stored as a root-owned private file and never committed to GitHub.

## Health behavior

If StrategyQuant is down, the bridge stays alive and reports `sqx_connected=false` with an empty capability list. That prevents the control plane from dispatching SQX commands until MCP recovers.

## Architecture

Director/RARA -> Supabase sqx-bridge -> outbound-polling VPS agent -> localhost StrategyQuant MCP

This is intentionally separate from broker/live execution.
