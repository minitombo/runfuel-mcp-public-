import os, unittest
from unittest import mock
from cryptography.fernet import Fernet
from api import mfp_native_vault, oauth_auth

class NativeVaultTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.old={k:os.environ.get(k) for k in ("RUNFUEL_SECRET_ENCRYPTION_KEY","RUNFUEL_OAUTH_PASSWORD","UPSTASH_REDIS_REST_TOKEN")}
        os.environ["RUNFUEL_SECRET_ENCRYPTION_KEY"]=Fernet.generate_key().decode()
        os.environ["RUNFUEL_OAUTH_PASSWORD"]="test-password"
        os.environ["UPSTASH_REDIS_REST_TOKEN"]="test-redis"
        self.store={}
        async def redis(cmd):
            op=cmd[0].upper()
            if op=="SET":
                key,val=cmd[1],cmd[2]
                if "NX" in [str(x).upper() for x in cmd[3:]]:
                    if key in self.store:return None
                    self.store[key]=val;return "OK"
                self.store[key]=val;return "OK"
            if op=="GET":return self.store.get(cmd[1])
            if op=="DEL":return 1 if self.store.pop(cmd[1],None) is not None else 0
            if op=="EVAL":
                key,owner=cmd[3],cmd[4]
                if self.store.get(key)==owner:del self.store[key];return 1
                return 0
            raise AssertionError(op)
        self.patch=mock.patch.object(oauth_auth,"_redis",side_effect=redis);self.patch.start()
    async def asyncTearDown(self):
        self.patch.stop()
        for k,v in self.old.items():
            if v is None:os.environ.pop(k,None)
            else:os.environ[k]=v
    async def test_encrypted_pair_round_trip_and_delete(self):
        record={"access_token":"access-private","refresh_token":"refresh-private","expires_at":1900000000,"domain_user_id":"mfp-user"}
        await mfp_native_vault.save_token_record('user-a', record)
        ciphertext=self.store[mfp_native_vault._token_key('user-a')]
        self.assertNotIn("access-private",ciphertext);self.assertNotIn("refresh-private",ciphertext)
        self.assertEqual((await mfp_native_vault.get_token_record('user-a'))["refresh_token"],"refresh-private")
        await mfp_native_vault.delete_token_record('user-a')
        self.assertIsNone(await mfp_native_vault.get_token_record("user-a"))

    async def test_users_have_isolated_encrypted_records(self):
        first = {"access_token":"access-a","refresh_token":"refresh-a","expires_at":1900000000,"domain_user_id":"mfp-a"}
        second = {"access_token":"access-b","refresh_token":"refresh-b","expires_at":1900000000,"domain_user_id":"mfp-b"}
        await mfp_native_vault.save_token_record("user-a", first)
        await mfp_native_vault.save_token_record("user-b", second)
        self.assertEqual((await mfp_native_vault.get_token_record("user-a"))["domain_user_id"], "mfp-a")
        self.assertEqual((await mfp_native_vault.get_token_record("user-b"))["domain_user_id"], "mfp-b")
        await mfp_native_vault.delete_token_record("user-a")
        self.assertIsNone(await mfp_native_vault.get_token_record("user-a"))
        self.assertEqual((await mfp_native_vault.get_token_record("user-b"))["domain_user_id"], "mfp-b")

    async def test_corrupt_ciphertext_fails_closed(self):
        self.store[mfp_native_vault._token_key("user-a")]="not-encrypted"
        with self.assertRaises(RuntimeError):await mfp_native_vault.get_token_record("user-a")
    async def test_refresh_lock_releases_lease(self):
        async with mfp_native_vault.refresh_lock('user-a'):self.assertIn(mfp_native_vault._lock_key('user-a'),self.store)
        self.assertNotIn(mfp_native_vault._lock_key("user-a"),self.store)
