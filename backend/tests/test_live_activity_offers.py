"""Guardians for the offer push channel (2026-10-02 redesign).

Product call 2026-10-02: the Live Activity island is no longer used for
OFFERS — every offer goes out as the FCM banner, even for drivers with
Live Activity tokens registered and APNs configured (user spec: "quiero
que le llegue la notificacion de oferta"). The island keeps only the
online-presence state. What stays pinned here:

  * the dispatch ALWAYS fires the banner and never calls the island push
  * the APNs payload shape of send_live_activity_offer (the function is
    kept — it serves the rider trip card and may serve a future re-enable)
  * the clear path never aims at the start token with no live card
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest

pytestmark = pytest.mark.asyncio

from services import apns_liveactivity  # noqa: E402


class _FakeResponse:
    def __init__(self, status_code):
        self.status_code = status_code
        self.text = ""


class _FakeClient:
    """Stands in for httpx.AsyncClient — captures every post."""
    posts = []

    def __init__(self, *args, **kwargs):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def post(self, url, *, headers=None, json=None):
        self.posts.append({"url": url, "headers": headers, "json": json})
        return _FakeResponse(_FakeClient.next_status)


@pytest.fixture
def captured(monkeypatch):
    """send_live_activity_offer with a working JWT and a captured post."""
    _FakeClient.posts = []
    _FakeClient.next_status = 200
    monkeypatch.setattr(apns_liveactivity, "_apns_jwt", lambda: "test-jwt")
    monkeypatch.setattr(apns_liveactivity.httpx, "AsyncClient", _FakeClient)
    return _FakeClient.posts


class TestThePayload:
    """What goes on the wire is the whole contract with ActivityKit."""

    async def test_update_on_an_existing_activity(self, captured):
        outcome = await apns_liveactivity.send_live_activity_offer(
            start_token=None,
            activity_token="activity-token-123",
            fare="$12.00",
            per_hour="$36.00/hr",
            miles="2.4 mi",
            minutes="9 min",
        )
        assert outcome is None
        (post,) = captured
        assert post["url"].endswith("/3/device/activity-token-123")
        aps = post["json"]
        assert aps["event"] == "update"
        assert "attributes-type" not in aps
        cs = aps["content-state"]
        for key in ("status", "since", "fare", "perHour", "miles", "minutes"):
            assert key in cs, f"content-state is missing {key!r}"
        assert cs["status"] == "offer"
        assert cs["fare"] == "$12.00"
        assert post["headers"]["apns-topic"] == (
            f"{apns_liveactivity._BUNDLE}.push-type.liveactivity")
        assert post["headers"]["apns-push-type"] == "liveactivity"
        assert aps["alert"]["sound"] == "cruise_online.wav"

    async def test_start_via_the_broadcast_token(self, captured):
        outcome = await apns_liveactivity.send_live_activity_offer(
            start_token="start-token-456",
            activity_token=None,
            fare="$12.00",
            per_hour=None,
            miles=None,
            minutes=None,
        )
        assert outcome is None
        (post,) = captured
        assert post["url"].endswith("/3/device/start-token-456")
        aps = post["json"]
        assert aps["event"] == "start"
        assert aps["attributes-type"] == "CruiseActivityAttributes"
        # Empty segments become empty strings, never a missing key — the
        # Swift ContentState decodes all six unconditionally.
        assert aps["content-state"]["perHour"] == ""
        assert aps["alert"]["sound"] == "cruise_online.wav"


class TestAStaleChannelIsCleared:
    """400/410 means the channel is dead — the DB must stop aiming at it."""

    @pytest.mark.parametrize("status", [400, 410])
    async def test_outcome_strings(self, captured, status):
        _FakeClient.next_status = status
        assert await apns_liveactivity.send_live_activity_offer(
            start_token=None, activity_token="a", fare="",
            per_hour=None, miles=None, minutes=None,
        ) == "stale_activity"
        assert await apns_liveactivity.send_live_activity_offer(
            start_token="s", activity_token=None, fare="",
            per_hour=None, miles=None, minutes=None,
        ) == "stale_start"

    async def test_the_offer_goes_out_as_the_fcm_banner_even_with_la_tokens(
            self, monkeypatch, db, test_trip, test_driver):
        """2026-10-02: LA tokens + APNs configured — the offer STILL goes
        out as the FCM banner and the island push is never attempted."""
        from routers import dispatch
        driver, _ = test_driver
        driver.apns_la_activity_token = "act-123"
        driver.apns_la_start_token = "start-456"
        driver.fcm_token = "fcm-123"
        await db.commit()
        monkeypatch.setattr(apns_liveactivity, "apns_configured", lambda: True)

        la_calls = []
        fcm_calls = []

        async def _fake_la_send(**kwargs):
            la_calls.append(kwargs)
            return None

        async def _fake_fcm(token, **kwargs):
            fcm_calls.append((token, kwargs))

        scheduled = []

        def _immediate(coro, *args, **kwargs):
            scheduled.append(coro)

        monkeypatch.setattr(
            apns_liveactivity, "send_live_activity_offer", _fake_la_send)
        monkeypatch.setattr(dispatch, "_send_fcm_push_async", _fake_fcm)
        monkeypatch.setattr(dispatch, "_safe_create_task", _immediate)

        await dispatch._send_offer_to_driver(
            db, test_trip, driver, "Rider", "+1000", "")
        for coro in scheduled:
            await coro

        assert fcm_calls, "the banner must ALWAYS go out — it is the only "
        "notification the driver gets now"
        assert fcm_calls[0][0] == "fcm-123"
        assert fcm_calls[0][1]["is_offer"] is True
        assert not la_calls, "the island push must never be attempted for "
        "an offer anymore"


class TestTheFcmFallback:
    """FIX 2: a registered LA channel must NOT suppress the FCM banner when
    APNs is not configured — that combination leaves the driver with no
    notification at all outside the app."""

    async def test_no_apns_config_means_the_banner_still_goes(
            self, monkeypatch, db, test_trip, test_driver):
        from routers import dispatch
        driver, _ = test_driver
        driver.apns_la_start_token = "start-token-456"
        await db.commit()

        # APNs env vars absent, and no cached JWT pretending otherwise.
        for var in ("APNS_KEY_CONTENT", "APNS_KEY_ID", "APNS_TEAM_ID"):
            monkeypatch.delenv(var, raising=False)
        monkeypatch.setattr(apns_liveactivity, "_cached_jwt", None)
        assert not apns_liveactivity.apns_configured()

        fcm_calls = []
        la_calls = []

        async def _fake_fcm(token, **kwargs):
            fcm_calls.append(kwargs)

        async def _fake_la_send(**kwargs):
            la_calls.append(kwargs)

        scheduled = []

        def _immediate(coro, *args, **kwargs):
            scheduled.append(coro)

        monkeypatch.setattr(dispatch, "_send_fcm_push_async", _fake_fcm)
        monkeypatch.setattr(
            apns_liveactivity, "send_live_activity_offer", _fake_la_send)
        monkeypatch.setattr(dispatch, "_safe_create_task", _immediate)

        await dispatch._send_offer_to_driver(
            db, test_trip, driver, "Rider", "+1000", "")
        for coro in scheduled:
            await coro

        assert fcm_calls, "driver has an LA token but APNs is not " \
            "configured — the FCM banner was suppressed and he got NOTHING"
        assert fcm_calls[0]["is_offer"] is True
        assert not la_calls


class TestGetDriverPendingAuth:
    """FIX 4: pending offers carry the rider's name, phone and photo — only
    the driver they belong to may read them (the SSE stream already 403s)."""

    def _headers(self, token):
        from tests.conftest import _make_auth_headers
        return {**_make_auth_headers(api_key="test-dispatch-key"),
                "Authorization": f"Bearer {token}"}

    async def test_own_pending_offer_is_returned(
            self, client, db, test_trip, test_driver):
        from models.database import DispatchOffer
        driver, token = test_driver
        test_trip.status = "requested"
        test_trip.driver_id = None
        db.add(DispatchOffer(
            trip_id=test_trip.id, driver_id=driver.id, status="pending"))
        await db.commit()

        resp = await client.get(
            f"/dispatch/driver/pending?driver_id={driver.id}",
            headers=self._headers(token))
        assert resp.status_code == 200, resp.text
        offers = resp.json()
        assert len(offers) == 1
        assert offers[0]["id"] == test_trip.id

    async def test_another_user_gets_403(
            self, client, db, test_trip, test_driver, test_rider):
        from models.database import DispatchOffer
        driver, _ = test_driver
        rider, rider_token = test_rider
        db.add(DispatchOffer(
            trip_id=test_trip.id, driver_id=driver.id, status="pending"))
        await db.commit()

        resp = await client.get(
            f"/dispatch/driver/pending?driver_id={driver.id}",
            headers=self._headers(rider_token))
        assert resp.status_code == 403


class TestTheStartTokenIsSacred:
    """User report 2026-09-23 ("la isla no se despliega sola"): production
    had EVERY Live Activity column NULL. The kill chain: an offer EXPIRED,
    the clear aimed its update at the push-to-start channel (which rejects
    updates when no activity exists, HTTP 400), the refusal read as a dead
    token, and apns_la_start_token was wiped — on every expiry, forever."""

    async def test_clear_with_no_activity_never_aims_at_the_start_token(
            self, monkeypatch, db, test_driver):
        from routers import dispatch
        driver, _ = test_driver
        driver.apns_la_activity_token = None
        driver.apns_la_start_token = "healthy-start"
        await db.commit()

        calls = []

        async def _fake_clear(**kwargs):
            calls.append(kwargs)
            return "stale_start"
        monkeypatch.setattr(
            apns_liveactivity, "clear_live_activity_offer", _fake_clear)

        await dispatch._clear_live_activity_offer(driver.id)

        await db.refresh(driver)
        assert not calls, "a clear with no live card must not push at all"
        assert driver.apns_la_start_token == "healthy-start", (
            "the start token is the seed for the NEXT offer's start push — "
            "a card that was never up must never cost it")
