"""Cruise App — FCM push notification service."""

import logging

# Check if Firebase Admin is available (initialized by firestore_sync or main app)
_HAS_FIREBASE = False
try:
    import firebase_admin
    if firebase_admin._apps:
        _HAS_FIREBASE = True
        logging.info("[FCM] Firebase Admin already initialized — FCM enabled")
    else:
        # Try to initialize if not done yet
        import os
        from firebase_admin import credentials
        sa_raw = os.getenv("FIREBASE_SERVICE_ACCOUNT", "")
        if sa_raw:
            import json, base64
            try:
                sa_json = base64.b64decode(sa_raw).decode("utf-8")
            except Exception:
                sa_json = sa_raw
            cred = credentials.Certificate(json.loads(sa_json))
            firebase_admin.initialize_app(cred)
            _HAS_FIREBASE = True
            logging.info("[FCM] Firebase Admin initialized from env var — FCM enabled")
        else:
            logging.warning("[FCM] No Firebase credentials — push notifications disabled")
except Exception as _e:
    logging.warning("[FCM] Firebase Admin not available: %s", _e)


async def send_to_topic_async(topic: str, title: str, body: str, data: dict = None) -> None:
    """Send FCM push to all subscribers of a topic (e.g. 'drivers_available').
    Runs in thread pool to avoid blocking the event loop."""
    import asyncio
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, lambda: _send_to_topic(topic, title, body, data))


def _send_to_topic(topic: str, title: str, body: str, data: dict = None) -> None:
    """Send FCM message to a topic. Silently skips if Firebase not available."""
    if not _HAS_FIREBASE or not topic:
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
        logging.warning("[FCM] Topic push to '%s' failed: %s", topic, _e)


async def _send_fcm_push_async(token: str, title: str, body: str, data: dict = None, is_offer: bool = False) -> None:
    """Async wrapper — runs FCM push in thread pool to avoid blocking event loop."""
    import asyncio
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, lambda: _send_fcm_push(token, title, body, data, is_offer))


def _send_fcm_push(token: str, title: str, body: str, data: dict = None, is_offer: bool = False):
    """Send FCM push notification. Silently skips if Firebase not available.

    Set is_offer=True for ride offer notifications — uses cruise_offers channel
    which has fullScreenIntent and max priority on Android.
    """
    if not _HAS_FIREBASE or not token:
        return
    try:
        from firebase_admin import messaging as _fcm
        channel_id = "cruise_offers" if is_offer else "cruise_premium"
        msg = _fcm.Message(
            notification=_fcm.Notification(title=title, body=body),
            data={k: str(v) for k, v in (data or {}).items()},
            token=token,
            android=_fcm.AndroidConfig(
                priority="high",
                notification=_fcm.AndroidNotification(
                    sound="cruise_online",
                    channel_id=channel_id,
                    visibility="public",
                ),
            ),
            apns=_fcm.APNSConfig(
                headers={"apns-priority": "10"},
                payload=_fcm.APNSPayload(aps=_fcm.Aps(sound="cruise_online.wav", badge=1)),
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
                try:
                    _loop = _asyncio.get_event_loop()
                    if _loop.is_running():
                        _asyncio.create_task(_clear())
                    else:
                        _loop.run_until_complete(_clear())
                except Exception:
                    pass
                logging.info("[FCM] stale token cleared (...%s)", token[-8:] if token else "?")
            except Exception as _clean_err:
                logging.warning("[FCM] stale-token cleanup failed: %s", _clean_err)
        else:
            logging.warning("[FCM] Push failed: %s", _msg)
