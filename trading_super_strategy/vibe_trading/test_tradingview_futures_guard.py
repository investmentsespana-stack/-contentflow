from __future__ import annotations

import pytest

from tradingview_futures_guard import (
    REQUIRED_TIMEFRAMES,
    assert_provider_symbol,
    build_snapshot_plan,
    resolve_route,
    validate_futures_tool,
    validate_timeframes,
)


@pytest.mark.parametrize(
    "root,exchange,symbol,category",
    [
        ("NQ", "CME", "NQ1!", "equity_index"),
        ("ES", "CME", "ES1!", "equity_index"),
        ("GC", "COMEX", "GC1!", "metals"),
        ("CL", "NYMEX", "CL1!", "energy"),
    ],
)
def test_canonical_futures_routes(root, exchange, symbol, category):
    route = resolve_route(root)
    assert route.exchange == exchange
    assert route.continuous_symbol == symbol
    assert route.category == category


@pytest.mark.parametrize(
    "root,tool",
    [
        ("NQ", "coin_analysis"),
        ("ES", "multi_timeframe_analysis"),
        ("GC", "combined_analysis"),
        ("CL", "multi_agent_analysis"),
    ],
)
def test_generic_analysis_tools_are_blocked_for_futures(root, tool):
    with pytest.raises(ValueError, match="FUTURES_TOOL_BLOCKED"):
        validate_futures_tool(root, tool)


@pytest.mark.parametrize("root", ["NQ", "ES", "GC", "CL"])
def test_futures_snapshot_tool_is_allowed(root):
    route = validate_futures_tool(root, "futures_category_snapshot")
    assert route.root == root


def test_gc_cannot_be_substituted_with_spot_gold():
    with pytest.raises(ValueError, match="FUTURES_SYMBOL_MISMATCH"):
        assert_provider_symbol("GC", "TVC:GOLD")


def test_nq_cannot_fall_back_to_kucoin():
    with pytest.raises(ValueError, match="FUTURES_SYMBOL_MISMATCH"):
        assert_provider_symbol("NQ", "KUCOIN:NQ1!")


@pytest.mark.parametrize(
    "root,symbol",
    [
        ("NQ", "CME:NQ1!"),
        ("ES", "CME:ES1!"),
        ("GC", "COMEX:GC1!"),
        ("CL", "NYMEX:CL1!"),
    ],
)
def test_expected_provider_symbols_pass(root, symbol):
    assert assert_provider_symbol(root, symbol) == symbol


def test_required_multitimeframe_set_is_exact():
    assert validate_timeframes(REQUIRED_TIMEFRAMES) == REQUIRED_TIMEFRAMES
    with pytest.raises(ValueError, match="FUTURES_TIMEFRAME_SET_INVALID"):
        validate_timeframes(("5m", "15m", "1h"))


def test_snapshot_plan_covers_all_categories_and_no_trade_mode():
    plan = build_snapshot_plan()
    assert plan["mode"] == "RESEARCH_ONLY"
    assert {x["category"] for x in plan["snapshot_calls"]} == {
        "equity_index",
        "metals",
        "energy",
    }
    assert plan["roots"]["GC"]["qualified_symbol"] == "COMEX:GC1!"
    assert plan["roots"]["CL"]["qualified_symbol"] == "NYMEX:CL1!"
    assert "coin_analysis" in plan["blocked_tools"]
