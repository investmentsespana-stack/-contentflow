from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, replace
from enum import Enum
from typing import Dict, Iterable, List, Optional, Set

from .registry_schema import StrategyDirection, StrategyVariant


class StrategyLifecycleState(str, Enum):
    IDEA = "IDEA"
    GENERATED = "GENERATED"
    FAST_BACKTEST = "FAST_BACKTEST"
    FILTERED = "FILTERED"
    OOS = "OOS"
    ROBUSTNESS = "ROBUSTNESS"
    ANTI_OVERFIT = "ANTI_OVERFIT"
    REGIME_TEST = "REGIME_TEST"
    PORTFOLIO_FIT = "PORTFOLIO_FIT"
    QA = "QA"
    PAPER = "PAPER"
    SHADOW = "SHADOW"
    LIVE_LIMITED = "LIVE_LIMITED"
    ACTIVE = "ACTIVE"
    QUARANTINED = "QUARANTINED"
    RETIRED = "RETIRED"


FORBIDDEN_V1_PROMOTIONS: Set[StrategyLifecycleState] = {
    StrategyLifecycleState.LIVE_LIMITED,
    StrategyLifecycleState.ACTIVE,
}

_SEQUENTIAL_NEXT = {
    StrategyLifecycleState.IDEA: StrategyLifecycleState.GENERATED,
    StrategyLifecycleState.GENERATED: StrategyLifecycleState.FAST_BACKTEST,
    StrategyLifecycleState.FAST_BACKTEST: StrategyLifecycleState.FILTERED,
    StrategyLifecycleState.FILTERED: StrategyLifecycleState.OOS,
    StrategyLifecycleState.OOS: StrategyLifecycleState.ROBUSTNESS,
    StrategyLifecycleState.ROBUSTNESS: StrategyLifecycleState.ANTI_OVERFIT,
    StrategyLifecycleState.ANTI_OVERFIT: StrategyLifecycleState.REGIME_TEST,
    StrategyLifecycleState.REGIME_TEST: StrategyLifecycleState.PORTFOLIO_FIT,
    StrategyLifecycleState.PORTFOLIO_FIT: StrategyLifecycleState.QA,
    StrategyLifecycleState.QA: StrategyLifecycleState.PAPER,
    StrategyLifecycleState.PAPER: StrategyLifecycleState.SHADOW,
}


@dataclass(frozen=True)
class RegisteredStrategy:
    variant: StrategyVariant
    content_hash: str
    lifecycle: StrategyLifecycleState = StrategyLifecycleState.IDEA

    @property
    def variant_id(self) -> str:
        return self.variant.variant_id


class TradingRegistry:
    """Research registry only. It intentionally has no broker/order/position execution API."""

    def __init__(self) -> None:
        self._records: Dict[str, RegisteredStrategy] = {}
        self._hash_index: Dict[str, str] = {}
        self._children_by_parent: Dict[str, List[str]] = {}

    @staticmethod
    def _stable(value):
        if isinstance(value, Enum):
            return value.value
        if isinstance(value, tuple):
            return [TradingRegistry._stable(x) for x in value]
        if isinstance(value, list):
            return [TradingRegistry._stable(x) for x in value]
        if isinstance(value, dict):
            return {k: TradingRegistry._stable(v) for k, v in value.items()}
        return value

    @classmethod
    def content_hash(cls, variant: StrategyVariant) -> str:
        """Hash the stable trading definition, not labels, lifecycle, lineage or measured stats."""
        definition = {
            "direction": variant.direction.value,
            "supported_instruments": list(variant.identity.supported_instruments),
            "premise": asdict(variant.premise),
            "regimes": [r.value for r in variant.regimes],
            "horizon": cls._stable(asdict(variant.horizon)),
            "data_requirements": [cls._stable(asdict(r)) for r in variant.data_requirements],
        }
        payload = json.dumps(definition, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    def register(self, variant: StrategyVariant) -> RegisteredStrategy:
        variant_id = variant.variant_id
        if variant_id in self._records:
            raise ValueError(f"directional variant already registered: {variant_id}")

        digest = self.content_hash(variant)
        duplicate_id = self._hash_index.get(digest)
        if duplicate_id is not None:
            raise ValueError(f"exact duplicate strategy definition: {duplicate_id}")

        parent = variant.lineage.parent_variant_id
        if parent is not None and parent not in self._records:
            raise ValueError(f"parent variant is not registered: {parent}")

        record = RegisteredStrategy(variant=variant, content_hash=digest)
        self._records[variant_id] = record
        self._hash_index[digest] = variant_id
        if parent is not None:
            self._children_by_parent.setdefault(parent, []).append(variant_id)
        return record

    def get(self, canonical_id: str, direction: StrategyDirection) -> Optional[RegisteredStrategy]:
        return self._records.get(f"{canonical_id}:{direction.value}")

    def get_by_variant_id(self, variant_id: str) -> Optional[RegisteredStrategy]:
        return self._records.get(variant_id)

    def children_of(self, parent_variant_id: str) -> List[str]:
        return list(self._children_by_parent.get(parent_variant_id, ()))

    def transition(
        self,
        canonical_id: str,
        direction: StrategyDirection,
        new_state: StrategyLifecycleState,
    ) -> RegisteredStrategy:
        if new_state in FORBIDDEN_V1_PROMOTIONS:
            raise ValueError(f"{new_state.value} promotion is forbidden in Registry V1")

        variant_id = f"{canonical_id}:{direction.value}"
        current = self._records.get(variant_id)
        if current is None:
            raise KeyError(variant_id)

        old = current.lifecycle
        allowed = False
        if new_state == StrategyLifecycleState.QUARANTINED and old != StrategyLifecycleState.RETIRED:
            allowed = True
        elif new_state == StrategyLifecycleState.RETIRED:
            allowed = True
        elif old == StrategyLifecycleState.QUARANTINED and new_state == StrategyLifecycleState.IDEA:
            allowed = True
        elif _SEQUENTIAL_NEXT.get(old) == new_state:
            allowed = True

        if not allowed:
            raise ValueError(f"illegal lifecycle transition: {old.value} -> {new_state.value}")

        updated = replace(current, lifecycle=new_state)
        self._records[variant_id] = updated
        return updated

    def all_records(self) -> Iterable[RegisteredStrategy]:
        return tuple(self._records.values())
