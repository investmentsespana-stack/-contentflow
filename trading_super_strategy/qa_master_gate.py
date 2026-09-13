from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Mapping, Sequence


REQUIRED_EVIDENCE_KEYS: Sequence[str] = (
    "strategy_registry",
    "backtest_engine",
    "coalition_discovery",
    "robustness_gate",
    "prop_firm",
    "macro_point_in_time",
    "microstructure",
    "execution_gateway",
)

REQUIRED_RR_GRID = (0.25, 0.40, 0.50, 0.70, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0)


@dataclass(frozen=True)
class QAEvidence:
    key: str
    runtime_verified: bool
    quality_score: float
    evidence_ref: str
    metadata: Mapping[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class CandidateMetrics:
    net_expectancy_r: float
    oos_positive: bool
    walk_forward_pass: bool
    monte_carlo_pass: bool
    pbo_pass: bool
    deflated_sharpe_pass: bool
    prop_firm_compatible: bool
    rr: float


@dataclass(frozen=True)
class QAMasterDecision:
    passed: bool
    reasons: List[str]


class EvidenceOnlyQAMasterGate:
    """Fail-closed auditor.

    It never reimplements registry/backtest/coalition logic. It only evaluates
    persisted evidence and candidate validation flags supplied by certified
    upstream components.
    """

    def audit(
        self,
        evidence: Mapping[str, QAEvidence],
        candidate: CandidateMetrics | None = None,
        live_money_enabled: bool = False,
        rr_grid: Sequence[float] = REQUIRED_RR_GRID,
    ) -> QAMasterDecision:
        reasons: List[str] = []

        if live_money_enabled:
            reasons.append("LIVE_MONEY_MUST_REMAIN_BLOCKED")

        missing = [key for key in REQUIRED_EVIDENCE_KEYS if key not in evidence]
        if missing:
            reasons.append("MISSING_EVIDENCE:" + ",".join(sorted(missing)))

        for key in REQUIRED_EVIDENCE_KEYS:
            item = evidence.get(key)
            if item is None:
                continue
            if not item.runtime_verified:
                reasons.append(f"RUNTIME_UNVERIFIED:{key}")
            if item.quality_score < 90:
                reasons.append(f"QUALITY_BELOW_90:{key}")
            if not item.evidence_ref.strip():
                reasons.append(f"MISSING_EVIDENCE_REF:{key}")

        normalized_grid = tuple(round(float(x), 2) for x in rr_grid)
        if normalized_grid != REQUIRED_RR_GRID:
            reasons.append("RR_GRID_INCOMPLETE_OR_CHANGED")

        if candidate is not None:
            if round(float(candidate.rr), 2) not in REQUIRED_RR_GRID:
                reasons.append("RR_NOT_IN_CERTIFIED_GRID")
            if candidate.net_expectancy_r <= 0:
                reasons.append("NON_POSITIVE_NET_EXPECTANCY")
            if not candidate.oos_positive:
                reasons.append("OOS_FAILED")
            if not candidate.walk_forward_pass:
                reasons.append("WALK_FORWARD_FAILED")
            if not candidate.monte_carlo_pass:
                reasons.append("MONTE_CARLO_FAILED")
            if not candidate.pbo_pass:
                reasons.append("PBO_FAILED")
            if not candidate.deflated_sharpe_pass:
                reasons.append("DEFLATED_SHARPE_FAILED")
            if not candidate.prop_firm_compatible:
                reasons.append("PROP_FIRM_INCOMPATIBLE")

        return QAMasterDecision(passed=not reasons, reasons=reasons)


# Runtime certification marker: this module is intentionally evidence-only.
