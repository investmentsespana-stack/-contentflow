from __future__ import annotations

import json
import math
import os
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from trading_super_strategy.backtest_engine import BacktestConfig, CausalBacktestEngine, COMPLETED_STATUSES
from trading_super_strategy.openbb_history_adapter import fetch_openbb_futures
from trading_super_strategy.regime_switch_candidates import R2_FROZEN_GRID, make_r2_runner
from trading_super_strategy.registry_schema import StrategyDirection
from trading_super_strategy.trend_candidates import make_r1_runner

OUT = Path(os.getenv("OUT_DIR", "openbb_crossmarket_survivor_output"))
START = os.getenv("START_DATE", "2026-07-20")
END = os.getenv("END_DATE", "2026-09-16")
SYMBOLS = ("ES", "YM", "RTY")

# Native CME contract assumptions used only to convert a fixed $2.50/side
# commission stress into index points and to express 1/2 ticks of slippage.
# These are explicit research assumptions, not brokerage fee claims.
CONTRACTS = {
    "ES": {"tick_points": 0.25, "point_value_usd": 50.0},
    "YM": {"tick_points": 1.0, "point_value_usd": 5.0},
    "RTY": {"tick_points": 0.10, "point_value_usd": 50.0},
}
COMMISSION_USD_PER_SIDE = 2.50


def _runners():
    short = StrategyDirection.SHORT
    instruments = SYMBOLS
    return [
        make_r2_runner(
            direction=short,
            timeframe_minutes=15,
            parameters=R2_FROZEN_GRID["er_switch"][0],
            instruments=instruments,
        ),
        make_r2_runner(
            direction=short,
            timeframe_minutes=15,
            parameters=R2_FROZEN_GRID["er_switch"][1],
            instruments=instruments,
        ),
        make_r1_runner(
            family="past_return_sign",
            direction=short,
            timeframe_minutes=15,
            parameters=20,
            instruments=instruments,
        ),
        make_r1_runner(
            family="ma_crossover",
            direction=short,
            timeframe_minutes=15,
            parameters=(10, 30),
            instruments=instruments,
        ),
    ]


def _max_drawdown(trials):
    equity = 0.0
    peak = 0.0
    worst = 0.0
    completed = [
        t for t in trials
        if t.status in COMPLETED_STATUSES and t.net_pnl is not None
    ]
    completed.sort(key=lambda t: (t.exit_time or t.signal_time, t.trial_id))
    for t in completed:
        equity += float(t.net_pnl or 0.0)
        peak = max(peak, equity)
        worst = max(worst, peak - equity)
    return worst


def _metric_row(result, runner_id: str):
    m = result.metrics[runner_id]
    trials = [t for t in result.trials if t.runner_id == runner_id]
    return {
        "trades": m.completed_trades,
        "wins": m.wins,
        "losses": m.losses,
        "win_rate": m.win_rate,
        "net_points": m.net_pnl,
        "expectancy_points": m.expectancy_per_trade,
        "profit_factor": None if math.isinf(m.profit_factor) else m.profit_factor,
        "profit_factor_infinite": math.isinf(m.profit_factor),
        "max_drawdown_points": _max_drawdown(trials),
        "eligible_sample": m.eligible,
        "eligibility_reason": m.eligibility_reason,
    }


def _config(symbol: str, ticks: int) -> BacktestConfig:
    spec = CONTRACTS[symbol]
    commission_points = COMMISSION_USD_PER_SIDE / spec["point_value_usd"]
    slippage_points = ticks * spec["tick_points"]
    return BacktestConfig(
        commission_per_unit_per_side=commission_points,
        slippage_per_unit_per_side=slippage_points,
        min_completed_trades=10,
    )


def main():
    runners = _runners()
    market = {}
    source = {}
    for symbol in SYMBOLS:
        bars, stats = fetch_openbb_futures(
            symbol=symbol,
            interval="15m",
            start_date=START,
            end_date=END,
            provider="yfinance",
            transport="python",
            naive_timezone=ZoneInfo("America/New_York"),
        )
        market[symbol] = bars
        source[symbol] = {
            "bars": stats.output_bars,
            "missing_volume_rows": stats.missing_volume_rows,
            "first_timestamp": stats.first_timestamp.isoformat(),
            "last_timestamp": stats.last_timestamp.isoformat(),
        }

    per_symbol = {}
    for symbol in SYMBOLS:
        symbol_rows = {}
        for ticks in (1, 2):
            result = CausalBacktestEngine(_config(symbol, ticks)).run(
                {symbol: market[symbol]}, runners
            )
            symbol_rows[f"{ticks}tick"] = {
                r.runner_id: _metric_row(result, r.runner_id)
                for r in runners
            }
        per_symbol[symbol] = symbol_rows

    summary = {}
    for runner in runners:
        rid = runner.runner_id
        one_tick = {
            symbol: per_symbol[symbol]["1tick"][rid]
            for symbol in SYMBOLS
        }
        two_tick = {
            symbol: per_symbol[symbol]["2tick"][rid]
            for symbol in SYMBOLS
        }
        summary[rid] = {
            "positive_markets_1tick": sum(
                1 for row in one_tick.values() if row["net_points"] > 0
            ),
            "positive_markets_2tick": sum(
                1 for row in two_tick.values() if row["net_points"] > 0
            ),
            "eligible_markets_1tick": sum(
                1 for row in one_tick.values() if row["eligible_sample"]
            ),
            "per_market_1tick": one_tick,
            "per_market_2tick": two_tick,
        }

    payload = {
        "study": "openbb_crossmarket_survivor_falsification_v1",
        "purpose": "cross-market portability falsification; not robustness certification",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "window": {"start": START, "end": END, "interval": "15m"},
        "provider": "yfinance via OpenBB",
        "symbols": list(SYMBOLS),
        "source": source,
        "cost_assumptions": {
            "commission_usd_per_side": COMMISSION_USD_PER_SIDE,
            "native_contract_specs": CONTRACTS,
            "scenarios": ["1 native tick slippage per side", "2 native ticks slippage per side"],
        },
        "candidate_count": len(runners),
        "results": summary,
        "limitations": [
            "These markets were not used in the NQ survivor selection, but the calendar window is contemporaneous rather than future OOS.",
            "Yahoo futures are continuous series and may contain contract-roll effects.",
            "R3 is intentionally excluded because its preregistered hypothesis is NQ-only.",
            "No candidate is promoted from this test; multi-year independent OOS remains mandatory.",
        ],
    }

    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / "summary.json"
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(payload, indent=2, sort_keys=True))
    print(f"RESULT_PATH={path}")


if __name__ == "__main__":
    main()
