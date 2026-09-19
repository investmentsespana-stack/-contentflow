import importlib.util
import pathlib
import sys
import unittest

APP = pathlib.Path(__file__).with_name("app.py")
spec = importlib.util.spec_from_file_location("cygnus_sqx_bridge_app", APP)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
assert spec.loader is not None
spec.loader.exec_module(module)


class StartupGateTests(unittest.TestCase):
    def test_rejects_unresolved_resources(self):
        text = "Cannot start project.\nProject has unresolved resources."
        self.assertEqual(module._startup_failure_reason(text), "cannot_start_project")

    def test_rejects_spanish_start_failure(self):
        text = "No se puede iniciar el proyecto.\nProject has unresolved resources."
        self.assertEqual(module._startup_failure_reason(text), "cannot_start_project_es")

    def test_rejects_license_failure(self):
        self.assertEqual(module._startup_failure_reason("Check License FAILED"), "license_failed")

    def test_positive_start_marker(self):
        self.assertTrue(module._startup_marker_seen("Starting project 'NQ BREAKOUT FUTURES H1 - Tradestation'"))

    def test_no_false_positive_on_generic_output(self):
        self.assertIsNone(module._startup_failure_reason("Data loaded\nProjects loaded"))
        self.assertFalse(module._startup_marker_seen("Data loaded\nProjects loaded"))


if __name__ == "__main__":
    unittest.main()
