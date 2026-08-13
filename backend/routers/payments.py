import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib, hmac
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, RiderPaymentMethod, Vehicle, DispatchOffer, Rating,
)
from models.schemas import PaymentIntentIn, PayPalOrderIn, PayPalCaptureIn, RiderPaymentMethodIn, BankAccountAttachIn
from utils.security import (
    HMAC_SECRET,

    _get_current_user, _verify_api_key, _require_dispatch_auth,
    pwd, _create_token, _create_refresh_token, _create_login_token,
    _check_login_throttle, _record_login_failure, _clear_login_failures,
    JWT_SECRET, JWT_ALGORITHM,
)
from utils.helpers import _safe_create_task, _haversine, _abs_photo_url, _user_dict, _resolve_rider_display
from services.fcm_service import _send_fcm_push
from services import vehicle_tiers, web_pricing
from services.sms_service import notify_guest_welcome
from services.email_service import email_guest_welcome, email_vip_drink_menu
from routers.vip import generate_vip_menu_token
from sqlalchemy.exc import IntegrityError
import jwt
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


# ─────────────────────────────────────────────────────────────────
#  Stripe Customer helper
# ─────────────────────────────────────────────────────────────────

async def _get_or_create_stripe_customer(user: User, db: AsyncSession) -> Optional[str]:
    """Return the Stripe customer_id for this user, creating one on
    first use. Stored on users.stripe_customer_id so we don't hit the
    Stripe API every request. Returns None if Stripe is not configured.

    All saved cards / SetupIntents / off_session charges hang off this
    customer — without it PaymentMethods are orphaned and unusable.

    The incoming `user` may be detached from `db` (different session
    from the one that resolved the dependency), so we always re-fetch
    the row inside this session before mutating it. Without the
    re-fetch, db.commit() raised:
        Instance '<User>' is not persistent within this Session
    in production logs 2026-04-27.
    """
    if not _HAS_STRIPE:
        return None
    if user.stripe_customer_id:
        return user.stripe_customer_id
    try:
        customer = _stripe_mod.Customer.create(
            email=user.email or None,
            phone=user.phone or None,
            name=" ".join([(user.first_name or ""), (user.last_name or "")]).strip() or None,
            metadata={"user_id": str(user.id)},
        )
        # Re-fetch user inside THIS session so it's attached and
        # commit() can persist the new stripe_customer_id.
        rs = await db.execute(select(User).where(User.id == user.id))
        attached_user = rs.scalar_one_or_none()
        if attached_user is None:
            # User vanished between auth and now — extremely unlikely
            # but bail out cleanly rather than crashing.
            return customer.id
        attached_user.stripe_customer_id = customer.id
        await db.commit()
        # Sync the in-memory user instance the caller is holding so the
        # next access doesn't re-trigger the create path.
        user.stripe_customer_id = customer.id
        return customer.id
    except Exception as e:
        logging.error("[stripe] Customer.create failed for user %s: %s", user.id, e)
        return None

@router.post("/payments/setup-intent", dependencies=[Depends(_verify_api_key)])
async def create_setup_intent(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Create a Stripe SetupIntent attached to the rider's Stripe
    customer so the saved card can be charged off_session later.

    Without `customer=`, the resulting PaymentMethod is orphaned and
    every future off_session charge fails with "No customer attached".
    The helper lazily creates the customer on first call and caches the
    id on users.stripe_customer_id."""
    if not _HAS_STRIPE:
        return {"client_secret": "seti_mock_secret_for_testing"}
    customer_id = await _get_or_create_stripe_customer(user, db)
    if not customer_id:
        raise HTTPException(500, "Could not initialise payment customer")
    try:
        intent = _stripe_mod.SetupIntent.create(
            customer=customer_id,
            usage="off_session",
            payment_method_types=["card"],
            metadata={"user_id": str(user.id)},
        )
        return {
            "client_secret": intent.client_secret,
            "customer_id": customer_id,
        }
    except _stripe_mod.error.StripeError as e:
        # Forward structured error data so the Flutter client can map decline codes
        # to localized user-friendly messages.
        detail = {
            "message": str(getattr(e, "user_message", None) or e),
            "code": getattr(e, "code", None),
            "decline_code": getattr(e, "decline_code", None),
            "type": getattr(e, "type", None),
        }
        raise HTTPException(400, detail=detail)


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
        # Always pass customer when we have one — required by Stripe to
        # use a saved PaymentMethod (off_session charges) and lets the
        # rider's saved cards / bank accounts surface in payment sheets.
        customer_id = await _get_or_create_stripe_customer(user, db)
        if customer_id:
            intent_params["customer"] = customer_id
        off_session = bool(body.payment_method_id)
        if off_session:
            intent_params["payment_method"] = body.payment_method_id
            intent_params["confirm"] = True
            intent_params["off_session"] = True
            intent_params["automatic_payment_methods"] = {
                "enabled": True,
                "allow_redirects": "never",
            }
        else:
            intent_params["automatic_payment_methods"] = {"enabled": True}

        # Hold-only: authorize but do NOT capture yet (capture on trip completion)
        if body.hold_only:
            intent_params["capture_method"] = "manual"

        # Save the payment method for future charges — but ONLY when the rider
        # is present to approve it.
        #
        # This was set unconditionally, and Stripe rejects the combination
        # outright: `setup_future_usage` together with `off_session=True` is an
        # error, not a warning. So the request never became a charge. Nothing
        # was authorised, nothing was debited, and the rider got Stripe's
        # internal explanation printed at them as if their bank had declined —
        # the same result for every rider paying with a saved method, every
        # time, which is why it looked like the button did nothing.
        #
        # The flag is also pointless in that branch: a `payment_method_id` only
        # exists because the method was already saved. There is nothing left to
        # set up. It belongs on the on-session path, where the rider is looking
        # at a payment sheet and can complete whatever the bank asks for.
        if not off_session:
            intent_params["setup_future_usage"] = "off_session"

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
        # Forward structured error data so the Flutter client can map decline codes
        # to localized user-friendly messages.
        detail = {
            "message": str(getattr(e, "user_message", None) or e),
            "code": getattr(e, "code", None),
            "decline_code": getattr(e, "decline_code", None),
            "type": getattr(e, "type", None),
        }
        raise HTTPException(400, detail=detail)


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
        # Forward structured error data so the Flutter client can map decline codes
        # to localized user-friendly messages.
        detail = {
            "message": str(getattr(e, "user_message", None) or e),
            "code": getattr(e, "code", None),
            "decline_code": getattr(e, "decline_code", None),
            "type": getattr(e, "type", None),
        }
        raise HTTPException(400, detail=detail)


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
        # A hold tied to an ACTIVE trip is not releasable here — the only
        # release path is the trip-cancel flow (_release_or_capture_fee_on_cancel),
        # which also settles any cancellation fee owed.
        if trip.status not in ("cancelled", "completed"):
            raise HTTPException(409, "Cannot release the hold while the trip is still active")
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
        # A hold tied to an ACTIVE trip is not capturable here — capture
        # happens through the trip-completion flow (_charge_trip), which
        # computes the final amount including wait fees and shortfall.
        if trip.status not in ("cancelled", "completed"):
            raise HTTPException(409, "Cannot capture the hold while the trip is still active")
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
        # Forward structured error data so the Flutter client can map decline codes
        # to localized user-friendly messages.
        detail = {
            "message": str(getattr(e, "user_message", None) or e),
            "code": getattr(e, "code", None),
            "decline_code": getattr(e, "decline_code", None),
            "type": getattr(e, "type", None),
        }
        raise HTTPException(400, detail=detail)


# ═══════════════════════════════════════════════════════════════════
#  RIDER PAYMENT METHOD SYNC
# ═══════════════════════════════════════════════════════════════════

@router.post("/users/me/payment-methods/sync", dependencies=[Depends(_verify_api_key)])
async def sync_payment_method(
    body: RiderPaymentMethodIn,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Sync a Stripe PaymentMethod to the backend after client-side tokenization.
    Creates or updates a RiderPaymentMethod row so the card is available for
    off-session charging and survives app reinstalls."""
    if not body.stripe_pm_id:
        raise HTTPException(400, "stripe_pm_id is required")

    # Check if already exists
    existing_r = await db.execute(
        select(RiderPaymentMethod).where(
            RiderPaymentMethod.user_id == user.id,
            RiderPaymentMethod.stripe_pm_id == body.stripe_pm_id,
        )
    )
    existing = existing_r.scalar_one_or_none()
    if existing:
        return {"status": "already_exists", "method_id": existing.id}

    # Unset previous default if this one should be default
    if body.set_default:
        await db.execute(
            text("""
                UPDATE rider_payment_methods
                SET is_default = FALSE
                WHERE user_id = :uid
            """),
            {"uid": user.id},
        )

    method = RiderPaymentMethod(
        user_id=user.id,
        method_type=body.method_type or "stripe_card",
        display_name=body.display_name or "Card",
        stripe_pm_id=body.stripe_pm_id,
        is_default=body.set_default,
    )
    db.add(method)
    await db.commit()
    await db.refresh(method)
    return {"status": "created", "method_id": method.id}


@router.get("/users/me/payment-methods", dependencies=[Depends(_verify_api_key)])
async def get_my_payment_methods(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Return all saved payment methods for the current rider.
    Used by the Flutter app to restore cards after reinstall."""
    result = await db.execute(
        select(RiderPaymentMethod).where(RiderPaymentMethod.user_id == user.id)
            .order_by(RiderPaymentMethod.is_default.desc(), RiderPaymentMethod.created_at.desc())
    )
    methods = result.scalars().all()
    return [
        {
            "id": m.id,
            "method_type": m.method_type,
            "display_name": m.display_name,
            "stripe_pm_id": m.stripe_pm_id,
            "is_default": m.is_default,
            "created_at": m.created_at.isoformat() if m.created_at else None,
        }
        for m in methods
    ]


# ═══════════════════════════════════════════════════════════════════
#  STRIPE LINK / FINANCIAL CONNECTIONS (BANK ACCOUNT)
# ═══════════════════════════════════════════════════════════════════

@router.post("/stripe/financial-connections", dependencies=[Depends(_verify_api_key)])
async def create_financial_connections_session(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Create a Stripe Financial Connections session so the rider can link
    a bank account for ACH payments. Returns a URL to open in a WebView
    or external browser."""
    if not _HAS_STRIPE:
        raise HTTPException(503, "Stripe not configured on this server")

    customer_id = await _get_or_create_stripe_customer(user, db)
    if not customer_id:
        raise HTTPException(500, "Could not initialise payment customer")

    try:
        session = _stripe_mod.financial_connections.Session.create(
            account_holder={"type": "customer", "customer": customer_id},
            permissions=["payment_method"],
            return_url=f"{os.environ.get('PUBLIC_URL', 'https://cruiseinride.com')}/bank-connected",
        )
        # NOTE: FC Sessions have NO hosted `url` — the object only carries a
        # client_secret that the native SDK (flutter_stripe
        # collectFinancialConnectionsAccounts) uses to launch the bank
        # linking sheet. Returning session.url here 500'd in production.
        return {"client_secret": session.client_secret, "session_id": session.id}
    except _stripe_mod.error.StripeError as e:
        logging.error("[Stripe] Financial Connections session failed: %s", e)
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))


@router.post("/stripe/bank-accounts/attach", dependencies=[Depends(_verify_api_key)])
async def attach_bank_account(
    payload: BankAccountAttachIn,
    request: Request,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Convert a Financial Connections account (collected client-side by the
    native Stripe SDK) into a us_bank_account PaymentMethod, attach it to the
    rider's Stripe customer and register it in rider_payment_methods so it
    shows in settings and can be charged via ACH."""
    if not _HAS_STRIPE:
        raise HTTPException(503, "Stripe not configured on this server")

    customer_id = await _get_or_create_stripe_customer(user, db)
    if not customer_id:
        raise HTTPException(500, "Could not initialise payment customer")

    # Stripe REQUIRES billing_details[name] on us_bank_account PaymentMethods
    # (it's the ACH account-holder name on the mandate). Omitting it returned
    # 400 "Missing required param: billing_details[name]" and the rider bounced
    # back to the vehicle sheet with a generic payment error.
    holder_name = " ".join(
        [(user.first_name or ""), (user.last_name or "")]
    ).strip()
    if not holder_name:
        # Last-resort fallbacks so the call never 400s on a nameless profile.
        holder_name = (user.email or "").split("@")[0].strip() or (
            user.phone or ""
        ).strip() or f"Cruise Rider {user.id}"

    billing_details = {"name": holder_name}
    if user.email:
        billing_details["email"] = user.email

    try:
        pm = _stripe_mod.PaymentMethod.create(
            type="us_bank_account",
            us_bank_account={
                "financial_connections_account": payload.account_id,
            },
            billing_details=billing_details,
        )
        _stripe_mod.PaymentMethod.attach(pm.id, customer=customer_id)
    except _stripe_mod.error.StripeError as e:
        logging.error("[Stripe] Attach bank account failed: %s", e)
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))

    # ACH MANDATE. Attaching the PaymentMethod is not enough: Stripe refuses
    # any off_session debit against a us_bank_account without a mandate on
    # record. Confirming a SetupIntent with online customer_acceptance creates
    # it, and Stripe then links it automatically to every later
    # PaymentIntent(customer=..., payment_method=..., off_session=True).
    #
    # Financial Connections returns an already-verified account, so this
    # normally lands on 'succeeded' immediately. If it lands on
    # requires_action, Stripe wants microdeposit verification and the account
    # is NOT chargeable yet — we say so instead of letting the rider pick a
    # bank that will decline at request time.
    setup_status = None
    try:
        setup_intent = _stripe_mod.SetupIntent.create(
            customer=customer_id,
            payment_method=pm.id,
            payment_method_types=["us_bank_account"],
            confirm=True,
            usage="off_session",
            mandate_data={
                "customer_acceptance": {
                    "type": "online",
                    "online": {
                        "ip_address": (
                            request.client.host if request.client else "0.0.0.0"
                        ),
                        "user_agent": request.headers.get("user-agent", "CruiseApp"),
                    },
                }
            },
            metadata={"user_id": str(user.id)},
        )
        setup_status = getattr(setup_intent, "status", None)
        logging.info(
            "[Stripe] ACH mandate SetupIntent %s for user %s → %s",
            setup_intent.id, user.id, setup_status,
        )
    except _stripe_mod.error.StripeError as e:
        # Roll the PaymentMethod back off the customer so a bank we cannot
        # actually debit never shows up as a usable method in the picker.
        try:
            _stripe_mod.PaymentMethod.detach(pm.id)
        except Exception:
            pass
        logging.error("[Stripe] ACH mandate setup failed: %s", e)
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))

    bank = getattr(pm, "us_bank_account", None)
    bank_name = getattr(bank, "bank_name", None) if bank else None
    last4 = getattr(bank, "last4", None) if bank else None
    display = f"{bank_name} •••• {last4}" if bank_name else f"Bank •••• {last4}"

    if setup_status != "succeeded":
        # Mandate not live (microdeposit verification pending). Detach and skip
        # the rider_payment_methods insert — otherwise GET /stripe/bank-accounts
        # would list it again on the next app resume and the client would cache
        # it as a usable method behind the picker's back.
        try:
            _stripe_mod.PaymentMethod.detach(pm.id)
        except Exception:
            pass
        logging.warning(
            "[Stripe] Bank for user %s not chargeable yet (setup_status=%s)",
            user.id, setup_status,
        )
        return {
            "stripe_pm_id": None,
            "bank_name": bank_name,
            "last4": last4,
            "display_name": display,
            "requires_verification": True,
            "setup_status": setup_status,
        }

    existing_r = await db.execute(
        select(RiderPaymentMethod).where(
            RiderPaymentMethod.user_id == user.id,
            RiderPaymentMethod.stripe_pm_id == pm.id,
        )
    )
    if existing_r.scalar_one_or_none() is None:
        db.add(
            RiderPaymentMethod(
                user_id=user.id,
                method_type="bank_account",
                display_name=display,
                stripe_pm_id=pm.id,
                is_default=False,
            )
        )
        await db.commit()

    return {
        "stripe_pm_id": pm.id,
        "bank_name": bank_name,
        "last4": last4,
        "display_name": display,
        # Mandate is live — the account can be debited off_session right away.
        "requires_verification": False,
        "setup_status": setup_status,
    }


@router.get("/stripe/bank-accounts", dependencies=[Depends(_verify_api_key)])
async def list_bank_accounts(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """List the rider's linked US bank accounts (ACH) and upsert them into
    rider_payment_methods so they survive reinstall and appear in settings.

    Returns an empty list (never 503) when Stripe is not configured so the
    app doesn't break in dev environments."""
    if not _HAS_STRIPE:
        return {"accounts": []}

    customer_id = await _get_or_create_stripe_customer(user, db)
    if not customer_id:
        return {"accounts": []}

    try:
        pms = _stripe_mod.PaymentMethod.list(
            customer=customer_id, type="us_bank_account"
        )
        accounts = []
        for pm in pms.data:
            bank = getattr(pm, "us_bank_account", None)
            bank_name = getattr(bank, "bank_name", None) if bank else None
            last4 = getattr(bank, "last4", None) if bank else None
            display = (
                f"{bank_name} •••• {last4}" if bank_name else f"Bank •••• {last4}"
            )

            # Upsert into rider_payment_methods (same pattern as
            # sync_payment_method: skip if this stripe_pm_id already exists).
            existing_r = await db.execute(
                select(RiderPaymentMethod).where(
                    RiderPaymentMethod.user_id == user.id,
                    RiderPaymentMethod.stripe_pm_id == pm.id,
                )
            )
            if existing_r.scalar_one_or_none() is None:
                db.add(
                    RiderPaymentMethod(
                        user_id=user.id,
                        method_type="bank_account",
                        display_name=display,
                        stripe_pm_id=pm.id,
                        is_default=False,
                    )
                )
            accounts.append(
                {"stripe_pm_id": pm.id, "bank_name": bank_name, "last4": last4}
            )
        await db.commit()
        return {"accounts": accounts}
    except _stripe_mod.error.StripeError as e:
        logging.error("[Stripe] List bank accounts failed: %s", e)
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))


@router.post("/stripe/link-session", dependencies=[Depends(_verify_api_key)])
async def create_link_session(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Create a Stripe Billing Portal session for the rider to manage
    payment methods (including Link). Falls back to Financial Connections
    if the customer has no existing Link setup."""
    if not _HAS_STRIPE:
        raise HTTPException(503, "Stripe not configured on this server")

    customer_id = await _get_or_create_stripe_customer(user, db)
    if not customer_id:
        raise HTTPException(500, "Could not initialise payment customer")

    try:
        session = _stripe_mod.billing_portal.Session.create(
            customer=customer_id,
            return_url=f"{os.environ.get('PUBLIC_URL', 'https://cruiseinride.com')}/payment-success",
        )
        return {"url": session.url}
    except _stripe_mod.error.StripeError as e:
        logging.error("[Stripe] Billing portal session failed: %s", e)
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


# ─────────────────────────────────────────────────────────────────
#  WEB QUOTES — the server prices the ride, the browser only shows it
#
#  book.html computes the fare in JavaScript, so the amount reaching
#  /payments/web/* was whatever the page chose to send: edit it and the ride
#  is authorized for less. /bookings/web/quote runs the same engine here,
#  over a route this server fetched, and hands back a short-lived signed
#  token. The payment endpoints accept the amount only with a token that
#  matches it.
# ─────────────────────────────────────────────────────────────────

MAPBOX_TOKEN = os.getenv(
    "MAPBOX_TOKEN",
    "pk.eyJ1Ijoicm95YWxwdXJwbGVjb3JwIiwiYSI6ImNtbHk4cmpsNjExamwzZm9sOGFobXZoZTMifQ.YNkz-m3W7noKKDKbwn9y3w",
)
QUOTE_TTL_SECONDS = 30 * 60
# Tip / rounding headroom: a rider may pay above the quote, never below.
QUOTE_MAX_OVER_PCT = 1.20
# Kill switch. "0" downgrades rejection to a logged warning — for use only if a
# pricing bug starts refusing legitimate rides in production.
WEB_PRICING_ENFORCE = os.getenv("WEB_PRICING_ENFORCE", "1").strip() not in ("0", "false", "no")


def _quote_sign(payload: dict) -> str:
    return jwt.encode({**payload, "typ": "web_quote"}, JWT_SECRET, algorithm=JWT_ALGORITHM)


def _quote_decode(token: str) -> Optional[dict]:
    """Return the quote claims, or None when the token is absent/invalid/expired."""
    if not token or not isinstance(token, str):
        return None
    try:
        claims = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
    except jwt.InvalidTokenError:
        return None
    if claims.get("typ") != "web_quote":
        return None
    return claims


def _enforce_quote(amount: int, quote_token: Optional[str], where: str) -> None:
    """Reject an amount the server did not quote.

    Under-paying is always refused. Paying over the quote is allowed up to
    QUOTE_MAX_OVER_PCT so a tip or a rounding difference never blocks a ride.
    A missing token is refused too — otherwise dropping the field would be the
    way around the check.
    """
    claims = _quote_decode(quote_token or "")
    if claims is None:
        msg = "no valid quote" if quote_token else "quote missing"
        if not WEB_PRICING_ENFORCE:
            logging.error("[WebPricing] %s: %s — ALLOWED (WEB_PRICING_ENFORCE=0), amount=%s", where, msg, amount)
            return
        logging.warning("[WebPricing] %s rejected: %s (amount=%s)", where, msg, amount)
        raise HTTPException(400, "Price could not be verified. Please refresh and try again.")
    quoted = int(claims.get("cents") or 0)
    if quoted <= 0 or amount < quoted or amount > int(quoted * QUOTE_MAX_OVER_PCT):
        if not WEB_PRICING_ENFORCE:
            logging.error("[WebPricing] %s: amount=%s vs quote=%s — ALLOWED (WEB_PRICING_ENFORCE=0)", where, amount, quoted)
            return
        logging.warning("[WebPricing] %s rejected: amount=%s does not match quote=%s", where, amount, quoted)
        raise HTTPException(400, "The price changed. Please refresh and try again.")


async def _mapbox_route(p_lat: float, p_lng: float, d_lat: float, d_lng: float):
    """Driving distance (m) and duration (s) between two points, or None."""
    import httpx
    url = (
        f"https://api.mapbox.com/directions/v5/mapbox/driving/"
        f"{p_lng},{p_lat};{d_lng},{d_lat}"
        f"?overview=false&access_token={MAPBOX_TOKEN}"
    )
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            r = await client.get(url)
        if r.status_code != 200:
            logging.warning("[WebQuote] Mapbox HTTP %s", r.status_code)
            return None
        routes = (r.json() or {}).get("routes") or []
        if not routes:
            return None
        return float(routes[0].get("distance") or 0), float(routes[0].get("duration") or 0)
    except Exception as e:
        logging.warning("[WebQuote] Mapbox call failed: %s", e)
        return None


@router.post("/bookings/web/quote")
async def web_quote(request: Request):
    """Price a website ride and return a signed quote.

    Body: {pickup:{lat,lng}, dropoff:{lat,lng}, vehicle_type, mode:'ride'|'hourly',
           hours, is_airport, airport_code}
    Returns every tier's price (the page shows four cards) plus a token per
    tier; the page sends back the token for whichever the rider picks.
    """
    _verify_web_origin(request)
    client_ip = request.client.host if request.client else "unknown"
    if _check_web_rate_limit(client_ip):
        raise HTTPException(429, "Too many requests — try again in a minute")
    _web_key_check(request)

    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Invalid JSON body")
    if not isinstance(body, dict):
        raise HTTPException(400, "Body must be an object")

    mode = (body.get("mode") or "ride").lower()
    airport_code = body.get("airport_code")
    is_airport = bool(body.get("is_airport"))
    now = int(time.time())
    tiers = list(web_pricing.TIERS.keys())
    out = {"mode": mode, "expires_in": QUOTE_TTL_SECONDS, "tiers": {}}

    if mode == "hourly":
        hours = body.get("hours") or 0
        for tier in tiers:
            cents = web_pricing.total_cents(
                tier, hours=hours, mode="hourly",
                airport_code=airport_code, is_airport=is_airport,
            )
            if cents <= 0:
                continue
            out["tiers"][tier] = {
                "cents": cents,
                "quote_token": _quote_sign({
                    "cents": cents, "tier": tier, "mode": "hourly",
                    "iat": now, "exp": now + QUOTE_TTL_SECONDS,
                }),
            }
        if not out["tiers"]:
            raise HTTPException(400, "Invalid hours for an hourly booking")
        return out

    pickup = body.get("pickup") or {}
    dropoff = body.get("dropoff") or {}
    try:
        p_lat, p_lng = float(pickup.get("lat")), float(pickup.get("lng"))
        d_lat, d_lng = float(dropoff.get("lat")), float(dropoff.get("lng"))
    except (TypeError, ValueError):
        raise HTTPException(400, "pickup and dropoff coordinates are required")

    route = await _mapbox_route(p_lat, p_lng, d_lat, d_lng)
    if not route:
        raise HTTPException(503, "Could not calculate the route. Please try again.")
    meters, seconds = route

    for tier in tiers:
        cents = web_pricing.total_cents(
            tier, seconds=seconds, meters=meters, mode="ride",
            airport_code=airport_code, is_airport=is_airport,
        )
        if cents <= 0:
            continue
        out["tiers"][tier] = {
            "cents": cents,
            "quote_token": _quote_sign({
                "cents": cents, "tier": tier, "mode": "ride",
                "mi": round(meters / web_pricing.METERS_PER_MILE, 2),
                "min": round(seconds / 60.0),
                "iat": now, "exp": now + QUOTE_TTL_SECONDS,
            }),
        }
    if not out["tiers"]:
        raise HTTPException(400, "Could not price this route")
    out["distance_meters"] = round(meters)
    out["duration_seconds"] = round(seconds)
    return out


@router.post("/payments/web/checkout")
async def create_web_checkout(request: Request):
    """Create a Stripe Checkout Session for website payments."""
    _verify_web_origin(request)
    client_ip = request.client.host if request.client else "unknown"
    if _check_web_rate_limit(client_ip):
        raise HTTPException(429, "Too many requests — try again in a minute")
    _web_key_check(request)

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
    _enforce_quote(amount, body.get("quote_token"), "checkout")

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
    _web_key_check(request)

    if not _HAS_STRIPE or not STRIPE_SECRET:
        raise HTTPException(503, "Stripe not configured")

    body = await request.json()
    amount = body.get("amount", 0)
    currency = body.get("currency", "usd")
    description = body.get("description", "Cruise Ride")
    metadata = body.get("metadata", {})

    if amount <= 0 or amount > 100000:
        raise HTTPException(400, "Invalid amount")
    _enforce_quote(amount, body.get("quote_token"), "create-intent")

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
    _web_key_check(request)
    if not _HAS_STRIPE:
        raise HTTPException(503, "Stripe not configured")
    try:
        intent = _stripe_mod.PaymentIntent.capture(intent_id)
        logging.info("[WebCapture] Captured: %s (amount=%d)", intent.id, intent.amount_received)
        return {"status": intent.status, "amount_captured": intent.amount_received}
    except _stripe_mod.error.StripeError as e:
        # Forward structured error data so the Flutter client can map decline codes
        # to localized user-friendly messages.
        detail = {
            "message": str(getattr(e, "user_message", None) or e),
            "code": getattr(e, "code", None),
            "decline_code": getattr(e, "decline_code", None),
            "type": getattr(e, "type", None),
        }
        raise HTTPException(400, detail=detail)


@router.post("/payments/web/cancel/{intent_id}")
async def cancel_web_hold(intent_id: str, request: Request):
    """Cancel a held PaymentIntent — release the hold if trip is cancelled."""
    _verify_web_origin(request)
    _web_key_check(request)
    if not _HAS_STRIPE:
        raise HTTPException(503, "Stripe not configured")
    try:
        intent = _stripe_mod.PaymentIntent.cancel(intent_id)
        logging.info("[WebCancel] Cancelled hold: %s", intent.id)
        return {"status": intent.status}
    except _stripe_mod.error.StripeError as e:
        # Forward structured error data so the Flutter client can map decline codes
        # to localized user-friendly messages.
        detail = {
            "message": str(getattr(e, "user_message", None) or e),
            "code": getattr(e, "code", None),
            "decline_code": getattr(e, "decline_code", None),
            "type": getattr(e, "type", None),
        }
        raise HTTPException(400, detail=detail)


# -------------------------------------------------------
#  WEB PAYPAL v2 — create + capture orders for Shopify checkout
# -------------------------------------------------------

def _verify_web_key(request: Request):
    """Shared auth helper for /payments/web/paypal/* endpoints."""
    _verify_web_origin(request)
    if _verify_web_hmac(request):
        return
    auth = request.headers.get("authorization", "")
    if not WEB_CHECKOUT_KEY or not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    if auth.split(" ", 1)[1] != WEB_CHECKOUT_KEY:
        raise HTTPException(401, "Invalid web checkout key")


async def _paypal_token() -> str:
    """Get a PayPal OAuth access token for REST API calls."""
    import httpx
    base = "https://api-m.sandbox.paypal.com" if PAYPAL_SANDBOX else "https://api-m.paypal.com"
    async with httpx.AsyncClient(timeout=15) as client:
        r = await client.post(
            f"{base}/v1/oauth2/token",
            data={"grant_type": "client_credentials"},
            auth=(PAYPAL_CLIENT_ID, PAYPAL_SECRET),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if r.status_code != 200:
            logging.error("[WebPayPal] auth failed: %s", r.text)
            raise HTTPException(502, "PayPal auth failed")
        return r.json()["access_token"]


@router.post("/payments/web/paypal/create-order")
async def create_web_paypal_order(request: Request):
    """Create a PayPal order for a Shopify checkout (Authorize, capture later)."""
    _verify_web_key(request)
    client_ip = request.client.host if request.client else "unknown"
    if _check_web_rate_limit(client_ip):
        raise HTTPException(429, "Too many requests — try again in a minute")

    if not PAYPAL_CLIENT_ID or not PAYPAL_SECRET:
        raise HTTPException(503, "PayPal not configured")

    body = await request.json()
    amount_cents = int(body.get("amount", 0))
    currency = str(body.get("currency", "USD")).upper()
    description = body.get("description", "Cruise Ride")

    if amount_cents <= 0 or amount_cents > 10_000_00:
        raise HTTPException(400, "Invalid amount")

    amount_str = f"{amount_cents / 100:.2f}"

    import httpx
    base = "https://api-m.sandbox.paypal.com" if PAYPAL_SANDBOX else "https://api-m.paypal.com"
    token = await _paypal_token()

    async with httpx.AsyncClient(timeout=15) as client:
        # Use AUTHORIZE so we hold funds and capture only when trip completes
        r = await client.post(
            f"{base}/v2/checkout/orders",
            json={
                "intent": "AUTHORIZE",
                "purchase_units": [{
                    "amount": {"currency_code": currency, "value": amount_str},
                    "description": description[:127],
                }],
                "application_context": {
                    "shipping_preference": "NO_SHIPPING",
                    "user_action": "PAY_NOW",
                    "brand_name": "Cruise",
                    "locale": "en-US",
                    "return_url": "https://cruiseinride.com/products/vip-service?paypal_return=1",
                    "cancel_url": "https://cruiseinride.com/products/vip-service?paypal_cancel=1",
                },
            },
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "Prefer": "return=representation",
            },
        )
        if r.status_code not in (200, 201):
            logging.error("[WebPayPal] create failed: %s %s", r.status_code, r.text)
            raise HTTPException(502, "PayPal order creation failed")
        data = r.json()
        # Extract approve link, fallback to constructing it from order_id
        approve_url = next((l["href"] for l in data.get("links", []) if l.get("rel") in ("approve", "payer-action")), "")
        if not approve_url and data.get("id"):
            checkout_base = "https://www.sandbox.paypal.com" if PAYPAL_SANDBOX else "https://www.paypal.com"
            approve_url = f"{checkout_base}/checkoutnow?token={data['id']}"
        logging.info("[WebPayPal] order created: %s amount=$%s approve=%s", data.get("id"), amount_str, approve_url[:80])
        return {
            "order_id": data["id"],
            "status": data.get("status", ""),
            "approve_url": approve_url,
        }


@router.post("/payments/web/paypal/capture-order")
async def capture_web_paypal_order(request: Request):
    """Authorize (hold) the approved PayPal order — final capture happens when trip completes."""
    _verify_web_key(request)

    if not PAYPAL_CLIENT_ID or not PAYPAL_SECRET:
        raise HTTPException(503, "PayPal not configured")

    body = await request.json()
    order_id = body.get("order_id", "")
    if not order_id:
        raise HTTPException(400, "Missing order_id")

    import httpx
    base = "https://api-m.sandbox.paypal.com" if PAYPAL_SANDBOX else "https://api-m.paypal.com"
    token = await _paypal_token()

    async with httpx.AsyncClient(timeout=15) as client:
        # Authorize (hold). We'll capture server-side when trip completes.
        r = await client.post(
            f"{base}/v2/checkout/orders/{order_id}/authorize",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "Prefer": "return=representation",
            },
        )
        if r.status_code not in (200, 201):
            logging.error("[WebPayPal] authorize failed: %s %s", r.status_code, r.text)
            raise HTTPException(502, "PayPal authorize failed")
        data = r.json()
        # Extract the authorization_id (used later to capture or void)
        auth_id = ""
        try:
            auth_id = data["purchase_units"][0]["payments"]["authorizations"][0]["id"]
        except (KeyError, IndexError):
            pass
        logging.info("[WebPayPal] authorized: order=%s auth_id=%s", order_id, auth_id)
        return {
            "order_id": order_id,
            "status": data.get("status", ""),
            "authorization_id": auth_id,
        }


@router.post("/payments/web/paypal/capture-auth/{authorization_id}")
async def capture_web_paypal_auth(authorization_id: str, request: Request):
    """Capture a held PayPal authorization — called when trip completes."""
    _verify_web_key(request)

    if not PAYPAL_CLIENT_ID or not PAYPAL_SECRET:
        raise HTTPException(503, "PayPal not configured")

    import httpx
    base = "https://api-m.sandbox.paypal.com" if PAYPAL_SANDBOX else "https://api-m.paypal.com"
    token = await _paypal_token()

    async with httpx.AsyncClient(timeout=15) as client:
        r = await client.post(
            f"{base}/v2/payments/authorizations/{authorization_id}/capture",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "Prefer": "return=representation",
            },
        )
        if r.status_code not in (200, 201):
            logging.error("[WebPayPal] capture failed: %s %s", r.status_code, r.text)
            raise HTTPException(502, "PayPal capture failed")
        data = r.json()
        logging.info("[WebPayPal] captured: auth=%s capture_id=%s", authorization_id, data.get("id"))
        return {"capture_id": data.get("id"), "status": data.get("status", "")}


@router.post("/payments/web/paypal/void-auth/{authorization_id}")
async def void_web_paypal_auth(authorization_id: str, request: Request):
    """Void (release) a held PayPal authorization — called on trip cancel."""
    _verify_web_key(request)

    if not PAYPAL_CLIENT_ID or not PAYPAL_SECRET:
        raise HTTPException(503, "PayPal not configured")

    import httpx
    base = "https://api-m.sandbox.paypal.com" if PAYPAL_SANDBOX else "https://api-m.paypal.com"
    token = await _paypal_token()

    async with httpx.AsyncClient(timeout=15) as client:
        r = await client.post(
            f"{base}/v2/payments/authorizations/{authorization_id}/void",
            headers={"Authorization": f"Bearer {token}"},
        )
        if r.status_code not in (200, 204):
            logging.error("[WebPayPal] void failed: %s %s", r.status_code, r.text)
            raise HTTPException(502, "PayPal void failed")
        logging.info("[WebPayPal] voided: auth=%s", authorization_id)
        return {"status": "voided"}


from fastapi.responses import RedirectResponse

from utils.bounded_cache import TTLCache

# Rate limiting for web checkout — max 10 requests per IP per minute
# Bounded: max 5,000 IPs, entries expire after 1 minute
_web_checkout_hits = TTLCache[str, list](ttl_seconds=60, max_size=5000, name="web_checkout_hits")
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

    # SECURITY: Always verify Stripe webhook signature. Never process unsigned webhooks.
    if not sig_header:
        logging.warning("[Stripe Webhook] Missing stripe-signature header")
        raise HTTPException(400, "Missing stripe-signature")

    if not STRIPE_WEBHOOK_SECRET:
        logging.error("[Stripe Webhook] STRIPE_WEBHOOK_SECRET not configured — rejecting webhook")
        raise HTTPException(500, "Webhook secret not configured")

    if not _HAS_STRIPE or _stripe_mod is None:
        logging.error("[Stripe Webhook] Stripe SDK not available")
        raise HTTPException(500, "Stripe not available")

    try:
        event = _stripe_mod.Webhook.construct_event(payload, sig_header, STRIPE_WEBHOOK_SECRET)
    except ValueError:
        logging.warning("[Stripe Webhook] Invalid payload")
        raise HTTPException(400, "Invalid payload")
    except _stripe_mod.error.SignatureVerificationError:
        logging.warning("[Stripe Webhook] Invalid signature")
        raise HTTPException(400, "Invalid signature")

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
                if trip and trip.payment_status == "paid":
                    # A LATER failure must not un-pay a trip (2026-08-09): the
                    # fare-shortfall off-session retry (kind=fare_shortfall)
                    # fires payment_failed AFTER the fare itself was captured —
                    # this used to flip the trip to "failed" and push the rider
                    # a "Payment Failed" banner for a ride they had paid for.
                    logging.info(
                        "[Stripe Webhook] Trip %s already paid — ignoring payment_failed (pi=%s)",
                        trip_id, intent.get("id", ""),
                    )
                elif trip:
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


def _verify_web_hmac(request: Request) -> bool:
    """Validate HMAC-SHA256 signed request for web checkout.
    Expected headers: x-api-key, x-timestamp, x-signature
    """
    x_api_key = request.headers.get("x-api-key", "")
    x_timestamp = request.headers.get("x-timestamp", "")
    x_signature = request.headers.get("x-signature", "")
    if not x_api_key or not x_timestamp or not x_signature:
        return False
    if x_api_key != WEB_CHECKOUT_KEY:
        return False
    try:
        ts = int(x_timestamp)
        if abs(int(time.time()) - ts) > 300:
            return False
    except ValueError:
        return False
    msg = f"{x_api_key}:{x_timestamp}"
    expected = hmac.new(HMAC_SECRET.encode(), msg.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, x_signature)


def _web_key_check(request: Request):
    if _verify_web_hmac(request):
        return
    auth = request.headers.get("authorization", "")
    logging.debug("[WebKeyCheck] auth_header=%r key_set=%s", auth[:40] if auth else "", bool(WEB_CHECKOUT_KEY))
    if not WEB_CHECKOUT_KEY or not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    received = auth.split(" ", 1)[1]
    if received != WEB_CHECKOUT_KEY:
        logging.warning("[WebKeyCheck] MISMATCH received=%r expected_len=%d", received[:10], len(WEB_CHECKOUT_KEY))
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
    # trip.fare is what gets captured when the ride completes, so it must be a
    # number this server stands behind. Prefer the signed quote; fall back to
    # re-running the engine over a route we fetch ourselves. Only if both are
    # unavailable do we keep the client's figure, and then it is logged.
    _quote_claims = _quote_decode(body.get("quote_token") or "")
    if _quote_claims and int(_quote_claims.get("cents") or 0) > 0:
        _server_cents = int(_quote_claims["cents"])
    else:
        _server_cents = 0
        _mode = (body.get("trip_type") or "ride").lower()
        try:
            if _mode == "hourly":
                _server_cents = web_pricing.total_cents(
                    vehicle_type, hours=body.get("hours") or 0, mode="hourly",
                    airport_code=body.get("airport_code"), is_airport=bool(body.get("is_airport")),
                )
            elif pickup_lat and pickup_lng and dropoff_lat and dropoff_lng:
                _r = await _mapbox_route(pickup_lat, pickup_lng, dropoff_lat, dropoff_lng)
                if _r:
                    _server_cents = web_pricing.total_cents(
                        vehicle_type, seconds=_r[1], meters=_r[0], mode="ride",
                        airport_code=body.get("airport_code"), is_airport=bool(body.get("is_airport")),
                    )
        except Exception as e:
            logging.warning("[WebBooking] server-side repricing failed: %s", e)
    if _server_cents > 0:
        if fare_cents and fare_cents < _server_cents and WEB_PRICING_ENFORCE:
            logging.warning(
                "[WebBooking] rejected: client fare %s below server fare %s (%s)",
                fare_cents, _server_cents, vehicle_type,
            )
            raise HTTPException(400, "The price changed. Please refresh and try again.")
        if fare_cents != _server_cents:
            logging.info("[WebBooking] fare %s → %s (server)", fare_cents, _server_cents)
        # Never bill above the quote; a larger client figure is not a tip here.
        fare_cents = _server_cents
    else:
        logging.warning("[WebBooking] could not reprice — keeping client fare %s", fare_cents)
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
    logging.warning(
        "[WebBooking-DIAG] trip=%d guest_first=%r guest_last=%r guest_email=%r guest_phone=%r",
        trip.id,
        getattr(trip, "guest_first_name", None),
        getattr(trip, "guest_last_name", None),
        getattr(trip, "guest_email", None),
        getattr(trip, "guest_phone", None),
    )
    try:
        await notify_guest_welcome(db, trip)
    except Exception as _sms_err:
        logging.warning("[SMS] notify_guest_welcome failed for trip %s: %s", trip.id, _sms_err)
    try:
        await email_guest_welcome(db, trip)
    except Exception as _email_err:
        logging.warning("[EMAIL] email_guest_welcome failed for trip %s: %s", trip.id, _email_err)

    # The drink menu goes to the top tier, whatever it is called this
    # month. A literal == "vip" here stops firing the day the rider app
    # starts sending "black", and silently: nobody gets an email and no
    # log line says why.
    if vehicle_tiers.normalize_tier(trip.vehicle_type) == vehicle_tiers.TIER_BLACK:
        try:
            from config import PUBLIC_URL
            trip.vip_menu_token = generate_vip_menu_token()
            trip.vip_menu_sent_at = datetime.now(timezone.utc)
            db.add(trip)
            await db.commit()
            # Use the Vercel-deployed VIP menu page
            menu_url = f"https://rides-vip-menu.vercel.app?token={trip.vip_menu_token}"
            await email_vip_drink_menu(db, trip, menu_url)
            logging.info("[VIP] Drink menu email sent for trip %s", trip.id)
        except Exception as _vip_err:
            logging.warning("[VIP] Failed to send drink menu for trip %s: %s", trip.id, _vip_err)

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
        _safe_create_task(_bg_sched_firestore_sync())
        try:
            from services.fcm_service import send_to_topic_async
            _fare_str = f"${trip.fare:.2f}" if trip.fare else ""
            _pu = (trip.pickup_address or "")[:40]
            _do = (trip.dropoff_address or "")[:40]
            _sched_str = trip.scheduled_at.strftime("%b %d %I:%M %p") if trip.scheduled_at else ""
            _body = f"{_fare_str} \u00b7 {_pu} \u2192 {_do} \u00b7 {_sched_str}".strip(" \u00b7")
            _safe_create_task(send_to_topic_async(
                topic="drivers_available",
                title="New Scheduled Ride Available",
                body=_body,
                data={"type": "scheduled_ride", "trip_id": str(trip.id)},
            ))
        except Exception as _fcm_err:
            logging.warning("[WebBooking] FCM scheduled-ride broadcast failed: %s", _fcm_err)
    else:
        # Mirror the rider-app path: sync immediate web bookings to Firestore
        # so the dispatch panel and any other real-time listeners see them
        # appear as soon as they're created — with the guest's real name.
        try:
            _rn_imm, _rp_imm = _resolve_rider_display(trip, None)
            _trip_imm_snap = {
                "id": trip.id, "rider_id": trip.rider_id or 0,
                "rider_name": _rn_imm, "rider_phone": _rp_imm,
                "pickup_address": trip.pickup_address, "pickup_lat": trip.pickup_lat, "pickup_lng": trip.pickup_lng,
                "dropoff_address": trip.dropoff_address, "dropoff_lat": trip.dropoff_lat, "dropoff_lng": trip.dropoff_lng,
                "status": trip.status, "fare": trip.fare, "vehicle_type": trip.vehicle_type,
                "created_at": trip.created_at, "scheduled_at": None,
                "is_airport": getattr(trip, "is_airport", False) or False,
                "airport_code": getattr(trip, "airport_code", None),
                "terminal": getattr(trip, "terminal", None),
                "pickup_zone": getattr(trip, "pickup_zone", None),
                "notes": trip.notes,
            }
            async def _bg_imm_firestore_sync():
                try:
                    if _HAS_FIRESTORE and firestore_sync:
                        firestore_sync.sync_trip(
                            trip_id=_trip_imm_snap["id"], rider_id=_trip_imm_snap["rider_id"],
                            rider_name=_trip_imm_snap["rider_name"], rider_phone=_trip_imm_snap["rider_phone"],
                            pickup_address=_trip_imm_snap["pickup_address"], pickup_lat=_trip_imm_snap["pickup_lat"], pickup_lng=_trip_imm_snap["pickup_lng"],
                            dropoff_address=_trip_imm_snap["dropoff_address"], dropoff_lat=_trip_imm_snap["dropoff_lat"], dropoff_lng=_trip_imm_snap["dropoff_lng"],
                            status=_trip_imm_snap["status"], fare=_trip_imm_snap["fare"], vehicle_type=_trip_imm_snap["vehicle_type"],
                            created_at=_trip_imm_snap["created_at"], scheduled_at=_trip_imm_snap["scheduled_at"],
                            is_airport=_trip_imm_snap["is_airport"], airport_code=_trip_imm_snap["airport_code"],
                            terminal=_trip_imm_snap["terminal"], pickup_zone=_trip_imm_snap["pickup_zone"], notes=_trip_imm_snap["notes"],
                        )
                except Exception as _e:
                    logging.warning("[WebBooking] Firestore sync immediate trip %d failed: %s", trip.id, _e)
            _safe_create_task(_bg_imm_firestore_sync())
        except Exception as _fs_err:
            logging.warning("[WebBooking] Failed to schedule Firestore sync for trip %d: %s", trip.id, _fs_err)

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
                logging.info("[WebDispatch] No online drivers for trip %d — rider will see searching state", trip_id)
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
            _safe_create_task(_auto_cascade(trip_id, offer.id, first_driver.id))

    except Exception as e:
        logging.exception("[WebDispatch] Error for trip %d: %s", trip_id, e)


@router.post("/bookings/web/nearby-driver")
async def web_nearby_driver(request: Request, db: AsyncSession = Depends(get_db)):
    """How far (in minutes) is the nearest online driver from a point?

    The booking page polls this for its "Faster" badge, shown when a driver
    is ~10 min or less from the rider's pickup. Same web-key auth as the
    other web endpoints. Returns only coarse data (minutes + a count) — never
    the drivers' actual positions.

    Lives under /bookings/web/ because the Cloudflare Worker in front only
    proxies allowlisted path prefixes (/drivers/* answered path_not_allowed)."""
    _verify_web_origin(request)
    client_ip = request.client.host if request.client else "unknown"
    if _check_web_rate_limit(client_ip):
        raise HTTPException(429, "Too many requests — try again in a minute")
    _web_key_check(request)

    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Invalid JSON body")
    try:
        lat, lng = float(body.get("lat")), float(body.get("lng"))
    except (TypeError, ValueError):
        raise HTTPException(400, "lat and lng are required")

    r = await db.execute(
        select(User).where(
            User.role == "driver",
            User.is_online == True,
            User.lat != None,
            User.lng != None,
            User.status == "active",
        )
    )
    drivers = r.scalars().all()
    if not drivers:
        return {"eta_minutes": None, "online_drivers": 0}

    km = min(_haversine(lat, lng, float(d.lat), float(d.lng)) for d in drivers)
    # Same 40 km/h average city speed the live tracker uses for its ETA.
    eta_min = max(1, int(round((km / 40.0) * 60.0)))
    return {"eta_minutes": eta_min, "online_drivers": len(drivers)}


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
        # The rating card needs the real fare to offer honest 15/20/25% tips,
        # and tip_amount tells it whether this trip was tipped already.
        "fare": round(float(trip.fare or 0.0), 2),
        "tip_amount": round(float(trip.tip_amount or 0.0), 2),
    }

    if trip.driver_id:
        # Fetch driver user
        dr = await db.execute(select(User).where(User.id == trip.driver_id))
        driver = dr.scalar_one_or_none()
        if driver:
            resp["driver_name"] = f"{driver.first_name or ''} {driver.last_name or ''}".strip()
            resp["driver_phone"] = driver.phone or ""
            resp["driver_photo_url"] = _abs_photo_url(driver.photo_url) or ""

            # Live ETA + distance based on driver's last known GPS vs the
            # relevant destination (pickup if en route/arrived, dropoff if in trip).
            try:
                if driver.lat is not None and driver.lng is not None:
                    # The website tracker draws the driver's car on the map with
                    # these — same freshness the ETA below is computed from
                    # (driver app persists GPS every ≤3s while online).
                    resp["driver_lat"] = float(driver.lat)
                    resp["driver_lng"] = float(driver.lng)
                    raw_lower = (trip.status or "").lower()
                    if raw_lower in ("in_trip", "on_trip", "in_progress") and trip.dropoff_lat is not None:
                        tgt_lat, tgt_lng = float(trip.dropoff_lat), float(trip.dropoff_lng or 0)
                    elif trip.pickup_lat is not None:
                        tgt_lat, tgt_lng = float(trip.pickup_lat), float(trip.pickup_lng or 0)
                    else:
                        tgt_lat = tgt_lng = None
                    if tgt_lat is not None:
                        km = _haversine(float(driver.lat), float(driver.lng), tgt_lat, tgt_lng)
                        resp["distance_km"] = round(km, 2)
                        resp["distance_miles"] = round(km * 0.621371, 2)
                        # Assume 40 km/h average city speed; floor at 1 min so
                        # the UI never shows "0 min" while the driver is still moving.
                        eta_min = max(1, int(round((km / 40.0) * 60.0)))
                        resp["eta_minutes"] = eta_min
            except Exception:
                pass
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


@router.get("/bookings/web/{booking_id}/chat")
async def web_booking_chat_get(booking_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Fetch all chat messages for a web-booked trip. Guest side only — the
    rider (guest) can read all messages in the trip conversation."""
    _verify_web_origin(request)
    _web_key_check(request)
    from models.database import ChatMessage
    trip_res = await db.execute(select(Trip).where(Trip.id == booking_id))
    trip = trip_res.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Booking not found")
    msgs_res = await db.execute(
        select(ChatMessage).where(ChatMessage.trip_id == booking_id).order_by(ChatMessage.created_at.asc())
    )
    msgs = msgs_res.scalars().all()
    out = []
    for m in msgs:
        out.append({
            "id": m.id,
            "sender_role": "driver" if (trip.driver_id and m.sender_id == trip.driver_id) else "rider",
            "message": m.message,
            "created_at": m.created_at.isoformat() if m.created_at else None,
        })
    return {"messages": out}


@router.post("/bookings/web/{booking_id}/chat")
async def web_booking_chat_post(booking_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Send a chat message as the guest rider on a web-booked trip.
    The sender is the trip's rider_id (shared web@cruiseinride.com system user);
    the driver app's existing chat UI will render it seamlessly."""
    _verify_web_origin(request)
    _web_key_check(request)
    body = await request.json()
    msg_text = (body.get("message") or "").strip()
    if not msg_text:
        raise HTTPException(400, "Message cannot be empty")
    if len(msg_text) > 2000:
        msg_text = msg_text[:2000]
    from models.database import ChatMessage
    trip_res = await db.execute(select(Trip).where(Trip.id == booking_id))
    trip = trip_res.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Booking not found")
    if not trip.driver_id:
        raise HTTPException(409, "No driver assigned yet")
    if not trip.rider_id:
        raise HTTPException(500, "Trip has no rider_id; cannot send message")
    msg = ChatMessage(
        trip_id=booking_id,
        sender_id=trip.rider_id,
        receiver_id=trip.driver_id,
        message=msg_text,
    )
    db.add(msg)
    await db.commit()
    await db.refresh(msg)
    # Realtime Database mirror — THE channel the driver's chat actually reads
    # for a trip (chats/{tripId}/messages); the REST poll below is only its
    # fallback. Without this the driver got the push and an empty thread.
    try:
        if _HAS_FIRESTORE and firestore_sync:
            _safe_create_task(asyncio.to_thread(
                firestore_sync.send_chat_message_rtdb,
                booking_id, trip.rider_id, "rider", msg_text))
    except Exception as _rtdb_err:
        logging.warning("[WebChat] RTDB mirror failed for trip %d: %s", booking_id, _rtdb_err)
    # Socket.IO instant broadcast — the driver app listens on trip:{id} and
    # renders the bubble in <100ms. Without this the driver only saw the
    # message on its next poll, which is why web chat felt delayed.
    try:
        from services.socketio_service import emit_chat_message
        _safe_create_task(emit_chat_message(
            trip_id=booking_id,
            sender_id=trip.rider_id,
            sender_role="rider",
            message=msg_text,
            timestamp=int(msg.created_at.timestamp() * 1000) if msg.created_at
            else int(datetime.now(timezone.utc).timestamp() * 1000),
        ))
    except Exception as _sock_err:
        logging.warning("[WebChat] socket emit failed for trip %d: %s", booking_id, _sock_err)
    # FCM push to driver so the chat bubble pops in the driver app
    try:
        drv_res = await db.execute(select(User).where(User.id == trip.driver_id))
        drv = drv_res.scalar_one_or_none()
        if drv and drv.fcm_token:
            guest_name = (getattr(trip, "guest_first_name", None) or "Rider").strip()
            _send_fcm_push(
                drv.fcm_token,
                title=f"Message from {guest_name}",
                body=msg_text[:200],
                data={"type": "chat_message", "trip_id": str(booking_id), "sender_role": "rider"},
            )
    except Exception:
        pass
    return {
        "id": msg.id,
        "sender_role": "rider",
        "message": msg.message,
        "created_at": msg.created_at.isoformat() if msg.created_at else None,
    }


@router.post("/bookings/web/{booking_id}/cancel")
async def web_booking_cancel(booking_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Cancel a web booking end-to-end:
    - Mark trip cancelled in Postgres
    - Expire any pending DispatchOffers for this trip (so driver app stops showing it)
    - Invalidate pending-offer cache for affected drivers
    - Push empty offer list + trip_update via SSE so the driver app reflects the
      cancellation instantly (no polling delay)
    - Send FCM "booking_cancelled" push to drivers who had pending offers OR to
      the driver who already accepted
    - Refund Stripe payment intent if the booking was on hold
    - Sync status to Firestore so any other listeners see it
    """
    _verify_web_origin(request)
    _web_key_check(request)

    r = await db.execute(select(Trip).where(Trip.id == booking_id).with_for_update())
    trip = r.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Booking not found")

    # Idempotent: already cancelled/completed is a no-op success response
    _current = (trip.status or "").lower()
    if _current in ("cancelled", "canceled", "completed"):
        return {"ok": True, "status": _current, "already": True}

    # Can't cancel if the ride is already in progress — refund window closed
    if _current in ("in_trip", "in_progress", "on_trip"):
        raise HTTPException(409, "Cannot cancel a ride that is in progress")

    previous_status = trip.status
    previous_driver_id = trip.driver_id

    # Gather drivers to notify BEFORE we expire offers (needed for FCM fan-out)
    affected_driver_ids: set[int] = set()
    if previous_driver_id:
        affected_driver_ids.add(previous_driver_id)
    try:
        from models.database import DispatchOffer
        pending_q = await db.execute(
            select(DispatchOffer).where(
                DispatchOffer.trip_id == trip.id,
                DispatchOffer.status == "pending",
            )
        )
        for off in pending_q.scalars().all():
            affected_driver_ids.add(off.driver_id)
            off.status = "canceled"
    except Exception as _off_err:
        logging.warning("[WebCancel] Failed to expire pending offers for trip %d: %s", trip.id, _off_err)

    # Stripe release / refund (best-effort — fall back to pending_refund for manual review)
    refunded = False
    new_payment_status = trip.payment_status
    if trip.stripe_payment_intent_id and _HAS_STRIPE:
        try:
            import stripe as _stripe_mod
            if trip.payment_status == "held":
                # Uncaptured hold: settle through the shared helper —
                # partial-captures any cancellation fee and releases the
                # remainder instantly (2026-08-05).
                from routers.trips import _release_or_capture_fee_on_cancel
                new_payment_status = await _release_or_capture_fee_on_cancel(trip)
                refunded = True
                logging.info("[WebCancel] trip=%d hold settled via Stripe (%s)", trip.id, new_payment_status)
            elif trip.payment_status == "paid":
                # Already captured: create a refund
                _stripe_mod.Refund.create(
                    payment_intent=trip.stripe_payment_intent_id,
                    reason="requested_by_customer",
                )
                refunded = True
                new_payment_status = "refunded"
                logging.info("[WebCancel] trip=%d refunded via Stripe", trip.id)
        except Exception as _refund_err:
            new_payment_status = "pending_refund"
            logging.warning("[WebCancel] trip=%d refund/cancel failed, marking pending_refund: %s", trip.id, _refund_err)

    trip.status = "cancelled"
    trip.cancel_reason = "rider_web_cancel"
    trip.payment_status = new_payment_status
    trip.updated_at = datetime.now(timezone.utc)
    await db.commit()

    # Invalidate cache + SSE push to affected drivers
    try:
        from routers.dispatch import _pending_cache as _dispatch_pending_cache
        for drv_id in affected_driver_ids:
            _dispatch_pending_cache.pop(drv_id, None)
    except Exception:
        pass

    try:
        from services.event_bus import event_bus as _ev_bus
        for drv_id in affected_driver_ids:
            _safe_create_task(_ev_bus.push_driver_offer(drv_id, []))
        # Also push a trip_update so rider-tracking-style listeners notice
        _safe_create_task(_ev_bus.push_trip_update(trip.id, {
            "status": "cancelled",
            "cancel_reason": "rider_web_cancel",
            "cancelled_by": "rider",
        }))
    except Exception as _ev_err:
        logging.warning("[WebCancel] SSE broadcast failed for trip %d: %s", trip.id, _ev_err)

    # FCM push to each affected driver so the driver app banner/toast appears
    # even if they don't have an SSE session open.
    try:
        from services.fcm_service import _send_fcm_push_async
        if affected_driver_ids:
            drv_q = await db.execute(select(User).where(User.id.in_(list(affected_driver_ids))))
            for drv in drv_q.scalars().all():
                if not drv.fcm_token:
                    continue
                _safe_create_task(_send_fcm_push_async(
                    drv.fcm_token,
                    title="Ride cancelled",
                    body="The rider cancelled this trip.",
                    data={
                        "type": "booking_cancelled",
                        "trip_id": str(trip.id),
                        "cancelled_by": "rider",
                    },
                ))
    except Exception as _fcm_err:
        logging.warning("[WebCancel] FCM fan-out failed for trip %d: %s", trip.id, _fcm_err)

    # Firestore sync so any mirroring listeners pick it up
    if _HAS_FIRESTORE and firestore_sync:
        try:
            firestore_sync.sync_trip_status(
                trip_id=trip.id,
                status="cancelled",
                cancel_reason="rider_web_cancel",
                cancelled_by="rider",
                payment_status=new_payment_status,
            )
        except Exception as _fs_err:
            logging.warning("[WebCancel] Firestore sync failed for trip %d: %s", trip.id, _fs_err)

    logging.info(
        "[WebCancel] trip=%d previous_status=%r driver=%s affected_drivers=%s refunded=%s",
        trip.id, previous_status, previous_driver_id, sorted(affected_driver_ids), refunded,
    )

    return {
        "ok": True,
        "status": "cancelled",
        "refunded": refunded,
        "payment_status": new_payment_status,
        "affected_drivers": len(affected_driver_ids),
    }


@router.post("/bookings/web/{booking_id}/rate")
async def web_booking_rate(booking_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Rate the driver of a finished web booking — the guest counterpart of
    /trips/{id}/rate. Stars + optional comment only: a web guest has no saved
    card on file, so there is nothing to charge a tip against and we do not
    pretend otherwise."""
    _verify_web_origin(request)
    _web_key_check(request)
    body = await request.json()
    try:
        stars = int(body.get("stars"))
    except (TypeError, ValueError):
        raise HTTPException(400, "stars is required")
    if stars < 1 or stars > 5:
        raise HTTPException(400, "Stars must be 1-5")
    comment = str(body.get("comment") or "").strip()[:500]

    r = await db.execute(select(Trip).where(Trip.id == booking_id))
    trip = r.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Booking not found")
    if (trip.status or "").lower() not in ("completed", "cancelled", "canceled"):
        raise HTTPException(400, "Trip must be completed before rating")
    if not trip.driver_id:
        raise HTTPException(400, "Cannot rate - no driver on this trip")
    if not trip.rider_id:
        raise HTTPException(500, "Trip has no rider_id")

    # One rating per trip, same as the app endpoint.
    dup = await db.execute(
        select(Rating).where(Rating.trip_id == booking_id, Rating.from_user_id == trip.rider_id)
    )
    if dup.scalar_one_or_none():
        return {"status": "ok", "already": True}

    rating = Rating(
        trip_id=booking_id,
        from_user_id=trip.rider_id,
        to_user_id=trip.driver_id,
        stars=stars,
        comment=comment or None,
    )
    db.add(rating)
    await db.commit()

    # Recompute the driver's average so the next rider sees it immediately.
    try:
        avg_res = await db.execute(
            select(func.avg(Rating.stars)).where(Rating.to_user_id == trip.driver_id)
        )
        avg = avg_res.scalar()
        if avg is not None:
            drv = (await db.execute(select(User).where(User.id == trip.driver_id))).scalar_one_or_none()
            if drv:
                drv.average_rating = round(float(avg), 2)
                await db.commit()
    except Exception as _avg_err:
        logging.warning("[WebRate] average recompute failed for trip %d: %s", booking_id, _avg_err)

    logging.info("[WebRate] Trip %s rated %s stars from web", booking_id, stars)
    return {"status": "ok", "stars": stars}


# ── Tips from the website (2026-08-12) ─────────────────────────────────
#    The app tips off the rider's saved card (/trips/{id}/rate → tip_amount)
#    and credits 100% of it to the driver. A web rider may have no card on
#    file, so this endpoint has two doors:
#      1. saved card  → charged off_session right here, one tap, like the app
#      2. no card     → returns a PaymentIntent the browser confirms, and the
#                       page calls back with its id so we can verify and credit
#    Money is only credited once Stripe says the charge succeeded.

_WEB_TIP_MIN_CENTS = 100
_WEB_TIP_MAX_CENTS = 10000


async def _web_tip_credit(db, trip, amount_cents: int, intent_id: str):
    """100% of the tip goes to the driver — same split the app applies."""
    if trip.stripe_tip_payment_intent_id:
        logging.warning("[WebTip] Trip %s already credited (%s), skipping",
                        trip.id, trip.stripe_tip_payment_intent_id)
        return
    amt = round(amount_cents / 100.0, 2)
    trip.tip_amount = round((trip.tip_amount or 0.0) + amt, 2)
    trip.stripe_tip_payment_intent_id = intent_id
    if trip.driver_earnings:
        trip.driver_earnings = round(trip.driver_earnings + amt, 2)
    drv = (await db.execute(select(User).where(User.id == trip.driver_id))).scalar_one_or_none()
    if drv:
        drv.pending_balance = round((drv.pending_balance or 0.0) + amt, 2)
        drv.total_earnings = round((drv.total_earnings or 0.0) + amt, 2)
    # The web rating already inserted the Rating row; hang the tip on it so
    # the driver's history shows the same shape an app tip does.
    if trip.rider_id:
        rating = (await db.execute(select(Rating).where(
            Rating.trip_id == trip.id, Rating.from_user_id == trip.rider_id
        ))).scalar_one_or_none()
        if rating:
            rating.tip_amount = round((rating.tip_amount or 0.0) + amt, 2)
    await db.commit()
    logging.info("[WebTip] Trip %s: $%.2f credited to driver %s", trip.id, amt, trip.driver_id)

    try:
        from models.database import Notification
        db.add(Notification(
            user_id=trip.driver_id,
            title="New tip",
            body=f"Your rider left you a ${amt:.2f} tip!",
            notif_type="trip",
        ))
        await db.commit()
    except Exception as e:
        logging.warning("[WebTip] notification failed for trip %s: %s", trip.id, e)
    try:
        if drv and drv.fcm_token:
            _send_fcm_push(
                drv.fcm_token,
                title="You got a tip 🎉",
                body=f"Your rider left you a ${amt:.2f} tip.",
                data={"type": "tip", "trip_id": str(trip.id)},
            )
    except Exception as e:
        logging.warning("[WebTip] FCM failed for trip %s: %s", trip.id, e)


@router.post("/bookings/web/{booking_id}/tip")
async def web_booking_tip(booking_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Tip the driver of a finished web booking. Two-step for guests."""
    _verify_web_origin(request)
    _web_key_check(request)
    body = await request.json()
    try:
        cents = int(body.get("amount_cents"))
    except (TypeError, ValueError):
        raise HTTPException(400, "amount_cents is required")
    if cents < _WEB_TIP_MIN_CENTS or cents > _WEB_TIP_MAX_CENTS:
        raise HTTPException(400, "Tip must be between $1 and $100")

    trip = (await db.execute(select(Trip).where(Trip.id == booking_id))).scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Booking not found")
    if (trip.status or "").lower() not in ("completed", "ended"):
        raise HTTPException(409, "Trip must be completed before tipping")
    if not trip.driver_id:
        raise HTTPException(409, "Trip has no driver")
    if trip.stripe_tip_payment_intent_id or (trip.tip_amount or 0.0) > 0:
        raise HTTPException(409, "This trip was already tipped")
    if not _HAS_STRIPE or not _stripe_mod:
        raise HTTPException(503, "Stripe not configured")

    loop = asyncio.get_event_loop()

    # Door 2, second half: the browser already paid — verify with Stripe and credit.
    pi_id = str(body.get("payment_intent_id") or "").strip()
    if pi_id:
        try:
            pi = await asyncio.wait_for(
                loop.run_in_executor(None, lambda: _stripe_mod.PaymentIntent.retrieve(pi_id)),
                timeout=15.0,
            )
        except Exception as e:
            logging.error("[WebTip] retrieve %s failed: %s", pi_id, e)
            raise HTTPException(502, "Could not verify the tip payment")
        meta = pi.get("metadata") or {}
        if str(meta.get("trip_id")) != str(trip.id) or meta.get("type") != "tip":
            raise HTTPException(400, "That payment does not belong to this trip")
        if pi.get("status") != "succeeded":
            raise HTTPException(402, "Tip payment not completed")
        paid = int(pi.get("amount_received") or pi.get("amount") or 0)
        if paid < _WEB_TIP_MIN_CENTS:
            raise HTTPException(400, "Tip amount too small")
        await _web_tip_credit(db, trip, paid, pi_id)
        return {"status": "ok", "paid": True, "tip_cents": paid}

    # Door 1: rider with a session and a card on file → charge it off_session.
    user = None
    tok = str(body.get("user_token") or "").strip()
    if tok:
        try:
            payload = jwt.decode(tok, JWT_SECRET, algorithms=[JWT_ALGORITHM])
            uid = int(payload.get("sub") or 0)
            if uid:
                user = (await db.execute(
                    select(User).where(User.id == uid, User.role == "rider")
                )).scalar_one_or_none()
        except Exception as e:
            logging.warning("[WebTip] user_token decode failed: %s", e)
    if user and user.stripe_customer_id:
        pm = (await db.execute(
            select(RiderPaymentMethod).where(
                RiderPaymentMethod.user_id == user.id,
                RiderPaymentMethod.method_type == "stripe_card",
                RiderPaymentMethod.stripe_pm_id.isnot(None),
            ).order_by(RiderPaymentMethod.is_default.desc())
        )).scalars().first()
        if pm:
            try:
                intent = await asyncio.wait_for(
                    loop.run_in_executor(None, lambda: _stripe_mod.PaymentIntent.create(
                        amount=cents,
                        currency="usd",
                        customer=user.stripe_customer_id,
                        payment_method=pm.stripe_pm_id,
                        confirm=True,
                        off_session=True,
                        automatic_payment_methods={"enabled": True, "allow_redirects": "never"},
                        description=f"Tip - Cruise trip {trip.id}",
                        metadata={"trip_id": str(trip.id), "type": "tip",
                                  "rider_id": str(user.id), "source": "web"},
                    )),
                    timeout=20.0,
                )
                if intent.status == "succeeded":
                    await _web_tip_credit(db, trip, cents, intent.id)
                    return {"status": "ok", "paid": True, "tip_cents": cents,
                            "card": pm.display_name}
                logging.warning("[WebTip] saved card ended in %s for trip %s",
                                intent.status, trip.id)
            except Exception as e:
                # Expired card, 3DS required, anything: fall through to the
                # browser flow instead of losing the tip.
                logging.warning("[WebTip] saved-card charge failed for trip %s: %s", trip.id, e)

    # Door 2, first half: no usable card on file — the browser pays.
    try:
        intent = await asyncio.wait_for(
            loop.run_in_executor(None, lambda: _stripe_mod.PaymentIntent.create(
                amount=cents,
                currency="usd",
                automatic_payment_methods={"enabled": True},
                description=f"Tip - Cruise trip {trip.id}",
                metadata={"trip_id": str(trip.id), "type": "tip", "source": "web"},
            )),
            timeout=20.0,
        )
    except Exception as e:
        logging.error("[WebTip] intent create failed for trip %s: %s", trip.id, e)
        raise HTTPException(502, "Could not start the tip payment")
    return {"status": "requires_payment", "client_secret": intent.client_secret,
            "payment_intent_id": intent.id, "tip_cents": cents}


# ── Rider ↔ driver handshake at the pickup (2026-08-12) ────────────────
#    The driver's screen sits on "Waiting for your rider" until the trip doc
#    carries rider_confirmed_pickup; only then does the Start Trip slider
#    unlock. In the app the rider writes that flag itself; a rider booking
#    from cruiseinride.com has no Firebase session, so its "I'm with my
#    driver" button lands here and we write the same flag on its behalf.

_WEB_RIDER_CONFIRM_STATUSES = (
    "accepted", "driver_assigned", "driver_en_route", "driver_enroute",
    "arrived", "arrived_at_pickup", "arrived_pickup", "driver_arrived",
)


@router.post("/bookings/web/{booking_id}/rider-confirmed")
async def web_booking_rider_confirmed(booking_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Rider confirms they are with the driver — unlocks the driver's Start Trip."""
    _verify_web_origin(request)
    _web_key_check(request)

    r = await db.execute(select(Trip).where(Trip.id == booking_id))
    trip = r.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Booking not found")
    raw = (trip.status or "").lower()
    # Already rolling: the driver started without waiting for us. Nothing to
    # unlock, and no reason to make the website show an error for it.
    if raw in ("in_trip", "on_trip", "in_progress", "trip_started", "rider_onboard"):
        return {"status": "ok", "already": True}
    if raw not in _WEB_RIDER_CONFIRM_STATUSES:
        raise HTTPException(409, f"Trip cannot be confirmed from status {trip.status}")
    if not trip.driver_id:
        raise HTTPException(409, "Trip has no driver yet")

    synced = False
    if _HAS_FIRESTORE and firestore_sync:
        try:
            synced = bool(firestore_sync.sync_rider_confirmed_pickup(trip.id))
        except Exception as e:
            logging.error("[WebRiderConfirm] Firestore sync failed for %s: %s", trip.id, e)

    # Push as well: the flag alone only shows if the driver has the trip screen
    # open. The banner is what gets them to look at the phone.
    try:
        drv = (await db.execute(select(User).where(User.id == trip.driver_id))).scalar_one_or_none()
        if drv and drv.fcm_token:
            _send_fcm_push(
                drv.fcm_token,
                title="Your rider is with you",
                body="The rider confirmed they are in the car — you can start the trip.",
                data={"type": "rider_confirmed_pickup", "trip_id": str(trip.id)},
            )
    except Exception as _fcm_err:
        logging.warning("[WebRiderConfirm] FCM failed for trip %d: %s", trip.id, _fcm_err)

    logging.info("[WebRiderConfirm] Trip %s: rider confirmed pickup from web (synced=%s)",
                 trip.id, synced)
    if not synced:
        # Without the Firestore write the driver never sees it — say so, so the
        # website can fall back to the chat message instead of lying to the rider.
        raise HTTPException(503, "Could not notify the driver")
    return {"status": "ok", "synced": True}


# ── Web route changes (2026-08-12): mirrors /trips/{id}/stops and
#    /trips/{id}/destination from routers/trips.py, but authenticated the
#    web way (origin + WEB_CHECKOUT_KEY) like the other /bookings/web/*.
#    The extra/new fare comes from the client's anchored math (same table
#    as the app: stop_pricing.dart) and is clamped to the same honest
#    bands the app endpoints enforce.

_WEB_ROUTE_CHANGE_STATUSES = ("accepted", "driver_en_route", "arrived", "in_trip")


async def _web_notify_driver_route_change(db, trip, title: str, body_text: str):
    """FCM to the driver — same banner the app's route-change endpoints send."""
    if not trip.driver_id:
        return
    try:
        drv = (await db.execute(select(User).where(User.id == trip.driver_id))).scalar_one_or_none()
        if drv and drv.fcm_token:
            _send_fcm_push(
                drv.fcm_token,
                title=title,
                body=body_text,
                data={"type": "route_change", "trip_id": str(trip.id)},
            )
    except Exception as _fcm_err:
        logging.warning("[WebStops] FCM failed for trip %d: %s", trip.id, _fcm_err)


@router.post("/bookings/web/{booking_id}/stops")
async def web_booking_add_stop(booking_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Add ONE stop to a web-booked trip (one per trip, like the app)."""
    _verify_web_origin(request)
    _web_key_check(request)
    body = await request.json()
    try:
        lat = float(body.get("lat"))
        lng = float(body.get("lng"))
        extra = int(body.get("extra_cents"))
    except (TypeError, ValueError):
        raise HTTPException(400, "lat, lng and extra_cents are required")
    label = str(body.get("label") or "").strip()[:200]
    if not (-90.0 <= lat <= 90.0 and -180.0 <= lng <= 180.0):
        raise HTTPException(400, "Invalid coordinates")

    r = await db.execute(select(Trip).where(Trip.id == booking_id).with_for_update())
    trip = r.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Booking not found")
    if (trip.status or "") not in _WEB_ROUTE_CHANGE_STATUSES:
        raise HTTPException(409, f"Trip cannot add a stop from status {trip.status}")
    existing = []
    if trip.stops:
        try:
            existing = json.loads(trip.stops) or []
        except Exception:
            existing = []
    if existing:
        raise HTTPException(409, "Trip already has a stop (one per trip)")

    # Money band: floor at the $2.50 stop fee, cap at $200 of extra —
    # outside that the client math is broken, not the road.
    if extra < 250:
        extra = 250
    if extra > 20000:
        raise HTTPException(400, "Stop extra out of range")

    stop = {
        "lat": lat,
        "lng": lng,
        "label": label,
        "extra_cents": extra,
        "added_at": datetime.now(timezone.utc).isoformat(),
    }
    trip.stops = json.dumps([stop])
    trip.fare = round((trip.fare or 0.0) + extra / 100.0, 2)
    await db.commit()

    if _HAS_FIRESTORE and firestore_sync:
        try:
            firestore_sync.sync_trip_route_change(
                trip.id, stops=[stop], fare=trip.fare, change_type="stop_added")
        except Exception as e:
            logging.error("[WebStops] Firestore sync failed for %s: %s", trip.id, e)
    await _web_notify_driver_route_change(
        db, trip, "New stop added",
        label or "The rider added a stop — open Cruise")
    logging.info("[WebStops] Trip %s: stop added (+$%.2f) via web", trip.id, extra / 100.0)
    return {"status": "ok", "stops": [stop], "fare": trip.fare}


@router.post("/bookings/web/{booking_id}/destination")
async def web_booking_change_destination(booking_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Change the destination of a web-booked trip. The client sends the
    SIGNED fare delta in cents (negative when the new drop-off is closer)."""
    _verify_web_origin(request)
    _web_key_check(request)
    body = await request.json()
    try:
        lat = float(body.get("lat"))
        lng = float(body.get("lng"))
    except (TypeError, ValueError):
        raise HTTPException(400, "lat and lng are required")
    label = str(body.get("label") or "").strip()[:300]
    if not (-90.0 <= lat <= 90.0 and -180.0 <= lng <= 180.0):
        raise HTTPException(400, "Invalid coordinates")
    try:
        delta = int(body.get("extra_cents"))
    except (TypeError, ValueError):
        delta = None

    r = await db.execute(select(Trip).where(Trip.id == booking_id).with_for_update())
    trip = r.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Booking not found")
    if (trip.status or "") not in _WEB_ROUTE_CHANGE_STATUSES:
        raise HTTPException(409, f"Trip cannot change destination from status {trip.status}")

    trip.dropoff_lat = lat
    trip.dropoff_lng = lng
    if label:
        trip.dropoff_address = label
    if delta is not None:
        # Same honest band every fare in this codebase lives in.
        if not (-20000 <= delta <= 20000):
            raise HTTPException(400, "Fare delta out of range")
        new_fare = round((trip.fare or 0.0) + delta / 100.0, 2)
        if not (3.0 <= new_fare <= 500.0):
            raise HTTPException(400, "Fare out of range")
        trip.fare = new_fare
    await db.commit()

    if _HAS_FIRESTORE and firestore_sync:
        try:
            firestore_sync.sync_trip_route_change(
                trip.id,
                dropoff={"lat": lat, "lng": lng, "label": trip.dropoff_address},
                fare=trip.fare,
                change_type="destination_changed")
        except Exception as e:
            logging.error("[WebStops] Firestore sync failed for %s: %s", trip.id, e)
    await _web_notify_driver_route_change(
        db, trip, "Destination changed",
        trip.dropoff_address or "The rider changed the destination — open Cruise")
    logging.info("[WebStops] Trip %s: destination changed via web", trip.id)
    return {"status": "ok", "dropoff_address": trip.dropoff_address, "fare": trip.fare}


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


# -------------------------------------------------------
#  WEB PAYMENT METHODS — list / add card from cruiseinride.com
#  JWT-authenticated (the rider's vr_at token), no HMAC. The mobile
#  equivalents (/riders/payment-methods, /payments/setup-intent,
#  /users/me/payment-methods/sync) all hang off _verify_api_key, whose
#  X-Timestamp/X-Nonce/X-Signature triple the browser cannot produce.
# -------------------------------------------------------

async def _web_jwt_user(request: Request, db: AsyncSession) -> User:
    """Resolve the signed-in rider for /auth/web/* endpoints that act on an
    account: origin check + the user JWT (not the web checkout key)."""
    _verify_web_origin(request)
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    token = auth.split(" ", 1)[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        user_id = int(payload.get("sub", 0))
    except (jwt.InvalidTokenError, ValueError):
        raise HTTPException(401, "Invalid or expired token")
    if not user_id:
        raise HTTPException(401, "Invalid token")
    r = await db.execute(select(User).where(User.id == user_id))
    user = r.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")
    return user


@router.get("/auth/web/payment-methods")
async def web_list_payment_methods(request: Request, db: AsyncSession = Depends(get_db)):
    """Saved payment methods for the signed-in rider. Card details
    (brand/last4/exp) come from Stripe by customer, so cards saved from the
    app and from the web both show up with the same data."""
    user = await _web_jwt_user(request, db)
    r = await db.execute(
        select(RiderPaymentMethod).where(RiderPaymentMethod.user_id == user.id)
        .order_by(RiderPaymentMethod.is_default.desc(), RiderPaymentMethod.created_at.desc())
    )
    rows = r.scalars().all()
    default_ids = {m.stripe_pm_id for m in rows if m.is_default}
    stripe_cards = []
    if _HAS_STRIPE and user.stripe_customer_id:
        try:
            listing = _stripe_mod.PaymentMethod.list(
                customer=user.stripe_customer_id, type="card", limit=20
            )
            stripe_cards = list(getattr(listing, "data", []) or [])
        except Exception as e:
            logging.warning("[/auth/web/payment-methods] Stripe list failed for %s: %s", user.id, e)
    out, seen = [], set()
    for pm in stripe_cards:
        card = getattr(pm, "card", None)
        out.append({
            "stripe_pm_id": pm.id,
            "method_type": "stripe_card",
            "brand": getattr(card, "brand", None),
            "last4": getattr(card, "last4", None),
            "exp_month": getattr(card, "exp_month", None),
            "exp_year": getattr(card, "exp_year", None),
            "is_default": pm.id in default_ids,
        })
        seen.add(pm.id)
    for m in rows:
        if m.stripe_pm_id in seen:
            continue
        out.append({
            "stripe_pm_id": m.stripe_pm_id,
            "method_type": m.method_type,
            "display_name": m.display_name,
            "brand": None, "last4": None, "exp_month": None, "exp_year": None,
            "is_default": m.is_default,
        })
    return out


@router.post("/auth/web/payments/setup-intent")
async def web_create_setup_intent(request: Request, db: AsyncSession = Depends(get_db)):
    """SetupIntent so the website can save a card (or US bank account when
    the Stripe account has it enabled) for off-session charging."""
    user = await _web_jwt_user(request, db)
    if not _HAS_STRIPE:
        raise HTTPException(503, "Stripe not configured")
    customer_id = await _get_or_create_stripe_customer(user, db)
    if not customer_id:
        raise HTTPException(500, "Could not initialise payment customer")
    last_err = None
    for types in (["card", "us_bank_account"], ["card"]):
        try:
            intent = _stripe_mod.SetupIntent.create(
                customer=customer_id,
                usage="off_session",
                payment_method_types=types,
                metadata={"user_id": str(user.id), "source": "web"},
            )
            return {"client_secret": intent.client_secret, "customer_id": customer_id}
        except _stripe_mod.error.StripeError as e:
            # us_bank_account may not be enabled on the account — retry card-only
            last_err = e
            continue
    raise HTTPException(400, str(getattr(last_err, "user_message", None) or last_err))


@router.post("/auth/web/payment-methods/sync")
async def web_sync_payment_method(request: Request, db: AsyncSession = Depends(get_db)):
    """Persist a Stripe PaymentMethod the browser just confirmed, mirroring
    POST /users/me/payment-methods/sync so web-added cards appear in the app.
    Verifies the PM hangs off this rider's Stripe customer before saving."""
    user = await _web_jwt_user(request, db)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Invalid JSON body")
    if not isinstance(body, dict):
        raise HTTPException(400, "Body must be an object")
    pm_id = (body.get("stripe_pm_id") or "").strip()
    if not pm_id:
        raise HTTPException(400, "stripe_pm_id is required")
    display_name = (body.get("display_name") or "Card").strip()[:60] or "Card"
    set_default = bool(body.get("set_default"))
    if _HAS_STRIPE:
        try:
            pm = _stripe_mod.PaymentMethod.retrieve(pm_id)
            pm_customer = getattr(pm, "customer", None)
            if pm_customer and user.stripe_customer_id and pm_customer != user.stripe_customer_id:
                raise HTTPException(403, "Payment method belongs to another customer")
        except HTTPException:
            raise
        except Exception as e:
            logging.warning("[/auth/web/payment-methods/sync] PM retrieve failed: %s", e)
    existing_r = await db.execute(
        select(RiderPaymentMethod).where(
            RiderPaymentMethod.user_id == user.id,
            RiderPaymentMethod.stripe_pm_id == pm_id,
        )
    )
    existing = existing_r.scalar_one_or_none()
    if existing:
        return {"status": "already_exists", "method_id": existing.id}
    if set_default:
        await db.execute(
            text("UPDATE rider_payment_methods SET is_default = FALSE WHERE user_id = :uid"),
            {"uid": user.id},
        )
    method = RiderPaymentMethod(
        user_id=user.id,
        method_type=(body.get("method_type") or "stripe_card"),
        display_name=display_name,
        stripe_pm_id=pm_id,
        is_default=set_default,
    )
    db.add(method)
    await db.commit()
    await db.refresh(method)
    return {"status": "created", "method_id": method.id}


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
            await trigger_welcome_email(user.email, user.first_name)
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
    except jwt.InvalidTokenError:
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
            from jwt import PyJWK
            public_key = PyJWK(key_data).key
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


# -----------------------------------------------------------------
# SCHEDULED RIDE EMAIL NOTIFICATIONS (SMTP) — use shared Cruise template
# -----------------------------------------------------------------
from services.email_sms_service import _send_email as _send_email_smtp
from services.email_service import (
    _shell, _h1, _h2, _p, _badge, _info_card, _row, _route_block
)
import asyncio as _asyncio_email


def _sched_summary(pickup, dropoff, when, vehicle, booking_id, lang="en"):
    lbl_sched = "Programado para" if lang == "es" else "Scheduled for"
    lbl_vehicle = "Vehículo" if lang == "es" else "Vehicle"
    lbl_booking = "Reserva" if lang == "es" else "Booking"
    lbl_details = "Detalles del viaje" if lang == "es" else "Ride details"
    info_rows = _row(lbl_sched, when) + _row(lbl_vehicle, vehicle) + _row(lbl_booking, str(booking_id), last=True)
    return _route_block(pickup, dropoff, lang) + _h2(lbl_details) + _info_card(info_rows)


@router.post("/emails/web/sched-confirm")
async def email_sched_confirm(request: Request):
    """Send 'Ride reserved' confirmation email (scheduled only)."""
    _verify_web_origin(request)
    auth = request.headers.get("authorization", "")
    if not WEB_CHECKOUT_KEY or not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    if auth.split(" ", 1)[1] != WEB_CHECKOUT_KEY:
        raise HTTPException(401, "Invalid key")

    body = await request.json()
    to = (body.get("to_email") or "").strip()
    if not to:
        raise HTTPException(400, "Missing email")
    name = body.get("to_name") or "Guest"
    lang = (body.get("lang") or "en").lower()
    vehicle = body.get("vehicle") or "Cruise"
    pickup = body.get("pickup") or "—"
    dropoff = body.get("dropoff") or "—"
    when = body.get("scheduled_when") or "—"
    booking_id = body.get("booking_id") or "—"

    if lang == "es":
        subject = f"Tu viaje está reservado — {booking_id}"
        preheader = "Te notificaremos cuando un conductor sea asignado."
        heading = "Tu reserva está confirmada"
        intro = (f"Hola {name}, hemos confirmado tu viaje programado. "
                 "Te avisaremos por email en cuanto un conductor acepte tu viaje.")
        status_badge = _badge("Ride Reserved", "#E8C547")
        hold_note = ("Tu tarjeta tiene un monto en espera (hold). "
                     "Solo se cobrará cuando el viaje se complete.")
    else:
        subject = f"Your ride is reserved — {booking_id}"
        preheader = "We'll email you the moment a driver is assigned."
        heading = "Your reservation is confirmed"
        intro = (f"Hi {name}, we've locked in your scheduled ride. "
                 "We'll email you as soon as a driver accepts.")
        status_badge = _badge("Ride Reserved", "#E8C547")
        hold_note = ("A hold has been placed on your card. "
                     "You'll only be charged when the trip is completed.")

    body_html = (
        f'<div style="text-align:center;margin-bottom:20px;">{status_badge}</div>'
        + _h1(heading)
        + _p(intro)
        + _sched_summary(pickup, dropoff, when, vehicle, booking_id, lang)
        + _p(hold_note)
    )
    html = _shell(subject, preheader, body_html)

    loop = _asyncio_email.get_event_loop()
    try:
        sent = await loop.run_in_executor(None, lambda: _send_email_smtp(to, subject, html, skip_emailjs=True))
        return {"ok": bool(sent), "to": to}
    except Exception as e:
        logging.error("[email sched-confirm] %s", e)
        raise HTTPException(500, "email send failed")


@router.post("/emails/web/sched-driver")
async def email_sched_driver(request: Request):
    """Send 'Driver confirmed' email for scheduled rides."""
    _verify_web_origin(request)
    auth = request.headers.get("authorization", "")
    if not WEB_CHECKOUT_KEY or not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    if auth.split(" ", 1)[1] != WEB_CHECKOUT_KEY:
        raise HTTPException(401, "Invalid key")

    body = await request.json()
    to = (body.get("to_email") or "").strip()
    if not to:
        raise HTTPException(400, "Missing email")
    name = body.get("to_name") or "Guest"
    lang = (body.get("lang") or "en").lower()
    vehicle = body.get("vehicle") or "Cruise"
    pickup = body.get("pickup") or "—"
    dropoff = body.get("dropoff") or "—"
    when = body.get("scheduled_when") or "—"
    driver_name = body.get("driver_name") or ("Tu conductor" if lang == "es" else "Your driver")
    driver_rating = body.get("driver_rating") or ""
    vehicle_make = body.get("vehicle_make") or ""
    vehicle_model = body.get("vehicle_model") or ""
    vehicle_plate = body.get("vehicle_plate") or ""
    booking_id = body.get("booking_id") or "—"

    car_desc = " ".join([p for p in [vehicle_make, vehicle_model] if p]).strip() or "—"
    rating_str = f"⭐ {driver_rating}" if driver_rating else ""
    plate_str = vehicle_plate or "—"

    if lang == "es":
        subject = f"Tu conductor está confirmado — {booking_id}"
        preheader = f"{driver_name} te recogerá a la hora programada."
        heading = "Tu conductor está listo"
        intro = (f"Hola {name}, tu conductor para el viaje programado ha sido asignado. "
                 "Te enviaremos otra notificación cuando esté en camino.")
        status_badge = _badge("Driver Confirmed", "#22c55e")
        lbl_driver = "Tu conductor"
        lbl_car = "Vehículo del conductor"
        lbl_plate = "Placa"
    else:
        subject = f"Your driver is confirmed — {booking_id}"
        preheader = f"{driver_name} will pick you up at your scheduled time."
        heading = "Your driver is ready"
        intro = (f"Hi {name}, a driver has been assigned to your scheduled ride. "
                 "We'll email you again when they're on their way.")
        status_badge = _badge("Driver Confirmed", "#22c55e")
        lbl_driver = "Your driver"
        lbl_car = "Driver's vehicle"
        lbl_plate = "Plate"

    driver_rows = _row(lbl_driver, f"{driver_name}  {rating_str}".strip()) + _row(lbl_car, car_desc) + _row(lbl_plate, plate_str, last=True)
    driver_card = _h2(lbl_driver) + _info_card(driver_rows)

    body_html = (
        f'<div style="text-align:center;margin-bottom:20px;">{status_badge}</div>'
        + _h1(heading)
        + _p(intro)
        + driver_card
        + _sched_summary(pickup, dropoff, when, vehicle, booking_id, lang)
    )
    html = _shell(subject, preheader, body_html)

    loop = _asyncio_email.get_event_loop()
    try:
        sent = await loop.run_in_executor(None, lambda: _send_email_smtp(to, subject, html, skip_emailjs=True))
        return {"ok": bool(sent), "to": to}
    except Exception as e:
        logging.error("[email sched-driver] %s", e)
        raise HTTPException(500, "email send failed")


@router.post("/emails/web/sched-enroute")
async def email_sched_enroute(request: Request):
    """Send 'Driver on the way' email (scheduled rides only)."""
    _verify_web_origin(request)
    auth = request.headers.get("authorization", "")
    if not WEB_CHECKOUT_KEY or not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    if auth.split(" ", 1)[1] != WEB_CHECKOUT_KEY:
        raise HTTPException(401, "Invalid key")

    body = await request.json()
    to = (body.get("to_email") or "").strip()
    if not to:
        raise HTTPException(400, "Missing email")
    name = body.get("to_name") or "Guest"
    lang = (body.get("lang") or "en").lower()
    vehicle = body.get("vehicle") or "Cruise"
    pickup = body.get("pickup") or "—"
    driver_name = body.get("driver_name") or ("Tu conductor" if lang == "es" else "Your driver")
    booking_id = body.get("booking_id") or "—"
    tracking_url = body.get("live_tracking_url") or "https://cruiseinride.com/products/vip-service"

    if lang == "es":
        subject = f"Tu conductor está en camino — {booking_id}"
        preheader = f"{driver_name} va hacia tu punto de recogida ahora."
        heading = "Tu conductor está en camino"
        intro = (f"Hola {name}, <b style=\"color:#E8C547\">{driver_name}</b> está yendo a tu punto de recogida. "
                 "Por favor asegúrate de estar listo.")
        status_badge = _badge("● Live — On The Way", "#E8C547")
        cta_label = "Ver en vivo"
        lbl_pickup = "Recogida"
        lbl_vehicle = "Vehículo"
        lbl_booking = "Reserva"
    else:
        subject = f"Your driver is on the way — {booking_id}"
        preheader = f"{driver_name} is heading to your pickup now."
        heading = "Your driver is on the way"
        intro = (f"Hi {name}, <b style=\"color:#E8C547\">{driver_name}</b> is heading to your pickup. "
                 "Please be ready at your pickup location.")
        status_badge = _badge("● Live — On The Way", "#E8C547")
        cta_label = "Track live"
        lbl_pickup = "Pickup"
        lbl_vehicle = "Vehicle"
        lbl_booking = "Booking"

    cta_html = (
        f'<div style="text-align:center;margin:24px 0;">'
        f'<a href="{tracking_url}" style="display:inline-block;background:#E8C547;color:#0a0a0a;text-decoration:none;padding:14px 36px;border-radius:100px;font-weight:800;font-size:13px;letter-spacing:1.5px;text-transform:uppercase">{cta_label}</a>'
        '</div>'
    )

    info_rows = _row(lbl_pickup, pickup) + _row(lbl_vehicle, vehicle) + _row(lbl_booking, str(booking_id), last=True)

    body_html = (
        f'<div style="text-align:center;margin-bottom:20px;">{status_badge}</div>'
        + _h1(heading)
        + _p(intro)
        + cta_html
        + _info_card(info_rows)
    )
    html = _shell(subject, preheader, body_html)

    loop = _asyncio_email.get_event_loop()
    try:
        sent = await loop.run_in_executor(None, lambda: _send_email_smtp(to, subject, html, skip_emailjs=True))
        return {"ok": bool(sent), "to": to}
    except Exception as e:
        logging.error("[email sched-enroute] %s", e)
        raise HTTPException(500, "email send failed")


# ═══════════════════════════════════════════════════════════════════════
#  STRIPE TERMINAL - TAP TO PAY (NFC Contactless Payments)
# ═══════════════════════════════════════════════════════════════════════

from pydantic import BaseModel, Field

class ConnectionTokenResponse(BaseModel):
    secret: str

class CreatePaymentIntentRequest(BaseModel):
    amount: int = Field(..., gt=0, description="Amount in cents (e.g., 1000 = $10.00)")
    currency: str = Field(default="usd", pattern="^[a-z]{3}$")
    description: Optional[str] = Field(default="Cruise Ride Payment")

class CreatePaymentIntentResponse(BaseModel):
    id: str
    client_secret: str
    status: str
    amount: int
    currency: str

class CapturePaymentIntentRequest(BaseModel):
    payment_intent_id: str

class PaymentStatusResponse(BaseModel):
    id: str
    status: str
    amount: int
    currency: str
    charges: List[dict] = []


@router.post("/stripe/connection-token", response_model=ConnectionTokenResponse)
async def get_stripe_connection_token(
    user: User = Depends(_get_current_user),
):
    """Generate a ConnectionToken for Stripe Terminal SDK.
    
    The Terminal SDK uses this token to authenticate with Stripe's servers
    and establish a secure connection for processing in-person payments.
    Tokens are short-lived and should be generated fresh for each session.
    """
    if not _HAS_STRIPE:
        # Return mock token for testing without Stripe configured
        return ConnectionTokenResponse(secret="pst_mock_token_for_testing")
    
    try:
        # Create a ConnectionToken using Stripe's API
        token = _stripe_mod.terminal.ConnectionToken.create()
        return ConnectionTokenResponse(secret=token.secret)
    except Exception as e:
        logging.error("[stripe terminal] Failed to create connection token: %s", e)
        raise HTTPException(500, "Failed to initialize payment terminal")


@router.post("/stripe/create-payment-intent", response_model=CreatePaymentIntentResponse)
async def create_tap_to_pay_payment_intent(
    request: CreatePaymentIntentRequest,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Create a PaymentIntent for Tap to Pay (NFC card-present transaction).
    
    This creates a PaymentIntent configured for card-present payments using
    Stripe Terminal. The client_secret is used by the Terminal SDK to
    collect the payment method from the NFC card.
    """
    if not _HAS_STRIPE:
        # Return mock response for testing
        mock_id = f"pi_mock_{secrets.token_hex(12)}"
        return CreatePaymentIntentResponse(
            id=mock_id,
            client_secret=f"{mock_id}_secret_mock",
            status="requires_payment_method",
            amount=request.amount,
            currency=request.currency,
        )
    
    try:
        # Get or create Stripe customer
        customer_id = await _get_or_create_stripe_customer(user, db)
        
        # Create PaymentIntent for card-present payment
        intent = _stripe_mod.PaymentIntent.create(
            amount=request.amount,
            currency=request.currency,
            customer=customer_id,
            description=request.description,
            payment_method_types=["card_present"],
            capture_method="automatic",
            metadata={
                "user_id": str(user.id),
                "payment_type": "tap_to_pay",
                "integration_type": "terminal",
            },
        )
        
        return CreatePaymentIntentResponse(
            id=intent.id,
            client_secret=intent.client_secret,
            status=intent.status,
            amount=intent.amount,
            currency=intent.currency,
        )
        
    except Exception as e:
        logging.error("[stripe terminal] Failed to create payment intent: %s", e)
        raise HTTPException(500, "Failed to create payment")


@router.post("/stripe/capture-payment-intent")
async def capture_tap_to_pay_payment(
    request: CapturePaymentIntentRequest,
    user: User = Depends(_get_current_user),
):
    """Capture a PaymentIntent after card-present payment is confirmed.
    
    For automatic capture, this endpoint verifies the payment succeeded.
    For manual capture, this would capture the authorized funds.
    """
    if not _HAS_STRIPE:
        return {"status": "succeeded", "payment_intent_id": request.payment_intent_id}
    
    try:
        # Retrieve the PaymentIntent to check status
        intent = _stripe_mod.PaymentIntent.retrieve(request.payment_intent_id)
        
        # If not captured and requires capture, capture it
        if intent.status == "requires_capture":
            intent = _stripe_mod.PaymentIntent.capture(request.payment_intent_id)
        
        return {
            "status": intent.status,
            "payment_intent_id": intent.id,
            "amount": intent.amount,
            "currency": intent.currency,
            "charges": [
                {
                    "id": charge.id,
                    "status": charge.status,
                    "receipt_url": charge.receipt_url,
                }
                for charge in intent.charges.data
            ] if intent.charges else [],
        }
        
    except Exception as e:
        logging.error("[stripe terminal] Failed to capture payment: %s", e)
        raise HTTPException(500, "Failed to process payment")


@router.get("/stripe/payment-status/{payment_intent_id}", response_model=PaymentStatusResponse)
async def get_tap_to_pay_payment_status(
    payment_intent_id: str,
    user: User = Depends(_get_current_user),
):
    """Get the current status of a PaymentIntent.
    
    Used to verify payment status after Tap to Pay transaction.
    """
    if not _HAS_STRIPE:
        return PaymentStatusResponse(
            id=payment_intent_id,
            status="succeeded",
            amount=0,
            currency="usd",
        )
    
    try:
        intent = _stripe_mod.PaymentIntent.retrieve(payment_intent_id)
        
        return PaymentStatusResponse(
            id=intent.id,
            status=intent.status,
            amount=intent.amount,
            currency=intent.currency,
            charges=[
                {
                    "id": charge.id,
                    "status": charge.status,
                    "receipt_url": charge.receipt_url,
                    "payment_method_details": charge.payment_method_details.to_dict() if charge.payment_method_details else None,
                }
                for charge in intent.charges.data
            ] if intent.charges else [],
        )
        
    except Exception as e:
        logging.error("[stripe terminal] Failed to retrieve payment status: %s", e)
        raise HTTPException(500, "Failed to retrieve payment status")

