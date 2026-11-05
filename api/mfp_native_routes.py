"""Authenticated mobile endpoints and read-only diary normalization for native MFP."""
from __future__ import annotations
import hashlib, html, logging, os, time
from urllib.parse import parse_qs
from datetime import date
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse
from api import mfp_native_auth, mfp_native_client, mfp_native_vault, oauth_auth

logger=logging.getLogger(__name__)

def _no_store(payload,status=200):
    return JSONResponse(payload,status_code=status,headers={"Cache-Control":"no-store","Pragma":"no-cache"})

async def _principal(request):
    header = request.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token:
        return None
    try:
        return await oauth_auth.get_access_principal(token)
    except Exception:
        return None

async def connect(request: Request):
    principal = await _principal(request)
    if not principal: return _no_store({"error":"Unauthorized"},401)
    if not os.environ.get("MFP_NATIVE_CLIENT_ID") or not os.environ.get("MFP_NATIVE_CLIENT_SECRET"):
        return _no_store({"error":"Native MyFitnessPal sign-in is not configured on this backend."},503)
    try:
        if not await oauth_auth._allow_login_attempt(request): return _no_store({"error":"Too many sign-in attempts. Try again later."},429)
        body=await request.json()
        if not isinstance(body,dict): return _no_store({"error":"Invalid request."},400)
        username=body.get("username")
        password=body.get("password")
        record=await mfp_native_auth.login(username,password)
        await mfp_native_vault.save_token_record(principal, record)
        return _no_store({"connected":True,"method":"native","expires_at":record["expires_at"]})
    except mfp_native_auth.NativeMFPAuthError as exc:
        message=str(exc)
        status=503 if "not configured" in message else 401
        return _no_store({"error":message},status)
    except Exception as exc:
        logger.warning("Native MyFitnessPal connection failed (type=%s)",type(exc).__name__)
        return _no_store({"error":"MyFitnessPal sign-in failed. No credentials were saved."},502)

async def status(request: Request):
    principal = await _principal(request)
    if not principal: return _no_store({"error":"Unauthorized"},401)
    try:
        record=await mfp_native_vault.get_token_record(principal)
        return _no_store({"connected":bool(record),"method":"native" if record else None,"expires_at":record["expires_at"] if record else None})
    except Exception as exc:
        logger.warning("Native MyFitnessPal status unavailable (type=%s)",type(exc).__name__)
        return _no_store({"error":"Connection status is temporarily unavailable."},503)

async def disconnect(request: Request):
    principal = await _principal(request)
    if not principal: return _no_store({"error":"Unauthorized"},401)
    try:
        await mfp_native_vault.delete_token_record(principal)
        return _no_store({"connected":False})
    except Exception as exc:
        logger.warning("Native MyFitnessPal disconnect failed (type=%s)",type(exc).__name__)
        return _no_store({"error":"Could not disconnect MyFitnessPal right now."},503)

def _value(value):
    if isinstance(value,dict): value=value.get("value")
    try: return float(value) if value is not None else 0.0
    except (TypeError,ValueError): return 0.0

def _normalize_nutrition(day, diary, goals_record):
    totals={"calories":0.0,"protein":0.0,"carbohydrates":0.0,"fat":0.0,"fiber":0.0,"sugar":0.0}
    meals={}
    for item in diary.get("items",[]):
        if not isinstance(item,dict): continue
        food=item.get("food") if isinstance(item.get("food"),dict) else {}
        nutrients=item.get("nutritional_contents") or food.get("nutritional_contents") or {}
        if not isinstance(nutrients,dict): nutrients={}
        values={
            "calories":_value(nutrients.get("energy",nutrients.get("calories"))),
            "protein":_value(nutrients.get("protein")),
            "carbohydrates":_value(nutrients.get("carbohydrates")),
            "fat":_value(nutrients.get("fat")),
            "fiber":_value(nutrients.get("fiber")),
            "sugar":_value(nutrients.get("sugar")),
        }
        for key,value in values.items(): totals[key]+=value
        meal=str(item.get("meal_name") or "Other")
        entry={"name":str(food.get("description") or food.get("name") or "Food"),"nutrients":values}
        meals.setdefault(meal,[]).append(entry)
    goal_source=goals_record.get("default_goal") if isinstance(goals_record,dict) else {}
    if not isinstance(goal_source,dict): goal_source={}
    goals={}
    for key,source in (("calories","energy"),("protein","protein"),("carbohydrates","carbohydrates"),("fat","fat"),("fiber","fiber"),("sugar","sugar")):
        if source in goal_source: goals[key]=_value(goal_source[source])
    return {"day":day,"totals":totals,"goals":goals,"meals":[{"meal":name,"entries":entries} for name,entries in meals.items()]}

async def _refresh_user_record(principal: str, previous: dict, *, force: bool = False):
    """Refresh under a per-user lock and report only safe persistence metadata."""
    async with mfp_native_vault.refresh_lock(principal):
        latest = await mfp_native_vault.get_token_record(principal)
        if latest is None:
            return None, {
                "refreshed": False, "credentials_saved": False,
                "refresh_token_rotated": None, "refreshed_at": None,
            }
        if latest["access_token"] == previous["access_token"] and (
            force or latest["expires_at"] <= time.time() + 60
        ):
            previous_refresh_token = latest["refresh_token"]
            renewed = await mfp_native_auth.refresh(latest)
            await mfp_native_vault.save_token_record(principal, renewed)
            return renewed, {
                "refreshed": True,
                "credentials_saved": True,
                "refresh_token_rotated": renewed["refresh_token"] != previous_refresh_token,
                "refreshed_at": int(time.time()),
            }
        return latest, {
            "refreshed": False, "credentials_saved": None,
            "refresh_token_rotated": None, "refreshed_at": None,
        }


async def native_nutrition(principal: str, day: str):
    record = await mfp_native_vault.get_token_record(principal)
    if record is None:
        return None
    refresh_diagnostic = {
        "attempted": False, "refreshed": False, "reason": "not_needed",
        "credentials_saved": None, "refresh_token_rotated": None,
        "refreshed_at": None, "expires_in_seconds": max(
            0, int(record["expires_at"] - time.time())
        ),
    }
    if record["expires_at"] <= time.time() + 60:
        refresh_reason = "expired" if record["expires_at"] <= time.time() else "near_expiry"
        refresh_diagnostic.update(attempted=True, reason=refresh_reason)
        record, outcome = await _refresh_user_record(principal, record)
        refresh_diagnostic.update(outcome)
        if record is None:
            return None
    try:
        diary = await mfp_native_client.fetch_diary(
            record["access_token"], record["domain_user_id"], day
        )
    except mfp_native_client.NativeMFPDiaryError as exc:
        if exc.status_code != 401:
            raise
        refresh_diagnostic.update(attempted=True, reason="upstream_401")
        previous_record = record
        record, outcome = await _refresh_user_record(principal, previous_record, force=True)
        if refresh_diagnostic["refreshed"] and outcome["refreshed"]:
            # A second refresh in one read is unusual; preserve the latest
            # successful outcome without exposing either token.
            refresh_diagnostic.update(outcome)
        else:
            refresh_diagnostic.update(outcome)
        if record is None:
            return None
        diary = await mfp_native_client.fetch_diary(
            record["access_token"], record["domain_user_id"], day
        )
    goals = await mfp_native_client.fetch_goals(
        record["access_token"], record["domain_user_id"]
    )
    refresh_diagnostic["expires_in_seconds"] = max(
        0, int(record["expires_at"] - time.time())
    )
    result = _normalize_nutrition(day, diary, goals)
    result["auth_refresh"] = refresh_diagnostic
    return result


LINK_TTL_SECONDS = 600
LINK_PREFIX = "rf:mfp-native:v2:link:"


async def create_connect_link(principal: str) -> str:
    """Create a short-lived, single-use link for the current MCP principal."""
    import secrets
    ticket = secrets.token_urlsafe(32)
    key = LINK_PREFIX + hashlib.sha256(ticket.encode("utf-8")).hexdigest()
    await oauth_auth._redis(["SET", key, principal, "EX", str(LINK_TTL_SECONDS)])
    return f"{oauth_auth.BASE_URL}/mfp/connect?ticket={ticket}"


def _page_response(body: str, status: int = 200):
    return HTMLResponse(
        body,
        status_code=status,
        headers={
            "Cache-Control": "no-store",
            "Pragma": "no-cache",
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "default-src 'none'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
        },
    )


async def connect_page(request: Request):
    ticket = request.query_params.get("ticket", "")
    if not isinstance(ticket, str) or len(ticket) < 32 or len(ticket) > 128:
        return _page_response("<h1>Invalid connection link</h1><p>Return to your AI client and request a new MyFitnessPal connection link.</p>", 400)
    key = LINK_PREFIX + hashlib.sha256(ticket.encode("utf-8")).hexdigest()
    try:
        principal = await oauth_auth._redis(["GET", key])
    except Exception:
        return _page_response("<h1>Temporarily unavailable</h1><p>Please request a new link shortly.</p>", 503)
    if not principal:
        return _page_response("<h1>Connection link expired</h1><p>Return to your AI client and request a new MyFitnessPal connection link.</p>", 410)
    body = f"""<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Connect MyFitnessPal to RunFuel</title></head>
<body style="font:16px system-ui;max-width:420px;margin:48px auto;padding:0 18px">
<h1>Connect MyFitnessPal</h1>
<p>Sign in to your own MyFitnessPal account. Your credentials are used only for the sign-in exchange and are not stored.</p>
<form method="post" action="/mfp/connect">
<input type="hidden" name="ticket" value="{html.escape(ticket, quote=True)}">
<label>MyFitnessPal email or username<br><input name="username" required maxlength="256" autocomplete="username" autocapitalize="off" style="box-sizing:border-box;width:100%;padding:12px;margin:8px 0 18px"></label>
<label>MyFitnessPal password<br><input type="password" name="password" required maxlength="1024" autocomplete="current-password" style="box-sizing:border-box;width:100%;padding:12px;margin:8px 0 18px"></label>
<button style="padding:12px 18px">Connect MyFitnessPal</button></form>
<p style="color:#666;font-size:13px">RunFuel stores only encrypted renewable tokens. Your AI client never receives your MyFitnessPal password or tokens. Access is read-only.</p>
</body></html>"""
    return _page_response(body)


async def connect_submit(request: Request):
    try:
        if not await oauth_auth._allow_login_attempt(request):
            return _page_response("<h1>Too many attempts</h1><p>Please wait 15 minutes and request a fresh connection link.</p>", 429)
        if "application/x-www-form-urlencoded" not in request.headers.get("content-type", "").lower():
            return _page_response("<h1>Unsupported form submission</h1>", 415)
        if not os.environ.get("MFP_NATIVE_CLIENT_ID") or not os.environ.get("MFP_NATIVE_CLIENT_SECRET"):
            return _page_response("<h1>MyFitnessPal sign-in is not configured</h1>", 503)
        try:
            if int(request.headers.get("content-length", "0") or "0") > 8192:
                return _page_response("<h1>Form submission too large</h1>", 413)
        except ValueError:
            return _page_response("<h1>Invalid form submission</h1>", 400)
        body = await request.body()
        if len(body) > 8192:
            return _page_response("<h1>Form submission too large</h1>", 413)
        raw = body.decode("utf-8")
        form = {key: values[0] for key, values in parse_qs(raw, keep_blank_values=True).items()}
        ticket = form.get("ticket", "")
        username, password = form.get("username", ""), form.get("password", "")
        if len(ticket) < 32 or len(ticket) > 128:
            return _page_response("<h1>Invalid connection link</h1>", 400)
        key = LINK_PREFIX + hashlib.sha256(ticket.encode("utf-8")).hexdigest()
        principal = await oauth_auth._redis(["GETDEL", key])
        if not principal:
            return _page_response("<h1>Connection link expired or already used</h1><p>Request a fresh link from your AI client.</p>", 410)
        record = await mfp_native_auth.login(username, password)
        await mfp_native_vault.save_token_record(str(principal), record)
        return _page_response("<h1>MyFitnessPal connected</h1><p>Your account is securely linked to this RunFuel AI connection. You can return to Claude or your AI client.</p>")
    except mfp_native_auth.NativeMFPAuthError as exc:
        return _page_response(f"<h1>MyFitnessPal sign-in failed</h1><p>{html.escape(str(exc))}</p><p>Request a fresh connection link from your AI client to try again.</p>", 401)
    except Exception as exc:
        logger.warning("Native MyFitnessPal web connection failed (type=%s)", type(exc).__name__)
        return _page_response("<h1>Connection unavailable</h1><p>No credentials were saved. Request a fresh link and try again.</p>", 503)
