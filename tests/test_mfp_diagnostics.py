import unittest
from unittest.mock import patch

from api import mfp_diagnostics
from myfitnesspal_mcp import auth, config, mfp_client


class DiagnosticClassificationTests(unittest.TestCase):
    def test_cloudflare_or_403_is_classified_without_echoing_exception(self):
        exc = RuntimeError("Cloudflare 403 challenge; private-value-must-not-leak")
        self.assertEqual(mfp_diagnostics._category(exc, 403), "http_block_or_anti_bot_challenge")
        self.assertNotIn("private-value-must-not-leak", mfp_diagnostics._category(exc, 403))

    def test_auth_failure_is_classified_without_echoing_exception(self):
        exc = RuntimeError("session token rejected: private-value-must-not-leak")
        self.assertEqual(mfp_diagnostics._category(exc, None), "authentication_rejected")

    def test_network_exception_is_classified_without_echoing_exception(self):
        class ConnectError(RuntimeError):
            pass
        network_exc = ConnectError("private network details")
        self.assertEqual(mfp_diagnostics._category(network_exc, None), "network_error")


class ConnectionDiagnosticTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.common_patches = [
            patch.object(config, "cookie_env", return_value="session-cookie-value"),
            patch.object(auth, "load_cookies", return_value={auth.SESSION_COOKIE: "secret"}),
            patch.object(config, "username_env", return_value="private-user"),
            patch.object(config, "impersonate", return_value="chrome"),
        ]
        for item in self.common_patches:
            item.start()
            self.addCleanup(item.stop)

    async def test_missing_cookie_returns_safe_diagnostic(self):
        with (
            patch.object(config, "cookie_env", return_value=None),
            patch.object(auth, "load_cookies", return_value=None),
            patch.object(config, "username_env", return_value=""),
            patch.object(config, "impersonate", return_value="chrome"),
        ):
            result = await mfp_diagnostics.fitness_check_connection()

        self.assertFalse(result["connected"])
        self.assertEqual(result["category"], "missing_cookie")
        self.assertFalse(result["probe_performed"])
        self.assertNotIn("cookie_value", str(result))

    async def test_initialization_failure_reports_safe_category_and_status(self):
        class FakeResponse:
            status_code = 403

        exc = RuntimeError("challenge with secret-looking text")
        exc.response = FakeResponse()

        with patch.object(mfp_client, "get_client", side_effect=exc):
            result = await mfp_diagnostics.fitness_check_connection()

        rendered = str(result)
        self.assertFalse(result["connected"])
        self.assertEqual(result["http_status"], 403)
        self.assertEqual(result["category"], "http_block_or_anti_bot_challenge")
        self.assertTrue(result["probe_performed"])
        self.assertNotIn("secret-looking text", rendered)
        self.assertNotIn("'secret'", rendered)
        self.assertNotIn("private-user", rendered)
        self.assertNotIn("session-cookie-value", rendered)

    async def test_client_initialization_alone_is_not_reported_as_connected(self):
        class FakeClient:
            session_renewed = True
            effective_username = "private-user"

            def get_date(self, day):
                raise RuntimeError("session expired: private-cookie-secret")

        with patch.object(mfp_client, "get_client", return_value=FakeClient()):
            result = await mfp_diagnostics.fitness_check_connection()

        rendered = str(result)
        self.assertFalse(result["connected"])
        self.assertEqual(result["category"], "authentication_rejected")
        self.assertFalse(result["session_renewed"])
        self.assertTrue(result["probe_performed"])
        self.assertNotIn("private-cookie-secret", rendered)
        self.assertNotIn("private-user", rendered)

    async def test_successful_empty_diary_read_confirms_connection_without_returning_data(self):
        class FakeDiary:
            meals = []
            totals = {}

        class FakeClient:
            session_renewed = True
            effective_username = "private-user"

            def get_date(self, day):
                return FakeDiary()

        with patch.object(mfp_client, "get_client", return_value=FakeClient()):
            result = await mfp_diagnostics.fitness_check_connection()

        rendered = str(result)
        self.assertTrue(result["connected"])
        self.assertEqual(result["category"], "authenticated_read_succeeded")
        self.assertTrue(result["probe_performed"])
        self.assertTrue(result["session_renewed"])
        self.assertFalse(result["diary_contents_returned"])
        self.assertNotIn("private-user", rendered)
        self.assertNotIn("'secret'", rendered)
        self.assertNotIn("meals", rendered)
        self.assertNotIn("totals", rendered)


if __name__ == "__main__":
    unittest.main()
