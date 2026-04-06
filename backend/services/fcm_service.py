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
                    notification_priority=_fcm.AndroidNotificationPriority.MAX_PRIORITY if is_offer else _fcm.AndroidNotificationPriority.HIGH_PRIORITY,
                    visibility=_fcm.AndroidNotificationVisibility.PUBLIC,
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
        logging.warning("[FCM] Push failed: %s", _e)
