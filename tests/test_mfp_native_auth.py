import os, unittest
from unittest.mock import AsyncMock, patch
import httpx
from api import mfp_native_auth

class NativeAuthTests(unittest.IsolatedAsyncioTestCase):
    async def test_login_uses_signed_credentials_and_resolves_mfp_account(self):
        seen=[]
        async def handler(request):
            seen.append(request)
            path=request.url.path
            if path=="/oauth/token" and request.content.decode().find("client_credentials")>=0:
                return httpx.Response(200,json={"access_token":"client-token","expires_in":3600})
            if path=="/clientKeys":
                return httpx.Response(200,json={"_embedded":{"clientKeys":[{"clientId":"client-id","key":{"use":"sig","alg":"HS512","kid":"key-1","k":"c2VjcmV0LWtleQ"}}]}})
            if path=="/oauth/authorize":
                return httpx.Response(302,headers={"location":"mfp://identity/callback?code=one-time"})
            if path=="/oauth/token":
                return httpx.Response(200,json={"access_token":"user-access","refresh_token":"user-refresh","id_token":"eyJhbGciOiJub25lIn0.eyJzdWIiOiJpZGVudGl0eS11c2VyIn0.","expires_in":3600})
            if path=="/users/identity-user":
                return httpx.Response(200,json={"accountLinks":[{"domain":"MFP","domainUserId":"mfp-domain-user"}]})
            return httpx.Response(404)
        transport=httpx.MockTransport(handler)
        original=httpx.AsyncClient
        def factory(*args,**kwargs):
            kwargs["transport"]=transport
            return original(*args,**kwargs)
        with patch.dict(os.environ,{"MFP_NATIVE_CLIENT_ID":"client-id","MFP_NATIVE_CLIENT_SECRET":"client-secret"}),patch.object(mfp_native_auth.httpx,"AsyncClient",side_effect=factory):
            record=await mfp_native_auth.login("test@example.com","not-stored")
        self.assertEqual(record["domain_user_id"],"mfp-domain-user")
        self.assertEqual(record["refresh_token"],"user-refresh")
        self.assertTrue(any(r.url.path=="/oauth/authorize" for r in seen))
        self.assertNotIn("not-stored",str(record))

    async def test_missing_client_configuration_fails_closed(self):
        with patch.dict(os.environ,{},clear=True):
            with self.assertRaises(mfp_native_auth.NativeMFPAuthError):
                await mfp_native_auth.login("user","password")

if __name__=="__main__": unittest.main()
