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
from utils.security import _get_current_user, _verify_api_key
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


# ═══════════════════════════════════════════════════════
#  STRIPE PAYMENT ENDPOINTS
# ═══════════════════════════════════════════════════════
STRIPE_SECRET = os.getenv("STRIPE_SECRET_KEY", "")
_HAS_STRIPE = False
try:
    import stripe as _stripe_mod
    if STRIPE_SECRET:
        _stripe_mod.api_key = STRIPE_SECRET
        _HAS_STRIPE = True
        logging.info("[Stripe] Initialized with secret key")
    else:
        logging.warning("[Stripe] No STRIPE_SECRET_KEY in .env � payment endpoints will return mock data")
except ImportError:
    logging.warning("[Stripe] stripe package not installed � pip install stripe")


@router.post("/payments/create-intent", dependencies=[Depends(_verify_api_key)])
async def create_payment_intent(body: PaymentIntentIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Create a Stripe PaymentIntent for a ride payment."""
    # SECURITY: Validate payment amount against trip fare if trip_id provided
    if body.trip_id:
        trip_r = await db.execute(select(Trip).where(Trip.id == body.trip_id))
        trip = trip_r.scalar_one_or_none()
        if trip and trip.fare:
            expected_cents = int(trip.fare * 100)
            if body.amount < expected_cents:
                raise HTTPException(400, f"Payment amount cannot be less than the trip fare (${trip.fare:.2f})")
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


@router.post("/payments/capture/{intent_id}", dependencies=[Depends(_verify_api_key)])
async def capture_payment_intent(intent_id: str, user: User = Depends(_get_current_user)):
    """Capture a previously authorized (held) PaymentIntent.
    Called when a trip is completed to finalize the charge."""
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


# -- PayPal token exchange (proxied through backend — never expose secret to client) --
PAYPAL_CLIENT_ID = os.getenv("PAYPAL_CLIENT_ID", "")
PAYPAL_SECRET = os.getenv("PAYPAL_SECRET", "")
PAYPAL_SANDBOX = os.getenv("PAYPAL_SANDBOX", "true").lower() == "true"


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
#  STRIPE WEBHOOK
# -------------------------------------------------------

STRIPE_WEBHOOK_SECRET = os.getenv("STRIPE_WEBHOOK_SECRET", "")

# Idempotency: track processed Stripe event IDs to prevent double-processing
_processed_stripe_events: collections.OrderedDict = collections.OrderedDict()
_MAX_PROCESSED_EVENTS = 5000


@router.post("/payments/stripe/webhook")
async def stripe_webhook(request: Request, db: AsyncSession = Depends(get_db)):
    """Handle Stripe webhook events (payment confirmations, refunds, etc.)."""
    payload = await request.body()
    sig_header = request.headers.get("stripe-signature", "")

    if not _HAS_STRIPE or not STRIPE_WEBHOOK_SECRET:
        logging.warning("[Stripe Webhook] Not configured � ignoring event")
        return {"status": "ignored"}

    try:
        event = _stripe_mod.Webhook.construct_event(payload, sig_header, STRIPE_WEBHOOK_SECRET)
    except (ValueError, _stripe_mod.error.SignatureVerificationError) as e:
        logging.warning("[Stripe Webhook] Signature verification failed: %s", e)
        raise HTTPException(400, "Invalid signature")

    event_type = event["type"]
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
        if trip_id:
            trip_r = await db.execute(select(Trip).where(Trip.id == int(trip_id)))
            trip = trip_r.scalar_one_or_none()
            if trip and trip.status == "completed":
                logging.info("[Stripe Webhook] Payment confirmed for trip %s", trip_id)

    elif event_type == "payment_intent.payment_failed":
        intent = event["data"]["object"]
        trip_id = intent.get("metadata", {}).get("trip_id")
        logging.warning("[Stripe Webhook] Payment failed for trip %s: %s",
                        trip_id, intent.get("last_payment_error", {}).get("message"))

    elif event_type == "charge.refunded":
        charge = event["data"]["object"]
        pi_id = charge.get("payment_intent")
        if pi_id:
            trip_r = await db.execute(select(Trip).where(Trip.stripe_payment_intent_id == pi_id))
            trip = trip_r.scalar_one_or_none()
            if trip:
                refunded_cents = charge.get("amount_refunded", 0)
                trip.refund_amount = round(refunded_cents / 100, 2)
                trip.refund_status = "full" if refunded_cents >= (charge.get("amount", 0)) else "partial"
                await db.commit()
                logging.info("[Stripe Webhook] Refund recorded for trip %s: $%.2f", trip.id, trip.refund_amount)

    return {"status": "ok"}


# ═══════════════════════════════════════════════════════
#  PAYPAL PAYMENTS
# ═══════════════════════════════════════════════════════

PAYPAL_CLIENT_ID     = os.getenv("PAYPAL_CLIENT_ID", "")
PAYPAL_CLIENT_SECRET = os.getenv("PAYPAL_CLIENT_SECRET", "")
PAYPAL_MODE          = os.getenv("PAYPAL_MODE", "sandbox")  # "sandbox" or "live"

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

