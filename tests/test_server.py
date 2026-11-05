import os
os.environ.setdefault("RUNFUEL_BASE_URL", "https://runfuel-test.example")

import asyncio
import os
import time
import unittest
from http.cookiejar import Cookie
from types import SimpleNamespace
from unittest import mock

from api import index, request_identity
from api.index import BLOCKED_MFP_TOOLS, GARMIN_READ_TOOLS, MFP_READ_TOOLS, authorized



class ManagedMfpSessionPersistenceTests(unittest.TestCase):
    def setUp(self):
        self.original_cookie = os.environ.get("MFP_COOKIE")
        self.original_last_cookie = index._last_mfp_cookie
        self.client = SimpleNamespace(
            saved_cookies={"__Secure-next-auth.session-token": "old-session"},
            loaded_cookies={"__Secure-next-auth.session-token": "old-session"},
        )
        self.client_patch = mock.patch.object(index.mfp_client, "_client", self.client)
        self.client_patch.start()

    def tearDown(self):
        self.client_patch.stop()
        index._last_mfp_cookie = self.original_last_cookie
        if self.original_cookie is None:
            os.environ.pop("MFP_COOKIE", None)
        else:
            os.environ["MFP_COOKIE"] = self.original_cookie

    def test_rotated_session_cookie_is_saved_to_encrypted_managed_storage(self):
        rotated = {"__Secure-next-auth.session-token": "new-session"}
        save = mock.AsyncMock()
        with (
            mock.patch.object(index, "_managed_session_cookies", return_value=rotated),
            mock.patch.object(index.token_manager, "save_credential", save),
        ):
            persisted = asyncio.run(index.persist_managed_mfp_session())

        self.assertTrue(persisted)
        save.assert_awaited_once_with(
            "MFP_COOKIE", "__Secure-next-auth.session-token=new-session"
        )
        self.assertEqual(os.environ["MFP_COOKIE"], "__Secure-next-auth.session-token=new-session")
        self.assertEqual(self.client.saved_cookies, rotated)
        self.assertEqual(self.client.loaded_cookies, rotated)
        self.assertEqual(index._last_mfp_cookie, os.environ["MFP_COOKIE"])

    def test_unchanged_session_cookie_is_not_rewritten(self):
        unchanged = dict(self.client.saved_cookies)
        save = mock.AsyncMock()
        with (
            mock.patch.object(index, "_managed_session_cookies", return_value=unchanged),
            mock.patch.object(index.token_manager, "save_credential", save),
        ):
            persisted = asyncio.run(index.persist_managed_mfp_session())

        self.assertFalse(persisted)
        save.assert_not_awaited()

    def test_missing_session_cookie_is_not_saved(self):
        save = mock.AsyncMock()
        with (
            mock.patch.object(index, "_managed_session_cookies", return_value={"other": "value"}),
            mock.patch.object(index.token_manager, "save_credential", save),
        ):
            persisted = asyncio.run(index.persist_managed_mfp_session())

        self.assertFalse(persisted)
        save.assert_not_awaited()


class ManagedMfpWarmSessionRenewalTests(unittest.TestCase):
    def test_cached_client_is_renewed_before_reuse(self):
        client = SimpleNamespace(session_renewed=False)
        with (
            mock.patch.object(index.mfp_client, "_client", client),
            mock.patch.object(index, "_renew_mfp_client_session", return_value=True) as renew,
        ):
            result = asyncio.run(index.renew_managed_mfp_session())

        self.assertTrue(result)
        self.assertTrue(client.session_renewed)
        renew.assert_called_once_with(client)

    def test_cold_worker_initializes_client_before_renewal(self):
        client = SimpleNamespace(session_renewed=False)
        with (
            mock.patch.object(index.mfp_client, "_client", None),
            mock.patch.object(index.mfp_client, "get_client", return_value=client),
            mock.patch.object(index, "_renew_mfp_client_session", return_value=True) as renew,
        ):
            result = asyncio.run(index.renew_managed_mfp_session())

        self.assertTrue(result)
        self.assertTrue(client.session_renewed)
        renew.assert_called_once_with(client)

    def test_failed_cached_renewal_is_safe_and_recorded(self):
        client = SimpleNamespace(session_renewed=True)
        with (
            mock.patch.object(index.mfp_client, "_client", client),
            mock.patch.object(index, "_renew_mfp_client_session", return_value=False),
        ):
            result = asyncio.run(index.renew_managed_mfp_session())

        self.assertFalse(result)
        self.assertFalse(client.session_renewed)


class ManagedMfpCookieJarTests(unittest.TestCase):
    @staticmethod
    def _cookie(name, value, *, domain=".myfitnesspal.com", expires=None):
        return Cookie(
            version=0, name=name, value=value, port=None, port_specified=False,
            domain=domain, domain_specified=True, domain_initial_dot=domain.startswith("."),
            path="/", path_specified=True, secure=True, expires=expires,
            discard=expires is None, comment=None, comment_url=None, rest={},
            rfc2109=False,
        )

    def test_keeps_unchanged_session_and_extracts_rotated_session(self):
        old = "old-session"
        client = SimpleNamespace(
            session=SimpleNamespace(cookies=SimpleNamespace(jar=[
                self._cookie("__Secure-next-auth.session-token", old, expires=None),
                self._cookie("csrf-token", "rotated-csrf", expires=int(time.time()) + 3600),
                self._cookie("unrelated", "ignore", domain=".example.com", expires=int(time.time()) + 3600),
            ])),
            loaded_cookies={"__Secure-next-auth.session-token": old},
        )
        self.assertEqual(
            index._managed_session_cookies(client),
            {
                "__Secure-next-auth.session-token": old,
                "csrf-token": "rotated-csrf",
            },
        )

    def test_extracts_rotated_session_cookie_without_expiry_attribute(self):
        client = SimpleNamespace(
            session=SimpleNamespace(cookies=SimpleNamespace(jar=[
                self._cookie(
                    "__Secure-next-auth.session-token",
                    "rotated-session",
                    expires=None,
                ),
            ])),
            loaded_cookies={"__Secure-next-auth.session-token": "old-session"},
        )
        self.assertEqual(
            index._managed_session_cookies(client),
            {"__Secure-next-auth.session-token": "rotated-session"},
        )

    def test_drops_expired_cookie(self):
        client = SimpleNamespace(
            session=SimpleNamespace(cookies=SimpleNamespace(jar=[
                self._cookie("__Secure-next-auth.session-token", "expired", expires=int(time.time()) - 60),
            ])),
            loaded_cookies={},
        )
        self.assertEqual(index._managed_session_cookies(client), {})



    def test_shared_cookie_credentials_are_not_loaded_into_mcp_runtime(self):
        old_cookie = os.environ.get("MFP_COOKIE")
        old_username = os.environ.get("MFP_USERNAME")
        os.environ["MFP_COOKIE"] = "shared-cookie-must-not-be-loaded"
        os.environ["MFP_USERNAME"] = "shared-user"
        try:
            with (
                mock.patch.object(index.token_manager, "get_credential", new=mock.AsyncMock(return_value=None)),
                mock.patch.object(index.mfp_client, "reset") as reset,
            ):
                asyncio.run(index.apply_managed_credentials())
            self.assertNotIn("MFP_COOKIE", os.environ)
            self.assertNotIn("MFP_USERNAME", os.environ)
        finally:
            if old_cookie is None:
                os.environ.pop("MFP_COOKIE", None)
            else:
                os.environ["MFP_COOKIE"] = old_cookie
            if old_username is None:
                os.environ.pop("MFP_USERNAME", None)
            else:
                os.environ["MFP_USERNAME"] = old_username

class AuthenticationTests(unittest.TestCase):
    def test_missing_config_fails_closed(self):
        self.assertFalse(authorized([(b"authorization", b"Bearer token")], None))

    def test_missing_header_is_rejected(self):
        self.assertFalse(authorized([], "secret"))

    def test_wrong_token_is_rejected(self):
        self.assertFalse(authorized([(b"authorization", b"Bearer wrong")], "secret"))

    def test_valid_bearer_token_is_accepted(self):
        self.assertTrue(authorized([(b"authorization", b"Bearer secret")], "secret"))

    def test_non_bearer_scheme_is_rejected(self):
        self.assertFalse(authorized([(b"authorization", b"Basic secret")], "secret"))


class ReadOnlyAllowlistTests(unittest.TestCase):
    def test_known_mutating_mfp_tools_are_not_allowlisted(self):
        self.assertTrue(set(MFP_READ_TOOLS).isdisjoint(BLOCKED_MFP_TOOLS))

    def test_download_tool_is_not_exposed(self):
        self.assertNotIn("garmin_download_activity", GARMIN_READ_TOOLS)

    def test_profile_tool_is_not_exposed_but_activity_detail_remains_available(self):
        self.assertNotIn("garmin_get_profile", GARMIN_READ_TOOLS)
        self.assertIn("garmin_get_activity", GARMIN_READ_TOOLS)
        self.assertIn("garmin_search_activities", GARMIN_READ_TOOLS)


    def test_only_per_user_native_mfp_tools_are_registered(self):
        registered = set(index.mcp._tool_manager._tools)
        expected = {
            "mfp_connect_account", "mfp_connection_status", "mfp_disconnect_account",
            "mfp_get_diary", "mfp_get_goals", "mfp_get_report",
        }
        self.assertTrue(expected.issubset(registered))
        self.assertTrue({
            "fitness_check_connection", "fitness_get_day",
            "fitness_get_nutrition_details", "fitness_bulk_export",
            "fitness_search_food", "fitness_get_trends", "fitness_list_food_pins",
        }.isdisjoint(registered))
    def test_expected_read_tools_are_allowlisted(self):
        self.assertEqual(set(MFP_READ_TOOLS), set())

    def test_mfp_exercise_tools_are_not_allowlisted(self):
        self.assertNotIn("fitness_get_exercise", MFP_READ_TOOLS)
        self.assertNotIn("fitness_get_exercise_entries", MFP_READ_TOOLS)



class PerUserNativeMfpToolTests(unittest.TestCase):
    def test_connection_status_uses_only_current_principal(self):
        principal_token = request_identity.set_principal("principal-a")
        record = {"expires_at": 1900000000}
        try:
            with mock.patch.object(index.mfp_native_routes.mfp_native_vault, "get_token_record", new=mock.AsyncMock(return_value=record)) as get_record:
                result = asyncio.run(index.mfp_connection_status())
            self.assertTrue(result["connected"])
            get_record.assert_awaited_once_with("principal-a")
        finally:
            request_identity.reset_principal(principal_token)

    def test_disconnect_deletes_only_current_principal(self):
        principal_token = request_identity.set_principal("principal-b")
        try:
            with (
                mock.patch.object(index.mfp_native_routes.mfp_native_vault, "delete_token_record", new=mock.AsyncMock()) as delete_record,
                mock.patch.object(index.mfp_cookie_vault, "delete_record", new=mock.AsyncMock()) as delete_cookie,
            ):
                result = asyncio.run(index.mfp_disconnect_account())
            self.assertFalse(result["connected"])
            delete_record.assert_awaited_once_with("principal-b")
            delete_cookie.assert_awaited_once_with("principal-b")
        finally:
            request_identity.reset_principal(principal_token)

    def test_goals_tool_returns_only_native_user_goals(self):
        principal_token = request_identity.set_principal("principal-c")
        try:
            with mock.patch.object(index, "mfp_get_diary", new=mock.AsyncMock(return_value={
                "connected": True, "day": "2026-11-02", "goals": {"calories": 2100}
            })) as diary:
                result = asyncio.run(index.mfp_get_goals("2026-11-02"))
            diary.assert_awaited_once_with("2026-11-02")
            self.assertEqual(result["goals"], {"calories": 2100})
        finally:
            request_identity.reset_principal(principal_token)


    def test_legacy_bulk_sync_flag_is_rejected_not_silently_ignored(self):
        principal_token = request_identity.set_principal("principal-f")
        try:
            with self.assertRaisesRegex(ValueError, "sync_first is not supported"):
                asyncio.run(index.fitness_bulk_export_native(sync_first=True))
        finally:
            request_identity.reset_principal(principal_token)
    def test_report_rejects_more_than_31_days(self):
        principal_token = request_identity.set_principal("principal-d")
        try:
            with self.assertRaises(ValueError):
                asyncio.run(index.mfp_get_report(start="2026-01-01", end="2026-02-01"))
        finally:
            request_identity.reset_principal(principal_token)

    def test_report_reads_each_day_for_current_principal(self):
        principal_token = request_identity.set_principal("principal-e")
        try:
            with mock.patch.object(index.mfp_native_routes, "native_nutrition", new=mock.AsyncMock(return_value={"day": "2026-11-01", "totals": {}})) as read_day:
                result = asyncio.run(index.mfp_get_report(start="2026-11-01", end="2026-11-03"))
            self.assertTrue(result["connected"])
            self.assertEqual(len(result["days"]), 3)
            self.assertEqual(read_day.await_args_list, [
                mock.call("principal-e", "2026-11-01"),
                mock.call("principal-e", "2026-11-02"),
                mock.call("principal-e", "2026-11-03"),
            ])
        finally:
            request_identity.reset_principal(principal_token)


if __name__ == "__main__":
    unittest.main()
