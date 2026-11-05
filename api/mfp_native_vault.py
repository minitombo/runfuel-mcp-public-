"""Per-user encrypted custody for native MyFitnessPal token pairs."""
from __future__ import annotations
import asyncio, hashlib, json, secrets, time
from contextlib import asynccontextmanager
from typing import AsyncIterator
from cryptography.fernet import InvalidToken
from api import oauth_auth, token_manager

TOKEN_PREFIX = "rf:mfp-native:v2:tokens:"
LOCK_PREFIX = "rf:mfp-native:v2:refresh-lock:"
LOCK_TTL_SECONDS = 90
LOCK_WAIT_SECONDS = 45
LOCK_POLL_SECONDS = 0.2
MAX_TOKEN_BYTES = 16384
_RELEASE = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end"


def _principal_key(principal: str) -> str:
    if not isinstance(principal, str) or not principal or len(principal) > 256:
        raise ValueError("A valid RunFuel user identity is required.")
    return hashlib.sha256(principal.encode("utf-8")).hexdigest()


def _token_key(principal: str) -> str:
    return TOKEN_PREFIX + _principal_key(principal)


def _lock_key(principal: str) -> str:
    return LOCK_PREFIX + _principal_key(principal)


def _validate(record: dict, preserve_updated_at: bool = False) -> dict:
    if not isinstance(record, dict):
        raise ValueError("Invalid native token record.")
    access, refresh = record.get("access_token"), record.get("refresh_token")
    expiry, user_id = record.get("expires_at"), record.get("domain_user_id")
    if not isinstance(access, str) or not access or len(access) > MAX_TOKEN_BYTES:
        raise ValueError("Invalid access token.")
    if not isinstance(refresh, str) or not refresh or len(refresh) > MAX_TOKEN_BYTES:
        raise ValueError("Invalid refresh token.")
    if not isinstance(expiry, (int, float)) or expiry <= 0:
        raise ValueError("Invalid token expiry.")
    if not isinstance(user_id, str) or not user_id or len(user_id) > 256:
        raise ValueError("Invalid account identifier.")
    updated = record.get("updated_at") if preserve_updated_at else None
    if not isinstance(updated, int) or updated <= 0:
        updated = int(time.time())
    return {
        "access_token": access, "refresh_token": refresh,
        "expires_at": float(expiry), "domain_user_id": user_id, "updated_at": updated,
    }


async def save_token_record(principal: str, record: dict) -> None:
    clean = _validate(record)
    raw = json.dumps(clean, separators=(",", ":"), sort_keys=True).encode()
    encrypted = token_manager._fernet().encrypt(raw).decode("ascii")
    await oauth_auth._redis(["SET", _token_key(principal), encrypted])


async def get_token_record(principal: str) -> dict | None:
    encrypted = await oauth_auth._redis(["GET", _token_key(principal)])
    if not encrypted:
        return None
    try:
        raw = token_manager._fernet().decrypt(str(encrypted).encode("ascii"))
        return _validate(json.loads(raw.decode()), True)
    except (InvalidToken, UnicodeDecodeError, json.JSONDecodeError, ValueError, TypeError):
        raise RuntimeError("Stored native MyFitnessPal credentials are unreadable.") from None


async def delete_token_record(principal: str) -> None:
    await oauth_auth._redis(["DEL", _token_key(principal)])


@asynccontextmanager
async def refresh_lock(principal: str) -> AsyncIterator[None]:
    lock_key = _lock_key(principal)
    owner = secrets.token_urlsafe(24)
    deadline = time.monotonic() + LOCK_WAIT_SECONDS
    while time.monotonic() < deadline:
        result = await oauth_auth._redis(
            ["SET", lock_key, owner, "NX", "EX", str(LOCK_TTL_SECONDS)]
        )
        if result == "OK":
            break
        await asyncio.sleep(LOCK_POLL_SECONDS)
    else:
        raise TimeoutError("MyFitnessPal token refresh is busy; retry shortly.")
    try:
        yield
    finally:
        await oauth_auth._redis(["EVAL", _RELEASE, "1", lock_key, owner])
