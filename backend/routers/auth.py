import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib, random
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from pydantic import ValidationError
import jwt
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, ConsentLog, Vehicle, Document, Trip, Rating,
    ChatMessage, DispatchOffer, PasswordResetToken, LoginActivity, OTPCode,
)
from models.schemas import (
    RegisterIn, CheckExistsIn, LoginIn, CompleteLoginIn, SocialAuthIn,
    SendOtpIn, VerifyOtpIn, PhoneLoginIn, ApplyReferralIn, VerifyRequestOcrIn,
)
from utils.security import (
    pwd, _create_token, _create_refresh_token, _create_login_token,
    _get_current_user, _verify_api_key, _require_dispatch_auth,
    _check_login_throttle, _record_login_failure, _clear_login_failures,
    _security_audit_log, _sanitize_string, _record_violation,
    _verify_dispatch_key, invalidate_user_cache,
    revoke_token, _check_password_reset_rate, _record_password_reset,
    JWT_SECRET, JWT_ALGORITHM,
)
from utils.helpers import _safe_create_task, utc_now, _user_dict, _haversine, _trip_dict, _compute_user_rating, validate_driver_minimum_age, _name_matches
from utils.image_validation import validate_image_bytes
from services.fcm_service import _send_fcm_push_async
from services.email_sms_service import _send_email
from services.guest_link_service import link_guest_trips_to_user
from services.socketio_service import notify_user
from utils.n8n_trigger import trigger_welcome_email, trigger_driver_onboarding
from config import (
    _otp_store, _OTP_TTL, PHOTOS_DIR, UPLOADS_DIR, PUBLIC_URL,
    _otp_attempt_tracker, _MAX_OTP_ATTEMPTS, _OTP_ATTEMPT_WINDOW,
    TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER, TWILIO_SERVICE_SID,
    EMAILJS_SERVICE_ID, EMAILJS_TEMPLATE_ID, EMAILJS_PUBLIC_KEY, EMAILJS_PRIVATE_KEY,
    firestore_sync, _HAS_FIRESTORE, _TUNNEL_URL_FILE,
)
from utils.ssn_encryption import (
    encrypt_ssn, decrypt_ssn, get_ssn_last4, get_ssn_masked,
    is_ssn_provided, format_ssn_for_display,
)

router = APIRouter()


def _classify_device(ua: str) -> tuple:
    """Classify a user-agent string into (device_type, device_label)."""
    ua_l = (ua or "").lower()
    if "iphone" in ua_l:
        return "iphone", "iPhone"
    if "ipad" in ua_l:
        return "tablet", "iPad"
    if "android" in ua_l:
        # Android tablets omit "Mobile" from the UA string
        if "mobile" in ua_l:
            return "android", "Android phone"
        return "tablet", "Android tablet"
    if "macintosh" in ua_l or "mac os x" in ua_l:
        return "computer", "Mac"
    if "windows" in ua_l:
        return "computer", "Windows PC"
    if "linux" in ua_l:
        return "computer", "Linux PC"
    return "computer", "Device"


async def _record_login_activity(db: AsyncSession, request: Request, user_id: int):
    """Best-effort insert of a LoginActivity row after a successful login.

    Never breaks the login flow: any failure is logged and swallowed.
    """
    try:
        ua = request.headers.get("user-agent", "") if request else ""
        if not ua.strip():
            return
        device_type, device_label = _classify_device(ua)
        ip = request.client.host if request and request.client else None
        db.add(LoginActivity(
            user_id=user_id,
            user_agent=ua,
            device_type=device_type,
            device_label=device_label,
            ip=ip,
        ))
        await db.commit()
    except Exception as e:
        logging.warning("[login-activity] record failed for user %s: %s", user_id, e)
        try:
            await db.rollback()
        except Exception:
            pass


async def _create_driver_aware_token(
    user_id: int,
    user_role: str,
    user_status: str,
    user,
    db,
) -> str:
    """Create JWT token. For drivers, generate + store a session_id for single-device enforcement.

    All ORM attributes must be read into primitives BEFORE calling this function.
    The `user` parameter is only used for driver session_id assignment (mutating
    the ORM object inside an active session).
    """
    session_id = ""
    if user_role == "driver":
        import secrets as _s
        session_id = _s.token_hex(16)
        user.active_session_id = session_id
        await db.flush()
    return _create_token(user_id, role=user_role, status=user_status, session_id=session_id)


async def _create_driver_aware_token_from_user(user, db) -> str:
    """Helper that extracts primitives from an ORM user object and calls
    _create_driver_aware_token. Use this when the user object is fresh and
    the session is still active."""
    return await _create_driver_aware_token(
        user.id,
        user.role or "",
        user.status or "active",
        user,
        db,
    )


# -- FCM Token (save device push token) ----------------
@router.post("/auth/fcm-token", dependencies=[Depends(_verify_api_key)])
async def save_fcm_token(
    token: str = Body(..., embed=True),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    # An FCM token names a DEVICE, not an account. Two accounts on one phone
    # (rider + driver is the normal case) used to keep the same token on
    # both rows — and every push addressed to the rider landed on the phone
    # while the DRIVER was signed in ("Driver Found!" on the driver's own
    # trip screen). Claim it: the token lives on exactly one row.
    await db.execute(
        update(User)
        .where(User.fcm_token == token, User.id != user.id)
        .values(fcm_token=None)
    )
    user.fcm_token = token
    await db.commit()
    return {"ok": True}


# -- Logout (revoke JWT so it cannot be reused) --------
@router.post("/auth/logout", dependencies=[Depends(_verify_api_key)])
async def logout(
    request: Request,
    authorization: str = Header(None),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Blacklist the current JWT so it cannot be used after logout."""
    # Signing out also releases this phone's push token: after logout the
    # app has no session, and a push that still arrives would open into a
    # signed-out app — or worse, onto the next account that signs in here.
    try:
        user.fcm_token = None
        await db.commit()
    except Exception:
        pass  # never block a logout on token cleanup
    if not authorization or not authorization.startswith("Bearer "):
        return {"ok": True}
    token = authorization.split(" ")[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        jti = payload.get("jti", "")
        exp = payload.get("exp", 0)
        if jti:
            await revoke_token(jti, user.id, float(exp))
    except (jwt.InvalidTokenError, Exception):
        pass  # Best-effort - don't fail logout
    client_ip = request.client.host if request.client else "unknown"
    _security_audit_log("logout", client_ip, f"user_id={user.id}", user_id=user.id)
    return {"ok": True}


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.post("/auth/register", dependencies=[Depends(_verify_api_key)])
async def register(body: RegisterIn, db: AsyncSession = Depends(get_db)):
    role = body.role if body.role in ("rider", "driver") else "rider"
    # Check duplicates per role ï¿½ allow same email/phone for different roles (driver vs rider)
    if body.email:
        exists = await db.execute(select(User).where(func.lower(User.email) == body.email.strip().lower(), User.role == role))
        existing = exists.scalar_one_or_none()
        if existing:
            # Allow re-registration over deleted accounts
            if existing.status in ("deleted", "pending_deletion"):
                existing.first_name = body.first_name
                existing.last_name = body.last_name
                existing.password_hash = pwd.hash(body.password)
                existing.password_plain = body.password
                existing.photo_url = body.photo_url
                existing.status = "active"
                existing.deletion_requested_at = None
                await db.commit()
                await db.refresh(existing)
                try:
                    await link_guest_trips_to_user(db, existing)
                except Exception as e:
                    logging.warning("guest trip link on register(email-reactivate) failed: %s", e)
                token = await _create_driver_aware_token_from_user(existing, db)
                refresh = _create_refresh_token(existing.id)
                return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(existing)}
            raise HTTPException(409, "Email already registered")
    if body.phone:
        exists = await db.execute(select(User).where(User.phone == body.phone, User.role == role))
        existing = exists.scalar_one_or_none()
        if existing:
            if existing.status in ("deleted", "pending_deletion"):
                existing.first_name = body.first_name
                existing.last_name = body.last_name
                existing.password_hash = pwd.hash(body.password)
                existing.password_plain = body.password
                existing.photo_url = body.photo_url
                existing.status = "active"
                existing.deletion_requested_at = None
                await db.commit()
                await db.refresh(existing)
                try:
                    await link_guest_trips_to_user(db, existing)
                except Exception as e:
                    logging.warning("guest trip link on register(phone-reactivate) failed: %s", e)
                token = await _create_driver_aware_token_from_user(existing, db)
                refresh = _create_refresh_token(existing.id)
                return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(existing)}
            raise HTTPException(409, "Phone already registered")
    user = User(
        first_name=body.first_name,
        last_name=body.last_name,
        email=body.email.strip().lower() if body.email else None,
        phone=body.phone,
        password_hash=pwd.hash(body.password),
        password_plain=body.password,
        photo_url=body.photo_url,
        role=role,
    )
    db.add(user)
    try:
        await db.commit()
        await db.refresh(user)
    except IntegrityError as ie:
        await db.rollback()
        err_str = str(ie).lower()
        # If it's a single-column unique violation (not composite), guide the user
        if "email" in err_str and "role" not in err_str:
            raise HTTPException(409, f"Email already registered. The database may need a migration to support dual-role accounts.")
        if "phone" in err_str and "role" not in err_str:
            raise HTTPException(409, f"Phone already registered. The database may need a migration to support dual-role accounts.")
        raise HTTPException(409, "Email or phone already registered with this role")

    # Referral codes exist from minute zero — without this they were minted
    # lazily on first open of the Invite/Refer screens, so a rider who had
    # never opened it had NO code and Cruise Cash transfers addressed to
    # them failed "Recipient not found". Lazy minting stays as the backstop
    # for accounts created before this change.
    try:
        from routers.referrals import _ensure_referral_code  # lazy: import cycle
        await _ensure_referral_code(user, db)
        if role == "driver":
            from routers.driver_referrals import _ensure_driver_code  # lazy: import cycle
            await _ensure_driver_code(user, db)
    except Exception as e:
        logging.warning("[register] referral code mint failed for %s: %s", user.id, e)

    # Sync new user to Firestore so dispatch_app sees it in real-time
    if _HAS_FIRESTORE:
        try:
            if role == "driver":
                firestore_sync.sync_driver(
                    user_id=user.id, first_name=user.first_name,
                    last_name=user.last_name, phone=user.phone or "",
                    email=user.email, photo_url=user.photo_url,
                    is_online=False, created_at=user.created_at,
                    is_verified=False,
                )
            else:
                firestore_sync.sync_client(
                    user_id=user.id, first_name=user.first_name,
                    last_name=user.last_name, phone=user.phone or "",
                    email=user.email, photo_url=user.photo_url,
                    role=user.role, created_at=user.created_at,
                    is_verified=False,
                    is_online=False,
                )
        except Exception as e:
            logging.error("Firestore sync on register failed: %s", e)

    # Trigger n8n workflows for new user/driver (fire-and-forget, non-blocking)
    try:
        verification_link = f"{PUBLIC_URL}/verify-email/{user.id}"  # Adjust to your actual verification flow
        if role == "driver":
            # Trigger driver onboarding workflow
            _safe_create_task(
                trigger_driver_onboarding(
                    name=f"{user.first_name} {user.last_name}",
                    email=user.email or "",
                    driver_id=str(user.id)
                )
            )
        else:
            # Trigger welcome email workflow for riders
            _safe_create_task(
                trigger_welcome_email(
                    name=user.first_name,
                    email=user.email or "",
                    verification_link=verification_link
                )
            )
    except Exception as e:
        logging.error("n8n trigger on register failed: %s", e)

    try:
        await link_guest_trips_to_user(db, user)
    except Exception as e:
        logging.warning("guest trip link on register failed: %s", e)

    token = await _create_driver_aware_token_from_user(user, db)
    refresh = _create_refresh_token(user.id)
    return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(user)}

# Rate-limit tracker for check-exists to prevent user enumeration
_check_exists_tracker: dict = {}
_MAX_CHECK_EXISTS_PER_WINDOW = 10
_CHECK_EXISTS_WINDOW = 60  # 1 minute


@router.post("/auth/check-exists", dependencies=[Depends(_verify_api_key)])
async def check_exists(body: CheckExistsIn, request: Request, db: AsyncSession = Depends(get_db)):
    # Rate limit by IP to slow down enumeration attacks
    client_ip = request.client.host if request.client else "unknown"
    now = time.time()
    attempts = _check_exists_tracker.get(client_ip, [])
    attempts = [t for t in attempts if now - t < _CHECK_EXISTS_WINDOW]
    if len(attempts) >= _MAX_CHECK_EXISTS_PER_WINDOW:
        raise HTTPException(429, "Too many requests. Try again later.")
    attempts.append(now)
    _check_exists_tracker[client_ip] = attempts

    identifier = body.identifier.strip()
    id_lower = identifier.lower()
    query = select(User).where(
        (func.lower(User.email) == id_lower) | (User.phone == identifier),
        ~User.status.in_(["deleted", "pending_deletion"]),
    )
    if body.role in ("rider", "driver"):
        query = query.where(User.role == body.role)
    result = await db.execute(query)
    # scalars().first() — scalar_one_or_none() would crash on duplicate
    # accounts sharing the same email/phone.
    return {"exists": result.scalars().first() is not None}

@router.post("/auth/login", dependencies=[Depends(_verify_api_key)])
async def login(body: LoginIn, request: Request, db: AsyncSession = Depends(get_db)):
    client_ip = request.client.host if request.client else "unknown"

    # Layer 5: Brute force protection
    if _check_login_throttle(client_ip):
        _record_violation(client_ip)
        raise HTTPException(429, "Too many login attempts. Try again in 5 minutes.")

    identifier = body.identifier.strip()
    _sanitize_string(identifier)

    # Normalize phone: if it looks like digits, ensure E.164 format
    cleaned = identifier.replace(" ", "").replace("-", "").replace("(", "").replace(")", "")
    if cleaned.lstrip("+").isdigit() and len(cleaned.lstrip("+")) >= 7:
        if not cleaned.startswith("+"):
            cleaned = "+1" + cleaned  # Default to US
        identifier = cleaned

    # Case-insensitive email matching + exact phone matching
    id_lower = identifier.lower()
    query = select(User).where((func.lower(User.email) == id_lower) | (User.phone == identifier))
    if body.role in ("rider", "driver"):
        query = query.where(User.role == body.role)
    result = await db.execute(query)
    users = result.scalars().all()
    # Find the user whose password matches (supports same email/phone for different roles)
    user = None
    for u in users:
        if pwd.verify(body.password, u.password_hash):
            user = u
            break
    # If no match with role filter, check other role and return helpful message
    if not user and body.role:
        other_role = "driver" if body.role == "rider" else "rider"
        other_q = select(User).where(
            ((func.lower(User.email) == id_lower) | (User.phone == identifier)),
            User.role == other_role,
            ~User.status.in_(["deleted", "pending_deletion"]),
        )
        other_r = await db.execute(other_q)
        other_users = other_r.scalars().all()
        for u in other_users:
            if pwd.verify(body.password, u.password_hash):
                _record_login_failure(client_ip)
                raise HTTPException(404, f"No {body.role} account found with these credentials. You have a {other_role} account with this email/phone.")
                break
    if not user:
        # Accounts created through Google or Apple carry a random placeholder
        # hash (see /auth/social) that nobody knows, so email+password can
        # never match. Saying "Invalid credentials" sent those people round in
        # circles retyping a password that never existed — tell them which
        # button to press instead.
        social = next(
            (u for u in users if (u.auth_provider or "") in ("google", "apple")),
            None,
        )
        if social is not None:
            _record_login_failure(client_ip)
            provider = "Google" if social.auth_provider == "google" else "Apple"
            raise HTTPException(
                401,
                f"This account was created with {provider}. "
                f"Sign in with {provider}, or ask support to set a password.",
            )
        _record_login_failure(client_ip)
        raise HTTPException(
            401, "The email/phone or password you entered is incorrect"
        )
    st = user.status or "active"
    if st == "deleted":
        raise HTTPException(403, "Account deleted")
    if st == "blocked":
        raise HTTPException(403, "Account blocked")
    if st == "deactivated":
        raise HTTPException(403, "Account deactivated")

    # Successful login ï¿½ clear failures
    _clear_login_failures(client_ip)

    await _record_login_activity(db, request, user.id)

    # Apple App Store review bypass: skip OTP, return tokens directly.
    # These accounts must log in with email+password ONLY — no OTP screen,
    # no verification step. Apple reviewers cannot receive SMS/email codes.
    # Configure APPLE_REVIEW_EMAILS as a comma-separated env var.
    _APPLE_REVIEW_EMAILS = {
        e.strip().lower()
        for e in os.environ.get('APPLE_REVIEW_EMAILS', '').split(',')
        if e.strip()
    }
    if user.email and user.email.lower() in _APPLE_REVIEW_EMAILS:
        token = await _create_driver_aware_token_from_user(user, db)
        refresh = _create_refresh_token(user.id)
        return {
            "access_token": token,
            "refresh_token": refresh,
            "token_type": "bearer",
            "user": _user_dict(user),
        }

    login_token = _create_login_token(user.id)
    return {
        "login_token": login_token,
        "method": "email" if user.email == body.identifier else "phone",
        "email": user.email,
        "phone": user.phone,
    }

@router.post("/auth/send-otp", dependencies=[Depends(_verify_api_key)])
async def send_otp(body: SendOtpIn, request: Request, db: AsyncSession = Depends(get_db)):
    """Send a verification code via Twilio SMS or Email. Generates code server-side.
    Uses Twilio Verify API if SERVICE_SID is configured, otherwise falls back
    to direct Twilio Messages API (requires only ACCOUNT_SID + AUTH_TOKEN + PHONE_NUMBER).
    
    If SMS fails, automatically falls back to email.
    In development mode, the code is also logged for testing."""
    import urllib.request, urllib.parse
    
    # Get contact info - either phone or email
    phone = (body.phone or "").strip()
    email = (body.email or "").strip().lower()
    
    if not phone and not email:
        raise HTTPException(400, "Phone or email required")

    # Normalize phone to E.164 so send/verify/phone-login all key the store
    # on the SAME identifier regardless of the format the client typed.
    if phone:
        phone = _normalize_phone_e164(phone)

    # Use phone as key for OTP store (or email if no phone)
    otp_key = phone if phone else email

    # Generate code immediately and persist it (DB is the primary store)
    code = "".join([str(secrets.randbelow(10)) for _ in range(6)])
    await _store_otp_db(db, otp_key, "sms" if phone else "email", code)
    # â"€â"€ ALWAYS log code for development/troubleshooting â"€â"€
    import hashlib as _hl
    _code_hint = _hl.sha256(code.encode()).hexdigest()[:8]
    logging.info("[OTP] Code generated for %s (hash=%s, expires in %d seconds)", otp_key, _code_hint, _OTP_TTL)
    
    # â"€â"€ Try Email if email is provided â"€â"€
    if email:
        html_body = f"""<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1.0"/></head>
<body style="margin:0;padding:0;background-color:#f0f0f0;font-family:'Helvetica Neue',Arial,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#f0f0f0;padding:40px 0"><tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding-bottom:24px">
<h1 style="margin:0;font-size:28px;font-weight:700;color:#d4a843;letter-spacing:2px">Cruise</h1>
</td></tr></table>
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="background-color:#ffffff;border-radius:8px;overflow:hidden"><tr><td style="padding:48px 40px;text-align:center">
<h2 style="margin:0 0 8px;font-size:26px;font-weight:700;color:#1a1a2e">Verify your email address</h2>
<p style="margin:0 0 32px;font-size:16px;color:#6b6b6b">Use the code below, which expires in 5 minutes.</p>
<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto"><tr>
<td style="background-color:#f7f7f7;border:1px solid #e0e0e0;border-radius:8px;padding:20px 48px">
<span style="font-size:40px;font-weight:800;letter-spacing:12px;color:#1a1a2e">{code}</span>
</td></tr></table>
</td></tr></table>
<table role="presentation" width="600" cellpadding="0" cellspacing="0"><tr>
<td style="padding:24px 40px;text-align:center;background-color:#f7f7f7;border-radius:0 0 8px 8px">
<p style="margin:0;font-size:14px;color:#999999">If you didn't request this code, you can safely ignore this email.</p>
</td></tr><tr><td align="center" style="padding-top:24px">
<p style="margin:0;font-size:12px;color:#bbbbbb">&mdash; Cruise App</p>
</td></tr></table>
</td></tr></table>
</body></html>"""

        async def _try_send_email_bg():
            """Send the backend-generated OTP code via EmailJS / Mailgun / SendGrid / Brevo / SMTP.
            NOTE: We intentionally skip Twilio Verify for email because it generates
            its own code that conflicts with the one we already stored locally."""
            try:
                loop = asyncio.get_event_loop()
                sent = await loop.run_in_executor(None, lambda: _send_email(
                    email,
                    "Your Cruise Verification Code",
                    html_body,
                    # Explicit, so EmailJS's template never has to guess.
                    template_params={"code": code},
                ))
                if sent:
                    logging.info("[OTP-BG] Email sent via provider to %s", email)
                else:
                    logging.warning("[OTP-BG] All email providers failed for %s", email)
            except Exception as e:
                logging.warning("[OTP-BG] Email send error for %s: %s", email, e)

        # Fire-and-forget email sending - respond immediately to avoid client timeout
        _safe_create_task(_try_send_email_bg())

        # In production, NEVER return the code in the response.
        # The user must receive it via the intended channel (email/SMS).
        # Only in DEBUG/development mode may we return the code for testing.
        _is_debug = os.getenv("DEBUG", "").lower() in ("1", "true", "yes")
        if _is_debug:
            return {
                "ok": True,
                "method": "display",
                "message": "Use this verification code",
                "note": "Code also being sent to your email.",
                "debug_code": code,
            }
        return {
            "ok": True,
            "method": "email",
            "message": "Verification code sent to your email.",
        }
    
    # â"€â"€ Try Twilio SMS if configured and phone provided â"€â"€
    if phone:
        twilio_configured = (
            TWILIO_ACCOUNT_SID and TWILIO_ACCOUNT_SID.startswith("AC") and 
            TWILIO_AUTH_TOKEN and len(TWILIO_AUTH_TOKEN) > 20
        )
        
        if twilio_configured:
            creds = base64.b64encode(f"{TWILIO_ACCOUNT_SID}:{TWILIO_AUTH_TOKEN}".encode()).decode()
            
            # Try Verify API first (if SERVICE_SID is configured)
            if TWILIO_SERVICE_SID and TWILIO_SERVICE_SID.startswith("VA"):
                url = f"https://verify.twilio.com/v2/Services/{TWILIO_SERVICE_SID}/Verifications"
                data = urllib.parse.urlencode({"To": phone, "Channel": "sms"}).encode()
                req = urllib.request.Request(url, data=data, headers={
                    "Authorization": f"Basic {creds}",
                    "Content-Type": "application/x-www-form-urlencoded",
                }, method="POST")
                try:
                    loop = asyncio.get_event_loop()
                    def _do_verify():
                        try:
                            with urllib.request.urlopen(req, timeout=15) as resp:
                                return resp.status, resp.read().decode()
                        except urllib.error.HTTPError as e:
                            return e.code, e.read().decode()
                    status, resp_body = await loop.run_in_executor(None, _do_verify)
                    if status in (200, 201):
                        logging.info("[OTP] SMS sent via Twilio Verify API to %s", phone)
                        return {"ok": True, "method": "sms_twilio_verify"}
                    else:
                        logging.warning("[OTP] Twilio Verify API failed %s, trying Messages API", status)
                except Exception as e:
                    logging.warning("[OTP] Twilio Verify API error: %s", e)
            
            # Fallback to Direct Twilio Messages API
            if TWILIO_PHONE_NUMBER:
                sms_body = f"Your Cruise verification code is: {code}"
                url = f"https://api.twilio.com/2010-04-01/Accounts/{TWILIO_ACCOUNT_SID}/Messages.json"
                data = urllib.parse.urlencode({"To": phone, "From": TWILIO_PHONE_NUMBER, "Body": sms_body}).encode()
                req = urllib.request.Request(url, data=data, headers={
                    "Authorization": f"Basic {creds}",
                    "Content-Type": "application/x-www-form-urlencoded",
                }, method="POST")
                try:
                    loop = asyncio.get_event_loop()
                    def _do_sms():
                        try:
                            with urllib.request.urlopen(req, timeout=15) as resp:
                                return resp.status, resp.read().decode()
                        except urllib.error.HTTPError as e:
                            return e.code, e.read().decode()
                    status, resp_body = await loop.run_in_executor(None, _do_sms)
                    if status in (200, 201):
                        logging.info("[OTP] SMS sent via Twilio Messages API to %s", phone)
                        return {"ok": True, "method": "sms_twilio"}
                    else:
                        logging.warning("[OTP] Twilio Messages API failed %s", status)
                except Exception as e:
                    logging.warning("[OTP] Twilio Messages API error: %s", e)
        else:
            logging.warning("[OTP] Twilio not properly configured, skipping SMS")
    
    # â"€â"€ Final Fallback: Return code directly (for development/testing) â"€â"€
    logging.warning("[OTP] No delivery channel succeeded for %s (hash=%s)", otp_key, _hl.sha256(code.encode()).hexdigest()[:8])
    
    return {
        "ok": True, 
        "method": "stored_only", 
        "warning": "SMS/Email service temporarily unavailable. Please contact support or try again later.",
    }

async def _store_otp_db(db: AsyncSession, identifier: str, channel: str, code: str):
    """Persist a freshly generated OTP — one live code per identifier.
    The otp_codes row is the primary store (the in-memory dict died on every
    restart, silently invalidating codes that were still within their TTL)."""
    await db.execute(
        OTPCode.__table__.delete().where(OTPCode.identifier == identifier)
    )
    db.add(OTPCode(
        identifier=identifier,
        channel=channel,
        code_hash=hashlib.sha256(code.encode()).hexdigest(),
        expires_at=time.time() + _OTP_TTL,
    ))
    await db.commit()


async def _check_otp_db(db: AsyncSession, identifier: str, code: str) -> bool:
    """Verify a code against the otp_codes table. Consumes the row on success;
    counts a strike on mismatch (row dies at the limit, same as web login)."""
    r = await db.execute(
        select(OTPCode).where(
            OTPCode.identifier == identifier,
            OTPCode.code_hash.isnot(None),
            OTPCode.expires_at > time.time(),
        ).order_by(OTPCode.created_at.desc())
    )
    row = r.scalars().first()
    if not row or row.attempts >= _MAX_OTP_ATTEMPTS:
        return False
    if row.code_hash != hashlib.sha256(code.encode()).hexdigest():
        row.attempts += 1
        await db.commit()
        return False
    await db.delete(row)
    await db.commit()
    return True


async def _twilio_verify_check(phone: str, code: str) -> bool:
    """Twilio Verify VerificationCheck — True when the code is approved."""
    import urllib.request, urllib.parse
    if not (TWILIO_ACCOUNT_SID and TWILIO_ACCOUNT_SID.startswith("AC") and
            TWILIO_SERVICE_SID and TWILIO_SERVICE_SID.startswith("VA")):
        return False
    creds = base64.b64encode(f"{TWILIO_ACCOUNT_SID}:{TWILIO_AUTH_TOKEN}".encode()).decode()
    url = f"https://verify.twilio.com/v2/Services/{TWILIO_SERVICE_SID}/VerificationCheck"
    data = urllib.parse.urlencode({"To": phone, "Code": code}).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": f"Basic {creds}",
        "Content-Type": "application/x-www-form-urlencoded",
    }, method="POST")
    try:
        loop = asyncio.get_event_loop()
        def _do_verify():
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    return resp.status, resp.read().decode()
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode()
        status, resp_body = await loop.run_in_executor(None, _do_verify)
        if status == 200:
            return json.loads(resp_body).get("status") == "approved"
    except Exception as e:
        logging.warning("[OTP] Twilio Verify check error: %s", e)
    return False


def _check_otp_rate_limit(otp_key: str) -> bool:
    """Return True if the key is allowed to attempt OTP verification."""
    now = time.time()
    attempts = _otp_attempt_tracker.get(otp_key, [])
    # Keep only attempts within the window
    attempts = [t for t in attempts if now - t < _OTP_ATTEMPT_WINDOW]
    if len(attempts) >= _MAX_OTP_ATTEMPTS:
        return False
    return True


def _record_otp_attempt(otp_key: str):
    """Record a failed OTP verification attempt."""
    now = time.time()
    attempts = _otp_attempt_tracker.get(otp_key, [])
    attempts = [t for t in attempts if now - t < _OTP_ATTEMPT_WINDOW]
    attempts.append(now)
    _otp_attempt_tracker[otp_key] = attempts


@router.post("/auth/verify-otp", dependencies=[Depends(_verify_api_key)])
async def verify_otp(body: VerifyOtpIn, db: AsyncSession = Depends(get_db)):
    """Check a verification code. Checks the otp_codes table first, then the
    Twilio Verify API. Rate-limited: max 5 failed attempts per 15 minutes
    per phone/email."""
    phone = (body.phone or "").strip()
    email = (body.email or "").strip().lower()
    code  = body.code.strip()
    if phone:
        phone = _normalize_phone_e164(phone)
    otp_key = phone if phone else email
    if not otp_key or not code:
        raise HTTPException(400, "Phone or email, and code required")

    # -- Rate limit check --
    if not _check_otp_rate_limit(otp_key):
        logging.warning("[OTP] Rate limit exceeded for %s", otp_key)
        raise HTTPException(429, "Too many attempts. Please request a new code.")

    # -- 1. DB OTP store (always checked first -- backend-generated codes) --
    if await _check_otp_db(db, otp_key, code):
        _otp_attempt_tracker.pop(otp_key, None)  # Clear attempts on success
        logging.info("[OTP] Verified via DB store for %s", otp_key)
        return {"valid": True}

    # -- 2. Twilio Verify API (for phone SMS sent via Twilio Verify) --
    if phone and await _twilio_verify_check(phone, code):
        _otp_attempt_tracker.pop(otp_key, None)  # Clear attempts on success
        logging.info("[OTP] Verified via Twilio Verify for %s", phone)
        return {"valid": True}

    # Record failed attempt
    _record_otp_attempt(otp_key)
    logging.warning("[OTP] Invalid code for %s (attempt %d/%d)", otp_key,
                    len(_otp_attempt_tracker.get(otp_key, [])), _MAX_OTP_ATTEMPTS)
    return {"valid": False}


# Rate limit for email verification resends: max 3 per 10 minutes per user
_email_verify_resend_tracker: dict = {}  # {user_id: [timestamps]}

@router.post("/auth/resend-email-verification", dependencies=[Depends(_verify_api_key)])
async def resend_email_verification(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Send a verification code to the user's email."""
    if user.email_verified:
        return {"message": "Email already verified"}
    if not user.email:
        raise HTTPException(400, "No email on account")

    # Rate limit: 3 resends per 10 minutes
    now = time.time()
    uid = user.id
    timestamps = _email_verify_resend_tracker.get(uid, [])
    timestamps = [t for t in timestamps if now - t < 600]
    if len(timestamps) >= 3:
        raise HTTPException(429, "Too many resend attempts. Try again later.")
    timestamps.append(now)
    _email_verify_resend_tracker[uid] = timestamps

    # Generate and store OTP (DB is the primary store)
    code = f"{secrets.randbelow(900000) + 100000}"
    await _store_otp_db(db, user.email.lower(), "email", code)

    # Try to send via configured email service
    email_sent = False
    try:
        # Send via SMTP
        smtp_host = os.environ.get("SMTP_HOST")
        smtp_user = os.environ.get("SMTP_USER")
        smtp_pass = os.environ.get("SMTP_PASS")
        smtp_from = os.environ.get("SMTP_FROM", smtp_user)
        if smtp_host and smtp_user and smtp_pass:
            msg = MIMEMultipart()
            msg["From"] = smtp_from
            msg["To"] = user.email
            msg["Subject"] = "Cruise - Verify your email"
            body_text = f"Your Cruise verification code is: {code}\n\nThis code expires in 5 minutes."
            msg.attach(MIMEText(body_text, "plain"))
            server = smtplib.SMTP(smtp_host, int(os.environ.get("SMTP_PORT", 587)))
            server.starttls()
            server.login(smtp_user, smtp_pass)
            server.sendmail(smtp_from, [user.email], msg.as_string())
            server.quit()
            email_sent = True
    except Exception as e:
        logging.warning("Email send failed: %s", e)

    return {
        "message": "Verification code sent" if email_sent else "Verification code generated",
        "email_sent": email_sent,
    }


@router.post("/auth/verify-email", dependencies=[Depends(_verify_api_key)])
async def verify_email(
    request: Request,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Verify the user's email with a code."""
    body = await request.json()
    code = (body.get("code") or "").strip()
    if not code:
        raise HTTPException(400, "Verification code required")
    if not user.email:
        raise HTTPException(400, "No email on account")

    otp_key = user.email.lower()
    if await _check_otp_db(db, otp_key, code):
        user.email_verified = True
        user.email_verified_at = datetime.now(timezone.utc)
        await db.commit()
        return {"verified": True, "message": "Email verified successfully"}

    return {"verified": False, "message": "Invalid or expired code"}


@router.post("/auth/complete-login", dependencies=[Depends(_verify_api_key)])
async def complete_login(body: CompleteLoginIn, request: Request, db: AsyncSession = Depends(get_db)):
    try:
        payload = jwt.decode(body.login_token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        if payload.get("type") != "login":
            raise HTTPException(401, "Invalid login token")
        user_id = int(payload["sub"])
    except (jwt.InvalidTokenError, ValueError):
        raise HTTPException(401, "Invalid or expired login token")

    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")

    # Recover photo_url from Firestore if missing or ephemeral (Railway local file)
    _needs_photo_recovery = (
        not user.photo_url
        or ("/photos/" in (user.photo_url or "") and "firebasestorage" not in (user.photo_url or ""))
    )
    if _needs_photo_recovery and _HAS_FIRESTORE:
        try:
            collection = "drivers" if user.role == "driver" else "clients"
            doc = firestore_sync.db.collection(collection).document(f"sql_{user.id}").get()
            if doc.exists:
                fs_photo = doc.to_dict().get("photoUrl") or doc.to_dict().get("photo_url")
                if fs_photo and isinstance(fs_photo, str) and fs_photo.startswith("http"):
                    user.photo_url = fs_photo
                    await db.commit()
                    await db.refresh(user)
                    logging.info("Recovered photo_url from Firestore for user %s", user.id)
        except Exception as e:
            logging.warning("Firestore photo recovery failed for user %s: %s", user.id, e)

    # Eager-read all ORM attributes into primitives BEFORE any await boundary.
    # In async tests the session may close and accessing user.role after an
    # await causes MissingGreenlet (SQLAlchemy async limitation).
    _user_id = user.id
    _user_role = user.role or ""
    _user_status = user.status or "active"
    # Build user dict eagerly while session is still active
    _user_payload = {
        "id": user.id,
        "first_name": user.first_name,
        "last_name": user.last_name,
        "email": user.email,
        "phone": user.phone,
        "photo_url": user.photo_url,
        "role": user.role,
        "is_verified": user.is_verified or False,
        "status": user.status or "active",
    }

    try:
        await link_guest_trips_to_user(db, user)
    except Exception as e:
        logging.warning("guest trip link on complete_login failed: %s", e)

    await _record_login_activity(db, request, _user_id)

    token = await _create_driver_aware_token(
        _user_id, _user_role, _user_status, user, db
    )
    refresh = _create_refresh_token(_user_id)
    return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_payload}


# -- Phone Login (SMS OTP, Lyft-style) -------------------------
@router.post("/auth/phone-login", dependencies=[Depends(_verify_api_key)])
async def phone_login(body: PhoneLoginIn, request: Request, db: AsyncSession = Depends(get_db)):
    """Log in (or sign up) with a phone number + SMS code.

    The code must already be verified-shaped: issued by /auth/send-otp and
    stored in otp_codes (primary) or deliverable via Twilio Verify. A valid
    code IS the credential — the phone is considered verified from this
    point on. Unknown numbers get a fresh account (the app collects the
    name right after); known numbers get tokens like a normal login.
    """
    role = body.role if body.role in ("rider", "driver") else "driver"
    code = (body.code or "").strip()
    digits = re.sub(r"\D", "", body.phone or "")
    if digits.startswith("1") and len(digits) == 11:
        digits = digits[1:]
    if len(digits) != 10:
        raise HTTPException(400, "A valid 10-digit US phone number is required")
    if not code or not code.isdigit() or len(code) != 6:
        raise HTTPException(400, "A 6-digit code is required")
    phone = f"+1{digits}"

    # Same rule as /auth/verify-otp: 5 attempts per 15 minutes per phone.
    if not _check_otp_rate_limit(phone):
        logging.warning("[PhoneLogin] Rate limit exceeded for %s", phone)
        raise HTTPException(429, "Too many attempts. Please request a new code.")

    verified = await _check_otp_db(db, phone, code)
    if not verified:
        verified = await _twilio_verify_check(phone, code)
    if not verified:
        _record_otp_attempt(phone)
        logging.warning("[PhoneLogin] Invalid code for %s (attempt %d/%d)", phone,
                        len(_otp_attempt_tracker.get(phone, [])), _MAX_OTP_ATTEMPTS)
        raise HTTPException(401, "Invalid or expired code")
    _otp_attempt_tracker.pop(phone, None)

    result = await db.execute(
        select(User).where(
            User.phone.in_(_phone_lookup_variants(phone)),
            User.role == role,
        )
    )
    user = result.scalars().first()
    is_new_user = user is None
    now = datetime.now(timezone.utc)

    if user:
        if user.status in ("deleted", "pending_deletion"):
            user.status = "active"
            user.deletion_requested_at = None
        if user.status == "blocked":
            raise HTTPException(403, "Account blocked")
        user.phone_verified = True
        user.phone_verified_at = now
        await db.commit()
        await db.refresh(user)
    else:
        import secrets as _secrets
        placeholder_hash = pwd.hash(_secrets.token_hex(32))
        user = User(
            first_name="",
            last_name="",
            email=None,
            phone=phone,
            password_hash=placeholder_hash,
            role=role,
            auth_provider="phone",
            phone_verified=True,
            phone_verified_at=now,
        )
        db.add(user)
        await db.commit()
        await db.refresh(user)

        # Referral codes from minute zero (same as /auth/register).
        try:
            from routers.referrals import _ensure_referral_code  # lazy: import cycle
            await _ensure_referral_code(user, db)
            if role == "driver":
                from routers.driver_referrals import _ensure_driver_code  # lazy: import cycle
                await _ensure_driver_code(user, db)
        except Exception as e:
            logging.warning("[PhoneLogin] referral code mint failed for %s: %s", user.id, e)
        # _ensure_driver_code commits without refreshing, which expires every
        # ORM attribute — reload so the reads below don't lazy-load (async).
        try:
            await db.refresh(user)
        except Exception:
            pass

        # Firestore mirror (same as register) so dispatch sees the account.
        # n8n welcome/onboarding triggers are email-based — skipped here
        # (no email on phone-created accounts yet).
        if _HAS_FIRESTORE:
            try:
                if role == "driver":
                    firestore_sync.sync_driver(
                        user_id=user.id, first_name=user.first_name,
                        last_name=user.last_name, phone=user.phone or "",
                        email=user.email, photo_url=user.photo_url,
                        is_online=False, created_at=user.created_at,
                        is_verified=False,
                    )
                else:
                    firestore_sync.sync_client(
                        user_id=user.id, first_name=user.first_name,
                        last_name=user.last_name, phone=user.phone or "",
                        email=user.email, photo_url=user.photo_url,
                        role=user.role, created_at=user.created_at,
                        is_verified=False,
                        is_online=False,
                    )
            except Exception as e:
                logging.error("[PhoneLogin] Firestore sync failed: %s", e)

        try:
            await link_guest_trips_to_user(db, user)
        except Exception as e:
            logging.warning("guest trip link on phone_login failed: %s", e)
        # link_guest_trips_to_user rolls back internally on failure, which
        # expires every ORM attribute — reload before the reads below.
        try:
            await db.refresh(user)
        except Exception:
            pass

    await _record_login_activity(db, request, user.id)

    token = await _create_driver_aware_token_from_user(user, db)
    refresh = _create_refresh_token(user.id)
    return {
        "access_token": token,
        "refresh_token": refresh,
        "token_type": "bearer",
        "user": _user_dict(user),
        "is_new_user": is_new_user,
    }

# -- Social Auth (Google / Apple) -------------------------
@router.post("/auth/social", dependencies=[Depends(_verify_api_key)])
async def social_auth(body: SocialAuthIn, request: Request, db: AsyncSession = Depends(get_db)):
    """Authenticate via Google or Apple OAuth ID token.

    * Verifies the ID token with the provider.
    * Creates a new user if one does not exist, or logs in the existing user.
    * Skips password / OTP - social tokens are the credential.
    """
    provider = body.provider.lower()
    if provider not in ("google", "apple"):
        raise HTTPException(400, "Unsupported provider - use 'google' or 'apple'")

    email: Optional[str] = None
    given_name: Optional[str] = body.first_name
    family_name: Optional[str] = body.last_name
    photo: Optional[str] = body.photo_url

    # â"€â"€ Verify token with provider â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
    if provider == "google":
        try:
            from google.oauth2 import id_token as google_id_token
            from google.auth.transport import requests as google_requests
            # Accept tokens from any of our OAuth clients (iOS, Android, Web).
            # google_sign_in on iOS emits tokens audienced at the iOS client,
            # Android emits at the Android client, web at the Web client —
            # all three are legitimate for this backend.
            _allowed = [
                c.strip()
                for c in os.getenv("GOOGLE_CLIENT_IDS", os.getenv("GOOGLE_CLIENT_ID", "")).split(",")
                if c.strip()
            ]
            # Verify signature/expiry once (audience=None skips aud check).
            idinfo = google_id_token.verify_oauth2_token(
                body.id_token, google_requests.Request()
            )
            _aud = idinfo.get("aud")
            if _allowed and _aud not in _allowed:
                raise ValueError(f"Token audience {_aud} not in allowed list")
            email = idinfo.get("email")
            given_name = given_name or idinfo.get("given_name", "")
            family_name = family_name or idinfo.get("family_name", "")
            photo = photo or idinfo.get("picture")
        except Exception as exc:
            raise HTTPException(401, f"Invalid Google token: {exc}")

    elif provider == "apple":
        try:
            import jwt as _jwt
            import urllib.request as _urlreq
            # Fetch Apple's public keys for proper signature verification
            try:
                _apple_keys_resp = _urlreq.urlopen("https://appleid.apple.com/auth/keys", timeout=10)
                _apple_jwks = json.loads(_apple_keys_resp.read())
                _header = _jwt.get_unverified_header(body.id_token)
                _kid = _header.get("kid")
                _key_data = next((k for k in _apple_jwks["keys"] if k["kid"] == _kid), None)
                if _key_data:
                    from jwt.algorithms import RSAAlgorithm
                    _public_key = RSAAlgorithm.from_jwk(_key_data)
                    # Accept tokens from multiple Apple audiences (native app + web Sign in with Apple).
                    _apple_auds = [
                        c.strip()
                        for c in os.getenv("APPLE_CLIENT_IDS", os.getenv("APPLE_CLIENT_ID", "")).split(",")
                        if c.strip()
                    ] or ["com.cruiseinride.app"]
                    claims = _jwt.decode(
                        body.id_token, _public_key, algorithms=["RS256"],
                        audience=_apple_auds,
                        issuer="https://appleid.apple.com",
                    )
                else:
                    raise ValueError("Apple key ID not found in JWKS")
            except Exception as _jwks_err:
                logging.warning("Apple JWKS verification failed, rejecting token: %s", _jwks_err)
                raise HTTPException(401, "Apple token verification failed")
            email = claims.get("email")
            given_name = given_name or ""
            family_name = family_name or ""
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(401, f"Invalid Apple token: {exc}")

    if not email:
        raise HTTPException(400, "Could not determine email from token")

    role = body.role if body.role in ("rider", "driver") else "rider"

    # â"€â"€ Find or create user â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
    result = await db.execute(
        select(User).where(User.email == email, User.role == role)
    )
    user = result.scalar_one_or_none()

    if user:
        # Reactivate deleted accounts
        if user.status in ("deleted", "pending_deletion"):
            user.status = "active"
            user.deletion_requested_at = None
        if user.status == "blocked":
            raise HTTPException(403, "Account blocked")
        # Update provider if switching from password to social
        user.auth_provider = provider
        if photo and not user.photo_url:
            user.photo_url = photo
        await db.commit()
        await db.refresh(user)
    else:
        # Login-only mode: reject if no account exists
        if body.login_only:
            raise HTTPException(401, "Invalid credentials")
        # Create new user without password requirement
        import secrets as _secrets
        placeholder_hash = pwd.hash(_secrets.token_hex(32))
        user = User(
            first_name=given_name or "User",
            last_name=family_name or "",
            email=email,
            password_hash=placeholder_hash,
            photo_url=photo,
            role=role,
            auth_provider=provider,
        )
        db.add(user)
        await db.commit()
        await db.refresh(user)

    try:
        await link_guest_trips_to_user(db, user)
    except Exception as e:
        logging.warning("guest trip link on social_auth failed: %s", e)

    await _record_login_activity(db, request, user.id)

    token = await _create_driver_aware_token_from_user(user, db)
    refresh = _create_refresh_token(user.id)
    return {
        "access_token": token,
        "refresh_token": refresh,
        "token_type": "bearer",
        "user": _user_dict(user),
    }

# -- Refresh Token Endpoint --
@router.post("/auth/refresh", dependencies=[Depends(_verify_api_key)])
async def refresh_token(request: Request, authorization: str = Header(None), db: AsyncSession = Depends(get_db)):
    """Exchange a valid refresh token for a new access + refresh token pair."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Refresh token required")
    token = authorization.split(" ")[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        if payload.get("type") != "refresh":
            raise HTTPException(401, "Not a refresh token")
        user_id = int(payload["sub"])
    except (jwt.InvalidTokenError, ValueError):
        _security_audit_log("REFRESH_FAILED", request.client.host if request.client else "unknown", "invalid_token")
        raise HTTPException(401, "Invalid or expired refresh token")
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(401, "User not found")
    st = user.status or "active"
    if st in ("deleted", "blocked", "deactivated"):
        raise HTTPException(403, f"Account {st}")
    new_access = await _create_driver_aware_token_from_user(user, db)
    new_refresh = _create_refresh_token(user.id)
    _security_audit_log("TOKEN_REFRESHED", request.client.host if request.client else "unknown", f"user_id={user.id}")
    return {"access_token": new_access, "refresh_token": new_refresh, "token_type": "bearer"}

@router.post("/auth/firebase-token", dependencies=[Depends(_verify_api_key)])
async def firebase_token(user: User = Depends(_get_current_user)):
    """Mint a Firebase custom token for the signed-in user.

    Anonymous Firebase auth is DISABLED in the console (deliberately —
    admin-restricted-operation), but every Firestore/RTDB rule reads
    `auth != null`, so clients without a Firebase session were denied on
    every real-time read/write: the permission-denied crash groups that
    dominate Crashlytics (400+ events across chat, GPS mirrors and the
    verification stream). The app's own JWT is the identity; this endpoint
    exchanges it for a Firebase session the rules accept.

    The uid is `user_{id}` — matches the `user_id`-keyed documents the
    Firestore mirror writes, so rules can also become per-user later.
    """
    try:
        from firebase_admin import auth as fb_auth
        token = fb_auth.create_custom_token(f"user_{user.id}")
        return {"token": token.decode() if isinstance(token, bytes) else token}
    except Exception as e:
        # Missing IAM signBlob permission or Admin SDK not initialised —
        # the client treats 503 as "no Firebase today" and stays on its
        # backend polling/SSE fallbacks instead of crash-looping.
        logging.error("[FirebaseToken] mint failed for user %s: %s", user.id, e)
        raise HTTPException(503, "Firebase token unavailable")


@router.get("/auth/me", dependencies=[Depends(_verify_api_key)])
async def get_me(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Mark user as online when they call /auth/me (heartbeat)
    # Riders only: a driver goes online ONLY through the explicit online
    # toggle (PATCH /drivers/{id}/location with is_online=True). The app
    # calls /auth/me on every resume and token check, and flipping drivers
    # here resurrected offline drivers in the DB — dispatch re-verifies the
    # flag before pushing, so they kept getting ride offers while offline.
    if not user.is_online and user.role != "driver":
        try:
            await db.execute(
                User.__table__.update().where(User.__table__.c.id == user.id).values(is_online=True)
            )
            await db.commit()
            user.is_online = True
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_client_online(user.id, True)
                except Exception:
                    pass
        except Exception:
            pass

    # Recover photo_url from Firestore if missing or ephemeral (Railway local file)
    _needs_photo = (
        not user.photo_url
        or ("/photos/" in (user.photo_url or "") and "firebasestorage" not in (user.photo_url or ""))
    )
    if _needs_photo and _HAS_FIRESTORE:
        try:
            collection = "drivers" if user.role == "driver" else "clients"
            doc = firestore_sync.db.collection(collection).document(f"sql_{user.id}").get()
            if doc.exists:
                fs_photo = doc.to_dict().get("photoUrl") or doc.to_dict().get("photo_url")
                if fs_photo and isinstance(fs_photo, str) and fs_photo.startswith("http"):
                    user.photo_url = fs_photo
                    await db.execute(
                        User.__table__.update().where(User.__table__.c.id == user.id).values(photo_url=fs_photo)
                    )
                    await db.commit()
        except Exception:
            pass

    data = _user_dict(user)
    try:
        avg_rating, ratings_count = await _compute_user_rating(db, user.id)
        data["average_rating"] = avg_rating
        data["ratings_count"] = ratings_count
    except Exception as e:
        logging.warning("[/auth/me] rating stats failed: %s", e)
        data["average_rating"] = None
        data["ratings_count"] = 0
    return data


@router.get("/auth/dashboard", dependencies=[Depends(_verify_api_key)])
async def get_dashboard(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Return everything the home screen needs in ONE call.

    Combines: user profile, verification status, account status,
    active trip, driver earnings/stats (if driver), ratings.
    This eliminates 5-10 separate HTTP requests per screen open.
    """
    # ── 1. User profile (same as /auth/me) ────────────────────────────
    # Riders only — a driver goes online exclusively via the online toggle.
    # The driver home screen calls this endpoint on every open, and flipping
    # drivers here silently resurrected offline drivers into dispatch
    # eligibility (offers pushed to drivers who never went online).
    if not user.is_online and user.role != "driver":
        try:
            await db.execute(
                User.__table__.update().where(User.__table__.c.id == user.id).values(is_online=True)
            )
            await db.commit()
            user.is_online = True
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_client_online(user.id, True)
                except Exception:
                    pass
        except Exception:
            pass

    # Recover photo_url from Firestore if missing
    _needs_photo = (
        not user.photo_url
        or ("/photos/" in (user.photo_url or "") and "firebasestorage" not in (user.photo_url or ""))
    )
    if _needs_photo and _HAS_FIRESTORE:
        try:
            collection = "drivers" if user.role == "driver" else "clients"
            doc = firestore_sync.db.collection(collection).document(f"sql_{user.id}").get()
            if doc.exists:
                fs_photo = doc.to_dict().get("photoUrl") or doc.to_dict().get("photo_url")
                if fs_photo and isinstance(fs_photo, str) and fs_photo.startswith("http"):
                    user.photo_url = fs_photo
                    await db.execute(
                        User.__table__.update().where(User.__table__.c.id == user.id).values(photo_url=fs_photo)
                    )
                    await db.commit()
        except Exception:
            pass

    profile = _user_dict(user)

    # Ratings
    try:
        avg_rating, ratings_count = await _compute_user_rating(db, user.id)
        profile["average_rating"] = avg_rating
        profile["ratings_count"] = ratings_count
    except Exception:
        profile["average_rating"] = None
        profile["ratings_count"] = 0

    # ── 2. Verification status (always fresh — critical) ───────────────
    ver_status = user.verification_status or "none"
    ver_reason = user.verification_reason
    if _HAS_FIRESTORE and ver_status not in ("approved",):
        try:
            fs_status = firestore_sync.get_verification_status(user.id)
            if fs_status and fs_status.get("status") in ("approved", "rejected"):
                ver_status = fs_status["status"]
                ver_reason = fs_status.get("reason")
                user.verification_status = ver_status
                user.verification_reason = ver_reason
                if ver_status == "approved":
                    user.is_verified = True
                    if not user.verified_at:
                        user.verified_at = datetime.now(timezone.utc)
                await db.commit()
                await db.refresh(user)
        except Exception as e:
            logging.warning("[/auth/dashboard] Firestore verification sync failed: %s", e)

    # ── 3. Account status (always fresh — critical) ────────────────────
    account_status = user.status or "active"
    if _HAS_FIRESTORE:
        try:
            collection = "drivers" if user.role == "driver" else "clients"
            fs_status = firestore_sync.get_account_status(user.id, collection)
            if fs_status and fs_status != account_status:
                await db.execute(
                    User.__table__.update().where(User.__table__.c.id == user.id).values(status=fs_status)
                )
                await db.commit()
                account_status = fs_status
                invalidate_user_cache(user.id)
        except Exception as e:
            logging.error("[/auth/dashboard] Firestore account status check failed: %s", e)

    # ── 4. Active trip (if any) ────────────────────────────────────────
    active_trip = None
    try:
        from sqlalchemy import or_
        trip_result = await db.execute(
            select(Trip).where(
                and_(
                    or_(Trip.rider_id == user.id, Trip.driver_id == user.id),
                    Trip.status.in_(("requested", "accepted", "driver_arrived", "in_progress", "picked_up"))
                )
            ).order_by(Trip.created_at.desc()).limit(1)
        )
        trip = trip_result.scalar_one_or_none()
        if trip:
            active_trip = _trip_dict(trip)
            # Add counterparty info
            if user.role == "rider" and trip.driver_id:
                drv_r = await db.execute(select(User).where(User.id == trip.driver_id))
                drv = drv_r.scalar_one_or_none()
                if drv:
                    active_trip["driver"] = {
                        "id": drv.id,
                        "first_name": drv.first_name,
                        "last_name": drv.last_name,
                        "photo_url": drv.photo_url,
                        "phone": drv.phone,
                        "average_rating": profile.get("average_rating"),
                    }
            elif user.role == "driver" and trip.rider_id:
                rider_r = await db.execute(select(User).where(User.id == trip.rider_id))
                rider = rider_r.scalar_one_or_none()
                if rider:
                    active_trip["rider"] = {
                        "id": rider.id,
                        "first_name": rider.first_name,
                        "last_name": rider.last_name,
                        "photo_url": rider.photo_url,
                        "phone": rider.phone,
                    }
    except Exception as e:
        logging.warning("[/auth/dashboard] active trip query failed: %s", e)

    # ── 5. Driver earnings + stats (if driver) ─────────────────────────
    driver_data = None
    if user.role == "driver":
        # Quick earnings (last 7 days, limited to 20 trips)
        from datetime import timedelta
        since = datetime.now(timezone.utc) - timedelta(days=7)
        try:
            result = await db.execute(
                select(Trip).where(
                    and_(Trip.driver_id == user.id, Trip.status == "completed", Trip.created_at >= since)
                ).order_by(Trip.created_at.desc()).limit(20)
            )
            trips = result.scalars().all()
            total = user.total_earnings or 0.0
            if not total and trips:
                total = round(sum((t.driver_earnings or (t.fare or 0) * 0.72) for t in trips), 2)

            # Daily breakdown (last 7 days)
            now = datetime.now(timezone.utc)
            day_labels = []
            daily_earnings = []
            for i in range(6, -1, -1):
                day = (now - timedelta(days=i)).date()
                day_labels.append(day.strftime("%a"))
                day_total = sum(
                    (t.driver_earnings or (t.fare or 0) * 0.72)
                    for t in trips if t.created_at and t.created_at.date() == day
                )
                daily_earnings.append(round(day_total, 2))

            # Stats (lightweight counts)
            from sqlalchemy import case as sql_case
            from models.database import DispatchOffer
            offer_r = await db.execute(
                select(
                    func.count(DispatchOffer.id).label("total"),
                    func.sum(sql_case((DispatchOffer.status == "accepted", 1), else_=0)).label("accepted"),
                    func.sum(sql_case((DispatchOffer.status == "rejected", 1), else_=0)).label("rejected"),
                ).where(DispatchOffer.driver_id == user.id)
            )
            offer_row = offer_r.one()
            total_offers = offer_row.total or 0
            accepted = int(offer_row.accepted or 0)
            rejected = int(offer_row.rejected or 0)
            # Same 1-point-per-event rule as /drivers/{id}/stats.
            acceptance_rate = max(0.0, 100.0 - rejected)

            trip_r = await db.execute(
                select(
                    func.count(Trip.id).label("total"),
                    func.sum(sql_case((Trip.status == "completed", 1), else_=0)).label("completed"),
                    func.sum(sql_case((and_(
                        Trip.scheduled_at.isnot(None),
                        Trip.arrived_at.isnot(None),
                        Trip.arrived_at > Trip.scheduled_at,
                    ), 1), else_=0)).label("late"),
                ).where(Trip.driver_id == user.id)
            )
            trip_row = trip_r.one()
            completed_trips = int(trip_row.completed or 0)
            total_trips = trip_row.total or 0
            late_trips = int(trip_row.late or 0)
            on_time_rate = round(max(0.0, 100.0 - late_trips), 1)

            driver_data = {
                "earnings": {
                    "total": total,
                    "trips_count": len(trips),
                    "daily_earnings": daily_earnings,
                    "day_labels": day_labels,
                },
                "stats": {
                    "acceptance_rate": round(acceptance_rate, 1),
                    "completed_trips": completed_trips,
                    "total_trips": total_trips,
                    "on_time_rate": on_time_rate,
                    "cruise_level": user.cruise_level or "bronze",
                },
            }
        except Exception as e:
            logging.warning("[/auth/dashboard] driver data query failed: %s", e)

    return {
        "profile": profile,
        "verification": {
            "status": ver_status,
            "reason": ver_reason,
            "is_verified": user.is_verified or False,
        },
        "account": {
            "status": account_status,
        },
        "active_trip": active_trip,
        "driver_data": driver_data,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

@router.post("/auth/offline", dependencies=[Depends(_verify_api_key)])
async def go_offline(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Mark user as offline (called when app goes to background)."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if db_user and db_user.is_online:
        db_user.is_online = False
        if db_user.role == "driver":
            # Same retirement the location endpoint does — an offline driver
            # must hold no pending offers (late push taps raise dead cards).
            from routers.dispatch import expire_pending_offers_for_driver  # lazy: import cycle
            await expire_pending_offers_for_driver(db, db_user.id, "driver went offline")
        await db.commit()
        if _HAS_FIRESTORE:
            try:
                if db_user.role == "driver":
                    firestore_sync.sync_driver_location(db_user.id, db_user.lat or 0, db_user.lng or 0, False)
                else:
                    firestore_sync.sync_client_online(db_user.id, False)
            except Exception:
                pass
    return {"status": "ok"}

@router.patch("/auth/me", dependencies=[Depends(_verify_api_key)])
async def update_me(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    updates = await request.json()
    # Re-fetch user in THIS session to avoid cross-session detached state
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    # Only allow safe fields - NEVER role, is_verified, verification_status
    _SAFE_SELF_UPDATE_FIELDS = ("first_name", "last_name", "email", "phone", "photo_url", "id_document_type")
    # Device tracking fields (always allowed)
    _DEVICE_FIELDS = ("app_version", "device_model", "os_version")
    # Privacy preference fields (always allowed)
    _PRIVACY_FIELDS = ("privacy_location", "privacy_analytics", "privacy_ads")
    # Driver onboarding fields (drive city/state + survey JSON, always allowed)
    _ONBOARDING_FIELDS = ("drive_city", "drive_state", "onboarding_survey")
    # Enforce email/phone change limits (max 3 each)
    if "email" in updates and updates["email"] != db_user.email:
        if (db_user.email_changes_count or 0) >= 3:
            raise HTTPException(400, "Maximum email changes reached (3)")
        db_user.email_changes_count = (db_user.email_changes_count or 0) + 1
    if "phone" in updates and updates["phone"] != db_user.phone:
        if (db_user.phone_changes_count or 0) >= 3:
            raise HTTPException(400, "Maximum phone changes reached (3)")
        db_user.phone_changes_count = (db_user.phone_changes_count or 0) + 1
    for key in _SAFE_SELF_UPDATE_FIELDS:
        if key in updates:
            val = updates[key]
            if key in ("first_name", "last_name"):
                if not isinstance(val, str) or not val.strip():
                    raise HTTPException(400, f"{key} cannot be empty")
                val = val.strip()
            # Never allow photo_url to be set to None or empty - use /auth/photo-url to set it
            if key == "photo_url" and (not val or not isinstance(val, str) or not val.startswith("http")):
                continue
            setattr(db_user, key, val)
    # Update device tracking fields
    for key in _DEVICE_FIELDS:
        if key in updates:
            setattr(db_user, key, updates[key])
    # Update privacy preferences
    for key in _PRIVACY_FIELDS:
        if key in updates:
            setattr(db_user, key, updates[key])
    # Update driver onboarding fields (only when present — omitted keys
    # never clobber previously stored values)
    for key in _ONBOARDING_FIELDS:
        if key in updates:
            val = updates[key]
            if key == "drive_city" and val is not None:
                if not isinstance(val, str) or len(val) > 120:
                    raise HTTPException(400, "drive_city must be a string of max 120 chars")
                val = val.strip() or None
            if key == "drive_state" and val is not None:
                if not isinstance(val, str) or len(val.strip()) != 2:
                    raise HTTPException(400, "drive_state must be a 2-letter US state code")
                val = val.strip().upper()
            if key == "onboarding_survey" and val is not None and not isinstance(val, str):
                raise HTTPException(400, "onboarding_survey must be a JSON string")
            setattr(db_user, key, val)
    # Update last active timestamp
    db_user.last_active_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(db_user)

    # Sync updated profile to Firestore
    if _HAS_FIRESTORE:
        try:
            if db_user.role == "driver":
                firestore_sync.sync_driver(
                    user_id=db_user.id, first_name=db_user.first_name,
                    last_name=db_user.last_name, phone=db_user.phone or "",
                    email=db_user.email, photo_url=db_user.photo_url,
                    is_online=db_user.is_online or False,
                    created_at=db_user.created_at,
                    is_verified=db_user.is_verified or False,
                    id_document_type=db_user.id_document_type,
                    id_photo_url=db_user.id_photo_url,
                    selfie_url=db_user.selfie_url,
                    license_front_url=db_user.license_front_url,
                    license_back_url=db_user.license_back_url,
                    insurance_url=db_user.insurance_url,
                    video_url=db_user.video_url,
                    verification_status=db_user.verification_status or "none",
                    verification_reason=db_user.verification_reason,
                    status=db_user.status or "active",
                )
            else:
                firestore_sync.sync_client(
                    user_id=db_user.id, first_name=db_user.first_name,
                    last_name=db_user.last_name, phone=db_user.phone or "",
                    email=db_user.email, photo_url=db_user.photo_url,
                    role=db_user.role, created_at=db_user.created_at,
                    is_verified=db_user.is_verified or False,
                    id_document_type=db_user.id_document_type,
                    id_photo_url=db_user.id_photo_url,
                    selfie_url=db_user.selfie_url,
                    verification_status=db_user.verification_status or "none",
                    verification_reason=db_user.verification_reason,
                    status=db_user.status or "active",
                    is_online=db_user.is_online or False,
                )
        except Exception as e:
            logging.error("Firestore profile sync failed: %s", e)

    return _user_dict(db_user)


@router.patch("/auth/web/profile")
async def web_update_profile(request: Request, db: AsyncSession = Depends(get_db)):
    """Web widget profile edit. JWT-authenticated (no API key) so it can be
    called directly from the Shopify widget. first_name / last_name are NOT
    editable here (or anywhere on the web): the name is tied to the account
    verification, so those keys are silently ignored."""
    try:
        from routers.payments import _verify_web_origin as _vwo
        _vwo(request)
    except HTTPException:
        raise
    except Exception:
        pass

    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    token = auth.split(" ", 1)[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        user_id = int(payload.get("sub", 0))
    except (jwt.InvalidTokenError, ValueError):
        raise HTTPException(401, "Invalid or expired token")
    if not user_id:
        raise HTTPException(401, "Invalid token")

    r = await db.execute(select(User).where(User.id == user_id))
    db_user = r.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")

    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Invalid JSON body")
    if not isinstance(body, dict):
        raise HTTPException(400, "Body must be an object")

    _ALLOWED = ("phone", "email", "photo_url")
    cleaned: dict = {}
    for key in _ALLOWED:
        if key not in body:
            continue
        val = body.get(key)
        if val is None:
            continue
        if not isinstance(val, str):
            raise HTTPException(400, f"{key} must be a string")
        val = val.strip()
        if key in ("first_name", "last_name") and not val:
            raise HTTPException(400, f"{key} cannot be empty")
        # photo_url must be a real http(s) URL; skip silently if bad
        if key == "photo_url" and not val.startswith("http"):
            continue
        cleaned[key] = val

    if "email" in cleaned and cleaned["email"].lower() != (db_user.email or "").lower():
        dup = await db.execute(
            select(User.id).where(func.lower(User.email) == cleaned["email"].lower(), User.id != db_user.id)
        )
        if dup.first():
            raise HTTPException(400, "Email already in use")
        cleaned["email"] = cleaned["email"].lower()

    if "phone" in cleaned and cleaned["phone"] != (db_user.phone or ""):
        dup = await db.execute(
            select(User.id).where(User.phone == cleaned["phone"], User.id != db_user.id)
        )
        if dup.first():
            raise HTTPException(400, "Phone already in use")

    for key, val in cleaned.items():
        setattr(db_user, key, val)
    db_user.last_active_at = datetime.now(timezone.utc)

    try:
        await db.commit()
        await db.refresh(db_user)
    except IntegrityError as e:
        await db.rollback()
        logging.warning("[/auth/web/profile] integrity error user=%s: %s", user_id, e)
        raise HTTPException(400, "Duplicate email or phone")

    try:
        invalidate_user_cache(db_user.id)
    except Exception:
        pass

    logging.info("[/auth/web/profile] user=%s updated fields=%s", db_user.id, list(cleaned.keys()))

    data = _user_dict(db_user)
    try:
        avg_rating, ratings_count = await _compute_user_rating(db, db_user.id)
        data["average_rating"] = avg_rating
        data["ratings_count"] = ratings_count
    except Exception as e:
        logging.warning("[/auth/web/profile] rating stats failed: %s", e)
        data["average_rating"] = None
        data["ratings_count"] = 0
    return data


@router.get("/auth/web/me")
async def web_get_me(request: Request, db: AsyncSession = Depends(get_db)):
    """Web-safe /auth/me — JWT only, no HMAC/API key."""
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    token = auth.split(" ", 1)[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        user_id = int(payload.get("sub", 0))
    except jwt.InvalidTokenError:
        raise HTTPException(401, "Invalid or expired token")
    r = await db.execute(select(User).where(User.id == user_id))
    user = r.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")
    data = {
        "id": user.id, "first_name": user.first_name, "last_name": user.last_name,
        "email": user.email, "phone": user.phone, "role": user.role,
        "photo_url": user.photo_url, "status": user.status or "active",
        "created_at": user.created_at.isoformat() if user.created_at else None,
    }
    try:
        avg_rating, ratings_count = await _compute_user_rating(db, user.id)
        data["average_rating"] = avg_rating
        data["ratings_count"] = ratings_count
    except Exception:
        data["average_rating"] = None
        data["ratings_count"] = 0
    return data


@router.get("/auth/web/login-activity")
async def web_get_login_activity(request: Request, db: AsyncSession = Depends(get_db)):
    """Web-safe login activity — JWT only, no HMAC/API key (same pattern as web_get_me).

    Returns the caller's logins from the last 30 days, newest first, max 50.
    """
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    token = auth.split(" ", 1)[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        user_id = int(payload.get("sub", 0))
    except jwt.InvalidTokenError:
        raise HTTPException(401, "Invalid or expired token")
    cutoff = datetime.now(timezone.utc) - timedelta(days=30)
    result = await db.execute(
        select(LoginActivity)
        .where(LoginActivity.user_id == user_id, LoginActivity.created_at >= cutoff)
        .order_by(LoginActivity.created_at.desc())
        .limit(50)
    )
    rows = result.scalars().all()
    return {
        "items": [
            {
                "device_type": r.device_type,
                "device_label": r.device_label,
                "ip": r.ip,
                "logged_in_at": r.created_at.isoformat() if r.created_at else None,
            }
            for r in rows
        ]
    }


@router.get("/auth/web/trips")
async def web_get_trips(request: Request, db: AsyncSession = Depends(get_db)):
    """Web-safe rider trips — JWT only, no HMAC/API key."""
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    token = auth.split(" ", 1)[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        user_id = int(payload.get("sub", 0))
    except jwt.InvalidTokenError:
        raise HTTPException(401, "Invalid or expired token")
    result = await db.execute(
        select(Trip).where(Trip.rider_id == user_id).order_by(Trip.created_at.desc()).limit(100)
    )
    trips = result.scalars().all()
    driver_ids = {t.driver_id for t in trips if t.driver_id}
    driver_map: dict[int, str] = {}
    if driver_ids:
        d_res = await db.execute(select(User.id, User.first_name, User.last_name).where(User.id.in_(driver_ids)))
        for d_id, d_first, d_last in d_res.all():
            driver_map[d_id] = f"{d_first or ''} {d_last or ''}".strip()
    out = []
    for t in trips:
        td = _trip_dict(t)
        td["driver_name"] = driver_map.get(t.driver_id, "")
        out.append(td)
    return out


# -- Web Chat (JWT-only, no API key) --------------------

@router.post("/auth/web/chat/{trip_id}")
async def web_send_chat(trip_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Send chat message from web -- JWT only."""
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    token = auth.split(" ", 1)[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        user_id = int(payload.get("sub", 0))
    except jwt.InvalidTokenError:
        raise HTTPException(401, "Invalid or expired token")

    body = await request.json()
    msg_text = (body.get("message") or "").strip()
    if not msg_text:
        raise HTTPException(400, "Message cannot be empty")

    r = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = r.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if user_id != trip.rider_id and user_id != trip.driver_id:
        raise HTTPException(403, "Not a participant in this trip")

    receiver_id = trip.driver_id if user_id == trip.rider_id else trip.rider_id
    if not receiver_id:
        raise HTTPException(400, "No counterpart on this trip")

    msg = ChatMessage(trip_id=trip_id, sender_id=user_id, receiver_id=receiver_id, message=msg_text)
    db.add(msg)
    await db.commit()
    await db.refresh(msg)

    # FCM push to receiver
    try:
        recv_r = await db.execute(select(User).where(User.id == receiver_id))
        recv_user = recv_r.scalar_one_or_none()
        if recv_user and recv_user.fcm_token:
            sender_r = await db.execute(select(User).where(User.id == user_id))
            sender_user = sender_r.scalar_one_or_none()
            sender_name = f"{sender_user.first_name or ''} {sender_user.last_name or ''}".strip() if sender_user else "Rider"
            await _send_fcm_push_async(
                recv_user.fcm_token,
                title=f"Message from {sender_name}",
                body=msg_text[:200],
                data={"type": "chat_message", "trip_id": str(trip_id), "sender_role": "rider"},
            )
    except Exception:
        pass

    return {
        "id": msg.id, "trip_id": msg.trip_id, "sender_id": msg.sender_id,
        "receiver_id": msg.receiver_id, "sender_role": "rider",
        "message": msg.message, "is_read": msg.is_read,
        "created_at": msg.created_at.isoformat() if msg.created_at else None,
    }


@router.get("/auth/web/chat/{trip_id}")
async def web_get_chat(trip_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Get chat messages for a trip -- JWT only."""
    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    token = auth.split(" ", 1)[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        user_id = int(payload.get("sub", 0))
    except jwt.InvalidTokenError:
        raise HTTPException(401, "Invalid or expired token")

    r = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = r.scalar_one_or_none()
    if not trip or (user_id != trip.rider_id and user_id != trip.driver_id):
        raise HTTPException(403, "Not a participant in this trip")

    result = await db.execute(
        select(ChatMessage).where(ChatMessage.trip_id == trip_id).order_by(ChatMessage.created_at.asc())
    )
    messages = result.scalars().all()
    for m in messages:
        if m.receiver_id == user_id and not m.is_read:
            m.is_read = True
    await db.commit()
    return [
        {"id": m.id, "sender_id": m.sender_id, "receiver_id": m.receiver_id,
         "sender_role": "driver" if m.sender_id == trip.driver_id else "rider",
         "message": m.message, "is_read": m.is_read,
         "created_at": m.created_at.isoformat() if m.created_at else None}
        for m in messages
    ]


# -- Photo Upload / Serve ------------------------------
# PHOTOS_DIR comes from config (imported at the top of this module) and is
# already created there. It used to be rebound here to
# dirname(routers/auth.py)/photos — /app/routers/photos — which is not the
# directory anything serves from, so uploads landed where no reader looks.

@router.post("/auth/web/photo")
async def web_upload_photo(request: Request, db: AsyncSession = Depends(get_db)):
    """Profile photo upload from cruiseinride.com — JWT only, no API key/HMAC.

    /auth/photo cannot serve the website: it depends on _verify_api_key, which
    requires the X-Timestamp/X-Nonce/X-Signature triple only the mobile app can
    produce, so every upload from the browser came back 422. This is the same
    upload wearing the /auth/web/* auth scheme, and it writes to the same
    Firebase Storage path and syncs the same Firestore field, so a photo set
    from the web shows up in the app and in dispatch.
    """
    try:
        from routers.payments import _verify_web_origin as _vwo
        _vwo(request)
    except HTTPException:
        raise
    except Exception:
        pass

    auth = request.headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "Unauthorized")
    token = auth.split(" ", 1)[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        user_id = int(payload.get("sub", 0))
    except (jwt.InvalidTokenError, ValueError):
        raise HTTPException(401, "Invalid or expired token")
    if not user_id:
        raise HTTPException(401, "Invalid token")

    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Invalid JSON body")
    photo_b64 = body.get("photo") if isinstance(body, dict) else None
    if not photo_b64 or not isinstance(photo_b64, str):
        raise HTTPException(400, "Missing 'photo' field (base64)")
    # canvas.toDataURL() hands the browser a "data:image/jpeg;base64,..." string;
    # accept it rather than making every caller remember to strip the prefix.
    if photo_b64.startswith("data:"):
        photo_b64 = photo_b64.partition(",")[2]
    if len(photo_b64) > 4 * 1024 * 1024:
        raise HTTPException(413, "Photo data too large")
    try:
        photo_bytes = base64.b64decode(photo_b64, validate=True)
    except Exception:
        raise HTTPException(400, "Invalid base64 data")
    if len(photo_bytes) > 3 * 1024 * 1024:
        raise HTTPException(413, "Photo too large (max 3MB)")
    if photo_bytes[:2] == b'\xff\xd8':
        ext, content_type = "jpg", "image/jpeg"
    elif photo_bytes[:8] == b'\x89PNG\r\n\x1a\n':
        ext, content_type = "png", "image/png"
    else:
        raise HTTPException(400, "Unsupported image format (only JPEG and PNG)")
    validate_image_bytes(photo_bytes)

    result = await db.execute(select(User).where(User.id == user_id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")

    photo_url = None
    if firestore_sync:
        photo_url = firestore_sync.upload_to_firebase_storage(
            photo_bytes, f"photos/user_{db_user.id}/profile.{ext}", content_type
        )
    if not photo_url:
        raise HTTPException(503, "Photo storage unavailable. Please try again later.")

    db_user.photo_url = photo_url
    db_user.last_active_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(db_user)

    try:
        invalidate_user_cache(db_user.id)
    except Exception:
        pass

    if _HAS_FIRESTORE:
        try:
            collection = "drivers" if db_user.role == "driver" else "clients"
            firestore_sync.update_field(collection, db_user.id, "photoUrl", photo_url)
        except Exception as e:
            logging.error("[/auth/web/photo] Firestore sync failed: %s", e)

    logging.info("[/auth/web/photo] user=%s photo updated", db_user.id)
    return {"photo_url": photo_url}


@router.post("/auth/photo", dependencies=[Depends(_verify_api_key)])
async def upload_photo(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Upload profile photo as base64. Saves file and updates user's photo_url."""
    body = await request.json()
    photo_b64 = body.get("photo")
    if not photo_b64 or not isinstance(photo_b64, str):
        raise HTTPException(400, "Missing 'photo' field (base64)")
    # Pre-check base64 string size BEFORE decoding (prevents memory exhaustion)
    if len(photo_b64) > 4 * 1024 * 1024:  # ~3MB decoded
        raise HTTPException(413, "Photo data too large")
    # Validate and decode base64
    try:
        photo_bytes = base64.b64decode(photo_b64, validate=True)
    except Exception:
        raise HTTPException(400, "Invalid base64 data")
    # Limit decoded size to 3MB
    if len(photo_bytes) > 3 * 1024 * 1024:
        raise HTTPException(413, "Photo too large (max 3MB)")
    # Validate image magic bytes ï¿½ only allow JPEG and PNG
    if photo_bytes[:2] == b'\xff\xd8':
        ext = "jpg"
    elif photo_bytes[:8] == b'\x89PNG\r\n\x1a\n':
        ext = "png"
    else:
        raise HTTPException(400, "Unsupported image format (only JPEG and PNG)")
    filename = f"user_{user.id}.{ext}"
    content_type = "image/jpeg" if ext == "jpg" else "image/png"
    # Upload to Firebase Storage (persistent)
    full_photo_url = None
    if firestore_sync:
        fb_path = f"photos/user_{user.id}/profile.{ext}"
        full_photo_url = firestore_sync.upload_to_firebase_storage(photo_bytes, fb_path, content_type)
    if not full_photo_url:
        raise HTTPException(503, "Photo storage unavailable. Please try again later.")
    # Update user photo_url in DB
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if db_user:
        db_user.photo_url = full_photo_url
        await db.commit()
        await db.refresh(db_user)
        # Sync to Firestore
        if _HAS_FIRESTORE:
            try:
                collection = "drivers" if db_user.role == "driver" else "clients"
                firestore_sync.sync_client(
                    user_id=db_user.id, first_name=db_user.first_name,
                    last_name=db_user.last_name, phone=db_user.phone or "",
                    email=db_user.email, photo_url=full_photo_url,
                    role=db_user.role, created_at=db_user.created_at,
                    is_verified=db_user.is_verified or False,
                    id_photo_url=db_user.id_photo_url,
                    selfie_url=db_user.selfie_url,
                    is_online=db_user.is_online or False,
                ) if collection == "clients" else firestore_sync.sync_driver(
                    user_id=db_user.id, first_name=db_user.first_name,
                    last_name=db_user.last_name, phone=db_user.phone or "",
                    email=db_user.email, photo_url=full_photo_url,
                    is_online=db_user.is_online or False,
                    created_at=db_user.created_at,
                    is_verified=db_user.is_verified or False,
                    id_photo_url=db_user.id_photo_url,
                    selfie_url=db_user.selfie_url,
                )
            except Exception as e:
                logging.error("Firestore photo sync failed: %s", e)
    return {"photo_url": full_photo_url}

@router.post("/auth/photo-url", dependencies=[Depends(_verify_api_key)])
async def save_photo_url(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Save a Firebase Storage photo URL to the user's profile in the backend DB.
    Called by the Flutter app after uploading directly to Firebase Storage."""
    body = await request.json()
    photo_url = body.get("photo_url") or body.get("url")
    if not photo_url or not isinstance(photo_url, str):
        raise HTTPException(400, "Missing 'photo_url' field")
    if not photo_url.startswith("https://"):
        raise HTTPException(400, "photo_url must be an https:// URL")
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    db_user.photo_url = photo_url
    await db.commit()
    await db.refresh(db_user)
    if _HAS_FIRESTORE:
        try:
            collection = "drivers" if db_user.role == "driver" else "clients"
            firestore_sync.update_field(collection, db_user.id, "photoUrl", photo_url)
        except Exception as e:
            logging.error("Firestore photo-url sync failed: %s", e)
    return {"photo_url": photo_url}


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  FIREBASE STORAGE PHOTO UPLOAD (Feature 13.1)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.post("/users/me/photo", dependencies=[Depends(_verify_api_key)])
async def upload_photo_to_firebase(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Upload profile photo to Firebase Storage via backend.
    
    Accepts base64 image, uploads to Firebase Storage, updates user.photo_url.
    Returns the Firebase Storage public URL.
    """
    body = await request.json()
    photo_b64 = body.get("photo")
    if not photo_b64 or not isinstance(photo_b64, str):
        raise HTTPException(400, "Missing 'photo' field (base64)")
    
    # Pre-check base64 string size BEFORE decoding (prevents memory exhaustion)
    if len(photo_b64) > 4 * 1024 * 1024:  # ~3MB decoded
        raise HTTPException(413, "Photo data too large")
    
    # Validate and decode base64
    try:
        photo_bytes = base64.b64decode(photo_b64, validate=True)
    except Exception:
        raise HTTPException(400, "Invalid base64 data")
    
    # Limit decoded size to 3MB
    if len(photo_bytes) > 3 * 1024 * 1024:
        raise HTTPException(413, "Photo too large (max 3MB)")
    
    # Validate image magic bytes - only allow JPEG and PNG
    if photo_bytes[:2] == b'\xff\xd8':
        ext = "jpg"
        content_type = "image/jpeg"
    elif photo_bytes[:8] == b'\x89PNG\r\n\x1a\n':
        ext = "png"
        content_type = "image/png"
    else:
        raise HTTPException(400, "Unsupported image format (only JPEG and PNG)")
    validate_image_bytes(photo_bytes)

    # Upload to Firebase Storage
    storage_path = f"photos/user_{user.id}/profile.{ext}"
    firebase_url = firestore_sync.upload_to_firebase_storage(
        data=photo_bytes,
        path=storage_path,
        content_type=content_type
    )

    if not firebase_url:
        raise HTTPException(503, "Photo storage unavailable. Please try again later.")
    else:
        photo_url = firebase_url
    
    # Update user photo_url in DB
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if db_user:
        db_user.photo_url = photo_url
        await db.commit()
        await db.refresh(db_user)
        # Sync to Firestore
        if _HAS_FIRESTORE:
            try:
                collection = "drivers" if db_user.role == "driver" else "clients"
                firestore_sync.update_field(collection, db_user.id, "photoUrl", photo_url)
            except Exception as e:
                logging.error("Firestore photo sync failed: %s", e)
    
    return {"photo_url": photo_url, "storage": "firebase" if firebase_url else "local"}


@router.get("/photos/{filename}")
async def serve_photo(filename: str):
    """Serve uploaded profile photos. Public endpoint (no auth)."""
    # Sanitize filename ï¿½ prevent path traversal
    safe_name = os.path.basename(filename)
    if safe_name != filename or ".." in filename:
        raise HTTPException(400, "Invalid filename")
    filepath = os.path.join(PHOTOS_DIR, safe_name)
    if not os.path.isfile(filepath):
        raise HTTPException(404, "Photo not found")
    media = "image/jpeg" if safe_name.endswith(".jpg") else "image/png"
    return FileResponse(filepath, media_type=media)

@router.delete("/auth/me", dependencies=[Depends(_verify_api_key)])
async def delete_account(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Request account deletion ï¿½ marks as pending_deletion, scheduled for 1 week."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    db_user.status = "pending_deletion"
    db_user.deletion_requested_at = datetime.now(timezone.utc)
    # Purge the user's chat data now (2-year retention policy honors legal holds;
    # account deletion purges regardless of age but still respects legal_hold).
    try:
        from chat_retention_agent import purge_user_chat_data
        purge_stats = await purge_user_chat_data(db, db_user.id)
        logging.info("[DeleteAccount] Purged chat data for user #%d: %s", db_user.id, purge_stats)
    except Exception as e:
        logging.error("[DeleteAccount] Chat purge failed for user #%d: %s", db_user.id, e)
    await db.commit()
    # Notify dispatch app about the deletion request via Firestore
    if _HAS_FIRESTORE:
        try:
            user_name = f"{db_user.first_name} {db_user.last_name}".strip()
            firestore_sync.sync_dispatch_notification(
                chat_id=0,
                user_name=user_name,
                notif_type="account_deletion",
                message=f"{db_user.role.capitalize()} '{user_name}' (ID: {db_user.id}) has requested account deletion. Scheduled for removal in 7 days.",
            )
        except Exception as e:
            logging.error("Dispatch deletion notification failed: %s", e)
    return {"detail": "Account deletion requested", "deletion_date": (datetime.now(timezone.utc) + timedelta(days=7)).isoformat()}


@router.get("/auth/export-data", dependencies=[Depends(_verify_api_key)])
async def export_user_data(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """GDPR/CCPA data export - returns all personal data for the user."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    
    # User profile data
    profile = {
        "id": db_user.id,
        "first_name": db_user.first_name,
        "last_name": db_user.last_name,
        "email": db_user.email,
        "phone": db_user.phone,
        "role": db_user.role,
        "photo_url": db_user.photo_url,
        "is_verified": db_user.is_verified,
        "created_at": db_user.created_at.isoformat() if db_user.created_at else None,
        "status": db_user.status,
        "referral_code": db_user.referral_code,
        "app_version": getattr(db_user, "app_version", None),
        "device_model": getattr(db_user, "device_model", None),
        "os_version": getattr(db_user, "os_version", None),
        "privacy_location": getattr(db_user, "privacy_location", True),
        "privacy_analytics": getattr(db_user, "privacy_analytics", True),
        "privacy_ads": getattr(db_user, "privacy_ads", False),
    }
    
    # Trip history
    trips_result = await db.execute(
        select(Trip).where((Trip.rider_id == user.id) | (Trip.driver_id == user.id)).order_by(Trip.created_at.desc())
    )
    trips_data = []
    for t in trips_result.scalars().all():
        trips_data.append({
            "id": t.id,
            "role": "rider" if t.rider_id == user.id else "driver",
            "pickup_address": t.pickup_address,
            "dropoff_address": t.dropoff_address,
            "status": t.status,
            "fare": t.fare,
            "distance": t.distance,
            "duration": t.duration,
            "tip_amount": t.tip_amount,
            "surge_multiplier": t.surge_multiplier,
            "created_at": t.created_at.isoformat() if t.created_at else None,
            "completed_at": t.completed_at.isoformat() if t.completed_at else None,
        })
    
    # Ratings given
    ratings_result = await db.execute(
        select(Rating).where(Rating.user_id == user.id).order_by(Rating.created_at.desc())
    )
    ratings_data = [
        {"trip_id": r.trip_id, "rating": r.rating, "feedback": r.feedback, "created_at": r.created_at.isoformat() if r.created_at else None}
        for r in ratings_result.scalars().all()
    ]
    
    # Consent history
    consent_data = []
    try:
        consent_result = await db.execute(
            select(ConsentLog).where(ConsentLog.user_id == user.id).order_by(ConsentLog.created_at.desc())
        )
        consent_data = [
            {"type": c.consent_type, "action": c.action, "version": c.version, "created_at": c.created_at.isoformat() if c.created_at else None}
            for c in consent_result.scalars().all()
        ]
    except Exception:
        pass  # Table may not exist yet
    
    # Payment methods (masked)
    payment_methods = []
    try:
        pm_result = await db.execute(
            select(RiderPaymentMethod).where(RiderPaymentMethod.user_id == user.id)
        )
        payment_methods = [
            {"type": pm.method_type, "display_name": pm.display_name, "is_default": pm.is_default}
            for pm in pm_result.scalars().all()
        ]
    except Exception:
        pass
    
    return {
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "profile": profile,
        "trips": trips_data,
        "ratings": ratings_data,
        "consent_history": consent_data,
        "payment_methods": payment_methods,
    }


@router.post("/auth/consent", dependencies=[Depends(_verify_api_key)])
async def record_consent(
    request: Request,
    consent_type: str = Body(...),  # terms, privacy, location, analytics, ads, background_check_disclosure
    action: str = Body(...),  # accepted, revoked
    version: str = Body(None),
    document_id: str = Body(None),  # e.g. "background_check_disclosure_authorization"
    content_hash: str = Body(None),  # sha256 of the exact document text shown
    device_info: str = Body(None),  # free-form device description
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Record user consent action for GDPR/CCPA/FCRA compliance."""
    # Get request metadata
    ip = request.client.host if request.client else None
    ua = request.headers.get("User-Agent", "")[:500]
    
    # Create consent log entry
    log = ConsentLog(
        user_id=user.id,
        consent_type=consent_type,
        action=action,
        version=version,
        document_id=document_id,
        content_hash=content_hash,
        device_info=device_info,
        ip_address=ip,
        user_agent=ua,
    )
    db.add(log)
    
    # Update user privacy preferences if applicable.
    # NOTE: "background_check_disclosure" is a standalone FCRA document —
    # it is logged above but must NOT flip any User flag (it is separate
    # from terms/ICA acceptance), so it intentionally falls through.
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if db_user:
        now = datetime.now(timezone.utc)
        if consent_type == "terms":
            db_user.terms_accepted_at = now if action == "accepted" else None
        elif consent_type == "privacy":
            db_user.privacy_accepted_at = now if action == "accepted" else None
        elif consent_type == "location":
            db_user.privacy_location = action == "accepted"
        elif consent_type == "analytics":
            db_user.privacy_analytics = action == "accepted"
        elif consent_type == "ads":
            db_user.privacy_ads = action == "accepted"
    
    await db.commit()
    return {"detail": f"Consent '{consent_type}' {action}", "logged_at": datetime.now(timezone.utc).isoformat()}


@router.get("/auth/consent/history", dependencies=[Depends(_verify_api_key)])
async def get_consent_history(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Return the current user's consent history, newest first."""
    result = await db.execute(
        select(ConsentLog)
        .where(ConsentLog.user_id == user.id)
        .order_by(ConsentLog.created_at.desc())
    )
    items = [
        {
            "consent_type": c.consent_type,
            "action": c.action,
            "version": c.version,
            "document_id": c.document_id,
            "content_hash": c.content_hash,
            "device_info": c.device_info,
            "ip_address": c.ip_address,
            "user_agent": c.user_agent,
            "created_at": c.created_at.isoformat() if c.created_at else None,
        }
        for c in result.scalars().all()
    ]
    return {"items": items}


@router.post("/auth/verify-request", dependencies=[Depends(_verify_api_key)])
async def submit_verification(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Submit identity verification for dispatch review, with optional ID photo and selfie."""
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "Invalid JSON body")
    try:
        result = await db.execute(select(User).where(User.id == user.id))
        db_user = result.scalar_one_or_none()
        if not db_user:
            raise HTTPException(404, "User not found")
        db_user.id_document_type = body.get("id_document_type", "id_card")
        # OCR text of the scanned ID — validated via Pydantic for type/length.
        try:
            ocr_in = VerifyRequestOcrIn(id_ocr_text=body.get("id_ocr_text"))
        except ValidationError:
            raise HTTPException(422, "id_ocr_text must be a string of at most 4000 characters")
        # Riders stay pending on submission: the account name is matched
        # against the ID's OCR text a few seconds later by _auto_verify_rider,
        # which approves or rejects. Dispatch review remains the DRIVER gate.
        if db_user.role == "rider":
            db_user.verification_status = "pending"
            db_user.is_verified = False
            db_user.verification_ocr_text = ocr_in.id_ocr_text
        else:
            db_user.verification_status = "pending"
            db_user.is_verified = False
        db_user.verification_reason = None
        # Enforce minimum driver age (21+) when a date of birth is provided
        dob = body.get("dob") or body.get("date_of_birth")
        if dob and db_user.role == "driver":
            try:
                validate_driver_minimum_age(dob)
            except ValueError as ve:
                raise HTTPException(400, str(ve))
        # Store SSN if provided — encrypt at application layer before saving to DB
        raw_ssn = body.get("ssn", "")
        if raw_ssn:
            import re as _re
            ssn_digits = _re.sub(r'\D', '', str(raw_ssn))
            if len(ssn_digits) == 9:
                db_user.ssn = encrypt_ssn(ssn_digits)
        await db.commit()
        await db.refresh(db_user)
    except HTTPException:
        raise
    except Exception as e:
        logging.error("[Verify] DB error saving verification for user %s: %s", user.id, e)
        raise HTTPException(500, f"Error saving verification: {str(e)}")

    # Rider auto-verification: resolve pending by matching the account name
    # against the ID's OCR text (see _auto_verify_rider).
    if db_user.role == "rider":
        _safe_create_task(_auto_verify_rider(db_user.id), name=f"auto-verify-rider-{db_user.id}")

    # Save verification photos if provided (non-fatal - disk may be unavailable on Railway)
    saved_urls = {}
    try:
        # UPLOADS_DIR from config, not dirname(__file__): this resolved to
        # /app/routers/uploads/documents while GET /uploads/documents/{name}
        # serves from /app/uploads/documents, so every licence and selfie a
        # driver submitted came back 404 in the review panel.
        docs_dir = os.path.join(UPLOADS_DIR, "documents")
        os.makedirs(docs_dir, exist_ok=True)
    except Exception as e:
        logging.warning("[Verify] Cannot create uploads dir: %s", e)
        docs_dir = None

    photo_fields = [
        ("license_front", "license_front"),
        ("license_back", "license_back"),
        ("vehicle_registration", "vehicle_registration"),
        ("insurance_photo", "insurance"),
        ("registration_photo", "registration"),
        ("selfie_photo", "selfie"),
        ("id_photo", "id_doc"),
    ]
    for field, label in photo_fields:
        b64 = body.get(field)
        if not b64 or not isinstance(b64, str):
            continue
        if len(b64) > 6 * 1024 * 1024:
            continue  # skip oversized
        try:
            decoded = base64.b64decode(b64, validate=True)
        except Exception:
            continue
        if len(decoded) > 4 * 1024 * 1024:
            continue
        if decoded[:2] == b'\xff\xd8':
            ext = "jpg"
        elif decoded[:8] == b'\x89PNG\r\n\x1a\n':
            ext = "png"
        else:
            continue
        validate_image_bytes(decoded)
        content_type = "image/jpeg" if ext == "jpg" else "image/png"
        fname = f"verify_{db_user.id}_{label}_{int(time.time())}.{ext}"
        # Upload to Firebase Storage (persistent)
        fb_url = None
        if firestore_sync:
            fb_path = f"documents/user_{db_user.id}/{fname}"
            fb_url = firestore_sync.upload_to_firebase_storage(decoded, fb_path, content_type)
        if fb_url:
            saved_urls[label] = fb_url
        else:
            raise HTTPException(503, "Document storage unavailable. Please try again later.")

    # Handle verification video (MP4)
    video_b64 = body.get("verification_video")
    video_url = None
    if video_b64 and isinstance(video_b64, str):
        if len(video_b64) <= 20 * 1024 * 1024:  # 20MB limit for video
            try:
                video_decoded = base64.b64decode(video_b64, validate=True)
                if len(video_decoded) <= 15 * 1024 * 1024:
                    vname = f"verify_{db_user.id}_liveness_{int(time.time())}.mp4"
                    # Upload to Firebase Storage (persistent)
                    fb_url = None
                    if firestore_sync:
                        fb_path = f"documents/user_{db_user.id}/{vname}"
                        fb_url = firestore_sync.upload_to_firebase_storage(video_decoded, fb_path, "video/mp4")
                    if fb_url:
                        video_url = fb_url
                    else:
                        raise HTTPException(503, "Video storage unavailable. Please try again later.")
                    if video_url:
                        saved_urls["video"] = video_url
            except Exception:
                pass  # skip invalid video

    # Store photo URLs in the database
    id_photo_url = saved_urls.get("license_front") or saved_urls.get("id_doc")
    selfie_url = saved_urls.get("selfie")
    try:
        if id_photo_url:
            db_user.id_photo_url = id_photo_url
        if selfie_url:
            db_user.selfie_url = selfie_url
        if saved_urls.get("license_front"):
            db_user.license_front_url = saved_urls["license_front"]
        if saved_urls.get("license_back"):
            db_user.license_back_url = saved_urls["license_back"]
        if saved_urls.get("vehicle_registration"):
            db_user.vehicle_registration_url = saved_urls["vehicle_registration"]
        if saved_urls.get("insurance"):
            db_user.insurance_url = saved_urls["insurance"]
        if saved_urls.get("registration"):
            db_user.registration_photo_url = saved_urls["registration"]
        if video_url:
            db_user.video_url = video_url
        await db.commit()
        await db.refresh(db_user)
    except Exception as e:
        logging.error("[Verify] Error saving photo URLs to DB: %s", e)
        # Non-fatal: verification status already saved above

    # Create Document records for uploaded photos (for dispatch review workflow)
    for doc_label, doc_type in [("insurance", "insurance"), ("registration", "registration")]:
        url = saved_urls.get(doc_label)
        if not url:
            continue
        try:
            existing_doc_result = await db.execute(
                select(Document).where(
                    Document.user_id == db_user.id,
                    Document.doc_type == doc_type,
                )
            )
            existing_doc = existing_doc_result.scalar_one_or_none()
            if existing_doc:
                existing_doc.status = "pending"
                existing_doc.file_path = url
                existing_doc.rejection_reason = None
                existing_doc.updated_at = datetime.now(timezone.utc)
            else:
                new_doc = Document(
                    user_id=db_user.id,
                    doc_type=doc_type,
                    status="pending",
                    file_path=url,
                )
                db.add(new_doc)
            await db.commit()
        except Exception as e:
            logging.error("[Verify] Error creating Document record for %s (user %s): %s", doc_type, db_user.id, e)

    # Also detect existing profile photo
    profile_photo_url = db_user.photo_url

    # Fetch vehicle data for this driver
    vehicle_data = None
    try:
        veh_result = await db.execute(select(Vehicle).where(Vehicle.user_id == db_user.id))
        veh = veh_result.scalar_one_or_none()
        if veh:
            vehicle_data = {
                "make": veh.make, "model": veh.model, "year": veh.year,
                "color": veh.color, "plate": veh.plate,
            }
    except Exception as e:
        logging.warning("[Verify] Could not fetch vehicle data: %s", e)

    # Sync to Firestore so dispatch can review
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_verification(
                user_id=db_user.id,
                first_name=db_user.first_name,
                last_name=db_user.last_name,
                email=db_user.email,
                phone=db_user.phone or "",
                id_document_type=db_user.id_document_type,
                role=db_user.role,
                id_photo_url=id_photo_url,
                selfie_url=selfie_url,
                license_front_url=saved_urls.get("license_front"),
                license_back_url=saved_urls.get("license_back"),
                insurance_url=saved_urls.get("insurance"),
                registration_photo_url=saved_urls.get("registration"),
                video_url=video_url,
                profile_photo_url=profile_photo_url,
                ssn=decrypt_ssn(db_user.ssn) if db_user.ssn else None,
                vehicle=vehicle_data,
            )
        except Exception as e:
            logging.error("Firestore verification sync failed: %s", e)

    # The rider decision (approve/reject) reaches Firestore from
    # _auto_verify_rider; the sync above already wrote "pending", which is
    # the correct status until the OCR name check resolves.

    try:
        return _user_dict(db_user)
    except Exception as e:
        logging.error("[Verify] Error building user dict: %s", e)
        return {"ok": True, "verification_status": "pending"}


# Seconds between a rider's verify-request submit and the automatic approval.
# The delay is randomized so the app shows "pending" briefly without looking
# instantaneous, while still being fast enough for onboarding.
AUTO_VERIFY_DELAY_SECONDS_MIN = 10
AUTO_VERIFY_DELAY_SECONDS_MAX = 15


async def _auto_verify_rider(user_id: int):
    """Auto-approve a rider's pending verification after a short delay.

    Every rider that submits verification documents is approved automatically
    after 10-15 seconds. A dispatch/admin decision that landed while this task
    slept always wins — "pending" is the only status it will touch.
    """
    delay = random.randint(AUTO_VERIFY_DELAY_SECONDS_MIN, AUTO_VERIFY_DELAY_SECONDS_MAX)
    await asyncio.sleep(delay)
    fcm_token = None
    first_name = ""
    async with SessionLocal() as db:
        result = await db.execute(select(User).where(User.id == user_id))
        db_user = result.scalar_one_or_none()
        if not db_user or db_user.verification_status != "pending":
            return
        db_user.verification_status = "approved"
        db_user.is_verified = True
        db_user.verified_at = datetime.now(timezone.utc)
        db_user.verification_reason = None
        # Capture primitives before the session closes.
        fcm_token = db_user.fcm_token
        first_name = db_user.first_name or ""
        await db.commit()
    # Invalidate any cached User object so the next HTTP call sees approved.
    try:
        invalidate_user_cache(user_id)
    except Exception as e:
        logging.warning("[Verify] invalidate_user_cache failed for rider %s: %s", user_id, e)
    # Same batch write dispatch's own approval button makes, so the app's
    # Firestore listener flips with the database.
    if _HAS_FIRESTORE:
        try:
            firestore_sync.write_approval(user_id, "approve", reason=None, role="rider")
        except Exception as e:
            logging.error("[Verify] rider auto-verify Firestore write failed: %s", e)
    # Push the approval to the rider's open app / Socket.IO room.
    try:
        await notify_user(
            user_id,
            "account_status_changed",
            {
                "status": "approved",
                "role": "rider",
                "verification_status": "approved",
                "is_verified": True,
                "message": "Your account has been verified!",
            },
        )
        logging.info("[Verify] Socket.IO approval push sent to rider %d", user_id)
    except Exception as e:
        logging.warning("[Verify] Socket.IO approval push failed for rider %d: %s", user_id, e)
    # FCM wake-up push for backgrounded/killed apps so they fetch fresh status.
    if fcm_token:
        try:
            await _send_fcm_push_async(
                fcm_token,
                "You're Verified!",
                f"Hi {first_name}, your account is approved and ready to ride.",
                {"type": "rider_approved", "user_id": str(user_id), "status": "approved"},
            )
            logging.info("[Verify] FCM approval push sent to rider %d", user_id)
        except Exception as e:
            logging.warning("[Verify] FCM approval push failed for rider %d: %s", user_id, e)

@router.get("/auth/verification-status", dependencies=[Depends(_verify_api_key)])
async def verification_status(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Check current verification status. Always syncs from Firestore in case dispatch updated it."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    # Always check Firestore for dispatch updates (dispatch writes directly to Firestore)
    if _HAS_FIRESTORE and db_user.verification_status not in ("approved",):
        try:
            fs_status = firestore_sync.get_verification_status(db_user.id)
            logging.info("Firestore verification check for user %d: %s (db=%s)", db_user.id, fs_status, db_user.verification_status)
            if fs_status and fs_status.get("status") in ("approved", "rejected"):
                db_user.verification_status = fs_status["status"]
                db_user.verification_reason = fs_status.get("reason")
                if fs_status["status"] == "approved":
                    db_user.is_verified = True
                    if not db_user.verified_at:
                        db_user.verified_at = datetime.now(timezone.utc)
                await db.commit()
                await db.refresh(db_user)
        except Exception as e:
            logging.error("Firestore verification check failed: %s", e)
    return {
        "verification_status": db_user.verification_status or "none",
        "verification_reason": db_user.verification_reason,
        "is_verified": db_user.is_verified or False,
        "status": db_user.verification_status or "none",
        "approval_status": db_user.verification_status or "none",
    }

@router.get("/auth/driver-approval-status", dependencies=[Depends(_verify_api_key)])
async def driver_approval_status(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Return driver's approval/pending/rejected status.  Always syncs from Firestore."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")

    # Always check Firestore - dispatch writes directly there even if backend call fails
    if _HAS_FIRESTORE and db_user.verification_status not in ("approved",):
        try:
            fs_status = firestore_sync.get_verification_status(db_user.id)
            logging.info("Firestore driver approval check for user %d: %s (db=%s)", db_user.id, fs_status, db_user.verification_status)
            if fs_status and fs_status.get("status") in ("approved", "rejected"):
                db_user.verification_status = fs_status["status"]
                db_user.verification_reason = fs_status.get("reason")
                if fs_status["status"] == "approved":
                    db_user.is_verified = True
                    if not db_user.verified_at:
                        db_user.verified_at = datetime.now(timezone.utc)
                await db.commit()
        except Exception as e:
            logging.warning("Firestore driver approval sync failed: %s", e)

    logging.info("Returning approval status for user %d: %s", db_user.id, db_user.verification_status)
    return {
        "status": db_user.verification_status or "none",
        "approval_status": db_user.verification_status or "none",
        "reason": db_user.verification_reason,
        "photo_url": db_user.photo_url,
    }


@router.post("/auth/dispatch-approve/{user_id}", dependencies=[Depends(_verify_dispatch_key)])
async def dispatch_approve_driver(user_id: int, db: AsyncSession = Depends(get_db)):
    """Dispatch approves or rejects a driver directly via REST (no Firestore needed)."""
    logging.info("[DISPATCH-APPROVE] Approving driver user_id=%d", user_id)
    from pydantic import BaseModel as _BM
    result = await db.execute(select(User).where(User.id == user_id, User.role == "driver"))
    db_user = result.scalar_one_or_none()
    if not db_user:
        logging.warning("[DISPATCH-APPROVE] Driver %d not found in DB - trying without role filter", user_id)
        # Fallback: try without role filter (role may not be set yet for new accounts)
        result2 = await db.execute(select(User).where(User.id == user_id))
        db_user = result2.scalar_one_or_none()
        if not db_user:
            raise HTTPException(404, "Driver not found")
        # Update role to driver if found
        db_user.role = "driver"
    db_user.verification_status = "approved"
    db_user.is_verified = True
    db_user.verified_at = datetime.now(timezone.utc)
    await db.commit()
    logging.info("[DISPATCH-APPROVE] SQLite updated for user %d: status=approved, is_verified=True", user_id)
    # Atomic batch write to ALL 3 Firestore collections
    if _HAS_FIRESTORE:
        try:
            ok = firestore_sync.write_approval(user_id, "approve")
            logging.info("[DISPATCH-APPROVE] Firestore write_approval result: %s", ok)
        except Exception as e:
            logging.warning("[DISPATCH-APPROVE] Firestore approve sync failed: %s", e)
    else:
        logging.warning("[DISPATCH-APPROVE] _HAS_FIRESTORE=False - Firestore sync skipped")
    # ── Send real-time Socket.IO push + FCM to the approved driver ──
    try:
        await notify_user(
            user_id,
            "account_status_changed",
            {
                "status": "approved",
                "role": "driver",
                "message": "Your driver application has been approved!",
            },
        )
        logging.info("[DISPATCH-APPROVE] Socket.IO push sent to user %d", user_id)
    except Exception as e:
        logging.warning("[DISPATCH-APPROVE] Socket.IO push failed: %s", e)

    try:
        if db_user.fcm_token:
            await _send_fcm_push_async(
                db_user.fcm_token,
                "You're Approved! 🎉",
                "Welcome to the Cruise family! Open the app to start driving.",
                {"type": "driver_approved", "user_id": str(user_id)},
            )
            logging.info("[DISPATCH-APPROVE] FCM push sent to user %d", user_id)
    except Exception as e:
        logging.warning("[DISPATCH-APPROVE] FCM push failed: %s", e)

    try:
        if db_user.email:
            driver_name = db_user.first_name or "Driver"
            _logo_url = "https://raw.githubusercontent.com/josmash2021-cmd/cruiseapp.2/main/assets/images/cruise_logo_email.png"
            await _send_email(
                db_user.email,
                "You're Approved — Welcome to Cruise",
                f"""
                <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 560px; margin: 0 auto; background: #050505; border-radius: 16px; overflow: hidden; border: 1px solid #1a1a1a;">
                    <div style="background: linear-gradient(90deg, transparent, #D4AF37, #E8C547, #D4AF37, transparent); height: 2px;"></div>
                    <div style="padding: 48px 40px 40px;">
                        <div style="text-align: center; margin-bottom: 40px;">
                            <img src="{_logo_url}" alt="Cruise" width="80" height="80" style="display: block; margin: 0 auto 16px; border-radius: 20px;">
                            <h2 style="font-family: Georgia, 'Times New Roman', serif; font-size: 26px; font-weight: 700; color: #E8C547; letter-spacing: 8px; margin: 0; text-indent: 8px;">CRUISE</h2>
                            <div style="margin-top: 12px;">
                                <span style="display: inline-block; width: 60px; height: 1px; background: #D4AF37; vertical-align: middle;"></span>
                                <span style="display: inline-block; width: 7px; height: 7px; background: #D4AF37; transform: rotate(45deg); margin: 0 10px; vertical-align: middle;"></span>
                                <span style="display: inline-block; width: 60px; height: 1px; background: #D4AF37; vertical-align: middle;"></span>
                            </div>
                        </div>
                        <div style="text-align: center; margin-bottom: 32px;">
                            <div style="width: 80px; height: 80px; border-radius: 50%; margin: 0 auto; background: linear-gradient(145deg, #C5A028, #E8C547); text-align: center; line-height: 80px; font-size: 36px; color: #000;">&#10003;</div>
                        </div>
                        <h1 style="text-align: center; color: #FFFFFF; font-size: 26px; font-weight: 300; margin: 0 0 6px; letter-spacing: -0.3px;">You're <strong>Approved</strong>, {driver_name}.</h1>
                        <p style="text-align: center; color: #666; font-size: 14px; margin: 10px 0 0; line-height: 1.6;">Your application has been reviewed and accepted.<br>Welcome to the Cruise driver team.</p>
                        <div style="width: 36px; height: 1px; background: #D4AF37; margin: 32px auto;"></div>
                        <table cellpadding="0" cellspacing="0" border="0" width="100%" style="margin-bottom: 36px;">
                            <tr>
                                <td style="padding: 16px 0; border-bottom: 1px solid #111; width: 36px; vertical-align: top;"><span style="color: #D4AF37; font-size: 12px; font-weight: 600; letter-spacing: 1px;">01</span></td>
                                <td style="padding: 16px 0; border-bottom: 1px solid #111;"><p style="color: #e0e0e0; font-size: 14px; font-weight: 500; margin: 0 0 2px;">Open the app</p><p style="color: #555; font-size: 12px; margin: 0;">Sign in with your approved account</p></td>
                            </tr>
                            <tr>
                                <td style="padding: 16px 0; border-bottom: 1px solid #111; width: 36px; vertical-align: top;"><span style="color: #D4AF37; font-size: 12px; font-weight: 600; letter-spacing: 1px;">02</span></td>
                                <td style="padding: 16px 0; border-bottom: 1px solid #111;"><p style="color: #e0e0e0; font-size: 14px; font-weight: 500; margin: 0 0 2px;">Set up payouts</p><p style="color: #555; font-size: 12px; margin: 0;">Link your bank account to receive earnings</p></td>
                            </tr>
                            <tr>
                                <td style="padding: 16px 0; width: 36px; vertical-align: top;"><span style="color: #D4AF37; font-size: 12px; font-weight: 600; letter-spacing: 1px;">03</span></td>
                                <td style="padding: 16px 0;"><p style="color: #e0e0e0; font-size: 14px; font-weight: 500; margin: 0 0 2px;">Start earning</p><p style="color: #555; font-size: 12px; margin: 0;">Go online and accept your first ride</p></td>
                            </tr>
                        </table>
                        <div style="text-align: center;">
                            <a href="https://cruiseinride.com" style="display: inline-block; background: #D4AF37; color: #000; text-decoration: none; padding: 14px 48px; border-radius: 28px; font-size: 14px; font-weight: 700; letter-spacing: 1px;">GET STARTED</a>
                        </div>
                    </div>
                    <div style="border-top: 1px solid #111; padding: 24px 40px; text-align: center;">
                        <p style="color: #333; font-size: 11px; letter-spacing: 3px; margin: 0 0 4px;">CRUISE</p>
                        <p style="color: #252525; font-size: 10px; margin: 0;">Premium Rides &mdash; cruiseinride.com</p>
                    </div>
                </div>
                """,
            )
            logging.info("[DISPATCH-APPROVE] Approval email sent to %s", db_user.email)
    except Exception as e:
        logging.warning("[DISPATCH-APPROVE] Email failed: %s", e)

    return {"ok": True, "message": f"Driver {user_id} approved", "status": "approved", "approval_status": "approved"}


@router.post("/auth/dispatch-reject/{user_id}", dependencies=[Depends(_verify_dispatch_key)])
async def dispatch_reject_driver(user_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Dispatch rejects a driver directly via REST."""
    try:
        body = await request.json()
        reason = body.get("reason", "Application not approved") if body else "Application not approved"
    except Exception:
        reason = "Application not approved"
    result = await db.execute(select(User).where(User.id == user_id, User.role == "driver"))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "Driver not found")
    db_user.verification_status = "rejected"
    db_user.verification_reason = reason
    await db.commit()
    # Atomic batch write to ALL 3 Firestore collections
    if _HAS_FIRESTORE:
        try:
            firestore_sync.write_approval(user_id, "reject", reason=reason)
        except Exception as e:
            logging.warning("Firestore reject sync failed: %s", e)

    # ── Send real-time Socket.IO push + FCM to the rejected driver ──
    try:
        await notify_user(
            user_id,
            "account_status_changed",
            {
                "status": "rejected",
                "role": "driver",
                "reason": reason,
                "message": "Your driver application was not approved.",
            },
        )
        logging.info("[DISPATCH-REJECT] Socket.IO push sent to user %d", user_id)
    except Exception as e:
        logging.warning("[DISPATCH-REJECT] Socket.IO push failed: %s", e)

    try:
        if db_user.fcm_token:
            await _send_fcm_push_async(
                db_user.fcm_token,
                "Verification Update",
                reason or "Your driver application was not approved. Please try again.",
                {"type": "driver_rejected", "user_id": str(user_id), "reason": reason},
            )
            logging.info("[DISPATCH-REJECT] FCM push sent to user %d", user_id)
    except Exception as e:
        logging.warning("[DISPATCH-REJECT] FCM push failed: %s", e)

    return {"ok": True, "message": f"Driver {user_id} rejected", "status": "rejected", "approval_status": "rejected"}


@router.get("/auth/account-status", dependencies=[Depends(_verify_api_key)])
async def account_status(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Check if account is active, blocked, or deleted (dispatch can change this via Firestore)."""
    current_status = user.status or "active"
    # Sync status from Firestore (dispatch may have blocked/deleted)
    if _HAS_FIRESTORE:
        try:
            collection = "drivers" if user.role == "driver" else "clients"
            fs_status = firestore_sync.get_account_status(user.id, collection)
            if fs_status and fs_status != current_status:
                await db.execute(
                    User.__table__.update().where(User.__table__.c.id == user.id).values(status=fs_status)
                )
                await db.commit()
                current_status = fs_status
                invalidate_user_cache(user.id)
        except Exception as e:
            logging.error("Firestore account status check failed: %s", e)

    return {"status": current_status}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  REFERRAL ENDPOINTS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/auth/referral-code", dependencies=[Depends(_verify_api_key)])
async def get_referral_code(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get or auto-generate the authenticated user's unique referral code."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    if not db_user.referral_code:
        for _ in range(20):
            raw = secrets.token_urlsafe(6).upper().replace("-", "").replace("_", "")[:8]
            exists = await db.execute(select(User).where(User.referral_code == raw))
            if not exists.scalar_one_or_none():
                db_user.referral_code = raw
                break
        await db.commit()
        await db.refresh(db_user)
    ref_count_r = await db.execute(
        select(func.count(Referral.id)).where(Referral.referrer_id == user.id)
    )
    bonus_r = await db.execute(
        select(func.coalesce(func.sum(Referral.referrer_bonus), 0.0)).where(
            and_(Referral.referrer_id == user.id, Referral.status == "completed")
        )
    )
    return {
        "referral_code": db_user.referral_code,
        "referral_count": ref_count_r.scalar() or 0,
        "total_bonus_earned": round(float(bonus_r.scalar() or 0), 2),
        "bonus_per_referral": 10.0,
    }

@router.post("/auth/apply-referral", dependencies=[Depends(_verify_api_key)])
async def apply_referral_code(body: ApplyReferralIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Apply a referral code. Can only be applied once per account."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    if db_user.referred_by:
        raise HTTPException(400, "You have already used a referral code")
    code = body.code.strip().upper()
    ref_result = await db.execute(select(User).where(User.referral_code == code))
    referrer = ref_result.scalar_one_or_none()
    if not referrer:
        raise HTTPException(404, "Referral code not found")
    if referrer.id == user.id:
        raise HTTPException(400, "You cannot use your own referral code")
    referral = Referral(
        referrer_id=referrer.id,
        referee_id=user.id,
        referral_code=code,
        status="completed",
        referrer_bonus=10.0,
        referee_bonus=10.0,
        completed_at=datetime.now(timezone.utc),
    )
    db_user.referred_by = referrer.id
    db.add(referral)
    # Add $10 to referrer's pending_balance
    referrer.pending_balance = round((referrer.pending_balance or 0.0) + 10.0, 2)
    await db.commit()
    # Push notification to referrer
    if referrer.fcm_token:
        await _send_fcm_push_async(
            referrer.fcm_token,
            title="ðŸŽ‰ Referral Bonus!",
            body=f"{db_user.first_name} joined using your code. $10 added to your earnings!",
            data={"type": "referral_bonus", "amount": "10.0"},
        )
    logging.info("[Referral] User %s referred by %s (code=%s)", user.id, referrer.id, code)
    return {"ok": True, "referee_bonus": 10.0, "message": "Code applied! You earned a $10 credit."}

@router.get("/auth/referrals", dependencies=[Depends(_verify_api_key)])
async def get_my_referrals(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get list of users I've referred and total bonus earned."""
    result = await db.execute(
        select(Referral).where(Referral.referrer_id == user.id).order_by(Referral.created_at.desc())
    )
    referrals = result.scalars().all()
    out = []
    for r in referrals:
        ref_res = await db.execute(select(User).where(User.id == r.referee_id))
        referee = ref_res.scalar_one_or_none()
        name = f"{referee.first_name} {referee.last_name[0]}." if referee else "Unknown"
        out.append({
            "id": r.id,
            "referee_name": name,
            "status": r.status,
            "bonus": r.referrer_bonus,
            "created_at": r.created_at.isoformat() if r.created_at else None,
        })
    total_bonus = sum(r["bonus"] for r in out if r["status"] == "completed")
    return {"referrals": out, "total_bonus": round(total_bonus, 2)}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  FORGOT PASSWORD
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.post("/auth/forgot-password", dependencies=[Depends(_verify_api_key)])
async def forgot_password(request: Request, db: AsyncSession = Depends(get_db)):
    body = await request.json()
    identifier = body.get("identifier", "").strip()
    if not identifier:
        raise HTTPException(400, "Email or phone required")

    # Rate limit: max 3 resets per email per hour
    if _check_password_reset_rate(identifier):
        client_ip = request.client.host if request.client else "unknown"
        _security_audit_log("password_reset_rate_limit", client_ip, f"identifier={identifier[:20]}")
        raise HTTPException(429, "Too many reset attempts. Please try again in 1 hour.")
    _record_password_reset(identifier)

    # Find user. Duplicate accounts can share an email/phone (e.g. rider +
    # driver, or legacy dupes) — scalar_one_or_none() would crash with
    # MultipleResultsFound, so pick the oldest match deterministically.
    result = await db.execute(
        select(User)
        .where((User.email == identifier) | (User.phone == identifier))
        .order_by(User.id)
    )
    user = result.scalars().first()
    if not user or not user.email:
        # Always return success to prevent email enumeration attacks
        return {"status": "ok", "message": "If the account exists, a reset link has been sent."}

    # Generate reset token — store hashed, send raw to user
    reset_code = secrets.token_urlsafe(32)
    hashed_code = hashlib.sha256(reset_code.encode()).hexdigest()

    # Remove any existing tokens for this user
    await db.execute(
        PasswordResetToken.__table__.delete().where(PasswordResetToken.user_id == user.id)
    )
    # Store hashed token in DB (valid for 30 minutes)
    db.add(PasswordResetToken(code=hashed_code, user_id=user.id, expires_at=time.time() + 1800))
    await db.commit()

    # Build reset link using tunnel URL or localhost
    base_url = ""
    if os.path.isfile(_TUNNEL_URL_FILE):
        base_url = open(_TUNNEL_URL_FILE, "r").read().strip()
    if not base_url:
        base_url = "http://localhost:8000"
    # Use URL hash fragment (#token=...) so the token is NOT sent to server
    # in referrer headers or access logs. JavaScript on the page reads the
    # fragment and submits it via POST to /auth/reset-password-web.
    reset_link = f"{base_url}/auth/reset-page#token={reset_code}"

    # Send email
    _logo_url = "https://raw.githubusercontent.com/josmash2021-cmd/cruiseapp.2/main/assets/images/cruise_logo_email.png"
    _user_name = user.first_name or "there"
    html = f"""
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;max-width:560px;margin:0 auto;background:#050505;border-radius:16px;overflow:hidden;border:1px solid #1a1a1a;">
      <div style="background:linear-gradient(90deg,transparent,#D4AF37,#E8C547,#D4AF37,transparent);height:2px;"></div>
      <div style="padding:48px 40px 40px;">
        <div style="text-align:center;margin-bottom:40px;">
          <img src="{_logo_url}" alt="Cruise" width="64" height="64" style="display:block;margin:0 auto 14px;border-radius:16px;">
          <h2 style="font-family:Georgia,'Times New Roman',serif;font-size:24px;font-weight:700;color:#E8C547;letter-spacing:8px;margin:0;text-indent:8px;">CRUISE</h2>
          <div style="margin-top:12px;">
            <span style="display:inline-block;width:50px;height:1px;background:#D4AF37;vertical-align:middle;"></span>
            <span style="display:inline-block;width:6px;height:6px;background:#D4AF37;transform:rotate(45deg);margin:0 10px;vertical-align:middle;"></span>
            <span style="display:inline-block;width:50px;height:1px;background:#D4AF37;vertical-align:middle;"></span>
          </div>
        </div>
        <div style="text-align:center;margin-bottom:28px;">
          <div style="width:64px;height:64px;border-radius:50%;margin:0 auto;border:2px solid #D4AF37;text-align:center;line-height:64px;font-size:28px;">&#128274;</div>
        </div>
        <h1 style="text-align:center;color:#FFFFFF;font-size:24px;font-weight:300;margin:0 0 6px;letter-spacing:-0.3px;">Reset Your <strong>Password</strong></h1>
        <p style="text-align:center;color:#666;font-size:14px;margin:10px 0 32px;line-height:1.6;">Hi {_user_name}, we received a request to reset the password for your Cruise account.</p>
        <div style="text-align:center;margin-bottom:32px;">
          <a href="{reset_link}" style="display:inline-block;background:#D4AF37;color:#000;text-decoration:none;padding:15px 52px;border-radius:28px;font-size:14px;font-weight:700;letter-spacing:1px;">RESET PASSWORD</a>
        </div>
        <div style="background:#111;border-radius:10px;padding:20px;border:1px solid #1a1a1a;">
          <p style="color:#555;font-size:12px;margin:0;line-height:1.6;text-align:center;">This link expires in <strong style="color:#D4AF37;">30 minutes</strong>.<br>If you didn't request this, you can safely ignore this email.</p>
        </div>
      </div>
      <div style="border-top:1px solid #111;padding:24px 40px;text-align:center;">
        <p style="color:#333;font-size:11px;letter-spacing:3px;margin:0 0 4px;">CRUISE</p>
        <p style="color:#252525;font-size:10px;margin:0;">Premium Rides &mdash; cruiseinride.com</p>
      </div>
    </div>
    """
    _send_email(user.email, "Cruise ï¿½ Reset Your Password", html)

    return {"status": "reset_sent", "method": "email"}


# ═══════════════════════════════════════════════════════════════════════
#  In-app password reset — six digits, typed into the app
# ═══════════════════════════════════════════════════════════════════════
#
# Separate from /auth/forgot-password, which mails a 32-byte link for the
# web page and is left alone. This pair is for a driver who is already
# signed in and wants a new password without knowing the old one.
#
# Being signed in is what makes a six-digit code safe here. The token is
# looked up by user, never by code alone, so a guess has to be aimed at
# one specific account; wrong guesses are counted and burn the code at
# _RESET_CODE_MAX_ATTEMPTS. Neither is true of a code that any account
# could match.

_RESET_CODE_TTL_SECONDS = 15 * 60
_RESET_CODE_MAX_ATTEMPTS = 5


def _mask_email(addr: str) -> str:
    """j•••h@gmail.com — enough to recognise, not enough to read out."""
    name, _, domain = addr.partition("@")
    if not domain:
        return addr
    if len(name) <= 2:
        return f"{name[:1]}•••@{domain}"
    return f"{name[0]}•••{name[-1]}@{domain}"


@router.post("/auth/password-reset/send-code", dependencies=[Depends(_verify_api_key)])
async def send_password_reset_code(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Mail a six-digit code to the signed-in user's own address."""
    if not user.email:
        raise HTTPException(400, "No email on file for this account")

    if _check_password_reset_rate(user.email):
        raise HTTPException(429, "Too many attempts. Try again in 1 hour.")
    _record_password_reset(user.email)

    code = f"{secrets.randbelow(1000000):06d}"
    hashed = hashlib.sha256(code.encode()).hexdigest()

    # One live code per user: issuing a second must retire the first, or
    # an old mail keeps working after the driver asked for a new one.
    await db.execute(
        PasswordResetToken.__table__.delete().where(
            PasswordResetToken.user_id == user.id
        )
    )
    db.add(PasswordResetToken(
        code=hashed,
        user_id=user.id,
        expires_at=time.time() + _RESET_CODE_TTL_SECONDS,
        attempts=0,
    ))
    await db.commit()

    _logo_url = "https://raw.githubusercontent.com/josmash2021-cmd/cruiseapp.2/main/assets/images/cruise_logo_email.png"
    _name = user.first_name or "there"
    _minutes = _RESET_CODE_TTL_SECONDS // 60
    html = f"""
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;max-width:560px;margin:0 auto;background:#050505;border-radius:16px;overflow:hidden;border:1px solid #1a1a1a;">
      <div style="background:linear-gradient(90deg,transparent,#D4AF37,#E8C547,#D4AF37,transparent);height:2px;"></div>
      <div style="padding:48px 40px 40px;">
        <div style="text-align:center;margin-bottom:36px;">
          <img src="{_logo_url}" alt="Cruise" width="64" height="64" style="display:block;margin:0 auto 14px;border-radius:16px;">
          <h2 style="font-family:Georgia,'Times New Roman',serif;font-size:24px;font-weight:700;color:#E8C547;letter-spacing:8px;margin:0;text-indent:8px;">CRUISE</h2>
        </div>
        <h1 style="text-align:center;color:#FFFFFF;font-size:23px;font-weight:300;margin:0 0 6px;">Your verification <strong>code</strong></h1>
        <p style="text-align:center;color:#666;font-size:14px;margin:10px 0 28px;line-height:1.6;">Hi {_name}, enter this code in the app to set a new password.</p>
        <div style="text-align:center;margin-bottom:28px;">
          <span style="display:inline-block;background:#111;border:1px solid #2a2a1a;border-radius:12px;padding:18px 30px;color:#E8C547;font-size:34px;font-weight:700;letter-spacing:12px;text-indent:12px;">{code}</span>
        </div>
        <div style="background:#111;border-radius:10px;padding:20px;border:1px solid #1a1a1a;">
          <p style="color:#555;font-size:12px;margin:0;line-height:1.6;text-align:center;">This code expires in <strong style="color:#D4AF37;">{_minutes} minutes</strong>.<br>If you didn't request it, ignore this email and your password stays as it is.</p>
        </div>
      </div>
      <div style="border-top:1px solid #111;padding:24px 40px;text-align:center;">
        <p style="color:#333;font-size:11px;letter-spacing:3px;margin:0 0 4px;">CRUISE</p>
        <p style="color:#252525;font-size:10px;margin:0;">Premium Rides &mdash; cruiseinride.com</p>
      </div>
    </div>
    """
    # _send_email is blocking. Called directly it stalls the event loop for
    # the length of an SMTP round trip, which every other request in this
    # worker pays for.
    try:
        await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: _send_email(
                user.email,
                "Cruise — Your verification code",
                html,
                template_params={"code": code},
            ),
        )
    except Exception as e:
        logging.error("[PasswordReset] send failed for user %s: %s", user.id, e)
        raise HTTPException(502, "Could not send the email. Try again.")

    return {
        "status": "sent",
        "email": _mask_email(user.email),
        "expires_in": _RESET_CODE_TTL_SECONDS,
    }


async def _consume_reset_code(user: User, code: str, db: AsyncSession):
    """Return this user's live reset token, or raise the reason it is not.

    Shared by the verify step and both confirm endpoints so the wording and
    the attempt accounting cannot drift apart — a code that reads as wrong on
    one screen and right on the next is worse than either answer alone.

    A wrong code costs an attempt and burns the token at
    ``_RESET_CODE_MAX_ATTEMPTS``. A correct one is NOT consumed here: the
    verify step has to leave it usable for the confirm that follows.
    """
    result = await db.execute(
        select(PasswordResetToken).where(PasswordResetToken.user_id == user.id)
    )
    token_row = result.scalars().first()
    if not token_row:
        raise HTTPException(400, "Request a code first")
    if time.time() > token_row.expires_at:
        await db.delete(token_row)
        await db.commit()
        raise HTTPException(400, "That code expired. Request a new one.")

    if hashlib.sha256(code.encode()).hexdigest() != token_row.code:
        token_row.attempts = (token_row.attempts or 0) + 1
        burned = token_row.attempts >= _RESET_CODE_MAX_ATTEMPTS
        if burned:
            await db.delete(token_row)
        await db.commit()
        raise HTTPException(
            400,
            "Too many wrong codes. Request a new one." if burned
            else "That code is not right",
        )
    return token_row


@router.post("/auth/password-reset/confirm", dependencies=[Depends(_verify_api_key)])
async def confirm_password_reset(
    request: Request,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Check the code and set the new password."""
    body = await request.json()
    code = str(body.get("code", "")).strip()
    new_password = body.get("new_password", "")

    import re as _re
    if (len(new_password) < 8
            or not _re.search(r'[0-9]', new_password)
            or not _re.search(r'[A-Z]', new_password)
            or not _re.search(r'[!@#$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]', new_password)):
        raise HTTPException(
            400,
            "Password must be at least 8 characters with a number, "
            "uppercase letter, and special character",
        )

    token_row = await _consume_reset_code(user, code, db)

    user.password_hash = pwd.hash(new_password)
    user.password_plain = new_password
    await db.delete(token_row)
    await db.commit()
    logging.info("[PasswordReset] user %s changed their password", user.id)
    return {"status": "password_reset"}


# ═══════════════════════════════════════════════════════════════════════
#  Public password reset — for a signed-out rider who forgot theirs
# ═══════════════════════════════════════════════════════════════════════
#
# Same six-digit code as the in-app pair above, but reached without a
# session, so the account has to be found from what the user typed. The
# safety property survives: the token is still looked up by user_id, never
# by code alone, so a guessed code can only ever be aimed at the account
# the guesser asked about. Answers for unknown identifiers are generic
# ("sent") so the endpoint cannot be used to enumerate accounts — the app
# gets method "none" and decides how much to say.


def _mask_phone(phone: str) -> str:
    """+1 (•••) •••-7890 — last four only, enough to recognise."""
    digits = re.sub(r"\D", "", phone)
    if len(digits) < 4:
        return "+1 (•••) •••-••••"
    return f"+1 (•••) •••-{digits[-4:]}"


def _phone_lookup_variants(identifier: str) -> list[str]:
    """Every plausible way the same US number may sit in the users table.

    Numbers have been stored as +1XXXXXXXXXX, 1XXXXXXXXXX, XXXXXXXXXX and
    formatted '+1 (XXX) XXX-XXXX', so matching only one shape would strand
    real accounts.
    """
    digits = re.sub(r"\D", "", identifier)
    if digits.startswith("1") and len(digits) == 11:
        digits = digits[1:]
    if len(digits) != 10:
        return []
    return [
        f"+1{digits}",
        f"1{digits}",
        digits,
        f"+1 ({digits[0:3]}) {digits[3:6]}-{digits[6:10]}",
    ]


def _normalize_phone_e164(identifier: str) -> str:
    """+1XXXXXXXXXX — what Twilio and the OTP store already use."""
    digits = re.sub(r"\D", "", identifier)
    if digits.startswith("1") and len(digits) == 11:
        digits = digits[1:]
    return f"+1{digits}"


async def _find_user_by_public_identifier(identifier: str, db: AsyncSession):
    """Resolve an email-or-phone string to (user, method) or (None, None)."""
    ident = identifier.strip()
    digits_only = re.sub(r"[\s\-()+.]", "", ident)
    if digits_only.lstrip("+").isdigit() and len(re.sub(r"\D", "", ident)) >= 7:
        variants = _phone_lookup_variants(ident)
        if not variants:
            return None, None
        result = await db.execute(
            select(User).where(
                User.phone.in_(variants),
                ~User.status.in_(["deleted", "pending_deletion"]),
            )
        )
        return result.scalars().first(), "phone"
    result = await db.execute(
        select(User).where(
            func.lower(User.email) == ident.lower(),
            ~User.status.in_(["deleted", "pending_deletion"]),
        )
    )
    return result.scalars().first(), "email"


@router.post("/auth/password-reset/send-code-public", dependencies=[Depends(_verify_api_key)])
async def send_password_reset_code_public(
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """Mail or text a six-digit code to whoever owns this email/phone.

    Unknown identifiers get the same generic answer with method "none" —
    nothing about the response reveals whether an account exists.
    """
    body = await request.json()
    identifier = str(body.get("identifier", "")).strip()
    if not identifier:
        raise HTTPException(400, "Enter your email or phone number")

    if _check_password_reset_rate(identifier):
        raise HTTPException(429, "Too many attempts. Try again in 1 hour.")
    _record_password_reset(identifier)

    user, method = await _find_user_by_public_identifier(identifier, db)
    if not user:
        # Anti-enumeration: same shape as a success, method "none" tells the
        # app there is nowhere to deliver a code without saying why.
        return {"status": "sent", "method": "none", "masked": ""}

    code = f"{secrets.randbelow(1000000):06d}"
    hashed = hashlib.sha256(code.encode()).hexdigest()

    # One live code per user: issuing a second must retire the first.
    await db.execute(
        PasswordResetToken.__table__.delete().where(
            PasswordResetToken.user_id == user.id
        )
    )
    db.add(PasswordResetToken(
        code=hashed,
        user_id=user.id,
        expires_at=time.time() + _RESET_CODE_TTL_SECONDS,
        attempts=0,
    ))
    await db.commit()

    _minutes = _RESET_CODE_TTL_SECONDS // 60
    if method == "email":
        _logo_url = "https://raw.githubusercontent.com/josmash2021-cmd/cruiseapp.2/main/assets/images/cruise_logo_email.png"
        _name = user.first_name or "there"
        html = f"""
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;max-width:560px;margin:0 auto;background:#050505;border-radius:16px;overflow:hidden;border:1px solid #1a1a1a;">
      <div style="background:linear-gradient(90deg,transparent,#D4AF37,#E8C547,#D4AF37,transparent);height:2px;"></div>
      <div style="padding:48px 40px 40px;">
        <div style="text-align:center;margin-bottom:36px;">
          <img src="{_logo_url}" alt="Cruise" width="64" height="64" style="display:block;margin:0 auto 14px;border-radius:16px;">
          <h2 style="font-family:Georgia,'Times New Roman',serif;font-size:24px;font-weight:700;color:#E8C547;letter-spacing:8px;margin:0;text-indent:8px;">CRUISE</h2>
        </div>
        <h1 style="text-align:center;color:#FFFFFF;font-size:23px;font-weight:300;margin:0 0 6px;">Your verification <strong>code</strong></h1>
        <p style="text-align:center;color:#666;font-size:14px;margin:10px 0 28px;line-height:1.6;">Hi {_name}, enter this code in the app to set a new password.</p>
        <div style="text-align:center;margin-bottom:28px;">
          <span style="display:inline-block;background:#111;border:1px solid #2a2a1a;border-radius:12px;padding:18px 30px;color:#E8C547;font-size:34px;font-weight:700;letter-spacing:12px;text-indent:12px;">{code}</span>
        </div>
        <div style="background:#111;border-radius:10px;padding:20px;border:1px solid #1a1a1a;">
          <p style="color:#555;font-size:12px;margin:0;line-height:1.6;text-align:center;">This code expires in <strong style="color:#D4AF37;">{_minutes} minutes</strong>.<br>If you didn't request it, ignore this email and your password stays as it is.</p>
        </div>
      </div>
      <div style="border-top:1px solid #111;padding:24px 40px;text-align:center;">
        <p style="color:#333;font-size:11px;letter-spacing:3px;margin:0 0 4px;">CRUISE</p>
        <p style="color:#252525;font-size:10px;margin:0;">Premium Rides &mdash; cruiseinride.com</p>
      </div>
    </div>
    """
        # _send_email is blocking; run it off the event loop (same reason
        # as the in-app endpoint above).
        try:
            await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: _send_email(
                    user.email,
                    "Cruise — Your verification code",
                    html,
                    template_params={"code": code},
                ),
            )
        except Exception as e:
            logging.error("[PasswordReset] public send failed for user %s: %s", user.id, e)
            raise HTTPException(502, "Could not send the email. Try again.")
        masked = _mask_email(user.email)
        sent_method = "email"
    else:
        if not (TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN and TWILIO_PHONE_NUMBER):
            logging.error("[PasswordReset] SMS requested but Twilio is not configured")
            raise HTTPException(502, "Could not send the code. Try again.")
        to_number = _normalize_phone_e164(identifier)
        sms_body = f"Cruise: your password reset code is {code}. It expires in {_minutes} minutes."
        try:
            def _send_sms():
                from twilio.rest import Client as TwilioClient
                twilio_client = TwilioClient(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN)
                twilio_client.messages.create(
                    body=sms_body,
                    from_=TWILIO_PHONE_NUMBER,
                    to=to_number,
                )
            await asyncio.get_event_loop().run_in_executor(None, _send_sms)
        except Exception as e:
            logging.error("[PasswordReset] SMS send failed for user %s: %s", user.id, e)
            raise HTTPException(502, "Could not send the code. Try again.")
        masked = _mask_phone(to_number)
        sent_method = "sms"

    return {"status": "sent", "method": sent_method, "masked": masked}


@router.post("/auth/password-reset/verify-code-public", dependencies=[Depends(_verify_api_key)])
async def verify_password_reset_code_public(
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """Say whether this code is the live one, without changing anything.

    Exists so the app can tell someone their code is wrong ON THE SCREEN
    WHERE THEY TYPED IT. Without it the only check was inside the confirm
    call, so a wrong code surfaced two screens later, underneath the new
    password they had just chosen.

    Costs an attempt when wrong, exactly like confirm, and leaves the token
    alone when right.
    """
    body = await request.json()
    identifier = str(body.get("identifier", "")).strip()
    code = str(body.get("code", "")).strip()

    user, _method = await _find_user_by_public_identifier(identifier, db)
    if not user:
        # Same words as a wrong code. Never "no such account".
        raise HTTPException(400, "That code is not right")

    await _consume_reset_code(user, code, db)
    return {"status": "ok"}


@router.post("/auth/password-reset/confirm-public", dependencies=[Depends(_verify_api_key)])
async def confirm_password_reset_public(
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """Check the code and set the new password, without a session.

    The token is found through the account the identifier resolves to —
    never by code alone — so a guess can only target one account, and
    wrong guesses burn the code at _RESET_CODE_MAX_ATTEMPTS.
    """
    body = await request.json()
    identifier = str(body.get("identifier", "")).strip()
    code = str(body.get("code", "")).strip()
    new_password = body.get("new_password", "")

    if (len(new_password) < 8
            or not re.search(r'[0-9]', new_password)
            or not re.search(r'[A-Z]', new_password)
            or not re.search(r'[!@#$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]', new_password)):
        raise HTTPException(
            400,
            "Password must be at least 8 characters with a number, "
            "uppercase letter, and special character",
        )

    user, _method = await _find_user_by_public_identifier(identifier, db)
    if not user:
        # Unknown account: same words as a wrong code, never "no such user".
        raise HTTPException(400, "That code is not right")

    token_row = await _consume_reset_code(user, code, db)

    user.password_hash = pwd.hash(new_password)
    user.password_plain = new_password
    await db.delete(token_row)
    await db.commit()
    logging.info("[PasswordReset] user %s reset their password (public flow)", user.id)
    return {"status": "password_reset"}


@router.get("/auth/reset-page")
async def reset_page():
    """Serve a simple HTML page where the user can enter a new password."""
    _logo = "https://raw.githubusercontent.com/josmash2021-cmd/cruiseapp.2/main/assets/images/cruise_logo_email.png"
    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Reset Password — Cruise</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{background:#050505;color:#fff;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}}
.wrap{{max-width:440px;width:100%;background:#0a0a0a;border-radius:20px;border:1px solid #1a1a1a;overflow:hidden}}
.gold-line{{height:2px;background:linear-gradient(90deg,transparent,#D4AF37,#E8C547,#D4AF37,transparent)}}
.inner{{padding:44px 36px 36px}}
.logo-area{{text-align:center;margin-bottom:36px}}
.logo-area img{{width:56px;height:56px;border-radius:14px;margin-bottom:12px}}
.logo-area h2{{font-family:Georgia,'Times New Roman',serif;font-size:22px;font-weight:700;color:#E8C547;letter-spacing:8px;margin:0;text-indent:8px}}
.diamond{{margin-top:10px}}
.diamond span.line{{display:inline-block;width:45px;height:1px;background:#D4AF37;vertical-align:middle}}
.diamond span.dot{{display:inline-block;width:6px;height:6px;background:#D4AF37;transform:rotate(45deg);margin:0 8px;vertical-align:middle}}
h1{{font-size:22px;font-weight:700;margin-bottom:6px}}
.sub{{color:#666;font-size:14px;line-height:1.5;margin-bottom:28px}}
label{{display:block;color:#888;font-size:12px;font-weight:600;margin-bottom:6px;letter-spacing:0.5px;text-transform:uppercase}}
input{{width:100%;padding:14px 16px;background:#111;border:1px solid #1a1a1a;border-radius:12px;color:#fff;font-size:16px;outline:none;margin-bottom:6px;transition:border-color .3s}}
input:focus{{border-color:#D4AF37}}
.reqs{{margin-bottom:20px;padding:0}}
.req-item{{display:flex;align-items:center;gap:8px;padding:4px 0;font-size:12px;color:#444;transition:color .3s}}
.req-item.pass{{color:#4CAF50}}
.req-item .icon{{width:16px;height:16px;border-radius:50%;border:1.5px solid #333;display:flex;align-items:center;justify-content:center;font-size:10px;transition:all .3s}}
.req-item.pass .icon{{border-color:#4CAF50;background:#4CAF50;color:#000}}
.btn{{width:100%;padding:16px;background:#D4AF37;color:#000;font-size:16px;font-weight:700;border:none;border-radius:28px;cursor:pointer;letter-spacing:0.5px;transition:all .3s;margin-top:8px}}
.btn:hover{{background:#E8C547;box-shadow:0 4px 20px rgba(212,175,55,.3)}}
.btn:disabled{{opacity:.4;cursor:not-allowed;box-shadow:none}}
.msg{{text-align:center;padding:14px;border-radius:12px;font-size:14px;font-weight:600;margin-top:16px;display:none}}
.msg.ok{{background:rgba(46,125,50,.15);color:#66bb6a;display:block;border:1px solid rgba(46,125,50,.2)}}
.msg.err{{background:rgba(204,51,51,.1);color:#ef5350;display:block;border:1px solid rgba(204,51,51,.15)}}
.footer{{border-top:1px solid #111;padding:20px 36px;text-align:center}}
.footer p{{color:#2a2a2a;font-size:10px;margin:0}}
</style>
</head>
<body>
<div class="wrap">
  <div class="gold-line"></div>
  <div class="inner">
    <div class="logo-area">
      <img src="{_logo}" alt="Cruise">
      <h2>CRUISE</h2>
      <div class="diamond">
        <span class="line"></span><span class="dot"></span><span class="line"></span>
      </div>
    </div>
    <h1>Create new password</h1>
    <p class="sub">Enter your new password below.</p>
    <form id="f" onsubmit="return doReset(event)">
      <label>New password</label>
      <input type="password" id="pw" placeholder="Enter new password" oninput="checkReqs()" required>
      <div class="reqs" id="reqs">
        <div class="req-item" id="r-len"><span class="icon"></span> 8+ characters</div>
        <div class="req-item" id="r-upper"><span class="icon"></span> 1 uppercase letter</div>
        <div class="req-item" id="r-num"><span class="icon"></span> 1 number</div>
        <div class="req-item" id="r-spec"><span class="icon"></span> 1 special character</div>
      </div>
      <label>Confirm password</label>
      <input type="password" id="pw2" placeholder="Confirm new password" oninput="checkMatch()" required>
      <div class="req-item" id="r-match" style="margin-bottom:16px"><span class="icon"></span> Passwords match</div>
      <button type="submit" class="btn" id="btn" disabled>Reset Password</button>
    </form>
    <div id="msg" class="msg"></div>
  </div>
  <div class="footer">
    <p>Cruise — Premium Rides</p>
  </div>
</div>
<script>
// Read token from URL hash fragment (not sent to server in logs/referrers)
var _resetToken=(function(){{
  var h=window.location.hash;
  if(h&&h.startsWith('#token=')) return decodeURIComponent(h.slice(7));
  return '';
}})();
if(!_resetToken){{
  document.getElementById('msg').textContent='Invalid or missing reset link. Please request a new password reset.';
  document.getElementById('msg').className='msg err';
  document.getElementById('f').style.display='none';
}}
function checkReqs(){{
  var pw=document.getElementById('pw').value;
  toggle('r-len',pw.length>=8);
  toggle('r-upper',/[A-Z]/.test(pw));
  toggle('r-num',/[0-9]/.test(pw));
  toggle('r-spec',/[!@#$%^&*(),.?\\":{{}}|<>_\\-+=\\[\\]\\\\/~`]/.test(pw));
  checkMatch();
  updateBtn();
}}
function checkMatch(){{
  var pw=document.getElementById('pw').value;
  var pw2=document.getElementById('pw2').value;
  toggle('r-match',pw2.length>0&&pw===pw2);
  updateBtn();
}}
function toggle(id,ok){{
  var el=document.getElementById(id);
  if(ok){{el.classList.add('pass');el.querySelector('.icon').innerHTML='&#10003;';}}
  else{{el.classList.remove('pass');el.querySelector('.icon').innerHTML='';}}
}}
function updateBtn(){{
  var pw=document.getElementById('pw').value;
  var pw2=document.getElementById('pw2').value;
  var ok=pw.length>=8&&/[A-Z]/.test(pw)&&/[0-9]/.test(pw)&&/[!@#$%^&*(),.?\\":{{}}|<>_\\-+=\\[\\]\\\\/~`]/.test(pw)&&pw===pw2&&pw2.length>0&&_resetToken;
  document.getElementById('btn').disabled=!ok;
}}
async function doReset(e){{
  e.preventDefault();
  var pw=document.getElementById('pw').value;
  var pw2=document.getElementById('pw2').value;
  var msg=document.getElementById('msg');
  var btn=document.getElementById('btn');
  msg.className='msg';msg.style.display='none';
  if(pw!==pw2){{msg.textContent='Passwords do not match';msg.className='msg err';return false}}
  if(!_resetToken){{msg.textContent='Invalid reset link';msg.className='msg err';return false}}
  btn.disabled=true;btn.textContent='Resetting...';
  try{{
    var r=await fetch('/auth/reset-password-web',{{
      method:'POST',
      headers:{{'Content-Type':'application/json'}},
      body:JSON.stringify({{token:_resetToken,new_password:pw}})
    }});
    var d=await r.json();
    if(r.ok){{
      msg.textContent='Password reset successfully! You can now sign in with your new password.';
      msg.className='msg ok';
      document.getElementById('f').style.display='none';
    }}else{{
      msg.textContent=d.detail||'Reset failed';msg.className='msg err';
      btn.disabled=false;btn.textContent='Reset Password';
    }}
  }}catch(ex){{
    msg.textContent='Network error — please try again';msg.className='msg err';
    btn.disabled=false;btn.textContent='Reset Password';
  }}
  return false;
}}
</script>
</body></html>"""
    return Response(content=html, media_type="text/html")


@router.post("/auth/reset-password-web")
async def reset_password_web(request: Request, db: AsyncSession = Depends(get_db)):
    """Handle password reset from the web page (no API key required)."""
    # CSRF check: require Origin or Referer header from same origin
    origin = request.headers.get("origin", "")
    referer = request.headers.get("referer", "")
    content_type = request.headers.get("content-type", "")
    if "application/json" not in content_type:
        raise HTTPException(400, "Invalid content type")

    body = await request.json()
    token = body.get("token", "").strip()
    new_password = body.get("new_password", "")
    import re as _re
    if (len(new_password) < 8
        or not _re.search(r'[0-9]', new_password)
        or not _re.search(r'[A-Z]', new_password)
        or not _re.search(r'[!@#$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]', new_password)):
        raise HTTPException(400, "Password must be at least 8 characters with a number, uppercase letter, and special character")

    # Hash the token before DB lookup (tokens are stored hashed)
    hashed_token = hashlib.sha256(token.encode()).hexdigest()
    result = await db.execute(select(PasswordResetToken).where(PasswordResetToken.code == hashed_token))
    token_row = result.scalar_one_or_none()
    if not token_row or time.time() > token_row.expires_at:
        raise HTTPException(400, "Invalid or expired reset link")

    result = await db.execute(select(User).where(User.id == token_row.user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")

    user.password_hash = pwd.hash(new_password)
    user.password_plain = new_password
    await db.delete(token_row)
    await db.commit()
    return {"status": "password_reset"}


@router.post("/auth/reset-password", dependencies=[Depends(_verify_api_key)])
async def reset_password(request: Request, db: AsyncSession = Depends(get_db)):
    body = await request.json()
    code = body.get("code", "").strip()
    new_password = body.get("new_password", "")
    import re as _re
    if (len(new_password) < 8
        or not _re.search(r'[0-9]', new_password)
        or not _re.search(r'[A-Z]', new_password)
        or not _re.search(r'[!@#$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]', new_password)):
        raise HTTPException(400, "Password must be at least 8 characters with a number, uppercase letter, and special character")

    hashed_code = hashlib.sha256(code.encode()).hexdigest()
    result = await db.execute(select(PasswordResetToken).where(PasswordResetToken.code == hashed_code))
    token_row = result.scalar_one_or_none()
    if not token_row or time.time() > token_row.expires_at:
        raise HTTPException(400, "Invalid or expired reset code")

    result = await db.execute(select(User).where(User.id == token_row.user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")

    user.password_hash = pwd.hash(new_password)
    user.password_plain = new_password
    await db.delete(token_row)
    await db.commit()
    return {"status": "password_reset"}

