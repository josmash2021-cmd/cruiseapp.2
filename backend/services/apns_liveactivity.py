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
_warned_not_configured = False


def apns_configured() -> bool:
    """True when the APNs credentials are all present — same env vars
    `_apns_jwt` needs, without minting the token. The dispatcher uses this
    to decide whether the FCM banner may be skipped in favor of the
    Live Activity push."""
    return bool(os.getenv("APNS_KEY_CONTENT")
                and os.getenv("APNS_KEY_ID")
                and os.getenv("APNS_TEAM_ID"))


def _apns_jwt():
    """ES256 provider token for APNs, or None when not configured."""
    global _cached_jwt, _cached_jwt_at, _warned_not_configured
    if _cached_jwt and (time.time() - _cached_jwt_at) < 3000:
        return _cached_jwt
    key_b64 = os.getenv("APNS_KEY_CONTENT", "")
    key_id = os.getenv("APNS_KEY_ID", "")
    team_id = os.getenv("APNS_TEAM_ID", "")
    if not (key_b64 and key_id and team_id):
        if not _warned_not_configured:
            _warned_not_configured = True
            logger.warning(
                "[APNs-LA] not configured (APNS_KEY_CONTENT/APNS_KEY_ID/"
                "APNS_TEAM_ID missing) — liveactivity pushes are no-ops")
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


async def clear_live_activity_offer(
    *,
    start_token: str | None,
    activity_token: str | None,
) -> str | None:
    """The offer died (expired, rejected, or went to another driver): the
    island goes back to the plain online state — no fare left on screen.

    Returns the same outcome strings as send_live_activity_offer.
    """
    token = _apns_jwt()
    if token is None:
        return None
    if not (activity_token or start_token):
        return None

    content_state = {
        "status": "online",
        "since": int(time.time()),
        "fare": "",
        "perHour": "",
        "miles": "",
        "minutes": "",
    }
    aps = {
        "timestamp": int(time.time()),
        "event": "update",
        "content-state": content_state,
        # No alert block: a silent repaint, not a second interruption.
    }
    channel = activity_token or start_token
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
            logger.info("[APNs-LA] offer cleared (channel ...%s)", channel[-6:])
            return None
        logger.warning("[APNs-LA] clear failed: HTTP %s %s",
                       r.status_code, r.text[:200])
        if r.status_code in (400, 410):
            return "stale_activity" if activity_token else "stale_start"
        return "error"
    except Exception as e:
        logger.warning("[APNs-LA] clear error: %s", e)
        return "error"


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


# ════════════════════════════════════════════════════════════════════
#  RIDER trip card — the passenger's Live Activity (drop-off ETA,
#  destination, driver photo/name/rating, car on the bar). The client
#  starts the activity itself when the trip is assigned (the app is
#  necessarily foreground at booking, so no push-to-start here); these
#  pushes keep it truthful while the app is backgrounded or killed.
# ════════════════════════════════════════════════════════════════════

# Content-state keys mirror CruiseRideActivityAttributes.ContentState —
# a rename on either side silently drops the field (decodeIfPresent).
def _ride_content_state(
    *,
    phase: str,
    started_at: int,
    dropoff_at: int,
    dropoff_address: str = "",
    driver_name: str = "",
    driver_rating: str = "",
    driver_photo_url: str = "",
    car_image: str = "",
) -> dict:
    return {
        "phase": phase,
        "startedAt": started_at,
        "dropoffAt": dropoff_at,
        "dropoffAddress": dropoff_address,
        "driverName": driver_name,
        "driverRating": driver_rating,
        "driverPhotoUrl": driver_photo_url,
        "carImage": car_image,
    }


async def _ride_push(ride_token: str, aps: dict) -> str | None:
    """One APNs liveactivity POST for the rider card. Same contract as the
    offer path: None on success/not configured, "stale" on a dead channel
    (caller clears the column), "error" otherwise."""
    token = _apns_jwt()
    if token is None or not ride_token:
        return None
    headers = {
        "authorization": f"bearer {token}",
        "apns-topic": f"{_BUNDLE}.push-type.liveactivity",
        "apns-push-type": "liveactivity",
        "apns-priority": "10",
    }
    try:
        async with httpx.AsyncClient(http2=True, timeout=10) as client:
            r = await client.post(
                f"{_HOST}/3/device/{ride_token}", headers=headers, json=aps)
        if r.status_code == 200:
            logger.info("[APNs-LA] ride %s sent (channel ...%s)",
                        aps.get("event"), ride_token[-6:])
            return None
        logger.warning("[APNs-LA] ride push failed: HTTP %s %s",
                       r.status_code, r.text[:200])
        if r.status_code in (400, 410):
            return "stale"
        return "error"
    except Exception as e:
        logger.warning("[APNs-LA] ride push error: %s", e)
        return "error"


async def update_ride_live_activity(
    *,
    ride_token: str | None,
    phase: str,
    started_at: int,
    dropoff_at: int,
    dropoff_address: str = "",
    driver_name: str = "",
    driver_rating: str = "",
    driver_photo_url: str = "",
    car_image: str = "",
    alert: dict | None = None,
) -> str | None:
    """Repaint the rider's trip card. Silent by design (no alert block):
    a phase change that must be SEEN (driver arrived) passes `alert`."""
    aps = {
        "timestamp": int(time.time()),
        "event": "update",
        "content-state": _ride_content_state(
            phase=phase, started_at=started_at, dropoff_at=dropoff_at,
            dropoff_address=dropoff_address, driver_name=driver_name,
            driver_rating=driver_rating, driver_photo_url=driver_photo_url,
            car_image=car_image,
        ),
    }
    if alert:
        aps["alert"] = alert
    return await _ride_push(ride_token, aps) if ride_token else None


async def end_ride_live_activity(
    *,
    ride_token: str | None,
    phase: str = "on_trip",
    started_at: int = 0,
    dropoff_at: int = 0,
) -> str | None:
    """Trip completed or cancelled — take the card down. APNs requires the
    final content-state on an end event; the timestamps are ignored by the
    widget once it is gone, so stale anchors are harmless.

    `dismissal-date: now` (user report 2026-09-23, "la tarjeta sigue en el
    lock screen con el viaje terminado"): without it iOS keeps the ENDED
    activity on the lock screen for up to 4 hours showing its final state —
    indistinguishable from the trip still being live."""
    if not ride_token:
        return None
    aps = {
        "timestamp": int(time.time()),
        "event": "end",
        "dismissal-date": int(time.time()),
        "content-state": _ride_content_state(
            phase=phase,
            started_at=started_at or int(time.time()),
            dropoff_at=dropoff_at or int(time.time()),
        ),
    }
    return await _ride_push(ride_token, aps)
