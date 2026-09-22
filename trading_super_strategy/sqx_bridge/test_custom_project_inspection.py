from __future__ import annotations

import tempfile
import zipfile
from pathlib import Path

from app import _inspect_cfx_workflow


def main() -> int:
    root = Path(tempfile.mkdtemp(prefix="sqx-custom-inspect-"))
    path = root / "sample.cfx"
    xml = """<project>
      <task name="Build strategies" type="Builder"/>
      <task name="Retester OOS" type="Retester"/>
      <task name="Monte Carlo Parameters" type="Robustness"/>
      <task name="Filter survivors" type="Filter"/>
      <task name="Go To Task" type="Loop"/>
      <databank name="Final"/>
    </project>"""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("config.xml", xml)

    result = _inspect_cfx_workflow(path)
    signals = result["workflow_signals"]
    assert result["likely_custom_project"] is True
    assert signals["builder"] is True
    assert signals["retest"] is True
    assert signals["monte_carlo"] is True
    assert signals["filter"] is True
    assert signals["loop"] is True
    assert signals["databank"] is True
    print("CUSTOM_PROJECT_INSPECTION_TEST=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
