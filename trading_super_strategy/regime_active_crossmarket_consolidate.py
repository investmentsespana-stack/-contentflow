"""Consolidate frozen ACTIVE_RESEARCH robustness audits across ES/RTY/YM/NQ."""

from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path


def main() -> None:
    src = Path("active_robustness_inputs")
    files = sorted(src.glob("active_robustness_*.json"))
    if not files:
        raise SystemExit("No active robustness market outputs found")

    markets = []
    all_candidates = []
    for path in files:
        payload = json.loads(path.read_text(encoding="utf-8"))
        summary = payload["summary"]
        candidates = payload["candidates"]
        markets.append(summary)
        all_candidates.extend(candidates)

    survivors = [r for r in all_candidates if r.get("robustness_pass")]
    pre_pbo = [r for r in all_candidates if r.get("candidate_robustness_pass_pre_pbo")]

    fail_counts = Counter()
    for row in all_candidates:
        for reason in row.get("candidate_fail_reasons", []):
            fail_counts[reason] += 1

    family_stats = defaultdict(lambda: {"selected": 0, "pre_pbo": 0, "final": 0, "markets": set()})
    for row in all_candidates:
        family = "+".join(row.get("members", []))
        slot = family_stats[family]
        slot["selected"] += 1
        slot["markets"].add(row["symbol"])
        if row.get("candidate_robustness_pass_pre_pbo"):
            slot["pre_pbo"] += 1
        if row.get("robustness_pass"):
            slot["final"] += 1

    families = []
    for family, slot in family_stats.items():
        families.append({
            "family": family,
            "selected": slot["selected"],
            "pre_pbo_survivors": slot["pre_pbo"],
            "final_survivors": slot["final"],
            "markets": sorted(slot["markets"]),
        })
    families.sort(key=lambda x: (x["final_survivors"], x["pre_pbo_survivors"], x["selected"]), reverse=True)

    summary = {
        "audit": "REGIME_ACTIVE_ROBUSTNESS_CROSSMARKET_V1",
        "markets": markets,
        "total_active_candidates_frozen": len(all_candidates),
        "total_pre_pbo_robust_survivors": len(pre_pbo),
        "total_final_robust_survivors": len(survivors),
        "fail_reason_counts": dict(fail_counts.most_common()),
        "family_summary": families,
        "survivor_keys": [
            {
                "symbol": r["symbol"],
                "candidate_key": r["candidate_key"],
                "direction": r["direction"],
                "members": r["members"],
                "rr": r["rr"],
                "context": r["context"],
            }
            for r in survivors
        ],
        "reserved_untouched_holdout": "2020-01-02/2022-08-31",
        "decision_note": "This audit reuses the confirmatory window and therefore cannot authorize paper/live. Survivors, if any, require a genuinely independent next test before the sealed final holdout is considered.",
        "live_money": False,
    }

    out = Path("active_robustness_crossmarket_output")
    out.mkdir(exist_ok=True)
    (out / "active_robustness_crossmarket_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    (out / "active_robustness_crossmarket_candidates.json").write_text(
        json.dumps(all_candidates, indent=2), encoding="utf-8"
    )
    print("REGIME_ACTIVE_CROSSMARKET_OK", flush=True)
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
