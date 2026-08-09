"""Guardian for the trip-resurrect NameError fix (session 2026-08-09).

The driver-override branch of update_trip_status (cancelled/completed →
arrived/in_trip/completed — the path a driver takes to continue a trip that
was auto-cancelled while their app was closed) called request.client.host,
but update_trip_status never declared `request` in its signature. That
branch raised NameError → 500 → rollback, every single time — the exact
"the app fails after closing and reopening" path.
"""
import pathlib
import re

TRIPS = pathlib.Path(__file__).resolve().parents[1] / "routers" / "trips.py"


def _signature_body(src: str) -> str:
    marker = "async def update_trip_status("
    start = src.index(marker)
    # The signature runs to the closing "):" of the def line.
    end = src.index("):", start)
    return src[start:end]


def test_update_trip_status_declares_request():
    src = TRIPS.read_text(encoding="utf-8")
    sig = _signature_body(src)
    assert "request: Request" in sig, (
        "the resurrect branch uses request.client.host — without the "
        "parameter it raises NameError and the driver cannot continue a "
        "trip auto-cancelled while their app was closed"
    )


def test_resurrect_branch_uses_the_injected_request():
    src = TRIPS.read_text(encoding="utf-8")
    resurrect = src.index("TRIP_RESURRECTED")
    window = src[max(0, resurrect - 800):resurrect]
    assert "request.client.host" in window, (
        "the audit log must keep the caller IP — the fix adds the "
        "parameter, it does not delete the log line"
    )
    assert re.search(r"async def update_trip_status\([^)]*request: Request", src), (
        "request must be FastAPI-injected via the signature"
    )
