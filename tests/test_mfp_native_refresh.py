import time
import unittest
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, patch

from api import mfp_native_auth, mfp_native_client, mfp_native_routes, mfp_native_vault


class NativeNutritionRefreshTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.day = "2026-11-01"
        self.expiring = {
            "access_token": "old-access",
            "refresh_token": "old-refresh",
            "expires_at": time.time() + 10,
            "domain_user_id": "mfp-user",
        }
        self.renewed = {
            "access_token": "new-access",
            "refresh_token": "rotated-refresh",
            "expires_at": time.time() + 3600,
            "domain_user_id": "mfp-user",
        }

    async def test_expiring_session_is_refreshed_and_rotated_pair_is_saved(self):
        get_record = AsyncMock(side_effect=[self.expiring, self.expiring])
        refresh = AsyncMock(return_value=self.renewed)
        save = AsyncMock()
        diary = AsyncMock(return_value={"items": []})
        goals = AsyncMock(return_value={})

        @asynccontextmanager
        async def lock(*_args, **_kwargs):
            yield

        with (
            patch.object(mfp_native_vault, "get_token_record", get_record),
            patch.object(mfp_native_vault, "refresh_lock", lock),
            patch.object(mfp_native_auth, "refresh", refresh),
            patch.object(mfp_native_vault, "save_token_record", save),
            patch.object(mfp_native_client, "fetch_diary", diary),
            patch.object(mfp_native_client, "fetch_goals", goals),
        ):
            result = await mfp_native_routes.native_nutrition("user-a", self.day)

        refresh.assert_awaited_once_with(self.expiring)
        save.assert_awaited_once_with("user-a", self.renewed)
        diary.assert_awaited_once_with("new-access", "mfp-user", self.day)
        goals.assert_awaited_once_with("new-access", "mfp-user")
        self.assertEqual(result["day"], self.day)


    async def test_rejected_unexpired_access_token_is_refreshed_and_retried(self):
        valid_old = {**self.expiring, "expires_at": time.time() + 3600}
        get_record = AsyncMock(side_effect=[valid_old, valid_old])
        refresh = AsyncMock(return_value=self.renewed)
        save = AsyncMock()
        diary = AsyncMock(side_effect=[
            mfp_native_client.NativeMFPDiaryError("rejected", 401),
            {"items": []},
        ])
        goals = AsyncMock(return_value={})

        @asynccontextmanager
        async def lock(*_args, **_kwargs):
            yield

        with (
            patch.object(mfp_native_vault, "get_token_record", get_record),
            patch.object(mfp_native_vault, "refresh_lock", lock),
            patch.object(mfp_native_auth, "refresh", refresh),
            patch.object(mfp_native_vault, "save_token_record", save),
            patch.object(mfp_native_client, "fetch_diary", diary),
            patch.object(mfp_native_client, "fetch_goals", goals),
        ):
            result = await mfp_native_routes.native_nutrition("user-a", self.day)

        refresh.assert_awaited_once_with(valid_old)
        save.assert_awaited_once_with("user-a", self.renewed)
        self.assertEqual(diary.await_count, 2)
        diary.assert_awaited_with("new-access", "mfp-user", self.day)
        self.assertEqual(result["day"], self.day)

    async def test_valid_session_skips_refresh(self):
        valid = {**self.renewed, "expires_at": time.time() + 3600}
        get_record = AsyncMock(return_value=valid)
        refresh = AsyncMock()
        save = AsyncMock()
        diary = AsyncMock(return_value={"items": []})
        goals = AsyncMock(return_value={})

        with (
            patch.object(mfp_native_vault, "get_token_record", get_record),
            patch.object(mfp_native_auth, "refresh", refresh),
            patch.object(mfp_native_vault, "save_token_record", save),
            patch.object(mfp_native_client, "fetch_diary", diary),
            patch.object(mfp_native_client, "fetch_goals", goals),
        ):
            await mfp_native_routes.native_nutrition('user-a', self.day)

        refresh.assert_not_awaited()
        save.assert_not_awaited()
        diary.assert_awaited_once_with("new-access", "mfp-user", self.day)

    async def test_refresh_lock_recheck_uses_tokens_renewed_by_another_request(self):
        valid = {**self.renewed, "expires_at": time.time() + 3600}
        get_record = AsyncMock(side_effect=[self.expiring, valid])
        refresh = AsyncMock()
        save = AsyncMock()
        diary = AsyncMock(return_value={"items": []})
        goals = AsyncMock(return_value={})

        @asynccontextmanager
        async def lock(*_args, **_kwargs):
            yield

        with (
            patch.object(mfp_native_vault, "get_token_record", get_record),
            patch.object(mfp_native_vault, "refresh_lock", lock),
            patch.object(mfp_native_auth, "refresh", refresh),
            patch.object(mfp_native_vault, "save_token_record", save),
            patch.object(mfp_native_client, "fetch_diary", diary),
            patch.object(mfp_native_client, "fetch_goals", goals),
        ):
            await mfp_native_routes.native_nutrition('user-a', self.day)

        refresh.assert_not_awaited()
        save.assert_not_awaited()
        diary.assert_awaited_once_with("new-access", "mfp-user", self.day)


if __name__ == "__main__":
    unittest.main()
