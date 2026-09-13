from __future__ import annotations

from dataclasses import dataclass
from math import erf, exp, log, sqrt
from statistics import mean, pstdev
from typing import Iterable, Sequence

from .robustness_engine import MonteCarloConfig, MonteCarloRobustnessEngine, walk_forward_stability

SUPPORTED_RR = (0.25, 0.40, 0.50, 0.70, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0)


@dataclass(frozen=True)
class RobustnessDecision:
    rr: float
    n: int
    net_expectancy_r: float
    walk_forward_positive_rate: float
    monte_carlo_profitable_probability: float
    monte_carlo_ruin_probability: float
    pbo_proxy: float
    deflated_sharpe_proxy: float
    passed: bool
    reasons: tuple[str, ...]


def _sharpe_proxy(xs: Sequence[float]) -> float:
    if len(xs) < 2:
        return 0.0
    sd = pstdev(xs)
    return 0.0 if sd <= 0 else mean(xs) / sd * sqrt(len(xs))


def _normal_cdf(x: float) -> float:
    return 0.5 * (1.0 + erf(x / sqrt(2.0)))


def _deflated_sharpe_proxy(sharpe: float, trials: int, n_obs: int) -> float:
    if n_obs < 2 or trials < 1:
        return -1.0
    expected_max = sqrt(max(0.0, 2.0 * log(max(2, trials))))
    se = sqrt(max(1e-12, (1.0 + 0.5 * sharpe * sharpe) / max(1, n_obs - 1)))
    return _normal_cdf((sharpe - expected_max) / se)


def _pbo_proxy(xs: Sequence[float], folds: int = 8) -> float:
    if len(xs) < folds * 4:
        return 1.0
    size = len(xs) // folds
    chunks = [xs[i * size:(i + 1) * size] for i in range(folds)]
    ranked = []
    for i, chunk in enumerate(chunks):
        if not chunk:
            continue
        is_score = mean(chunk)
        oos = [x for j, c in enumerate(chunks) if j != i for x in c]
        oos_score = mean(oos) if oos else -1.0
        ranked.append((is_score, oos_score))
    if not ranked:
        return 1.0
    return sum(1 for is_score, oos_score in ranked if is_score > 0 and oos_score <= 0) / len(ranked)


def evaluate_returns(
    returns_r: Iterable[float],
    rr: float,
    execution_cost_r: float = 0.03,
    tested_trials: int = 1,
    min_trades: int = 30,
) -> RobustnessDecision:
    if rr not in SUPPORTED_RR:
        raise ValueError(f"unsupported rr: {rr}")
    raw = tuple(float(x) for x in returns_r)
    net = tuple(x - abs(execution_cost_r) for x in raw)
    reasons: list[str] = []
    if len(net) < min_trades:
        reasons.append("insufficient_sample")
    expectancy = mean(net) if net else 0.0
    if expectancy <= 0:
        reasons.append("non_positive_net_expectancy")

    if len(net) >= 10:
        window = max(5, min(20, len(net) // 4))
        wf = walk_forward_stability(net, window)
        wf_rate = wf.positive_window_rate
        if wf_rate < 0.60 or wf.worst_window_r <= -5.0:
            reasons.append("walk_forward_unstable")
    else:
        wf_rate = 0.0
        reasons.append("walk_forward_unavailable")

    if net:
        mc = MonteCarloRobustnessEngine().run(
            net,
            MonteCarloConfig(iterations=1000, seed=17, omit_trade_probability=0.03, extra_cost_r=0.01, slippage_r_std=0.02, ruin_drawdown_r=8.0),
        )
        if mc.profitable_probability < 0.80:
            reasons.append("monte_carlo_profitability_low")
        if mc.ruin_probability > 0.05:
            reasons.append("monte_carlo_ruin_high")
        mc_profit = mc.profitable_probability
        mc_ruin = mc.ruin_probability
    else:
        mc_profit = 0.0
        mc_ruin = 1.0
        reasons.append("monte_carlo_unavailable")

    pbo = _pbo_proxy(net)
    if pbo > 0.20:
        reasons.append("pbo_too_high")
    dsr = _deflated_sharpe_proxy(_sharpe_proxy(net), max(1, tested_trials), len(net))
    if dsr < 0.95:
        reasons.append("deflated_sharpe_too_low")

    return RobustnessDecision(
        rr=rr,
        n=len(net),
        net_expectancy_r=expectancy,
        walk_forward_positive_rate=wf_rate,
        monte_carlo_profitable_probability=mc_profit,
        monte_carlo_ruin_probability=mc_ruin,
        pbo_proxy=pbo,
        deflated_sharpe_proxy=dsr,
        passed=not reasons,
        reasons=tuple(reasons),
    )
