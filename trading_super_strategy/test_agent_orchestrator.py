import unittest

from agent_orchestrator import DirectorOrchestrator, ResearchTask, TaskState, default_agent_pool


class DirectorOrchestratorTests(unittest.TestCase):
    def setUp(self):
        self.director = DirectorOrchestrator(default_agent_pool(), max_attempts_before_block=3)

    def test_routes_parallel_research_tasks_to_specialists(self):
        tasks = [
            ResearchTask("s1", "strategy_generation"),
            ResearchTask("c1", "coalition_discovery"),
            ResearchTask("b1", "backtest"),
            ResearchTask("r1", "monte_carlo"),
            ResearchTask("p1", "prop_firm_simulation"),
            ResearchTask("m1", "macro_context"),
            ResearchTask("o1", "microstructure_research"),
        ]
        assignments = self.director.assign_parallel(tasks)
        agents = {a.task_id: a.agent_name for a in assignments}
        self.assertEqual(agents["s1"], "strategy_builder")
        self.assertEqual(agents["c1"], "coalition_researcher")
        self.assertEqual(agents["b1"], "backtest_agent")
        self.assertEqual(agents["r1"], "robustness_agent")
        self.assertEqual(agents["p1"], "prop_firm_agent")
        self.assertEqual(agents["m1"], "macro_agent")
        self.assertEqual(agents["o1"], "microstructure_agent")
        self.assertTrue(all(t.state == TaskState.CLAIMED for t in tasks))

    def test_success_requires_verification_then_done(self):
        task = ResearchTask("b1", "backtest")
        self.director.assign(task)
        self.director.start(task)
        self.director.submit_for_review(task)
        decision = self.director.review(task, approved=True)
        self.assertTrue(decision.approved)
        self.assertEqual(task.state, TaskState.DONE)
        self.assertTrue(task.qa_approved)

    def test_qa_rejection_routes_to_rara(self):
        task = ResearchTask("b1", "backtest")
        self.director.assign(task)
        self.director.start(task)
        self.director.submit_for_review(task)
        decision = self.director.review(task, approved=False, reason="OOS_FAIL")
        self.assertFalse(decision.approved)
        self.assertEqual(decision.next_agent, "rara_repair")
        self.assertEqual(task.assigned_agent, "rara_repair")
        self.assertEqual(task.state, TaskState.CLAIMED)

    def test_live_execution_is_hard_blocked(self):
        task = ResearchTask("x1", "place_live_order", {"instrument": "MNQ", "side": "BUY"})
        with self.assertRaises(PermissionError):
            self.director.assign(task)
        self.assertEqual(task.state, TaskState.BLOCKED)

    def test_agent_pool_has_no_broker_authority(self):
        self.assertTrue(all(not a.can_execute_orders for a in default_agent_pool()))


if __name__ == "__main__":
    unittest.main()
