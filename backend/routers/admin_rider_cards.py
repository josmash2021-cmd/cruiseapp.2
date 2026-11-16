"""Dispatch adds a card to a rider (owner 2026-11-15, drawing
https://claude.ai/artifact/9ajBYu169bo3u3ovcTSf3u).

A rider whose phone cannot save a card gives it to an operator by PHONE —
never by chat, which is stored. The panel mounts Stripe's own card field
(Stripe.js): the number goes straight from the operator's browser to
Stripe, never through this server.

  POST /admin/users/{id}/card-setup    → a SetupIntent on the rider's
                                         customer + the publishable key
  POST /admin/users/{id}/card-confirm  → after the browser confirmed it:
                                         files the card for the rider

The card then shows in the rider's app (the ride page restores it from
/users/me/payment-methods) and is charged off-session like any saved card.
The rider's consent is required and every add is in the audit log.
"""
from __future__ import annotations

import logging
import os
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from config import _HAS_STRIPE, _stripe_mod
from models.database import RiderPaymentMethod, User, get_db
from services.payment_security import stripe_call, stripe_value
from utils.security import _require_dispatch_auth, _security_audit_log

router = APIRouter()

# Public by design: the same key the rider app (lib/config/env.dart) and
# cruiseinride.com embed. Same Stripe account as STRIPE_SECRET_KEY
# (acct_1T8W4JIO4JMEXI8b, verified 2026-11-15).
_DEFAULT_PUBLISHABLE_KEY = (
    "pk_live_51T8W4JIO4JMEXI8bqM5p5Q16jeIRiaiOmp1zgAiISQFx0v67Sl2HvGAOdNRC00J"
    "fCqwgF6T2VD9J6bjXjucmA3SG00Rwg6MHdk"
)
_CARD_FAMILY = ("stripe_card", "apple_pay", "google_pay")


def publishable_key() -> str:
    return (os.getenv("STRIPE_PUBLISHABLE_KEY") or _DEFAULT_PUBLISHABLE_KEY).strip()


class CardConfirmIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    setup_intent_id: str = Field(min_length=6, max_length=100, pattern=r"^seti_[A-Za-z0-9_]+$")
    set_default: bool = True
    # The operator ticks "the rider authorized it by phone". Without it no card.
    consent: bool = False


async def _load_rider(db: AsyncSession, user_id: int) -> User:
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if user is None or user.role != "rider":
        raise HTTPException(404, "Rider not found")
    return user


def _display_name(brand: Optional[str], last4: Optional[str]) -> str:
    # Same shape the app writes ("Visa ending in 4242"): it reads the brand
    # from the first word and the last4 from the end.
    b = (brand or "card").replace("_", " ").strip() or "card"
    b = b[0].upper() + b[1:]
    return f"{b} ending in {last4 or '????'}"


@router.post("/admin/users/{user_id}/card-setup",
             dependencies=[Depends(_require_dispatch_auth)])
async def admin_card_setup(user_id: int, db: AsyncSession = Depends(get_db)):
    if not _HAS_STRIPE:
        raise HTTPException(503, "Stripe is not configured")
    rider = await _load_rider(db, user_id)
    from routers.payments import _get_or_create_stripe_customer
    customer_id = await _get_or_create_stripe_customer(rider, db)
    if not customer_id:
        raise HTTPException(503, "Could not open the rider's Stripe customer")
    try:
        intent = await stripe_call(
            _stripe_mod.SetupIntent.create,
            customer=customer_id,
            payment_method_types=["card"],
            usage="off_session",
            metadata={"rider_id": str(rider.id), "added_by": "dispatch"},
        )
    except _stripe_mod.error.StripeError as exc:
        logging.warning("[AdminCard] setup intent failed for rider %s: %s", rider.id, exc)
        raise HTTPException(502, "Stripe did not open the card form. Try again.") from None
    return {
        "client_secret": stripe_value(intent, "client_secret"),
        "setup_intent_id": stripe_value(intent, "id"),
        "publishable_key": publishable_key(),
    }


@router.post("/admin/users/{user_id}/card-confirm",
             dependencies=[Depends(_require_dispatch_auth)])
async def admin_card_confirm(user_id: int, body: CardConfirmIn,
                             db: AsyncSession = Depends(get_db)):
    if not body.consent:
        raise HTTPException(400, "The rider has to authorize saving the card.")
    if not _HAS_STRIPE:
        raise HTTPException(503, "Stripe is not configured")
    rider = await _load_rider(db, user_id)
    try:
        intent = await stripe_call(
            _stripe_mod.SetupIntent.retrieve, body.setup_intent_id,
            expand=["payment_method"])
    except _stripe_mod.error.StripeError:
        raise HTTPException(404, "Setup not found") from None

    metadata = stripe_value(intent, "metadata") or {}
    owner = stripe_value(metadata, "rider_id")
    customer = stripe_value(intent, "customer")
    if owner != str(rider.id) or not customer or customer != rider.stripe_customer_id:
        raise HTTPException(403, "This card setup belongs to another account")
    if stripe_value(intent, "status") != "succeeded":
        raise HTTPException(409, "Stripe has not confirmed the card yet")
    pm = stripe_value(intent, "payment_method")
    pm_id = pm if isinstance(pm, str) else stripe_value(pm, "id")
    if not pm_id:
        raise HTTPException(409, "The setup carries no card")
    card = None if isinstance(pm, str) else stripe_value(pm, "card")
    brand = stripe_value(card, "brand") if card is not None else None
    last4 = stripe_value(card, "last4") if card is not None else None

    existing = (await db.execute(select(RiderPaymentMethod).where(
        RiderPaymentMethod.user_id == rider.id,
        RiderPaymentMethod.stripe_pm_id == pm_id,
    ))).scalar_one_or_none()
    if body.set_default:
        await db.execute(
            text("UPDATE rider_payment_methods SET is_default = FALSE WHERE user_id = :uid"),
            {"uid": rider.id})
    if existing is None:
        existing = RiderPaymentMethod(
            user_id=rider.id, method_type="stripe_card",
            display_name=_display_name(brand, last4),
            stripe_pm_id=pm_id, is_default=body.set_default)
        db.add(existing)
    elif body.set_default:
        existing.is_default = True
    await db.commit()
    await db.refresh(existing)

    if body.set_default:
        try:
            await stripe_call(
                _stripe_mod.Customer.modify, customer,
                invoice_settings={"default_payment_method": pm_id})
        except _stripe_mod.error.StripeError as exc:
            # Cosmetic in Stripe's dashboard; our own default is the row.
            logging.warning("[AdminCard] customer default not set for %s: %s", rider.id, exc)

    _security_audit_log(
        "ADMIN_RIDER_CARD_ADDED", "admin",
        f"rider_id={rider.id} brand={brand or '?'} last4={last4 or '?'} "
        f"default={body.set_default} consent=phone")
    return {
        "method_id": existing.id,
        "display_name": existing.display_name,
        "is_default": bool(existing.is_default),
    }


async def make_default_for_trip(db: AsyncSession, rider_id: int, method_id: int) -> None:
    """The card dispatch picked for a trip becomes the rider's default.

    A reservation is charged later, off-session, against the DEFAULT card
    (the scheduled dispatcher's hold, the charge at completion): picking a
    card means making it the default, so every later charge finds it.
    """
    row = (await db.execute(select(RiderPaymentMethod).where(
        RiderPaymentMethod.id == method_id,
        RiderPaymentMethod.user_id == rider_id,
        RiderPaymentMethod.method_type.in_(_CARD_FAMILY),
        RiderPaymentMethod.stripe_pm_id.isnot(None),
    ))).scalar_one_or_none()
    if row is None:
        raise HTTPException(400, "That card is not one of the rider's saved cards.")
    if row.is_default:
        return
    await db.execute(
        text("UPDATE rider_payment_methods SET is_default = FALSE WHERE user_id = :uid"),
        {"uid": rider_id})
    row.is_default = True
    await db.flush()
