"""Driver email systems (2026-10-20, user spec "quiero los 4").

One shared branded builder + one sender per email type:

  1. Scheduled-ride reminders (24 h and 1 h before pickup).
  2. Document expiring (30/15/7/1-day thresholds).
  3. Weekly earnings summary (Monday) + payout confirmation.
  4. Account lifecycle (background check decided, account
     deactivated/blocked/reactivated, referral milestone paid).

Every email is ES/EN by ``users.locale``, carries the CRUISE IN RIDE brand
and the OPEN THE APP button (``/open-app`` — the per-platform store
redirect; an installed app shows "Abrir" there). Senders run the SYNC
``_send_email`` in the executor and are fail-soft: a mail failure never
breaks the agent loop, webhook or admin action that triggered them.
"""

import asyncio
import logging
import os
from datetime import datetime, timezone
from html import escape as _esc

from models.database import User
from services.driver_approval import _DOC_NAME

logger = logging.getLogger(__name__)

OPEN_APP_URL = os.getenv(
    "PUBLIC_BASE_URL", "https://cruiseapp2-production.up.railway.app") + "/open-app"
_LOGO_URL = "https://raw.githubusercontent.com/josmash2021-cmd/cruiseapp.2/main/assets/images/cruise_logo_email.png"


def _es(user) -> bool:
    return (getattr(user, "locale", None) or "es").lower().startswith("es")


def _first(user) -> str:
    return _esc(getattr(user, "first_name", None) or "Driver")


def _branded(headline: str, paragraphs: list[str],
             rows: list[tuple[str, str]] | None = None,
             button: str = "OPEN THE APP") -> str:
    """The shared dark/gold CRUISE IN RIDE layout. ``rows`` values are
    inserted as-is (already formatted/escaped by the caller); labels are
    escaped here."""
    rows_html = ""
    if rows:
        body = "".join(
            f'<tr><td style="color:#555;font-size:12px;padding:5px 0;">{_esc(label)}</td>'
            f'<td style="color:#e0e0e0;font-size:14px;text-align:right;padding:5px 0;">{value}</td></tr>'
            for label, value in rows)
        rows_html = (
            '<div style="background:#111;border:1px solid #1a1a1a;border-radius:10px;'
            'padding:16px 20px;margin:0 0 28px;"><table cellpadding="0" cellspacing="0" '
            f'border="0" width="100%">{body}</table></div>')
    paras = "".join(
        f'<p style="text-align:center;color:#666;font-size:14px;margin:0 0 14px;line-height:1.6;">{p}</p>'
        for p in paragraphs)
    return f"""
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;max-width:560px;margin:0 auto;background:#050505;border-radius:16px;overflow:hidden;border:1px solid #1a1a1a;">
      <div style="background:linear-gradient(90deg,transparent,#D4AF37,#E8C547,#D4AF37,transparent);height:2px;"></div>
      <div style="padding:44px 40px 36px;">
        <div style="text-align:center;margin-bottom:28px;">
          <img src="{_LOGO_URL}" alt="CRUISE IN RIDE" width="72" height="72" style="display:block;margin:0 auto 14px;border-radius:18px;">
          <h2 style="font-family:Georgia,'Times New Roman',serif;font-size:22px;font-weight:700;color:#E8C547;letter-spacing:4px;margin:0;text-indent:4px;">CRUISE IN RIDE</h2>
        </div>
        <h1 style="text-align:center;color:#FFFFFF;font-size:23px;font-weight:300;margin:0 0 22px;">{headline}</h1>
        {paras}
        {rows_html}
        <div style="text-align:center;margin-top:30px;">
          <a href="{OPEN_APP_URL}" style="display:inline-block;background:#D4AF37;color:#000;text-decoration:none;padding:14px 48px;border-radius:28px;font-size:14px;font-weight:700;letter-spacing:1px;">{button}</a>
        </div>
      </div>
      <div style="border-top:1px solid #111;padding:24px 40px;text-align:center;">
        <p style="color:#333;font-size:11px;letter-spacing:2px;margin:0 0 4px;">CRUISE IN RIDE</p>
        <p style="color:#252525;font-size:10px;margin:0;">Premium Rides &mdash; cruiseinride.com</p>
      </div>
    </div>
    """


async def _send_driver_email(user: User, subject: str, html: str) -> bool:
    """Fail-soft branded send. Returns True when a provider accepted it."""
    if not getattr(user, "email", None):
        return False
    try:
        from services.email_sms_service import _send_email
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            None, lambda: _send_email(user.email, subject, html))
    except Exception as e:
        logger.warning("[DriverEmails] send failed for user %s: %s",
                       getattr(user, "id", "?"), e)
        return False


# ── 1. Scheduled-ride reminders ──────────────────────────────────────────

def _fmt_pickup(sched_at: datetime) -> str:
    """'Tue, Oct 21 · 8:30 AM ET / 7:30 AM CT' — FL is Eastern, AL is
    Central and there is no per-user timezone, so the email shows both."""
    if sched_at.tzinfo is None:
        sched_at = sched_at.replace(tzinfo=timezone.utc)
    from zoneinfo import ZoneInfo
    et = sched_at.astimezone(ZoneInfo("America/New_York"))
    ct = sched_at.astimezone(ZoneInfo("America/Chicago"))
    day = et.strftime("%a, %b %d")
    _t = lambda d: d.strftime("%I:%M %p").lstrip("0")  # %-I is not portable
    return f"{day} · {_t(et)} ET / {_t(ct)} CT"


async def send_scheduled_reminder_email(user: User, trip, hours: int) -> bool:
    """24 h / 1 h before the reserved pickup. ES/EN by driver locale."""
    es = _es(user)
    when = _fmt_pickup(trip.scheduled_at)
    rider = _esc(getattr(trip, "guest_first_name", None) or "")
    if not rider:
        rider = _esc(getattr(trip, "_rider_name", "") or "")
    pickup = _esc((trip.pickup_address or "")[:90])
    dropoff = _esc((trip.dropoff_address or "")[:90])
    fare = trip.fare
    rows = [
        ("Recogida" if es else "Pickup", _esc(when)),
        ("Desde" if es else "From", pickup),
        ("Hasta" if es else "To", dropoff),
    ]
    if rider:
        rows.append(("Rider", rider))
    if fare:
        rows.append(("Tarifa estimada" if es else "Estimated fare",
                     f"${fare:.2f}"))
    if es:
        subject = f"CRUISE IN RIDE — Recordatorio: viaje en {hours} h"
        headline = f"Viaje agendado en <strong>{hours} horas</strong>"
        paras = [f"{_first(user)}, tienes un viaje reservado. Revísalo en "
                 "la app y conéctate a tiempo — si no llegas, la reserva "
                 "puede asignarse a otro conductor."]
        btn = "ABRIR LA APP"
    else:
        subject = f"CRUISE IN RIDE — Reminder: ride in {hours}h"
        headline = f"Scheduled ride in <strong>{hours} hours</strong>"
        paras = [f"{_first(user)}, you have a reserved ride. Review it in "
                 "the app and go online on time — if you miss it, the "
                 "reservation may go to another driver."]
        btn = "OPEN THE APP"
    return await _send_driver_email(
        user, subject, _branded(headline, paras, rows, btn))


# ── 2. Document expiring ─────────────────────────────────────────────────

async def send_doc_expiry_email(user: User, doc_type: str,
                                expiry: datetime, days_left: int) -> bool:
    """30/15/7/1-day notices before a document expires."""
    es = _es(user)
    names = _DOC_NAME.get(doc_type, ("Documento", "Document"))
    doc_name = names[0] if es else names[1]
    exp_txt = _esc(expiry.strftime("%b %d, %Y"))
    urgency = ("¡VENCE MAÑANA!" if days_left <= 1 else
               f"Vence en {days_left} días") if es else (
               "EXPIRES TOMORROW!" if days_left <= 1 else
               f"Expires in {days_left} days")
    rows = [
        ("Documento" if es else "Document", _esc(doc_name)),
        ("Vence" if es else "Expires", exp_txt),
        ("Estado" if es else "Status", _esc(urgency)),
    ]
    if es:
        subject = f"CRUISE IN RIDE — {doc_name} por vencer"
        headline = "Documento <strong>por vencer</strong>"
        paras = [f"{_first(user)}, tu {doc_name} vence pronto. Súbelo de "
                 "nuevo desde tu lista To-do para no quedar bloqueado."]
        btn = "ABRIR LA APP"
    else:
        subject = f"CRUISE IN RIDE — {doc_name} expiring soon"
        headline = "Document <strong>expiring soon</strong>"
        paras = [f"{_first(user)}, your {doc_name} expires soon. Upload it "
                 "again from your To-do list so you don't get blocked."]
        btn = "OPEN THE APP"
    return await _send_driver_email(
        user, subject, _branded(headline, paras, rows, btn))


# ── 3. Weekly summary + payout ───────────────────────────────────────────

async def send_weekly_summary_email(user: User, stats: dict) -> bool:
    """Monday recap: trips, earnings, tips, total for the past ISO week."""
    es = _es(user)
    trips = int(stats.get("trips", 0))
    earnings = float(stats.get("earnings", 0.0))
    tips = float(stats.get("tips", 0.0))
    total = earnings + tips
    rows = [
        ("Viajes" if es else "Trips", str(trips)),
        ("Ganancia por viajes" if es else "Trip earnings", f"${earnings:.2f}"),
        ("Propinas" if es else "Tips", f"${tips:.2f}"),
        ("Total", f"${total:.2f}"),
    ]
    if es:
        subject = "CRUISE IN RIDE — Tu resumen semanal"
        headline = "Tu semana <strong>en números</strong>"
        paras = [f"{_first(user)}, así te fue la semana pasada. El pago se "
                 "procesa los lunes y llega a tu banco en 1-2 días."]
        btn = "VER MIS GANANCIAS"
    else:
        subject = "CRUISE IN RIDE — Your weekly summary"
        headline = "Your week <strong>in numbers</strong>"
        paras = [f"{_first(user)}, here's how last week went. Payouts run "
                 "on Mondays and reach your bank in 1-2 days."]
        btn = "VIEW MY EARNINGS"
    return await _send_driver_email(
        user, subject, _branded(headline, paras, rows, btn))


async def send_payout_email(user: User, amount: float) -> bool:
    """The weekly payout left for the driver's bank."""
    es = _es(user)
    rows = [("Monto" if es else "Amount", f"${amount:.2f}"),
            ("Llega" if es else "Arrives",
             _esc("1-2 días hábiles" if es else "1-2 business days"))]
    if es:
        subject = f"CRUISE IN RIDE — Tu pago de ${amount:.2f} va en camino"
        headline = "Pago <strong>en camino</strong>"
        paras = [f"{_first(user)}, tu pago semanal ya se procesó y va "
                 "camino a tu cuenta bancaria."]
        btn = "ABRIR LA APP"
    else:
        subject = f"CRUISE IN RIDE — Your ${amount:.2f} payout is on its way"
        headline = "Payout <strong>on its way</strong>"
        paras = [f"{_first(user)}, your weekly payout was processed and is "
                 "on its way to your bank account."]
        btn = "OPEN THE APP"
    return await _send_driver_email(
        user, subject, _branded(headline, paras, rows, btn))


# ── 4. Account lifecycle ─────────────────────────────────────────────────

async def send_background_check_email(user: User, clear: bool) -> bool:
    """Checkr report.completed: clear = approved, consider = under review."""
    es = _es(user)
    if es:
        subject = ("CRUISE IN RIDE — Antecedentes aprobados" if clear else
                   "CRUISE IN RIDE — Antecedentes en revisión")
        headline = ("Antecedentes <strong>aprobados</strong>" if clear else
                    "Antecedentes <strong>en revisión</strong>")
        paras = [
            f"{_first(user)}, tu verificación de antecedentes fue aprobada."
            if clear else
            f"{_first(user)}, tu verificación de antecedentes requiere "
            "revisión adicional. Te contactaremos si necesitamos algo."]
        btn = "ABRIR LA APP"
    else:
        subject = ("CRUISE IN RIDE — Background check approved" if clear else
                   "CRUISE IN RIDE — Background check under review")
        headline = ("Background check <strong>approved</strong>" if clear else
                    "Background check <strong>under review</strong>")
        paras = [
            f"{_first(user)}, your background check was approved."
            if clear else
            f"{_first(user)}, your background check needs additional "
            "review. We'll reach out if we need anything."]
        btn = "OPEN THE APP"
    return await _send_driver_email(
        user, subject, _branded(headline, paras, [], btn))


async def send_account_status_email(user: User, status: str) -> bool:
    """deactivated / blocked / re-activated to active."""
    es = _es(user)
    st = (status or "").lower()
    if st == "active":
        subject = "CRUISE IN RIDE — Tu cuenta fue reactivada" if es else \
            "CRUISE IN RIDE — Your account was reactivated"
        headline = "Cuenta <strong>reactivada</strong>" if es else \
            "Account <strong>reactivated</strong>"
        paras = [f"{_first(user)}, tu cuenta está activa de nuevo. Ya "
                 "puedes conectarte y trabajar." if es else
                 f"{_first(user)}, your account is active again. You can "
                 "go online and work."]
    elif st == "blocked":
        subject = "CRUISE IN RIDE — Tu cuenta fue bloqueada" if es else \
            "CRUISE IN RIDE — Your account was blocked"
        headline = "Cuenta <strong>bloqueada</strong>" if es else \
            "Account <strong>blocked</strong>"
        paras = [f"{_first(user)}, tu cuenta fue bloqueada. Si crees que "
                 "es un error, contáctanos desde el centro de ayuda."
                 if es else
                 f"{_first(user)}, your account was blocked. If you think "
                 "this is a mistake, contact us from the help center."]
    else:  # deactivated
        subject = "CRUISE IN RIDE — Tu cuenta fue desactivada" if es else \
            "CRUISE IN RIDE — Your account was deactivated"
        headline = "Cuenta <strong>desactivada</strong>" if es else \
            "Account <strong>deactivated</strong>"
        paras = [f"{_first(user)}, tu cuenta fue desactivada temporalmente. "
                 "Contáctanos si tienes preguntas." if es else
                 f"{_first(user)}, your account was temporarily deactivated. "
                 "Contact us if you have questions."]
    btn = "ABRIR LA APP" if es else "OPEN THE APP"
    return await _send_driver_email(
        user, subject, _branded(headline, paras, [], btn))


async def send_referral_milestone_email(user: User, amount: float) -> bool:
    """A driver-referral milestone bonus landed in pending_balance."""
    es = _es(user)
    rows = [("Bono" if es else "Bonus", f"${amount:.2f}"),
            ("Dónde" if es else "Where",
             _esc("Tu balance — se paga el lunes" if es else
                  "Your balance — paid out on Monday"))]
    if es:
        subject = f"CRUISE IN RIDE — Ganaste ${amount:.2f} por tu referido"
        headline = "Bono de referido <strong>acreditado</strong>"
        paras = [f"{_first(user)}, tu referido alcanzó un hito y el bono "
                 "ya está en tu balance. Sigue compartiendo tu código."]
        btn = "ABRIR LA APP"
    else:
        subject = f"CRUISE IN RIDE — You earned ${amount:.2f} from your referral"
        headline = "Referral bonus <strong>credited</strong>"
        paras = [f"{_first(user)}, your referral hit a milestone and the "
                 "bonus is already in your balance. Keep sharing your code."]
        btn = "OPEN THE APP"
    return await _send_driver_email(
        user, subject, _branded(headline, paras, rows, btn))
