"""Read-only access to the complete nutrient fields returned by MyFitnessPal."""
from __future__ import annotations

from datetime import date
from typing import Any

from mcp.server.fastmcp import Context
from myfitnesspal_mcp import server as mfp_server


class _SilentContext:
    """Minimal MCP context for internal calls made outside an MCP request."""

    async def info(self, _message: str) -> None:
        return None


def _numeric_fields(values: Any) -> dict[str, float]:
    """Keep every numeric nutrient/goal field that the upstream API provides."""
    if not isinstance(values, dict):
        return {}
    result: dict[str, float] = {}
    for key, value in values.items():
        if value is None or isinstance(value, bool):
            continue
        try:
            result[str(key)] = float(value)
        except (TypeError, ValueError):
            continue
    return result


async def fitness_get_nutrition_details(
    date: str | None = None, ctx: Context = None
) -> dict:
    """Read a day's full MyFitnessPal nutrient totals, goals and meal entries.

    Unlike the upstream cached summary, this reads the source day object
    directly. Additional fields such as fibre/fiber, sugar and sodium are
    returned when MyFitnessPal supplies them. No diary data is written.
    """
    day = mfp_server.parse_day(date)

    def read_day(_store, client):
        source_day = client.get_date(day)
        totals = _numeric_fields(getattr(source_day, "totals", {}))
        goals = _numeric_fields(getattr(source_day, "goals", {}) or {})
        meals = []
        for meal in getattr(source_day, "meals", []) or []:
            entries = []
            for entry in getattr(meal, "entries", []) or []:
                entries.append({
                    "name": str(getattr(entry, "name", "")),
                    "nutrients": _numeric_fields(getattr(entry, "totals", {})),
                })
            meals.append({
                "meal": str(getattr(meal, "name", "")).title(),
                "entries": entries,
            })
        return {
            "day": day.isoformat(),
            "source": "MyFitnessPal",
            "totals": totals,
            "goals": goals,
            "meals": meals,
            "available_nutrient_fields": sorted(totals),
            "available_goal_fields": sorted(goals),
            "note": (
                "Only fields actually returned by MyFitnessPal are included. "
                "Meal timestamps are not reported because the upstream day "
                "object does not guarantee them."
            ),
        }

    # The mobile REST endpoint calls this function without an MCP Context.
    # The upstream session helper may call ctx.info() when refreshing an
    # expired session, so provide a harmless logger for that internal path.
    session_context = ctx if ctx is not None else _SilentContext()
    return await mfp_server.with_session(session_context, read_day)
