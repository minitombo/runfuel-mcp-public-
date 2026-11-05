"""Read-only compatibility aliases for familiar MFP tool names.

Aliases reuse RunFuel's existing session/authentication path. Where the upstream
package has no supported read implementation, do not register a placeholder.
"""
from __future__ import annotations

from datetime import date, timedelta

from mcp.server.fastmcp import Context
from myfitnesspal_mcp import server as mfp_server

from api.nutrition_metrics import fitness_get_nutrition_details


async def mfp_get_goals(date: str | None = None, ctx: Context = None) -> dict:
    """Read the goals returned by MyFitnessPal for a selected diary date."""
    details = await fitness_get_nutrition_details(date=date, ctx=ctx)
    return {
        "date": details.get("day"),
        "source": "MyFitnessPal day object",
        "goals": details.get("goals", {}),
        "available_goal_fields": details.get("available_goal_fields", []),
        "note": "Only goals supplied by MyFitnessPal's source day object are returned; missing goals are not inferred.",
    }


async def mfp_get_measurements(
    start_date: str | None = None,
    end_date: str | None = None,
    ctx: Context = None,
) -> dict:
    """Read cached weight trend points; this is not a full body-measurement API."""
    end_day = date.fromisoformat(end_date) if end_date else date.today()
    start_day = date.fromisoformat(start_date) if start_date else end_day - timedelta(days=30)
    if start_day > end_day:
        raise ValueError("start_date must be on or before end_date")

    result = await mfp_server.fitness_get_trends(
        metric="weight",
        start=start_day.isoformat(),
        end=end_day.isoformat(),
        ctx=ctx,
    )
    return {
        "source": "RunFuel MyFitnessPal weight trend cache",
        "start_date": start_day.isoformat(),
        "end_date": end_day.isoformat(),
        "measurement": "weight",
        "points": result.get("points", []) if isinstance(result, dict) else [],
        "limitations": [
            "This is the existing cached weight trend, not a direct full body-measurement history endpoint.",
            "Only dates present in the local trend cache are included.",
        ],
    }


async def mfp_bulk_export_bounded(
    start: str | None = None,
    end: str | None = None,
    sync_first: bool = False,
    ctx: Context = None,
) -> dict:
    """Export a bounded diary window; default to 7 days and cap at 31 days.

    Large historical exports can create very large responses and trigger
    expensive upstream synchronization. Longer histories should be requested
    in smaller date windows. The upstream export remains read-only.
    """
    end_day = date.fromisoformat(end) if end else date.today()
    start_day = date.fromisoformat(start) if start else end_day - timedelta(days=6)
    if start_day > end_day:
        raise ValueError("start must be on or before end")
    span = (end_day - start_day).days + 1
    if span > 31:
        raise ValueError(
            f"Date range is {span} days; maximum per export is 31 days. "
            "Request the history in smaller date windows."
        )
    return await mfp_server.fitness_bulk_export(
        start=start_day.isoformat(),
        end=end_day.isoformat(),
        sync_first=sync_first,
        ctx=ctx,
    )
