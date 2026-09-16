from __future__ import annotations

from datetime import timezone
import unittest

from trading_super_strategy.ninjatrader_history_adapter import (
    parse_ninjatrader_minute_text,
    resample_minute_bars,
)


class NinjaTraderHistoryAdapterTests(unittest.TestCase):
    def _minute_text(self, count: int = 15) -> str:
        rows = []
        for i in range(1, count + 1):
            minute = i
            ts = f"20260102 14{minute:02d}00"
            open_ = 100.0 + i - 1
            close = open_ + 0.25
            high = close + 0.5
            low = open_ - 0.5
            volume = 100 + i
            rows.append(f"{ts};{open_};{high};{low};{close};{volume}")
        return "\n".join(rows)

    def test_parser_uses_utc_and_end_bar_records(self):
        bars = parse_ninjatrader_minute_text(
            "20260102 143100;100;101;99;100.5;123\n"
            "20260102 143200;100.5;102;100;101.5;456"
        )
        self.assertEqual(len(bars), 2)
        self.assertEqual(bars[0].timestamp.tzinfo, timezone.utc)
        self.assertEqual(bars[0].timestamp.hour, 14)
        self.assertEqual(bars[0].timestamp.minute, 31)
        self.assertEqual(bars[1].volume, 456.0)

    def test_parser_rejects_bad_shape_and_non_monotonic_time(self):
        with self.assertRaises(ValueError):
            parse_ninjatrader_minute_text("20260102 143100;100;101;99;100.5")
        with self.assertRaises(ValueError):
            parse_ninjatrader_minute_text(
                "20260102 143200;100;101;99;100.5;1\n"
                "20260102 143100;100;101;99;100.5;1"
            )

    def test_resample_15_minute_ohlcv_is_deterministic(self):
        bars = parse_ninjatrader_minute_text(self._minute_text(15))
        out, stats = resample_minute_bars(bars, minutes=15, require_complete=True)
        self.assertEqual(len(out), 1)
        bar = out[0]
        self.assertEqual((bar.timestamp.hour, bar.timestamp.minute), (14, 15))
        self.assertEqual(bar.open, bars[0].open)
        self.assertEqual(bar.close, bars[-1].close)
        self.assertEqual(bar.high, max(x.high for x in bars))
        self.assertEqual(bar.low, min(x.low for x in bars))
        self.assertEqual(bar.volume, sum(x.volume for x in bars))
        self.assertEqual(stats.source_bars, 15)
        self.assertEqual(stats.output_bars, 1)
        self.assertEqual(stats.dropped_incomplete_buckets, 0)

    def test_incomplete_bucket_is_dropped_fail_closed(self):
        bars = parse_ninjatrader_minute_text(self._minute_text(14))
        with self.assertRaises(ValueError):
            resample_minute_bars(bars, minutes=15, require_complete=True)

    def test_gap_inside_bucket_is_not_treated_as_complete(self):
        rows = self._minute_text(15).splitlines()
        # Remove one minute but append minute 16, preserving 15 records with a gap.
        rows.pop(5)
        rows.append("20260102 141600;115;116;114;115.5;999")
        bars = parse_ninjatrader_minute_text("\n".join(rows))
        with self.assertRaises(ValueError):
            resample_minute_bars(bars, minutes=15, require_complete=True)


if __name__ == "__main__":
    unittest.main()
