"""RunFuel MCP: authenticated, read-only Garmin + MyFitnessPal MCP gateway.

This reuses the published upstream tools and deliberately registers only
read-only MyFitnessPal operations. It is configured for stateless HTTP because
Vercel functions may not retain process/session state between requests.
"""
from __future__ import annotations

import asyncio
import functools
import hmac
import inspect
import importlib
import logging
import os
import re
from pathlib import Path
from urllib.parse import parse_qs, urlparse

# Vercel's function filesystem is read-only outside /tmp. The upstream Garmin
# and MyFitnessPal clients use platformdirs for token/config/cache files, so
# redirect their writable locations before importing either package.
os.environ["HOME"] = "/tmp"
os.environ["XDG_CONFIG_HOME"] = "/tmp/.config"
os.environ["XDG_DATA_HOME"] = "/tmp/.local/share"
os.environ["XDG_CACHE_HOME"] = "/tmp/.cache"
os.environ.setdefault("MFP_MCP_DATA_DIR", "/tmp/runfuel-mfp")
Path("/tmp/.config").mkdir(parents=True, exist_ok=True)
Path("/tmp/.local/share").mkdir(parents=True, exist_ok=True)
Path("/tmp/.cache").mkdir(parents=True, exist_ok=True)
Path(os.environ["MFP_MCP_DATA_DIR"]).mkdir(parents=True, exist_ok=True)
from contextlib import asynccontextmanager

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from api import oauth_auth, token_manager, mfp_native_routes, mfp_cookie_routes, mfp_cookie_vault, request_identity
from api.nutrition_metrics import fitness_get_nutrition_details
from api.mfp_compat import mfp_bulk_export_bounded, mfp_get_goals, mfp_get_measurements
from api.mfp_diagnostics import fitness_check_connection
from api.garmin_metrics import garmin_get_running_summary
from api.garmin_track import READ_ONLY as TRACK_READ_ONLY, garmin_get_activity_track
from mcp.types import ToolAnnotations
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route
from starlette.types import ASGIApp, Receive, Scope, Send

logger = logging.getLogger(__name__)

from garmin_personal_mcp import server as garmin_server
from myfitnesspal_mcp import server as mfp_server, mfp_client

GARMIN_READ_TOOLS = (
    "garmin_get_day", "garmin_get_daily_summary", "garmin_get_daily_summaries",
    "garmin_get_steps", "garmin_get_stress", "garmin_get_hydration",
    "garmin_get_body_battery", "garmin_get_heart_rate", "garmin_get_spo2",
    "garmin_get_wellness_activities", "garmin_get_sleep", "garmin_get_sleep_summaries",
    "garmin_get_hrv", "garmin_get_hrv_summaries", "garmin_get_weight",
    "garmin_get_weight_goals", "garmin_get_food_log", "garmin_search_activities",
    "garmin_get_activity", "garmin_get_activity_workouts",
    "garmin_get_heart_rate_zones", "garmin_get_fitness_age",
    "garmin_get_menstrual_cycle", "garmin_get_menstrual_day",
)
# MFP tools backed by the old shared-cookie client are intentionally disabled.
# Native MFP tools below resolve a per-RunFuel-principal encrypted token record.
MFP_READ_TOOLS = ()
BLOCKED_MFP_TOOLS = (
    "fitness_draft_food", "fitness_log_food", "fitness_delete_food",
    "fitness_modify_food", "fitness_log_weight", "fitness_log_water",
    "fitness_delete_exercise", "fitness_log_note", "fitness_log_feel",
    "fitness_clear_food_pin",
)
READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=True)

# Apply the same recursive privacy boundary to every exposed Garmin response.
# The name is retained for compatibility with existing regression tests.
PRIVACY_FILTERED_GARMIN_TOOLS = frozenset(GARMIN_READ_TOOLS)

_PRIVATE_EXACT_KEYS = frozenset({
    "owner", "ownerinfo", "ownerprofile", "ownerfullname",
    "ownerdisplayname", "ownerid", "owneravatar", "owneravatarurl",
    "ownerimage", "ownerimageurl", "ownerprofileimage",
    "ownerprofileimageurl", "ownerprofilepicture", "ownerprofilepictureurl",
    "ownerprofilephoto", "ownerprofilephotourl", "profile", "profileimage",
    "profileimageurl", "profilepicture", "profilepictureurl",
    "profilephoto", "profilephotourl", "avatar", "avatarurl",
    "userprofile", "userprofileid", "userinfodto", "displayname", "fullname",
    "userdailysummaryid", "userid", "accountid", "deviceid", "username",
    "email", "emailaddress", "firstname", "lastname", "profileid",
    "useravatar", "useravatarurl", "userimage", "userimageurl",
    "userphoto", "userphotourl", "profileurl",
})


def _is_private_activity_metadata_key(key: object) -> bool:
    """Recognize owner identifiers and profile/avatar image fields by key."""
    normalized = re.sub(r"[^a-z0-9]", "", str(key).casefold())
    if normalized in _PRIVATE_EXACT_KEYS:
        return True
    # Garmin detail payloads use these variants instead of owner* fields.
    # IDs tied to an account/profile/device are not required for coaching.
    # Preserve activityId, foodId, and other domain-specific record identifiers.
    if (normalized.startswith("user") and normalized.endswith("id")) or (
        normalized.startswith("account") and normalized.endswith("id")
    ):
        return True
    if normalized.startswith("device") and normalized.endswith("id"):
        return True
    if normalized.startswith("userprofile") or normalized in {"displayname", "fullname"}:
        return True
    if "owner" in normalized and any(
        part in normalized for part in ("name", "id", "avatar", "image", "photo", "picture", "profile")
    ):
        return True
    if "profile" in normalized and any(
        part in normalized for part in ("image", "avatar", "photo", "picture", "url")
    ):
        return True
    return False


_GPS_DETAIL_KEYS = frozenset({
    "lat", "lon", "latitude", "longitude", "positionlat", "positionlong",
    "startlat", "startlon", "startlatitude", "startlongitude",
    "endlat", "endlon", "endlatitude", "endlongitude",
    "coordinates", "coordinate", "polyline", "trackpoints", "gpspoints",
    "routepoints", "trackcoordinates", "routecoordinates", "activitytrack",
    "gpx", "fitfile",
})


def _is_gps_detail_key(key: object) -> bool:
    """Recognize coordinate arrays and route geometry in ordinary data responses."""
    normalized = re.sub(r"[^a-z0-9]", "", str(key).casefold())
    return normalized in _GPS_DETAIL_KEYS


def _sanitize_activity_payload(value, *, strip_gps: bool = False):
    """Remove identity metadata and, unless explicitly requested, detailed GPS fields."""
    if isinstance(value, dict):
        return {
            key: _sanitize_activity_payload(item, strip_gps=strip_gps)
            for key, item in value.items()
            if not _is_private_activity_metadata_key(key)
            and not (strip_gps and _is_gps_detail_key(key))
        }
    if isinstance(value, list):
        return [_sanitize_activity_payload(item, strip_gps=strip_gps) for item in value]
    if isinstance(value, tuple):
        return tuple(_sanitize_activity_payload(item, strip_gps=strip_gps) for item in value)
    return value


async def renew_managed_mfp_session() -> bool:
    """Initialize the MFP client and refresh its session before each read.

    The pinned upstream package does not perform this session check itself.
    Initialize on cold workers, then call the harmless NextAuth session
    endpoint for both new and warm clients. The synchronous HTTP operations
    run off the event loop.
    """
    try:
        client = await asyncio.to_thread(mfp_client.get_client)
    except Exception as exc:
        logger.warning("Couldn't initialize MyFitnessPal client (%s)", type(exc).__name__)
        return False
    try:
        renewed = bool(await asyncio.to_thread(_renew_mfp_client_session, client))
        client.session_renewed = renewed
        return renewed
    except Exception as exc:
        logger.warning("Couldn't renew MyFitnessPal session (%s)", type(exc).__name__)
        client.session_renewed = False
        return False

def _privacy_filtered_tool(fn, *, strip_gps: bool = False, persist_mfp: bool = False):
    """Wrap a tool without changing its signature; optionally omit GPS and persist rotated MFP cookies."""
    @functools.wraps(fn)
    async def wrapper(*args, **kwargs):
        if persist_mfp:
            await renew_managed_mfp_session()
        try:
            result = fn(*args, **kwargs)
            if inspect.isawaitable(result):
                result = await result
            return _sanitize_activity_payload(result, strip_gps=strip_gps)
        finally:
            if persist_mfp:
                await persist_managed_mfp_session()
    return wrapper

# Derive the allowed host from the canonical deployment URL. This supports
# self-hosters while retaining FastMCP's DNS-rebinding protection.
_BASE_HOST = urlparse(oauth_auth.BASE_URL).hostname
if not _BASE_HOST:
    raise RuntimeError("RUNFUEL_BASE_URL must contain a valid hostname")
mcp = FastMCP(
    "runfuel",
    stateless_http=True,
    transport_security=TransportSecuritySettings(
        allowed_hosts=[_BASE_HOST, f"{_BASE_HOST}:*"],
    ),
)


def register_upstream_tools() -> None:
    """Register the explicitly allowlisted functions with read-only annotations."""
    for name in GARMIN_READ_TOOLS:
        fn = getattr(garmin_server, name, None)
        if fn is None:
            raise RuntimeError(f"Expected Garmin upstream tool is missing: {name}")
        # Ordinary Garmin reads return coaching metrics only. Detailed GPS
        # coordinates are reserved for the separately invoked track tool.
        fn = _privacy_filtered_tool(fn, strip_gps=True)
        mcp.add_tool(fn, name=name, annotations=READ_ONLY)
    for name in MFP_READ_TOOLS:
        fn = (
            mfp_bulk_export_bounded
            if name == "fitness_bulk_export"
            else getattr(mfp_server, name, None)
        )
        if fn is None:
            raise RuntimeError(f"Expected MyFitnessPal upstream tool is missing: {name}")
        fn = _privacy_filtered_tool(fn, persist_mfp=True)
        mcp.add_tool(fn, name=name, annotations=READ_ONLY)


register_upstream_tools()
mcp.add_tool(
    _privacy_filtered_tool(garmin_get_running_summary),
    name="garmin_get_running_summary",
    annotations=READ_ONLY,
)
mcp.add_tool(
    _privacy_filtered_tool(garmin_get_activity_track),
    name="garmin_get_activity_track",
    annotations=TRACK_READ_ONLY,
)

def _mfp_auth_mode() -> str:
    """Select one backend-wide auth mode; native remains the safe default."""
    mode = os.environ.get("MFP_AUTH_MODE", "native").strip().lower()
    if mode not in {"native", "cookie"}:
        raise RuntimeError("MFP_AUTH_MODE must be either 'native' or 'cookie'.")
    return mode


async def _mfp_create_connect_link(principal: str) -> tuple[str, int, str]:
    if _mfp_auth_mode() == "cookie":
        return (await mfp_cookie_routes.create_connect_link(principal), mfp_cookie_routes.LINK_TTL_SECONDS, "cookie")
    return (await mfp_native_routes.create_connect_link(principal), mfp_native_routes.LINK_TTL_SECONDS, "native")


async def mfp_connect_account() -> dict:
    """Create a secure, short-lived link for this RunFuel user's selected MFP sign-in method."""
    principal = request_identity.get_principal()
    url, ttl, method = await _mfp_create_connect_link(principal)
    instructions = "Paste your own MyFitnessPal session cookie using this single-use link." if method == "cookie" else "Sign in to your own MyFitnessPal account using this single-use link."
    return {"connected": False, "method": method, "connect_url": url, "expires_in_seconds": ttl, "instructions": instructions}


async def _mfp_unconnected(principal: str) -> dict:
    url, _, method = await _mfp_create_connect_link(principal)
    instructions = "Connect your own MyFitnessPal account using this single-use link, then call this tool again." if method == "native" else "Connect your own MyFitnessPal session cookie using this single-use link, then call this tool again."
    return {"connected": False, "method": method, "connect_url": url, "instructions": instructions}


async def mfp_get_diary(date: str | None = None) -> dict:
    """Read this RunFuel user's MyFitnessPal diary using their encrypted native session."""
    from datetime import date as date_type
    from zoneinfo import ZoneInfo
    principal = request_identity.get_principal()
    day = date_type.fromisoformat(date).isoformat() if date else __import__("datetime").datetime.now(ZoneInfo("Pacific/Auckland")).date().isoformat()
    nutrition = (
        await mfp_cookie_routes.cookie_nutrition(principal, day)
        if _mfp_auth_mode() == "cookie"
        else await mfp_native_routes.native_nutrition(principal, day)
    )
    if nutrition is None:
        return await _mfp_unconnected(principal)
    return {"connected": True, "method": _mfp_auth_mode(), **nutrition}


async def mfp_connection_status() -> dict:
    """Check whether this RunFuel user has connected a MyFitnessPal account."""
    principal = request_identity.get_principal()
    mode = _mfp_auth_mode()
    if mode == "cookie":
        record = await mfp_cookie_vault.get_record(principal)
        if record is None:
            return await _mfp_unconnected(principal)
        return {"connected": True, "method": "cookie"}
    record = await mfp_native_routes.mfp_native_vault.get_token_record(principal)
    if record is None:
        return await _mfp_unconnected(principal)
    return {"connected": True, "method": "native", "expires_at": record["expires_at"]}


async def mfp_disconnect_account() -> dict:
    """Disconnect only this RunFuel user's MyFitnessPal account."""
    principal = request_identity.get_principal()
    await mfp_native_routes.mfp_native_vault.delete_token_record(principal)
    await mfp_cookie_vault.delete_record(principal)
    return {"connected": False, "message": "Your MyFitnessPal account has been disconnected from this RunFuel connection."}


async def mfp_get_goals(date: str | None = None) -> dict:
    """Read this user's MyFitnessPal nutrition goals for a diary date."""
    result = await mfp_get_diary(date)
    if not result.get("connected"):
        return result
    return {"connected": True, "day": result.get("day"), "goals": result.get("goals", {})}


async def mfp_get_report(start: str | None = None, end: str | None = None) -> dict:
    """Read a bounded daily nutrition history for this user's connected MyFitnessPal account (maximum 31 days)."""
    from datetime import date as date_type, timedelta
    from zoneinfo import ZoneInfo
    principal = request_identity.get_principal()
    end_day = date_type.fromisoformat(end) if end else __import__("datetime").datetime.now(ZoneInfo("Pacific/Auckland")).date()
    start_day = date_type.fromisoformat(start) if start else end_day - timedelta(days=6)
    if start_day > end_day:
        raise ValueError("start must be on or before end")
    span = (end_day - start_day).days + 1
    if span > 31:
        raise ValueError("Date range exceeds 31 days; request smaller date windows.")
    days = []
    for offset in range(span):
        day = (start_day + timedelta(days=offset)).isoformat()
        nutrition = (
            await mfp_cookie_routes.cookie_nutrition(principal, day)
            if _mfp_auth_mode() == "cookie"
            else await mfp_native_routes.native_nutrition(principal, day)
        )
        if nutrition is None:
            return await _mfp_unconnected(principal)
        days.append(nutrition)
    return {"connected": True, "start": start_day.isoformat(), "end": end_day.isoformat(), "days": days}


async def fitness_bulk_export_native(start: str | None = None, end: str | None = None, sync_first: bool = False) -> dict:
    """Compatibility name for the native-auth, read-only bounded diary export."""
    if sync_first:
        raise ValueError("sync_first is not supported by the native MyFitnessPal API; diary data is fetched directly.")
    return await mfp_get_report(start=start, end=end)


mcp.add_tool(mfp_connect_account, name="mfp_connect_account", annotations=READ_ONLY)
mcp.add_tool(mfp_connection_status, name="mfp_connection_status", annotations=READ_ONLY)
mcp.add_tool(mfp_disconnect_account, name="mfp_disconnect_account", annotations=ToolAnnotations(readOnlyHint=False, destructiveHint=True, openWorldHint=False))
mcp.add_tool(mfp_get_diary, name="mfp_get_diary", annotations=READ_ONLY)
mcp.add_tool(mfp_get_goals, name="mfp_get_goals", annotations=READ_ONLY)
mcp.add_tool(mfp_get_report, name="mfp_get_report", annotations=READ_ONLY)


_last_mfp_cookie: str | None = None


async def apply_managed_credentials() -> None:
    """Load encrypted credentials concurrently; never persist them to local disk."""
    global _last_mfp_cookie
    # MFP_COOKIE and MFP_USERNAME belong to the retired shared-cookie flow.
    # Never load another user's legacy MFP credentials into MCP worker state.
    names = tuple(
        name for name in token_manager.SECRET_NAMES
        if name not in {"MFP_COOKIE", "MFP_USERNAME"}
    )
    os.environ.pop("MFP_COOKIE", None)
    os.environ.pop("MFP_USERNAME", None)

    async def load(name: str) -> tuple[str, str | None]:
        try:
            value = await token_manager.get_credential(name)
        except Exception:
            # Preserve env-based operation if managed storage is unavailable.
            value = os.environ.get(name)
        return name, value

    # Redis reads are independent. Running them together reduces the time this
    # serverless invocation waits on credential storage.
    loaded = await asyncio.gather(*(load(name) for name in names))
    credentials = dict(loaded)
    for name, value in credentials.items():
        if value:
            os.environ[name] = value
        else:
            os.environ.pop(name, None)

    # Reset the upstream client only when its cookie actually changes. This
    # preserves its in-process session/cache between warm invocations while
    # still picking up credential updates on the next request.
    current_cookie = credentials.get("MFP_COOKIE")
    if current_cookie != _last_mfp_cookie:
        mfp_client.reset()
        _last_mfp_cookie = current_cookie


MFP_SESSION_COOKIE = "__Secure-next-auth.session-token"
MFP_SESSION_URL = "https://www.myfitnesspal.com/api/auth/session"


def _renew_mfp_client_session(client) -> bool:
    """Ask MFP's NextAuth session endpoint to refresh a still-valid session."""
    try:
        response = client.session.get(
            MFP_SESSION_URL, headers={"Accept": "application/json"}
        )
        return bool(response.json().get("expires"))
    except Exception as exc:
        # Exception text can contain request details; log only the class.
        logger.warning("Couldn't renew MyFitnessPal session (%s)", type(exc).__name__)
        return False


def _managed_session_cookies(client) -> dict[str, str]:
    """Extract only durable MFP cookies, including a newly issued session token."""
    kept: dict[str, str] = {}
    jar = getattr(getattr(getattr(client, "session", None), "cookies", None), "jar", ())
    loaded = getattr(client, "loaded_cookies", {})
    for cookie in jar:
        if not cookie.domain.endswith("myfitnesspal.com") or cookie.name == "__cf_bm":
            continue
        untouched = (
            cookie.expires is None
            and cookie.domain.startswith(".")
            and loaded.get(cookie.name) == cookie.value
        )
        if untouched:
            kept.setdefault(cookie.name, cookie.value)
        elif cookie.name == MFP_SESSION_COOKIE and not cookie.is_expired():
            # Some session-cookie responses omit an explicit expiry attribute.
            # Preserve a changed primary session cookie even in that case.
            kept[cookie.name] = cookie.value
        elif cookie.expires is not None and not cookie.is_expired():
            kept[cookie.name] = cookie.value
    return kept


async def persist_managed_mfp_session() -> bool:
    """Persist a rotated MFP session cookie into encrypted managed storage."""
    global _last_mfp_cookie
    client = getattr(mfp_client, "_client", None)
    if client is None:
        return False
    try:
        cookies = _managed_session_cookies(client)
        if MFP_SESSION_COOKIE not in cookies:
            return False
        if cookies == getattr(client, "saved_cookies", {}):
            return False
        cookie_header = "; ".join(f"{name}={value}" for name, value in cookies.items())
        await token_manager.save_credential("MFP_COOKIE", cookie_header)
        os.environ["MFP_COOKIE"] = cookie_header
        client.loaded_cookies = dict(cookies)
        client.saved_cookies = dict(cookies)
        _last_mfp_cookie = cookie_header
        logger.info("Persisted a rotated MyFitnessPal session cookie to encrypted storage")
        return True
    except Exception as exc:
        logger.warning("Couldn't persist rotated MyFitnessPal session (%s)", type(exc).__name__)
        return False


def authorized(headers: list[tuple[bytes, bytes]], expected_token: str | None) -> bool:
    """Constant-time bearer-token comparison; missing configuration fails closed."""
    if not expected_token:
        return False
    header_value = next(
        (value.decode("latin-1") for key, value in headers if key.lower() == b"authorization"),
        "",
    )
    scheme, _, supplied = header_value.partition(" ")
    return scheme.lower() == "bearer" and bool(supplied) and hmac.compare_digest(supplied, expected_token)


async def health(_: Request) -> JSONResponse:
    return JSONResponse({"ok": True, "service": "runfuel-mcp"})


mcp_asgi = mcp.streamable_http_app()


def _normalize_request_path(requested_path: str) -> str:
    """Normalize Vercel-mounted paths without capturing OAuth metadata routes."""
    # The path-specific OAuth metadata URL ends in "/mcp" too. It must remain
    # a public metadata route rather than being treated as an MCP protocol call.
    if requested_path.endswith("/.well-known/oauth-protected-resource/mcp"):
        return requested_path
    if requested_path.endswith("/health"):
        return "/health"
    if requested_path.endswith("/mcp"):
        return "/mcp"
    return requested_path


class BearerAuth:
    """ASGI wrapper protecting all MCP protocol requests."""
    def __init__(self, app: ASGIApp) -> None:
        self.app = app
        self._credential_lock = asyncio.Lock()

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        original_path = scope.get("path", "")
        query = parse_qs(scope.get("query_string", b"").decode("latin-1"))
        requested_path = query.get("__runfuel_path", [original_path])[0]
        path = _normalize_request_path(requested_path)
        normalized_scope = dict(scope)
        normalized_scope["path"] = path
        if path != "/mcp":
            await self.app(normalized_scope, receive, send)
            return

        headers = scope.get("headers", [])
        header_value = next(
            (value.decode("latin-1") for key, value in headers if key.lower() == b"authorization"),
            "",
        )
        scheme, _, supplied = header_value.partition(" ")
        oauth_configured = bool(
            os.environ.get("UPSTASH_REDIS_REST_URL") and os.environ.get("UPSTASH_REDIS_REST_TOKEN")
        )
        oauth_valid = False
        oauth_principal = None
        if scheme.lower() == "bearer" and supplied and oauth_configured:
            try:
                oauth_principal = await oauth_auth.get_access_principal(supplied)
                oauth_valid = bool(oauth_principal)
            except Exception:
                oauth_valid = False
        legacy_valid = authorized(headers, os.environ.get("RUNFUEL_ACCESS_TOKEN"))
        if not (oauth_valid or legacy_valid) and scheme.lower() == "bearer" and supplied:
            # A managed legacy token is stored encrypted in Redis, not in source/env.
            try:
                managed_legacy = await token_manager.get_credential("RUNFUEL_ACCESS_TOKEN")
                legacy_valid = authorized(headers, managed_legacy)
            except Exception:
                legacy_valid = False
        if not (oauth_valid or legacy_valid):
            metadata_url = f"{oauth_auth.BASE_URL}/.well-known/oauth-protected-resource/mcp"
            response = JSONResponse(
                {"error": "Unauthorized"}, status_code=401,
                headers={"WWW-Authenticate": f'Bearer resource_metadata="{metadata_url}", scope="runfuel:read"'},
            )
            await response(scope, receive, send)
            return
        # Avoid two simultaneous requests swapping process-wide credentials mid-call.
        async with self._credential_lock:
            # Bind the authenticated OAuth principal to this request only.
            # MCP tools use this ContextVar to select that user's encrypted MFP vault.
            principal_token = request_identity.set_principal(oauth_principal)
            try:
                await apply_managed_credentials()
                await self.app(normalized_scope, receive, send)
            finally:
                request_identity.reset_principal(principal_token)


async def mobile_sync(request: Request) -> JSONResponse:
    """Authenticated, compact read-only sync payload for the selected RunFuel day.

    The Android app supplies an ISO date when the user navigates to a previous
    day. Keep the Garmin summary window anchored to that selected day and fetch
    the matching MyFitnessPal diary rather than silently returning today's data.
    """
    header = request.headers.get("authorization", "")
    scheme, _, bearer = header.partition(" ")
    if scheme.lower() != "bearer" or not bearer:
        return JSONResponse({"error": "Unauthorized"}, status_code=401,
                            headers={"Cache-Control": "no-store"})
    try:
        principal = await oauth_auth.get_access_principal(bearer)
        if not principal:
            return JSONResponse({"error": "Unauthorized"}, status_code=401,
                                headers={"Cache-Control": "no-store"})
    except Exception:
        return JSONResponse({"error": "Authentication service unavailable"}, status_code=503,
                            headers={"Cache-Control": "no-store"})

    from datetime import date as date_type, datetime, timedelta, timezone
    from zoneinfo import ZoneInfo
    today = datetime.now(ZoneInfo("Pacific/Auckland")).date()
    requested_date = request.query_params.get("date")
    if requested_date is None:
        selected_day = today
    else:
        try:
            selected_day = date_type.fromisoformat(requested_date)
        except (TypeError, ValueError):
            return JSONResponse(
                {"error": "Invalid date. Use YYYY-MM-DD."},
                status_code=400,
                headers={"Cache-Control": "no-store"},
            )
        if selected_day.isoformat() != requested_date:
            return JSONResponse(
                {"error": "Invalid date. Use YYYY-MM-DD."},
                status_code=400,
                headers={"Cache-Control": "no-store"},
            )
        if selected_day > today:
            return JSONResponse(
                {"error": "Future dates cannot be synced."},
                status_code=400,
                headers={"Cache-Control": "no-store"},
            )

    end = selected_day.isoformat()
    start = (selected_day - timedelta(days=6)).isoformat()
    payload = {
        "synced_at": datetime.now(timezone.utc).isoformat(),
        "date": end,
        "garmin": {"status": "error"},
        "myfitnesspal": {"status": "error"},
    }
    try:
        # MCP and app sync share process-wide credential environment variables.
        # Serialize the whole read so concurrent requests cannot swap credentials.
        async with app._credential_lock:
            await apply_managed_credentials()
            try:
                running = await garmin_get_running_summary(start=start, end=end)
                payload["garmin"] = {"status": "ok", "running_summary": running}
                # Wellness calls are read-only and deliberately omit high-volume
                # all-day samples and GPS/route data. Each metric is isolated so
                # one unavailable Garmin endpoint cannot block activity or MFP sync.
                wellness = {}
                wellness_errors = []
                for metric, tool_name in (
                    ("daily_summary", "garmin_get_daily_summary"),
                    ("sleep", "garmin_get_sleep"),
                    ("hrv", "garmin_get_hrv"),
                ):
                    try:
                        tool = getattr(garmin_server, tool_name)
                        result = await tool(date=end)
                        wellness[metric] = _sanitize_activity_payload(result)
                    except Exception as metric_exc:
                        logger.warning("Mobile Garmin %s failed (type=%s)", metric, type(metric_exc).__name__)
                        wellness_errors.append(metric)
                payload["garmin"]["health"] = {
                    "status": "ok" if wellness else "error",
                    "daily_summary": wellness.get("daily_summary"),
                    "sleep": wellness.get("sleep"),
                    "hrv": wellness.get("hrv"),
                    "unavailable_metrics": wellness_errors,
                }
            except Exception as exc:
                logger.warning("Mobile Garmin sync failed (type=%s)", type(exc).__name__)
                payload["garmin"] = {"status": "error", "message": "Garmin data could not be retrieved"}
            # Never fall back to the shared cookie store for an authenticated
            # OAuth principal: that could disclose another user's diary.
            try:
                native_nutrition = await mfp_native_routes.native_nutrition(principal, end)
                if native_nutrition is None:
                    payload["myfitnesspal"] = {
                        "status": "not_connected",
                        "message": "Connect your own MyFitnessPal account to this RunFuel connection.",
                        "auth_method": "native",
                        "session_check_succeeded": False,
                    }
                else:
                    payload["myfitnesspal"] = {
                        "status": "ok",
                        "nutrition": native_nutrition,
                        "auth_method": "native",
                        "session_check_succeeded": True,
                    }
            except Exception as exc:
                logger.warning("Mobile native MyFitnessPal sync failed (type=%s)", type(exc).__name__)
                payload["myfitnesspal"] = {
                    "status": "error",
                    "message": "MyFitnessPal data could not be retrieved",
                    "auth_method": "native",
                    "session_check_succeeded": False,
                }
    except Exception:
        return JSONResponse({"error": "Could not load connected data credentials"}, status_code=503,
                            headers={"Cache-Control": "no-store"})
    return JSONResponse(payload, headers={"Cache-Control": "no-store"})


async def not_found(_: Request) -> JSONResponse:
    return JSONResponse({"error": "Not found"}, status_code=404)


from starlette.applications import Starlette


@asynccontextmanager
async def mcp_lifespan(_app: Starlette):
    """Start the MCP Streamable HTTP session manager for the app lifetime."""
    async with mcp.session_manager.run():
        yield


inner_app = Starlette(
    lifespan=mcp_lifespan,
    routes=[
        Route("/health", health, methods=["GET"]),
        Route("/api/mobile/sync", mobile_sync, methods=["GET"]),
        Route("/api/mobile/mfp/connect", mfp_native_routes.connect, methods=["POST"]),
        Route("/api/mobile/mfp/status", mfp_native_routes.status, methods=["GET"]),
        Route("/api/mobile/mfp/disconnect", mfp_native_routes.disconnect, methods=["DELETE"]),
        Route("/mfp/connect", mfp_native_routes.connect_page, methods=["GET"]),
        Route("/mfp/connect", mfp_native_routes.connect_submit, methods=["POST"]),
        Route("/mfp/cookie/connect", mfp_cookie_routes.connect_page, methods=["GET"]),
        Route("/mfp/cookie/connect", mfp_cookie_routes.connect_submit, methods=["POST"]),
        Route("/settings", token_manager.settings_page, methods=["GET"]),
        Route("/settings", token_manager.save_settings, methods=["POST"]),
        Route("/.well-known/oauth-authorization-server", oauth_auth.metadata, methods=["GET"]),
        Route("/.well-known/oauth-protected-resource", oauth_auth.protected_resource, methods=["GET"]),
        Route("/.well-known/oauth-protected-resource/mcp", oauth_auth.protected_resource, methods=["GET"]),
        Route("/register", oauth_auth.register, methods=["POST"]),
        Route("/authorize", oauth_auth.authorize, methods=["GET"]),
        Route("/login", oauth_auth.login, methods=["POST"]),
        Route("/token", oauth_auth.token, methods=["POST"]),
        Mount("/", app=mcp_asgi),
        Route("/{path:path}", not_found, methods=["GET", "POST", "PUT", "PATCH", "DELETE"]),
    ],
)
app = BearerAuth(inner_app)
