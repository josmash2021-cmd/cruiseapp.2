"""App Store review rider (owner decision 2026-10-29): no charge, and the
driver who finishes the ride is paid his share by the platform, once."""
import pytest

from models.database import Trip
from services.completed_trip_settlement import settle_completed_trip

pytestmark = pytest.mark.asyncio


def _trip(rider, driver, **kw):
    base = dict(
        rider_id=rider.id, driver_id=driver.id,
        pickup_address="Origin", dropoff_address="Destination",
        pickup_lat=33.5, pickup_lng=-86.8, dropoff_lat=33.55, dropoff_lng=-86.85,
        vehicle_type="standard", status="completed", fare=20.0,
        payment_status="unpaid", driver_share_rate=0.90,
    )
    base.update(kw)
    return Trip(**base)


async def test_review_rider_trip_pays_the_driver_once(db, test_rider, test_driver, monkeypatch):
    rider, _ = test_rider
    driver, _ = test_driver
    monkeypatch.setenv("TEST_MODE_RIDER_IDS", str(rider.id))
    before = float(driver.pending_balance or 0)
    trip = _trip(rider, driver)
    db.add(trip)
    await db.commit()

    await settle_completed_trip(db, trip)
    await db.commit()
    await settle_completed_trip(db, trip)  # retry must not pay twice
    await db.commit()
    await db.refresh(driver)
    await db.refresh(trip)

    assert trip.payment_status == "not_required"
    assert trip.funding_source == "review_test"
    assert trip.platform_credit_cents == 1800
    assert round(float(driver.pending_balance) - before, 2) == 18.00
    assert round(float(trip.driver_earnings), 2) == 18.00


async def test_normal_rider_is_untouched(db, test_rider, test_driver, monkeypatch):
    rider, _ = test_rider
    driver, _ = test_driver
    monkeypatch.setenv("TEST_MODE_RIDER_IDS", "999999")
    trip = _trip(rider, driver)
    db.add(trip)
    await db.commit()
    await settle_completed_trip(db, trip)
    assert trip.funding_source is None
    assert trip.payment_status == "unpaid"


async def test_review_rider_with_real_hold_is_untouched(db, test_rider, test_driver, monkeypatch):
    rider, _ = test_rider
    driver, _ = test_driver
    monkeypatch.setenv("TEST_MODE_RIDER_IDS", str(rider.id))
    trip = _trip(rider, driver, payment_status="held", stripe_payment_intent_id="pi_real")
    db.add(trip)
    await db.commit()
    await settle_completed_trip(db, trip)
    assert trip.funding_source is None


async def test_live_priced_review_trip_still_pays_the_driver(db, test_rider, test_driver, monkeypatch):
    """Live pricing (2026-10-26) stamps every booking funding_source="rider".
    That stamp must not switch test mode off (trip 780 era: the driver of a
    review-rider ride would have been paid nothing)."""
    rider, _ = test_rider
    driver, _ = test_driver
    monkeypatch.setenv("TEST_MODE_RIDER_IDS", str(rider.id))
    before = float(driver.pending_balance or 0)
    trip = _trip(rider, driver, funding_source="rider")
    db.add(trip)
    await db.commit()

    await settle_completed_trip(db, trip)
    await db.commit()
    await db.refresh(driver)

    assert trip.funding_source == "review_test"
    assert trip.payment_status == "not_required"
    assert round(float(driver.pending_balance) - before, 2) == 18.00


async def test_review_rider_cruise_cash_trip_is_untouched(db, test_rider, test_driver, monkeypatch):
    rider, _ = test_rider
    driver, _ = test_driver
    monkeypatch.setenv("TEST_MODE_RIDER_IDS", str(rider.id))
    trip = _trip(rider, driver, funding_source="cruise_cash")
    db.add(trip)
    await db.commit()
    await settle_completed_trip(db, trip)
    assert trip.funding_source == "cruise_cash"


def test_scheduler_never_holds_a_review_rider_card():
    """A review-rider reservation with no card used to be cancelled as
    payment_declined the moment it entered the dispatch window (trip 780)."""
    from pathlib import Path
    src = (Path(__file__).resolve().parents[1] / "main.py").read_text(encoding="utf-8")
    anchor = src.index("_needs_hold = bool(trip.stripe_payment_intent_id)")
    window = src[anchor:anchor + 700]
    assert "trip.rider_id in review_tester_ids()" in window
    assert "_needs_hold = False" in window
