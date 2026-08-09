"""Guardian for the hold-settlement fixes (session 2026-08-09, audit tanda 2).

Every path that cancels a trip while a hold may exist must settle that hold
with _release_or_capture_fee_on_cancel (PaymentIntent.cancel for a full
release) — NOT stripe.Refund, which raises on a requires_capture PI and left
the money pinned to the rider's card for ~7 days. And a paid trip must never
be un-paid by a later webhook failure.
"""
import pathlib

BACKEND = pathlib.Path(__file__).resolve().parents[1]
GUARDIAN = (BACKEND / "guardian_agent.py").read_text(encoding="utf-8")
PAYMENTS = (BACKEND / "routers" / "payments.py").read_text(encoding="utf-8")


def _window(src: str, marker: str, before: int = 200, after: int = 2600) -> str:
    at = src.index(marker)
    return src[max(0, at - before):at + after]


def test_on_demand_auto_cancel_releases_hold_not_refund():
    body = _window(GUARDIAN, "auto:no_driver_found_10min", before=4000, after=200)
    assert "_release_or_capture_fee_on_cancel" in body, (
        "the 10-min on-demand auto-cancel must cancel the held PI, not "
        "refund it — Refund.create raises on requires_capture and the hold "
        "stayed pinned ~7 days"
    )
    held_window = body[body.index('pay_status == "held"'):]
    assert "Refund.create" not in held_window.split('pay_status == "paid"')[0], (
        "the held branch must never reach Refund.create"
    )


def test_scheduled_auto_cancel_releases_hold_and_pushes_rider():
    body = _window(GUARDIAN, "auto:scheduled_no_driver_30min", before=3500, after=2500)
    assert "_release_or_capture_fee_on_cancel" in body, (
        "the 30-min scheduled auto-cancel cancelled with the hold pinned"
    )
    assert "_send_fcm_push" in body and "scheduled_cancelled" in body, (
        "the docstring always promised the rider a push it never sent"
    )


def test_ghost_cancel_releases_hold():
    body = _window(GUARDIAN, "auto:guardian_ghost_stale", before=2500, after=500)
    assert "_release_or_capture_fee_on_cancel" in body, (
        "the 180-min ghost cancel also left the hold pinned"
    )


def test_payment_monitor_sweeps_held_not_authorized():
    assert 'Trip.payment_status == "held"' in GUARDIAN, (
        "nothing in the codebase ever writes 'authorized' — the sweep was "
        "dead code until it read 'held'"
    )
    assert 'Trip.payment_status == "authorized"' not in GUARDIAN


def test_dispatch_timeout_un_orphans_the_trip():
    body = _window(GUARDIAN, "class DispatchTimeoutAgent", after=6500)
    assert "trip.driver_id = None" in body, (
        "offers created outside the cascade (scheduled dispatcher, retry "
        "agent) orphan the trip in 'requested' with a driver_id that never "
        "answers — every retry/cancel path requires driver_id IS NULL"
    )


def test_webhook_never_unpays_a_paid_trip():
    body = _window(PAYMENTS, 'payment_intent.payment_failed', after=1500)
    assert 'trip.payment_status == "paid"' in body, (
        "a later payment_failed (fare-shortfall retry) must not flip a "
        "paid trip to failed nor push the rider a false 'Payment Failed'"
    )
    paid_guard = body.index('trip.payment_status == "paid"')
    mark_failed = body.index('trip.payment_status = "failed"')
    assert paid_guard < mark_failed, "the paid guard must come first"
