"""Panel "Pagos" reads and pays through the server (2026-11-09).

It read Firestore `drivers.balance` and `payouts`, which nothing writes, and
"Pagar ahora" only wrote a Firestore doc. The bundle is patched by hand
(CLAUDE.md #30): these pins fail if a rebuild brings the old page back.
"""
from pathlib import Path

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
PAGE = (ASSETS / "index-BmdudzzQ.js").read_text(encoding="utf-8")


def test_the_page_lists_from_postgres():
    assert 'Ie("/admin/payouts").then(' in PAGE
    assert "(m?.pending??[]).map(j=>_s(String(j.driverId),j))" in PAGE
    assert 'Y(P,"payouts")' not in PAGE
    assert 'me("balance",">",0)' not in PAGE


def test_pay_now_is_a_real_server_payout():
    assert "await $e(`/admin/drivers/${a}/payout`,{method:e.method})" in PAGE
    assert '{balance:0}' not in PAGE
    # Instant needs the driver's debit card: it stays the driver's request.
    assert 'id:"instant",label:"Instant' not in PAGE
