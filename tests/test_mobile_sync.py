import asyncio
import json
import unittest
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from unittest import mock

from starlette.requests import Request

from api import index


class MobileSyncHistoricalDateTests(unittest.TestCase):
    def _request(self, query_string: bytes) -> Request:
        return Request({
            "type": "http",
            "method": "GET",
            "path": "/api/mobile/sync",
            "headers": [(b"authorization", b"Bearer test-access-token")],
            "query_string": query_string,
        })

    def test_selected_previous_day_is_used_for_garmin_and_mfp(self):
        selected = datetime.now(ZoneInfo("Pacific/Auckland")).date() - timedelta(days=1)
        end = selected.isoformat()
        start = (selected - timedelta(days=6)).isoformat()

        async def run():
            with (
                mock.patch.object(index.oauth_auth, "get_access_principal", new=mock.AsyncMock(return_value="principal-1")),
                mock.patch.object(index, "apply_managed_credentials", new=mock.AsyncMock()),
                mock.patch.object(index, "garmin_get_running_summary", new=mock.AsyncMock(return_value={"start": start, "end": end})) as running,
                mock.patch.object(index.garmin_server, "garmin_get_daily_summary", new=mock.AsyncMock(return_value={"date": end})) as daily,
                mock.patch.object(index.garmin_server, "garmin_get_sleep", new=mock.AsyncMock(return_value={"date": end})) as sleep,
                mock.patch.object(index.garmin_server, "garmin_get_hrv", new=mock.AsyncMock(return_value={"date": end})) as hrv,
                mock.patch.object(index.mfp_native_routes, "native_nutrition", new=mock.AsyncMock(return_value={"day": end})) as nutrition,
            ):
                response = await index.mobile_sync(self._request(f"date={end}".encode()))
                payload = json.loads(response.body)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(payload["date"], end)
                self.assertEqual(payload["garmin"]["running_summary"], {"start": start, "end": end})
                self.assertEqual(payload["myfitnesspal"]["nutrition"], {"day": end})
                running.assert_awaited_once_with(start=start, end=end)
                daily.assert_awaited_once_with(date=end)
                sleep.assert_awaited_once_with(date=end)
                hrv.assert_awaited_once_with(date=end)
                nutrition.assert_awaited_once_with("principal-1", end)

        asyncio.run(run())

    def test_invalid_date_is_rejected_before_provider_calls(self):
        async def run():
            with (
                mock.patch.object(index.oauth_auth, "get_access_principal", new=mock.AsyncMock(return_value="principal-1")),
                mock.patch.object(index, "apply_managed_credentials", new=mock.AsyncMock()) as apply_credentials,
                mock.patch.object(index.mfp_native_routes, "native_nutrition", new=mock.AsyncMock()) as nutrition,
            ):
                response = await index.mobile_sync(self._request(b"date=2026-02-30"))
                payload = json.loads(response.body)
                self.assertEqual(response.status_code, 400)
                self.assertIn("Invalid date", payload["error"])
                apply_credentials.assert_not_awaited()
                nutrition.assert_not_awaited()

        asyncio.run(run())

    def test_future_date_is_rejected(self):
        async def run():
            with (
                mock.patch.object(index.oauth_auth, "get_access_principal", new=mock.AsyncMock(return_value="principal-1")),
                mock.patch.object(index, "apply_managed_credentials", new=mock.AsyncMock()) as apply_credentials,
            ):
                response = await index.mobile_sync(self._request(b"date=2999-01-01"))
                payload = json.loads(response.body)
                self.assertEqual(response.status_code, 400)
                self.assertIn("Future dates", payload["error"])
                apply_credentials.assert_not_awaited()

        asyncio.run(run())


if __name__ == "__main__":
    unittest.main()
