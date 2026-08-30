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


# ── callback calling ("we call you") ─────────────────────────────────────
#
# POST /trips/{id}/callback-call places an OUTBOUND Twilio call to the
# caller's registered number; /voice/callback then bridges to the
# counterparty. No extension, no real numbers in any response.


class _FakeTwilioCall:
    sid = "CAtest1234567890"


def _patch_twilio(monkeypatch):
    """Give the endpoint fake credentials + a fake Twilio REST client.

    Returns the list of calls.create() kwargs for assertions.
    """
    from routers import masked_calls

    monkeypatch.setattr(masked_calls, "TWILIO_ACCOUNT_SID", "ACtest")
    monkeypatch.setattr(masked_calls, "TWILIO_AUTH_TOKEN", "tokentest")

    created = []

    class _FakeCalls:
        def create(self, **kwargs):
            created.append(kwargs)
            return _FakeTwilioCall()

    class _FakeClient:
        def __init__(self, *a, **k):
            self.calls = _FakeCalls()

    import twilio.rest

    monkeypatch.setattr(twilio.rest, "Client", _FakeClient)
    return created


def _token_from_url(url: str) -> str:
    from urllib.parse import parse_qs, urlparse

    return parse_qs(urlparse(url).query)["token"][0]


async def test_callback_call_rings_the_caller_never_exposes_numbers(
    client: AsyncClient, test_rider, test_driver, test_trip, monkeypatch,
):
    created = _patch_twilio(monkeypatch)
    rider, rider_token = test_rider
    driver, _ = test_driver

    resp = await client.post(
        f"/trips/{test_trip.id}/callback-call?role=rider",
        headers=_headers(rider_token),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"status": "calling"}
    # No real phone number anywhere in the response.
    blob = json.dumps(resp.json())
    assert rider.phone not in blob and driver.phone not in blob

    # Twilio rings the CALLER's registered number from the proxy number.
    assert len(created) == 1
    assert created[0]["to"] == rider.phone
    assert created[0]["from_"] == _PROXY_NUMBER
    assert "/voice/callback?token=" in created[0]["url"]


async def test_callback_call_driver_side_rings_the_driver(
    client: AsyncClient, test_driver, test_trip, monkeypatch,
):
    created = _patch_twilio(monkeypatch)
    driver, driver_token = test_driver

    resp = await client.post(
        f"/trips/{test_trip.id}/callback-call?role=driver",
        headers=_headers(driver_token),
    )
    assert resp.status_code == 200, resp.text
    assert created[0]["to"] == driver.phone


async def test_callback_call_rejects_non_party(
    client: AsyncClient, test_rider, test_trip, monkeypatch,
):
    created = _patch_twilio(monkeypatch)
    _, rider_token = test_rider
    resp = await client.post(
        f"/trips/{test_trip.id}/callback-call?role=driver",
        headers=_headers(rider_token),
    )
    assert resp.status_code == 403
    assert created == []  # no Twilio call placed


async def test_callback_call_rejects_inactive_trip(
    client: AsyncClient, test_rider, test_trip, db, monkeypatch,
):
    created = _patch_twilio(monkeypatch)
    _, rider_token = test_rider
    test_trip.status = "completed"
    db.add(test_trip)
    await db.commit()

    resp = await client.post(
        f"/trips/{test_trip.id}/callback-call?role=rider",
        headers=_headers(rider_token),
    )
    assert resp.status_code == 409
    assert created == []


async def test_callback_call_503_without_twilio_credentials(
    client: AsyncClient, test_rider, test_trip,
):
    """No TWILIO_ACCOUNT_SID/AUTH_TOKEN configured → clean 503, never a 500."""
    _, rider_token = test_rider
    resp = await client.post(
        f"/trips/{test_trip.id}/callback-call?role=rider",
        headers=_headers(rider_token),
    )
    assert resp.status_code == 503


async def test_callback_webhook_bridges_to_counterparty_once(
    client: AsyncClient, test_rider, test_driver, test_trip, monkeypatch,
):
    created = _patch_twilio(monkeypatch)
    rider, rider_token = test_rider
    driver, _ = test_driver

    await client.post(
        f"/trips/{test_trip.id}/callback-call?role=rider",
        headers=_headers(rider_token),
    )
    token = _token_from_url(created[0]["url"])

    resp = await client.post(f"/voice/callback?token={token}", data={})
    assert resp.status_code == 200
    assert "<Dial" in resp.text
    assert f'callerId="{_PROXY_NUMBER}"' in resp.text
    assert driver.phone in resp.text  # bridge target (server-side TwiML only)
    # The caller's own number is never dialed/echoed.
    assert f">{rider.phone}<" not in resp.text

    # One-shot: a replay of the same webhook URL is rejected.
    replay = await client.post(f"/voice/callback?token={token}", data={})
    assert "<Dial" not in replay.text
    assert "<Hangup" in replay.text


async def test_callback_webhook_rejects_unknown_token(client: AsyncClient):
    resp = await client.post("/voice/callback?token=garbage", data={})
    assert resp.status_code == 200
    assert "<Dial" not in resp.text
    assert "<Hangup" in resp.text


async def test_callback_webhook_rejects_inactive_trip(
    client: AsyncClient, test_rider, test_trip, db, monkeypatch,
):
    created = _patch_twilio(monkeypatch)
    _, rider_token = test_rider
    await client.post(
        f"/trips/{test_trip.id}/callback-call?role=rider",
        headers=_headers(rider_token),
    )
    token = _token_from_url(created[0]["url"])

    test_trip.status = "cancelled"
    db.add(test_trip)
    await db.commit()

    resp = await client.post(f"/voice/callback?token={token}", data={})
    assert resp.status_code == 200
    assert "<Dial" not in resp.text
