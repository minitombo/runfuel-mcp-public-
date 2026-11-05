import os
os.environ.setdefault("RUNFUEL_BASE_URL", "https://runfuel-test.example")

import unittest
from unittest.mock import AsyncMock, patch

from api.mfp_compat import mfp_bulk_export_bounded


class BoundedBulkExportTests(unittest.IsolatedAsyncioTestCase):
    async def test_default_export_is_limited_to_seven_days(self):
        with patch("api.mfp_compat.mfp_server.fitness_bulk_export", new=AsyncMock(return_value={"count": 7})) as export:
            result = await mfp_bulk_export_bounded(end="2026-10-31")
        self.assertEqual(result, {"count": 7})
        export.assert_awaited_once_with(
            start="2026-10-25",
            end="2026-10-31",
            sync_first=False,
            ctx=None,
        )

    async def test_explicit_export_can_cover_up_to_31_days(self):
        with patch("api.mfp_compat.mfp_server.fitness_bulk_export", new=AsyncMock(return_value={"count": 31})) as export:
            await mfp_bulk_export_bounded(start="2026-10-01", end="2026-10-31")
        export.assert_awaited_once()

    async def test_export_over_31_days_is_rejected_before_upstream_call(self):
        with patch("api.mfp_compat.mfp_server.fitness_bulk_export", new=AsyncMock()) as export:
            with self.assertRaisesRegex(ValueError, "maximum per export is 31 days"):
                await mfp_bulk_export_bounded(start="2026-09-30", end="2026-10-31")
        export.assert_not_awaited()

    async def test_reversed_date_range_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "on or before"):
            await mfp_bulk_export_bounded(start="2026-10-31", end="2026-10-01")


if __name__ == "__main__":
    unittest.main()
