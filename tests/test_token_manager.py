import os
os.environ.setdefault("RUNFUEL_BASE_URL", "https://runfuel-test.example")

import asyncio
import os
import unittest
from types import SimpleNamespace
from unittest import mock

from cryptography.fernet import Fernet

from api import oauth_auth, token_manager


class TokenManagerTests(unittest.TestCase):
    def setUp(self):
        self.store = {}
        self.original_key = os.environ.get("RUNFUEL_SECRET_ENCRYPTION_KEY")
        self.original_password = os.environ.get("RUNFUEL_OAUTH_PASSWORD")
        self.original_redis_token = os.environ.get("UPSTASH_REDIS_REST_TOKEN")
        os.environ["RUNFUEL_SECRET_ENCRYPTION_KEY"] = Fernet.generate_key().decode()
        os.environ["RUNFUEL_OAUTH_PASSWORD"] = "test-password-only"
        os.environ["UPSTASH_REDIS_REST_TOKEN"] = "test-upstash-token-only"

        async def fake_redis(command):
            op = command[0].upper()
            if op == "SET":
                self.store[command[1]] = command[2]
                return "OK"
            if op == "GET":
                return self.store.get(command[1])
            raise AssertionError(f"Unexpected Redis command: {op}")

        self.patcher = mock.patch.object(oauth_auth, "_redis", side_effect=fake_redis)
        self.patcher.start()

    def tearDown(self):
        self.patcher.stop()
        for name, value in (
            ("RUNFUEL_SECRET_ENCRYPTION_KEY", self.original_key),
            ("RUNFUEL_OAUTH_PASSWORD", self.original_password),
            ("UPSTASH_REDIS_REST_TOKEN", self.original_redis_token),
        ):
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    def test_credential_is_encrypted_in_redis_and_round_trips(self):
        secret = "private-cookie-value-not-for-logs"
        asyncio.run(token_manager.save_credential("MFP_COOKIE", secret))
        ciphertext = self.store[token_manager.REDIS_PREFIX + "MFP_COOKIE"]
        self.assertNotIn(secret, ciphertext)
        self.assertEqual(asyncio.run(token_manager.get_credential("MFP_COOKIE")), secret)

    def test_unknown_credential_is_rejected(self):
        with self.assertRaises(ValueError):
            asyncio.run(token_manager.save_credential("ARBITRARY_ENV", "value"))

    def test_empty_or_oversized_secret_is_rejected(self):
        with self.assertRaises(ValueError):
            asyncio.run(token_manager.save_credential("MFP_COOKIE", "  "))
        with self.assertRaises(ValueError):
            asyncio.run(token_manager.save_credential("MFP_USERNAME", "x" * 257))

    def test_automatic_encryption_key_derivation_round_trips_without_extra_env_var(self):
        os.environ.pop("RUNFUEL_SECRET_ENCRYPTION_KEY", None)
        secret = "cookie-encrypted-with-derived-key"
        asyncio.run(token_manager.save_credential("MFP_COOKIE", secret))
        self.assertEqual(asyncio.run(token_manager.get_credential("MFP_COOKIE")), secret)
        self.assertEqual(token_manager._encryption_key_source(), "Automatic encryption ready")

    def test_missing_encryption_key_and_derivation_secrets_fails_closed(self):
        os.environ.pop("RUNFUEL_SECRET_ENCRYPTION_KEY", None)
        os.environ.pop("RUNFUEL_OAUTH_PASSWORD", None)
        os.environ.pop("UPSTASH_REDIS_REST_TOKEN", None)
        with self.assertRaises(RuntimeError):
            asyncio.run(token_manager.save_credential("MFP_COOKIE", "cookie"))

    def test_origin_check_accepts_canonical_https_origin_with_default_port(self):
        with mock.patch.object(oauth_auth, "BASE_URL", "https://example-runfuel.vercel.app"):
            self.assertTrue(token_manager._same_canonical_origin("https://example-runfuel.vercel.app"))
            self.assertTrue(token_manager._same_canonical_origin("https://RUNFUEL-MCP.VERCEL.APP:443"))

    def test_origin_check_rejects_other_hosts_and_unsafe_origins(self):
        with mock.patch.object(oauth_auth, "BASE_URL", "https://example-runfuel.vercel.app"):
            for origin in (
                "http://example-runfuel.vercel.app",
                "https://attacker.example",
                "https://example-runfuel.vercel.app.evil.example",
                "https://example-runfuel.vercel.app/settings",
                "null",
            ):
                with self.subTest(origin=origin):
                    self.assertFalse(token_manager._same_canonical_origin(origin))

    def test_null_origin_uses_same_origin_https_referer_fallback(self):
        with mock.patch.object(oauth_auth, "BASE_URL", "https://example-runfuel.vercel.app"):
            request = SimpleNamespace(headers={
                "referer": "https://example-runfuel.vercel.app/settings",
                "host": "example-runfuel.vercel.app",
                "sec-fetch-site": "same-origin",
            })
            self.assertTrue(token_manager._valid_settings_origin(request, "null"))

    def test_null_origin_referer_fallback_rejects_cross_origin_or_untrusted_host(self):
        with mock.patch.object(oauth_auth, "BASE_URL", "https://example-runfuel.vercel.app"):
            cases = [
                {"referer": "https://attacker.example/settings", "host": "example-runfuel.vercel.app", "sec-fetch-site": "same-origin"},
                {"referer": "http://example-runfuel.vercel.app/settings", "host": "example-runfuel.vercel.app", "sec-fetch-site": "same-origin"},
                {"referer": "https://example-runfuel.vercel.app/settings", "host": "attacker.example", "sec-fetch-site": "same-origin"},
                {"referer": "https://example-runfuel.vercel.app/settings", "host": "example-runfuel.vercel.app", "sec-fetch-site": "cross-site"},
            ]
            for headers in cases:
                with self.subTest(headers=headers):
                    self.assertFalse(token_manager._valid_settings_origin(SimpleNamespace(headers=headers), "null"))

    def test_non_null_invalid_origin_does_not_use_referer_fallback(self):
        with mock.patch.object(oauth_auth, "BASE_URL", "https://example-runfuel.vercel.app"):
            request = SimpleNamespace(headers={
                "referer": "https://example-runfuel.vercel.app/settings",
                "host": "example-runfuel.vercel.app",
                "sec-fetch-site": "same-origin",
            })
            self.assertFalse(token_manager._valid_settings_origin(request, "https://attacker.example"))

    def test_manager_requires_basic_auth(self):
        no_auth = SimpleNamespace(headers={})
        self.assertFalse(token_manager._authorized(no_auth))
        encoded = __import__("base64").b64encode(b"admin:test-password-only").decode()
        valid = SimpleNamespace(headers={"authorization": f"Basic {encoded}"})
        self.assertTrue(token_manager._authorized(valid))
        wrong = SimpleNamespace(headers={"authorization": "Basic " + __import__("base64").b64encode(b"admin:wrong").decode()})
        self.assertFalse(token_manager._authorized(wrong))

    def test_auth_failure_response_is_rate_limited(self):
        request = SimpleNamespace(headers={"x-forwarded-for": "192.0.2.1"})
        with mock.patch.object(oauth_auth, "_allow_login_attempt", new=mock.AsyncMock(return_value=False)):
            response = asyncio.run(token_manager._auth_failure_response(request))
        self.assertEqual(response.status_code, 429)
        self.assertEqual(response.headers["Retry-After"], str(oauth_auth.LOGIN_RATE_WINDOW))

    def test_rendered_page_never_contains_stored_secret(self):
        secret = "cookie-should-never-be-rendered"
        page = token_manager._page({"MFP_COOKIE": "Stored encrypted"})
        self.assertNotIn(secret, page)
        self.assertNotIn('value="' + secret, page)
        self.assertIn("Leave blank to keep current value", page)


if __name__ == "__main__":
    unittest.main()
