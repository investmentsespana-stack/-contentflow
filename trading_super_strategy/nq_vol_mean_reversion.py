from __future__ import annotations

from dataclasses import dataclass
import math
from statistics import pstdev
from typing import Callable, Sequence, Tuple

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


# One preregistered research hypothesis for the first falsification pass.
# Parameter perturbations belong to robustness testing and are not silently
# promoted as additional hand-picked strategy variants.
R3_FROZEN_PARAMETERS: Tuple[int, int, int, float, float] = (
    20,   # prior-window z-score lookback
    10,   # short realized-vol lookback
    60,   # long realized-vol lookback
    1.25, # maximum short/long volatility ratio allowed
    1.75, # z-score excursion threshold
)
R3_FROZEN_TIMEFRAMES: Tuple[int, ...] = (15,)


@dataclass(frozen=True)
class R3RiskConfig:
    atr_lookback: int = 14
    stop_atr: float = 1.5
    target_atr: float = 1.0
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
    values = []
    for i in range(len(history) - lookback, len(history)):
        bar = history[i]
        prev_close = history[i - 1].close
        values.append(
            max(
                bar.high - bar.low,
                abs(bar.high - prev_close),
                abs(bar.low - prev_close),
            )
        )
    value = sum(values) / len(values)
    return value if math.isfinite(value) and value > 0.0 else None


def _returns(closes: Sequence[float]) -> list[float]:
    return [closes[i] / closes[i - 1] - 1.0 for i in range(1, len(closes))]


def realized_vol_ratio(
    history: Sequence[Bar],
    *,
    short_lookback: int,
    long_lookback: int,
    exclude_current_bar: bool = True,
) -> float | None:
    """Return short/long realized-vol ratio using only already-closed bars.

    By default the current signal bar is excluded, so the volatility regime is
    known before evaluating the excursion on the current closed bar.
    """
    if short_lookback < 2 or long_lookback <= short_lookback:
        raise ValueError("require 2 <= short_lookback < long_lookback")
    bars = history[:-1] if exclude_current_bar else history
    closes = [b.close for b in bars]
    if len(closes) < long_lookback + 1:
        return None
    rets = _returns(closes[-long_lookback - 1 :])
    long_vol = pstdev(rets)
    short_vol = pstdev(rets[-short_lookback:])
    if not math.isfinite(long_vol) or long_vol <= 0.0:
        return None
    if not math.isfinite(short_vol):
        return None
    return short_vol / long_vol


def prior_window_zscore(history: Sequence[Bar], lookback: int) -> float | None:
    if lookback < 3:
        raise ValueError("lookback must be >= 3")
    closes = [b.close for b in history]
    if len(closes) < lookback + 1:
        return None
    prior = closes[-lookback - 1 : -1]
    mean = sum(prior) / len(prior)
    sd = pstdev(prior)
    if not math.isfinite(sd) or sd <= 0.0:
        return None
    return (closes[-1] - mean) / sd


def _intent(history: Sequence[Bar], risk: R3RiskConfig, plan_id: str) -> SignalIntent | None:
    atr = _atr(history, risk.atr_lookback)
    if atr is None:
        return None
    return SignalIntent(
        quantity=risk.quantity,
        stop_distance=risk.stop_atr * atr,
        target_distance=risk.target_atr * atr,
        plan_id=plan_id,
    )


def nq_vol_conditioned_mean_reversion_signal(
    direction: StrategyDirection,
    *,
    z_lookback: int,
    short_vol_lookback: int,
    long_vol_lookback: int,
    max_vol_ratio: float,
    z_threshold: float,
    risk: R3RiskConfig = R3RiskConfig(),
) -> Callable[[Sequence[Bar]], SignalIntent | None]:
    if max_vol_ratio <= 0.0:
        raise ValueError("max_vol_ratio must be positive")
    if z_threshold <= 0.0:
        raise ValueError("z_threshold must be positive")

    def extreme(z: float) -> bool:
        if direction == StrategyDirection.LONG:
            return z <= -z_threshold
        return z >= z_threshold

    def signal(history: Sequence[Bar]) -> SignalIntent | None:
        required = max(
            z_lookback + 2,
            long_vol_lookback + 2,
            risk.atr_lookback + 1,
        )
        if len(history) < required:
            return None

        vol_ratio = realized_vol_ratio(
            history,
            short_lookback=short_vol_lookback,
            long_lookback=long_vol_lookback,
            exclude_current_bar=True,
        )
        if vol_ratio is None or vol_ratio > max_vol_ratio:
            return None

        current_z = prior_window_zscore(history, z_lookback)
        previous_z = prior_window_zscore(history[:-1], z_lookback)
        if current_z is None or previous_z is None:
            return None

        # Emit only the first threshold crossing; do not re-enter every bar while
        # price remains stretched.
        if extreme(current_z) and not extreme(previous_z):
            side = "long" if direction == StrategyDirection.LONG else "short"
            return _intent(
                history,
                risk,
                f"r3-nq-vol-mr-{side}-z{z_lookback}-{z_threshold:g}-vr{max_vol_ratio:g}",
            )
        return None

    return signal


def make_r3_runner(
    *,
    direction: StrategyDirection,
    timeframe_minutes: int,
    parameters: object = R3_FROZEN_PARAMETERS,
) -> StrategyRunner:
    if timeframe_minutes not in R3_FROZEN_TIMEFRAMES:
        raise ValueError("timeframe is outside the frozen R3 research set")
    if parameters != R3_FROZEN_PARAMETERS:
        raise ValueError("parameters are outside the frozen R3 research hypothesis")

    z_lookback, short_vol, long_vol, max_ratio, z_threshold = R3_FROZEN_PARAMETERS
    signal_fn = nq_vol_conditioned_mean_reversion_signal(
        direction,
        z_lookback=z_lookback,
        short_vol_lookback=short_vol,
        long_vol_lookback=long_vol,
        max_vol_ratio=max_ratio,
        z_threshold=z_threshold,
    )

    canonical_id = (
        f"R3_NQ_VOL_MR_Z{z_lookback}_SV{short_vol}_LV{long_vol}_"
        f"VR{max_ratio:g}_ZT{z_threshold:g}_{timeframe_minutes}m"
    )
    identity = StrategyIdentity(
        family_id="R3_NQ_VOL_MEAN_REVERSION",
        canonical_id=canonical_id,
        display_name=f"R3 NQ vol-conditioned mean reversion @ {timeframe_minutes}m",
        version="1.0.0",
        supported_instruments=("NQ",),
    )
    premise = TradingPremise(
        premise="Short-horizon NQ price excursions may mean-revert when the pre-existing volatility regime is not expanding sharply.",
        entry_rules="Closed bars only. Pre-signal short/long realized-vol ratio must be <=1.25; first prior-window z-score excursion beyond +/-1.75 enters next bar open.",
        exit_rules="Initial falsification uses fixed ATR-normalized exit: 1.5 ATR stop, 1.0 ATR target; no trailing or adaptive exit optimization.",
        risk_rules="NQ only; fixed quantity=1; stop=1.5 ATR(14), target=1.0 ATR(14).",
    )
    variant = StrategyVariant(
        identity=identity,
        direction=direction,
        premise=premise,
        regimes=(StrategyRegime.RANGING, StrategyRegime.LOW_VOLATILITY),
        horizon=TradingHorizon(HorizonUnit.MINUTE, timeframe_minutes),
        data_requirements=(
            DataRequirement(
                DataRequirementType.PRICE_BAR,
                TradingHorizon(HorizonUnit.MINUTE, timeframe_minutes * 90),
                0.99,
            ),
        ),
        lineage=LineageMetadata(origin="ROBUST_STRATEGY_SCREEN_V1:R3"),
    )
    return StrategyRunner(variant=variant, signal_fn=signal_fn)
