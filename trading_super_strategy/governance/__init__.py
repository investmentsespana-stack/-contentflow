"""Anti-overfitting governance for strategy research."""

from .deflated_sharpe import (
    DeflatedSharpeResult,
    deflated_sharpe_ratio,
    expected_maximum_sharpe,
    probabilistic_sharpe_ratio,
    sharpe_ratio,
)
from .experiment_registry import ExperimentRegistry, TrialRecord
from .pbo_cscv import PBOResult, probability_of_backtest_overfitting
from .promotion_gate import PromotionDecision, PromotionEvidence, PromotionPolicy, evaluate_promotion

__all__ = [
    "DeflatedSharpeResult",
    "ExperimentRegistry",
    "PBOResult",
    "PromotionDecision",
    "PromotionEvidence",
    "PromotionPolicy",
    "TrialRecord",
    "deflated_sharpe_ratio",
    "evaluate_promotion",
    "expected_maximum_sharpe",
    "probabilistic_sharpe_ratio",
    "probability_of_backtest_overfitting",
    "sharpe_ratio",
]
