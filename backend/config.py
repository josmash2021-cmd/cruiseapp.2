"""Cruise Backend — Shared configuration, env vars, and state."""
import os, logging
from datetime import datetime

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
_SERVER_START_TIME = datetime.utcnow()
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

# ── n8n Webhooks ──
N8N_WEBHOOK_BASE = os.getenv("N8N_WEBHOOK_BASE", "")  # e.g. https://n8n.example.com/webhook
_HAS_N8N = bool(N8N_WEBHOOK_BASE)
