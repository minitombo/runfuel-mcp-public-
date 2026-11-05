import datetime
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from api.nutrition_metrics import fitness_get_nutrition_details
from myfitnesspal_mcp import server as mfp_server


class NutritionDetailsTests(unittest.IsolatedAsyncioTestCase):
    async def test_returns_all_available_nutrients_and_goals_read_only(self):
        source_day = SimpleNamespace(
            totals={
                "calories": 1800,
                "protein": 140,
                "carbohydrates": 180,
                "fat": 50,
                "fiber": 24,
                "sugar": 35,
                "sodium": 1700,
                "unavailable": None,
            },
            goals={"calories": 2000, "protein": 150, "fiber": 30},
            meals=[
                SimpleNamespace(
                    name="breakfast",
                    entries=[
                        SimpleNamespace(
                            name="Oats",
                            totals={"calories": 300, "fiber": 8, "sugar": 4},
                        )
                    ],
                )
            ],
        )

        class FakeClient:
            def get_date(self, day):
                self.requested_day = day
                return source_day

        fake_client = FakeClient()

        async def fake_with_session(ctx, operation):
            return operation(None, fake_client)

        with patch.object(mfp_server, "with_session", new=fake_with_session):
            result = await fitness_get_nutrition_details("2026-10-28")

        self.assertEqual(result["day"], "2026-10-28")
        self.assertEqual(result["totals"]["fiber"], 24.0)
        self.assertEqual(result["totals"]["sodium"], 1700.0)
        self.assertNotIn("unavailable", result["totals"])
        self.assertEqual(result["goals"]["protein"], 150.0)
        self.assertEqual(result["meals"][0]["entries"][0]["nutrients"]["fiber"], 8.0)
        self.assertEqual(fake_client.requested_day, datetime.date(2026, 10, 28))


if __name__ == "__main__":
    unittest.main()
