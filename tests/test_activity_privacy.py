import os
os.environ.setdefault("RUNFUEL_BASE_URL", "https://runfuel-test.example")

import unittest

from api.index import (
    GARMIN_READ_TOOLS,
    MFP_READ_TOOLS,
    PRIVACY_FILTERED_GARMIN_TOOLS,
    _privacy_filtered_tool,
    _sanitize_activity_payload,
    _normalize_request_path,
    register_upstream_tools,
)


class ActivityPrivacySanitizerTests(unittest.TestCase):
    def test_path_specific_oauth_metadata_is_not_normalized_to_mcp(self):
        metadata_path = "/.well-known/oauth-protected-resource/mcp"
        self.assertEqual(_normalize_request_path(metadata_path), metadata_path)
        self.assertEqual(
            _normalize_request_path("/prefix/.well-known/oauth-protected-resource/mcp"),
            "/prefix/.well-known/oauth-protected-resource/mcp",
        )

    def test_mcp_and_health_paths_still_normalize(self):
        self.assertEqual(_normalize_request_path("/mcp"), "/mcp")
        self.assertEqual(_normalize_request_path("/prefix/mcp"), "/mcp")
        self.assertEqual(_normalize_request_path("/prefix/health"), "/health")

    def test_removes_known_owner_and_profile_fields_case_insensitively(self):
        payload = {
            "activityId": 123,
            "activityName": "Easy Run",
            "distance": 4123.0,
            "userDailySummaryId": 9876,
            "deviceId": "private-device-id",
            "userId": 9876,
            "accountId": 9876,
            "username": "private-user",
            "email": "private@example.invalid",
            "firstName": "Private",
            "lastName": "Person",
            "ownerFullName": "Private Name",
            "ownerDisplayName": "Private Display",
            "ownerId": 456,
            "userProfileId": 9876,
            "metadataDTO": {
                "userInfoDto": {
                    "userProfilePk": 9876,
                    "displayname": "Private Display",
                    "fullname": "Private Full Name",
                    "userPro": True,
                }
            },
            "profileImageUrl": "https://example.invalid/profile.jpg",
            "nested": {
                "OWNER_ID": 789,
                "ownerProfileImageURL": "https://example.invalid/nested.jpg",
                "profile": {"name": "Private Profile"},
                "averageHR": 142,
            },
            "splits": [
                {
                    "distance": 1000,
                    "ownerAvatarUrl": "https://example.invalid/avatar.png",
                    "pace": "5:30",
                }
            ],
        }

        sanitized = _sanitize_activity_payload(payload)

        self.assertEqual(sanitized["activityId"], 123)
        self.assertEqual(sanitized["activityName"], "Easy Run")
        self.assertEqual(sanitized["distance"], 4123.0)
        self.assertEqual(sanitized["nested"]["averageHR"], 142)
        self.assertEqual(sanitized["splits"][0]["distance"], 1000)
        self.assertEqual(sanitized["splits"][0]["pace"], "5:30")
        serialized = repr(sanitized).casefold()
        for forbidden in (
            "ownerfullname", "ownerdisplayname", "ownerid", "profileimageurl",
            "userprofileid", "userinfodto", "userprofilepk", "displayname",
            "fullname", "private full name", "userdailysummaryid", "deviceid",
            "userid", "accountid", "username", "email", "firstname", "lastname",
            "private-device-id", "private-user", "private@example.invalid",
            "ownerprofileimageurl", "owneravatarurl", "private name",
            "private display", "private profile", "example.invalid",
        ):
            self.assertNotIn(forbidden, serialized)

    def test_ordinary_garmin_responses_strip_gps_details_recursively(self):
        payload = {
            "activityId": 123,
            "distance": 5000,
            "startLatitude": -37.7,
            "startLongitude": 175.2,
            "splits": [{"pace": 330, "latitude": -37.7, "longitude": 175.2}],
            "map": {"polyline": "route-data", "trackPoints": [{"lat": 1, "lon": 2}]},
        }
        sanitized = _sanitize_activity_payload(payload, strip_gps=True)
        self.assertEqual(sanitized["activityId"], 123)
        self.assertEqual(sanitized["distance"], 5000)
        self.assertEqual(sanitized["splits"], [{"pace": 330}])
        self.assertEqual(sanitized["map"], {})

    def test_explicit_track_tool_can_preserve_gps_coordinates(self):
        payload = {"activityId": 123, "points": [{"lat": -37.7, "lon": 175.2}]}
        self.assertEqual(_sanitize_activity_payload(payload), payload)

    def test_recursively_sanitizes_lists_and_tuples(self):
        sanitized = _sanitize_activity_payload(
            ({"activityId": 7, "ownerId": 8}, [{"ownerDisplayName": "Hidden", "pace": 300}])
        )
        self.assertEqual(sanitized, ({"activityId": 7}, [{"pace": 300}]))

    def test_expected_activity_tools_are_filtered(self):
        self.assertTrue({
            "garmin_get_day",
            "garmin_search_activities",
            "garmin_get_activity",
            "garmin_get_activity_workouts",
            "garmin_get_wellness_activities",
        }.issubset(PRIVACY_FILTERED_GARMIN_TOOLS))

    def test_all_upstream_tool_allowlists_use_privacy_filtering(self):
        from unittest.mock import patch

        registered = {}
        with patch("api.index.mcp.add_tool", side_effect=lambda fn, name, annotations: registered.update({name: fn})):
            register_upstream_tools()

        expected = set(GARMIN_READ_TOOLS) | set(MFP_READ_TOOLS)
        self.assertEqual(set(registered), expected)
        for name, fn in registered.items():
            with self.subTest(tool=name):
                self.assertTrue(hasattr(fn, "__wrapped__"), f"{name} was not privacy-wrapped")

    def test_wrapper_sanitizes_sync_tool_results(self):
        def upstream(activity_id: int):
            return {
                "activityId": activity_id,
                "ownerFullName": "Hidden",
                "distance": 1000,
            }

        import asyncio
        result = asyncio.run(_privacy_filtered_tool(upstream)(42))
        self.assertEqual(result, {"activityId": 42, "distance": 1000})


if __name__ == "__main__":
    unittest.main()
