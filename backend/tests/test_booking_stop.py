"""Booking-time stop ("+" on the addresses page) — end to end (2026-10-02).

The rider's stop travels as stop_lat/stop_lng/stop_address on BOTH create
paths (POST /trips and /dispatch/request) and lands in `trips.stops` with
the SAME JSON shape the mid-trip endpoint writes — so the driver offer
(SSE/pending carry `stops` via _trip_dict, the push carries flat strings)
can pin it and route pickup → stop → dropoff as one continuous line.

The two failure modes this pins:
  1. Trip(**data) receives the flat stop_* kwargs → TypeError → 500 at
     booking (there are no such columns — the helper must pop them).
  2. The offer push leaves the stop out → the tap-card draws the ride
     without it even though the trip row knows about it.
"""

import asyncio
import json

import pytest

from main import Trip
from models.schemas import CreateTripIn, DispatchRequestIn
from utils.helpers import booking_stops_json

pytestmark = pytest.mark.asyncio

_STOP = dict(stop_lat=25.7700, stop_lng=-80.1950, stop_address="7 Midway Rd")


def _base(**extra):
    return dict(
        rider_id=1,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=25.5,
        **extra,
    )


async def test_helper_folds_stop_into_stops_json():
    data = _base(**_STOP)
    booking_stops_json(data)
    # Flat fields popped — Trip(**data) must never see them.
    assert "stop_lat" not in data
    assert "stop_lng" not in data
    assert "stop_address" not in data
    stops = json.loads(data["stops"])
    assert len(stops) == 1
    s = stops[0]
    assert s["lat"] == _STOP["stop_lat"] and s["lng"] == _STOP["stop_lng"]
    assert s["label"] == "7 Midway Rd"
    # Booking-time: the stop's miles are already in the fare — no surcharge.
    assert s["extra_cents"] == 0


async def test_helper_without_stop_or_invalid_coords_writes_nothing():
    data = _base()
    booking_stops_json(data)
    assert "stops" not in data

    data = _base(stop_lat=200.0, stop_lng=0.0, stop_address="Nowhere")
    booking_stops_json(data)
    assert "stops" not in data
    # …but the flat fields are STILL popped — an invalid stop must not 500
    # the booking either.
    assert "stop_lat" not in data


async def test_create_trip_schema_to_model():
    body = CreateTripIn(**_base(**_STOP))
    data = body.model_dump()
    booking_stops_json(data)
    trip = Trip(**data)  # the exact call create_trip makes
    assert json.loads(trip.stops)[0]["lat"] == _STOP["stop_lat"]


async def test_dispatch_request_schema_to_model():
    body = DispatchRequestIn(**_base(**_STOP))
    data = body.model_dump()
    booking_stops_json(data)
    trip = Trip(**data)  # the exact call /dispatch/request makes
    assert json.loads(trip.stops)[0]["label"] == "7 Midway Rd"


async def test_offer_push_data_carries_the_stop(db, test_trip, test_driver, monkeypatch):
    """The instant tap-card is built from the push payload alone — the stop
    must ride it as flat strings (the SSE/pending channels carry `stops`
    via _trip_dict already)."""
    import routers.dispatch as dispatch

    driver, _ = test_driver
    test_trip.driver_id = None
    test_trip.status = "requested"
    test_trip.stops = json.dumps([{
        "lat": 25.7700, "lng": -80.1950, "label": "7 Midway Rd",
        "extra_cents": 0, "added_at": "2026-10-02T00:00:00+00:00",
    }])
    await db.commit()

    sent = []

    async def _spy(token, title=None, body=None, data=None, **kw):
        sent.append({"token": token, "data": data})

    monkeypatch.setattr(dispatch, "_send_fcm_push_async", _spy)

    await dispatch._send_offer_to_driver(db, test_trip, driver, "Rider", "", "")
    # The push goes out via _safe_create_task — let the loop run it.
    for _ in range(10):
        await asyncio.sleep(0)
        if sent:
            break

    assert sent, "the offer push never fired"
    data = sent[0]["data"]
    assert data["stop_lat"] == "25.77"
    assert data["stop_lng"] == "-80.195"
    assert data["stop_address"] == "7 Midway Rd"
