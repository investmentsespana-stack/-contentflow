from __future__ import annotations

import unittest

from tradingview_futures_guard import (
    REQUIRED_TIMEFRAMES,
    assert_provider_symbol,
    build_snapshot_plan,
    codex_policy_text,
    resolve_route,
    validate_futures_tool,
    validate_timeframes,
)


class TradingViewFuturesGuardTests(unittest.TestCase):
    def test_canonical_futures_routes(self):
        expected = {
            "NQ": ("CME", "NQ1!", "equity_index"),
            "ES": ("CME", "ES1!", "equity_index"),
            "GC": ("COMEX", "GC1!", "metals"),
            "CL": ("NYMEX", "CL1!", "energy"),
        }
        for root, (exchange, symbol, category) in expected.items():
            with self.subTest(root=root):
                route = resolve_route(root)
                self.assertEqual(route.exchange, exchange)
                self.assertEqual(route.continuous_symbol, symbol)
                self.assertEqual(route.category, category)

    def test_generic_analysis_tools_are_blocked_for_futures(self):
        blocked = {
            "NQ": "coin_analysis",
            "ES": "multi_timeframe_analysis",
            "GC": "combined_analysis",
            "CL": "multi_agent_analysis",
        }
        for root, tool in blocked.items():
            with self.subTest(root=root, tool=tool):
                with self.assertRaisesRegex(ValueError, "FUTURES_TOOL_BLOCKED"):
                    validate_futures_tool(root, tool)

    def test_futures_snapshot_tool_is_allowed(self):
        for root in ("NQ", "ES", "GC", "CL"):
            with self.subTest(root=root):
                route = validate_futures_tool(root, "futures_category_snapshot")
                self.assertEqual(route.root, root)

    def test_gc_cannot_be_substituted_with_spot_gold(self):
        with self.assertRaisesRegex(ValueError, "FUTURES_SYMBOL_MISMATCH"):
            assert_provider_symbol("GC", "TVC:GOLD")

    def test_nq_cannot_fall_back_to_kucoin(self):
        with self.assertRaisesRegex(ValueError, "FUTURES_SYMBOL_MISMATCH"):
            assert_provider_symbol("NQ", "KUCOIN:NQ1!")

    def test_expected_provider_symbols_pass(self):
        expected = {
            "NQ": "CME:NQ1!",
            "ES": "CME:ES1!",
            "GC": "COMEX:GC1!",
            "CL": "NYMEX:CL1!",
        }
        for root, symbol in expected.items():
            with self.subTest(root=root):
                self.assertEqual(assert_provider_symbol(root, symbol), symbol)

    def test_required_multitimeframe_set_is_exact(self):
        self.assertEqual(validate_timeframes(REQUIRED_TIMEFRAMES), REQUIRED_TIMEFRAMES)
        with self.assertRaisesRegex(ValueError, "FUTURES_TIMEFRAME_SET_INVALID"):
            validate_timeframes(("5m", "15m", "1h"))


    def test_policy_pins_yahoo_and_handles_truncation_safely(self):
        policy = codex_policy_text()
        self.assertIn("source=yahoo", policy)
        self.assertIn("truncated=true is NOT evidence", policy)
        self.assertIn("max_rows=0", policy)
        self.assertIn("backtest tool reads its own full loader frame", policy)

    def test_snapshot_plan_covers_all_categories_and_no_trade_mode(self):
        plan = build_snapshot_plan()
        self.assertEqual(plan["mode"], "RESEARCH_ONLY")
        self.assertEqual(
            {x["category"] for x in plan["snapshot_calls"]},
            {"equity_index", "metals", "energy"},
        )
        self.assertEqual(plan["roots"]["GC"]["qualified_symbol"], "COMEX:GC1!")
        self.assertEqual(plan["roots"]["CL"]["qualified_symbol"], "NYMEX:CL1!")
        self.assertIn("coin_analysis", plan["blocked_tools"])


if __name__ == "__main__":
    unittest.main()
