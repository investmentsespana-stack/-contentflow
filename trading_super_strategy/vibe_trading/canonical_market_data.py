[Reading 343 lines from start (total: 343 lines, 0 remaining)]

from __future__ import annotations

import hashlib
import json
import os
import time
from datetime import date, timedelta, timezone, datetime
from pathlib import Path
from typing import Any

import pandas as pd

ROOT = Path(r"C:\Cygnus\VibeTrading")
DATA_ROOT = ROOT / "data" / "canonical"
CACHE_ROOT = ROOT / "data" / "loader-cache"

os.environ["VIBE_TRADING_DATA_CACHE"] = "1"
os.environ["VIBE_TRADING_DATA_CACHE_ROOT"] = str(CACHE_ROOT)

SYMBOLS = {
    "ES": "ES=F",
    "NQ": "NQ=F",
    "GC": "GC=F",
    "CL": "CL=F",
}

# Use settled windows only. Yahoo's sub-hour intraday history is bounded;
# 55 days stays safely inside the practical retention window. Hourly history
# gets a much larger but still bounded window. 4H is derived from the exact 1H
# snapshot because Yahoo has no native 4H bars.
WINDOW_DAYS = {
    "5m": 55,
    "15m": 55,
    "1H": 650,
    "4H": 650,
}

MIN_ROWS = {
    "5m": 200,
    "15m": 100,
    "1H": 500,
    "4H": 120,
}


def _settled_end() -> date:
    return datetime.now(timezone.utc).date() - timedelta(days=1)


def _window(interval: str) -> tuple[str, str]:
    end = _settled_end()
    start = end - timedelta(days=WINDOW_DAYS[interval])
    return start.isoformat(), end.isoformat()


def _frame_hash(frame: pd.DataFrame) -> str:
    work = frame.copy()
    work = work.sort_index()
    blob = work.to_csv(index=True, date_format="%Y-%m-%dT%H:%M:%S", float_format="%.10g").encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def _validate_frame(frame: pd.DataFrame | None, interval: str) -> dict[str, Any]:
    if frame is None or frame.empty:
        return {"ok": False, "reason": "empty", "rows": 0}
    required = {"open", "high", "low", "close"}
    if not required.issubset(frame.columns):
        return {"ok": False, "reason": "missing_ohlc", "rows": len(frame)}
    idx = pd.DatetimeIndex(frame.index)
    duplicate_count = int(idx.duplicated().sum())
    bad_ohlc = int(
        (
            (frame["high"] < frame["low"])
            | (frame["high"] < frame["open"])
            | (frame["high"] < frame["close"])
            | (frame["low"] > frame["open"])
            | (frame["low"] > frame["close"])
            | (frame[["open", "high", "low", "close"]] <= 0).any(axis=1)
        ).sum()
    )
    monotonic = bool(idx.is_monotonic_increasing)
    rows = int(len(frame))
    return {
        "ok": rows >= MIN_ROWS[interval] and duplicate_count == 0 and bad_ohlc == 0 and monotonic,
        "rows": rows,
        "min_rows": MIN_ROWS[interval],
        "duplicates": duplicate_count,
        "bad_ohlc": bad_ohlc,
        "monotonic": monotonic,
        "first": str(idx.min()),
        "last": str(idx.max()),
        "sha256": _frame_hash(frame),
    }


def _fetch_yahoo(symbol: str, interval: str, start: str, end: str, attempts: int = 3) -> pd.DataFrame | None:
    from backtest.loaders.yahoo_loader import DataLoader

    loader = DataLoader()
    last: pd.DataFrame | None = None
    for attempt in range(1, attempts + 1):
        result = loader.fetch([symbol], start, end, interval=interval)
        frame = result.get(symbol)
        if frame is not None and not frame.empty:
            return frame.sort_index()
        last = frame
        if attempt < attempts:
            time.sleep(2.0 * attempt)
    return last


def _resample_4h(hourly: pd.DataFrame) -> pd.DataFrame:
    agg = {
        "open": "first",
        "high": "max",
        "low": "min",
        "close": "last",
        "volume": "sum",
    }
    frame = hourly.resample("4h").agg(agg)
    frame = frame.dropna(subset=["open", "high", "low", "close"])
    frame.index.name = hourly.index.name
    return frame.astype(float)


def _write_cache(symbol: str, interval: str, start: str, end: str, frame: pd.DataFrame) -> None:
    from backtest.loaders.base import loader_cache_put

    loader_cache_put(
        source="yahoo",
        symbol=symbol,
        timeframe=interval,
        start_date=start,
        end_date=end,
        fields=None,
        frame=frame,
    )


def _read_cache(symbol: str, interval: str, start: str, end: str) -> pd.DataFrame | None:
    from backtest.loaders.base import loader_cache_get

    return loader_cache_get(
        source="yahoo",
        symbol=symbol,
        timeframe=interval,
        start_date=start,
        end_date=end,
        fields=None,
    )


def build_contract(asset: str, *, force_refresh: bool = False) -> dict[str, Any]:
    asset = asset.strip().upper()
    if asset not in SYMBOLS:
        raise ValueError(f"ASSET_NOT_SUPPORTED:{asset}")
    symbol = SYMBOLS[asset]
    out_dir = DATA_ROOT / asset
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = out_dir / "manifest.json"

    if manifest_path.exists() and not force_refresh:
        try:
            existing = json.loads(manifest_path.read_text(encoding="utf-8"))
            if existing.get("settled_end") == _settled_end().isoformat():
                verified = verify_contract(asset)
                if verified.get("ok"):
                    return existing
        except Exception:
            pass

    frames: dict[str, pd.DataFrame] = {}
    records: dict[str, Any] = {}

    for interval in ("5m", "15m", "1H"):
        start, end = _window(interval)
        # First try the official Vibe loader cache. Only hit Yahoo if absent.
        frame = None if force_refresh else _read_cache(symbol, interval, start, end)
        origin = "vibe_loader_cache"
        if frame is None or frame.empty:
            frame = _fetch_yahoo(symbol, interval, start, end)
            origin = "yahoo_live_then_frozen"
        check = _validate_frame(frame, interval)
        if not check["ok"]:
            raise RuntimeError(f"CANONICAL_DATA_INVALID:{asset}:{interval}:{check}")
        assert frame is not None
        _write_cache(symbol, interval, start, end, frame)
        frames[interval] = frame
        records[interval] = {
            **check,
            "source": "yahoo",
            "origin": origin,
            "start_date": start,
            "end_date": end,
            "cache_key_contract": {
                "source": "yahoo",
                "symbol": symbol,
                "timeframe": interval,
                "start_date": start,
                "end_date": end,
            },
        }

    start4, end4 = _window("4H")
    hourly = frames["1H"]
    frame4 = _resample_4h(hourly)
    check4 = _validate_frame(frame4, "4H")
    if not check4["ok"]:
        raise RuntimeError(f"CANONICAL_DATA_INVALID:{asset}:4H:{check4}")
    _write_cache(symbol, "4H", start4, end4, frame4)
    records["4H"] = {
        **check4,
        "source": "yahoo",
        "origin": "derived_from_frozen_1H",
        "derived_from": "1H",
        "start_date": start4,
        "end_date": end4,
        "cache_key_contract": {
            "source": "yahoo",
            "symbol": symbol,
            "timeframe": "4H",
            "start_date": start4,
            "end_date": end4,
        },
    }

    manifest = {
        "schema": "cygnus.vibe.canonical_market_data.v1",
        "asset": asset,
        "symbol": symbol,
        "provider": "yahoo",
        "settled_end": _settled_end().isoformat(),
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "cache_root": str(CACHE_ROOT),
        "immutable_for_run": True,
        "timeframes": records,
        "rules": {
            "agents_must_use_exact_windows": True,
            "backtests_must_use_source": "yahoo",
            "4H_is_resampled_from_1H": True,
            "do_not_infer_discontinuity_from_max_rows_truncation": True,
        },
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    return manifest


def verify_contract(asset: str) -> dict[str, Any]:
    asset = asset.strip().upper()
    symbol = SYMBOLS[asset]
    path = DATA_ROOT / asset / "manifest.json"
    if not path.exists():
        return {"ok": False, "reason": "manifest_missing", "asset": asset}
    manifest = json.loads(path.read_text(encoding="utf-8"))
    checks: dict[str, Any] = {}
    ok = True
    for interval, meta in (manifest.get("timeframes") or {}).items():
        frame = _read_cache(symbol, interval, meta["start_date"], meta["end_date"])
        check = _validate_frame(frame, interval)
        expected_hash = meta.get("sha256")
        hash_match = bool(check.get("sha256")) and check.get("sha256") == expected_hash
        checks[interval] = {**check, "hash_match": hash_match}
        ok = ok and bool(check.get("ok")) and hash_match
    required = {"5m", "15m", "1H", "4H"}
    ok = ok and required.issubset(checks)
    return {
        "ok": bool(ok),
        "asset": asset,
        "symbol": symbol,
        "manifest_path": str(path),
        "timeframes": checks,
    }


def ensure_contract(asset: str) -> dict[str, Any]:
    try:
        manifest = build_contract(asset)
    except Exception as exc:
        return {"ok": False, "asset": asset, "error": f"{type(exc).__name__}: {exc}"}
    verified = verify_contract(asset)
    return {
        "ok": bool(verified.get("ok")),
        "asset": asset,
        "manifest": manifest,
        "verification": verified,
    }


def ensure_all() -> dict[str, Any]:
    results = {asset: ensure_contract(asset) for asset in SYMBOLS}
    return {"ok": all(v.get("ok") for v in results.values()), "assets": results}


def compact_contract(asset: str) -> str:
    path = DATA_ROOT / asset.strip().upper() / "manifest.json"
    manifest = json.loads(path.read_text(encoding="utf-8"))
    compact = {
        "symbol": manifest["symbol"],
        "provider": manifest["provider"],
        "settled_end": manifest["settled_end"],
        "timeframes": {
            tf: {
                "start_date": v["start_date"],
                "end_date": v["end_date"],
                "rows": v["rows"],
                "sha256": v["sha256"],
                "origin": v["origin"],
            }
            for tf, v in manifest["timeframes"].items()
        },
        "rules": manifest["rules"],
    }
    return json.dumps(compact, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser()
    p.add_argument("--asset", default="ALL")
    p.add_argument("--force-refresh", action="store_true")
    p.add_argument("--verify", action="store_true")
    args = p.parse_args()

    if args.asset.upper() == "ALL":
        result = ensure_all() if not args.verify else {
            "ok": all(verify_contract(a).get("ok") for a in SYMBOLS),
            "assets": {a: verify_contract(a) for a in SYMBOLS},
        }
    else:
        asset = args.asset.upper()
        if args.force_refresh:
            try:
                build_contract(asset, force_refresh=True)
            except Exception as exc:
                result = {"ok": False, "asset": asset, "error": f"{type(exc).__name__}: {exc}"}
            else:
                result = ensure_contract(asset)
        else:
            result = verify_contract(asset) if args.verify else ensure_contract(asset)

    print(json.dumps(result, indent=2, ensure_ascii=False, default=str))
    raise SystemExit(0 if result.get("ok") else 2)

[executed on device: WIN-31RCI8K7JR2 (dfb74cc6-deae-45bc-8c9d-634f7d1202b2)]