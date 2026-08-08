"""APNs Live Activity pushes (ActivityKit) — puts a ride offer on the
Dynamic Island / lock screen while the driver is in another app or the app
is fully killed.

Why this exists: a normal FCM/APNs alert can only draw a banner. Repainting
(or starting) a Live Activity from outside the app requires Apple's
`push-type: liveactivity` channel, which does NOT go through Firebase — it
is a direct APNs HTTP/2 call signed with the team's .p8 key.

Env vars (Railway):
  APNS_KEY_CONTENT  — the .p8, base64-encoded (raw PEM also accepted)
  APNS_KEY_ID       — e.g. ZT32FV423C
  APNS_TEAM_ID      — e.g. 7QLC9UVB3Z
  APNS_BUNDLE_ID    — defaults to com.cruiseinride.app

Everything here is fail-soft and logged: the FCM banner is the guaranteed
copy; the Live Activity is the rich one.
"""

import base64
import json
import logging
import os
import time

import httpx
import jwt  # PyJWT

logger = logging.getLogger(__name__)

_BUNDLE = os.getenv("APNS_BUNDLE_ID", "com.cruiseinride.app")
_PROD = os.getenv("RAILWAY_ENVIRONMENT_NAME", "") == "production"
_HOST = "https://api.push.apple.com" if _PROD else "https://api.sandbox.push.apple.com"

# Provider JWTs live 60 min max; we re-mint at 50.
_cached_jwt = None
_cached_jwt_at = 0.0


def _apns_jwt():
    """ES256 provider token for APNs, or None when not configured."""
    global _cached_jwt, _cached_jwt_at
    if _cached_jwt and (time.time() - _cached_jwt_at) < 3000:
        return _cached_jwt
    key_b64 = os.getenv("APNS_KEY_CONTENT", "")
    key_id = os.getenv("APNS_KEY_ID", "")
    team_id = os.getenv("APNS_TEAM_ID", "")
    if not (key_b64 and key_id and team_id):
        return None
    try:
        try:
            key = base64.b64decode(key_b64).decode("utf-8")
        except Exception:
            key = key_b64
        _cached_jwt = jwt.encode(
            {"iss": team_id, "iat": int(time.time())},
            key,
            algorithm="ES256",
            headers={"alg": "ES256", "kid": key_id},
        )
        _cached_jwt_at = time.time()
        return _cached_jwt
    except Exception as e:
        logger.warning("[APNs-LA] could not mint provider JWT: %s", e)
        return None


async def send_live_activity_offer(
    *,
    start_token: str | None,
    activity_token: str | None,
    fare: str,
    per_hour: str | None,
    miles: str | None,
    minutes: str | None,
) -> str | None:
    """Start or update the driver's Live Activity with a ride offer.

    An existing activity gets an `update` on its own channel; otherwise the
    broadcast push-to-start token starts a fresh one (iOS 17.2+). Either way
    the alert block makes it break out with the offer sound.

    Returns None on success (or when APNs is not configured / there is no
    channel — both silent no-ops), "stale_activity" / "stale_start" when
    Apple says the channel is dead (caller clears it), and "error" otherwise.
    """
    token = _apns_jwt()
    if token is None:
        return  # not configured — FCM banner still goes out

    content_state = {
        "status": "offer",
        # Codable Date → seconds since 1970, which is how the Swift
        # ContentState decodes `since`.
        "since": int(time.time()),
        "fare": fare,
        "perHour": per_hour or "",
        "miles": miles or "",
        "minutes": minutes or "",
    }
    body_parts = [p for p in (fare, per_hour, miles, minutes) if p]
    alert = {
        "title": "New Ride Offer",
        "body": " · ".join(body_parts),
        "sound": "cruise_online.wav",
    }

    if activity_token:
        channel = activity_token
        aps = {
            "timestamp": int(time.time()),
            "event": "update",
            "content-state": content_state,
            "alert": alert,
        }
    elif start_token:
        channel = start_token
        aps = {
            "timestamp": int(time.time()),
            "event": "start",
            "attributes-type": "CruiseActivityAttributes",
            "attributes": {},
            "content-state": content_state,
            "alert": alert,
        }
    else:
        return

    headers = {
        "authorization": f"bearer {token}",
        "apns-topic": f"{_BUNDLE}.push-type.liveactivity",
        "apns-push-type": "liveactivity",
        "apns-priority": "10",
    }
    try:
        async with httpx.AsyncClient(http2=True, timeout=10) as client:
            r = await client.post(
                f"{_HOST}/3/device/{channel}", headers=headers, json=aps)
        if r.status_code == 200:
            logger.info("[APNs-LA] offer %s sent (channel ...%s)",
                        aps["event"], channel[-6:])
            return None
        # 400 BadDeviceToken / 410 Expired: the channel is dead — the caller
        # clears it so we stop paying for pushes that cannot land.
        logger.warning("[APNs-LA] offer push failed: HTTP %s %s",
                       r.status_code, r.text[:200])
        if r.status_code in (400, 410):
            return "stale_activity" if activity_token else "stale_start"
        return "error"
    except Exception as e:
        logger.warning("[APNs-LA] offer push error: %s", e)
        return "error"
