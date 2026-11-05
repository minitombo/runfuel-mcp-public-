"""Request-scoped RunFuel identity for authenticated MCP tool calls."""
from __future__ import annotations

from contextvars import ContextVar

_current_principal: ContextVar[str | None] = ContextVar("runfuel_principal", default=None)


def set_principal(principal: str | None):
    """Set the authenticated principal for the current ASGI request."""
    return _current_principal.set(principal)


def reset_principal(token) -> None:
    """Restore the previous principal after the request completes."""
    _current_principal.reset(token)


def get_principal() -> str:
    """Return the principal bound to this MCP request; fail closed if absent."""
    principal = _current_principal.get()
    if not isinstance(principal, str) or not principal:
        raise RuntimeError("A valid RunFuel user identity is required.")
    return principal
