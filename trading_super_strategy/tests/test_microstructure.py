import unittest

from trading_super_strategy.microstructure import (
    BookEvent,
    DataUnsafeError,
    PointInTimeMicrostructureEngine,
)


class MicrostructureTests(unittest.TestCase):
    def setUp(self):
        self.engine = PointInTimeMicrostructureEngine()

    def test_point_in_time_excludes_future_events(self):
        events = [
            BookEvent(100, 101, 100.0, 100.25, 10, 5, "add"),
            BookEvent(200, 201, 99.0, 99.25, 1, 20, "cancel"),
        ]
        snap = self.engine.snapshot(events, as_of_ns=150)
        self.assertEqual(snap.spread, 0.25)
        self.assertAlmostEqual(snap.book_imbalance, 1 / 3)
        self.assertEqual(snap.add_count, 1)
        self.assertEqual(snap.cancel_count, 0)

    def test_receive_before_event_fails_closed(self):
        with self.assertRaises(DataUnsafeError):
            self.engine.snapshot([BookEvent(100, 99, 100, 101, 1, 1)], 100)

    def test_crossed_book_fails_closed(self):
        with self.assertRaises(DataUnsafeError):
            self.engine.snapshot([BookEvent(100, 100, 101, 100, 1, 1)], 100)

    def test_counts_measured_events_without_intent_claims(self):
        events = [
            BookEvent(100, 100, 100, 101, 3, 2, "add"),
            BookEvent(110, 111, 100, 101, 2, 2, "cancel"),
            BookEvent(120, 121, 100, 101, 2, 1, "trade"),
        ]
        snap = self.engine.snapshot(events, 120)
        self.assertEqual((snap.add_count, snap.cancel_count, snap.trade_count), (1, 1, 1))
        self.assertEqual(snap.inferred_label, "measured_pattern_not_participant_intent")

    def test_no_visible_events_is_unsafe(self):
        with self.assertRaises(DataUnsafeError):
            self.engine.snapshot([BookEvent(200, 201, 100, 101, 1, 1)], 100)


if __name__ == "__main__":
    unittest.main()
