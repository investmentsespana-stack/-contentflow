import importlib.util
import pathlib
import sys
import tempfile
import unittest

APP = pathlib.Path(__file__).with_name("app.py")
spec = importlib.util.spec_from_file_location("cygnus_sqx_bridge_app_resource", APP)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
assert spec.loader is not None
spec.loader.exec_module(module)


class IdleRuntime:
    def is_running(self):
        return False


class ResourceRepairTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.original = module._run_sqcli

        def fake(path, args, timeout=180):
            self.calls.append((path, args, timeout))
            return {"returncode": 0, "stdout": "ok", "stderr": ""}

        module._run_sqcli = fake
        self.cfg = module.BridgeConfig(
            device_id="test",
            device_name="test",
            sqcli_path=r"C:\\SQX\\sqcli.exe",
            allow_project_control=True,
        )
        self.runtime = IdleRuntime()

    def tearDown(self):
        module._run_sqcli = self.original

    def test_add_nq_instrument_exact_contract(self):
        out = module.sqx_call(
            self.cfg,
            self.runtime,
            "add_instrument",
            {
                "instrument": "NQ - CME",
                "description": "History data instrument",
                "pointvalue": 20,
                "ticksize": 0.25,
                "tickstep": 0.25,
                "defaultspread": 2,
                "datatype": "futures",
            },
        )
        self.assertEqual(out["command"], "add_instrument")
        args = self.calls[-1][1]
        self.assertIn("instrument=NQ - CME", args)
        self.assertIn("pointvalue=20", args)
        self.assertIn("ticksize=0.25", args)
        self.assertIn("datatype=futures", args)

    def test_add_nq_symbol_exact_contract(self):
        module.sqx_call(
            self.cfg,
            self.runtime,
            "add_symbol",
            {
                "symbol": "@NQ",
                "instrument": "NQ - CME",
                "datasource": "file",
                "datatype": "M1",
                "bartype": "endofbar",
            },
        )
        args = self.calls[-1][1]
        self.assertEqual(args[0:2], ["-symbol", "action=add"])
        self.assertIn("symbols=@NQ", args)
        self.assertIn("instrument=NQ - CME", args)
        self.assertIn("datasource=file", args)

    def test_rejects_unsafe_resource_name(self):
        with self.assertRaises(RuntimeError):
            module.sqx_call(
                self.cfg,
                self.runtime,
                "add_symbol",
                {
                    "symbol": "@NQ & del C:\\",
                    "instrument": "NQ - CME",
                },
            )


    def test_replace_existing_project_config_with_backup(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            sqcli = root / "sqcli.exe"
            sqcli.write_bytes(b"")
            project = root / "user" / "projects" / "NQ BREAKOUT FUTURES  H1 - Tradestation"
            project.mkdir(parents=True)
            target = project / "project.cfx"
            target.write_bytes(b"old-config")
            cfg = module.BridgeConfig(
                device_id="test",
                device_name="test",
                sqcli_path=str(sqcli),
                allow_project_control=True,
            )
            encoded = module.base64.b64encode(b"new-config").decode("ascii")
            out = module.sqx_call(
                cfg,
                self.runtime,
                "load_project_config",
                {
                    "project": "NQ BREAKOUT FUTURES  H1 - Tradestation",
                    "config_b64": encoded,
                    "replace_existing": True,
                },
            )
            self.assertTrue(out["replace_existing"])
            self.assertEqual(target.read_bytes(), b"new-config")
            self.assertIn("backup_sha256", out)



if __name__ == "__main__":
    unittest.main()
