from __future__ import annotations

import json
import math
import os
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from trading_super_strategy.backtest_engine import BacktestConfig, CausalBacktestEngine, COMPLETED_STATUSES
from trading_super_strategy.openbb_history_adapter import fetch_openbb_futures
from trading_super_strategy.registry_schema import StrategyDirection
from trading_super_strategy.trend_candidates import R1_FROZEN_GRID, make_r1_runner
from trading_super_strategy.regime_switch_candidates import R2_FROZEN_GRID, make_r2_runner
from trading_super_strategy.nq_vol_mean_reversion import R3_FROZEN_PARAMETERS, make_r3_runner

OUT = Path(os.getenv("BACKTEST_OUT", "openbb_nq15_backtest_output"))
START = os.getenv("START_DATE", "2026-07-20")
END = os.getenv("END_DATE", "2026-09-16")


def _runners():
    runners = []
    for direction in (StrategyDirection.LONG, StrategyDirection.SHORT):
        for family, params in R1_FROZEN_GRID.items():
            for parameter in params:
                runners.append(
                    make_r1_runner(
                        family=family,
                        direction=direction,
                        timeframe_minutes=15,
                        parameters=parameter,
                        instruments=("NQ",),
                    )
                )
        for parameter in R2_FROZEN_GRID["er_switch"]:
            runners.append(
                make_r2_runner(
                    direction=direction,
                    timeframe_minutes=15,
                    parameters=parameter,
                    instruments=("NQ",),
                )
            )
        runners.append(
            make_r3_runner(
                direction=direction,
                timeframe_minutes=15,
                parameters=R3_FROZEN_PARAMETERS,
            )
        )
    return runners


def _max_drawdown_points(trials):
    equity = 0.0
    peak = 0.0
    worst = 0.0
    for trial in sorted(trials, key=lambda t: (t.exit_time or t.signal_time, t.trial_id)):
        if trial.status in COMPLETED_STATUSES and trial.net_pnl is not None:
            equity += trial.net_pnl
            peak = max(peak, equity)
            worst = max(worst, peak - equity)
    return worst


def _serialize_result(label, result):
    rows = []
    for runner_id, m in sorted(result.metrics.items()):
        trials = [t for t in result.trials if t.runner_id == runner_id]
        rows.append(
            {
                "runner_id": runner_id,
                "attempts": m.attempts,
                "completed_trades": m.completed_trades,
                "failed_trials": m.failed_trials,
                "wins": m.wins,
                "losses": m.losses,
                "win_rate": m.win_rate,
                "net_points": m.net_pnl,
                "expectancy_points": m.expectancy_per_trade,
                "profit_factor": None if math.isinf(m.profit_factor) else m.profit_factor,
                "profit_factor_infinite": math.isinf(m.profit_factor),
                "max_drawdown_points": _max_drawdown_points(trials),
                "eligible_sample": m.eligible,
                "eligibility_reason": m.eligibility_reason,
            }
        )
    return {"label": label, "metrics": rows, "baselines": dict(result.baselines)}


def main():
    # OpenBB/yfinance can expose timezone-naive futures timestamps. In the live
    # evidence run on 2026-09-16, treating those values as America/Chicago put
    # the latest bar one hour into the future relative to the workflow clock.
    # The Yahoo/OpenBB presentation clock for this endpoint is therefore pinned
    # explicitly to America/New_York in this research runner. This changes only
    # timestamp provenance; the ordered OHLCV values and strategy calculations
    # are otherwise unchanged because these candidates have no session filter.
    bars, stats = fetch_openbb_futures(
        symbol="NQ",
        interval="15m",
        start_date=START,
        end_date=END,
        provider="yfinance",
        transport="python",
        naive_timezone=ZoneInfo("America/New_York"),
    )
    runners = _runners()

    configs = {
        "zero_cost": BacktestConfig(
            commission_per_unit_per_side=0.0,
            slippage_per_unit_per_side=0.0,
            min_completed_trades=10,
        ),
        # NQ point value is $20.  $2.50/side commission ~= 0.125 points/side.
        # One tick of NQ slippage is 0.25 points/side. This is an explicit first
        # stress assumption, not a claim about the user's actual brokerage cost.
        "cost_stress_1tick": BacktestConfig(
            commission_per_unit_per_side=0.125,
            slippage_per_unit_per_side=0.25,
            min_completed_trades=10,
        ),
    }

    outputs = []
    for label, config in configs.items():
        result = CausalBacktestEngine(config).run({"NQ": bars}, runners)
        outputs.append(_serialize_result(label, result))

    payload = {
        "study": "openbb_nq15_r1_r2_r3_discovery_smoke_v1",
        "purpose": "mechanics/discovery only; not robustness certification",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "source": {
            "provider": stats.provider,
            "transport": stats.transport,
            "symbol": stats.symbol,
            "interval": stats.interval,
            "requested_start": START,
            "requested_end": END,
            "source_rows": stats.source_rows,
            "output_bars": stats.output_bars,
            "missing_volume_rows": stats.missing_volume_rows,
            "first_timestamp": stats.first_timestamp.isoformat(),
            "last_timestamp": stats.last_timestamp.isoformat(),
            "naive_timezone_policy": "America/New_York only if provider returned naive timestamps",
        },
        "runner_count": len(runners),
        "runs": outputs,
        "bb14_status": "not included: frozen BB14 user-rule engine is not yet on the same 15m common-Bar runner; avoid invalid apples-to-oranges comparison",
    }

    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / "summary.json"
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(payload, indent=2, sort_keys=True))
    print(f"RESULT_PATH={path}")


if __name__ == "__main__":
    main()
