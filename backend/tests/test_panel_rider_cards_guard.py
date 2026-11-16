"""Panel: add a card to a rider and pick the card a trip is charged to
(owner 2026-11-15, drawing https://claude.ai/artifact/9ajBYu169bo3u3ovcTSf3u).

The bundles are patched by hand (CLAUDE.md #30): these pins fail if a
rebuild drops the wiring, and they hold the safety rules of the card form.
"""
from pathlib import Path

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
CHUNK = (ASSETS / "rider-cards-Cruise2026.js").read_text(encoding="utf-8")
PROFILE = (ASSETS / "index-azyIyM-i.js").read_text(encoding="utf-8")
NEW_TRIP = (ASSETS / "index-B68rRA9U.js").read_text(encoding="utf-8")


def test_the_card_number_only_ever_goes_to_stripe():
    # Stripe's own field, loaded from Stripe; we only ever post ids back.
    assert 'src="https://js.stripe.com/v3/"' in CHUNK
    assert 'stripe.elements().create("card",' in CHUNK
    assert "confirmCardSetup(setupRef.current.client_secret" in CHUNK
    assert "card-confirm`,{setup_intent_id:r.setupIntent.id" in CHUNK
    # Link's "Autofill" would fill the OPERATOR's own saved card.
    assert "disableLink:true" in CHUNK
    # No card fields of our own.
    for word in ("cardNumber", "card_number", "cvc:", "exp_month"):
        assert word not in CHUNK


def test_consent_is_required_and_the_chat_is_ruled_out():
    assert "const canSave=ready&&complete&&consent&&!saving" in CHUNK
    assert "autorizó por teléfono guardar esta tarjeta" in CHUNK
    assert "nunca por el chat" in CHUNK


def test_profile_has_add_card_for_riders_only():
    assert "guard-pin panel_rider_cards" in PROFILE
    assert 'import("./rider-cards-Cruise2026.js").then(x=>({default:x.AddRiderCardButton}))' in PROFILE
    assert "trailing:!r&&c!==null?e.jsx(m.Suspense" in PROFILE
    assert "onSaved:()=>f.reload()" in PROFILE


def test_new_trip_picks_the_card_and_sends_it():
    assert "guard-pin panel_rider_cards" in NEW_TRIP
    assert 'import("./rider-cards-Cruise2026.js").then(m=>({default:m.RiderCardPicker}))' in NEW_TRIP
    assert "const[pmChoice,setPmChoice]=a.useState(null);" in NEW_TRIP
    assert 'paymentMethodId:fundingMode==="rider"&&typeof pmChoice==="number"?pmChoice:null' in NEW_TRIP
    assert 'body.payment_method_id=input.paymentMethodId' in NEW_TRIP
    # Adding a card from the form re-quotes so the new card is listed.
    assert 'onAdded:()=>{setQuote(null);setQuoteSig("");bumpQuoteRetry(v=>v+1)}' in NEW_TRIP


def test_panel_csp_allows_stripe_js():
    main = (Path(__file__).resolve().parents[1] / "main.py").read_text(encoding="utf-8")
    assert "https://js.stripe.com;" in main or "https://js.stripe.com; " in main
    assert "frame-src https://js.stripe.com https://hooks.stripe.com" in main
