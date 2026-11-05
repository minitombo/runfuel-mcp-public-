"""Experimental read-only MyFitnessPal native identity login and refresh.

Uses the reverse-engineered mobile identity flow. It is not an officially
supported public API. Credentials are used only in-memory for the login
exchange and are never logged or persisted.
"""
from __future__ import annotations
import base64, os, secrets, time
from urllib.parse import parse_qs, urlparse
import httpx, jwt
from jwt.utils import base64url_decode

IDENTITY_URL = "https://identity-api.myfitnesspal.com"
REDIRECT_URI = "mfp://identity/callback"
class NativeMFPAuthError(RuntimeError): pass

def _config():
    client_id=os.environ.get("MFP_NATIVE_CLIENT_ID","").strip()
    client_secret=os.environ.get("MFP_NATIVE_CLIENT_SECRET","").strip()
    if not client_id or not client_secret:
        raise NativeMFPAuthError("Native MyFitnessPal sign-in is not configured on this backend.")
    return client_id,client_secret

def _safe_json(response):
    try: data=response.json()
    except ValueError: raise NativeMFPAuthError("MyFitnessPal returned an unreadable sign-in response.") from None
    if not isinstance(data,dict): raise NativeMFPAuthError("MyFitnessPal returned an unexpected sign-in response.")
    return data

async def _client_token(client, client_id, client_secret):
    response=await client.post("/oauth/token",data={"grant_type":"client_credentials","client_id":client_id,"client_secret":client_secret})
    if response.status_code!=200: raise NativeMFPAuthError("MyFitnessPal app authentication failed.")
    data=_safe_json(response)
    token=data.get("access_token")
    if not isinstance(token,str) or not token: raise NativeMFPAuthError("MyFitnessPal app authentication returned no token.")
    return token

def _signing_key(data, client_id):
    entries=(data.get("_embedded") or {}).get("clientKeys") or []
    for entry in entries:
        key=entry.get("key") or {}
        if entry.get("clientId")==client_id and str(key.get("use","")).lower()=="sig":
            alg=key.get("alg")
            if alg not in ("HS256","HS384","HS512"): break
            secret=key.get("k")
            kid=key.get("kid")
            if not isinstance(secret,str) or not secret: break
            return alg,base64url_decode(secret.encode("ascii")),kid
    raise NativeMFPAuthError("MyFitnessPal did not provide a compatible sign-in key.")

def _claims(token):
    try:
        # The subject is used only to ask the authenticated identity service for
        # the matching MFP account link; all access remains bearer-token gated.
        return jwt.decode(token,options={"verify_signature":False,"verify_aud":False})
    except Exception:
        raise NativeMFPAuthError("MyFitnessPal returned an invalid identity token.") from None

async def _domain_user_id(client, access_token, id_token):
    claims=_claims(id_token or access_token)
    subject=claims.get("sub") or claims.get("user_id") or claims.get("userId")
    if not isinstance(subject,str) or not subject or len(subject)>256 or "/" in subject:
        raise NativeMFPAuthError("MyFitnessPal identity did not include an account identifier.")
    response=await client.get(f"/users/{subject}",params={"fetch_profile":"true","fetch_emails":"true"},headers={"Authorization":f"Bearer {access_token}"})
    if response.status_code!=200: raise NativeMFPAuthError("Could not verify the MyFitnessPal account link.")
    data=_safe_json(response)
    for link in data.get("accountLinks") or []:
        if isinstance(link,dict) and link.get("domain")=="MFP":
            value=link.get("domainUserId")
            if isinstance(value,str) and value and len(value)<=256: return value
    raise NativeMFPAuthError("No MyFitnessPal diary account was linked to this sign-in.")

async def login(username: str, password: str) -> dict:
    client_id,client_secret=_config()
    if not isinstance(username,str) or not username.strip() or len(username)>256: raise NativeMFPAuthError("Enter your MyFitnessPal email or username.")
    if not isinstance(password,str) or not password or len(password)>1024: raise NativeMFPAuthError("Enter your MyFitnessPal password.")
    timeout=httpx.Timeout(20.0,connect=10.0)
    async with httpx.AsyncClient(base_url=IDENTITY_URL,timeout=timeout,follow_redirects=False) as client:
        client_token=await _client_token(client,client_id,client_secret)
        keys=await client.get("/clientKeys",auth=(client_id,client_secret))
        if keys.status_code!=200: raise NativeMFPAuthError("Could not obtain MyFitnessPal sign-in key.")
        alg,secret,kid=_signing_key(_safe_json(keys),client_id)
        headers={"kid":kid} if kid else {}
        credentials=jwt.encode({"username":username.strip(),"password":password},secret,algorithm=alg,headers=headers)
        response=await client.post("/oauth/authorize",data={"client_id":client_id,"credentials":credentials,"nonce":secrets.randbelow(2**31),"redirect_uri":REDIRECT_URI,"response_type":"code","scope":"openid"})
        location=response.headers.get("location","")
        params=parse_qs(urlparse(location).query)
        code=(params.get("code") or [None])[0]
        if response.status_code not in (302,303) or not code:
            raise NativeMFPAuthError("MyFitnessPal did not accept the sign-in. Check the details and try again.")
        exchange=await client.post("/oauth/token",data={"grant_type":"authorization_code","code":code,"redirect_uri":REDIRECT_URI,"auto_create_account_link":"true"},headers={"Authorization":f"Bearer {client_token}"})
        if exchange.status_code!=200: raise NativeMFPAuthError("MyFitnessPal could not complete the sign-in.")
        tokens=_safe_json(exchange)
        access,refresh=tokens.get("access_token"),tokens.get("refresh_token")
        if not isinstance(access,str) or not access or not isinstance(refresh,str) or not refresh:
            raise NativeMFPAuthError("MyFitnessPal did not issue a renewable session.")
        user_id=await _domain_user_id(client,access,tokens.get("id_token"))
        return {"access_token":access,"refresh_token":refresh,"expires_at":time.time()+float(tokens.get("expires_in",3600)),"domain_user_id":user_id}

async def refresh(record: dict) -> dict:
    client_id,client_secret=_config()
    refresh_token=record.get("refresh_token")
    if not isinstance(refresh_token,str) or not refresh_token: raise NativeMFPAuthError("MyFitnessPal session cannot be renewed. Sign in again.")
    async with httpx.AsyncClient(base_url=IDENTITY_URL,timeout=httpx.Timeout(20.0,connect=10.0),follow_redirects=False) as client:
        client_token=await _client_token(client,client_id,client_secret)
        response=await client.post("/oauth/token",data={"grant_type":"refresh_token","refresh_token":refresh_token},headers={"Authorization":f"Bearer {client_token}"})
        if response.status_code!=200: raise NativeMFPAuthError("MyFitnessPal session expired. Sign in again.")
        data=_safe_json(response)
        access=data.get("access_token")
        new_refresh=data.get("refresh_token") or refresh_token
        if not isinstance(access,str) or not access or not isinstance(new_refresh,str) or not new_refresh:
            raise NativeMFPAuthError("MyFitnessPal did not renew the session.")
        return {"access_token":access,"refresh_token":new_refresh,"expires_at":time.time()+float(data.get("expires_in",3600)),"domain_user_id":record["domain_user_id"]}
