import unittest

from trading_super_strategy.qa_master_gate import (
    CandidateMetrics,
    EvidenceOnlyQAMasterGate,
    QAEvidence,
    REQUIRED_EVIDENCE_KEYS,
    REQUIRED_RR_GRID,
)


def full_evidence():
    return {
        key: QAEvidence(
            key=key,
            runtime_verified=True,
            quality_score=95,
            evidence_ref=f"runtime://{key}/pass",
        )
        for key in REQUIRED_EVIDENCE_KEYS
    }


class QAMasterGateTests(unittest.TestCase):
    def setUp(self):
        self.gate = EvidenceOnlyQAMasterGate()

    def test_full_verified_evidence_passes_without_candidate(self):
        decision = self.gate.audit(full_evidence())
        self.assertTrue(decision.passed)
        self.assertEqual(decision.reasons, [])

    def test_missing_runtime_evidence_fails_closed(self):
        ev = full_evidence()
        ev["microstructure"] = QAEvidence("microstructure", False, 95, "runtime://micro/pass")
        decision = self.gate.audit(ev)
        self.assertFalse(decision.passed)
        self.assertIn("RUNTIME_UNVERIFIED:microstructure", decision.reasons)

    def test_live_money_is_always_blocked(self):
        decision = self.gate.audit(full_evidence(), live_money_enabled=True)
        self.assertFalse(decision.passed)
        self.assertIn("LIVE_MONEY_MUST_REMAIN_BLOCKED", decision.reasons)

    def test_sub_one_rr_high_win_proxy_still_fails_if_expectancy_negative(self):
        candidate = CandidateMetrics(
            net_expectancy_r=-0.01,
            oos_positive=True,
            walk_forward_pass=True,
            monte_carlo_pass=True,
            pbo_pass=True,
            deflated_sharpe_pass=True,
            prop_firm_compatible=True,
            rr=0.25,
        )
        decision = self.gate.audit(full_evidence(), candidate=candidate)
        self.assertFalse(decision.passed)
        self.assertIn("NON_POSITIVE_NET_EXPECTANCY", decision.reasons)

    def test_candidate_requires_all_statistical_gates(self):
        candidate = CandidateMetrics(
            net_expectancy_r=0.2,
            oos_positive=True,
            walk_forward_pass=True,
            monte_carlo_pass=True,
            pbo_pass=True,
            deflated_sharpe_pass=True,
            prop_firm_compatible=True,
            rr=0.70,
        )
        decision = self.gate.audit(full_evidence(), candidate=candidate)
        self.assertTrue(decision.passed)

    def test_rr_grid_is_exact_and_includes_sub_one_targets(self):
        self.assertEqual(REQUIRED_RR_GRID, (0.25, 0.40, 0.50, 0.70, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0))
        decision = self.gate.audit(full_evidence(), rr_grid=(0.5, 1.0, 2.0))
        self.assertFalse(decision.passed)
        self.assertIn("RR_GRID_INCOMPLETE_OR_CHANGED", decision.reasons)


if __name__ == "__main__":
    unittest.main()
