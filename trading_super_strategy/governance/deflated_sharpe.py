"""Deflated Sharpe Ratio (DSR) utilities.

Implements Bailey & López de Prado's multiple-testing correction using only the
Python standard library plus NumPy. Sharpe ratios must use a consistent return
frequency across the candidate and the trial population. The DSR is a research
validation statistic; it is not a trading signal.
"""
from __future__ import annotations

from dataclasses import dataclass
from math import e, isfinite, sqrt
from statistics import NormalDist
from typing import Iterable, Sequence

import numpy as np

EULER_MASCHERONI = 0.5772156649015329
_STD_NORMAL = NormalDist()


@dataclass(frozen=True)
class DeflatedSharpeResult:
    observed_sharpe: float
    benchmark_sharpe: float
    dsr: float
    n_observations: int
    n_trials: int
    skewness: float
    kurtosis: float
    trial_sharpe_variance: float


def _clean_returns(returns: Iterable[float]) -> np.ndarray:
    values = np.asarray(list(returns), dtype=float)
    values = values[np.isfinite(values)]
    if values.size < 3:
        raise ValueError("at least 3 finite return observations are required")
    return values


def sharpe_ratio(returns: Iterable[float]) -> float:
    """Return the non-annualized sample Sharpe ratio for periodic returns."""
    r = _clean_returns(returns)
    sd = float(np.std(r, ddof=1))
    if sd <= 0.0:
        raise ValueError("returns must have non-zero sample standard deviation")
    return float(np.mean(r) / sd)


def _shape_stats(r: np.ndarray) -> tuple[float, float]:
    """Population-moment skewness and Pearson kurtosis (normal == 3)."""
    centered = r - float(np.mean(r))
    m2 = float(np.mean(centered**2))
    if m2 <= 0:
        raise ValueError("returns must have non-zero variance")
    m3 = float(np.mean(centered**3))
    m4 = float(np.mean(centered**4))
    skew = m3 / (m2 ** 1.5)
    kurtosis = m4 / (m2 * m2)
    return skew, kurtosis


def probabilistic_sharpe_ratio(
    returns: Iterable[float],
    *,
    benchmark_sharpe: float = 0.0,
) -> float:
    """Probability that the observed Sharpe exceeds ``benchmark_sharpe``.

    Uses the non-normality adjustment with observed skewness and Pearson
    kurtosis. Inputs and benchmark must be expressed at the same frequency.
    """
    r = _clean_returns(returns)
    sr = sharpe_ratio(r)
    skew, kurtosis = _shape_stats(r)
    variance_term = 1.0 - skew * sr + ((kurtosis - 1.0) / 4.0) * sr * sr
    if variance_term <= 0.0 or not isfinite(variance_term):
        raise ValueError("invalid PSR variance term; inspect return distribution")
    z = (sr - float(benchmark_sharpe)) * sqrt(r.size - 1.0) / sqrt(variance_term)
    return float(_STD_NORMAL.cdf(z))


def expected_maximum_sharpe(trial_sharpes: Sequence[float]) -> tuple[float, float]:
    """Expected maximum Sharpe under the null and cross-trial Sharpe variance."""
    srs = np.asarray(list(trial_sharpes), dtype=float)
    srs = srs[np.isfinite(srs)]
    n = int(srs.size)
    if n < 1:
        raise ValueError("at least one registered trial Sharpe is required")
    if n == 1:
        return 0.0, 0.0

    variance = float(np.var(srs, ddof=1))
    if variance < 0 or not isfinite(variance):
        raise ValueError("trial Sharpe variance is invalid")
    sigma = sqrt(variance)
    z1 = _STD_NORMAL.inv_cdf(1.0 - 1.0 / n)
    z2 = _STD_NORMAL.inv_cdf(1.0 - 1.0 / (n * e))
    benchmark = sigma * ((1.0 - EULER_MASCHERONI) * z1 + EULER_MASCHERONI * z2)
    return float(benchmark), variance


def deflated_sharpe_ratio(
    returns: Iterable[float],
    *,
    trial_sharpes: Sequence[float],
) -> DeflatedSharpeResult:
    """Compute DSR after correcting for search breadth and non-normal returns."""
    r = _clean_returns(returns)
    sr = sharpe_ratio(r)
    skew, kurtosis = _shape_stats(r)
    benchmark, variance = expected_maximum_sharpe(trial_sharpes)
    dsr = probabilistic_sharpe_ratio(r, benchmark_sharpe=benchmark)
    return DeflatedSharpeResult(
        observed_sharpe=sr,
        benchmark_sharpe=benchmark,
        dsr=dsr,
        n_observations=int(r.size),
        n_trials=len([x for x in trial_sharpes if isfinite(float(x))]),
        skewness=skew,
        kurtosis=kurtosis,
        trial_sharpe_variance=variance,
    )
