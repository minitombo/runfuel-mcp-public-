import unittest
import asyncio
import os
from urllib.parse import urlencode
from unittest import mock
from contextlib import asynccontextmanager
from starlette.requests import Request
from api import mfp_native_routes, oauth_auth, mfp_native_auth, mfp_native_vault, mfp_native_client
from api.mfp_native_routes import _normalize_nutrition

class NativeNutritionMappingTests(unittest.TestCase):
    def test_food_entries_are_mapped_to_existing_runfuel_shape(self):
        result=_normalize_nutrition("2026-11-01",{"items":[
            {"meal_name":"Breakfast","food":{"description":"Oats"},"nutritional_contents":{"energy":{"value":250},"protein":10,"carbohydrates":40,"fat":5,"fiber":6,"sugar":3}},
            {"meal_name":"Lunch","food":{"description":"Rice"},"nutritional_contents":{"energy":{"value":300},"protein":8,"carbohydrates":55,"fat":4}}
        ]},{"default_goal":{"energy":{"value":2000},"protein":{"value":150}}})
        self.assertEqual(result["totals"]["calories"],550)
        self.assertEqual(result["totals"]["protein"],18)
        self.assertEqual(result["totals"]["fiber"],6)
        self.assertEqual(result["goals"]["calories"],2000)
        self.assertEqual(result["meals"][0]["entries"][0]["name"],"Oats")


class NativeMfpConnectLinkTests(unittest.IsolatedAsyncioTestCase):
    async def test_connect_link_is_random_short_lived_and_stores_only_hashed_ticket_key(self):
        commands = []
        async def redis(command):
            commands.append(command)
            return "OK"
        with mock.patch.object(oauth_auth, "_redis", side_effect=redis):
            url = await mfp_native_routes.create_connect_link("principal-123")
        self.assertTrue(url.startswith(oauth_auth.BASE_URL + "/mfp/connect?ticket="))
        ticket = url.split("ticket=", 1)[1]
        self.assertGreaterEqual(len(ticket), 32)
        self.assertEqual(commands[0][0], "SET")
        self.assertTrue(commands[0][1].startswith(mfp_native_routes.LINK_PREFIX))
        self.assertNotIn(ticket, commands[0][1])
        self.assertEqual(commands[0][2], "principal-123")
        self.assertEqual(commands[0][-2:], ["EX", str(mfp_native_routes.LINK_TTL_SECONDS)])

    async def test_connect_page_is_no_store_and_escapes_ticket(self):
        ticket = "a" * 40
        async def redis(command):
            return "principal-123"
        with mock.patch.object(oauth_auth, "_redis", side_effect=redis):
            request = Request({
                "type": "http", "method": "GET", "path": "/mfp/connect",
                "headers": [], "query_string": ("ticket=" + ticket).encode(),
                "server": ("test", 443), "client": ("127.0.0.1", 1234), "scheme": "https",
            })
            response = await mfp_native_routes.connect_page(request)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(response.headers["referrer-policy"], "no-referrer")
        self.assertIn(b'type="password"', response.body)
        self.assertIn(ticket.encode(), response.body)

    async def test_connect_submit_consumes_ticket_and_saves_encrypted_pair(self):
        body = urlencode({"ticket": "t" * 40, "username": "person@example.test", "password": "private-password"}).encode()
        commands = []
        async def redis(command):
            commands.append(command)
            if command[0] == "GETDEL":
                return "principal-123"
            return "OK"
        record = {"access_token": "a", "refresh_token": "r", "expires_at": 1900000000, "domain_user_id": "mfp-123"}
        async def receive():
            return {"type": "http.request", "body": body, "more_body": False}
        request = Request({
            "type": "http", "method": "POST", "path": "/mfp/connect",
            "headers": [
                (b"content-type", b"application/x-www-form-urlencoded"),
                (b"content-length", str(len(body)).encode()),
                (b"x-forwarded-for", b"192.0.2.55"),
            ],
            "query_string": b"", "server": ("test", 443),
            "client": ("127.0.0.1", 1234), "scheme": "https",
        }, receive)
        with (
            mock.patch.object(oauth_auth, "_allow_login_attempt", new=mock.AsyncMock(return_value=True)),
            mock.patch.object(oauth_auth, "_redis", side_effect=redis),
            mock.patch.dict(os.environ, {"MFP_NATIVE_CLIENT_ID": "test-client", "MFP_NATIVE_CLIENT_SECRET": "test-secret"}),
            mock.patch.object(mfp_native_auth, "login", new=mock.AsyncMock(return_value=record)) as login,
            mock.patch.object(mfp_native_vault, "save_token_record", new=mock.AsyncMock()) as save,
        ):
            response = await mfp_native_routes.connect_submit(request)
        self.assertEqual(response.status_code, 200)
        login.assert_awaited_once_with("person@example.test", "private-password")
        save.assert_awaited_once_with("principal-123", record)
        self.assertTrue(any(command[0] == "GETDEL" for command in commands))
        self.assertNotIn(b"private-password", response.body)

    async def test_connect_submit_rejects_wrong_content_type_before_ticket_consumption(self):
        body = b"not-a-form"
        redis = mock.AsyncMock()
        async def receive():
            return {"type": "http.request", "body": body, "more_body": False}
        request = Request({
            "type": "http", "method": "POST", "path": "/mfp/connect",
            "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode()), (b"x-forwarded-for", b"192.0.2.56")],
            "query_string": b"", "server": ("test", 443),
            "client": ("127.0.0.1", 1234), "scheme": "https",
        }, receive)
        with (
            mock.patch.object(oauth_auth, "_allow_login_attempt", new=mock.AsyncMock(return_value=True)),
            mock.patch.object(oauth_auth, "_redis", redis),
        ):
            response = await mfp_native_routes.connect_submit(request)
        self.assertEqual(response.status_code, 415)
        redis.assert_not_awaited()


@asynccontextmanager
async def _no_refresh_lock(_principal):
    yield


class NativeMfpRefreshDiagnosticsTests(unittest.IsolatedAsyncioTestCase):
    async def test_expired_refresh_reports_saved_credentials_and_rotation(self):
        old = {
            "access_token": "old-access", "refresh_token": "old-refresh",
            "expires_at": 1, "domain_user_id": "mfp-user",
        }
        renewed = {
            "access_token": "new-access", "refresh_token": "new-refresh",
            "expires_at": 1900000000, "domain_user_id": "mfp-user",
        }
        with (
            mock.patch.object(mfp_native_vault, "get_token_record", new=mock.AsyncMock(side_effect=[old, old])),
            mock.patch.object(mfp_native_vault, "refresh_lock", new=_no_refresh_lock),
            mock.patch.object(mfp_native_auth, "refresh", new=mock.AsyncMock(return_value=renewed)),
            mock.patch.object(mfp_native_vault, "save_token_record", new=mock.AsyncMock()) as save,
            mock.patch.object(mfp_native_client, "fetch_diary", new=mock.AsyncMock(return_value={"items": []})),
            mock.patch.object(mfp_native_client, "fetch_goals", new=mock.AsyncMock(return_value={"default_goal": {}})),
        ):
            result = await mfp_native_routes.native_nutrition("principal-a", "2026-11-02")
        self.assertTrue(result["auth_refresh"]["attempted"])
        self.assertEqual(result["auth_refresh"]["reason"], "expired")
        self.assertTrue(result["auth_refresh"]["refreshed"])
        self.assertTrue(result["auth_refresh"]["credentials_saved"])
        self.assertTrue(result["auth_refresh"]["refresh_token_rotated"])
        self.assertIsInstance(result["auth_refresh"]["refreshed_at"], int)
        self.assertGreaterEqual(result["auth_refresh"]["expires_in_seconds"], 0)
        save.assert_awaited_once_with("principal-a", renewed)

    async def test_near_expiry_refresh_reports_near_expiry_reason(self):
        record = {
            "access_token": "access", "refresh_token": "refresh",
            "expires_at": 150, "domain_user_id": "mfp-user",
        }
        renewed = {
            "access_token": "new-access", "refresh_token": "new-refresh",
            "expires_at": 1900000000, "domain_user_id": "mfp-user",
        }
        with (
            mock.patch.object(mfp_native_vault, "get_token_record", new=mock.AsyncMock(side_effect=[record, record])),
            mock.patch.object(mfp_native_vault, "refresh_lock", new=_no_refresh_lock),
            mock.patch.object(mfp_native_auth, "refresh", new=mock.AsyncMock(return_value=renewed)),
            mock.patch.object(mfp_native_vault, "save_token_record", new=mock.AsyncMock()),
            mock.patch.object(mfp_native_client, "fetch_diary", new=mock.AsyncMock(return_value={"items": []})),
            mock.patch.object(mfp_native_client, "fetch_goals", new=mock.AsyncMock(return_value={"default_goal": {}})),
            mock.patch.object(mfp_native_routes.time, "time", return_value=100),
        ):
            result = await mfp_native_routes.native_nutrition("principal-a", "2026-11-02")
        self.assertEqual(result["auth_refresh"]["reason"], "near_expiry")

    async def test_refresh_without_rotation_reports_false_and_persists_pair(self):
        old = {
            "access_token": "old-access", "refresh_token": "same-refresh",
            "expires_at": 1, "domain_user_id": "mfp-user",
        }
        renewed = {
            "access_token": "new-access", "refresh_token": "same-refresh",
            "expires_at": 1900000000, "domain_user_id": "mfp-user",
        }
        with (
            mock.patch.object(mfp_native_vault, "get_token_record", new=mock.AsyncMock(side_effect=[old, old])),
            mock.patch.object(mfp_native_vault, "refresh_lock"),
            mock.patch.object(mfp_native_auth, "refresh", new=mock.AsyncMock(return_value=renewed)),
            mock.patch.object(mfp_native_vault, "save_token_record", new=mock.AsyncMock()) as save,
            mock.patch.object(mfp_native_client, "fetch_diary", new=mock.AsyncMock(return_value={"items": []})),
            mock.patch.object(mfp_native_client, "fetch_goals", new=mock.AsyncMock(return_value={"default_goal": {}})),
        ):
            result = await mfp_native_routes.native_nutrition("principal-a", "2026-11-02")
        self.assertFalse(result["auth_refresh"]["refresh_token_rotated"])
        self.assertTrue(result["auth_refresh"]["credentials_saved"])
        save.assert_awaited_once_with("principal-a", renewed)

    async def test_not_needed_does_not_claim_credentials_were_saved(self):
        record = {
            "access_token": "access", "refresh_token": "refresh",
            "expires_at": 1900000000, "domain_user_id": "mfp-user",
        }
        with (
            mock.patch.object(mfp_native_vault, "get_token_record", new=mock.AsyncMock(return_value=record)),
            mock.patch.object(mfp_native_client, "fetch_diary", new=mock.AsyncMock(return_value={"items": []})),
            mock.patch.object(mfp_native_client, "fetch_goals", new=mock.AsyncMock(return_value={"default_goal": {}})),
        ):
            result = await mfp_native_routes.native_nutrition("principal-a", "2026-11-02")
        diagnostic = result["auth_refresh"]
        self.assertFalse(diagnostic["attempted"])
        self.assertFalse(diagnostic["refreshed"])
        self.assertIsNone(diagnostic["credentials_saved"])
        self.assertIsNone(diagnostic["refresh_token_rotated"])
        self.assertIsNone(diagnostic["refreshed_at"])

if __name__=="__main__":unittest.main()
