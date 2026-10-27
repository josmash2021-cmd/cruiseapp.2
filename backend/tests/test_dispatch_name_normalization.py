import unicodedata

import pytest
from sqlalchemy import select

from models.database import User
from tests.conftest import _make_auth_headers
from utils.helpers import _strip_accents

pytestmark = pytest.mark.asyncio


def _register_payload(email, source, first_name="José", last_name="Martínez"):
    return {
        "first_name": first_name,
        "last_name": last_name,
        "email": email,
        "password": "StrongPass1!",
        "role": "rider",
        "registration_source": source,
    }


def test_strip_accents_preserves_name_text_without_diacritics():
    assert _strip_accents("José Martínez") == "Jose Martinez"
    assert _strip_accents("María Ñuñez") == "Maria Nunez"
    assert _strip_accents(unicodedata.normalize("NFD", "José")) == "Jose"
    assert _strip_accents("Jhon") == "Jhon"


async def test_only_dispatch_registration_normalizes_names(client, db):
    response = await client.post(
        "/auth/register",
        json=_register_payload("dispatch-accents@test.com", "dispatch"),
        headers=_make_auth_headers(),
    )
    assert response.status_code == 200, response.text
    assert response.json()["user"]["first_name"] == "Jose"
    assert response.json()["user"]["last_name"] == "Martinez"
    saved = (await db.execute(
        select(User).where(User.email == "dispatch-accents@test.com"),
    )).scalar_one()
    assert (saved.first_name, saved.last_name) == ("Jose", "Martinez")

    response = await client.post(
        "/auth/register",
        json=_register_payload("app-accents@test.com", "app"),
        headers=_make_auth_headers(),
    )
    assert response.status_code == 200, response.text
    assert response.json()["user"]["first_name"] == "José"
    assert response.json()["user"]["last_name"] == "Martínez"


async def test_dispatch_reactivation_also_normalizes_names(client, db, monkeypatch):
    from routers import auth

    async def _no_guest_link(_db, _user):
        pass

    monkeypatch.setattr(auth, "link_guest_trips_to_user", _no_guest_link)
    user = User(
        first_name="Deleted",
        last_name="Account",
        email="reactivate-accents@test.com",
        phone="+19990001111",
        password_hash="unused",
        role="rider",
        status="deleted",
    )
    db.add(user)
    await db.commit()

    response = await client.post(
        "/auth/register",
        json=_register_payload("reactivate-accents@test.com", "dispatch"),
        headers=_make_auth_headers(),
    )
    assert response.status_code == 200, response.text
    await db.refresh(user)
    assert (user.first_name, user.last_name) == ("Jose", "Martinez")


async def test_dispatch_patch_normalizes_both_name_fields(client, db, test_rider):
    rider, _ = test_rider
    response = await client.patch(
        f"/admin/users/{rider.id}",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"first_name": "María", "last_name": "Ñuñez"},
    )
    assert response.status_code == 200, response.text
    await db.refresh(rider)
    assert (rider.first_name, rider.last_name) == ("Maria", "Nunez")
