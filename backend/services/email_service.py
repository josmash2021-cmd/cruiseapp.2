"""Guest rider EMAIL notifications — bilingual (EN/ES) with hosted logo.

Sends the same 5 lifecycle events as the SMS service (welcome, driver_assigned,
driver_en_route, driver_arrived, trip_completed). Language is chosen from
``trip.guest_lang`` (defaults to ``en``), so only Spanish-speaking guests see
Spanish copy.
"""

import asyncio
import logging
import re

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from models.database import EmailLog
from services.email_sms_service import _send_email

_log = logging.getLogger(__name__)

_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

BRAND_GOLD = "#E8C547"
BRAND_BG = "#000000"
BRAND_CARD = "#000000"
BRAND_TEXT_GOLD = "#E8C547"
BRAND_TEXT_SOFT = "#d9c98b"
BRAND_MUTED = "#8a7e4e"

LOGO_URL = "https://cdn.shopify.com/s/files/1/0805/8640/8191/files/Untitled_design_069defa2-9e36-4d98-831f-f776d4c6f7a5.png?v=1772961171"


def _shell(title: str, body_html: str) -> str:
    return f"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<meta name="color-scheme" content="dark">
<meta name="supported-color-schemes" content="dark">
<title>{title}</title>
<style>
  :root {{ color-scheme: dark; supported-color-schemes: dark; }}
  body, table, td {{ background-color: #000000 !important; }}
  .gold {{ color: #E8C547 !important; }}
</style>
</head>
<body bgcolor="#000000" style="margin:0;padding:0;background:#000000 !important;font-family:'Poppins',Helvetica,Arial,sans-serif;color:#E8C547;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#000000" style="background-color:#000000 !important;padding:40px 14px;">
<tr><td align="center" bgcolor="#000000" style="background-color:#000000 !important;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#000000" style="max-width:560px;background-color:#000000 !important;border-radius:18px;border:1px solid rgba(232,197,71,.28);box-shadow:0 0 0 1px rgba(232,197,71,.08),0 12px 40px rgba(232,197,71,.18),0 24px 80px rgba(232,197,71,.12),0 40px 120px rgba(0,0,0,.8);">
<tr><td align="center" bgcolor="#000000" style="background-color:#000000 !important;padding:34px 30px 26px;border-bottom:1px solid rgba(232,197,71,.18);">
<img src="{LOGO_URL}" alt="Cruise" width="72" height="72" style="display:block;width:72px;height:72px;border:0;outline:none;">
<div style="margin-top:10px;font-size:30px;font-weight:900;letter-spacing:3px;color:#E8C547 !important;font-family:Georgia,'Times New Roman',serif;">CRUISE</div>
</td></tr>
<tr><td bgcolor="#000000" style="background-color:#000000 !important;padding:30px 30px 12px;">{body_html}</td></tr>
<tr><td align="center" bgcolor="#000000" style="background-color:#000000 !important;padding:22px 30px 10px;border-top:1px solid rgba(232,197,71,.18);">
<a href="https://cruiseinride.com" style="display:inline-block;padding:11px 24px;background:#0d0d0d;border:1px solid rgba(232,197,71,.5);border-radius:999px;color:#E8C547 !important;font-size:13px;font-weight:700;text-decoration:none;letter-spacing:.02em;">cruiseinride.com →</a>
</td></tr>
<tr><td bgcolor="#000000" style="background-color:#000000 !important;padding:12px 30px 22px;font-size:11px;color:#8a7e4e !important;text-align:center;line-height:1.5;">
© Cruise · cruiseinride.com
</td></tr>
</table>
</td></tr></table>
</body></html>"""


def _h1(text: str) -> str:
    return (
        f'<h1 style="margin:0 0 14px 0;font-size:24px;font-weight:800;'
        f'color:#E8C547 !important;letter-spacing:-.01em;">{text}</h1>'
    )


def _p(text: str) -> str:
    return (
        f'<p style="margin:0 0 14px 0;font-size:15px;line-height:1.55;'
        f'color:#d9c98b !important;">{text}</p>'
    )


def _kv_row(label: str, value: str) -> str:
    return (
        f'<tr><td style="padding:8px 0;font-size:13px;color:#8a7e4e !important;width:38%;">{label}</td>'
        f'<td style="padding:8px 0;font-size:14px;color:#E8C547 !important;font-weight:700;">{value}</td></tr>'
    )


# ═══════════════════════════════════════════════════════
# Bilingual templates
# ═══════════════════════════════════════════════════════

def _build_welcome(first_name: str, lang: str) -> tuple[str, str, str]:
    if lang == "es":
        subject = f"¡Bienvenido a Cruise, {first_name}!"
        body = (
            _h1(f"¡Bienvenido, {first_name}!")
            + _p("Tu viaje ya está en nuestro sistema. Te avisaremos en unos "
                 "minutos cuando tengas un conductor asignado.")
            + _p("Gracias por elegir Cruise.")
        )
        text = (
            f"¡Bienvenido a Cruise, {first_name}!\n\n"
            "Tu viaje ya está en nuestro sistema. Te avisaremos en unos "
            "minutos cuando tengas un conductor asignado.\n\n"
            "Gracias por elegir Cruise."
        )
    else:
        subject = f"Welcome to Cruise, {first_name}!"
        body = (
            _h1(f"Welcome, {first_name}!")
            + _p("Your ride is now in our system. We'll notify you in a few "
                 "minutes once a driver has been assigned.")
            + _p("Thank you for choosing Cruise.")
        )
        text = (
            f"Welcome to Cruise, {first_name}!\n\n"
            "Your ride is now in our system. We'll notify you in a few "
            "minutes once a driver has been assigned.\n\n"
            "Thank you for choosing Cruise."
        )
    return subject, _shell(subject, body), text


def _build_driver_assigned(driver_name, vehicle_year, vehicle_make, vehicle_model,
                           vehicle_color, vehicle_plate, driver_phone, lang) -> tuple[str, str, str]:
    if lang == "es":
        subject = "Tu conductor está asignado"
        labels = {"driver": "Conductor", "vehicle": "Vehículo",
                  "color": "Color", "plate": "Placa", "phone": "Teléfono"}
        heading = "¡Conductor asignado!"
        intro = "Tu viaje ya tiene conductor. Aquí están los detalles:"
        closing = "Estará contigo pronto."
    else:
        subject = "Your driver has been assigned"
        labels = {"driver": "Driver", "vehicle": "Vehicle",
                  "color": "Color", "plate": "Plate", "phone": "Phone"}
        heading = "Driver assigned!"
        intro = "Your ride now has a driver. Here are the details:"
        closing = "They'll be with you shortly."
    rows = (
        _kv_row(labels["driver"], driver_name)
        + _kv_row(labels["vehicle"], f"{vehicle_year} {vehicle_make} {vehicle_model}".strip())
        + _kv_row(labels["color"], vehicle_color or "—")
        + _kv_row(labels["plate"], vehicle_plate or "—")
        + _kv_row(labels["phone"], driver_phone or "—")
    )
    body = (
        _h1(heading) + _p(intro)
        + f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" '
          f'style="border-collapse:collapse;border-top:1px solid rgba(232,197,71,.18);'
          f'border-bottom:1px solid rgba(232,197,71,.18);margin:8px 0 16px;">{rows}</table>'
        + _p(closing)
    )
    text = (
        f"{heading}\n\n{labels['driver']}: {driver_name}\n"
        f"{labels['vehicle']}: {vehicle_year} {vehicle_make} {vehicle_model} ({vehicle_color})\n"
        f"{labels['plate']}: {vehicle_plate}\n"
        f"{labels['phone']}: {driver_phone}\n\n{closing}"
    )
    return subject, _shell(subject, body), text


def _build_driver_en_route(driver_name: str, lang: str) -> tuple[str, str, str]:
    if lang == "es":
        subject = "Tu conductor va en camino"
        body = _h1("Tu conductor va en camino") + _p(
            f"<strong style=\"color:#E8C547 !important;\">{driver_name}</strong> "
            "ya está en camino hacia tu punto de recogida."
        )
        text = f"Tu conductor {driver_name} ya está en camino hacia tu punto de recogida."
    else:
        subject = "Your driver is on the way"
        body = _h1("Your driver is on the way") + _p(
            f"<strong style=\"color:#E8C547 !important;\">{driver_name}</strong> "
            "is now heading to your pickup location."
        )
        text = f"Your driver {driver_name} is now heading to your pickup location."
    return subject, _shell(subject, body), text


def _build_driver_arrived(driver_name: str, lang: str) -> tuple[str, str, str]:
    if lang == "es":
        subject = "Tu conductor ha llegado"
        body = _h1("Tu conductor ha llegado") + _p(
            f"<strong style=\"color:#E8C547 !important;\">{driver_name}</strong> "
            "ha llegado al punto de recogida y te está esperando."
        )
        text = f"Tu conductor {driver_name} ha llegado. Te está esperando."
    else:
        subject = "Your driver has arrived"
        body = _h1("Your driver has arrived") + _p(
            f"<strong style=\"color:#E8C547 !important;\">{driver_name}</strong> "
            "has arrived at the pickup location and is waiting for you."
        )
        text = f"Your driver {driver_name} has arrived. They're waiting for you."
    return subject, _shell(subject, body), text


def _build_trip_completed(lang: str) -> tuple[str, str, str]:
    if lang == "es":
        subject = "Tu viaje ha sido completado — gracias"
        body = (
            _h1("Viaje completado")
            + _p("¡Gracias por viajar con Cruise!")
            + _p('Para más información visita <a href="https://cruiseinride.com" '
                 'style="color:#E8C547 !important;text-decoration:none;font-weight:700;">cruiseinride.com</a>.')
        )
        text = (
            "Tu viaje ha sido completado. ¡Gracias por viajar con Cruise!\n"
            "Para más información visita cruiseinride.com"
        )
    else:
        subject = "Your trip is complete — thank you"
        body = (
            _h1("Trip completed")
            + _p("Thank you for riding with Cruise!")
            + _p('For more info visit <a href="https://cruiseinride.com" '
                 'style="color:#E8C547 !important;text-decoration:none;font-weight:700;">cruiseinride.com</a>.')
        )
        text = (
            "Your trip has been completed. Thank you for riding with Cruise!\n"
            "For more info visit cruiseinride.com"
        )
    return subject, _shell(subject, body), text


def _guest_email(trip) -> str:
    raw = (getattr(trip, "guest_email", None) or "").strip().lower()
    if not raw or not _EMAIL_RE.match(raw):
        return ""
    return raw


def _guest_first_name(trip) -> str:
    return (getattr(trip, "guest_first_name", None) or "").strip() or "friend"


def _guest_lang(trip) -> str:
    raw = (getattr(trip, "guest_lang", None) or "en").strip().lower()[:2]
    return raw if raw in ("en", "es") else "en"


async def _write_log(db, *, trip_id, event_type, email_address, status, provider_id=None, error_message=None):
    try:
        row = EmailLog(
            trip_id=trip_id,
            event_type=event_type,
            email_address=email_address,
            status=status,
            provider_id=provider_id,
            error_message=error_message,
        )
        db.add(row)
        await db.commit()
        return True
    except IntegrityError:
        await db.rollback()
        return False
    except Exception as log_err:
        try:
            await db.rollback()
        except Exception:
            pass
        _log.warning(
            "[EMAIL] failed to persist EmailLog (%s trip=%s status=%s): %s",
            event_type, trip_id, status, log_err,
        )
        return False


async def _dispatch(
    db,
    trip_id: int,
    event_type: str,
    email_address: str,
    subject: str,
    html_body: str,
    text_body: str,
) -> None:
    if not email_address:
        return

    if db is None:
        try:
            await asyncio.to_thread(
                _send_email, email_address, subject, html_body, {"message": text_body}
            )
        except Exception as e:
            _log.warning("[EMAIL] exception sending %s to %s: %s", event_type, email_address, e)
        return

    try:
        existing = await db.execute(
            select(EmailLog.id).where(
                EmailLog.trip_id == trip_id,
                EmailLog.event_type == event_type,
                EmailLog.status == "sent",
            )
        )
        if existing.scalar_one_or_none() is not None:
            _log.info("[EMAIL] skipped duplicate %s for trip %s", event_type, trip_id)
            return
    except Exception as lookup_err:
        _log.warning(
            "[EMAIL] idempotency lookup failed for %s trip=%s: %s — sending anyway",
            event_type, trip_id, lookup_err,
        )
        try:
            await db.rollback()
        except Exception:
            pass

    send_error = None
    success = False
    try:
        result = await asyncio.to_thread(
            _send_email, email_address, subject, html_body, {"message": text_body}
        )
        success = bool(result)
        if not success:
            send_error = "email provider returned falsy"
    except Exception as e:
        send_error = str(e)

    if success:
        _log.info("[EMAIL] sent %s to %s", event_type, email_address)
        await _write_log(
            db, trip_id=trip_id, event_type=event_type,
            email_address=email_address, status="sent",
        )
    else:
        _log.warning("[EMAIL] failed %s to %s: %s", event_type, email_address, send_error)
        await _write_log(
            db, trip_id=trip_id, event_type=event_type,
            email_address=email_address, status="failed",
            error_message=send_error,
        )


async def email_guest_welcome(db, trip) -> None:
    try:
        email = _guest_email(trip)
        if not email:
            return
        subject, html, text = _build_welcome(_guest_first_name(trip), _guest_lang(trip))
        await _dispatch(db, trip.id, "welcome", email, subject, html, text)
    except Exception as e:
        _log.warning("[EMAIL] email_guest_welcome failed for trip %s: %s", getattr(trip, "id", "?"), e)


async def email_guest_driver_assigned(db, trip, driver, vehicle) -> None:
    try:
        email = _guest_email(trip)
        if not email:
            return
        driver_name = (
            f"{getattr(driver, 'first_name', '') or ''} {getattr(driver, 'last_name', '') or ''}"
        ).strip() or "your driver"
        subject, html, text = _build_driver_assigned(
            driver_name=driver_name,
            vehicle_year=getattr(vehicle, "year", "") or "",
            vehicle_make=getattr(vehicle, "make", "") or "",
            vehicle_model=getattr(vehicle, "model", "") or "",
            vehicle_color=getattr(vehicle, "color", "") or "",
            vehicle_plate=getattr(vehicle, "plate", None) or getattr(vehicle, "license_plate", "") or "",
            driver_phone=getattr(driver, "phone", "") or "",
            lang=_guest_lang(trip),
        )
        await _dispatch(db, trip.id, "driver_assigned", email, subject, html, text)
    except Exception as e:
        _log.warning("[EMAIL] email_guest_driver_assigned failed for trip %s: %s", getattr(trip, "id", "?"), e)


async def email_guest_driver_en_route(db, trip, driver) -> None:
    try:
        email = _guest_email(trip)
        if not email:
            return
        driver_name = (
            f"{getattr(driver, 'first_name', '') or ''} {getattr(driver, 'last_name', '') or ''}"
        ).strip() or "your driver"
        subject, html, text = _build_driver_en_route(driver_name, _guest_lang(trip))
        await _dispatch(db, trip.id, "driver_en_route", email, subject, html, text)
    except Exception as e:
        _log.warning("[EMAIL] email_guest_driver_en_route failed for trip %s: %s", getattr(trip, "id", "?"), e)


async def email_guest_driver_arrived(db, trip, driver) -> None:
    try:
        email = _guest_email(trip)
        if not email:
            return
        driver_name = (
            f"{getattr(driver, 'first_name', '') or ''} {getattr(driver, 'last_name', '') or ''}"
        ).strip() or "your driver"
        subject, html, text = _build_driver_arrived(driver_name, _guest_lang(trip))
        await _dispatch(db, trip.id, "driver_arrived", email, subject, html, text)
    except Exception as e:
        _log.warning("[EMAIL] email_guest_driver_arrived failed for trip %s: %s", getattr(trip, "id", "?"), e)


async def email_guest_trip_completed(db, trip) -> None:
    try:
        email = _guest_email(trip)
        if not email:
            return
        subject, html, text = _build_trip_completed(_guest_lang(trip))
        await _dispatch(db, trip.id, "trip_completed", email, subject, html, text)
    except Exception as e:
        _log.warning("[EMAIL] email_guest_trip_completed failed for trip %s: %s", getattr(trip, "id", "?"), e)
