"""The push message has to BUILD, and it has to ENCODE.

Every offer reaches a backgrounded driver through one `messaging.Message`
carrying both the Android block and the APNs block. Because it is a single
constructor call, a bad keyword in the Android part raises before the object
exists — `send()` is never reached and the iOS half dies with it. The whole
fleet goes quiet and the only trace is one WARNING line.

That is not hypothetical: `notification_priority="PRIORITY_MAX"` shipped
twice. It is the wire name, not the constructor's, and the SDK adds the
`PRIORITY_` prefix itself. It was removed once in b4a7ae83 and a later
latency commit put it straight back.

Two failure modes, so two checks:
  * a wrong KEYWORD blows up at construction — caught by building
  * a wrong VALUE blows up at encode time — caught by encoding
Building alone would have missed the second.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest

firebase_admin = pytest.importorskip("firebase_admin")
from firebase_admin import messaging as fcm  # noqa: E402


def _encode(message):
    """Run the SDK's own encoder — the step that validates the values."""
    from firebase_admin import _messaging_encoder
    # MessageEncoder subclasses json.JSONEncoder; default() is what turns a
    # Message into the dict that goes on the wire, and where every value is
    # validated.
    return _messaging_encoder.MessageEncoder().default(message)


def _build(is_offer: bool):
    """The message exactly as fcm_service builds it."""
    from datetime import timedelta
    channel_id = "cruise_offers" if is_offer else "cruise_default"
    return fcm.Message(
        notification=fcm.Notification(title="New ride", body="2.4 mi away"),
        data={"type": "ride_offer", "trip_id": "123"},
        token="d" * 140,
        android=fcm.AndroidConfig(
            priority="high",
            ttl=timedelta(seconds=45 if is_offer else 600),
            direct_boot_ok=True,
            notification=fcm.AndroidNotification(
                sound="cruise_online",
                channel_id=channel_id,
                visibility="public",
                default_vibrate_timings=True,
                priority="max" if is_offer else "high",
            ),
        ),
        apns=fcm.APNSConfig(
            headers={"apns-priority": "10", "apns-push-type": "alert"},
            payload=fcm.APNSPayload(aps=fcm.Aps(
                sound="cruise_online.wav",
                badge=1,
                content_available=True if is_offer else None,
                mutable_content=True if is_offer else None,
            )),
        ),
    )


@pytest.mark.parametrize("is_offer", [True, False])
def test_the_message_builds_and_encodes(is_offer):
    out = _encode(_build(is_offer))
    assert out["token"]
    # Both halves survived. If the Android block had thrown, neither would
    # be here — that is the failure this file exists for.
    assert "android" in out
    assert "apns" in out


def test_the_android_priority_reaches_the_wire_as_fcm_expects():
    out = _encode(_build(True))
    note = out["android"]["notification"]
    assert note["notification_priority"] == "PRIORITY_MAX"
    assert out["android"]["priority"] == "high"


def test_a_normal_push_is_high_not_max():
    note = _encode(_build(False))["android"]["notification"]
    assert note["notification_priority"] == "PRIORITY_HIGH"


class TestTheTwoWaysThisBreaks:
    def test_the_wire_name_is_not_a_constructor_argument(self):
        """The exact regression: passing `notification_priority=`."""
        with pytest.raises(TypeError):
            fcm.AndroidNotification(notification_priority="PRIORITY_MAX")

    def test_a_prefixed_value_is_rejected_at_encode_time(self):
        """And the other half: the right keyword with the wire's value."""
        msg = fcm.Message(
            token="d" * 140,
            android=fcm.AndroidConfig(
                notification=fcm.AndroidNotification(priority="PRIORITY_MAX"),
            ),
        )
        with pytest.raises(ValueError):
            _encode(msg)


def test_the_service_still_passes_the_right_keyword():
    """Guards the real file, not the copy above.

    The copy could stay correct forever while fcm_service drifts; this reads
    the shipped source.
    """
    src = (Path(__file__).resolve().parents[1]
           / "services" / "fcm_service.py").read_text(encoding="utf-8")
    assert "notification_priority=" not in src, (
        "fcm_service is passing the WIRE name to the constructor again — "
        "that raises TypeError and kills the push on both platforms"
    )
    assert 'priority="max" if is_offer else "high"' in src
