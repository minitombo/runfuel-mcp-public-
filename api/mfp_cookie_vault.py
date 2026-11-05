"""Per-RunFuel-principal encrypted MyFitnessPal browser-cookie custody."""
from __future__ import annotations

import hashlib
import json

from cryptography.fernet import InvalidToken

from api import oauth_auth, token_manager

COOKIE_PREFIX = "rf:mfp-cookie:v1:records:"
MAX_COOKIE_BYTES = 12000
MAX_USERNAME_LENGTH = 256


def _key(principal: str) -> str:
    if not isinstance(principal, str) or not principal or len(principal) > 256:
        raise ValueError("A valid RunFuel user identity is required.")
    return COOKIE_PREFIX + hashlib.sha256(principal.encode("utf-8")).hexdigest()


def validate_record(record: dict) -> dict:
    if not isinstance(record, dict):
        raise ValueError("Invalid MyFitnessPal cookie record.")
    cookie = record.get("cookie")
    username = record.get("username")
    if not isinstance(cookie, str) or not cookie.strip() or len(cookie) > MAX_COOKIE_BYTES:
        raise ValueError("Invalid MyFitnessPal session cookie.")
    if chr(0) in cookie:
        raise ValueError("The MyFitnessPal cookie contains an invalid character.")
    if not isinstance(username, str) or not username.strip() or len(username) > MAX_USERNAME_LENGTH:
        raise ValueError("Enter your MyFitnessPal username.")
    return {"cookie": cookie.strip(), "username": username.strip()}


async def save_record(principal: str, record: dict) -> None:
    clean = validate_record(record)
    encrypted = token_manager._fernet().encrypt(
        json.dumps(clean, separators=(",", ":"), sort_keys=True).encode("utf-8")
    ).decode("ascii")
    await oauth_auth._redis(["SET", _key(principal), encrypted])


async def get_record(principal: str) -> dict | None:
    encrypted = await oauth_auth._redis(["GET", _key(principal)])
    if not encrypted:
        return None
    try:
        raw = token_manager._fernet().decrypt(str(encrypted).encode("ascii"))
        return validate_record(json.loads(raw.decode("utf-8")))
    except (InvalidToken, UnicodeDecodeError, json.JSONDecodeError, ValueError, TypeError):
        raise RuntimeError("Stored MyFitnessPal cookie credentials are unreadable.") from None


async def delete_record(principal: str) -> None:
    await oauth_auth._redis(["DEL", _key(principal)])
