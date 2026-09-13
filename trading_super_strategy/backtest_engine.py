from __future__ import annotations

from dataclasses import dataclass, field, replace
from datetime import datetime
from enum import Enum
import math
import random
from typing import Callable, Dict, List, Mapping, Optional, Sequence, Tuple

from .registry_schema import StrategyDirection, StrategyVariant


class AmbiguousBarPolicy(str, Enum):
    STOP_FIRST = "STOP_FIRST"
    REQUIRE_FINER_DATA = "REQUIRE_FINER_DATA"


class TrialStatus(str, Enum):
    PENDING_ENTRY = "PENDING_ENTRY"
    OPEN = "OPEN"
    TARGET = "TARGET"
    STOP = "STOP"
    AMBIGUOUS_STOP_FIRST = "AMBIGUOUS_STOP_FIRST"
    FORCED_EXIT = "FORCED_EXIT"
    FAILED_NO_NEXT_BAR = "FAILED_NO_NEXT_BAR"
    FAILED_INVALID_SIGNAL = "FAILED_INVALID_SIGNAL"
    FAILED_POSITION_ALREADY_OPEN = "FAILED_POSITION_ALREADY_OPEN"
    FAILED_DATA_UNSAFE = "FAILED_DATA_UNSAFE"
    FAILED_AMBIGUOUS_BAR = "FAILED_AMBIGUOUS_BAR"


COMPLETED_STATUSES = {
    TrialStatus.TARGET,
    TrialStatus.STOP,
    TrialStatus.AMBIGUOUS_STOP_FIRST,
    TrialStatus.FORCED_EXIT,
}


@dataclass(frozen=True)
class Bar:
    timestamp: datetime
    open: float
    high: float
    low: float
    close: float
    volume: float = 0.0
    data_safe: bool = True

    def validate(self) -> Optional[str]:
        prices = (self.open, self.high, self.low, self.close)
        if not all(math.isfinite(v) and v > 0.0 for v in prices):
            return "non_finite_or_non_positive_price"
        if self.high < max(self.open, self.close, self.low):
            return "high_below_ohlc"
        if self.low > min(self.open, self.close, self.high):
            return "low_above_ohlc"
        if not math.isfinite(self.volume) or self.volume < 0.0:
            return "invalid_volume"
        if not self.data_safe:
            return "data_safe_flag_false"
        return None


@dataclass(frozen=True)
class SignalIntent:
    quantity: float
    stop_distance: float
    target_distance: float
    plan_id: Optional[str] = None
    members: Tuple[str, ...] = ()

    def validate(self) -> Optional[str]:
        values = (self.quantity, self.stop_distance, self.target_distance)
        if not all(math.isfinite(v) for v in values):
            return "non_finite_signal_value"
        if self.quantity <= 0.0:
            return "quantity_must_be_positive"
        if self.stop_distance <= 0.0:
            return "stop_distance_must_be_positive"
        if self.target_distance <= 0.0:
            return "target_distance_must_be_positive"
        return None


SignalFn = Callable[[Sequence[Bar]], Optional[SignalIntent]]
ContextFn = Callable[[Bar], str]


@dataclass(frozen=True)
class StrategyRunner:
    variant: StrategyVariant
    signal_fn: SignalFn

    @property
    def runner_id(self) -> str:
        return self.variant.variant_id


@dataclass(frozen=True)
class BacktestConfig:
    commission_per_unit_per_side: float = 0.0
    slippage_per_unit_per_side: float = 0.0
    min_completed_trades: int = 10
    ambiguous_bar_policy: AmbiguousBarPolicy = AmbiguousBarPolicy.STOP_FIRST
    seed: int = 42

    def __post_init__(self) -> None:
        if self.commission_per_unit_per_side < 0.0:
            raise ValueError("commission cannot be negative")
        if self.slippage_per_unit_per_side < 0.0:
            raise ValueError("slippage cannot be negative")
        if self.min_completed_trades < 1:
            raise ValueError("min_completed_trades must be >= 1")


@dataclass
class TrialRecord:
    trial_id: str
    runner_id: str
    symbol: str
    direction: StrategyDirection
    signal_time: datetime
    context: str
    quantity: float
    stop_distance: float
    target_distance: float
    plan_id: str
    members: Tuple[str, ...]
    status: TrialStatus
    entry_time: Optional[datetime] = None
    exit_time: Optional[datetime] = None
    entry_price: Optional[float] = None
    exit_price: Optional[float] = None
    gross_pnl: Optional[float] = None
    net_pnl: Optional[float] = None
    total_costs: float = 0.0
    failure_reason: Optional[str] = None


@dataclass(frozen=True)
class PerformanceMetrics:
    attempts: int
    completed_trades: int
    failed_trials: int
    wins: int
    losses: int
    win_rate: float
    net_pnl: float
    expectancy_per_trade: float
    profit_factor: float
    eligible: bool
    eligibility_reason: Optional[str]


@dataclass(frozen=True)
class BacktestResult:
    seed: int
    trials: Tuple[TrialRecord, ...]
    metrics: Mapping[str, PerformanceMetrics]
    context_metrics: Mapping[str, Mapping[str, PerformanceMetrics]]
    baselines: Mapping[str, float]


@dataclass
class _PendingEntry:
    trial: TrialRecord
    entry_index: int


@dataclass
class _OpenPosition:
    trial: TrialRecord
    entry_index: int
    entry_price: float
    stop_price: float
    target_price: float


class CausalBacktestEngine:
    """Deterministic research backtester.

    Signals are generated only from bars available through index i. Any accepted
    signal enters at the next bar open (i+1), so the signal cannot use the
    execution bar. A coalition should be represented as one StrategyRunner and
    one SignalIntent/Position Plan; member strategies are metadata only and do
    not place independent orders inside this engine.
    """

    def __init__(self, config: BacktestConfig = BacktestConfig()) -> None:
        self.config = config
        self._rng = random.Random(config.seed)
        self._trial_counter = 0

    def _next_trial_id(self) -> str:
        self._trial_counter += 1
        return f"trial-{self.config.seed}-{self._trial_counter:08d}"

    def _validate_bars(self, bars: Sequence[Bar]) -> List[Optional[str]]:
        errors: List[Optional[str]] = []
        previous: Optional[datetime] = None
        for bar in bars:
            reason = bar.validate()
            if previous is not None and bar.timestamp <= previous:
                reason = reason or "timestamps_not_strictly_increasing"
            errors.append(reason)
            previous = bar.timestamp
        return errors

    def _entry_price(self, bar: Bar, direction: StrategyDirection) -> float:
        slip = self.config.slippage_per_unit_per_side
        return bar.open + slip if direction == StrategyDirection.LONG else bar.open - slip

    def _exit_price(self, raw_price: float, direction: StrategyDirection) -> float:
        slip = self.config.slippage_per_unit_per_side
        return raw_price - slip if direction == StrategyDirection.LONG else raw_price + slip

    def _prices_for_plan(
        self,
        entry_price: float,
        direction: StrategyDirection,
        intent: SignalIntent,
    ) -> Tuple[float, float]:
        if direction == StrategyDirection.LONG:
            return entry_price - intent.stop_distance, entry_price + intent.target_distance
        return entry_price + intent.stop_distance, entry_price - intent.target_distance

    def _close(
        self,
        position: _OpenPosition,
        raw_exit_price: float,
        exit_time: datetime,
        status: TrialStatus,
    ) -> None:
        trial = position.trial
        exit_price = self._exit_price(raw_exit_price, trial.direction)
        qty = trial.quantity
        if trial.direction == StrategyDirection.LONG:
            gross = (exit_price - position.entry_price) * qty
        else:
            gross = (position.entry_price - exit_price) * qty
        commissions = 2.0 * self.config.commission_per_unit_per_side * qty
        # Slippage is already embedded in entry/exit prices; expose it as cost
        # metadata too, without subtracting it a second time.
        slippage_cost = 2.0 * self.config.slippage_per_unit_per_side * qty
        trial.status = status
        trial.exit_time = exit_time
        trial.exit_price = exit_price
        trial.gross_pnl = gross + slippage_cost
        trial.total_costs = commissions + slippage_cost
        trial.net_pnl = gross - commissions

    def _evaluate_exit(self, position: _OpenPosition, bar: Bar) -> bool:
        direction = position.trial.direction
        if direction == StrategyDirection.LONG:
            stop_hit = bar.low <= position.stop_price
            target_hit = bar.high >= position.target_price
        else:
            stop_hit = bar.high >= position.stop_price
            target_hit = bar.low <= position.target_price

        if stop_hit and target_hit:
            if self.config.ambiguous_bar_policy == AmbiguousBarPolicy.REQUIRE_FINER_DATA:
                trial = position.trial
                trial.status = TrialStatus.FAILED_AMBIGUOUS_BAR
                trial.exit_time = bar.timestamp
                trial.failure_reason = "stop_and_target_touched_same_bar_requires_finer_data"
                return True
            self._close(position, position.stop_price, bar.timestamp, TrialStatus.AMBIGUOUS_STOP_FIRST)
            return True
        if stop_hit:
            self._close(position, position.stop_price, bar.timestamp, TrialStatus.STOP)
            return True
        if target_hit:
            self._close(position, position.target_price, bar.timestamp, TrialStatus.TARGET)
            return True
        return False

    def _record_failed_signal(
        self,
        runner: StrategyRunner,
        symbol: str,
        bar: Bar,
        context: str,
        intent: SignalIntent,
        status: TrialStatus,
        reason: str,
    ) -> TrialRecord:
        trial_id = self._next_trial_id()
        members = intent.members or (runner.runner_id,)
        trial = TrialRecord(
            trial_id=trial_id,
            runner_id=runner.runner_id,
            symbol=symbol,
            direction=runner.variant.direction,
            signal_time=bar.timestamp,
            context=context,
            quantity=intent.quantity,
            stop_distance=intent.stop_distance,
            target_distance=intent.target_distance,
            plan_id=intent.plan_id or trial_id,
            members=members,
            status=status,
            failure_reason=reason,
        )
        return trial

    def _run_runner_symbol(
        self,
        symbol: str,
        bars: Sequence[Bar],
        bar_errors: Sequence[Optional[str]],
        runner: StrategyRunner,
        context_fn: ContextFn,
        ledger: List[TrialRecord],
    ) -> None:
        if symbol not in runner.variant.identity.supported_instruments:
            return

        pending: Optional[_PendingEntry] = None
        position: Optional[_OpenPosition] = None

        for i, bar in enumerate(bars):
            context = context_fn(bar)

            if pending is not None and pending.entry_index == i:
                trial = pending.trial
                if bar_errors[i] is not None:
                    trial.status = TrialStatus.FAILED_DATA_UNSAFE
                    trial.failure_reason = f"entry_bar_unsafe:{bar_errors[i]}"
                    pending = None
                else:
                    entry_price = self._entry_price(bar, trial.direction)
                    intent = SignalIntent(
                        quantity=trial.quantity,
                        stop_distance=trial.stop_distance,
                        target_distance=trial.target_distance,
                        plan_id=trial.plan_id,
                        members=trial.members,
                    )
                    stop_price, target_price = self._prices_for_plan(entry_price, trial.direction, intent)
                    trial.status = TrialStatus.OPEN
                    trial.entry_time = bar.timestamp
                    trial.entry_price = entry_price
                    position = _OpenPosition(
                        trial=trial,
                        entry_index=i,
                        entry_price=entry_price,
                        stop_price=stop_price,
                        target_price=target_price,
                    )
                    pending = None

            if position is not None and i >= position.entry_index:
                if bar_errors[i] is not None:
                    position.trial.status = TrialStatus.FAILED_DATA_UNSAFE
                    position.trial.exit_time = bar.timestamp
                    position.trial.failure_reason = f"position_bar_unsafe:{bar_errors[i]}"
                    position = None
                elif self._evaluate_exit(position, bar):
                    position = None

            history = bars[: i + 1]
            if bar_errors[i] is not None:
                continue

            intent = runner.signal_fn(history)
            if intent is None:
                continue
            validation_error = intent.validate()
            if validation_error is not None:
                ledger.append(
                    self._record_failed_signal(
                        runner,
                        symbol,
                        bar,
                        context,
                        intent,
                        TrialStatus.FAILED_INVALID_SIGNAL,
                        validation_error,
                    )
                )
                continue

            if pending is not None or position is not None:
                ledger.append(
                    self._record_failed_signal(
                        runner,
                        symbol,
                        bar,
                        context,
                        intent,
                        TrialStatus.FAILED_POSITION_ALREADY_OPEN,
                        "shared_position_plan_already_active",
                    )
                )
                continue

            if i + 1 >= len(bars):
                ledger.append(
                    self._record_failed_signal(
                        runner,
                        symbol,
                        bar,
                        context,
                        intent,
                        TrialStatus.FAILED_NO_NEXT_BAR,
                        "next_bar_required_for_causal_entry",
                    )
                )
                continue

            trial_id = self._next_trial_id()
            members = intent.members or (runner.runner_id,)
            trial = TrialRecord(
                trial_id=trial_id,
                runner_id=runner.runner_id,
                symbol=symbol,
                direction=runner.variant.direction,
                signal_time=bar.timestamp,
                context=context,
                quantity=intent.quantity,
                stop_distance=intent.stop_distance,
                target_distance=intent.target_distance,
                plan_id=intent.plan_id or trial_id,
                members=members,
                status=TrialStatus.PENDING_ENTRY,
            )
            ledger.append(trial)
            pending = _PendingEntry(trial=trial, entry_index=i + 1)

        if pending is not None:
            pending.trial.status = TrialStatus.FAILED_NO_NEXT_BAR
            pending.trial.failure_reason = "pending_entry_left_at_end_of_window"

        if position is not None:
            final_bar = bars[-1]
            if final_bar.validate() is None:
                self._close(position, final_bar.close, final_bar.timestamp, TrialStatus.FORCED_EXIT)
            else:
                position.trial.status = TrialStatus.FAILED_DATA_UNSAFE
                position.trial.failure_reason = "unsafe_final_bar_prevents_forced_exit"

    def _metrics_for(self, trials: Sequence[TrialRecord]) -> PerformanceMetrics:
        completed = [t for t in trials if t.status in COMPLETED_STATUSES and t.net_pnl is not None]
        failed = [t for t in trials if t.status not in COMPLETED_STATUSES]
        wins = sum(1 for t in completed if (t.net_pnl or 0.0) > 0.0)
        losses = sum(1 for t in completed if (t.net_pnl or 0.0) <= 0.0)
        net_pnl = sum(t.net_pnl or 0.0 for t in completed)
        win_rate = wins / len(completed) if completed else 0.0
        expectancy = net_pnl / len(completed) if completed else 0.0
        gross_profit = sum((t.net_pnl or 0.0) for t in completed if (t.net_pnl or 0.0) > 0.0)
        gross_loss = -sum((t.net_pnl or 0.0) for t in completed if (t.net_pnl or 0.0) < 0.0)
        if gross_loss == 0.0:
            profit_factor = math.inf if gross_profit > 0.0 else 0.0
        else:
            profit_factor = gross_profit / gross_loss
        eligible = len(completed) >= self.config.min_completed_trades
        return PerformanceMetrics(
            attempts=len(trials),
            completed_trades=len(completed),
            failed_trials=len(failed),
            wins=wins,
            losses=losses,
            win_rate=win_rate,
            net_pnl=net_pnl,
            expectancy_per_trade=expectancy,
            profit_factor=profit_factor,
            eligible=eligible,
            eligibility_reason=None if eligible else f"sample_size<{self.config.min_completed_trades}",
        )

    def _baselines(self, market: Mapping[str, Sequence[Bar]]) -> Dict[str, float]:
        baselines: Dict[str, float] = {}
        for symbol, bars in market.items():
            if len(bars) < 2:
                continue
            first = bars[0]
            last = bars[-1]
            if first.validate() is not None or last.validate() is not None:
                continue
            qty = 1.0
            commission = 2.0 * self.config.commission_per_unit_per_side * qty
            slip = self.config.slippage_per_unit_per_side
            long_entry = first.open + slip
            long_exit = last.close - slip
            short_entry = first.open - slip
            short_exit = last.close + slip
            baselines[f"{symbol}:BUY_HOLD_LONG"] = (long_exit - long_entry) * qty - commission
            baselines[f"{symbol}:BUY_HOLD_SHORT"] = (short_entry - short_exit) * qty - commission
        return baselines

    def run(
        self,
        market: Mapping[str, Sequence[Bar]],
        runners: Sequence[StrategyRunner],
        context_fn: Optional[ContextFn] = None,
    ) -> BacktestResult:
        # Reset deterministic state for every run so the same engine/config/input
        # is reproducible and does not inherit prior ledger/counter state.
        self._rng = random.Random(self.config.seed)
        self._trial_counter = 0
        context_fn = context_fn or (lambda _bar: "ALL")
        ledger: List[TrialRecord] = []

        normalized_market: Dict[str, Tuple[Bar, ...]] = {}
        errors_by_symbol: Dict[str, List[Optional[str]]] = {}
        for symbol in sorted(market):
            bars = tuple(market[symbol])
            normalized_market[symbol] = bars
            errors_by_symbol[symbol] = self._validate_bars(bars)

        # Stable order is important for deterministic trial ids and audit replay.
        for runner in sorted(runners, key=lambda r: r.runner_id):
            for symbol in sorted(normalized_market):
                bars = normalized_market[symbol]
                if not bars:
                    continue
                self._run_runner_symbol(
                    symbol,
                    bars,
                    errors_by_symbol[symbol],
                    runner,
                    context_fn,
                    ledger,
                )

        metrics: Dict[str, PerformanceMetrics] = {}
        context_metrics: Dict[str, Dict[str, PerformanceMetrics]] = {}
        for runner in sorted(runners, key=lambda r: r.runner_id):
            runner_trials = [t for t in ledger if t.runner_id == runner.runner_id]
            metrics[runner.runner_id] = self._metrics_for(runner_trials)
            contexts = sorted({t.context for t in runner_trials})
            context_metrics[runner.runner_id] = {
                ctx: self._metrics_for([t for t in runner_trials if t.context == ctx])
                for ctx in contexts
            }

        return BacktestResult(
            seed=self.config.seed,
            trials=tuple(ledger),
            metrics=metrics,
            context_metrics=context_metrics,
            baselines=self._baselines(normalized_market),
        )
