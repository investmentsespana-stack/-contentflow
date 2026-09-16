from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json

import numpy as np

from trading_super_strategy.governance.deflated_sharpe import deflated_sharpe_ratio
from trading_super_strategy.governance.experiment_registry import ExperimentRegistry, TrialRecord
from trading_super_strategy.governance.pbo_cscv import probability_of_backtest_overfitting
from trading_super_strategy.governance.promotion_gate import (
    PromotionEvidence,
    PromotionPolicy,
    evaluate_promotion,
)
from trading_super_strategy.multimodal.cross_attention import CrossAttentionContextEngine
from trading_super_strategy.multimodal.timestamp_guard import NewsEvent, PointInTimeNewsGuard


def test_multiple_trials_raise_dsr_benchmark_and_reduce_dsr():
    rng = np.random.default_rng(7)
    returns = rng.normal(0.0015, 0.01, size=500)
    one = deflated_sharpe_ratio(returns, trial_sharpes=[0.15])
    many_srs = np.linspace(-0.20, 0.35, 100)
    many = deflated_sharpe_ratio(returns, trial_sharpes=many_srs)
    assert many.benchmark_sharpe > one.benchmark_sharpe
    assert many.dsr < one.dsr
    assert 0.0 <= many.dsr <= 1.0


def test_registry_hash_chain_is_tamper_evident(tmp_path):
    path = tmp_path / "experiments.jsonl"
    registry = ExperimentRegistry(path)
    registry.append(
        TrialRecord(
            trial_id="T1",
            strategy_id="bb14_touch_3_9",
            code_version="abc",
            data_window={"start": "2026-01-01", "end": "2026-02-01"},
            config={"rr": 0.5},
            metrics={"sharpe": 0.2},
            status="RESEARCH",
        )
    )
    assert registry.verify_chain()
    row = json.loads(path.read_text(encoding="utf-8"))
    row["metrics"]["sharpe"] = 99.0
    path.write_text(json.dumps(row) + "\n", encoding="utf-8")
    assert not registry.verify_chain()


def test_pbo_returns_probability():
    rng = np.random.default_rng(11)
    matrix = rng.normal(0.0, 0.01, size=(120, 6))
    result = probability_of_backtest_overfitting(matrix, n_slices=6)
    assert 0.0 <= result.pbo <= 1.0
    assert result.n_combinations == 20


def test_future_news_is_never_visible_to_attention():
    now = datetime(2026, 9, 15, 14, 0, tzinfo=timezone.utc)
    past = NewsEvent(
        "past", "past headline", now - timedelta(minutes=2), now - timedelta(minutes=1),
        np.array([1.0, 0.0]), encoder_model_id="finbert:test",
    )
    future = NewsEvent(
        "future", "future headline", now + timedelta(minutes=1), now + timedelta(minutes=1),
        np.array([0.0, 1.0]), encoder_model_id="finbert:test",
    )
    assert tuple(e.event_id for e in PointInTimeNewsGuard.visible([past, future], now)) == ("past",)
    result = CrossAttentionContextEngine().attend(
        np.array([1.0, 0.0]), [past, future], decision_time=now
    )
    assert result.event_ids == ("past",)
    assert result.attention_weights == (1.0,)
    assert np.allclose(result.context_vector, [1.0, 0.0])


def test_promotion_gate_is_fail_closed_until_pbo_threshold_is_configured():
    evidence = PromotionEvidence(
        dsr=0.99,
        pbo=0.10,
        walk_forward_passed=True,
        oos_passed=True,
        cost_stress_passed=True,
        registry_chain_valid=True,
    )
    blocked = evaluate_promotion(evidence, PromotionPolicy())
    assert not blocked.allowed
    assert "PBO_THRESHOLD_NOT_CONFIGURED" in blocked.reasons

    allowed = evaluate_promotion(evidence, PromotionPolicy(max_pbo=0.20))
    assert allowed.allowed
