"""Reservation reminder pushes (2026-10-30).

The 30-min "go online" push printed the UTC clock (1:40 PM Miami went out
as "05:40 PM"), and three reminders reached Spanish phones in English.
"""
from pathlib import Path

_MAIN = (Path(__file__).resolve().parents[1] / "main.py").read_text(encoding="utf-8")


def test_no_utc_clock_in_reminder_copy():
    assert "sched_at.strftime(" not in _MAIN
    # Since 2026-10-31 the go-online push lands 15 min before the 1-hour
    # deadline (it used to be the 30-min one) — still no clock time.
    assert "Conéctate para mantener tu reserva" in _MAIN


def test_reminders_are_spanish_first_with_english_copy():
    for es, en in [
        ('title="Tu viaje reservado empieza pronto"', 'title_en="Your scheduled ride starts soon"'),
        ('title="Ve al punto de recogida"', 'title_en="Head to the pickup point now"'),
        ('title="Tu viaje empieza en 15 minutos"', 'title_en="Your ride starts in 15 minutes"'),
        ('title="Conéctate para mantener tu reserva"', 'title_en="Go online to keep your reservation"'),
    ]:
        assert es in _MAIN and en in _MAIN
        assert _MAIN.index(es) < _MAIN.index(en)


def test_driver_reservations_carry_pickup_wall_clock():
    """Shipped 'Mis Reservas' prints scheduled_at as-is: send the pickup's
    wall clock (1:40 PM Miami, 12:40 PM Birmingham) plus the real instant."""
    from datetime import datetime, timezone
    from types import SimpleNamespace
    from routers.trips import _with_wall_clock_schedule

    at = datetime(2026, 10, 30, 17, 40, tzinfo=timezone.utc)
    miami = _with_wall_clock_schedule(SimpleNamespace(scheduled_at=at, pickup_lng=-80.2), {})
    assert miami["scheduled_at"] == "2026-10-30T13:40:00"
    assert miami["scheduled_at_utc"] == "2026-10-30T17:40:00+00:00"
    bham = _with_wall_clock_schedule(SimpleNamespace(scheduled_at=at.replace(tzinfo=None), pickup_lng=-86.8), {})
    assert bham["scheduled_at"] == "2026-10-30T12:40:00"
    assert _with_wall_clock_schedule(SimpleNamespace(scheduled_at=None, pickup_lng=-80.2), {"x": 1}) == {"x": 1}
