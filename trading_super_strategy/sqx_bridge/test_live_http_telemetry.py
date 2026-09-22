import importlib.util
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

APP = pathlib.Path(__file__).with_name("app.py")
spec = importlib.util.spec_from_file_location("cygnus_sqx_bridge_live_telemetry", APP)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
assert spec.loader is not None
spec.loader.exec_module(module)


class DummyRuntime:
    def __init__(self, running=False):
        self._running = running

    def is_running(self):
        return self._running


class LiveTelemetryTests(unittest.TestCase):
    def test_parse_status_metrics(self):
        text = """
        Strategies generated                         12345
        Rejected                                    98.50 %
        Accepted                                     1.50 %
        Failed                                          12
        Passed                                         185
        Strategies per hour                         456.78
        Accepted strategies per hour                  6.85
        Running time so far                         1d 02:03:04
        In databank                                    197
        """
        m = module._parse_sqx_status_metrics(text)
        self.assertEqual(m["strategies_generated"], 12345)
        self.assertEqual(m["in_databank"], 197)
        self.assertEqual(m["passed"], 185)
        self.assertEqual(m["failed"], 12)
        self.assertAlmostEqual(m["accepted_pct"], 1.5)
        self.assertAlmostEqual(m["strategies_per_hour"], 456.78)
        self.assertEqual(m["running_time"], "1d 02:03:04")

    def test_parse_databank_records(self):
        self.assertEqual(
            module._parse_sqx_status_metrics("Records: 188")["records"],
            188,
        )

    def test_sqx_http_literal_encoding_keeps_equals_and_encodes_space(self):
        out = module._encode_sqx_http_cmd('-project action=status name="GOLD BREAKOUT M30 - Dukascopy"')
        self.assertIn("action=status", out)
        self.assertNotIn("%3D", out)
        self.assertIn("%20", out)
        self.assertNotIn("+action", out)

    @mock.patch.object(module, "_sqx_http_call")
    def test_project_control_uses_single_quoted_name(self, http_call):
        http_call.return_value = {
            "returncode": 0,
            "stdout": "Project GOLD BREAKOUT M30 - Dukascopy stopped",
            "stderr": "",
        }
        module._sqx_http_project_control("stop", "GOLD BREAKOUT M30 - Dukascopy")
        sent = http_call.call_args.args[0]
        self.assertIn("name='GOLD BREAKOUT M30 - Dukascopy'", sent)
        self.assertNotIn('name="GOLD BREAKOUT M30 - Dukascopy"', sent)

    def test_http_value_is_fail_closed(self):
        self.assertEqual(
            module._sqx_http_value("GOLD BREAKOUT M30 - Dukascopy", "project", "status_project"),
            "GOLD BREAKOUT M30 - Dukascopy",
        )
        with self.assertRaises(RuntimeError):
            module._sqx_http_value('GOLD" & -exit', "project", "status_project")


    def test_direct_databank_file_count_without_sqcli(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            sqcli = root / "sqcli.exe"
            sqcli.write_bytes(b"stub")
            bank = root / "user" / "projects" / "GOLD BREAKOUT M30 - Dukascopy" / "databanks" / "Final strategies"
            bank.mkdir(parents=True)
            for i in range(3):
                (bank / f"Strategy {i}.sqx").write_bytes(b"x")
            cfg = module.BridgeConfig("d", "n", str(sqcli))
            out = module._databank_file_count(
                cfg, "GOLD BREAKOUT M30 - Dukascopy", "Final strategies"
            )
            self.assertEqual(out["records"], 3)
            self.assertTrue(out["databank_path"].endswith("Final strategies"))

    @mock.patch.object(module, "_sqx_instance_alive", return_value=(True, "help"))
    def test_project_file_status_infers_running_from_unclosed_log(self, alive):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            sqcli = root / "sqcli.exe"
            sqcli.write_bytes(b"stub")
            logdir = root / "user" / "projects" / "GOLD BREAKOUT M30 - Dukascopy" / "log"
            logdir.mkdir(parents=True)
            (logdir / "global_log_20260921_120000.log").write_text(
                "=========== Project started ===========\n"
                "Build strategies : Initializing backtest data...\n",
                encoding="utf-8",
            )
            cfg = module.BridgeConfig("d", "n", str(sqcli))
            out = module._project_file_status(cfg, "GOLD BREAKOUT M30 - Dukascopy")
            self.assertTrue(out["instance_http_alive"])
            self.assertTrue(out["unclosed_start_marker"])
            self.assertTrue(out["running_inferred"])
            alive.assert_called_once()

    @mock.patch.object(module, "_project_file_status")
    @mock.patch.object(module, "_sqx_instance_alive", return_value=(True, "help"))
    @mock.patch.object(module, "_sqx_http_call")
    def test_status_project_prefers_live_http_when_gui_is_alive(self, http_call, alive, file_status):
        http_call.return_value = {
            "returncode": 0,
            "stdout": "Project GOLD BREAKOUT M30 - Dukascopy is STOPPED",
            "stderr": "",
        }
        file_status.return_value = {
            "project_root": r"C:\\SQX\\user\\projects\\GOLD",
            "status_metrics": {},
            "running_inferred": False,
            "log_tail": "old log",
        }
        cfg = module.BridgeConfig("d", "n", r"C:\\SQX\\sqcli.exe", allow_project_control=True)
        runtime = module.SqCliRuntime(cfg.sqcli_path)
        result = module.sqx_call(cfg, runtime, "status_project", {"project": "GOLD BREAKOUT M30 - Dukascopy"})
        self.assertEqual(result["transport"], "sqx_http_api")
        self.assertTrue(result["attached_existing_instance"])
        self.assertIn("STOPPED", result["stdout"])
        self.assertEqual(result["telemetry_source"], "sqx_http_api")
        self.assertEqual(http_call.call_count, 1)

    @mock.patch.object(module, "_run_sqcli")
    @mock.patch.object(module, "_sqx_http_call")
    def test_existing_http_instance_is_preferred(self, http_call, run_sqcli):
        http_call.return_value = {
            "returncode": 0,
            "stdout": "Strategies generated 100\nIn databank 188",
            "stderr": "",
        }
        result, extra = module._read_only_http_or_sqcli(
            module.BridgeConfig("d", "n", r"C:\SQX\sqcli.exe"),
            DummyRuntime(False),
            command_name="status_project",
            http_command='-project action=status name="GOLD BREAKOUT M30 - Dukascopy"',
            sqcli_args=["-project", "action=status", "name=GOLD BREAKOUT M30 - Dukascopy"],
        )
        self.assertEqual(result["returncode"], 0)
        self.assertEqual(extra["transport"], "sqx_http_api")
        self.assertTrue(extra["attached_existing_instance"])
        self.assertEqual(extra["status_metrics"]["in_databank"], 188)
        run_sqcli.assert_not_called()

    @mock.patch.object(module, "_run_sqcli")
    @mock.patch.object(module, "_sqx_http_call")
    def test_never_launches_competing_sqcli_when_runtime_is_active(self, http_call, run_sqcli):
        http_call.side_effect = RuntimeError("SQX_HTTP_UNAVAILABLE")
        with self.assertRaisesRegex(RuntimeError, "SQX_LIVE_TELEMETRY_UNAVAILABLE"):
            module._read_only_http_or_sqcli(
                module.BridgeConfig("d", "n", r"C:\SQX\sqcli.exe"),
                DummyRuntime(True),
                command_name="count_databank",
                http_command='-databank action=count project="GOLD" name="Final strategies"',
                sqcli_args=["-databank", "action=count", "project=GOLD", "name=Final strategies"],
            )
        run_sqcli.assert_not_called()

    @mock.patch.object(module, "_run_sqcli")
    @mock.patch.object(module, "_sqx_http_call")
    def test_falls_back_to_sqcli_only_when_no_runtime_is_active(self, http_call, run_sqcli):
        http_call.side_effect = RuntimeError("SQX_HTTP_UNAVAILABLE")
        run_sqcli.return_value = {
            "returncode": 0,
            "stdout": "Records: 12",
            "stderr": "",
        }
        result, extra = module._read_only_http_or_sqcli(
            module.BridgeConfig("d", "n", r"C:\SQX\sqcli.exe"),
            DummyRuntime(False),
            command_name="count_databank",
            http_command='-databank action=count project="GOLD" name="Final strategies"',
            sqcli_args=["-databank", "action=count", "project=GOLD", "name=Final strategies"],
        )
        self.assertEqual(extra["transport"], "sqcli_process")
        self.assertEqual(extra["status_metrics"]["records"], 12)
        run_sqcli.assert_called_once()


if __name__ == "__main__":
    unittest.main()
