from __future__ import annotations

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
import unittest
from urllib.parse import parse_qs, urlparse

from trading_super_strategy.backtest_engine import Bar
from trading_super_strategy.openbb_history_adapter import (
    OPENBB_FUTURES_HISTORY_PATH,
    OpenBBHistoryError,
    bars_to_ohlcv_rows,
    fetch_openbb_http,
    fetch_openbb_python,
    normalize_openbb_results,
)


def sample_rows(count: int = 4):
    start = datetime(2026, 9, 15, 13, 30, tzinfo=timezone.utc)
    rows = []
    for i in range(count):
        price = 25000.0 + i
        rows.append(
            {
                "date": (start + timedelta(minutes=15 * i)).isoformat(),
                "open": price,
                "high": price + 2.0,
                "low": price - 2.0,
                "close": price + 0.5,
                "volume": 1000 + i,
            }
        )
    return rows


class FakeFuturesEndpoint:
    def __init__(self, rows):
        self.rows = rows
        self.calls = []

    def historical(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(results=self.rows, provider="yfinance")


class OpenBBHistoryAdapterTests(unittest.TestCase):
    def test_python_transport_fetches_free_yfinance_futures(self):
        endpoint = FakeFuturesEndpoint(sample_rows())
        client = SimpleNamespace(derivatives=SimpleNamespace(futures=endpoint))

        bars, stats = fetch_openbb_python(
            symbol="NQ",
            interval="15m",
            start_date="2026-09-15",
            end_date="2026-09-16",
            client=client,
        )

        self.assertEqual(len(bars), 4)
        self.assertTrue(all(isinstance(bar, Bar) for bar in bars))
        self.assertEqual(stats.symbol, "NQ")
        self.assertEqual(stats.provider, "yfinance")
        self.assertEqual(stats.transport, "python")
        self.assertEqual(
            endpoint.calls[0],
            {
                "symbol": "NQ",
                "interval": "15m",
                "provider": "yfinance",
                "start_date": "2026-09-15",
                "end_date": "2026-09-16",
            },
        )

    def test_http_transport_targets_bbterminal_openbb_api(self):
        captured = {}

        def fake_get(url, timeout):
            captured["url"] = url
            captured["timeout"] = timeout
            return {"provider": "yfinance", "results": sample_rows()}

        bars, stats = fetch_openbb_http(
            symbol="ES",
            interval="15m",
            start_date="2026-09-15",
            end_date="2026-09-16",
            base_url="http://127.0.0.1:6900",
            http_get=fake_get,
        )

        parsed = urlparse(captured["url"])
        query = parse_qs(parsed.query)
        self.assertEqual(parsed.path, OPENBB_FUTURES_HISTORY_PATH)
        self.assertEqual(query["symbol"], ["ES"])
        self.assertEqual(query["provider"], ["yfinance"])
        self.assertEqual(query["interval"], ["15m"])
        self.assertEqual(query["start_date"], ["2026-09-15"])
        self.assertEqual(query["end_date"], ["2026-09-16"])
        self.assertEqual(captured["timeout"], 20.0)
        self.assertEqual(len(bars), 4)
        self.assertEqual(stats.transport, "http")

    def test_provider_rows_are_sorted_but_duplicate_times_fail_closed(self):
        rows = sample_rows()
        reversed_rows = list(reversed(rows))
        bars, _ = normalize_openbb_results(
            reversed_rows,
            symbol="YM",
            interval="15m",
        )
        self.assertLess(bars[0].timestamp, bars[-1].timestamp)

        duplicate = rows + [dict(rows[-1])]
        with self.assertRaises(OpenBBHistoryError):
            normalize_openbb_results(duplicate, symbol="YM", interval="15m")

    def test_naive_intraday_timestamp_requires_explicit_timezone(self):
        rows = sample_rows(1)
        rows[0]["date"] = "2026-09-15T09:30:00"
        with self.assertRaises(OpenBBHistoryError):
            normalize_openbb_results(rows, symbol="RTY", interval="15m")

        bars, _ = normalize_openbb_results(
            rows,
            symbol="RTY",
            interval="15m",
            naive_timezone=timezone.utc,
        )
        self.assertEqual(bars[0].timestamp.tzinfo, timezone.utc)

    def test_missing_volume_is_allowed_and_evidenced(self):
        rows = sample_rows(2)
        rows[1]["volume"] = None
        bars, stats = normalize_openbb_results(rows, symbol="NQ", interval="15m")
        self.assertEqual(bars[1].volume, 0.0)
        self.assertEqual(stats.missing_volume_rows, 1)

    def test_invalid_ohlc_and_unregistered_scope_fail_closed(self):
        rows = sample_rows(1)
        rows[0]["high"] = rows[0]["low"] - 1.0
        with self.assertRaises(OpenBBHistoryError):
            normalize_openbb_results(rows, symbol="ES", interval="15m")
        with self.assertRaises(ValueError):
            normalize_openbb_results(sample_rows(1), symbol="CL", interval="15m")
        with self.assertRaises(ValueError):
            normalize_openbb_results(sample_rows(1), symbol="ES", interval="4h")
        with self.assertRaises(ValueError):
            normalize_openbb_results(sample_rows(1), symbol="ES", interval="15m", provider="fmp")

    def test_common_ohlcv_bridge_preserves_values_for_frozen_loaders(self):
        bars, _ = normalize_openbb_results(sample_rows(2), symbol="ES", interval="15m")
        rows = bars_to_ohlcv_rows(bars)
        self.assertEqual(
            set(rows[0]),
            {"timestamp", "open", "high", "low", "close", "volume"},
        )
        self.assertEqual(rows[0]["open"], bars[0].open)
        self.assertEqual(rows[1]["close"], bars[1].close)


if __name__ == "__main__":
    unittest.main()
