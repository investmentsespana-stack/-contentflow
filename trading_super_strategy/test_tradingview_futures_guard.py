from __future__ import annotations

import sys
import unittest
from pathlib import Path

VIBE_DIR = Path(__file__).resolve().parent / "vibe_trading"
if str(VIBE_DIR) not in sys.path:
    sys.path.insert(0, str(VIBE_DIR))

from tradingview_futures_guard import (  # noqa: E402
    REQUIRED_TIMEFRAMES,
    assert_provider_symbol,
    build_snapshot_plan,
    resolve_route,
    validate_futures_tool,
    validate_timeframes,
)


class TradingViewFuturesGuardCITests(unittest.TestCase):
    def test_routes_are_futures_native(self):
        expected = {
            "NQ": "CME:NQ1!",
            "ES": "CME:ES1!",
            "GC": "COMEX:GC1!",
            "CL": "NYMEX:CL1!",
        }
        for root, qualified in expected.items():
            with self.subTest(root=root):
                route = resolve_route(root)
                self.assertEqual(route.qualified_symbol, qualified)
                self.assertEqual(assert_provider_symbol(root, qualified), qualified)

    def test_crypto_and_spot_fallbacks_are_blocked(self):
        with self.assertRaises(ValueError):
            assert_provider_symbol("NQ", "KUCOIN:NQ1!")
        with self.assertRaises(ValueError):
            assert_provider_symbol("GC", "TVC:GOLD")
        for root in ("NQ", "ES", "GC", "CL"):
            with self.subTest(root=root):
                with self.assertRaisesRegex(ValueError, "FUTURES_TOOL_BLOCKED"):
                    validate_futures_tool(root, "coin_analysis")

    def test_required_timeframes_and_snapshot_plan(self):
        self.assertEqual(validate_timeframes(REQUIRED_TIMEFRAMES), REQUIRED_TIMEFRAMES)
        plan = build_snapshot_plan()
        self.assertEqual(plan["mode"], "RESEARCH_ONLY")
        self.assertEqual(
            [x["category"] for x in plan["snapshot_calls"]],
            ["equity_index", "metals", "energy"],
        )
        self.assertIn("coin_analysis", plan["blocked_tools"])


if __name__ == "__main__":
    unittest.main()
