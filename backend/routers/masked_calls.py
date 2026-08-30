"""Masked (proxied) rider<->driver voice calls via a Twilio <Dial> bridge.

Flow
----
1. The app calls ``GET /trips/{trip_id}/masked-contact?role=rider|driver``
   (authenticated). The server validates that the caller is a party to the
   trip and that the trip is active, then returns the company's Twilio number
   plus a short-lived 6-digit extension code. The counterparty's real number
   is NEVER returned.
2. The app dials ``tel:<twilio_number>,,,<extension>`` — the commas make the
   phone send the extension as DTMF once the call connects.
3. Twilio hits the voice webhook ``POST /voice/bridge`` which collects the
   extension (buffered DTMF or a spoken/typed prompt fallback), looks it up,
   re-validates the trip, and bridges the call with
   ``<Dial callerId=<twilio_number>>`` to the counterparty's real number.
   Neither side ever sees the other's real number: both see the Twilio number.

Twilio console configuration required
-------------------------------------
- Buy/provision a DEDICATED Twilio number for masked calls and set its env var
  ``TWILIO_PROXY_PHONE_NUMBER`` (falls back to ``TWILIO_PHONE_NUMBER`` if
  unset, but reusing the support IVR number will break the support line
  because a number can only have one voice webhook).
- In the Twilio console, on that number, set:
      Voice & Fax -> "A call comes in" -> Webhook:
      POST {PUBLIC_URL}/voice/bridge
- That's it — no TwiML App, no Proxy product needed. The same
  ``TWILIO_ACCOUNT_SID`` / ``TWILIO_AUTH_TOKEN`` are used for signature
  validation (``X-Twilio-Signature``), same as routers/voice.py.

NOTE: extension codes are kept in an in-memory TTLCache (same pattern as the
voice sessions in routers/voice.py). That assumes a single-process backend;
if the deployment ever scales to multiple workers, move ``_bridge_codes`` to
Redis.

Callback calling ("we call you") — newer app builds
---------------------------------------------------
Newer builds never open the dialer: the app POSTs
``/trips/{trip_id}/callback-call?role=...``, the server places an OUTBOUND
Twilio call to the caller's registered number, and when they answer, the
``POST /voice/callback?token=...`` webhook answers that leg with TwiML that
<Dial>s the counterparty. No extension to display or type — the caller is
authenticated by the fact that WE called their registered number. The
extension flow above stays live for older app builds.
"""

import asyncio
import logging
import re
import secrets
from xml.sax.saxutils import escape as _xml_escape

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import Response
from sqlalchemy.ext.asyncio import AsyncSession

from config import (
    PUBLIC_URL,
    TWILIO_ACCOUNT_SID,
    TWILIO_AUTH_TOKEN,
    TWILIO_PHONE_NUMBER,
    TWILIO_PROXY_PHONE_NUMBER,
)
from models.database import get_db, Trip, User
from routers.voice import _validate_twilio_sig
from utils.bounded_cache import TTLCache
from utils.security import _get_current_user, _verify_api_key

router = APIRouter()

_log = logging.getLogger(__name__)

# Number the app dials + the callerId both sides see.
_MASKED_NUMBER = TWILIO_PROXY_PHONE_NUMBER or TWILIO_PHONE_NUMBER

_EXTENSION_TTL_SECONDS = 15 * 60  # 15 minutes
# extension code -> {"trip_id": int, "role": "rider"|"driver"}
_bridge_codes: TTLCache[str, dict] = TTLCache(
    ttl_seconds=_EXTENSION_TTL_SECONDS, max_size=5000, name="masked_call_codes",
)

# Trip statuses where a rider<->driver call makes sense. Mirrors
# trips._ACTIVE_TRIP_STATUSES plus "scheduled" so a driver can call the rider
# ahead of an upcoming scheduled pickup.
_CALLABLE_TRIP_STATUSES = {
    "requested", "accepted", "driver_en_route", "driver_arriving",
    "arrived", "driver_arrived", "in_trip", "in_progress",
    "rider_onboard", "on_trip", "en_route_to_pickup",
    "scheduled", "scheduled_accepted", "scheduled_active",
}


def _digits(phone: str) -> str:
    return re.sub(r"\D", "", phone or "")


def _same_number(a: str, b: str) -> bool:
    """Loose E.164-ish comparison on the trailing 10 digits (US market)."""
    da, db = _digits(a), _digits(b)
    return bool(da) and bool(db) and da[-10:] == db[-10:]


def _mask(phone: str) -> str:
    """Last-4-only rendering for logs — never log a full phone number."""
    d = _digits(phone)
    return f"***{d[-4:]}" if d else "***"


def _twiml_gather_extension() -> str:
    """Prompt for the 6-digit extension. If the dialer already sent the code
    as DTMF (tel:...,,<code>), Twilio buffers the digits and the <Gather>
    completes immediately without the caller hearing the whole prompt."""
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<Response>"
        '<Gather input="dtmf" numDigits="6" timeout="10" action="/voice/bridge" method="POST">'
        '<Say voice="Google.es-US-Studio-B" language="es-US">'
        "Conectando tu llamada. Si se solicita, ingresa tu c&#243;digo de 6 d&#237;gitos."
        "</Say>"
        '<Say voice="Google.en-US-Studio-O" language="en-US">'
        "Connecting your call. If asked, enter your 6 digit code."
        "</Say>"
        "</Gather>"
        '<Say voice="Google.en-US-Studio-O" language="en-US">'
        "We did not receive a code. Please try again from the app."
        "</Say>"
        "<Hangup/>"
        "</Response>"
    )


def _twiml_reject(message_en: str, message_es: str) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<Response>"
        f'<Say voice="Google.es-US-Studio-B" language="es-US">{_xml_escape(message_es)}</Say>'
        f'<Say voice="Google.en-US-Studio-O" language="en-US">{_xml_escape(message_en)}</Say>'
        "<Hangup/>"
        "</Response>"
    )


async def _resolve_party_phone(db: AsyncSession, trip: Trip, side: str) -> str:
    """Return the phone of one side of the trip.

    side="counterparty" -> the person being called; side="caller" handled by
    the caller verification below. Guest trips (no rider_id) resolve the
    rider side to ``trip.guest_phone``.
    """
    if side == "driver":
        if not trip.driver_id:
            return ""
        driver = await db.get(User, trip.driver_id)
        return (driver.phone or "") if driver else ""
    # rider side (registered rider or guest)
    if trip.rider_id:
        rider = await db.get(User, trip.rider_id)
        return (rider.phone or "") if rider else ""
    return (trip.guest_phone or "")


@router.get("/trips/{trip_id}/masked-contact", dependencies=[Depends(_verify_api_key)])
async def get_masked_contact(
    trip_id: int,
    role: str = Query(..., pattern="^(rider|driver)$"),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Return the masked-call number + a short-lived extension for this trip.

    ``role`` is the CALLER's role. The response never contains the
    counterparty's real phone number.
    """
    if not _MASKED_NUMBER:
        raise HTTPException(503, "Masked calling is not configured")

    trip = await db.get(Trip, trip_id)
    if not trip:
        raise HTTPException(404, "Trip not found")

    # The caller must be the trip party matching the claimed role.
    party_id = trip.rider_id if role == "rider" else trip.driver_id
    if not party_id or party_id != user.id:
        raise HTTPException(403, "You are not a party to this trip")

    if (trip.status or "") not in _CALLABLE_TRIP_STATUSES:
        raise HTTPException(409, "Trip is not active")

    counterparty_side = "driver" if role == "rider" else "rider"
    counterparty_phone = await _resolve_party_phone(db, trip, counterparty_side)
    if not counterparty_phone:
        raise HTTPException(404, "The other party has no phone number on file")

    code = f"{secrets.randbelow(1000000):06d}"
    _bridge_codes[code] = {"trip_id": trip.id, "role": role}
    _log.info(
        "[MaskedCall] issued extension for trip=%s role=%s caller=%s",
        trip.id, role, _mask(user.phone or ""),
    )
    return {
        "phone_number": _MASKED_NUMBER,
        "extension": code,
        "expires_in": _EXTENSION_TTL_SECONDS,
    }


@router.post("/voice/bridge")
async def voice_bridge(request: Request, db: AsyncSession = Depends(get_db)):
    """Twilio voice webhook for the masked-call number.

    Configure on the Twilio number: Voice -> "A call comes in" ->
    Webhook POST {PUBLIC_URL}/voice/bridge.
    """
    form = await request.form()
    _validate_twilio_sig(
        str(request.url), dict(form), request.headers.get("X-Twilio-Signature", ""),
    )

    digits = (form.get("Digits") or "").strip()
    if not digits:
        return Response(content=_twiml_gather_extension(), media_type="application/xml")

    entry = _bridge_codes.get(digits)
    if not entry:
        _log.info("[MaskedCall] rejected: unknown/expired extension")
        return Response(
            content=_twiml_reject(
                "This call code is invalid or has expired. Please try again from the app.",
                "Este c&#243;digo es inv&#225;lido o expir&#243;. Int&#233;ntalo de nuevo desde la app.",
            ),
            media_type="application/xml",
        )

    trip = await db.get(Trip, entry["trip_id"])
    if not trip or (trip.status or "") not in _CALLABLE_TRIP_STATUSES:
        _log.info("[MaskedCall] rejected: trip=%s no longer active", entry["trip_id"])
        return Response(
            content=_twiml_reject(
                "This trip is no longer active. Goodbye.",
                "Este viaje ya no est&#225; activo. Adi&#243;s.",
            ),
            media_type="application/xml",
        )

    role = entry["role"]
    counterparty_side = "driver" if role == "rider" else "rider"
    target = await _resolve_party_phone(db, trip, counterparty_side)
    if not target:
        return Response(
            content=_twiml_reject(
                "The other party cannot be reached by phone. Goodbye.",
                "La otra persona no est&#225; disponible por tel&#233;fono. Adi&#243;s.",
            ),
            media_type="application/xml",
        )

    # Verify the caller is the party the extension was issued to. When the
    # party has no phone on file we cannot verify — the random, short-lived
    # extension is the credential in that case.
    expected_caller = await _resolve_party_phone(db, trip, role)
    caller = form.get("From", "")
    if expected_caller and not _same_number(caller, expected_caller):
        _log.warning(
            "[MaskedCall] rejected: caller %s does not match trip=%s role=%s",
            _mask(caller), trip.id, role,
        )
        return Response(
            content=_twiml_reject(
                "This call cannot be completed. Please call from your registered phone.",
                "No se puede completar la llamada. Llama desde tu n&#250;mero registrado.",
            ),
            media_type="application/xml",
        )

    _log.info(
        "[MaskedCall] bridging trip=%s role=%s -> %s",
        trip.id, role, _mask(target),
    )
    twiml = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<Response>"
        f'<Dial callerId="{_xml_escape(_MASKED_NUMBER)}" timeout="25">'
        f"{_xml_escape(target)}"
        "</Dial>"
        "</Response>"
    )
    return Response(content=twiml, media_type="application/xml")


# ── Callback calling ("we call you") ──────────────────────────────────────
#
# The app never opens the dialer: it POSTs here, we have Twilio ring the
# CALLER's registered number, and /voice/callback bridges the answered leg
# to the counterparty. No extension, no DTMF — nothing ugly in the dialer.

_CALLBACK_TOKEN_TTL_SECONDS = 120  # one Twilio fetch, then it's dead weight
# opaque token -> {"trip_id": int, "role": "rider"|"driver"}
_callback_tokens: TTLCache[str, dict] = TTLCache(
    ttl_seconds=_CALLBACK_TOKEN_TTL_SECONDS, max_size=5000,
    name="masked_call_callbacks",
)


@router.post("/trips/{trip_id}/callback-call", dependencies=[Depends(_verify_api_key)])
async def start_callback_call(
    trip_id: int,
    role: str = Query(..., pattern="^(rider|driver)$"),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Ring the caller's registered phone, then bridge to the counterparty.

    Same guards as get_masked_contact. The response never contains real
    phone numbers — just {"status": "calling"}.
    """
    if not _MASKED_NUMBER or not TWILIO_ACCOUNT_SID or not TWILIO_AUTH_TOKEN:
        raise HTTPException(503, "Masked calling is not configured")

    trip = await db.get(Trip, trip_id)
    if not trip:
        raise HTTPException(404, "Trip not found")

    # The caller must be the trip party matching the claimed role.
    party_id = trip.rider_id if role == "rider" else trip.driver_id
    if not party_id or party_id != user.id:
        raise HTTPException(403, "You are not a party to this trip")

    if (trip.status or "") not in _CALLABLE_TRIP_STATUSES:
        raise HTTPException(409, "Trip is not active")

    caller_phone = await _resolve_party_phone(db, trip, role)
    if not caller_phone:
        raise HTTPException(404, "Your account has no phone number on file")

    counterparty_side = "driver" if role == "rider" else "rider"
    counterparty_phone = await _resolve_party_phone(db, trip, counterparty_side)
    if not counterparty_phone:
        raise HTTPException(404, "The other party has no phone number on file")

    token = secrets.token_urlsafe(16)
    _callback_tokens[token] = {"trip_id": trip.id, "role": role}

    def _place_call():
        from twilio.rest import Client as TwilioClient
        client = TwilioClient(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN)
        return client.calls.create(
            to=caller_phone,
            from_=_MASKED_NUMBER,
            url=f"{PUBLIC_URL}/voice/callback?token={token}",
            timeout=20,
        )

    try:
        # The Twilio SDK is synchronous — keep it off the event loop.
        call = await asyncio.to_thread(_place_call)
    except Exception as e:
        _callback_tokens.pop(token, None)
        _log.warning("[MaskedCall] callback create failed for trip=%s: %s", trip.id, e)
        raise HTTPException(502, "Could not place the call")

    _log.info(
        "[MaskedCall] callback sid=%s trip=%s role=%s caller=%s",
        getattr(call, "sid", "?"), trip.id, role, _mask(caller_phone),
    )
    return {"status": "calling"}


@router.post("/voice/callback")
async def voice_callback(
    request: Request,
    token: str = Query(default=""),
    db: AsyncSession = Depends(get_db),
):
    """TwiML webhook for the callback leg we placed to the caller.

    Configure nothing in Twilio — calls.create() passes this URL per call.
    """
    form = await request.form()
    _validate_twilio_sig(
        str(request.url), dict(form), request.headers.get("X-Twilio-Signature", ""),
    )

    # One-shot: the token is consumed by the first (and only) TwiML fetch.
    entry = _callback_tokens.pop(token, None) if token else None
    if not entry:
        _log.info("[MaskedCall] callback rejected: unknown/expired token")
        return Response(
            content=_twiml_reject(
                "This call link is invalid or has expired. Please try again from the app.",
                "Este enlace de llamada es inv&#225;lido o expir&#243;. Int&#233;ntalo de nuevo desde la app.",
            ),
            media_type="application/xml",
        )

    trip = await db.get(Trip, entry["trip_id"])
    if not trip or (trip.status or "") not in _CALLABLE_TRIP_STATUSES:
        _log.info("[MaskedCall] callback rejected: trip=%s no longer active", entry["trip_id"])
        return Response(
            content=_twiml_reject(
                "This trip is no longer active. Goodbye.",
                "Este viaje ya no est&#225; activo. Adi&#243;s.",
            ),
            media_type="application/xml",
        )

    role = entry["role"]
    counterparty_side = "driver" if role == "rider" else "rider"
    target = await _resolve_party_phone(db, trip, counterparty_side)
    if not target:
        return Response(
            content=_twiml_reject(
                "The other party cannot be reached by phone. Goodbye.",
                "La otra persona no est&#225; disponible por tel&#233;fono. Adi&#243;s.",
            ),
            media_type="application/xml",
        )

    _log.info(
        "[MaskedCall] callback bridging trip=%s role=%s -> %s",
        trip.id, role, _mask(target),
    )
    twiml = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<Response>"
        '<Say voice="Google.es-US-Studio-B" language="es-US">Conectando.</Say>'
        '<Say voice="Google.en-US-Studio-O" language="en-US">Connecting.</Say>'
        f'<Dial callerId="{_xml_escape(_MASKED_NUMBER)}" timeout="25">'
        f"{_xml_escape(target)}"
        "</Dial>"
        "</Response>"
    )
    return Response(content=twiml, media_type="application/xml")
