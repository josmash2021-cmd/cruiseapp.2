"""Guardians for the RIDER trip Live Activity channel (apns_liveactivity
ride card + trips._push_ride_live_activity).

The card on the rider's lock screen must track the trip even with the app
killed. Three silent-death modes live here, mirrored from the offer side:

  * the payload drifts from CruiseRideActivityAttributes.ContentState and
    Apple/ActivityKit drops every push — caught by inspecting what
    update_ride_live_activity posts (all eight content-state keys, the
    topic, the event)
  * a dead channel (400/410) is never cleared and every later update aims
    at a token that cannot land — caught by asserting the column is nulled
  * the server claiming a pickup ETA it cannot know (no driver position)
    — caught by asserting en_route never produces a server push at all
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
    """A working JWT and a captured wire, per test."""
    _FakeClient.posts = []
    _FakeClient.next_status = 200
    monkeypatch.setattr(apns_liveactivity, "_apns_jwt", lambda: "test-jwt")
    monkeypatch.setattr(apns_liveactivity.httpx, "AsyncClient", _FakeClient)
    return _FakeClient.posts


class TestTheRidePayload:
    """What goes on the wire is the whole contract with ActivityKit."""

    async def test_update_carries_every_content_state_key(self, captured):
        outcome = await apns_liveactivity.update_ride_live_activity(
            ride_token="ride-token-1",
            phase="on_trip",
            started_at=1700000000,
            dropoff_at=1700000900,
            dropoff_address="Canopy Dr",
            driver_name="Arvell",
            driver_rating="5.0",
            driver_photo_url="https://x.test/p.jpg",
            car_image="CarSuv",
        )
        assert outcome is None
        (post,) = captured
        assert post["url"].endswith("/3/device/ride-token-1")
        aps = post["json"]
        assert aps["event"] == "update"
        cs = aps["content-state"]
        # CruiseRideActivityAttributes.ContentState decodes exactly these —
        # a rename on either side silently drops the field.
        for key in ("phase", "startedAt", "dropoffAt", "dropoffAddress",
                    "driverName", "driverRating", "driverPhotoUrl",
                    "carImage"):
            assert key in cs, f"content-state is missing {key!r}"
        assert cs["phase"] == "on_trip"
        assert cs["carImage"] == "CarSuv"
        assert post["headers"]["apns-topic"] == (
            f"{apns_liveactivity._BUNDLE}.push-type.liveactivity")
        assert post["headers"]["apns-push-type"] == "liveactivity"
        # Silent repaint: an alert on every ETA tick would be harassment.
        assert "alert" not in aps

    async def test_arrived_is_the_one_push_with_an_alert(self, captured):
        await apns_liveactivity.update_ride_live_activity(
            ride_token="r1", phase="arrived",
            started_at=1700000000, dropoff_at=1700000000,
            alert={"title": "Your driver is here", "body": "...", "sound": "default"},
        )
        (post,) = captured
        assert post["json"]["alert"]["title"] == "Your driver is here"

    async def test_end_event_carries_a_final_state(self, captured):
        outcome = await apns_liveactivity.end_ride_live_activity(
            ride_token="ride-token-1")
        assert outcome is None
        (post,) = captured
        assert post["json"]["event"] == "end"
        assert "content-state" in post["json"]

    async def test_no_token_and_no_creds_are_silent_noops(self, captured):
        assert await apns_liveactivity.update_ride_live_activity(
            ride_token=None, phase="arrived",
            started_at=0, dropoff_at=0) is None
        assert not captured


class TestAStaleRideChannel:
    """400/410 means the channel is dead — the DB must stop aiming at it."""

    @pytest.mark.parametrize("status", [400, 410])
    async def test_outcome_is_stale(self, captured, status):
        _FakeClient.next_status = status
        assert await apns_liveactivity.update_ride_live_activity(
            ride_token="dead", phase="arrived",
            started_at=0, dropoff_at=0) == "stale"
        assert await apns_liveactivity.end_ride_live_activity(
            ride_token="dead") == "stale"


class TestTheTripStatusHook:
    """trips._push_ride_live_activity — which transitions repaint the card."""

    async def _setup(self, db, test_trip, test_driver, test_rider):
        trip = test_trip
        driver, _ = test_driver
        rider, _ = test_rider
        driver.first_name = "Arvell"
        driver.photo_url = "photos/d.jpg"
        driver.average_rating = 5.0
        trip.rider_id = rider.id
        trip.driver_id = driver.id
        trip.pickup_lat, trip.pickup_lng = 25.7, -80.3
        trip.dropoff_lat, trip.dropoff_lng = 25.9, -80.2
        trip.dropoff_address = "Canopy Dr"
        trip.vehicle_type = "black"
        rider.apns_la_ride_token = "ride-token-1"
        await db.commit()
        return trip, rider

    def _capture(self, monkeypatch):
        calls = {"update": [], "end": []}

        async def _upd(**kw):
            calls["update"].append(kw)
            return None

        async def _end(**kw):
            calls["end"].append(kw)
            return None

        monkeypatch.setattr(apns_liveactivity, "apns_configured", lambda: True)
        monkeypatch.setattr(apns_liveactivity, "update_ride_live_activity", _upd)
        monkeypatch.setattr(apns_liveactivity, "end_ride_live_activity", _end)
        return calls

    async def test_arrived_repaints_with_alert(
            self, monkeypatch, db, test_trip, test_driver, test_rider):
        from routers.trips import _push_ride_live_activity
        await self._setup(db, test_trip, test_driver, test_rider)
        calls = self._capture(monkeypatch)

        await _push_ride_live_activity(test_trip.id, "arrived")

        assert len(calls["update"]) == 1
        kw = calls["update"][0]
        assert kw["phase"] == "arrived"
        assert kw["ride_token"] == "ride-token-1"
        assert kw["driver_name"] == "Arvell"
        assert kw["driver_rating"] == "5.0"
        assert kw["car_image"] == "CarSuv"  # black tier → SUV art
        assert kw["dropoff_address"] == "Canopy Dr"
        assert kw["alert"] is not None
        assert not calls["end"]

    async def test_in_trip_repaints_without_alert(
            self, monkeypatch, db, test_trip, test_driver, test_rider):
        from routers.trips import _push_ride_live_activity
        await self._setup(db, test_trip, test_driver, test_rider)
        calls = self._capture(monkeypatch)

        await _push_ride_live_activity(test_trip.id, "in_trip")

        assert len(calls["update"]) == 1
        kw = calls["update"][0]
        assert kw["phase"] == "on_trip"
        assert kw["alert"] is None
        assert kw["dropoff_at"] > kw["started_at"]  # a real ETA, not zero

    async def test_en_route_never_comes_from_the_server(
            self, monkeypatch, db, test_trip, test_driver, test_rider):
        """The pickup ETA needs the driver's live position, which the app
        has and the server does not — a server-side en_route card would
        show a number invented from thin air."""
        from routers.trips import _push_ride_live_activity
        await self._setup(db, test_trip, test_driver, test_rider)
        calls = self._capture(monkeypatch)

        await _push_ride_live_activity(test_trip.id, "driver_en_route")
        await _push_ride_live_activity(test_trip.id, "accepted")

        assert not calls["update"] and not calls["end"]

    async def test_completed_ends_and_stale_clears_the_column(
            self, monkeypatch, db, test_trip, test_driver, test_rider):
        from routers.trips import _push_ride_live_activity
        _, rider = await self._setup(db, test_trip, test_driver, test_rider)
        self._capture(monkeypatch)

        async def _stale(**kw):
            return "stale"

        monkeypatch.setattr(
            apns_liveactivity, "end_ride_live_activity", _stale)

        await _push_ride_live_activity(test_trip.id, "completed")

        await db.refresh(rider)
        assert rider.apns_la_ride_token is None

    async def test_no_token_means_no_work(
            self, monkeypatch, db, test_trip, test_driver, test_rider):
        from routers.trips import _push_ride_live_activity
        trip, rider = await self._setup(db, test_trip, test_driver, test_rider)
        rider.apns_la_ride_token = None
        await db.commit()
        calls = self._capture(monkeypatch)

        await _push_ride_live_activity(trip.id, "arrived")
        assert not calls["update"] and not calls["end"]


class TestRideTokenRegistration:
    """kind=ride_activity lands on its own column — never clobbering the
    driver's offer channels on a user who both drives and rides."""

    def _headers(self, token):
        from tests.conftest import _make_auth_headers
        return {**_make_auth_headers(api_key="test-dispatch-key"),
                "Authorization": f"Bearer {token}"}

    async def test_ride_activity_kind_roundtrip(self, client, db, test_rider):
        rider, token = test_rider
        resp = await client.post(
            "/drivers/live-activity-token",
            headers=self._headers(token),
            json={"kind": "ride_activity", "token": "ride-tok-9"})
        assert resp.status_code == 200, resp.text
        await db.refresh(rider)
        assert rider.apns_la_ride_token == "ride-tok-9"
        # The driver channels are untouched.
        assert rider.apns_la_start_token is None
        assert rider.apns_la_activity_token is None

        # Empty clears.
        resp = await client.post(
            "/drivers/live-activity-token",
            headers=self._headers(token),
            json={"kind": "ride_activity", "token": ""})
        assert resp.status_code == 200
        await db.refresh(rider)
        assert rider.apns_la_ride_token is None

    async def test_an_unknown_kind_is_rejected(self, client, db, test_rider):
        _, token = test_rider
        resp = await client.post(
            "/drivers/live-activity-token",
            headers=self._headers(token),
            json={"kind": "nope", "token": "x"})
        assert resp.status_code == 400
