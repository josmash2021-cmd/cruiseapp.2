"""A driver can read his trip doc from the first second (2026-11-03).

firestore.rules lets a driver read and write trips/sql_<id> only through its
driverId or accessUids. The accept mirror that writes driverId runs AFTER the
HTTP answer, and the app arms its trip listener the moment the answer lands —
a listener denied once never comes back (it carries rider_confirmed_pickup
and the rider's route changes for the whole trip). So every path that gives
a driver a trip grants his uid BEFORE it answers.
"""
from datetime import datetime, timedelta, timezone

import pytest

import firestore_sync
from models.database import DispatchOffer, Trip, Vehicle
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


class _FakeFirestore:
    """Records the grant; every other mirror call is a no-op — no test may
    reach a real Firestore."""

    def __init__(self):
        self.grants = []

    async def grant_trip_access_now(self, trip_id, driver_id, timeout=3.0):
        self.grants.append((trip_id, driver_id))
        return True

    def __getattr__(self, name):
        return lambda *a, **k: None


@pytest.fixture
def fs(monkeypatch):
    from routers import dispatch, scheduled, trips
    fake = _FakeFirestore()
    for mod in (dispatch, scheduled, trips):
        monkeypatch.setattr(mod, "firestore_sync", fake)
        monkeypatch.setattr(mod, "_HAS_FIRESTORE", True)
    # Fire-and-forget tasks share the SQLite connection (see
    # test_acceptance_rate.py) — and a grant left to a task would not be
    # "before the answer" anyway, so it must not count.
    monkeypatch.setattr(dispatch, "_safe_create_task",
                        lambda coro, **kw: (coro.close(), None)[1])
    return fake


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _trip(db, rider, **kw):
    now = datetime.now(timezone.utc)
    trip = Trip(
        rider_id=rider.id, pickup_address="123 Test St", dropoff_address="456 Dest Ave",
        pickup_lat=25.7617, pickup_lng=-80.1918, dropoff_lat=25.7750, dropoff_lng=-80.2000,
        fare=25.50, vehicle_type="standard", status="requested", payment_status="held",
        created_at=now,
    )
    for k, v in kw.items():
        setattr(trip, k, v)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


async def test_accepting_an_offer(client, db, test_rider, test_driver, fs):
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _trip(db, rider)
    offer = DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="pending")
    db.add(offer)
    await db.commit()
    await db.refresh(offer)

    resp = await client.post(
        f"/dispatch/driver/accept?offer_id={offer.id}&driver_id={driver.id}", headers=_h(token))

    assert resp.status_code == 200, resp.text
    assert fs.grants == [(trip.id, driver.id)]


async def test_claiming_off_the_board(client, db, test_rider, test_driver, fs):
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _trip(db, rider)

    resp = await client.post(
        f"/dispatch/claim?trip_id={trip.id}&driver_id={driver.id}", headers=_h(token))

    assert resp.status_code == 200, resp.text
    assert fs.grants == [(trip.id, driver.id)]


async def test_accepting_without_an_offer(client, db, test_rider, test_driver, fs):
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _trip(db, rider, pickup_lat=25.7700)

    resp = await client.post(
        f"/trips/{trip.id}/accept", json={"driver_id": driver.id}, headers=_h(token))

    assert resp.status_code == 200, resp.text
    assert fs.grants == [(trip.id, driver.id)]


async def test_claiming_a_reservation(client, db, test_rider, test_driver, fs, monkeypatch):
    from routers import dispatch as D
    monkeypatch.setattr(D, "GOOGLE_MAPS_API_KEY", "")  # state fails open
    rider, _ = test_rider
    driver, token = test_driver
    driver.is_verified = True
    driver.verification_status = "approved"
    driver.is_online = True
    db.add(Vehicle(user_id=driver.id, make="Toyota", model="Camry", year=2022,
                   plate="GRANT1", vehicle_type="standard", is_active=True,
                   approval_status="approved"))
    now = datetime.now(timezone.utc)
    trip = await _trip(db, rider, status="scheduled", payment_status="unpaid",
                       scheduled_at=now + timedelta(hours=5),
                       created_at=now - timedelta(hours=3))

    resp = await client.post(f"/scheduled-trips/{trip.id}/claim", headers=_h(token))

    assert resp.status_code == 200, resp.text
    assert fs.grants == [(trip.id, driver.id)]


def test_the_grant_writes_his_uid_into_access_uids(monkeypatch):
    writes = []

    class _Doc:
        def __init__(self, path):
            self.path = path

        def set(self, data, merge=False, timeout=None):
            writes.append((self.path, data, merge))

    class _Coll:
        def __init__(self, name):
            self.name = name

        def document(self, doc_id):
            return _Doc(f"{self.name}/{doc_id}")

    class _Client:
        def collection(self, name):
            return _Coll(name)

    monkeypatch.setattr(firestore_sync, "_ensure_init", lambda *a, **k: None)
    monkeypatch.setattr(firestore_sync, "_db", _Client())

    assert firestore_sync.grant_trip_access(12, 34) is True
    (path, data, merge), = writes
    assert path == "trips/sql_12" and merge is True
    union = data["accessUids"]
    assert type(union).__name__ == "ArrayUnion"
    assert list(union.values) == ["user_34"]
