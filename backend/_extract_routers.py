#!/usr/bin/env python3
"""R1.3 — Extract endpoints from main.py into domain router modules.

Creates:
  config.py                 — shared env vars, state, init
  routers/auth.py           — /auth/* endpoints
  routers/trips.py          — /trips/* endpoints
  routers/drivers.py        — /drivers/*, /riders/*, /wallet/*, /plaid/*, /webhooks/*
  routers/dispatch.py       — /dispatch/*, /api/dispatch/*, /admin/sync-*
  routers/support.py        — /support/* + AI support engine
  routers/voice.py          — /voice/* + Twilio IVR
  routers/payments.py       — /payments/*, /paypal/* + Stripe config
  routers/admin.py          — /admin/* CRUD
  routers/misc.py           — everything else

Modifies:
  main.py                   — removes extracted code, adds include_router()

Usage:  cd backend && python _extract_routers.py
"""

import re, os, sys, textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "main.py")
ROUTERS = os.path.join(HERE, "routers")
os.makedirs(ROUTERS, exist_ok=True)

# ── Read source ────────────────────────────────────────────────
with open(MAIN, "r", encoding="utf-8-sig") as f:
    lines = f.readlines()
N = len(lines)
print(f"[1/7] Read {N} lines from main.py")

# ══════════════════════════════════════════════════════════════
#  STEP 1: Find every @app endpoint block
# ══════════════════════════════════════════════════════════════

EP = re.compile(r'^@app\.(get|post|patch|delete|put)\(\s*"(/[^"]+)"')
DEF = re.compile(r'^(async\s+)?def\s+(\w+)\(')

def func_body_end(def_idx):
    """Return the (exclusive) line index where the function body of `def_idx` ends."""
    # Skip past multi-line signatures
    i = def_idx
    paren_depth = lines[i].count("(") - lines[i].count(")")
    while paren_depth > 0 and i < N - 1:
        i += 1
        paren_depth += lines[i].count("(") - lines[i].count(")")
    # Now scan body — stop at first non-blank line with indent 0
    i += 1
    while i < N:
        s = lines[i]
        if s.strip() == "":
            i += 1
            continue
        if s[0:1] not in (" ", "\t"):
            return i
        i += 1
    return N

eps = []
idx = 0
while idx < N:
    m = EP.match(lines[idx])
    if not m:
        idx += 1
        continue
    url, meth = m.group(2), m.group(1)
    # walk backward for stacked decorators
    dec = idx
    while dec > 0 and lines[dec - 1].strip().startswith("@"):
        dec -= 1
    # find the async def / def
    j = idx + 1
    while j < N and not DEF.match(lines[j]):
        j += 1
    if j >= N:
        idx += 1
        continue
    fname = DEF.match(lines[j]).group(2)
    end = func_body_end(j)
    eps.append(dict(s=dec, e=end, url=url, meth=meth, fn=fname))
    idx = end

print(f"[2/7] Found {len(eps)} endpoints")

# ══════════════════════════════════════════════════════════════
#  STEP 2: URL → router mapping
# ══════════════════════════════════════════════════════════════

def router_for(url):
    if url.startswith("/health") or url == "/admin/run-migrations":
        return None                       # keep in main
    if url.startswith("/dispatch") or url.startswith("/api/dispatch"):
        return "dispatch"
    if url in ("/admin/sync-verifications", "/admin/backfill-approved"):
        return "dispatch"
    if url.startswith("/auth/") or url.startswith("/photos/") or url.startswith("/users/me"):
        return "auth"
    if url.startswith("/trips") or url.startswith("/track/") or url.startswith("/users/"):
        return "trips"
    if any(url.startswith(p) for p in ("/drivers/", "/riders/", "/wallet/", "/plaid/", "/webhooks/")):
        return "drivers"
    if url.startswith("/support/"):
        return "support"
    if url.startswith("/voice/"):
        return "voice"
    if url.startswith("/payments/") or url.startswith("/paypal/"):
        return "payments"
    if url.startswith("/admin/"):
        return "admin"
    return "misc"

for ep in eps:
    ep["rtr"] = router_for(ep["url"])

# ══════════════════════════════════════════════════════════════
#  STEP 3: Build per-line ownership array
# ══════════════════════════════════════════════════════════════

own = [None] * N  # None = keep in main

# 3a — endpoint blocks
for ep in eps:
    if ep["rtr"] is None:
        continue
    for i in range(ep["s"], ep["e"]):
        if own[i] is None:
            own[i] = ep["rtr"]

# 3b — gaps between consecutive same-router endpoints → same router
sorted_eps = sorted([e for e in eps if e["rtr"]], key=lambda e: e["s"])
for k in range(len(sorted_eps) - 1):
    a, b = sorted_eps[k], sorted_eps[k + 1]
    if a["rtr"] != b["rtr"]:
        continue
    gs, ge = a["e"], b["s"]
    if ge - gs > 800:        # too large — probably a different domain's helpers in between
        continue
    if all(own[j] is None for j in range(gs, ge)):
        for j in range(gs, ge):
            own[j] = a["rtr"]

# 3c — large helper blocks between different-router endpoints
# Support AI engine: between last non-support ep before support and first support ep
support_eps = [e for e in sorted_eps if e["rtr"] == "support"]
if support_eps:
    first = support_eps[0]["s"]
    sh_start = first
    while sh_start > 0 and own[sh_start - 1] is None:
        sh_start -= 1
    if first - sh_start > 50:
        for j in range(sh_start, first):
            own[j] = "support"
        print(f"  ├ Support helpers: L{sh_start+1}–L{first} ({first-sh_start} lines)")

# Voice config/helpers: between last support ep and first voice ep
voice_eps = [e for e in sorted_eps if e["rtr"] == "voice"]
if voice_eps:
    first = voice_eps[0]["s"]
    vh_start = first
    while vh_start > 0 and own[vh_start - 1] is None:
        vh_start -= 1
    if first - vh_start > 30:
        for j in range(vh_start, first):
            own[j] = "voice"
        print(f"  ├ Voice helpers: L{vh_start+1}–L{first} ({first-vh_start} lines)")

# Stripe config block & PayPal v1 config: between admin and payment endpoints
# We detect by content — search for known config var patterns
CONF_ASSIGN = {
    re.compile(r"^STRIPE_SECRET\s*="): "payments",
    re.compile(r"^_HAS_STRIPE\s*="): "payments",
    re.compile(r"^PAYPAL_CLIENT_ID\s*="): "payments",
    re.compile(r"^PAYPAL_SECRET\s*="): "payments",
    re.compile(r"^PAYPAL_SANDBOX\s*="): "payments",
    re.compile(r"^PAYPAL_CLIENT_SECRET\s*="): "payments",
    re.compile(r"^PAYPAL_MODE\s*="): "payments",
    re.compile(r"^STRIPE_WEBHOOK_SECRET\s*="): "payments",
    re.compile(r"^CHECKR_API_KEY\s*="): "drivers",
    re.compile(r"^CHECKR_BASE_URL\s*="): "drivers",
    re.compile(r"^def _paypal_base_url"): "payments",
    re.compile(r"^async def _get_paypal_access_token"): "payments",
}
for i, line in enumerate(lines):
    if own[i] is not None:
        continue
    for pat, rtr in CONF_ASSIGN.items():
        if pat.match(line):
            own[i] = rtr
            # Also grab the try/except/import block for stripe init
            if "STRIPE_SECRET" in line or "_HAS_STRIPE" in line:
                # Extend to include the entire try/except block
                j = i + 1
                while j < N and (lines[j].strip().startswith(("try:", "import ", "if ", "_stripe",
                                                                "_HAS_STRIPE", "logging.", "except"))
                                 or lines[j].strip() == ""
                                 or lines[j][0:1] in (" ", "\t")):
                    if own[j] is None:
                        own[j] = rtr
                    j += 1
            # For _paypal_base_url and _get_paypal_access_token, grab function body
            if "def " in line:
                j = i
                end = func_body_end(j)
                for k in range(j, end):
                    if own[k] is None:
                        own[k] = rtr
            break

# 3d — Section comments just before an extracted block → same router
for i in range(N):
    if own[i] is not None:
        continue
    stripped = lines[i].strip()
    if stripped.startswith("#") or stripped.startswith("# ═") or stripped == "":
        # Check if next non-blank non-comment line is extracted
        j = i + 1
        while j < N and (lines[j].strip() == "" or lines[j].strip().startswith("#")):
            j += 1
        if j < N and own[j] is not None:
            # Also check prior: only adopt if previous line is also None or same router
            own[i] = own[j]

# Count extracted lines per router
counts = {}
for v in own:
    if v:
        counts[v] = counts.get(v, 0) + 1
print(f"[3/7] Line ownership: {counts}")
print(f"  └ Kept in main: {sum(1 for v in own if v is None)}")

# ══════════════════════════════════════════════════════════════
#  STEP 4: Generate config.py
# ══════════════════════════════════════════════════════════════

# Config vars from main.py L97-L143 will be imported from config.py instead.
# We also centralize vars that appear later (STRIPE_SECRET, PAYPAL, CHECKR, etc.)

config_content = '''\
"""Cruise Backend — Shared configuration, env vars, and state."""
import os, logging
from datetime import datetime, timezone

# ── Owner / Dispatch ──
OWNER_EMAIL = os.getenv("OWNER_EMAIL", "")
OWNER_PASSWORD_HASH = os.getenv("OWNER_PASSWORD_HASH", "")
OWNER_PASSWORD = os.getenv("OWNER_PASSWORD", "")
PUBLIC_URL = os.getenv("PUBLIC_URL", "https://cruiseapp2-production.up.railway.app")
DISPATCH_ALLOWED_IPS = os.getenv("DISPATCH_ALLOWED_IPS", "")

# ── Twilio ──
TWILIO_ACCOUNT_SID = os.getenv("TWILIO_ACCOUNT_SID", "")
TWILIO_AUTH_TOKEN = os.getenv("TWILIO_AUTH_TOKEN", "")
TWILIO_PHONE_NUMBER = os.getenv("TWILIO_PHONE_NUMBER", "")
TWILIO_SERVICE_SID = os.getenv("TWILIO_SERVICE_SID", "")

# ── Claude AI ──
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
_HAS_CLAUDE = bool(ANTHROPIC_API_KEY)

# ── OTP ──
_otp_store: dict = {}
_OTP_TTL = 300

# ── Dispatch cache ──
_pending_cache: dict = {}
_PENDING_CACHE_TTL = 3.0
OFFER_TIMEOUT_SECONDS = 20

# ── EmailJS ──
EMAILJS_SERVICE_ID = os.getenv("EMAILJS_SERVICE_ID", "")
EMAILJS_TEMPLATE_ID = os.getenv("EMAILJS_TEMPLATE_ID", "")
EMAILJS_PUBLIC_KEY = os.getenv("EMAILJS_PUBLIC_KEY", "")
EMAILJS_PRIVATE_KEY = os.getenv("EMAILJS_PRIVATE_KEY", "")

# ── Google Maps ──
GOOGLE_MAPS_API_KEY = os.getenv("GOOGLE_MAPS_API_KEY", "")

# ── Monitoring ──
_SERVER_START_TIME = datetime.now(timezone.utc)
_watchdog_stats = {
    "db_failures": 0, "db_reconnects": 0,
    "firebase_failures": 0, "firebase_reconnects": 0,
}
_TUNNEL_URL_FILE = os.path.join(os.path.dirname(__file__), "tunnel_url.txt")

# ── Directories ──
PHOTOS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "photos")
os.makedirs(PHOTOS_DIR, exist_ok=True)
UPLOADS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "uploads")
os.makedirs(os.path.join(UPLOADS_DIR, "documents"), exist_ok=True)

# ── Stripe ──
STRIPE_SECRET = os.getenv("STRIPE_SECRET_KEY", "")
STRIPE_WEBHOOK_SECRET = os.getenv("STRIPE_WEBHOOK_SECRET", "")
_HAS_STRIPE = False
_stripe_mod = None
try:
    import stripe as _stripe_mod
    if STRIPE_SECRET:
        _stripe_mod.api_key = STRIPE_SECRET
        _HAS_STRIPE = True
        logging.info("[Stripe] Initialized with secret key")
except ImportError:
    logging.warning("[Stripe] stripe package not installed")

# ── PayPal ──
PAYPAL_CLIENT_ID = os.getenv("PAYPAL_CLIENT_ID", "")
PAYPAL_SECRET = os.getenv("PAYPAL_SECRET", "")
PAYPAL_SANDBOX = os.getenv("PAYPAL_SANDBOX", "true").lower() == "true"
PAYPAL_CLIENT_SECRET = os.getenv("PAYPAL_CLIENT_SECRET", "")
PAYPAL_MODE = os.getenv("PAYPAL_MODE", "sandbox")

# ── Checkr ──
CHECKR_API_KEY = os.getenv("CHECKR_API_KEY", "")
CHECKR_BASE_URL = os.getenv("CHECKR_BASE_URL", "https://api.checkr.com/v1")

# ── Firestore ──
_HAS_FIRESTORE = False
firestore_sync = None
try:
    from . import firestore_sync as _fs_mod
    firestore_sync = _fs_mod
    _HAS_FIRESTORE = True
except Exception:
    try:
        import firestore_sync as _fs_mod
        firestore_sync = _fs_mod
        _HAS_FIRESTORE = True
    except Exception as _e:
        logging.warning("firestore_sync not available: %s", _e)
'''

config_path = os.path.join(HERE, "config.py")
with open(config_path, "w", encoding="utf-8") as f:
    f.write(config_content)
print(f"[4/7] Created config.py")

# ══════════════════════════════════════════════════════════════
#  STEP 5: Generate router files
# ══════════════════════════════════════════════════════════════

# Common import header used by every router
COMMON_HEADER = '''\
import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text
from sqlalchemy.ext.asyncio import AsyncSession
'''

# Per-router specific imports (from our modules)
ROUTER_IMPORTS = {
    "auth": '''\
from models.database import (
    get_db, SessionLocal, User, ConsentLog, Vehicle, Document, Trip,
)
from models.schemas import (
    RegisterIn, CheckExistsIn, LoginIn, CompleteLoginIn, SocialAuthIn,
    SendOtpIn, VerifyOtpIn, ApplyReferralIn,
)
from utils.security import (
    pwd, _create_token, _create_refresh_token, _create_login_token,
    _get_current_user, _verify_api_key, _require_dispatch_auth,
    _check_login_throttle, _record_login_failure, _clear_login_failures,
    _security_audit_log, _sanitize_string, _record_violation,
    JWT_SECRET, JWT_ALGORITHM, DEV_SKIP_AUTH,
)
from utils.helpers import utc_now, _user_dict, _haversine
from services.fcm_service import _send_fcm_push
from services.email_sms_service import _send_email
from config import (
    _otp_store, _OTP_TTL, PHOTOS_DIR, PUBLIC_URL,
    TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER, TWILIO_SERVICE_SID,
    EMAILJS_SERVICE_ID, EMAILJS_TEMPLATE_ID, EMAILJS_PUBLIC_KEY, EMAILJS_PRIVATE_KEY,
    firestore_sync, _HAS_FIRESTORE,
)
''',
    "trips": '''\
from models.database import (
    get_db, SessionLocal, User, Trip, FareSplit, Rating, ChatMessage, SurgeZone,
)
from models.schemas import CreateTripIn, AcceptTripIn
from utils.security import (
    _get_current_user, _verify_api_key, _security_audit_log,
)
from utils.helpers import utc_now, _haversine, _trip_dict
from services.fcm_service import _send_fcm_push
from config import (
    PUBLIC_URL, STRIPE_SECRET, _HAS_STRIPE, _stripe_mod,
    firestore_sync, _HAS_FIRESTORE,
)
''',
    "drivers": '''\
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
    _haversine, _user_dict, _vehicle_dict, _doc_dict,
)
from services.fcm_service import _send_fcm_push
from config import (
    PUBLIC_URL, STRIPE_SECRET, _HAS_STRIPE, _stripe_mod,
    CHECKR_API_KEY, CHECKR_BASE_URL,
    firestore_sync, _HAS_FIRESTORE,
)
''',
    "dispatch": '''\
from models.database import (
    get_db, SessionLocal, User, Trip, DispatchOffer, Vehicle,
    SupportChat, SupportMessage, ActionRequest,
)
from models.schemas import OwnerLogin, DispatchRequestIn
from utils.security import (
    pwd, _get_current_user, _verify_api_key, _require_dispatch_auth,
    _dispatch_sessions, _security_audit_log,
    JWT_SECRET, JWT_ALGORITHM,
)
from utils.helpers import utc_now, _haversine, _trip_dict, _user_dict
from services.fcm_service import _send_fcm_push
from config import (
    OWNER_EMAIL, OWNER_PASSWORD_HASH, OWNER_PASSWORD,
    DISPATCH_ALLOWED_IPS, PUBLIC_URL,
    _pending_cache, _PENDING_CACHE_TTL, OFFER_TIMEOUT_SECONDS,
    firestore_sync, _HAS_FIRESTORE,
)
''',
    "support": '''\
from models.database import (
    get_db, SessionLocal, User, Trip, SupportChat, SupportMessage, ActionRequest,
)
from utils.security import (
    _get_current_user, _verify_api_key, _require_dispatch_auth,
    _security_audit_log,
)
from utils.helpers import utc_now, _support_msg_dict
from services.fcm_service import _send_fcm_push
from config import (
    ANTHROPIC_API_KEY, _HAS_CLAUDE,
    firestore_sync, _HAS_FIRESTORE,
)
from support_cache import find_cached_response, add_natural_variation, claude_health, maybe_cache_response
''',
    "voice": '''\
from config import TWILIO_PHONE_NUMBER
''',
    "payments": '''\
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
''',
    "admin": '''\
from models.database import (
    get_db, SessionLocal, User, Trip, Vehicle, Document, Rating,
    SupportChat, RiderPaymentMethod, SurgeZone, DispatchOffer, DriverIncentive,
)
from models.schemas import AdminStatsResponse
from utils.security import (
    _get_current_user, _require_admin, _verify_api_key,
    _require_dispatch_auth, _security_audit_log,
)
from utils.helpers import (
    utc_now, utc_today_start, utc_month_start,
    _user_dict, _trip_dict, _haversine,
)
from services.fcm_service import _send_fcm_push
from config import (
    PUBLIC_URL, UPLOADS_DIR,
    firestore_sync, _HAS_FIRESTORE,
)
''',
    "misc": '''\
from models.database import (
    get_db, SessionLocal, User, Trip, PromoCode, Notification,
    PasswordResetToken, SurgeZone, ServiceArea,
    Referral, FavoriteLocation,
)
from utils.security import (
    _get_current_user, _verify_api_key, _security_audit_log,
)
from utils.helpers import utc_now, _haversine
from services.fcm_service import _send_fcm_push
from services.email_sms_service import _send_email
from config import (
    PUBLIC_URL, GOOGLE_MAPS_API_KEY, _TUNNEL_URL_FILE,
    TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER,
    firestore_sync, _HAS_FIRESTORE,
)
''',
}

ROUTER_NAMES = ["auth", "trips", "drivers", "dispatch", "support", "voice", "payments", "admin", "misc"]
created_files = []

for rname in ROUTER_NAMES:
    # Gather all lines owned by this router, in order
    rlines = []
    for i in range(N):
        if own[i] == rname:
            rlines.append(lines[i])

    if not rlines:
        print(f"  ├ {rname}.py — SKIPPED (0 lines)")
        continue

    # Replace @app. with @router. in the collected lines
    for k in range(len(rlines)):
        if EP.match(rlines[k]):
            rlines[k] = rlines[k].replace("@app.", "@router.", 1)

    # Build the file
    header = COMMON_HEADER + (ROUTER_IMPORTS.get(rname, "") or "") + "\nrouter = APIRouter()\n\n"
    body = "".join(rlines)

    fpath = os.path.join(ROUTERS, f"{rname}.py")
    with open(fpath, "w", encoding="utf-8") as f:
        f.write(header)
        f.write(body)
    created_files.append(rname)
    line_count = header.count("\n") + body.count("\n")
    print(f"  ├ {rname}.py — {line_count} lines")

print(f"[5/7] Created {len(created_files)} router files")

# ══════════════════════════════════════════════════════════════
#  STEP 6: Rewrite main.py
# ══════════════════════════════════════════════════════════════

# Keep only lines not assigned to any router
keep = []
for i in range(N):
    if own[i] is None:
        keep.append(lines[i])

# Remove config var definitions now in config.py (they're in the "keep" section).
# ONLY remove top-level (indent=0) config lines that are NOT inside a function body.
CONFIG_REMOVALS = [
    re.compile(r"^OWNER_EMAIL\s*="),
    re.compile(r"^OWNER_PASSWORD_HASH\s*="),
    re.compile(r"^OWNER_PASSWORD\s*="),
    re.compile(r"^PUBLIC_URL\s*="),
    re.compile(r"^DISPATCH_ALLOWED_IPS\s*="),
    re.compile(r"^TWILIO_ACCOUNT_SID\s*="),
    re.compile(r"^TWILIO_AUTH_TOKEN\s*="),
    re.compile(r"^TWILIO_PHONE_NUMBER\s*="),
    re.compile(r"^TWILIO_SERVICE_SID\s*="),
    re.compile(r"^ANTHROPIC_API_KEY\s*="),
    re.compile(r"^_HAS_CLAUDE\s*="),
    re.compile(r"^_otp_store:\s*dict"),
    re.compile(r"^_OTP_TTL\s*="),
    re.compile(r"^_pending_cache:\s*dict"),
    re.compile(r"^_PENDING_CACHE_TTL\s*="),
    re.compile(r"^OFFER_TIMEOUT_SECONDS\s*="),
    re.compile(r"^EMAILJS_SERVICE_ID\s*="),
    re.compile(r"^EMAILJS_TEMPLATE_ID\s*="),
    re.compile(r"^EMAILJS_PUBLIC_KEY\s*="),
    re.compile(r"^EMAILJS_PRIVATE_KEY\s*="),
    re.compile(r"^GOOGLE_MAPS_API_KEY\s*="),
    re.compile(r"^_SERVER_START_TIME\s*="),
    re.compile(r"^_TUNNEL_URL_FILE\s*="),
]

remove_indices = set()
for i, line in enumerate(keep):
    # Only match top-level (non-indented) lines
    if line[0:1] in (" ", "\t"):
        continue
    for pat in CONFIG_REMOVALS:
        if pat.match(line):
            remove_indices.add(i)
            break

# Remove _watchdog_stats multi-line dict (top-level only)
for i, line in enumerate(keep):
    if re.match(r"^_watchdog_stats\s*=\s*\{", line):
        remove_indices.add(i)
        j = i + 1
        while j < len(keep) and "}" not in keep[j]:
            remove_indices.add(j)
            j += 1
        if j < len(keep):
            remove_indices.add(j)

# Remove top-level Firestore try/import/except block (only the top-level one)
for i, line in enumerate(keep):
    if line[0:1] in (" ", "\t"):
        continue  # skip indented code
    if line.strip() == "try:" and i + 1 < len(keep) and "import firestore_sync" in keep[i + 1]:
        j = i
        while j < len(keep):
            remove_indices.add(j)
            stripped = keep[j].strip()
            if stripped.startswith("logging.warning") and "firestore_sync" in keep[j]:
                break
            # Safety: stop if we hit a non-indented def/class/decorator after try
            if j > i + 1 and keep[j][0:1] not in (" ", "\t", ""):
                if not stripped.startswith(("except", "logging", "try", "#", "")):
                    break
            j += 1
        break  # only one firestore import block

# Remove os.makedirs for photos/uploads (top-level only)
for i, line in enumerate(keep):
    if line[0:1] in (" ", "\t"):
        continue
    if "os.makedirs(" in line and ("photos" in line or "uploads" in line):
        remove_indices.add(i)

# Remove stale comment lines for config descriptions
for i, line in enumerate(keep):
    if line[0:1] in (" ", "\t"):
        continue
    s = line.strip()
    if s in ("# -- Config ----------------------------------------------",
             "# ── In-memory OTP store: phone → {code, expires} ──",
             "# L3: per-driver response cache for /dispatch/driver/pending",
             "# Prevents DB hammering when client polls faster than the 5-second interval",
             "# ── EmailJS configuration (preferred over SMTP) ──",
             "# ── Claude AI for support chat ──",
             "# ── Monitoring globals ──────────────────────────────────────────",
             "# -- Firestore Sync -------------------------------------"):
        remove_indices.add(i)

# Build cleaned keep, collapsing runs of 3+ blank lines
cleaned_keep = []
prev_blank = False
for i, line in enumerate(keep):
    if i in remove_indices:
        continue
    is_blank = line.strip() == ""
    if is_blank and prev_blank:
        continue
    cleaned_keep.append(line)
    prev_blank = is_blank

# Now we need to:
# 1. Add config imports to the top of main.py
# 2. Add include_router() calls after `app = FastAPI(...)`

# Find where to insert config import (after the existing module imports)
new_main_lines = []
inserted_config_import = False
inserted_routers = False

CONFIG_IMPORT = """\
# ── Configuration (env vars, shared state) ─────────────────────
from config import (
    _SERVER_START_TIME, _watchdog_stats, _HAS_FIRESTORE, firestore_sync,
    STRIPE_SECRET, PHOTOS_DIR, UPLOADS_DIR,
)
"""

ROUTER_INCLUDES = """\

# ── Router modules ─────────────────────────────────────────────
from routers.auth import router as auth_router
from routers.trips import router as trips_router
from routers.drivers import router as drivers_router
from routers.dispatch import router as dispatch_router
from routers.support import router as support_router
from routers.voice import router as voice_router
from routers.payments import router as payments_router
from routers.admin import router as admin_router
from routers.misc import router as misc_router

app.include_router(auth_router)
app.include_router(trips_router)
app.include_router(drivers_router)
app.include_router(dispatch_router)
app.include_router(support_router)
app.include_router(voice_router)
app.include_router(payments_router)
app.include_router(admin_router)
app.include_router(misc_router)
"""

for i, line in enumerate(cleaned_keep):
    # Insert config import after "from services.email_sms_service import"
    if not inserted_config_import and "from services.email_sms_service" in line:
        new_main_lines.append(line)
        new_main_lines.append("\n")
        new_main_lines.append(CONFIG_IMPORT)
        inserted_config_import = True
        continue
    # Insert router includes after "app = FastAPI(...)" line
    if not inserted_routers and line.strip().startswith("app = FastAPI("):
        new_main_lines.append(line)
        new_main_lines.append(ROUTER_INCLUDES)
        inserted_routers = True
        continue
    new_main_lines.append(line)

# Write new main.py
main_text = "".join(new_main_lines)

# Collapse runs of 3+ blank lines into 2
main_text = re.sub(r'\n{4,}', '\n\n\n', main_text)

with open(MAIN, "w", encoding="utf-8") as f:
    f.write(main_text)

new_line_count = main_text.count("\n")
print(f"[6/7] Rewrote main.py — {new_line_count} lines (was {N})")
print(f"  └ Removed {N - new_line_count} lines ({100*(N-new_line_count)//N}%)")

# ══════════════════════════════════════════════════════════════
#  STEP 7: Update routers/__init__.py
# ══════════════════════════════════════════════════════════════

init_path = os.path.join(ROUTERS, "__init__.py")
with open(init_path, "w", encoding="utf-8") as f:
    f.write("# Router package — imported by main.py\n")
print(f"[7/7] Updated routers/__init__.py")

print("\n✅ Extraction complete!")
print(f"   Created: config.py + {len(created_files)} router files")
print(f"   main.py: {N} → {new_line_count} lines")
