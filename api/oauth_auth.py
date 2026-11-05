"""Minimal OAuth 2.1 authorization service for RunFuel (Claude custom connector).

Uses Upstash Redis REST for cross-instance state. Public clients use PKCE S256;
OAuth access tokens are opaque and only accepted by this RunFuel resource server.
"""
from __future__ import annotations

import hashlib
import html as html_module
import hmac
import json
import logging
import os
import secrets
import time
from urllib.parse import parse_qs, urlencode, urlsplit

import httpx
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, RedirectResponse

logger = logging.getLogger(__name__)
BASE_URL = os.environ.get("RUNFUEL_BASE_URL", "").strip().rstrip("/")
if not BASE_URL:
    # Vercel supplies a deployment-specific host for preview deployments. This
    # avoids ever falling back to the maintainer's endpoint while keeping previews testable.
    _vercel_host = os.environ.get("VERCEL_URL", "").strip().rstrip("/")
    if _vercel_host:
        BASE_URL = _vercel_host if "://" in _vercel_host else f"https://{_vercel_host}"
if not BASE_URL:
    raise RuntimeError(
        "RUNFUEL_BASE_URL is required outside Vercel; configure your own canonical HTTPS URL."
    )
CLAUDE_CALLBACKS = {"https://claude.ai/api/mcp/auth_callback"}
# Generated Android package ID: --org com.runfuel.app --project-name runfuel.
ANDROID_CALLBACK = "com.runfuel.app.runfuel://oauth2redirect"
ALLOWED_CALLBACKS = CLAUDE_CALLBACKS | {ANDROID_CALLBACK}
RESOURCE = f"{BASE_URL}/mcp"
ACCESS_TTL = 3600
REFRESH_TTL = 60 * 60 * 24 * 30
CODE_TTL = 300
LOGIN_RATE_WINDOW = 15 * 60
LOGIN_RATE_LIMIT = 10
LOGIN_RATE_SCRIPT = """
local count = redis.call('INCR', KEYS[1])
if count == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end
return count
"""


class OAuthError(Exception):
    def __init__(self, error: str, status: int = 400, description: str = ""):
        super().__init__(description or error)
        self.error, self.status, self.description = error, status, description


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


async def _redis(command: list[str]):
    url = os.environ.get("UPSTASH_REDIS_REST_URL", "").strip().rstrip("/")
    token = os.environ.get("UPSTASH_REDIS_REST_TOKEN", "")
    if not url or not token:
        raise OAuthError("server_error", 503, "OAuth storage is not configured.")
    try:
        parsed_url = urlsplit(url)
        logger.info(
            "RunFuel Redis URL shape: https=%s host_present=%s whitespace=%s "
            "surrounding_quote=%s env_assignment_prefix=%s",
            parsed_url.scheme == "https", bool(parsed_url.netloc),
            any(char.isspace() for char in url),
            url.startswith(('"', "'")) or url.endswith(('"', "'")),
            url.startswith("UPSTASH_REDIS_REST_URL="),
        )
        async with httpx.AsyncClient(timeout=8.0) as client:
            response = await client.post(url, headers={"Authorization": f"Bearer {token}"}, json=command)
            response.raise_for_status()
            result = response.json()
    except httpx.HTTPStatusError as exc:
        logger.error("RunFuel OAuth Redis returned HTTP status %s", exc.response.status_code)
        raise OAuthError("server_error", 503, "OAuth storage request failed.") from None
    except httpx.TimeoutException:
        logger.error("RunFuel OAuth Redis request timed out")
        raise OAuthError("server_error", 503, "OAuth storage request timed out.") from None
    except httpx.RequestError as exc:
        logger.error("RunFuel OAuth Redis connection failed (type=%s)", type(exc).__name__)
        raise OAuthError("server_error", 503, "OAuth storage connection failed.") from None
    except ValueError:
        logger.error("RunFuel OAuth Redis returned invalid JSON")
        raise OAuthError("server_error", 503, "OAuth storage returned an invalid response.") from None
    if not isinstance(result, dict):
        logger.error("RunFuel OAuth Redis returned an unexpected response format")
        raise OAuthError("server_error", 503, "OAuth storage returned an invalid response.")
    if result.get("error"):
        logger.error("RunFuel OAuth Redis returned an error response")
        raise OAuthError("server_error", 503, "OAuth storage request failed.")
    return result.get("result")


async def _get(key: str):
    value = await _redis(["GET", key])
    return json.loads(value) if value else None


async def _set(key: str, value, ttl: int):
    await _redis(["SET", key, json.dumps(value, separators=(",", ":")), "EX", str(ttl)])


async def _getdel(key: str):
    value = await _redis(["GETDEL", key])
    return json.loads(value) if value else None


async def _allow_login_attempt(request: Request) -> bool:
    """Apply a Redis-backed fixed-window limit across serverless instances."""
    headers = getattr(request, "headers", {})
    # Prefer the platform-provided single-IP header when available.
    client_ip = headers.get("x-real-ip", "").strip()
    if not client_ip:
        forwarded = headers.get("x-forwarded-for", "")
        client_ip = forwarded.split(",", 1)[0].strip()
    if not client_ip:
        client = getattr(request, "client", None)
        client_ip = getattr(client, "host", "") or "unknown"
    # Store only a hash of the IP, not the raw address.
    key = f"rf:login-rate:{_hash(client_ip)}"
    count = await _redis(["EVAL", LOGIN_RATE_SCRIPT, "1", key, str(LOGIN_RATE_WINDOW)])
    return int(count) <= LOGIN_RATE_LIMIT


def _json_error(error: OAuthError) -> JSONResponse:
    return JSONResponse(
        {"error": error.error, **({"error_description": error.description} if error.description else {})},
        status_code=error.status,
        headers={"Cache-Control": "no-store", "Pragma": "no-cache"},
    )


async def metadata(_: Request):
    return JSONResponse({
        "issuer": BASE_URL, "authorization_endpoint": f"{BASE_URL}/authorize",
        "token_endpoint": f"{BASE_URL}/token", "registration_endpoint": f"{BASE_URL}/register",
        "response_types_supported": ["code"], "grant_types_supported": ["authorization_code", "refresh_token"],
        "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"], "scopes_supported": ["runfuel:read"],
        "client_id_metadata_document_supported": False,
    }, headers={"Cache-Control": "public, max-age=300"})


async def protected_resource(_: Request):
    return JSONResponse({
        "resource": RESOURCE, "authorization_servers": [BASE_URL],
        "scopes_supported": ["runfuel:read"], "bearer_methods_supported": ["header"],
    }, headers={"Cache-Control": "public, max-age=300"})


async def register(request: Request):
    try:
        body = await request.json()
        redirects = body.get("redirect_uris")
        if not isinstance(redirects, list) or not redirects or any(u not in ALLOWED_CALLBACKS for u in redirects):
            raise OAuthError("invalid_client_metadata", 400, "Only the registered Claude or official RunFuel Android callback URI is allowed.")
        if body.get("token_endpoint_auth_method", "none") != "none":
            raise OAuthError("invalid_client_metadata", 400, "Only public PKCE clients are supported.")
        client_id = secrets.token_urlsafe(24)
        client = {
            "client_id": client_id, "client_name": str(body.get("client_name", "RunFuel client"))[:100],
            "redirect_uris": redirects, "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
        }
        await _set(f"rf:client:{client_id}", client, 60 * 60 * 24 * 365)
        return JSONResponse(client, status_code=201, headers={"Cache-Control": "no-store"})
    except OAuthError as e:
        return _json_error(e)
    except Exception:
        return _json_error(OAuthError("invalid_client_metadata", 400))


async def authorize(request: Request):
    try:
        q = request.query_params
        client_id, redirect_uri = q.get("client_id", ""), q.get("redirect_uri", "")
        client = await _get(f"rf:client:{client_id}")
        if not client or redirect_uri not in client["redirect_uris"]:
            raise OAuthError("invalid_request", 400, "Unknown client or redirect URI.")
        if q.get("response_type") != "code":
            raise OAuthError("unsupported_response_type", 400)
        resource = q.get("resource", "").strip()
        if resource != RESOURCE:
            raise OAuthError("invalid_target", 400, "The resource parameter must identify this RunFuel MCP server.")
        challenge, method = q.get("code_challenge", ""), q.get("code_challenge_method", "")
        if not challenge or method != "S256":
            raise OAuthError("invalid_request", 400, "PKCE S256 is required.")
        nonce = secrets.token_urlsafe(24)
        # Keep a stable, unguessable browser identity across OAuth re-authorizations.
        # Never derive a data-owner identity from the public OAuth client_id: that
        # value can be shared by multiple people using the same client application.
        browser_id = getattr(request, "cookies", {}).get("rf_browser_id", "")
        if not isinstance(browser_id, str) or not (32 <= len(browser_id) <= 128):
            browser_id = secrets.token_urlsafe(32)
        principal = "browser:" + _hash(browser_id)
        auth_request = {
            "client_id": client_id, "client_name": client.get("client_name", "RunFuel client"),
            "redirect_uri": redirect_uri, "state": q.get("state", ""),
            "code_challenge": challenge, "resource": resource,
            "scope": q.get("scope", "runfuel:read"), "created": int(time.time()),
            "principal": principal,
        }
        await _set(f"rf:authreq:{nonce}", auth_request, CODE_TTL)
        html = f"""<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>RunFuel sign in</title></head>
<body style="font:16px system-ui;max-width:420px;margin:48px auto;padding:0 18px">
<h1>Sign in to RunFuel</h1><p>Approve {html_module.escape(auth_request["client_name"])} to read your Garmin and MyFitnessPal data. This connection is read-only and cannot edit your diary or activities.</p>
<form method="post" action="/login">
<input type="hidden" name="nonce" value="{nonce}">
<label>RunFuel access password<br><input type="password" name="password" required autocomplete="current-password" style="box-sizing:border-box;width:100%;padding:12px;margin:8px 0 18px"></label>
<hr style="border:0;border-top:1px solid #ddd;margin:18px 0">
<h2 style="font-size:18px">Connect MyFitnessPal now</h2>
<p style="color:#555">Optional: enter your MyFitnessPal sign-in here to connect it during setup. Leave both fields blank to connect later.</p>
<label>MyFitnessPal email or username<br><input name="mfp_username" maxlength="256" autocomplete="username" autocapitalize="off" style="box-sizing:border-box;width:100%;padding:12px;margin:8px 0 14px"></label>
<label>MyFitnessPal password<br><input type="password" name="mfp_password" maxlength="1024" autocomplete="current-password" style="box-sizing:border-box;width:100%;padding:12px;margin:8px 0 18px"></label>
<button style="padding:12px 18px">Authorize RunFuel</button></form>
<p style="color:#666;font-size:13px">Your MyFitnessPal password is used only for sign-in and is not stored or shared with Claude. Never enter your Garmin password or paste a MyFitnessPal cookie here.</p></body></html>"""
        response = HTMLResponse(html, headers={"Cache-Control": "no-store"})
        response.set_cookie(
            "rf_browser_id", browser_id, max_age=60 * 60 * 24 * 365,
            secure=True, httponly=True, samesite="lax", path="/",
        )
        return response
    except OAuthError as e:
        return _json_error(e)
    except Exception as exc:
        logger.error("RunFuel OAuth authorize failed (type=%s)", type(exc).__name__)
        return _json_error(OAuthError("server_error", 503))


async def login(request: Request):
    try:
        if not await _allow_login_attempt(request):
            return HTMLResponse(
                "<h1>Too many sign-in attempts</h1><p>Please wait 15 minutes before trying again.</p>",
                status_code=429, headers={"Retry-After": str(LOGIN_RATE_WINDOW), "Cache-Control": "no-store"},
            )
        raw = (await request.body()).decode("utf-8")
        form = {k: v[0] for k, v in parse_qs(raw, keep_blank_values=True).items()}
        configured = os.environ.get("RUNFUEL_OAUTH_PASSWORD", "")
        if not configured or not hmac.compare_digest(form.get("password", ""), configured):
            return HTMLResponse(
                "<h1>Sign-in failed</h1><p>Check the RunFuel access password and try again.</p>",
                status_code=401, headers={"Cache-Control": "no-store"},
            )
        nonce = form.get("nonce", "")
        auth_request = await _get(f"rf:authreq:{nonce}")
        if not auth_request:
            raise OAuthError("invalid_request", 400, "Sign-in request expired. Return to the app or connected client and start again.")

        # Optional MFP sign-in is part of the same browser authorisation flow.
        # Credentials are exchanged in memory and only renewable tokens are saved.
        mfp_username = form.get("mfp_username", "").strip()
        mfp_password = form.get("mfp_password", "")
        if bool(mfp_username) != bool(mfp_password):
            return HTMLResponse(
                "<h1>MyFitnessPal sign-in incomplete</h1><p>Enter both your MyFitnessPal email/username and password, or leave both blank to connect later. Go back and try again.</p>",
                status_code=400, headers={"Cache-Control": "no-store"},
            )
        if mfp_username and mfp_password:
            if os.environ.get("MFP_AUTH_MODE", "native").strip().lower() != "native":
                return HTMLResponse(
                    "<h1>MyFitnessPal sign-in unavailable here</h1><p>This setup screen supports native MyFitnessPal sign-in. Leave both fields blank and connect using the MyFitnessPal tool instead.</p>",
                    status_code=400, headers={"Cache-Control": "no-store"},
                )
            try:
                from api import mfp_native_auth, mfp_native_vault
                mfp_record = await mfp_native_auth.login(mfp_username, mfp_password)
                await mfp_native_vault.save_token_record(auth_request["principal"], mfp_record)
            except mfp_native_auth.NativeMFPAuthError as exc:
                safe_message = html_module.escape(str(exc))
                return HTMLResponse(
                    f"<h1>MyFitnessPal sign-in failed</h1><p>{safe_message}</p><p>Your RunFuel authorisation has not been completed. Go back and check your MyFitnessPal details.</p>",
                    status_code=401, headers={"Cache-Control": "no-store"},
                )
            except Exception as exc:
                logger.warning("MFP sign-in during OAuth failed (type=%s)", type(exc).__name__)
                return HTMLResponse(
                    "<h1>MyFitnessPal sign-in unavailable</h1><p>We couldn't complete the MyFitnessPal connection. Your password was not saved. Try again or leave both fields blank to connect later.</p>",
                    status_code=502, headers={"Cache-Control": "no-store"},
                )

        # Consume the short-lived OAuth request only after optional MFP sign-in
        # succeeds, so a typo does not force the user to restart setup.
        consumed = await _getdel(f"rf:authreq:{nonce}")
        if not consumed or consumed != auth_request:
            raise OAuthError("invalid_request", 400, "This sign-in request was already used. Start again from your connected client.")
        # Reuse the browser-bound principal created during /authorize so a later
        # Claude OAuth re-authorization does not orphan this user's MFP vault.
        code = secrets.token_urlsafe(32)
        await _set(f"rf:code:{_hash(code)}", auth_request, CODE_TTL)
        params = {"code": code}
        if auth_request.get("state"):
            params["state"] = auth_request["state"]
        return RedirectResponse(auth_request["redirect_uri"] + "?" + urlencode(params), status_code=302)
    except OAuthError as e:
        return _json_error(e)
    except Exception:
        return _json_error(OAuthError("server_error", 503))


async def token(request: Request):
    try:
        raw = (await request.body()).decode("utf-8")
        form = {k: v[0] for k, v in parse_qs(raw, keep_blank_values=True).items()}
        grant, client_id = form.get("grant_type", ""), form.get("client_id", "")
        resource = form.get("resource", "").strip()
        if resource != RESOURCE:
            raise OAuthError("invalid_target", 400, "The resource parameter must identify this RunFuel MCP server.")
        client = await _get(f"rf:client:{client_id}")
        if not client:
            raise OAuthError("invalid_client", 401)
        if grant == "authorization_code":
            code = form.get("code", "")
            key = f"rf:code:{_hash(code)}"
            saved = await _get(key)
            if (not saved or saved["client_id"] != client_id
                    or saved["redirect_uri"] != form.get("redirect_uri")
                    or saved.get("resource") != resource):
                raise OAuthError("invalid_grant", 400)
            verifier = form.get("code_verifier", "")
            expected = __import__("base64").urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
            if not verifier or not hmac.compare_digest(expected, saved["code_challenge"]):
                raise OAuthError("invalid_grant", 400, "PKCE verification failed.")
            consumed = await _getdel(key)
            if not consumed or consumed != saved:
                raise OAuthError("invalid_grant", 400)
            principal = saved.get("principal") or secrets.token_urlsafe(24)
        elif grant == "refresh_token":
            refresh = form.get("refresh_token", "")
            saved = await _getdel(f"rf:refresh:{_hash(refresh)}")
            if (not saved or saved["client_id"] != client_id
                    or saved.get("resource") != resource):
                raise OAuthError("invalid_grant", 400)
            principal = saved["principal"]
        else:
            raise OAuthError("unsupported_grant_type", 400)
        access, refresh = secrets.token_urlsafe(32), secrets.token_urlsafe(40)
        await _set(f"rf:access:{_hash(access)}", {"principal": principal, "client_id": client_id, "resource": resource}, ACCESS_TTL)
        await _set(f"rf:refresh:{_hash(refresh)}", {"principal": principal, "client_id": client_id, "resource": resource}, REFRESH_TTL)
        return JSONResponse({
            "access_token": access, "token_type": "Bearer", "expires_in": ACCESS_TTL,
            "refresh_token": refresh, "scope": "runfuel:read",
        }, headers={"Cache-Control": "no-store", "Pragma": "no-cache"})
    except OAuthError as e:
        return _json_error(e)
    except Exception:
        return _json_error(OAuthError("server_error", 503))


async def get_access_principal(token: str) -> str | None:
    """Resolve a bearer token to its isolated RunFuel data principal."""
    if not token:
        return None
    saved = await _get(f"rf:access:{_hash(token)}")
    principal = saved.get("principal") if isinstance(saved, dict) else None
    if not isinstance(saved, dict) or saved.get("resource") != RESOURCE:
        return None
    return principal if isinstance(principal, str) and principal else None


async def validate_access_token(token: str) -> bool:
    return bool(await get_access_principal(token))
