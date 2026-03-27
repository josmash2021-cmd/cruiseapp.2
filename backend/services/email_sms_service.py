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
    """Send email via Mailgun API, SendGrid API, Brevo API, or SMTP fallback."""
    import urllib.request as _ureq, json as _json, urllib.error as _uerr, urllib.parse as _uparse

    # 1. Mailgun API
    MAILGUN_API_KEY = os.getenv("MAILGUN_API_KEY", "")
    MAILGUN_DOMAIN = os.getenv("MAILGUN_DOMAIN", "")
    if MAILGUN_API_KEY and MAILGUN_DOMAIN:
        try:
            import base64 as _b64
            creds = _b64.b64encode(f"api:{MAILGUN_API_KEY}".encode()).decode()
            form = _uparse.urlencode({
                "from": f"Cruise App <mailgun@{MAILGUN_DOMAIN}>",
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

    # 2. SendGrid API
    SENDGRID_API_KEY = os.getenv("SENDGRID_API_KEY", "")
    if SENDGRID_API_KEY:
        try:
            payload = _json.dumps({
                "personalizations": [{"to": [{"email": to_email}]}],
                "from": {"email": "noreply@cruiseapp.com", "name": "Cruise App"},
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

    # 3. Brevo (Sendinblue) API
    BREVO_API_KEY = os.getenv("BREVO_API_KEY", "")
    if BREVO_API_KEY:
        try:
            payload = _json.dumps({
                "sender": {"name": "Cruise App", "email": "royalpurplecorp@gmail.com"},
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

    # 4. SMTP fallback
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
