from trading_super_strategy.cross_market_portfolio_engine import (
    StrategySeries,
    assess_addition,
    build_portfolio,
    evaluate_portfolio,
    leave_one_out,
)


def s(name, market, family, vals):
    return StrategySeries(
        strategy_id=name,
        market=market,
        family=family,
        timeframe="H1",
        daily_returns={f"2026-01-{i+1:02d}": v for i, v in enumerate(vals)},
    )


def test_rejects_highly_correlated_duplicate():
    gold_a = s("gold_a", "XAUUSD", "breakout", [1, -1, 1, -1, 1, -1, 1, -1])
    gold_clone = s("gold_clone", "XAUUSD", "breakout", [2, -2, 2, -2, 2, -2, 2, -2])
    d = assess_addition([gold_a], gold_clone, max_pairwise_corr=0.65)
    assert not d.accepted
    assert d.reason == "correlation_gate"


def test_accepts_different_market_with_offsetting_path():
    gold = s("gold", "XAUUSD", "breakout", [1, -1, 1, -1, 1, -1, 1, -1])
    nq = s("nq", "NQ", "trend", [-0.5, 1, -0.5, 1, -0.5, 1, -0.5, 1])
    d = assess_addition([gold], nq, max_pairwise_corr=0.95, max_dd_overlap=0.95)
    assert d.accepted
    assert d.reason == "diversifying_addition"


def test_market_balanced_portfolio_and_leave_one_out():
    strategies = [
        s("gold", "XAUUSD", "breakout", [1, -0.3, 0.8, -0.2, 1, -0.1]),
        s("nq", "NQ", "trend", [-0.2, 0.8, -0.1, 0.9, -0.2, 0.7]),
        s("dxy", "DXY", "mean_reversion", [0.3, 0.2, -0.1, 0.2, 0.3, -0.1]),
    ]
    m = evaluate_portfolio(strategies)
    assert len(m.members) == 3
    assert 0 < m.max_market_share <= 1
    loo = leave_one_out(strategies)
    assert set(loo) == {"gold", "nq", "dxy"}


def test_builder_respects_target_size():
    candidates = [
        s("gold", "XAUUSD", "breakout", [1, 0, 1, 0, 1, 0]),
        s("nq", "NQ", "trend", [0, 1, 0, 1, 0, 1]),
        s("dxy", "DXY", "mean_reversion", [0.2, 0.1, 0.2, 0.1, 0.2, 0.1]),
    ]
    selected, decisions = build_portfolio(candidates, target_size=2, max_pairwise_corr=0.99, max_dd_overlap=1.0)
    assert len(selected) == 2
    assert sum(d.accepted for d in decisions) == 2
