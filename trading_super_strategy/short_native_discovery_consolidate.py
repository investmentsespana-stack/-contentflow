"""Cross-market consolidation for SHORT native asymmetric discovery V1.

Selection/freeze uses discovery evidence only. No confirmatory or holdout data is read.
Up to five candidates per market/family are frozen for the NEXT confirmatory stage.
"""
from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path

IN = Path("short_native_inputs")
OUT = Path("short_native_consolidated_output")
MAX_PER_MARKET_FAMILY = 5


def main():
    payloads = []
    for path in sorted(IN.rglob("short_native_discovery_*.json")):
        if path.name.endswith("_summary.json"):
            continue
        payloads.append(json.loads(path.read_text(encoding="utf-8")))
    if not payloads:
        raise SystemExit("No SHORT native discovery artifacts found")

    summaries = [p["summary"] for p in payloads]
    all_survivors = [r for p in payloads for r in p.get("survivors", [])]
    grouped = defaultdict(list)
    for row in all_survivors:
        grouped[(row["symbol"], row["family"])].append(row)

    frozen = []
    group_report = {}
    for key, rows in sorted(grouped.items()):
        rows.sort(key=lambda r: (
            r["late_half"]["expectancy_r"],
            r["moving_block_mc_2x_p05_total_r"],
            r["cost_stress_2x"]["total_r"],
            -r["baseline"]["max_drawdown_r"],
        ), reverse=True)
        selected = rows[:MAX_PER_MARKET_FAMILY]
        frozen.extend(selected)
        group_report[f"{key[0]}|{key[1]}"] = {
            "discovery_survivors": len(rows),
            "frozen_for_confirmatory": len(selected),
            "frozen_ids": [r["candidate_key"] for r in selected],
        }

    summary = {
        "phase": "SHORT_NATIVE_DISCOVERY_CROSSMARKET_V1",
        "markets": [s["symbol"] for s in summaries],
        "tested_candidates": sum(int(s["tested_candidates"]) for s in summaries),
        "discovery_survivors": len(all_survivors),
        "frozen_for_confirmatory": len(frozen),
        "freeze_rule": "Up to 5 per market/family, ranked only on preregistered discovery metrics: late-half expectancy, moving-block MC 2x-cost p05, 2x-cost total R, then lower baseline drawdown.",
        "groups": group_report,
        "next_stage": "Confirm frozen candidates on 2022-09-01..2025-09-24 without new search or retuning.",
        "guardrails": [
            "2018-2019 is not used for candidate selection or retuning.",
            "2020-01-02..2022-08-31 remains sealed.",
            "No live-money authorization.",
        ],
    }
    OUT.mkdir(exist_ok=True)
    (OUT / "short_native_crossmarket_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    (OUT / "short_native_frozen_candidates.json").write_text(json.dumps(frozen, indent=2), encoding="utf-8")
    print("SHORT_NATIVE_CONSOLIDATE_OK")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
