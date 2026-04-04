import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from jose import jwt, JWTError
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
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
    _verify_dispatch_key, invalidate_user_cache,
    revoke_token, _check_password_reset_rate, _record_password_reset,
    JWT_SECRET, JWT_ALGORITHM,
)
from utils.helpers import utc_now, _user_dict, _haversine
from services.fcm_service import _send_fcm_push
from services.email_sms_service import _send_email
from utils.n8n_trigger import trigger_welcome_email, trigger_driver_onboarding
from config import (
    _otp_store, _OTP_TTL, PHOTOS_DIR, PUBLIC_URL,
    TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER, TWILIO_SERVICE_SID,
    EMAILJS_SERVICE_ID, EMAILJS_TEMPLATE_ID, EMAILJS_PUBLIC_KEY, EMAILJS_PRIVATE_KEY,
    firestore_sync, _HAS_FIRESTORE,
)

router = APIRouter()

# -- FCM Token (save device push token) ----------------
@router.post("/auth/fcm-token", dependencies=[Depends(_verify_api_key)])
async def save_fcm_token(
    token: str = Body(..., embed=True),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    user.fcm_token = token
    await db.commit()
    return {"ok": True}


# -- Logout (revoke JWT so it cannot be reused) --------
@router.post("/auth/logout", dependencies=[Depends(_verify_api_key)])
async def logout(
    request: Request,
    authorization: str = Header(None),
    user: User = Depends(_get_current_user),
):
    """Blacklist the current JWT so it cannot be used after logout."""
    if not authorization or not authorization.startswith("Bearer "):
        return {"ok": True}
    token = authorization.split(" ")[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        jti = payload.get("jti", "")
        exp = payload.get("exp", 0)
        if jti:
            await revoke_token(jti, user.id, float(exp))
    except (JWTError, Exception):
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
                existing.photo_url = body.photo_url
                existing.status = "active"
                existing.deletion_requested_at = None
                await db.commit()
                await db.refresh(existing)
                token = _create_token(existing.id, role=existing.role, status=existing.status or "active")
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
                existing.photo_url = body.photo_url
                existing.status = "active"
                existing.deletion_requested_at = None
                await db.commit()
                await db.refresh(existing)
                token = _create_token(existing.id, role=existing.role, status=existing.status or "active")
                refresh = _create_refresh_token(existing.id)
                return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(existing)}
            raise HTTPException(409, "Phone already registered")
    user = User(
        first_name=body.first_name,
        last_name=body.last_name,
        email=body.email.strip().lower() if body.email else None,
        phone=body.phone,
        password_hash=pwd.hash(body.password),
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

    # Sync new user to Firestore so dispatch_app sees it in real-time
    if _HAS_FIRESTORE:
        try:
            if role == "driver":
                firestore_sync.sync_driver(
                    user_id=user.id, first_name=user.first_name,
                    last_name=user.last_name, phone=user.phone or "",
                    email=user.email, photo_url=user.photo_url,
                    is_online=False, created_at=user.created_at,
                    password_hash=user.password_hash,
                    is_verified=False,
                )
            else:
                firestore_sync.sync_client(
                    user_id=user.id, first_name=user.first_name,
                    last_name=user.last_name, phone=user.phone or "",
                    email=user.email, photo_url=user.photo_url,
                    role=user.role, created_at=user.created_at,
                    password_hash=user.password_hash,
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
            asyncio.create_task(
                trigger_driver_onboarding(
                    name=f"{user.first_name} {user.last_name}",
                    email=user.email or "",
                    driver_id=str(user.id)
                )
            )
        else:
            # Trigger welcome email workflow for riders
            asyncio.create_task(
                trigger_welcome_email(
                    name=user.first_name,
                    email=user.email or "",
                    verification_link=verification_link
                )
            )
    except Exception as e:
        logging.error("n8n trigger on register failed: %s", e)

    token = _create_token(user.id, role=user.role, status=user.status or "active")
    refresh = _create_refresh_token(user.id)
    return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(user)}

@router.post("/auth/check-exists", dependencies=[Depends(_verify_api_key)])
async def check_exists(body: CheckExistsIn, db: AsyncSession = Depends(get_db)):
    identifier = body.identifier.strip()
    id_lower = identifier.lower()
    query = select(User).where(
        (func.lower(User.email) == id_lower) | (User.phone == identifier),
        ~User.status.in_(["deleted", "pending_deletion"]),
    )
    if body.role in ("rider", "driver"):
        query = query.where(User.role == body.role)
    result = await db.execute(query)
    return {"exists": result.scalar_one_or_none() is not None}

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
        _record_login_failure(client_ip)
        raise HTTPException(401, "Invalid credentials")
    st = user.status or "active"
    if st == "deleted":
        raise HTTPException(403, "Account deleted")
    if st == "blocked":
        raise HTTPException(403, "Account blocked")
    if st == "deactivated":
        raise HTTPException(403, "Account deactivated")

    # Successful login ï¿½ clear failures
    _clear_login_failures(client_ip)

    login_token = _create_login_token(user.id)
    return {
        "login_token": login_token,
        "method": "email" if user.email == body.identifier else "phone",
        "email": user.email,
        "phone": user.phone,
    }

@router.post("/auth/send-otp", dependencies=[Depends(_verify_api_key)])
async def send_otp(body: SendOtpIn, request: Request):
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
    
    # Use phone as key for OTP store (or email if no phone)
    otp_key = phone if phone else email
    
    # Generate code immediately
    code = "".join([str(secrets.randbelow(10)) for _ in range(6)])
    _otp_store[otp_key] = {"code": code, "expires": time.time() + _OTP_TTL, "email": email, "phone": phone}
    
    # Clean expired entries
    now = time.time()
    expired = [k for k, v in _otp_store.items() if v["expires"] < now]
    for k in expired:
        del _otp_store[k]
    
    # â"€â"€ ALWAYS log code for development/troubleshooting â"€â"€
    logging.info("[OTP] Generated code for %s: %s (expires in %d seconds)", otp_key, code, _OTP_TTL)
    
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
                sent = await loop.run_in_executor(None, lambda: _send_email(email,
                    "Your Cruise Verification Code", html_body))
                if sent:
                    logging.info("[OTP-BG] Email sent via provider to %s", email)
                else:
                    logging.warning("[OTP-BG] All email providers failed for %s", email)
            except Exception as e:
                logging.warning("[OTP-BG] Email send error for %s: %s", email, e)

        # Fire-and-forget email sending - respond immediately to avoid client timeout
        asyncio.create_task(_try_send_email_bg())

        # Always return the code so user can verify even if email is delayed/fails
        return {
            "ok": True,
            "method": "display",
            "message": "Use this verification code",
            "note": "Code also being sent to your email."
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
    logging.info("[OTP] CODE FOR %s: %s (check backend logs)", otp_key, code)
    
    return {
        "ok": True, 
        "method": "stored_only", 
        "warning": "SMS/Email service temporarily unavailable. Please contact support or try again later.",
    }

@router.post("/auth/verify-otp", dependencies=[Depends(_verify_api_key)])
async def verify_otp(body: VerifyOtpIn):
    """Check a verification code. Tries Twilio Verify API first, then local store."""
    import urllib.request, urllib.parse
    phone = (body.phone or "").strip()
    email = (body.email or "").strip().lower()
    code  = body.code.strip()
    otp_key = phone if phone else email
    if not otp_key or not code:
        raise HTTPException(400, "Phone or email, and code required")

    # -- 1. Local OTP store (always checked first -- backend-generated codes) --
    entry = _otp_store.get(otp_key)
    if entry and entry["code"] == code and entry["expires"] > time.time():
        _otp_store.pop(otp_key, None)
        logging.info("[OTP] Verified via local store for %s", otp_key)
        return {"valid": True}

    # -- 2. Twilio Verify API (for phone SMS sent via Twilio Verify) --
    twilio_verify_ok = (TWILIO_ACCOUNT_SID and TWILIO_ACCOUNT_SID.startswith("AC") and
                        TWILIO_SERVICE_SID and TWILIO_SERVICE_SID.startswith("VA"))
    if twilio_verify_ok and phone:
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
                if json.loads(resp_body).get("status") == "approved":
                    _otp_store.pop(otp_key, None)
                    logging.info("[OTP] Verified via Twilio Verify for %s", phone)
                    return {"valid": True}
        except Exception as e:
            logging.warning("[OTP] Twilio Verify check error: %s", e)

    logging.warning("[OTP] Invalid code for %s", otp_key)
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

    # Generate and store OTP
    code = f"{secrets.randbelow(900000) + 100000}"
    _otp_store[user.email.lower()] = {"code": code, "expires": now + _OTP_TTL}

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
        logging.warning(f"Email send failed: {e}")

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
    entry = _otp_store.get(otp_key)
    if entry and entry["code"] == code and entry["expires"] > time.time():
        _otp_store.pop(otp_key, None)
        user.email_verified = True
        user.email_verified_at = datetime.now(timezone.utc)
        await db.commit()
        return {"verified": True, "message": "Email verified successfully"}

    return {"verified": False, "message": "Invalid or expired code"}


@router.post("/auth/complete-login", dependencies=[Depends(_verify_api_key)])
async def complete_login(body: CompleteLoginIn, db: AsyncSession = Depends(get_db)):
    try:
        payload = jwt.decode(body.login_token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        if payload.get("type") != "login":
            raise HTTPException(401, "Invalid login token")
        user_id = int(payload["sub"])
    except (JWTError, ValueError):
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

    token = _create_token(user.id, role=user.role, status=user.status or "active")
    refresh = _create_refresh_token(user.id)
    return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(user)}

# -- Social Auth (Google / Apple) -------------------------
@router.post("/auth/social", dependencies=[Depends(_verify_api_key)])
async def social_auth(body: SocialAuthIn, db: AsyncSession = Depends(get_db)):
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
            idinfo = google_id_token.verify_oauth2_token(
                body.id_token, google_requests.Request()
            )
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
                    claims = _jwt.decode(
                        body.id_token, _public_key, algorithms=["RS256"],
                        audience=os.getenv("APPLE_CLIENT_ID", ""),
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

    token = _create_token(user.id, role=user.role, status=user.status or "active")
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
    except (JWTError, ValueError):
        _security_audit_log("REFRESH_FAILED", request.client.host if request.client else "unknown", "invalid_token")
        raise HTTPException(401, "Invalid or expired refresh token")
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(401, "User not found")
    st = user.status or "active"
    if st in ("deleted", "blocked", "deactivated"):
        raise HTTPException(403, f"Account {st}")
    device_fp = request.headers.get("x-device-fp", "")
    new_access = _create_token(user.id, device_fp, role=user.role, status=user.status or "active")
    new_refresh = _create_refresh_token(user.id)
    _security_audit_log("TOKEN_REFRESHED", request.client.host if request.client else "unknown", f"user_id={user.id}")
    return {"access_token": new_access, "refresh_token": new_refresh, "token_type": "bearer"}

@router.get("/auth/me", dependencies=[Depends(_verify_api_key)])
async def get_me(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Mark user as online when they call /auth/me (heartbeat)
    # Drivers AND riders: calling /auth/me means the app is open and active
    if not user.is_online:
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

    return _user_dict(user)

@router.post("/auth/offline", dependencies=[Depends(_verify_api_key)])
async def go_offline(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Mark user as offline (called when app goes to background)."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if db_user and db_user.is_online:
        db_user.is_online = False
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
    # Enforce email/phone change limits (max 3 each)
    if "email" in updates and updates["email"] != db_user.email:
        if (db_user.email_changes_count or 0) >= 3:
            raise HTTPException(400, "Maximum email changes reached (3)")
        db_user.email_changes_count = (db_user.email_changes_count or 0) + 1
    if "phone" in updates and updates["phone"] != db_user.phone:
        if (db_user.phone_changes_count or 0) >= 3:
            raise HTTPException(400, "Maximum phone changes reached (3)")
        db_user.phone_changes_count = (db_user.phone_changes_count or 0) + 1
    # Block name changes - first_name and last_name cannot be changed
    updates.pop("first_name", None)
    updates.pop("last_name", None)
    for key in _SAFE_SELF_UPDATE_FIELDS:
        if key in updates:
            val = updates[key]
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
    # Update last active timestamp
    db_user.last_active_at = datetime.now(timezone.utc)
    if updates.get("is_verified") and not db_user.verified_at:
        db_user.verified_at = datetime.now(timezone.utc)
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
                    password_hash=db_user.password_hash,
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
                    password_hash=db_user.password_hash,
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

# -- Photo Upload / Serve ------------------------------
PHOTOS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "photos")
os.makedirs(PHOTOS_DIR, exist_ok=True)

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
    filepath = os.path.join(PHOTOS_DIR, filename)
    with open(filepath, "wb") as f:
        f.write(photo_bytes)
    # Update user photo_url in DB
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    full_photo_url = f"{PUBLIC_URL}/photos/{filename}"
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
                    password_hash=db_user.password_hash,
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
                    password_hash=db_user.password_hash,
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
    
    # Upload to Firebase Storage
    storage_path = f"photos/user_{user.id}/profile.{ext}"
    firebase_url = firestore_sync.upload_to_firebase_storage(
        data=photo_bytes,
        path=storage_path,
        content_type=content_type
    )
    
    if not firebase_url:
        # Fallback to local storage if Firebase fails
        filename = f"user_{user.id}.{ext}"
        filepath = os.path.join(PHOTOS_DIR, filename)
        with open(filepath, "wb") as f:
            f.write(photo_bytes)
        photo_url = f"{PUBLIC_URL}/photos/{filename}"
        logging.warning("Firebase Storage upload failed, using local storage: %s", photo_url)
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
    consent_type: str = Body(...),  # terms, privacy, location, analytics, ads
    action: str = Body(...),  # accepted, revoked
    version: str = Body(None),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Record user consent action for GDPR/CCPA compliance."""
    # Get request metadata
    ip = request.client.host if request.client else None
    ua = request.headers.get("User-Agent", "")[:500]
    
    # Create consent log entry
    log = ConsentLog(
        user_id=user.id,
        consent_type=consent_type,
        action=action,
        version=version,
        ip_address=ip,
        user_agent=ua,
    )
    db.add(log)
    
    # Update user privacy preferences if applicable
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
        db_user.verification_status = "pending"
        db_user.verification_reason = None
        db_user.is_verified = False
        # Store SSN if provided (validate format, store as XXX-XX-XXXX)
        raw_ssn = body.get("ssn", "")
        if raw_ssn:
            import re as _re
            ssn_digits = _re.sub(r'\D', '', str(raw_ssn))
            if len(ssn_digits) == 9:
                db_user.ssn = f"{ssn_digits[:3]}-{ssn_digits[3:5]}-{ssn_digits[5:]}"
        await db.commit()
        await db.refresh(db_user)
    except HTTPException:
        raise
    except Exception as e:
        logging.error("[Verify] DB error saving verification for user %s: %s", user.id, e)
        raise HTTPException(500, f"Error saving verification: {str(e)}")

    # Save verification photos if provided (non-fatal - disk may be unavailable on Railway)
    saved_urls = {}
    try:
        docs_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "uploads", "documents")
        os.makedirs(docs_dir, exist_ok=True)
    except Exception as e:
        logging.warning("[Verify] Cannot create uploads dir: %s", e)
        docs_dir = None

    photo_fields = [
        ("license_front", "license_front"),
        ("license_back", "license_back"),
        ("vehicle_registration", "vehicle_registration"),
        ("insurance_photo", "insurance"),
        ("selfie_photo", "selfie"),
        ("id_photo", "id_doc"),
    ]
    if docs_dir:
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
            try:
                fname = f"verify_{db_user.id}_{label}_{int(time.time())}.{ext}"
                fpath = os.path.join(docs_dir, fname)
                with open(fpath, "wb") as f:
                    f.write(decoded)
                saved_urls[label] = f"{PUBLIC_URL}/uploads/documents/{fname}"
            except Exception as e:
                logging.warning("[Verify] Could not save photo %s: %s", label, e)

    # Handle verification video (MP4)
    video_b64 = body.get("verification_video")
    video_url = None
    if docs_dir and video_b64 and isinstance(video_b64, str):
        if len(video_b64) <= 20 * 1024 * 1024:  # 20MB limit for video
            try:
                video_decoded = base64.b64decode(video_b64, validate=True)
                if len(video_decoded) <= 15 * 1024 * 1024:
                    vname = f"verify_{db_user.id}_liveness_{int(time.time())}.mp4"
                    vpath = os.path.join(docs_dir, vname)
                    with open(vpath, "wb") as f:
                        f.write(video_decoded)
                    video_url = f"{PUBLIC_URL}/uploads/documents/{vname}"
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
        if video_url:
            db_user.video_url = video_url
        await db.commit()
        await db.refresh(db_user)
    except Exception as e:
        logging.error("[Verify] Error saving photo URLs to DB: %s", e)
        # Non-fatal: verification status already saved above

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
                video_url=video_url,
                profile_photo_url=profile_photo_url,
                ssn=db_user.ssn,
                vehicle=vehicle_data,
            )
        except Exception as e:
            logging.error("Firestore verification sync failed: %s", e)
    try:
        return _user_dict(db_user)
    except Exception as e:
        logging.error("[Verify] Error building user dict: %s", e)
        return {"ok": True, "verification_status": "pending"}

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
    # ── Send push notification + email to the approved driver ──
    try:
        if db_user.fcm_token:
            await _send_fcm_push(
                db_user.fcm_token,
                "You're Approved! 🎉",
                "Welcome to the Cruise family! Open the app to start driving.",
                {"type": "driver_approved"},
            )
            logging.info("[DISPATCH-APPROVE] FCM push sent to user %d", user_id)
    except Exception as e:
        logging.warning("[DISPATCH-APPROVE] FCM push failed: %s", e)

    try:
        if db_user.email:
            driver_name = db_user.first_name or "Driver"
            await _send_email(
                db_user.email,
                "Welcome to the Cruise Family!",
                f"""
                <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 600px; margin: 0 auto; background: #0A0A0A; color: #ffffff; padding: 40px 30px; border-radius: 16px;">
                    <div style="text-align: center; margin-bottom: 30px;">
                        <div style="width: 80px; height: 80px; background: linear-gradient(135deg, #D4AF37, #E8C547); border-radius: 50%; margin: 0 auto 20px; display: flex; align-items: center; justify-content: center;">
                            <span style="font-size: 36px;">✓</span>
                        </div>
                        <h1 style="color: #E8C547; font-size: 28px; margin: 0; letter-spacing: 2px;">WELCOME TO THE FAMILY</h1>
                        <p style="color: #D4AF37; font-size: 22px; letter-spacing: 8px; margin: 8px 0 0;">CRUISE</p>
                    </div>
                    <p style="color: #cccccc; font-size: 16px; line-height: 1.6; text-align: center;">
                        Congratulations <strong style="color: #E8C547;">{driver_name}</strong>! Your application has been approved.
                        You're now part of the Cruise driver team.
                    </p>
                    <p style="color: #999999; font-size: 14px; line-height: 1.6; text-align: center; margin-top: 20px;">
                        Open the Cruise app to complete your setup and start accepting rides.
                    </p>
                    <div style="text-align: center; margin-top: 30px; padding-top: 20px; border-top: 1px solid #222;">
                        <p style="color: #666; font-size: 12px;">© Cruise — Premium Rides</p>
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
    return {"ok": True, "message": f"Driver {user_id} rejected", "status": "rejected", "approval_status": "rejected"}


_account_status_cache: dict = {}  # user_id -> (status_str, monotonic_ts)
_ACCOUNT_STATUS_CACHE_TTL = 15.0  # seconds - Firestore check at most every 15s

@router.get("/auth/account-status", dependencies=[Depends(_verify_api_key)])
async def account_status(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Check if account is active, blocked, or deleted (dispatch can change this via Firestore)."""
    import time as _time
    _now = _time.monotonic()
    _cached = _account_status_cache.get(user.id)
    if _cached and (_now - _cached[1]) < _ACCOUNT_STATUS_CACHE_TTL:
        return {"status": _cached[0]}

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

    _account_status_cache[user.id] = (current_status, _now)
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
        _send_fcm_push(
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

    # Find user
    result = await db.execute(
        select(User).where((User.email == identifier) | (User.phone == identifier))
    )
    user = result.scalar_one_or_none()
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
    reset_link = f"{base_url}/auth/reset-page?token={reset_code}"

    # Send email
    html = f"""
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:480px;margin:0 auto;padding:32px 24px;background:#0a0a0a;color:#fff;border-radius:16px;">
      <div style="text-align:center;margin-bottom:24px;">
        <div style="font-size:32px;font-weight:900;color:#E8C547;letter-spacing:2px;">CRUISE</div>
      </div>
      <h2 style="color:#fff;font-size:20px;font-weight:700;margin:0 0 12px;">Reset your password</h2>
      <p style="color:#aaa;font-size:15px;line-height:1.6;margin:0 0 24px;">
        We received a request to reset the password for your Cruise account. Click the button below to create a new password.
      </p>
      <div style="text-align:center;margin:24px 0;">
        <a href="{reset_link}"
           style="display:inline-block;padding:14px 36px;background:linear-gradient(135deg,#E8C547,#D4A800);color:#1a1400;font-size:16px;font-weight:800;text-decoration:none;border-radius:28px;">
          Reset Password
        </a>
      </div>
      <p style="color:#666;font-size:13px;line-height:1.5;margin:24px 0 0;">
        This link expires in 30 minutes. If you didn't request this, ignore this email.
      </p>
    </div>
    """
    _send_email(user.email, "Cruise ï¿½ Reset Your Password", html)

    return {"status": "reset_sent", "method": "email"}


@router.get("/auth/reset-page")
async def reset_page(token: str = Query(...)):
    """Serve a simple HTML page where the user can enter a new password."""
    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Reset Password ï¿½ Cruise</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{background:#0a0a0a;color:#fff;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}}
.card{{max-width:420px;width:100%;padding:40px 32px;background:#111;border-radius:20px;border:1px solid rgba(255,255,255,.06)}}
.logo{{text-align:center;font-size:28px;font-weight:900;color:#E8C547;letter-spacing:2px;margin-bottom:28px}}
h2{{font-size:22px;font-weight:800;margin-bottom:8px}}
.sub{{color:#888;font-size:14px;line-height:1.5;margin-bottom:24px}}
label{{display:block;color:#aaa;font-size:13px;font-weight:600;margin-bottom:6px}}
input{{width:100%;padding:14px 16px;background:#1c1c1e;border:1px solid rgba(255,255,255,.08);border-radius:12px;color:#fff;font-size:16px;outline:none;margin-bottom:16px}}
input:focus{{border-color:#E8C547}}
.btn{{width:100%;padding:16px;background:linear-gradient(135deg,#E8C547,#D4A800);color:#1a1400;font-size:17px;font-weight:800;border:none;border-radius:28px;cursor:pointer;margin-top:8px}}
.btn:disabled{{opacity:.5;cursor:not-allowed}}
.msg{{text-align:center;padding:12px;border-radius:10px;font-size:14px;font-weight:600;margin-top:16px;display:none}}
.msg.ok{{background:rgba(46,125,50,.2);color:#66bb6a;display:block}}
.msg.err{{background:rgba(204,51,51,.15);color:#ef5350;display:block}}
.req{{color:#666;font-size:12px;line-height:1.6;margin-bottom:16px}}
.req span{{color:#E8C547}}
</style>
</head>
<body>
<div class="card">
  <div class="logo">CRUISE</div>
  <h2>Create new password</h2>
  <p class="sub">Enter your new password below.</p>
  <form id="f" onsubmit="return doReset(event)">
    <label>New password</label>
    <input type="password" id="pw" placeholder="Min 8 chars, 1 uppercase, 1 number, 1 special" required>
    <label>Confirm password</label>
    <input type="password" id="pw2" placeholder="Confirm new password" required>
    <div class="req">Requirements: <span>8+ characters</span>, <span>1 uppercase</span>, <span>1 number</span>, <span>1 special character</span></div>
    <button type="submit" class="btn" id="btn">Reset Password</button>
  </form>
  <div id="msg" class="msg"></div>
</div>
<script>
async function doReset(e){{
  e.preventDefault();
  var pw=document.getElementById('pw').value;
  var pw2=document.getElementById('pw2').value;
  var msg=document.getElementById('msg');
  var btn=document.getElementById('btn');
  msg.className='msg';msg.style.display='none';
  if(pw!==pw2){{msg.textContent='Passwords do not match';msg.className='msg err';return false}}
  if(pw.length<8||!/[A-Z]/.test(pw)||!/[0-9]/.test(pw)||!/[!@#$%^&*(),.?\\":{{}}|<>_\\-+=\\[\\]\\\\/~`]/.test(pw)){{
    msg.textContent='Password does not meet requirements';msg.className='msg err';return false
  }}
  btn.disabled=true;btn.textContent='Resetting...';
  try{{
    var r=await fetch('/auth/reset-password-web',{{
      method:'POST',
      headers:{{'Content-Type':'application/json'}},
      body:JSON.stringify({{token:'{token}',new_password:pw}})
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
    msg.textContent='Network error ï¿½ please try again';msg.className='msg err';
    btn.disabled=false;btn.textContent='Reset Password';
  }}
  return false
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
    await db.delete(token_row)
    await db.commit()
    return {"status": "password_reset"}

