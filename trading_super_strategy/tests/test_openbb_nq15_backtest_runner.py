from __future__ import annotations

import unittest

from trading_super_strategy.run_openbb_nq15_backtest import _runners


class OpenBBNQ15BacktestRunnerTests(unittest.TestCase):
    def test_runner_pool_is_frozen_and_complete(self):
        runners = _runners()
        self.assertEqual(len(runners), 22)
        ids = [runner.runner_id for runner in runners]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertTrue(all("NQ" in runner.variant.identity.supported_instruments for runner in runners))


if __name__ == "__main__":
    unittest.main()
