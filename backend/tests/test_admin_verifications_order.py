"""GET /admin/verifications — the dispatch panel's verification queue.

User request (2026-10-13): "en la pagina de verificacion colocame por orden
de recien a mas viejo". The panel merges this endpoint's rows into its queue
and sorts by submission date, but the payload carried no date the panel
could use — backend rows sank to the bottom of the list (submittedAt=null
→ year-2000 fallback in the panel's comparator).

Pins: the list is newest-first and every row carries created_at (ISO), the
field the panel's backend-row mapper now reads.
"""
import pytest

from models.database import User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def _pending_driver(db, first_name):
    u = User(
        first_name=first_name,
        last_name="Queue",
        email=f"{first_name.lower()}.queue@test.com",
        phone=f"+1555{first_name.lower()}",
        password_hash="x",
        role="driver",
        status="active",
        verification_status="pending",
    )
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def test_verifications_newest_first_with_created_at(client, db):
    older = await _pending_driver(db, "Olderqueue")
    newer = await _pending_driver(db, "Newerqueue")

    resp = await client.get(
        "/admin/verifications?limit=500",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert resp.status_code == 200, resp.text
    rows = resp.json()
    ids = [r["user_id"] for r in rows]
    assert ids == sorted(ids, reverse=True), "list must be newest-first"
    by_id = {r["user_id"]: r for r in rows}
    for u in (older, newer):
        created = by_id[u.id]["created_at"]
        assert created and created.startswith("20"), (
            "the panel's sort needs a real ISO date, not null"
        )
