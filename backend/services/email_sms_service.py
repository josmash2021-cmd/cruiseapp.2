"""Cruise App — Email (Mailgun/SendGrid/Brevo/SMTP) and SMS (Twilio) services."""

import os
import logging
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

# SMTP config
SMTP_HOST = os.getenv("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASS = os.getenv("SMTP_PASS", "")
SMTP_FROM = os.getenv("SMTP_FROM", "")


def _send_email(to_email: str, subject: str, html_body: str, template_params: dict = None):
    """Send email via EmailJS, Mailgun API, SendGrid API, Brevo API, or SMTP fallback."""
    import urllib.request as _ureq, json as _json, urllib.error as _uerr, urllib.parse as _uparse

    # 1. EmailJS REST API (server-side)
    EMAILJS_SERVICE_ID = os.getenv("EMAILJS_SERVICE_ID", "")
    EMAILJS_TEMPLATE_ID = os.getenv("EMAILJS_TEMPLATE_ID", "")
    EMAILJS_PUBLIC_KEY = os.getenv("EMAILJS_PUBLIC_KEY", "")
    EMAILJS_PRIVATE_KEY = os.getenv("EMAILJS_PRIVATE_KEY", "")
    if EMAILJS_SERVICE_ID and EMAILJS_TEMPLATE_ID and EMAILJS_PUBLIC_KEY and EMAILJS_PRIVATE_KEY:
        try:
            # Extract OTP code from html_body if present (6-digit number)
            import re as _re
            _otp_match = _re.search(r'\b(\d{6})\b', html_body)
            _otp_code = _otp_match.group(1) if _otp_match else ""
            _params = template_params or {}
            _params.setdefault("to_email", to_email)
            _params.setdefault("email", to_email)
            _params.setdefault("name", to_email.split("@")[0])
            _params.setdefault("to_name", to_email.split("@")[0])
            _params.setdefault("subject", subject)
            _params.setdefault("code", _otp_code)
            _params.setdefault("otp_code", _otp_code)
            _params.setdefault("verification_code", _otp_code)
            _params.setdefault("app_name", "Cruise")
            _params.setdefault("from_name", "Cruise")
            _params.setdefault("message", html_body)
            payload = _json.dumps({
                "service_id": EMAILJS_SERVICE_ID,
                "template_id": EMAILJS_TEMPLATE_ID,
                "user_id": EMAILJS_PUBLIC_KEY,
                "accessToken": EMAILJS_PRIVATE_KEY,
                "template_params": _params,
            }).encode()
            req = _ureq.Request(
                "https://api.emailjs.com/api/v1.0/email/send",
                data=payload,
                headers={"Content-Type": "application/json", "origin": "https://cruiseapp2-production.up.railway.app"},
                method="POST",
            )
            with _ureq.urlopen(req, timeout=10) as resp:
                logging.info("[EMAIL] EmailJS OK to %s", to_email)
                return True
        except _uerr.HTTPError as e:
            logging.error("[EMAIL] EmailJS HTTP %s: %s", e.code, e.read().decode()[:200])
        except Exception as e:
            logging.error("[EMAIL] EmailJS failed: %s", e)

    # 3. Mailgun API
    MAILGUN_API_KEY = os.getenv("MAILGUN_API_KEY", "")
    MAILGUN_DOMAIN = os.getenv("MAILGUN_DOMAIN", "")
    if MAILGUN_API_KEY and MAILGUN_DOMAIN:
        try:
            import base64 as _b64
            creds = _b64.b64encode(f"api:{MAILGUN_API_KEY}".encode()).decode()
            form = _uparse.urlencode({
                "from": f"Cruise <noreply@cruiseapp.com>",
                "to": to_email,
                "subject": subject,
                "html": html_body,
            }).encode()
            req = _ureq.Request(
                f"https://api.mailgun.net/v3/{MAILGUN_DOMAIN}/messages",
                data=form,
                headers={"Authorization": f"Basic {creds}"},
                method="POST"
            )
            with _ureq.urlopen(req, timeout=8) as resp:
                logging.info("[EMAIL] Mailgun OK to %s", to_email)
                return True
        except _uerr.HTTPError as e:
            logging.error("[EMAIL] Mailgun HTTP %s: %s", e.code, e.read().decode()[:200])
        except Exception as e:
            logging.error("[EMAIL] Mailgun failed: %s", e)

    # 4. SendGrid API
    SENDGRID_API_KEY = os.getenv("SENDGRID_API_KEY", "")
    if SENDGRID_API_KEY:
        try:
            payload = _json.dumps({
                "personalizations": [{"to": [{"email": to_email}]}],
                "from": {"email": "noreply@cruiseapp.com", "name": "Cruise"},
                "subject": subject,
                "content": [{"type": "text/html", "value": html_body}]
            }).encode()
            req = _ureq.Request(
                "https://api.sendgrid.com/v3/mail/send",
                data=payload,
                headers={"Content-Type": "application/json", "Authorization": f"Bearer {SENDGRID_API_KEY}"},
                method="POST"
            )
            with _ureq.urlopen(req, timeout=8) as resp:
                logging.info("[EMAIL] SendGrid OK to %s", to_email)
                return True
        except _uerr.HTTPError as e:
            logging.error("[EMAIL] SendGrid HTTP %s: %s", e.code, e.read().decode()[:200])
        except Exception as e:
            logging.error("[EMAIL] SendGrid failed: %s", e)

    # 5. Brevo (Sendinblue) API
    BREVO_API_KEY = os.getenv("BREVO_API_KEY", "")
    if BREVO_API_KEY:
        try:
            payload = _json.dumps({
                "sender": {"name": "Cruise", "email": "noreply@cruiseapp.com"},
                "to": [{"email": to_email}],
                "subject": subject,
                "htmlContent": html_body,
            }).encode()
            req = _ureq.Request(
                "https://api.brevo.com/v3/smtp/email",
                data=payload,
                headers={"Content-Type": "application/json", "api-key": BREVO_API_KEY},
                method="POST"
            )
            with _ureq.urlopen(req, timeout=8) as resp:
                logging.info("[EMAIL] Brevo OK to %s", to_email)
                return True
        except _uerr.HTTPError as e:
            logging.error("[EMAIL] Brevo HTTP %s: %s", e.code, e.read().decode()[:200])
        except Exception as e:
            logging.error("[EMAIL] Brevo failed: %s", e)

    # 6. SMTP fallback
    if not SMTP_USER or not SMTP_PASS:
        logging.warning("[EMAIL] No email provider configured for %s", to_email)
        return False
    _from = SMTP_FROM.strip() if SMTP_FROM else SMTP_USER

    def _build_msg():
        m = MIMEMultipart("alternative")
        m["Subject"] = subject
        m["From"] = _from
        m["To"] = to_email
        m.attach(MIMEText(html_body, "html"))
        return m

    try:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=8) as server:
            server.starttls()
            server.login(SMTP_USER, SMTP_PASS)
            server.sendmail(_from, to_email, _build_msg().as_string())
        logging.info("[EMAIL] Sent via SMTP STARTTLS to %s", to_email)
        return True
    except Exception as e:
        logging.warning("[EMAIL] SMTP port %s failed: %s — trying SSL 465", SMTP_PORT, e)
    try:
        with smtplib.SMTP_SSL(SMTP_HOST, 465, timeout=8) as server:
            server.login(SMTP_USER, SMTP_PASS)
            server.sendmail(_from, to_email, _build_msg().as_string())
        logging.info("[EMAIL] Sent via SMTP SSL to %s", to_email)
        return True
    except Exception as e:
        logging.error("[EMAIL] SMTP SSL also failed to %s: %s", to_email, e)
        return False


def _send_sms(phone_number: str, message: str):
    """Send SMS via Twilio. Returns Twilio message SID on success, None on failure.

    Historically this returned bool; callers that only check truthiness keep
    working because a non-empty SID string is truthy."""
    TWILIO_ACCOUNT_SID = os.getenv("TWILIO_ACCOUNT_SID", "")
    TWILIO_AUTH_TOKEN = os.getenv("TWILIO_AUTH_TOKEN", "")
    TWILIO_PHONE_NUMBER = os.getenv("TWILIO_PHONE_NUMBER", "")

    if not (TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN and TWILIO_PHONE_NUMBER):
        logging.error("[SMS] Twilio credentials not configured")
        return None

    try:
        from twilio.rest import Client
        client = Client(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN)
        sms = client.messages.create(
            body=message,
            from_=TWILIO_PHONE_NUMBER,
            to=phone_number
        )
        logging.info("[SMS] Sent to %s (SID: %s)", phone_number, sms.sid)
        return sms.sid
    except Exception as e:
        logging.error("[SMS] Failed to send to %s: %s", phone_number, e)
        return None
