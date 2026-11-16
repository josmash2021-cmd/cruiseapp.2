"""Dispatch adds a card to a rider and picks the card a trip is charged to
(owner 2026-11-15, drawing https://claude.ai/artifact/9ajBYu169bo3u3ovcTSf3u).

The number never reaches us: the panel mounts Stripe's card field, Stripe
confirms the SetupIntent in the browser, and the server only files the
resulting card once it checks the setup is this rider's and succeeded.
"""
from unittest.mock import AsyncMock

import pytest
from sqlalchemy import select

from models.database import RiderPaymentMethod, Trip
from routers import admin_rider_cards
from tests.conftest import _make_auth_headers
from tests.test_dispatch_trip_booking import (
    _create_trip, _dispatch_headers, _patch_route, _patch_stripe, _payable_rider,
    _quote_payload, _reload,
)

pytestmark = pytest.mark.asyncio


def _patch_setup(monkeypatch, *, owner, customer, status="succeeded",
                 brand="visa", last4="4242", pm_id="pm_card_panel"):
    calls = {"create": [], "modify": []}

    def _create(**kw):
        calls["create"].append(kw)
        return {"id": "seti_test123", "client_secret": "seti_test123_secret_x"}

    def _retrieve(sid, **kw):
        return {
            "id": sid, "status": status, "customer": customer,
            "metadata": {"rider_id": str(owner), "added_by": "dispatch"},
            "payment_method": {"id": pm_id, "card": {"brand": brand, "last4": last4}},
        }

    def _modify(cid, **kw):
        calls["modify"].append((cid, kw))
        return {"id": cid}

    monkeypatch.setattr("stripe.SetupIntent.create", _create)
    monkeypatch.setattr("stripe.SetupIntent.retrieve", _retrieve)
    monkeypatch.setattr("stripe.Customer.modify", _modify)
    return calls


async def _rows(rider_id):
    from main import SessionLocal
    async with SessionLocal() as s:
        return (await s.execute(select(RiderPaymentMethod).where(
            RiderPaymentMethod.user_id == rider_id).order_by(RiderPaymentMethod.id))).scalars().all()


async def test_card_routes_need_the_panel_session(client, test_rider):
    rider, _ = test_rider
    for path in (f"/admin/users/{rider.id}/card-setup", f"/admin/users/{rider.id}/card-confirm"):
        r = await client.post(path, json={}, headers=_make_auth_headers())
        assert r.status_code in (401, 403), (path, r.status_code)


async def test_setup_opens_a_setup_intent_on_the_riders_customer(client, db, test_rider, monkeypatch):
    rider, _ = test_rider
    rider.stripe_customer_id = "cus_test_rider"
    await db.commit()
    calls = _patch_setup(monkeypatch, owner=rider.id, customer="cus_test_rider")

    r = await client.post(f"/admin/users/{rider.id}/card-setup", headers=_dispatch_headers())
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["client_secret"] == "seti_test123_secret_x"
    assert body["publishable_key"].startswith("pk_live_51T8W4JIO4JMEXI8b")
    kw = calls["create"][0]
    assert kw["customer"] == "cus_test_rider"
    assert kw["usage"] == "off_session"
    assert kw["metadata"] == {"rider_id": str(rider.id), "added_by": "dispatch"}


async def test_setup_is_riders_only(client, test_driver, monkeypatch):
    driver, _ = test_driver
    _patch_setup(monkeypatch, owner=driver.id, customer="cus_x")
    r = await client.post(f"/admin/users/{driver.id}/card-setup", headers=_dispatch_headers())
    assert r.status_code == 404


async def test_confirm_files_the_card_as_the_default(client, db, test_rider, monkeypatch):
    rider, _ = test_rider
    await _payable_rider(db, rider)          # an older default card
    calls = _patch_setup(monkeypatch, owner=rider.id, customer="cus_test_rider")

    r = await client.post(f"/admin/users/{rider.id}/card-confirm", headers=_dispatch_headers(),
                          json={"setup_intent_id": "seti_test123", "consent": True})
    assert r.status_code == 200, r.text
    assert r.json()["display_name"] == "Visa ending in 4242"
    rows = await _rows(rider.id)
    assert [(m.stripe_pm_id, m.is_default) for m in rows] == [
        ("pm_card_test", False), ("pm_card_panel", True)]
    assert calls["modify"] == [
        ("cus_test_rider", {"invoice_settings": {"default_payment_method": "pm_card_panel"}})]

    # Saving it again files nothing twice.
    r = await client.post(f"/admin/users/{rider.id}/card-confirm", headers=_dispatch_headers(),
                          json={"setup_intent_id": "seti_test123", "consent": True})
    assert r.status_code == 200
    assert len(await _rows(rider.id)) == 2


@pytest.mark.parametrize("case,expected", [
    ("no_consent", 400), ("other_rider", 403), ("other_customer", 403), ("not_done", 409),
])
async def test_confirm_guards(client, db, test_rider, monkeypatch, case, expected):
    rider, _ = test_rider
    rider.stripe_customer_id = "cus_test_rider"
    await db.commit()
    _patch_setup(
        monkeypatch,
        owner=rider.id + 999 if case == "other_rider" else rider.id,
        customer="cus_someone_else" if case == "other_customer" else "cus_test_rider",
        status="requires_payment_method" if case == "not_done" else "succeeded")
    r = await client.post(f"/admin/users/{rider.id}/card-confirm", headers=_dispatch_headers(),
                          json={"setup_intent_id": "seti_test123", "consent": case != "no_consent"})
    assert r.status_code == expected, r.text
    assert await _rows(rider.id) == []


async def test_trip_is_held_on_the_card_dispatch_picked(client, db, test_rider, monkeypatch):
    rider, _ = test_rider
    await _payable_rider(db, rider)                       # pm_card_test, default
    db.add(RiderPaymentMethod(user_id=rider.id, method_type="stripe_card",
                              display_name="Amex ending in 1005",
                              stripe_pm_id="pm_card_amex", is_default=False))
    await db.commit()
    _patch_route(monkeypatch)
    store = _patch_stripe(monkeypatch)
    monkeypatch.setattr("routers.dispatch._find_nearest_drivers", AsyncMock(return_value=[]))

    quote = (await client.post("/admin/trips/quote", json=_quote_payload(rider.id),
                               headers=_dispatch_headers())).json()
    amex = next(m for m in quote["payment_methods"] if m["display_name"].startswith("Amex"))
    resp = await _create_trip(client, rider, quote_id=quote["quote_id"], payment_method_id=amex["id"])
    assert resp.status_code == 200, resp.text
    create_kw = next(kw for kw in store["create_kwargs"]
                     if kw.get("metadata", {}).get("kind") == "fare")
    assert create_kw["payment_method"] == "pm_card_amex"
    assert (await _reload(RiderPaymentMethod, amex["id"])).is_default is True
    trip = await _reload(Trip, resp.json()["id"])
    assert trip.funding_source == "rider"


async def test_a_card_of_another_rider_is_refused(client, db, test_rider, test_driver, monkeypatch):
    rider, _ = test_rider
    other, _ = test_driver
    await _payable_rider(db, rider)
    foreign = RiderPaymentMethod(user_id=other.id, method_type="stripe_card",
                                 display_name="Visa ending in 9999",
                                 stripe_pm_id="pm_foreign", is_default=True)
    db.add(foreign)
    await db.commit()
    await db.refresh(foreign)
    _patch_route(monkeypatch)
    _patch_stripe(monkeypatch)
    monkeypatch.setattr("routers.dispatch._find_nearest_drivers", AsyncMock(return_value=[]))
    resp = await _create_trip(client, rider, payment_method_id=foreign.id)
    assert resp.status_code == 400, resp.text


async def test_display_name_matches_what_the_app_parses():
    assert admin_rider_cards._display_name("visa", "4242") == "Visa ending in 4242"
    assert admin_rider_cards._display_name("amex", "1005") == "Amex ending in 1005"
