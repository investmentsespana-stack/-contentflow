from __future__ import annotations

import argparse
import hashlib
import json
import re
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET


def _read_text(raw: bytes) -> str:
    for enc in ("utf-8", "cp1252"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            pass
    return raw.decode("utf-8", errors="replace")


def inspect_cfx(path: Path) -> dict:
    if not path.is_file():
        raise FileNotFoundError(path)
    if not zipfile.is_zipfile(path):
        raise ValueError(f"Not a valid SQX .cfx ZIP: {path}")

    result = {
        "file": str(path),
        "size": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "tasks": [],
        "resources": [],
        "chart_symbols": [],
        "databanks": [],
        "signals": {},
    }

    with zipfile.ZipFile(path, "r") as zf:
        names = zf.namelist()
        result["entries"] = names

        config_text = _read_text(zf.read("config.xml")) if "config.xml" in names else ""
        if config_text:
            root = ET.fromstring(config_text)

            for task in root.findall(".//Task"):
                result["tasks"].append({
                    "type": task.attrib.get("type"),
                    "name": task.attrib.get("name"),
                    "title": task.attrib.get("title"),
                    "file": task.attrib.get("taskXMLFile"),
                    "active": task.attrib.get("active"),
                    "template_file": task.attrib.get("templateFile"),
                })

            for sym in root.findall(".//Resources/Symbols/Symbol"):
                info = sym.find("InstrumentInfo")
                result["resources"].append({
                    "symbol": sym.attrib.get("name"),
                    "instrument": info.attrib.get("instrument") if info is not None else None,
                    "source": sym.attrib.get("source"),
                    "clone_from": sym.attrib.get("cloneFrom"),
                    "timezone": sym.attrib.get("timezone"),
                })

            for db in root.findall(".//Databanks/Databank"):
                result["databanks"].append({
                    "name": db.attrib.get("name"),
                    "sync_type": db.attrib.get("syncType"),
                    "position": db.attrib.get("position"),
                })

        seen = set()
        all_text = []
        for name in names:
            if not name.lower().endswith((".xml", ".json", ".txt", ".cfg", ".properties")):
                continue
            text = _read_text(zf.read(name))
            all_text.append(text)
            if name.lower().endswith(".xml"):
                try:
                    root = ET.fromstring(text)
                except Exception:
                    continue
                for chart in root.findall(".//Chart"):
                    item = {
                        "file": name,
                        "symbol": chart.attrib.get("symbol"),
                        "timeframe": chart.attrib.get("timeframe"),
                    }
                    key = tuple(item.values())
                    if key not in seen:
                        seen.add(key)
                        result["chart_symbols"].append(item)

        combined = "\n".join(all_text).lower()
        checks = {
            "builder": ("build strategies", "type=\"build\""),
            "retest": ("retest", "retester"),
            "monte_carlo": ("monte carlo", "montecarlo", "montecarloretest"),
            "walk_forward": ("walk forward", "walkforward", "wf matrix"),
            "slippage": ("slippage",),
            "oos": ("out of sample", "oos"),
            "loop": ("go to task", "goto", "loop"),
            "additional_markets": ("retestonadditionalmarkets",),
        }
        result["signals"] = {
            key: any(term in combined for term in terms)
            for key, terms in checks.items()
        }

    return result


def main() -> int:
    ap = argparse.ArgumentParser(description="Read-only StrategyQuant Custom Project .cfx inspector")
    ap.add_argument("cfx", type=Path)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    result = inspect_cfx(args.cfx)
    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0

    print(f"PROJECT FILE: {result['file']}")
    print(f"SHA256: {result['sha256']}")
    print("\nTASKS")
    for i, task in enumerate(result["tasks"], 1):
        print(f"{i:02d}. {task['type']} | {task['title'] or task['name']} | {task['file']}")
    print("\nCHART SYMBOLS")
    for item in result["chart_symbols"]:
        print(f"- {item['file']}: {item['symbol']} / {item['timeframe']}")
    print("\nRESOURCES")
    for item in result["resources"]:
        print(f"- {item['symbol']} -> {item['instrument']}")
    print("\nSIGNALS")
    for key, value in result["signals"].items():
        print(f"- {key}: {value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
