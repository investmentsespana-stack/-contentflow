"""Diagnostic autopsy of the frozen LONG portfolios on consumed 2018-2019 evidence.

This is NOT a tuning or selection stage. It replays the exact frozen LONG components
and attributes the 2018 vs 2019 deterioration by component, market, family, session,
RR and frozen context. No weights, rules, thresholds or candidates are changed.
The sealed 2020-01-02..2022-08-31 holdout is never read.
"""
from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path

from long_portfolio_independent_validation import (
    BASELINE_COST_R,
    TARGET_IDS,
    build_features,
    metrics,
    replay_component,
)
from robustness_engine import max_drawdown_r

SRC = Path("autopsy_inputs/directional_portfolios.json")
CACHE = Path("autopsy_cache")
OUT = Path("long_2019_autopsy_output")


def family(comp):
    return "+".join(comp.get("members", []))


def day_value(replay, day):
    return float(replay["gross"].get(day, 0.0)) - BASELINE_COST_R * float(replay["cost_units"].get(day, 0.0))


def group_totals(component_rows, key_fn):
    out = defaultdict(lambda: {"2018": 0.0, "2019": 0.0, "all": 0.0})
    for row in component_rows:
        key = str(key_fn(row))
        for y in ("2018", "2019"):
            out[key][y] += float(row["weighted_year_r"].get(y, 0.0))
        out[key]["all"] += float(row["weighted_total_r"])
    return dict(sorted(out.items()))


def main():
    frozen = json.loads(SRC.read_text(encoding="utf-8"))
    portfolios = [p for p in frozen if p.get("portfolio_id") in TARGET_IDS]
    if {p["portfolio_id"] for p in portfolios} != TARGET_IDS:
        raise SystemExit("Missing one or more frozen LONG target portfolios")

    unique = {}
    for p in portfolios:
        for comp in p["components"]:
            unique[comp["candidate_key"]] = comp

    by_symbol = defaultdict(dict)
    for key, comp in unique.items():
        by_symbol[comp["symbol"]][key] = comp

    replay = {}
    for symbol, comps in by_symbol.items():
        path = CACHE / f"{symbol}.parquet"
        if not path.exists():
            raise SystemExit(f"Missing consumed-evidence checkpoint {path}")
        g = build_features(path)
        for key, comp in comps.items():
            replay[key] = replay_component(g, comp)

    component_diagnostics = []
    for key, comp in sorted(unique.items()):
        x = replay[key]
        dates = sorted(set(x["gross"]) | set(x["cost_units"]))
        vals = [day_value(x, d) for d in dates]
        years = defaultdict(list)
        quarters = defaultdict(float)
        for d, v in zip(dates, vals):
            years[d[:4]].append(v)
            q = (int(d[5:7]) - 1) // 3 + 1
            quarters[f"{d[:4]}Q{q}"] += v
        component_diagnostics.append({
            "candidate_key": key,
            "symbol": comp["symbol"],
            "family": family(comp),
            "members": comp["members"],
            "rr": float(comp["rr"]),
            "session": comp["context"]["session"],
            "context": comp["context"],
            "trades": int(x["trades"]),
            "baseline": metrics(vals),
            "year_r": {y: float(sum(vs)) for y, vs in sorted(years.items())},
            "quarter_r": dict(sorted(quarters.items())),
            "deterioration_2019_minus_2018": float(sum(years.get("2019", [])) - sum(years.get("2018", []))),
        })

    portfolio_reports = []
    for p in sorted(portfolios, key=lambda z: z["portfolio_id"]):
        all_dates = sorted({d for c in p["components"] for d in replay[c["candidate_key"]]["gross"]} |
                           {d for c in p["components"] for d in replay[c["candidate_key"]]["cost_units"]})
        full_daily = {d: 0.0 for d in all_dates}
        component_rows = []
        for comp in p["components"]:
            key = comp["candidate_key"]
            w = float(comp["weight"])
            x = replay[key]
            weighted_daily = {d: w * day_value(x, d) for d in all_dates}
            for d, v in weighted_daily.items():
                full_daily[d] += v
            yr = defaultdict(float)
            for d, v in weighted_daily.items():
                yr[d[:4]] += v
            component_rows.append({
                "candidate_key": key,
                "symbol": comp["symbol"],
                "family": family(comp),
                "rr": float(comp["rr"]),
                "session": comp["context"]["session"],
                "volatility_regime": comp["context"]["volatility_regime"],
                "trend_regime": comp["context"]["trend_regime"],
                "structure_regime": comp["context"]["structure_regime"],
                "weight": w,
                "weighted_total_r": float(sum(weighted_daily.values())),
                "weighted_year_r": dict(sorted(yr.items())),
                "weighted_deterioration_2019_minus_2018": float(yr.get("2019", 0.0) - yr.get("2018", 0.0)),
            })

        full_vals = [full_daily[d] for d in all_dates]
        full_metrics = metrics(full_vals)
        year_daily = defaultdict(list)
        quarter_r = defaultdict(float)
        for d, v in zip(all_dates, full_vals):
            year_daily[d[:4]].append(v)
            q = (int(d[5:7]) - 1) // 3 + 1
            quarter_r[f"{d[:4]}Q{q}"] += v

        loo = []
        for row in component_rows:
            key = row["candidate_key"]
            w = row["weight"]
            x = replay[key]
            reduced = [full_daily[d] - w * day_value(x, d) for d in all_dates]
            loo.append({
                "candidate_key": key,
                "symbol": row["symbol"],
                "family": row["family"],
                "session": row["session"],
                "rr": row["rr"],
                "diagnostic_total_r_without_component": float(sum(reduced)),
                "diagnostic_max_drawdown_r_without_component": float(max_drawdown_r(reduced)),
                "delta_total_r_vs_full": float(sum(reduced) - full_metrics["total_r"]),
                "delta_max_drawdown_r_vs_full": float(max_drawdown_r(reduced) - full_metrics["max_drawdown_r"]),
            })

        neg_2019 = [r for r in component_rows if float(r["weighted_year_r"].get("2019", 0.0)) < 0]
        pos_2019 = [r for r in component_rows if float(r["weighted_year_r"].get("2019", 0.0)) > 0]
        total_negative = abs(sum(float(r["weighted_year_r"].get("2019", 0.0)) for r in neg_2019))
        worst5 = sorted(neg_2019, key=lambda r: float(r["weighted_year_r"].get("2019", 0.0)))[:5]
        worst5_abs = abs(sum(float(r["weighted_year_r"].get("2019", 0.0)) for r in worst5))

        portfolio_reports.append({
            "portfolio_id": p["portfolio_id"],
            "scheme": p["scheme"],
            "baseline": full_metrics,
            "year_metrics": {y: metrics(vals) for y, vals in sorted(year_daily.items())},
            "quarter_r": dict(sorted(quarter_r.items())),
            "component_signs": {
                "2019_positive": len(pos_2019),
                "2019_negative": len(neg_2019),
                "2019_zero": len(component_rows) - len(pos_2019) - len(neg_2019),
            },
            "loss_concentration_2019": {
                "total_negative_component_contribution_r_abs": total_negative,
                "worst5_negative_contribution_r_abs": worst5_abs,
                "worst5_share_of_negative": (worst5_abs / total_negative) if total_negative else 0.0,
                "worst5": worst5,
            },
            "attribution": {
                "market": group_totals(component_rows, lambda r: r["symbol"]),
                "family": group_totals(component_rows, lambda r: r["family"]),
                "session": group_totals(component_rows, lambda r: r["session"]),
                "rr": group_totals(component_rows, lambda r: r["rr"]),
                "volatility_regime": group_totals(component_rows, lambda r: r["volatility_regime"]),
                "structure_regime": group_totals(component_rows, lambda r: r["structure_regime"]),
            },
            "weighted_components": sorted(component_rows, key=lambda r: r["weighted_deterioration_2019_minus_2018"]),
            "leave_one_out_diagnostic_only": sorted(loo, key=lambda r: r["delta_total_r_vs_full"], reverse=True),
        })

    negative_2019_components = sum(1 for r in component_diagnostics if float(r["year_r"].get("2019", 0.0)) < 0)
    positive_2019_components = sum(1 for r in component_diagnostics if float(r["year_r"].get("2019", 0.0)) > 0)
    summary = {
        "audit": "LONG_2019_AUTOPSY_V1",
        "purpose": "diagnosis_only_no_retuning",
        "source_frozen_portfolio_run": 34781565340,
        "source_consumed_independent_run": 34782842917,
        "unique_frozen_components": len(unique),
        "tested_portfolios": [p["portfolio_id"] for p in portfolios],
        "component_signs_2019_unweighted": {
            "positive": positive_2019_components,
            "negative": negative_2019_components,
            "zero": len(unique) - positive_2019_components - negative_2019_components,
        },
        "guardrails": [
            "2018-2019 is consumed validation evidence and is not used to retune rules, thresholds or weights.",
            "Leave-one-out results are diagnostic only and cannot authorize component removal or a new portfolio.",
            "2020-01-02 through 2022-08-31 remains sealed and unread.",
            "LIVE MONEY=false.",
        ],
    }

    OUT.mkdir(exist_ok=True)
    (OUT / "long_2019_autopsy.json").write_text(json.dumps({"summary": summary, "components": component_diagnostics, "portfolios": portfolio_reports}, indent=2), encoding="utf-8")
    (OUT / "long_2019_autopsy_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print("LONG_2019_AUTOPSY_OK")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
