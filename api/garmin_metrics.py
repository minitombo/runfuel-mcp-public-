"""Read-only derived running metrics built from Garmin activity records."""
from __future__ import annotations

from datetime import date, timedelta
from typing import Any

from mcp.server.fastmcp import Context
from garmin_personal_mcp import server as garmin_server


def _number(row: dict, *keys: str) -> float | None:
    for key in keys:
        value = row.get(key)
        if value is None or isinstance(value, bool):
            continue
        try:
            return float(value)
        except (TypeError, ValueError):
            continue
    return None


def _activity_rows(result: Any) -> list[dict]:
    if isinstance(result, list):
        return [row for row in result if isinstance(row, dict)]
    if isinstance(result, dict):
        rows = result.get("results", result.get("data", []))
        if isinstance(rows, list):
            return [row for row in rows if isinstance(row, dict)]
    return []


async def garmin_get_running_summary(
    start: str | None = None,
    end: str | None = None,
    ctx: Context = None,
) -> dict:
    """Summarize recorded running activities over a date range.

    Returns totals and derived metrics only when source activity records contain
    the required fields. This is not Garmin's proprietary training load,
    readiness, VO2 max, or race prediction metric.
    """
    end_day = date.fromisoformat(end) if end else date.today()
    start_day = date.fromisoformat(start) if start else end_day - timedelta(days=6)
    if start_day > end_day:
        raise ValueError("start must be on or before end")

    result = await garmin_server.garmin_search_activities(
        start=start_day.isoformat(),
        end=end_day.isoformat(),
        activity_type="running",
        limit=100,
        offset=0,
    )
    rows = _activity_rows(result)
    distances_m = []
    durations_s = []
    elevation_m = []
    hr_duration_pairs = []
    activities = []

    for row in rows:
        distance = _number(row, "distance", "distanceInMeters")
        duration = _number(row, "duration", "movingDuration", "timerDuration")
        avg_hr = _number(row, "averageHR", "avgHR", "averageHeartRate")
        elevation = _number(row, "elevationGain", "totalElevationGain")
        activities.append({
            "activity_id": row.get("activityId", row.get("activity_id")),
            "name": row.get("activityName", row.get("name")),
            "start_time": row.get("startTimeLocal", row.get("startTimeGMT", row.get("startTime"))),
            "distance_m": distance,
            "duration_s": duration,
            "average_hr_bpm": avg_hr,
            "elevation_gain_m": elevation,
            "average_speed_m_s": _number(row, "averageSpeed", "avgSpeed"),
            "training_effect": row.get("trainingEffect", row.get("aerobicTrainingEffect")),
        })
        # A running record without distance may be an imported exercise entry.
        # Keep it visible in the activity list, but exclude it from totals.
        if distance is not None and distance > 0:
            distances_m.append(distance)
            if duration is not None and duration > 0:
                durations_s.append(duration)
                if avg_hr is not None and avg_hr > 0:
                    hr_duration_pairs.append((avg_hr, duration))
        if elevation is not None and elevation >= 0:
            elevation_m.append(elevation)

    total_distance_m = sum(distances_m) if distances_m else None
    total_duration_s = sum(durations_s) if durations_s else None
    pace_seconds_per_km = (
        total_duration_s / (total_distance_m / 1000)
        if total_duration_s is not None and total_distance_m is not None and total_distance_m > 0
        else None
    )
    weighted_hr = (
        sum(hr * duration for hr, duration in hr_duration_pairs)
        / sum(duration for _, duration in hr_duration_pairs)
        if hr_duration_pairs else None
    )

    return {
        "source": "Garmin Connect Personal API activity records",
        "start": start_day.isoformat(),
        "end": end_day.isoformat(),
        "activity_type_filter": "running",
        "activity_count": len(rows),
        "total_distance_km": round(total_distance_m / 1000, 3) if total_distance_m is not None else None,
        "total_duration_s": round(total_duration_s, 1) if total_duration_s is not None else None,
        "average_pace_min_per_km": round(pace_seconds_per_km / 60, 2) if pace_seconds_per_km is not None else None,
        "duration_weighted_average_hr_bpm": round(weighted_hr, 1) if weighted_hr is not None else None,
        "total_elevation_gain_m": round(sum(elevation_m), 1) if elevation_m else None,
        "activities": activities,
        "limitations": [
            "Derived values are calculated only from fields returned by Garmin.",
            "Activities without a positive recorded distance remain listed but are excluded from running totals and pace.",
            "This summary is not a substitute for Garmin's proprietary training status, acute load, readiness, VO2 max, or race predictions.",
            "Only the first 100 matching activities are requested per call.",
        ],
    }
