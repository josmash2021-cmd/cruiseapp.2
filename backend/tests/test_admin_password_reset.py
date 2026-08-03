"""Regression: resetting a password from the dispatch panel answered
"Invalid input detected" for any password containing ; & | ` or $.

`admin_update_user` ran the password through `_sanitize_string()`, whose
command-injection rule is `[;&|`$]`. That check belongs on a name or an
address — values that get echoed back into pages and queries — but a password
goes straight to `pwd.hash()` and is never interpolated anywhere. The filter
rejected exactly the strongest passwords, and the operator could not tell why.

These pin the behaviour both ways: special characters go through, and the
strength rules still hold.
"""
import pytest

from tests.conftest import _make_auth_headers
from utils.security import pwd


def _headers():
    return _make_auth_headers("test-dispatch-key")


async def _reset(client, user_id: int, password: str):
    return await client.patch(
        f"/admin/users/{user_id}",
        headers=_headers(),
        json={"password": password, "confirm_password_change": True},
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "password",
    [
        "Cruise$2026",       # dollar — was rejected
        "Rider&Driver1",     # ampersand — was rejected
        "Miami;Ride9",       # semicolon — was rejected
        "Pipe|Line7A",       # pipe — was rejected
        "Back`tick2B",       # backtick — was rejected
        "Plain1Password",    # nothing special, always worked
    ],
)
async def test_special_characters_are_accepted(client, db, test_rider, password):
    rider, _ = test_rider

    resp = await _reset(client, rider.id, password)

    assert resp.status_code == 200, resp.text
    await db.refresh(rider)
    assert pwd.verify(password, rider.password_hash), (
        "the stored hash must verify against the password that was set"
    )


@pytest.mark.asyncio
async def test_reset_works_for_drivers_too(client, db, test_driver):
    driver, _ = test_driver

    resp = await _reset(client, driver.id, "Driver$Pass1")

    assert resp.status_code == 200, resp.text
    await db.refresh(driver)
    assert pwd.verify("Driver$Pass1", driver.password_hash)


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "password,expected",
    [
        ("Sh0rt", "at least 8 characters"),
        ("alllowercase1", "uppercase"),
        ("NoDigitsHere", "digit"),
    ],
)
async def test_strength_rules_still_apply(client, test_rider, password, expected):
    rider, _ = test_rider

    resp = await _reset(client, rider.id, password)

    assert resp.status_code == 400, resp.text
    assert expected in resp.json()["detail"]


@pytest.mark.asyncio
async def test_confirmation_flag_is_still_required(client, db, test_rider):
    rider, _ = test_rider
    original = rider.password_hash

    resp = await client.patch(
        f"/admin/users/{rider.id}",
        headers=_headers(),
        json={"password": "Cruise$2026"},
    )

    assert resp.status_code == 400, resp.text
    await db.refresh(rider)
    assert rider.password_hash == original, "password must not change without the flag"


@pytest.mark.asyncio
async def test_other_fields_are_still_sanitised(client, test_rider):
    """The filter was removed from the password only — a name that looks like
    an injection attempt must still be refused."""
    rider, _ = test_rider

    resp = await client.patch(
        f"/admin/users/{rider.id}",
        headers=_headers(),
        json={"first_name": "<script>alert(1)</script>"},
    )

    assert resp.status_code == 400, resp.text
    assert "Invalid input" in resp.json()["detail"]


# ── The whole point: after the reset, the person can actually log in ────────


@pytest.mark.asyncio
@pytest.mark.parametrize("password", ["Cruise$2026", "Rider&Driver1"])
async def test_rider_can_log_in_with_the_password_admin_set(
    client, test_rider, password
):
    rider, _ = test_rider
    assert (await _reset(client, rider.id, password)).status_code == 200

    resp = await client.post(
        "/auth/login",
        json={
            "identifier": rider.email,
            "password": password,
            "role": "rider",
        },
        headers=_make_auth_headers(),
    )

    assert resp.status_code == 200, resp.text
    assert "login_token" in resp.json()


@pytest.mark.asyncio
async def test_driver_can_log_in_with_the_password_admin_set(client, test_driver):
    driver, _ = test_driver
    assert (await _reset(client, driver.id, "Driver$Pass1")).status_code == 200

    resp = await client.post(
        "/auth/login",
        json={
            "identifier": driver.email,
            "password": "Driver$Pass1",
            "role": "driver",
        },
        headers=_make_auth_headers(),
    )

    assert resp.status_code == 200, resp.text
    assert "login_token" in resp.json()


@pytest.mark.asyncio
async def test_the_old_password_stops_working(client, test_rider):
    rider, _ = test_rider
    assert (await _reset(client, rider.id, "Cruise$2026")).status_code == 200

    resp = await client.post(
        "/auth/login",
        json={
            "identifier": rider.email,
            "password": "TestPass1!",
            "role": "rider",
        },
        headers=_make_auth_headers(),
    )

    assert resp.status_code == 401, resp.text


# ── Social accounts: no password anybody knows ──────────────────────────────


@pytest.mark.asyncio
async def test_social_account_says_which_button_to_press(client, db, test_rider):
    """A Google/Apple account has a random placeholder hash, so email+password
    can never match. "Invalid credentials" made people retype a password that
    never existed."""
    rider, _ = test_rider
    rider.auth_provider = "google"
    await db.commit()

    resp = await client.post(
        "/auth/login",
        json={"identifier": rider.email, "password": "AnyGuess1", "role": "rider"},
        headers=_make_auth_headers(),
    )

    assert resp.status_code == 401, resp.text
    assert "Google" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_admin_password_unblocks_a_social_account(client, db, test_rider):
    """Setting a password from the panel is the remedy: the same account can
    then sign in with email+password."""
    rider, _ = test_rider
    rider.auth_provider = "google"
    await db.commit()

    assert (await _reset(client, rider.id, "Cruise$2026")).status_code == 200

    resp = await client.post(
        "/auth/login",
        json={"identifier": rider.email, "password": "Cruise$2026", "role": "rider"},
        headers=_make_auth_headers(),
    )

    assert resp.status_code == 200, resp.text
    assert "login_token" in resp.json()


@pytest.mark.asyncio
async def test_password_accounts_keep_the_generic_message(client, test_rider):
    """No account enumeration beyond what the social hint requires: a normal
    account with a wrong password still says nothing specific."""
    resp = await client.post(
        "/auth/login",
        json={"identifier": "rider@test.com", "password": "WrongPass9", "role": "rider"},
        headers=_make_auth_headers(),
    )

    assert resp.status_code == 401, resp.text
    assert resp.json()["detail"] == (
        "The email/phone or password you entered is incorrect"
    )
