"""Robustness audit for pre-registered directional portfolios.

Runs only after portfolio formation is frozen. Tests LONG and SHORT portfolios as
portfolios, not as individual strategies. Uses exact stored gross R and cost exposure,
so 1x/1.5x/2x cost stress is portfolio-consistent. Moving-block MC is run on the
2x-cost daily portfolio series. Holdout 2020-01-02..2022-08-31 stays sealed.
"""
from __future__ import annotations
import json, math, random
from collections import defaultdict
from pathlib import Path
import numpy as np
from phase3_multiyear_validation import BASELINE_COST_R
from phase3_risk_gate_v2 import cscv_pbo, deflated_sharpe_probability, sample_moving_blocks, percentile, capital_max_drawdown
from robustness_engine import max_drawdown_r

SRC = Path("directional_portfolio_output/directional_portfolios.json")
OUT = Path("directional_portfolio_robustness_output")
MC_ITER = 2000
BLOCKS = (5, 20)
RISK_FRACTION = 0.0025
DD_BUDGET = 0.10
PBO_MAX = 0.50


def pf(vals):
    gp = sum(x for x in vals if x > 0); gl = abs(sum(x for x in vals if x < 0))
    return gp / gl if gl > 0 else (float("inf") if gp > 0 else 0.0)


def metrics(vals):
    arr = [float(x) for x in vals]
    nz = sum(abs(x) > 1e-12 for x in arr)
    mu = float(np.mean(arr)) if arr else 0.0
    vol = float(np.std(arr)) if arr else 0.0
    return {"days": len(arr), "active_days": nz, "total_r": sum(arr), "mean_daily_r": mu,
            "profit_factor": pf(arr), "max_drawdown_r": max_drawdown_r(arr),
            "positive_day_rate": (sum(x > 0 for x in arr) / len(arr)) if arr else 0.0,
            "sharpe_annualized": (math.sqrt(252.0) * mu / vol) if vol > 0 else 0.0}


def mc(vals, block, seed):
    rng = random.Random(seed + block * 101)
    totals=[]; dds=[]; capital=[]; breach=0
    for _ in range(MC_ITER):
        path = sample_moving_blocks(vals, block, rng)
        totals.append(sum(path)); dds.append(max_drawdown_r(path))
        dd = capital_max_drawdown(path, RISK_FRACTION); capital.append(dd)
        breach += int(dd >= DD_BUDGET)
    return {"iterations": MC_ITER, "block_length": block,
            "p05_total_r": percentile(totals, .05), "median_total_r": percentile(totals, .50),
            "p95_max_drawdown_r": percentile(dds, .95), "p99_max_drawdown_r": percentile(dds, .99),
            "capital_drawdown_breach_probability": breach / MC_ITER,
            "p95_capital_max_drawdown": percentile(capital, .95), "p99_capital_max_drawdown": percentile(capital, .99)}


def main():
    portfolios = json.loads(SRC.read_text(encoding="utf-8"))
    if len(portfolios) != 8: raise SystemExit(f"Expected 8 frozen portfolios, got {len(portfolios)}")
    results=[]; quarters_by_direction=defaultdict(list); qlabels_by_direction={}
    for i,p in enumerate(portfolios,1):
        dates = sorted(set(p["daily_gross_r"]) | set(p["daily_cost_units"]))
        gross=[float(p["daily_gross_r"].get(d,0.0)) for d in dates]
        units=[float(p["daily_cost_units"].get(d,0.0)) for d in dates]
        base=[g - BASELINE_COST_R*u for g,u in zip(gross,units)]
        s15=[g - 1.5*BASELINE_COST_R*u for g,u in zip(gross,units)]
        s20=[g - 2.0*BASELINE_COST_R*u for g,u in zip(gross,units)]
        year_vals=defaultdict(list); quarter_vals=defaultdict(float)
        for d,v in zip(dates,base):
            year_vals[d[:4]].append(v); quarter=(int(d[5:7])-1)//3+1; quarter_vals[f"{d[:4]}Q{quarter}"] += v
        folds=[]
        for y in sorted(year_vals):
            m=metrics(year_vals[y]); m["year"]=int(y); folds.append(m)
        positive_fold_rate=sum(f["total_r"]>0 for f in folds)/len(folds) if folds else 0.0
        mcs=[mc(s20,b,9000+i) for b in BLOCKS]
        worst_p05=min(x["p05_total_r"] for x in mcs); worst_ruin=max(x["capital_drawdown_breach_probability"] for x in mcs)
        dsr8=deflated_sharpe_probability(base,8); dsr165=deflated_sharpe_probability(base,165)
        fail=[]
        bm=metrics(base); m20=metrics(s20)
        if bm["active_days"] < 60: fail.append("insufficient_active_days")
        if bm["total_r"] <= 0: fail.append("nonpositive_total_r")
        if bm["profit_factor"] <= 1.05: fail.append("profit_factor_le_1_05")
        if m20["total_r"] <= 0: fail.append("fails_2x_cost_stress")
        if len(folds) < 3: fail.append("insufficient_year_folds")
        if positive_fold_rate < .60: fail.append("unstable_year_folds")
        if worst_p05 <= 0: fail.append("dependent_mc_2x_p05_nonpositive")
        if worst_ruin > .01: fail.append("capital_aware_ruin_gt_1pct")
        if dsr8["probability"] < .95: fail.append("dsr_portfolio_set_below_095")
        row={"portfolio_id":p["portfolio_id"],"direction":p["direction"],"scheme":p["scheme"],
             "component_count":p["component_count"],"baseline":bm,"cost_stress_1_5x":metrics(s15),
             "cost_stress_2x":m20,"year_folds":folds,"positive_fold_rate":positive_fold_rate,
             "dependent_block_mc_2x_cost":mcs,"worst_mc_p05_total_r":worst_p05,
             "worst_capital_drawdown_breach_probability":worst_ruin,"dsr_portfolio_trials_8":dsr8,
             "dsr_candidate_trials_165_diagnostic":dsr165,"quarter_total_r":dict(sorted(quarter_vals.items())),
             "pre_pbo_pass":not fail,"fail_reasons":fail,"components":p["components"]}
        results.append(row)
    for direction in ("LONG","SHORT"):
        subset=[r for r in results if r["direction"]==direction]
        qlabels=sorted({q for r in subset for q in r["quarter_total_r"]})
        matrix=[[r["quarter_total_r"].get(q,0.0) for r in subset] for q in qlabels]
        pbo=cscv_pbo(matrix); passed=bool(pbo.get("available") and float(pbo.get("pbo",1.0)) <= PBO_MAX)
        qlabels_by_direction[direction]=pbo
        for r in subset:
            r["direction_pbo_pass"]=passed; r["portfolio_robustness_pass"]=bool(r["pre_pbo_pass"] and passed)
    summary={"audit":"DIRECTIONAL_PORTFOLIO_ROBUSTNESS_V1","portfolio_count":len(results),
             "long_portfolios":sum(r["direction"]=="LONG" for r in results),
             "short_portfolios":sum(r["direction"]=="SHORT" for r in results),
             "long_pbo":qlabels_by_direction.get("LONG"),"short_pbo":qlabels_by_direction.get("SHORT"),
             "pre_pbo_survivors":sum(r["pre_pbo_pass"] for r in results),
             "final_survivors":sum(r["portfolio_robustness_pass"] for r in results),
             "survivor_ids":[r["portfolio_id"] for r in results if r["portfolio_robustness_pass"]],
             "gates":{"active_days_min":60,"profit_factor_gt":1.05,"2x_cost_total_r_gt_0":True,
                      "positive_year_rate_min":.60,"moving_block_mc_2x_p05_gt_0":True,
                      "capital_dd_10pct_breach_probability_max":.01,"dsr_trials_8_min":.95,"pbo_max":.50},
             "important_limitation":"Portfolio formation and robustness reuse the 2022-09-01/2025-09-24 confirmatory window; this is not independent OOS.",
             "reserved_untouched_holdout":"2020-01-02/2022-08-31","live_money":False}
    OUT.mkdir(exist_ok=True)
    (OUT/"directional_portfolio_robustness.json").write_text(json.dumps({"summary":summary,"portfolios":results},indent=2),encoding="utf-8")
    (OUT/"directional_portfolio_robustness_summary.json").write_text(json.dumps(summary,indent=2),encoding="utf-8")
    print("DIRECTIONAL_PORTFOLIO_ROBUSTNESS_OK"); print(json.dumps(summary,indent=2))

if __name__ == "__main__": main()
