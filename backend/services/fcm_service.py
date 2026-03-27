"""Cruise App — FCM push notification service."""

import logging

try:
    import firestore_sync
    _HAS_FIRESTORE = True
except Exception as _fs_err:
    _HAS_FIRESTORE = False
    logging.warning("firestore_sync not available: %s", _fs_err)


def _send_fcm_push(token: str, title: str, body: str, data: dict = None):
    """Send FCM push notification. Silently skips if Firebase not available."""
    if not _HAS_FIRESTORE or not token:
        return
    try:
        from firebase_admin import messaging as _fcm
        msg = _fcm.Message(
            notification=_fcm.Notification(title=title, body=body),
            data={k: str(v) for k, v in (data or {}).items()},
            token=token,
            android=_fcm.AndroidConfig(priority="high"),
            apns=_fcm.APNSConfig(
                headers={"apns-priority": "10"},
                payload=_fcm.APNSPayload(aps=_fcm.Aps(sound="default", badge=1)),
            ),
        )
        _fcm.send(msg)
        logging.info("[FCM] Push sent to ...%s", token[-8:])
    except Exception as _e:
        logging.warning("[FCM] Push failed: %s", _e)
