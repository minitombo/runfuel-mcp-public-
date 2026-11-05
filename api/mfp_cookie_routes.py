"""Isolated, read-only MFP cookie authentication for individual RunFuel principals.

Never uses myfitnesspal_mcp.mfp_client.get_client(), whose singleton is shared
by the process. A fresh client is built from the selected principal's cookie
for each read, preventing cross-account cookie swaps.
"""
from __future__ import annotations

import asyncio
import hashlib
import html
import logging
from datetime import date
from urllib.parse import parse_qs

from starlette.requests import Request
from starlette.responses import HTMLResponse

from api import mfp_cookie_vault, oauth_auth

logger = logging.getLogger(__name__)
LINK_TTL_SECONDS = 600
LINK_PREFIX = "rf:mfp-cookie:v1:link:"
SESSION_COOKIE = "__Secure-next-auth.session-token"


def _no_store(body: str, status: int = 200) -> HTMLResponse:
    return HTMLResponse(body, status_code=status, headers={
        "Cache-Control": "no-store",
        "Pragma": "no-cache",
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    })


async def create_connect_link(principal: str) -> str:
    import secrets
    ticket = secrets.token_urlsafe(32)
    key = LINK_PREFIX + hashlib.sha256(ticket.encode("utf-8")).hexdigest()
    await oauth_auth._redis(["SET", key, principal, "EX", str(LINK_TTL_SECONDS)])
    return f"{oauth_auth.BASE_URL}/mfp/cookie/connect?ticket={ticket}"


async def connect_page(request: Request):
    ticket = request.query_params.get("ticket", "")
    if not isinstance(ticket, str) or len(ticket) < 32 or len(ticket) > 128:
        return _no_store("<h1>Invalid connection link</h1><p>Request a fresh link from your AI client.</p>", 400)
    key = LINK_PREFIX + hashlib.sha256(ticket.encode("utf-8")).hexdigest()
    try:
        principal = await oauth_auth._redis(["GET", key])
    except Exception:
        return _no_store("<h1>Temporarily unavailable</h1><p>Please try again shortly.</p>", 503)
    if not principal:
        return _no_store("<h1>Connection link expired</h1><p>Request a fresh link from your AI client.</p>", 410)
    body = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Connect MyFitnessPal to RunFuel</title></head>
<body style="font:16px system-ui;max-width:460px;margin:40px auto;padding:0 18px">
<h1>Connect MyFitnessPal</h1>
<p>Paste your own MyFitnessPal session cookie. RunFuel encrypts it for this AI connection only. Your cookie is never returned to Claude.</p>
<form method="post" action="/mfp/cookie/connect">
<input type="hidden" name="ticket" value="{html.escape(ticket, quote=True)}">
<label>Session cookie or full Cookie header<br><textarea name="cookie" required maxlength="12000" rows="5" autocomplete="off" autocapitalize="off" spellcheck="false" style="box-sizing:border-box;width:100%;padding:10px;margin:8px 0 16px"></textarea></label>
<label>MyFitnessPal username<br><input name="username" required maxlength="256" autocomplete="off" autocapitalize="off" style="box-sizing:border-box;width:100%;padding:10px;margin:8px 0 16px"></label>
<button style="padding:12px 18px">Connect MyFitnessPal</button>
</form><p style="color:#666;font-size:13px">Use only a cookie from your own account. This connection is read-only. The link expires in 10 minutes and can be used once.</p>
</body></html>"""
    return _no_store(body)


async def connect_submit(request: Request):
    try:
        if not await oauth_auth._allow_login_attempt(request):
            return _no_store("<h1>Too many attempts</h1><p>Wait 15 minutes and request a fresh link.</p>", 429)
        if "application/x-www-form-urlencoded" not in request.headers.get("content-type", "").lower():
            return _no_store("<h1>Unsupported form submission</h1>", 415)
        try:
            declared_length = int(request.headers.get("content-length", "0") or "0")
            if declared_length > 16384:
                return _no_store("<h1>Form submission too large</h1>", 413)
        except ValueError:
            return _no_store("<h1>Invalid form submission</h1>", 400)
        body = await request.body()
        if len(body) > 16384:
            return _no_store("<h1>Form submission too large</h1>", 413)
        form = {key: values[0] for key, values in parse_qs(body.decode("utf-8"), keep_blank_values=True).items()}
        ticket, raw_cookie = form.get("ticket", ""), form.get("cookie", "").strip()
        username = form.get("username", "").strip() or None
        if len(ticket) < 32 or len(ticket) > 128:
            return _no_store("<h1>Invalid connection link</h1>", 400)
        if not raw_cookie or len(raw_cookie) > mfp_cookie_vault.MAX_COOKIE_BYTES or not username or len(username) > mfp_cookie_vault.MAX_USERNAME_LENGTH:
            return _no_store("<h1>Enter your MyFitnessPal username and a valid session cookie</h1>", 400)
        from myfitnesspal_mcp import auth, mfp_client
        cookies = auth.parse_cookie_input(raw_cookie)
        if not cookies.get(SESSION_COOKIE):
            return _no_store("<h1>Session cookie not found</h1><p>Paste the __Secure-next-auth.session-token value or the full Cookie header.</p>", 400)
        mfp_cookie_vault.validate_record({"cookie": raw_cookie, "username": username})
        key = LINK_PREFIX + hashlib.sha256(ticket.encode("utf-8")).hexdigest()
        principal = await oauth_auth._redis(["GETDEL", key])
        if not principal:
            return _no_store("<h1>Connection link expired or already used</h1><p>Request a fresh link from your AI client.</p>", 410)
        # Validate with an isolated client; never touch the package's global singleton.
        client = await asyncio.to_thread(mfp_client.build_client, cookies, username=username)
        await asyncio.to_thread(client.get_date, date.today())
        await mfp_cookie_vault.save_record(str(principal), {"cookie": raw_cookie, "username": username})
        return _no_store("<h1>MyFitnessPal connected</h1><p>Your cookie is encrypted and linked only to this RunFuel AI connection. Return to Claude and call the diary tool again.</p>")
    except Exception as exc:
        logger.warning("Per-user MyFitnessPal cookie connection failed (type=%s)", type(exc).__name__)
        return _no_store("<h1>Connection failed</h1><p>MyFitnessPal did not accept that session. No cookie was saved. Request a fresh link and try again.</p>", 401)


def _number(values, *keys) -> float:
    if not isinstance(values, dict):
        return 0.0
    for key in keys:
        value = values.get(key)
        if isinstance(value, dict):
            value = value.get("value")
        try:
            if value is not None:
                return float(value)
        except (TypeError, ValueError):
            continue
    return 0.0


def _mapping(value):
    if isinstance(value, dict):
        return value
    if hasattr(value, "items"):
        try:
            return dict(value.items())
        except Exception:
            pass
    return {}


def _normalize_day(day: str, record) -> dict:
    totals_source = _mapping(getattr(record, "totals", {}))
    goals_source = _mapping(getattr(record, "goals", {}))
    fields = {
        "calories": ("calories", "energy"),
        "protein": ("protein",),
        "carbohydrates": ("carbohydrates", "carbs"),
        "fat": ("fat",),
        "fiber": ("fiber",),
        "sugar": ("sugar",),
    }
    totals = {name: _number(totals_source, *aliases) for name, aliases in fields.items()}
    goals = {name: _number(goals_source, *aliases) for name, aliases in fields.items() if any(k in goals_source for k in aliases)}
    meals = []
    for meal in getattr(record, "meals", ()) or ():
        entries = []
        for entry in getattr(meal, "entries", ()) or ():
            values = _mapping(getattr(entry, "totals", {}))
            entries.append({
                "name": str(getattr(entry, "name", None) or "Food"),
                "nutrients": {name: _number(values, *aliases) for name, aliases in fields.items()},
            })
        meals.append({"meal": str(getattr(meal, "name", None) or "Other"), "entries": entries})
    return {"day": day, "totals": totals, "goals": goals, "meals": meals}


async def cookie_nutrition(principal: str, day: str):
    record = await mfp_cookie_vault.get_record(principal)
    if record is None:
        return None
    from myfitnesspal_mcp import auth, mfp_client
    cookies = auth.parse_cookie_input(record["cookie"])
    # A new client is created for every principal and every request. The
    # process-wide mfp_client._client singleton is deliberately never used.
    client = await asyncio.to_thread(mfp_client.build_client, cookies, username=record.get("username"))
    parsed_day = date.fromisoformat(day)
    diary = await asyncio.to_thread(client.get_date, parsed_day)
    return _normalize_day(day, diary)
