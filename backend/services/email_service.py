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

# ═══════════════ Brand ═══════════════
BRAND_GOLD = "#E8C547"
BRAND_GOLD_LIGHT = "#F5DC7A"
BRAND_GOLD_DARK = "#B08800"
BRAND_BG = "#000000"
BRAND_SURFACE = "#0d0d0d"
BRAND_TEXT_SOFT = "#d9c98b"
BRAND_MUTED = "#8a7e4e"
BRAND_BORDER = "rgba(232,197,71,.22)"

LOGO_URL = "https://cdn.shopify.com/s/files/1/0805/8640/8191/files/Untitled_design_069defa2-9e36-4d98-831f-f776d4c6f7a5.png?v=1772961171"
SUPPORT_EMAIL = "support@cruiseinride.com"
SUPPORT_PHONE = "+1 (205) 555-0100"  # placeholder — update if needed


# ═══════════════ Shell / Layout helpers ═══════════════

def _shell(title: str, preheader: str, body_html: str) -> str:
    """Premium email shell with logo header, body, footer, social links."""
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
  @media (max-width: 480px) {{
    .card {{ border-radius: 14px !important; }}
    .pad-lg {{ padding: 24px 22px !important; }}
    .h1 {{ font-size: 22px !important; }}
    .big-pill {{ font-size: 13px !important; padding: 12px 20px !important; }}
  }}
</style>
</head>
<body bgcolor="#000000" style="margin:0;padding:0;background:#000000 !important;font-family:'Poppins','Helvetica Neue',Helvetica,Arial,sans-serif;color:#E8C547;">
<!-- Preheader (hidden in most clients) -->
<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;visibility:hidden;opacity:0;font-size:1px;line-height:1px;color:#000;">{preheader}</div>

<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#000000" style="background-color:#000000 !important;padding:40px 14px;">
<tr><td align="center" bgcolor="#000000">

<!-- Main card -->
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#000000" class="card" style="max-width:580px;background-color:#000000 !important;border-radius:20px;border:1px solid rgba(232,197,71,.28);box-shadow:0 0 0 1px rgba(232,197,71,.08),0 12px 40px rgba(232,197,71,.16),0 40px 120px rgba(0,0,0,.85);">

<!-- Header -->
<tr><td align="center" bgcolor="#000000" style="padding:38px 30px 22px;border-bottom:1px solid rgba(232,197,71,.18);">
<img src="{LOGO_URL}" alt="Cruise" width="68" height="68" style="display:block;width:68px;height:68px;border:0;outline:none;border-radius:14px;">
<div style="margin-top:12px;font-size:28px;font-weight:900;letter-spacing:4px;color:#E8C547 !important;font-family:Georgia,'Times New Roman',serif;">CRUISE</div>
<div style="margin-top:4px;font-size:10px;font-weight:600;letter-spacing:2.5px;color:#8a7e4e !important;text-transform:uppercase;">Premium Ride Service</div>
</td></tr>

<!-- Body -->
<tr><td bgcolor="#000000" class="pad-lg" style="padding:30px 34px 10px;">{body_html}</td></tr>

<!-- CTA -->
<tr><td align="center" bgcolor="#000000" style="padding:12px 30px 22px;">
<a href="https://cruiseinride.com" class="big-pill" style="display:inline-block;padding:13px 28px;background:linear-gradient(135deg,#F5DC7A,#E8C547,#B08800);border-radius:999px;color:#0a0a0a !important;font-size:13px;font-weight:800;text-decoration:none;letter-spacing:.06em;text-transform:uppercase;box-shadow:0 4px 14px rgba(232,197,71,.35);">Visit cruiseinride.com</a>
</td></tr>

<!-- Divider -->
<tr><td bgcolor="#000000" style="padding:0 30px;">
<div style="height:1px;background:rgba(232,197,71,.18);"></div>
</td></tr>

<!-- Support row -->
<tr><td bgcolor="#000000" style="padding:18px 30px 8px;font-size:12px;color:#8a7e4e !important;line-height:1.6;text-align:center;">
<strong style="color:#d9c98b !important;">Need help?</strong><br>
<a href="mailto:{SUPPORT_EMAIL}" style="color:#E8C547 !important;text-decoration:none;font-weight:600;">{SUPPORT_EMAIL}</a>
</td></tr>

<!-- Footer -->
<tr><td bgcolor="#000000" style="padding:12px 30px 26px;font-size:11px;color:#6b5e2e !important;text-align:center;line-height:1.6;">
© Cruise · All rights reserved<br>
<a href="https://cruiseinride.com" style="color:#8a7e4e !important;text-decoration:none;">cruiseinride.com</a>
</td></tr>

</table>
</td></tr></table>
</body></html>"""


# ═══════════════ Content helpers ═══════════════

def _h1(text: str) -> str:
    return (
        f'<h1 class="h1" style="margin:0 0 10px 0;font-size:26px;font-weight:800;'
        f'color:#E8C547 !important;letter-spacing:-.01em;line-height:1.25;">{text}</h1>'
    )


def _h2(text: str) -> str:
    return (
        f'<div style="margin:18px 0 8px;font-size:11px;font-weight:800;'
        f'letter-spacing:.18em;color:#8a7e4e !important;text-transform:uppercase;">{text}</div>'
    )


def _p(text: str) -> str:
    return (
        f'<p style="margin:0 0 14px 0;font-size:15px;line-height:1.6;'
        f'color:#d9c98b !important;">{text}</p>'
    )


def _badge(text: str, color: str = "#E8C547") -> str:
    return (
        f'<div style="display:inline-block;padding:8px 16px;border-radius:999px;'
        f'background:rgba(232,197,71,.1);border:1px solid {color};'
        f'color:{color} !important;font-size:12px;font-weight:700;'
        f'letter-spacing:.06em;text-transform:uppercase;">{text}</div>'
    )


def _info_card(rows_html: str) -> str:
    """Dark card with rounded corners + gold border for structured info."""
    return (
        f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" '
        f'style="border-collapse:separate;border-spacing:0;margin:14px 0 18px;'
        f'background:#0d0d0d;border:1px solid rgba(232,197,71,.22);'
        f'border-radius:14px;overflow:hidden;">'
        f'{rows_html}</table>'
    )


def _row(label: str, value: str, last: bool = False) -> str:
    border = "" if last else 'border-bottom:1px solid rgba(232,197,71,.12);'
    return (
        f'<tr><td style="padding:13px 18px;{border}">'
        f'<div style="font-size:11px;font-weight:700;letter-spacing:.1em;'
        f'color:#8a7e4e !important;text-transform:uppercase;margin-bottom:3px;">{label}</div>'
        f'<div style="font-size:15px;font-weight:600;color:#E8C547 !important;">{value}</div>'
        f'</td></tr>'
    )


def _route_block(pickup: str, dropoff: str, lang: str) -> str:
    """Visual pickup → dropoff block with dots and line."""
    lbl_pickup = "Recogida" if lang == "es" else "Pickup"
    lbl_dropoff = "Destino" if lang == "es" else "Dropoff"
    # Layout strategy: 3-row table where each figure shares a row with its label.
    # - Row 1 (PICKUP): circle + label column. Circle is top-aligned at the
    #   exact height of the label's cap line (padding-top:1px inside a 10px
    #   div that sits beside a 10px-line-height uppercase label).
    # - Row 2 (connector): line-only row. The line extends vertically using
    #   large negative vertical margins that make it bleed INTO both
    #   neighbour rows so it visually touches the circle bottom AND the
    #   square top.
    # - Row 3 (DROPOFF): square + label column, same alignment as row 1.
    # This keeps the circle anchored at PICKUP and the square anchored at
    # DROPOFF regardless of how many lines the addresses wrap to.
    return f"""
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:14px 0 18px;background:#0d0d0d;border:1px solid rgba(232,197,71,.22);border-radius:14px;">
<tr><td style="padding:16px 18px 14px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">
<tr>
<td width="14" align="center" valign="top" style="padding:1px 0 0 0;line-height:0;font-size:0;width:14px;">
<div style="width:10px;height:10px;border-radius:50%;background:#E8C547;box-shadow:0 0 8px rgba(232,197,71,.5);margin:0 auto;"></div>
</td>
<td valign="top" style="padding:0 0 14px 10px;">
<div style="font-size:10px;font-weight:800;letter-spacing:.14em;color:#8a7e4e !important;text-transform:uppercase;line-height:1;">{lbl_pickup}</div>
<div style="font-size:14px;font-weight:600;color:#E8C547 !important;margin-top:3px;word-break:break-word;line-height:1.35;">{pickup}</div>
</td>
</tr>
<tr>
<td width="14" align="center" style="padding:0;line-height:0;font-size:0;width:14px;height:1px;">
<div style="width:2px;height:22px;background:linear-gradient(180deg,#E8C547,rgba(232,197,71,.55));margin:-11px auto -11px;"></div>
</td>
<td style="padding:0;line-height:0;font-size:0;height:1px;">&nbsp;</td>
</tr>
<tr>
<td width="14" align="center" valign="top" style="padding:1px 0 0 0;line-height:0;font-size:0;width:14px;">
<div style="width:10px;height:10px;background:#ffffff;border-radius:2px;margin:0 auto;"></div>
</td>
<td valign="top" style="padding:0 0 0 10px;">
<div style="font-size:10px;font-weight:800;letter-spacing:.14em;color:#8a7e4e !important;text-transform:uppercase;line-height:1;">{lbl_dropoff}</div>
<div style="font-size:14px;font-weight:600;color:#ffffff !important;margin-top:3px;word-break:break-word;line-height:1.35;">{dropoff}</div>
</td>
</tr>
</table>
</td></tr></table>
"""


# ═══════════════ Trip data helpers ═══════════════

def _trip_pickup(trip) -> str:
    return (getattr(trip, "pickup_address", None) or "—").strip() or "—"


def _trip_dropoff(trip) -> str:
    return (getattr(trip, "dropoff_address", None) or "—").strip() or "—"


def _trip_vehicle_type(trip, lang: str) -> str:
    vt = (getattr(trip, "vehicle_type", None) or "").strip().lower()
    if not vt:
        return "—"
    names_en = {"sedan": "Sedan", "comfort": "Comfort", "premium": "Premium", "vip": "VIP"}
    names_es = {"sedan": "Sedán", "comfort": "Comfort", "premium": "Premium", "vip": "VIP"}
    table = names_es if lang == "es" else names_en
    return table.get(vt, vt.title())


def _trip_fare(trip) -> str:
    fare = getattr(trip, "fare", None)
    if fare is None:
        fare = getattr(trip, "base_fare", None)
    if fare is None or fare <= 0:
        return "—"
    return f"${float(fare):.2f}"


def _trip_scheduled(trip, lang: str) -> str | None:
    sched = getattr(trip, "scheduled_at", None)
    if not sched:
        return None
    try:
        from datetime import datetime
        if not isinstance(sched, datetime):
            return None
        months_en = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        months_es = ["Ene", "Feb", "Mar", "Abr", "May", "Jun",
                     "Jul", "Ago", "Sep", "Oct", "Nov", "Dic"]
        mo = months_es if lang == "es" else months_en
        h, m = sched.hour, sched.minute
        am_pm = "PM" if h >= 12 else "AM"
        h12 = h % 12 or 12
        return f"{mo[sched.month - 1]} {sched.day}, {sched.year} · {h12}:{m:02d} {am_pm}"
    except Exception:
        return None


def _trip_id_short(trip) -> str:
    tid = str(getattr(trip, "id", "")) or "—"
    return f"#{tid}"


# ═══════════════ Bilingual templates ═══════════════

def _build_welcome(first_name: str, trip, lang: str) -> tuple[str, str, str]:
    pickup = _trip_pickup(trip)
    dropoff = _trip_dropoff(trip)
    vehicle = _trip_vehicle_type(trip, lang)
    fare = _trip_fare(trip)
    sched = _trip_scheduled(trip, lang)
    tid = _trip_id_short(trip)

    if lang == "es":
        subject = f"✓ Reserva confirmada — {tid}"
        preheader = f"Hola {first_name}, tu viaje está reservado. Buscando conductor ahora."
        heading = f"¡Reserva confirmada, {first_name}!"
        intro = "Tu viaje ya está en nuestro sistema. Estamos buscando un conductor cercano que esté listo para atenderte."
        status_badge = _badge("Buscando conductor", BRAND_GOLD)
        lbl_trip = "Viaje"
        lbl_vehicle = "Vehículo"
        lbl_fare = "Tarifa estimada"
        lbl_scheduled = "Programado para"
        next_hdr = "Qué sigue"
        next_body = ("En unos minutos recibirás otro email con los detalles de tu conductor: "
                     "nombre, foto, placa del vehículo, color y modelo. Luego te avisaremos cuando "
                     "esté en camino y cuando llegue.")
        thanks = "Gracias por elegir Cruise — viajar con estilo es nuestra prioridad."
    else:
        subject = f"✓ Booking confirmed — {tid}"
        preheader = f"Hi {first_name}, your ride is booked. Finding a driver now."
        heading = f"Booking confirmed, {first_name}!"
        intro = ("Your ride is now in our system. We're matching you with a nearby driver who's "
                 "ready to take care of you.")
        status_badge = _badge("Finding driver", BRAND_GOLD)
        lbl_trip = "Trip"
        lbl_vehicle = "Vehicle"
        lbl_fare = "Estimated fare"
        lbl_scheduled = "Scheduled for"
        next_hdr = "What's next"
        next_body = ("In a few minutes you'll receive another email with your driver's details: "
                     "name, photo, license plate, color and model. Then we'll notify you when "
                     "they're on the way and when they arrive.")
        thanks = "Thank you for choosing Cruise — riding in style is our priority."

    info_rows = _row(lbl_trip, tid) + _row(lbl_vehicle, vehicle)
    if fare != "—":
        info_rows += _row(lbl_fare, fare)
    if sched:
        info_rows += _row(lbl_scheduled, sched, last=True)
    else:
        # Close the last row's border
        info_rows = info_rows.replace(
            'border-bottom:1px solid rgba(232,197,71,.12);', '', 1
        ) if not fare else info_rows
        # Ensure last row has no border (mark last by wrapping the string)

    body = (
        f'<div style="text-align:center;margin-bottom:20px;">{status_badge}</div>'
        + _h1(heading)
        + _p(intro)
        + _route_block(pickup, dropoff, lang)
        + _info_card(info_rows)
        + _h2(next_hdr)
        + _p(next_body)
        + _p(thanks)
    )
    text = (
        f"{heading}\n\n{intro}\n\n"
        f"Trip: {tid}\nVehicle: {vehicle}\n"
        f"From: {pickup}\nTo: {dropoff}\n"
        + (f"Fare: {fare}\n" if fare != "—" else "")
        + (f"Scheduled: {sched}\n" if sched else "")
        + f"\n{next_body}\n\n{thanks}"
    )
    return subject, _shell(subject, preheader, body), text


def _build_driver_assigned(driver_name, vehicle_year, vehicle_make, vehicle_model,
                           vehicle_color, vehicle_plate, driver_phone, trip, lang) -> tuple[str, str, str]:
    pickup = _trip_pickup(trip)
    dropoff = _trip_dropoff(trip)
    tid = _trip_id_short(trip)

    vehicle_full = " ".join(filter(None, [
        str(vehicle_year) if vehicle_year else "",
        (vehicle_make or "").strip(),
        (vehicle_model or "").strip(),
    ])).strip() or "—"

    if lang == "es":
        subject = f"🚗 Conductor asignado — {tid}"
        preheader = f"Tu conductor {driver_name} está listo y en camino hacia ti."
        heading = "¡Conductor asignado!"
        intro = f"<strong style=\"color:#E8C547 !important;\">{driver_name}</strong> ha aceptado tu viaje y estará contigo pronto."
        status_badge = _badge("Conductor en camino", BRAND_GOLD)
        lbl_driver = "Conductor"
        lbl_vehicle = "Vehículo"
        lbl_color = "Color"
        lbl_plate = "Placa"
        lbl_phone = "Teléfono del conductor"
        tip_hdr = "Consejos"
        tip_body = ("Ve a la puerta 2-3 minutos antes de que llegue el conductor. "
                    "Verifica la placa antes de abordar por tu seguridad.")
    else:
        subject = f"🚗 Driver assigned — {tid}"
        preheader = f"Your driver {driver_name} is ready and heading to you."
        heading = "Driver assigned!"
        intro = f"<strong style=\"color:#E8C547 !important;\">{driver_name}</strong> has accepted your ride and will be with you shortly."
        status_badge = _badge("Driver on the way", BRAND_GOLD)
        lbl_driver = "Driver"
        lbl_vehicle = "Vehicle"
        lbl_color = "Color"
        lbl_plate = "Plate"
        lbl_phone = "Driver's phone"
        tip_hdr = "Tips"
        tip_body = ("Step outside 2-3 minutes before your driver arrives. "
                    "Always verify the license plate before boarding for your safety.")

    info_rows = (
        _row(lbl_driver, driver_name)
        + _row(lbl_vehicle, vehicle_full)
        + _row(lbl_color, vehicle_color or "—")
        + _row(lbl_plate, f"<span style='font-family:monospace;letter-spacing:.08em;background:#1a1a1a;padding:3px 8px;border-radius:5px;border:1px solid rgba(232,197,71,.3);'>{vehicle_plate}</span>" if vehicle_plate else "—")
        + _row(lbl_phone, f"<a href='tel:{driver_phone}' style='color:#E8C547 !important;text-decoration:none;'>{driver_phone}</a>" if driver_phone else "—", last=True)
    )

    body = (
        f'<div style="text-align:center;margin-bottom:20px;">{status_badge}</div>'
        + _h1(heading)
        + _p(intro)
        + _info_card(info_rows)
        + _route_block(pickup, dropoff, lang)
        + _h2(tip_hdr)
        + _p(tip_body)
    )
    text = (
        f"{heading}\n\n{intro}\n\n"
        f"Driver: {driver_name}\nVehicle: {vehicle_full}\n"
        f"Color: {vehicle_color}\nPlate: {vehicle_plate}\nPhone: {driver_phone}\n\n"
        f"From: {pickup}\nTo: {dropoff}\n\n{tip_body}"
    )
    return subject, _shell(subject, preheader, body), text


def _build_driver_en_route(driver_name: str, trip, lang: str) -> tuple[str, str, str]:
    pickup = _trip_pickup(trip)
    tid = _trip_id_short(trip)

    if lang == "es":
        subject = f"🚕 Tu conductor va en camino — {tid}"
        preheader = f"{driver_name} se dirige a tu recogida."
        heading = "¡Tu conductor va en camino!"
        intro = f"<strong style=\"color:#E8C547 !important;\">{driver_name}</strong> está manejando hacia tu punto de recogida."
        status_badge = _badge("En camino", BRAND_GOLD)
        tip_body = "Ve a la puerta para no hacer esperar al conductor. ¡Te vemos pronto!"
    else:
        subject = f"🚕 Your driver is on the way — {tid}"
        preheader = f"{driver_name} is heading to your pickup."
        heading = "Your driver is on the way!"
        intro = f"<strong style=\"color:#E8C547 !important;\">{driver_name}</strong> is now driving to your pickup location."
        status_badge = _badge("En route", BRAND_GOLD)
        tip_body = "Step outside so your driver doesn't have to wait. See you soon!"

    body = (
        f'<div style="text-align:center;margin-bottom:20px;">{status_badge}</div>'
        + _h1(heading)
        + _p(intro)
        + _p(f'<span style="color:#8a7e4e !important;font-size:13px;">📍 {pickup}</span>')
        + _p(tip_body)
    )
    text = f"{heading}\n\n{intro}\n\nPickup: {pickup}\n\n{tip_body}"
    return subject, _shell(subject, preheader, body), text


def _build_driver_arrived(driver_name: str, vehicle_color: str, vehicle_plate: str, trip, lang: str) -> tuple[str, str, str]:
    tid = _trip_id_short(trip)
    plate_html = (
        f"<span style='font-family:monospace;letter-spacing:.08em;background:#1a1a1a;padding:3px 8px;border-radius:5px;border:1px solid rgba(232,197,71,.3);'>{vehicle_plate}</span>"
        if vehicle_plate else "—"
    )

    if lang == "es":
        subject = f"📍 Tu conductor ha llegado — {tid}"
        preheader = f"{driver_name} está afuera esperándote."
        heading = "¡Tu conductor ha llegado!"
        intro = f"<strong style=\"color:#E8C547 !important;\">{driver_name}</strong> está en el punto de recogida y te está esperando."
        status_badge = _badge("Ha llegado", "#6ee589")
        look_for = "Busca:"
        lbl_color = "Color del vehículo"
        lbl_plate = "Placa"
        safety = "Por tu seguridad, verifica la placa antes de subir al vehículo."
    else:
        subject = f"📍 Your driver has arrived — {tid}"
        preheader = f"{driver_name} is outside waiting for you."
        heading = "Your driver has arrived!"
        intro = f"<strong style=\"color:#E8C547 !important;\">{driver_name}</strong> is at the pickup location and is waiting for you."
        status_badge = _badge("Arrived", "#6ee589")
        look_for = "Look for:"
        lbl_color = "Vehicle color"
        lbl_plate = "Plate"
        safety = "For your safety, verify the license plate before boarding."

    info_rows = (
        _row(lbl_color, vehicle_color or "—")
        + _row(lbl_plate, plate_html, last=True)
    )

    body = (
        f'<div style="text-align:center;margin-bottom:20px;">{status_badge}</div>'
        + _h1(heading)
        + _p(intro)
        + _h2(look_for)
        + _info_card(info_rows)
        + _p(f'<em style="color:#d9c98b !important;">{safety}</em>')
    )
    text = f"{heading}\n\n{intro}\n\nColor: {vehicle_color}\nPlate: {vehicle_plate}\n\n{safety}"
    return subject, _shell(subject, preheader, body), text


def _build_trip_completed(trip, lang: str) -> tuple[str, str, str]:
    pickup = _trip_pickup(trip)
    dropoff = _trip_dropoff(trip)
    fare = _trip_fare(trip)
    tid = _trip_id_short(trip)

    if lang == "es":
        subject = f"✓ Viaje completado — {tid}"
        preheader = "Gracias por viajar con Cruise. Déjanos tu opinión."
        heading = "¡Viaje completado!"
        intro = "Esperamos que hayas tenido una experiencia cómoda y segura."
        status_badge = _badge("Completado", "#6ee589")
        lbl_summary = "Resumen del viaje"
        lbl_trip = "Viaje"
        lbl_total = "Total cobrado"
        rate_hdr = "¿Cómo estuvo tu viaje?"
        rate_body = ("Tu opinión nos ayuda a mejorar. Toma un momento para calificar a tu "
                     "conductor en la app o responde a este email.")
        thanks = "Gracias por elegir Cruise. ¡Esperamos verte pronto!"
    else:
        subject = f"✓ Trip completed — {tid}"
        preheader = "Thanks for riding with Cruise. We'd love your feedback."
        heading = "Trip completed!"
        intro = "We hope you had a comfortable and safe experience."
        status_badge = _badge("Completed", "#6ee589")
        lbl_summary = "Trip summary"
        lbl_trip = "Trip"
        lbl_total = "Total charged"
        rate_hdr = "How was your ride?"
        rate_body = ("Your feedback helps us improve. Take a moment to rate your driver in the "
                     "app or reply to this email with comments.")
        thanks = "Thank you for choosing Cruise. We hope to see you again soon!"

    info_rows = _row(lbl_trip, tid)
    if fare != "—":
        info_rows += _row(lbl_total, fare, last=True)
    else:
        info_rows = _row(lbl_trip, tid, last=True)

    body = (
        f'<div style="text-align:center;margin-bottom:20px;">{status_badge}</div>'
        + _h1(heading)
        + _p(intro)
        + _route_block(pickup, dropoff, lang)
        + _h2(lbl_summary)
        + _info_card(info_rows)
        + _h2(rate_hdr)
        + _p(rate_body)
        + _p(thanks)
    )
    text = (
        f"{heading}\n\n{intro}\n\n"
        f"Trip: {tid}\nFrom: {pickup}\nTo: {dropoff}\n"
        + (f"Total: {fare}\n" if fare != "—" else "")
        + f"\n{rate_body}\n\n{thanks}"
    )
    return subject, _shell(subject, preheader, body), text


# ═══════════════ Guest helpers ═══════════════

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
    except IntegrityError:
        try:
            await db.rollback()
        except Exception:
            pass
    except Exception as e:
        _log.warning("[EMAIL] log write failed (trip=%s event=%s): %s", trip_id, event_type, e)
        try:
            await db.rollback()
        except Exception:
            pass


async def _dispatch(
    db,
    trip_id,
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
                _send_email, email_address, subject, html_body, {"message": text_body}, True
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
            _send_email, email_address, subject, html_body, {"message": text_body}, True
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


# ═══════════════ Public API ═══════════════

async def email_guest_welcome(db, trip) -> None:
    try:
        email = _guest_email(trip)
        if not email:
            return
        subject, html, text = _build_welcome(_guest_first_name(trip), trip, _guest_lang(trip))
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
            trip=trip,
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
        subject, html, text = _build_driver_en_route(driver_name, trip, _guest_lang(trip))
        await _dispatch(db, trip.id, "driver_en_route", email, subject, html, text)
    except Exception as e:
        _log.warning("[EMAIL] email_guest_driver_en_route failed for trip %s: %s", getattr(trip, "id", "?"), e)


async def email_guest_driver_arrived(db, trip, driver, vehicle=None) -> None:
    try:
        email = _guest_email(trip)
        if not email:
            return
        driver_name = (
            f"{getattr(driver, 'first_name', '') or ''} {getattr(driver, 'last_name', '') or ''}"
        ).strip() or "your driver"
        vehicle_color = getattr(vehicle, "color", "") or "" if vehicle else ""
        vehicle_plate = (getattr(vehicle, "plate", None) or getattr(vehicle, "license_plate", "") or "") if vehicle else ""
        subject, html, text = _build_driver_arrived(
            driver_name, vehicle_color, vehicle_plate, trip, _guest_lang(trip)
        )
        await _dispatch(db, trip.id, "driver_arrived", email, subject, html, text)
    except Exception as e:
        _log.warning("[EMAIL] email_guest_driver_arrived failed for trip %s: %s", getattr(trip, "id", "?"), e)


async def email_guest_trip_completed(db, trip) -> None:
    try:
        email = _guest_email(trip)
        if not email:
            return
        subject, html, text = _build_trip_completed(trip, _guest_lang(trip))
        await _dispatch(db, trip.id, "trip_completed", email, subject, html, text)
    except Exception as e:
        _log.warning("[EMAIL] email_guest_trip_completed failed for trip %s: %s", getattr(trip, "id", "?"), e)


def _build_no_driver(trip, lang: str, refunded: bool) -> tuple[str, str, str]:
    pickup = _trip_pickup(trip)
    dropoff = _trip_dropoff(trip)
    fare = _trip_fare(trip)
    tid = _trip_id_short(trip)

    if lang == "es":
        subject = f"No pudimos encontrar conductor — {tid}"
        preheader = "Te reembolsamos el total. Intenta nuevamente en unos minutos."
        heading = "No encontramos un conductor disponible"
        intro = ("Lo sentimos mucho. No pudimos asignar un conductor para tu viaje en este momento. "
                 "Sabemos lo frustrante que es esto y te pedimos disculpas.")
        status_badge = _badge("Sin conductor", "#ff6b6b")
        lbl_summary = "Detalles del viaje"
        lbl_trip = "Viaje"
        lbl_total = "Total"
        refund_hdr = "Reembolso emitido" if refunded else "Reembolso"
        refund_body = (
            "Te reembolsamos el total a tu método de pago original. El reembolso aparecerá "
            "en 5-10 días hábiles dependiendo de tu banco."
            if refunded else
            "No se te cobró nada. Si ves un cargo pendiente, desaparecerá automáticamente en 1-3 días."
        )
        retry_hdr = "¿Intentamos de nuevo?"
        retry_body = ("Nuestra flota puede estar ocupada. Te recomendamos intentar nuevamente en "
                      "unos minutos. También puedes programar tu viaje con anticipación para "
                      "garantizar disponibilidad.")
        thanks = "Gracias por tu paciencia. Estamos aquí para servirte."
    else:
        subject = f"We couldn't find a driver — {tid}"
        preheader = "You've been fully refunded. Please try again in a few minutes."
        heading = "No driver available right now"
        intro = ("We're very sorry. We couldn't match your ride with a driver at this time. "
                 "We know how frustrating this is and we apologize.")
        status_badge = _badge("No driver", "#ff6b6b")
        lbl_summary = "Ride details"
        lbl_trip = "Trip"
        lbl_total = "Total"
        refund_hdr = "Refund issued" if refunded else "Refund"
        refund_body = (
            "A full refund has been issued to your original payment method. It will appear "
            "within 5-10 business days depending on your bank."
            if refunded else
            "No charge was processed. Any pending hold will clear automatically in 1-3 days."
        )
        retry_hdr = "Want to try again?"
        retry_body = ("Our fleet may be busy. We recommend trying again in a few minutes. "
                      "You can also schedule your ride in advance to guarantee availability.")
        thanks = "Thank you for your patience. We're here to serve you."

    info_rows = _row(lbl_trip, tid)
    if fare != "—":
        info_rows += _row(lbl_total, fare, last=True)
    else:
        info_rows = _row(lbl_trip, tid, last=True)

    body = (
        f'<div style="text-align:center;margin-bottom:20px;">{status_badge}</div>'
        + _h1(heading)
        + _p(intro)
        + _route_block(pickup, dropoff, lang)
        + _h2(lbl_summary)
        + _info_card(info_rows)
        + _h2(refund_hdr)
        + _p(refund_body)
        + _h2(retry_hdr)
        + _p(retry_body)
        + _p(thanks)
    )
    text = (
        f"{heading}\n\n{intro}\n\n"
        f"Trip: {tid}\nFrom: {pickup}\nTo: {dropoff}\n"
        + (f"Total: {fare}\n" if fare != "—" else "")
        + f"\n{refund_hdr}\n{refund_body}\n\n{retry_hdr}\n{retry_body}\n\n{thanks}"
    )
    return subject, _shell(subject, preheader, body), text


async def email_guest_no_driver(db, trip, refunded: bool = False) -> None:
    try:
        email = _guest_email(trip)
        if not email:
            return
        subject, html, text = _build_no_driver(trip, _guest_lang(trip), refunded)
        await _dispatch(db, trip.id, "no_driver", email, subject, html, text)
    except Exception as e:
        _log.warning("[EMAIL] email_guest_no_driver failed for trip %s: %s", getattr(trip, "id", "?"), e)
