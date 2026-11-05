"""GET-only MyFitnessPal native diary transport."""
from __future__ import annotations
from datetime import date
from typing import Any
import httpx

API_BASE="https://api.myfitnesspal.com"
CLIENT_HEADER="mfp-mobile-android-google"
class NativeMFPDiaryError(RuntimeError):
    def __init__(self, message: str, status_code: int | None = None):
        super().__init__(message)
        self.status_code = status_code

async def fetch_diary(access_token: str, domain_user_id: str, day: str | date) -> dict[str,Any]:
    if not access_token or len(access_token)>16384 or not domain_user_id or len(domain_user_id)>256:
        raise ValueError("A valid MyFitnessPal session is required.")
    entry_date=day.isoformat() if isinstance(day,date) else date.fromisoformat(day).isoformat()
    params=[("entry_date",entry_date),("types","food_entry"),("fields[]","food"),("fields[]","nutritional_contents"),("fields[]","serving_size"),("fields[]","meal_name"),("fields[]","servings")]
    headers={"Authorization":f"Bearer {access_token}","Accept":"application/json","mfp-user-id":domain_user_id,"mfp-client-id":CLIENT_HEADER,"User-Agent":"RunFuel/experimental"}
    try:
        async with httpx.AsyncClient(timeout=15.0,follow_redirects=False) as client:
            response=await client.get(f"{API_BASE}/v2/diary",params=params,headers=headers)
        if response.status_code in (401,403): raise NativeMFPDiaryError("MyFitnessPal rejected the native session.", response.status_code)
        if response.status_code==429: raise NativeMFPDiaryError("MyFitnessPal rate-limited the diary request.")
        if response.status_code>=500: raise NativeMFPDiaryError("MyFitnessPal diary service is temporarily unavailable.")
        if response.status_code!=200: raise NativeMFPDiaryError("MyFitnessPal diary request was unsuccessful.")
        if len(response.content)>2_000_000: raise NativeMFPDiaryError("MyFitnessPal diary response exceeded the safety limit.")
        data=response.json()
        if not isinstance(data,dict) or not isinstance(data.get("items",[]),list): raise NativeMFPDiaryError("MyFitnessPal returned an unexpected diary format.")
        return data
    except httpx.TimeoutException: raise NativeMFPDiaryError("MyFitnessPal diary request timed out.") from None
    except httpx.RequestError: raise NativeMFPDiaryError("Could not connect to MyFitnessPal diary service.") from None

async def fetch_goals(access_token: str, domain_user_id: str) -> dict:
    headers={"Authorization":f"Bearer {access_token}","Accept":"application/json","mfp-user-id":domain_user_id,"mfp-client-id":CLIENT_HEADER}
    try:
        async with httpx.AsyncClient(timeout=15.0,follow_redirects=False) as client:
            response=await client.get(f"{API_BASE}/v2/nutrient-goals",headers=headers)
        if response.status_code!=200: return {}
        data=response.json()
        items=data.get("items") if isinstance(data,dict) else None
        return items[0] if isinstance(items,list) and items and isinstance(items[0],dict) else {}
    except (httpx.HTTPError,ValueError): return {}
