from __future__ import annotations

from pathlib import Path
import hashlib
import json
import math
import numpy as np
import pandas as pd

ROOT = Path(r"C:\Cygnus\VibeTrading")
DATA_ROOT = ROOT / "data" / "canonical_futures"

TARGETS = {
    "ES": "ES=F",
    "NQ": "NQ=F",
    "GC": "GC=F",
    "CL": "CL=F",
}

TF_SPECS = {
    "5m":  {"suffix": "5M",  "interval": "5m", "min_rows": 200},
    "15m": {"suffix": "15M", "interval": "15m", "min_rows": 100},
    "1H":  {"suffix": "1H",  "interval": "1H", "min_rows": 500},
    "4H":  {"suffix": "4H",  "interval": "4H", "min_rows": 120},
}


def _normalize_asset(asset: str) -> str:
    value = str(asset or "").strip().upper()
    if value not in TARGETS:
        raise ValueError(f"UNSUPPORTED_CANONICAL_ASSET:{value}")
    return value


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _frame(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, parse_dates=["date"])
    if "date" not in df.columns:
        raise ValueError(f"CANONICAL_DATE_COLUMN_MISSING:{path}")
    return df.sort_values("date").reset_index(drop=True)


def _finite(value: object, digits: int = 8) -> float | None:
    try:
        x = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(x):
        return None
    return round(x, digits)


def _percentile_rank(history: pd.Series, current: float | None) -> float | None:
    if current is None:
        return None
    clean = pd.to_numeric(history, errors="coerce").dropna()
    if clean.empty:
        return None
    return _finite((clean <= float(current)).mean() * 100.0, 3)


def _research_snapshot(df: pd.DataFrame) -> dict:
    """Compact deterministic features derived from the full frozen OHLCV file.

    This is analysis context for the agents, not a backtest result. Backtests still
    read the complete local file through Vibe's native local loader.
    """
    if len(df) < 60:
        raise ValueError("CANONICAL_SNAPSHOT_REQUIRES_60_ROWS")

    close = pd.to_numeric(df["close"], errors="coerce")
    high = pd.to_numeric(df["high"], errors="coerce")
    low = pd.to_numeric(df["low"], errors="coerce")
    volume = pd.to_numeric(df.get("volume", pd.Series(index=df.index, dtype=float)), errors="coerce")

    ret = close.pct_change()
    ema20 = close.ewm(span=20, adjust=False).mean()
    ema50 = close.ewm(span=50, adjust=False).mean()
    trend = (ema20 / ema50 - 1.0) * 100.0

    prev_close = close.shift(1)
    true_range = pd.concat(
        [(high - low), (high - prev_close).abs(), (low - prev_close).abs()],
        axis=1,
    ).max(axis=1)
    atr14 = true_range.ewm(alpha=1 / 14, adjust=False).mean()
    atr_pct = atr14 / close * 100.0

    delta = close.diff()
    gain = delta.clip(lower=0).ewm(alpha=1 / 14, adjust=False).mean()
    loss = (-delta.clip(upper=0)).ewm(alpha=1 / 14, adjust=False).mean()
    rs = gain / loss.replace(0, np.nan)
    rsi14 = 100.0 - (100.0 / (1.0 + rs))

    abs_path = close.diff().abs().rolling(20).sum()
    efficiency20 = (close - close.shift(20)).abs() / abs_path.replace(0, np.nan)
    vol20 = ret.rolling(20).std() * 100.0
    range20 = (high.rolling(20).max() / low.rolling(20).min() - 1.0) * 100.0

    last_close = _finite(close.iloc[-1])
    last_trend = _finite(trend.iloc[-1])
    last_vol = _finite(vol20.iloc[-1])
    last_eff = _finite(efficiency20.iloc[-1])
    last_atr = _finite(atr_pct.iloc[-1])
    last_rsi = _finite(rsi14.iloc[-1])

    def pct_change_n(n: int) -> float | None:
        if len(close) <= n or close.iloc[-n - 1] == 0:
            return None
        return _finite((close.iloc[-1] / close.iloc[-n - 1] - 1.0) * 100.0)

    def quantiles(series: pd.Series) -> dict:
        clean = series.dropna()
        if clean.empty:
            return {"p25": None, "p50": None, "p75": None}
        return {
            "p25": _finite(clean.quantile(0.25)),
            "p50": _finite(clean.quantile(0.50)),
            "p75": _finite(clean.quantile(0.75)),
        }

    direction = "flat"
    if last_trend is not None:
        if last_trend > 0:
            direction = "up"
        elif last_trend < 0:
            direction = "down"

    tail = []
    for row in df.tail(8).itertuples(index=False):
        tail.append({
            "date": str(getattr(row, "date")),
            "open": _finite(getattr(row, "open")),
            "high": _finite(getattr(row, "high")),
            "low": _finite(getattr(row, "low")),
            "close": _finite(getattr(row, "close")),
            "volume": _finite(getattr(row, "volume", None), 3),
        })

    return {
        "schema": "cygnus.canonical_research_snapshot.v1",
        "derived_from_full_frozen_file": True,
        "rows_used": int(len(df)),
        "last_bar": str(df["date"].iloc[-1]),
        "last_close": last_close,
        "return_pct": {"1_bar": pct_change_n(1), "5_bar": pct_change_n(5), "20_bar": pct_change_n(20)},
        "ema20": _finite(ema20.iloc[-1]),
        "ema50": _finite(ema50.iloc[-1]),
        "ema20_vs_ema50_pct": last_trend,
        "trend_direction": direction,
        "realized_vol_20_per_bar_pct": last_vol,
        "atr14_pct_of_close": last_atr,
        "rsi14": last_rsi,
        "efficiency_ratio_20": last_eff,
        "range_20_pct": _finite(range20.iloc[-1]),
        "trend_percentile": _percentile_rank(trend.abs(), abs(last_trend) if last_trend is not None else None),
        "volatility_percentile": _percentile_rank(vol20, last_vol),
        "efficiency_percentile": _percentile_rank(efficiency20, last_eff),
        "history_quantiles": {
            "abs_trend_pct": quantiles(trend.abs()),
            "vol20_per_bar_pct": quantiles(vol20),
            "efficiency20": quantiles(efficiency20),
            "atr14_pct": quantiles(atr_pct),
        },
        "volume": {
            "last": _finite(volume.iloc[-1], 3) if not volume.empty else None,
            "median_20": _finite(volume.tail(20).median(), 3) if not volume.empty else None,
        },
        "recent_bars": tail,
    }


def _meta(asset: str, tf: str) -> dict:
    spec = TF_SPECS[tf]
    alias = f"{asset}_CYGNUS_{spec['suffix']}"
    path = DATA_ROOT / f"{alias}.csv"
    if not path.is_file():
        raise FileNotFoundError(str(path))
    df = _frame(path)
    if df.empty:
        raise ValueError(f"CANONICAL_EMPTY:{alias}")
    first = pd.Timestamp(df["date"].iloc[0])
    last = pd.Timestamp(df["date"].iloc[-1])
    return {
        "symbol": alias,
        "target": TARGETS[asset],
        "source": "local",
        "interval": spec["interval"],
        "start_date": first.date().isoformat(),
        "end_date": last.date().isoformat(),
        "rows": int(len(df)),
        "sha256": _sha256(path),
        "file": str(path),
        "min_rows": int(spec["min_rows"]),
        "snapshot": _research_snapshot(df),
    }


def ensure_contract(asset: str) -> dict:
    asset = _normalize_asset(asset)
    try:
        timeframes = {tf: _meta(asset, tf) for tf in TF_SPECS}
        settled_end = min(v["end_date"] for v in timeframes.values())
        return {
            "ok": True,
            "manifest": {
                "schema": "cygnus.canonical_market_data.v3",
                "asset": asset,
                "target": TARGETS[asset],
                "source": "local",
                "settled_end": settled_end,
                "timeframes": timeframes,
            },
        }
    except Exception as exc:
        return {"ok": False, "asset": asset, "error": f"{type(exc).__name__}: {exc}"}


def verify_contract(asset: str) -> dict:
    asset = _normalize_asset(asset)
    state = ensure_contract(asset)
    if not state.get("ok"):
        return state
    manifest = state["manifest"]
    checks = {}
    for tf, meta in manifest["timeframes"].items():
        path = Path(meta["file"])
        try:
            df = _frame(path)
            dup = int(df["date"].duplicated().sum())
            monotonic = bool(df["date"].is_monotonic_increasing)
            bad_ohlc = int((
                (df["high"] < df[["open", "close", "low"]].max(axis=1)) |
                (df["low"] > df[["open", "close", "high"]].min(axis=1))
            ).sum())
            actual_hash = _sha256(path)
            checks[tf] = {
                "ok": (
                    len(df) >= int(meta["min_rows"])
                    and dup == 0
                    and monotonic
                    and bad_ohlc == 0
                    and actual_hash == meta["sha256"]
                ),
                "symbol": meta["symbol"],
                "source": "local",
                "rows": int(len(df)),
                "min_rows": int(meta["min_rows"]),
                "duplicates": dup,
                "bad_ohlc": bad_ohlc,
                "monotonic": monotonic,
                "first": str(df["date"].iloc[0]),
                "last": str(df["date"].iloc[-1]),
                "sha256": actual_hash,
                "hash_match": actual_hash == meta["sha256"],
                "snapshot_ready": bool(meta.get("snapshot")),
            }
        except Exception as exc:
            checks[tf] = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
    return {
        "ok": all(bool(v.get("ok")) for v in checks.values()),
        "asset": asset,
        "symbol": TARGETS[asset],
        "source": "local",
        "timeframes": checks,
        "manifest": manifest,
    }


def compact_contract(asset: str) -> str:
    asset = _normalize_asset(asset)
    state = ensure_contract(asset)
    if not state.get("ok"):
        return json.dumps(state, separators=(",", ":"))
    m = state["manifest"]
    payload = {
        "schema": m["schema"],
        "identity_target": m["target"],
        "execution_mode": "RESEARCH_ONLY",
        "data_source": "local",
        "fresh_network_fetch_inside_swarm": False,
        "settled_end": m["settled_end"],
        "datasets": {
            tf: {
                "symbol": meta["symbol"],
                "interval": meta["interval"],
                "start": meta["start_date"],
                "end": meta["end_date"],
                "rows": meta["rows"],
                "sha256": meta["sha256"],
                "research_snapshot": meta["snapshot"],
            }
            for tf, meta in m["timeframes"].items()
        },
    }
    return json.dumps(payload, separators=(",", ":"))