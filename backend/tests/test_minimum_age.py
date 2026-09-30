"""Tests for the minimum driver age (25+) enforcement.

Covers the shared validation helper (utils.helpers.validate_driver_minimum_age)
and the endpoints that enforce it:
- POST /auth/register (driver role requires DOB, must be 25+)
- POST /drivers/{id}/background-check (DOB already required, must be 25+)
"""

from datetime import date, datetime, timedelta, timezone

import pytest
from httpx import AsyncClient

from utils.helpers import (
    MIN_DRIVER_AGE,
    compute_age,
    parse_date_of_birth,
    validate_driver_minimum_age,
)


# ── Helpers ──────────────────────────────────────────────────────────────────

def _dob_for_age(years: int, *, day_offset: int = 0) -> str:
    """DOB (YYYY-MM-DD) for someone turning `years` today plus `day_offset` days.

    day_offset=0  -> birthday is today (exactly `years` years old)
    day_offset=1  -> birthday is tomorrow (still one day short)

    Anchored to the UTC date, not the machine's local one. compute_age()
    measures against UTC, so building the boundary cases from date.today()
    made the day_offset=1 cases fail on any machine whose local date was
    behind UTC at the time of the run — the "one day short" birthday had
    already passed in UTC. That made these tests pass in the morning and
    fail in the evening, which is worse than no test: a real regression
    would be dismissed as the usual flake.
    """
    today = datetime.now(timezone.utc).date()
    dob = date(today.year - years, today.month, today.day) + timedelta(days=day_offset)
    return dob.isoformat()




def _h(token):
    # The HMAC nonce is single-use — fresh signed headers per request or the
    # middleware answers 401 "Replay detected".
    from tests.conftest import _make_auth_headers
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _register_payload(dob: str | None) -> dict:
    payload = {
        "first_name": "Age",
        "last_name": "Test",
        "email": f"age_test_{dob or 'none'}@test.com",
        "password": "StrongPass1!",
        "role": "driver",
    }
    if dob is not None:
        payload["date_of_birth"] = dob
    return payload


# ── Helper unit tests ─────────────────────────────────────────────────────────

def test_compute_age_boundary():
    # Birthday today -> exact age; birthday tomorrow -> one year less
    assert compute_age(date(2000, 6, 15), today=date(2025, 6, 15)) == 25
    assert compute_age(date(2000, 6, 16), today=date(2025, 6, 15)) == 24
    assert compute_age(date(2000, 6, 14), today=date(2025, 6, 15)) == 25


def test_parse_date_of_birth_formats():
    assert parse_date_of_birth("1990-01-31") == date(1990, 1, 31)
    assert parse_date_of_birth(date(1990, 1, 31)) == date(1990, 1, 31)
    with pytest.raises(ValueError):
        parse_date_of_birth("31/01/1990")
    with pytest.raises(ValueError):
        parse_date_of_birth("")
    with pytest.raises(ValueError):
        parse_date_of_birth(None)


def test_validate_minimum_age_accepts_exactly_25():
    dob = validate_driver_minimum_age(_dob_for_age(MIN_DRIVER_AGE))
    assert compute_age(dob) == MIN_DRIVER_AGE


def test_validate_minimum_age_rejects_one_day_short_of_25():
    with pytest.raises(ValueError, match=f"at least {MIN_DRIVER_AGE}"):
        validate_driver_minimum_age(_dob_for_age(MIN_DRIVER_AGE, day_offset=1))


def test_validate_minimum_age_rejects_24():
    with pytest.raises(ValueError, match=f"at least {MIN_DRIVER_AGE}"):
        validate_driver_minimum_age(_dob_for_age(24))


def test_validate_minimum_age_rejects_future_dob():
    future = (date.today() + timedelta(days=30)).isoformat()
    with pytest.raises(ValueError):
        validate_driver_minimum_age(future)


# ── POST /auth/register ───────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_register_driver_exactly_25_accepted(client: AsyncClient):
    from tests.conftest import _make_auth_headers

    resp = await client.post(
        "/auth/register",
        json=_register_payload(_dob_for_age(MIN_DRIVER_AGE)),
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["user"]["role"] == "driver"


@pytest.mark.asyncio
async def test_register_driver_under_25_rejected(client: AsyncClient):
    from tests.conftest import _make_auth_headers

    resp = await client.post(
        "/auth/register",
        json=_register_payload(_dob_for_age(24)),
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 422
    assert f"at least {MIN_DRIVER_AGE}" in resp.text


@pytest.mark.asyncio
async def test_register_driver_one_day_short_rejected(client: AsyncClient):
    from tests.conftest import _make_auth_headers

    resp = await client.post(
        "/auth/register",
        json=_register_payload(_dob_for_age(MIN_DRIVER_AGE, day_offset=1)),
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 422


@pytest.mark.asyncio
async def test_register_driver_missing_dob_rejected(client: AsyncClient):
    from tests.conftest import _make_auth_headers

    resp = await client.post(
        "/auth/register",
        json=_register_payload(None),
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 422
    assert "Date of birth is required" in resp.text


@pytest.mark.asyncio
async def test_register_rider_without_dob_still_allowed(client: AsyncClient):
    from tests.conftest import _make_auth_headers

    payload = _register_payload(None)
    payload["role"] = "rider"
    resp = await client.post(
        "/auth/register",
        json=payload,
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200, resp.text


# ── POST /drivers/{id}/background-check ──────────────────────────────────────

@pytest.mark.asyncio
async def test_background_check_under_25_rejected(client: AsyncClient, test_driver):
    from tests.conftest import _make_auth_headers

    driver, token = test_driver
    resp = await client.post(
        f"/drivers/{driver.id}/background-check",
        json={"dob": _dob_for_age(24)},
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 400
    assert f"at least {MIN_DRIVER_AGE}" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_background_check_one_day_short_rejected(client: AsyncClient, test_driver):
    from tests.conftest import _make_auth_headers

    driver, token = test_driver
    resp = await client.post(
        f"/drivers/{driver.id}/background-check",
        json={"dob": _dob_for_age(MIN_DRIVER_AGE, day_offset=1)},
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 400


@pytest.mark.asyncio
async def test_background_check_missing_dob_rejected(client: AsyncClient, test_driver):
    from tests.conftest import _make_auth_headers

    driver, token = test_driver
    resp = await client.post(
        f"/drivers/{driver.id}/background-check",
        json={},
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 400
    assert "Date of birth is required" in resp.json()["detail"]



# ── Rider age gate (18+, user spec 2026-09-27) ─────────────────────────────
# Registered through the legacy payload when present, and through
# PATCH /auth/me from the phone-onboarding name step.

@pytest.mark.asyncio
async def test_register_rider_18_accepted(client: AsyncClient):
    from tests.conftest import _make_auth_headers

    payload = _register_payload(_dob_for_age(18))
    payload["role"] = "rider"
    resp = await client.post(
        "/auth/register", json=payload, headers=_make_auth_headers())
    assert resp.status_code == 200, resp.text


@pytest.mark.asyncio
async def test_register_rider_under_18_rejected(client: AsyncClient):
    from tests.conftest import _make_auth_headers

    payload = _register_payload(_dob_for_age(17))
    payload["role"] = "rider"
    resp = await client.post(
        "/auth/register", json=payload, headers=_make_auth_headers())
    assert resp.status_code == 422
    assert "at least 18" in resp.text


@pytest.mark.asyncio
async def test_patch_me_dob_rider_gate(client: AsyncClient, test_rider):
    from tests.conftest import _make_auth_headers

    rider, token = test_rider

    resp = await client.patch(
        "/auth/me", json={"date_of_birth": _dob_for_age(17)}, headers=_h(token))
    assert resp.status_code == 400
    assert "at least 18" in resp.json()["detail"]

    resp = await client.patch(
        "/auth/me", json={"date_of_birth": _dob_for_age(18)}, headers=_h(token))
    assert resp.status_code == 200, resp.text


@pytest.mark.asyncio
async def test_patch_me_dob_driver_gate(client: AsyncClient, test_driver):
    from tests.conftest import _make_auth_headers

    driver, token = test_driver

    resp = await client.patch(
        "/auth/me",
        json={"date_of_birth": _dob_for_age(MIN_DRIVER_AGE, day_offset=1)},
        headers=_h(token))
    assert resp.status_code == 400
    assert f"at least {MIN_DRIVER_AGE}" in resp.json()["detail"]

    resp = await client.patch(
        "/auth/me",
        json={"date_of_birth": _dob_for_age(MIN_DRIVER_AGE)},
        headers=_h(token))
    assert resp.status_code == 200, resp.text


@pytest.mark.asyncio
async def test_patch_me_dob_empty_never_clobbers(client: AsyncClient, test_rider):
    from tests.conftest import _make_auth_headers

    rider, token = test_rider
    good = _dob_for_age(30)
    resp = await client.patch(
        "/auth/me", json={"date_of_birth": good}, headers=_h(token))
    assert resp.status_code == 200, resp.text

    # An empty write must not erase the stored date.
    resp = await client.patch(
        "/auth/me", json={"date_of_birth": ""}, headers=_h(token))
    assert resp.status_code == 200, resp.text

    resp = await client.get("/auth/me", headers=_h(token))
    assert resp.json().get("date_of_birth") == good


@pytest.mark.asyncio
async def test_patch_me_dob_future_rejected(client: AsyncClient, test_rider):
    from tests.conftest import _make_auth_headers

    rider, token = test_rider
    future = (date.today() + timedelta(days=30)).isoformat()
    resp = await client.patch(
        "/auth/me", json={"date_of_birth": future}, headers=_h(token))
    assert resp.status_code == 400
