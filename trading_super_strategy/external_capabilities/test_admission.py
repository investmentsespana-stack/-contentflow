from __future__ import annotations

import json
import unittest
from pathlib import Path
import importlib.util

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("admission", HERE / "admission.py")
mod = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(mod)


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.registry = mod.load_registry()

    def test_registry_passes(self):
        self.assertEqual(mod.validate_registry(self.registry), [])

    def test_live_execution_is_fail_closed(self):
        tv = mod.capability(self.registry, "tradingview_mcp")
        self.assertFalse(mod.is_operation_allowed(tv, "place_order"))
        self.assertFalse(mod.is_operation_allowed(tv, "broker_login"))

    def test_research_runtime_allowed(self):
        graphify = mod.capability(self.registry, "graphify")
        self.assertTrue(mod.is_operation_allowed(graphify, "knowledge_graph"))

    def test_patterns_only_not_runtime(self):
        gateway = mod.capability(self.registry, "mcp_gateway")
        self.assertFalse(mod.is_operation_allowed(gateway, "run_tool"))

    def test_secret_redaction(self):
        value = "Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456"
        self.assertNotIn("abcdefghijklmnopqrstuvwxyz123456", mod.sanitize_text(value))


if __name__ == "__main__":
    unittest.main()
