"""A lost accept race retires the loser's offer (2026-10-28).

The 409 alone left the offer row pending, so the driver app's next poll
rang the same card again, forever ("sale en bucle").
"""
import pytest

from models.database import DispatchOffer
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def test_lost_race_answers_409_and_expires_the_offer(client, db, test_trip, test_driver):
    driver, token = test_driver
    test_trip.status = "requested"
    test_trip.driver_id = None
    mine = DispatchOffer(trip_id=test_trip.id, driver_id=driver.id, status="pending")
    winner = DispatchOffer(trip_id=test_trip.id, driver_id=driver.id + 500, status="accepted")
    db.add_all([mine, winner])
    await db.commit()
    await db.refresh(mine)

    resp = await client.post(
        f"/dispatch/driver/accept?offer_id={mine.id}&driver_id={driver.id}",
        headers=_h(token),
    )
    assert resp.status_code == 409, resp.text
    assert "another driver" in resp.json()["detail"]

    await db.refresh(mine)
    assert mine.status == "expired"
    await db.refresh(test_trip)
    assert test_trip.driver_id is None
