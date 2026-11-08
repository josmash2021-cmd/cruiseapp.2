"""Panel Promos page: dollars-off promotions (owner 2026-11-07, the rider
welcome promotion is $10 off the first ride). Hand-patched bundle
(CLAUDE.md #30): these pins fail if a rebuild drops the "Monto fijo" kind.
"""
from pathlib import Path

PROMOS = (Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
          / "index-BmdudzzQ.js").read_text(encoding="utf-8")


def test_form_offers_a_fixed_amount_and_sends_amount_cents():
    assert 't.jsx("option",{value:"amount",children:"Monto fijo de descuento ($)"})' in PROMOS
    assert 'if(kind!=="percent"&&kind!=="free"&&kind!=="amount")return' in PROMOS
    assert '...(kind==="amount"?{amount_cents:amountCents}:{})' in PROMOS
    # Same bounds as the server ($1–$200, PromotionGrantIn.amount_cents).
    assert "amountCents<100||amountCents>20000" in PROMOS


def test_list_titles_a_fixed_amount_in_dollars():
    assert 'if(grant.kind==="amount"){const c=Number(grant.amount_cents)||0;return`$${c%100===0?c/100:(c/100).toFixed(2)} de descuento`}' in PROMOS
