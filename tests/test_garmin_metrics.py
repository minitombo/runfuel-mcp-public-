import unittest
from unittest.mock import patch

from api.garmin_metrics import garmin_get_running_summary
from garmin_personal_mcp import server as garmin_server


class GarminRunningSummaryTests(unittest.IsolatedAsyncioTestCase):
    async def test_computes_totals_from_returned_activity_fields(self):
        async def fake_search(**kwargs):
            self.assertEqual(kwargs["activity_type"], "running")
            self.assertEqual(kwargs["start"], "2026-10-26")
            self.assertEqual(kwargs["end"], "2026-10-28")
            return {
                "results": [
                    {
                        "activityId": 1,
                        "activityName": "Easy run",
                        "distance": 5000,
                        "duration": 1500,
                        "averageHR": 140,
                        "elevationGain": 20,
                    },
                    {
                        "activityId": 2,
                        "activityName": "Long run",
                        "distance": 10000,
                        "duration": 3300,
                        "averageHR": 150,
                        "elevationGain": 80,
                    },
                ]
            }

        with patch.object(garmin_server, "garmin_search_activities", new=fake_search):
            result = await garmin_get_running_summary("2026-10-26", "2026-10-28")

        self.assertEqual(result["activity_count"], 2)
        self.assertEqual(result["total_distance_km"], 15.0)
        self.assertEqual(result["total_duration_s"], 4800.0)
        self.assertEqual(result["average_pace_min_per_km"], 5.33)
        self.assertEqual(result["duration_weighted_average_hr_bpm"], 146.9)
        self.assertEqual(result["total_elevation_gain_m"], 100.0)

    async def test_distance_missing_activity_does_not_inflate_running_duration_or_pace(self):
        async def fake_search(**kwargs):
            return {"results": [
                {"activityId": 1, "activityName": "Garmin run", "distance": 5000, "duration": 2100, "averageHR": 140},
                {"activityId": 2, "activityName": "Synced jogging entry", "distance": None, "duration": 1800, "averageHR": 120},
                {"activityId": 3, "activityName": "Garmin run 2", "distance": 5000, "duration": 2100, "averageHR": 145},
            ]}

        with patch.object(garmin_server, "garmin_search_activities", new=fake_search):
            result = await garmin_get_running_summary("2026-10-28", "2026-10-28")

        self.assertEqual(result["activity_count"], 3)
        self.assertEqual(result["total_distance_km"], 10.0)
        self.assertEqual(result["total_duration_s"], 4200.0)
        self.assertEqual(result["average_pace_min_per_km"], 7.0)
        self.assertEqual(result["duration_weighted_average_hr_bpm"], 142.5)
        self.assertEqual(len(result["activities"]), 3)

    async def test_missing_metrics_are_not_invented(self):
        async def fake_search(**kwargs):
            return {"results": [{"activityId": 3, "activityName": "Unusual record"}]}

        with patch.object(garmin_server, "garmin_search_activities", new=fake_search):
            result = await garmin_get_running_summary("2026-10-28", "2026-10-28")

        self.assertEqual(result["activity_count"], 1)
        self.assertIsNone(result["total_distance_km"])
        self.assertIsNone(result["average_pace_min_per_km"])
        self.assertIsNone(result["duration_weighted_average_hr_bpm"])

    async def test_invalid_date_range_is_rejected(self):
        with self.assertRaises(ValueError):
            await garmin_get_running_summary("2026-10-29", "2026-10-28")


if __name__ == "__main__":
    unittest.main()
