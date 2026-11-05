"""Safe, read-only diagnostics for the MyFitnessPal connection.

The probe performs one harmless read of today's diary. Initializing a client
alone is not sufficient evidence that the session is authenticated.
"""
from __future__ import annotations

import asyncio
from typing import Any

from myfitnesspal_mcp import auth, config, mfp_client, server as mfp_server


def _status_code(exc: BaseException) -> int | None:
    """Extract an HTTP status without returning response bodies or secrets."""
    seen: set[int] = set()
    current: BaseException | None = exc
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        response = getattr(current, "response", None)
        status = getattr(response, "status_code", None)
        if status is None:
            status = getattr(response, "status", None)
        if isinstance(status, int):
            return status
        current = current.__cause__ or current.__context__
    return None


def _category(exc: BaseException, status: int | None) -> str:
    """Return a safe category only; never echo the exception text."""
    message = str(exc).lower()
    exception_names = {cls.__name__.lower() for cls in type(exc).__mro__}
    if status == 403 or "cloudflare" in message or "challenge" in message:
        return "http_block_or_anti_bot_challenge"
    if status == 401 or any(
        word in message
        for word in ("unauthorized", "logged out", "session", "csrf", "expired cookie", "invalid cookie")
    ):
        return "authentication_rejected"
    if any(word in exception_names for word in ("timeoutexception", "connecterror", "networkerror")):
        return "network_error"
    if isinstance(exc, (TimeoutError, ConnectionError)):
        return "network_error"
    if status is not None:
        return "upstream_http_error"
    return "client_initialization_error"


def _next_step(category: str) -> str:
    if category == "missing_cookie":
        return "Configure MFP_COOKIE with the session cookie or full Cookie header."
    if category == "authentication_rejected":
        return (
            "MyFitnessPal rejected the session. Sign in normally, update MFP_COOKIE "
            "in RunFuel Token Manager, then retry this read-only check."
        )
    if category == "http_block_or_anti_bot_challenge":
        return (
            "MyFitnessPal returned a block or anti-bot challenge. Avoid repeated retries; "
            "confirm access in your normal browser and investigate the supported access method."
        )
    if category == "network_error":
        return "This looks like a temporary network or timeout issue. Retry later before replacing the cookie."
    if category == "upstream_http_error":
        return "MyFitnessPal returned an HTTP error. Retry later; replace the cookie only if authentication is rejected."
    if category == "client_initialization_error":
        return "The client could not initialize. Check the cookie format and configured username without sharing either value."
    return "A read-only diary probe succeeded. No credential update is needed."


async def fitness_check_connection(ctx: Any = None) -> dict[str, Any]:
    """Probe MyFitnessPal with one harmless diary read and return safe status only.

    Does not return diary contents, usernames, cookie values, response bodies,
    or exception text. The successful probe confirms a read succeeded at the
    time of the check; it does not guarantee future availability.
    """
    raw_cookie = config.cookie_env()
    cookies = auth.load_cookies() or {}
    has_expected_cookie = auth.SESSION_COOKIE in cookies
    cookie_names = sorted(str(name) for name in cookies.keys())
    username_configured = bool(config.username_env())
    impersonate = config.impersonate()

    result: dict[str, Any] = {
        "source": "MFP_COOKIE" if raw_cookie else ("local_saved_cookie" if cookies else "none"),
        "cookie_configured": bool(raw_cookie or cookies),
        "expected_session_cookie_present": has_expected_cookie,
        "cookie_names_only": cookie_names,
        "username_configured": username_configured,
        "impersonate_profile": impersonate,
        "read_only": True,
        "secrets_returned": False,
        "probe_performed": False,
        "diary_contents_returned": False,
    }
    if not cookies:
        result.update({
            "connected": False,
            "category": "missing_cookie",
            "http_status": None,
            "session_renewed": False,
            "next_step": _next_step("missing_cookie"),
        })
        return result

    try:
        client = await asyncio.to_thread(mfp_client.get_client)
        day = mfp_server.parse_day(None)

        # A direct read verifies authentication beyond client construction.
        # The returned diary object is intentionally discarded.
        await asyncio.to_thread(client.get_date, day)
    except Exception as exc:
        status = _status_code(exc)
        category = _category(exc, status)
        result.update({
            "connected": False,
            "category": category,
            "http_status": status,
            "probe_performed": True,
            "session_renewed": False,
            "next_step": _next_step(category),
        })
        return result

    result.update({
        "connected": True,
        "category": "authenticated_read_succeeded",
        "http_status": None,
        "probe_performed": True,
        "session_renewed": bool(getattr(client, "session_renewed", False)),
        "next_step": _next_step("authenticated_read_succeeded"),
    })
    return result
