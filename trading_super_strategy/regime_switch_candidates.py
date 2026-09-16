from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
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


class R2Mode(str, Enum):
    TREND = "TREND"
    MEAN_REVERSION = "MEAN_REVERSION"
    NO_TRADE = "NO_TRADE"


# Frozen, deliberately tiny regime grid. Every later expansion must be logged as
# a new experiment family so DSR/PBO counts the additional research attempts.
R2_FROZEN_GRID: Dict[str, Tuple[object, ...]] = {
    "er_switch": (
        (20, 20, 0.60, 0.25, 1.50),
        (60, 20, 0.60, 0.25, 1.50),
    ),
}


@dataclass(frozen=True)
class R2RiskConfig:
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


@dataclass(frozen=True)
class RegimeSnapshot:
    mode: R2Mode
    efficiency_ratio: float
    signed_move: float
    zscore: float | None


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


def _intent(history: Sequence[Bar], risk: R2RiskConfig, plan_id: str) -> SignalIntent | None:
    atr = _atr(history, risk.atr_lookback)
    if atr is None:
        return None
    return SignalIntent(
        quantity=risk.quantity,
        stop_distance=risk.stop_atr * atr,
        target_distance=risk.target_atr * atr,
        plan_id=plan_id,
    )


def _efficiency_ratio(closes: Sequence[float], lookback: int) -> tuple[float, float] | None:
    if len(closes) < lookback + 1:
        return None
    window = closes[-lookback - 1 :]
    signed_move = window[-1] - window[0]
    path = sum(abs(window[i] - window[i - 1]) for i in range(1, len(window)))
    if not math.isfinite(path) or path <= 0.0:
        return 0.0, 0.0
    er = abs(signed_move) / path
    return max(0.0, min(1.0, er)), signed_move


def _prior_window_zscore(closes: Sequence[float], lookback: int) -> float | None:
    if len(closes) < lookback + 1:
        return None
    prior = closes[-lookback - 1 : -1]
    mean = sum(prior) / len(prior)
    sd = pstdev(prior)
    if not math.isfinite(sd) or sd <= 0.0:
        return None
    return (closes[-1] - mean) / sd


def classify_r2_regime(
    history: Sequence[Bar],
    *,
    trend_lookback: int,
    range_lookback: int,
    trend_er: float,
    range_er: float,
) -> RegimeSnapshot | None:
    """Classify a closed-bar market state with a causal efficiency-ratio gate.

    ER >= trend_er routes to TREND; ER <= range_er routes to MEAN_REVERSION;
    the gap in between is intentionally NO_TRADE. Z-score is measured against
    the prior window so the current closed bar cannot move its own reference.
    """
    if trend_lookback < 3 or range_lookback < 3:
        raise ValueError("lookbacks must be >= 3")
    if not 0.0 <= range_er < trend_er <= 1.0:
        raise ValueError("require 0 <= range_er < trend_er <= 1")

    closes = [b.close for b in history]
    er_result = _efficiency_ratio(closes, trend_lookback)
    if er_result is None:
        return None
    er, signed_move = er_result
    zscore = _prior_window_zscore(closes, range_lookback)

    if er >= trend_er:
        mode = R2Mode.TREND
    elif er <= range_er:
        mode = R2Mode.MEAN_REVERSION
    else:
        mode = R2Mode.NO_TRADE
    return RegimeSnapshot(mode=mode, efficiency_ratio=er, signed_move=signed_move, zscore=zscore)


def regime_switch_signal(
    direction: StrategyDirection,
    *,
    trend_lookback: int,
    range_lookback: int,
    trend_er: float,
    range_er: float,
    mean_reversion_z: float,
    risk: R2RiskConfig = R2RiskConfig(),
) -> Callable[[Sequence[Bar]], SignalIntent | None]:
    if mean_reversion_z <= 0.0:
        raise ValueError("mean_reversion_z must be positive")

    def snapshot(history: Sequence[Bar]) -> RegimeSnapshot | None:
        return classify_r2_regime(
            history,
            trend_lookback=trend_lookback,
            range_lookback=range_lookback,
            trend_er=trend_er,
            range_er=range_er,
        )

    def trend_matches(state: RegimeSnapshot) -> bool:
        if state.mode != R2Mode.TREND:
            return False
        return state.signed_move > 0.0 if direction == StrategyDirection.LONG else state.signed_move < 0.0

    def mr_matches(state: RegimeSnapshot) -> bool:
        if state.mode != R2Mode.MEAN_REVERSION or state.zscore is None:
            return False
        if direction == StrategyDirection.LONG:
            return state.zscore <= -mean_reversion_z
        return state.zscore >= mean_reversion_z

    def signal(history: Sequence[Bar]) -> SignalIntent | None:
        required = max(trend_lookback + 2, range_lookback + 2, risk.atr_lookback + 1)
        if len(history) < required:
            return None

        current = snapshot(history)
        previous = snapshot(history[:-1])
        if current is None or previous is None:
            return None

        # Trend expert fires only when entering the requested directional trend,
        # not on every bar that remains trending.
        if trend_matches(current) and not trend_matches(previous):
            return _intent(
                history,
                risk,
                f"r2-trend-er{trend_lookback}-{trend_er:g}",
            )

        # Mean-reversion expert fires only on the first closed-bar excursion
        # through the preregistered z threshold while the ER state is ranging.
        if mr_matches(current) and not mr_matches(previous):
            return _intent(
                history,
                risk,
                f"r2-mr-z{range_lookback}-{mean_reversion_z:g}",
            )

        # Deliberate abstention is part of the strategy, not a missing signal.
        return None

    return signal


def make_r2_runner(
    *,
    direction: StrategyDirection,
    timeframe_minutes: int,
    parameters: object,
    instruments: Tuple[str, ...] = ("ES", "NQ", "YM", "RTY"),
) -> StrategyRunner:
    if timeframe_minutes < 1:
        raise ValueError("timeframe_minutes must be positive")
    if parameters not in R2_FROZEN_GRID["er_switch"]:
        raise ValueError("parameters are outside the frozen R2 research grid")

    trend_lookback, range_lookback, trend_er, range_er, mean_reversion_z = parameters  # type: ignore[misc]
    trend_lookback = int(trend_lookback)
    range_lookback = int(range_lookback)
    trend_er = float(trend_er)
    range_er = float(range_er)
    mean_reversion_z = float(mean_reversion_z)

    signal_fn = regime_switch_signal(
        direction,
        trend_lookback=trend_lookback,
        range_lookback=range_lookback,
        trend_er=trend_er,
        range_er=range_er,
        mean_reversion_z=mean_reversion_z,
    )

    canonical_id = (
        f"R2_ER_SWITCH_T{trend_lookback}_R{range_lookback}_"
        f"TE{trend_er:g}_RE{range_er:g}_Z{mean_reversion_z:g}_{timeframe_minutes}m"
    )
    identity = StrategyIdentity(
        family_id="R2_REGIME_SWITCH",
        canonical_id=canonical_id,
        display_name=f"R2 ER regime switch {trend_lookback}/{range_lookback} @ {timeframe_minutes}m",
        version="1.0.0",
        supported_instruments=instruments,
    )
    premise = TradingPremise(
        premise="Trend and mean-reversion edges are conditional on different causal market states; ambiguous states should abstain.",
        entry_rules="Closed bars only. ER routes TREND/MEAN_REVERSION/NO_TRADE; directional trend transitions or range z-score excursions enter next bar open.",
        exit_rules="Initial falsification uses fixed 1.5 ATR stop and 2.0 ATR target; no adaptive exits or trailing optimization.",
        risk_rules="Fixed quantity=1; stop=1.5 ATR(14), target=2.0 ATR(14).",
    )
    variant = StrategyVariant(
        identity=identity,
        direction=direction,
        premise=premise,
        regimes=(
            StrategyRegime.TRENDING_UP,
            StrategyRegime.TRENDING_DOWN,
            StrategyRegime.RANGING,
            StrategyRegime.HIGH_VOLATILITY,
            StrategyRegime.LOW_VOLATILITY,
        ),
        horizon=TradingHorizon(HorizonUnit.MINUTE, timeframe_minutes),
        data_requirements=(
            DataRequirement(
                DataRequirementType.PRICE_BAR,
                TradingHorizon(HorizonUnit.MINUTE, timeframe_minutes * 90),
                0.99,
            ),
        ),
        lineage=LineageMetadata(origin="ROBUST_STRATEGY_SCREEN_V1:R2"),
    )
    return StrategyRunner(variant=variant, signal_fn=signal_fn)
