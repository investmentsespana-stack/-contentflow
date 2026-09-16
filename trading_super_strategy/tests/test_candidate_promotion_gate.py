import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class CandidatePromotionGateTest(unittest.TestCase):
    def test_agent_pool_and_status_are_fail_closed(self):
        config = json.loads((ROOT / "agent_pool_config.json").read_text(encoding="utf-8"))
        status = json.loads((ROOT / "candidate_falsification_status_v1.json").read_text(encoding="utf-8"))

        self.assertFalse(config["live_money"])
        self.assertFalse(config["order_execution_authority_for_agents"])

        gate = config["candidate_promotion_gate"]
        self.assertEqual(gate["mode"], "fail_closed")
        self.assertFalse(gate["promotion_allowed"])
        self.assertEqual(
            gate["status_file"],
            "trading_super_strategy/candidate_falsification_status_v1.json",
        )

        self.assertEqual(status["mode"], "RESEARCH_HOLD_FAIL_CLOSED")
        self.assertFalse(status["promotion_allowed"])
        self.assertFalse(status["live_money_allowed"])
        self.assertGreaterEqual(len(status["global_fail_closed_reasons"]), 1)
        self.assertGreaterEqual(len(status["required_next_evidence"]), 1)

        for candidate in status["candidates"].values():
            self.assertEqual(candidate["status"], "RESEARCH_HOLD")
            self.assertGreaterEqual(len(candidate["promotion_blockers"]), 1)


if __name__ == "__main__":
    unittest.main()
