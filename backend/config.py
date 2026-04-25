"""Cruise Backend — Shared configuration, env vars, and state."""
import os, logging, time
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
_MAX_OTP_ENTRIES = 5000  # cap for memory safety

# ── Dispatch cache ──
_pending_cache: dict = {}
_PENDING_CACHE_TTL = 1.5  # Short TTL — offers are time-critical; invalidated on accept/reject
_MAX_PENDING_CACHE = 5000
OFFER_TIMEOUT_SECONDS = 20  # seconds — UI countdown for driver to tap Accept (reduced from 45 to cut rider wait)

# ── Nearby drivers cache (in-memory, short TTL) ──
_nearby_cache: dict = {}  # key=(lat_rounded, lng_rounded, radius) -> (timestamp, result)
_NEARBY_CACHE_TTL = 3.0  # seconds — invalidated per-cell on driver location update
_MAX_NEARBY_CACHE = 3000

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


def sweep_caches():
    """Evict expired entries from all in-memory caches. Call periodically."""
    now = time.monotonic()
    # OTP — entries store "expires" as time.time() epoch
    import time as _time
    _expired = [k for k, v in _otp_store.items() if _time.time() > v.get("expires", 0)]
    for k in _expired:
        _otp_store.pop(k, None)
    if len(_otp_store) > _MAX_OTP_ENTRIES:
        _otp_store.clear()
    # Pending
    _expired = [k for k, v in _pending_cache.items() if now - v[0] > _PENDING_CACHE_TTL]
    for k in _expired:
        _pending_cache.pop(k, None)
    if len(_pending_cache) > _MAX_PENDING_CACHE:
        # Evict oldest half instead of nuking everything
        sorted_keys = sorted(_pending_cache, key=lambda k: _pending_cache[k][0])
        for k in sorted_keys[:len(sorted_keys) // 2]:
            _pending_cache.pop(k, None)
    # Nearby
    _expired = [k for k, v in _nearby_cache.items() if now - v[0] > _NEARBY_CACHE_TTL]
    for k in _expired:
        _nearby_cache.pop(k, None)
    if len(_nearby_cache) > _MAX_NEARBY_CACHE:
        sorted_keys = sorted(_nearby_cache, key=lambda k: _nearby_cache[k][0])
        for k in sorted_keys[:len(sorted_keys) // 2]:
            _nearby_cache.pop(k, None)

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
    _HAS_STRIPE = True  # SDK available regardless of API key configuration
    if STRIPE_SECRET:
        _stripe_mod.api_key = STRIPE_SECRET
        logging.info("[Stripe] Initialized with secret key")
except ImportError:
    logging.warning("[Stripe] stripe package not installed")

# ── PayPal ──
PAYPAL_CLIENT_ID = os.getenv("PAYPAL_CLIENT_ID", "")
PAYPAL_SECRET = os.getenv("PAYPAL_SECRET", "")
PAYPAL_SANDBOX = os.getenv("PAYPAL_SANDBOX", "false").lower() in ("true", "1", "yes", "on")
# PAYPAL_CLIENT_SECRET falls back to PAYPAL_SECRET for Railway compatibility
PAYPAL_CLIENT_SECRET = os.getenv("PAYPAL_CLIENT_SECRET", "") or PAYPAL_SECRET
PAYPAL_MODE = os.getenv("PAYPAL_MODE", "live")

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

# ── n8n Webhooks ──
N8N_WEBHOOK_BASE = os.getenv("N8N_WEBHOOK_BASE", "")  # e.g. https://n8n.example.com/webhook
_HAS_N8N = bool(N8N_WEBHOOK_BASE)
