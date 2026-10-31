"""Owner rule 2026-10-31: nothing a rider or driver sees may say that
dispatch (or an operator / admin) did it — no "by dispatch", no "equipo de
dispatch", no "Tu operador de Cruise". The rider app shows cancel_reason
verbatim, so an operator-written reason that names them is stored neutral."""
from pathlib import Path

from utils.helpers import rider_safe_cancel_reason

_BACKEND = Path(__file__).resolve().parents[1]


def test_operator_reasons_are_stored_neutral():
    assert rider_safe_cancel_reason("Cancelado por dispatch") == "cancelled"
    assert rider_safe_cancel_reason("admin_cancel") == "cancelled"
    assert rider_safe_cancel_reason("El operador lo canceló") == "cancelled"
    assert rider_safe_cancel_reason("") == "cancelled"
    assert rider_safe_cancel_reason(None) == "cancelled"


def test_a_plain_reason_still_reaches_the_rider():
    assert rider_safe_cancel_reason("Espera muy larga") == "Espera muy larga"


def test_no_user_facing_text_names_dispatch():
    banned = (
        "canceled by dispatch", "cancelled by dispatch", "equipo de dispatch",
        "dispatch team", "operador de Cruise", "Cruise operator",
        "enviada a dispatch", "or dispatch can cancel", "contact dispatch",
        "admin_bulk_cleanup", "from our dispatch team",
    )
    files = [*(_BACKEND / "routers").glob("*.py"), *(_BACKEND / "services").glob("*.py"),
             _BACKEND / "main.py", _BACKEND / "utils" / "helpers.py"]
    hits = [f"{f.name}: {b}" for f in files
            for b in banned if b in f.read_text(encoding="utf-8")]
    assert not hits, hits


def test_admin_cancel_stores_a_rider_safe_reason():
    src = (_BACKEND / "routers" / "admin.py").read_text(encoding="utf-8")
    assert "trip.cancel_reason = rider_safe_cancel_reason(reason)" in src
