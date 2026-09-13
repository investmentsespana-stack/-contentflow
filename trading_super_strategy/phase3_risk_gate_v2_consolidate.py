"""Consolidate RR-sharded Phase 3 Risk Gate V2 evidence.

No market data is queried here. Candidate metrics come from independent RR shards;
CSCV-style PBO is then recomputed across the complete frozen symbol pool exactly
once, preserving the original Phase 3 V2 approval logic.
"""

from __future__ import annotations

import json
from pathlib import Path

import phase3_risk_gate_v2 as v2
from phase3_multiyear_validation import freeze_exact_intersection


def main() -> None:
    symbol = "ES.v.0"
    shard_dir = Path("phase3_risk_gate_v2_shards")
    files = sorted(shard_dir.glob("rr_*.json"))
    if not files:
        raise SystemExit("No Phase 3 V2 RR shard files found")

    results = []
    rows_downloaded = 0
    quarters = []
    for path in files:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if payload.get("symbol") != symbol:
            raise SystemExit(f"Unexpected symbol in {path}: {payload.get('symbol')}")
        rows_downloaded = max(rows_downloaded, int(payload.get("rows_downloaded", 0)))
        if payload.get("quarters"):
            if quarters and quarters != payload["quarters"]:
                raise SystemExit(f"Quarter mismatch in shard {path}")
            quarters = payload["quarters"]
        results.extend(payload.get("candidates", []))

    frozen = freeze_exact_intersection(symbol)
    expected_keys = {v2.candidate_key(row) for row in frozen}
    actual_keys = {row["candidate_key"] for row in results}
    if actual_keys != expected_keys:
        missing = sorted(expected_keys - actual_keys)
        extra = sorted(actual_keys - expected_keys)
        raise SystemExit(
            f"Incomplete sharded pool: expected={len(expected_keys)} actual={len(actual_keys)} "
            f"missing={missing[:5]} extra={extra[:5]}"
        )

    results.sort(key=lambda row: int(row.get("global_frozen_index", 10**9)))
    if not quarters:
        quarters = sorted(next(iter(results))["quarter_total_r"].keys())

    performance_matrix = [
        [float(row["quarter_total_r"].get(quarter, 0.0)) for row in results]
        for quarter in quarters
    ]
    pbo = v2.cscv_pbo(performance_matrix)
    pbo_pass = bool(pbo.get("available")) and pbo.get("pbo", 1.0) <= v2.PBO_MAX

    for row in results:
        row["symbol_pool_pbo"] = pbo
        row["pbo_pass"] = pbo_pass
        row["phase3_v2_pass"] = (
            bool(row["core_edge_pass"])
            and bool(row["risk_gate_v2_pass"])
            and bool(row["selection_bias_pass"])
            and pbo_pass
        )

    survivors = [row for row in results if row["phase3_v2_pass"]]
    risk_survivors = [
        row for row in results if row["core_edge_pass"] and row["risk_gate_v2_pass"]
    ]
    core_survivors = [row for row in results if row["core_edge_pass"]]
    survivors.sort(
        key=lambda row: (
            row["worst_block_p05_total_r"],
            row["baseline"]["expectancy_r"],
            -row["worst_primary_ruin_probability"],
        ),
        reverse=True,
    )

    out = Path("phase3_risk_gate_v2_output")
    out.mkdir(exist_ok=True)
    summary = {
        "phase": "3_RISK_GATE_V2",
        "execution_mode": "rr_sharded_checkpointed",
        "symbol": symbol,
        "frozen_candidates": len(frozen),
        "validation_start": v2.VALIDATION_START,
        "validation_end": v2.VALIDATION_END,
        "reserved_untouched_holdout": "2020-01-02/2022-08-31",
        "rows_downloaded": rows_downloaded,
        "block_lengths": list(v2.BLOCK_LENGTHS),
        "monte_carlo_iterations": v2.MC_ITERATIONS,
        "capital_drawdown_budget": v2.CAPITAL_DD_BUDGET,
        "risk_profiles": v2.RISK_PROFILES,
        "primary_risk_profile": v2.PRIMARY_RISK_PROFILE,
        "max_ruin_probability": v2.MAX_RUIN_PROB,
        "dsr_threshold": v2.DSR_THRESHOLD,
        "survivor_pool_trials_for_dsr": v2.SURVIVOR_POOL_TRIALS,
        "full_search_trials_upper_bound": v2.FULL_SEARCH_TRIAL_UPPER_BOUND,
        "symbol_pool_pbo": pbo,
        "pbo_pass": pbo_pass,
        "core_edge_survivors": len(core_survivors),
        "core_plus_risk_v2_survivors": len(risk_survivors),
        "phase3_v2_survivors": len(survivors),
        "phase3_v2_sub1r_survivors": sum(1 for row in survivors if float(row["rr"]) < 1.0),
        "top_survivors": survivors[:25],
        "notes": [
            "Compute was sharded by RR only to avoid hosted-runner interruption; statistical gates are unchanged.",
            "V2 removes the fixed 8R hard-ruin gate from confirmatory approval.",
            "Ruin is evaluated as capital drawdown under explicit risk-per-1R profiles.",
            "Moving-block bootstrap preserves local trade dependence better than IID resampling.",
            "DSR is reported against the 165 frozen survivor pool and full-search upper bound.",
            "CSCV-style PBO is recomputed here across the complete frozen ES candidate pool.",
            "The 2020-01-02/2022-08-31 holdout is not queried or used here.",
            "Live money remains disabled.",
        ],
    }

    (out / "phase3_risk_gate_v2_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    (out / "phase3_risk_gate_v2_all_candidates.json").write_text(
        json.dumps(results, indent=2), encoding="utf-8"
    )
    (out / "phase3_risk_gate_v2_survivors.json").write_text(
        json.dumps(survivors, indent=2), encoding="utf-8"
    )

    print("PHASE3_RISK_GATE_V2_SHARDED_OK", flush=True)
    print(
        json.dumps(
            {
                "symbol": symbol,
                "frozen_candidates": len(frozen),
                "core_edge_survivors": len(core_survivors),
                "core_plus_risk_v2_survivors": len(risk_survivors),
                "phase3_v2_survivors": len(survivors),
                "pbo": pbo,
            },
            indent=2,
        ),
        flush=True,
    )


if __name__ == "__main__":
    main()
