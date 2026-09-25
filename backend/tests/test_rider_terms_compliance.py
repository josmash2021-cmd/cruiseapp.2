"""Compliance tests: Rider Terms of Service vs. actual app behavior.

Guards docs/rider_terms_of_service.md against drift from the code:
receipt contents (Fla. Stat. § 627.748(6)), the instant pre-pickup
cancellation flow, wait/no-show fee figures, the support email, and the
cleaning/damage and lost-item fee decisions (no such fees are charged).
"""

import os
import re

import pytest
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TERMS_PATH = os.path.join(REPO_ROOT, "docs", "rider_terms_of_service.md")
RIDER_TERMS_SCREEN_PATH = os.path.join(
    REPO_ROOT, "lib", "screens", "terms_of_service_screen.dart")
TRIPS_PATH = os.path.join(REPO_ROOT, "backend", "routers", "trips.py")


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def _flat(path: str) -> str:
    """File contents with all whitespace runs collapsed (the legal doc is
    hard-wrapped at ~80 chars, so phrases span line breaks)."""
    return re.sub(r"\s+", " ", _read(path))


# ── 1. Receipt includes driver first name (Fla. Stat. § 627.748(6)) ────────


async def test_receipt_includes_driver_first_name(
    client: AsyncClient, test_rider, test_trip
):
    from tests.conftest import _make_auth_headers

    _, token = test_rider
    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    resp = await client.get(
        f"/trips/{test_trip.id}/fare-breakdown", headers=headers
    )
    assert resp.status_code == 200
    data = resp.json()
    # The electronic receipt must state the driver's first name.
    assert data.get("driver_first_name") == "Test"


# ── 2. Cancellation flow: instant rider cancel, even with a driver ──────


async def test_rider_cancel_instant_pre_pickup_with_driver(
    client: AsyncClient, test_rider, test_trip, db
):
    """A rider may cancel instantly at any point before pickup, even with a
    driver assigned. The old policy sent them through /request-cancel
    (dispatch approval), which left the trip alive for the driver after the
    rider had already walked away. The driver is notified immediately.
    In-trip the rider may cancel too (2026-09-23) — charged the full
    estimate."""
    from sqlalchemy import select
    from models.database import Notification
    from tests.conftest import _make_auth_headers

    _, token = test_rider
    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    # Put the fixture trip in a pre-pickup state with the driver assigned.
    test_trip.status = "driver_en_route"
    await db.commit()

    resp = await client.post(f"/trips/{test_trip.id}/cancel", headers=headers)
    assert resp.status_code == 200
    assert resp.json()["status"] == "cancelled"

    # The assigned driver is told about it — that was the point of the
    # change: before it, nothing reached them.
    res = await db.execute(
        select(Notification).where(
            Notification.user_id == test_trip.driver_id,
            Notification.notif_type == "trip_cancelled",
        )
    )
    assert res.scalars().first() is not None

    # In-trip the rider may ALSO cancel (user spec 2026-09-23) — charged the
    # FULL estimate: cancellation_fee == fare. Fresh headers each call —
    # the API's nonce anti-replay rejects a reused set with a 401.
    test_trip.status = "in_trip"
    test_trip.fare = 25.50
    await db.commit()
    fresh = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}
    resp3 = await client.post(f"/trips/{test_trip.id}/cancel", headers=fresh)
    assert resp3.status_code == 200
    assert resp3.json()["status"] == "cancelled"
    assert resp3.json()["cancellation_fee"] == 25.50


# ── 3. No-show / wait fee figures: UI matches backend policy ───────────────


def test_wait_fee_schedule_consistent_between_ui_and_backend():
    backend = _read(TRIPS_PATH)
    # Compare against the text as RENDERED: the screen marks figures bold
    # (**$5.00**), which riders never see — strip the markers before matching.
    screen = _read(RIDER_TERMS_SCREEN_PATH).replace("**", "")

    # Backend wait policy (trips.py): (free_minutes, fee_per_minute).
    for pattern in (
        r'"sedan":\s+\(2, 0\.40\)',
        r'"comfort":\s+\(2, 0\.40\)',
        r'"standard":\s+\(2, 0\.40\)',
        r'"premium":\s+\(3, 0\.60\)',
        r'"suv_xl":\s+\(5, 1\.00\)',
        r'"vip":\s+\(5, 1\.00\)',
        r'"black":\s+\(5, 1\.00\)',
        r"_AIRPORT_WAIT_POLICY = \(10, 0\.40\)",
    ):
        assert re.search(pattern, backend), f"backend wait policy missing: {pattern}"

    # The in-app terms text must mirror the same per-minute figures.
    for frag in ("$0.40 per minute", "$0.60 per minute", "$1.00 per minute"):
        assert frag in screen, f"terms screen missing wait-fee figure: {frag}"

    # No-show fee minimum (2026-09-13): the no-show fee is max(accrued wait
    # fee, a per-tier minimum). The backend constants in
    # backend/wait_timeout_agent.py and the rider-facing text must advertise
    # the SAME figures — drift here means the app promises one fee and the
    # backend captures another.
    agent_src = _read(os.path.join(REPO_ROOT, "backend", "wait_timeout_agent.py"))
    for pattern in (
        r'"sedan":\s+5\.0',
        r'"comfort":\s+5\.0',
        r'"standard":\s+5\.0',
        r'"premium":\s+8\.0',
        r'"suv_xl":\s+10\.0',
        r'"vip":\s+10\.0',
        r'"black":\s+10\.0',
        r"_NO_SHOW_MIN_FEE_AIRPORT = 10\.0",
    ):
        assert re.search(pattern, agent_src), \
            f"backend no-show minimum missing: {pattern}"
    for frag in (
        "$5.00 Standard/Compact",
        "$8.00 Premium",
        "$10.00 Black/SUV XL",
    ):
        assert frag in screen, f"terms screen missing no-show minimum figure: {frag}"


# ── 4. Support email is support@cruiseinride.com everywhere ──────────────────


def test_support_email_is_correct_repo_wide():
    stale = "support@" + "cruise" + "app.com"  # avoid matching this test file
    offenders = []
    for top in ("lib", "backend", "docs", "api", "n8n", "web"):
        for dirpath, dirnames, filenames in os.walk(os.path.join(REPO_ROOT, top)):
            dirnames[:] = [
                d for d in dirnames if d not in ("__pycache__", ".pytest_cache", "archive")
            ]
            for fn in filenames:
                if not fn.endswith((".dart", ".py", ".md", ".ts", ".json", ".html")):
                    continue
                path = os.path.join(dirpath, fn)
                try:
                    if stale in _read(path):
                        offenders.append(path)
                except (UnicodeDecodeError, OSError):
                    continue
    assert not offenders, f"stale support email found in: {offenders}"


# ── 5. Rider Terms: no cleaning/damage fee (not currently charged) ─────────


def test_rider_terms_has_no_cleaning_damage_fee():
    terms = _flat(TERMS_PATH)
    assert "[CLEANING/DAMAGE" not in terms
    assert "cleaning or damage fee may apply" not in terms
    assert "does not currently charge cleaning or damage fees" in terms

    # The in-app copy of the terms must match the same decision.
    screen = _flat(
        os.path.join(REPO_ROOT, "lib", "screens", "terms_of_service_screen.dart")
    )
    assert "cleaning or damage fee may apply" not in screen
    assert "does not currently charge cleaning or damage fees" in screen


# ── 6. Rider Terms: lost items carry no fee ────────────────────────────────


def test_rider_terms_lost_items_has_no_fee():
    terms = _flat(TERMS_PATH)
    assert "[LOST ITEM" not in terms
    section = terms.split("## 14. Lost Items")[1].split("## 15.")[0]
    assert "fee may apply" not in section
    assert "does not charge a lost-item or return fee" in section

    # The in-app copy and the help screen must not advertise a return fee.
    screen = _flat(
        os.path.join(REPO_ROOT, "lib", "screens", "terms_of_service_screen.dart")
    )
    assert "return fee is displayed" not in screen
    assert "does not charge a lost-item or return fee" in screen
    help_screen = _flat(
        os.path.join(REPO_ROOT, "lib", "screens", "help_screen.dart")
    )
    assert "return fee may apply" not in help_screen
