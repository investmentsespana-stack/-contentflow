from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import re
import time
from datetime import date
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
from fastmcp import Client

DEFAULT_MCP_URL = "http://127.0.0.1:8900/mcp"
ROOT = Path(r"C:\Cygnus\VibeTrading")
EVIDENCE_ROOT = ROOT / "evidence"

ASSETS: dict[str, dict[str, str]] = {
    "CL": {
        "target": "CL=F",
        "market": "CME WTI Crude Oil futures (CL)",
        "timeframe": "1D",
        "objective": "discover diverse systematic WTI crude-oil strategies with real-data OOS and robustness evidence",
    },
    "ES": {
        "target": "ES=F",
        "market": "CME E-mini S&P 500 futures (ES)",
        "timeframe": "1D",
        "objective": "discover diverse systematic E-mini S&P 500 strategies with real-data OOS and robustness evidence",
    },
    "NQ": {
        "target": "NQ=F",
        "market": "CME E-mini Nasdaq-100 futures (NQ)",
        "timeframe": "1D",
        "objective": "discover diverse systematic E-mini Nasdaq-100 strategies with real-data OOS and robustness evidence",
    },
    "GC": {
        "target": "GC=F",
        "market": "COMEX Gold futures (GC)",
        "timeframe": "1D",
        "objective": "discover diverse systematic gold-futures strategies with real-data OOS and robustness evidence",
    },
    "DXY": {
        "target": "DX-Y.NYB",
        "market": "US Dollar Index / ICE Dollar Index proxy (DXY/DX)",
        "timeframe": "1D",
        "objective": "discover diverse systematic US Dollar Index strategies with real-data OOS and robustness evidence",
    },
}
ALIASES = {"DX": "DXY"}
FORBIDDEN_TOOL_NAMES = {"bash", "shell", "terminal", "exec", "run_command"}
FORBIDDEN_TOOL_PREFIXES = ("trading_",)


def _normalize_asset(value: str) -> str:
    asset = str(value or "").strip().upper()
    asset = ALIASES.get(asset, asset)
    if asset not in ASSETS:
        raise ValueError("ASSET_NOT_ALLOWED:" + asset)
    return asset


def _safe_run_id(value: str) -> str:
    run_id = str(value or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9._:-]{1,160}", run_id):
        raise ValueError("INVALID_RUN_ID")
    return run_id


def _text(result: Any) -> str:
    if result is None:
        return ""
    if isinstance(result, str):
        return result
    data = getattr(result, "data", None)
    if data is not None:
        try:
            return json.dumps(data, default=str, ensure_ascii=False)
        except Exception:
            return str(data)
    content = getattr(result, "content", None)
    if content is not None:
        try:
            return "\n".join(
                str(getattr(item, "text", None) or getattr(item, "data", None) or item)
                for item in content
            )
        except Exception:
            pass
    return str(result)


def _decode_json_layers(value: Any, max_layers: int = 6) -> Any:
    current = value
    for _ in range(max_layers):
        if isinstance(current, (dict, list)):
            return current
        if not isinstance(current, str):
            return current
        stripped = current.strip()
        if not stripped:
            return stripped
        try:
            decoded = json.loads(stripped)
        except Exception:
            return current
        if decoded == current:
            return decoded
        current = decoded
    return current


async def _call(client: Client, name: str, args: dict[str, Any]) -> dict[str, Any]:
    try:
        result = await client.call_tool(name, args)
        ok = not bool(getattr(result, "is_error", False))
        raw = _text(result)
        parsed = _decode_json_layers(raw)
        return {"ok": ok, "tool": name, "result": parsed, "excerpt": raw[:4000]}
    except Exception as exc:
        return {"ok": False, "tool": name, "error": f"{type(exc).__name__}: {exc}"}


def _pick_key(row: dict[str, Any], names: tuple[str, ...]) -> str | None:
    keys = {str(k).lower(): str(k) for k in row}
    for name in names:
        if name.lower() in keys:
            return keys[name.lower()]
    return None


def _records_to_frame(payload: Any, target: str) -> tuple[pd.DataFrame, dict[str, Any]]:
    payload = _decode_json_layers(payload)
    if not isinstance(payload, dict):
        raise RuntimeError(f"MARKET_DATA_BAD_SHAPE:{type(payload).__name__}")
    if payload.get("ok") is False:
        raise RuntimeError(f"MARKET_DATA_ERROR:{payload.get('error')}")
    rows = payload.get(target)
    if not isinstance(rows, list) or len(rows) < 150:
        unresolved = payload.get("_unresolved")
        raise RuntimeError(f"MARKET_DATA_INSUFFICIENT:{target}:rows={0 if not isinstance(rows, list) else len(rows)} unresolved={unresolved}")
    if not isinstance(rows[0], dict):
        raise RuntimeError("MARKET_DATA_ROWS_NOT_OBJECTS")

    sample = rows[0]
    date_key = _pick_key(sample, ("date", "datetime", "timestamp", "time", "index"))
    open_key = _pick_key(sample, ("open",))
    high_key = _pick_key(sample, ("high",))
    low_key = _pick_key(sample, ("low",))
    close_key = _pick_key(sample, ("close", "adj close", "adj_close"))
    volume_key = _pick_key(sample, ("volume",))
    if not close_key:
        raise RuntimeError(f"MARKET_DATA_CLOSE_MISSING:keys={list(sample)[:20]}")

    df = pd.DataFrame(rows)
    out = pd.DataFrame(index=df.index)
    if date_key:
        out["date"] = pd.to_datetime(df[date_key], errors="coerce", utc=True)
    else:
        out["date"] = pd.RangeIndex(len(df))
    for std, key in (("open", open_key), ("high", high_key), ("low", low_key), ("close", close_key), ("volume", volume_key)):
        if key:
            out[std] = pd.to_numeric(df[key], errors="coerce")
    if "open" not in out:
        out["open"] = out["close"]
    if "high" not in out:
        out["high"] = out[["open", "close"]].max(axis=1)
    if "low" not in out:
        out["low"] = out[["open", "close"]].min(axis=1)

    out = out.replace([np.inf, -np.inf], np.nan).dropna(subset=["close", "high", "low"])
    if date_key:
        out = out.dropna(subset=["date"]).sort_values("date")
    out = out.drop_duplicates(subset=["date"], keep="last").reset_index(drop=True)
    if len(out) < 150:
        raise RuntimeError(f"MARKET_DATA_INSUFFICIENT_AFTER_CLEAN:{len(out)}")

    provenance = payload.get("_provenance", {})
    prov = provenance.get(target, {}) if isinstance(provenance, dict) else {}
    return out, prov if isinstance(prov, dict) else {}


def _stateful_breakout(long_cond: pd.Series, short_cond: pd.Series, exit_cond: pd.Series | None = None) -> pd.Series:
    state = 0.0
    values: list[float] = []
    for i in range(len(long_cond)):
        if bool(long_cond.iloc[i]):
            state = 1.0
        elif bool(short_cond.iloc[i]):
            state = -1.0
        elif exit_cond is not None and bool(exit_cond.iloc[i]):
            state = 0.0
        values.append(state)
    return pd.Series(values, index=long_cond.index, dtype=float)


def _strategy_candidates(df: pd.DataFrame) -> dict[str, pd.Series]:
    close = df["close"]
    high = df["high"]
    low = df["low"]
    returns = close.pct_change()

    candidates: dict[str, pd.Series] = {}

    for fast, slow in ((10, 50), (20, 100), (50, 200)):
        f = close.rolling(fast, min_periods=fast).mean()
        s = close.rolling(slow, min_periods=slow).mean()
        candidates[f"trend_sma_{fast}_{slow}"] = pd.Series(np.sign(f - s), index=df.index).fillna(0.0)

    for lookback in (20, 60, 120):
        mom = close.pct_change(lookback)
        candidates[f"momentum_{lookback}"] = pd.Series(np.sign(mom), index=df.index).fillna(0.0)

    for lookback in (20, 55):
        hh = high.rolling(lookback, min_periods=lookback).max().shift(1)
        ll = low.rolling(lookback, min_periods=lookback).min().shift(1)
        candidates[f"donchian_{lookback}"] = _stateful_breakout(close > hh, close < ll)

    for lookback, threshold in ((10, 1.5), (20, 1.5), (40, 2.0)):
        ma = close.rolling(lookback, min_periods=lookback).mean()
        sd = close.rolling(lookback, min_periods=lookback).std(ddof=0).replace(0, np.nan)
        z = (close - ma) / sd
        candidates[f"meanrev_z_{lookback}_{threshold}"] = _stateful_breakout(
            z < -threshold,
            z > threshold,
            z.abs() < 0.35,
        )

    vol20 = returns.rolling(20, min_periods=20).std(ddof=0)
    vol_med = vol20.rolling(126, min_periods=60).median()
    trend = pd.Series(np.sign(close.rolling(20).mean() - close.rolling(100).mean()), index=df.index).fillna(0.0)
    candidates["trend_lowvol"] = trend.where(vol20 <= vol_med, 0.0).fillna(0.0)
    candidates["trend_highvol"] = trend.where(vol20 > vol_med, 0.0).fillna(0.0)

    return candidates


def _max_drawdown(r: pd.Series) -> float:
    r = r.dropna().clip(lower=-0.999999)
    if r.empty:
        return 0.0
    eq = (1.0 + r).cumprod()
    dd = eq / eq.cummax() - 1.0
    return float(dd.min())


def _perf(r: pd.Series) -> dict[str, float]:
    r = r.replace([np.inf, -np.inf], np.nan).dropna().clip(lower=-0.999999)
    n = int(len(r))
    if n == 0:
        return {
            "n": 0, "total_return": 0.0, "annualized_return": 0.0,
            "annualized_vol": 0.0, "sharpe": 0.0, "max_drawdown": 0.0,
            "positive_day_rate": 0.0,
        }
    total = float((1.0 + r).prod() - 1.0)
    ann = float((1.0 + total) ** (252.0 / n) - 1.0) if total > -1.0 else -1.0
    vol = float(r.std(ddof=0) * math.sqrt(252.0))
    sharpe = float(r.mean() / r.std(ddof=0) * math.sqrt(252.0)) if float(r.std(ddof=0)) > 0 else 0.0
    return {
        "n": n,
        "total_return": total,
        "annualized_return": ann,
        "annualized_vol": vol,
        "sharpe": sharpe,
        "max_drawdown": _max_drawdown(r),
        "positive_day_rate": float((r > 0).mean()),
    }


def _bootstrap_mc(r: pd.Series, seed: int, sims: int = 500, ruin_dd: float = -0.30) -> dict[str, float]:
    arr = r.replace([np.inf, -np.inf], np.nan).dropna().clip(lower=-0.999999).to_numpy(dtype=float)
    if len(arr) < 30:
        return {"simulations": 0, "profitable_probability": 0.0, "ruin_probability": 1.0, "p05_total_return": -1.0, "p95_max_drawdown": -1.0}
    rng = np.random.default_rng(seed)
    samples = rng.choice(arr, size=(sims, len(arr)), replace=True)
    eq = np.cumprod(1.0 + samples, axis=1)
    peak = np.maximum.accumulate(eq, axis=1)
    dd = eq / peak - 1.0
    totals = eq[:, -1] - 1.0
    max_dd = dd.min(axis=1)
    return {
        "simulations": int(sims),
        "profitable_probability": float(np.mean(totals > 0)),
        "ruin_probability": float(np.mean(max_dd <= ruin_dd)),
        "p05_total_return": float(np.quantile(totals, 0.05)),
        "p95_max_drawdown": float(np.quantile(max_dd, 0.05)),
    }


def _evaluate_candidate(name: str, raw_signal: pd.Series, close_returns: pd.Series, split_idx: int, seed: int) -> tuple[dict[str, Any], pd.Series]:
    signal = raw_signal.replace([np.inf, -np.inf], np.nan).fillna(0.0).clip(-1.0, 1.0)
    position = signal.shift(1).fillna(0.0)
    turnover = position.diff().abs().fillna(position.abs())

    def net(cost_bps: float) -> pd.Series:
        return (position * close_returns.fillna(0.0) - turnover * (cost_bps / 10000.0)).fillna(0.0)

    base = net(2.0)
    stress5 = net(5.0)
    stress10 = net(10.0)
    full = _perf(base)
    oos = _perf(base.iloc[split_idx:])
    stress5_oos = _perf(stress5.iloc[split_idx:])
    stress10_oos = _perf(stress10.iloc[split_idx:])
    mc = _bootstrap_mc(base.iloc[split_idx:], seed=seed)
    trades = int((turnover > 0).sum())

    reasons: list[str] = []
    if trades < 10:
        reasons.append("too_few_trades")
    if oos["total_return"] <= 0:
        reasons.append("oos_not_profitable")
    if oos["sharpe"] < 0.50:
        reasons.append("oos_sharpe_below_0.50")
    if stress5_oos["total_return"] <= 0:
        reasons.append("fails_5bps_cost_stress")
    if full["max_drawdown"] <= -0.40:
        reasons.append("full_drawdown_worse_than_40pct")
    if mc["profitable_probability"] < 0.65:
        reasons.append("bootstrap_profitability_below_65pct")
    if mc["ruin_probability"] > 0.25:
        reasons.append("bootstrap_ruin_above_25pct")

    passed = not reasons
    metrics = {
        "name": name,
        "passed_screen": passed,
        "screen_reasons": reasons,
        "trades_proxy": trades,
        "baseline_cost_bps_per_unit_turnover": 2.0,
        "full": full,
        "oos_30pct": oos,
        "oos_cost_5bps": stress5_oos,
        "oos_cost_10bps": stress10_oos,
        "bootstrap_oos": mc,
    }
    return metrics, base


def _diversify(results: list[dict[str, Any]], return_map: dict[str, pd.Series], split_idx: int) -> tuple[list[str], list[dict[str, Any]]]:
    passed = [r for r in results if r.get("passed_screen")]
    passed.sort(key=lambda x: float(x["oos_30pct"]["sharpe"]), reverse=True)
    selected: list[str] = []
    duplicate_notes: list[dict[str, Any]] = []
    for row in passed:
        name = str(row["name"])
        keep = True
        for existing in selected:
            a = return_map[name].iloc[split_idx:]
            b = return_map[existing].iloc[split_idx:]
            corr = float(a.corr(b)) if len(a) and len(b) else 0.0
            if math.isfinite(corr) and abs(corr) >= 0.85:
                duplicate_notes.append({"candidate": name, "duplicate_of": existing, "oos_return_correlation": corr})
                keep = False
                break
        if keep:
            selected.append(name)
    return selected, duplicate_notes


async def _deterministic_research(asset: str, mcp_url: str) -> dict[str, Any]:
    meta = ASSETS[asset]
    started = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    run_id = f"det-{asset.lower()}-{started.lower()}"

    evidence: dict[str, Any] = {
        "schema": "cygnus.vibe.asset_research.det.v1",
        "run_id": run_id,
        "asset": asset,
        "target": meta["target"],
        "market": meta["market"],
        "timeframe": meta["timeframe"],
        "status": "RUNNING",
        "mode": "RESEARCH_ONLY",
        "live": False,
        "shell_tools": False,
        "broker_execution": False,
        "execution_mode": "vibe_market_data_plus_deterministic_screen",
        "started_at_utc": started,
        "method_notes": [
            "Daily-bar research screen only; not production certification.",
            "Signals are shifted one bar to avoid same-bar lookahead.",
            "Costs are bps-per-unit-turnover proxies, not contract-specific commission/tick modeling.",
            "Final deployment still requires contract-level futures validation and independent robustness.",
        ],
    }

    async with Client(mcp_url) as client:
        await client.ping()
        tools = await client.list_tools()
        names = sorted(str(getattr(t, "name", "") or "") for t in tools)
        dangerous = [
            name for name in names
            if name.lower() in FORBIDDEN_TOOL_NAMES
            or any(name.lower().startswith(p) for p in FORBIDDEN_TOOL_PREFIXES)
            or "shell" in name.lower()
            or "terminal" in name.lower()
        ]
        if dangerous:
            raise RuntimeError("FORBIDDEN_MCP_TOOLS_EXPOSED:" + ",".join(dangerous))

        evidence["mcp_tool_count"] = len(names)
        evidence["mcp_ping"] = "PASS"

        goal = await _call(client, "start_research_goal", {
            "objective": meta["objective"] + ". Deterministic fallback: data + systematic screen without LLM workers.",
            "session_id": run_id,
            "criteria": [
                "Use real Vibe market data with provenance.",
                "Test multiple structurally different strategy families.",
                "Use chronological 70/30 OOS.",
                "Stress costs and bootstrap OOS returns.",
                "Filter highly correlated survivors.",
                "Never place orders or enable live trading.",
            ],
            "ui_summary": f"Cygnus deterministic {asset} strategy screen",
            "protocol": "thesis_review",
            "risk_tier": "research_general",
            "turn_budget": 10,
            "time_budget_seconds": 1800,
        })
        evidence["research_goal_call"] = goal

        market = await _call(client, "get_market_data", {
            "codes": [meta["target"]],
            "start_date": "2015-01-01",
            "end_date": date.today().isoformat(),
            "source": "auto",
            "interval": meta["timeframe"],
            "max_rows": 0,
        })
        evidence["market_data_call_ok"] = market.get("ok")
        if not market.get("ok"):
            evidence["status"] = "BLOCKED_MARKET_DATA"
            evidence["market_data_error"] = market
            return evidence

        df, provenance = _records_to_frame(market.get("result"), meta["target"])
        evidence["data"] = {
            "rows": int(len(df)),
            "first_date": str(df["date"].iloc[0]),
            "last_date": str(df["date"].iloc[-1]),
            "provenance": provenance,
        }

        close_returns = df["close"].pct_change().fillna(0.0)
        split_idx = max(1, int(len(df) * 0.70))
        candidates = _strategy_candidates(df)
        results: list[dict[str, Any]] = []
        return_map: dict[str, pd.Series] = {}
        for i, (name, sig) in enumerate(candidates.items()):
            row, series = _evaluate_candidate(name, sig, close_returns, split_idx, seed=1000 + i)
            results.append(row)
            return_map[name] = series

        selected, duplicates = _diversify(results, return_map, split_idx)
        diagnostics = sorted(
            results,
            key=lambda x: float(x["oos_30pct"]["sharpe"]),
            reverse=True,
        )[:5]

        evidence["candidate_count"] = len(results)
        evidence["screen_pass_count_before_diversity"] = sum(1 for r in results if r["passed_screen"])
        evidence["diversified_survivors"] = selected
        evidence["duplicate_rejections"] = duplicates
        evidence["candidates"] = results
        evidence["top_diagnostics_by_oos_sharpe"] = [
            {
                "name": r["name"],
                "passed_screen": r["passed_screen"],
                "oos_sharpe": r["oos_30pct"]["sharpe"],
                "oos_total_return": r["oos_30pct"]["total_return"],
                "max_drawdown": r["full"]["max_drawdown"],
                "reasons": r["screen_reasons"],
            }
            for r in diagnostics
        ]
        evidence["status"] = "COMPLETED_DETERMINISTIC"
        evidence["completed_at_utc"] = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        return evidence


def _run_evidence_path(run_id: str) -> Path:
    return EVIDENCE_ROOT / f"asset-research-run-{run_id}.json"


async def start(asset: str, mcp_url: str) -> dict[str, Any]:
    asset = _normalize_asset(asset)
    return await _deterministic_research(asset, mcp_url)


async def inspect(action: str, run_id: str) -> dict[str, Any]:
    run_id = _safe_run_id(run_id)
    path = _run_evidence_path(run_id)
    if not path.is_file():
        return {
            "schema": "cygnus.vibe.asset_research.det.v1",
            "action": action,
            "run_id": run_id,
            "status": "NOT_FOUND",
            "mode": "RESEARCH_ONLY",
            "live": False,
            "shell_tools": False,
            "broker_execution": False,
        }
    data = json.loads(path.read_text(encoding="utf-8"))
    return {
        "schema": "cygnus.vibe.asset_research.det.v1",
        "action": action,
        "run_id": run_id,
        "status": data.get("status"),
        "mode": "RESEARCH_ONLY",
        "live": False,
        "shell_tools": False,
        "broker_execution": False,
        "run": data,
        "checked_at_utc": time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()),
    }


async def run(args: argparse.Namespace) -> int:
    EVIDENCE_ROOT.mkdir(parents=True, exist_ok=True)

    if args.action == "start":
        evidence = await start(args.asset, args.mcp_url)
        run_id = str(evidence.get("run_id") or "")
        if run_id:
            _run_evidence_path(run_id).write_text(
                json.dumps(evidence, indent=2, ensure_ascii=False, default=str),
                encoding="utf-8",
            )
        asset = _normalize_asset(args.asset)
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        path = EVIDENCE_ROOT / f"asset-research-{asset.lower()}-{stamp}.json"
        path.write_text(json.dumps(evidence, indent=2, ensure_ascii=False, default=str), encoding="utf-8")

        print("VIBE_ASSET_RESEARCH_START")
        print(f"ASSET={asset}")
        # Bridge v6 expects STARTED. The evidence status records whether the deterministic
        # research completed or was blocked.
        bridge_status = "STARTED" if evidence.get("status") == "COMPLETED_DETERMINISTIC" else "BLOCKED"
        print(f"STATUS={bridge_status}")
        print(f"RUN_ID={run_id}")
        print(f"RESEARCH_STATUS={evidence.get('status')}")
        print(f"CANDIDATES={evidence.get('candidate_count', 0)}")
        print(f"SURVIVORS={len(evidence.get('diversified_survivors', []))}")
        print("MODE=RESEARCH_ONLY")
        print("LIVE=false")
        print("SHELL_TOOLS=false")
        print("BROKER_EXECUTION=false")
        print(f"EVIDENCE={path}")
        return 0 if evidence.get("status") == "COMPLETED_DETERMINISTIC" else 2

    if not args.run_id:
        raise ValueError("RUN_ID_REQUIRED")
    evidence = await inspect(args.action, args.run_id)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    path = EVIDENCE_ROOT / f"asset-research-{args.action}-{stamp}.json"
    path.write_text(json.dumps(evidence, indent=2, ensure_ascii=False, default=str), encoding="utf-8")

    print("VIBE_ASSET_RESEARCH_CHECK")
    print(f"ACTION={args.action}")
    print(f"RUN_ID={args.run_id}")
    print(f"RESEARCH_STATUS={evidence.get('status')}")
    print("MODE=RESEARCH_ONLY")
    print("LIVE=false")
    print("SHELL_TOOLS=false")
    print("BROKER_EXECUTION=false")
    print(f"EVIDENCE={path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", choices=("start", "status", "result"), required=True)
    parser.add_argument("--asset", default="")
    parser.add_argument("--run-id", default="")
    parser.add_argument("--mcp-url", default=DEFAULT_MCP_URL)
    args = parser.parse_args()
    try:
        return asyncio.run(run(args))
    except Exception as exc:
        print(f"VIBE_ASSET_RESEARCH_FAIL: {type(exc).__name__}: {exc}", file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
