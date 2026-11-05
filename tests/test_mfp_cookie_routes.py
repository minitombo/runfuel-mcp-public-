import unittest
from unittest import mock
from cryptography.fernet import Fernet

from api import mfp_cookie_routes, mfp_cookie_vault, oauth_auth, token_manager


class CookieVaultTests(unittest.IsolatedAsyncioTestCase):
    async def test_cookie_is_encrypted_and_isolated_by_principal(self):
        cipher = Fernet(Fernet.generate_key())
        records = {}
        commands = []

        async def redis(command):
            commands.append(command)
            if command[0] == "SET":
                records[command[1]] = command[2]
                return "OK"
            if command[0] == "GET":
                return records.get(command[1])
            if command[0] == "DEL":
                records.pop(command[1], None)
                return 1
            raise AssertionError(command)

        with (
            mock.patch.object(token_manager, "_fernet", return_value=cipher),
            mock.patch.object(oauth_auth, "_redis", side_effect=redis),
        ):
            await mfp_cookie_vault.save_record("principal-a", {
                "cookie": "__Secure-next-auth.session-token=private-cookie",
                "username": "runner_a",
            })
            await mfp_cookie_vault.save_record("principal-b", {
                "cookie": "__Secure-next-auth.session-token=other-cookie",
                "username": "runner_b",
            })
            first = await mfp_cookie_vault.get_record("principal-a")
            second = await mfp_cookie_vault.get_record("principal-b")

        self.assertEqual(first["username"], "runner_a")
        self.assertEqual(second["username"], "runner_b")
        self.assertNotEqual(first["cookie"], second["cookie"])
        self.assertEqual(len(records), 2)
        for encrypted in records.values():
            self.assertNotIn(b"private-cookie", encrypted.encode())
            self.assertNotIn(b"other-cookie", encrypted.encode())
        self.assertNotEqual(
            mfp_cookie_vault._key("principal-a"),
            mfp_cookie_vault._key("principal-b"),
        )

    def test_cookie_record_requires_cookie_and_explicit_username(self):
        with self.assertRaises(ValueError):
            mfp_cookie_vault.validate_record({"cookie": "token"})
        with self.assertRaises(ValueError):
            mfp_cookie_vault.validate_record({"cookie": "token", "username": " "})
        with self.assertRaises(ValueError):
            mfp_cookie_vault.validate_record({"cookie": "bad" + chr(0), "username": "runner"})
        record = mfp_cookie_vault.validate_record({
            "cookie": "  token  ",
            "username": " runner ",
        })
        self.assertEqual(record, {"cookie": "token", "username": "runner"})


class CookieConnectLinkTests(unittest.IsolatedAsyncioTestCase):
    async def test_link_is_single_use_ttl_scoped_and_ticket_is_hashed(self):
        commands = []

        async def redis(command):
            commands.append(command)
            return "OK"

        with mock.patch.object(oauth_auth, "_redis", side_effect=redis):
            url = await mfp_cookie_routes.create_connect_link("principal-cookie")

        self.assertTrue(url.startswith(oauth_auth.BASE_URL + "/mfp/cookie/connect?ticket="))
        ticket = url.split("ticket=", 1)[1]
        self.assertGreaterEqual(len(ticket), 32)
        self.assertTrue(commands[0][1].startswith(mfp_cookie_routes.LINK_PREFIX))
        self.assertNotIn(ticket, commands[0][1])
        self.assertEqual(commands[0][2], "principal-cookie")
        self.assertEqual(commands[0][-2:], ["EX", str(mfp_cookie_routes.LINK_TTL_SECONDS)])


class CookieNormalizationTests(unittest.TestCase):
    def test_upstream_day_object_maps_to_runfuel_shape(self):
        class Entry:
            name = "Oats"
            totals = {"calories": 250, "protein": 10, "carbohydrates": 40, "fat": 5}

        class Meal:
            name = "Breakfast"
            entries = [Entry()]

        class Diary:
            totals = {"calories": 250, "protein": 10, "carbohydrates": 40, "fat": 5}
            goals = {"calories": 2000, "protein": 150}
            meals = [Meal()]

        result = mfp_cookie_routes._normalize_day("2026-11-02", Diary())
        self.assertEqual(result["totals"]["calories"], 250)
        self.assertEqual(result["goals"]["calories"], 2000)
        self.assertEqual(result["meals"][0]["entries"][0]["name"], "Oats")
        self.assertEqual(result["meals"][0]["meal"], "Breakfast")


if __name__ == "__main__":
    unittest.main()
