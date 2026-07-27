"""Compliance tests: Rider Terms of Service vs. actual app behavior.

Guards docs/rider_terms_of_service.md against drift from the code:
receipt contents (Fla. Stat. § 627.748(6)), the support-mediated
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
L10N_PATH = os.path.join(REPO_ROOT, "lib", "l10n", "app_localizations.dart")
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


# ── 2. Cancellation flow: support required after driver assignment ─────────


async def test_rider_cancel_blocked_after_driver_assignment(
    client: AsyncClient, test_rider, test_trip
):
    """Riders cannot self-cancel via /cancel once a driver is assigned;
    the backend directs them to support (request-cancel flow)."""
    from tests.conftest import _make_auth_headers

    _, token = test_rider
    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    # test_trip has a driver assigned, so direct cancel must be rejected.
    resp = await client.post(f"/trips/{test_trip.id}/cancel", headers=headers)
    assert resp.status_code == 403
    assert "contact support" in resp.json()["detail"].lower()

    # The support-mediated path must be available instead.
    fresh = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}
    resp2 = await client.post(
        f"/trips/{test_trip.id}/request-cancel",
        json={"reason": "compliance test"},
        headers=fresh,
    )
    assert resp2.status_code == 200
    assert resp2.json().get("ok") is True


# ── 3. No-show / wait fee figures: UI matches backend policy ───────────────


def test_wait_fee_schedule_consistent_between_ui_and_backend():
    backend = _read(TRIPS_PATH)
    l10n = _read(L10N_PATH)

    # Backend wait policy (trips.py): (free_minutes, fee_per_minute).
    for snippet in (
        '"sedan":   (2, 0.40)',
        '"comfort": (2, 0.40)',
        '"premium": (3, 0.60)',
        '"vip":     (5, 1.00)',
        "_AIRPORT_WAIT_POLICY = (10, 0.40)",
    ):
        assert snippet in backend, f"backend wait policy missing: {snippet}"

    # The in-app terms text must mirror the same per-minute figures and
    # must NOT advertise a flat $10.00 no-show fee (it does not exist).
    for frag in (r"\$0.40/min", r"\$0.60/min", r"\$1.00/min"):
        assert frag in l10n, f"l10n missing wait-fee figure: {frag}"
    assert "No-show fee" not in l10n
    assert r"\$10.00" not in l10n


# ── 4. Support email is support@cruiseapp.com everywhere ──────────────────


def test_support_email_is_correct_repo_wide():
    stale = "support@" + "cruiseinride.com"  # avoid matching this test file
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
