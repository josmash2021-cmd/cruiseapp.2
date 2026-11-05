"""A status set from the dispatch panel (PATCH /admin/trips/{id}) must reach
the apps at once (owner 2026-11-05: "cuando se marca desde dispatch comenzar
viaje, conductor llegó… funciona lento, no responde a veces").

The real-time block was guarded by `"status" in body` — always False on a
Pydantic model (`in` compares against its (name, value) pairs) — so Socket.io,
the SSE bus and the rider's push never fired for a panel change."""
from pathlib import Path

from models.schemas import AdminUpdateTripIn

_ADMIN = (Path(__file__).resolve().parents[1] / "routers" / "admin.py").read_text(
    encoding="utf-8")


def test_membership_on_the_model_is_the_trap():
    body = AdminUpdateTripIn(status="arrived")
    assert ("status" in body) is False
    assert "status" in body.model_dump(exclude_unset=True)


def test_the_panel_update_checks_the_fields_it_was_sent():
    assert 'if "status" in body:' not in _ADMIN
    assert 'if "status" in update_data:' in _ADMIN


def test_the_rider_push_is_in_their_language_with_the_driver_path_types():
    start = _ADMIN.index("async def admin_update_trip(")
    end = _ADMIN.index("@router.", start + 10)
    fn = _ADMIN[start:end]
    assert "locale=user_lang(rider)" in fn
    for t in ("driver_arrived", "trip_started", "trip_completed",
              "driver_en_route", "trip_canceled"):
        assert f'"{t}"' in fn
    assert "dispatch" not in fn.split('_copy = {', 1)[1].split('}.get(', 1)[0].lower()
