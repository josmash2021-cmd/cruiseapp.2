"""The panel's pulse (owner 2026-11-16, approved drawing
https://claude.ai/artifact/MSML67sC6y5MHc4kNF2rxQ): the menu's live counts
and the only two notices the panel shows.

  GET /admin/panel/pulse  → asked every 10 s with the tab visible, every
                            20 s hidden (the tab title still counts)

Only two things ever notify, because someone must act now:
  · support: people waiting for a PERSON (the Soporte inbox's rule)
  · unassigned: a ride nobody accepted for 2 min, or a reservation with no
    driver 2 h or less before its pickup
Everything else is a number: reservations with no driver (24 h), drivers
online / without signal, payouts that failed. Read-only and cheap: no
ETAs, no geocoding.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Body, Depends, HTTPException
from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import Cashout, Trip, User, get_db
from routers.admin_home import (_PAYOUT_WINDOW, _STALE_DRIVER_S, _aware, _iso, _place)
from routers.admin_support_inbox import waiting_chats
from utils.helpers import ACTIVE_ACCOUNT_STATUSES, is_real_reservation
from utils.security import _require_dispatch_auth

router = APIRouter()

UNASSIGNED_AFTER = timedelta(minutes=2)   # a ride for now, nobody accepted
RESERVATION_URGENT = timedelta(hours=2)   # a reservation with no driver this close
_SEARCH_WINDOW = timedelta(hours=12)
_RESERVE_AHEAD = timedelta(hours=24)
_RESERVE_BEHIND = timedelta(hours=3)
_FUTURE_RESERVATION = timedelta(minutes=60)


@router.get("/admin/panel/pulse", dependencies=[Depends(_require_dispatch_auth)])
async def panel_pulse(db: AsyncSession = Depends(get_db)):
    return await pulse_snapshot(db)


async def pulse_snapshot(db: AsyncSession) -> dict:
    """The counts — shared by the panel's poll and the phone pushes
    (services/panel_push.py), so both always say the same thing."""
    now = datetime.now(timezone.utc)

    support = await waiting_chats(db)

    trips = (await db.execute(select(Trip).where(or_(
        and_(Trip.status == "requested",
             or_(Trip.created_at >= now - _SEARCH_WINDOW,
                 and_(Trip.scheduled_at >= now - _RESERVE_BEHIND,
                      Trip.scheduled_at <= now + _RESERVE_AHEAD))),
        and_(Trip.status == "scheduled", Trip.driver_id.is_(None),
             Trip.scheduled_at >= now - _RESERVE_BEHIND,
             Trip.scheduled_at <= now + _RESERVE_AHEAD),
    )))).scalars().all()

    urgent: list[dict] = []
    reservations_open = 0
    for t in trips:
        sched = _aware(t.scheduled_at)
        reservation = sched is not None and is_real_reservation(t) and (
            t.status == "scheduled" or sched > now + _FUTURE_RESERVATION)
        if reservation:
            reservations_open += 1
            if sched - now <= RESERVATION_URGENT:
                urgent.append({"trip_id": t.id, "reservation": True,
                               "since": _iso(sched - RESERVATION_URGENT),
                               "pickup_at": _iso(sched),
                               "label": f"{_place(t.pickup_address, t)} → {_place(t.dropoff_address, t)}"})
            continue
        created = _aware(t.created_at)
        if created is not None and now - created >= UNASSIGNED_AFTER:
            urgent.append({"trip_id": t.id, "reservation": False, "since": _iso(created),
                           "label": f"{_place(t.pickup_address, t)} → {_place(t.dropoff_address, t)}"})
    urgent.sort(key=lambda r: r["since"] or "")

    drivers = (await db.execute(select(User.id, User.last_active_at).where(
        User.role == "driver", User.is_online.is_(True),
        User.status.in_(ACTIVE_ACCOUNT_STATUSES),
    ))).all()
    quiet = sum(1 for _, last in drivers
                if _aware(last) is None or (now - _aware(last)).total_seconds() > _STALE_DRIVER_S)

    # Payouts whose latest attempt failed and nothing went through since —
    # the Inicio's "Necesita atención" rule.
    latest: dict[int, tuple] = {}
    for user_id, status, amount in (await db.execute(
        select(Cashout.user_id, Cashout.status, Cashout.amount)
        .where(Cashout.created_at >= now - _PAYOUT_WINDOW)
        .order_by(Cashout.created_at.asc(), Cashout.id.asc())
    )).all():
        latest[user_id] = (status, amount)
    failed = [a for s, a in latest.values() if s == "failed"]

    return {
        "now": _iso(now),
        "support": {"n": len(support), "oldest": support[0]["since"] if support else None,
                    "first": support[0] if support else None},
        "unassigned": {"n": len(urgent), "oldest": urgent[0]["since"] if urgent else None,
                       "first": urgent[0] if urgent else None},
        "reservations_open": reservations_open,
        "drivers": {"online": len(drivers), "quiet": quiet},
        "payouts_failed": {"n": len(failed), "amount": round(sum(float(a or 0) for a in failed), 2)},
    }


# ── Notices on the operators' phones (Web Push, services/panel_push.py) ──
@router.get("/admin/panel/push/key", dependencies=[Depends(_require_dispatch_auth)])
async def panel_push_key():
    from services import panel_push
    return {"public_key": panel_push.keys()[1]}


@router.post("/admin/panel/push/subscribe", dependencies=[Depends(_require_dispatch_auth)])
async def panel_push_subscribe(body: dict = Body(...), db: AsyncSession = Depends(get_db)):
    from services import panel_push
    sub = panel_push.clean(body.get("subscription"))
    if sub is None:
        raise HTTPException(400, "Suscripción no válida")
    await panel_push.save(db, sub, str(body.get("label") or ""))
    return {"ok": True}


@router.post("/admin/panel/push/unsubscribe", dependencies=[Depends(_require_dispatch_auth)])
async def panel_push_unsubscribe(body: dict = Body(...), db: AsyncSession = Depends(get_db)):
    from services import panel_push
    endpoint = body.get("endpoint")
    if not isinstance(endpoint, str):
        raise HTTPException(400, "Falta el endpoint")
    return {"ok": True, "removed": await panel_push.remove(db, endpoint)}


@router.post("/admin/panel/push/test", dependencies=[Depends(_require_dispatch_auth)])
async def panel_push_test(body: dict = Body(...), db: AsyncSession = Depends(get_db)):
    """One test notice to THIS device only — never to the other operators."""
    from services import panel_push
    endpoint = body.get("endpoint")
    if not isinstance(endpoint, str) or not any(
            s["endpoint"] == endpoint for s in await panel_push.subscriptions(db)):
        raise HTTPException(404, "Este dispositivo no tiene los avisos activados")
    sent = await panel_push.send({"title": "Cruise Dispatch", "body": "Los avisos llegan a este teléfono.",
                                  "url": "/inicio", "tag": "cruise-test"}, only=endpoint)
    if not sent:
        raise HTTPException(502, "El servicio de avisos del teléfono no lo aceptó")
    return {"ok": True}


# ── A new panel page that fell back to the old one (2026-11-17) ────────────
# Each hand-written page (#30) sits in an error boundary that shows the page
# from before when it throws. Without this the error only lived in the
# operator's browser console (#833's trip page showed the old layout and
# nothing said why). Logged, never stored; per process at most 60 a minute.
_client_errors: list[float] = []


@router.post("/admin/panel/client-error", dependencies=[Depends(_require_dispatch_auth)])
async def panel_client_error(body: dict = Body(...)):
    import logging
    import time as _time
    now = _time.monotonic()
    _client_errors[:] = [t for t in _client_errors if now - t < 60]
    if len(_client_errors) >= 60:
        return {"ok": False}
    _client_errors.append(now)

    def clip(k, n):
        v = body.get(k) if isinstance(body, dict) else None
        return " ".join(str(v or "").split())[:n]

    logging.getLogger(__name__).warning(
        "[PanelError] where=%s path=%s msg=%s | stack=%s | component=%s",
        clip("where", 40), clip("path", 200), clip("message", 500), clip("stack", 1500), clip("component", 800))
    return {"ok": True}
