# External Capabilities Admission v1

This directory is the canonical admission registry for third-party agent/MCP capabilities used by the Cygnus Director.

## Decisions

- **Graphify**: approved now for a local, code-only knowledge graph. It is not allowed to send repository code to a cloud model in the default Cygnus configuration.
- **SkillSpector**: approved only as an isolated CI scanner. It is not installed on the production VPS.
- **MCP Gateway**: its security patterns are adopted (secret masking, allowlists, admission checks), but it is not installed as another runtime router because the Director already owns dispatch and audit.
- **TradingView MCP**: approved as a secondary research-only market cross-check. It must never become canonical market history and must never receive broker credentials or execute orders.
- **Stagehand**: approved for a future Social Ops pilot only, with a domain allowlist and human approval for destructive or publishing actions.

All entries are fail-closed. `live_money_allowed=false` and `arbitrary_shell_allowed=false` are mandatory.

## Validate

```bash
python trading_super_strategy/external_capabilities/admission.py validate
python -m unittest trading_super_strategy/external_capabilities/test_admission.py
```

## Graphify

The CI workflow builds a **code-only** graph for the trading/control-plane source, so code stays on the runner and no LLM API key is required. Generated graph artifacts are CI evidence, not a source of truth. Extracted edges can inform navigation; any inferred/ambiguous relationship still requires source verification.

## TradingView MCP

Its role is independent corroboration only: quotes, technical indicators, multi-timeframe context and walk-forward comparisons. NQ/ES/YM canonical history remains the frozen/verified research dataset used by the StrategyQuant pipeline.

## Security rule

Any new third-party skill, MCP server, browser agent, data source or execution connector must first be added to `registry.json`, pinned, validated and reviewed before runtime use.
