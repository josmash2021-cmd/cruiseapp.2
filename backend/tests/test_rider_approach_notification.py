from pathlib import Path

import pytest
from pydantic import ValidationError

from models.database import Trip, User
from models.schemas import DriverLocationIn
from services import approach_notifications


pytestmark = pytest.mark.asyncio


class _SessionContext:
    def __init__(self, db):
        self.db = db

    async def __aenter__(self):
        return self.db

    async def __aexit__(self, *_):
        pass


def _install_fakes(db, monkeypatch):
    monkeypatch.setattr(
        approach_notifications, "SessionLocal", lambda: _SessionContext(db)
    )
    calls = []

    async def fake_push(token, **kwargs):
        calls.append((token, kwargs))

    monkeypatch.setattr(
        approach_notifications, "_send_fcm_push_async", fake_push
    )
    return calls


async def _rider(db, name="Rider", locale="es", token="rider-fcm"):
    user = User(
        first_name=name,
        last_name="Approach",
        email=f"{name.lower()}@example.com",
        password_hash="x",
        role="rider",
        status="active",
        locale=locale,
        fcm_token=token,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


async def _approach_trip(db, test_trip, driver, rider, status="driver_en_route"):
    trip = test_trip
    trip.rider_id = rider.id
    trip.driver_id = driver.id
    trip.status = status
    trip.rider_approach_notified_at = None
    await db.commit()
    await db.refresh(trip)
    return trip


async def test_threshold_is_once_per_trip_and_localized_spanish(
    db, test_trip, test_driver, monkeypatch
):
    calls = _install_fakes(db, monkeypatch)
    driver, _ = test_driver
    rider = await _rider(db, locale="es")
    trip = await _approach_trip(db, test_trip, driver, rider)

    await approach_notifications.maybe_notify_rider_approach(driver.id, 120, trip.id)
    await approach_notifications.maybe_notify_rider_approach(driver.id, 120, trip.id)
    await db.refresh(trip)

    assert len(calls) == 1
    token, payload = calls[0]
    assert token == "rider-fcm"
    assert payload["title"] == "Tu conductor está por llegar"
    assert payload["body"] == "Tu driver llega en 2 minutos o menos"
    assert payload["locale"] == "es"
    assert payload["data"] == {
        "type": "driver_arriving",
        "trip_id": str(trip.id),
    }
    assert trip.rider_approach_notified_at is not None


async def test_english_copy(db, test_trip, test_driver, monkeypatch):
    calls = _install_fakes(db, monkeypatch)
    driver, _ = test_driver
    rider = await _rider(db, locale="en")
    trip = await _approach_trip(db, test_trip, driver, rider)

    await approach_notifications.maybe_notify_rider_approach(driver.id, 90, trip.id)

    _, payload = calls[0]
    assert payload["title_en"] == "Your driver is almost here"
    assert payload["body_en"] == "Your driver arrives in 2 minutes or less"
    assert payload["locale"] == "en"


async def test_missing_token_does_not_consume_the_claim(
    db, test_trip, test_driver, monkeypatch
):
    calls = _install_fakes(db, monkeypatch)
    driver, _ = test_driver
    rider = await _rider(db, token=None)
    trip = await _approach_trip(db, test_trip, driver, rider)

    await approach_notifications.maybe_notify_rider_approach(driver.id, 100, trip.id)
    await db.refresh(trip)
    assert calls == []
    assert trip.rider_approach_notified_at is None

    rider.fcm_token = "rider-fcm-later"
    await db.commit()
    await approach_notifications.maybe_notify_rider_approach(driver.id, 100, trip.id)
    assert len(calls) == 1


async def test_rejects_late_eta_arrival_and_other_driver(
    db, test_trip, test_driver, monkeypatch
):
    calls = _install_fakes(db, monkeypatch)
    driver, _ = test_driver
    rider = await _rider(db)
    trip = await _approach_trip(db, test_trip, driver, rider)

    await approach_notifications.maybe_notify_rider_approach(driver.id, 121, trip.id)
    await approach_notifications.maybe_notify_rider_approach(driver.id + 999, 100, trip.id)
    trip.status = "arrived"
    await db.commit()
    await approach_notifications.maybe_notify_rider_approach(driver.id, 100, trip.id)
    await db.refresh(trip)

    assert calls == []
    assert trip.rider_approach_notified_at is None


async def test_trip_context_must_match_before_claiming(
    db, test_trip, test_driver, monkeypatch
):
    calls = _install_fakes(db, monkeypatch)
    driver, _ = test_driver
    rider = await _rider(db)
    trip = await _approach_trip(db, test_trip, driver, rider)

    await approach_notifications.maybe_notify_rider_approach(driver.id, 100, trip.id + 999)
    assert calls == []
    assert trip.rider_approach_notified_at is None

    await approach_notifications.maybe_notify_rider_approach(driver.id, 100, trip.id)
    assert len(calls) == 1


async def test_reassignment_allows_the_new_driver_to_notify(
    db, test_trip, test_driver, monkeypatch
):
    calls = _install_fakes(db, monkeypatch)
    driver, _ = test_driver
    rider = await _rider(db)
    trip = await _approach_trip(db, test_trip, driver, rider)
    await approach_notifications.maybe_notify_rider_approach(driver.id, 110, trip.id)

    other = User(
        first_name="Other",
        last_name="Driver",
        email="other-driver@example.com",
        password_hash="x",
        role="driver",
        status="active",
    )
    db.add(other)
    await db.flush()
    await db.refresh(other)
    trip.driver_id = other.id
    trip.rider_approach_notified_at = None
    await db.commit()

    await approach_notifications.maybe_notify_rider_approach(other.id, 110, trip.id)
    assert len(calls) == 2


def test_schema_and_both_migration_lists():
    assert DriverLocationIn(lat=25.0, lng=-80.0).eta_seconds is None
    assert DriverLocationIn(lat=25.0, lng=-80.0, eta_seconds=120).eta_seconds == 120
    with pytest.raises(ValidationError):
        DriverLocationIn(lat=25.0, lng=-80.0, eta_seconds=-1)

    source = (Path(__file__).parents[1] / "models" / "database.py").read_text(encoding="utf-8")
    assert "rider_approach_notified_at = Column(DateTime(timezone=True), nullable=True)" in source
    assert '("trips", "rider_approach_notified_at", "DATETIME")' in source
    assert '("trips", "rider_approach_notified_at", "TIMESTAMP WITH TIME ZONE")' in source


def test_every_driver_release_resets_the_approach_marker():
    backend = Path(__file__).parents[1]
    expected_counts = {
        "routers/trips.py": 1,
        "routers/dispatch.py": 2,
        "guardian_agent.py": 1,
        "main.py": 1,
        "routers/scheduled.py": 2,
    }
    for relative, count in expected_counts.items():
        source = (backend / relative).read_text(encoding="utf-8")
        assert source.count("rider_approach_notified_at = None") >= count, relative
