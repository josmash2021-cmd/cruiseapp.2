"""GET /trips/{id} answers a driver the trip was offered to (2026-10-28).

The driver app verifies here after a refused accept and after a dispatch
reassign. A 403 read as "cannot tell", and the app kept a trip that was
never its own. A driver with an offer row sees the trip's real state; a
driver with no connection to the trip is still refused.
"""
import pytest

from models.database import DispatchOffer, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def test_offered_driver_can_read_the_trip_state(client, db, test_trip, test_driver):
    driver, token = test_driver
    test_trip.status = "requested"
    test_trip.driver_id = None  # the race was lost: nobody, or somebody else
    db.add(DispatchOffer(trip_id=test_trip.id, driver_id=driver.id, status="pending"))
    await db.commit()

    resp = await client.get(f"/trips/{test_trip.id}", headers=_h(token))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "requested"
    assert body["driver_id"] is None


async def test_unrelated_driver_is_still_refused(client, db, test_trip, test_driver):
    driver, token = test_driver
    test_trip.driver_id = None
    await db.commit()

    resp = await client.get(f"/trips/{test_trip.id}", headers=_h(token))
    assert resp.status_code == 403
