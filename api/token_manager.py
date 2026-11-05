"""Mobile-friendly, encrypted RunFuel credential manager.

Stored values are encrypted with Fernet before reaching Upstash. A dedicated
RUNFUEL_SECRET_ENCRYPTION_KEY is preferred; when absent, a stable key is
derived with HKDF from existing server-only secrets so first-run setup needs no
manual key generation. The page is protected by the existing OAuth password.
Secret values are never rendered back into the page.
"""
from __future__ import annotations

import hmac
import html
import os
from urllib.parse import urlsplit

from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from starlette.requests import Request
from starlette.responses import HTMLResponse

from api import oauth_auth

SECRET_NAMES = {
    "MFP_COOKIE": "Legacy shared MyFitnessPal cookie (app compatibility)",
    "MFP_USERNAME": "Legacy MyFitnessPal username (app compatibility)",
    "GARMIN_PERSONAL_API_KEY": "Garmin Personal API key",
    "RUNFUEL_ACCESS_TOKEN": "Legacy RunFuel bearer token",
}
REDIS_PREFIX = "rf:credential:v1:"
FIELD_LIMITS = {
    "MFP_COOKIE": 12000,
    "MFP_USERNAME": 256,
    "GARMIN_PERSONAL_API_KEY": 4096,
    "RUNFUEL_ACCESS_TOKEN": 4096,
}
COOKIE_HINT = "Paste the session cookie or full Cookie header, as accepted by the upstream MyFitnessPal connector."


def _encryption_key_source() -> str:
    """Describe key setup without returning key material or secret values."""
    if os.environ.get("RUNFUEL_SECRET_ENCRYPTION_KEY", "").strip():
        return "Dedicated encryption key configured"
    if os.environ.get("RUNFUEL_OAUTH_PASSWORD") and os.environ.get("UPSTASH_REDIS_REST_TOKEN"):
        return "Automatic encryption ready"
    return "Encryption setup incomplete"


def _fernet() -> Fernet:
    """Use a dedicated key when set, otherwise derive one from existing secrets.

    The fallback avoids requiring a separate manual Vercel variable. Because
    the derived key depends on the OAuth password and Upstash REST token, keep
    those values stable while managed credentials are stored. If either must
    change, first export/re-enter the managed credentials or configure a
    dedicated RUNFUEL_SECRET_ENCRYPTION_KEY and re-encrypt them.
    """
    configured = os.environ.get("RUNFUEL_SECRET_ENCRYPTION_KEY", "").strip()
    if configured:
        try:
            return Fernet(configured.encode("ascii"))
        except (ValueError, UnicodeEncodeError):
            raise RuntimeError("Credential encryption key is invalid.") from None

    password = os.environ.get("RUNFUEL_OAUTH_PASSWORD", "")
    redis_token = os.environ.get("UPSTASH_REDIS_REST_TOKEN", "")
    if not password or not redis_token:
        raise RuntimeError("Credential encryption is not configured.")

    material = password.encode("utf-8") + b"\x00" + redis_token.encode("utf-8")
    derived = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=b"runfuel-managed-credential-encryption-v1",
        info=b"runfuel-mcp/fernet-key",
    ).derive(material)
    import base64
    return Fernet(base64.urlsafe_b64encode(derived))


async def get_credential(name: str) -> str | None:
    """Read and decrypt a managed credential, falling back to Vercel env vars."""
    if name not in SECRET_NAMES:
        raise ValueError("Unknown credential.")
    try:
        ciphertext = await oauth_auth._redis(["GET", REDIS_PREFIX + name])
        if ciphertext:
            try:
                return _fernet().decrypt(str(ciphertext).encode("ascii")).decode("utf-8")
            except (InvalidToken, UnicodeDecodeError, ValueError):
                raise RuntimeError("A stored credential could not be decrypted.") from None
    except RuntimeError:
        raise
    except Exception:
        # Keep existing environment-based deployment functional during Redis
        # outages. The settings page itself reports the storage problem.
        return os.environ.get(name) or None
    return os.environ.get(name) or None


async def save_credential(name: str, value: str) -> None:
    if name not in SECRET_NAMES:
        raise ValueError("Unknown credential.")
    if not value or not value.strip():
        raise ValueError("Enter a value before saving.")
    if len(value) > FIELD_LIMITS[name]:
        raise ValueError(f"{SECRET_NAMES[name]} is too long.")
    if "\x00" in value:
        raise ValueError("The value contains an invalid character.")
    token = _fernet().encrypt(value.strip().encode("utf-8")).decode("ascii")
    await oauth_auth._redis(["SET", REDIS_PREFIX + name, token])


async def credential_status() -> dict[str, str]:
    status: dict[str, str] = {}
    for name in SECRET_NAMES:
        try:
            managed = await oauth_auth._redis(["GET", REDIS_PREFIX + name])
            status[name] = "Stored encrypted" if managed else (
                "Using Vercel environment variable" if os.environ.get(name) else "Not configured"
            )
        except Exception:
            status[name] = "Storage unavailable"
    return status


def _same_canonical_origin(origin: str) -> bool:
    """Accept only HTTPS requests from the configured canonical host.

    Parse and normalize the origin instead of comparing raw strings: browsers
    and reverse proxies may represent the default HTTPS port or host casing
    differently. Paths, credentials, alternate hosts, and non-HTTPS origins
    remain rejected.
    """
    try:
        supplied = urlsplit(origin)
        canonical = urlsplit(oauth_auth.BASE_URL)
        return bool(
            supplied.scheme.lower() == "https"
            and canonical.scheme.lower() == "https"
            and supplied.hostname
            and canonical.hostname
            and supplied.hostname.casefold() == canonical.hostname.casefold()
            and supplied.port in (None, 443)
            and supplied.username is None
            and supplied.password is None
            and not supplied.path
            and not supplied.query
            and not supplied.fragment
        )
    except ValueError:
        return False


def _same_canonical_referer(referer: str, host_header: str, fetch_site: str) -> bool:
    """Validate a same-origin HTTPS Referer for browsers that send Origin: null."""
    try:
        supplied = urlsplit(referer)
        canonical = urlsplit(oauth_auth.BASE_URL)
        expected_host = canonical.hostname
        request_host = host_header.split(":", 1)[0].strip().casefold()
        return bool(
            supplied.scheme.lower() == "https"
            and canonical.scheme.lower() == "https"
            and supplied.hostname
            and expected_host
            and supplied.hostname.casefold() == expected_host.casefold()
            and supplied.port in (None, 443)
            and supplied.username is None
            and supplied.password is None
            and request_host == expected_host.casefold()
            and fetch_site in ("", "same-origin")
        )
    except ValueError:
        return False


def _valid_settings_origin(request: Request, origin: str) -> bool:
    """Prefer Origin; narrowly fall back to Referer for opaque Origin: null."""
    if _same_canonical_origin(origin):
        return True
    if origin.strip().lower() != "null":
        return False
    return _same_canonical_referer(
        request.headers.get("referer", ""),
        request.headers.get("host", ""),
        request.headers.get("sec-fetch-site", ""),
    )


def _authorized(request: Request) -> bool:
    configured = os.environ.get("RUNFUEL_OAUTH_PASSWORD", "")
    auth = request.headers.get("authorization", "")
    scheme, _, encoded = auth.partition(" ")
    if scheme.lower() != "basic" or not encoded or not configured:
        return False
    try:
        import base64
        username, separator, password = base64.b64decode(encoded, validate=True).decode("utf-8").partition(":")
    except Exception:
        return False
    return bool(separator and hmac.compare_digest(username, "admin") and hmac.compare_digest(password, configured))


def _auth_required() -> HTMLResponse:
    body = """<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>RunFuel sign in</title></head>
<body style="font:16px system-ui;max-width:32rem;margin:3rem auto;padding:1rem">
<h1>RunFuel Token Manager</h1>
<p>Sign in with username <b>admin</b> and your RunFuel access password.</p>
</body></html>"""
    return HTMLResponse(
        body,
        status_code=401,
        headers={
            "WWW-Authenticate": 'Basic realm="RunFuel Token Manager", charset="UTF-8"',
            "Cache-Control": "no-store",
            "Pragma": "no-cache",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
            "Content-Security-Policy": "default-src 'none'; base-uri 'none'; frame-ancestors 'none'",
        },
    )


async def _auth_failure_response(request: Request) -> HTMLResponse:
    """Rate-limit failed manager logins using the shared hashed-IP Redis limiter."""
    try:
        allowed = await oauth_auth._allow_login_attempt(request)
    except Exception:
        return HTMLResponse(
            "Sign-in is temporarily unavailable. Please try again shortly.",
            status_code=503,
            headers={"Cache-Control": "no-store", "Retry-After": "60"},
        )
    if not allowed:
        return HTMLResponse(
            "Too many sign-in attempts. Please wait 15 minutes before trying again.",
            status_code=429,
            headers={"Cache-Control": "no-store", "Retry-After": str(oauth_auth.LOGIN_RATE_WINDOW)},
        )
    return _auth_required()


def _page(status: dict[str, str], message: str = "", error: bool = False) -> str:
    rows = []
    for name, label in SECRET_NAMES.items():
        state = html.escape(status.get(name, "Unknown"))
        note = COOKIE_HINT if name == "MFP_COOKIE" else (
            "Read-only Garmin Personal API key. Do not enter your Garmin website password." if name == "GARMIN_PERSONAL_API_KEY" else
            "Optional compatibility token. OAuth-issued Claude tokens are managed automatically."
            if name == "RUNFUEL_ACCESS_TOKEN" else "Your MyFitnessPal account username, not your email address."
        )
        rows.append(f"""
        <section class="credential">
          <label for="{name}">{html.escape(label)}</label>
          <input id="{name}" name="{name}" type="password" autocomplete="new-password"
                 autocapitalize="off" spellcheck="false" maxlength="{FIELD_LIMITS[name]}"
                 placeholder="Leave blank to keep current value">
          <p class="hint">{html.escape(note)}</p>
          <p class="status"><strong>Status:</strong> {state}</p>
        </section>""")
    notice = f'<p class="notice {"error" if error else "success"}" role="status">{html.escape(message)}</p>' if message else ""
    rows.insert(0, """<div class="app-note"><strong>Using the RunFuel Android app?</strong><p>You do not need to log in to MyFitnessPal here. Open RunFuel, go to Settings / Connections, and connect MyFitnessPal using the app’s native login. Leave both MyFitnessPal fields on this page blank; the app manages its own authentication.</p><p><strong>Using Claude or another MCP client?</strong> Use the MyFitnessPal login fields below to configure that connection.</p></div>""")
    encryption_state = html.escape(_encryption_key_source())
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>RunFuel Token Manager</title>
<style>
:root{{color-scheme:light dark;font-family:system-ui,-apple-system,sans-serif}}
body{{margin:0;background:Canvas;color:CanvasText}} main{{max-width:42rem;margin:0 auto;padding:1.25rem}}
h1{{font-size:1.7rem;margin-bottom:.3rem}} .muted,.hint{{color:GrayText;font-size:.92rem;line-height:1.45}}
.credential{{border:1px solid #8886;border-radius:14px;padding:1rem;margin:1rem 0}}
label{{display:block;font-weight:650;margin-bottom:.55rem}} input{{box-sizing:border-box;width:100%;padding:.85rem;border:1px solid #888;border-radius:9px;font:inherit;background:Canvas;color:CanvasText}}
.hint{{margin:.5rem 0}} .status{{font-size:.9rem;margin:.6rem 0 0}} button{{width:100%;padding:1rem;border:0;border-radius:10px;font:inherit;font-weight:700;background:#1769aa;color:white}}
.notice{{padding:.85rem;border-radius:8px}} .success{{background:#18733b22}} .error{{background:#b3261e22}}
.warning{{border-left:4px solid #b7791f;padding:.75rem 1rem;margin:1rem 0}} .app-note{{border:1px solid #1769aa66;border-left:4px solid #1769aa;border-radius:10px;padding:.85rem 1rem;margin:1rem 0;line-height:1.5}} .app-note p{{margin:.45rem 0 0}} footer{{margin:1.5rem 0;font-size:.85rem;color:GrayText}}
</style></head><body><main>
<h1>RunFuel Token Manager</h1>
<p class="muted">Manage credentials for your Garmin + MyFitnessPal MCP server. Saved values are encrypted before storage and are never shown again.</p>
<div class="warning">For Claude and other AI clients, do not paste an MFP cookie here. Use the MCP tool <strong>mfp_connect_account</strong> to generate a private sign-in link for your own MyFitnessPal account. Each RunFuel OAuth authorization gets its own encrypted MFP token record. The legacy MFP cookie fields below are retained only for existing single-owner app compatibility.</div>
<div class="warning">Only manage credentials for accounts you own. Do not enter your Garmin password, Claude tokens, or unrelated service passwords here. MyFitnessPal MCP tools remain read-only.</div>
<p class="status"><strong>Credential encryption:</strong> {encryption_state}. RunFuel creates the encryption key automatically from server-only secrets unless a dedicated key is configured.</p>
{notice}
<form method="post" action="/settings" autocomplete="off">
{"".join(rows)}
<button type="submit">Save credentials securely</button>
</form>
<footer>RunFuel does not store secrets in your browser. Blank fields leave existing credentials unchanged. OAuth access and refresh tokens used by Claude are issued and rotated automatically; they are not displayed here.</footer>
</main></body></html>"""


async def settings_page(request: Request):
    if not _authorized(request):
        return await _auth_failure_response(request)
    status = await credential_status()
    return HTMLResponse(_page(status), headers={"Cache-Control": "no-store, max-age=0", "Pragma": "no-cache", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "same-origin", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"})


async def save_settings(request: Request):
    if not _authorized(request):
        return await _auth_failure_response(request)
    origin = request.headers.get("origin", "")
    if not origin or not _valid_settings_origin(request, origin):
        # Log only normalized origin metadata (never credentials or the full header).
        try:
            supplied = urlsplit(origin)
            canonical = urlsplit(oauth_auth.BASE_URL)
            import logging
            logging.warning(
                "RunFuel settings origin rejected: scheme=%r host=%r port=%r path_present=%s canonical_scheme=%r canonical_host=%r host_header=%r",
                supplied.scheme.lower(), supplied.hostname, supplied.port,
                bool(supplied.path or supplied.query or supplied.fragment),
                canonical.scheme.lower(), canonical.hostname,
                request.headers.get("host", ""),
            )
        except Exception:
            pass
        return HTMLResponse("Origin check failed. Open the settings page from your canonical RunFuel domain and try again.", status_code=403, headers={"Cache-Control": "no-store"})
    if "application/x-www-form-urlencoded" not in request.headers.get("content-type", "").lower():
        return HTMLResponse("Unsupported form content type.", status_code=415, headers={"Cache-Control": "no-store"})
    try:
        form = await request.form()
        saved = []
        for name in SECRET_NAMES:
            value = form.get(name, "")
            if not isinstance(value, str):
                continue
            if value.strip():
                await save_credential(name, value)
                saved.append(SECRET_NAMES[name])
        status = await credential_status()
        message = "Saved encrypted: " + (", ".join(saved) if saved else "no changes made")
        return HTMLResponse(_page(status, message), headers={"Cache-Control": "no-store, max-age=0", "Pragma": "no-cache", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"})
    except Exception as exc:
        # Never echo input or raw exception details; they may contain secrets.
        status = await credential_status()
        message = "Could not save credentials. Check that Redis is available and RunFuel's OAuth password and Upstash token are configured."
        return HTMLResponse(_page(status, message, error=True), status_code=503, headers={"Cache-Control": "no-store, max-age=0", "Pragma": "no-cache", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"})
