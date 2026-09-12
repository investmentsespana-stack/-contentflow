from dataclasses import dataclass
from random import Random
from statistics import median
from typing import Iterable, List, Sequence, Tuple


@dataclass(frozen=True)
class MonteCarloConfig:
    iterations: int = 2000
    seed: int = 7
    omit_trade_probability: float = 0.02
    extra_cost_r: float = 0.0
    slippage_r_std: float = 0.02
    ruin_drawdown_r: float = 10.0


@dataclass(frozen=True)
class MonteCarloResult:
    iterations: int
    profitable_probability: float
    ruin_probability: float
    median_total_r: float
    p05_total_r: float
    median_max_drawdown_r: float
    p95_max_drawdown_r: float
    median_win_rate: float


def _percentile(values: Sequence[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * q
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def max_drawdown_r(returns_r: Iterable[float]) -> float:
    equity = 0.0
    peak = 0.0
    worst = 0.0
    for value in returns_r:
        equity += value
        peak = max(peak, equity)
        worst = max(worst, peak - equity)
    return worst


def win_rate(returns_r: Sequence[float]) -> float:
    if not returns_r:
        return 0.0
    return sum(1 for x in returns_r if x > 0) / len(returns_r)


class MonteCarloRobustnessEngine:
    """Trade-sequence robustness testing for strategies and coalitions.

    The simulation resamples trades with replacement and stresses omitted fills,
    costs and slippage. It intentionally works on normalized R returns so it can
    be reused across instruments and account sizes.
    """

    def run(self, returns_r: Sequence[float], config: MonteCarloConfig = MonteCarloConfig()) -> MonteCarloResult:
        if not returns_r:
            raise ValueError("returns_r must not be empty")
        if config.iterations < 1:
            raise ValueError("iterations must be >= 1")
        if not 0.0 <= config.omit_trade_probability < 1.0:
            raise ValueError("omit_trade_probability must be in [0, 1)")

        rng = Random(config.seed)
        totals: List[float] = []
        drawdowns: List[float] = []
        win_rates: List[float] = []
        ruins = 0

        n = len(returns_r)
        for _ in range(config.iterations):
            path: List[float] = []
            for _index in range(n):
                if rng.random() < config.omit_trade_probability:
                    continue
                sampled = returns_r[rng.randrange(n)]
                slippage = rng.gauss(0.0, config.slippage_r_std)
                stressed = sampled - abs(config.extra_cost_r) + slippage
                path.append(stressed)

            total = sum(path)
            dd = max_drawdown_r(path)
            totals.append(total)
            drawdowns.append(dd)
            win_rates.append(win_rate(path))
            if dd >= abs(config.ruin_drawdown_r):
                ruins += 1

        profitable = sum(1 for x in totals if x > 0) / config.iterations
        return MonteCarloResult(
            iterations=config.iterations,
            profitable_probability=profitable,
            ruin_probability=ruins / config.iterations,
            median_total_r=median(totals),
            p05_total_r=_percentile(totals, 0.05),
            median_max_drawdown_r=median(drawdowns),
            p95_max_drawdown_r=_percentile(drawdowns, 0.95),
            median_win_rate=median(win_rates),
        )


@dataclass(frozen=True)
class WalkForwardResult:
    windows: int
    positive_window_rate: float
    median_window_r: float
    worst_window_r: float
    stability_score: float


def walk_forward_stability(returns_r: Sequence[float], window_size: int) -> WalkForwardResult:
    if window_size < 1:
        raise ValueError("window_size must be >= 1")
    if len(returns_r) < window_size:
        raise ValueError("not enough observations")

    windows: List[float] = []
    for start in range(0, len(returns_r) - window_size + 1, window_size):
        chunk = returns_r[start:start + window_size]
        if len(chunk) == window_size:
            windows.append(sum(chunk))
    if not windows:
        raise ValueError("no complete walk-forward windows")

    positive_rate = sum(1 for x in windows if x > 0) / len(windows)
    med = median(windows)
    worst = min(windows)
    spread = max(windows) - min(windows)
    stability = positive_rate / (1.0 + max(0.0, spread))
    return WalkForwardResult(
        windows=len(windows),
        positive_window_rate=positive_rate,
        median_window_r=med,
        worst_window_r=worst,
        stability_score=stability,
    )


def dropout_sensitivity(full_coalition_r: Sequence[float], reduced_coalition_r: Sequence[float]) -> float:
    """Return fractional performance loss when one coalition member is removed.

    Large positive values indicate fragility; negative values mean the reduced
    coalition actually improved.
    """
    full = sum(full_coalition_r)
    reduced = sum(reduced_coalition_r)
    denominator = max(abs(full), 1e-9)
    return (full - reduced) / denominator
