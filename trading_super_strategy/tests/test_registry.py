from __future__ import annotations

import unittest
from dataclasses import replace

from trading_super_strategy.registry import StrategyLifecycleState, TradingRegistry
from trading_super_strategy.registry_schema import (
    DataRequirement,
    DataRequirementType,
    DirectionalStats,
    HorizonUnit,
    LineageMetadata,
    OutOfSampleMetrics,
    StrategyDirection,
    StrategyIdentity,
    StrategyRegime,
    StrategyVariant,
    TradingHorizon,
    TradingPremise,
)


def make_variant(
    canonical_id: str = "sweep-v1",
    direction: StrategyDirection = StrategyDirection.LONG,
    *,
    parent_variant_id: str | None = None,
    entry_rules: str = "sweep prior high then reclaim",
    stats: DirectionalStats | None = None,
) -> StrategyVariant:
    return StrategyVariant(
        identity=StrategyIdentity(
            family_id="liquidity-sweep",
            canonical_id=canonical_id,
            display_name="Liquidity Sweep",
            version="1.0.0",
            supported_instruments=("NQ", "MNQ"),
        ),
        direction=direction,
        premise=TradingPremise(
            premise="liquidity sweep and reclaim",
            entry_rules=entry_rules,
            exit_rules="structure invalidation or adaptive target",
            risk_rules="hard initial risk cap",
        ),
        regimes=(StrategyRegime.TRENDING_UP, StrategyRegime.EVENT),
        horizon=TradingHorizon(HorizonUnit.MINUTE, 30),
        data_requirements=(
            DataRequirement(
                DataRequirementType.PRICE_BAR,
                TradingHorizon(HorizonUnit.MINUTE, 120),
                0.99,
            ),
            DataRequirement(
                DataRequirementType.MBP,
                TradingHorizon(HorizonUnit.MINUTE, 30),
                0.98,
            ),
        ),
        lineage=LineageMetadata(
            origin="registry-certification",
            parent_variant_id=parent_variant_id,
            version_chain=("1.0.0",),
        ),
        stats=stats,
        oos=OutOfSampleMetrics(
            total_trades=50,
            win_rate=0.54,
            expectancy_r=0.11,
            profit_factor=1.24,
            max_drawdown_r=4.2,
        ),
    )


class RegistryCertificationTests(unittest.TestCase):
    def test_required_field_validation(self) -> None:
        with self.assertRaises(ValueError):
            StrategyIdentity("", "x", "x", "1", ("NQ",))
        with self.assertRaises(ValueError):
            TradingHorizon(HorizonUnit.MINUTE, 0)
        with self.assertRaises(ValueError):
            DataRequirement(
                DataRequirementType.PRICE_BAR,
                TradingHorizon(HorizonUnit.MINUTE, 1),
                1.1,
            )

    def test_long_short_variants_are_independent(self) -> None:
        registry = TradingRegistry()
        long_variant = make_variant(direction=StrategyDirection.LONG)
        short_variant = make_variant(direction=StrategyDirection.SHORT)
        long_record = registry.register(long_variant)
        short_record = registry.register(short_variant)
        self.assertNotEqual(long_record.variant_id, short_record.variant_id)
        self.assertNotEqual(long_record.content_hash, short_record.content_hash)
        self.assertIsNotNone(registry.get("sweep-v1", StrategyDirection.LONG))
        self.assertIsNotNone(registry.get("sweep-v1", StrategyDirection.SHORT))

    def test_hash_is_deterministic_and_ignores_measured_stats(self) -> None:
        base = make_variant()
        different_stats = DirectionalStats(
            total_trades=100,
            wins=60,
            losses=40,
            win_rate=0.60,
            expectancy_r=0.20,
            profit_factor=1.40,
            max_drawdown_r=5.0,
        )
        changed_measurements = replace(base, stats=different_stats)
        self.assertEqual(
            TradingRegistry.content_hash(base),
            TradingRegistry.content_hash(changed_measurements),
        )

    def test_exact_duplicate_definition_rejected_even_with_new_label(self) -> None:
        registry = TradingRegistry()
        base = make_variant(canonical_id="base")
        registry.register(base)
        relabeled = replace(
            base,
            identity=replace(
                base.identity,
                canonical_id="relabeled",
                display_name="Different Label",
                version="9.9.9",
            ),
            lineage=LineageMetadata(origin="other-source"),
        )
        with self.assertRaisesRegex(ValueError, "exact duplicate"):
            registry.register(relabeled)

    def test_near_clone_requires_explicit_parent_and_is_retained(self) -> None:
        registry = TradingRegistry()
        parent = make_variant(canonical_id="parent")
        registry.register(parent)
        child = make_variant(
            canonical_id="child",
            parent_variant_id=parent.variant_id,
            entry_rules="sweep prior high, reclaim, and positive delta confirmation",
        )
        registry.register(child)
        self.assertEqual(registry.children_of(parent.variant_id), [child.variant_id])

    def test_unknown_parent_rejected(self) -> None:
        registry = TradingRegistry()
        orphan = make_variant(canonical_id="orphan", parent_variant_id="missing:LONG")
        with self.assertRaisesRegex(ValueError, "parent variant"):
            registry.register(orphan)

    def test_lifecycle_is_sequential_and_live_promotions_are_forbidden(self) -> None:
        registry = TradingRegistry()
        variant = make_variant()
        registry.register(variant)
        ordered = [
            StrategyLifecycleState.GENERATED,
            StrategyLifecycleState.FAST_BACKTEST,
            StrategyLifecycleState.FILTERED,
            StrategyLifecycleState.OOS,
            StrategyLifecycleState.ROBUSTNESS,
            StrategyLifecycleState.ANTI_OVERFIT,
            StrategyLifecycleState.REGIME_TEST,
            StrategyLifecycleState.PORTFOLIO_FIT,
            StrategyLifecycleState.QA,
            StrategyLifecycleState.PAPER,
            StrategyLifecycleState.SHADOW,
        ]
        for state in ordered:
            registry.transition("sweep-v1", StrategyDirection.LONG, state)
        with self.assertRaisesRegex(ValueError, "LIVE_LIMITED"):
            registry.transition(
                "sweep-v1", StrategyDirection.LONG, StrategyLifecycleState.LIVE_LIMITED
            )
        with self.assertRaisesRegex(ValueError, "ACTIVE"):
            registry.transition(
                "sweep-v1", StrategyDirection.LONG, StrategyLifecycleState.ACTIVE
            )

    def test_illegal_skip_rejected(self) -> None:
        registry = TradingRegistry()
        registry.register(make_variant())
        with self.assertRaisesRegex(ValueError, "illegal lifecycle transition"):
            registry.transition("sweep-v1", StrategyDirection.LONG, StrategyLifecycleState.OOS)

    def test_quarantine_and_retire_are_fail_safe(self) -> None:
        registry = TradingRegistry()
        registry.register(make_variant())
        record = registry.transition(
            "sweep-v1", StrategyDirection.LONG, StrategyLifecycleState.QUARANTINED
        )
        self.assertEqual(record.lifecycle, StrategyLifecycleState.QUARANTINED)
        record = registry.transition(
            "sweep-v1", StrategyDirection.LONG, StrategyLifecycleState.RETIRED
        )
        self.assertEqual(record.lifecycle, StrategyLifecycleState.RETIRED)

    def test_no_execution_capability_on_registry_public_api(self) -> None:
        forbidden = ("order", "broker", "execute", "position", "submit")
        public = [name.lower() for name in dir(TradingRegistry) if not name.startswith("_")]
        for name in public:
            for keyword in forbidden:
                self.assertNotIn(keyword, name)


if __name__ == "__main__":
    unittest.main()
