"""Unit tests for read-only MyFitnessPal compatibility helpers."""
import unittest
from unittest.mock import AsyncMock, patch

from api import mfp_compat


class MfpCompatTests(unittest.IsolatedAsyncioTestCase):
    async def test_goals_returns_only_source_goal_fields(self):
        with patch(
            "api.mfp_compat.fitness_get_nutrition_details",
            new=AsyncMock(return_value={
                "day": "2026-10-28",
                "goals": {"calories": 2016.0},
                "available_goal_fields": ["calories"],
            }),
        ):
            result = await mfp_compat.mfp_get_goals("2026-10-28")
        self.assertEqual(result["date"], "2026-10-28")
        self.assertEqual(result["goals"], {"calories": 2016.0})
        self.assertNotIn("protein", result["goals"])

    async def test_measurements_is_explicitly_weight_trend_only(self):
        with patch(
            "api.mfp_compat.mfp_server.fitness_get_trends",
            new=AsyncMock(return_value={
                "metric": "weight",
                "points": [{"day": "2026-10-28", "value": 90.0}],
            }),
        ):
            result = await mfp_compat.mfp_get_measurements(
                "2026-10-28", "2026-10-29"
            )
        self.assertEqual(result["measurement"], "weight")
        self.assertEqual(result["points"][0]["value"], 90.0)
        self.assertTrue(any("not a direct full body-measurement" in item
                            for item in result["limitations"]))


if __name__ == "__main__":
    unittest.main()
