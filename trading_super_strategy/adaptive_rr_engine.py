from dataclasses import dataclass
from typing import Iterable, Optional, Tuple


@dataclass(frozen=True)
class RRCandidate:
    reward_r: float
    p_win: float
    samples: int
    cost_r: float = 0.0
    uncertainty: float = 0.0
    oos_stability: float = 1.0


@dataclass(frozen=True)
class RRDecision:
    accepted: bool
    reward_r: float
    expected_value_r: float
    breakeven_win_rate: float
    score: float
    reason: str


class AdaptiveRiskRewardEngine:
    """Chooses target distance by calibrated probability and net expectancy.

    `reward_r < 1.0` is intentionally allowed. Such a negative/asymmetric ratio
    is selected only when its OOS probability is high enough to remain positive
    after costs and uncertainty penalties. Win rate is never optimized alone.
    """

    def __init__(
        self,
        *,
        min_samples: int = 30,
        min_oos_stability: float = 0.55,
        uncertainty_penalty: float = 0.20,
    ) -> None:
        self.min_samples = min_samples
        self.min_oos_stability = min_oos_stability
        self.uncertainty_penalty = uncertainty_penalty

    @staticmethod
    def breakeven_win_rate(reward_r: float, cost_r: float = 0.0) -> float:
        if reward_r <= 0:
            raise ValueError("reward_r must be > 0")
        # Solve p*reward - (1-p)*1 - cost = 0.
        return (1.0 + max(0.0, cost_r)) / (1.0 + reward_r)

    @staticmethod
    def expected_value(candidate: RRCandidate) -> float:
        if not 0.0 <= candidate.p_win <= 1.0:
            raise ValueError("p_win must be in [0, 1]")
        if candidate.reward_r <= 0:
            raise ValueError("reward_r must be > 0")
        return (
            candidate.p_win * candidate.reward_r
            - (1.0 - candidate.p_win) * 1.0
            - abs(candidate.cost_r)
        )

    def evaluate(self, candidate: RRCandidate) -> RRDecision:
        if candidate.samples < self.min_samples:
            return RRDecision(False, candidate.reward_r, 0.0, self.breakeven_win_rate(candidate.reward_r, candidate.cost_r), float("-inf"), "INSUFFICIENT_SAMPLES")
        if candidate.oos_stability < self.min_oos_stability:
            return RRDecision(False, candidate.reward_r, 0.0, self.breakeven_win_rate(candidate.reward_r, candidate.cost_r), float("-inf"), "LOW_OOS_STABILITY")

        ev = self.expected_value(candidate)
        breakeven = self.breakeven_win_rate(candidate.reward_r, candidate.cost_r)
        if ev <= 0:
            return RRDecision(False, candidate.reward_r, ev, breakeven, ev, "NON_POSITIVE_EV")

        uncertainty = min(max(candidate.uncertainty, 0.0), 1.0)
        score = ev * candidate.oos_stability - self.uncertainty_penalty * uncertainty
        if score <= 0:
            return RRDecision(False, candidate.reward_r, ev, breakeven, score, "UNCERTAINTY_TOO_HIGH")
        return RRDecision(True, candidate.reward_r, ev, breakeven, score, "RR_OK")

    def select(self, candidates: Iterable[RRCandidate]) -> RRDecision:
        best: Optional[RRDecision] = None
        for candidate in candidates:
            decision = self.evaluate(candidate)
            if not decision.accepted:
                continue
            if best is None or decision.score > best.score:
                best = decision
        if best is None:
            return RRDecision(False, 0.0, 0.0, 0.0, float("-inf"), "NO_VALID_RR")
        return best


@dataclass(frozen=True)
class PositionRiskState:
    initial_hard_stop_r: float
    current_hard_stop_r: float
    target_r: float


def validate_stop_update(state: PositionRiskState, proposed_hard_stop_r: float) -> Tuple[bool, str]:
    """Forbids increasing maximum loss after entry.

    Stops are expressed as positive loss distances in R. A smaller distance
    reduces risk; a larger distance widens risk and is rejected.
    """
    if proposed_hard_stop_r <= 0:
        return False, "INVALID_STOP"
    if proposed_hard_stop_r > state.initial_hard_stop_r + 1e-12:
        return False, "CANNOT_WIDEN_BEYOND_INITIAL_RISK"
    if proposed_hard_stop_r > state.current_hard_stop_r + 1e-12:
        return False, "CANNOT_REINCREASE_RISK"
    return True, "STOP_UPDATE_OK"
