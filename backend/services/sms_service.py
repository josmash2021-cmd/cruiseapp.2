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


# ═══════════════ Bilingual templates ═══════════════
# Keep each message under ~320 chars so carriers don't split (soft limit 160 but
# multi-part SMS is widely supported; aim for 1-2 parts).

_TPL = {
    "welcome": {
        "en": (
            "Cruise: Booking confirmed, {first_name}. We're matching you with "
            "a nearby driver. Ride #{tid} · {pickup} → {dropoff}. "
            "You'll get a text the moment your driver is assigned."
        ),
        "es": (
            "Cruise: Reserva confirmada, {first_name}. Estamos buscando un "
            "conductor cerca de ti. Viaje #{tid} · {pickup} → {dropoff}. "
            "Te avisaremos cuando se asigne tu conductor."
        ),
    },
    "driver_assigned": {
        "en": (
            "Cruise: Driver found! {driver_name} is coming in a {vehicle_color} "
            "{vehicle_year} {vehicle_make} {vehicle_model} · plate {vehicle_plate}. "
            "Call/text {driver_phone} if needed. Ride #{tid}."
        ),
        "es": (
            "Cruise: ¡Conductor encontrado! {driver_name} llegará en un "
            "{vehicle_make} {vehicle_model} {vehicle_color} {vehicle_year} · "
            "placa {vehicle_plate}. Contacto: {driver_phone}. Viaje #{tid}."
        ),
    },
    "driver_en_route": {
        "en": (
            "Cruise: {driver_name} is on the way to your pickup at {pickup}. "
            "Please be ready — ride #{tid}."
        ),
        "es": (
            "Cruise: {driver_name} va en camino a tu recogida en {pickup}. "
            "Prepárate — viaje #{tid}."
        ),
    },
    "driver_arrived": {
        "en": (
            "Cruise: {driver_name} has arrived at your pickup. Look for the "
            "{vehicle_color} vehicle · plate {vehicle_plate}. Ride #{tid}."
        ),
        "es": (
            "Cruise: {driver_name} ha llegado a tu recogida. Busca el vehículo "
            "{vehicle_color} · placa {vehicle_plate}. Viaje #{tid}."
        ),
    },
    "trip_completed": {
        "en": (
            "Cruise: Trip completed — thanks for riding with us! Total: {fare}. "
            "Rate your driver at cruiseinride.com. See you next time."
        ),
        "es": (
            "Cruise: Viaje completado — ¡gracias por viajar con nosotros! "
            "Total: {fare}. Califica a tu conductor en cruiseinride.com."
        ),
    },
    "no_driver_refund": {
        "en": (
            "Cruise: Sorry, no driver was available. Your payment has been "
            "fully refunded (5-10 business days). Please try again or schedule "
            "in advance. We apologize for the inconvenience."
        ),
        "es": (
            "Cruise: Lo sentimos, no encontramos conductor disponible. Te "
            "reembolsamos el total (5-10 días hábiles). Intenta de nuevo o "
            "programa con anticipación. Disculpa las molestias."
        ),
    },
    "no_driver_no_charge": {
        "en": (
            "Cruise: Sorry, no driver was available. No charge was processed "
            "(any hold clears in 1-3 days). Please try again in a few minutes."
        ),
        "es": (
            "Cruise: Lo sentimos, no encontramos conductor disponible. No se "
            "te cobró nada (una retención se libera en 1-3 días). Intenta de nuevo."
        ),
    },
}


def _pick(event: str, lang: str) -> str:
    bucket = _TPL.get(event) or {}
    return bucket.get(lang) or bucket.get("en") or ""


def _guest_lang(trip) -> str:
    v = (getattr(trip, "guest_lang", None) or "").strip().lower()
    return "es" if v == "es" else "en"


def _trip_id_short(trip) -> str:
    return str(getattr(trip, "id", "") or "")


def _trip_pickup_short(trip) -> str:
    raw = (getattr(trip, "pickup_address", None) or "").strip()
    if not raw:
        return "—"
    # Keep SMS lean — take just the street portion (everything before the first comma).
    return raw.split(",")[0][:60]


def _trip_dropoff_short(trip) -> str:
    raw = (getattr(trip, "dropoff_address", None) or "").strip()
    if not raw:
        return "—"
    return raw.split(",")[0][:60]


def _trip_fare(trip) -> str:
    fare = getattr(trip, "fare", None)
    if fare is None or fare <= 0:
        return "—"
    try:
        return f"${float(fare):.2f}"
    except Exception:
        return "—"


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


def _driver_name(driver, lang: str) -> str:
    name = (
        f"{getattr(driver, 'first_name', '') or ''} "
        f"{getattr(driver, 'last_name', '') or ''}"
    ).strip()
    if name:
        return name
    return "tu conductor" if lang == "es" else "your driver"


async def notify_guest_welcome(db, trip) -> None:
    raw = getattr(trip, "guest_phone", None)
    phone = _guest_phone(trip)
    _log.info(
        "[SMS] notify_guest_welcome trip=%s raw_phone=%r normalized=%r",
        getattr(trip, "id", "?"), raw, phone,
    )
    if not phone:
        return
    lang = _guest_lang(trip)
    message = _pick("welcome", lang).format(
        first_name=_guest_first_name(trip),
        tid=_trip_id_short(trip),
        pickup=_trip_pickup_short(trip),
        dropoff=_trip_dropoff_short(trip),
    )
    await _dispatch(db, trip.id, "welcome", phone, message)


async def notify_guest_driver_assigned(db, trip, driver, vehicle) -> None:
    phone = _guest_phone(trip)
    if not phone:
        return
    lang = _guest_lang(trip)
    message = _pick("driver_assigned", lang).format(
        driver_name=_driver_name(driver, lang),
        vehicle_year=getattr(vehicle, "year", "") or "",
        vehicle_make=getattr(vehicle, "make", "") or "",
        vehicle_model=getattr(vehicle, "model", "") or "",
        vehicle_color=getattr(vehicle, "color", "") or "",
        vehicle_plate=getattr(vehicle, "plate", None) or getattr(vehicle, "license_plate", "") or "—",
        driver_phone=getattr(driver, "phone", "") or "—",
        tid=_trip_id_short(trip),
    )
    await _dispatch(db, trip.id, "driver_assigned", phone, message)


async def notify_guest_driver_en_route(db, trip, driver) -> None:
    phone = _guest_phone(trip)
    if not phone:
        return
    lang = _guest_lang(trip)
    message = _pick("driver_en_route", lang).format(
        driver_name=_driver_name(driver, lang),
        pickup=_trip_pickup_short(trip),
        tid=_trip_id_short(trip),
    )
    await _dispatch(db, trip.id, "driver_en_route", phone, message)


async def notify_guest_driver_arrived(db, trip, driver, vehicle=None) -> None:
    phone = _guest_phone(trip)
    if not phone:
        return
    lang = _guest_lang(trip)
    message = _pick("driver_arrived", lang).format(
        driver_name=_driver_name(driver, lang),
        vehicle_color=(getattr(vehicle, "color", "") or "—") if vehicle else "—",
        vehicle_plate=((getattr(vehicle, "plate", None) or getattr(vehicle, "license_plate", "")) or "—") if vehicle else "—",
        tid=_trip_id_short(trip),
    )
    await _dispatch(db, trip.id, "driver_arrived", phone, message)


async def notify_guest_trip_completed(db, trip) -> None:
    phone = _guest_phone(trip)
    if not phone:
        return
    lang = _guest_lang(trip)
    message = _pick("trip_completed", lang).format(
        fare=_trip_fare(trip),
    )
    await _dispatch(db, trip.id, "trip_completed", phone, message)


async def notify_guest_no_driver(db, trip, refunded: bool = False) -> None:
    phone = _guest_phone(trip)
    if not phone:
        return
    lang = _guest_lang(trip)
    key = "no_driver_refund" if refunded else "no_driver_no_charge"
    message = _pick(key, lang)
    await _dispatch(db, trip.id, "no_driver", phone, message)
