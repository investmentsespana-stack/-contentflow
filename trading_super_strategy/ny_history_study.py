import json
import os
from pathlib import Path
from datetime import datetime, timedelta, time
from zoneinfo import ZoneInfo

import pandas as pd
import databento as db

TZ = ZoneInfo("America/New_York")
UTC = ZoneInfo("UTC")
SYMBOLS = ["NQ.v.0", "ES.v.0", "YM.v.0", "RTY.v.0"]
SEGMENTS = {
    "pre_08_09": (time(8, 0), time(9, 0)),
    "ny_09_10": (time(9, 0), time(10, 0)),
    "ny_10_11": (time(10, 0), time(11, 0)),
    "ny_11_1130": (time(11, 0), time(11, 30)),
    "observe_1130_12": (time(11, 30), time(12, 0)),
    "anchor_09_12": (time(9, 0), time(12, 0)),
}


def weekdays(end_date: datetime, count: int):
    out = []
    d = end_date.date()
    while len(out) < count:
        if d.weekday() < 5:
            out.append(d)
        d -= timedelta(days=1)
    return sorted(out)


def utc_iso(d, hh, mm=0):
    local = datetime.combine(d, time(hh, mm), TZ)
    return local.astimezone(UTC).isoformat().replace("+00:00", "Z")


def segment_stats(g, start_t, end_t):
    lt = g["local_time"].dt.time
    mask = (lt >= start_t) & (lt < end_t)
    s = g[mask]
    if s.empty:
        return None
    op = float(s.iloc[0]["open"])
    cl = float(s.iloc[-1]["close"])
    hi = float(s["high"].max())
    lo = float(s["low"].min())
    rng = hi - lo
    net = cl - op
    return {
        "rows": int(len(s)),
        "open": op,
        "high": hi,
        "low": lo,
        "close": cl,
        "range": rng,
        "net": net,
        "volume": int(s["volume"].sum()),
        "direction": 1 if net > 0 else (-1 if net < 0 else 0),
        "efficiency": abs(net) / rng if rng else 0.0,
        "close_location": (cl - lo) / rng if rng else 0.5,
    }


def classify_day(by_symbol):
    # These are research proxies, not labels of market intent.
    d10 = [v["ny_10_11"]["direction"] for v in by_symbol.values() if v.get("ny_10_11")]
    cross_consensus_10_11 = abs(sum(d10)) / len(d10) if d10 else 0.0

    avg_eff_09_10 = sum(v["ny_09_10"]["efficiency"] for v in by_symbol.values()) / len(by_symbol)
    avg_eff_10_11 = sum(v["ny_10_11"]["efficiency"] for v in by_symbol.values()) / len(by_symbol)
    avg_vol_09_10 = sum(v["ny_09_10"]["volume"] for v in by_symbol.values()) / len(by_symbol)
    avg_vol_10_11 = sum(v["ny_10_11"]["volume"] for v in by_symbol.values()) / len(by_symbol)

    pre_dirs = [v["pre_08_09"]["direction"] for v in by_symbol.values()]
    ny1_dirs = [v["ny_09_10"]["direction"] for v in by_symbol.values()]
    pre_to_ny_same = sum(1 for a, b in zip(pre_dirs, ny1_dirs) if a != 0 and a == b) / len(by_symbol)

    return {
        "cross_market_consensus_10_11": cross_consensus_10_11,
        "avg_efficiency_09_10": avg_eff_09_10,
        "avg_efficiency_10_11": avg_eff_10_11,
        "avg_volume_09_10": avg_vol_09_10,
        "avg_volume_10_11": avg_vol_10_11,
        "volume_ratio_10_11_vs_09_10": avg_vol_10_11 / avg_vol_09_10 if avg_vol_09_10 else None,
        "pre_to_09_10_same_direction_fraction": pre_to_ny_same,
        "distribution_proxy": bool(cross_consensus_10_11 >= 0.75 and avg_eff_10_11 >= 0.50),
        "continuation_proxy": bool(pre_to_ny_same >= 0.75 and avg_eff_09_10 >= 0.35),
        "manipulation_then_distribution_proxy": bool(avg_eff_09_10 < 0.35 and cross_consensus_10_11 >= 0.75 and avg_eff_10_11 >= 0.50),
    }


def main():
    key = os.getenv("DATABENTO_API_KEY", "")
    if not key:
        raise SystemExit("DATABENTO_API_KEY secret is missing")

    count = int(os.getenv("STUDY_SESSIONS", "15"))
    end = datetime(2026, 9, 11, tzinfo=TZ)
    dates = weekdays(end, count)
    client = db.Historical(key)
    out = Path("trading_study_output")
    out.mkdir(exist_ok=True)

    sessions = []
    all_rows = []
    for d in dates:
        data = client.timeseries.get_range(
            dataset="GLBX.MDP3",
            schema="ohlcv-1m",
            stype_in="continuous",
            symbols=SYMBOLS,
            start=utc_iso(d, 8, 0),
            end=utc_iso(d, 12, 0),
        )
        df = data.to_df()
        if df.empty:
            continue
        idx = pd.DatetimeIndex(df.index)
        if idx.tz is None:
            idx = idx.tz_localize("UTC")
        work = df.copy()
        work["local_time"] = idx.tz_convert(TZ)
        work["session_date"] = str(d)
        all_rows.append(work.reset_index())

        by_symbol = {}
        for symbol, g in work.groupby("symbol"):
            rec = {}
            for name, (a, b) in SEGMENTS.items():
                rec[name] = segment_stats(g, a, b)
            if all(rec[k] is not None for k in ["pre_08_09", "ny_09_10", "ny_10_11", "ny_11_1130", "anchor_09_12"]):
                by_symbol[str(symbol)] = rec
        if len(by_symbol) == 4:
            sessions.append({"date": str(d), "symbols": by_symbol, "classification": classify_day(by_symbol)})

    if all_rows:
        pd.concat(all_rows, ignore_index=True).to_csv(out / "raw_1m_sessions.csv", index=False)

    n = len(sessions)
    agg = {
        "sessions_requested": count,
        "sessions_complete": n,
        "symbols": SYMBOLS,
        "anchor": "09:00-12:00 ET",
        "entry_window": "09:00-11:30 ET",
        "distribution_proxy_rate": sum(s["classification"]["distribution_proxy"] for s in sessions) / n if n else None,
        "continuation_proxy_rate": sum(s["classification"]["continuation_proxy"] for s in sessions) / n if n else None,
        "manipulation_then_distribution_proxy_rate": sum(s["classification"]["manipulation_then_distribution_proxy"] for s in sessions) / n if n else None,
        "avg_cross_market_consensus_10_11": sum(s["classification"]["cross_market_consensus_10_11"] for s in sessions) / n if n else None,
        "avg_efficiency_09_10": sum(s["classification"]["avg_efficiency_09_10"] for s in sessions) / n if n else None,
        "avg_efficiency_10_11": sum(s["classification"]["avg_efficiency_10_11"] for s in sessions) / n if n else None,
        "avg_volume_ratio_10_11_vs_09_10": sum(s["classification"]["volume_ratio_10_11_vs_09_10"] for s in sessions) / n if n else None,
        "note": "Heuristic proxies only; not yet trained labels or evidence of causality/market intent."
    }

    with open(out / "session_details.json", "w", encoding="utf-8") as f:
        json.dump(sessions, f, indent=2)
    with open(out / "aggregate.json", "w", encoding="utf-8") as f:
        json.dump(agg, f, indent=2)

    print("NY_HISTORY_STUDY_OK")
    print(json.dumps(agg, indent=2))


if __name__ == "__main__":
    main()
