"""Cruise Ride � FastAPI Backend
Complete implementation matching the Flutter client's ApiService endpoints.
Hardened with 10 LAYERS OF ULTRA-STRONG SECURITY PROTECTION.

 L1   CORS � Origin allowlist + credentials
 L2   Security Headers � HSTS, CSP, X-Frame, no-sniff, no-cache
 L3   Rate Limiting � Per-IP sliding window (60 req / 60 sec)
 L4   Request Size Limit � 5 MB max body (anti-payload bomb)
 L5   Brute Force Protection � 5 attempts / 5 min lockout on login
 L6   IP Blacklist � Auto-ban after 20 violations
 L7   Input Sanitization � SQL injection + XSS regex rejection
 L8   Crash Protection � Global exception handler, zero info leakage
 L9   Nonce Replay Protection � Server-side nonce dedup with TTL
 L10  Security Audit Logging � Tamper-evident hash-chain log
"""

# ── Logging level ──────────────────────────────────────────────────────────
# Nothing configured the root logger, so Python's default of WARNING applied
# and every logging.info() in this file was silently dropped in production.
# Startup was invisible: no "Phase 1 agents started", no "FULLY OPERATIONAL",
# no indication of which worker won the scheduler lock — the state of the
# service had to be inferred from the database instead of read from its logs.
# Configured first, before any import can emit or install a handler.
import logging as _logging_boot
import os as _os_boot

_logging_boot.basicConfig(
    level=getattr(
        _logging_boot,
        (_os_boot.getenv("LOG_LEVEL") or "INFO").upper(),
        _logging_boot.INFO,
    ),
    format="%(levelname)s:%(name)s:%(message)s",
)

# ── CRITICAL: Ensure imports work regardless of working directory ──
import sys
from pathlib import Path
# Add the directory containing this file to sys.path
_backend_dir = Path(__file__).parent.resolve()
if str(_backend_dir) not in sys.path:
    sys.path.insert(0, str(_backend_dir))

import os, time, hmac, hashlib, math, secrets, logging, collections, re, json, smtplib, traceback, inspect
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import datetime, timedelta, timezone
from contextlib import asynccontextmanager
import asyncio
from typing import Optional, List

# ── Load .env BEFORE any module that reads environment variables ──
# Modules like utils.security read os.getenv at import time. If .env
# isn't loaded first, those imports see empty values and either crash
# (Railway) or auto-generate insecure defaults (local dev).
from dotenv import load_dotenv
load_dotenv()

# Support chat AI cache & health monitoring
from support_cache import find_cached_response, add_natural_variation, claude_health, load_cache, maybe_cache_response

# Security Guardian Agent — blocks threats BEFORE they cause damage
from security_guardian import security_guardian

# Guardian Agent — keeps all systems healthy and connections alive
from guardian_agent import guardian_agent

# Autonomous Agents — ghost cleanup, safety, document expiry/approval, rating moderation
from ghost_driver_agent import ghost_driver_agent
from safety_monitor_agent import safety_monitor_agent
from document_expiry_agent import document_expiry_agent
from background_recheck_agent import background_recheck_agent
from document_approval_agent import document_approval_agent
from rating_moderator_agent import rating_moderator_agent
from cruise_level_agent import cruise_level_agent
from chat_retention_agent import chat_retention_agent
from proactive_support_agent import run_proactive_agent_loop
from wait_timeout_agent import wait_timeout_agent

# Socket.io real-time service
from services.socketio_service import sio, configure as _configure_socketio

# Automatic PostgreSQL backup system
from db_backup import backup_scheduler as _backup_scheduler, get_status as _backup_status

import base64
import socketio
from fastapi import FastAPI, Depends, HTTPException, Header, Request, Query, Body
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse, FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, field_validator, model_validator
import jwt
import bcrypt as _bcrypt
from sqlalchemy import (
    Column, Integer, String, Float, Boolean, DateTime, ForeignKey, Text, select, func, and_, text, UniqueConstraint
)
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase, relationship

# ── Extracted modules ──────────────────────────────────────────────────
from models.database import (
    Base, engine, SessionLocal, get_db, IS_SQLITE, DATABASE_URL,
    User, ConsentLog, Trip, FareSplit, DispatchOffer, PayoutMethod,
    RiderPaymentMethod, Wallet, WalletTransaction, Cashout, Vehicle,
    Document, Rating, ChatMessage, SupportChat, SupportMessage,
    ActionRequest, Notification, PromoCode, PasswordResetToken,
    Referral, FavoriteLocation, DriverIncentive, SurgeZone, ServiceArea,
    AuditLog,
    column_missing as _column_missing,
    migrate_add_columns as _migrate_add_columns,
    migrate_postgres as _migrate_postgres,
)
from models.schemas import (
    RegisterIn, CheckExistsIn, LoginIn, CompleteLoginIn, SocialAuthIn,
    SendOtpIn, VerifyOtpIn, OwnerLogin, ApplyReferralIn,
    CreateTripIn, AcceptTripIn, DriverLocationIn, CashoutIn,
    PayoutMethodIn, RiderPaymentMethodIn, WalletTopUpIn, WalletWithdrawIn,
    PaymentIntentIn, PayPalOrderIn, PayPalCaptureIn,
    DispatchRequestIn, AdminStatsResponse,
)
from utils.security import (
    pwd, _Pwd,
    _create_token, _create_refresh_token, _create_login_token,
    _get_current_user, _require_admin, _verify_api_key,
    _require_dispatch_auth, _verify_dispatch_key,
    _check_login_throttle, _record_login_failure, _clear_login_failures,
    _ip_blacklist, _ip_violations, _record_violation,
    _used_nonces, _check_nonce_replay,
    _audit_chain, _security_audit_log,
    _sanitize_string, _SQL_INJECTION_PATTERN, _XSS_PATTERN,
    _dispatch_sessions,
    load_revoked_tokens_from_db, flush_audit_logs_to_db,
    API_KEY, HMAC_SECRET, JWT_SECRET, DISPATCH_API_KEY,
    JWT_ALGORITHM, JWT_EXPIRE_HOURS, JWT_REFRESH_HOURS,
)
from utils.helpers import (
    utc_now, utc_today_start, utc_days_ago, utc_month_start, utc_year_start,
    _haversine, _user_dict, _trip_dict, _vehicle_dict, _doc_dict, _support_msg_dict,
    ACTIVE_ACCOUNT_STATUSES, _safe_create_task,
)
from services.fcm_service import _send_fcm_push
from services.email_sms_service import _send_email

# ── Configuration (env vars, shared state) ─────────────────────
from config import (
    _SERVER_START_TIME, _watchdog_stats, _HAS_FIRESTORE, firestore_sync,
    STRIPE_SECRET, PHOTOS_DIR, UPLOADS_DIR, sweep_caches,
)

# ── Tiered rate limiter (auth vs general API) ─────────────────
from middleware.rate_limit import rate_limiter as _tiered_rate_limiter

# When the transfer is SENT, which is not when the driver sees the money.
#
# The week worked is Monday to Sunday. The run goes out Monday (weekday 0),
# and a US bank credit takes about two business days, so it lands Wednesday —
# which is the day the driver was promised. Setting this to Wednesday, as it
# briefly was, would have paid them on Friday.
#
# Monday is 0. 02:00 UTC is Sunday 21:00 in Alabama, so the run fires late
# Sunday evening local — after the week it is paying for has closed, which is
# the point.
_PAYOUT_WEEKDAY = 0
_PAYOUT_HOUR_UTC = 2


def _next_payout_run() -> datetime:
    """Return the next payday at 02:00 UTC (or today if it is payday and before 2 AM)."""
    now = datetime.now(timezone.utc)
    days_ahead = (_PAYOUT_WEEKDAY - now.weekday()) % 7
    if days_ahead == 0 and now.hour >= _PAYOUT_HOUR_UTC:
        days_ahead = 7
    target = (now + timedelta(days=days_ahead)).replace(
        hour=_PAYOUT_HOUR_UTC, minute=0, second=0, microsecond=0
    )
    return target

# ── Weekly auto-payout ────────────────────────────────────────────────────
#
# Real money leaves the platform here, so everything below follows one rule:
# it is always better to pay a driver LATE than to pay them TWICE.
#
# The old order of operations was: insert the Cashout row, call Stripe, then
# commit. Railway sends SIGTERM on every redeploy, and a SIGTERM landing
# between the Stripe call and the commit left the transfer done and the
# database untouched — the row rolled back and pending_balance was never
# zeroed — so the NEXT run paid the whole balance a second time. The Stripe
# idempotency key did not stop that: it was stamped with the calendar date,
# and the next run happens on a different date.
#
# The database is written FIRST now:
#
#   1. CLAIM    under a row lock, insert the Cashout as "processing" and zero
#               pending_balance, then COMMIT. This is the point of no return:
#               from here the money is spoken for and no later run can claim
#               it again.
#   2. TRANSFER call Stripe, off the event loop.
#   3. SETTLE   mark the row "completed"; or, ONLY for errors Stripe answered
#               with a definitive rejection, "failed" + hand the balance back.
#
# An interruption anywhere after step 1 leaves the row in "processing", and
# the driver earnings ledger in routers/drivers.py already treats that as
# money spent (it sums every cashout whose status is not "failed"). So the
# stuck state costs a manual reconciliation and never a double payment.
# _report_stuck_payouts() below is the alarm for exactly that state.
#
# LIMITATION, stated plainly: closing a stuck row automatically would need
# the Stripe transfer id persisted on the cashout, and there is no column for
# it. Adding one is a schema change and out of scope here, so the recovery is
# a loud ERROR log naming the cashout id and the idempotency key, not code.

# A claim older than this that is still "processing" was interrupted.
_PAYOUT_STUCK_AFTER_MINUTES = 30
# How long a cancelled payout may keep running to finish writing its result.
# Kept well under the shutdown budget: the platform SIGKILLs a container that
# takes too long to exit, and being killed here is no worse than being killed
# anywhere else — the claim is already committed either way.
_PAYOUT_SETTLE_GRACE = 8.0
# True only while a driver is mid claim→transfer→settle (read by shutdown).
_payout_in_flight = False


def _iso_week_stamp(dt: datetime) -> str:
    """'2026W32' — the ISO year+week a payout logically belongs to."""
    iso = dt.isocalendar()
    return f"{iso[0]}W{iso[1]:02d}"


async def _report_stuck_payouts() -> None:
    """Log every payout claim that never reached a terminal state.

    Read-only. This is the alarm for an interrupted run: the driver's balance
    is claimed but nothing here can tell whether Stripe moved the money, so a
    human has to look the transfer up and close the row.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=_PAYOUT_STUCK_AFTER_MINUTES)
    try:
        async with SessionLocal() as db:
            rows = (
                await db.execute(
                    select(Cashout)
                    .where(Cashout.status == "processing", Cashout.created_at < cutoff)
                    .order_by(Cashout.id.asc())
                    .limit(50)
                )
            ).scalars().all()
    except Exception as e:
        logging.error("[AutoPayout] stuck-payout scan failed: %s", e)
        return

    for c in rows:
        created = c.created_at
        # Two kinds of row land in this scan now, and they carry DIFFERENT
        # idempotency keys. Printing the weekly key for a driver-initiated
        # instant cashout would send whoever is reconciling to look up a
        # transfer that does not exist under that name — and conclude the
        # money never moved, which is exactly the wrong half of the
        # decision below.
        if (c.method or "") == "instant":
            idem = f"cashout-fund-{c.id}"
        elif created:
            idem = f"auto_payout_{c.user_id}_{_iso_week_stamp(created)}"
        else:
            idem = "?"
        logging.error(
            "[AutoPayout] STUCK PAYOUT — cashout #%s driver=%s $%.2f method=%s claimed=%s "
            "is still 'processing'. The balance is claimed and will NOT be paid again "
            "automatically. Look up idempotency_key=%s in Stripe: if the transfer "
            "exists set the row to 'completed', if it does not set it to 'failed' and "
            "add $%.2f back to the driver's pending_balance.",
            c.id, c.user_id, float(c.amount or 0.0), c.method or "standard",
            created.isoformat() if created else "?",
            idem,
            float(c.amount or 0.0),
        )


async def _release_payout_claim(driver_id: int, cashout_id: int, amount: float) -> None:
    """Undo a claim Stripe definitively refused: mark it failed, give the money back.

    Called ONLY for an error Stripe answered with a 4xx — the request reached
    Stripe and was rejected, so no transfer exists. A connection error or a 5xx
    is NOT this: those are ambiguous, and handing the balance back on an
    ambiguous error is precisely how a driver gets paid twice.
    """
    async with SessionLocal() as db:
        try:
            c = await db.get(Cashout, cashout_id)
            if c is None or c.status != "processing":
                logging.error(
                    "[AutoPayout] refusing to release cashout #%s — it is %r, not 'processing'",
                    cashout_id, getattr(c, "status", None),
                )
                return
            c.status = "failed"  # 'failed' rows are excluded from the earnings ledger
            drv = (
                await db.execute(
                    select(User).where(User.id == driver_id).with_for_update()
                )
            ).scalar_one_or_none()
            if drv is not None:
                drv.pending_balance = round(float(drv.pending_balance or 0.0) + amount, 2)
            await db.commit()
            logging.warning(
                "[AutoPayout] cashout #%s marked failed — $%.2f returned to driver %s",
                cashout_id, amount, driver_id,
            )
        except Exception as e:
            await db.rollback()
            logging.error(
                "[AutoPayout] could not release claim for cashout #%s (driver %s, $%.2f): %s "
                "— the row stays 'processing', reconcile by hand",
                cashout_id, driver_id, amount, e,
            )


async def _transfer_and_settle(
    driver_id: int, cashout_id: int, amount: float,
    connect_id: str, idem_key: str, fcm_token, _s,
) -> None:
    """Steps 2 and 3: send the money, then record what happened."""

    def _create_transfer():
        return _s.Transfer.create(
            # int() alone truncates (12.34 * 100 is 1233.9999... in binary
            # float), quietly shaving a cent off every payout while the full
            # balance was zeroed. Round first.
            amount=max(int(round(amount * 100)), 50),
            currency="usd",
            destination=connect_id,
            description=f"Cruise weekly auto-payout — cashout #{cashout_id}",
            metadata={"cashout_id": str(cashout_id), "driver_id": str(driver_id)},
            idempotency_key=idem_key,
        )

    try:
        # The Stripe SDK is synchronous. Called directly it froze the whole
        # event loop for the round-trip, once per driver, serially.
        transfer = await asyncio.to_thread(_create_transfer)
    except Exception as e:
        http_status = getattr(e, "http_status", None)
        definitely_rejected = isinstance(http_status, int) and 400 <= http_status < 500
        if definitely_rejected:
            logging.error(
                "[AutoPayout] Stripe rejected driver %s cashout #%s (HTTP %s): %s "
                "— balance returned",
                driver_id, cashout_id, http_status, e,
            )
            await _release_payout_claim(driver_id, cashout_id, amount)
        else:
            logging.error(
                "[AutoPayout] Stripe call for driver %s cashout #%s ($%.2f) failed with NO "
                "definitive answer (%s). The transfer may or may not have gone through, so "
                "the balance stays claimed and the row stays 'processing'. Reconcile against "
                "idempotency_key=%s.",
                driver_id, cashout_id, amount, e, idem_key,
            )
        return

    try:
        transfer_id = transfer["id"]
    except Exception:
        transfer_id = getattr(transfer, "id", None)

    async with SessionLocal() as db:
        try:
            c = await db.get(Cashout, cashout_id)
            if c is not None and c.status != "completed":
                c.status = "completed"
                await db.commit()
        except Exception as e:
            await db.rollback()
            logging.error(
                "[AutoPayout] transfer %s SUCCEEDED for driver %s but cashout #%s could not "
                "be marked completed: %s — the balance is correctly claimed, only the row "
                "status is wrong; fix it by hand",
                transfer_id, driver_id, cashout_id, e,
            )

    logging.info(
        "[AutoPayout] Driver %s — $%.2f — transfer %s", driver_id, amount, transfer_id
    )
    if fcm_token:
        try:
            _send_fcm_push(
                fcm_token,
                title="💰 Payout Sent!",
                body=f"${amount:.2f} has been transferred to your bank account.",
                data={"type": "auto_payout", "amount": str(amount)},
            )
        except Exception as e:
            logging.warning("[AutoPayout] payout push failed for driver %s: %s", driver_id, e)


async def _payout_one_driver(driver_id: int, _s) -> None:
    """Claim → transfer → settle for exactly one driver."""
    global _payout_in_flight

    # ── 1. CLAIM (committed before a cent moves) ──────────────────────────
    async with SessionLocal() as db:
        drv = (
            await db.execute(
                # Row-level lock, taken and released inside this one short
                # transaction. skip_locked means a concurrent run walks past a
                # driver somebody else is already claiming instead of blocking.
                select(User).where(User.id == driver_id).with_for_update(skip_locked=True)
            )
        ).scalar_one_or_none()
        if drv is None:
            logging.info("[AutoPayout] driver %s is locked by another run — skipping", driver_id)
            return
        # Re-read under the lock rather than trusting the list this run was
        # built from: a concurrent run may already have claimed this balance,
        # in which case pending_balance is now 0 and there is nothing to send.
        amount = round(float(drv.pending_balance or 0.0), 2)
        if amount <= 1.0 or not drv.stripe_connect_id:
            return
        cashout = Cashout(user_id=drv.id, amount=amount, status="processing")
        db.add(cashout)
        drv.pending_balance = 0.0
        await db.commit()
        cashout_id = int(cashout.id)
        connect_id = drv.stripe_connect_id
        fcm_token = drv.fcm_token
        claimed_at = getattr(cashout, "created_at", None) or datetime.now(timezone.utc)

    # The idempotency key identifies the LOGICAL payout, not the attempt.
    #
    # It was driver + calendar date, which only ever protected against a
    # duplicate inside the same day — the exact case that a crash-and-retry
    # does not fall into. Driver + ISO week matches the schedule the payout
    # actually runs on (one run per driver per week, Tuesday 02:00 UTC), so
    # every retry of the same week's payout carries the same key. The week is
    # taken from the CLAIM ROW's timestamp, not from "now", so a retry stays
    # bound to the run it belongs to instead of drifting into the next week.
    #
    # Deliberately NOT keyed on cashout.id: the whole failure being fixed is a
    # second attempt for the same week, and a second attempt means a second
    # cashout row, so a row-scoped key would collide with nothing and pay
    # twice. A week-scoped key errs the other way — if two claims for one
    # driver ever existed in one week, Stripe returns the first transfer
    # instead of creating a second. That direction is an underpayment, which
    # is visible and repairable; the other direction is money that is gone.
    #
    # Note this key is a SECOND line of defence only. Stripe retains
    # idempotency keys for about 24 hours, so it cannot stop a retry a week
    # later on its own. The committed claim above is what actually guarantees
    # the balance is never claimed twice.
    idem_key = f"auto_payout_{driver_id}_{_iso_week_stamp(claimed_at)}"

    # ── 2+3. TRANSFER and SETTLE, shielded ────────────────────────────────
    # Shutdown must not sever this in half. If SIGTERM arrives while Stripe is
    # in flight, the shielded task keeps going and gets a bounded grace period
    # to write down what happened.
    _payout_in_flight = True
    inner = asyncio.ensure_future(
        _transfer_and_settle(driver_id, cashout_id, amount, connect_id, idem_key, fcm_token, _s)
    )
    try:
        await asyncio.shield(inner)
    except asyncio.CancelledError:
        try:
            await asyncio.wait_for(asyncio.shield(inner), _PAYOUT_SETTLE_GRACE)
        except BaseException:
            logging.error(
                "[AutoPayout] shutdown interrupted cashout #%s (driver %s, $%.2f) before it "
                "could be settled. The row stays 'processing' and the balance stays claimed, "
                "so it will NOT be paid again automatically — look up idempotency_key=%s in "
                "Stripe and close the row by hand.",
                cashout_id, driver_id, amount, idem_key,
            )
        raise
    finally:
        _payout_in_flight = False


async def _auto_payout_all_drivers():
    """Transfer pending_balance to every eligible driver via Stripe Connect."""
    if not STRIPE_SECRET:
        logging.warning("[AutoPayout] STRIPE_SECRET not configured — skipping")
        return
    try:
        import stripe as _s
        _s.api_key = STRIPE_SECRET
    except Exception as e:
        logging.error("[AutoPayout] Stripe import failed: %s", e)
        return

    # Surface anything a previous run left half-finished before adding to it.
    await _report_stuck_payouts()

    # Leadership is re-checked here, not just at boot. If this process quietly
    # lost the advisory lock, another one is the leader and will run its own
    # payout — this one must not also run. Re-acquiring is the same authority
    # the election uses, so a transient blip does not cost a whole week.
    if not _is_scheduler_leader and not await _try_become_scheduler_leader():
        logging.error(
            "[AutoPayout] this process does not hold the scheduler lock — skipping the run "
            "rather than risking a second payer"
        )
        return

    logging.info("[AutoPayout] Starting weekly payout run")
    async with SessionLocal() as db:
        # IDs only, no locks held across the run: locks live inside each
        # driver's own short transaction below. The old code held a
        # FOR UPDATE over the whole loop, but committed inside it, so every
        # lock was released after the first driver anyway.
        driver_ids = (
            await db.execute(
                select(User.id)
                .where(
                    and_(
                        User.role == "driver",
                        User.stripe_connect_id.isnot(None),
                        User.pending_balance > 1.0,
                    )
                )
                .order_by(User.id.asc())
            )
        ).scalars().all()

    logging.info("[AutoPayout] %d driver(s) eligible for payout", len(driver_ids))
    for _idx, driver_id in enumerate(driver_ids):
        try:
            await _payout_one_driver(int(driver_id), _s)
        except asyncio.CancelledError:
            logging.error(
                "[AutoPayout] run interrupted — the remaining %d driver(s) keep their "
                "balance and are paid on the next run",
                len(driver_ids) - _idx - 1,
            )
            raise
        except Exception as e:
            logging.error("[AutoPayout] Failed for driver %s: %s", driver_id, e)

# ── Single-leader election for background tasks ──────────────────────────
# Uvicorn runs multiple worker PROCESSES (UVICORN_WORKERS). Each one executes
# lifespan(), so every scheduler below used to run once per worker: two copies
# of the weekly payout loop, the scheduled-ride dispatcher, the ghost-driver
# agent, backups and the nightly reconcile.
#
# For the payout loop that meant both workers waking at the same Tuesday
# 02:00 UTC, both reading the same pending_balance and both transferring it —
# paying every driver twice. This lock is what stops that.
#
# A session-scoped Postgres advisory lock is the right primitive here: it is
# held by ONE connection, needs no table, and the database releases it
# automatically if the process dies, so a respawned worker can take over.
_leader_conn = None  # released on shutdown, never handed back to the pool
_is_scheduler_leader = False  # True only while this process holds the lock
_leader_guard = None  # asyncio.Lock, created lazily (see _get_leader_guard)


def _get_leader_guard() -> asyncio.Lock:
    """Serialise election attempts inside this process.

    Two callers race for leadership now (the boot path and the watchdog, plus
    the payout run's re-check). Without this they could both call
    engine.connect() and stomp _leader_conn, leaking the connection that owns
    the lock. Created lazily so no event loop is needed at import time.
    """
    global _leader_guard
    if _leader_guard is None:
        _leader_guard = asyncio.Lock()
    return _leader_guard


async def _try_become_scheduler_leader() -> bool:
    """True if THIS worker process should run the background schedulers.

    Returns True on SQLite (tests, local single-process runs) since there are
    no sibling workers to race with. Safe to call repeatedly: a process that
    already holds the lock short-circuits, and a process that does not either
    takes it or leaves empty-handed.
    """
    global _leader_conn, _is_scheduler_leader
    if IS_SQLITE:
        _is_scheduler_leader = True
        return True
    async with _get_leader_guard():
        if _is_scheduler_leader and _leader_conn is not None:
            return True
        conn = None
        try:
            # Raw connection outside the pool: an advisory lock lives as long
            # as its connection, so it must not be handed back to the pool and
            # reused by an unrelated query.
            conn = await engine.connect()
            got = await conn.scalar(
                text("SELECT pg_try_advisory_lock(:k)"), {"k": _SCHEDULER_LOCK_KEY}
            )
            if got:
                # End the implicit transaction that SELECT opened. A
                # connection parked "idle in transaction" for days is what
                # idle_in_transaction_session_timeout and every pooler reaper
                # go looking for, and killing it would drop the lock. The lock
                # itself is SESSION-scoped (pg_advisory_lock, not the _xact_
                # variant), so committing here does not release it.
                try:
                    await conn.rollback()
                except Exception:
                    pass
                _leader_conn = conn
                _is_scheduler_leader = True
                logging.info("[Leader] This worker owns the background schedulers")
                return True
            await conn.close()
            logging.info("[Leader] Another worker owns the schedulers — standing by")
            return False
        except Exception as e:
            # Never let lock trouble take the API down. Failing closed (no
            # schedulers) is safer than two workers racing over real money: a
            # missed payout run is recoverable, a doubled one is not.
            logging.error("[Leader] Advisory lock failed, skipping schedulers: %s", e)
            if conn is not None:
                try:
                    await conn.close()
                except Exception:
                    pass
            return False


# How often leadership is re-checked. Long enough to be free, short enough
# that a container that lost the boot race takes over within a minute of the
# previous one exiting.
_LEADER_CHECK_INTERVAL = 60


async def _leader_watchdog():
    """Keep exactly one process owning the schedulers, for as long as it runs.

    Two states used to be unrecoverable without a manual redeploy:

      * A process that LOST the election at boot never tried again. Railway
        overlaps containers during a deploy, so the outgoing container still
        holds the lock while the new one starts — the new one lost the race
        and then stood by forever. Ghost cleanup, the weekly payout, backups,
        audit retention, the nightly reconcile and the scheduled-ride
        dispatcher simply did not run until somebody deployed again.
      * A LEADER whose lock connection dropped (Postgres restart, pooler
        eviction, network blip) silently stopped being the leader. Postgres
        releases an advisory lock with its connection, and nobody ever took it.

    On not creating a second leader — the property that matters more than any
    of the above: the advisory lock is the authority, exactly one connection
    can hold it, and this loop only ever starts the schedulers after
    pg_try_advisory_lock has itself returned true. _start_scheduler_agents()
    is once-per-process, so re-acquiring the lock in a process that is already
    running the agents starts nothing a second time.

    The one case this does NOT fully resolve is a leader that loses the lock
    and cannot retake it: its agents keep running while another process may
    have taken over. Stopping and restarting live agents to close that window
    is more dangerous than the window itself, so the choice here is a loud
    ERROR instead — plus _auto_payout_all_drivers() re-checks leadership at
    run time, which keeps the money path single-writer regardless, and the
    per-driver claim in the payout makes even a concurrent run non-duplicating.
    """
    global _is_scheduler_leader, _leader_conn
    while True:
        await asyncio.sleep(_LEADER_CHECK_INTERVAL)
        try:
            if not _is_scheduler_leader:
                if await _try_become_scheduler_leader():
                    logging.warning("[Leader] took over the background schedulers")
                    await _start_scheduler_agents()
                continue

            # Leader: is the connection that holds the lock still alive?
            try:
                if _leader_conn is None:
                    raise RuntimeError("leader connection is gone")
                await _leader_conn.scalar(text("SELECT 1"))
                # Leave it idle, not idle-in-transaction (see the acquire path).
                try:
                    await _leader_conn.rollback()
                except Exception:
                    pass
                continue  # still healthy
            except Exception as e:
                logging.error("[Leader] lock connection is not usable: %s", e)

            _is_scheduler_leader = False
            old_conn, _leader_conn = _leader_conn, None
            if old_conn is not None:
                try:
                    await old_conn.close()
                except Exception:
                    pass

            if await _try_become_scheduler_leader():
                logging.warning(
                    "[Leader] lock connection replaced — leadership retained, "
                    "agents left running untouched"
                )
            else:
                logging.error(
                    "[Leader] LOST the scheduler lock and could not retake it. The "
                    "background schedulers in THIS process are still running while another "
                    "process may now be the leader. Payouts are still single-writer (the "
                    "run re-checks the lock and every payout claims its balance in the "
                    "database first), but redeploy to return to one leader."
                )
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logging.error("[Leader] watchdog iteration failed: %s", e)


async def _release_scheduler_leadership() -> None:
    """Drop the advisory lock on shutdown so the next container can take it."""
    global _leader_conn, _is_scheduler_leader
    _is_scheduler_leader = False
    conn, _leader_conn = _leader_conn, None
    if conn is None:
        return
    try:
        await conn.close()
        logging.info("[Leader] scheduler lock released")
    except Exception as e:
        logging.warning("[Leader] releasing the scheduler lock failed: %s", e)


# Arbitrary but fixed application-wide key for the scheduler lock.
_SCHEDULER_LOCK_KEY = 771_120_045


async def _schedule_weekly_payouts():
    """Background loop: sleep until the next run (Monday 02:00 UTC, lands Wednesday), run payouts, repeat."""
    # A redeploy that interrupted a payout run is worth hearing about now,
    # not next Tuesday — this is the closest thing to a boot-time alarm the
    # payout has. Read-only, so it cannot make anything worse.
    try:
        await _report_stuck_payouts()
    except Exception as e:
        logging.error("[AutoPayout] boot-time stuck scan failed: %s", e)
    while True:
        target = _next_payout_run()
        wait_secs = (target - datetime.now(timezone.utc)).total_seconds()
        logging.info(
            "[AutoPayout] Next run scheduled at %s (in %.0f s)",
            target.isoformat(), wait_secs,
        )
        await asyncio.sleep(max(wait_secs, 0))
        await _auto_payout_all_drivers()
        await asyncio.sleep(60)  # prevent tight re-entry at the same second


# ── Background task registry ─────────────────────────────────────────────
# Every loop below used to be launched with a bare asyncio.create_task() and
# then forgotten: no reference was kept (so the garbage collector was free to
# drop a running task), and shutdown cancelled none of them. On SIGTERM the
# engine was disposed underneath twelve loops that were still mid-query.
#
# _safe_create_task (utils/helpers.py) already holds a strong reference and
# logs whatever a task dies of, so it is reused here rather than growing a
# second mechanism; this list adds only the handle needed to cancel them.
_BACKGROUND_TASKS: List[asyncio.Task] = []


def _spawn_background(coro, name: str) -> asyncio.Task:
    """Start a long-lived background loop and remember it for shutdown."""
    task = _safe_create_task(coro, name=name)
    _BACKGROUND_TASKS.append(task)
    return task


async def _shutdown_background_tasks(timeout: float = 10.0) -> None:
    """Cancel every registered loop and give it a moment to unwind.

    MUST run before the SQLAlchemy engine is disposed: a task cancelled after
    disposal wakes up on a dead engine. The brief wait is what lets a loop
    finish the statement it is in the middle of instead of being severed —
    and, for a payout caught mid-transfer, what lets its shielded settle write
    land before the process goes (see _payout_one_driver).
    """
    tasks = [t for t in _BACKGROUND_TASKS if not t.done()]
    _BACKGROUND_TASKS.clear()
    if not tasks:
        return
    for t in tasks:
        t.cancel()
    try:
        _, pending = await asyncio.wait(tasks, timeout=timeout)
    except Exception as e:  # pragma: no cover - defensive
        logging.warning("[Shutdown] waiting on background tasks failed: %s", e)
        return
    if pending:
        logging.warning(
            "[Shutdown] %d background task(s) did not stop within %.0fs: %s",
            len(pending), timeout,
            ", ".join(sorted((t.get_name() or "unnamed") for t in pending)),
        )
    else:
        logging.info("[Shutdown] %d background task(s) stopped cleanly", len(tasks))
    if _payout_in_flight:
        logging.error(
            "[Shutdown] a driver payout was STILL in flight when shutdown stopped waiting "
            "— look for the [AutoPayout] line naming the cashout left in 'processing'"
        )


# Set the instant the schedulers are started, so they can never be started a
# second time in one process (a re-election in a process that is already the
# leader must be a no-op). Checked and set with no await in between, which in
# a single-threaded event loop makes it atomic.
_scheduler_agents_started = False


async def _start_scheduler_agents() -> None:
    """Start every leader-only background agent, staggered.

    The stagger used to sit in lifespan() BEFORE its yield. ASGI startup has
    to complete before uvicorn serves anything, so those three sleeps kept the
    container from answering /ping for 30s on top of DB init — against a
    120s healthcheck budget that the last deploy needed four attempts to meet.

    The stagger itself is worth keeping: it stops a dozen loops from opening
    connections in the same instant at boot. It just has no business running
    before the app is allowed to serve traffic, so it lives here, in a task.

    Start ORDER is unchanged from the original phases. Nothing here depends on
    anything else here — they are independent periodic loops — so the order is
    a courtesy to the connection pool, not a requirement.
    """
    global _scheduler_agents_started
    if _scheduler_agents_started:
        return
    _scheduler_agents_started = True

    # Phase 2: Critical background agents only (5s delay)
    await asyncio.sleep(5)
    wait_timeout_agent.set_db_session_maker(SessionLocal)
    await wait_timeout_agent.start()
    logging.info("[Lifespan] Phase 2 agents started (wait_timeout)")

    # Phase 3: Low-priority agents (staggered, 15s apart)
    await asyncio.sleep(10)
    ghost_driver_agent.set_db_session_maker(SessionLocal)
    await ghost_driver_agent.start()
    safety_monitor_agent.set_db_session_maker(SessionLocal)
    await safety_monitor_agent.start()
    logging.info("[Lifespan] Phase 3 agents started (ghost_driver, safety_monitor)")

    # Phase 4: Periodic tasks (30s delay) — full set with DB-smart intervals
    await asyncio.sleep(15)
    _spawn_background(_audit_flush_loop(), "audit_flush")
    _spawn_background(_audit_retention_loop(), "audit_retention")
    _spawn_background(_scheduled_ride_dispatcher(), "scheduled_ride_dispatcher")
    _spawn_background(_scheduled_ride_reminder_loop(), "scheduled_ride_reminder")
    _spawn_background(_rating_aftermath_loop(), "rating_aftermath")
    logging.info("[Lifespan] Phase 4 periodic tasks started")

    # Re-enabled agents with longer intervals to reduce PgBouncer churn
    _spawn_background(_schedule_weekly_payouts(), "weekly_payouts")
    _spawn_background(_backup_scheduler(), "backup_scheduler")
    _spawn_background(run_proactive_agent_loop(), "proactive_support")
    _spawn_background(_scheduled_rides_available_notify_loop(), "scheduled_rides_notify")
    _spawn_background(_nightly_reconcile_loop(), "nightly_reconcile")
    _spawn_background(_driver_referral_expiry_loop(), "driver_referral_expiry")

    # Class-based autonomous agents
    document_expiry_agent.set_db_session_maker(SessionLocal)
    await document_expiry_agent.start()

    background_recheck_agent.set_db_session_maker(SessionLocal)
    await background_recheck_agent.start()

    document_approval_agent.set_db_session_maker(SessionLocal)
    await document_approval_agent.start()

    rating_moderator_agent.set_db_session_maker(SessionLocal)
    await rating_moderator_agent.start()

    cruise_level_agent.set_db_session_maker(SessionLocal)
    await cruise_level_agent.start()

    chat_retention_agent.set_db_session_maker(SessionLocal)
    await chat_retention_agent.start()
    logging.info("[Lifespan] Class-based agents started")

    _spawn_background(_cache_sweep(), "cache_sweep")

    logging.info("🚀 Cruise backend FULLY OPERATIONAL — all agents active")


async def _cache_sweep():
    """Sweep the in-process caches every 60s."""
    while True:
        await asyncio.sleep(60)
        try:
            sweep_caches()
        except Exception:
            pass


async def _scheduler_bootstrap() -> None:
    """Contest the leadership, then keep contesting it for as long as we run."""
    # Started FIRST, and in leader and non-leader alike: the leader watches its
    # lock, everyone else waits for it to come free. Starting it after the
    # election would tie the watchdog's existence to a path that takes 30s of
    # deliberate stagger to return — and that can itself fail.
    _spawn_background(_leader_watchdog(), "leader_watchdog")
    try:
        if await _try_become_scheduler_leader():
            await _start_scheduler_agents()
        else:
            logging.info("[Lifespan] Not the scheduler leader — serving requests only")
    except asyncio.CancelledError:
        raise
    except Exception as e:
        logging.error("[Lifespan] Scheduler bootstrap failed: %s", e, exc_info=True)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Optimized startup: critical path first, agents staggered."""
    from services.event_bus import event_bus as _eb
    _eb.start_heartbeat()

    # Resolve the support LLM provider now and say which one won.
    #
    # The module logs this at import, but routers/support.py imports it
    # lazily inside the endpoint — so the line only appeared once a rider
    # had already written in, which is exactly too late to notice that
    # the key is missing and every conversation is being handed to a
    # human. Touching it here makes a misconfigured deploy visible in the
    # startup logs. Guarded: support must degrade, never block boot.
    try:
        from services.openai_support_service import _MODEL, _PROVIDER
        if _PROVIDER == "none":
            logging.warning(
                "[Support AI] no provider configured — every support chat "
                "will be handed straight to a human. Set MOONSHOT_API_KEY."
            )
        else:
            logging.info("[Support AI] provider=%s model=%s", _PROVIDER, _MODEL)
    except Exception as _e:  # noqa: BLE001
        logging.error("[Support AI] failed to initialise: %s", _e)

    # ── CRITICAL PATH: DB init (SYNCHRONOUS - blocks startup until done) ──
    db_initialized = False
    for _attempt in range(5):
        try:
            if IS_SQLITE:
                async with engine.begin() as conn:
                    await conn.run_sync(Base.metadata.create_all)
                    await conn.execute(text("PRAGMA journal_mode=WAL"))
                    await conn.execute(text("PRAGMA synchronous=NORMAL"))
                    await conn.execute(text("PRAGMA busy_timeout=30000"))
                    await conn.execute(text("PRAGMA cache_size=-64000"))
                    await _migrate_add_columns(conn)
            else:
                # PostgreSQL: use sync SQLAlchemy for DDL
                from sqlalchemy import create_engine
                from db_url import resolve_database_url
                sync_url = resolve_database_url(async_driver=False)
                # Ensure we use plain postgresql:// for sync engine
                for prefix in ("postgresql+asyncpg://", "postgresql+psycopg://", "postgres://"):
                    if sync_url.startswith(prefix):
                        sync_url = "postgresql://" + sync_url[len(prefix):]
                        break
                logging.info("[DB Init] Using sync URL: %s", sync_url.replace("//", "//***:").rsplit("@", 1)[-1] if "@" in sync_url else sync_url)
                sync_engine = create_engine(
                    sync_url,
                    echo=False,
                    connect_args={"sslmode": "require", "connect_timeout": 15, "options": "-c search_path=public"},
                )
                # Set search_path and create tables
                with sync_engine.begin() as sync_conn:
                    sync_conn.execute(text("SET search_path TO public"))
                    Base.metadata.create_all(sync_conn, checkfirst=True)
                    logging.info("[DB Init] Tables created/verified")
                sync_engine.dispose()
                
                # Verify tables exist with async connection
                async with engine.begin() as conn:
                    result = await conn.execute(text("SELECT tablename FROM pg_tables WHERE schemaname = 'public'"))
                    tables = [row[0] for row in result.fetchall()]
                    logging.info("[DB Init] Public tables: %s", tables)
                    required = ['users', 'trips', 'dispatch_offers', 'vehicles', 'documents']
                    missing = [t for t in required if t not in tables]
                    if missing:
                        logging.error("[DB Init] MISSING tables: %s", missing)
                        raise RuntimeError(f"Missing tables: {missing}")
                    logging.info("[DB Init] All required tables present ✓")
                    
                    # CRITICAL: Verify async engine can actually query the tables
                    # (catches search_path mismatches where tables exist in public
                    # but the connection searches a different schema first)
                    for tbl in required:
                        try:
                            await conn.execute(text(f"SELECT 1 FROM {tbl} LIMIT 0"))
                            logging.info("[DB Init] Table %s accessible from async engine ✓", tbl)
                        except Exception as _verify_err:
                            logging.error("[DB Init] Table %s NOT accessible from async engine: %s", tbl, _verify_err)
                            raise RuntimeError(f"Table {tbl} exists but is not accessible: {_verify_err}")
            
            # NOTE: PostgreSQL index migrations moved to standalone script
            # (backend/run_migrations.py) to avoid running DDL on every boot.
            # Indexes are created with IF NOT EXISTS, but checking pg_indexes
            # on every startup adds latency and locks. Run migrations manually
            # after schema changes instead.
            logging.info("[DB Init] Skipping on-boot index migration — use run_migrations.py for DDL changes")
            
            db_initialized = True
            logging.info("Database initialized successfully")
            break
        except Exception as _e:
            logging.warning("DB init attempt %d/5 failed: %s", _attempt + 1, _e, exc_info=_attempt == 4)
            if _attempt < 4:
                await asyncio.sleep(3)
    
    if not db_initialized:
        logging.error("[DB Init] CRITICAL: Database could not be initialized after 5 attempts")
        logging.error("[DB Init] The server will start but agents will fail")
        # Don't return - let the server start so health checks pass
        # But skip agent startup

    # ── Startup config validation (logs warnings for missing services) ──
    try:
        from config import validate_startup_config
        validate_startup_config()
    except Exception as _cfg_err:
        logging.warning("[Lifespan] Startup config validation failed: %s", _cfg_err)

    # Only start agents if DB is initialized
    if db_initialized:
        logging.info("[Lifespan] Starting agent initialization...")

        # ── Load revoked tokens (blocks JWT validation) ──
        try:
            await load_revoked_tokens_from_db()
            logging.info("[Lifespan] Revoked tokens loaded")
        except Exception as _e:
            logging.warning("[Lifespan] Revoked tokens load failed: %s", _e)

        # ── Staggered agent startup (avoid thundering herd) ──
        # Phase 1: Critical agents (0s delay)
        # These start in EVERY worker: request handlers call
        # guardian_agent.request_guardian, so a worker without it would fail
        # those requests.
        guardian_agent.set_db_session_maker(SessionLocal)
        await guardian_agent.start()
        await security_guardian.start_heartbeat()
        logging.info("[Lifespan] Phase 1 agents started (guardian, security)")

        # ── Scheduler leadership + the rest of the agents ──
        # Everything from here down is a periodic background loop, and uvicorn
        # runs several worker PROCESSES that each execute this function. Every
        # loop therefore ran once per worker — including the weekly payout,
        # which read the same pending_balance in both workers and transferred
        # it twice. Only the leader runs them.
        #
        # Handed to a task rather than awaited: ASGI lifespan startup must
        # finish before uvicorn serves a single request, and the election plus
        # the 30s of deliberate stagger inside it used to run before the yield
        # below — 30s of a 120s deploy healthcheck budget spent not answering
        # /ping, on top of a DB init that can itself take ~87s.
        _spawn_background(_scheduler_bootstrap(), "scheduler_bootstrap")
    else:
        logging.error("[Lifespan] Agents NOT started because DB initialization failed")

    yield
    # ── Cleanup ──
    # Background loops FIRST: they hold sessions, and cancelling them after the
    # engine is disposed wakes them up on a dead engine mid-statement.
    await _shutdown_background_tasks()
    await security_guardian.stop_heartbeat()
    await guardian_agent.stop()
    # Safe on agents this process never started — stop() is a no-op without a
    # task, and a non-leader only ever started the Phase 1 pair above.
    await ghost_driver_agent.stop()
    await safety_monitor_agent.stop()
    await document_expiry_agent.stop()
    await background_recheck_agent.stop()
    await document_approval_agent.stop()
    await rating_moderator_agent.stop()
    await wait_timeout_agent.stop()
    await chat_retention_agent.stop()
    # Started with the others but never stopped, so its loop outlived the
    # engine on every redeploy.
    await cruise_level_agent.stop()
    # Hand the advisory lock back before the engine goes, so the container
    # replacing this one can take over on its first attempt instead of waiting
    # for Postgres to notice the connection died.
    await _release_scheduler_leadership()
    # Dispose SQLAlchemy engine to close all pooled connections gracefully
    try:
        from models.database import engine as _engine
        await _engine.dispose()
        logging.info("[Shutdown] Database engine disposed — all connections closed")
    except Exception as _e:
        logging.warning("[Shutdown] Engine dispose warning: %s", _e)


async def _audit_flush_loop():
    """Flush audit logs to DB every 30s."""
    while True:
        await asyncio.sleep(30)
        try:
            await flush_audit_logs_to_db()
        except Exception:
            pass


async def _rating_aftermath_loop():
    """Two rating chores that have to happen on a clock, not on a request.

    One: the delayed word to a driver whose trip earned 3 stars or fewer.
    It waits half an hour on purpose — sent on the spot it would point
    straight at the rider who just got out of the car.

    Two: releasing drivers whose temporary deactivation has run out. This
    is the only way back: a suspended driver takes no trips, so no rating
    will ever arrive to lift them.

    A minute of granularity is plenty for both, and both are idempotent —
    they dedup against what they have already written, so a redeploy in
    the middle of either costs nothing.
    """
    from services import rating_actions

    while True:
        await asyncio.sleep(60)
        try:
            async with SessionLocal() as db:
                await rating_actions.deliver_due_followups(db)
                await rating_actions.release_expired_suspensions(db)
        except Exception as e:
            logging.warning("[RatingAftermath] loop iteration failed: %s", e)


# Days of audit history kept in Postgres. Older entries are archived to
# object storage and removed from the table.
AUDIT_RETENTION_DAYS = int(os.getenv("AUDIT_RETENTION_DAYS", "90"))
_AUDIT_ARCHIVE_BATCH = 5000


async def _archive_and_prune_audit_logs() -> None:
    """Move audit rows older than AUDIT_RETENTION_DAYS to object storage.

    audit_logs is the only table here that grows without bound — it is
    already the largest in the database — and nothing ever pruned it.

    Rows are ARCHIVED, never merely deleted. Each row carries prev_hash and
    entry_hash: the table is a tamper-evident chain, and dropping the oldest
    rows outright would leave the surviving ones pointing at entries that no
    longer exist anywhere, destroying exactly the property the chain was
    built to provide. The archive keeps both hashes, so history stays
    verifiable after the rows leave Postgres.

    Ordering is deliberate: upload, confirm, then delete. If the upload
    fails the rows stay in the database — losing disk space is recoverable,
    losing the audit trail is not.
    """
    from services.storage import archive_bytes

    cutoff = datetime.now(timezone.utc) - timedelta(days=AUDIT_RETENTION_DAYS)

    async with SessionLocal() as db:
        result = await db.execute(
            select(AuditLog)
            .where(AuditLog.ts < cutoff)
            .order_by(AuditLog.id.asc())
            .limit(_AUDIT_ARCHIVE_BATCH)
        )
        rows = result.scalars().all()
        if not rows:
            return

        payload = "\n".join(
            json.dumps(
                {
                    "id": r.id,
                    "ts": r.ts.isoformat() if r.ts else None,
                    "event": r.event,
                    "ip": r.ip,
                    "user_id": r.user_id,
                    "details": r.details,
                    "prev_hash": r.prev_hash,
                    "entry_hash": r.entry_hash,
                },
                sort_keys=True,
            )
            for r in rows
        ).encode()

        first_id, last_id = rows[0].id, rows[-1].id
        day = datetime.now(timezone.utc).strftime("%Y%m%d")
        key = f"audit-archive/{day}/audit_{first_id}_{last_id}.jsonl"

        try:
            await archive_bytes(payload, key)
        except Exception as e:
            # Includes S3 being unconfigured. Keep the rows.
            logging.error(
                "[AuditRetention] Archive failed for ids %s-%s — keeping rows: %s",
                first_id, last_id, e,
            )
            return

        await db.execute(
            text("DELETE FROM audit_logs WHERE id BETWEEN :a AND :b"),
            {"a": first_id, "b": last_id},
        )
        await db.commit()

    logging.info(
        "[AuditRetention] Archived %d rows (ids %s-%s) to %s and pruned them",
        len(rows), first_id, last_id, key,
    )
    # Leaves its own trace in the chain: the gap in ids is explained by an
    # entry that names the archive holding the missing rows.
    _security_audit_log(
        "audit_archive",
        "system",
        f"ids={first_id}-{last_id} count={len(rows)} key={key}",
    )


async def _audit_retention_loop():
    """Prune archived audit history daily. Leader-only, like every loop here."""
    while True:
        # Offset from startup so it never collides with the deploy itself.
        await asyncio.sleep(3600)
        try:
            await _archive_and_prune_audit_logs()
        except Exception as e:
            logging.error("[AuditRetention] Run failed: %s", e)
        await asyncio.sleep(86400 - 3600)

# Use orjson for 2-10x faster JSON serialization if available
try:
    import orjson
    from fastapi.responses import ORJSONResponse
    _default_response_class = ORJSONResponse
except ImportError:
    _default_response_class = JSONResponse

app = FastAPI(title="Cruise Ride API", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None, default_response_class=_default_response_class)

# Pydantic's default 422 handler echoes the request body back inside each
# error's `input` — including the plaintext password and the SSN, which then
# render straight into the client's error banner. Keep the useful part
# (what is missing or invalid), mask the sensitive keys.
from fastapi.exceptions import RequestValidationError as _RequestValidationError
from fastapi.responses import JSONResponse as _JSONResponse

_SENSITIVE_ERROR_KEYS = {
    "password", "new_password", "old_password", "current_password",
    "ssn", "token", "id_token", "access_token", "refresh_token",
}


def _mask_validation_inputs(value):
    if isinstance(value, dict):
        return {
            k: ("***" if str(k).lower() in _SENSITIVE_ERROR_KEYS else _mask_validation_inputs(v))
            for k, v in value.items()
        }
    if isinstance(value, list):
        return [_mask_validation_inputs(v) for v in value]
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    # pydantic v2 packs the raised ValueError into ctx — serialize it, never
    # fail the error response over it.
    return str(value)


@app.exception_handler(_RequestValidationError)
async def _validation_exception_handler(request: Request, exc: _RequestValidationError):
    return _JSONResponse(
        status_code=422,
        content={"detail": _mask_validation_inputs(exc.errors())},
    )

# Configure Socket.io JWT (same secret as REST API)
# Guard: if JWT_SECRET is empty/missing, fail fast with a clear message.
if not JWT_SECRET:
    raise ValueError(
        "JWT_SECRET is not set. Check Railway Variables (or .env for local dev). "
        "This is required for WebSocket authentication."
    )
_configure_socketio(jwt_secret=JWT_SECRET, algorithm=JWT_ALGORITHM)

# Wrap FastAPI with Socket.io ASGI app
socket_app = socketio.ASGIApp(sio, other_asgi_app=app, socketio_path="/socket.io")

# ── Router modules ─────────────────────────────────────────────
from routers.auth import router as auth_router
from routers.trips import router as trips_router
from routers.drivers import router as drivers_router
from routers.dispatch import router as dispatch_router
from routers.support import router as support_router, _rehydrate_pending_reminders
from routers.voice import router as voice_router
from routers.masked_calls import router as masked_calls_router
from routers.payments import router as payments_router
from routers.admin import router as admin_router
from routers.misc import router as misc_router
from routers.scheduled import router as scheduled_router
from routers.referrals import router as referrals_router
from routers.driver_referrals import (
    router as driver_referrals_router,
    expire_stale_driver_referrals,
)
from routers.vip import router as vip_router
from routers.system import router as system_router
from routers.uploads import router as uploads_router
from routers.webhooks import router as webhooks_router
from routers.worker import router as worker_router
from routers.legal import router as legal_router
from routers.zero_tolerance import router as zero_tolerance_router
from services.event_bus import event_bus

app.include_router(auth_router)
app.include_router(trips_router)
app.include_router(drivers_router)
app.include_router(dispatch_router)
app.include_router(support_router)
app.include_router(voice_router)
app.include_router(masked_calls_router)
app.include_router(payments_router)
app.include_router(admin_router)
app.include_router(misc_router)
app.include_router(scheduled_router)
app.include_router(referrals_router)
app.include_router(driver_referrals_router)
app.include_router(vip_router)
app.include_router(system_router)
app.include_router(uploads_router)
app.include_router(webhooks_router)
app.include_router(worker_router)
app.include_router(legal_router)
app.include_router(zero_tolerance_router)

# Serve static legal documents (FCRA Summary of Rights PDF, disclosures, etc.)
app.mount(
    "/static",
    StaticFiles(directory=os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")),
    name="static",
)

# ═══════════════════════════════════════════════════════
#  8 LAYERS OF SECURITY PROTECTION
# ═══════════════════════════════════════════════════════

# -- LAYER 1: CORS — Allow mobile-app + known web origins ----
# Mobile apps (Flutter) don't send browser-origin headers; CORS does not
# protect native traffic.  Real security is in L5-L10 (API key, HMAC, JWT).
# SECURITY FIX: localhost origins are ONLY included when DEBUG=1 is set AND
# ENV is not production. This prevents accidental exposure if DEBUG=1 is
# accidentally set in production.
_is_production = os.getenv("ENV", "").lower() == "production"
_is_debug_cors = (
    not _is_production
    and os.getenv("DEBUG", "").lower() in ("1", "true", "yes")
)
if os.getenv("CORS_ORIGINS"):
    _CORS_ORIGINS = [o.strip() for o in os.getenv("CORS_ORIGINS", "").split(",") if o.strip()]
else:
    _CORS_ORIGINS = [
        "https://www.cruiseinride.com",
        "https://cruiseinride.com",
        "https://cruiseapp2-production.up.railway.app",
        # Dispatch admin panel served locally with `flutter run -d web-server`
        "http://localhost:8080",
        "http://127.0.0.1:8080",
    ]
    if _is_debug_cors:
        _CORS_ORIGINS.extend(["http://localhost:3000", "http://localhost:8000"])
app.add_middleware(GZipMiddleware, minimum_size=1000, compresslevel=4)
# Any localhost port, not just 8080.
#
# The Flutter app now runs in a browser for design review, and `flutter run`
# picks a different port every time unless it is pinned. Hardcoding one port
# meant the first thing the reviewer saw was "Connection error — is the
# server running?", which is a CORS rejection wearing the wrong label.
#
# The origin is still restricted to loopback: a page has to be served from
# the reviewer's own machine to match, which is the same trust boundary the
# existing localhost:8080 entry already assumed.
_CORS_LOCALHOST_RE = r"http://(localhost|127\.0\.0\.1)(:\d+)?"

# -- LAYER 2: Security Headers -------------------------
# Paths served to browsers (dispatch dashboard, photos, uploads)
_BROWSER_PATHS = ("/dispatch", "/photos", "/uploads")

@app.middleware("http")
async def security_headers_middleware(request: Request, call_next):
    # Let CORS middleware handle OPTIONS preflight requests
    if request.method == "OPTIONS":
        return await call_next(request)
    response = await call_next(request)
    _path = request.url.path
    response.headers["X-Content-Type-Options"] = "nosniff"
    # API paths (mobile app) + Socket.io — minimal headers, skip CSP/HSTS/cache overhead
    if _path.startswith("/api/") or _path.startswith("/auth/") or _path.startswith("/drivers/") or _path.startswith("/dispatch/") or _path.startswith("/trips/") or _path.startswith("/socket.io") or _is_hot_path(_path):
        return response
    # Browser-facing paths — full security headers
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Permissions-Policy"] = "geolocation=(), camera=(), microphone=()"
    if any(_path.startswith(p) for p in _BROWSER_PATHS):
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self' 'unsafe-inline'; "
            "style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data: blob: *; "
            "media-src 'self' blob: *; "
            "connect-src 'self' *; "
            "frame-ancestors 'none'"
        )
    else:
        response.headers["Content-Security-Policy"] = "default-src 'none'; frame-ancestors 'none'"
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    response.headers["Connection"] = "keep-alive"
    return response

# -- LAYER 3: Rate Limiting (per-IP, anti-DDoS) --------
_RATE_LIMIT = 3000        # max requests per IP per window (1500+ users + SSE + polling)
_RATE_WINDOW = 60         # per this many seconds

@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):
    # Let CORS middleware handle OPTIONS preflight requests
    if request.method == "OPTIONS":
        return await call_next(request)
    client_ip = request.client.host if request.client else "unknown"
    # IP blacklist check (merged — avoid extra middleware hop)
    if client_ip in _ip_blacklist:
        return JSONResponse({"detail": "Access denied"}, status_code=403)
    _path = request.url.path
    # Skip rate limiting for SSE streams, Socket.io, hot paths, and health checks
    if _path.endswith("/stream") or _path.startswith("/socket.io") or _is_hot_path(_path):
        return await call_next(request)
    # Skip tiered limits for health/docs/static (they don't need per-endpoint throttling)
    if _path not in ("/ping", "/docs", "/openapi.json"):
        # ── Tiered rate limiting (stricter for auth, moderate for general API) ──
        # This runs BEFORE the global DDoS cap below and provides per-category limits.
        # The limiter may be sync (in-memory) or async (Redis) — handle both.
        try:
            if "/auth/" in _path:
                # Auth endpoints: 20 req/min per IP (prevents brute-force/OTP spam)
                _check = _tiered_rate_limiter.check(f"auth:{client_ip}", max_requests=20, window_seconds=60)
            elif "/payments/" in _path or "/webhooks/" in _path:
                # Payment endpoints: 30 req/min per IP (prevents charge spam)
                _check = _tiered_rate_limiter.check(f"pay:{client_ip}", max_requests=30, window_seconds=60)
            else:
                # General API: 100 req/min per IP
                _check = _tiered_rate_limiter.check(f"api:{client_ip}", max_requests=100, window_seconds=60)
            # Await if the limiter is async (Redis backend), otherwise it's already done
            if inspect.isawaitable(_check):
                await _check
        except HTTPException:
            # Re-raise 429 from tiered limiter as a JSONResponse
            return JSONResponse({"detail": "Too many requests. Please try again later."}, status_code=429)
    # ── Global DDoS cap (Layer 3 — all endpoints, high ceiling) ──
    # Uses the same limiter backend as tiered limits so Redis is enforced
    # in multi-instance deployments when REDIS_URL is configured.
    try:
        _check = _tiered_rate_limiter.check(
            f"ddos:{client_ip}", max_requests=_RATE_LIMIT, window_seconds=_RATE_WINDOW
        )
        if inspect.isawaitable(_check):
            await _check
    except HTTPException:
        return JSONResponse({"detail": "Rate limit exceeded"}, status_code=429)
    return await call_next(request)



# -- LAYER 4: Request Size Limit (anti-payload bomb) ---
_MAX_BODY_SIZE = 5 * 1024 * 1024  # 5 MB max (photos are ~1-2MB base64)
_MAX_VERIFY_SIZE = 30 * 1024 * 1024  # 30 MB for verification (photos + video)
_LARGE_BODY_PATHS = {"/auth/verify-request", "/drivers/documents", "/drivers/documents/upload"}

@app.middleware("http")
async def request_size_limit_middleware(request: Request, call_next):
    # GET/HEAD/OPTIONS/Socket.io/hot paths never have meaningful bodies — skip entirely
    if request.method in ("GET", "HEAD", "OPTIONS") or request.url.path.startswith("/socket.io") or _is_hot_path(request.url.path):
        return await call_next(request)
    limit = _MAX_VERIFY_SIZE if request.url.path in _LARGE_BODY_PATHS else _MAX_BODY_SIZE
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            if int(content_length) > limit:
                return JSONResponse({"detail": "Request body too large"}, status_code=413)
        except ValueError:
            return JSONResponse({"detail": "Invalid content-length"}, status_code=400)
    return await call_next(request)


# Hot paths that should skip expensive middleware operations (checksum, etc.)
_HOT_PATHS = {
    "/dispatch/driver/pending", "/drivers/nearby", "/health", "/ping",
    "/dispatch/trip/status", "/auth/me", "/auth/account-status",
    "/dispatch/driver/pending/stream",  # SSE stream for drivers
    "/drivers/vehicle", "/drivers/earnings",
    "/dispatch/driver/accept", "/dispatch/driver/reject",
}
_SSE_PREFIX = "/dispatch/driver/pending/stream", "/dispatch/trip/"
_LOCATION_PREFIX = "/drivers/"  # matches /drivers/{id}/location
_PHOTO_PREFIX = "/dispatch/user/"  # matches /dispatch/user/{id}/photo

def _is_hot_path(path: str) -> bool:
    """Fast check: returns True for high-frequency paths that should skip heavy middleware."""
    return (path in _HOT_PATHS
            or any(path.startswith(p) for p in _SSE_PREFIX)
            or (path.startswith(_LOCATION_PREFIX) and path.endswith("/location"))
            or path.startswith(_PHOTO_PREFIX))

@app.middleware("http")
async def crash_protection_middleware(request: Request, call_next):
    try:
        return await call_next(request)
    except Exception as e:
        import traceback as _tb
        client_ip = request.client.host if request.client else "unknown"
        logging.error("[CRASH] Unhandled error from %s on %s: %s\n%s", client_ip, request.url.path, str(e), _tb.format_exc())
        _security_audit_log("crash", client_ip, f"Unhandled: {request.url.path}")
        return JSONResponse(
            {"detail": "Internal server error"},
            status_code=500,
        )


# -- CORS, registered LAST so it is the OUTERMOST middleware --------------
#
# Starlette builds the stack so the last-added middleware runs outermost.
# CORS used to be added before the four @app.middleware("http") handlers
# above, which put it *inside* them — so every response those return
# without calling call_next (403 blacklist, 429 rate limit, 413 body too
# large, 500 crash) went to the browser with no Access-Control-Allow-Origin
# on it.
#
# A browser rejects such a response outright. The client never sees the
# status, so a 500 and a dead server are indistinguishable to it, and the
# app reports both as "Connection error — is the server running?". A real
# 500 on /auth/login was invisible for exactly this reason: the server was
# answering, the answer was just unreadable.
#
# Registered here, every response leaves through CORS, including the ones
# that never reached a route.
app.add_middleware(
    CORSMiddleware,
    allow_origins=_CORS_ORIGINS,
    allow_origin_regex=_CORS_LOCALHOST_RE,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-Api-Key", "X-Timestamp", "X-Nonce", "X-Signature", "X-Device-FP", "X-Client-Version"],
)


@app.get("/ping")
async def ping():
    """Ultra-fast connectivity check — no DB, no auth, no overhead."""
    return {"status": "ok"}


def _api_key_ok(provided: str) -> bool:
    """Constant-time API key check.

    `provided != API_KEY` returns as soon as two bytes differ, so how long the
    comparison takes tells the caller how much of the key they got right — a
    key is guessable one character at a time from timing alone. compare_digest
    always looks at everything.

    An unset API_KEY denies. utils.security refuses to boot without one, so
    this should be unreachable — but the comparison it replaces would have
    GRANTED in that state ("" != "" is False, i.e. a request with no key at
    all passing the check), and a fallback should fail the safe way.
    """
    if not API_KEY:
        return False
    return hmac.compare_digest(str(provided or ""), str(API_KEY))

# -- Full Diagnostics Endpoint --------------------------------------------
# NOTE: this used to be registered on "/health", but routers/system.py also
# declares GET /health and is included first (see include_router above), so
# FastAPI silently kept system.py's deep check and this handler never ran.
# Moved to /health/full — same family as /health/security and /health/guardian.
@app.get("/health/full")
async def health_full(x_api_key: str = Header(default="")):
    # Fast path: public response — no DB, instant
    if not _api_key_ok(x_api_key):
        return {
            "status": "ok",
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

    # Slow path: private healthcheck with full diagnostics — requires API key
    db_status = "ok"
    db_latency_ms = 0.0
    try:
        t0 = time.time()
        async with asyncio.timeout(2):
            async with SessionLocal() as db:
                await db.execute(text("SELECT 1"))
        db_latency_ms = round((time.time() - t0) * 1000, 1)
    except Exception as e:
        db_status = f"error: {str(e)[:80]}"

    uptime_s = int((datetime.now(timezone.utc) - _SERVER_START_TIME).total_seconds())
    overall = "ok" if db_status == "ok" else "degraded"

    public_response = {
        "status": overall,
        "version": "2.0",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

    # Private response — full details (API key already verified above)
    firebase_usable = False
    if _HAS_FIRESTORE:
        try:
            firebase_usable = firestore_sync._db is not None
        except Exception:
            pass
    uptime_str = f"{uptime_s // 3600}h {(uptime_s % 3600) // 60}m {uptime_s % 60}s"
    return {
        "status": overall,
        "version": "2.0",
        "uptime": uptime_str,
        "uptime_seconds": uptime_s,
        "database": {"status": db_status, "latency_ms": db_latency_ms},
        "firebase": {
            "imported": _HAS_FIRESTORE,
            "db_initialized": firebase_usable,
            "status": "ok" if firebase_usable else ("imported_but_no_creds" if _HAS_FIRESTORE else "disabled"),
        },
        "watchdog": _watchdog_stats,
        "security": security_guardian.get_status(),
        "guardian": guardian_agent.get_status(),
        "backup": _backup_status(),
        "ghost_driver_agent": ghost_driver_agent.get_status(),
        "safety_monitor_agent": safety_monitor_agent.get_status(),
        "document_expiry_agent": document_expiry_agent.get_status(),
        "background_recheck_agent": background_recheck_agent.get_status(),
        "document_approval_agent": document_approval_agent.get_status(),
        "rating_moderator_agent": rating_moderator_agent.get_status(),
        "chat_retention_agent": chat_retention_agent.get_status(),
        "sse": event_bus.get_stats(),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

# -- Security Guardian Health Endpoint ------------------------------------
@app.get("/health/security")
async def security_health(x_api_key: str = Header(default="")):
    """Security Guardian status — detailed threat monitoring info.
    Protected by API key for production safety."""
    if not _api_key_ok(x_api_key):
        raise HTTPException(403, "Forbidden")
    
    status = security_guardian.get_status()
    status["rate_limiter_details"] = {
        "max_requests_per_minute": security_guardian.rate_limiter.MAX_REQUESTS_PER_MINUTE,
        "max_requests_per_second": security_guardian.rate_limiter.MAX_REQUESTS_PER_SECOND,
        "max_auth_attempts_per_hour": security_guardian.rate_limiter.MAX_AUTH_ATTEMPTS_PER_HOUR,
        "block_duration_seconds": security_guardian.rate_limiter.BLOCK_DURATION_SECONDS,
    }
    return status

# -- Guardian Agent Health Endpoint ----------------------------------------
@app.get("/health/guardian")
async def guardian_health(x_api_key: str = Header(default="")):
    """Guardian Agent status — system health, connections, memory, data integrity.
    Protected by API key for production safety."""
    if not _api_key_ok(x_api_key):
        raise HTTPException(403, "Forbidden")
    
    return guardian_agent.get_status()

# -- Autonomous Agents Health Endpoints ------------------------------------
@app.get("/health/agents")
async def agents_health(x_api_key: str = Header(default="")):
    """All autonomous agents status — ghost cleanup, safety, docs, ratings.
    Protected by API key for production safety."""
    if not _api_key_ok(x_api_key):
        raise HTTPException(403, "Forbidden")
    return {
        "ghost_driver": ghost_driver_agent.get_status(),
        "safety_monitor": safety_monitor_agent.get_status(),
        "document_expiry": document_expiry_agent.get_status(),
        "background_recheck": background_recheck_agent.get_status(),
        "document_approval": document_approval_agent.get_status(),
        "rating_moderator": rating_moderator_agent.get_status(),
        "chat_retention": chat_retention_agent.get_status(),
    }

# -- One-time migration endpoint (protected by API key) ------------------
@app.post("/admin/run-migrations")
async def run_migrations(x_api_key: str = Header(default="")):
    """Run PostgreSQL column migrations manually. Call once to fix missing columns."""
    if not _api_key_ok(x_api_key):
        raise HTTPException(403, "Forbidden")
    if IS_SQLITE:
        return {"ok": False, "message": "Only needed for PostgreSQL"}
    results = []
    try:
        async with engine.begin() as conn:
            await _migrate_postgres(conn)
        results.append("migrations completed")
    except Exception as e:
        results.append(f"error: {e}")
    return {"ok": True, "results": results}

# -- Emergency schema creation endpoint (protected by API key) -----------
@app.post("/admin/create-schema")
async def create_schema(x_api_key: str = Header(default="")):
    """Create all database tables from scratch. EMERGENCY USE ONLY."""
    if not _api_key_ok(x_api_key):
        raise HTTPException(403, "Forbidden")
    if IS_SQLITE:
        return {"ok": False, "message": "Only needed for PostgreSQL"}
    
    results = []
    try:
        from sqlalchemy import create_engine
        from db_url import resolve_database_url
        sync_url = resolve_database_url(async_driver=False)
        for prefix in ("postgresql+asyncpg://", "postgresql+psycopg://", "postgres://"):
            if sync_url.startswith(prefix):
                sync_url = "postgresql://" + sync_url[len(prefix):]
                break
        
        sync_engine = create_engine(
            sync_url,
            echo=False,
            connect_args={"sslmode": "require", "connect_timeout": 15, "options": "-c search_path=public"},
        )
        
        with sync_engine.begin() as sync_conn:
            sync_conn.execute(text("SET search_path TO public"))
            Base.metadata.create_all(sync_conn, checkfirst=True)
            results.append("All tables created successfully")
        
        sync_engine.dispose()
        
        # Run migrations to add indexes and constraints
        async with engine.begin() as conn:
            await _migrate_postgres(conn)
            results.append("Migrations completed")
        
        return {"ok": True, "results": results}
    except Exception as e:
        logging.error("Schema creation failed: %s", e, exc_info=True)
        return {"ok": False, "error": str(e)}

# -------------------------------------------------------
#  SCHEDULED RIDE AUTO-DISPATCH (background task)
# -------------------------------------------------------

async def _scheduled_ride_dispatcher():
    """Smart dispatcher for scheduled rides -- sends offers at the right time.

    Dispatch timing based on how far ahead the booking is:
      * <= 30 min until ride   -> dispatch immediately (urgent)
      * 30 min - 3 hours       -> dispatch when <= 60 min remain
      * 3+ hours               -> dispatch when <= 120 min remain

    Rides that pass their scheduled time by >5 min with no driver are
    auto-cancelled and the rider is notified.
    """
    while True:
        await asyncio.sleep(60)  # Check every minute
        try:
            async with SessionLocal() as db:
                now = datetime.now(timezone.utc)

                # Find all scheduled rides that need dispatching
                # (status = "scheduled", no driver assigned yet)
                result = await db.execute(
                    select(Trip).where(
                        and_(
                            Trip.status == "scheduled",
                            Trip.scheduled_at.isnot(None),
                            Trip.driver_id.is_(None),
                        )
                    )
                )
                trips = result.scalars().all()

                for trip in trips:
                    minutes_until = (trip.scheduled_at - now).total_seconds() / 60

                    # --------------------------------------------------
                    # Expired: ride is more than 5 min past scheduled time
                    # --------------------------------------------------
                    if minutes_until < -5:
                        _prev = trip.status
                        trip.status = "cancelled"
                        trip.cancel_reason = "auto:scheduler_expired_no_driver"
                        trip.updated_at = datetime.now(timezone.utc)
                        # Release the payment hold NOW instead of letting it
                        # pin the rider's card for ~7 days (2026-08-05).
                        try:
                            from routers.trips import _release_or_capture_fee_on_cancel
                            trip.payment_status = await _release_or_capture_fee_on_cancel(trip)
                        except Exception as _hold_err:
                            logging.warning("[AutoCancel/Scheduler] hold settle failed trip=%d: %s", trip.id, _hold_err)
                        await db.commit()
                        logging.warning(
                            "[AutoCancel/Scheduler] trip=%d prev_status=%r driver_id=%s "
                            "scheduled_at=%s (%.0f min past) — no driver picked it up",
                            trip.id, _prev, trip.driver_id,
                            trip.scheduled_at.isoformat() if trip.scheduled_at else None,
                            abs(minutes_until),
                        )
                        # Notify rider
                        try:
                            rider_r = await db.execute(
                                select(User).where(User.id == trip.rider_id)
                            )
                            rider = rider_r.scalar_one_or_none()
                            if rider and rider.fcm_token:
                                _send_fcm_push(
                                    token=rider.fcm_token,
                                    title="Scheduled ride cancelled",
                                    body="We could not find a driver for your scheduled ride. Please try requesting a new ride.",
                                    data={"type": "scheduled_canceled", "trip_id": str(trip.id)},
                                )
                        except Exception as _fcm_err:
                            logging.warning("[Scheduler] FCM notify rider failed for trip %d: %s", trip.id, _fcm_err)
                        # Update Firestore
                        if _HAS_FIRESTORE:
                            try:
                                # Canonical spelling, two Ls — the same one the
                                # sync_scheduled_ride call below already uses and the
                                # one every client string-compares against.
                                # firestore_sync normalises the one-L form, but the
                                # caller should not be relying on that.
                                firestore_sync.sync_trip_status(trip.id, "cancelled")
                                firestore_sync.sync_scheduled_ride(
                                    trip_id=trip.id, rider_id=trip.rider_id,
                                    status="cancelled",
                                )
                            except Exception:
                                pass
                        continue

                    # --------------------------------------------------
                    # Determine if it is time to dispatch this offer
                    #
                    # The original scheduled_at determines the "booking
                    # lead time" but the loop fires every 60 s, so we
                    # only care about how many minutes remain RIGHT NOW.
                    #
                    #   <= 30 min remain  -> dispatch (urgent)
                    #   <= 60 min remain  -> dispatch (normal)
                    #   <= 120 min remain -> dispatch (early, for long bookings)
                    #
                    # We always dispatch once <= 60 min remain.  For
                    # bookings originally >3 h out we start at 120 min.
                    # --------------------------------------------------
                    should_dispatch = False
                    if minutes_until <= 30:
                        # <= 30 min away -> dispatch NOW (urgent)
                        should_dispatch = True
                    elif minutes_until <= 60:
                        # 30-60 min away -> dispatch (standard window)
                        should_dispatch = True
                    elif minutes_until <= 120:
                        # 60-120 min away -> dispatch only for rides that
                        # were originally booked 3+ hours in advance
                        # (i.e. created_at is well before scheduled_at)
                        original_lead = (trip.scheduled_at - trip.created_at).total_seconds() / 60 if trip.created_at else 0
                        if original_lead >= 180:
                            should_dispatch = True

                    if not should_dispatch:
                        continue

                    # --------------------------------------------------
                    # Re-verify the payment hold before dispatching.
                    # Issuer holds expire (~7 days), so a ride booked far
                    # ahead can reach dispatch time with a dead hold:
                    # re-authorize off-session for the current total; if
                    # the card declines, cancel WITHOUT fee and push the
                    # rider to update their payment method.
                    # --------------------------------------------------
                    if trip.stripe_payment_intent_id and trip.payment_status == "held":
                        from config import _HAS_STRIPE, _stripe_mod
                        if _HAS_STRIPE:
                            try:
                                _existing_pi = _stripe_mod.PaymentIntent.retrieve(
                                    trip.stripe_payment_intent_id)
                                _pi_ok = getattr(_existing_pi, "status", "") == "requires_capture"
                            except Exception as _pi_err:
                                logging.warning(
                                    "[Scheduler] hold retrieve failed trip=%d: %s", trip.id, _pi_err)
                                _pi_ok = False
                            if not _pi_ok:
                                _reauthed = False
                                try:
                                    pm_r = await db.execute(
                                        select(RiderPaymentMethod).where(
                                            RiderPaymentMethod.user_id == trip.rider_id,
                                            RiderPaymentMethod.method_type == "stripe_card",
                                            RiderPaymentMethod.stripe_pm_id.isnot(None),
                                        ).order_by(
                                            RiderPaymentMethod.is_default.desc(),
                                            RiderPaymentMethod.created_at.asc(),
                                        )
                                    )
                                    _pm = pm_r.scalars().first()
                                    if not _pm:
                                        raise ValueError("no saved card")
                                    rider_r = await db.execute(
                                        select(User).where(User.id == trip.rider_id))
                                    _rider_row = rider_r.scalar_one_or_none()
                                    _customer_id = getattr(_rider_row, "stripe_customer_id", None)
                                    _new_pi = _stripe_mod.PaymentIntent.create(
                                        amount=max(int(round(float(trip.fare or 0) * 100)), 50),
                                        currency="usd",
                                        payment_method=_pm.stripe_pm_id,
                                        **({"customer": _customer_id} if _customer_id else {}),
                                        confirm=True,
                                        off_session=True,
                                        capture_method="manual",
                                        automatic_payment_methods={
                                            "enabled": True, "allow_redirects": "never"},
                                        metadata={
                                            "trip_id": str(trip.id),
                                            "rider_id": str(trip.rider_id),
                                            "kind": "scheduled_reauth"},
                                    )
                                    if _new_pi.status != "requires_capture":
                                        raise ValueError(f"re-auth status {_new_pi.status}")
                                    trip.stripe_payment_intent_id = _new_pi.id
                                    trip.payment_status = "held"
                                    await db.commit()
                                    _reauthed = True
                                    logging.info(
                                        "[Scheduler] trip=%d hold re-authorized off-session (pi=%s)",
                                        trip.id, _new_pi.id)
                                except Exception as _reauth_err:
                                    logging.warning(
                                        "[Scheduler] trip=%d hold re-auth DECLINED: %s — cancelling without fee",
                                        trip.id, _reauth_err)
                                if not _reauthed:
                                    trip.status = "cancelled"
                                    trip.cancel_reason = "payment_declined"
                                    trip.payment_status = "cancelled"
                                    trip.updated_at = datetime.now(timezone.utc)
                                    await db.commit()
                                    try:
                                        rider_r = await db.execute(
                                            select(User).where(User.id == trip.rider_id))
                                        rider = rider_r.scalar_one_or_none()
                                        if rider and rider.fcm_token:
                                            _send_fcm_push(
                                                token=rider.fcm_token,
                                                title="Scheduled ride cancelled",
                                                body="Your payment method was declined. Please update it and book again.",
                                                data={"type": "scheduled_canceled", "trip_id": str(trip.id)},
                                            )
                                    except Exception as _fcm_err:
                                        logging.warning("[Scheduler] FCM notify rider failed for trip %d: %s", trip.id, _fcm_err)
                                    if _HAS_FIRESTORE:
                                        try:
                                            firestore_sync.sync_trip_status(trip.id, "cancelled")
                                            firestore_sync.sync_scheduled_ride(
                                                trip_id=trip.id, rider_id=trip.rider_id,
                                                status="cancelled",
                                            )
                                        except Exception:
                                            pass
                                    continue

                    # --------------------------------------------------
                    # Find nearest online driver
                    # --------------------------------------------------
                    drivers_r = await db.execute(
                        select(User).where(
                            User.role == "driver",
                            User.is_online == True,
                            User.status.in_(ACTIVE_ACCOUNT_STATUSES),
                        )
                    )
                    drivers = drivers_r.scalars().all()
                    if not drivers:
                        continue

                    best = None
                    best_dist = float("inf")
                    for d in drivers:
                        if d.lat and d.lng:
                            dist = _haversine(
                                trip.pickup_lat, trip.pickup_lng,
                                d.lat, d.lng,
                            )
                            if dist < best_dist:
                                best_dist = dist
                                best = d

                    if best and best_dist < 50:  # Within 50 km
                        # Create dispatch offer
                        offer = DispatchOffer(
                            trip_id=trip.id, driver_id=best.id, status="pending",
                        )
                        db.add(offer)
                        trip.status = "requested"
                        trip.driver_id = best.id
                        await db.commit()

                        is_urgent = minutes_until <= 30
                        logging.info(
                            "[Scheduler] Dispatched scheduled trip %d to driver %d "
                            "(%.1f km away, %.0f min until ride%s)",
                            trip.id, best.id, best_dist, minutes_until,
                            ", URGENT" if is_urgent else "",
                        )

                        # Notify driver via FCM
                        if best.fcm_token:
                            try:
                                driver_name = (best.first_name or "").strip() or "Conductor"
                                pickup = trip.pickup_address or "punto de recogida"
                                urgency_text = (
                                    "URGENTE: " if is_urgent else ""
                                )
                                _send_fcm_push(
                                    token=best.fcm_token,
                                    title=f"{urgency_text}Viaje reservado asignado",
                                    body=f"{driver_name}, tienes un viaje programado hacia {pickup} en {int(minutes_until)} minutos.",
                                    data={
                                        "type": "scheduled_offer",
                                        "trip_id": str(trip.id),
                                        "urgent": "true" if is_urgent else "false",
                                    },
                                    is_offer=True,
                                )
                            except Exception as _fcm_err:
                                logging.warning(
                                    "[Scheduler] FCM notify driver failed for trip %d: %s",
                                    trip.id, _fcm_err,
                                )

                        # Sync to Firestore scheduled_rides collection
                        if _HAS_FIRESTORE:
                            try:
                                firestore_sync.sync_scheduled_ride(
                                    trip_id=trip.id,
                                    rider_id=trip.rider_id,
                                    status="assigned",
                                    driver_id=best.id,
                                    driver_name=f"{best.first_name or ''} {best.last_name or ''}".strip(),
                                    driver_phone=best.phone or "",
                                    scheduled_at=trip.scheduled_at,
                                    pickup_address=trip.pickup_address or "",
                                    dropoff_address=trip.dropoff_address or "",
                                    pickup_lat=trip.pickup_lat or 0,
                                    pickup_lng=trip.pickup_lng or 0,
                                    dropoff_lat=trip.dropoff_lat or 0,
                                    dropoff_lng=trip.dropoff_lng or 0,
                                    fare=trip.fare or 0,
                                )
                            except Exception as _fs_err:
                                logging.warning(
                                    "[Scheduler] Firestore sync_scheduled_ride failed for trip %d: %s",
                                    trip.id, _fs_err,
                                )

        except Exception as e:
            logging.error("[Scheduler] Error in scheduled ride dispatcher: %s", e)


# -------------------------------------------------------
#  SCHEDULED RIDES AVAILABLE NOTIFIER (background task)
# -------------------------------------------------------

async def _scheduled_rides_available_notify_loop():
    """Every 30 minutes, notify online drivers who have no active trip
    that there are scheduled rides available matching their vehicle type."""
    while True:
        await asyncio.sleep(1800)  # 30 minutes (was 15m) — reduced for NullPool/PgBouncer efficiency
        try:
            async with SessionLocal() as db:
                from sqlalchemy import select as sa_select
                from models import User, Trip

                # Count unclaimed scheduled rides in the next 24h
                now = datetime.now(timezone.utc)
                cutoff = now + timedelta(hours=24)
                sched_result = await db.execute(
                    sa_select(Trip).where(
                        and_(
                            Trip.status == "scheduled",
                            Trip.driver_id.is_(None),
                            Trip.scheduled_at.isnot(None),
                            Trip.scheduled_at > now,
                            Trip.scheduled_at < cutoff,
                        )
                    )
                )
                unclaimed = sched_result.scalars().all()
                if not unclaimed:
                    continue

                count = len(unclaimed)

                # Get online drivers with no active trip and an FCM token
                active_statuses = ["driver_en_route", "arrived", "in_progress",
                                   "scheduled_active", "scheduled_accepted"]
                drivers_result = await db.execute(
                    sa_select(User).where(
                        and_(
                            User.role == "driver",
                            User.is_online == True,
                            User.fcm_token.isnot(None),
                        )
                    )
                )
                online_drivers = drivers_result.scalars().all()

                for driver in online_drivers:
                    # Skip drivers with an active trip
                    active_result = await db.execute(
                        sa_select(Trip).where(
                            and_(
                                Trip.driver_id == driver.id,
                                Trip.status.in_(active_statuses),
                            )
                        )
                    )
                    if active_result.scalars().first():
                        continue

                    if driver.fcm_token:
                        title = f"{count} viaje{'s' if count > 1 else ''} reservado{'s' if count > 1 else ''} disponible{'s' if count > 1 else ''}"
                        body = "Toca para ver los viajes reservados disponibles cerca de ti."
                        _send_fcm_push(
                            driver.fcm_token,
                            title=title,
                            body=body,
                            data={"type": "scheduled_rides_available", "count": str(count)},
                        )

        except Exception as e:
            logging.warning("[ScheduledNotifier] Error: %s", e)


#  SCHEDULED RIDE REMINDER LOOP (background task)
# -------------------------------------------------------

async def _scheduled_ride_reminder_loop():
    """Send timed reminders to drivers and riders who have scheduled rides.

    Reminder schedule (after a driver has accepted):
      * 1 hour before   -> driver reminder
      * 30 minutes before -> driver reminder + rider reminder
      * 15 minutes before -> driver urgent reminder

    Also cancels rides that are >5 min past scheduled time with no pickup.
    Uses an in-memory set per trip to avoid duplicate notifications.
    """
    # Track which reminders have been sent: trip_id -> set of reminder keys
    sent_reminders: dict[int, set[str]] = {}

    while True:
        await asyncio.sleep(60)
        try:
            async with SessionLocal() as db:
                now = datetime.now(timezone.utc)

                # Find trips: scheduled, driver assigned, not yet in progress
                result = await db.execute(
                    select(Trip).where(
                        and_(
                            Trip.scheduled_at.isnot(None),
                            Trip.driver_id.isnot(None),
                            # ONLY scheduled-ride statuses — "requested" and
                            # "driver_en_route" are shared with on-demand trips
                            # and must NOT be cancelled by the scheduled-ride
                            # reminder loop (was causing phantom cancellations).
                            Trip.status.in_(["scheduled", "scheduled_accepted", "scheduled_active"]),
                        )
                    )
                )
                trips = result.scalars().all()

                for trip in trips:
                    minutes_until = (trip.scheduled_at - now).total_seconds() / 60
                    trip_reminders = sent_reminders.setdefault(trip.id, set())

                    # --------------------------------------------------
                    # No-show / expired: >5 min past with no pickup
                    # --------------------------------------------------
                    if minutes_until < -5 and "no_driver_cancel" not in trip_reminders:
                        _prev = trip.status
                        trip.status = "cancelled"
                        trip.cancel_reason = "auto:reminder_past_scheduled_no_pickup"
                        trip.updated_at = datetime.now(timezone.utc)
                        # Same instant hold release as the scheduler path.
                        try:
                            from routers.trips import _release_or_capture_fee_on_cancel
                            trip.payment_status = await _release_or_capture_fee_on_cancel(trip)
                        except Exception as _hold_err:
                            logging.warning("[AutoCancel/Reminder] hold settle failed trip=%d: %s", trip.id, _hold_err)
                        await db.commit()
                        logging.warning(
                            "[AutoCancel/Reminder] trip=%d prev_status=%r driver_id=%s "
                            "scheduled_at=%s (%.0f min past) — driver assigned but never picked up",
                            trip.id, _prev, trip.driver_id,
                            trip.scheduled_at.isoformat() if trip.scheduled_at else None,
                            abs(minutes_until),
                        )
                        # Notify rider
                        try:
                            rider_r = await db.execute(
                                select(User).where(User.id == trip.rider_id)
                            )
                            rider = rider_r.scalar_one_or_none()
                            if rider and rider.fcm_token:
                                _send_fcm_push(
                                    token=rider.fcm_token,
                                    title="Scheduled ride cancelled",
                                    body="We could not find a driver for your scheduled ride. Please try requesting a new ride.",
                                    data={"type": "scheduled_canceled", "trip_id": str(trip.id)},
                                )
                        except Exception as _fcm_err:
                            logging.warning("[Reminder] FCM rider cancel notify failed for trip %d: %s", trip.id, _fcm_err)
                        # Update Firestore
                        if _HAS_FIRESTORE:
                            try:
                                # Canonical spelling, two Ls — the same one the
                                # sync_scheduled_ride call below already uses and the
                                # one every client string-compares against.
                                # firestore_sync normalises the one-L form, but the
                                # caller should not be relying on that.
                                firestore_sync.sync_trip_status(trip.id, "cancelled")
                                firestore_sync.sync_scheduled_ride(
                                    trip_id=trip.id, rider_id=trip.rider_id,
                                    status="cancelled",
                                )
                            except Exception:
                                pass
                        trip_reminders.add("no_driver_cancel")
                        continue

                    # --------------------------------------------------
                    # Fetch driver for push notifications
                    # --------------------------------------------------
                    driver_r = await db.execute(
                        select(User).where(User.id == trip.driver_id)
                    )
                    driver = driver_r.scalar_one_or_none()
                    if not driver or not driver.fcm_token:
                        continue

                    driver_name = (driver.first_name or "").strip() or "Conductor"
                    pickup = trip.pickup_address or "punto de recogida"

                    # --------------------------------------------------
                    # 1-hour reminder (driver only)
                    # --------------------------------------------------
                    if 55 <= minutes_until <= 65 and "1h" not in trip_reminders:
                        _send_fcm_push(
                            token=driver.fcm_token,
                            title="Viaje reservado en 1 hora",
                            body=f"{driver_name}, tienes un viaje programado hacia {pickup} en aproximadamente 1 hora. Preparate para salir a tiempo.",
                            data={"type": "scheduled_reminder", "trip_id": str(trip.id), "reminder": "1h"},
                        )
                        trip_reminders.add("1h")
                        logging.info("[Reminder] 1h reminder sent to driver %d for trip %d", driver.id, trip.id)

                    # --------------------------------------------------
                    # 30-minute reminder + LOCKOUT (driver + rider)
                    # --------------------------------------------------
                    if 25 <= minutes_until <= 35 and "30m" not in trip_reminders:
                        # Transition to scheduled_active (lockout: no more offers)
                        if trip.status == "scheduled_accepted":
                            trip.status = "scheduled_active"
                            await db.commit()
                            logging.info("[Reminder] Trip %d locked: driver %d locked out of new offers", trip.id, driver.id)
                        _send_fcm_push(
                            token=driver.fcm_token,
                            title="Tu viaje comienza en 30 minutos",
                            body=f"{driver_name}, tu viaje reservado comienza en 30 minutos. Ya no recibiras nuevos viajes hasta completar este.",
                            data={"type": "scheduled_lockout", "trip_id": str(trip.id), "reminder": "30m"},
                        )
                        trip_reminders.add("30m")
                        logging.info("[Reminder] 30m reminder sent to driver %d for trip %d", driver.id, trip.id)

                    # Rider 30-minute reminder
                    if 25 <= minutes_until <= 35 and "rider_30m" not in trip_reminders:
                        try:
                            rider_r = await db.execute(
                                select(User).where(User.id == trip.rider_id)
                            )
                            rider = rider_r.scalar_one_or_none()
                            if rider and rider.fcm_token:
                                rider_name = (rider.first_name or "").strip() or "Rider"
                                _send_fcm_push(
                                    token=rider.fcm_token,
                                    title="Your scheduled ride starts soon",
                                    body=f"{rider_name}, your ride starts in 30 minutes. Your driver is on the way.",
                                    data={"type": "scheduled_reminder", "trip_id": str(trip.id), "reminder": "rider_30m"},
                                )
                                trip_reminders.add("rider_30m")
                                logging.info("[Reminder] 30m rider reminder sent to rider %d for trip %d", rider.id, trip.id)
                        except Exception as _fcm_err:
                            logging.warning("[Reminder] FCM rider 30m notify failed for trip %d: %s", trip.id, _fcm_err)

                    # --------------------------------------------------
                    # 15-minute reminder (driver + rider)
                    # --------------------------------------------------
                    if 10 <= minutes_until <= 18 and "15m" not in trip_reminders:
                        _send_fcm_push(
                            token=driver.fcm_token,
                            title="Head to the pickup point now",
                            body=f"{driver_name}, your scheduled ride starts in 15 minutes. Head to {pickup} now to arrive on time.",
                            data={"type": "scheduled_reminder", "trip_id": str(trip.id), "reminder": "15m"},
                        )
                        trip_reminders.add("15m")
                        logging.info("[Reminder] 15m urgent reminder sent to driver %d for trip %d", driver.id, trip.id)

                    # Rider 15-minute reminder — opens tracking screen
                    if 10 <= minutes_until <= 18 and "rider_15m" not in trip_reminders:
                        try:
                            rider_r2 = await db.execute(
                                select(User).where(User.id == trip.rider_id)
                            )
                            rider2 = rider_r2.scalar_one_or_none()
                            if rider2 and rider2.fcm_token:
                                rider_name2 = (rider2.first_name or "").strip() or "Rider"
                                _send_fcm_push(
                                    token=rider2.fcm_token,
                                    title="Your ride starts in 15 minutes",
                                    body=f"{rider_name2}, your driver {driver_name} is on the way. Your scheduled ride starts in 15 minutes.",
                                    data={
                                        "type": "scheduled_trip_starting",
                                        "trip_id": str(trip.id),
                                        "driver_id": str(trip.driver_id),
                                        "driver_name": driver_name,
                                        "pickup_address": pickup,
                                        "reminder": "rider_15m",
                                    },
                                )
                                trip_reminders.add("rider_15m")
                                logging.info("[Reminder] 15m rider reminder sent to rider %d for trip %d", rider2.id, trip.id)
                        except Exception as _fcm_err:
                            logging.warning("[Reminder] FCM rider 15m notify failed for trip %d: %s", trip.id, _fcm_err)

                # --------------------------------------------------
                # RIDER ADVANCE NOTIFICATIONS — scheduled trips with
                # NO driver assigned yet. Nudge the rider at 2h / 1h /
                # 30min windows so they aren't surprised by a late
                # failure to match.
                # --------------------------------------------------
                try:
                    no_driver_result = await db.execute(
                        select(Trip).where(
                            and_(
                                Trip.scheduled_at.isnot(None),
                                Trip.driver_id.is_(None),
                                Trip.status.in_(["scheduled", "requested"]),
                                Trip.scheduled_at > now,
                            )
                        )
                    )
                    no_driver_trips = no_driver_result.scalars().all()
                except Exception as _adv_q_err:
                    logging.warning("[ScheduledAdvance] query error: %s", _adv_q_err)
                    no_driver_trips = []

                for adv_trip in no_driver_trips:
                    adv_minutes = (adv_trip.scheduled_at - now).total_seconds() / 60
                    adv_reminders = sent_reminders.setdefault(adv_trip.id, set())

                    # Skip if outside any relevant window
                    if not (
                        (110 <= adv_minutes <= 130 and "rider_2h" not in adv_reminders)
                        or (50 <= adv_minutes <= 70 and "rider_1h" not in adv_reminders)
                        or (20 <= adv_minutes <= 40 and "rider_30min" not in adv_reminders)
                    ):
                        continue

                    # Fetch rider
                    try:
                        adv_rider_r = await db.execute(
                            select(User).where(User.id == adv_trip.rider_id)
                        )
                        adv_rider = adv_rider_r.scalar_one_or_none()
                    except Exception as _rf:
                        logging.warning("[ScheduledAdvance] rider fetch failed trip=%d: %s", adv_trip.id, _rf)
                        continue
                    if not adv_rider or not adv_rider.fcm_token:
                        continue

                    # 2-hour advance notification
                    if 110 <= adv_minutes <= 130 and "rider_2h" not in adv_reminders:
                        try:
                            _send_fcm_push(
                                token=adv_rider.fcm_token,
                                title="Buscando conductor / Searching for driver",
                                body=(
                                    "Seguimos buscando un conductor para tu viaje reservado. "
                                    "Still looking for a driver for your scheduled ride."
                                ),
                                data={
                                    "type": "scheduled_searching",
                                    "trip_id": str(adv_trip.id),
                                    "window": "2h",
                                },
                            )
                            adv_reminders.add("rider_2h")
                            logging.info("[ScheduledAdvance] 2h trip=%d", adv_trip.id)
                        except Exception as _fe:
                            logging.warning("[ScheduledAdvance] 2h FCM failed trip=%d: %s", adv_trip.id, _fe)

                    # 1-hour advance notification
                    if 50 <= adv_minutes <= 70 and "rider_1h" not in adv_reminders:
                        try:
                            _send_fcm_push(
                                token=adv_rider.fcm_token,
                                title="Aún buscando conductor / Still searching",
                                body=(
                                    "Aún buscando conductor — si no encontramos te avisaremos. "
                                    "Still searching — we'll let you know if we can't find one."
                                ),
                                data={
                                    "type": "scheduled_searching",
                                    "trip_id": str(adv_trip.id),
                                    "window": "1h",
                                },
                            )
                            adv_reminders.add("rider_1h")
                            logging.info("[ScheduledAdvance] 1h trip=%d", adv_trip.id)
                        except Exception as _fe:
                            logging.warning("[ScheduledAdvance] 1h FCM failed trip=%d: %s", adv_trip.id, _fe)

                    # 30-minute advance notification (HIGH priority prompt)
                    if 20 <= adv_minutes <= 40 and "rider_30min" not in adv_reminders:
                        try:
                            _send_fcm_push(
                                token=adv_rider.fcm_token,
                                title="Sin conductor / No driver found",
                                body=(
                                    "No hemos encontrado conductor. ¿Quieres intentar de nuevo? "
                                    "We couldn't find a driver. Want to try again?"
                                ),
                                data={
                                    "type": "scheduled_no_driver_prompt",
                                    "trip_id": str(adv_trip.id),
                                    "action": "reschedule_or_immediate",
                                },
                                is_offer=True,
                            )
                            adv_reminders.add("rider_30min")
                            logging.info("[ScheduledAdvance] 30min trip=%d", adv_trip.id)
                        except Exception as _fe:
                            logging.warning("[ScheduledAdvance] 30min FCM failed trip=%d: %s", adv_trip.id, _fe)

                # ---- Memory cleanup ----
                # Remove entries for trips no longer in the active batch
                active_ids = {t.id for t in trips} | {t.id for t in no_driver_trips}
                for tid in list(sent_reminders.keys()):
                    if tid not in active_ids:
                        sent_reminders.pop(tid, None)

        except Exception as e:
            logging.error("[Reminder] Scheduled ride reminder loop error: %s", e)


# -------------------------------------------------------
#  DRIVER REFERRAL EXPIRY (background task, every 6h)
# -------------------------------------------------------

async def _driver_referral_expiry_loop():
    """Every 12 hours, flip pending DriverReferral rows whose 60-day
    window has elapsed to status='expired'. Pure cleanup — no money
    movement, no notifications. Safe to run concurrently with the trip
    completion hook (each row is independent)."""
    # Brief warmup so we don't compete with boot-time DB activity.
    await asyncio.sleep(180)
    while True:
        try:
            from routers.driver_referrals import expire_stale_driver_referrals
            async with SessionLocal() as db:
                n = await expire_stale_driver_referrals(db)
                if n:
                    logging.info(
                        "[driver_referrals] expired %d stale referral(s)", n
                    )
        except Exception as e:
            logging.warning(
                "[driver_referrals] expiry loop error: %s", e
            )
        await asyncio.sleep(12 * 60 * 60)  # 12 hours (was 6h) — reduced for NullPool/PgBouncer efficiency


# -------------------------------------------------------
#  NIGHTLY MONEY RECONCILIATION (background task)
# -------------------------------------------------------

async def _nightly_reconcile_loop():
    """Once every 24 hours, reconcile each driver's pending_balance against
    the ground-truth computed from trips.driver_earnings and cashouts.

    Reports drift but NEVER auto-fixes — a human must review because the
    root cause could be refund clawback bugs, not a simple ledger drift.
    If drift is significant (>= 3 drivers OR > $50 total), an admin_alerts
    doc is written to Firestore.
    """
    # Warmup — let the server finish booting before hammering the DB
    await asyncio.sleep(300)
    while True:
        try:
            async with SessionLocal() as db:
                # Single roundtrip: LEFT JOIN trips + cashouts per driver
                sql = text(
                    """
                    SELECT
                        u.id AS driver_id,
                        u.first_name,
                        u.last_name,
                        COALESCE(u.pending_balance, 0.0) AS ledger,
                        COALESCE(t.earned, 0.0) AS earned,
                        COALESCE(c.paid, 0.0) AS paid,
                        COALESCE(t.trip_count, 0) AS trip_count,
                        COALESCE(c.cashout_count, 0) AS cashout_count
                    FROM users u
                    LEFT JOIN (
                        SELECT driver_id,
                               SUM(COALESCE(driver_earnings, 0.0)) AS earned,
                               COUNT(*) AS trip_count
                          FROM trips
                         WHERE driver_id IS NOT NULL
                           AND (
                               status = 'completed'
                               OR (status = 'cancelled'
                                   AND driver_earnings IS NOT NULL
                                   AND driver_earnings > 0)
                           )
                         GROUP BY driver_id
                    ) t ON t.driver_id = u.id
                    LEFT JOIN (
                        SELECT user_id,
                               SUM(COALESCE(amount, 0.0)) AS paid,
                               COUNT(*) AS cashout_count
                          FROM cashouts
                         WHERE status != 'failed'
                         GROUP BY user_id
                    ) c ON c.user_id = u.id
                    WHERE u.role = 'driver'
                    """
                )
                rows = (await db.execute(sql)).all()

                checked = 0
                drifted: list[dict] = []
                total_abs_drift = 0.0

                for row in rows:
                    trip_count = int(row.trip_count or 0)
                    cashout_count = int(row.cashout_count or 0)
                    # Skip brand new signups with zero activity
                    if trip_count == 0 and cashout_count == 0:
                        continue

                    checked += 1
                    ledger = float(row.ledger or 0.0)
                    earned = float(row.earned or 0.0)
                    paid = float(row.paid or 0.0)
                    expected = round(earned - paid, 2)
                    drift = round(ledger - expected, 2)

                    if abs(drift) > 0.01:
                        first = (row.first_name or "").strip()
                        last = (row.last_name or "").strip()
                        logging.warning(
                            "[Reconcile] driver=%s name=%s %s ledger=%.2f expected=%.2f drift=%.2f",
                            row.driver_id, first, last, ledger, expected, drift,
                        )
                        drifted.append({
                            "driver_id": int(row.driver_id),
                            "name": f"{first} {last}".strip(),
                            "ledger": ledger,
                            "expected": expected,
                            "drift": drift,
                        })
                        total_abs_drift += abs(drift)

                total_abs_drift = round(total_abs_drift, 2)
                logging.info(
                    "[Reconcile] nightly pass complete - checked=%d drifted=%d total_drift=$%.2f",
                    checked, len(drifted), total_abs_drift,
                )

                # Raise Firestore alert if significant
                if _HAS_FIRESTORE and (len(drifted) >= 3 or total_abs_drift > 50.0):
                    try:
                        alert_id = f"money_reconciliation_{int(datetime.now(timezone.utc).timestamp())}"
                        firestore_sync._db.collection("admin_alerts").document(alert_id).set({
                            "severity": "high",
                            "type": "money_reconciliation",
                            "created_at": datetime.now(timezone.utc).isoformat(),
                            "checked": checked,
                            "drifted_count": len(drifted),
                            "total_abs_drift": total_abs_drift,
                            "drivers": drifted,
                        })
                        logging.warning(
                            "[Reconcile] Firestore admin_alert raised: %s (drifted=%d total=$%.2f)",
                            alert_id, len(drifted), total_abs_drift,
                        )
                    except Exception as _fs_err:
                        logging.error(
                            "[Reconcile] Failed to write Firestore admin_alert: %s", _fs_err,
                        )

        except Exception as e:
            logging.error("[Reconcile] Nightly reconcile loop error: %s", e)

        # 24 hour interval
        await asyncio.sleep(86400)


def _firestore_ping() -> None:
    """One write to the Firestore ping document. Raises if Firestore is down."""
    import firestore_sync as _fs
    _fs._db.collection("_ping").document("watchdog").set(
        {"ts": datetime.now(timezone.utc).isoformat()}, merge=True
    )


def _firestore_force_reconnect() -> None:
    """Ask firestore_sync for a genuine re-initialisation.

    Written against the CONTRACT, not against a particular signature: whether
    the repair is reconnect(), _ensure_init(force=True) or the plain no-op
    _ensure_init(), the caller cannot tell from the return value whether
    anything was actually fixed. The ping afterwards is what decides.
    """
    import firestore_sync as _fs
    reconnect = getattr(_fs, "reconnect", None)
    if callable(reconnect):
        reconnect()
        return
    try:
        _fs._ensure_init(force=True)
    except TypeError:
        # Older signature without the force flag.
        _fs._ensure_init()


async def _connection_watchdog():
    """Monitors DB + Firebase every 30 s and auto-reconnects on failure."""
    await asyncio.sleep(15)  # Give server time to fully start
    while True:
        try:
            # ── DB health check ──────────────────────────
            try:
                async with SessionLocal() as _db:
                    await _db.execute(text("SELECT 1"))
                _watchdog_stats["db_failures"] = 0
            except Exception as _e:
                _watchdog_stats["db_failures"] += 1
                logging.error("[Watchdog] DB unreachable (fail #%d): %s",
                              _watchdog_stats["db_failures"], _e)
                if _watchdog_stats["db_failures"] >= 2:
                    try:
                        await engine.dispose()
                        async with engine.begin() as _conn:
                            await _conn.execute(text("SELECT 1"))
                        _watchdog_stats["db_reconnects"] += 1
                        _watchdog_stats["db_failures"] = 0
                        logging.info("[Watchdog] ✅ DB reconnected (total: %d)",
                                     _watchdog_stats["db_reconnects"])
                    except Exception as _re:
                        logging.error("[Watchdog] ❌ DB reconnect failed: %s", _re)

            # ── Firebase health check ────────────────────
            if _HAS_FIRESTORE:
                try:
                    _firestore_ping()
                    _watchdog_stats["firebase_failures"] = 0
                except Exception as _e:
                    _watchdog_stats["firebase_failures"] += 1
                    logging.error("[Watchdog] Firebase unreachable (fail #%d): %s",
                                  _watchdog_stats["firebase_failures"], _e)
                    if _watchdog_stats["firebase_failures"] >= 2:
                        # Only the ping proves anything. The old code called
                        # _ensure_init(), which returns immediately once the
                        # client exists, then logged "✅ Firebase reconnected"
                        # and cleared the failure counter — so a real outage
                        # repaired nothing, reported success every 30s, and
                        # never counted a single failure again.
                        try:
                            _firestore_force_reconnect()
                            _firestore_ping()
                        except Exception as _re:
                            logging.error("[Watchdog] ❌ Firebase reconnect failed: %s", _re)
                        else:
                            _watchdog_stats["firebase_reconnects"] += 1
                            _watchdog_stats["firebase_failures"] = 0
                            logging.info("[Watchdog] ✅ Firebase reconnected (verified by ping)")
        except Exception as _outer:
            logging.error("[Watchdog] Unexpected error: %s", _outer)

        await asyncio.sleep(30)
# ── Stripe Webhooks ──
# Handled solely by routers/webhooks.py, registered above. There used to be a
# second router here declaring the same POST /webhooks/stripe path: FastAPI
# keeps the first route registered for a path and silently ignores later ones,
# so that module never ran a single event. Two copies of the payment-event
# logic meant a fix landing in the wrong one would do nothing, with no error
# to show for it. The duplicate module has been deleted — do not add another
# router on this path.
# -------------------------------------------------------
#  SERVER STARTUP (if run directly)
# -------------------------------------------------------

if __name__ == "__main__":
    import uvicorn
    logging.info("=" * 60)
    logging.info("CRUISE BACKEND SERVER")
    logging.info("=" * 60)
    logging.info("Started at: %s", datetime.now().strftime('%Y-%m-%d %H:%M:%S'))
    logging.info("Server URL: http://0.0.0.0:8000")
    logging.info("Socket.io:  ws://0.0.0.0:8000/socket.io")
    logging.info("=" * 60)

    uvicorn.run(
        socket_app,
        host="0.0.0.0",
        port=8000,
        log_level="info",
        access_log=True,
        timeout_keep_alive=75,
        limit_concurrency=2000,
        workers=1,
    )
