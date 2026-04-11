"""Guest rider SMS notifications (Shopify widget "Continue as Guest" flow).

Wraps the Twilio helper in ``email_sms_service._send_sms`` so that callers in
the trip status-transition endpoints can fire-and-forget notifications without
caring about credentials, formatting, or delivery failures. Every public
function is a safe no-op when ``trip.guest_phone`` is missing (registered
riders get their updates via FCM push + in-app, not SMS).

Idempotency + audit: every dispatch writes an ``SmsLog`` row keyed by
``(trip_id, event_type)``. The DB-level UNIQUE constraint on that pair is the
source of truth for "did we already send this?" — we check it before calling
Twilio and also catch IntegrityError as a race-condition safety net.
"""

import asyncio
import logging
import re

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from models.database import SmsLog
from services.email_sms_service import _send_sms

_log = logging.getLogger(__name__)


WELCOME_TEMPLATE = (
    "¡Bienvenido a Cruise, {full_name}! 🚗 Tu ride ya está en nuestro sistema. "
    "Te avisaremos en unos minutos cuando tengas un conductor asignado."
)

DRIVER_ASSIGNED_TEMPLATE = (
    "¡Tu viaje ya tiene conductor asignado! 🎉\n\n"
    "Conductor: {driver_name}\n"
    "Vehículo: {vehicle_year} {vehicle_make} {vehicle_model} ({vehicle_color})\n"
    "Placa: {vehicle_plate}\n"
    "Teléfono: {driver_phone}\n\n"
    "Estará contigo pronto."
)

DRIVER_EN_ROUTE_TEMPLATE = (
    "🚘 Tu conductor {driver_name} ya está en camino hacia tu punto de recogida."
)

DRIVER_ARRIVED_TEMPLATE = (
    "📍 Tu conductor {driver_name} ha llegado al punto de recogida. "
    "¡Te está esperando!"
)

TRIP_COMPLETED_TEMPLATE = (
    "✅ Tu viaje ha sido completado. ¡Gracias por viajar con Cruise! "
    "Para más información visita cruiseinride.com"
)


def _normalize_phone(phone: str) -> str:
    # Twilio needs E.164. We default non-prefixed numbers to US (+1) because
    # Cruise currently only serves Birmingham Metro; revisit if we launch
    # in markets outside North America.
    phone = (phone or "").strip()
    if not phone:
        return ""
    digits = re.sub(r"\D", "", phone)
    if not digits:
        return ""
    # "+11XXXXXXXXXX" bug — frontend prepended +1 to a number that already had a leading 1.
    if len(digits) == 12 and digits.startswith("11"):
        digits = digits[1:]
    if len(digits) == 10:
        return "+1" + digits
    if len(digits) == 11 and digits.startswith("1"):
        return "+" + digits
    return "+" + digits


def _guest_phone(trip) -> str:
    raw = getattr(trip, "guest_phone", None)
    if not raw:
        return ""
    return _normalize_phone(raw)


def _guest_first_name(trip) -> str:
    return (getattr(trip, "guest_first_name", None) or "").strip() or "amig@"


def _guest_last_name(trip) -> str:
    return (getattr(trip, "guest_last_name", None) or "").strip()


async def _write_log(db, *, trip_id, event_type, phone_number, status, twilio_sid=None, error_message=None):
    """Insert an SmsLog row. Returns True if inserted, False if the unique
    constraint already has a row for this (trip_id, event_type)."""
    try:
        row = SmsLog(
            trip_id=trip_id,
            event_type=event_type,
            phone_number=phone_number,
            status=status,
            twilio_sid=twilio_sid,
            error_message=error_message,
        )
        db.add(row)
        await db.commit()
        return True
    except IntegrityError:
        # Unique (trip_id, event_type) already populated by a parallel caller.
        await db.rollback()
        return False
    except Exception as log_err:
        try:
            await db.rollback()
        except Exception:
            pass
        _log.warning(
            "[SMS] failed to persist SmsLog (%s trip=%s status=%s): %s",
            event_type, trip_id, status, log_err,
        )
        return False


async def _dispatch(
    db,
    trip_id: int,
    event_type: str,
    phone_number: str,
    message: str,
) -> None:
    if not phone_number:
        return

    # Without a DB session we cannot enforce idempotency or audit — fall back
    # to a best-effort send so we don't break flows that forget to pass one.
    if db is None:
        try:
            await asyncio.to_thread(_send_sms, phone_number, message)
        except Exception as e:
            _log.warning("[SMS] exception sending %s to %s: %s", event_type, phone_number, e)
        return

    try:
        existing = await db.execute(
            select(SmsLog.id).where(
                SmsLog.trip_id == trip_id,
                SmsLog.event_type == event_type,
                SmsLog.status == "sent",
            )
        )
        if existing.scalar_one_or_none() is not None:
            _log.info("[SMS] skipped duplicate %s for trip %s", event_type, trip_id)
            return
    except Exception as lookup_err:
        _log.warning(
            "[SMS] idempotency lookup failed for %s trip=%s: %s — sending anyway",
            event_type, trip_id, lookup_err,
        )
        try:
            await db.rollback()
        except Exception:
            pass

    twilio_sid = None
    send_error = None
    try:
        # _send_sms is synchronous (Twilio REST client). Offload to a thread
        # so we never block the FastAPI event loop on network I/O.
        result = await asyncio.to_thread(_send_sms, phone_number, message)
        # result may be: a SID string (success), None/False (failure), or
        # legacy True (success, no SID). Normalize to (success, sid).
        if isinstance(result, str) and result:
            twilio_sid = result
        elif result is True:
            twilio_sid = None  # legacy path, success but no SID exposed
        elif not result:
            send_error = "twilio returned no SID"
    except Exception as e:
        send_error = str(e)

    if send_error is None:
        _log.info("[SMS] sent %s to %s", event_type, phone_number)
        await _write_log(
            db,
            trip_id=trip_id,
            event_type=event_type,
            phone_number=phone_number,
            status="sent",
            twilio_sid=twilio_sid,
        )
    else:
        _log.warning("[SMS] failed %s to %s: %s", event_type, phone_number, send_error)
        await _write_log(
            db,
            trip_id=trip_id,
            event_type=event_type,
            phone_number=phone_number,
            status="failed",
            error_message=send_error,
        )


async def notify_guest_welcome(db, trip) -> None:
    phone = _guest_phone(trip)
    if not phone:
        return
    full_name = f"{_guest_first_name(trip)} {_guest_last_name(trip)}".strip()
    message = WELCOME_TEMPLATE.format(full_name=full_name)
    await _dispatch(db, trip.id, "welcome", phone, message)


async def notify_guest_driver_assigned(db, trip, driver, vehicle) -> None:
    phone = _guest_phone(trip)
    if not phone:
        return
    driver_name = (
        f"{getattr(driver, 'first_name', '') or ''} {getattr(driver, 'last_name', '') or ''}"
    ).strip() or "tu conductor"
    message = DRIVER_ASSIGNED_TEMPLATE.format(
        driver_name=driver_name,
        vehicle_year=getattr(vehicle, "year", "") or "",
        vehicle_make=getattr(vehicle, "make", "") or "",
        vehicle_model=getattr(vehicle, "model", "") or "",
        vehicle_color=getattr(vehicle, "color", "") or "",
        vehicle_plate=getattr(vehicle, "plate", None) or getattr(vehicle, "license_plate", "") or "",
        driver_phone=getattr(driver, "phone", "") or "",
    )
    await _dispatch(db, trip.id, "driver_assigned", phone, message)


async def notify_guest_driver_en_route(db, trip, driver) -> None:
    phone = _guest_phone(trip)
    if not phone:
        return
    driver_name = (
        f"{getattr(driver, 'first_name', '') or ''} {getattr(driver, 'last_name', '') or ''}"
    ).strip() or "tu conductor"
    message = DRIVER_EN_ROUTE_TEMPLATE.format(driver_name=driver_name)
    await _dispatch(db, trip.id, "driver_en_route", phone, message)


async def notify_guest_driver_arrived(db, trip, driver) -> None:
    phone = _guest_phone(trip)
    if not phone:
        return
    driver_name = (
        f"{getattr(driver, 'first_name', '') or ''} {getattr(driver, 'last_name', '') or ''}"
    ).strip() or "tu conductor"
    message = DRIVER_ARRIVED_TEMPLATE.format(driver_name=driver_name)
    await _dispatch(db, trip.id, "driver_arrived", phone, message)


async def notify_guest_trip_completed(db, trip) -> None:
    phone = _guest_phone(trip)
    if not phone:
        return
    await _dispatch(db, trip.id, "trip_completed", phone, TRIP_COMPLETED_TEMPLATE)
