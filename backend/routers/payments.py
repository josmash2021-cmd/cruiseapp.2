import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, RiderPaymentMethod,
)
from models.schemas import PaymentIntentIn, PayPalOrderIn, PayPalCaptureIn
from utils.security import _get_current_user, _verify_api_key, _require_dispatch_auth
from config import (
    STRIPE_SECRET, _HAS_STRIPE, _stripe_mod, STRIPE_WEBHOOK_SECRET,
    PAYPAL_CLIENT_ID, PAYPAL_SECRET, PAYPAL_SANDBOX,
    PAYPAL_CLIENT_SECRET, PAYPAL_MODE,
)

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

@router.post("/payments/web/checkout")
async def create_web_checkout(request: Request):
    """Create a Stripe Checkout Session for website payments.
    No HMAC required — uses a simple bearer token (WEB_CHECKOUT_KEY).
    Body: {"amount": cents, "currency": "usd", "description": "...",
           "success_url": "https://...", "cancel_url": "https://...",
           "customer_email": "optional@email.com", "metadata": {}}
    """
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


@router.post("/payments/webhook")
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
                    trip.refund_amount = round(refunded_cents / 100, 2)
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

    trip.refund_status = "full" if (trip.fare and amount >= float(trip.fare)) else "partial"
    trip.refund_amount = amount
    trip.refund_reason = reason
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

