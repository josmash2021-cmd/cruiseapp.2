# ═══════════════════════════════════════════════════════
#  NEW FEATURES ENDPOINTS - To be added to main.py
# ═══════════════════════════════════════════════════════

# -------------------------------------------------------
#  STRIPE CONNECT - Driver Payouts
# -------------------------------------------------------

@app.post("/drivers/stripe-connect/onboard", dependencies=[Depends(_verify_api_key)])
async def stripe_connect_onboard(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Create Stripe Connect account for driver to receive payouts."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can onboard to Stripe Connect")
    
    if not _HAS_STRIPE:
        return {"account_link": "https://connect.stripe.com/mock", "mock": True}
    
    # Create or retrieve Stripe Connect account
    if user.stripe_connect_id:
        account_id = user.stripe_connect_id
    else:
        account = _stripe_mod.Account.create(
            type="express",
            country="US",
            email=user.email,
            capabilities={
                "card_payments": {"requested": True},
                "transfers": {"requested": True},
            },
            business_type="individual",
        )
        account_id = account.id
        user.stripe_connect_id = account_id
        await db.commit()
    
    # Create account link for onboarding
    account_link = _stripe_mod.AccountLink.create(
        account=account_id,
        refresh_url="cruiseapp://stripe-connect/refresh",
        return_url="cruiseapp://stripe-connect/complete",
        type="account_onboarding",
    )
    
    return {"account_link": account_link.url, "account_id": account_id}

@app.post("/drivers/payout/transfer", dependencies=[Depends(_verify_api_key)])
async def driver_payout_transfer(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Transfer driver's pending balance to their Stripe Connect account."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can request payouts")
    
    if not user.stripe_connect_id:
        raise HTTPException(400, "Driver must complete Stripe Connect onboarding first")
    
    if user.pending_balance <= 0:
        raise HTTPException(400, "No pending balance to transfer")
    
    if not _HAS_STRIPE:
        # Mock payout
        amount = user.pending_balance
        user.pending_balance = 0.0
        await db.commit()
        return {"amount": amount, "status": "paid", "mock": True}
    
    # Create Stripe transfer
    amount_cents = int(user.pending_balance * 100)
    transfer = _stripe_mod.Transfer.create(
        amount=amount_cents,
        currency="usd",
        destination=user.stripe_connect_id,
        description=f"Weekly payout for driver {user.id}",
    )
    
    # Update driver balance
    payout_amount = user.pending_balance
    user.pending_balance = 0.0
    await db.commit()
    
    return {
        "amount": payout_amount,
        "transfer_id": transfer.id,
        "status": "paid",
        "estimated_arrival": "2-3 business days"
    }

# -------------------------------------------------------
#  SURGE PRICING
# -------------------------------------------------------

@app.get("/surge/current", dependencies=[Depends(_verify_api_key)])
async def get_current_surge(lat: float = Query(...), lng: float = Query(...), db: AsyncSession = Depends(get_db)):
    """Get current surge multiplier for a location."""
    result = await db.execute(
        select(SurgeZone).where(SurgeZone.is_active == True)
    )
    zones = result.scalars().all()
    
    # Find nearest surge zone
    best_multiplier = 1.0
    for zone in zones:
        dist = _haversine(lat, lng, zone.center_lat, zone.center_lng)
        if dist <= zone.radius_km:
            best_multiplier = max(best_multiplier, zone.surge_multiplier)
    
    return {
        "surge_multiplier": best_multiplier,
        "is_surge": best_multiplier > 1.0,
        "message": f"{best_multiplier}x" if best_multiplier > 1.0 else "No surge"
    }

@app.post("/admin/surge/update", dependencies=[Depends(_require_dispatch_auth)])
async def update_surge_zone(
    zone_name: str = Body(...),
    center_lat: float = Body(...),
    center_lng: float = Body(...),
    surge_multiplier: float = Body(...),
    radius_km: float = Body(2.0),
    db: AsyncSession = Depends(get_db)
):
    """Admin: Update or create surge zone."""
    result = await db.execute(
        select(SurgeZone).where(SurgeZone.zone_name == zone_name)
    )
    zone = result.scalar_one_or_none()
    
    if zone:
        zone.surge_multiplier = surge_multiplier
        zone.center_lat = center_lat
        zone.center_lng = center_lng
        zone.radius_km = radius_km
        zone.updated_at = datetime.now(timezone.utc)
    else:
        zone = SurgeZone(
            zone_name=zone_name,
            center_lat=center_lat,
            center_lng=center_lng,
            surge_multiplier=surge_multiplier,
            radius_km=radius_km
        )
        db.add(zone)
    
    await db.commit()
    return {"status": "ok", "zone": zone_name, "multiplier": surge_multiplier}

# -------------------------------------------------------
#  CANCELLATION FEES
# -------------------------------------------------------

@app.post("/trips/{trip_id}/cancel", dependencies=[Depends(_verify_api_key)])
async def cancel_trip_with_fee(
    trip_id: int,
    reason: str = Body(...),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Cancel trip with automatic cancellation fee calculation."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    
    if not trip:
        raise HTTPException(404, "Trip not found")
    
    # Check authorization
    if user.id not in (trip.rider_id, trip.driver_id) and user.role != "admin":
        raise HTTPException(403, "Not authorized")
    
    # Calculate cancellation fee
    cancellation_fee = 0.0
    now = datetime.now(timezone.utc)
    
    if trip.status in ("driver_en_route", "arrived"):
        # Late cancellation - charge fee
        time_since_accept = (now - trip.created_at).total_seconds() / 60
        if time_since_accept > 2:  # More than 2 minutes after driver accepted
            cancellation_fee = 5.0  # $5 cancellation fee
    
    trip.status = "canceled"
    trip.cancel_reason = reason
    trip.cancellation_fee = cancellation_fee
    trip.updated_at = now
    
    await db.commit()
    
    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            firestore_sync.update_field("trips", trip.id, "status", "canceled")
            firestore_sync.update_field("trips", trip.id, "cancel_reason", reason)
        except Exception as e:
            logging.error("Firestore sync failed: %s", e)
    
    return {
        "status": "canceled",
        "cancellation_fee": cancellation_fee,
        "message": f"${cancellation_fee:.2f} cancellation fee applied" if cancellation_fee > 0 else "No fee"
    }

# -------------------------------------------------------
#  TIPPING
# -------------------------------------------------------

@app.post("/trips/{trip_id}/tip", dependencies=[Depends(_verify_api_key)])
async def add_tip(
    trip_id: int,
    tip_amount: float = Body(..., ge=0, le=100),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Add tip to completed trip."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    
    if not trip:
        raise HTTPException(404, "Trip not found")
    
    if trip.rider_id != user.id:
        raise HTTPException(403, "Only the rider can tip")
    
    if trip.status != "completed":
        raise HTTPException(400, "Can only tip completed trips")
    
    # Update trip tip
    trip.tip_amount = tip_amount
    
    # Add tip to driver's pending balance
    if trip.driver_id:
        driver_result = await db.execute(select(User).where(User.id == trip.driver_id))
        driver = driver_result.scalar_one_or_none()
        if driver:
            driver.pending_balance += tip_amount
            driver.total_earnings += tip_amount
    
    await db.commit()
    
    return {"status": "ok", "tip_amount": tip_amount, "message": "Tip added successfully"}

# -------------------------------------------------------
#  REFERRAL SYSTEM
# -------------------------------------------------------

@app.get("/referral/code", dependencies=[Depends(_verify_api_key)])
async def get_referral_code(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get user's referral code or generate one."""
    if not user.referral_code:
        # Generate unique referral code
        import string
        import random
        code = ''.join(random.choices(string.ascii_uppercase + string.digits, k=8))
        user.referral_code = code
        await db.commit()
    
    # Count successful referrals
    result = await db.execute(
        select(func.count(Referral.id)).where(
            Referral.referrer_id == user.id,
            Referral.status == "rewarded"
        )
    )
    successful_referrals = result.scalar() or 0
    
    return {
        "referral_code": user.referral_code,
        "successful_referrals": successful_referrals,
        "share_message": f"Join Cruise with my code {user.referral_code} and get $10 off your first ride!"
    }

@app.post("/referral/apply", dependencies=[Depends(_verify_api_key)])
async def apply_referral_code(
    referral_code: str = Body(...),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Apply referral code during signup."""
    if user.referred_by:
        raise HTTPException(400, "Referral code already applied")
    
    # Find referrer
    result = await db.execute(
        select(User).where(User.referral_code == referral_code)
    )
    referrer = result.scalar_one_or_none()
    
    if not referrer:
        raise HTTPException(404, "Invalid referral code")
    
    if referrer.id == user.id:
        raise HTTPException(400, "Cannot refer yourself")
    
    # Create referral record
    referral = Referral(
        referrer_id=referrer.id,
        referee_id=user.id,
        referral_code=referral_code,
        status="pending"
    )
    db.add(referral)
    user.referred_by = referrer.id
    
    await db.commit()
    
    return {
        "status": "ok",
        "message": "Referral code applied! Complete your first trip to unlock $10 credit."
    }

@app.post("/referral/complete/{referral_id}", dependencies=[Depends(_verify_api_key)])
async def complete_referral(referral_id: int, db: AsyncSession = Depends(get_db)):
    """Mark referral as completed when referee completes first trip."""
    result = await db.execute(select(Referral).where(Referral.id == referral_id))
    referral = result.scalar_one_or_none()
    
    if not referral or referral.status != "pending":
        return {"status": "already_processed"}
    
    # Award bonuses
    referral.status = "rewarded"
    referral.completed_at = datetime.now(timezone.utc)
    
    # Add bonus to referrer's account (could be credits or cash)
    referrer_result = await db.execute(select(User).where(User.id == referral.referrer_id))
    referrer = referrer_result.scalar_one_or_none()
    if referrer:
        referrer.pending_balance += referral.referrer_bonus
    
    await db.commit()
    
    return {
        "status": "rewarded",
        "referrer_bonus": referral.referrer_bonus,
        "referee_bonus": referral.referee_bonus
    }

# -------------------------------------------------------
#  FAVORITE LOCATIONS
# -------------------------------------------------------

@app.get("/favorites", dependencies=[Depends(_verify_api_key)])
async def get_favorite_locations(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get user's favorite locations."""
    result = await db.execute(
        select(FavoriteLocation).where(FavoriteLocation.user_id == user.id)
    )
    favorites = result.scalars().all()
    
    return [{
        "id": f.id,
        "label": f.label,
        "address": f.address,
        "lat": f.lat,
        "lng": f.lng,
        "icon": f.icon
    } for f in favorites]

@app.post("/favorites", dependencies=[Depends(_verify_api_key)])
async def add_favorite_location(
    label: str = Body(...),
    address: str = Body(...),
    lat: float = Body(...),
    lng: float = Body(...),
    icon: str = Body("star"),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Add a favorite location."""
    favorite = FavoriteLocation(
        user_id=user.id,
        label=label,
        address=address,
        lat=lat,
        lng=lng,
        icon=icon
    )
    db.add(favorite)
    await db.commit()
    await db.refresh(favorite)
    
    return {"id": favorite.id, "label": label, "status": "added"}

@app.delete("/favorites/{favorite_id}", dependencies=[Depends(_verify_api_key)])
async def delete_favorite_location(
    favorite_id: int,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Delete a favorite location."""
    result = await db.execute(
        select(FavoriteLocation).where(
            FavoriteLocation.id == favorite_id,
            FavoriteLocation.user_id == user.id
        )
    )
    favorite = result.scalar_one_or_none()
    
    if not favorite:
        raise HTTPException(404, "Favorite not found")
    
    await db.delete(favorite)
    await db.commit()
    
    return {"status": "deleted"}

# -------------------------------------------------------
#  WAIT TIME TRACKING & CHARGES
# -------------------------------------------------------

@app.post("/trips/{trip_id}/wait-time/start", dependencies=[Depends(_verify_api_key)])
async def start_wait_time(trip_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Driver starts wait time clock at pickup."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    
    if not trip or trip.driver_id != user.id:
        raise HTTPException(403, "Not authorized")
    
    if trip.status != "arrived":
        raise HTTPException(400, "Can only start wait time when arrived at pickup")
    
    # Store wait time start in trip notes
    trip.notes = (trip.notes or "") + f"\nWait started: {datetime.now(timezone.utc).isoformat()}"
    await db.commit()
    
    return {"status": "wait_time_started", "message": "Wait time clock started"}

@app.post("/trips/{trip_id}/wait-time/end", dependencies=[Depends(_verify_api_key)])
async def end_wait_time(trip_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Calculate and apply wait time charges."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    
    if not trip or trip.driver_id != user.id:
        raise HTTPException(403, "Not authorized")
    
    # Parse wait start time from notes
    if not trip.notes or "Wait started:" not in trip.notes:
        return {"wait_time_minutes": 0, "wait_time_charge": 0.0}
    
    wait_start_str = trip.notes.split("Wait started: ")[1].split("\n")[0]
    wait_start = datetime.fromisoformat(wait_start_str)
    wait_end = datetime.now(timezone.utc)
    wait_minutes = int((wait_end - wait_start).total_seconds() / 60)
    
    # Free wait time: 2 minutes, then $0.50/minute
    if wait_minutes > 2:
        billable_minutes = wait_minutes - 2
        wait_charge = billable_minutes * 0.50
    else:
        billable_minutes = 0
        wait_charge = 0.0
    
    trip.wait_time_minutes = wait_minutes
    trip.wait_time_charge = wait_charge
    trip.fare = (trip.fare or 0) + wait_charge
    
    await db.commit()
    
    return {
        "wait_time_minutes": wait_minutes,
        "billable_minutes": billable_minutes,
        "wait_time_charge": wait_charge,
        "new_total_fare": trip.fare
    }

# -------------------------------------------------------
#  DRIVER INCENTIVES & QUESTS
# -------------------------------------------------------

@app.get("/drivers/incentives", dependencies=[Depends(_verify_api_key)])
async def get_driver_incentives(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get driver's active incentives and quests."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can view incentives")
    
    result = await db.execute(
        select(DriverIncentive).where(
            DriverIncentive.driver_id == user.id,
            DriverIncentive.status.in_(["active", "completed"])
        ).order_by(DriverIncentive.created_at.desc())
    )
    incentives = result.scalars().all()
    
    return [{
        "id": i.id,
        "type": i.incentive_type,
        "title": i.title,
        "description": i.description,
        "progress": f"{i.current_trips}/{i.target_trips}",
        "bonus_amount": i.bonus_amount,
        "status": i.status,
        "expires_at": i.expires_at.isoformat() if i.expires_at else None
    } for i in incentives]

@app.post("/admin/incentives/create", dependencies=[Depends(_require_dispatch_auth)])
async def create_driver_incentive(
    driver_id: int = Body(...),
    incentive_type: str = Body(...),
    title: str = Body(...),
    target_trips: int = Body(...),
    bonus_amount: float = Body(...),
    expires_hours: int = Body(168),  # Default 7 days
    db: AsyncSession = Depends(get_db)
):
    """Admin: Create driver incentive/quest."""
    incentive = DriverIncentive(
        driver_id=driver_id,
        incentive_type=incentive_type,
        title=title,
        description=f"Complete {target_trips} trips to earn ${bonus_amount:.2f}",
        target_trips=target_trips,
        bonus_amount=bonus_amount,
        expires_at=datetime.now(timezone.utc) + timedelta(hours=expires_hours)
    )
    db.add(incentive)
    await db.commit()
    
    return {"status": "created", "incentive_id": incentive.id}

@app.post("/drivers/incentives/{incentive_id}/claim", dependencies=[Depends(_verify_api_key)])
async def claim_incentive_bonus(
    incentive_id: int,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Claim completed incentive bonus."""
    result = await db.execute(
        select(DriverIncentive).where(
            DriverIncentive.id == incentive_id,
            DriverIncentive.driver_id == user.id
        )
    )
    incentive = result.scalar_one_or_none()
    
    if not incentive:
        raise HTTPException(404, "Incentive not found")
    
    if incentive.status != "completed":
        raise HTTPException(400, "Incentive not yet completed")
    
    # Award bonus
    incentive.status = "claimed"
    user.pending_balance += incentive.bonus_amount
    user.total_earnings += incentive.bonus_amount
    
    await db.commit()
    
    return {
        "status": "claimed",
        "bonus_amount": incentive.bonus_amount,
        "new_balance": user.pending_balance
    }

# -------------------------------------------------------
#  GEOFENCING & SERVICE AREA VALIDATION
# -------------------------------------------------------

@app.get("/service-area/check", dependencies=[Depends(_verify_api_key)])
async def check_service_area(
    lat: float = Query(...),
    lng: float = Query(...),
    db: AsyncSession = Depends(get_db)
):
    """Check if location is within service area."""
    result = await db.execute(
        select(ServiceArea).where(ServiceArea.is_active == True)
    )
    areas = result.scalars().all()
    
    for area in areas:
        dist = _haversine(lat, lng, area.center_lat, area.center_lng)
        if dist <= area.radius_km:
            return {
                "in_service_area": True,
                "area_name": area.area_name,
                "message": "Location is within service area"
            }
    
    return {
        "in_service_area": False,
        "message": "Sorry, we don't service this area yet",
        "nearest_area": areas[0].area_name if areas else None
    }
