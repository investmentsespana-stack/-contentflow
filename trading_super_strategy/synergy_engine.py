from dataclasses import dataclass
from itertools import combinations
from statistics import mean
from typing import Dict, List, Sequence, Tuple


@dataclass(frozen=True)
class StrategyState:
    name: str
    family: str
    direction: int  # -1 short, 0 neutral, +1 long
    confidence: float
    win_rate: float
    expectancy_r: float
    profit_factor: float
    max_drawdown_r: float
    oos_stability: float
    preferred_target_r: float


@dataclass(frozen=True)
class PairCompatibility:
    strategy_a: str
    strategy_b: str
    principle_compatible: bool
    error_correlation: float
    contradiction_rate: float
    target_overlap: float


@dataclass(frozen=True)
class CoalitionDecision:
    accepted: bool
    members: Tuple[str, ...]
    direction: int
    score: float
    coordinated_target_seed_r: float
    reason: str


@dataclass(frozen=True)
class RegimeRoutingDecision:
    action: str  # LONG / SHORT / NO_TRADE
    coalition: CoalitionDecision
    reason: str


class StrategySynergyEngine:
    """Builds one coordinated coalition instead of independent strategy orders.

    Research/backtest must search LONG and SHORT coalitions independently because
    the optimal members can be asymmetric by side, session and regime. Sideways
    and unclear regimes fail closed to NO_TRADE unless that policy is explicitly
    changed and validated later.
    """

    def __init__(
        self,
        *,
        max_error_correlation: float = 0.80,
        max_contradiction_rate: float = 0.30,
        min_target_overlap: float = 0.35,
        min_members: int = 2,
    ) -> None:
        self.max_error_correlation = max_error_correlation
        self.max_contradiction_rate = max_contradiction_rate
        self.min_target_overlap = min_target_overlap
        self.min_members = min_members

    @staticmethod
    def _pair_key(a: str, b: str) -> Tuple[str, str]:
        return tuple(sorted((a, b)))

    @staticmethod
    def _empty(reason: str, direction: int = 0) -> CoalitionDecision:
        return CoalitionDecision(False, tuple(), direction, float("-inf"), 0.0, reason)

    def evaluate(
        self,
        strategies: Sequence[StrategyState],
        pair_metrics: Dict[Tuple[str, str], PairCompatibility],
    ) -> CoalitionDecision:
        if len(strategies) < self.min_members:
            return CoalitionDecision(False, tuple(s.name for s in strategies), 0, 0.0, 0.0, "TOO_FEW_MEMBERS")

        directions = {s.direction for s in strategies if s.direction != 0}
        if len(directions) != 1:
            return CoalitionDecision(False, tuple(s.name for s in strategies), 0, 0.0, 0.0, "DIRECTION_CONFLICT")
        direction = directions.pop()

        pair_rows: List[PairCompatibility] = []
        for a, b in combinations(strategies, 2):
            key = self._pair_key(a.name, b.name)
            metric = pair_metrics.get(key)
            if metric is None:
                return CoalitionDecision(False, tuple(s.name for s in strategies), direction, 0.0, 0.0, f"MISSING_PAIR_METRICS:{a.name}:{b.name}")
            if not metric.principle_compatible:
                return CoalitionDecision(False, tuple(s.name for s in strategies), direction, 0.0, 0.0, f"PRINCIPLE_CONFLICT:{a.name}:{b.name}")
            if metric.error_correlation > self.max_error_correlation:
                return CoalitionDecision(False, tuple(s.name for s in strategies), direction, 0.0, 0.0, f"REDUNDANT_ERRORS:{a.name}:{b.name}")
            if metric.contradiction_rate > self.max_contradiction_rate:
                return CoalitionDecision(False, tuple(s.name for s in strategies), direction, 0.0, 0.0, f"HIGH_CONTRADICTION:{a.name}:{b.name}")
            if metric.target_overlap < self.min_target_overlap:
                return CoalitionDecision(False, tuple(s.name for s in strategies), direction, 0.0, 0.0, f"TARGET_CONFLICT:{a.name}:{b.name}")
            pair_rows.append(metric)

        unique_families = len({s.family for s in strategies})
        family_diversity = unique_families / len(strategies)

        avg_win = mean(s.win_rate for s in strategies)
        avg_expectancy = mean(s.expectancy_r for s in strategies)
        avg_pf = mean(min(s.profit_factor, 3.0) / 3.0 for s in strategies)
        avg_oos = mean(s.oos_stability for s in strategies)
        avg_conf = mean(s.confidence for s in strategies)
        dd_penalty = mean(min(abs(s.max_drawdown_r) / 20.0, 1.0) for s in strategies)

        avg_corr = mean(p.error_correlation for p in pair_rows) if pair_rows else 0.0
        avg_contradiction = mean(p.contradiction_rate for p in pair_rows) if pair_rows else 0.0
        avg_target_overlap = mean(p.target_overlap for p in pair_rows) if pair_rows else 1.0
        diversity_bonus = (1.0 - max(0.0, avg_corr)) * family_diversity

        score = (
            0.22 * avg_win
            + 0.18 * max(min(avg_expectancy, 1.0), -1.0)
            + 0.14 * avg_pf
            + 0.16 * avg_oos
            + 0.10 * avg_conf
            + 0.10 * diversity_bonus
            + 0.10 * avg_target_overlap
            - 0.10 * avg_contradiction
            - 0.10 * dd_penalty
        )

        weights = [max(1e-6, s.confidence * s.oos_stability) for s in strategies]
        target_seed = sum(s.preferred_target_r * w for s, w in zip(strategies, weights)) / sum(weights)

        return CoalitionDecision(
            True,
            tuple(s.name for s in strategies),
            direction,
            round(score, 6),
            round(target_seed, 4),
            "COALITION_OK",
        )

    def search_best(
        self,
        strategies: Sequence[StrategyState],
        pair_metrics: Dict[Tuple[str, str], PairCompatibility],
        *,
        max_members: int = 4,
    ) -> CoalitionDecision:
        best = self._empty("NO_VALID_COALITION")
        upper = min(max_members, len(strategies))
        for size in range(self.min_members, upper + 1):
            for subset in combinations(strategies, size):
                decision = self.evaluate(subset, pair_metrics)
                if decision.accepted and decision.score > best.score:
                    best = decision
        return best

    def search_best_by_direction(
        self,
        strategies: Sequence[StrategyState],
        pair_metrics: Dict[Tuple[str, str], PairCompatibility],
        *,
        max_members: int = 4,
    ) -> Dict[int, CoalitionDecision]:
        """Searches the combinatorial space separately for LONG and SHORT.

        The same underlying strategy may later be represented as two directional
        variants with different backtest statistics, e.g. breakout_long and
        breakout_short. This preserves directional asymmetry instead of forcing
        one universal coalition.
        """
        result: Dict[int, CoalitionDecision] = {}
        for direction in (1, -1):
            candidates = [s for s in strategies if s.direction == direction]
            if len(candidates) < self.min_members:
                result[direction] = self._empty("NO_VALID_DIRECTIONAL_COALITION", direction)
            else:
                found = self.search_best(candidates, pair_metrics, max_members=max_members)
                if found.direction == 0 and not found.accepted:
                    found = self._empty(found.reason, direction)
                result[direction] = found
        return result

    def route_for_regime(
        self,
        regime: str,
        directional: Dict[int, CoalitionDecision],
    ) -> RegimeRoutingDecision:
        """Routes the validated directional coalition for the current regime."""
        normalized = regime.strip().lower()
        bullish = {"bull", "bullish", "bull_trend", "positive_trend", "uptrend"}
        bearish = {"bear", "bearish", "bear_trend", "negative_trend", "downtrend"}
        sideways = {"sideways", "range", "lateral", "neutral", "unclear", "chop"}

        if normalized in sideways:
            return RegimeRoutingDecision("NO_TRADE", self._empty("SIDEWAYS_OR_UNCLEAR"), "SIDEWAYS_OR_UNCLEAR")
        if normalized in bullish:
            coalition = directional.get(1, self._empty("NO_LONG_COALITION", 1))
            if not coalition.accepted:
                return RegimeRoutingDecision("NO_TRADE", coalition, "NO_VALID_LONG_COALITION")
            return RegimeRoutingDecision("LONG", coalition, "BULLISH_REGIME_LONG_COALITION")
        if normalized in bearish:
            coalition = directional.get(-1, self._empty("NO_SHORT_COALITION", -1))
            if not coalition.accepted:
                return RegimeRoutingDecision("NO_TRADE", coalition, "NO_VALID_SHORT_COALITION")
            return RegimeRoutingDecision("SHORT", coalition, "BEARISH_REGIME_SHORT_COALITION")
        return RegimeRoutingDecision("NO_TRADE", self._empty("UNSUPPORTED_REGIME"), "UNSUPPORTED_REGIME")
