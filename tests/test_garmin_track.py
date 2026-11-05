import unittest
from datetime import datetime
from unittest.mock import patch

from api.garmin_track import _parse_fit_track, _sample_points


class FakeField:
    def __init__(self, name, value):
        self.name = name
        self.value = value


class FakeMessage:
    def __init__(self, **fields):
        self.fields = [FakeField(name, value) for name, value in fields.items()]

    def __iter__(self):
        return iter(self.fields)


class GarminTrackTests(unittest.TestCase):
    def test_track_preserves_coordinates_and_optional_metrics(self):
        records = [
            FakeMessage(
                position_lat=-37.8 * (2**31 / 180),
                position_long=175.3 * (2**31 / 180),
                enhanced_altitude=42.5,
                timestamp=datetime(2026, 10, 30, 8, 0, 0),
            ),
            FakeMessage(position_lat=-37.81 * (2**31 / 180), position_long=175.31 * (2**31 / 180)),
        ]
        fake_fit = type("FakeFit", (), {"get_messages": lambda self, name: records})()
        with patch("api.garmin_track.FitFile", return_value=fake_fit):
            result = _parse_fit_track(b"fake fit", 100)
        self.assertEqual(result["point_count"], 2)
        self.assertEqual(result["returned_point_count"], 2)
        self.assertFalse(result["sampled"])
        self.assertAlmostEqual(result["points"][0]["lat"], -37.8)
        self.assertAlmostEqual(result["points"][0]["lon"], 175.3)
        self.assertEqual(result["points"][0]["altitude_m"], 42.5)
        self.assertEqual(result["points"][0]["timestamp"], "2026-10-30T08:00:00")

    def test_records_without_coordinates_are_skipped(self):
        records = [FakeMessage(heart_rate=120), FakeMessage(position_lat=None, position_long=175 * (2**31 / 180))]
        fake_fit = type("FakeFit", (), {"get_messages": lambda self, name: records})()
        with patch("api.garmin_track.FitFile", return_value=fake_fit):
            result = _parse_fit_track(b"fake fit", 100)
        self.assertEqual(result["point_count"], 0)
        self.assertEqual(result["points"], [])

    def test_sampling_keeps_first_and_last_points(self):
        points = [{"lat": i, "lon": i} for i in range(10)]
        sampled = _sample_points(points, 4)
        self.assertEqual(len(sampled), 4)
        self.assertEqual(sampled[0], points[0])
        self.assertEqual(sampled[-1], points[-1])


if __name__ == "__main__":
    unittest.main()
