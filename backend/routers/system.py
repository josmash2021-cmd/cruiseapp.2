"""System administration endpoints — health, metrics, API key rotation."""

import asyncio
import os
import time
import logging
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Header, Request
from pydantic import BaseModel, Field

from utils.security import _verify_api_key, _require_admin, _require_dispatch_auth, _security_audit_log
from models.database import get_db, SessionLocal, AppConfig
from services.query_cache import stats as cache_stats
from middleware.rate_limit import rate_limiter

logger = logging.getLogger(__name__)
router = APIRouter()


# ═══════════════════════════════════════════════════════════════════════
#  Health Check (Deep)
# ═══════════════════════════════════════════════════════════════════════

class HealthResponse(BaseModel):
    status: str
    version: str = "2.0"
    timestamp: str
    checks: dict


# ── Hardening notes for GET /health ───────────────────────────────────
#
# This endpoint is UNAUTHENTICATED and is listed in main.py's _HOT_PATHS,
# which means it bypasses BOTH rate limiters. Anyone who knows the URL can
# loop it. Three consequences had to be closed off:
#
# 1. It blocked the event loop. _check_stripe() and _check_twilio() call
#    SYNCHRONOUS network clients (stripe.Balance.retrieve(),
#    client.api.accounts(sid).fetch()) from inside `async def`, pinning the
#    single uvicorn worker for the full round trip. They now run in a thread
#    with a hard timeout.
# 2. It amplified. One request in became five third-party requests out, on an
#    unthrottled path, burning Stripe/Twilio quota. Results are now cached, so
#    a flood costs at most one dependency sweep per _HEALTH_CACHE_TTL.
# 3. It leaked. Raw exception strings from SQLAlchemy/asyncpg routinely carry
#    host, port, database name and username. The public body now carries only
#    {"ok": bool} per dependency; detail goes to the server log.
#
# Railway's healthcheckPath is /ping (railway.toml), NOT /health, so this
# endpoint is not load-bearing for deploys. The response SHAPE is unchanged
# because something external may be scraping it, and no auth was added for
# the same reason - main.py's /health/full remains the API-key-gated place
# to get detail.
_HEALTH_CACHE_TTL = 30.0   # seconds; dependency results reused this long
_DEP_TIMEOUT = 2.0         # seconds; per-dependency ceiling

_health_cache: Optional[dict] = None
_health_cache_at: float = 0.0
_health_lock = asyncio.Lock()


def _public_checks(checks: dict) -> dict:
    """Strip internal detail from dependency results.

    Any entry carrying an "ok" flag is reduced to exactly {"ok": bool}, which
    drops "error" (raw exception text: DSNs, credentials, hostnames) and
    "project_id". Entries without an "ok" key - cache, rate_limiter - are
    pure counters and pass through so the response shape is preserved.
    """
    public: dict = {}
    for name, result in checks.items():
        if isinstance(result, dict) and "ok" in result:
            public[name] = {"ok": bool(result.get("ok"))}
        else:
            public[name] = result
    return public


def _log_check_failures(checks: dict) -> None:
    """Log dependency failure detail server-side (once per cache refresh)."""
    for name, result in checks.items():
        if isinstance(result, dict) and result.get("ok") is False:
            logger.warning(
                "[Health] dependency %s unhealthy: %s",
                name, str(result.get("error", "unknown"))[:200],
            )


async def _dependency_checks() -> dict:
    """Return dependency results, cached for _HEALTH_CACHE_TTL seconds.

    Single-flight: concurrent callers arriving on a cold cache wait on the
    lock and reuse one sweep rather than each firing their own.
    """
    global _health_cache, _health_cache_at

    now = time.monotonic()
    cached = _health_cache
    if cached is not None and (now - _health_cache_at) < _HEALTH_CACHE_TTL:
        return cached

    async with _health_lock:
        # Re-check: another caller may have refreshed while we waited.
        now = time.monotonic()
        if _health_cache is not None and (now - _health_cache_at) < _HEALTH_CACHE_TTL:
            return _health_cache

        names = ("database", "redis", "stripe", "twilio", "fcm")
        results = await asyncio.gather(
            _check_database(),
            _check_redis(),
            _check_stripe(),
            _check_twilio(),
            _check_fcm(),
            return_exceptions=True,
        )
        checks: dict = {}
        for name, result in zip(names, results):
            if isinstance(result, BaseException):
                checks[name] = {"ok": False, "error": f"{type(result).__name__}: {result}"}
            else:
                checks[name] = result

        _health_cache = checks
        _health_cache_at = time.monotonic()
        _log_check_failures(checks)
        return checks


@router.get("/health", response_model=HealthResponse)
async def health_check(request: Request):
    """Deep health check with external service connectivity."""
    # copy(): the cached dict is shared, so the live counters below must not
    # be written into it.
    checks = dict(await _dependency_checks())
    checks["cache"] = cache_stats()
    checks["rate_limiter"] = rate_limiter.get_stats()

    # Overall status: degraded if any critical check fails
    critical = ["database"]
    failed_critical = [c for c in critical if not checks[c].get("ok", False)]

    status = "degraded" if failed_critical else "ok"

    return HealthResponse(
        status=status,
        timestamp=datetime.now(timezone.utc).isoformat(),
        checks=_public_checks(checks),
    )


async def _check_database() -> dict:
    """Check database connectivity.

    Detail in the returned dict is for server-side logging only - the public
    response is sanitised by _public_checks().
    """
    try:
        async with asyncio.timeout(_DEP_TIMEOUT):
            async with SessionLocal() as db:
                from sqlalchemy import text
                result = await db.execute(text("SELECT 1"))
                row = result.fetchone()
                if row:
                    return {"ok": True}
                return {"ok": False, "error": "No row returned"}
    except asyncio.TimeoutError:
        return {"ok": False, "error": f"timeout after {_DEP_TIMEOUT}s"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def _check_redis() -> dict:
    """Check Redis connectivity."""
    try:
        from services.redis_cache import _get_redis
        async with asyncio.timeout(_DEP_TIMEOUT):
            redis = await _get_redis()
            if redis is None:
                return {"ok": False, "error": "Redis not configured or unavailable"}
            await redis.ping()
        return {"ok": True}
    except asyncio.TimeoutError:
        return {"ok": False, "error": f"timeout after {_DEP_TIMEOUT}s"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def _check_stripe() -> dict:
    """Check Stripe API connectivity.

    stripe-python is a SYNCHRONOUS client. Called directly from `async def`
    it blocks the single uvicorn worker for the whole round trip, so an
    unauthenticated /health flood could stall all trip traffic. Run it in a
    worker thread with a hard timeout instead.

    Caveat: a thread cannot be cancelled, so on timeout the call keeps
    running in the executor until the socket returns. The result is
    discarded. Bounded by the /health cache, that is at most one stray
    thread per _HEALTH_CACHE_TTL, not one per request.
    """
    api_key = os.getenv("STRIPE_SECRET_KEY", "")
    if not api_key:
        return {"ok": False, "error": "No API key"}

    def _probe() -> None:
        import stripe
        stripe.api_key = api_key
        # Lightweight check: retrieve balance (fast, no objects created)
        stripe.Balance.retrieve()

    try:
        await asyncio.wait_for(asyncio.to_thread(_probe), timeout=_DEP_TIMEOUT)
        return {"ok": True}
    except asyncio.TimeoutError:
        return {"ok": False, "error": f"timeout after {_DEP_TIMEOUT}s"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def _check_twilio() -> dict:
    """Check Twilio API connectivity.

    Same blocking-client problem as Stripe - see _check_stripe().
    """
    sid = os.getenv("TWILIO_ACCOUNT_SID", "")
    token = os.getenv("TWILIO_AUTH_TOKEN", "")
    if not sid or not token:
        return {"ok": False, "error": "No credentials"}

    def _probe() -> None:
        from twilio.rest import Client
        # Twilio's HTTP client logs full request/response headers at DEBUG.
        # On a public, unthrottled endpoint that dumps auth-adjacent headers
        # into the logs at request rate. Scoped to Twilio's own logger only.
        logging.getLogger("twilio.http_client").setLevel(logging.WARNING)
        client = Client(sid, token)
        # Lightweight: fetch account info
        client.api.accounts(sid).fetch()

    try:
        await asyncio.wait_for(asyncio.to_thread(_probe), timeout=_DEP_TIMEOUT)
        return {"ok": True}
    except asyncio.TimeoutError:
        return {"ok": False, "error": f"timeout after {_DEP_TIMEOUT}s"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def _check_fcm() -> dict:
    """Check Firebase/FCM deliverability.

    This used to assert only that `firebase_admin._apps` was non-empty - that
    an app OBJECT exists. services/fcm_service.py gates real sends behind its
    own flag, so /health could report {"fcm": {"ok": true}} while every ride
    offer was being dropped with no log: a health check that stays green
    during the exact outage it exists to detect.

    fcm_enabled() reports whether pushes will actually be delivered, so we
    consult it as well. It is imported lazily and run off the event loop -
    when Firebase is down it may attempt a (throttled) real init, which is
    not work we want inline on an unauthenticated endpoint.
    """
    def _probe() -> dict:
        import firebase_admin
        # fcm_enabled() FIRST, before looking at _apps.
        #
        # Firebase initialises lazily: in a container that has not served a
        # trip yet nothing has created the default app, so an _apps check up
        # front returned "not initialized" and left early — skipping the one
        # call that knows how to initialise it. The result was a check that
        # went red on every fresh deploy and could not tell "no push has been
        # needed yet" apart from "pushes are broken", which is the exact
        # question it exists to answer. It also explained the silence in the
        # logs: fcm_service never ran, so it never reported why.
        try:
            from services.fcm_service import fcm_enabled
            sends_enabled = fcm_enabled()
        except Exception as e:
            return {"ok": False, "error": f"fcm_enabled() probe failed: {e}"}

        if not firebase_admin._apps:
            return {"ok": False, "error": "FCM not initialized"}
        app = firebase_admin.get_app()

        if not sends_enabled:
            return {
                "ok": False,
                "error": "Firebase app exists but fcm_service reports sends disabled",
                "project_id": app.project_id,
            }
        return {"ok": True, "project_id": app.project_id}

    try:
        return await asyncio.wait_for(asyncio.to_thread(_probe), timeout=_DEP_TIMEOUT)
    except asyncio.TimeoutError:
        return {"ok": False, "error": f"timeout after {_DEP_TIMEOUT}s"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ═══════════════════════════════════════════════════════════════════════
#  API Key Rotation
# ═══════════════════════════════════════════════════════════════════════

class RotateKeyRequest(BaseModel):
    key_type: str  # "api_key", "hmac_secret", "jwt_secret", "dispatch_api_key"
    new_value: Optional[str] = None  # If None, auto-generate


class RotateKeyResponse(BaseModel):
    key_type: str
    rotated_at: str
    preview: str  # First 8 chars + ... for verification


@router.post("/admin/rotate-key", response_model=RotateKeyResponse)
async def rotate_api_key(
    req: RotateKeyRequest,
    request: Request,
    admin=Depends(_require_admin),
    x_api_key: str = Header(..., alias="X-API-Key"),
):
    """Rotate an API key or secret.
    
    Requires admin authentication. The new key is stored in the database
    (AppConfig table) and takes effect immediately without restart.
    """
    valid_types = {"api_key", "hmac_secret", "jwt_secret", "dispatch_api_key"}
    if req.key_type not in valid_types:
        raise HTTPException(400, f"Invalid key_type. Must be one of: {valid_types}")
    
    # Generate new value if not provided
    new_value = req.new_value
    if not new_value:
        import secrets
        new_value = secrets.token_urlsafe(48)
    
    # Store in AppConfig for persistence
    async with SessionLocal() as db:
        from sqlalchemy import select
        stmt = select(AppConfig).where(AppConfig.key == f"rotated_{req.key_type}")
        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()
        
        if existing:
            existing.value = new_value
            existing.updated_at = datetime.now(timezone.utc)
        else:
            db.add(AppConfig(
                key=f"rotated_{req.key_type}",
                value=new_value,
                description=f"Rotated {req.key_type}",
            ))
        await db.commit()
    
    # Update in-memory cache
    os.environ[req.key_type.upper()] = new_value
    
    # Audit log
    _security_audit_log(
        event="api_key_rotated",
        ip=request.client.host if request.client else "unknown",
        user_id=admin.id if hasattr(admin, "id") else None,
        details={"key_type": req.key_type},
    )
    
    logger.warning("API key rotated: %s by admin", req.key_type)
    
    return RotateKeyResponse(
        key_type=req.key_type,
        rotated_at=datetime.now(timezone.utc).isoformat(),
        preview=new_value[:8] + "...",
    )


# ═══════════════════════════════════════════════════════════════════════
#  System Metrics
# ═══════════════════════════════════════════════════════════════════════

@router.get("/admin/metrics")
async def system_metrics(admin=Depends(_require_admin)):
    """Return system metrics for monitoring dashboards."""
    return {
        "cache": cache_stats(),
        "rate_limiter": rate_limiter.get_stats(),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


# ═══════════════════════════════════════════════════════════════════════
#  Force-update switch — dispatch flips it, the app checks it at boot
#  (2026-10-10, user spec: a panel button sends users to the store;
#  v2 same day: min build per platform so users who ALREADY updated walk
#  straight in, and a socket broadcast flips live apps in real time;
#  v3 2026-10-11: PER-ROLE switches — drivers and riders gate separately,
#  spec "también debe salir un botón para pasajero")
# ═══════════════════════════════════════════════════════════════════════

_FORCE_UPDATE_KEY = "force_update_required"  # legacy global: everyone
_FORCE_UPDATE_ROLE_KEYS = {
    "driver": "force_update_required_driver",
    "rider": "force_update_required_rider",
}
_MAINTENANCE_KEY = "maintenance_mode"  # 2026-10-11: dispatch kill page
_MIN_BUILD_KEYS = {
    "ios": "force_update_min_build_ios",
    "android": "force_update_min_build_android",
}
_STORE_URLS = {
    "ios": "https://apps.apple.com/app/id6760517086",
    "android": "https://play.google.com/store/apps/details?id=com.cruiseinride.app",
}


async def _read_app_update_state(db) -> dict:
    """Raw + effective gate state. Raises on DB error; callers decide their
    failure mode (public endpoint fails OPEN, admin fails LOUD)."""
    from sqlalchemy import select

    keys = [_FORCE_UPDATE_KEY, *_FORCE_UPDATE_ROLE_KEYS.values(),
            _MAINTENANCE_KEY, *_MIN_BUILD_KEYS.values()]
    r = await db.execute(
        select(AppConfig.key, AppConfig.value).where(AppConfig.key.in_(keys)))
    rows = {k: v for k, v in r.all()}

    def _on(key: str) -> bool:
        return (rows.get(key) or "").strip() == "1"

    def _min_build(platform: str) -> int:
        try:
            return int((rows.get(_MIN_BUILD_KEYS[platform]) or "0").strip())
        except ValueError:
            return 0

    legacy = _on(_FORCE_UPDATE_KEY)
    return {
        # Legacy global switch still gates everyone until the panel clears
        # it by writing the per-role keys.
        "all": legacy,
        "driver": legacy or _on(_FORCE_UPDATE_ROLE_KEYS["driver"]),
        "rider": legacy or _on(_FORCE_UPDATE_ROLE_KEYS["rider"]),
        "maintenance": _on(_MAINTENANCE_KEY),
        "mins": {p: _min_build(p) for p in _MIN_BUILD_KEYS},
    }


@router.get("/app-update-status", dependencies=[Depends(_verify_api_key)])
async def app_update_status(platform: str = "", build: int = 0,
                            role: str = "", db=Depends(get_db)):
    """Boot gate for the app: update_required=true means the store page is
    the only screen the user gets.

    Fail-open BY DESIGN: a DB hiccup answers update_required=false rather
    than locking every user out of the app over our own outage.

    Version-aware: a client on build >= the required minimum is NOT gated
    (the user who already updated must not loop back to the store page).
    build=0 (clients too old to report it) and min_build=0 (never set from
    the panel) both fall back to the plain switch: enabled = everyone gated.

    Role-aware (v3): the driver switch gates drivers, the rider switch
    gates riders; a client whose role is unknown (logged out) is gated when
    EITHER switch is on — dispatch is forcing that build out of service.
    """
    required = False
    maintenance = False
    try:
        state = await _read_app_update_state(db)
        maintenance = state["maintenance"]
        r = (role or "").lower()
        if r == "driver":
            enabled = state["driver"]
        elif r == "rider":
            enabled = state["rider"]
        else:
            enabled = state["driver"] or state["rider"]
        min_build = state["mins"].get((platform or "").lower(), 0)
        required = enabled and (
            min_build <= 0 or build <= 0 or build < min_build)
    except Exception as e:
        logger.warning("[AppUpdate] status read failed: %s", e)
    return {
        "update_required": required,
        # Maintenance kill page (2026-10-11): dispatch flips it when the app
        # is having a bad day; the whole app then shows "Something went
        # wrong" until it is turned back off. Fail-open with the rest.
        "maintenance": maintenance,
        "store_url": _STORE_URLS.get((platform or "").lower(),
                                     _STORE_URLS["android"]),
    }


class AppUpdateSwitch(BaseModel):
    # Any flag left null is not touched — the panel sends all three.
    enabled: Optional[bool] = None  # legacy global (everyone)
    driver_enabled: Optional[bool] = None
    rider_enabled: Optional[bool] = None
    maintenance_enabled: Optional[bool] = None  # the kill page
    min_build_ios: int = Field(0, ge=0, le=100000)
    min_build_android: int = Field(0, ge=0, le=100000)


@router.get("/admin/app-update", dependencies=[Depends(_require_dispatch_auth)])
async def get_app_update_switch(db=Depends(get_db)):
    state = await _read_app_update_state(db)
    return {
        "all_enabled": state["all"],
        # Legacy field name kept for the pre-role panel/tests.
        "enabled": state["all"],
        "driver_enabled": state["driver"],
        "rider_enabled": state["rider"],
        "maintenance_enabled": state["maintenance"],
        "min_build_ios": state["mins"]["ios"],
        "min_build_android": state["mins"]["android"],
        "store_urls": _STORE_URLS,
    }


@router.post("/admin/app-update", dependencies=[Depends(_require_dispatch_auth)])
async def set_app_update_switch(req: AppUpdateSwitch, request: Request,
                                db=Depends(get_db)):
    from sqlalchemy import select

    async def _upsert(key: str, value: str, description: str) -> None:
        r = await db.execute(select(AppConfig).where(AppConfig.key == key))
        row = r.scalar_one_or_none()
        if row:
            row.value = value
            row.updated_at = datetime.now(timezone.utc)
        else:
            db.add(AppConfig(key=key, value=value, description=description))

    wrote_role = False
    if req.enabled is not None:
        await _upsert(_FORCE_UPDATE_KEY, "1" if req.enabled else "0",
                      "Force-update gate — legacy global (everyone)")
    if req.driver_enabled is not None:
        wrote_role = True
        await _upsert(_FORCE_UPDATE_ROLE_KEYS["driver"],
                      "1" if req.driver_enabled else "0",
                      "Force-update gate — drivers")
    if req.rider_enabled is not None:
        wrote_role = True
        await _upsert(_FORCE_UPDATE_ROLE_KEYS["rider"],
                      "1" if req.rider_enabled else "0",
                      "Force-update gate — riders")
    # Role keys are now explicit: the legacy global must not keep gating
    # everyone from behind them.
    if wrote_role and req.enabled is None:
        await _upsert(_FORCE_UPDATE_KEY, "0",
                      "Force-update gate — legacy global (everyone)")
    if req.maintenance_enabled is not None:
        await _upsert(_MAINTENANCE_KEY, "1" if req.maintenance_enabled else "0",
                      "Maintenance kill page — '1' = the app shows "
                      "'Something went wrong'")
    await _upsert(_MIN_BUILD_KEYS["ios"], str(req.min_build_ios),
                  "Min iOS build before the gate applies (0 = all builds)")
    await _upsert(_MIN_BUILD_KEYS["android"], str(req.min_build_android),
                  "Min Android build before the gate applies (0 = all builds)")
    await db.commit()
    _security_audit_log(
        "app_update_switch",
        request.client.host if request.client else "unknown",
        f"enabled={req.enabled} driver={req.driver_enabled} "
        f"rider={req.rider_enabled} min_ios={req.min_build_ios} "
        f"min_android={req.min_build_android}",
    )
    logger.warning(
        "[AppUpdate] force-update switch -> all=%s driver=%s rider=%s",
        req.enabled, req.driver_enabled, req.rider_enabled)

    # Wake live apps so the gate flips in real time (socket broadcast reaches
    # every worker via the Redis manager; offline apps catch it at boot, and
    # the blocked page polls every 15 s as the final fallback).
    any_on = bool(req.enabled) or bool(req.driver_enabled) \
        or bool(req.rider_enabled) or bool(req.maintenance_enabled)
    try:
        from services.socketio_service import sio
        await sio.emit("app_update_gate_changed", {"required": any_on})
    except Exception as e:
        logger.warning("[AppUpdate] socket broadcast failed: %s", e)

    state = await _read_app_update_state(db)
    return {
        "all_enabled": state["all"],
        "enabled": state["all"],
        "driver_enabled": state["driver"],
        "rider_enabled": state["rider"],
        "maintenance_enabled": state["maintenance"],
    }


# ═══════════════════════════════════════════════════════════════════════
#  Feature flags — tiny remote kill switches (2026-10-11)
#  Born for the zone layers: the driver map drawing can be switched off
#  from the server while a live issue is diagnosed, and back on without a
#  new build or patch.
# ═══════════════════════════════════════════════════════════════════════

_FLAG_KEYS = {
    "zones_map_enabled": "Municipal zone shading + highlight on the driver map",
}


@router.get("/feature-flags", dependencies=[Depends(_verify_api_key)])
async def feature_flags(db=Depends(get_db)):
    """Public read for the app. Missing key = OFF (a flag that was never
    written reads as off — fail to the SAFE side)."""
    from sqlalchemy import select

    r = await db.execute(
        select(AppConfig.key, AppConfig.value)
        .where(AppConfig.key.in_(list(_FLAG_KEYS))))
    rows = {k: v for k, v in r.all()}
    return {k: (rows.get(k) or "").strip() == "1" for k in _FLAG_KEYS}


class FeatureFlagIn(BaseModel):
    key: str
    enabled: bool


@router.post("/admin/feature-flags",
             dependencies=[Depends(_require_dispatch_auth)])
async def set_feature_flag(req: FeatureFlagIn, request: Request,
                           db=Depends(get_db)):
    from sqlalchemy import select

    if req.key not in _FLAG_KEYS:
        raise HTTPException(400, f"unknown flag: {req.key}")
    r = await db.execute(
        select(AppConfig).where(AppConfig.key == req.key))
    row = r.scalar_one_or_none()
    value = "1" if req.enabled else "0"
    if row:
        row.value = value
        row.updated_at = datetime.now(timezone.utc)
    else:
        db.add(AppConfig(key=req.key, value=value,
                         description=_FLAG_KEYS[req.key]))
    await db.commit()
    _security_audit_log(
        "feature_flag",
        request.client.host if request.client else "unknown",
        f"{req.key}={req.enabled}",
    )
    logger.warning("[Flags] %s -> %s", req.key, req.enabled)
    return {"key": req.key, "enabled": req.enabled}


# ═══════════════════════════════════════════════════════════════════════
#  Client breadcrumbs — the app's taps report to the server log so a dead
#  button on a phone is diagnosable WITHOUT the device (2026-10-11, born
#  for the offline recenter FAB that "does nothing" on the user's phone)
# ═══════════════════════════════════════════════════════════════════════

class ClientEventIn(BaseModel):
    event: str = Field(min_length=1, max_length=60)
    detail: Optional[str] = Field(None, max_length=300)


@router.post("/diag/client-event", dependencies=[Depends(_verify_api_key)])
async def client_event(req: ClientEventIn, request: Request):
    # A log line, nothing else — this is a diag instrument, not a data pipe.
    logger.warning(
        "[ClientEvent] %s | %s | %s",
        req.event,
        req.detail or "",
        request.client.host if request.client else "unknown",
    )
    return {"ok": True}


# ═══════════════════════════════════════════════════════════════════════
#  Sector demand heat (2026-10-12, user spec): the driver map paints big
#  sectors (not mini-cities) — always visible in gray with their boundary,
#  and dispatch turns individual sectors "on" in gold, three levels deep
#  (semi / Ocupado / Muy ocupado) with an optional +$ bonus pill. Phase 1 is
#  display + control only; the bonus is NOT charged or paid yet.
# ═══════════════════════════════════════════════════════════════════════

_SECTOR_DEMAND_KEY = "sector_demand"
# Live-editable sector map (panel → apps over socket): the GeoJSON rides in
# app_config, the baked static file is only the seed/fallback until the
# first PUT. The version is the change signal for the apps.
_SECTORS_GEOJSON_KEY = "fl_sectors_geojson"
_SECTORS_VERSION_KEY = "fl_sectors_version"
_SECTOR_IDS: frozenset = frozenset()
_sector_demand_cache: tuple = ()  # (monotonic_ts, payload_dict)


def _sectors_version_from(raw: Optional[str]) -> int:
    try:
        return int((raw or "0").strip())
    except ValueError:
        return 0


def _load_sector_ids() -> frozenset:
    """Sector ids from the baked static file (validated once per process —
    the file ships with the deploy)."""
    global _SECTOR_IDS
    if _SECTOR_IDS:
        return _SECTOR_IDS
    try:
        import json as _json
        import os as _os
        path = _os.path.join(_os.path.dirname(__file__), "..", "static",
                             "fl_sectors.json")
        with open(path, encoding="utf-8") as fh:
            data = _json.load(fh)
        _SECTOR_IDS = frozenset(
            f["properties"]["id"] for f in data.get("features", []))
    except Exception as e:  # fail-open: empty set rejects nothing below
        logger.warning("[Zones] sector id load failed: %s", e)
        _SECTOR_IDS = frozenset()
    return _SECTOR_IDS


def _parse_sector_demand(raw: str) -> dict:
    """'{"sunrise_plantation": {"level": 2, "bonus": 1.5}, ...}' → dict.
    Anything malformed drops out entry by entry — one bad row must never
    blank the whole heat layer."""
    import json as _json
    out = {}
    try:
        data = _json.loads(raw) if raw else {}
    except Exception:
        return out
    if not isinstance(data, dict):
        return out
    for sid, cfg in data.items():
        if not isinstance(cfg, dict):
            continue
        try:
            level = int(cfg.get("level", 0))
            bonus = float(cfg.get("bonus", 0) or 0)
        except (TypeError, ValueError):
            continue
        if level < 0 or level > 3 or bonus < 0 or bonus > 50:
            continue
        if level == 0:
            continue  # level 0 is the gray base — storing it is noise
        out[sid] = {"level": level, "bonus": round(bonus, 2)}
    return out


@router.get("/zones/demand", dependencies=[Depends(_verify_api_key)])
async def zone_demand(db=Depends(get_db)):
    """Public read for the app (drivers): sector -> {level, bonus}.
    Cached 30 s in-process — the app polls it every minute and the value
    changes by hand, never hot. `sectors_version` rides along so the same
    poll doubles as the change detector for the live sector map when the
    socket is down (a bump means refetch /zones/sectors)."""
    import time as _time
    global _sector_demand_cache
    now = _time.monotonic()
    if _sector_demand_cache and now - _sector_demand_cache[0] < 30:
        return _sector_demand_cache[1]
    from sqlalchemy import select
    r = await db.execute(
        select(AppConfig.key, AppConfig.value)
        .where(AppConfig.key.in_([_SECTOR_DEMAND_KEY, _SECTORS_VERSION_KEY])))
    rows = {k: v for k, v in r.all()}
    payload = {"sectors": _parse_sector_demand(
                   rows.get(_SECTOR_DEMAND_KEY) or ""),
               "sectors_version": _sectors_version_from(
                   rows.get(_SECTORS_VERSION_KEY))}
    _sector_demand_cache = (now, payload)
    return payload


class ZoneDemandIn(BaseModel):
    sector_id: str = Field(min_length=1, max_length=40)
    level: int = Field(ge=0, le=3)
    bonus: float = Field(0, ge=0, le=50)


@router.get("/admin/zone-demand", dependencies=[Depends(_require_dispatch_auth)])
async def get_zone_demand(db=Depends(get_db)):
    """Dispatch read (the panel paints the current heat map)."""
    from sqlalchemy import select
    r = await db.execute(
        select(AppConfig.value).where(AppConfig.key == _SECTOR_DEMAND_KEY))
    raw = r.scalar_one_or_none() or ""
    return {"sectors": _parse_sector_demand(raw)}


@router.post("/admin/zone-demand", dependencies=[Depends(_require_dispatch_auth)])
async def set_zone_demand(req: ZoneDemandIn, request: Request,
                          db=Depends(get_db)):
    """Dispatch sets/clears one sector's heat. The whole map lives in ONE
    AppConfig row (JSON) so a write is a read-modify-write — two dispatchers
    editing at once keep each other's sectors."""
    import json as _json
    from sqlalchemy import select

    known = _load_sector_ids()
    if known and req.sector_id not in known:
        raise HTTPException(400, f"unknown sector: {req.sector_id}")
    global _sector_demand_cache
    r = await db.execute(
        select(AppConfig).where(AppConfig.key == _SECTOR_DEMAND_KEY))
    row = r.scalar_one_or_none()
    current = _parse_sector_demand(row.value if row else "")
    if req.level == 0:
        current.pop(req.sector_id, None)
    else:
        current[req.sector_id] = {"level": req.level,
                                  "bonus": round(req.bonus, 2)}
    value = _json.dumps(current, separators=(",", ":"))
    if row:
        row.value = value
        row.updated_at = datetime.now(timezone.utc)
    else:
        db.add(AppConfig(key=_SECTOR_DEMAND_KEY, value=value,
                         description="Sector heat set by dispatch "
                                     "{sector_id: {level, bonus}}"))
    await db.commit()
    _sector_demand_cache = ()  # bust the read cache this instant
    _security_audit_log(
        "zone_demand",
        request.client.host if request.client else "unknown",
        f"{req.sector_id}=lvl{req.level}/${req.bonus}",
    )
    logger.warning("[Zones] demand %s -> lvl %d, $%.2f", req.sector_id,
                   req.level, req.bonus)
    return {"sector_id": req.sector_id, "level": req.level,
            "bonus": round(req.bonus, 2)}


# ═══════════════════════════════════════════════════════════════════════
#  Live sector map (user spec: dispatch edits the driver-map sectors from
#  the panel and every app updates over the socket — no redeploy, no app
#  restart). The edited copy lives in app_config; the baked static file
#  stays the seed/fallback until the first PUT. A monotonically increasing
#  version is the change signal: the "zones_updated" socket event live,
#  /zones/demand's sectors_version as the polling fallback.
# ═══════════════════════════════════════════════════════════════════════

_SECTORS_FILE = os.path.join(os.path.dirname(__file__), "..", "static",
                             "fl_sectors.json")
_SECTOR_MAX_FEATURES = 60
_SECTOR_MAX_POINTS = 50000
_sectors_file_cache: tuple = ()  # (mtime, geojson_dict)


def _load_sectors_file() -> Optional[dict]:
    """Baked sectors shipped with the deploy — the seed the panel edits
    from and the fallback until the first PUT. Cached by mtime."""
    global _sectors_file_cache
    try:
        mtime = os.path.getmtime(_SECTORS_FILE)
        if _sectors_file_cache and _sectors_file_cache[0] == mtime:
            return _sectors_file_cache[1]
        import json as _json
        with open(_SECTORS_FILE, encoding="utf-8") as fh:
            data = _json.load(fh)
        if not isinstance(data, dict) or data.get("type") != "FeatureCollection":
            raise ValueError("not a FeatureCollection")
        _sectors_file_cache = (mtime, data)
        return data
    except Exception as e:  # the endpoint turns this into a clean 503
        logger.warning("[Zones] sectors file load failed: %s", e)
        return None


def _clean_position(pos, where: str) -> list:
    if (not isinstance(pos, (list, tuple)) or len(pos) != 2
            or any(isinstance(v, bool) or not isinstance(v, (int, float))
                   for v in pos)):
        raise HTTPException(400, f"{where}: position must be [lng, lat]")
    lng, lat = float(pos[0]), float(pos[1])
    # NaN/inf fall out here: every comparison against them is False.
    if not (-180.0 <= lng <= 180.0 and -90.0 <= lat <= 90.0):
        raise HTTPException(400, f"{where}: lng/lat out of range")
    return [lng, lat]


def _clean_ring(ring, where: str) -> list:
    if not isinstance(ring, list) or len(ring) < 3:
        raise HTTPException(400, f"{where}: a ring needs >= 3 positions")
    pts = [_clean_position(p, where) for p in ring]
    if len({(p[0], p[1]) for p in pts}) < 3:
        raise HTTPException(400,
                            f"{where}: a ring needs >= 3 distinct positions")
    if pts[0] != pts[-1]:
        pts.append(list(pts[0]))  # close the ring server-side
    return pts


def _slugify_sector(name: str, taken: set) -> str:
    """id = slug of the name (server-assigned, never client-sent):
    lowercase, accents stripped, non [a-z0-9] runs -> _, unique via _2, _3…"""
    import re
    import unicodedata
    base = unicodedata.normalize("NFKD", name) \
        .encode("ascii", "ignore").decode()
    base = re.sub(r"[^a-z0-9]+", "_", base.lower()).strip("_") or "sector"
    slug, n = base, 2
    while slug in taken:
        slug = f"{base}_{n}"
        n += 1
    taken.add(slug)
    return slug


class SectorsGeojsonIn(BaseModel):
    # The envelope only — the deep ring structure is validated strictly in
    # _validate_sector_collection (nested lists don't map to field types).
    type: str
    features: list


def _validate_sector_collection(req: SectorsGeojsonIn) -> list:
    """Strict structural validation + normalization. Raises 400 with the
    specific reason on the first violation; returns clean features whose
    id/bbox/center are ALWAYS recomputed here — the client is never trusted
    for them. bbox = [w, s, e, n]; center = centroid of the bbox."""
    if req.type != "FeatureCollection":
        raise HTTPException(400, "type must be FeatureCollection")
    features = req.features
    if not isinstance(features, list) \
            or not (1 <= len(features) <= _SECTOR_MAX_FEATURES):
        raise HTTPException(
            400, f"features must be 1..{_SECTOR_MAX_FEATURES}")
    out, taken, total = [], set(), 0
    for i, feat in enumerate(features):
        where = f"feature {i}"
        if not isinstance(feat, dict):
            raise HTTPException(400, f"{where}: not an object")
        props = feat.get("properties")
        if not isinstance(props, dict):
            raise HTTPException(400, f"{where}: properties must be an object")
        raw_name = props.get("name")
        if not isinstance(raw_name, str) or not raw_name.strip():
            raise HTTPException(400, f"{where}: properties.name required")
        name = raw_name.strip()
        if len(name) > 100:
            raise HTTPException(400, f"{where}: properties.name too long")
        geom = feat.get("geometry")
        if not isinstance(geom, dict):
            raise HTTPException(400, f"{where}: geometry must be an object")
        gtype, coords = geom.get("type"), geom.get("coordinates")
        if gtype == "Polygon":
            polys = [coords]
        elif gtype == "MultiPolygon":
            if not isinstance(coords, list) or not coords:
                raise HTTPException(400, f"{where}: empty MultiPolygon")
            polys = coords
        else:
            raise HTTPException(
                400, f"{where}: geometry must be Polygon|MultiPolygon")
        clean_polys = []
        for poly in polys:
            if not isinstance(poly, list) or not poly:
                raise HTTPException(400, f"{where}: a polygon needs rings")
            clean_polys.append([_clean_ring(r, where) for r in poly])
        total += sum(len(r) for poly in clean_polys for r in poly)
        if total > _SECTOR_MAX_POINTS:
            raise HTTPException(
                400, f"too many points (>{_SECTOR_MAX_POINTS})")
        pts = [p for poly in clean_polys for ring in poly for p in ring]
        lngs = [p[0] for p in pts]
        lats = [p[1] for p in pts]
        w, s, e, n = min(lngs), min(lats), max(lngs), max(lats)
        new_props = {k: v for k, v in props.items()
                     if k not in ("id", "bbox", "center")}
        new_props["name"] = name
        new_props["id"] = _slugify_sector(name, taken)
        new_props["bbox"] = [w, s, e, n]
        new_props["center"] = [(w + e) / 2, (s + n) / 2]
        out.append({"type": "Feature", "properties": new_props,
                    "geometry": {"type": gtype, "coordinates": clean_polys}})
    return out


@router.get("/zones/sectors", dependencies=[Depends(_verify_api_key)])
async def get_zone_sectors(db=Depends(get_db)):
    """Live sector map for the apps. The dispatch-edited copy in app_config
    wins; until the first PUT the baked static file is served. The version
    is the client's cache key — refetch only when it changes."""
    import json as _json
    from sqlalchemy import select

    r = await db.execute(
        select(AppConfig.key, AppConfig.value)
        .where(AppConfig.key.in_([_SECTORS_GEOJSON_KEY,
                                  _SECTORS_VERSION_KEY])))
    rows = {k: v for k, v in r.all()}
    geojson = None
    raw = rows.get(_SECTORS_GEOJSON_KEY)
    if raw:
        try:
            parsed = _json.loads(raw)
            if isinstance(parsed, dict) \
                    and parsed.get("type") == "FeatureCollection":
                geojson = parsed
        except Exception as e:
            logger.warning(
                "[Zones] stored sectors unreadable, serving file: %s", e)
    if geojson is None:
        geojson = _load_sectors_file()
    if geojson is None:
        raise HTTPException(503, "sector map unavailable")
    return {"version": _sectors_version_from(rows.get(_SECTORS_VERSION_KEY)),
            "geojson": geojson}


@router.put("/admin/zones/sectors",
            dependencies=[Depends(_require_dispatch_auth)])
async def put_zone_sectors(req: SectorsGeojsonIn, request: Request,
                           db=Depends(get_db)):
    """Dispatch replaces the whole sector map. Strictly validated, ids and
    bbox/center recomputed server-side, version bumped, live apps woken over
    the socket."""
    import json as _json
    from sqlalchemy import select

    global _sector_demand_cache, _SECTOR_IDS
    cleaned = _validate_sector_collection(req)
    r = await db.execute(
        select(AppConfig).where(
            AppConfig.key.in_([_SECTORS_GEOJSON_KEY, _SECTORS_VERSION_KEY])))
    rows = {row.key: row for row in r.scalars().all()}
    prev = rows.get(_SECTORS_VERSION_KEY)
    version = _sectors_version_from(prev.value if prev else None) + 1
    collection = {"type": "FeatureCollection", "features": cleaned}

    def _upsert(key: str, value: str, description: str) -> None:
        row = rows.get(key)
        if row:
            row.value = value
            row.updated_at = datetime.now(timezone.utc)
        else:
            db.add(AppConfig(key=key, value=value, description=description))

    _upsert(_SECTORS_GEOJSON_KEY,
            _json.dumps(collection, ensure_ascii=False,
                        separators=(",", ":")),
            "Live FL sector map (GeoJSON FeatureCollection)")
    _upsert(_SECTORS_VERSION_KEY, str(version),
            "Sector map version — bumped on every PUT")
    await db.commit()
    _sector_demand_cache = ()  # sectors_version rides that payload
    # The heat writer validates sector ids against this set — point it at
    # the new map this instant or renames would 400 until a restart.
    _SECTOR_IDS = frozenset(f["properties"]["id"] for f in cleaned)
    _security_audit_log(
        "zone_sectors",
        request.client.host if request.client else "unknown",
        f"version={version} features={len(cleaned)}",
    )
    logger.warning("[Zones] sectors replaced -> v%d (%d features)",
                   version, len(cleaned))

    # Wake live apps so the map flips in real time (same pattern as the
    # app-update gate above; offline apps catch the version bump on the
    # /zones/demand poll).
    try:
        from services.socketio_service import sio
        await sio.emit("zones_updated", {"version": version})
    except Exception as e:
        logger.warning("[Zones] socket broadcast failed: %s", e)
    return {"ok": True, "version": version, "count": len(cleaned)}
