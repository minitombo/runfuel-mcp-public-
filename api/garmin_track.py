"""Read-only retrieval of GPS track points from Garmin activity files, in memory."""
from __future__ import annotations

import asyncio
import io
import zipfile
from datetime import datetime
from typing import Any

from fitparse import FitFile
from mcp.types import ToolAnnotations
from garmin_personal_mcp import server as garmin_server

MAX_TRACK_POINTS = 2000


def _field_values(message: Any) -> dict[str, Any]:
    return {field.name: field.value for field in message}


def _sample_points(points: list[dict], max_points: int) -> list[dict]:
    """Evenly sample a track while preserving its first and last valid points."""
    if len(points) <= max_points:
        return points
    if max_points == 1:
        return [points[0]]
    last = len(points) - 1
    indices = sorted({round(i * last / (max_points - 1)) for i in range(max_points)})
    return [points[i] for i in indices]


def _parse_fit_track(fit_bytes: bytes, max_points: int) -> dict:
    points: list[dict] = []
    for message in FitFile(io.BytesIO(fit_bytes)).get_messages("record"):
        fields = _field_values(message)
        latitude = fields.get("position_lat")
        longitude = fields.get("position_long")
        if latitude is None or longitude is None:
            continue
        try:
            # python-fitparse returns FIT position fields in semicircles.
            latitude = float(latitude) * (180.0 / (2**31))
            longitude = float(longitude) * (180.0 / (2**31))
        except (TypeError, ValueError):
            continue
        if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
            continue
        point = {"lat": latitude, "lon": longitude}
        altitude = fields.get("enhanced_altitude")
        if altitude is None:
            altitude = fields.get("altitude")
        if altitude is not None:
            try:
                point["altitude_m"] = float(altitude)
            except (TypeError, ValueError):
                pass
        timestamp = fields.get("timestamp")
        if isinstance(timestamp, datetime):
            point["timestamp"] = timestamp.isoformat()
        elif timestamp is not None:
            point["timestamp"] = str(timestamp)
        points.append(point)

    if not points:
        return {
            "point_count": 0,
            "returned_point_count": 0,
            "sampled": False,
            "points": [],
            "message": "The activity file contained no GPS record points.",
        }
    sampled_points = _sample_points(points, max_points)
    return {
        "point_count": len(points),
        "returned_point_count": len(sampled_points),
        "sampled": len(sampled_points) < len(points),
        "coordinate_format": "latitude/longitude in decimal degrees",
        "points": sampled_points,
    }


def _download_fit_bytes(activity_id: int) -> bytes:
    """Download the Garmin activity archive without writing it to disk."""
    archive_bytes = garmin_server.garmin_client.call(
        lambda client: client.download_activity(activity_id)
    )
    if not isinstance(archive_bytes, (bytes, bytearray)):
        raise RuntimeError("Garmin did not return an activity-file archive.")
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        fit_names = [
            name for name in archive.namelist()
            if name.lower().endswith(".fit") and not name.endswith("/")
        ]
        if not fit_names:
            raise RuntimeError("No FIT file was found in the Garmin activity archive.")
        return archive.read(fit_names[0])


async def garmin_get_activity_track(activity_id: int, max_points: int = 2000) -> dict:
    """Read GPS track points for a Garmin activity without saving its file to disk.

    Returns coordinates in decimal degrees, plus timestamps and altitude when
    available. Tracks are evenly sampled to max_points (default and maximum
    2000) to keep responses manageable. This tool returns only track data;
    use garmin_get_activity for the activity summary and splits.
    """
    if activity_id <= 0:
        raise ValueError("activity_id must be a positive integer")
    if not 1 <= max_points <= MAX_TRACK_POINTS:
        raise ValueError(f"max_points must be between 1 and {MAX_TRACK_POINTS}")
    fit_bytes = await asyncio.to_thread(_download_fit_bytes, activity_id)
    result = await asyncio.to_thread(_parse_fit_track, fit_bytes, max_points)
    return {"activity_id": activity_id, **result}


READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=True)
