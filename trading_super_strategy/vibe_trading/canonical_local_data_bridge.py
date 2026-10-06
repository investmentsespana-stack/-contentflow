from __future__ import annotations

"""Cygnus canonical local Data Bridge for Vibe-Trading futures research.

Stage 1 uses canonical_market_data for controlled Yahoo ingestion/freeze.
Stage 2 materializes that verified cache into Vibe's official local Data Bridge,
verifies local-loader parity, and emits deterministic research snapshots.
Swarm agents never refresh network data; backtests use source=local.
"""

from pathlib import Path
import hashlib
import json
import math
from typing import Any

import numpy as np
import pandas as pd
import yaml

import canonical_market_data as ingest
from backtest.loaders.base import loader_cache_get
from backtest.loaders.local_loader import DataLoader as LocalDataLoader

ROOT = Path(r"C:\Cygnus\VibeTrading")
DATA_ROOT = ROOT / "data" / "canonical_futures"
MANIFEST_ROOT = DATA_ROOT / "manifests"
BRIDGE_CONFIG = Path.home() / ".vibe-trading" / "data-bridge" / "config.yaml"

TARGETS = {"ES": "ES=F", "NQ": "NQ=F", "GC": "GC=F", "CL": "CL=F"}
TF_SPECS = {
    "5m": {"suffix": "5M", "min_rows": 200},
    "15m": {"suffix": "15M", "min_rows": 100},
    "1H": {"suffix": "1H", "min_rows": 500},
    "4H": {"suffix": "4H", "min_rows": 120},
}


def _normalize_asset(asset: str) -> str:
    value = str(asset or "").strip().upper()
    if value not in TARGETS:
        raise ValueError(f"UNSUPPORTED_CANONICAL_ASSET:{value}")
    return value


def _file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _csv_frame(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, parse_dates=["date"])
    if "date" not in df.columns:
        raise ValueError(f"CANONICAL_DATE_COLUMN_MISSING:{path}")
    return df.sort_values("date").reset_index(drop=True)


def _finite(value: object, digits: int = 8) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number):
        return None
    return round(number, digits)


def _percentile_rank(history: pd.Series, current: float | None) -> float | None:
    if current is None:
        return None
    clean = pd.to_numeric(history, errors="coerce").dropna()
    if clean.empty:
        return None
    return _finite((clean <= float(current)).mean() * 100.0, 3)


def _quantiles(series: pd.Series) -> dict[str, float | None]:
    clean = pd.to_numeric(series, errors="coerce").dropna()
    if clean.empty:
        return {"p25": None, "p50": None, "p75": None}
    return {
        "p25": _finite(clean.quantile(0.25)),
        "p50": _finite(clean.quantile(0.50)),
        "p75": _finite(clean.quantile(0.75)),
    }


def _research_snapshot(df: pd.DataFrame) -> dict[str, Any]:
    if len(df) < 60:
        raise ValueError("CANONICAL_SNAPSHOT_REQUIRES_60_ROWS")

    close = pd.to_numeric(df["close"], errors="coerce")
    high = pd.to_numeric(df["high"], errors="coerce")
    low = pd.to_numeric(df["low"], errors="coerce")
    volume = pd.to_numeric(
        df.get("volume", pd.Series(index=df.index, dtype=float)), errors="coerce"
    )

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

    last_trend = _finite(trend.iloc[-1])
    last_vol = _finite(vol20.iloc[-1])
    last_eff = _finite(efficiency20.iloc[-1])

    def pct_change_n(n: int) -> float | None:
        if len(close) <= n or float(close.iloc[-n - 1]) == 0:
            return None
        return _finite((close.iloc[-1] / close.iloc[-n - 1] - 1.0) * 100.0)

    direction = "flat"
    if last_trend is not None:
        direction = "up" if last_trend > 0 else ("down" if last_trend < 0 else "flat")

    recent_bars = []
    for row in df.tail(8).itertuples(index=False):
        recent_bars.append({
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
        "last_close": _finite(close.iloc[-1]),
        "return_pct": {
            "1_bar": pct_change_n(1),
            "5_bar": pct_change_n(5),
            "20_bar": pct_change_n(20),
        },
        "ema20": _finite(ema20.iloc[-1]),
        "ema50": _finite(ema50.iloc[-1]),
        "ema20_vs_ema50_pct": last_trend,
        "trend_direction": direction,
        "realized_vol_20_per_bar_pct": last_vol,
        "atr14_pct_of_close": _finite(atr_pct.iloc[-1]),
        "rsi14": _finite(rsi14.iloc[-1]),
        "efficiency_ratio_20": last_eff,
        "range_20_pct": _finite(range20.iloc[-1]),
        "trend_percentile": _percentile_rank(
            trend.abs(), abs(last_trend) if last_trend is not None else None
        ),
        "volatility_percentile": _percentile_rank(vol20, last_vol),
        "efficiency_percentile": _percentile_rank(efficiency20, last_eff),
        "history_quantiles": {
            "abs_trend_pct": _quantiles(trend.abs()),
            "vol20_per_bar_pct": _quantiles(vol20),
            "efficiency20": _quantiles(efficiency20),
            "atr14_pct": _quantiles(atr_pct),
        },
        "volume": {
            "last": _finite(volume.iloc[-1], 3) if not volume.empty else None,
            "median_20": _finite(volume.tail(20).median(), 3) if not volume.empty else None,
        },
        "recent_bars": recent_bars,
    }


def _bridge_entries() -> list[dict[str, Any]]:
    if not BRIDGE_CONFIG.exists():
        return []
    data = yaml.safe_load(BRIDGE_CONFIG.read_text(encoding="utf-8")) or {}
    sources = data.get("sources")
    return list(sources) if isinstance(sources, list) else []


def _write_bridge_entries(entries: list[dict[str, Any]]) -> None:
    BRIDGE_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    BRIDGE_CONFIG.write_text(
        yaml.safe_dump({"sources": entries}, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )


def _upsert_bridge_alias(alias: str, path: Path) -> None:
    entries = _bridge_entries()
    entries = [e for e in entries if str(e.get("symbol") or "").strip() != alias]
    entries.append({
        "symbol": alias,
        "type": "csv",
        "path": str(path),
        "columns": {
            "date": "date", "open": "open", "high": "high",
            "low": "low", "close": "close", "volume": "volume",
        },
    })
    _write_bridge_entries(entries)


def _cached_frame(symbol: str, interval: str, meta: dict[str, Any]) -> pd.DataFrame:
    frame = loader_cache_get(
        source="yahoo",
        symbol=symbol,
        timeframe=interval,
        start_date=meta["start_date"],
        end_date=meta["end_date"],
        fields=None,
    )
    if frame is None or frame.empty:
        raise RuntimeError(f"FROZEN_INGEST_CACHE_MISSING:{symbol}:{interval}")
    return frame.sort_index()


def _write_alias_csv(alias: str, frame: pd.DataFrame) -> tuple[Path, pd.DataFrame]:
    DATA_ROOT.mkdir(parents=True, exist_ok=True)
    work = frame.copy()
    work.index = pd.DatetimeIndex(work.index)
    work.index.name = "date"
    work = work.reset_index()
    if "volume" not in work.columns:
        work["volume"] = 0.0
    work = work[["date", "open", "high", "low", "close", "volume"]]
    work = work.sort_values("date").drop_duplicates(subset=["date"], keep="last")
    path = DATA_ROOT / f"{alias}.csv"
    work.to_csv(path, index=False)
    return path, work.reset_index(drop=True)


def _validate_csv(df: pd.DataFrame, min_rows: int) -> dict[str, Any]:
    duplicates = int(df["date"].duplicated().sum())
    monotonic = bool(df["date"].is_monotonic_increasing)
    bad_ohlc = int((
        (df["high"] < df[["open", "close", "low"]].max(axis=1))
        | (df["low"] > df[["open", "close", "high"]].min(axis=1))
    ).sum())
    return {
        "ok": len(df) >= min_rows and duplicates == 0 and monotonic and bad_ohlc == 0,
        "rows": int(len(df)),
        "duplicates": duplicates,
        "bad_ohlc": bad_ohlc,
        "monotonic": monotonic,
        "first": str(df["date"].iloc[0]),
        "last": str(df["date"].iloc[-1]),
    }


def _local_loader_probe(alias: str, interval: str, start: str, end: str) -> dict[str, Any]:
    loader = LocalDataLoader()
    result = loader.fetch([alias], start, end, interval=interval)
    frame = result.get(alias)
    return {
        "ok": frame is not None and not frame.empty,
        "rows": int(len(frame)) if frame is not None else 0,
    }


def materialize_contract(asset: str) -> dict[str, Any]:
    asset = _normalize_asset(asset)
    ingested = ingest.ensure_contract(asset)
    if not ingested.get("ok"):
        raise RuntimeError(f"INGEST_CONTRACT_NOT_READY:{asset}:{ingested}")

    base_manifest = ingested["manifest"]
    symbol = str(base_manifest["symbol"])
    timeframes = {}

    for interval, spec in TF_SPECS.items():
        source_meta = base_manifest["timeframes"][interval]
        frame = _cached_frame(symbol, interval, source_meta)
        alias = f"{asset}_CYGNUS_{spec['suffix']}"
        path, csv_df = _write_alias_csv(alias, frame)
        _upsert_bridge_alias(alias, path)

        csv_check = _validate_csv(csv_df, int(spec["min_rows"]))
        probe = _local_loader_probe(
            alias, interval, str(source_meta["start_date"]), str(source_meta["end_date"])
        )
        if not csv_check["ok"] or not probe["ok"] or probe["rows"] != csv_check["rows"]:
            raise RuntimeError(
                f"LOCAL_BRIDGE_VERIFY_FAILED:{asset}:{interval}:"
                f"csv={csv_check}:probe={probe}"
            )

        record = {
            "symbol": alias,
            "target": TARGETS[asset],
            "source": "local",
            "interval": interval,
            "start_date": str(source_meta["start_date"]),
            "end_date": str(source_meta["end_date"]),
            "rows": int(csv_check["rows"]),
            "sha256": _file_sha256(path),
            "file": str(path),
            "min_rows": int(spec["min_rows"]),
            "ingest_provider": "yahoo",
            "ingest_origin": source_meta.get("origin"),
            "ingest_sha256": source_meta.get("sha256"),
            "local_loader_rows": int(probe["rows"]),
            "research_snapshot": _research_snapshot(csv_df),
        }
        timeframes[interval] = record

        MANIFEST_ROOT.mkdir(parents=True, exist_ok=True)
        (MANIFEST_ROOT / f"{alias}.json").write_text(
            json.dumps(record, indent=2, ensure_ascii=False), encoding="utf-8"
        )

    manifest = {
        "schema": "cygnus.canonical_market_data.v3",
        "asset": asset,
        "target": TARGETS[asset],
        "source": "local",
        "ingest_provider": "yahoo",
        "settled_end": min(v["end_date"] for v in timeframes.values()),
        "immutable_for_run": True,
        "timeframes": timeframes,
        "rules": {
            "network_inside_swarm": False,
            "backtests_must_use_source": "local",
            "agents_use_research_snapshot": True,
            "raw_backtest_data_is_full_local_file": True,
        },
    }
    MANIFEST_ROOT.mkdir(parents=True, exist_ok=True)
    (MANIFEST_ROOT / f"{asset}_CONTRACT.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    return manifest


def verify_contract(asset: str) -> dict[str, Any]:
    asset = _normalize_asset(asset)
    path = MANIFEST_ROOT / f"{asset}_CONTRACT.json"
    if not path.exists():
        return {"ok": False, "asset": asset, "reason": "manifest_missing"}

    manifest = json.loads(path.read_text(encoding="utf-8"))
    checks = {}
    for interval, meta in manifest.get("timeframes", {}).items():
        csv_path = Path(meta["file"])
        try:
            df = _csv_frame(csv_path)
            csv_check = _validate_csv(df, int(meta["min_rows"]))
            actual_hash = _file_sha256(csv_path)
            probe = _local_loader_probe(
                meta["symbol"], interval, meta["start_date"], meta["end_date"]
            )
            checks[interval] = {
                **csv_check,
                "symbol": meta["symbol"],
                "source": "local",
                "sha256": actual_hash,
                "hash_match": actual_hash == meta["sha256"],
                "local_loader_rows": probe["rows"],
                "local_loader_match": probe["rows"] == len(df),
                "snapshot_ready": bool(meta.get("research_snapshot")),
                "ok": (
                    bool(csv_check["ok"])
                    and actual_hash == meta["sha256"]
                    and bool(probe["ok"])
                    and probe["rows"] == len(df)
                    and bool(meta.get("research_snapshot"))
                ),
            }
        except Exception as exc:
            checks[interval] = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}

    required = set(TF_SPECS)
    return {
        "ok": required.issubset(checks) and all(bool(v.get("ok")) for v in checks.values()),
        "asset": asset,
        "symbol": TARGETS[asset],
        "source": "local",
        "timeframes": checks,
        "manifest": manifest,
    }


def ensure_contract(asset: str) -> dict[str, Any]:
    asset = _normalize_asset(asset)
    try:
        manifest = materialize_contract(asset)
    except Exception as exc:
        return {"ok": False, "asset": asset, "error": f"{type(exc).__name__}: {exc}"}
    verified = verify_contract(asset)
    return {"ok": bool(verified.get("ok")), "asset": asset, "manifest": manifest,
            "verification": verified}


def ensure_all() -> dict[str, Any]:
    results = {asset: ensure_contract(asset) for asset in TARGETS}
    return {"ok": all(bool(v.get("ok")) for v in results.values()), "assets": results}


def compact_contract(asset: str) -> str:
    asset = _normalize_asset(asset)
    path = MANIFEST_ROOT / f"{asset}_CONTRACT.json"
    if not path.exists():
        state = ensure_contract(asset)
        if not state.get("ok"):
            return json.dumps(state, separators=(",", ":"))
    manifest = json.loads(path.read_text(encoding="utf-8"))
    payload = {
        "schema": manifest["schema"],
        "identity_target": manifest["target"],
        "execution_mode": "RESEARCH_ONLY",
        "data_source": "local",
        "fresh_network_fetch_inside_swarm": False,
        "settled_end": manifest["settled_end"],
        "datasets": {
            tf: {
                "symbol": meta["symbol"],
                "interval": meta["interval"],
                "start": meta["start_date"],
                "end": meta["end_date"],
                "rows": meta["rows"],
                "sha256": meta["sha256"],
                "research_snapshot": meta["research_snapshot"],
            }
            for tf, meta in manifest["timeframes"].items()
        },
    }
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--asset", default="ALL")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.asset.upper() == "ALL":
        result = (
            {"ok": all(verify_contract(a).get("ok") for a in TARGETS),
             "assets": {a: verify_contract(a) for a in TARGETS}}
            if args.verify else ensure_all()
        )
    else:
        result = verify_contract(args.asset) if args.verify else ensure_contract(args.asset)
    print(json.dumps(result, indent=2, ensure_ascii=False, default=str))
    raise SystemExit(0 if result.get("ok") else 2)
