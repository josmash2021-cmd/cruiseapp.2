import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib, hmac
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, Vehicle, Document, DispatchOffer,
    Cashout, PayoutMethod, RiderPaymentMethod, Wallet, WalletTransaction,
    Rating, Referral, DriverIncentive,
)
from models.schemas import (
    DriverLocationIn, CashoutIn, PayoutMethodIn,
    RiderPaymentMethodIn, WalletTopUpIn, WalletWithdrawIn,
)
from utils.security import (
    _get_current_user, _verify_api_key, _security_audit_log,
)
from utils.helpers import (
    utc_now, utc_today_start, utc_days_ago, utc_month_start, utc_year_start,
    _haversine, _user_dict, _vehicle_dict, _doc_dict, _trip_dict,
)
from services.fcm_service import _send_fcm_push
from config import (
    PUBLIC_URL, STRIPE_SECRET, _HAS_STRIPE, _stripe_mod,
    CHECKR_API_KEY, CHECKR_BASE_URL,
    firestore_sync, _HAS_FIRESTORE,
    _nearby_cache, _NEARBY_CACHE_TTL,
)
from services.event_bus import event_bus

router = APIRouter()

PLATFORM_COMMISSION_RATE = 0.60
DRIVER_SHARE_RATE = 0.40


def _driver_trip_amounts(trip: Trip) -> tuple[float, float]:
    """Return (base_earnings_without_tip, total_earnings_with_tip)."""
    tip = float(trip.tip_amount or 0.0)
    if trip.driver_earnings is not None:
        total = round(float(trip.driver_earnings), 2)
        base = round(max(total - tip, 0.0), 2)
        return base, total
    base = round(float(trip.fare or 0.0) * DRIVER_SHARE_RATE, 2)
    return base, round(base + tip, 2)


def _driver_visible_trip_dict(trip: Trip) -> dict:
    data = _trip_dict(trip)
    base, total = _driver_trip_amounts(trip)
    data["fare"] = total
    data["driver_earnings"] = total
    if trip.platform_fee is None and trip.fare is not None:
        data["platform_fee"] = round(float(trip.fare or 0.0) * PLATFORM_COMMISSION_RATE, 2)
    data["driver_base_earnings"] = base
    return data

# ═══════════════════════════════════════════════════════
#  DRIVER  ENDPOINTS
# ═══════════════════════════════════════════════════════

# In-memory driver location store for ultra-fast reads (bypasses DB for location)
_driver_locations: dict = {}  # driver_id -> {"lat": float, "lng": float, "is_online": bool, "ts": float}

@router.patch("/drivers/{driver_id}/location", dependencies=[Depends(_verify_api_key)])
async def update_driver_location(driver_id: int, body: DriverLocationIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Ownership check: only the driver themselves can update their location
    if user.id != driver_id:
        raise HTTPException(403, "Not authorized to update this driver's location")

    # Update in-memory location cache FIRST (instant for nearby reads)
    _driver_locations[driver_id] = {
        "lat": body.lat, "lng": body.lng,
        "is_online": body.is_online, "ts": time.monotonic(),
    }

    # Update DB (lightweight — no SELECT needed, use the authenticated user object)
    user.lat = body.lat
    user.lng = body.lng
    user.is_online = body.is_online
    await db.commit()

    # Invalidate nearby cache cells near this driver's new position
    _stale = [k for k in _nearby_cache if abs(k[0] - round(body.lat, 3)) < 0.01 and abs(k[1] - round(body.lng, 3)) < 0.01]
    for k in _stale:
        _nearby_cache.pop(k, None)

    # Push driver location to riders watching active trips via SSE (sub-second)
    # Find active trip for this driver
    active_trip = await db.execute(
        select(Trip.id).where(
            and_(Trip.driver_id == driver_id, Trip.status.in_(["driver_en_route", "arrived", "in_progress"]))
        ).limit(1)
    )
    trip_row = active_trip.scalar_one_or_none()
    if trip_row:
        asyncio.create_task(event_bus.push_driver_location(trip_row, driver_id, body.lat, body.lng))

    # Sync driver location to Firestore (non-blocking)
    if _HAS_FIRESTORE:
        def _sync_fs():
            try:
                firestore_sync.sync_driver_location(driver_id, body.lat, body.lng, body.is_online)
            except Exception as e:
                logging.error("Firestore sync on driver location failed: %s", e)
        asyncio.get_event_loop().run_in_executor(None, _sync_fs)

    return {"status": "ok", "lat": body.lat, "lng": body.lng, "is_online": body.is_online}

@router.get("/drivers/nearby", dependencies=[Depends(_verify_api_key)])
async def get_nearby_drivers(
    lat: float = Query(...), lng: float = Query(...), radius_km: float = Query(15.0),
    user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db),
):
    # Cache key: round coordinates to ~100m grid for cache hits from same area
    _cache_key = (round(lat, 3), round(lng, 3), radius_km)
    _now = time.monotonic()
    _cached = _nearby_cache.get(_cache_key)
    if _cached and (_now - _cached[0]) < _NEARBY_CACHE_TTL:
        return _cached[1]

    # Bounding box pre-filter in SQL (~0.009° per km at equator)
    _lat_delta = radius_km / 111.0
    _lng_delta = radius_km / (111.0 * max(math.cos(math.radians(lat)), 0.01))

    result = await db.execute(
        select(User.id, User.lat, User.lng, User.first_name, User.last_name)
        .where(and_(
            User.role == "driver", User.is_online == True,
            User.lat.isnot(None), User.lng.isnot(None),
            User.lat >= lat - _lat_delta, User.lat <= lat + _lat_delta,
            User.lng >= lng - _lng_delta, User.lng <= lng + _lng_delta,
        ))
    )
    nearby = []
    for d_id, d_lat, d_lng, d_first, d_last in result.all():
        # Use in-memory location if fresher than DB
        mem = _driver_locations.get(d_id)
        if mem and mem["is_online"]:
            d_lat, d_lng = mem["lat"], mem["lng"]
        if _haversine(lat, lng, d_lat or 0, d_lng or 0) <= radius_km:
            nearby.append({"id": d_id, "lat": d_lat, "lng": d_lng, "name": f"{d_first} {d_last}"})

    response = {"count": len(nearby), "drivers": nearby}
    _nearby_cache[_cache_key] = (_now, response)
    return response

@router.get("/riders/{rider_id}/trips", dependencies=[Depends(_verify_api_key)])
async def get_rider_trips(rider_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Ownership check: riders can only see their own trips
    if user.id != rider_id and user.role != "admin":
        raise HTTPException(403, "Not authorized to view these trips")
    result = await db.execute(select(Trip).where(Trip.rider_id == rider_id).order_by(Trip.created_at.desc()).limit(100))
    return [_trip_dict(t) for t in result.scalars().all()]

@router.get("/drivers/{driver_id}/trips", dependencies=[Depends(_verify_api_key)])
async def get_driver_trips(driver_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Ownership check: drivers can only see their own trips
    if user.id != driver_id and user.role != "admin":
        raise HTTPException(403, "Not authorized to view these trips")
    result = await db.execute(select(Trip).where(Trip.driver_id == driver_id).order_by(Trip.created_at.desc()).limit(100))
    return [_driver_visible_trip_dict(t) for t in result.scalars().all()]

# ═══════════════════════════════════════════════════════
#  EARNINGS  ENDPOINTS
# ═══════════════════════════════════════════════════════

@router.get("/drivers/earnings", dependencies=[Depends(_verify_api_key)])
async def get_driver_earnings(period: str = Query("week"), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    now = utc_now()
    if period == "today":
        since = utc_today_start()
    elif period == "month":
        since = utc_days_ago(30)
    else:
        since = utc_days_ago(7)

    result = await db.execute(
        select(Trip).where(
            and_(Trip.driver_id == user.id, Trip.status == "completed", Trip.created_at >= since)
        ).order_by(Trip.created_at.desc())
    )
    trips = result.scalars().all()
    total = round(sum(_driver_trip_amounts(t)[0] for t in trips), 2)

    # Compute tips from ratings for these trips
    trip_ids = [t.id for t in trips]
    tips_total = 0.0
    if trip_ids:
        tips_r = await db.execute(
            select(func.coalesce(func.sum(Rating.tip_amount), 0.0)).where(
                Rating.trip_id.in_(trip_ids), Rating.to_user_id == user.id
            )
        )
        tips_total = float(tips_r.scalar() or 0)

    # Daily earnings breakdown (last 7 days)
    day_labels = []
    daily_earnings = []
    for i in range(6, -1, -1):
        day = (now - timedelta(days=i)).date()
        day_labels.append(day.strftime("%a"))
        day_total = sum(_driver_trip_amounts(t)[0] for t in trips if t.created_at and t.created_at.date() == day)
        daily_earnings.append(round(day_total, 2))

    # Recent transactions
    transactions = []
    for t in trips[:20]:
        base, _total = _driver_trip_amounts(t)
        transactions.append({
            "id": t.id,
            "pickup": t.pickup_address,
            "dropoff": t.dropoff_address,
            "fare": base,
            "date": t.created_at.isoformat() if t.created_at else None,
        })

    return {
        "total": total,
        "trips_count": len(trips),
        "online_hours": len(trips) * 0.5,
        "tips_total": round(tips_total, 2),
        "daily_earnings": daily_earnings,
        "day_labels": day_labels,
        "transactions": transactions,
    }

# ── Stripe Connect onboarding ──────────────────────────────────────────
@router.post("/drivers/stripe-connect", dependencies=[Depends(_verify_api_key)])
async def create_stripe_connect_link(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Create or resume a Stripe Connect Express onboarding link for a driver."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can set up Stripe payouts")
    if not STRIPE_SECRET:
        raise HTTPException(503, "Stripe not configured on this server")
    try:
        import stripe as _stripe
        _stripe.api_key = STRIPE_SECRET
        if not user.stripe_connect_id:
            account = _stripe.Account.create(
                type="express",
                email=user.email or "",
                capabilities={"transfers": {"requested": True}},
            )
            user.stripe_connect_id = account["id"]
            await db.commit()
        link = _stripe.AccountLink.create(
            account=user.stripe_connect_id,
            refresh_url=f"{PUBLIC_URL}/stripe-refresh",
            return_url=f"{PUBLIC_URL}/stripe-return",
            type="account_onboarding",
        )
        return {"url": link["url"], "stripe_account_id": user.stripe_connect_id}
    except Exception as e:
        logging.error("[StripeConnect] %s", e)
        raise HTTPException(500, f"Stripe error: {str(e)[:120]}")

@router.get("/drivers/stripe-connect/status", dependencies=[Depends(_verify_api_key)])
async def get_stripe_connect_status(
    user: User = Depends(_get_current_user),
):
    """Check if driver has completed Stripe Connect onboarding."""
    if not user.stripe_connect_id or not STRIPE_SECRET:
        return {"connected": False, "stripe_account_id": None}
    try:
        import stripe as _stripe
        _stripe.api_key = STRIPE_SECRET
        acct = _stripe.Account.retrieve(user.stripe_connect_id)
        return {
            "connected": acct.get("charges_enabled", False),
            "stripe_account_id": user.stripe_connect_id,
            "payouts_enabled": acct.get("payouts_enabled", False),
        }
    except Exception as e:
        return {"connected": False, "error": str(e)[:100]}

@router.post("/drivers/cashout", dependencies=[Depends(_verify_api_key)])
async def request_cashout(body: CashoutIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    if body.amount <= 0:
        raise HTTPException(400, "Cashout amount must be positive")
    # Calculate available balance from driver payout (not rider gross fare).
    completed_r = await db.execute(
        select(Trip).where(and_(Trip.driver_id == user.id, Trip.status == "completed"))
    )
    completed_trips = completed_r.scalars().all()
    total_earnings = round(sum(_driver_trip_amounts(t)[1] for t in completed_trips), 2)
    cashouts_r = await db.execute(
        select(func.coalesce(func.sum(Cashout.amount), 0.0)).where(Cashout.user_id == user.id)
    )
    total_cashouts = float(cashouts_r.scalar() or 0)
    available_balance = total_earnings - total_cashouts
    if body.amount > available_balance:
        raise HTTPException(400, f"Insufficient balance. Available: ${available_balance:.2f}")
    cashout = Cashout(user_id=user.id, amount=body.amount)
    db.add(cashout)
    await db.commit()
    await db.refresh(cashout)

    # ── Stripe Connect Transfer (real payout to driver's bank) ──
    transfer_id = None
    stripe_error = None
    if user.stripe_connect_id and STRIPE_SECRET:
        try:
            import stripe as _s
            _s.api_key = STRIPE_SECRET
            # Amount in cents; Stripe requires positive integer
            amount_cents = max(int(body.amount * 100), 50)
            transfer = _s.Transfer.create(
                amount=amount_cents,
                currency="usd",
                destination=user.stripe_connect_id,
                description=f"Cruise driver payout — cashout #{cashout.id}",
                metadata={"cashout_id": str(cashout.id), "driver_id": str(user.id)},
            )
            transfer_id = transfer["id"]
            cashout.status = "completed"
            # Deduct from pending_balance
            result2 = await db.execute(select(User).where(User.id == user.id))
            drv = result2.scalar_one_or_none()
            if drv:
                drv.pending_balance = round(max(0.0, (drv.pending_balance or 0.0) - body.amount), 2)
            await db.commit()
            await db.refresh(cashout)
            logging.info("[Cashout] Stripe Transfer %s created for driver %s — $%.2f", transfer_id, user.id, body.amount)
        except Exception as _se:
            stripe_error = str(_se)[:200]
            logging.error("[Cashout] Stripe Transfer failed for driver %s: %s", user.id, _se)

    return {
        "id": cashout.id,
        "amount": cashout.amount,
        "status": cashout.status,
        "transfer_id": transfer_id,
        "stripe_error": stripe_error,
    }

@router.get("/drivers/cashouts", dependencies=[Depends(_verify_api_key)])
async def get_cashouts(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Cashout).where(Cashout.user_id == user.id).order_by(Cashout.created_at.desc()))
    return [{"id": c.id, "amount": c.amount, "status": c.status, "created_at": c.created_at.isoformat()} for c in result.scalars().all()]

@router.get("/drivers/payouts/next-date", dependencies=[Depends(_verify_api_key)])
async def get_next_payout_date(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Return next scheduled auto-payout date (Tuesday 02:00 UTC) and driver's pending balance."""
    result = await db.execute(select(User).where(User.id == user.id))
    drv = result.scalar_one_or_none()
    pending = round(float(drv.pending_balance or 0.0), 2) if drv else 0.0
    next_date = _next_tuesday_2am()
    return {
        "next_payout_date": next_date.isoformat(),
        "pending_balance": pending,
        "stripe_connected": bool(drv and drv.stripe_connect_id),
    }

@router.get("/drivers/payout-methods", dependencies=[Depends(_verify_api_key)])
async def get_payout_methods(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(PayoutMethod).where(PayoutMethod.user_id == user.id))
    return [{"id": p.id, "method_type": p.method_type, "display_name": p.display_name, "is_default": p.is_default} for p in result.scalars().all()]

@router.post("/drivers/payout-methods", dependencies=[Depends(_verify_api_key)])
async def add_payout_method(body: PayoutMethodIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    pm = PayoutMethod(user_id=user.id, method_type=body.method_type, display_name=body.display_name, is_default=body.set_default)
    db.add(pm)
    await db.commit()
    await db.refresh(pm)
    return {"id": pm.id, "method_type": pm.method_type, "display_name": pm.display_name, "is_default": pm.is_default}

@router.delete("/drivers/payout-methods/{payout_id}", dependencies=[Depends(_verify_api_key)])
async def delete_payout_method(payout_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(PayoutMethod).where(PayoutMethod.id == payout_id, PayoutMethod.user_id == user.id))
    pm = result.scalar_one_or_none()
    if not pm:
        raise HTTPException(404, "Payout method not found")
    await db.delete(pm)
    await db.commit()
    return {"status": "deleted"}

# ═══════════════════════════════════════════════════════
#  PLAID  (stub)
# ═══════════════════════════════════════════════════════

@router.post("/plaid/create-link-token", dependencies=[Depends(_verify_api_key)])
async def create_plaid_link_token(user: User = Depends(_get_current_user)):
    return {"link_token": f"link-sandbox-{secrets.token_hex(16)}"}

@router.post("/plaid/exchange-token", dependencies=[Depends(_verify_api_key)])
async def exchange_plaid_token(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    body = await request.json()
    institution = body.get("institution_name", "Bank")
    mask = body.get("account_mask", "")
    subtype = body.get("account_subtype", "checking")
    display = f"{institution} {subtype.capitalize()} {'••••' + mask if mask else ''}".strip()
    pm = RiderPaymentMethod(user_id=user.id, method_type="bank_account", display_name=display)
    db.add(pm)
    await db.commit()
    return {"status": "ok", "account_id": body.get("account_id", "acct_stub")}

# ═══════════════════════════════════════════════════════
#  RIDER PAYMENT METHODS
# ═══════════════════════════════════════════════════════

@router.get("/riders/payment-methods", dependencies=[Depends(_verify_api_key)])
async def get_rider_payment_methods(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(RiderPaymentMethod).where(RiderPaymentMethod.user_id == user.id).order_by(RiderPaymentMethod.created_at)
    )
    return [{"id": p.id, "method_type": p.method_type, "display_name": p.display_name,
             "stripe_pm_id": p.stripe_pm_id, "is_default": p.is_default,
             "created_at": p.created_at.isoformat() if p.created_at else None}
            for p in result.scalars().all()]

@router.post("/riders/payment-methods", dependencies=[Depends(_verify_api_key)])
async def add_rider_payment_method(body: RiderPaymentMethodIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    if body.set_default:
        existing = await db.execute(select(RiderPaymentMethod).where(RiderPaymentMethod.user_id == user.id))
        for pm in existing.scalars().all():
            pm.is_default = False
    pm = RiderPaymentMethod(
        user_id=user.id,
        method_type=body.method_type,
        display_name=body.display_name,
        stripe_pm_id=body.stripe_pm_id,
        is_default=body.set_default,
    )
    db.add(pm)
    await db.commit()
    await db.refresh(pm)
    return {"id": pm.id, "method_type": pm.method_type, "display_name": pm.display_name,
            "stripe_pm_id": pm.stripe_pm_id, "is_default": pm.is_default}

@router.delete("/riders/payment-methods/{pm_id}", dependencies=[Depends(_verify_api_key)])
async def delete_rider_payment_method(pm_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(RiderPaymentMethod).where(RiderPaymentMethod.id == pm_id, RiderPaymentMethod.user_id == user.id))
    pm = result.scalar_one_or_none()
    if not pm:
        raise HTTPException(404, "Payment method not found")
    await db.delete(pm)
    await db.commit()
    return {"status": "deleted"}

@router.patch("/riders/payment-methods/{pm_id}/default", dependencies=[Depends(_verify_api_key)])
async def set_default_rider_payment_method(pm_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    existing = await db.execute(select(RiderPaymentMethod).where(RiderPaymentMethod.user_id == user.id))
    target = None
    for pm in existing.scalars().all():
        pm.is_default = (pm.id == pm_id)
        if pm.id == pm_id:
            target = pm
    if not target:
        raise HTTPException(404, "Payment method not found")
    await db.commit()
    return {"status": "ok"}

# ═══════════════════════════════════════════════════════
#  WALLET ENDPOINTS (Feature 12.1)
# ═══════════════════════════════════════════════════════

async def _get_or_create_wallet(user_id: int, db: AsyncSession) -> Wallet:
    """Get existing wallet or create a new one for the user."""
    result = await db.execute(select(Wallet).where(Wallet.user_id == user_id))
    wallet = result.scalar_one_or_none()
    if not wallet:
        wallet = Wallet(user_id=user_id, balance=0.0, currency="USD")
        db.add(wallet)
        await db.commit()
        await db.refresh(wallet)
    return wallet

@router.get("/wallet/balance", dependencies=[Depends(_verify_api_key)])
async def get_wallet_balance(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get user's wallet balance."""
    wallet = await _get_or_create_wallet(user.id, db)
    return {
        "id": wallet.id,
        "balance": wallet.balance,
        "currency": wallet.currency,
        "updated_at": wallet.updated_at.isoformat() if wallet.updated_at else None
    }

@router.get("/wallet/transactions", dependencies=[Depends(_verify_api_key)])
async def get_wallet_transactions(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
    limit: int = 50,
    offset: int = 0
):
    """Get user's wallet transactions (most recent first)."""
    wallet = await _get_or_create_wallet(user.id, db)
    result = await db.execute(
        select(WalletTransaction)
        .where(WalletTransaction.wallet_id == wallet.id)
        .order_by(WalletTransaction.created_at.desc())
        .limit(limit)
        .offset(offset)
    )
    transactions = result.scalars().all()
    return {
        "balance": wallet.balance,
        "currency": wallet.currency,
        "transactions": [
            {
                "id": t.id,
                "amount": t.amount,
                "type": t.type,
                "reference_id": t.reference_id,
                "description": t.description,
                "created_at": t.created_at.isoformat() if t.created_at else None
            }
            for t in transactions
        ]
    }

@router.post("/wallet/top-up", dependencies=[Depends(_verify_api_key)])
async def top_up_wallet(body: WalletTopUpIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Add funds to wallet via payment method."""
    if body.amount <= 0:
        raise HTTPException(400, "Amount must be positive")
    if body.amount > 1000:
        raise HTTPException(400, "Maximum top-up amount is $1000")
    
    wallet = await _get_or_create_wallet(user.id, db)
    
    # In production, process payment via Stripe here using body.payment_method_id
    # For now, we directly credit the wallet (simulated success)
    
    wallet.balance += body.amount
    wallet.updated_at = datetime.utcnow()
    
    # Record transaction
    txn = WalletTransaction(
        wallet_id=wallet.id,
        amount=body.amount,
        type="top-up",
        reference_id=body.payment_method_id or "manual",
        description=f"Added ${body.amount:.2f} to wallet"
    )
    db.add(txn)
    await db.commit()
    await db.refresh(wallet)
    await db.refresh(txn)
    
    return {
        "status": "success",
        "new_balance": wallet.balance,
        "transaction": {
            "id": txn.id,
            "amount": txn.amount,
            "type": txn.type,
            "created_at": txn.created_at.isoformat() if txn.created_at else None
        }
    }

@router.post("/wallet/pay-ride", dependencies=[Depends(_verify_api_key)])
async def pay_ride_with_wallet(trip_id: int, amount: float, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Deduct ride payment from wallet."""
    if amount <= 0:
        raise HTTPException(400, "Amount must be positive")
    
    wallet = await _get_or_create_wallet(user.id, db)
    
    if wallet.balance < amount:
        raise HTTPException(400, f"Insufficient balance. Available: ${wallet.balance:.2f}")
    
    wallet.balance -= amount
    wallet.updated_at = datetime.utcnow()
    
    # Record transaction
    txn = WalletTransaction(
        wallet_id=wallet.id,
        amount=-amount,  # Negative for debit
        type="ride-payment",
        reference_id=str(trip_id),
        description=f"Ride payment for trip #{trip_id}"
    )
    db.add(txn)
    await db.commit()
    await db.refresh(wallet)
    
    return {
        "status": "success",
        "new_balance": wallet.balance,
        "amount_paid": amount
    }

@router.post("/wallet/refund", dependencies=[Depends(_verify_api_key)])
async def refund_to_wallet(trip_id: int, amount: float, reason: str = "Ride refund", user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Refund amount to wallet (for cancelled rides, etc.)."""
    if amount <= 0:
        raise HTTPException(400, "Amount must be positive")
    
    wallet = await _get_or_create_wallet(user.id, db)
    
    wallet.balance += amount
    wallet.updated_at = datetime.utcnow()
    
    # Record transaction
    txn = WalletTransaction(
        wallet_id=wallet.id,
        amount=amount,
        type="refund",
        reference_id=str(trip_id),
        description=reason
    )
    db.add(txn)
    await db.commit()
    await db.refresh(wallet)
    
    return {
        "status": "success",
        "new_balance": wallet.balance,
        "amount_refunded": amount
    }

# ═══════════════════════════════════════════════════════
#  DISPATCH  ENDPOINTS
# ═══════════════════════════════════════════════════════

@router.get("/drivers/{driver_id}/stats", dependencies=[Depends(_verify_api_key)])
async def get_driver_stats(driver_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Compute real acceptance rate, on-time rate, etc. — 2 queries instead of 5."""
    from sqlalchemy import case as sql_case, literal_column

    # Single query: all offer counts via CASE
    offer_r = await db.execute(
        select(
            func.count(DispatchOffer.id).label("total"),
            func.sum(sql_case((DispatchOffer.status == "accepted", 1), else_=0)).label("accepted"),
            func.sum(sql_case((DispatchOffer.status == "rejected", 1), else_=0)).label("rejected"),
        ).where(DispatchOffer.driver_id == driver_id)
    )
    offer_row = offer_r.one()
    total_offers = offer_row.total or 0
    accepted = int(offer_row.accepted or 0)
    rejected = int(offer_row.rejected or 0)

    # Single query: trip counts + avg rating via subquery
    trip_r = await db.execute(
        select(
            func.count(Trip.id).label("total"),
            func.sum(sql_case((Trip.status == "completed", 1), else_=0)).label("completed"),
            func.sum(sql_case((Trip.status == "canceled", 1), else_=0)).label("canceled"),
        ).where(Trip.driver_id == driver_id)
    )
    trip_row = trip_r.one()
    total_trips = trip_row.total or 0
    completed = int(trip_row.completed or 0)
    canceled = int(trip_row.canceled or 0)

    # Average rating (lightweight index scan)
    ratings_r = await db.execute(
        select(func.avg(Rating.stars)).where(Rating.to_user_id == driver_id)
    )
    avg_rating = ratings_r.scalar()

    acceptance_rate = (accepted / total_offers * 100) if total_offers > 0 else 100.0
    on_time_rate = round(((completed / total_trips) * 100), 1) if total_trips > 0 else 100.0

    return {
        "total_offers": total_offers,
        "accepted_offers": accepted,
        "rejected_offers": rejected,
        "acceptance_rate": round(acceptance_rate, 1),
        "total_trips": total_trips,
        "completed_trips": completed,
        "canceled_trips": canceled,
        "on_time_rate": on_time_rate,
        "avg_rating": round(avg_rating, 2) if avg_rating else 5.0,
    }


# ═══════════════════════════════════════════════════════
#  VEHICLE  ENDPOINTS
# ═══════════════════════════════════════════════════════

@router.get("/drivers/vehicle", dependencies=[Depends(_verify_api_key)])
async def get_vehicle(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Vehicle).where(Vehicle.user_id == user.id))
    v = result.scalar_one_or_none()
    if not v:
        return {"vehicle": None}
    return {"vehicle": _vehicle_dict(v)}

@router.post("/drivers/vehicle", dependencies=[Depends(_verify_api_key)])
async def create_or_update_vehicle(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    body = await request.json()
    result = await db.execute(select(Vehicle).where(Vehicle.user_id == user.id))
    v = result.scalar_one_or_none()
    if v:
        for k in ("make", "model", "year", "color", "plate", "vin", "vehicle_type"):
            if k in body:
                setattr(v, k, body[k])
    else:
        v = Vehicle(
            user_id=user.id,
            make=body.get("make", ""),
            model=body.get("model", ""),
            year=body.get("year", 2020),
            color=body.get("color"),
            plate=body.get("plate", ""),
            vin=body.get("vin"),
            vehicle_type=body.get("vehicle_type", "comfort"),
        )
        db.add(v)
    await db.commit()
    await db.refresh(v)
    return {"vehicle": _vehicle_dict(v)}

# ═══════════════════════════════════════════════════════
#  DOCUMENT  ENDPOINTS
# ═══════════════════════════════════════════════════════

@router.get("/drivers/documents", dependencies=[Depends(_verify_api_key)])
async def get_documents(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(Document).where(Document.user_id == user.id).order_by(Document.created_at.desc())
    )
    docs = result.scalars().all()
    return [_doc_dict(d) for d in docs]

@router.post("/drivers/documents", dependencies=[Depends(_verify_api_key)])
async def upload_document(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    body = await request.json()
    doc_type = body.get("doc_type", "")
    _sanitize_string(doc_type)
    allowed_types = {"drivers_license", "insurance", "registration", "background_check", "vehicle_inspection", "profile_photo"}
    if doc_type not in allowed_types:
        raise HTTPException(400, f"Invalid document type. Allowed: {', '.join(allowed_types)}")
    # Save base64 photo if provided
    file_path = None
    photo_b64 = body.get("photo")
    if photo_b64:
        if not isinstance(photo_b64, str) or len(photo_b64) > 6 * 1024 * 1024:
            raise HTTPException(413, "Document image too large (max ~4.5MB)")
        import os as _os
        docs_dir = _os.path.join(_os.path.dirname(__file__), "uploads", "documents")
        _os.makedirs(docs_dir, exist_ok=True)
        try:
            decoded = base64.b64decode(photo_b64, validate=True)
        except Exception:
            raise HTTPException(400, "Invalid base64 data")
        if len(decoded) > 4 * 1024 * 1024:
            raise HTTPException(413, "Decoded document too large (max 4MB)")
        # Validate magic bytes
        if decoded[:2] == b'\xff\xd8':
            ext = "jpg"
        elif decoded[:8] == b'\x89PNG\r\n\x1a\n':
            ext = "png"
        elif decoded[:4] == b'%PDF':
            ext = "pdf"
        else:
            raise HTTPException(400, "Unsupported format (JPEG, PNG, PDF only)")
        fname = f"doc_{user.id}_{doc_type}_{int(time.time())}.{ext}"
        fpath = _os.path.join(docs_dir, fname)
        with open(fpath, "wb") as f:
            f.write(decoded)
        file_path = f"/uploads/documents/{fname}"

    # Check if doc of this type already exists � update it
    result = await db.execute(
        select(Document).where(and_(Document.user_id == user.id, Document.doc_type == doc_type))
    )
    existing = result.scalar_one_or_none()
    if existing:
        existing.status = "pending"
        existing.file_path = file_path or existing.file_path
        existing.doc_number = body.get("doc_number", existing.doc_number)
        if body.get("expiry_date"):
            existing.expiry_date = datetime.fromisoformat(body["expiry_date"])
        existing.rejection_reason = None
        existing.updated_at = datetime.utcnow()
        doc = existing
    else:
        doc = Document(
            user_id=user.id,
            doc_type=doc_type,
            status="pending",
            file_path=file_path,
            doc_number=body.get("doc_number"),
            expiry_date=datetime.fromisoformat(body["expiry_date"]) if body.get("expiry_date") else None,
        )
        db.add(doc)
    await db.commit()
    await db.refresh(doc)
    return _doc_dict(doc)

# ═══════════════════════════════════════════════════════
#  CHECKR  BACKGROUND  CHECK  ENDPOINTS
# ═══════════════════════════════════════════════════════

@router.post("/drivers/{driver_id}/background-check", dependencies=[Depends(_verify_api_key)])
async def initiate_background_check(
    driver_id: int,
    request: Request,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Start a Checkr background check for a driver."""
    if user.id != driver_id and user.role != "admin":
        raise HTTPException(403, "Not authorized")
    result = await db.execute(select(User).where(User.id == driver_id))
    driver = result.scalar_one_or_none()
    if not driver:
        raise HTTPException(404, "Driver not found")
    if driver.role != "driver":
        raise HTTPException(400, "User is not a driver")
    if driver.background_check_status in ("pending", "processing", "clear"):
        return {"status": driver.background_check_status, "message": "Background check already initiated"}

    body = await request.json()
    email = driver.email
    first_name = body.get("first_name", driver.name or "")
    last_name = body.get("last_name", "")
    dob = body.get("dob")  # YYYY-MM-DD
    ssn_last4 = body.get("ssn_last4")
    license_number = body.get("license_number")
    license_state = body.get("license_state")

    if not dob:
        raise HTTPException(400, "Date of birth is required")

    from services.checkr_service import checkr
    # Create candidate
    candidate = await checkr.create_candidate(
        email=email,
        first_name=first_name,
        last_name=last_name,
        dob=dob,
    )
    if not candidate:
        raise HTTPException(502, "Failed to create Checkr candidate")

    candidate_id = candidate.get("id")
    driver.checkr_candidate_id = candidate_id

    # Create invitation (triggers the background check)
    invitation = await checkr.create_invitation(candidate_id=candidate_id)
    if not invitation:
        raise HTTPException(502, "Failed to create Checkr invitation")

    driver.background_check_status = "pending"
    await db.commit()
    await db.refresh(driver)

    return {
        "status": "pending",
        "candidate_id": candidate_id,
        "invitation_url": invitation.get("invitation_url"),
        "message": "Background check initiated",
    }


@router.get("/drivers/{driver_id}/background-check/status", dependencies=[Depends(_verify_api_key)])
async def get_background_check_status(
    driver_id: int,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get the current background check status for a driver."""
    if user.id != driver_id and user.role != "admin":
        raise HTTPException(403, "Not authorized")
    result = await db.execute(select(User).where(User.id == driver_id))
    driver = result.scalar_one_or_none()
    if not driver:
        raise HTTPException(404, "Driver not found")
    return {
        "status": driver.background_check_status or "none",
        "completed_at": driver.background_check_completed_at.isoformat() if driver.background_check_completed_at else None,
        "candidate_id": driver.checkr_candidate_id,
        "report_id": driver.checkr_report_id,
    }


# Convenience routes (use current user's ID)
@router.post("/drivers/background-check", dependencies=[Depends(_verify_api_key)])
async def initiate_background_check_self(
    request: Request,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Convenience: initiate background check for the current user."""
    return await initiate_background_check(user.id, request, user, db)


@router.get("/drivers/background-check/status", dependencies=[Depends(_verify_api_key)])
async def get_background_check_status_self(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Convenience: get background check status for the current user."""
    return await get_background_check_status(user.id, user, db)


@router.post("/webhooks/checkr")
async def checkr_webhook(request: Request, db: AsyncSession = Depends(get_db)):
    """Handle Checkr webhook events (report.completed, invitation.completed, etc.)."""
    body_bytes = await request.body()
    signature = request.headers.get("x-checkr-signature", "")
    webhook_secret = os.environ.get("CHECKR_WEBHOOK_SECRET", "")
    if webhook_secret:
        expected = hmac.new(
            webhook_secret.encode(), body_bytes, hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(signature, expected):
            _security_audit_log("CHECKR_WEBHOOK_INVALID_SIG", "checkr", "signature mismatch")
            raise HTTPException(401, "Invalid signature")

    try:
        payload = json.loads(body_bytes)
    except Exception:
        raise HTTPException(400, "Invalid JSON")

    event_type = payload.get("type", "")
    data = payload.get("data", {}).get("object", {})
    candidate_id = data.get("candidate_id") or data.get("id")

    if not candidate_id:
        return {"ok": True, "message": "No candidate_id, skipped"}

    # Find driver by checkr_candidate_id
    result = await db.execute(select(User).where(User.checkr_candidate_id == candidate_id))
    driver = result.scalar_one_or_none()
    if not driver:
        logging.warning(f"Checkr webhook: no driver for candidate {candidate_id}")
        return {"ok": True, "message": "Driver not found, skipped"}

    if event_type == "report.completed":
        report_id = data.get("id")
        status = data.get("status", "")  # clear, consider
        driver.checkr_report_id = report_id
        driver.background_check_completed_at = datetime.utcnow()
        if status == "clear":
            driver.background_check_status = "clear"
            driver.verification_status = "approved"
        elif status == "consider":
            driver.background_check_status = "consider"
        else:
            driver.background_check_status = status
        await db.commit()
        logging.info(f"Checkr report.completed: driver={driver.id} status={status}")

    elif event_type == "invitation.completed":
        driver.background_check_status = "processing"
        await db.commit()
        logging.info(f"Checkr invitation.completed: driver={driver.id}")

    elif event_type == "report.upgraded":
        report_id = data.get("id")
        status = data.get("status", "")
        driver.checkr_report_id = report_id
        if status == "clear":
            driver.background_check_status = "clear"
            driver.verification_status = "approved"
        elif status == "consider":
            driver.background_check_status = "consider"
        driver.background_check_completed_at = datetime.utcnow()
        await db.commit()
        logging.info(f"Checkr report.upgraded: driver={driver.id} status={status}")

    return {"ok": True}

# ═══════════════════════════════════════════════════════
#  STRIPE CONNECT - Driver Payouts
# ═══════════════════════════════════════════════════════

@router.post("/drivers/stripe-connect/onboard", dependencies=[Depends(_verify_api_key)])
async def stripe_connect_onboard(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Create Stripe Connect account for driver to receive payouts."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can onboard to Stripe Connect")
    
    if not _HAS_STRIPE:
        return {"account_link": "https://connect.stripe.com/mock", "mock": True}
    
    if user.stripe_connect_id:
        account_id = user.stripe_connect_id
    else:
        account = _stripe_mod.Account.create(
            type="express",
            country="US",
            email=user.email,
            capabilities={"card_payments": {"requested": True}, "transfers": {"requested": True}},
            business_type="individual",
        )
        account_id = account.id
        user.stripe_connect_id = account_id
        await db.commit()
    
    account_link = _stripe_mod.AccountLink.create(
        account=account_id,
        refresh_url="cruiseapp://stripe-connect/refresh",
        return_url="cruiseapp://stripe-connect/complete",
        type="account_onboarding",
    )
    return {"account_link": account_link.url, "account_id": account_id}

@router.post("/drivers/payout/transfer", dependencies=[Depends(_verify_api_key)])
async def driver_payout_transfer(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Transfer driver's pending balance to their Stripe Connect account."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can request payouts")
    if not user.stripe_connect_id:
        raise HTTPException(400, "Driver must complete Stripe Connect onboarding first")
    if user.pending_balance <= 0:
        raise HTTPException(400, "No pending balance to transfer")
    
    if not _HAS_STRIPE:
        amount = user.pending_balance
        user.pending_balance = 0.0
        await db.commit()
        return {"amount": amount, "status": "paid", "mock": True}
    
    amount_cents = int(user.pending_balance * 100)
    transfer = _stripe_mod.Transfer.create(
        amount=amount_cents, currency="usd", destination=user.stripe_connect_id,
        description=f"Weekly payout for driver {user.id}",
    )
    payout_amount = user.pending_balance
    user.pending_balance = 0.0
    await db.commit()
    return {"amount": payout_amount, "transfer_id": transfer.id, "status": "paid", "estimated_arrival": "2-3 business days"}

# ═══════════════════════════════════════════════════════
#  DRIVER INCENTIVES & QUESTS
# ═══════════════════════════════════════════════════════

@router.get("/drivers/incentives", dependencies=[Depends(_verify_api_key)])
async def get_driver_incentives(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get driver's active incentives and quests."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can view incentives")
    result = await db.execute(select(DriverIncentive).where(DriverIncentive.driver_id == user.id, DriverIncentive.status.in_(["active", "completed"])).order_by(DriverIncentive.created_at.desc()))
    incentives = result.scalars().all()
    return [{"id": i.id, "type": i.incentive_type, "title": i.title, "description": i.description, "progress": f"{i.current_trips}/{i.target_trips}", "bonus_amount": i.bonus_amount, "status": i.status, "expires_at": i.expires_at.isoformat() if i.expires_at else None} for i in incentives]

@router.post("/drivers/incentives/{incentive_id}/claim", dependencies=[Depends(_verify_api_key)])
async def claim_incentive_bonus(incentive_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Claim completed incentive bonus."""
    result = await db.execute(select(DriverIncentive).where(DriverIncentive.id == incentive_id, DriverIncentive.driver_id == user.id))
    incentive = result.scalar_one_or_none()
    if not incentive:
        raise HTTPException(404, "Incentive not found")
    if incentive.status != "completed":
        raise HTTPException(400, "Incentive not yet completed")
    incentive.status = "claimed"
    user.pending_balance += incentive.bonus_amount
    user.total_earnings += incentive.bonus_amount
    await db.commit()
    return {"status": "claimed", "bonus_amount": incentive.bonus_amount, "new_balance": user.pending_balance}

@router.get("/drivers/demand-heatmap", dependencies=[Depends(_verify_api_key)])
async def get_driver_demand_heatmap(
    lat: float = Query(...),
    lng: float = Query(...),
    radius_km: float = Query(10.0),
    db: AsyncSession = Depends(get_db),
):
    """Get demand heatmap for drivers showing high-demand pickup areas nearby."""
    since = datetime.utcnow() - timedelta(minutes=30)
    result = await db.execute(
        select(Trip.pickup_lat, Trip.pickup_lng, func.count(Trip.id).label("cnt"))
        .where(Trip.status.in_(["requested", "driver_en_route"]), Trip.created_at >= since)
        .group_by(Trip.pickup_lat, Trip.pickup_lng)
    )
    points = []
    for row in result.all():
        p_lat, p_lng, cnt = row
        if p_lat and p_lng and _haversine(lat, lng, p_lat, p_lng) <= radius_km:
            points.append({"lat": p_lat, "lng": p_lng, "weight": cnt})

    # Also include active surge zones
    surge_r = await db.execute(select(SurgeZone).where(SurgeZone.is_active == True, SurgeZone.surge_multiplier > 1.0))
    surge_zones = [
        {"lat": z.center_lat, "lng": z.center_lng, "radius_km": z.radius_km, "multiplier": z.surge_multiplier, "name": z.zone_name}
        for z in surge_r.scalars().all()
        if _haversine(lat, lng, z.center_lat, z.center_lng) <= radius_km + z.radius_km
    ]

    return {"demand_points": points, "surge_zones": surge_zones}

# ═══════════════════════════════════════════════════════
#  BACKGROUND CHECK (CHECKR INTEGRATION)
# ═══════════════════════════════════════════════════════

CHECKR_API_KEY = os.getenv("CHECKR_API_KEY", "")
CHECKR_BASE_URL = os.getenv("CHECKR_BASE_URL", "https://api.checkr.com/v1")

@router.post("/drivers/background-check", dependencies=[Depends(_verify_api_key)])
async def initiate_background_check(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Initiate a background check via Checkr for a driver."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can request background checks")

    if not CHECKR_API_KEY:
        # Mock response when Checkr not configured
        logging.info("[BGCheck] Mock background check for driver %s", user.id)
        return {
            "status": "pending",
            "provider": "checkr",
            "mock": True,
            "message": "Background check initiated (demo mode). Configure CHECKR_API_KEY for production.",
        }

    try:
        auth = base64.b64encode(f"{CHECKR_API_KEY}:".encode()).decode()
        async with httpx.AsyncClient() as client:
            # Create candidate
            candidate_resp = await client.post(
                f"{CHECKR_BASE_URL}/candidates",
                headers={"Authorization": f"Basic {auth}"},
                json={
                    "first_name": user.first_name,
                    "last_name": user.last_name,
                    "email": user.email,
                    "phone": user.phone,
                    "ssn": user.ssn or "",
                },
                timeout=15,
            )
            if candidate_resp.status_code not in (200, 201):
                raise HTTPException(502, f"Checkr candidate creation failed: {candidate_resp.text}")
            candidate = candidate_resp.json()

            # Create invitation (triggers background check)
            invite_resp = await client.post(
                f"{CHECKR_BASE_URL}/invitations",
                headers={"Authorization": f"Basic {auth}"},
                json={
                    "candidate_id": candidate["id"],
                    "package": "driver_pro",  # Standard rideshare package
                },
                timeout=15,
            )
            if invite_resp.status_code not in (200, 201):
                raise HTTPException(502, f"Checkr invitation failed: {invite_resp.text}")
            invitation = invite_resp.json()

        logging.info("[BGCheck] Checkr check initiated for driver %s, candidate %s",
                     user.id, candidate["id"])
        return {
            "status": "pending",
            "provider": "checkr",
            "candidate_id": candidate["id"],
            "invitation_url": invitation.get("invitation_url"),
        }
    except HTTPException:
        raise
    except Exception as e:
        logging.error("[BGCheck] Checkr error for driver %s: %s", user.id, e)
        raise HTTPException(502, f"Background check service error: {str(e)}")


@router.post("/drivers/background-check/webhook")
async def checkr_webhook(request: Request, db: AsyncSession = Depends(get_db)):
    """Handle Checkr webhook events for background check completion."""
    payload = await request.json()
    event_type = payload.get("type", "")
    data = payload.get("data", {}).get("object", {})

    logging.info("[BGCheck Webhook] Received: %s", event_type)

    if event_type in ("report.completed", "report.upgraded"):
        candidate_id = data.get("candidate_id", "")
        status = data.get("status", "")  # clear, consider, suspended
        result = data.get("result", "")

        # Map Checkr status to our verification
        if result == "clear" or status == "clear":
            ver_status = "approved"
        elif result in ("consider",) or status in ("consider",):
            ver_status = "pending"  # Manual review needed
        else:
            ver_status = "rejected"

        # Find user by email from candidate
        email = data.get("email")
        if email:
            user_r = await db.execute(
                select(User).where(User.email == email, User.role == "driver")
            )
            user = user_r.scalar_one_or_none()
            if user:
                user.verification_status = ver_status
                if ver_status == "approved":
                    user.is_verified = True
                    user.verified_at = datetime.utcnow()
                elif ver_status == "rejected":
                    user.verification_reason = f"Background check: {result}"
                await db.commit()
                logging.info("[BGCheck] Driver %s verification updated to %s", user.id, ver_status)

    return {"status": "ok"}


