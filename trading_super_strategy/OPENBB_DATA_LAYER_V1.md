# OpenBB Free Data Layer v1

Purpose: add a free, auditable market-data path for the Super Estrategia without changing any trading rule.

## Supported scope

- Provider: `yfinance` through OpenBB only.
- Futures roots: `ES`, `NQ`, `YM`, `RTY`.
- Primary research interval: `15m`; the adapter also accepts the yfinance intervals registered in code.
- Output: the same `Bar` type used by the causal backtest engine, so R1/R2/R3 consume OpenBB data without a strategy-specific translation layer.
- Frozen/legacy loaders can consume `bars_to_ohlcv_rows()` as a provider-neutral OHLCV bridge.

## Two connection modes

### 1. Direct OpenBB Python

Install OpenBB (BB-Terminal's setup already installs it), then:

```python
from trading_super_strategy.openbb_history_adapter import fetch_openbb_futures

bars, evidence = fetch_openbb_futures(
    symbol="NQ",
    interval="15m",
    start_date="2026-09-01",
    end_date="2026-09-15",
    transport="python",
)
```

The adapter calls:

```python
obb.derivatives.futures.historical(..., provider="yfinance")
```

### 2. BB-Terminal / OpenBB local HTTP API

When BB-Terminal is running, its OpenBB API defaults to port `6900`.

```python
bars, evidence = fetch_openbb_futures(
    symbol="ES",
    interval="15m",
    transport="http",
    base_url="http://127.0.0.1:6900",
)
```

The v1 adapter targets:

`/api/v1/derivatives/futures/historical`

## Fail-closed rules

- Unknown futures roots are rejected.
- v1 is pinned to `provider=yfinance`; silent provider fallback is rejected.
- Invalid OHLCV is rejected.
- Duplicate timestamps are rejected.
- Timezone-naive intraday rows are rejected unless the caller supplies the timezone explicitly.
- Missing volume is converted to zero but counted in evidence metadata.
- Provider rows are sorted by timestamp before use.

## Research governance

This source is suitable for data acquisition, mechanics tests, recent-history screening and independent cross-provider checks. Provider retention/depth limits still apply. A successful OpenBB fetch is not evidence that R1/R2/R3 or any frozen baseline is robust. Promotion still requires the project's OOS, walk-forward, cost/slippage, Monte Carlo, CSCV/PBO and DSR gates.

Databento remains available for data depth/microstructure that free providers cannot supply. NinjaTrader exports remain the second local/free historical path.
