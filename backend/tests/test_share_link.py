"""Shared trip links: they must resolve, and they must stop when the trip does."""

import os

import pytest

pytestmark = pytest.mark.asyncio


async def test_tracking_page_is_actually_served(client):
    """The link a rider sends must not land on a JSON error.

    Regression: the handler joined "static" onto its own routers/ directory,
    but the page lives one level up in backend/static, so every shared link
    404'd in production. The person the rider sent it to — often someone
    checking they got home — saw {"detail":"Tracking page not found"}.
    """
    resp = await client.get("/track/sometokenthatdoesnotexist")
    # Unknown token still serves the page; the page resolves the token via
    # the API and shows its own not-found state.
    assert resp.status_code == 200, resp.text
    assert "text/html" in resp.headers.get("content-type", "")


def test_page_file_is_where_the_handler_looks():
    """Pins the layout the handler depends on."""
    here = os.path.dirname(os.path.abspath(__file__))
    backend = os.path.dirname(here)
    assert os.path.isfile(os.path.join(backend, "static", "shared_trip.html"))


@pytest.mark.parametrize(
    "status,finished",
    [
        ("in_trip", False),
        ("driver_en_route", False),
        ("arrived", False),
        ("completed", True),
        ("cancelled", True),
        # driver-app spellings must normalise, or a link stays alive
        ("canceled", True),
        ("on_trip", False),
        ("", False),
        (None, False),
    ],
)
def test_share_finished_covers_alias_spellings(status, finished):
    from routers.trips import _is_share_finished

    assert _is_share_finished(status) is finished


async def test_location_stops_once_the_trip_ends(client, test_trip, db):
    """The privacy one: a finished trip must not keep streaming the driver.

    Before this, the link checked only its 24-hour expiry, so after drop-off
    it followed the DRIVER through their next fares and home, for anyone
    holding the URL.
    """
    from datetime import datetime, timedelta, timezone

    test_trip.share_token = "tok_live_share_test"
    test_trip.share_expires_at = datetime.now(timezone.utc) + timedelta(hours=24)
    test_trip.status = "in_trip"
    await db.commit()

    live = await client.get(f"/trips/shared/{test_trip.share_token}/location")
    assert live.status_code == 200, "an active trip should still resolve"

    test_trip.status = "completed"
    await db.commit()

    ended = await client.get(f"/trips/shared/{test_trip.share_token}/location")
    assert ended.status_code == 410, (
        f"completed trip still served location: {ended.status_code} {ended.text}"
    )
