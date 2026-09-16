"""Fail-closed promotion gate for strategy/coalition research."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class PromotionPolicy:
    dsr_min: float = 0.95
    max_pbo: Optional[float] = None
    require_walk_forward: bool = True
    require_oos: bool = True
    require_cost_stress: bool = True
    require_registry_chain: bool = True


@dataclass(frozen=True)
class PromotionEvidence:
    dsr: Optional[float]
    pbo: Optional[float]
    walk_forward_passed: bool
    oos_passed: bool
    cost_stress_passed: bool
    registry_chain_valid: bool


@dataclass(frozen=True)
class PromotionDecision:
    allowed: bool
    reasons: tuple[str, ...]


def evaluate_promotion(evidence: PromotionEvidence, policy: PromotionPolicy) -> PromotionDecision:
    """Evaluate promotion. Missing thresholds/evidence block promotion."""
    reasons: list[str] = []
    if evidence.dsr is None:
        reasons.append("DSR_MISSING")
    elif evidence.dsr < policy.dsr_min:
        reasons.append(f"DSR_BELOW_{policy.dsr_min:.2f}")

    if policy.max_pbo is None:
        reasons.append("PBO_THRESHOLD_NOT_CONFIGURED")
    elif evidence.pbo is None:
        reasons.append("PBO_MISSING")
    elif evidence.pbo > policy.max_pbo:
        reasons.append("PBO_ABOVE_THRESHOLD")

    if policy.require_walk_forward and not evidence.walk_forward_passed:
        reasons.append("WALK_FORWARD_FAILED_OR_MISSING")
    if policy.require_oos and not evidence.oos_passed:
        reasons.append("OOS_FAILED_OR_MISSING")
    if policy.require_cost_stress and not evidence.cost_stress_passed:
        reasons.append("COST_STRESS_FAILED_OR_MISSING")
    if policy.require_registry_chain and not evidence.registry_chain_valid:
        reasons.append("EXPERIMENT_REGISTRY_INVALID")
    return PromotionDecision(allowed=not reasons, reasons=tuple(reasons))
