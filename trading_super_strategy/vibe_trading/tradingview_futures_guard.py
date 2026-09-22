from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable

SAFE_FUTURES_TOOLS = frozenset({
    "futures_category_snapshot",
    "futures_market_overview",
    "futures_top_movers",
    "futures_watchlist",
})

UNSAFE_GENERIC_ANALYSIS_TOOLS = frozenset({
    "coin_analysis",
    "multi_timeframe_analysis",
    "combined_analysis",
    "multi_agent_analysis",
})

REQUIRED_TIMEFRAMES = ("5m", "15m", "1h", "4h")


@dataclass(frozen=True)
class FuturesRoute:
    root: str
    exchange: str
    continuous_symbol: str
    category: str

    @property
    def qualified_symbol(self) -> str:
        return f"{self.exchange}:{self.continuous_symbol}"


ROUTES: dict[str, FuturesRoute] = {
    "NQ": FuturesRoute("NQ", "CME", "NQ1!", "equity_index"),
    "ES": FuturesRoute("ES", "CME", "ES1!", "equity_index"),
    "GC": FuturesRoute("GC", "COMEX", "GC1!", "metals"),
    "CL": FuturesRoute("CL", "NYMEX", "CL1!", "energy"),
}


def resolve_route(root: str) -> FuturesRoute:
    key = str(root or "").strip().upper()
    if key not in ROUTES:
        raise ValueError(f"FUTURES_ROOT_NOT_ALLOWED:{key}")
    return ROUTES[key]


def validate_futures_tool(root: str, tool_name: str) -> FuturesRoute:
    route = resolve_route(root)
    tool = str(tool_name or "").strip()
    if tool in UNSAFE_GENERIC_ANALYSIS_TOOLS:
        raise ValueError(
            f"FUTURES_TOOL_BLOCKED:{route.root}:{tool}:"
            "generic analysis routing may fall back to crypto/spot aliases"
        )
    if tool not in SAFE_FUTURES_TOOLS:
        raise ValueError(f"FUTURES_TOOL_NOT_ALLOWLISTED:{route.root}:{tool}")
    return route


def validate_timeframes(timeframes: Iterable[str]) -> tuple[str, ...]:
    normalized = tuple(str(tf).strip() for tf in timeframes)
    if normalized != REQUIRED_TIMEFRAMES:
        raise ValueError(
            "FUTURES_TIMEFRAME_SET_INVALID:"
            + ",".join(normalized)
            + ":required="
            + ",".join(REQUIRED_TIMEFRAMES)
        )
    return normalized


def build_snapshot_plan(roots: Iterable[str] = ("NQ", "ES", "GC", "CL")) -> dict[str, Any]:
    routes = [resolve_route(root) for root in roots]
    categories: list[str] = []
    for route in routes:
        if route.category not in categories:
            categories.append(route.category)

    return {
        "schema": "cygnus.tradingview.futures_route_guard.v1",
        "mode": "RESEARCH_ONLY",
        "roots": {
            route.root: {
                "exchange": route.exchange,
                "continuous_symbol": route.continuous_symbol,
                "qualified_symbol": route.qualified_symbol,
                "category": route.category,
            }
            for route in routes
        },
        "snapshot_calls": [
            {"tool": "futures_category_snapshot", "category": category}
            for category in categories
        ],
        "allowed_tools": sorted(SAFE_FUTURES_TOOLS),
        "blocked_tools": sorted(UNSAFE_GENERIC_ANALYSIS_TOOLS),
        "required_timeframes": list(REQUIRED_TIMEFRAMES),
        "invariants": [
            "never route NQ/ES/GC/CL to crypto or KUCOIN",
            "never replace COMEX:GC1! with TVC:GOLD",
            "never replace NYMEX:CL1! with a spot/CFD proxy",
            "never claim an expiry-specific contract unless the provider explicitly returns it",
            "no trades or broker execution",
        ],
    }


def assert_provider_symbol(root: str, provider_symbol: str) -> str:
    route = resolve_route(root)
    actual = str(provider_symbol or "").strip().upper()
    expected = route.qualified_symbol.upper()
    if actual != expected:
        raise ValueError(
            f"FUTURES_SYMBOL_MISMATCH:{route.root}:expected={expected}:actual={actual}"
        )
    if actual.startswith("KUCOIN:"):
        raise ValueError(f"FUTURES_CRYPTO_FALLBACK_BLOCKED:{route.root}:{actual}")
    if route.root == "GC" and actual == "TVC:GOLD":
        raise ValueError("FUTURES_SPOT_SUBSTITUTION_BLOCKED:GC:TVC:GOLD")
    return actual


def codex_policy_text() -> str:
    return (
        "use futures-native tools only for the supplied target and canonical symbol. "
        "use the futures category snapshot before analysis. "
        "do not use crypto analysis routes as substitutes for futures research. "
        "do not fall back to crypto, spot, index-cash, or cfd proxies. "
        "use the supplied research timeframes and do not place trades."
    )
