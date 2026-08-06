"""Cruise App — FCM push notification service."""

import logging
import os
import threading
import time

# ── Firebase availability ────────────────────────────────────────
# This used to be decided ONCE at import time, reading only the
# FIREBASE_SERVICE_ACCOUNT env var. This module is imported (via
# proactive_support_agent) BEFORE anything initialises Firebase, so on any
# host that carries backend/serviceAccountKey.json instead of the env var the
# flag latched False for the whole process life: Firestore worked, every push
# was dropped, and nothing said why. It is now re-evaluated lazily, so the
# moment firestore_sync (or anyone else) initialises the default app, FCM
# starts working — and if nobody does, this module loads the SAME credentials
# firestore_sync does (file path first, then env var, base64 or raw JSON).
_HAS_FIREBASE = False          # cached POSITIVE result only; False = "not confirmed yet"
_INIT_LOCK = threading.Lock()
_LAST_INIT_ATTEMPT = 0.0       # monotonic; throttles credential loading
_INIT_RETRY_SECONDS = 30.0

# backend/serviceAccountKey.json — same file firestore_sync._KEY_PATH prefers.
# (__file__ is backend/services/fcm_service.py, hence the double dirname.)
_KEY_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "serviceAccountKey.json",
)
# Matches firestore_sync._STORAGE_BUCKET. Only used if THIS module ends up
# being the one that creates the default app, so that whoever initialises
# first leaves identical app options behind.
_STORAGE_BUCKET = "cruise-af9f1.firebasestorage.app"

# Dropped-push accounting — a skipped send must never be invisible again.
_drop_counts: dict = {}
_last_drop_log = 0.0
_DROP_LOG_INTERVAL = 60.0      # seconds between WARNING lines (first drop logs immediately)


def _load_credentials():
    """Load a firebase_admin Certificate the same way firestore_sync does.

    Order: backend/serviceAccountKey.json, then FIREBASE_SERVICE_ACCOUNT
    (base64-encoded JSON or raw JSON). Never logs credential contents.
    """
    from firebase_admin import credentials
    if os.path.exists(_KEY_PATH):
        try:
            return credentials.Certificate(_KEY_PATH)
        except Exception as e:
            logging.error("[FCM] serviceAccountKey.json unusable: %s", e)
    sa_raw = os.getenv("FIREBASE_SERVICE_ACCOUNT", "")
    if sa_raw:
        import json, base64
        try:
            try:
                sa_json = base64.b64decode(sa_raw).decode("utf-8")
            except Exception:
                sa_json = sa_raw
            return credentials.Certificate(json.loads(sa_json))
        except Exception as e:
            logging.error("[FCM] FIREBASE_SERVICE_ACCOUNT unusable: %s", e)
    return None


def _has_firebase() -> bool:
    """True when the Firebase default app exists (initialising it if needed).

    Cheap on the hot path: one dict lookup once the answer is True. When it is
    False the real work is throttled to once per _INIT_RETRY_SECONDS so a
    credential-less deploy cannot spend the CPU of every push retrying.
    """
    global _HAS_FIREBASE, _LAST_INIT_ATTEMPT
    if _HAS_FIREBASE:
        return True
    try:
        import firebase_admin
    except Exception as e:
        logging.warning("[FCM] firebase_admin import failed: %s", e)
        return False
    if firebase_admin._apps:
        _HAS_FIREBASE = True
        logging.info("[FCM] Firebase Admin available — FCM enabled")
        return True
    if (time.monotonic() - _LAST_INIT_ATTEMPT) < _INIT_RETRY_SECONDS and _LAST_INIT_ATTEMPT:
        return False
    with _INIT_LOCK:
        # Re-check under the lock: another thread may have just won this race.
        if _HAS_FIREBASE:
            return True
        if firebase_admin._apps:
            _HAS_FIREBASE = True
            logging.info("[FCM] Firebase Admin available — FCM enabled")
            return True
        if (time.monotonic() - _LAST_INIT_ATTEMPT) < _INIT_RETRY_SECONDS and _LAST_INIT_ATTEMPT:
            return False
        _LAST_INIT_ATTEMPT = time.monotonic()
        # Prefer letting firestore_sync own the init so app options (storage
        # bucket) stay consistent with the rest of the backend.
        try:
            import firestore_sync as _fs
            _fs._ensure_init()
            if firebase_admin._apps:
                _HAS_FIREBASE = True
                logging.info("[FCM] Firebase Admin initialised by firestore_sync — FCM enabled")
                return True
        except Exception as e:
            logging.warning("[FCM] firestore_sync init delegation failed: %s", e)
        try:
            cred = _load_credentials()
        except Exception as e:
            # This runs on the caller's thread (sometimes a request handler);
            # it must never raise out of here and turn a missed push into a 500.
            logging.error("[FCM] credential load raised: %s", e)
            return False
        if cred is None:
            logging.warning(
                "[FCM] No Firebase credentials (serviceAccountKey.json or "
                "FIREBASE_SERVICE_ACCOUNT) — push notifications DISABLED, retrying in %ds",
                int(_INIT_RETRY_SECONDS),
            )
            return False
        try:
            firebase_admin.initialize_app(cred, {'storageBucket': _STORAGE_BUCKET})
            _HAS_FIREBASE = True
            logging.info("[FCM] Firebase Admin initialised from credentials — FCM enabled")
            return True
        except ValueError:
            # "default app already exists" — someone initialised between our
            # check and this call. That is a success, not a failure.
            if firebase_admin._apps:
                _HAS_FIREBASE = True
                logging.info("[FCM] Firebase Admin initialised concurrently — FCM enabled")
                return True
            return False
        except Exception as e:
            logging.error("[FCM] Firebase init failed: %s", e)
            return False


def fcm_enabled() -> bool:
    """Public probe for health checks: is FCM actually able to send right now?

    /health used to test `firebase_admin._apps` directly, which reported ok
    while this module was dropping every push.
    """
    return _has_firebase()


def _reset_if_app_gone(err_msg: str) -> None:
    """Drop the cached positive when the default app was torn down under us.

    firestore_sync.reconnect() deletes and re-creates the app; a send racing
    that would otherwise leave this module convinced Firebase is fine forever.
    """
    global _HAS_FIREBASE
    if "default Firebase app does not exist" in err_msg:
        _HAS_FIREBASE = False


def _log_drop(reason: str) -> None:
    """Record a dropped push and log it at WARNING, rate-limited.

    First drop of a reason logs immediately; after that at most one line per
    _DROP_LOG_INTERVAL, carrying the running totals so nothing is lost.
    """
    global _last_drop_log
    _drop_counts[reason] = _drop_counts.get(reason, 0) + 1
    now = time.monotonic()
    if _drop_counts[reason] == 1 or (now - _last_drop_log) >= _DROP_LOG_INTERVAL:
        _last_drop_log = now
        logging.warning(
            "[FCM] push DROPPED (%s) — totals since boot: %s",
            reason,
            ", ".join(f"{k}={v}" for k, v in sorted(_drop_counts.items())),
        )

# Main event loop reference — captured by _send_fcm_push_async so the
# stale-token cleanup can schedule coroutines thread-safely from the
# executor worker thread (asyncio.get_event_loop() always fails there).
_MAIN_LOOP = None


async def send_to_topic_async(topic: str, title: str, body: str, data: dict = None) -> None:
    """Send FCM push to all subscribers of a topic (e.g. 'drivers_available').
    Runs in thread pool to avoid blocking the event loop."""
    import asyncio
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, lambda: _send_to_topic(topic, title, body, data))


def _send_to_topic(topic: str, title: str, body: str, data: dict = None) -> None:
    """Send FCM message to a topic. Skips (and logs) if Firebase not available."""
    if not topic:
        _log_drop("empty topic")
        return
    if not _has_firebase():
        _log_drop("firebase unavailable (topic)")
        return
    try:
        from firebase_admin import messaging as _fcm
        msg = _fcm.Message(
            notification=_fcm.Notification(title=title, body=body),
            data={k: str(v) for k, v in (data or {}).items()},
            topic=topic,
            android=_fcm.AndroidConfig(
                priority="high",
                notification=_fcm.AndroidNotification(
                    sound="cruise_online",
                    channel_id="cruise_premium",
                    visibility="public",
                ),
            ),
            apns=_fcm.APNSConfig(
                headers={"apns-priority": "10"},
                payload=_fcm.APNSPayload(aps=_fcm.Aps(sound="cruise_online.wav", badge=1)),
            ),
        )
        _fcm.send(msg)
        logging.info("[FCM] Topic push sent to '%s'", topic)
    except Exception as _e:
        _reset_if_app_gone(str(_e))
        logging.warning("[FCM] Topic push to '%s' failed: %s", topic, _e)


async def _send_fcm_push_async(token: str, title: str, body: str, data: dict = None, is_offer: bool = False) -> None:
    """Async wrapper — runs FCM push in thread pool to avoid blocking event loop."""
    import asyncio
    global _MAIN_LOOP
    if _MAIN_LOOP is None:
        _MAIN_LOOP = asyncio.get_event_loop()
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, lambda: _send_fcm_push(token, title, body, data, is_offer))


def _send_fcm_push(token: str, title: str, body: str, data: dict = None, is_offer: bool = False):
    """Send FCM push notification. Skips (and logs) if Firebase not available.

    Set is_offer=True for ride offer notifications — uses cruise_offers channel
    which has fullScreenIntent and max priority on Android.
    """
    if not token:
        # Common and expected (user never registered a device), so it is
        # counted rather than logged line-by-line — see _log_drop.
        _log_drop("missing device token")
        return
    if not _has_firebase():
        _log_drop("firebase unavailable")
        return
    # Auto-detect offer push from data payload so callers that don't pass the
    # is_offer flag still get the priority behaviour (FCM channels, sound, etc.)
    try:
        _typ = (data or {}).get("type", "")
        if _typ in ("new_offer", "ride_offer", "offer"):
            is_offer = True
    except Exception:
        pass
    try:
        from firebase_admin import messaging as _fcm
        from datetime import timedelta as _td
        channel_id = "cruise_offers" if is_offer else "cruise_premium"
        msg = _fcm.Message(
            notification=_fcm.Notification(title=title, body=body),
            data={k: str(v) for k, v in (data or {}).items()},
            token=token,
            android=_fcm.AndroidConfig(
                # Offers are time-critical — `high` priority + short TTL bypass Doze
                # mode and App Standby buckets on Android, minimising delivery delay.
                priority="high",
                ttl=_td(seconds=45 if is_offer else 600),
                direct_boot_ok=True,
                notification=_fcm.AndroidNotification(
                    sound="cruise_online",
                    channel_id=channel_id,
                    visibility="public",
                    default_vibrate_timings=True,
                    notification_priority="PRIORITY_MAX" if is_offer else "PRIORITY_HIGH",
                ),
            ),
            apns=_fcm.APNSConfig(
                # apns-priority 10 = immediate delivery, interrupts low-power mode
                headers={"apns-priority": "10", "apns-push-type": "alert"},
                payload=_fcm.APNSPayload(aps=_fcm.Aps(
                    sound="cruise_online.wav",
                    badge=1,
                    content_available=True if is_offer else None,
                    mutable_content=True if is_offer else None,
                )),
            ),
        )
        _fcm.send(msg)
        logging.info("[FCM] Push sent to ...%s (channel=%s)", token[-8:], channel_id)
    except Exception as _e:
        _msg = str(_e)
        if "Requested entity was not found" in _msg or "registration-token-not-registered" in _msg.lower():
            # Stale token — clean it from any User row so we stop trying it.
            try:
                import asyncio as _asyncio
                from sqlalchemy import update as _upd
                from models.database import SessionLocal as _SL, User as _U
                async def _clear():
                    async with _SL() as _db:
                        await _db.execute(_upd(_U).where(_U.fcm_token == token).values(fcm_token=None))
                        await _db.commit()
                if _MAIN_LOOP is not None and _MAIN_LOOP.is_running():
                    _asyncio.run_coroutine_threadsafe(_clear(), _MAIN_LOOP)
                    logging.info("[FCM] stale token cleared (...%s)", token[-8:] if token else "?")
                else:
                    logging.info("[FCM] stale-token cleanup skipped (no main loop)")
            except Exception as _clean_err:
                logging.warning("[FCM] stale-token cleanup failed: %s", _clean_err)
        else:
            _reset_if_app_gone(_msg)
            logging.warning("[FCM] Push failed: %s", _msg)


# ═══════════════════════════════════════════════════════════════
#  UNIVERSAL WRAPPER — works in both sync and async contexts
# ═══════════════════════════════════════════════════════════════

def send_fcm_push(token: str, title: str, body: str, data: dict = None, is_offer: bool = False):
    """Universal FCM push sender — works in sync AND async contexts.
    
    Use this instead of _send_fcm_push() or _send_fcm_push_async().
    It automatically detects if we're in an async context and handles accordingly.
    """
    import asyncio
    try:
        loop = asyncio.get_running_loop()
        # We're in an async context — schedule in background
        if loop.is_running():
            asyncio.create_task(_send_fcm_push_async(token, title, body, data, is_offer))
        else:
            loop.run_until_complete(_send_fcm_push_async(token, title, body, data, is_offer))
    except RuntimeError:
        # No event loop — sync context, call directly
        _send_fcm_push(token, title, body, data, is_offer)
