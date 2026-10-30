"""Reservation reminder pushes (2026-10-30).

The 30-min "go online" push printed the UTC clock (1:40 PM Miami went out
as "05:40 PM"), and three reminders reached Spanish phones in English.
"""
from pathlib import Path

_MAIN = (Path(__file__).resolve().parents[1] / "main.py").read_text(encoding="utf-8")


def test_no_utc_clock_in_reminder_copy():
    assert "sched_at.strftime(" not in _MAIN
    assert "Tienes una reserva en 30 minutos" in _MAIN


def test_reminders_are_spanish_first_with_english_copy():
    for es, en in [
        ('title="Tu viaje reservado empieza pronto"', 'title_en="Your scheduled ride starts soon"'),
        ('title="Ve al punto de recogida"', 'title_en="Head to the pickup point now"'),
        ('title="Tu viaje empieza en 15 minutos"', 'title_en="Your ride starts in 15 minutes"'),
        ('title="Tienes una reserva en 30 minutos"', 'title_en="You have a reservation in 30 minutes"'),
    ]:
        assert es in _MAIN and en in _MAIN
        assert _MAIN.index(es) < _MAIN.index(en)
