# Robust Strategy Screen — v1

Date: 2026-09-16
Status: RESEARCH ONLY / NO LIVE EXECUTION

## Objective

Find deterministic strategy families with a plausible economic mechanism and prior evidence of stability, then attempt to falsify them before they are allowed into the Cross-Attention / Mixture-of-Experts layer.

A strategy is not considered robust because it aligns with Cross-Attention. Cross-Attention is a fusion mechanism, not statistical validation.

## Priority candidates

### R1 — Multi-horizon time-series momentum / trend

Hypothesis: persistent directional moves contain continuation information across horizons.

Core families to test independently:
- sign of own past return over fixed lookback;
- fast/slow moving-average crossover;
- channel / Donchian breakout;
- volatility-scaled versions of the same signals.

Why first: published evidence spans many futures markets, long samples, multiple parameterizations, subperiods and transaction-cost assumptions. The research prior is materially stronger than for most retail intraday patterns.

Constraints:
- no parameter optimization before preregistered grid is frozen;
- LONG and SHORT evaluated separately;
- ES, NQ, YM and RTY separately before pooling;
- test 15m, 30m and higher-horizon variants independently; do not infer an intraday edge from daily evidence;
- use next-bar execution and realistic costs.

### R2 — Regime-switched momentum vs mean reversion

Hypothesis: trend and mean-reversion experts should not vote simultaneously; a regime gate should decide which family is eligible.

Regime features allowed initially:
- realized volatility percentile;
- Bollinger bandwidth / compression-expansion;
- directional efficiency ratio;
- VWAP distance and slope;
- session/time bucket;
- optional VIX/VXN or equivalent implied-volatility context when point-in-time data are available.

The regime switch is evaluated as a separate model. A profitable expert cannot rescue a non-robust regime classifier.

### R3 — Volatility-conditioned NQ mean reversion

Hypothesis: extreme intraday displacement can revert only in specific volatility regimes.

Initial deterministic form:
- displacement threshold expressed in volatility units, not a hand-tuned point value;
- entry only after the threshold is breached and a causal confirmation is observed;
- separate long and short variants;
- compare implied-volatility bands when available against realized-volatility proxies.

This is a candidate, not accepted evidence. It must survive costs, OOS, parameter perturbation and regime splits.

### R4 — Existing BB14 / EMA3-9 / SAR strategy as internal baseline

Keep the user-rule strategy frozen. Use it as a baseline expert and ablation reference, not as a parameter-search target.

## Negative-control / low-priority families

The following are deliberately included as falsification controls rather than promotion candidates:
- generic opening-range breakout from OHLCV only;
- generic gap continuation without enough events;
- standalone value-area breakout continuation;
- simple large-open-move reversal without cost-aware filtering.

Recent evidence shows several of these patterns can disappear after realistic costs, sample-size requirements or multi-year stability checks. They may still become contextual features, but should not be promoted as standalone experts without new evidence.

## Mandatory robustness funnel

Every candidate must pass, in order:

1. Causality / no-lookahead audit.
2. Train / validation split with frozen rules.
3. True untouched OOS.
4. Walk-forward stability.
5. Realistic commissions + slippage + latency sensitivity.
6. Parameter perturbation: nearby values must not collapse performance.
7. Trade dropout / missed-fill stress.
8. Block-bootstrap or Monte Carlo path stress.
9. Regime, year, instrument and direction decomposition.
10. Minimum sample-size gate.
11. CSCV / PBO.
12. Deflated Sharpe Ratio using the complete experiment registry.
13. Paper / shadow only after statistical promotion.

Fail any hard gate => REJECTED or RESEARCH_ONLY. No manual rescue because a chart looks good.

## Cross-Attention admission rule

Only features/experts that have either:
- independent robustness evidence, or
- a clearly defined role as contextual input with positive ablation value

may enter the Cross-Attention candidate pool.

Cross-Attention must then beat these baselines OOS:
- technical expert alone;
- news/macro alone;
- simple concatenation / linear fusion;
- equal-weight expert ensemble.

If Cross-Attention does not add stable OOS value, the simpler architecture wins.

## Data requirement

The one-day Databento sample from 2026-09-11 is only a mechanics/causality fixture. It is not sufficient for robustness conclusions. Official screening requires multi-year point-in-time data with contract-roll, session, cost and timestamp handling documented.
