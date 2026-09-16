"""Probability of Backtest Overfitting (PBO) via CSCV.

Input is a T x N matrix of synchronized periodic returns: T observations and N
strategy/parameter trials. This module is deliberately independent of the
strategy engines so every attempted variant can be audited with the same tool.
"""
from __future__ import annotations

from dataclasses import dataclass
from itertools import combinations
from math import log
from typing import Optional

import numpy as np


@dataclass(frozen=True)
class PBOResult:
    pbo: float
    logits: tuple[float, ...]
    selected_strategy_indices: tuple[int, ...]
    n_combinations: int
    n_slices: int


def _column_sharpes(matrix: np.ndarray) -> np.ndarray:
    means = np.nanmean(matrix, axis=0)
    stds = np.nanstd(matrix, axis=0, ddof=1)
    out = np.full(means.shape, -np.inf, dtype=float)
    valid = np.isfinite(means) & np.isfinite(stds) & (stds > 0)
    out[valid] = means[valid] / stds[valid]
    return out


def probability_of_backtest_overfitting(
    returns_matrix: np.ndarray,
    *,
    n_slices: int = 10,
    max_combinations: Optional[int] = None,
) -> PBOResult:
    """Estimate PBO with combinatorially symmetric cross-validation.

    ``n_slices`` must be even. The matrix must have at least two strategies and
    enough rows to give every slice two or more observations. PBO is the share
    of splits where the in-sample winner ranks below the OOS median.
    """
    matrix = np.asarray(returns_matrix, dtype=float)
    if matrix.ndim != 2:
        raise ValueError("returns_matrix must be 2-D [observations, strategies]")
    t_obs, n_strategies = matrix.shape
    if n_strategies < 2:
        raise ValueError("PBO requires at least two strategy trials")
    if n_slices < 4 or n_slices % 2:
        raise ValueError("n_slices must be even and >= 4")
    if t_obs < n_slices * 2:
        raise ValueError("need at least two observations per CSCV slice")
    if max_combinations is not None and max_combinations < 1:
        raise ValueError("max_combinations must be positive")

    slices = np.array_split(np.arange(t_obs), n_slices)
    half = n_slices // 2
    logits: list[float] = []
    selected: list[int] = []

    for combo_idx, is_slice_ids in enumerate(combinations(range(n_slices), half)):
        if max_combinations is not None and combo_idx >= max_combinations:
            break
        is_set = set(is_slice_ids)
        oos_slice_ids = [i for i in range(n_slices) if i not in is_set]
        is_rows = np.concatenate([slices[i] for i in is_slice_ids])
        oos_rows = np.concatenate([slices[i] for i in oos_slice_ids])
        is_scores = _column_sharpes(matrix[is_rows])
        if not np.isfinite(is_scores).any():
            continue
        winner = int(np.nanargmax(is_scores))
        oos_scores = _column_sharpes(matrix[oos_rows])
        if not np.isfinite(oos_scores[winner]):
            relative_rank = 1.0 / (n_strategies + 1.0)
        else:
            score = oos_scores[winner]
            lower = int(np.sum(oos_scores < score))
            equal = int(np.sum(oos_scores == score))
            rank = lower + (equal + 1.0) / 2.0
            relative_rank = rank / (n_strategies + 1.0)
        relative_rank = min(max(relative_rank, 1e-12), 1.0 - 1e-12)
        logits.append(log(relative_rank / (1.0 - relative_rank)))
        selected.append(winner)

    if not logits:
        raise ValueError("CSCV produced no valid splits")
    pbo = float(np.mean(np.asarray(logits) <= 0.0))
    return PBOResult(
        pbo=pbo,
        logits=tuple(float(x) for x in logits),
        selected_strategy_indices=tuple(selected),
        n_combinations=len(logits),
        n_slices=n_slices,
    )
