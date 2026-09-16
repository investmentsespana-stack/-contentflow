from __future__ import annotations

from dataclasses import dataclass
import math
from statistics import pstdev
from typing import Callable, Dict, Sequence, Tuple

from .backtest_engine import Bar, SignalIntent, StrategyRunner
from .registry_schema import (
    DataRequirement,
    DataRequirementType,
    HorizonUnit,
    LineageMetadata,
    StrategyDirection,
    StrategyIdentity,
    StrategyRegime,
    StrategyVariant,
    TradingHorizon,
    TradingPremise,
)


# Frozen coarse research grid. These are hypotheses, not optimized parameters.
# Any later expansion must be registered as a new experiment family so DSR/PBO
# includes every trial rather than only the winners.
R1_FROZEN_GRID: Dict[str, Tuple[object, ...]] = {
    "past_return_sign": (20, 60),
    "ma_crossover": ((10, 30), (20, 60)),
    "channel_breakout": (20, 55),
    "vol_scaled_trend": ((20, 1.0), (60, 1.0)),
}


@dataclass(frozen=True)
class TrendRiskConfig:
    atr_lookback: int = 14
    stop_atr: float = 1.5
    target_atr: float = 2.0
    quantity: float = 1.0

    def __post_init__(self) -> None:
        if self.atr_lookback < 2:
            raise ValueError("atr_lookback must be >= 2")
        if self.stop_atr <= 0.0 or self.target_atr <= 0.0:
            raise ValueError("ATR risk multiples must be positive")
        if self.quantity <= 0.0:
            raise ValueError("quantity must be positive")


def _atr(history: Sequence[Bar], lookback: int) -> float | None:
    if len(history) < lookback + 1:
        return None
    true_ranges = []
    start = len(history) - lookback
    for i in range(start, len(history)):
        bar = history[i]
        prev_close = history[i - 1].close
        true_ranges.append(
            max(
                bar.high - bar.low,
                abs(bar.high - prev_close),
                abs(bar.low - prev_close),
            )
        )
    value = sum(true_ranges) / len(true_ranges)
    return value if math.isfinite(value) and value > 0.0 else None


def _intent(history: Sequence[Bar], risk: TrendRiskConfig, plan_id: str) -> SignalIntent | None:
    atr = _atr(history, risk.atr_lookback)
    if atr is None:
        return None
    return SignalIntent(
        quantity=risk.quantity,
        stop_distance=risk.stop_atr * atr,
        target_distance=risk.target_atr * atr,
        plan_id=plan_id,
    )


def _direction_matches(value: float, direction: StrategyDirection) -> bool:
    return value > 0.0 if direction == StrategyDirection.LONG else value < 0.0


def past_return_sign_signal(
    direction: StrategyDirection,
    lookback: int,
    risk: TrendRiskConfig = TrendRiskConfig(),
) -> Callable[[Sequence[Bar]], SignalIntent | None]:
    """Signal only when the lookback return crosses into the requested sign.

    The signal uses only fully closed bars through history[-1]. Entry is handled
    by CausalBacktestEngine on the next bar open.
    """
    if lookback < 2:
        raise ValueError("lookback must be >= 2")

    def signal(history: Sequence[Bar]) -> SignalIntent | None:
        required = max(lookback + 2, risk.atr_lookback + 1)
        if len(history) < required:
            return None
        current = history[-1].close / history[-1 - lookback].close - 1.0
        previous = history[-2].close / history[-2 - lookback].close - 1.0
        if _direction_matches(current, direction) and not _direction_matches(previous, direction):
            return _intent(history, risk, f"r1-past-return-{lookback}")
        return None

    return signal


def _mean(values: Sequence[float]) -> float:
    return sum(values) / len(values)


def ma_crossover_signal(
    direction: StrategyDirection,
    fast: int,
    slow: int,
    risk: TrendRiskConfig = TrendRiskConfig(),
) -> Callable[[Sequence[Bar]], SignalIntent | None]:
    if fast < 2 or slow <= fast:
        raise ValueError("require 2 <= fast < slow")

    def signal(history: Sequence[Bar]) -> SignalIntent | None:
        required = max(slow + 1, risk.atr_lookback + 1)
        if len(history) < required:
            return None
        closes = [b.close for b in history]
        fast_now = _mean(closes[-fast:])
        slow_now = _mean(closes[-slow:])
        fast_prev = _mean(closes[-fast - 1:-1])
        slow_prev = _mean(closes[-slow - 1:-1])
        crossed_up = fast_now > slow_now and fast_prev <= slow_prev
        crossed_down = fast_now < slow_now and fast_prev >= slow_prev
        match = crossed_up if direction == StrategyDirection.LONG else crossed_down
        if match:
            return _intent(history, risk, f"r1-ma-{fast}-{slow}")
        return None

    return signal


def channel_breakout_signal(
    direction: StrategyDirection,
    lookback: int,
    risk: TrendRiskConfig = TrendRiskConfig(),
) -> Callable[[Sequence[Bar]], SignalIntent | None]:
    """Closed-bar Donchian-style breakout against the PRIOR lookback window."""
    if lookback < 2:
        raise ValueError("lookback must be >= 2")

    def signal(history: Sequence[Bar]) -> SignalIntent | None:
        required = max(lookback + 1, risk.atr_lookback + 1)
        if len(history) < required:
            return None
        prior = history[-lookback - 1:-1]
        upper = max(b.high for b in prior)
        lower = min(b.low for b in prior)
        current = history[-1]
        match = current.close > upper if direction == StrategyDirection.LONG else current.close < lower
        if match:
            return _intent(history, risk, f"r1-channel-{lookback}")
        return None

    return signal


def vol_scaled_trend_signal(
    direction: StrategyDirection,
    lookback: int,
    threshold: float,
    risk: TrendRiskConfig = TrendRiskConfig(),
) -> Callable[[Sequence[Bar]], SignalIntent | None]:
    """Return trend normalized by realized close-to-close volatility.

    A threshold of 1.0 means the lookback return must exceed one lookback unit
    of realized volatility after sqrt(time) scaling. The threshold grid is
    intentionally coarse and frozen for the first falsification pass.
    """
    if lookback < 3:
        raise ValueError("lookback must be >= 3")
    if threshold <= 0.0:
        raise ValueError("threshold must be positive")

    def score(closes: Sequence[float]) -> float | None:
        if len(closes) < lookback + 1:
            return None
        returns = [closes[i] / closes[i - 1] - 1.0 for i in range(len(closes) - lookback, len(closes))]
        vol = pstdev(returns)
        if not math.isfinite(vol) or vol <= 0.0:
            return None
        total_return = closes[-1] / closes[-1 - lookback] - 1.0
        return total_return / (vol * math.sqrt(lookback))

    def signal(history: Sequence[Bar]) -> SignalIntent | None:
        required = max(lookback + 2, risk.atr_lookback + 1)
        if len(history) < required:
            return None
        closes = [b.close for b in history]
        now = score(closes)
        prev = score(closes[:-1])
        if now is None or prev is None:
            return None
        signed_now = now if direction == StrategyDirection.LONG else -now
        signed_prev = prev if direction == StrategyDirection.LONG else -prev
        if signed_now > threshold and signed_prev <= threshold:
            return _intent(history, risk, f"r1-vol-trend-{lookback}-{threshold:g}")
        return None

    return signal


def make_r1_runner(
    *,
    family: str,
    direction: StrategyDirection,
    timeframe_minutes: int,
    parameters: object,
    instruments: Tuple[str, ...] = ("ES", "NQ", "YM", "RTY"),
    risk: TrendRiskConfig = TrendRiskConfig(),
) -> StrategyRunner:
    if timeframe_minutes < 1:
        raise ValueError("timeframe_minutes must be positive")
    if family not in R1_FROZEN_GRID:
        raise ValueError(f"unknown R1 family: {family}")
    if parameters not in R1_FROZEN_GRID[family]:
        raise ValueError("parameters are outside the frozen R1 research grid")

    if family == "past_return_sign":
        lookback = int(parameters)
        signal_fn = past_return_sign_signal(direction, lookback, risk)
        parameter_label = str(lookback)
    elif family == "ma_crossover":
        fast, slow = parameters  # type: ignore[misc]
        signal_fn = ma_crossover_signal(direction, int(fast), int(slow), risk)
        parameter_label = f"{fast}-{slow}"
    elif family == "channel_breakout":
        lookback = int(parameters)
        signal_fn = channel_breakout_signal(direction, lookback, risk)
        parameter_label = str(lookback)
    else:
        lookback, threshold = parameters  # type: ignore[misc]
        signal_fn = vol_scaled_trend_signal(direction, int(lookback), float(threshold), risk)
        parameter_label = f"{lookback}-{threshold:g}"

    canonical_id = f"R1_{family}_{parameter_label}_{timeframe_minutes}m"
    identity = StrategyIdentity(
        family_id="R1_TSMOM_TREND",
        canonical_id=canonical_id,
        display_name=f"R1 {family} {parameter_label} @ {timeframe_minutes}m",
        version="1.0.0",
        supported_instruments=instruments,
    )
    premise = TradingPremise(
        premise="Directional persistence may continue after a causal trend-state transition.",
        entry_rules="Use only closed bars; signal a preregistered trend transition; enter next bar open.",
        exit_rules="Initial falsification uses fixed ATR-normalized stop/target; no trailing optimization.",
        risk_rules=f"Stop={risk.stop_atr:g} ATR, target={risk.target_atr:g} ATR, quantity={risk.quantity:g}.",
    )
    variant = StrategyVariant(
        identity=identity,
        direction=direction,
        premise=premise,
        regimes=(StrategyRegime.TRENDING_UP, StrategyRegime.TRENDING_DOWN, StrategyRegime.HIGH_VOLATILITY, StrategyRegime.LOW_VOLATILITY),
        horizon=TradingHorizon(HorizonUnit.MINUTE, timeframe_minutes),
        data_requirements=(
            DataRequirement(DataRequirementType.PRICE_BAR, TradingHorizon(HorizonUnit.MINUTE, timeframe_minutes * 60), 0.99),
        ),
        lineage=LineageMetadata(origin="ROBUST_STRATEGY_SCREEN_V1:R1"),
    )
    return StrategyRunner(variant=variant, signal_fn=signal_fn)
