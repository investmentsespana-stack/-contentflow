"""Discovery-only V4 robustness replay.

Replays the frozen V4 causal entry logic while perturbing ONLY the consecutive
trade-color exit count (2, 3, 4). Cost stress is applied later from gross-R so
execution paths are not changed by costs. Confirmatory and sealed holdout data
are not accessed.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

import pandas as pd

import bollinger_ema_sar_v1_backtest as base
import bollinger_ema_sar_v3_backtest as v3

OUT = Path("bollinger_ema_sar_v4_robustness_output")
EXIT_COUNTS = (2, 3, 4)


def run_trade(g: pd.DataFrame, signal_i: int, direction: int, exit_count: int):
    entry_i = signal_i + 1
    if entry_i >= len(g):
        return None
    entry = float(g.at[entry_i, "open"])
    if direction == 1:
        stop = float(g.at[signal_i - 1, "low"])
        if not (entry > stop):
            return None
        risk = entry - stop
    else:
        stop = float(g.at[signal_i - 1, "high"])
        if not (entry < stop):
            return None
        risk = stop - entry
    if risk <= 0:
        return None

    consecutive = 0
    exit_i = len(g) - 1
    exit_price = float(g.at[exit_i, "close"])
    reason = "dataset_end"

    for j in range(entry_i, len(g)):
        high = float(g.at[j, "high"])
        low = float(g.at[j, "low"])
        opn = float(g.at[j, "open"])
        close = float(g.at[j, "close"])
        stop_hit = low <= stop if direction == 1 else high >= stop
        if stop_hit:
            exit_i, exit_price, reason = j, stop, "stop"
            break
        same_color = close > opn if direction == 1 else close < opn
        consecutive = consecutive + 1 if same_color else 0
        if consecutive >= exit_count:
            exit_i, exit_price = j, close
            reason = f"{exit_count}_consecutive_trade_color"
            break

    pnl_points = direction * (exit_price - entry)
    gross_r = pnl_points / risk
    return {
        "entry_i": entry_i,
        "exit_i": exit_i,
        "entry": entry,
        "stop": stop,
        "exit": exit_price,
        "exit_reason": reason,
        "risk_points": risk,
        "pnl_points": pnl_points,
        "gross_r": gross_r,
        "bars_held": exit_i - entry_i + 1,
    }


def replay_symbol(symbol: str, exit_count: int) -> list[dict]:
    g = base.enrich(base.load_market(symbol))
    _, _, long_mask, short_mask, pats = v3.signal_masks_v3(g)
    trades: list[dict] = []
    i = 205
    while i < len(g) - 1:
        long_ok = bool(long_mask.iloc[i])
        short_ok = bool(short_mask.iloc[i])
        if long_ok == short_ok:
            i += 1
            continue
        direction = 1 if long_ok else -1
        result = run_trade(g, i, direction, exit_count)
        if result is None:
            i += 1
            continue
        row = g.iloc[i]
        aligned, crossed_signal, crossed_during, phase = v3.ema9_20_diagnostics(
            g, i, direction, int(result["exit_i"])
        )
        trades.append({
            "symbol": symbol,
            "exit_count": exit_count,
            "direction": "LONG" if direction == 1 else "SHORT",
            "signal_time_et": str(row["local_time"]),
            "entry_time_et": str(g.iloc[result["entry_i"]]["local_time"]),
            "exit_time_et": str(g.iloc[result["exit_i"]]["local_time"]),
            "session": str(row["session"]),
            "pattern": base.pattern_name(i, direction, pats),
            "ema9_20_aligned_at_signal": bool(aligned),
            "ema9_20_cross_on_signal": bool(crossed_signal),
            "ema9_20_cross_during_trade": bool(crossed_during),
            "ema9_20_phase": str(phase),
            **{k: v for k, v in result.items() if not k.endswith("_i")},
        })
        i = int(result["exit_i"]) + 1
    return trades


def main():
    symbol = os.getenv("BES_SYMBOL", "ES.v.0").strip()
    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported BES_SYMBOL={symbol}")
    OUT.mkdir(exist_ok=True)
    all_rows: list[dict] = []
    counts = {}
    for n in EXIT_COUNTS:
        rows = replay_symbol(symbol, n)
        all_rows.extend(rows)
        counts[str(n)] = len(rows)
    pd.DataFrame(all_rows).to_csv(OUT / f"{symbol.replace('.', '_')}_robustness_trades.csv", index=False)
    summary = {
        "strategy": "bollinger_ema_sar_v4_robustness",
        "symbol": symbol,
        "window": [str(base.START), str(base.END)],
        "exit_counts": list(EXIT_COUNTS),
        "trade_counts": counts,
        "live_money": False,
        "confirmatory_touched": False,
        "sealed_holdout_touched": False,
    }
    (OUT / f"{symbol.replace('.', '_')}_robustness_manifest.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
