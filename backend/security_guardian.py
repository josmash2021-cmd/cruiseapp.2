"""
Security Guardian Agent - BLOCK FIRST, ASK QUESTIONS LATER

Prevents hacking, fraud, DDoS attacks, and any attempt to manipulate the server.
This agent is ALWAYS active and blocks threats BEFORE they cause damage.

Components:
- RateLimiter: Prevents DDoS and brute force attacks
- InputSanitizer: Prevents SQL injection, XSS, command injection, path traversal
- AuthGuardian: Prevents unauthorized access and privilege escalation
- FraudDetector: Prevents ride fraud, fare manipulation, GPS spoofing
- SecurityGuardian: Master orchestrator for all security checks
"""

import re
import html
import time
import json
import asyncio
import logging
import hashlib
from collections import defaultdict
from typing import Optional, Tuple, Dict, Any
from math import radians, sin, cos, sqrt, atan2
from datetime import datetime, timezone
from pathlib import Path

from fastapi import Request
from fastapi.responses import JSONResponse

_BLOCKED_IPS_FILE = Path(__file__).parent / "blocked_ips.json"


def _load_blocked_ips() -> Dict[str, float]:
    """Load persisted blocked IPs from disk, filtering expired ones."""
    try:
        if _BLOCKED_IPS_FILE.exists():
            data = json.loads(_BLOCKED_IPS_FILE.read_text())
            now = time.time()
            return {ip: t for ip, t in data.items() if t > now}
    except Exception:
        pass
    return {}


def _save_blocked_ips(blocked: Dict[str, float]) -> None:
    """Persist blocked IPs to disk so they survive restarts."""
    try:
        now = time.time()
        active = {ip: t for ip, t in blocked.items() if t > now}
        _BLOCKED_IPS_FILE.write_text(json.dumps(active))
    except Exception:
        pass

logger = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════════════
# 1. RATE LIMITER - Prevent DDoS and Brute Force
# ══════════════════════════════════════════════════════════════════════════════

class RateLimiter:
    """Prevents abuse by limiting requests per IP and per user"""

    def __init__(self):
        self._ip_requests: Dict[str, list] = defaultdict(list)  # IP → [timestamps]
        self._user_requests: Dict[str, list] = defaultdict(list)  # user_id → [timestamps]
        self._blocked_ips: Dict[str, float] = _load_blocked_ips()  # IP → block_until_timestamp (persisted)
        self._ip_warnings: Dict[str, int] = defaultdict(int)  # IP → warning count
        self._auth_attempts: Dict[str, list] = defaultdict(list)  # IP → auth timestamps

        # Limits
        self.MAX_REQUESTS_PER_MINUTE = 120  # normal usage (raised for mobile polling)
        self.MAX_REQUESTS_PER_SECOND = 15  # burst protection
        self.MAX_AUTH_ATTEMPTS_PER_HOUR = 10  # login brute force protection
        self.MAX_DISPATCH_REQUESTS_PER_MINUTE = 10  # ride request spam protection
        self.BLOCK_DURATION_SECONDS = 300  # 5 minute block
        self.SEVERE_BLOCK_DURATION = 3600  # 1 hour for severe offenses

    def is_blocked(self, ip: str) -> bool:
        """Check if IP is currently blocked"""
        if ip in self._blocked_ips:
            if time.time() < self._blocked_ips[ip]:
                return True
            else:
                del self._blocked_ips[ip]  # block expired
                self._ip_warnings[ip] = 0  # reset warnings
        return False

    def block_ip(self, ip: str, duration: int = None, reason: str = ""):
        """Block an IP address and persist to disk so it survives restarts."""
        duration = duration or self.BLOCK_DURATION_SECONDS
        self._blocked_ips[ip] = time.time() + duration
        _save_blocked_ips(self._blocked_ips)
        logger.critical(f"🔒 IP BLOCKED: {ip} for {duration}s — reason: {reason}")

    def check_rate(self, ip: str, endpoint: str = "", user_id: str = None) -> Tuple[bool, str]:
        """Returns (is_allowed, reason). is_allowed=True means request can proceed."""
        now = time.time()

        # Clean old entries (older than 1 hour)
        self._ip_requests[ip] = [t for t in self._ip_requests[ip] if now - t < 3600]

        # Check per-second burst
        recent_1s = [t for t in self._ip_requests[ip] if now - t < 1]
        if len(recent_1s) >= self.MAX_REQUESTS_PER_SECOND:
            self._ip_warnings[ip] += 1
            if self._ip_warnings[ip] >= 3:
                self.block_ip(ip, reason="burst rate limit exceeded 3 times")
            return False, "burst_rate_exceeded"

        # Check per-minute rate
        recent_1m = [t for t in self._ip_requests[ip] if now - t < 60]
        if len(recent_1m) >= self.MAX_REQUESTS_PER_MINUTE:
            self._ip_warnings[ip] += 1
            if self._ip_warnings[ip] >= 5:
                self.block_ip(ip, reason="minute rate limit exceeded 5 times")
            return False, "minute_rate_exceeded"

        # Check auth endpoint specifically (brute force protection)
        if '/auth/login' in endpoint or '/auth/signin' in endpoint or '/auth/register' in endpoint:
            self._auth_attempts[ip] = [t for t in self._auth_attempts[ip] if now - t < 3600]
            self._auth_attempts[ip].append(now)
            if len(self._auth_attempts[ip]) >= self.MAX_AUTH_ATTEMPTS_PER_HOUR:
                self.block_ip(ip, duration=self.SEVERE_BLOCK_DURATION, reason="too many auth attempts")
                return False, "auth_brute_force"

        # Check dispatch endpoint (ride request spam)
        if '/dispatch' in endpoint and 'driver' not in endpoint:
            user_key = user_id or ip
            self._user_requests[user_key] = [t for t in self._user_requests[user_key] if now - t < 60]
            if len(self._user_requests[user_key]) >= self.MAX_DISPATCH_REQUESTS_PER_MINUTE:
                logger.warning(f"🔒 Ride request spam from {user_key}")
                return False, "dispatch_spam"
            self._user_requests[user_key].append(now)

        # Record this request
        self._ip_requests[ip].append(now)

        return True, ""

    def get_blocked_count(self) -> int:
        """How many IPs are currently blocked"""
        now = time.time()
        # Clean expired blocks
        expired = [ip for ip, t in self._blocked_ips.items() if t <= now]
        for ip in expired:
            del self._blocked_ips[ip]
        return len(self._blocked_ips)

    def get_stats(self) -> dict:
        """Get rate limiter statistics"""
        now = time.time()
        return {
            "blocked_ips": self.get_blocked_count(),
            "tracked_ips": len(self._ip_requests),
            "warnings_issued": sum(self._ip_warnings.values()),
        }


# ══════════════════════════════════════════════════════════════════════════════
# 2. INPUT SANITIZER - Prevent Injection Attacks
# ══════════════════════════════════════════════════════════════════════════════

class InputSanitizer:
    """Sanitizes ALL input to prevent SQL injection, XSS, command injection"""

    # Dangerous patterns - SQL injection
    SQL_PATTERNS = [
        r"(\b(SELECT|INSERT|UPDATE|DELETE|DROP|UNION|ALTER|CREATE|EXEC|EXECUTE)\b\s+.*(FROM|INTO|TABLE|SET|WHERE|VALUES))",
        r"(--\s|;\s*--|/\*|\*/)",
        r"(\bOR\b\s+['\"]*\d+['\"]*\s*=\s*['\"]*\d+)",  # OR 1=1 variations
        r"('\s*(OR|AND)\s+')",
        r"(WAITFOR\s+DELAY|SLEEP\s*\(|BENCHMARK\s*\()",  # Time-based injection
        r"(@@version|@@servername|version\(\))",  # Info disclosure
    ]

    # XSS patterns
    XSS_PATTERNS = [
        r"<script[^>]*>",
        r"javascript\s*:",
        r"on(click|load|error|mouseover|focus|blur|submit|change|input)\s*=",
        r"<iframe[^>]*>",
        r"<object[^>]*>",
        r"<embed[^>]*>",
        r"<svg[^>]*onload",
        r"eval\s*\(",
        r"document\.(cookie|location|write|domain)",
        r"window\.(location|open)",
        r"innerHTML\s*=",
        r"outerHTML\s*=",
    ]

    # Command injection patterns
    COMMAND_PATTERNS = [
        r"[;&|`$]",  # shell metacharacters
        r"\|{2}",  # ||
        r"&{2}",  # &&
        r"\$\(",  # $(command)
        r"`[^`]+`",  # `command`
        r"(^|\s)(cat|ls|rm|wget|curl|nc|bash|sh|python|perl|ruby|php|node)\s",
    ]

    # Path traversal patterns
    PATH_TRAVERSAL_PATTERNS = [
        r"\.\./",
        r"\.\.\\",
        r"%2e%2e[%/\\]",
        r"%252e%252e",
        r"\.\.%00",
        r"/etc/(passwd|shadow|hosts)",
        r"c:\\windows",
        r"\\\\[a-z0-9_]+\\",  # UNC paths
    ]

    # Whitelist fields that may contain special characters
    ALLOWED_SPECIAL_FIELDS = {
        "password", "password_hash", "card_number", "cvv", "notes",
        "pickup_address", "dropoff_address", "message", "content"
    }

    def is_malicious(self, value: str, field_name: str = "") -> Tuple[bool, Optional[str]]:
        """Check if input contains malicious content. Returns (is_malicious, threat_type)"""
        if not isinstance(value, str):
            return False, None

        if not value or len(value) < 3:
            return False, None

        # Skip checking certain fields that legitimately contain special chars
        if field_name.lower() in self.ALLOWED_SPECIAL_FIELDS:
            # Still check for obvious injection in these fields
            if re.search(r"<script|javascript:|eval\(", value, re.IGNORECASE):
                return True, "XSS"
            return False, None

        for pattern in self.SQL_PATTERNS:
            if re.search(pattern, value, re.IGNORECASE):
                return True, "SQL_INJECTION"

        for pattern in self.XSS_PATTERNS:
            if re.search(pattern, value, re.IGNORECASE):
                return True, "XSS"

        # Only check command injection for certain contexts
        if field_name.lower() not in {"query", "search", "address", "name"}:
            for pattern in self.COMMAND_PATTERNS:
                if re.search(pattern, value):
                    return True, "COMMAND_INJECTION"

        for pattern in self.PATH_TRAVERSAL_PATTERNS:
            if re.search(pattern, value, re.IGNORECASE):
                return True, "PATH_TRAVERSAL"

        return False, None

    def sanitize(self, value: str) -> str:
        """Clean input — escape HTML, remove dangerous characters"""
        if not isinstance(value, str):
            return value

        # Escape HTML entities
        value = html.escape(value)

        # Remove null bytes
        value = value.replace('\x00', '')

        # Remove other dangerous control characters
        value = re.sub(r'[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]', '', value)

        # Limit length (prevent buffer overflow attempts)
        if len(value) > 10000:
            value = value[:10000]

        return value.strip()

    def scan_request_body(self, body: Any, ip: str, depth: int = 0) -> Tuple[bool, Optional[dict]]:
        """Scan entire request body for threats. Returns (is_safe, threat_details)"""
        if depth > 10:  # Prevent deep recursion attacks
            return True, None

        if isinstance(body, dict):
            for key, value in body.items():
                if isinstance(value, str):
                    is_malicious, threat_type = self.is_malicious(value, key)
                    if is_malicious:
                        logger.critical(
                            f"🚨 ATTACK DETECTED from {ip}: {threat_type} in field '{key}' — "
                            f"value: {value[:100]}"
                        )
                        return False, {"type": threat_type, "field": key}
                elif isinstance(value, (dict, list)):
                    is_safe, details = self.scan_request_body(value, ip, depth + 1)
                    if not is_safe:
                        return False, details

        elif isinstance(body, list):
            for item in body:
                is_safe, details = self.scan_request_body(item, ip, depth + 1)
                if not is_safe:
                    return False, details

        return True, None


# ══════════════════════════════════════════════════════════════════════════════
# 3. AUTH GUARDIAN - Prevent Unauthorized Access
# ══════════════════════════════════════════════════════════════════════════════

class AuthGuardian:
    """Prevents unauthorized access, token forgery, and privilege escalation"""

    def __init__(self):
        self._revoked_tokens: set = set()
        self._suspicious_users: Dict[str, int] = defaultdict(int)
        self._max_revoked_tokens = 10000

    def revoke_token(self, token: str):
        """Add token to revocation list"""
        # Hash the token for storage efficiency
        token_hash = hashlib.sha256(token.encode()).hexdigest()[:32]
        self._revoked_tokens.add(token_hash)
        # Limit size
        if len(self._revoked_tokens) > self._max_revoked_tokens:
            # Remove oldest (approximation - just pop one)
            self._revoked_tokens.pop()

    def is_token_revoked(self, token: str) -> bool:
        """Check if token has been revoked"""
        token_hash = hashlib.sha256(token.encode()).hexdigest()[:32]
        return token_hash in self._revoked_tokens

    async def validate_request(self, request: Request, user_data: dict = None) -> Tuple[bool, str]:
        """Validate that the request is from a legitimate authenticated user.
        Returns (is_valid, reason)"""

        # Check auth header exists for protected routes
        auth_header = request.headers.get("Authorization", "")
        if not auth_header and self._requires_auth(request.url.path):
            return False, "missing_auth"

        # Check token format
        if auth_header:
            if not auth_header.startswith("Bearer "):
                ip = self._get_ip(request)
                logger.warning(f"🔒 Malformed auth header from {ip}")
                return False, "malformed_token"

            token = auth_header.replace("Bearer ", "")

            # Check if token is revoked
            if self.is_token_revoked(token):
                ip = self._get_ip(request)
                logger.warning(f"🔒 Revoked token used from {ip}")
                return False, "revoked_token"

        # Check for privilege escalation attempts
        if user_data:
            if await self._is_privilege_escalation(request, user_data):
                ip = self._get_ip(request)
                user_id = user_data.get('uid', user_data.get('id', 'unknown'))
                logger.critical(f"🚨 PRIVILEGE ESCALATION attempt from {ip}, user {user_id}")
                self._suspicious_users[str(user_id)] += 1
                return False, "privilege_escalation"

        return True, ""

    async def _is_privilege_escalation(self, request: Request, user_data: dict) -> bool:
        """Detect if user is trying to access resources they shouldn't"""
        path = request.url.path
        method = request.method
        user_role = user_data.get('role', 'rider')
        user_id = str(user_data.get('uid', user_data.get('id', '')))

        # Driver-only endpoints accessed by rider
        driver_write_endpoints = ['/drivers/', '/dispatch/driver/', '/earnings/']
        if user_role == 'rider':
            for ep in driver_write_endpoints:
                if ep in path and method in ['PATCH', 'PUT', 'DELETE', 'POST']:
                    # Allow riders to view driver info, block modifications
                    return True

        # Admin-only endpoints
        admin_endpoints = ['/admin/', '/users/all', '/analytics/', '/security/']
        if user_role not in ('admin', 'owner'):
            for ep in admin_endpoints:
                if ep in path:
                    return True

        # User trying to modify another user's data
        if '/users/' in path and method in ['PATCH', 'PUT', 'DELETE']:
            # Extract user ID from path like /users/123/profile
            parts = path.split('/users/')
            if len(parts) > 1:
                path_user_id = parts[1].split('/')[0]
                if path_user_id.isdigit() and path_user_id != user_id:
                    if user_role != 'admin':
                        return True

        return False

    def _requires_auth(self, path: str) -> bool:
        """Check if this endpoint requires authentication"""
        public_paths = [
            '/health', '/auth/login', '/auth/signup', '/auth/register',
            '/auth/forgot-password', '/auth/reset-password', '/auth/verify',
            '/docs', '/openapi.json', '/redoc', '/', '/dispatch',
            '/places/', '/vehicles/types'
        ]
        for p in public_paths:
            if path.startswith(p) or path == p:
                return False
        return True

    def _get_ip(self, request: Request) -> str:
        forwarded = request.headers.get("X-Forwarded-For", "")
        if forwarded:
            return forwarded.split(",")[0].strip()
        return request.client.host if request.client else "unknown"


# ══════════════════════════════════════════════════════════════════════════════
# 4. FRAUD DETECTOR - Prevent Ride Fraud and Payment Manipulation
# ══════════════════════════════════════════════════════════════════════════════

class FraudDetector:
    """Detects and prevents fraud in rides and payments"""

    def __init__(self):
        self._ride_patterns: Dict[str, list] = defaultdict(list)  # user_id → timestamps
        self._driver_locations: Dict[str, tuple] = {}  # driver_id → (lat, lng, timestamp)
        self._suspicious_users: Dict[str, int] = defaultdict(int)

    async def check_ride_request(
        self, user_id: str, pickup: dict, dropoff: dict, ip: str
    ) -> Tuple[bool, str]:
        """Check ride request for fraud patterns. Returns (is_legitimate, reason)"""

        # 1. Too many ride requests in short time (bot behavior)
        now = time.time()
        self._ride_patterns[user_id] = [
            t for t in self._ride_patterns[user_id] if now - t < 300
        ]
        if len(self._ride_patterns[user_id]) > 15:
            logger.critical(
                f"🚨 FRAUD: User {user_id} made {len(self._ride_patterns[user_id])} "
                f"ride requests in 5 min"
            )
            self._suspicious_users[user_id] += 1
            return False, "too_many_requests"
        self._ride_patterns[user_id].append(now)

        # 2. Validate coordinates exist
        pickup_lat = pickup.get('lat', pickup.get('latitude'))
        pickup_lng = pickup.get('lng', pickup.get('longitude'))
        dropoff_lat = dropoff.get('lat', dropoff.get('latitude'))
        dropoff_lng = dropoff.get('lng', dropoff.get('longitude'))

        if not all([pickup_lat, pickup_lng, dropoff_lat, dropoff_lng]):
            return False, "invalid_coordinates"

        try:
            pickup_lat, pickup_lng = float(pickup_lat), float(pickup_lng)
            dropoff_lat, dropoff_lng = float(dropoff_lat), float(dropoff_lng)
        except (ValueError, TypeError):
            return False, "invalid_coordinates"

        # 3. Impossibly short or long distances
        distance_km = self._haversine(
            {'lat': pickup_lat, 'lng': pickup_lng},
            {'lat': dropoff_lat, 'lng': dropoff_lng}
        )
        if distance_km < 0.05:  # less than 50 meters
            logger.warning(f"🔒 Suspicious ride: {distance_km:.3f}km distance from user {user_id}")
            return False, "distance_too_short"
        if distance_km > 800:  # more than 800km
            logger.warning(f"🔒 Suspicious ride: {distance_km:.0f}km distance from user {user_id}")
            return False, "distance_too_long"

        # 4. Same pickup and dropoff
        if (abs(pickup_lat - dropoff_lat) < 0.0001 and
            abs(pickup_lng - dropoff_lng) < 0.0001):
            return False, "same_location"

        # 5. Coordinates must be valid lat/lng ranges
        if not (-90 <= pickup_lat <= 90 and -180 <= pickup_lng <= 180):
            return False, "invalid_pickup_coordinates"
        if not (-90 <= dropoff_lat <= 90 and -180 <= dropoff_lng <= 180):
            return False, "invalid_dropoff_coordinates"

        return True, ""

    async def check_fare_manipulation(
        self, trip_id: str, claimed_fare: float, calculated_fare: float
    ) -> Tuple[bool, str]:
        """Detect if someone is trying to manipulate the fare"""
        if calculated_fare <= 0:
            return True, ""  # Can't validate without calculated fare

        # Allow 10% tolerance for rounding and surge
        tolerance = calculated_fare * 0.10

        if claimed_fare < calculated_fare - tolerance:
            logger.critical(
                f"🚨 FARE FRAUD: Trip {trip_id} claimed ${claimed_fare:.2f} "
                f"but calculated ${calculated_fare:.2f}"
            )
            return False, "fare_too_low"

        if claimed_fare > calculated_fare * 4:  # more than 4x calculated
            logger.critical(
                f"🚨 FARE FRAUD: Trip {trip_id} claimed ${claimed_fare:.2f} "
                f"but calculated ${calculated_fare:.2f}"
            )
            return False, "fare_too_high"

        return True, ""

    async def check_driver_location_spoofing(
        self,
        driver_id: str,
        reported_lat: float,
        reported_lng: float,
    ) -> Tuple[bool, str]:
        """Detect GPS spoofing — driver reporting impossible movements"""
        now = time.time()

        # Get previous location
        prev = self._driver_locations.get(driver_id)
        if not prev:
            self._driver_locations[driver_id] = (reported_lat, reported_lng, now)
            return True, ""

        previous_lat, previous_lng, prev_time = prev
        time_diff_seconds = now - prev_time

        # Only check if there's meaningful time difference
        if time_diff_seconds < 1:
            return True, ""

        distance_km = self._haversine(
            {'lat': previous_lat, 'lng': previous_lng},
            {'lat': reported_lat, 'lng': reported_lng}
        )

        # Speed in km/h
        speed_kmh = (distance_km / time_diff_seconds) * 3600

        # Update stored location
        self._driver_locations[driver_id] = (reported_lat, reported_lng, now)

        # No car goes faster than 300 km/h (186 mph)
        # Being generous for GPS jitter and tunnels
        if speed_kmh > 300:
            logger.critical(
                f"🚨 GPS SPOOFING: Driver {driver_id} moved {distance_km:.1f}km in "
                f"{time_diff_seconds:.0f}s = {speed_kmh:.0f}km/h — IMPOSSIBLE"
            )
            return False, "gps_spoofing"

        return True, ""

    def _haversine(self, coord1: dict, coord2: dict) -> float:
        """Calculate distance between two points in km"""
        R = 6371  # Earth radius in km
        lat1, lat2 = radians(coord1['lat']), radians(coord2['lat'])
        dlat = radians(coord2['lat'] - coord1['lat'])
        dlng = radians(coord2['lng'] - coord1['lng'])
        a = sin(dlat / 2) ** 2 + cos(lat1) * cos(lat2) * sin(dlng / 2) ** 2
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))

    def get_stats(self) -> dict:
        """Get fraud detector statistics"""
        return {
            "tracked_drivers": len(self._driver_locations),
            "suspicious_users": len(self._suspicious_users),
            "active_ride_patterns": len(self._ride_patterns),
        }


# ══════════════════════════════════════════════════════════════════════════════
# 5. SECURITY HEADERS - Harden All Responses
# ══════════════════════════════════════════════════════════════════════════════

class SecurityHeaders:
    """Add security headers to every response"""

    @staticmethod
    async def add_headers(request: Request, call_next):
        response = await call_next(request)

        # Prevent clickjacking
        response.headers["X-Frame-Options"] = "DENY"

        # Prevent MIME sniffing
        response.headers["X-Content-Type-Options"] = "nosniff"

        # XSS protection
        response.headers["X-XSS-Protection"] = "1; mode=block"

        # Strict transport security (HTTPS only)
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"

        # Don't expose server info
        response.headers["Server"] = "CruiseApp"

        # Referrer policy
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"

        # Prevent caching of sensitive data
        path = str(request.url.path)
        if any(p in path for p in ['/auth/', '/payment/', '/users/', '/wallet/']):
            response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
            response.headers["Pragma"] = "no-cache"

        return response


# ══════════════════════════════════════════════════════════════════════════════
# 6. SECURITY GUARDIAN - Master Security Orchestrator
# ══════════════════════════════════════════════════════════════════════════════

class SecurityGuardian:
    """Master security agent — orchestrates all security checks on every request"""

    def __init__(self):
        self.rate_limiter = RateLimiter()
        self.sanitizer = InputSanitizer()
        self.auth_guardian = AuthGuardian()
        self.fraud_detector = FraudDetector()
        self.threats_blocked = 0
        self.attacks_detected: Dict[str, int] = defaultdict(int)
        self._start_time = time.time()
        self._request_count = 0
        self._heartbeat_task = None

    def register_middleware(self, app):
        """Register security middleware on the FastAPI app.
        Call this BEFORE other middleware registration."""

        @app.middleware("http")
        async def security_middleware(request: Request, call_next):
            return await self.process_request(request, call_next)

    async def process_request(self, request: Request, call_next):
        """Main security gate — every request passes through here"""
        self._request_count += 1

        # Get client IP
        ip = request.headers.get("X-Forwarded-For", "")
        if ip:
            ip = ip.split(",")[0].strip()
        else:
            ip = request.client.host if request.client else "unknown"

        path = str(request.url.path)

        # 1. CHECK IF IP IS BLOCKED
        if self.rate_limiter.is_blocked(ip):
            self.threats_blocked += 1
            logger.warning(f"🔒 Blocked request from banned IP: {ip}")
            return JSONResponse(status_code=403, content={"error": "Access denied"})

        # 2. RATE LIMIT CHECK
        allowed, reason = self.rate_limiter.check_rate(ip, path)
        if not allowed:
            self.threats_blocked += 1
            self.attacks_detected["rate_limit"] += 1
            logger.warning(f"🔒 Rate limit: {ip} on {path} — {reason}")
            return JSONResponse(status_code=429, content={"error": "Too many requests"})

        # 3. CHECK URL FOR PATH TRAVERSAL
        url_malicious, url_threat = self.sanitizer.is_malicious(str(request.url), "url")
        if url_malicious:
            self.threats_blocked += 1
            self.attacks_detected[url_threat] += 1
            self.rate_limiter.block_ip(ip, duration=3600, reason=f"URL attack: {url_threat}")
            logger.critical(f"🚨 URL ATTACK from {ip}: {url_threat}")
            return JSONResponse(status_code=400, content={"error": "Invalid request"})

        # 4. CHECK QUERY PARAMS
        for key, value in request.query_params.items():
            is_malicious, threat_type = self.sanitizer.is_malicious(value, key)
            if is_malicious:
                self.threats_blocked += 1
                self.attacks_detected[threat_type] += 1
                self.rate_limiter.block_ip(
                    ip, duration=3600, reason=f"query param attack: {threat_type}"
                )
                logger.critical(f"🚨 QUERY ATTACK from {ip}: {threat_type} in '{key}'")
                return JSONResponse(status_code=400, content={"error": "Invalid input"})

        # 5. SCAN REQUEST BODY FOR ATTACKS (POST/PUT/PATCH)
        if request.method in ["POST", "PUT", "PATCH"]:
            # We need to read body carefully (can only read once)
            try:
                body_bytes = await request.body()
                if body_bytes:
                    import json
                    try:
                        body = json.loads(body_bytes)
                        is_safe, threat = self.sanitizer.scan_request_body(body, ip)
                        if not is_safe:
                            self.threats_blocked += 1
                            self.attacks_detected[threat["type"]] += 1
                            self.rate_limiter.block_ip(
                                ip, duration=3600, reason=f"body attack: {threat['type']}"
                            )
                            return JSONResponse(status_code=400, content={"error": "Invalid input"})
                    except json.JSONDecodeError:
                        pass  # Not JSON body — allow through

                    # Reconstruct request with body for downstream handlers
                    # Create a new receive that returns the cached body
                    async def receive():
                        return {"type": "http.request", "body": body_bytes}
                    request._receive = receive

            except Exception as e:
                logger.warning(f"Error reading request body from {ip}: {e}")

        # ALL CHECKS PASSED — proceed with request
        return await call_next(request)

    async def start_heartbeat(self):
        """Start the security heartbeat background task"""
        self._heartbeat_task = asyncio.create_task(self._security_heartbeat())

    async def stop_heartbeat(self):
        """Stop the heartbeat task"""
        if self._heartbeat_task:
            self._heartbeat_task.cancel()
            try:
                await self._heartbeat_task
            except asyncio.CancelledError:
                pass

    async def _security_heartbeat(self):
        """Log security status every 5 minutes"""
        while True:
            try:
                await asyncio.sleep(300)  # 5 minutes
                blocked_count = self.rate_limiter.get_blocked_count()
                uptime_hours = (time.time() - self._start_time) / 3600
                logger.info(
                    f"🛡️ SECURITY GUARDIAN | uptime={uptime_hours:.1f}h | "
                    f"requests={self._request_count} | threats_blocked={self.threats_blocked} | "
                    f"ips_blocked={blocked_count} | attacks={dict(self.attacks_detected)}"
                )

                # Reset attack counters every hour to prevent memory growth
                if int(time.time()) % 3600 < 300:
                    self.attacks_detected.clear()

            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Security heartbeat error: {e}")

    def get_status(self) -> dict:
        """Get comprehensive security status"""
        uptime_seconds = time.time() - self._start_time
        return {
            "status": "active",
            "uptime_seconds": int(uptime_seconds),
            "total_requests": self._request_count,
            "threats_blocked": self.threats_blocked,
            "ips_blocked": self.rate_limiter.get_blocked_count(),
            "attack_types_detected": dict(self.attacks_detected),
            "rate_limiter": self.rate_limiter.get_stats(),
            "fraud_detector": self.fraud_detector.get_stats(),
        }


# ══════════════════════════════════════════════════════════════════════════════
# Singleton instance
# ══════════════════════════════════════════════════════════════════════════════

# Create global security guardian instance
security_guardian = SecurityGuardian()
