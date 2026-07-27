"""Tests for masked rider<->driver calling (routers/masked_calls.py) and
guest-SMS phone hygiene (services/sms_service.py)."""

import json

import pytest
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio

_PROXY_NUMBER = "+12065550100"  # TWILIO_PROXY_PHONE_NUMBER set in conftest


def _headers(token: str) -> dict:
    from tests.conftest import _make_auth_headers

    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _get_masked_contact(client, trip_id, role, token):
    return await client.get(
        f"/trips/{trip_id}/masked-contact?role={role}",
        headers=_headers(token),
    )


# ── masked-contact endpoint ─────────────────────────────────────────────


async def test_masked_contact_returns_proxy_number_never_real_number(
    client: AsyncClient, test_rider, test_driver, test_trip,
):
    """Rider gets the Twilio proxy number + extension, never the driver's
    real phone number."""
    rider, rider_token = test_rider
    driver, _ = test_driver

    resp = await _get_masked_contact(client, test_trip.id, "rider", rider_token)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["phone_number"] == _PROXY_NUMBER
    assert data["extension"].isdigit() and len(data["extension"]) == 6
    assert data["expires_in"] > 0
    # The counterparty's (and caller's) real numbers must not appear anywhere.
    blob = json.dumps(data)
    assert driver.phone not in blob
    assert rider.phone not in blob


async def test_masked_contact_driver_side(
    client: AsyncClient, test_driver, test_trip,
):
    _, driver_token = test_driver
    resp = await _get_masked_contact(client, test_trip.id, "driver", driver_token)
    assert resp.status_code == 200, resp.text
    assert resp.json()["phone_number"] == _PROXY_NUMBER


async def test_masked_contact_rejects_non_party(
    client: AsyncClient, test_rider, test_trip,
):
    """A rider cannot claim the driver role (and vice versa) — 403."""
    _, rider_token = test_rider
    resp = await _get_masked_contact(client, test_trip.id, "driver", rider_token)
    assert resp.status_code == 403


async def test_masked_contact_rejects_inactive_trip(
    client: AsyncClient, test_rider, test_trip, db,
):
    """Completed/cancelled trips cannot be called — 409."""
    _, rider_token = test_rider
    test_trip.status = "completed"
    db.add(test_trip)
    await db.commit()

    resp = await _get_masked_contact(client, test_trip.id, "rider", rider_token)
    assert resp.status_code == 409


async def test_masked_contact_requires_auth(client: AsyncClient, test_trip):
    resp = await client.get(f"/trips/{test_trip.id}/masked-contact?role=rider")
    assert resp.status_code in (401, 403, 422)


# ── bridge webhook (TwiML) ──────────────────────────────────────────────


async def test_bridge_prompts_for_extension_without_digits(client: AsyncClient):
    resp = await client.post("/voice/bridge", data={})
    assert resp.status_code == 200
    assert "<Gather" in resp.text
    assert 'numDigits="6"' in resp.text
    assert "<Dial" not in resp.text


async def test_bridge_dials_counterparty_with_masked_caller_id(
    client: AsyncClient, test_rider, test_driver, test_trip,
):
    """With a valid extension the bridge returns <Dial> to the counterparty's
    real number with callerId = the proxy number."""
    rider, rider_token = test_rider
    driver, _ = test_driver

    contact = (
        await _get_masked_contact(client, test_trip.id, "rider", rider_token)
    ).json()

    resp = await client.post(
        "/voice/bridge",
        data={"Digits": contact["extension"], "From": rider.phone},
    )
    assert resp.status_code == 200
    assert "<Dial" in resp.text
    assert f'callerId="{_PROXY_NUMBER}"' in resp.text
    assert driver.phone in resp.text  # bridge target (server-side TwiML only)
    # The caller's own number is never dialed/echoed.
    assert f">{rider.phone}<" not in resp.text


async def test_bridge_rejects_unknown_extension(client: AsyncClient):
    resp = await client.post(
        "/voice/bridge", data={"Digits": "000000", "From": "+12065559999"},
    )
    assert resp.status_code == 200
    assert "<Dial" not in resp.text
    assert "<Hangup" in resp.text


async def test_bridge_rejects_wrong_caller(
    client: AsyncClient, test_rider, test_trip,
):
    """An extension is only usable from the phone it was issued to."""
    rider, rider_token = test_rider
    contact = (
        await _get_masked_contact(client, test_trip.id, "rider", rider_token)
    ).json()

    resp = await client.post(
        "/voice/bridge",
        data={"Digits": contact["extension"], "From": "+19998887777"},
    )
    assert resp.status_code == 200
    assert "<Dial" not in resp.text


async def test_bridge_rejects_inactive_trip(
    client: AsyncClient, test_rider, test_trip, db,
):
    rider, rider_token = test_rider
    contact = (
        await _get_masked_contact(client, test_trip.id, "rider", rider_token)
    ).json()

    test_trip.status = "cancelled"
    db.add(test_trip)
    await db.commit()

    resp = await client.post(
        "/voice/bridge",
        data={"Digits": contact["extension"], "From": rider.phone},
    )
    assert resp.status_code == 200
    assert "<Dial" not in resp.text


# ── guest SMS hygiene ───────────────────────────────────────────────────


class _GuestTrip:
    id = 77
    guest_phone = "+12065550111"
    guest_lang = "en"
    guest_first_name = "Alex"
    guest_last_name = "Guest"
    pickup_address = "100 Main St, Orlando, FL"
    dropoff_address = "200 Oak Ave, Orlando, FL"
    fare = 18.25


class _Driver:
    first_name = "Dan"
    last_name = "Wheel"
    phone = "+12055559876"  # must NEVER appear in the SMS text


class _Vehicle:
    year = "2021"
    make = "Toyota"
    model = "Camry"
    color = "Black"
    plate = "XYZ-123"
    license_plate = None


async def test_guest_driver_assigned_sms_contains_no_phone(monkeypatch):
    from services import sms_service

    sent = {}

    async def fake_dispatch(db, trip_id, event_type, phone_number, message):
        sent["message"] = message

    monkeypatch.setattr(sms_service, "_dispatch", fake_dispatch)

    for lang in ("en", "es"):
        trip = _GuestTrip()
        trip.guest_lang = lang
        await sms_service.notify_guest_driver_assigned(
            None, trip, _Driver(), _Vehicle(),
        )
        msg = sent["message"]
        assert _Driver.phone not in msg
        assert "2055559876" not in msg
        assert "Call/text" not in msg
        assert "Contacto:" not in msg
        # Driver identity info is still present.
        assert "Dan Wheel" in msg
        assert "XYZ-123" in msg


async def test_guest_sms_templates_have_no_phone_placeholder():
    from services import sms_service

    for event, bucket in sms_service._TPL.items():
        for lang, tpl in bucket.items():
            assert "{driver_phone}" not in tpl, f"{event}/{lang}"
