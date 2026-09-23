# StrategyQuant Generation Protocol v1

Status: PRE-REGISTERED RESEARCH PROTOCOL
Project: Super Estrategia Adaptativa — Trading Algorítmico
Live money: OFF

## Purpose

Use StrategyQuant X as a candidate-generation and first-pass robustness factory. StrategyQuant is not the final arbiter. Final selection, portfolio construction, independent validation, risk gating and promotion remain under Director/RARA and the external research pipeline.

## Non-negotiable data governance

- Discovery / candidate-generation window: 2025-09-25 through 2026-09-11.
- Confirmatory research window: 2022-09-01 through 2025-09-24.
- 2018-01-02 through 2019-12-31 is now CONSUMED independent validation evidence and must not be used for tuning the current failed design.
- Final holdout 2020-01-02 through 2022-08-31 remains SEALED and must not be read by StrategyQuant generation, optimization, ranking or retesting.
- No parameter, rule, weighting or filter may be changed after seeing sealed holdout results.

## Markets and directions

Markets: ES, NQ, YM, RTY.
Directions are separate research populations:
- LONG campaigns generate LONG-only candidates.
- SHORT campaigns generate SHORT-only candidates.
- A LONG rule is not automatically mirrored to create a SHORT rule.

## Session and anchor rule

The New York 09:00-12:00 ET anchor is structural/contextual only. It is NOT a hard trading-time restriction. Candidates may operate in Globex, Europe, pre-NY, NY or later sessions when their context is valid. No candidate is rejected solely for being outside 09:00-12:00 ET.

## Initial campaign size

Initial target: 5,000 generated candidates per market and direction, 40,000 total raw candidates across 4 markets x 2 directions. This is a discovery target, not a quota that must be forced through filters.

## Candidate diversity

Generation should deliberately span distinct families instead of one over-optimized template. Candidate metadata must preserve family, market, direction, timeframe/session, entry logic, exit logic, stop/target structure and parameter count.

LONG examples: momentum continuation, breakout, pullback, VWAP/mean-reversion where directionally valid, trend continuation.

SHORT campaign families are defined separately in `short_restructure_v1.json`.

## StrategyQuant triage gates

These are only first-pass factory filters; external gates remain stricter and authoritative.

A candidate must:
- have positive expectancy after baseline costs;
- have profit factor above 1.05;
- have enough observations to avoid tiny-sample promotion;
- survive increased trading costs/slippage tests including 1.5x and 2x cost scenarios;
- survive parameter perturbation around the selected values rather than only one exact parameter point;
- survive trade-order / bootstrap-style robustness testing;
- survive Walk-Forward testing with no single fold dominating the result;
- avoid pathological concentration in one month, one quarter or one isolated market episode.

No candidate is promoted because of win rate alone.

## Anti-overfit policy

- Prefer simpler rule trees and fewer free parameters when performance is comparable.
- Penalize near-duplicate strategies.
- Preserve broad behavioral diversity before portfolio construction.
- Rank on a vector of expectancy, PF, drawdown, stability, cost survival, WF robustness and diversity, not a single scalar score.
- Do not retune a failed independent candidate on the same independent period.
- Do not weaken hard robustness gates merely to create survivors.

## Export contract to Director/RARA

Every StrategyQuant survivor exported to the external pipeline must include at least:
- stable candidate ID;
- symbol;
- LONG or SHORT;
- timeframe and session/context;
- full rule description / exportable strategy definition;
- parameter values and allowed perturbation ranges;
- trade list or timestamped equity/return series;
- baseline costs and stressed-cost results;
- trade count;
- expectancy;
- profit factor;
- max drawdown;
- annual / quarterly fold results;
- Walk-Forward evidence;
- Monte Carlo evidence;
- StrategyQuant databank/project provenance;
- generation seed or reproducibility metadata when available.

## External pipeline after StrategyQuant

StrategyQuant survivor -> Director/RARA schema validation -> deduplication -> external causal replay where possible -> LONG/SHORT portfolio construction -> cost stress -> moving-block Monte Carlo -> capital-aware drawdown test -> DSR -> CSCV/PBO -> independent OOS -> final sealed holdout only after prior stages pass -> paper/shadow -> limited live only with explicit final authorization.

## Portfolio-first research rule

Individual robustness remains diagnostic, but portfolio robustness is evaluated separately. A moderately strong candidate may be retained for portfolio research if it contributes independent edge/diversification; however, weak components are never justified solely by diversification if the aggregate fails hard robustness.

## Kill criteria

If broad, diverse StrategyQuant campaigns repeatedly fail independent external validation across regimes, stop tuning weights/thresholds and redesign the strategy families/data/context layer. The objective is generalization, not fitting the historical sample.

## HELIOS-style portfolio validation and demo gate (v1)

This project adopts the portfolio-first validation pattern from the HELIOS H1 reference as an operating discipline: the finished research product is a **portfolio of multiple robots**, not one headline strategy.

### Canonical pipeline

`StrategyQuant Custom Project -> generation -> reserved OOS -> other markets/timeframes -> slippage -> Monte Carlo -> Final -> Vibe/AI survivor review -> EA export -> MT5 DEMO`.

The stages are sequential hard gates. A strong in-sample backtest never skips later stages.

### Portfolio construction after SQX Final

- Build portfolios from multiple frozen survivor robots; do not promote a single robot as the finished product.
- Preserve diversification across asset, direction, family, timeframe/session and trade timing where evidence permits.
- Measure each robot's contribution to portfolio net result, drawdown and trade count.
- Recalculate portfolio net result, profit factor, drawdown and trade count independently from the exported trade/equity series.
- Report concentration explicitly. A portfolio whose result is economically dependent on one robot remains research-only until that dependence is understood and pre-registered.
- Vibe/AI may analyze, classify and compare survivors, but it may not invent missing backtest evidence or rescue a failed SQX/OOS/robustness gate.

### Reserved OOS requirement

After StrategyQuant discovery, require a period that was not used to generate, optimize, rank or choose the robots. Portfolio-level OOS must be reported separately from development results. No retuning is allowed after inspecting the reserved OOS; a failed design returns to a new research cycle.

### MT5 demo validation

Before any live-money discussion, freeze the selected robots and run them in demo for a minimum of **30 calendar days without parameter changes**.

Canonical terminal allocation:

- `MT5-DEMO-01` -> Portfolio A
- `MT5-DEMO-02` -> Portfolio B
- `MT5-DEMO-03` -> Portfolio C / future validated portfolio

During the frozen demo month compare SQX model versus MT5 demo at both robot and portfolio level:

- expected versus observed trade count and timing;
- net P/L, profit factor, win rate and max drawdown;
- spread/slippage/fill differences;
- missed/duplicate orders;
- symbol/timeframe mapping;
- Expert/Journal/runtime errors;
- contribution and concentration by robot.

The HELIOS reference's simulated-to-real PF compression (1.73 in simulation versus an expected 1.25-1.40 range in real) is treated as a **stress expectation, not a guaranteed target or hard promotion threshold**. The purpose of the demo month is to detect execution/model drift while the system is frozen.

Demo failure criteria include operational errors, missing robots, duplicate/missed execution, wrong symbol mapping, or behavior materially inconsistent with the frozen model. A small losing month alone is not an automatic failure.

### Promotion rule

Only a portfolio that has passed the full SQX robustness chain, independent portfolio verification, reserved OOS, Vibe/AI evidence review, EA export verification, and the frozen MT5 demo period can be considered for a later live-money authorization. Live money remains OFF by default.

