"""Cross-market portfolio fit engine.

Combines already-robust robot return series into a diversified research/demo
portfolio. It is intentionally conservative: no return-optimized weights and
no live execution.
"""
from __future__ import annotations

from dataclasses import dataclass
from collections import Counter
from typing import Dict, Iterable, List, Mapping, Sequence, Tuple
import math

import numpy as np


@dataclass(frozen=True)
class StrategySeries:
    strategy_id: str
    market: str
    family: str
    timeframe: str
    daily_returns: Mapping[str, float]
    eligible: bool = True


@dataclass(frozen=True)
class PortfolioMetrics:
    members: Tuple[str, ...]
    days: int
    total_return: float
    profit_factor: float
    max_drawdown: float
    max_market_share: float


@dataclass(frozen=True)
class AdditionDecision:
    strategy_id: str
    accepted: bool
    reason: str
    max_positive_correlation: float
    max_drawdown_overlap: float
    portfolio_max_drawdown: float


def _dates(strategies: Sequence[StrategySeries]) -> List[str]:
    return sorted({d for s in strategies for d in s.daily_returns})


def _aligned(strategy: StrategySeries, dates: Sequence[str]) -> np.ndarray:
    return np.array([float(strategy.daily_returns.get(d, 0.0)) for d in dates], dtype=float)


def profit_factor(values: Sequence[float]) -> float:
    gp = sum(v for v in values if v > 0)
    gl = abs(sum(v for v in values if v < 0))
    if gl > 0:
        return gp / gl
    return float("inf") if gp > 0 else 0.0


def max_drawdown(values: Sequence[float]) -> float:
    equity = 0.0
    peak = 0.0
    worst = 0.0
    for value in values:
        equity += float(value)
        peak = max(peak, equity)
        worst = max(worst, peak - equity)
    return worst


def _corr(a: np.ndarray, b: np.ndarray) -> float:
    if len(a) < 3 or float(np.std(a)) <= 1e-12 or float(np.std(b)) <= 1e-12:
        return 0.0
    value = float(np.corrcoef(a, b)[0, 1])
    return 0.0 if not math.isfinite(value) else value


def _drawdown_mask(values: np.ndarray) -> np.ndarray:
    equity = np.cumsum(values)
    peaks = np.maximum.accumulate(np.concatenate(([0.0], equity)))[:-1]
    return equity < peaks


def drawdown_overlap(a: np.ndarray, b: np.ndarray) -> float:
    ma = _drawdown_mask(a)
    mb = _drawdown_mask(b)
    union = int(np.logical_or(ma, mb).sum())
    if union == 0:
        return 0.0
    return float(np.logical_and(ma, mb).sum() / union)


def _weights(strategies: Sequence[StrategySeries], scheme: str) -> Dict[str, float]:
    if not strategies:
        return {}
    if scheme == "EQUAL":
        return {s.strategy_id: 1.0 / len(strategies) for s in strategies}
    if scheme != "MARKET_BALANCED":
        raise ValueError("scheme must be EQUAL or MARKET_BALANCED")
    counts = Counter(s.market for s in strategies)
    markets = len(counts)
    return {s.strategy_id: (1.0 / markets) / counts[s.market] for s in strategies}


def evaluate_portfolio(strategies: Sequence[StrategySeries], scheme: str = "MARKET_BALANCED") -> PortfolioMetrics:
    if not strategies:
        return PortfolioMetrics((), 0, 0.0, 0.0, 0.0, 0.0)
    dates = _dates(strategies)
    weights = _weights(strategies, scheme)
    combined = np.zeros(len(dates), dtype=float)
    market_weight: Dict[str, float] = {}
    for strategy in strategies:
        w = weights[strategy.strategy_id]
        combined += w * _aligned(strategy, dates)
        market_weight[strategy.market] = market_weight.get(strategy.market, 0.0) + w
    return PortfolioMetrics(
        members=tuple(s.strategy_id for s in strategies),
        days=len(dates),
        total_return=float(combined.sum()),
        profit_factor=profit_factor(combined.tolist()),
        max_drawdown=max_drawdown(combined.tolist()),
        max_market_share=max(market_weight.values()),
    )


def assess_addition(
    current: Sequence[StrategySeries],
    candidate: StrategySeries,
    *,
    max_pairwise_corr: float = 0.65,
    max_dd_overlap: float = 0.75,
    max_per_market: int = 3,
    dd_tolerance: float = 1.10,
) -> AdditionDecision:
    if not candidate.eligible:
        return AdditionDecision(candidate.strategy_id, False, "individual_not_eligible", 0.0, 0.0, 0.0)
    if sum(s.market == candidate.market for s in current) >= max_per_market:
        return AdditionDecision(candidate.strategy_id, False, "market_concentration_limit", 0.0, 0.0, 0.0)
    if not current:
        m = evaluate_portfolio([candidate])
        return AdditionDecision(candidate.strategy_id, True, "seed", 0.0, 0.0, m.max_drawdown)

    dates = _dates([*current, candidate])
    c = _aligned(candidate, dates)
    max_corr = 0.0
    max_overlap = 0.0
    for member in current:
        x = _aligned(member, dates)
        max_corr = max(max_corr, _corr(c, x))
        max_overlap = max(max_overlap, drawdown_overlap(c, x))
    if max_corr > max_pairwise_corr:
        return AdditionDecision(candidate.strategy_id, False, "positive_correlation_gate", max_corr, max_overlap, 0.0)
    if max_overlap > max_dd_overlap:
        return AdditionDecision(candidate.strategy_id, False, "drawdown_overlap_gate", max_corr, max_overlap, 0.0)

    before = evaluate_portfolio(current)
    after = evaluate_portfolio([*current, candidate])
    allowed = before.max_drawdown * dd_tolerance if before.max_drawdown > 0 else float("inf")
    if after.max_drawdown > allowed:
        return AdditionDecision(candidate.strategy_id, False, "portfolio_drawdown_gate", max_corr, max_overlap, after.max_drawdown)
    return AdditionDecision(candidate.strategy_id, True, "diversifying_addition", max_corr, max_overlap, after.max_drawdown)


def build_portfolio(
    candidates: Iterable[StrategySeries],
    *,
    target_size: int = 10,
    max_pairwise_corr: float = 0.65,
    max_dd_overlap: float = 0.75,
    max_per_market: int = 3,
) -> Tuple[List[StrategySeries], List[AdditionDecision]]:
    pool = [s for s in candidates if s.eligible]
    if not pool or target_size <= 0:
        return [], []

    # Seed with strongest simple return/drawdown ratio. This is only a seed;
    # subsequent admissions are governed by diversification hard gates.
    def quality(s: StrategySeries) -> Tuple[float, float]:
        vals = list(float(v) for v in s.daily_returns.values())
        dd = max_drawdown(vals)
        ratio = sum(vals) / dd if dd > 1e-12 else sum(vals)
        return ratio, profit_factor(vals)

    pool.sort(key=quality, reverse=True)
    selected: List[StrategySeries] = []
    decisions: List[AdditionDecision] = []

    for candidate in pool:
        if len(selected) >= target_size:
            break
        decision = assess_addition(
            selected,
            candidate,
            max_pairwise_corr=max_pairwise_corr,
            max_dd_overlap=max_dd_overlap,
            max_per_market=max_per_market,
        )
        decisions.append(decision)
        if decision.accepted:
            selected.append(candidate)

    return selected, decisions


def leave_one_out(strategies: Sequence[StrategySeries]) -> Dict[str, PortfolioMetrics]:
    return {
        s.strategy_id: evaluate_portfolio([x for x in strategies if x.strategy_id != s.strategy_id])
        for s in strategies
    }
