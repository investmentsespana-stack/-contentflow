import math
import unittest

from trading_super_strategy.coalition_backtester import BacktestEvent, CoalitionBacktester, ContextKey


CTX = ContextKey("NQ", "ny", "open_0_30", "medium", "bullish", "normal")


def event(signals, long_r=1.0, short_r=-1.0, cost=0.03):
    return BacktestEvent(CTX, signals, long_r, short_r, cost)


class CoalitionBacktesterTests(unittest.TestCase):
    def test_long_short_independent(self):
        bt = CoalitionBacktester()
        events = [
            event({"a": 1, "b": 1}, 1.0, -1.0),
            event({"a": 1, "b": 1}, -1.0, 1.0),
            event({"a": -1, "b": -1}, 1.0, 1.0),
            event({"a": -1, "b": -1}, -1.0, -1.0),
        ]
        long_m = bt.evaluate(events, ("a", "b"), 1)
        short_m = bt.evaluate(events, ("a", "b"), -1)
        self.assertEqual(long_m.trades, 2)
        self.assertEqual(short_m.trades, 2)
        self.assertNotEqual(long_m.total_r, short_m.total_r)

    def test_costs_reduce_expectancy(self):
        bt = CoalitionBacktester()
        clean = [event({"a": 1, "b": 1}, 1.0, -1.0, 0.0) for _ in range(5)]
        costly = [event({"a": 1, "b": 1}, 1.0, -1.0, 0.2) for _ in range(5)]
        self.assertGreater(bt.evaluate(clean, ("a", "b"), 1).expectancy_r,
                           bt.evaluate(costly, ("a", "b"), 1).expectancy_r)

    def test_train_oos_requires_positive_oos_and_min_trades(self):
        bt = CoalitionBacktester()
        train = [event({"a": 1, "b": 1}, 1.0, -1.0, 0.0) for _ in range(30)]
        oos = [event({"a": 1, "b": 1}, 0.5, -1.0, 0.0) for _ in range(10)]
        survivors = bt.train_oos_search(train + oos, ["a", "b"], 1,
                                        train_fraction=0.75, member_sizes=(2,),
                                        min_train_trades=20, min_oos_trades=5)
        self.assertEqual(len(survivors), 1)
        self.assertGreater(survivors[0][1].expectancy_r, 0)

    def test_search_uses_single_coordinated_position_outcome(self):
        bt = CoalitionBacktester()
        events = [event({"a": 1, "b": 1}, 1.0, -1.0, 0.0) for _ in range(20)]
        result = bt.search(events, ["a", "b"], 1, member_sizes=(2,), min_trades=20)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].trades, 20)
        self.assertAlmostEqual(result[0].total_r, 20.0)

    def test_invalid_direction_fails_closed(self):
        bt = CoalitionBacktester()
        with self.assertRaises(ValueError):
            bt.returns_for([], ["a"], 0)


if __name__ == "__main__":
    unittest.main()
