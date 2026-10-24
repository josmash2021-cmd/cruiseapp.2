from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest
from fastapi import HTTPException
from sqlalchemy import select

from models.database import RiderPaymentMethod, Trip, User
from services.payment_security import record_trip_refund, validate_trip_hold
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers(token: str) -> dict:
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _reload(model, pk):
    from main import SessionLocal
    async with SessionLocal() as session:
        return (await session.execute(select(model).where(model.id == pk))).scalar_one()


async def _money_trip(
    db,
    rider,
    driver,
    *,
    status="completed",
    payment_status="held",
    fare=20.0,
    payment_intent_id="pi_main",
    with_card=False,
    with_split=False,
):
    rider.stripe_customer_id = "cus_rider"
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=fare,
        vehicle_type="comfort",
        status=status,
        payment_status=payment_status,
        stripe_payment_intent_id=payment_intent_id,
        created_at=datetime.now(timezone.utc),
    )
    if with_split:
        trip.driver_earnings = round(fare * 0.60, 2)
        trip.platform_fee = round(fare * 0.40, 2)
        driver.pending_balance = trip.driver_earnings
        driver.total_earnings = trip.driver_earnings
    else:
        driver.pending_balance = 0.0
        driver.total_earnings = 0.0
    db.add(trip)
    if with_card:
        db.add(RiderPaymentMethod(
            user_id=rider.id,
            method_type="stripe_card",
            display_name="Visa 4242",
            stripe_pm_id="pm_card",
            is_default=True,
            created_at=datetime.now(timezone.utc),
        ))
    await db.commit()
    await db.refresh(trip)
    return trip


def _intent(trip, *, pi_id="pi_main", kind="fare", status="succeeded", cents=2000):
    return {
        "id": pi_id,
        "status": status,
        "amount": cents,
        "amount_received": cents if status == "succeeded" else 0,
        "currency": "usd",
        "customer": "cus_rider",
        "metadata": {
            "trip_id": str(trip.id),
            "rider_id": str(trip.rider_id),
            "kind": kind,
            "type": kind,
        },
    }


def _stripe_for(intent):
    return SimpleNamespace(
        PaymentIntent=SimpleNamespace(
            retrieve=MagicMock(return_value=intent),
            increment_authorization=MagicMock(),
        )
    )


async def test_rate_rejects_non_rider_and_non_completed(client, db, test_rider, test_driver):
    rider, rider_token = test_rider
    driver, driver_token = test_driver
    trip = await _money_trip(db, rider, driver, status="in_trip")

    with patch("stripe.PaymentIntent.create") as create:
        wrong_user = await client.post(
            f"/trips/{trip.id}/rate",
            json={"stars": 5, "tip_amount": 5},
            headers=_headers(driver_token),
        )
        wrong_state = await client.post(
            f"/trips/{trip.id}/rate",
            json={"stars": 5, "tip_amount": 5},
            headers=_headers(rider_token),
        )

    assert wrong_user.status_code == 403
    assert wrong_state.status_code == 400
    create.assert_not_called()
    fresh_driver = await _reload(User, driver.id)
    assert fresh_driver.pending_balance == 0


@pytest.mark.parametrize("bad_tip", [float("nan"), float("inf"), -0.01, 100.01])
async def test_rate_rejects_non_finite_or_out_of_range_tip(
    client, db, test_rider, test_driver, bad_tip,
):
    rider, token = test_rider
    driver, _ = test_driver
    trip = await _money_trip(db, rider, driver)
    response = await client.post(
        f"/trips/{trip.id}/rate",
        json={"stars": 5, "tip_amount": bad_tip},
        headers=_headers(token),
    )
    assert response.status_code == 400, response.text
    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.tip_amount == 0
    assert fresh_driver.pending_balance == 0


async def test_rate_without_payment_method_saves_rating_but_credits_zero(
    client, db, test_rider, test_driver,
):
    rider, token = test_rider
    driver, _ = test_driver
    trip = await _money_trip(db, rider, driver, with_card=False)

    response = await client.post(
        f"/trips/{trip.id}/rate",
        json={"stars": 5, "tip_amount": 5},
        headers=_headers(token),
    )
    assert response.status_code == 200, response.text
    assert response.json()["tip_amount"] == 0
    assert response.json()["stripe_status"] == "no_payment_method"
    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.tip_amount == 0
    assert fresh_driver.pending_balance == 0
    assert fresh_driver.total_earnings == 0


async def test_rate_stripe_failure_never_credits(client, db, test_rider, test_driver):
    rider, token = test_rider
    driver, _ = test_driver
    trip = await _money_trip(db, rider, driver, with_card=True)

    with patch("stripe.PaymentIntent.create", side_effect=Exception("declined")):
        response = await client.post(
            f"/trips/{trip.id}/rate",
            json={"stars": 5, "tip_amount": 5},
            headers=_headers(token),
        )
    assert response.status_code == 200, response.text
    assert response.json()["tip_amount"] == 0
    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.tip_amount == 0
    assert fresh_driver.pending_balance == 0
    assert fresh_driver.total_earnings == 0


async def test_tip_charges_once_and_duplicate_request_credits_once(
    client, db, test_rider, test_driver,
):
    rider, token = test_rider
    driver, _ = test_driver
    trip = await _money_trip(db, rider, driver, with_card=True)
    paid = _intent(trip, pi_id="pi_tip", kind="tip", cents=500)

    with patch("stripe.PaymentIntent.create", return_value=paid) as create:
        first = await client.post(
            f"/trips/{trip.id}/tip", json={"tip_amount": 5}, headers=_headers(token),
        )
        second = await client.post(
            f"/trips/{trip.id}/tip", json={"tip_amount": 5}, headers=_headers(token),
        )

    assert first.status_code == 200, first.text
    assert second.status_code == 200, second.text
    assert create.call_count == 1
    assert create.call_args.kwargs["idempotency_key"] == f"trip-tip-{trip.id}"
    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.tip_amount == 5
    assert fresh_trip.stripe_tip_payment_intent_id == "pi_tip"
    assert fresh_driver.pending_balance == 5
    assert fresh_driver.total_earnings == 5
    assert second.json()["already"] is True


async def test_rate_success_and_duplicate_rating_never_double_charge(
    client, db, test_rider, test_driver,
):
    rider, token = test_rider
    driver, _ = test_driver
    trip = await _money_trip(db, rider, driver, with_card=True)
    paid = _intent(trip, pi_id="pi_rate_tip", kind="tip", cents=500)
    with patch("stripe.PaymentIntent.create", return_value=paid) as create:
        first = await client.post(
            f"/trips/{trip.id}/rate",
            json={"stars": 5, "tip_amount": 5},
            headers=_headers(token),
        )
        duplicate = await client.post(
            f"/trips/{trip.id}/rate",
            json={"stars": 5, "tip_amount": 5},
            headers=_headers(token),
        )
    assert first.status_code == 200, first.text
    assert first.json()["tip_amount"] == 5.0
    assert duplicate.status_code == 409
    assert create.call_count == 1
    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.tip_amount == 5.0
    assert fresh_driver.pending_balance == 5.0
    assert fresh_driver.total_earnings == 5.0


async def test_charge_rejects_driver_not_assigned(client, db, test_rider, test_driver):
    rider, _ = test_rider
    other_driver, other_token = test_driver
    assigned = User(
        first_name="Assigned",
        last_name="Driver",
        email="assigned@test.com",
        phone="+10000000001",
        password_hash="x",
        role="driver",
        status="active",
        created_at=datetime.now(timezone.utc),
    )
    db.add(assigned)
    await db.commit()
    await db.refresh(assigned)
    trip = await _money_trip(db, rider, assigned)

    with patch("stripe.PaymentIntent.capture") as capture:
        response = await client.post(
            f"/trips/{trip.id}/charge", headers=_headers(other_token),
        )
    assert response.status_code == 403
    capture.assert_not_called()


async def test_partial_capture_and_failed_shortfall_split_only_collected_money(
    client, db, test_rider, test_driver,
):
    rider, _ = test_rider
    driver, driver_token = test_driver
    trip = await _money_trip(db, rider, driver, with_card=True)
    held = _intent(trip, status="requires_capture", cents=1000)
    captured = _intent(trip, status="succeeded", cents=1000)

    with patch("stripe.PaymentIntent.retrieve", return_value=held), \
         patch("stripe.PaymentIntent.capture", return_value=captured), \
         patch("stripe.PaymentIntent.create", side_effect=Exception("shortfall declined")):
        response = await client.post(
            f"/trips/{trip.id}/charge", headers=_headers(driver_token),
        )

    assert response.status_code == 200, response.text
    assert response.json()["payment_status"] == "partial"
    assert response.json()["collected_cents"] == 1000
    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.payment_status == "partial"
    assert fresh_trip.driver_earnings == 6.0
    assert fresh_trip.platform_fee == 4.0
    assert fresh_driver.pending_balance == 6.0
    assert fresh_driver.total_earnings == 6.0


async def test_successful_shortfall_completes_fare_without_replacing_main_pi(
    client, db, test_rider, test_driver,
):
    rider, _ = test_rider
    driver, driver_token = test_driver
    trip = await _money_trip(db, rider, driver, with_card=True)
    held = _intent(trip, status="requires_capture", cents=1000)
    captured = _intent(trip, status="succeeded", cents=1000)
    shortfall = _intent(trip, pi_id="pi_shortfall", kind="fare_shortfall", cents=1000)

    with patch("stripe.PaymentIntent.retrieve", return_value=held), \
         patch("stripe.PaymentIntent.capture", return_value=captured), \
         patch("stripe.PaymentIntent.create", return_value=shortfall):
        response = await client.post(
            f"/trips/{trip.id}/charge", headers=_headers(driver_token),
        )

    assert response.status_code == 200, response.text
    assert response.json()["payment_status"] == "paid"
    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.stripe_payment_intent_id == "pi_main"
    assert fresh_trip.driver_earnings == 12.0
    assert fresh_driver.pending_balance == 12.0


@pytest.mark.parametrize(
    "override",
    [
        {"currency": "eur"},
        {"amount": 1000},
        {"customer": "cus_other"},
        {"status": "canceled"},
        {"metadata": {"rider_id": "999", "kind": "fare"}},
    ],
)
async def test_hold_rejects_wrong_currency_amount_owner_customer_or_status(
    db, test_rider, override,
):
    rider, _ = test_rider
    rider.stripe_customer_id = "cus_rider"
    await db.commit()
    intent = {
        "id": "pi_hold",
        "status": "requires_capture",
        "amount": 2000,
        "currency": "usd",
        "customer": "cus_rider",
        "metadata": {"rider_id": str(rider.id), "kind": "fare"},
        **override,
    }
    with pytest.raises(HTTPException) as error:
        await validate_trip_hold(
            db,
            payment_intent_id="pi_hold",
            rider=rider,
            expected_cents=2000,
            stripe_module=_stripe_for(intent),
        )
    assert error.value.status_code == 402


async def test_succeeded_pi_is_rejected_for_new_booking_and_on_reuse(
    db, test_rider, test_driver,
):
    rider, _ = test_rider
    driver, _ = test_driver
    rider.stripe_customer_id = "cus_rider"
    await db.commit()
    intent = {
        "id": "pi_succeeded",
        "status": "succeeded",
        "amount": 2000,
        "amount_received": 2000,
        "currency": "usd",
        "customer": "cus_rider",
        "metadata": {"rider_id": str(rider.id), "kind": "fare"},
    }
    stripe = _stripe_for(intent)
    with pytest.raises(HTTPException) as captured:
        await validate_trip_hold(
            db,
            payment_intent_id="pi_succeeded",
            rider=rider,
            expected_cents=2000,
            stripe_module=stripe,
        )
    assert captured.value.status_code == 402

    await _money_trip(db, rider, driver, payment_intent_id="pi_succeeded")
    with pytest.raises(HTTPException) as reused:
        await validate_trip_hold(
            db,
            payment_intent_id="pi_succeeded",
            rider=rider,
            expected_cents=2000,
            stripe_module=stripe,
        )
    assert reused.value.status_code == 402


async def test_hold_increment_failure_is_not_ignored(db, test_rider):
    rider, _ = test_rider
    rider.stripe_customer_id = "cus_rider"
    await db.commit()
    intent = {
        "id": "pi_small",
        "status": "requires_capture",
        "amount": 1000,
        "currency": "usd",
        "customer": "cus_rider",
        "metadata": {"rider_id": str(rider.id), "kind": "fare"},
    }
    stripe = _stripe_for(intent)
    stripe.PaymentIntent.increment_authorization.side_effect = Exception("unsupported")
    with pytest.raises(HTTPException) as error:
        await validate_trip_hold(
            db,
            payment_intent_id="pi_small",
            rider=rider,
            expected_cents=2000,
            increment_if_needed=True,
            stripe_module=stripe,
        )
    assert error.value.status_code == 402


async def test_legacy_payout_transfer_is_gone_and_does_not_move_balance(
    client, db, test_driver,
):
    driver, token = test_driver
    driver.pending_balance = 100.0
    driver.stripe_connect_id = "acct_driver"
    await db.commit()
    with patch("stripe.Transfer.create") as transfer:
        response = await client.post(
            "/drivers/payout/transfer", headers=_headers(token),
        )
    assert response.status_code == 410
    transfer.assert_not_called()
    fresh_driver = await _reload(User, driver.id)
    assert fresh_driver.pending_balance == 100.0


async def _cancelled_with_fee(db, rider, driver):
    trip = await _money_trip(
        db, rider, driver, status="cancelled", payment_status="paid", fare=25.50,
    )
    trip.cancellation_fee = 5.0
    trip.driver_earnings = 3.0
    trip.platform_fee = 2.0
    driver.pending_balance = 3.0
    driver.total_earnings = 3.0
    await db.commit()
    return trip


async def test_refund_of_cancellation_fee_claws_back_that_fee(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _cancelled_with_fee(db, rider, driver)
    delta = await record_trip_refund(
        db, trip, cumulative_refund_cents=500, captured_cents=500,
    )
    await db.commit()
    assert delta == 3.0
    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.driver_earnings == 0
    assert fresh_driver.pending_balance == 0
    assert fresh_driver.total_earnings == 0


async def test_refund_beyond_cancellation_fee_preserves_fee_split(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _cancelled_with_fee(db, rider, driver)
    delta = await record_trip_refund(
        db, trip, cumulative_refund_cents=2000, captured_cents=2550,
    )
    await db.commit()
    assert delta == 0
    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.driver_earnings == 3.0
    assert fresh_driver.pending_balance == 3.0
    assert fresh_driver.total_earnings == 3.0


async def test_refund_stripe_failure_leaves_payment_and_balances_untouched(
    client, db, test_rider, test_driver,
):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _money_trip(db, rider, driver, payment_status="paid", with_split=True)
    original = _intent(trip, status="succeeded", cents=2000)
    with patch("routers.payments.STRIPE_SECRET", "configured"), \
         patch("stripe.PaymentIntent.retrieve", return_value=original), \
         patch("stripe.Refund.create", side_effect=Exception("stripe unavailable")):
        response = await client.post(
            "/payments/refund",
            json={"trip_id": trip.id, "amount": 5},
            headers=_make_auth_headers("test-dispatch-key"),
        )
    assert response.status_code == 502, response.text
    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.payment_status == "paid"
    assert fresh_trip.refund_amount == 0
    assert fresh_trip.refund_status is None
    assert fresh_trip.driver_earnings == 12.0
    assert fresh_driver.pending_balance == 12.0
    assert fresh_driver.total_earnings == 12.0


async def test_admin_refund_moves_stripe_money_and_claws_back_once_with_webhook(
    client, db, test_rider, test_driver,
):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _money_trip(
        db, rider, driver, payment_status="paid", with_split=True,
    )
    original = _intent(trip, status="succeeded", cents=2000)
    refund_event = {
        "id": "evt_refund_p0",
        "type": "charge.refunded",
        "data": {"object": {
            "id": "ch_p0",
            "payment_intent": "pi_main",
            "amount": 2000,
            "amount_refunded": 500,
        }},
    }

    with patch("routers.payments.STRIPE_SECRET", "configured"), \
         patch("stripe.PaymentIntent.retrieve", return_value=original), \
         patch("stripe.Refund.create", return_value={"id": "re_p0", "amount": 500}) as refund:
        response = await client.post(
            "/payments/refund",
            json={"trip_id": trip.id, "amount": 5, "reason": "requested_by_customer"},
            headers=_make_auth_headers("test-dispatch-key"),
        )
        duplicate = await client.post(
            "/payments/refund",
            json={"trip_id": trip.id, "amount": 5, "reason": "requested_by_customer"},
            headers=_make_auth_headers("test-dispatch-key"),
        )

    assert response.status_code == 200, response.text
    assert duplicate.status_code == 200, duplicate.text
    assert duplicate.json()["already"] is True
    assert refund.call_count == 1
    assert refund.call_args.kwargs["amount"] == 500
    fresh_driver = await _reload(User, driver.id)
    assert fresh_driver.pending_balance == 9.0
    assert fresh_driver.total_earnings == 9.0

    with patch("routers.webhooks._stripe_mod") as stripe_webhook:
        stripe_webhook.Webhook.construct_event.return_value = refund_event
        stripe_webhook.error.SignatureVerificationError = Exception
        webhook_response = await client.post(
            "/webhooks/stripe",
            json=refund_event,
            headers={"stripe-signature": "t=1,v1=test"},
        )
    assert webhook_response.status_code == 200, webhook_response.text

    other_delivery = {**refund_event, "id": "evt_refund_p0_other_delivery"}
    with patch("routers.payments._stripe_mod") as stripe_alias:
        stripe_alias.Webhook.construct_event.return_value = other_delivery
        stripe_alias.error.SignatureVerificationError = Exception
        alias_response = await client.post(
            "/payments/webhook",
            json=other_delivery,
            headers={"stripe-signature": "t=1,v1=test"},
        )
    assert alias_response.status_code == 200, alias_response.text
    fresh_driver = await _reload(User, driver.id)
    fresh_trip = await _reload(Trip, trip.id)
    assert fresh_driver.pending_balance == 9.0
    assert fresh_driver.total_earnings == 9.0
    assert fresh_trip.driver_earnings == 9.0
    assert fresh_trip.refund_amount == 5.0
    assert fresh_trip.refund_status == "partial"
