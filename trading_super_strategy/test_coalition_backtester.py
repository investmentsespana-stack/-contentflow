import unittest

from coalition_backtester import BacktestEvent, CoalitionBacktester, ContextKey


class CoalitionBacktesterTests(unittest.TestCase):
    def setUp(self):
        self.backtester = CoalitionBacktester()
        self.context = ContextKey("NQ", "new_york", "+0_30", "high", "trend", "expansion")

    def _events(self):
        events = []
        # LONG specialist pair A+B: B filters A's losing long signals.
        for _ in range(30):
            events.append(BacktestEvent(self.context, {"A": 1, "B": 1}, 0.5, -0.5, 0.02))
        for _ in range(10):
            events.append(BacktestEvent(self.context, {"A": 1, "B": 0}, -1.0, 0.2, 0.02))

        # SHORT specialist pair C+D: D filters C's losing short signals.
        for _ in range(30):
            events.append(BacktestEvent(self.context, {"C": -1, "D": -1}, -0.5, 0.5, 0.02))
        for _ in range(10):
            events.append(BacktestEvent(self.context, {"C": -1, "D": 0}, 0.2, -1.0, 0.02))
        return events

    def test_long_and_short_can_have_different_optimal_groups(self):
        results = self.backtester.search_long_short(
            self._events(),
            ["A", "B", "C", "D"],
            member_sizes=(2,),
            min_trades=20,
        )
        self.assertEqual(results[1][0].members, ("A", "B"))
        self.assertEqual(results[-1][0].members, ("C", "D"))
        self.assertGreater(results[1][0].win_rate_uplift, 0)
        self.assertGreater(results[-1][0].win_rate_uplift, 0)

    def test_coalition_uses_single_coordinated_return_after_costs(self):
        metrics = self.backtester.evaluate(self._events(), ("A", "B"), 1)
        self.assertEqual(metrics.trades, 30)
        self.assertAlmostEqual(metrics.expectancy_r, 0.48)
        self.assertEqual(metrics.win_rate, 1.0)

    def test_negative_expectancy_groups_are_not_promoted(self):
        bad = [
            BacktestEvent(self.context, {"A": 1, "B": 1}, -0.2, 0.0, 0.05)
            for _ in range(25)
        ]
        results = self.backtester.search(bad, ["A", "B"], 1, member_sizes=(2,), min_trades=20)
        self.assertEqual(results, [])


if __name__ == "__main__":
    unittest.main()
