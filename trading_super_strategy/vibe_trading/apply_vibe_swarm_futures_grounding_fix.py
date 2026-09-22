from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import os
import py_compile
from pathlib import Path

REFERENCE_COMMITS = [
    "8b4dcaf31368dc63870ac744ec8b34e5e05a9e5b",
    "26a51bde82b786a0a08da671216c72782d4a093f",
]

FUTURES_PATTERN = '    re.compile(r"(?<![A-Za-z0-9_])[A-Z0-9]{1,10}=F(?![A-Za-z0-9_])", re.IGNORECASE),'
FOREX_PATTERN = '    re.compile(r"(?<![A-Za-z0-9_])[A-Z0-9]{3,15}=X(?![A-Za-z0-9_])", re.IGNORECASE),'
DERIVATIVE_GUARD_MARKER = "derivative_roots = {"
VENUE_WORDS = ('"CME"', '"COMEX"', '"NYMEX"', '"CBOT"', '"CBOE"', '"ICE"', '"TVC"')


def sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def locate():
    import src.swarm.grounding as grounding
    return grounding, Path(grounding.__file__).resolve()


def state(text: str) -> dict[str, object]:
    return {
        "futures_pattern": FUTURES_PATTERN in text,
        "forex_pattern": FOREX_PATTERN in text,
        "derivative_guard": DERIVATIVE_GUARD_MARKER in text,
        "venue_stopwords": all(word in text for word in VENUE_WORDS),
    }


def fixed(text: str) -> bool:
    s = state(text)
    return all(bool(v) for v in s.values())


def smoke(module) -> dict[str, object]:
    f = module.extract_symbols_from_user_vars
    expected = {root: [f"{root}=F"] for root in ("ES", "NQ", "GC", "CL")}
    observed = {root: f({"target": f"{root}=F"}) for root in expected}
    full_es = f({
        "target": "ES=F",
        "market": "E-mini S&P 500 futures, CME",
        "goal": "discover diverse systematic ES strategies with real-data backtests",
        "tv_symbol": "CME:ES1!",
        "tv_category": "equity_index",
        "tv_policy": "use only the supplied canonical futures target; reject crypto spot and cfd substitutes",
        "research_timeframes": "5m,15m,1h,4h",
    })
    equity = f({"target": "AAPL.US"})
    crypto = f({"target": "BTC-USDT"})
    ok = (
        observed == expected
        and full_es == ["ES=F"]
        and equity == ["AAPL.US"]
        and crypto == ["BTC-USDT"]
    )
    if not ok:
        raise RuntimeError("GROUNDING_SMOKE_FAILED:" + json.dumps({
            "observed": observed, "full_es": full_es, "equity": equity, "crypto": crypto
        }, sort_keys=True))
    return {
        "continuous_futures": observed,
        "full_es_variables": full_es,
        "equity_regression": equity,
        "crypto_regression": crypto,
    }


def apply() -> dict[str, object]:
    module, path = locate()
    original = path.read_text(encoding="utf-8")
    before = sha(original)

    if fixed(original):
        reloaded = importlib.reload(module)
        return {
            "status": "ALREADY_FIXED",
            "path": str(path),
            "sha256": before,
            "references": REFERENCE_COMMITS,
            "state": state(original),
            "smoke": smoke(reloaded),
        }

    text = original

    if FUTURES_PATTERN not in text or FOREX_PATTERN not in text:
        needle = '    re.compile(r"\\b[A-Z]{2,6}-USDT\\b"),\n'
        if text.count(needle) != 1:
            raise RuntimeError("SYMBOL_PATTERN_PRECONDITION_FAILED")
        additions = needle + FUTURES_PATTERN + "\n" + FOREX_PATTERN + "\n"
        text = text.replace(needle, additions, 1)

    if not all(word in text for word in VENUE_WORDS):
        venue_needle = '    "HKEX", "TSX", "TSXV", "SPX", "NDX", "DJI", "DJIA", "HSI", "CSI", "FTSE", "MSCI", "VIX",\n'
        if text.count(venue_needle) != 1:
            raise RuntimeError("VENUE_STOPWORD_PRECONDITION_FAILED")
        venue_new = (
            '    "HKEX", "TSX", "TSXV", "SPX", "NDX", "DJI", "DJIA", "HSI", "CSI", "FTSE", "MSCI", "VIX",\n'
            '    "CME", "COMEX", "NYMEX", "CBOT", "CBOE", "ICE", "TVC",\n'
        )
        text = text.replace(venue_needle, venue_new, 1)

    if DERIVATIVE_GUARD_MARKER not in text:
        old_return = '    return list(explicit) + [s for s in promoted if s not in explicit]\n'
        if text.count(old_return) != 1:
            raise RuntimeError("RETURN_GUARD_PRECONDITION_FAILED")
        new_return = '''    derivative_roots = {
        symbol.rsplit("=", 1)[0].upper()
        for symbol in explicit
        if re.fullmatch(r"[A-Z0-9]{1,15}=[FX]", symbol, re.IGNORECASE)
    }
    blocked_promotions = {f"{root}.US" for root in derivative_roots}
    return list(explicit) + [
        s for s in promoted
        if s not in explicit and s.upper() not in blocked_promotions
    ]
'''
        text = text.replace(old_return, new_return, 1)

    compile(text, str(path), "exec")
    backup = path.with_name(path.name + ".pre-cygnus-futures-grounding.bak")
    if not backup.exists():
        backup.write_text(original, encoding="utf-8")
    temp = path.with_name(path.name + ".cygnus-new")
    temp.write_text(text, encoding="utf-8")
    os.replace(temp, path)
    py_compile.compile(str(path), doraise=True)

    after = path.read_text(encoding="utf-8")
    if not fixed(after):
        raise RuntimeError("GROUNDING_FIX_POSTCONDITION_FAILED:" + json.dumps(state(after), sort_keys=True))
    reloaded = importlib.reload(module)
    return {
        "status": "PATCHED",
        "path": str(path),
        "backup": str(backup),
        "sha256_before": before,
        "sha256_after": sha(after),
        "references": REFERENCE_COMMITS,
        "state": state(after),
        "smoke": smoke(reloaded),
    }


def check() -> dict[str, object]:
    module, path = locate()
    text = path.read_text(encoding="utf-8")
    result = {
        "status": "PASS" if fixed(text) else "FAIL",
        "path": str(path),
        "sha256": sha(text),
        "references": REFERENCE_COMMITS,
        "state": state(text),
    }
    if result["status"] == "PASS":
        result["smoke"] = smoke(module)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = check() if args.check else apply()
    print("VIBE_SWARM_FUTURES_GROUNDING_FIX=" + str(result["status"]))
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result["status"] in {"PASS", "PATCHED", "ALREADY_FIXED"} else 2


if __name__ == "__main__":
    raise SystemExit(main())
