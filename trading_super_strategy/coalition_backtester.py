from dataclasses import dataclass
from itertools import combinations
from typing import Dict, Iterable, List, Mapping, Sequence, Tuple

from robustness_engine import max_drawdown_r


@dataclass(frozen=True)
class ContextKey:
    instrument: str
    session: str
    minutes_from_open_bucket: str
    volatility_regime: str
    trend_regime: str
    structure_regime: str


@dataclass(frozen=True)
class BacktestEvent:
    context: ContextKey
    signals: Mapping[str, int]  # strategy -> -1/0/+1
    coordinated_long_return_r: float
    coordinated_short_return_r: float
    execution_cost_r: float = 0.0


@dataclass(frozen=True)
class CoalitionMetrics:
    members: Tuple[str, ...]
    direction: int
    trades: int
    wins: int
    win_rate: float
    expectancy_r: float
    profit_factor: float
    max_drawdown_r: float
    total_r: float
    best_member_win_rate: float
    win_rate_uplift: float


class CoalitionBacktester:
    """Combinatorial directional coalition search over precomputed events.

    A coalition fires only when every member independently signals the same side.
    The trade outcome belongs to one coordinated position plan, not to separate
    strategy orders. LONG and SHORT are evaluated independently.
    """

    @staticmethod
    def _event_return(event: BacktestEvent, direction: int) -> float:
        gross = event.coordinated_long_return_r if direction == 1 else event.coordinated_short_return_r
        return gross - abs(event.execution_cost_r)

    @staticmethod
    def _active(event: BacktestEvent, members: Sequence[str], direction: int) -> bool:
        return all(event.signals.get(member, 0) == direction for member in members)

    def returns_for(
        self,
        events: Iterable[BacktestEvent],
        members: Sequence[str],
        direction: int,
        *,
        context: ContextKey | None = None,
    ) -> List[float]:
        if direction not in (-1, 1):
            raise ValueError("direction must be -1 or 1")
        output: List[float] = []
        for event in events:
            if context is not None and event.context != context:
                continue
            if self._active(event, members, direction):
                output.append(self._event_return(event, direction))
        return output

    @staticmethod
    def _metrics_from_returns(members: Sequence[str], direction: int, returns_r: Sequence[float]) -> CoalitionMetrics:
        trades = len(returns_r)
        wins = sum(1 for value in returns_r if value > 0)
        win_rate = wins / trades if trades else 0.0
        total_r = sum(returns_r)
        expectancy = total_r / trades if trades else 0.0
        gross_profit = sum(value for value in returns_r if value > 0)
        gross_loss = abs(sum(value for value in returns_r if value < 0))
        if gross_loss > 0:
            profit_factor = gross_profit / gross_loss
        elif gross_profit > 0:
            profit_factor = float("inf")
        else:
            profit_factor = 0.0
        return CoalitionMetrics(
            members=tuple(members),
            direction=direction,
            trades=trades,
            wins=wins,
            win_rate=win_rate,
            expectancy_r=expectancy,
            profit_factor=profit_factor,
            max_drawdown_r=max_drawdown_r(returns_r),
            total_r=total_r,
            best_member_win_rate=0.0,
            win_rate_uplift=0.0,
        )

    def evaluate(
        self,
        events: Sequence[BacktestEvent],
        members: Sequence[str],
        direction: int,
        *,
        context: ContextKey | None = None,
    ) -> CoalitionMetrics:
        coalition_returns = self.returns_for(events, members, direction, context=context)
        base = self._metrics_from_returns(members, direction, coalition_returns)

        member_rates: List[float] = []
        for member in members:
            individual = self.returns_for(events, [member], direction, context=context)
            if individual:
                member_rates.append(sum(1 for value in individual if value > 0) / len(individual))
        best_member = max(member_rates) if member_rates else 0.0
        return CoalitionMetrics(
            members=base.members,
            direction=base.direction,
            trades=base.trades,
            wins=base.wins,
            win_rate=base.win_rate,
            expectancy_r=base.expectancy_r,
            profit_factor=base.profit_factor,
            max_drawdown_r=base.max_drawdown_r,
            total_r=base.total_r,
            best_member_win_rate=best_member,
            win_rate_uplift=base.win_rate - best_member,
        )

    def search(
        self,
        events: Sequence[BacktestEvent],
        strategy_names: Sequence[str],
        direction: int,
        *,
        member_sizes: Sequence[int] = (2, 3, 4),
        min_trades: int = 20,
        context: ContextKey | None = None,
    ) -> List[CoalitionMetrics]:
        results: List[CoalitionMetrics] = []
        unique_names = tuple(dict.fromkeys(strategy_names))
        for size in member_sizes:
            if size < 1 or size > len(unique_names):
                continue
            for members in combinations(unique_names, size):
                metrics = self.evaluate(events, members, direction, context=context)
                if metrics.trades < min_trades:
                    continue
                if metrics.expectancy_r <= 0:
                    continue
                results.append(metrics)

        # Win rate matters, but expectancy, PF and drawdown break ties so the
        # search does not optimize hit rate in isolation.
        def rank_key(item: CoalitionMetrics) -> Tuple[float, float, float, float, int]:
            pf = item.profit_factor if item.profit_factor != float("inf") else 999.0
            return (
                item.win_rate,
                item.expectancy_r,
                pf,
                -item.max_drawdown_r,
                item.trades,
            )

        return sorted(results, key=rank_key, reverse=True)

    def search_long_short(
        self,
        events: Sequence[BacktestEvent],
        strategy_names: Sequence[str],
        *,
        member_sizes: Sequence[int] = (2, 3, 4),
        min_trades: int = 20,
        context: ContextKey | None = None,
    ) -> Dict[int, List[CoalitionMetrics]]:
        return {
            1: self.search(events, strategy_names, 1, member_sizes=member_sizes, min_trades=min_trades, context=context),
            -1: self.search(events, strategy_names, -1, member_sizes=member_sizes, min_trades=min_trades, context=context),
        }

    def train_oos_search(
        self,
        events: Sequence[BacktestEvent],
        strategy_names: Sequence[str],
        direction: int,
        *,
        train_fraction: float = 0.70,
        member_sizes: Sequence[int] = (2, 3, 4),
        min_train_trades: int = 20,
        min_oos_trades: int = 5,
        top_n_train: int = 25,
    ) -> List[Tuple[CoalitionMetrics, CoalitionMetrics]]:
        if not 0.5 <= train_fraction < 1.0:
            raise ValueError("train_fraction must be in [0.5, 1.0)")
        split = max(1, min(len(events) - 1, int(len(events) * train_fraction)))
        train = events[:split]
        oos = events[split:]
        train_ranked = self.search(
            train,
            strategy_names,
            direction,
            member_sizes=member_sizes,
            min_trades=min_train_trades,
        )[:top_n_train]

        survivors: List[Tuple[CoalitionMetrics, CoalitionMetrics]] = []
        for train_metrics in train_ranked:
            oos_metrics = self.evaluate(oos, train_metrics.members, direction)
            if oos_metrics.trades < min_oos_trades:
                continue
            if oos_metrics.expectancy_r <= 0:
                continue
            survivors.append((train_metrics, oos_metrics))

        return sorted(
            survivors,
            key=lambda pair: (pair[1].win_rate, pair[1].expectancy_r, -pair[1].max_drawdown_r),
            reverse=True,
        )
