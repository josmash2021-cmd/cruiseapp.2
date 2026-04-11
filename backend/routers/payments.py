import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, RiderPaymentMethod, Vehicle, DispatchOffer, Rating,
)
from models.schemas import PaymentIntentIn, PayPalOrderIn, PayPalCaptureIn
from utils.security import (
    _get_current_user, _verify_api_key, _require_dispatch_auth,
    pwd, _create_token, _create_refresh_token, _create_login_token,
    _check_login_throttle, _record_login_failure, _clear_login_failures,
    JWT_SECRET, JWT_ALGORITHM,
)
from utils.helpers import _haversine, _abs_photo_url, _user_dict, _resolve_rider_display
from services.fcm_service import _send_fcm_push
from services.sms_service import notify_guest_welcome
from services.email_service import email_guest_welcome
from sqlalchemy.exc import IntegrityError
from jose import jwt, JWTError
from config import (
    STRIPE_SECRET, _HAS_STRIPE, _stripe_mod, STRIPE_WEBHOOK_SECRET,
    PAYPAL_CLIENT_ID, PAYPAL_SECRET, PAYPAL_SANDBOX,
    PAYPAL_CLIENT_SECRET, PAYPAL_MODE,
    firestore_sync, _HAS_FIRESTORE,
)
try:
    from utils.n8n_trigger import trigger_welcome_email
except ImportError:
    trigger_welcome_email = None

router = APIRouter()

@router.post("/payments/setup-intent", dependencies=[Depends(_verify_api_key)])
async def create_setup_intent(user: User = Depends(_get_current_user)):
    """Create a Stripe SetupIntent so the rider's card is authorised for future off-session charges."""
    if not _HAS_STRIPE:
        return {"client_secret": "seti_mock_secret_for_testing"}
    try:
        intent = _stripe_mod.SetupIntent.create(
            usage="off_session",
            metadata={"user_id": str(user.id)},
        )
        return {"client_secret": intent.client_secret}
    except _stripe_mod.error.StripeError as e:
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))


# -------------------------------------------------------
#  STRIPE PAYMENT ENDPOINTS
# -------------------------------------------------------

@router.post("/payments/create-intent", dependencies=[Depends(_verify_api_key)])
async def create_payment_intent(body: PaymentIntentIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Create a Stripe PaymentIntent for a ride payment."""
    # SECURITY: Validate payment amount against trip fare if trip_id provided
    if body.trip_id:
        trip_r = await db.execute(select(Trip).where(Trip.id == body.trip_id))
        trip = trip_r.scalar_one_or_none()
        if trip and trip.fare:
            expected_cents = int(trip.fare * 100)
            max_allowed = int(trip.fare * 1.20 * 100)  # Max 20% over fare (tip tolerance)
            if body.amount < expected_cents:
                raise HTTPException(400, f"Payment amount cannot be less than the trip fare (${trip.fare:.2f})")
            if body.amount > max_allowed:
                raise HTTPException(400, f"Payment amount exceeds maximum allowed (${trip.fare * 1.20:.2f})")
    if body.amount <= 0 or body.amount > 100000:  # Max $1000
        raise HTTPException(400, "Invalid payment amount")
    if not _HAS_STRIPE:
        # Return mock data when Stripe is not configured
        return {
            "client_secret": "mock_secret_for_testing",
            "payment_intent_id": f"pi_mock_{int(time.time())}",
            "status": "requires_payment_method",
            "amount": body.amount,
            "currency": body.currency,
        }
    try:
        intent_params = {
            "amount": body.amount,
            "currency": body.currency,
            "metadata": {"rider_id": str(user.id)},
        }
        if body.payment_method_id:
            intent_params["payment_method"] = body.payment_method_id
            intent_params["confirm"] = True
            intent_params["automatic_payment_methods"] = {
                "enabled": True,
                "allow_redirects": "never",
            }
        else:
            intent_params["automatic_payment_methods"] = {"enabled": True}

        # Hold-only: authorize but do NOT capture yet (capture on trip completion)
        if body.hold_only:
            intent_params["capture_method"] = "manual"

        if body.trip_id:
            intent_params["metadata"]["trip_id"] = str(body.trip_id)

        intent = _stripe_mod.PaymentIntent.create(**intent_params)
        return {
            "client_secret": intent.client_secret,
            "payment_intent_id": intent.id,
            "status": intent.status,
            "amount": intent.amount,
            "currency": intent.currency,
        }
    except _stripe_mod.error.StripeError as e:
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))


@router.get("/payments/intent/{intent_id}", dependencies=[Depends(_verify_api_key)])
async def get_payment_intent(intent_id: str, user: User = Depends(_get_current_user)):
    """Check the status of a PaymentIntent."""
    if not _HAS_STRIPE:
        return {"payment_intent_id": intent_id, "status": "succeeded", "amount": 0}
    try:
        intent = _stripe_mod.PaymentIntent.retrieve(intent_id)
        return {
            "payment_intent_id": intent.id,
            "status": intent.status,
            "amount": intent.amount,
            "currency": intent.currency,
        }
    except _stripe_mod.error.StripeError as e:
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))


@router.post("/payments/cancel/{intent_id}", dependencies=[Depends(_verify_api_key)])
async def cancel_payment_intent(intent_id: str, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Cancel a held PaymentIntent when a rider cancels before trip starts.
    Releasing the hold immediately so the rider's funds are freed."""
    # SECURITY: verify the caller owns this PaymentIntent (or is admin/dispatch)
    if user.role not in ("admin", "dispatch"):
        trip_r = await db.execute(
            select(Trip).where(Trip.stripe_payment_intent_id == intent_id)
        )
        trip = trip_r.scalar_one_or_none()
        if not trip:
            raise HTTPException(404, "No trip found for this payment intent")
        if trip.rider_id != user.id:
            logging.warning("[Payment] Unauthorized cancel attempt on %s by user %s", intent_id, user.id)
            raise HTTPException(403, "You are not authorized to cancel this payment")
    if not _HAS_STRIPE:
        return {"payment_intent_id": intent_id, "status": "canceled", "cancelled": True}
    try:
        intent = _stripe_mod.PaymentIntent.cancel(intent_id)
        logging.info("[Payment] Cancelled hold %s for user %s", intent_id, user.id)
        return {
            "payment_intent_id": intent.id,
            "status": intent.status,
            "cancelled": intent.status == "canceled",
        }
    except _stripe_mod.error.StripeError as e:
        # If already captured/succeeded, log but don't crash — trip was completed
        logging.warning("[Payment] Could not cancel %s: %s", intent_id, e)
        return {"payment_intent_id": intent_id, "status": "error", "cancelled": False}


@router.post("/payments/capture/{intent_id}", dependencies=[Depends(_verify_api_key)])
async def capture_payment_intent(intent_id: str, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Capture a previously authorized (held) PaymentIntent.
    Called when a trip is completed to finalize the charge."""
    # SECURITY: verify the caller owns this PaymentIntent (or is admin/dispatch)
    if user.role not in ("admin", "dispatch"):
        trip_r = await db.execute(
            select(Trip).where(Trip.stripe_payment_intent_id == intent_id)
        )
        trip = trip_r.scalar_one_or_none()
        if not trip:
            raise HTTPException(404, "No trip found for this payment intent")
        if trip.rider_id != user.id:
            logging.warning("[Payment] Unauthorized capture attempt on %s by user %s", intent_id, user.id)
            raise HTTPException(403, "You are not authorized to capture this payment")
    if not _HAS_STRIPE:
        return {"payment_intent_id": intent_id, "status": "succeeded", "captured": True}
    try:
        intent = _stripe_mod.PaymentIntent.capture(intent_id)
        return {
            "payment_intent_id": intent.id,
            "status": intent.status,
            "amount": intent.amount,
            "captured": intent.status == "succeeded",
        }
    except _stripe_mod.error.StripeError as e:
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))


# -- PayPal token exchange (proxied through backend -- never expose secret to client) --

@router.post("/payments/paypal/create-order", dependencies=[Depends(_verify_api_key)])
async def paypal_create_order(body: PayPalOrderIn, user: User = Depends(_get_current_user)):
    """Create a PayPal order � client secret stays on the server."""
    if not PAYPAL_CLIENT_ID or not PAYPAL_SECRET:
        return {"order_id": f"mock_paypal_{int(time.time())}", "approval_url": "", "status": "mock"}

    import httpx
    base = "https://api-m.sandbox.paypal.com" if PAYPAL_SANDBOX else "https://api-m.paypal.com"
    async with httpx.AsyncClient() as client:
        # Get access token
        auth_resp = await client.post(
            f"{base}/v1/oauth2/token",
            data={"grant_type": "client_credentials"},
            auth=(PAYPAL_CLIENT_ID, PAYPAL_SECRET),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if auth_resp.status_code != 200:
            raise HTTPException(502, "PayPal auth failed")
        token = auth_resp.json()["access_token"]

        # Create order
        order_resp = await client.post(
            f"{base}/v2/checkout/orders",
            json={
                "intent": "CAPTURE",
                "purchase_units": [{
                    "amount": {"currency_code": body.currency, "value": body.amount},
                }],
            },
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )
        if order_resp.status_code not in (200, 201):
            raise HTTPException(502, "PayPal order creation failed")
        order = order_resp.json()
        approval_url = next((l["href"] for l in order.get("links", []) if l["rel"] == "approve"), "")
        return {"order_id": order["id"], "approval_url": approval_url, "status": order["status"]}


# -- PayPal capture (after user approves the order) --

@router.post("/payments/paypal/capture-order", dependencies=[Depends(_verify_api_key)])
async def paypal_capture_order(body: PayPalCaptureIn, user: User = Depends(_get_current_user)):
    """Capture a PayPal order after the user has approved payment."""
    if not PAYPAL_CLIENT_ID or not PAYPAL_SECRET:
        return {"order_id": body.order_id, "status": "COMPLETED", "mock": True}

    import httpx
    base = "https://api-m.sandbox.paypal.com" if PAYPAL_SANDBOX else "https://api-m.paypal.com"
    async with httpx.AsyncClient() as client:
        auth_resp = await client.post(
            f"{base}/v1/oauth2/token",
            data={"grant_type": "client_credentials"},
            auth=(PAYPAL_CLIENT_ID, PAYPAL_SECRET),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if auth_resp.status_code != 200:
            raise HTTPException(502, "PayPal auth failed")
        token = auth_resp.json()["access_token"]

        capture_resp = await client.post(
            f"{base}/v2/checkout/orders/{body.order_id}/capture",
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )
        if capture_resp.status_code not in (200, 201):
            raise HTTPException(502, "PayPal capture failed")
        data = capture_resp.json()
        return {"order_id": data["id"], "status": data["status"]}


# -------------------------------------------------------
#  WEB CHECKOUT — Stripe Checkout Session (for website)
# -------------------------------------------------------

WEB_CHECKOUT_KEY = os.getenv("WEB_CHECKOUT_KEY", "")
WEB_ALLOWED_ORIGINS = os.getenv("WEB_ALLOWED_ORIGINS", "https://cruiseinride.com,https://www.cruiseinride.com").split(",")

def _verify_web_origin(request: Request):
    """Block requests not from allowed origins."""
    origin = request.headers.get("origin", "")
    referer = request.headers.get("referer", "")
    if origin and not any(origin.startswith(o.strip()) for o in WEB_ALLOWED_ORIGINS):
        raise HTTPException(403, "Origin not allowed")
    if not origin and referer and not any(referer.startswith(o.strip()) for o in WEB_ALLOWED_ORIGINS):
        raise HTTPException(403, "Referer not allowed")

@router.post("/payments/web/checkout")
async def create_web_checkout(request: Request):
    """Create a Stripe Checkout Session for website payments."""
    _verify_web_origin(request)
    client_ip = request.client.host if request.client else "unknown"
    if _check_web_rate_limit(client_ip):
        raise HTTPException(429, "Too many requests — try again in a minute")
    # Auth: simple bearer token check
    auth = request.headers.get("authorization", "")
    if not WEB_CHECKOUT_KEY or not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    if auth.split(" ", 1)[1] != WEB_CHECKOUT_KEY:
        raise HTTPException(401, "Invalid web checkout key")

    if not _HAS_STRIPE or not STRIPE_SECRET:
        raise HTTPException(503, "Stripe not configured")

    body = await request.json()
    amount = body.get("amount", 0)
    currency = body.get("currency", "usd")
    description = body.get("description", "Cruise Ride")
    success_url = body.get("success_url", "https://ridecruise.app/success")
    cancel_url = body.get("cancel_url", "https://ridecruise.app/cancel")
    customer_email = body.get("customer_email")
    metadata = body.get("metadata", {})

    if amount <= 0 or amount > 100000:
        raise HTTPException(400, "Invalid amount")

    # Determine payment methods based on what the client selected
    pm_types = ["card"]

    try:
        session_params = {
            "payment_method_types": pm_types,
            "line_items": [{
                "price_data": {
                    "currency": currency,
                    "unit_amount": amount,
                    "product_data": {"name": description},
                },
                "quantity": 1,
            }],
            "mode": "payment",
            "payment_intent_data": {
                "capture_method": "manual",  # HOLD — authorize only, capture on trip completion
                "metadata": metadata,
            },
            "success_url": success_url + "?session_id={CHECKOUT_SESSION_ID}",
            "cancel_url": cancel_url,
            "metadata": metadata,
        }
        if customer_email:
            session_params["customer_email"] = customer_email

        session = _stripe_mod.checkout.Session.create(**session_params)
        logging.info("[WebCheckout] Session created: %s (amount=%d %s)", session.id, amount, currency)
        return {"session_id": session.id, "url": session.url}
    except _stripe_mod.error.StripeError as e:
        logging.error("[WebCheckout] Stripe error: %s", e)
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))


# -------------------------------------------------------
#  WEB PAYMENT INTENT — for Apple Pay / Google Pay native sheets
# -------------------------------------------------------

@router.post("/payments/web/create-intent")
async def create_web_payment_intent(request: Request):
    """Create a Stripe PaymentIntent for native Apple Pay / Google Pay."""
    _verify_web_origin(request)
    client_ip = request.client.host if request.client else "unknown"
    if _check_web_rate_limit(client_ip):
        raise HTTPException(429, "Too many requests — try again in a minute")
    auth = request.headers.get("authorization", "")
    if not WEB_CHECKOUT_KEY or not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    if auth.split(" ", 1)[1] != WEB_CHECKOUT_KEY:
        raise HTTPException(401, "Invalid web checkout key")

    if not _HAS_STRIPE or not STRIPE_SECRET:
        raise HTTPException(503, "Stripe not configured")

    body = await request.json()
    amount = body.get("amount", 0)
    currency = body.get("currency", "usd")
    description = body.get("description", "Cruise Ride")
    metadata = body.get("metadata", {})

    if amount <= 0 or amount > 100000:
        raise HTTPException(400, "Invalid amount")

    try:
        intent = _stripe_mod.PaymentIntent.create(
            amount=amount,
            currency=currency,
            automatic_payment_methods={"enabled": True},
            capture_method="manual",  # HOLD — authorize only, capture later
            description=description,
            metadata=metadata,
        )
        logging.info("[WebPayIntent] HOLD created: %s (amount=%d %s)", intent.id, amount, currency)
        return {
            "client_secret": intent.client_secret,
            "payment_intent_id": intent.id,
        }
    except _stripe_mod.error.StripeError as e:
        logging.error("[WebPayIntent] Stripe error: %s", e)
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))


# -------------------------------------------------------
#  WEB CAPTURE / CANCEL HOLD — called when trip completes or cancels
# -------------------------------------------------------

@router.post("/payments/web/capture/{intent_id}")
async def capture_web_hold(intent_id: str, request: Request):
    """Capture a held PaymentIntent — charge the customer after trip completion."""
    _verify_web_origin(request)
    auth = request.headers.get("authorization", "")
    if not WEB_CHECKOUT_KEY or not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    if auth.split(" ", 1)[1] != WEB_CHECKOUT_KEY:
        raise HTTPException(401, "Invalid key")
    if not _HAS_STRIPE:
        raise HTTPException(503, "Stripe not configured")
    try:
        intent = _stripe_mod.PaymentIntent.capture(intent_id)
        logging.info("[WebCapture] Captured: %s (amount=%d)", intent.id, intent.amount_received)
        return {"status": intent.status, "amount_captured": intent.amount_received}
    except _stripe_mod.error.StripeError as e:
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))


@router.post("/payments/web/cancel/{intent_id}")
async def cancel_web_hold(intent_id: str, request: Request):
    """Cancel a held PaymentIntent — release the hold if trip is cancelled."""
    _verify_web_origin(request)
    auth = request.headers.get("authorization", "")
    if not WEB_CHECKOUT_KEY or not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    if auth.split(" ", 1)[1] != WEB_CHECKOUT_KEY:
        raise HTTPException(401, "Invalid key")
    if not _HAS_STRIPE:
        raise HTTPException(503, "Stripe not configured")
    try:
        intent = _stripe_mod.PaymentIntent.cancel(intent_id)
        logging.info("[WebCancel] Cancelled hold: %s", intent.id)
        return {"status": intent.status}
    except _stripe_mod.error.StripeError as e:
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))


from fastapi.responses import RedirectResponse

# Rate limiting for web checkout — max 10 requests per IP per minute
_web_checkout_hits: dict = {}  # ip -> [timestamps]
_WEB_CHECKOUT_MAX = 10
_WEB_CHECKOUT_WINDOW = 60  # seconds

def _check_web_rate_limit(ip: str) -> bool:
    now = time.monotonic()
    hits = _web_checkout_hits.get(ip, [])
    hits = [t for t in hits if now - t < _WEB_CHECKOUT_WINDOW]
    _web_checkout_hits[ip] = hits
    if len(hits) >= _WEB_CHECKOUT_MAX:
        return True  # blocked
    hits.append(now)
    return False

@router.get("/payments/web/book")
async def web_book_redirect(
    request: Request,
    amount: int = Query(..., description="Amount in cents"),
    key: str = Query(..., description="WEB_CHECKOUT_KEY"),
    description: str = Query("Cruise Ride"),
    currency: str = Query("usd"),
    success_url: str = Query("https://ridecruise.app/success"),
    cancel_url: str = Query("https://ridecruise.app/cancel"),
    email: str = Query(None),
):
    """GET endpoint that creates a Stripe Checkout Session and redirects
    the user directly to Stripe's payment page. Designed for Shopify —
    just link to this URL, no JavaScript needed."""
    client_ip = request.client.host if request.client else "unknown"
    if _check_web_rate_limit(client_ip):
        raise HTTPException(429, "Too many requests — try again in a minute")
    if not WEB_CHECKOUT_KEY or key != WEB_CHECKOUT_KEY:
        raise HTTPException(401, "Invalid key")
    if not _HAS_STRIPE or not STRIPE_SECRET:
        raise HTTPException(503, "Stripe not configured")
    if amount <= 0 or amount > 100000:
        raise HTTPException(400, "Invalid amount")

    try:
        session_params = {
            "payment_method_types": ["card"],
            "line_items": [{
                "price_data": {
                    "currency": currency,
                    "unit_amount": amount,
                    "product_data": {"name": description},
                },
                "quantity": 1,
            }],
            "mode": "payment",
            "success_url": success_url + "?session_id={CHECKOUT_SESSION_ID}",
            "cancel_url": cancel_url,
        }
        if email:
            session_params["customer_email"] = email

        session = _stripe_mod.checkout.Session.create(**session_params)
        logging.info("[WebBook] Redirect to Stripe: %s (amount=%d)", session.id, amount)
        return RedirectResponse(url=session.url, status_code=303)
    except _stripe_mod.error.StripeError as e:
        logging.error("[WebBook] Stripe error: %s", e)
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))


# -------------------------------------------------------
#  STRIPE WEBHOOK
# -------------------------------------------------------

# Idempotency: track processed Stripe event IDs to prevent double-processing
_processed_stripe_events: collections.OrderedDict = collections.OrderedDict()
_MAX_PROCESSED_EVENTS = 5000


@router.post("/payments/stripe/webhook")
@router.post("/payments/webhook")  # legacy alias
async def stripe_webhook(request: Request, db: AsyncSession = Depends(get_db)):
    """Handle Stripe webhook events (payment confirmations, refunds, etc.).
    No auth required -- Stripe calls this directly; signature verification is the auth."""
    payload = await request.body()
    sig_header = request.headers.get("stripe-signature", "")

    # Verify signature when STRIPE_WEBHOOK_SECRET is configured; skip check if not set
    if STRIPE_WEBHOOK_SECRET and _HAS_STRIPE:
        try:
            event = _stripe_mod.Webhook.construct_event(payload, sig_header, STRIPE_WEBHOOK_SECRET)
        except (ValueError, _stripe_mod.error.SignatureVerificationError) as e:
            logging.warning("[Stripe Webhook] Signature verification failed: %s", e)
            raise HTTPException(400, "Invalid signature")
    else:
        # No webhook secret configured -- parse payload directly (dev/test mode)
        try:
            event = json.loads(payload)
        except (ValueError, json.JSONDecodeError) as e:
            logging.warning("[Stripe Webhook] Invalid JSON payload: %s", e)
            raise HTTPException(400, "Invalid payload")
        logging.warning("[Stripe Webhook] Processing without signature verification (STRIPE_WEBHOOK_SECRET not set)")

    event_type = event.get("type", "")
    event_id = event.get("id", "")
    logging.info("[Stripe Webhook] Received event: %s (id=%s)", event_type, event_id)

    # Idempotency: skip already-processed events (Stripe retries on timeout)
    if event_id and event_id in _processed_stripe_events:
        logging.info("[Stripe Webhook] Skipping duplicate event: %s", event_id)
        return {"status": "duplicate_skipped"}
    if event_id:
        _processed_stripe_events[event_id] = time.time()
        # Cap size to prevent memory leak
        while len(_processed_stripe_events) > _MAX_PROCESSED_EVENTS:
            _processed_stripe_events.popitem(last=False)

    if event_type == "payment_intent.succeeded":
        intent = event["data"]["object"]
        trip_id = intent.get("metadata", {}).get("trip_id")
        payment_intent_id = intent.get("id", "")
        if trip_id:
            try:
                trip_r = await db.execute(select(Trip).where(Trip.id == int(trip_id)))
                trip = trip_r.scalar_one_or_none()
                if trip and trip.payment_status != "paid":
                    trip.payment_status = "paid"
                    if payment_intent_id:
                        trip.stripe_payment_intent_id = payment_intent_id
                    await db.commit()
                    logging.info(
                        "[Stripe Webhook] Trip %s payment confirmed via webhook (pi=%s)",
                        trip_id, payment_intent_id,
                    )
                elif trip:
                    logging.info("[Stripe Webhook] Trip %s already marked as paid, skipping", trip_id)
            except Exception as e:
                logging.error("[Stripe Webhook] Failed to update trip %s on payment_intent.succeeded: %s", trip_id, e)

    elif event_type == "payment_intent.payment_failed":
        intent = event["data"]["object"]
        trip_id = intent.get("metadata", {}).get("trip_id")
        error_msg = (intent.get("last_payment_error") or {}).get("message", "Payment failed")
        logging.warning("[Stripe Webhook] Payment failed for trip %s: %s", trip_id, error_msg)
        if trip_id:
            try:
                trip_r = await db.execute(select(Trip).where(Trip.id == int(trip_id)))
                trip = trip_r.scalar_one_or_none()
                if trip:
                    trip.payment_status = "failed"
                    await db.commit()
                    logging.info("[Stripe Webhook] Trip %s marked as payment failed", trip_id)
                    # Notify rider via FCM if token available
                    try:
                        from models.database import User
                        rider_r = await db.execute(select(User).where(User.id == trip.rider_id))
                        rider = rider_r.scalar_one_or_none()
                        if rider and rider.fcm_token:
                            from services.fcm_service import _send_fcm_push
                            _send_fcm_push(
                                rider.fcm_token,
                                "Payment Failed",
                                f"Your payment for trip #{trip_id} failed. Please update your payment method.",
                                {"type": "payment_failed", "trip_id": str(trip_id)},
                            )
                    except Exception as fcm_err:
                        logging.warning("[Stripe Webhook] FCM notify failed for trip %s: %s", trip_id, fcm_err)
            except Exception as e:
                logging.error("[Stripe Webhook] Failed to update trip %s on payment_failed: %s", trip_id, e)

    elif event_type == "charge.refunded":
        charge = event["data"]["object"]
        pi_id = charge.get("payment_intent")
        if pi_id:
            try:
                trip_r = await db.execute(select(Trip).where(Trip.stripe_payment_intent_id == pi_id))
                trip = trip_r.scalar_one_or_none()
                if trip:
                    refunded_cents = charge.get("amount_refunded", 0)
                    total_cents = charge.get("amount", 0)
                    refund_amount = round(refunded_cents / 100, 2)
                    # Clawback BEFORE updating payment_status so the
                    # idempotency guard inside the helper still works.
                    await _apply_refund_clawback(db, trip, refund_amount)
                    trip.refund_amount = refund_amount
                    trip.refund_status = "full" if refunded_cents >= total_cents else "partial"
                    trip.payment_status = "refunded"
                    await db.commit()
                    logging.info(
                        "[Stripe Webhook] Refund recorded for trip %s: $%.2f (%s)",
                        trip.id, trip.refund_amount, trip.refund_status,
                    )
            except Exception as e:
                logging.error("[Stripe Webhook] Failed to process refund for pi=%s: %s", pi_id, e)

    return {"status": "ok"}


async def _apply_refund_clawback(db: AsyncSession, trip: Trip, refund_amount: float) -> None:
    """Decrement the driver's pending / total balances proportional to the
    refund.  Idempotent — if the trip was already marked as refunded, the
    clawback is skipped so the Stripe webhook and the admin refund endpoint
    can never double-decrement when both run for the same trip.

    Clawback strategy:
      • Compute the driver's share of the refund as:
            clawback = driver_earnings * (refund_amount / fare)
      • Clamp pending_balance at zero — if the driver already cashed out,
        we log a warning with the unrecovered debt so an operator can do
        a manual adjustment.
      • Always decrement total_earnings by the full clawback so lifetime
        stats reflect reality.
    """
    if (trip.payment_status or "").lower() == "refunded":
        logging.info(
            "[Refund] Trip %d already marked refunded — clawback skipped (idempotent)",
            trip.id,
        )
        return
    if not trip.driver_id:
        return
    fare = float(trip.fare or 0)
    driver_earnings = float(trip.driver_earnings or 0)
    if fare <= 0 or driver_earnings <= 0:
        logging.info(
            "[Refund] Trip %d has no driver earnings to claw back (fare=%.2f, earnings=%.2f)",
            trip.id, fare, driver_earnings,
        )
        return

    ratio = min(1.0, max(0.0, refund_amount / fare))
    clawback = round(driver_earnings * ratio, 2)
    if clawback <= 0:
        return

    drv_r = await db.execute(select(User).where(User.id == trip.driver_id))
    drv = drv_r.scalar_one_or_none()
    if not drv:
        logging.warning(
            "[Refund] Trip %d — driver %d not found for clawback of $%.2f",
            trip.id, trip.driver_id, clawback,
        )
        return

    pending_before = float(drv.pending_balance or 0)
    pending_after = max(0.0, round(pending_before - clawback, 2))
    actual_clawback = round(pending_before - pending_after, 2)
    drv.pending_balance = pending_after
    # Decrement total_earnings by the full clawback even if pending can't
    # cover it — lifetime stats should reflect the real payment outcome.
    drv.total_earnings = max(
        0.0, round(float(drv.total_earnings or 0) - clawback, 2)
    )

    # Also reduce the trip's driver_earnings so the cashout endpoint in
    # drivers.py (which recomputes available_balance from trip rows) sees
    # the refund. Without this, pending_balance and the cashout calculation
    # would diverge and a clawed-back driver could still cash out the old
    # amount.
    trip.driver_earnings = max(0.0, round(driver_earnings - clawback, 2))

    if actual_clawback < clawback:
        debt = round(clawback - actual_clawback, 2)
        logging.warning(
            "[Refund] PARTIAL clawback on trip %d — driver %d only had "
            "$%.2f pending, $%.2f debt remains (manual adjustment needed)",
            trip.id, trip.driver_id, pending_before, debt,
        )
    logging.info(
        "[Refund] Clawed back $%.2f from driver %d on trip %d (pending %.2f -> %.2f, refund_amount=$%.2f)",
        actual_clawback, trip.driver_id, trip.id, pending_before, pending_after, refund_amount,
    )


# ═══════════════════════════════════════════════════════
#  DISPATCH ADMIN — REFUND & TRIP PAYMENT DETAIL
# ═══════════════════════════════════════════════════════

@router.post("/payments/refund", dependencies=[Depends(_require_dispatch_auth)])
async def admin_refund_trip(request: Request, db: AsyncSession = Depends(get_db)):
    """Process a trip refund from the dispatch admin app.
    Body: {"trip_id": int, "amount": float (optional, defaults to full fare), "reason": str}
    """
    body = await request.json()
    trip_id = body.get("trip_id")
    reason = body.get("reason", "")
    if not trip_id:
        raise HTTPException(400, "trip_id is required")
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")

    # Determine refund amount — default to full fare
    amount = body.get("amount")
    if amount is None:
        amount = float(trip.fare or 0.0)
    amount = round(float(amount), 2)
    if amount <= 0:
        raise HTTPException(400, "Refund amount must be positive")
    if trip.fare and amount > float(trip.fare):
        raise HTTPException(400, "Refund amount cannot exceed trip fare")

    # Clawback driver earnings BEFORE marking payment_status=refunded so
    # the idempotency guard inside _apply_refund_clawback still works.
    await _apply_refund_clawback(db, trip, amount)
    trip.refund_status = "full" if (trip.fare and amount >= float(trip.fare)) else "partial"
    trip.refund_amount = amount
    trip.refund_reason = reason
    trip.payment_status = "refunded"
    await db.commit()
    await db.refresh(trip)
    logging.info("[Refund] trip_id=%s amount=%.2f reason=%s", trip_id, amount, reason)
    return {"ok": True, "refund_amount": amount}


@router.get("/payments/trip/{trip_id}", dependencies=[Depends(_require_dispatch_auth)])
async def get_trip_payment_details(trip_id: int, db: AsyncSession = Depends(get_db)):
    """Get payment details for a specific trip. For dispatch admin app."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    return {
        "trip_id": trip.id,
        "fare": trip.fare,
        "payment_status": trip.payment_status or "unpaid",
        "stripe_payment_intent_id": trip.stripe_payment_intent_id,
        "refund_status": trip.refund_status,
        "refund_amount": float(trip.refund_amount or 0.0),
        "driver_earnings": float(trip.driver_earnings or 0.0),
        "platform_fee": float(trip.platform_fee or 0.0),
        "tip_amount": float(trip.tip_amount or 0.0),
    }


# -------------------------------------------------------
#  PAYPAL PAYMENTS
# -------------------------------------------------------

def _paypal_base_url() -> str:
    return (
        "https://api-m.paypal.com"
        if PAYPAL_MODE == "live"
        else "https://api-m.sandbox.paypal.com"
    )

async def _get_paypal_access_token() -> str:
    """Obtain a PayPal OAuth2 access token using client_credentials grant."""
    import base64, urllib.request, urllib.parse
    url   = f"{_paypal_base_url()}/v1/oauth2/token"
    creds = base64.b64encode(f"{PAYPAL_CLIENT_ID}:{PAYPAL_CLIENT_SECRET}".encode()).decode()
    data  = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode()
    req   = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Authorization", f"Basic {creds}")
    req.add_header("Content-Type",  "application/x-www-form-urlencoded")
    loop  = asyncio.get_event_loop()
    def _fetch():
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read().decode())
    result = await loop.run_in_executor(None, _fetch)
    return result["access_token"]

@router.post("/paypal/create-order", dependencies=[Depends(_verify_api_key)])
async def create_paypal_order(body: PayPalOrderIn):
    """Create a PayPal order and return the approval URL for the WebView."""
    if not PAYPAL_CLIENT_ID or not PAYPAL_CLIENT_SECRET:
        raise HTTPException(503, "PayPal is not configured on this server")
    try:
        access_token = await _get_paypal_access_token()
        return_url   = "https://cruise-app.com/paypal/success"
        cancel_url   = "https://cruise-app.com/paypal/cancel"
        order_payload = {
            "intent": "CAPTURE",
            "purchase_units": [{
                "amount":      {"currency_code": body.currency, "value": body.amount},
                "description": body.description,
            }],
            "application_context": {
                "return_url": return_url,
                "cancel_url": cancel_url,
                "user_action": "PAY_NOW",
                "brand_name":  "Cruise",
            },
        }
        import urllib.request
        url  = f"{_paypal_base_url()}/v2/checkout/orders"
        data = json.dumps(order_payload).encode()
        req  = urllib.request.Request(url, data=data, method="POST")
        req.add_header("Authorization", f"Bearer {access_token}")
        req.add_header("Content-Type",  "application/json")
        loop = asyncio.get_event_loop()
        def _create():
            with urllib.request.urlopen(req, timeout=15) as r:
                return json.loads(r.read().decode())
        result = await loop.run_in_executor(None, _create)
        approval_url = next(
            (lnk["href"] for lnk in result.get("links", []) if lnk["rel"] == "approve"),
            None,
        )
        if not approval_url:
            raise HTTPException(500, "PayPal did not return an approval URL")
        logging.info("[PayPal] Order created: %s", result.get("id"))
        return {"order_id": result["id"], "approval_url": approval_url}
    except HTTPException:
        raise
    except Exception as e:
        logging.error("[PayPal] create_paypal_order failed: %s", e)
        raise HTTPException(502, f"PayPal error: {str(e)}")


# -------------------------------------------------------
#  WEB BOOKING — Create trip from Shopify & dispatch to drivers
# -------------------------------------------------------

WEB_SYSTEM_USER_ID = int(os.getenv("WEB_SYSTEM_USER_ID", "0"))


def _web_key_check(request: Request):
    auth = request.headers.get("authorization", "")
    if not WEB_CHECKOUT_KEY or not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    if auth.split(" ", 1)[1] != WEB_CHECKOUT_KEY:
        raise HTTPException(401, "Invalid web checkout key")


@router.post("/bookings/web/create")
async def web_create_booking(request: Request, db: AsyncSession = Depends(get_db)):
    """Create a trip from the Shopify booking widget and dispatch to nearby drivers."""
    _verify_web_origin(request)
    _web_key_check(request)

    body = await request.json()
    logging.info(
        "[WebBooking] RAW scheduled fields: scheduled_at=%r scheduled_date=%r scheduled_time=%r",
        body.get("scheduled_at"), body.get("scheduled_date"), body.get("scheduled_time"),
    )
    # Accept both flat and nested payload shapes (Shopify widget sends nested)
    pickup_obj = body.get("pickup") if isinstance(body.get("pickup"), dict) else {}
    dropoff_obj = body.get("dropoff") if isinstance(body.get("dropoff"), dict) else {}
    pickup_address = body.get("pickup_address") or pickup_obj.get("address") or ""
    pickup_lat = float(body.get("pickup_lat") or pickup_obj.get("lat") or 0)
    pickup_lng = float(body.get("pickup_lng") or pickup_obj.get("lng") or 0)
    dropoff_address = body.get("dropoff_address") or dropoff_obj.get("address") or ""
    dropoff_lat = float(body.get("dropoff_lat") or dropoff_obj.get("lat") or 0)
    dropoff_lng = float(body.get("dropoff_lng") or dropoff_obj.get("lng") or 0)
    vehicle_type = (body.get("vehicle_type") or "comfort").lower()
    fare_cents = int(body.get("amount_cents", 0))
    payment_intent_id = body.get("payment_intent_id")
    scheduled_date = body.get("scheduled_date")
    scheduled_time = body.get("scheduled_time")
    contact_name = body.get("contact_name") or "Web Booking"
    contact_phone = body.get("contact_phone") or ""

    # Preferred: the Shopify widget now sends discrete guest fields via the
    # "Continue as Guest" flow. Legacy clients still send contact_name /
    # contact_phone, so we fall back to splitting contact_name on the first
    # space when the new fields are absent.
    guest_first_name = (body.get("rider_first_name") or "").strip()
    guest_last_name = (body.get("rider_last_name") or "").strip()
    guest_phone = (body.get("rider_phone") or "").strip()
    guest_email = (body.get("rider_email") or "").strip().lower()
    guest_lang = (body.get("rider_lang") or "en").strip().lower()[:2]
    if guest_lang not in ("en", "es"):
        guest_lang = "en"
    if not guest_first_name and not guest_last_name and contact_name and contact_name != "Web Booking":
        _parts = contact_name.strip().split(" ", 1)
        guest_first_name = _parts[0]
        guest_last_name = _parts[1] if len(_parts) > 1 else ""
    if not guest_phone:
        guest_phone = contact_phone

    if not pickup_address or not dropoff_address:
        raise HTTPException(400, "pickup_address and dropoff_address are required")

    # Resolve the rider:
    #   1) If the Shopify widget forwards a rider JWT in `user_token`, use that user.
    #   2) Else fall back to WEB_SYSTEM_USER_ID env var.
    #   3) Else look up/auto-create a shared web@cruiseinride.com account.
    rider_id = 0
    user_token = body.get("user_token") or ""
    if user_token:
        try:
            payload = jwt.decode(user_token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
            uid = int(payload.get("sub") or 0)
            if uid:
                r = await db.execute(select(User).where(User.id == uid, User.role == "rider"))
                u = r.scalar_one_or_none()
                if u and u.status not in ("deleted", "pending_deletion"):
                    rider_id = u.id
        except Exception as _e:
            logging.warning("[WebBooking] user_token decode failed: %s", _e)

    if not rider_id and WEB_SYSTEM_USER_ID:
        r = await db.execute(select(User).where(User.id == WEB_SYSTEM_USER_ID))
        if r.scalar_one_or_none():
            rider_id = WEB_SYSTEM_USER_ID

    if not rider_id:
        r = await db.execute(select(User).where(User.email == "web@cruiseinride.com"))
        sys_user = r.scalar_one_or_none()
        if sys_user:
            rider_id = sys_user.id

    if not rider_id:
        # Auto-create a shared web system user so first-time deploys don't 503
        try:
            sys_user = User(
                first_name="Web",
                last_name="Booking",
                email="web@cruiseinride.com",
                password_hash=pwd.hash(secrets.token_urlsafe(24)),
                role="rider",
                status="active",
            )
            db.add(sys_user)
            await db.commit()
            await db.refresh(sys_user)
            rider_id = sys_user.id
            logging.info("[WebBooking] Auto-created system user web@cruiseinride.com id=%d", rider_id)
        except Exception as _e:
            await db.rollback()
            logging.error("[WebBooking] Failed to auto-create system user: %s", _e)
            raise HTTPException(503, "Web booking system user could not be created")

    # Resolve scheduled_at with two guards:
    #   1) The Shopify widget pre-fills scheduled_date / scheduled_time with
    #      the current date/time even when the rider taps "Book now", so we
    #      treat anything within 3 minutes of now as an immediate booking
    #      and clear scheduled_at — otherwise the driver offer card would
    #      render with a "VIAJE RESERVADO" badge for a normal on-demand ride.
    #   2) Hardcoding "+00:00" assumed the widget always sent UTC; we try
    #      a couple of timezone interpretations so local-time payloads do
    #      not end up shifted.
    # Prefer the widget-computed ISO string (which carries the user's local
    # timezone offset). Fall back to scheduled_date + scheduled_time, which
    # the old widget sent without timezone info — we interpret those as UTC
    # which is wrong but kept as a safety net for legacy clients.
    scheduled_at = None
    raw_iso = (body.get("scheduled_at") or "").strip()
    parsed: datetime | None = None
    if raw_iso:
        try:
            parsed = datetime.fromisoformat(raw_iso.replace("Z", "+00:00"))
        except Exception:
            parsed = None
    if parsed is None and scheduled_date and scheduled_time:
        raw = f"{scheduled_date}T{scheduled_time}"
        for candidate in (raw, f"{raw}:00", f"{raw}:00+00:00"):
            try:
                parsed = datetime.fromisoformat(candidate)
                break
            except Exception:
                continue
    if parsed is not None:
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        now_utc = datetime.now(timezone.utc)
        if parsed - now_utc < timedelta(minutes=3):
            logging.info(
                "[WebBooking] scheduled_at %s is within 3 min of now — treating as immediate",
                parsed.isoformat(),
            )
            scheduled_at = None
        else:
            scheduled_at = parsed

    fare = fare_cents / 100.0 if fare_cents else None
    notes_text = f"Web booking \u2014 {contact_name}"
    if contact_phone:
        notes_text += f" \u00b7 {contact_phone}"

    # A future scheduled booking must enter the scheduled-ride marketplace
    # rather than the live dispatch path — otherwise the driver offer card
    # fires right now for a trip that is not actually ready to pick up.
    # The scheduled-ride dispatcher in main.py handles the hand-off when
    # the pickup time gets close enough.
    is_future_scheduled = scheduled_at is not None
    trip_status = "scheduled" if is_future_scheduled else "requested"

    try:
        trip = Trip(
            rider_id=rider_id,
            pickup_address=pickup_address,
            pickup_lat=pickup_lat,
            pickup_lng=pickup_lng,
            dropoff_address=dropoff_address,
            dropoff_lat=dropoff_lat,
            dropoff_lng=dropoff_lng,
            vehicle_type=vehicle_type,
            fare=fare,
            status=trip_status,
            stripe_payment_intent_id=payment_intent_id,
            scheduled_at=scheduled_at,
            notes=notes_text,
            guest_first_name=guest_first_name or None,
            guest_last_name=guest_last_name or None,
            guest_phone=guest_phone or None,
            guest_email=guest_email or None,
            guest_lang=guest_lang or "en",
            payment_status="held" if payment_intent_id else "unpaid",
        )
        db.add(trip)
        await db.commit()
        await db.refresh(trip)
    except Exception as e:
        await db.rollback()
        logging.error("[WebBooking] Create trip failed: %s", e)
        raise HTTPException(500, f"Failed to create booking: {e}")

    # Guest SMS: welcome message (no-op if trip.guest_phone is empty).
    # Fired AFTER commit so a rolled-back transaction cannot trigger an SMS.
    try:
        await notify_guest_welcome(db, trip)
    except Exception as _sms_err:
        logging.warning("[SMS] notify_guest_welcome failed for trip %s: %s", trip.id, _sms_err)
    try:
        await email_guest_welcome(db, trip)
    except Exception as _email_err:
        logging.warning("[EMAIL] email_guest_welcome failed for trip %s: %s", trip.id, _email_err)

    if is_future_scheduled:
        logging.info(
            "[WebBooking] Created SCHEDULED trip %d for %s (%.2f %s) — marketplace will pick it up",
            trip.id, scheduled_at.isoformat(), fare or 0, vehicle_type,
        )
        # Mirror the rider-app /trips path: sync Firestore and broadcast to drivers
        # so web-scheduled bookings enter the exact same marketplace pipeline.
        _rn, _rp = _resolve_rider_display(trip, None)
        _trip_snap = {
            "id": trip.id, "rider_id": trip.rider_id or 0, "rider_name": _rn, "rider_phone": _rp,
            "pickup_address": trip.pickup_address, "pickup_lat": trip.pickup_lat, "pickup_lng": trip.pickup_lng,
            "dropoff_address": trip.dropoff_address, "dropoff_lat": trip.dropoff_lat, "dropoff_lng": trip.dropoff_lng,
            "status": trip.status, "fare": trip.fare, "vehicle_type": trip.vehicle_type,
            "created_at": trip.created_at, "scheduled_at": trip.scheduled_at,
            "is_airport": getattr(trip, "is_airport", False) or False,
            "airport_code": getattr(trip, "airport_code", None),
            "terminal": getattr(trip, "terminal", None),
            "pickup_zone": getattr(trip, "pickup_zone", None),
            "notes": trip.notes,
        }
        async def _bg_sched_firestore_sync():
            try:
                if _HAS_FIRESTORE and firestore_sync:
                    firestore_sync.sync_trip(
                        trip_id=_trip_snap["id"], rider_id=_trip_snap["rider_id"],
                        rider_name=_trip_snap["rider_name"], rider_phone=_trip_snap["rider_phone"],
                        pickup_address=_trip_snap["pickup_address"], pickup_lat=_trip_snap["pickup_lat"], pickup_lng=_trip_snap["pickup_lng"],
                        dropoff_address=_trip_snap["dropoff_address"], dropoff_lat=_trip_snap["dropoff_lat"], dropoff_lng=_trip_snap["dropoff_lng"],
                        status=_trip_snap["status"], fare=_trip_snap["fare"], vehicle_type=_trip_snap["vehicle_type"],
                        created_at=_trip_snap["created_at"], scheduled_at=_trip_snap["scheduled_at"],
                        is_airport=_trip_snap["is_airport"], airport_code=_trip_snap["airport_code"],
                        terminal=_trip_snap["terminal"], pickup_zone=_trip_snap["pickup_zone"], notes=_trip_snap["notes"],
                    )
            except Exception as _e:
                logging.warning("[WebBooking] Firestore sync scheduled trip %d failed: %s", trip.id, _e)
        asyncio.create_task(_bg_sched_firestore_sync())
        try:
            from services.fcm_service import send_to_topic_async
            _fare_str = f"${trip.fare:.2f}" if trip.fare else ""
            _pu = (trip.pickup_address or "")[:40]
            _do = (trip.dropoff_address or "")[:40]
            _sched_str = trip.scheduled_at.strftime("%b %d %I:%M %p") if trip.scheduled_at else ""
            _body = f"{_fare_str} \u00b7 {_pu} \u2192 {_do} \u00b7 {_sched_str}".strip(" \u00b7")
            asyncio.create_task(send_to_topic_async(
                topic="drivers_available",
                title="New Scheduled Ride Available",
                body=_body,
                data={"type": "scheduled_ride", "trip_id": str(trip.id)},
            ))
        except Exception as _fcm_err:
            logging.warning("[WebBooking] FCM scheduled-ride broadcast failed: %s", _fcm_err)
    else:
        # Immediate booking — dispatch to nearest driver INLINE so the offer
        # hits the driver app before the widget's first poll. Auto-cascade to
        # subsequent drivers (if the first doesn't accept) still runs in the
        # background so we don't block on offer timeouts.
        try:
            await asyncio.wait_for(
                _web_dispatch_to_drivers(trip.id, pickup_lat, pickup_lng, vehicle_type, fare),
                timeout=3.0,
            )
        except asyncio.TimeoutError:
            logging.warning("[WebBooking] dispatch inline timeout for trip %d — continuing", trip.id)
        except Exception as _dx:
            logging.warning("[WebBooking] dispatch inline error for trip %d: %s", trip.id, _dx)
        logging.info(
            "[WebBooking] Created trip %d (%.2f %s) → dispatched",
            trip.id, fare or 0, vehicle_type,
        )
    return {"booking_id": trip.id, "status": trip.status}


async def _web_dispatch_to_drivers(
    trip_id: int, pickup_lat: float, pickup_lng: float, vehicle_type: str, fare: float | None
):
    """Find the nearest online driver and send an offer using the SAME dispatch
    path as the mobile app (SSE event_bus push + FCM offer notification +
    auto-cascade to next driver if unanswered). This ensures a web booking
    behaves identically to an app booking from the driver's perspective."""
    try:
        # Import here to avoid a circular import at module load
        from routers.dispatch import _send_offer_to_driver, _auto_cascade

        async with SessionLocal() as db:
            r = await db.execute(select(Trip).where(Trip.id == trip_id))
            trip = r.scalar_one_or_none()
            if not trip:
                return

            # Guest info takes priority — rider_id on web bookings points to
            # the shared web@cruiseinride.com system user, whose "name" would
            # otherwise overwrite the actual guest name collected at checkout.
            # _resolve_rider_display centralises this preference.
            rider = None
            if trip.rider_id:
                rr = await db.execute(select(User).where(User.id == trip.rider_id))
                rider = rr.scalar_one_or_none()
            rider_name, rider_phone = _resolve_rider_display(trip, rider)
            rider_photo = (
                _abs_photo_url(rider.photo_url) if rider else ""
            ) or ""

            # Fetch online drivers with known location (match vehicle_type if possible)
            result = await db.execute(
                select(User).where(
                    User.role == "driver",
                    User.is_online == True,
                    User.lat != None,
                    User.lng != None,
                    User.status == "active",
                )
            )
            all_drivers = result.scalars().all()
            if not all_drivers:
                logging.warning("[WebDispatch] No online drivers for trip %d", trip_id)
                return

            # Sort by distance
            nearby = sorted(
                [(d, _haversine(pickup_lat, pickup_lng, d.lat, d.lng)) for d in all_drivers],
                key=lambda x: x[1],
            )
            first_driver = nearby[0][0]

            # Send offer via the SAME mechanism as the app dispatch
            offer = await _send_offer_to_driver(
                db, trip, first_driver, rider_name, rider_phone, rider_photo,
            )
            logging.info(
                "[WebDispatch] Trip %d offered to driver %d (%.2f km away) — cascade enabled",
                trip_id, first_driver.id, nearby[0][1],
            )

            # Auto-cascade to next drivers if not accepted
            asyncio.create_task(_auto_cascade(trip_id, offer.id, first_driver.id))

    except Exception as e:
        logging.exception("[WebDispatch] Error for trip %d: %s", trip_id, e)


@router.get("/bookings/web/{booking_id}/status")
async def web_booking_status(booking_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Poll status of a web booking. Returns driver + vehicle info once a driver accepts."""
    _verify_web_origin(request)
    _web_key_check(request)

    r = await db.execute(select(Trip).where(Trip.id == booking_id))
    trip = r.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Booking not found")

    # Normalise internal trip states into the simple vocabulary the
    # Shopify widget understands (requested / accepted / in_progress /
    # completed / cancelled). The widget flips to the "Driver Found"
    # screen as soon as it sees "accepted" or "driver_assigned".
    _raw = (trip.status or "").lower()
    if _raw in ("requested", "pending", "searching"):
        _web_status = "requested"
    elif _raw in ("driver_en_route", "driver_enroute", "accepted", "driver_assigned", "arrived", "arrived_at_pickup"):
        _web_status = "accepted"
    elif _raw in ("in_trip", "in_progress", "on_trip"):
        _web_status = "in_progress"
    elif _raw in ("completed", "ended"):
        _web_status = "completed"
    elif _raw in ("canceled", "cancelled", "no_driver"):
        _web_status = "cancelled"
    else:
        _web_status = _raw or "requested"

    resp: dict = {
        "status": _web_status,
        "raw_status": trip.status,
        "booking_id": trip.id,
    }

    if trip.driver_id:
        # Fetch driver user
        dr = await db.execute(select(User).where(User.id == trip.driver_id))
        driver = dr.scalar_one_or_none()
        if driver:
            resp["driver_name"] = f"{driver.first_name or ''} {driver.last_name or ''}".strip()
            resp["driver_photo_url"] = _abs_photo_url(driver.photo_url) or ""
            # Only expose the driver rating if they have been rated at least once
            drv_cnt_res = await db.execute(
                select(func.count(Rating.id)).where(Rating.to_user_id == driver.id)
            )
            drv_ratings_count = int(drv_cnt_res.scalar() or 0)
            resp["driver_ratings_count"] = drv_ratings_count
            resp["driver_is_new"] = drv_ratings_count == 0
            if drv_ratings_count > 0 and driver.average_rating is not None:
                resp["driver_rating"] = round(float(driver.average_rating), 1)
            else:
                resp["driver_rating"] = None

            # Fetch driver's vehicle — prefer matching vehicle_type
            vq = (
                select(Vehicle)
                .where(Vehicle.user_id == driver.id)
                .order_by(Vehicle.id.desc())
                .limit(1)
            )
            if trip.vehicle_type:
                vq_typed = (
                    select(Vehicle)
                    .where(Vehicle.user_id == driver.id, Vehicle.vehicle_type == trip.vehicle_type)
                    .order_by(Vehicle.id.desc())
                    .limit(1)
                )
                vr = await db.execute(vq_typed)
                vehicle = vr.scalar_one_or_none()
                if not vehicle:
                    vr = await db.execute(vq)
                    vehicle = vr.scalar_one_or_none()
            else:
                vr = await db.execute(vq)
                vehicle = vr.scalar_one_or_none()

            if vehicle:
                resp["vehicle_make"] = vehicle.make or ""
                resp["vehicle_model"] = vehicle.model or ""
                resp["vehicle_plate"] = vehicle.plate or ""
                resp["vehicle_year"] = vehicle.year or ""
                resp["vehicle_color"] = vehicle.color or ""

    return resp


# -------------------------------------------------------
#  WEB AUTH — Register / Login / Social (for Shopify widget)
#  Uses WEB_CHECKOUT_KEY instead of HMAC-based _verify_api_key
# -------------------------------------------------------

@router.post("/auth/web/check-exists")
async def web_check_exists(request: Request, db: AsyncSession = Depends(get_db)):
    """Check if email or phone already exists (web-safe, no HMAC needed)."""
    _verify_web_origin(request)
    _web_key_check(request)
    body = await request.json()
    identifier = (body.get("identifier") or "").strip().lower()
    role = body.get("role", "rider")
    if not identifier:
        raise HTTPException(400, "identifier required")
    if "@" in identifier:
        r = await db.execute(
            select(User).where(func.lower(User.email) == identifier, User.role == role)
            .where(User.status.notin_(["deleted", "pending_deletion"]))
        )
    else:
        r = await db.execute(
            select(User).where(User.phone == identifier, User.role == role)
            .where(User.status.notin_(["deleted", "pending_deletion"]))
        )
    return {"exists": r.scalar_one_or_none() is not None}


@router.post("/auth/web/register")
async def web_register(request: Request, db: AsyncSession = Depends(get_db)):
    """Register a new rider from the Shopify widget."""
    _verify_web_origin(request)
    _web_key_check(request)
    body = await request.json()
    first_name = (body.get("first_name") or "").strip()
    last_name = (body.get("last_name") or "").strip()
    email = (body.get("email") or "").strip().lower() or None
    phone = (body.get("phone") or "").strip() or None
    password = body.get("password", "")
    role = "rider"

    if not first_name or not last_name:
        raise HTTPException(400, "first_name and last_name required")
    if not email and not phone:
        raise HTTPException(400, "email or phone required")
    if len(password) < 8:
        raise HTTPException(400, "Password must be at least 8 characters")

    # Check duplicates
    if email:
        r = await db.execute(select(User).where(func.lower(User.email) == email, User.role == role))
        existing = r.scalar_one_or_none()
        if existing:
            if existing.status in ("deleted", "pending_deletion"):
                existing.first_name = first_name
                existing.last_name = last_name
                existing.password_hash = pwd.hash(password)
                existing.status = "active"
                existing.deletion_requested_at = None
                await db.commit()
                await db.refresh(existing)
                token = _create_token(existing.id, role=existing.role, status="active")
                return {"access_token": token, "token_type": "bearer", "user": _user_dict(existing)}
            raise HTTPException(409, "Email already registered")

    if phone:
        r = await db.execute(select(User).where(User.phone == phone, User.role == role))
        existing = r.scalar_one_or_none()
        if existing:
            if existing.status in ("deleted", "pending_deletion"):
                existing.first_name = first_name
                existing.last_name = last_name
                existing.password_hash = pwd.hash(password)
                existing.status = "active"
                existing.deletion_requested_at = None
                await db.commit()
                await db.refresh(existing)
                token = _create_token(existing.id, role=existing.role, status="active")
                return {"access_token": token, "token_type": "bearer", "user": _user_dict(existing)}
            raise HTTPException(409, "Phone already registered")

    user = User(
        first_name=first_name, last_name=last_name,
        email=email, phone=phone,
        password_hash=pwd.hash(password),
        role=role,
    )
    db.add(user)
    try:
        await db.commit()
        await db.refresh(user)
    except IntegrityError:
        await db.rollback()
        raise HTTPException(409, "Email or phone already registered")

    # Handle profile photo upload (base64 data URL from wizard)
    photo_data = body.get("photo_data") or ""
    if photo_data and photo_data.startswith("data:image"):
        try:
            # Parse "data:image/jpeg;base64,XXXX" format
            header, b64 = photo_data.split(",", 1)
            if len(b64) > 4 * 1024 * 1024:
                logging.warning("[WebAuth] Photo data too large for user %d", user.id)
            else:
                photo_bytes = base64.b64decode(b64, validate=True)
                if len(photo_bytes) <= 3 * 1024 * 1024:
                    if photo_bytes[:2] == b'\xff\xd8':
                        ext, content_type = "jpg", "image/jpeg"
                    elif photo_bytes[:8] == b'\x89PNG\r\n\x1a\n':
                        ext, content_type = "png", "image/png"
                    else:
                        ext, content_type = None, None

                    if ext and _HAS_FIRESTORE and firestore_sync:
                        storage_path = f"photos/user_{user.id}/profile.{ext}"
                        firebase_url = firestore_sync.upload_to_firebase_storage(
                            data=photo_bytes, path=storage_path, content_type=content_type
                        )
                        if firebase_url:
                            user.photo_url = firebase_url
                            await db.commit()
                            await db.refresh(user)
                            logging.info("[WebAuth] Photo uploaded for user %d: %s", user.id, firebase_url)
        except Exception as _photo_err:
            logging.warning("[WebAuth] Photo upload failed for user %d: %s", user.id, _photo_err)

    # Sync new user to Firestore (same as mobile app register)
    if _HAS_FIRESTORE and firestore_sync:
        try:
            firestore_sync.sync_client(
                user_id=user.id,
                first_name=user.first_name,
                last_name=user.last_name,
                phone=user.phone or "",
                email=user.email,
                photo_url=user.photo_url,
                role=user.role,
                created_at=user.created_at,
                is_verified=False,
            )
        except Exception as _fs_err:
            logging.warning("[WebAuth] Firestore sync failed: %s", _fs_err)

    # Trigger welcome email via n8n (same as mobile app register)
    if trigger_welcome_email and user.email:
        try:
            trigger_welcome_email(user.email, user.first_name)
        except Exception as _n8n_err:
            logging.warning("[WebAuth] Welcome email trigger failed: %s", _n8n_err)

    token = _create_token(user.id, role=user.role, status="active")
    refresh = _create_refresh_token(user.id)
    logging.info("[WebAuth] New rider registered via Shopify: %s (id=%d)", email or phone, user.id)
    return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(user)}


@router.post("/auth/web/login")
async def web_login(request: Request, db: AsyncSession = Depends(get_db)):
    """Login from the Shopify widget — returns login_token for complete-login step."""
    _verify_web_origin(request)
    _web_key_check(request)
    body = await request.json()
    identifier = (body.get("identifier") or "").strip()
    password = body.get("password", "")
    role = body.get("role", "rider")

    if not identifier or not password:
        raise HTTPException(400, "identifier and password required")

    client_ip = request.client.host if request.client else "unknown"
    if _check_login_throttle(client_ip):
        raise HTTPException(429, "Too many attempts. Try again in a few minutes.")

    # Find user by email or phone
    if "@" in identifier:
        r = await db.execute(
            select(User).where(func.lower(User.email) == identifier.lower(), User.role == role)
        )
    else:
        r = await db.execute(select(User).where(User.phone == identifier, User.role == role))
    user = r.scalar_one_or_none()

    if not user or not pwd.verify(password, user.password_hash):
        _record_login_failure(client_ip)
        raise HTTPException(401, "Invalid credentials")

    if user.status in ("deleted", "pending_deletion"):
        raise HTTPException(403, "Account has been deleted")

    _clear_login_failures(client_ip)
    login_token = _create_login_token(user.id)
    return {"login_token": login_token, "method": "web"}


@router.post("/auth/web/complete-login")
async def web_complete_login(request: Request, db: AsyncSession = Depends(get_db)):
    """Exchange login_token for full JWT (web flow skips OTP)."""
    _verify_web_origin(request)
    _web_key_check(request)
    body = await request.json()
    login_token = body.get("login_token", "")
    if not login_token:
        raise HTTPException(400, "login_token required")

    try:
        payload = jwt.decode(login_token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        if payload.get("type") != "login":
            raise HTTPException(401, "Invalid token type")
        user_id = int(payload.get("sub", 0))
    except JWTError:
        raise HTTPException(401, "Invalid or expired login token")

    r = await db.execute(select(User).where(User.id == user_id))
    user = r.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")

    token = _create_token(user.id, role=user.role, status=user.status or "active")
    refresh = _create_refresh_token(user.id)
    logging.info("[WebAuth] Login complete: user %d", user.id)
    return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(user)}


@router.post("/auth/web/social")
async def web_social_auth(request: Request, db: AsyncSession = Depends(get_db)):
    """Google / Apple social auth from the Shopify widget."""
    _verify_web_origin(request)
    _web_key_check(request)
    body = await request.json()
    provider = body.get("provider", "")
    id_token_str = body.get("id_token", "")
    role = body.get("role", "rider")
    login_only = body.get("login_only", False)
    first_name = body.get("first_name", "")
    last_name = body.get("last_name", "")

    if provider not in ("google", "apple") or not id_token_str:
        raise HTTPException(400, "provider and id_token required")

    email = None
    # Verify token based on provider
    if provider == "google":
        try:
            import requests as _req
            # Verify Google ID token via Google's tokeninfo endpoint
            g = _req.get(f"https://oauth2.googleapis.com/tokeninfo?id_token={id_token_str}", timeout=10)
            if g.status_code != 200:
                raise HTTPException(401, "Invalid Google token")
            g_data = g.json()
            email = g_data.get("email", "").lower()
            if not first_name:
                first_name = g_data.get("given_name", "")
            if not last_name:
                last_name = g_data.get("family_name", "")
        except HTTPException:
            raise
        except Exception as e:
            logging.error("[WebSocial] Google verify error: %s", e)
            raise HTTPException(401, "Could not verify Google token")

    elif provider == "apple":
        try:
            # Decode Apple ID token header to get key ID
            header = jwt.get_unverified_header(id_token_str)
            kid = header.get("kid")
            import requests as _req
            apple_keys = _req.get("https://appleid.apple.com/auth/keys", timeout=10).json()
            key_data = next((k for k in apple_keys.get("keys", []) if k["kid"] == kid), None)
            if not key_data:
                raise HTTPException(401, "Apple key not found")
            from jose import jwk
            public_key = jwk.construct(key_data, algorithm="RS256")
            decoded = jwt.decode(id_token_str, public_key, algorithms=["RS256"], audience=body.get("client_id", ""))
            email = decoded.get("email", "").lower()
        except HTTPException:
            raise
        except Exception as e:
            logging.error("[WebSocial] Apple verify error: %s", e)
            raise HTTPException(401, "Could not verify Apple token")

    if not email:
        raise HTTPException(400, "Could not extract email from token")

    # Find or create user
    r = await db.execute(
        select(User).where(func.lower(User.email) == email, User.role == role)
    )
    user = r.scalar_one_or_none()

    if user:
        if user.status in ("deleted", "pending_deletion"):
            user.status = "active"
            user.deletion_requested_at = None
            await db.commit()
            await db.refresh(user)
        token = _create_token(user.id, role=user.role, status=user.status or "active")
        refresh = _create_refresh_token(user.id)
        return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(user)}

    if login_only:
        raise HTTPException(401, "No account found. Please create an account first.")

    # Create new user
    user = User(
        first_name=first_name or "User",
        last_name=last_name or "",
        email=email,
        password_hash=pwd.hash(secrets.token_hex(16)),
        role=role,
    )
    db.add(user)
    try:
        await db.commit()
        await db.refresh(user)
    except IntegrityError:
        await db.rollback()
        raise HTTPException(409, "Account already exists")

    token = _create_token(user.id, role=user.role, status="active")
    refresh = _create_refresh_token(user.id)
    logging.info("[WebAuth] Social %s register: %s (id=%d)", provider, email, user.id)
    return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(user)}


# -------------------------------------------------------
#  WEB DEFAULT PAYMENT METHOD
# -------------------------------------------------------

def _decode_user_from_token(token: str) -> int:
    """Extract user_id from a JWT access token. Returns 0 if invalid."""
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        return int(payload.get("sub", 0))
    except Exception:
        return 0


@router.post("/auth/web/set-default-payment")
async def web_set_default_payment(request: Request, db: AsyncSession = Depends(get_db)):
    """Save the user's chosen payment method as default.
    Authenticated via the user's JWT access token (not WEB_CHECKOUT_KEY)."""
    _verify_web_origin(request)
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    token = auth.split(" ", 1)[1]
    user_id = _decode_user_from_token(token)
    if not user_id:
        raise HTTPException(401, "Invalid token")

    body = await request.json()
    method_type = (body.get("method_type") or "").strip()  # 'apple_pay','google_pay','card','cash','test_mode'
    display_name = (body.get("display_name") or method_type.replace("_", " ").title()).strip()
    stripe_pm_id = body.get("stripe_pm_id") or None

    if not method_type:
        raise HTTPException(400, "method_type required")

    r = await db.execute(select(User).where(User.id == user_id))
    user = r.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")

    # Clear any existing defaults
    existing = await db.execute(
        select(RiderPaymentMethod).where(RiderPaymentMethod.user_id == user_id, RiderPaymentMethod.is_default == True)
    )
    for m in existing.scalars().all():
        m.is_default = False

    # Find or create this method
    lookup = await db.execute(
        select(RiderPaymentMethod).where(
            RiderPaymentMethod.user_id == user_id,
            RiderPaymentMethod.method_type == method_type
        )
    )
    pm = lookup.scalar_one_or_none()
    if pm:
        pm.is_default = True
        pm.display_name = display_name
        if stripe_pm_id:
            pm.stripe_pm_id = stripe_pm_id
    else:
        pm = RiderPaymentMethod(
            user_id=user_id,
            method_type=method_type,
            display_name=display_name,
            stripe_pm_id=stripe_pm_id,
            is_default=True,
        )
        db.add(pm)

    await db.commit()
    logging.info("[WebAuth] Default payment set for user %d: %s", user_id, method_type)
    return {"ok": True, "method_type": method_type}


@router.get("/auth/web/default-payment")
async def web_get_default_payment(request: Request, db: AsyncSession = Depends(get_db)):
    """Return the user's default payment method (if any)."""
    _verify_web_origin(request)
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    token = auth.split(" ", 1)[1]
    user_id = _decode_user_from_token(token)
    if not user_id:
        raise HTTPException(401, "Invalid token")

    r = await db.execute(
        select(RiderPaymentMethod).where(
            RiderPaymentMethod.user_id == user_id,
            RiderPaymentMethod.is_default == True
        ).order_by(RiderPaymentMethod.id.desc()).limit(1)
    )
    pm = r.scalar_one_or_none()
    if not pm:
        return {"default": None}
    return {
        "default": {
            "method_type": pm.method_type,
            "display_name": pm.display_name,
            "stripe_pm_id": pm.stripe_pm_id or "",
        }
    }

