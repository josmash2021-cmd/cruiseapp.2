"""Driver onboarding profile fields (drive_city / drive_state / onboarding_survey).

The signup questionnaire ("Tell us about yourself" + drive city/state) is
written by the app through PATCH /auth/me, which whitelists self-update
fields — without these three in the list the answers were silently dropped.
Pins that the endpoint persists them, that the user dict exposes them back,
and that omitted keys never clobber previously stored values.
"""
import json

import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _hdrs(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def test_patch_auth_me_persists_onboarding_fields(client, db, test_driver):
    driver, token = test_driver
    survey = json.dumps({
        "reasons": ["extra_income", "be_own_boss"],
        "hours_per_week": "10-20",
        "experience": ["rideshare"],
        "income_role": "side",
    })

    resp = await client.patch(
        "/auth/me",
        headers=_hdrs(token),
        json={"drive_city": "Miami", "drive_state": "fl", "onboarding_survey": survey},
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()
    # Returned in the user dict so the app can read them back.
    assert data["drive_city"] == "Miami"
    assert data["drive_state"] == "FL"  # normalized to the 2-letter code
    assert data["onboarding_survey"] == survey

    await db.refresh(driver)
    assert driver.drive_city == "Miami"
    assert driver.drive_state == "FL"
    assert driver.onboarding_survey == survey
    parsed = json.loads(driver.onboarding_survey)
    assert parsed["reasons"] == ["extra_income", "be_own_boss"]
    assert parsed["hours_per_week"] == "10-20"


async def test_patch_auth_me_omitted_onboarding_fields_do_not_clobber(client, db, test_driver):
    """A profile update that omits the onboarding keys must keep the stored values."""
    driver, token = test_driver
    driver.drive_city = "Orlando"
    driver.drive_state = "FL"
    driver.onboarding_survey = json.dumps({"reasons": ["flexible_hours"]})
    await db.commit()

    resp = await client.patch(
        "/auth/me",
        headers=_hdrs(token),
        json={"first_name": "Updated"},
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["first_name"] == "Updated"
    assert data["drive_city"] == "Orlando"
    assert data["drive_state"] == "FL"
    assert json.loads(data["onboarding_survey"])["reasons"] == ["flexible_hours"]

    await db.refresh(driver)
    assert driver.drive_city == "Orlando"
    assert driver.drive_state == "FL"


async def test_patch_auth_me_bad_state_code_rejected(client, db, test_driver):
    driver, token = test_driver
    resp = await client.patch(
        "/auth/me",
        headers=_hdrs(token),
        json={"drive_state": "Florida"},
    )
    assert resp.status_code == 400
    await db.refresh(driver)
    assert driver.drive_state is None
