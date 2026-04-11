"""Guest rider EMAIL notifications — mirror of services/sms_service.py.

Sends the same 5 lifecycle events as the SMS service (welcome, driver_assigned,
driver_en_route, driver_arrived, trip_completed) via the email provider helper
in ``email_sms_service._send_email``. Every public function is a safe no-op
when ``trip.guest_email`` is missing.

Idempotency + audit: each dispatch writes an ``EmailLog`` row keyed by
``(trip_id, event_type)``. The DB UNIQUE constraint prevents duplicates.
We use a separate ``email_log`` table (rather than extending ``sms_log``)
so existing SMS logic, queries, and back-office reports stay untouched.
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
BRAND_BG = "#05060a"
BRAND_CARD = "#0b0c10"
BRAND_TEXT = "#f5f5f5"
BRAND_MUTED = "#9ba4b4"


def _shell(title: str, body_html: str) -> str:
    return f"""<!DOCTYPE html>
<html lang="es"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>{title}</title></head>
<body style="margin:0;padding:0;background:{BRAND_BG};font-family:'Poppins',system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:{BRAND_TEXT};">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:{BRAND_BG};padding:40px 14px;">
<tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:{BRAND_CARD};border-radius:18px;overflow:hidden;border:1px solid rgba(232,197,71,.22);box-shadow:0 0 0 1px rgba(232,197,71,.08),0 12px 40px rgba(232,197,71,.18),0 24px 80px rgba(232,197,71,.12),0 40px 120px rgba(0,0,0,.6);">
<tr><td align="center" style="padding:30px 30px 24px;border-bottom:1px solid rgba(232,197,71,.14);background:linear-gradient(180deg,rgba(232,197,71,.06) 0%,rgba(232,197,71,0) 100%);">
<table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center"><tr>
<td style="vertical-align:middle;padding-right:14px;">
<div style="width:56px;height:56px;border-radius:50%;border:2.5px solid {BRAND_GOLD};background:#000;display:inline-block;text-align:center;line-height:0;box-shadow:0 0 0 4px rgba(232,197,71,.08),0 6px 22px rgba(232,197,71,.25);">
<svg xmlns="http://www.w3.org/2000/svg" width="34" height="34" viewBox="0 0 64 64" style="display:inline-block;vertical-align:middle;margin-top:10px;">
<path fill="{BRAND_GOLD}" d="M52.5 30.2l-2.8-8.4c-.7-2-2.5-3.4-4.6-3.4H18.9c-2.1 0-3.9 1.4-4.6 3.4l-2.8 8.4c-1.4.6-2.3 1.9-2.3 3.4v11c0 1.1.9 2 2 2h2.3c1.1 0 2-.9 2-2v-2h32.9v2c0 1.1.9 2 2 2h2.3c1.1 0 2-.9 2-2v-11c.1-1.5-.9-2.8-2.2-3.4zM18.9 22h26.2l2.7 8H16.2l2.7-8zM17.5 39.5c-1.4 0-2.5-1.1-2.5-2.5s1.1-2.5 2.5-2.5 2.5 1.1 2.5 2.5-1.1 2.5-2.5 2.5zm29 0c-1.4 0-2.5-1.1-2.5-2.5s1.1-2.5 2.5-2.5 2.5 1.1 2.5 2.5-1.1 2.5-2.5 2.5z"/>
</svg>
</div>
</td>
<td style="vertical-align:middle;">
<div style="font-size:30px;font-weight:900;letter-spacing:3px;color:{BRAND_GOLD};font-family:Georgia,'Times New Roman',serif;text-shadow:0 0 20px rgba(232,197,71,.35);">CRUISE</div>
</td>
</tr></table>
</td></tr>
<tr><td style="padding:28px;">{body_html}</td></tr>
<tr><td align="center" style="padding:22px 30px 10px;border-top:1px solid rgba(232,197,71,.12);">
<a href="https://cruiseinride.com" style="display:inline-block;padding:11px 24px;background:rgba(232,197,71,.1);border:1px solid rgba(232,197,71,.38);border-radius:999px;color:{BRAND_GOLD};font-size:13px;font-weight:700;text-decoration:none;letter-spacing:.02em;">Visita cruiseinride.com →</a>
</td></tr>
<tr><td style="padding:12px 30px 22px;font-size:11px;color:{BRAND_MUTED};text-align:center;line-height:1.5;">
Recibiste este correo porque reservaste un viaje con Cruise.
</td></tr>
</table></td></tr></table></body></html>"""


def _h1(text: str) -> str:
    return f'<h1 style="margin:0 0 14px 0;font-size:24px;font-weight:800;color:{BRAND_GOLD};letter-spacing:-.01em;text-shadow:0 0 18px rgba(232,197,71,.2);">{text}</h1>'


def _p(text: str) -> str:
    return f'<p style="margin:0 0 14px 0;font-size:15px;line-height:1.55;color:rgba(245,230,180,.92);">{text}</p>'


def _kv_row(label: str, value: str) -> str:
    return (
        f'<tr><td style="padding:8px 0;font-size:13px;color:{BRAND_MUTED};width:38%;">{label}</td>'
        f'<td style="padding:8px 0;font-size:14px;color:{BRAND_TEXT};font-weight:600;">{value}</td></tr>'
    )


def _build_welcome(first_name: str) -> tuple[str, str, str]:
    subject = f"¡Bienvenido a Cruise, {first_name}! 🚗"
    body = _h1(f"¡Bienvenido, {first_name}!") + _p(
        "Tu viaje ya está en nuestro sistema. Te avisaremos en unos minutos cuando "
        "tengas un conductor asignado."
    ) + _p("Gracias por elegir Cruise.")
    text = (
        f"¡Bienvenido a Cruise, {first_name}!\n\n"
        "Tu viaje ya está en nuestro sistema. Te avisaremos en unos minutos cuando "
        "tengas un conductor asignado.\n\nGracias por elegir Cruise."
    )
    return subject, _shell(subject, body), text


def _build_driver_assigned(driver_name, vehicle_year, vehicle_make, vehicle_model,
                           vehicle_color, vehicle_plate, driver_phone) -> tuple[str, str, str]:
    subject = "Tu conductor está asignado"
    rows = (
        _kv_row("Conductor", driver_name)
        + _kv_row("Vehículo", f"{vehicle_year} {vehicle_make} {vehicle_model}".strip())
        + _kv_row("Color", vehicle_color or "—")
        + _kv_row("Placa", vehicle_plate or "—")
        + _kv_row("Teléfono", driver_phone or "—")
    )
    body = (
        _h1("¡Conductor asignado! 🎉")
        + _p("Tu viaje ya tiene conductor. Aquí están los detalles:")
        + f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" '
          f'style="border-collapse:collapse;border-top:1px solid #1f2940;border-bottom:1px solid #1f2940;margin:8px 0 16px;">{rows}</table>'
        + _p("Estará contigo pronto.")
    )
    text = (
        "¡Tu viaje ya tiene conductor asignado!\n\n"
        f"Conductor: {driver_name}\n"
        f"Vehículo: {vehicle_year} {vehicle_make} {vehicle_model} ({vehicle_color})\n"
        f"Placa: {vehicle_plate}\n"
        f"Teléfono: {driver_phone}\n\nEstará contigo pronto."
    )
    return subject, _shell(subject, body), text


def _build_driver_en_route(driver_name: str) -> tuple[str, str, str]:
    subject = "Tu conductor va en camino"
    body = _h1("Tu conductor va en camino 🚘") + _p(
        f"<strong>{driver_name}</strong> ya está en camino hacia tu punto de recogida."
    )
    text = f"Tu conductor {driver_name} ya está en camino hacia tu punto de recogida."
    return subject, _shell(subject, body), text


def _build_driver_arrived(driver_name: str) -> tuple[str, str, str]:
    subject = "Tu conductor ha llegado"
    body = _h1("Tu conductor ha llegado 📍") + _p(
        f"<strong>{driver_name}</strong> ha llegado al punto de recogida y te está esperando."
    )
    text = f"Tu conductor {driver_name} ha llegado al punto de recogida. ¡Te está esperando!"
    return subject, _shell(subject, body), text


def _build_trip_completed() -> tuple[str, str, str]:
    subject = "Tu viaje ha sido completado — gracias"
    body = (
        _h1("Viaje completado ✅")
        + _p("¡Gracias por viajar con Cruise!")
        + _p('Para más información visita <a href="https://cruiseinride.com" '
             f'style="color:{BRAND_GOLD};text-decoration:none;">cruiseinride.com</a>.')
    )
    text = (
        "Tu viaje ha sido completado. ¡Gracias por viajar con Cruise!\n"
        "Para más información visita cruiseinride.com"
    )
    return subject, _shell(subject, body), text


def _guest_email(trip) -> str:
    raw = (getattr(trip, "guest_email", None) or "").strip().lower()
    if not raw or not _EMAIL_RE.match(raw):
        return ""
    return raw


def _guest_first_name(trip) -> str:
    return (getattr(trip, "guest_first_name", None) or "").strip() or "amig@"


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
            db,
            trip_id=trip_id,
            event_type=event_type,
            email_address=email_address,
            status="sent",
        )
    else:
        _log.warning("[EMAIL] failed %s to %s: %s", event_type, email_address, send_error)
        await _write_log(
            db,
            trip_id=trip_id,
            event_type=event_type,
            email_address=email_address,
            status="failed",
            error_message=send_error,
        )


async def email_guest_welcome(db, trip) -> None:
    try:
        email = _guest_email(trip)
        if not email:
            return
        subject, html, text = _build_welcome(_guest_first_name(trip))
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
        ).strip() or "tu conductor"
        subject, html, text = _build_driver_assigned(
            driver_name=driver_name,
            vehicle_year=getattr(vehicle, "year", "") or "",
            vehicle_make=getattr(vehicle, "make", "") or "",
            vehicle_model=getattr(vehicle, "model", "") or "",
            vehicle_color=getattr(vehicle, "color", "") or "",
            vehicle_plate=getattr(vehicle, "plate", None) or getattr(vehicle, "license_plate", "") or "",
            driver_phone=getattr(driver, "phone", "") or "",
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
        ).strip() or "tu conductor"
        subject, html, text = _build_driver_en_route(driver_name)
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
        ).strip() or "tu conductor"
        subject, html, text = _build_driver_arrived(driver_name)
        await _dispatch(db, trip.id, "driver_arrived", email, subject, html, text)
    except Exception as e:
        _log.warning("[EMAIL] email_guest_driver_arrived failed for trip %s: %s", getattr(trip, "id", "?"), e)


async def email_guest_trip_completed(db, trip) -> None:
    try:
        email = _guest_email(trip)
        if not email:
            return
        subject, html, text = _build_trip_completed()
        await _dispatch(db, trip.id, "trip_completed", email, subject, html, text)
    except Exception as e:
        _log.warning("[EMAIL] email_guest_trip_completed failed for trip %s: %s", getattr(trip, "id", "?"), e)
