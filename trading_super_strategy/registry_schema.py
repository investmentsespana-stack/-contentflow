from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Optional, Tuple


class StrategyDirection(str, Enum):
    LONG = "LONG"
    SHORT = "SHORT"


class StrategyRegime(str, Enum):
    TRENDING_UP = "TRENDING_UP"
    TRENDING_DOWN = "TRENDING_DOWN"
    RANGING = "RANGING"
    HIGH_VOLATILITY = "HIGH_VOLATILITY"
    LOW_VOLATILITY = "LOW_VOLATILITY"
    EVENT = "EVENT"


class HorizonUnit(str, Enum):
    SECOND = "SECOND"
    MINUTE = "MINUTE"
    HOUR = "HOUR"
    DAY = "DAY"


class DataRequirementType(str, Enum):
    PRICE_BAR = "PRICE_BAR"
    TRADES = "TRADES"
    VOLUME = "VOLUME"
    MBP = "MBP"
    MBO = "MBO"
    MACRO = "MACRO"
    NEWS = "NEWS"
    CROSS_MARKET = "CROSS_MARKET"


@dataclass(frozen=True)
class TradingHorizon:
    unit: HorizonUnit
    count: int

    def __post_init__(self) -> None:
        if self.count <= 0:
            raise ValueError("horizon count must be positive")


@dataclass(frozen=True)
class DataRequirement:
    data_type: DataRequirementType
    lookback: TradingHorizon
    minimum_quality: float

    def __post_init__(self) -> None:
        if not 0.0 <= self.minimum_quality <= 1.0:
            raise ValueError("minimum_quality must be between 0 and 1")


@dataclass(frozen=True)
class StrategyIdentity:
    family_id: str
    canonical_id: str
    display_name: str
    version: str
    supported_instruments: Tuple[str, ...]

    def __post_init__(self) -> None:
        if not self.family_id.strip() or not self.canonical_id.strip():
            raise ValueError("family_id and canonical_id are required")
        if not self.version.strip():
            raise ValueError("version is required")
        if not self.supported_instruments:
            raise ValueError("supported_instruments cannot be empty")


@dataclass(frozen=True)
class TradingPremise:
    premise: str
    entry_rules: str
    exit_rules: str
    risk_rules: str

    def __post_init__(self) -> None:
        if not all(x.strip() for x in (self.premise, self.entry_rules, self.exit_rules, self.risk_rules)):
            raise ValueError("premise and all rules are required")


@dataclass(frozen=True)
class DirectionalStats:
    total_trades: int
    wins: int
    losses: int
    win_rate: float
    expectancy_r: float
    profit_factor: float
    max_drawdown_r: float

    def __post_init__(self) -> None:
        if self.total_trades < 0 or self.wins < 0 or self.losses < 0:
            raise ValueError("trade counts cannot be negative")
        if self.wins + self.losses > self.total_trades:
            raise ValueError("wins + losses cannot exceed total_trades")
        if not 0.0 <= self.win_rate <= 1.0:
            raise ValueError("win_rate must be between 0 and 1")
        if self.profit_factor < 0.0:
            raise ValueError("profit_factor cannot be negative")


@dataclass(frozen=True)
class OutOfSampleMetrics:
    total_trades: int
    win_rate: float
    expectancy_r: float
    profit_factor: float
    max_drawdown_r: float

    def __post_init__(self) -> None:
        if self.total_trades < 0:
            raise ValueError("total_trades cannot be negative")
        if not 0.0 <= self.win_rate <= 1.0:
            raise ValueError("win_rate must be between 0 and 1")
        if self.profit_factor < 0.0:
            raise ValueError("profit_factor cannot be negative")


@dataclass(frozen=True)
class LineageMetadata:
    origin: str
    parent_variant_id: Optional[str] = None
    version_chain: Tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not self.origin.strip():
            raise ValueError("origin is required")


@dataclass(frozen=True)
class StrategyVariant:
    identity: StrategyIdentity
    direction: StrategyDirection
    premise: TradingPremise
    regimes: Tuple[StrategyRegime, ...]
    horizon: TradingHorizon
    data_requirements: Tuple[DataRequirement, ...]
    lineage: LineageMetadata
    stats: Optional[DirectionalStats] = None
    oos: Optional[OutOfSampleMetrics] = None

    @property
    def variant_id(self) -> str:
        return f"{self.identity.canonical_id}:{self.direction.value}"

    def __post_init__(self) -> None:
        if not self.regimes:
            raise ValueError("at least one regime is required")
        if not self.data_requirements:
            raise ValueError("at least one data requirement is required")
