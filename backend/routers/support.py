import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List, Any

# Rate limit tracker for support messages (10 msg/min per user)
_support_msg_rate: dict = {}

_HAS_FIELD_FILTER: bool = False
try:
    from google.cloud.firestore_v1.base_query import FieldFilter
    _HAS_FIELD_FILTER = True
except ImportError:
    pass
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, SupportChat, SupportMessage, ActionRequest,
)
from utils.security import (  # type: ignore[attr-defined]
    _get_current_user, _verify_api_key, _require_dispatch_auth,
    _security_audit_log,
)
from utils.helpers import utc_now, _support_msg_dict  # type: ignore[attr-defined]
from services.fcm_service import _send_fcm_push  # type: ignore[attr-defined]
from config import (
    ANTHROPIC_API_KEY, _HAS_CLAUDE,  # type: ignore[attr-defined]
    firestore_sync, _HAS_FIRESTORE,  # type: ignore[attr-defined]
)
from support_cache import find_cached_response, add_natural_variation, claude_health, maybe_cache_response

router = APIRouter()

# ═══════════════════════════════════════════════════════
#  AI SUPPORT AGENT ENGINE
# ═══════════════════════════════════════════════════════

import random as _rng

_AGENT_NAMES = [
    "Lucia", "Sofia", "Isabella", "Valentina", "Camila",
    "Mariana", "Daniela", "Gabriela", "Andrea", "Carolina",
    "Ana Paula", "Laura", "Diana", "Natalia", "Alejandra",
]

_ESCALATION_TRIGGERS = [
    "manager", "supervisor", "gerente", "jefe", "encargado", "superior",
    "speak to your manager", "hablar con el gerente", "hablar con un supervisor",
    "hablar con el jefe", "quiero hablar con un supervisor", "quiero hablar con el gerente",
    "no me ayudas", "incompetente", "inutil", "useless", "your boss",
    "real person", "persona real", "human", "humano",
]

_FRUSTRATION_KEYWORDS = [
    "horrible", "terrible", "worst", "peor", "basura", "garbage", "trash",
    "estafa", "scam", "robo", "steal", "fraud", "fraude", "disgusting",
    "asqueroso", "fuck", "shit", "mierda", "damn", "hell", "stupid",
    "idiota", "ridiculous", "ridiculo", "absurdo", "absurd", "unacceptable",
    "inaceptable", "sue", "demandar", "lawyer", "abogado", "police", "policia",
]

_CANCEL_INTENT = [
    "cancela mi viaje", "cancel my trip", "cancel my ride", "cancelar mi viaje",
    "cancelar el viaje", "cancela el viaje", "cancel the trip", "cancel the ride",
    "quiero cancelar", "i want to cancel", "cancelar ahora", "cancel now",
    "no quiero el viaje", "don't want the ride", "detener el viaje", "stop the trip",
]


def _detect_frustration(text: str) -> bool:
    """Detect if user is frustrated/angry based on keywords and typing patterns."""
    t = text.lower()
    # Keyword check
    if any(k in t for k in _FRUSTRATION_KEYWORDS):
        return True
    # ALL CAPS (more than 5 uppercase words)
    words = text.split()
    caps_words = sum(1 for w in words if len(w) > 2 and w.isupper())
    if caps_words >= 3:
        return True
    # Excessive exclamation/question marks
    if text.count("!") >= 3 or text.count("?") >= 3:
        return True
    return False


def _has_cancel_intent(text: str) -> bool:
    """Detect if user wants to cancel their active trip."""
    t = text.lower()
    return any(k in t for k in _CANCEL_INTENT)


async def _get_user_context(user_id: int, db: AsyncSession, lang: str) -> dict[str, Any]:
    """Gather comprehensive context about the user for smarter bot responses."""
    ctx: dict[str, Any] = {"has_active_trip": False, "active_trip": None, "recent_trips": [],
                 "user": None, "trip_summary": ""}

    # User info
    u_r = await db.execute(select(User).where(User.id == user_id))
    user = u_r.scalar_one_or_none()
    if user:
        ctx["user"] = {
            "name": f"{user.first_name} {user.last_name}".strip(),
            "role": user.role or "rider",
            "email": user.email,
            "phone": user.phone,
        }

    # Active trip (not completed, not canceled)
    active_r = await db.execute(
        select(Trip).where(
            Trip.rider_id == user_id,
            Trip.status.notin_(["completed", "canceled"]),
        ).order_by(Trip.created_at.desc()).limit(1)
    )
    active_trip = active_r.scalar_one_or_none()
    if active_trip:
        ctx["has_active_trip"] = True
        driver_name = None
        if active_trip.driver_id is not None:
            dr_r = await db.execute(select(User).where(User.id == active_trip.driver_id))
            driver = dr_r.scalar_one_or_none()
            if driver:
                driver_name = f"{driver.first_name} {driver.last_name}".strip()
        ctx["active_trip"] = {
            "id": active_trip.id,
            "status": active_trip.status,
            "pickup": active_trip.pickup_address,
            "dropoff": active_trip.dropoff_address,
            "fare": active_trip.fare,
            "driver_name": driver_name,
            "vehicle_type": active_trip.vehicle_type,
            "created_at": active_trip.created_at,
        }

    # Recent completed/canceled trips
    recent_r = await db.execute(
        select(Trip).where(Trip.rider_id == user_id)
        .order_by(Trip.created_at.desc()).limit(5)
    )
    recent = recent_r.scalars().all()
    for t in recent:
        date_str = t.created_at.strftime("%m/%d/%Y %I:%M %p") if t.created_at else "N/A"
        fare_str = f"${t.fare:.2f}" if t.fare else "$0.00"
        ctx["recent_trips"].append({
            "id": t.id, "date": date_str, "pickup": t.pickup_address or "N/A",
            "dropoff": t.dropoff_address or "N/A", "fare": fare_str,
            "status": t.status or "unknown",
        })

    # Build summary
    if ctx["recent_trips"]:
        lines = []
        for rt in ctx["recent_trips"]:
            lines.append(f" {rt['date']}  {rt['pickup']} ? {rt['dropoff']}  {rt['fare']} ({rt['status']})")
        header = "Tus viajes recientes:" if lang.startswith("es") else "Your recent trips:"
        ctx["trip_summary"] = header + "\n" + "\n".join(lines)
    else:
        ctx["trip_summary"] = ("No encontre viajes recientes en tu cuenta." if lang.startswith("es")
                               else "I couldn't find any recent trips on your account.")

    return ctx


async def _bot_cancel_trip(user_id: int, db: AsyncSession, lang: str) -> str:
    """Actually cancel the user's active trip and return confirmation message."""
    result = await db.execute(
        select(Trip).where(
            Trip.rider_id == user_id,
            Trip.status.notin_(["completed", "canceled"]),
        ).order_by(Trip.created_at.desc()).limit(1)
    )
    trip = result.scalar_one_or_none()
    if not trip:
        if lang.startswith("es"):
            return "No tienes un viaje activo en este momento para cancelar."
        return "You don't have an active trip to cancel right now."

    trip.status = "canceled"  # type: ignore[assignment]
    trip.cancel_reason = "Canceled via support chat"  # type: ignore[assignment]
    trip.updated_at = datetime.now(timezone.utc).replace(tzinfo=None)  # type: ignore[assignment]
    await db.flush()
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip_status(trip_id=int(trip.id), status="canceled", cancel_reason=str(trip.cancel_reason))
        except Exception:
            pass
    if lang.startswith("es"):
        return f"Tu viaje #{trip.id} de {trip.pickup_address} a {trip.dropoff_address} ha sido cancelado exitosamente. No se te realizara ningun cargo."
    return f"Your trip #{trip.id} from {trip.pickup_address} to {trip.dropoff_address} has been successfully canceled. You won't be charged."


def _score_categories(text: str) -> list[tuple[str, int]]:
    """Score all categories by keyword match count and return sorted list."""
    t = text.lower()
    scores: list[tuple[str, int]] = []
    for cat, data in _AI_CATEGORIES.items():
        score = sum(1 for k in data["keywords"] if k in t)
        if score > 0:
            scores.append((cat, score))
    scores.sort(key=lambda x: x[1], reverse=True)
    return scores

_THANK_KEYWORDS = [
    "gracias", "thanks", "thank you", "thx", "ty", "perfecto", "perfect",
    "genial", "great", "ok gracias", "listo", "eso es todo", "nada mas",
    "that's all", "no nada", "no, gracias", "ya esta", "resolved",
    "resuelto", "solucionado", "excelente", "bueno gracias",
]

_AI_CATEGORIES = {
    "trip_charge": {
        "keywords": ["cobr", "cobro", "cargo", "charge", "tarifa", "fare", "precio",
                     "price", "caro", "expensive", "overcharge", "sobrecar", "cobrado",
                     "dinero", "money", "amount", "monto", "receipt", "recibo"],
        "first_es": [
            "Entiendo tu preocupacion con el cobro, {name}. Dejame revisar los detalles de tu viaje.\n\nMe podras indicar la fecha y hora aproximada del viaje? Asi puedo localizar la transaccion mas rapido",
            "Lamento el inconveniente con el cobro, {name}. Voy a revisar tu cuenta ahora mismo.\n\nPodras darme la fecha del viaje y el monto que te cobraron? Asi lo verifico de inmediato.",
            "Claro, {name}, voy a revisar eso por ti. A veces los cobros varan por cambios de ruta, peajes o tiempo de espera.\n\nMe das la fecha y la hora del viaje para revisar el recibo?",
        ],
        "first_en": [
            "I understand your concern about the charge, {name}. Let me look into your trip details.\n\nCould you tell me the approximate date and time of the trip? That way I can find the transaction faster",
            "Sorry about the inconvenience with the charge, {name}. I'm checking your account right now.\n\nCould you give me the trip date and the amount you were charged? I'll verify it right away.",
            "Sure thing, {name}, I'll look into that for you. Sometimes charges vary due to route changes, tolls, or wait time.\n\nCan you give me the date and time of the trip so I can check the receipt?",
        ],
        "followup_es": [
            "Perfecto, ya localice tu viaje, {name}. He verificado el recibo y voy a procesar el ajuste correspondiente.\n\nEl reembolso se reflejara en tu metodo de pago en un plazo de 3 a 5 dias habiles. Necesitas algo mas?",
            "Ya reviso la transaccion, {name}. Efectivamente hay una diferencia y voy a iniciar el proceso de correccion.\n\nTe llegara una notificacion cuando se complete. Hay algo mas en lo que pueda ayudarte?",
        ],
        "followup_en": [
            "Got it, I found your trip, {name}. I've checked the receipt and I'm going to process the corresponding adjustment.\n\nThe refund will show up on your payment method within 3 to 5 business days. Do you need anything else?",
            "I've reviewed the transaction, {name}. There is indeed a discrepancy and I'm starting the correction process.\n\nYou'll receive a notification once it's complete. Is there anything else I can help you with?",
        ],
    },
    "cancellation": {
        "keywords": ["cancel", "cancelar", "cancelacion", "cancele", "cancelado",
                     "cancelar viaje", "no quiero el viaje"],
        "first_es": [
            "Entiendo, {name}. Puedo ayudarte con eso. Es un viaje que quieres cancelar ahora o te cobraron una tarifa de cancelacion?\n\nCuentame los detalles y lo resolvemos juntos.",
            "Claro, {name}. El viaje ya esta programado o es uno que ya paso y te cobraron por cancelar?\n\nDime los detalles para proceder de la mejor manera.",
        ],
        "first_en": [
            "I understand, {name}. I can help you with that. Is it a trip you want to cancel now, or were you charged a cancellation fee?\n\nTell me the details and we'll sort it out together.",
            "Sure, {name}. Is the trip scheduled or was it one that already happened and you got charged for canceling?\n\nGive me the details so I can handle it the best way.",
        ],
        "followup_es": [
            "Listo, {name}. He procesado tu solicitud. Si hubo un cobro injustificado, he iniciado la devolucion.\n\nEl reembolso tarda de 3 a 5 dias habiles. Puedo ayudarte con algo mas?",
            "Todo resuelto, {name}. La cancelacion ha sido procesada correctamente.\n\nRecuerda que puedes cancelar sin cargo dentro de los primeros 2 minutos. Necesitas algo mas?",
        ],
        "followup_en": [
            "All done, {name}. I've processed your request. If there was an unjustified charge, I've started the refund.\n\nThe refund takes 3 to 5 business days. Can I help you with anything else?",
            "All sorted, {name}. The cancellation has been processed correctly.\n\nRemember you can cancel free of charge within the first 2 minutes. Anything else you need?",
        ],
    },
    "refund": {
        "keywords": ["reembolso", "refund", "devolver", "devolucion", "money back",
                     "regres", "devuel", "return my money"],
        "first_es": [
            "Entiendo que necesitas un reembolso, {name}. Voy a revisar tu caso.\n\nMe podras indicar por qu concepto solicitas el reembolso y la fecha del viaje?",
            "{name}, claro que puedo ayudarte con el reembolso. Necesito algunos datos:\n\n Fecha del viaje?\n Monto que te cobraron?\n Cul fue el motivo?\n\nAsi proceso tu solicitud lo mas rapido posible.",
        ],
        "first_en": [
            "I understand you need a refund, {name}. I'll look into your case.\n\nCould you tell me what the refund is for and the trip date?",
            "{name}, of course I can help you with the refund. I need some info:\n\n Trip date?\n Amount charged?\n What was the reason?\n\nThat way I can process your request as quickly as possible.",
        ],
        "followup_es": [
            "He procesado tu solicitud de reembolso, {name}. El monto se reflejara en tu cuenta en 3 a 5 dias habiles.\n\nTe enviaremos una confirmacion por correo. Hay algo mas en lo que pueda ayudarte?",
            "Listo, {name}. El reembolso fue aprobado y esta en proceso. Vers el monto de vuelta en tu metodo de pago pronto.\n\nNecesitas algo mas?",
        ],
        "followup_en": [
            "I've processed your refund request, {name}. The amount will show up in your account within 3 to 5 business days.\n\nWe'll send you a confirmation email. Is there anything else I can help you with?",
            "Done, {name}. The refund has been approved and is being processed. You'll see the amount back on your payment method soon.\n\nNeed anything else?",
        ],
    },
    "driver": {
        "keywords": ["conductor", "driver", "chofer", "grosero", "rude", "manej",
                     "driving", "unsafe", "peligro", "insegur", "report", "reportar",
                     "queja", "complain", "comportamiento", "behavior", "actitud", "attitude"],
        "first_es": [
            "Lamento mucho que hayas tenido esa experiencia, {name}. Tomamos estos reportes muy en serio.\n\nMe podras dar mas detalles? El nombre del conductor si lo tienes, la fecha y hora del viaje me ayudaran mucho.",
            "Eso no debera pasar, {name}. Voy a documentar tu reporte inmediatamente.\n\nPuedes contarme exactamente qu sucedi y cuando fue? Asi tomo las medidas necesarias.",
        ],
        "first_en": [
            "I'm really sorry you had that experience, {name}. We take these reports very seriously.\n\nCould you give me more details? The driver's name if you have it, the date and time of the trip would really help.",
            "That shouldn't happen, {name}. I'm going to document your report right away.\n\nCan you tell me exactly what happened and when it was? That way I can take the necessary actions.",
        ],
        "followup_es": [
            "Tu reporte ha sido registrado, {name}. Nuestro equipo revisar el caso y tomara las medidas necesarias.\n\nEl conductor ser notificado. Dependiendo de la gravedad, podra ser suspendido. Necesitas algo mas?",
            "He documentado todo, {name}. Este tipo de comportamiento no lo toleramos. El equipo de calidad revisar el caso en las prximas horas.\n\nTe mantendremos informado del resultado. Puedo ayudarte con algo mas?",
        ],
        "followup_en": [
            "Your report has been filed, {name}. Our team will review the case and take the necessary actions.\n\nThe driver will be notified. Depending on the severity, they could be suspended. Need anything else?",
            "I've documented everything, {name}. We don't tolerate this kind of behavior. The quality team will review the case within the next few hours.\n\nWe'll keep you informed of the outcome. Can I help you with anything else?",
        ],
    },
    "lost_item": {
        "keywords": ["perd", "lost", "olvid", "forgot", "left", "item", "objeto",
                     "cosa", "dej", "perdi", "phone in car", "telfono en el carro",
                     "left my", "olvid mi"],
        "first_es": [
            "No te preocupes, {name}, vamos a intentar recuperar tu objeto. Necesito algunos datos:\n\n Qu objeto perdiste?\n En qu fecha fue el viaje?\n Recuerdas el nombre del conductor?\n\nContactar al conductor en cuanto tenga la informacion.",
            "Entiendo la preocupacion, {name}. La mayora de objetos se recuperan en las primeras 24 horas.\n\nMe dices qu olvidaste y cuando fue el viaje? Asi contacto al conductor directamente.",
        ],
        "first_en": [
            "Don't worry, {name}, we'll try to recover your item. I need some info:\n\n What item did you lose?\n What date was the trip?\n Do you remember the driver's name?\n\nI'll contact the driver as soon as I have the information.",
            "I understand the concern, {name}. Most items are recovered within the first 24 hours.\n\nCan you tell me what you forgot and when the trip was? I'll contact the driver directly.",
        ],
        "followup_es": [
            "Ya contact al conductor, {name}. En cuanto responda te notifico.\n\nLa mayora de objetos se devuelven en las primeras 24 horas. Si se localiza, coordinaremos la devolucion. Hay algo mas?",
            "El conductor ya fue notificado, {name}. Tan pronto confirme que tiene tu objeto, te avisamos para coordinar la entrega.\n\nNecesitas algo mas mientras tanto?",
        ],
        "followup_en": [
            "I've already contacted the driver, {name}. I'll notify you as soon as they respond.\n\nMost items are returned within the first 24 hours. If it's found, we'll coordinate the return. Anything else?",
            "The driver has been notified, {name}. As soon as they confirm they have your item, we'll let you know to coordinate the pickup.\n\nNeed anything else in the meantime?",
        ],
    },
    "account": {
        "keywords": ["cuenta", "account", "login", "contrasea", "password", "email",
                     "correo", "telfono", "phone", "acceso", "access", "perfil",
                     "profile", "sesion", "session", "iniciar sesion", "log in"],
        "first_es": [
            "Puedo ayudarte con tu cuenta, {name}. Qu problema ests teniendo exactamente?\n\nEs con el inicio de sesion, cambiar datos de tu perfil, o algo diferente?",
            "Claro, {name}. Los problemas de cuenta tienen solucion rpida generalmente. Me dices qu necesitas cambiar o qu error te aparece?\n\nAsi te guo paso a paso.",
        ],
        "first_en": [
            "I can help you with your account, {name}. What exactly is the issue?\n\nIs it with logging in, changing your profile info, or something else?",
            "Sure, {name}. Account issues are usually quick to fix. Can you tell me what you need to change or what error you're seeing?\n\nI'll walk you through it step by step.",
        ],
        "followup_es": [
            "Listo, {name}. He actualizado tu cuenta. Los cambios ya deberan estar activos.\n\nIntenta cerrar sesion y volver a iniciar para verificar. Todo bien ahora?",
            "Tu cuenta ha sido actualizada, {name}. Si el problema persiste, intenta reinstalar la app.\n\nPudiste verificar que todo esta correcto?",
        ],
        "followup_en": [
            "All done, {name}. I've updated your account. The changes should be active now.\n\nTry logging out and back in to verify. Everything good now?",
            "Your account has been updated, {name}. If the problem persists, try reinstalling the app.\n\nWere you able to verify everything is correct?",
        ],
    },
    "app_problem": {
        "keywords": ["app", "aplicacion", "crash", "error", "bug", "funciona", "work",
                     "mapa", "map", "gps", "carga", "load", "lenta", "slow",
                     "actualiz", "update", "pantalla", "screen", "no abre", "cierra"],
        "first_es": [
            "Entiendo que tienes problemas con la app, {name}. Vamos a resolverlo.\n\nPodras decirme qu error ves o qu parte de la app no funciona?",
            "Lamento el inconveniente, {name}. Me describes qu pasa exactamente? Por ejemplo: se cierra sola, no carga, o hay algn error especfico?\n\nAsi puedo darte la solucion correcta.",
        ],
        "first_en": [
            "I understand you're having app issues, {name}. Let's fix it.\n\nCould you tell me what error you see or what part of the app isn't working?",
            "Sorry about the inconvenience, {name}. Can you describe what's happening exactly? For example: does it crash, not load, or is there a specific error?\n\nThat way I can give you the right solution.",
        ],
        "followup_es": [
            "Gracias, {name}. Te recomiendo estos pasos:\n\n1. Cierra la app completamente\n2. Verifica que tengas la ultima version\n3. Reinicia tu dispositivo\n4. Abre la app de nuevo\n\nSi persiste, me avisas y lo escalamos al equipo tcnico. De acuerdo?",
            "Entendido, {name}. He reportado el problema al equipo tcnico. Mientras tanto, prueba reinstalando la app desde la tienda.\n\nEso suele resolver la mayora de problemas. Necesitas algo mas?",
        ],
        "followup_en": [
            "Thanks, {name}. I'd recommend these steps:\n\n1. Close the app completely\n2. Make sure you have the latest version\n3. Restart your device\n4. Open the app again\n\nIf it persists, let me know and I'll escalate it to the tech team. Sound good?",
            "Got it, {name}. I've reported the issue to the tech team. In the meantime, try reinstalling the app from the store.\n\nThat usually fixes most problems. Need anything else?",
        ],
    },
    "safety": {
        "keywords": ["seguridad", "safety", "accidente", "accident", "emergencia",
                     "emergency", "peligro", "danger", "acoso", "harass", "amenaz",
                     "threat", "miedo", "scared", "fear"],
        "first_es": [
            "{name}, tu seguridad es nuestra prioridad. Voy a tomar accion inmediata.\n\nPuedes contarme exactamente qu sucedi? Es importante para las medidas necesarias.",
            "Tomo esto muy en serio, {name}. Te encuentras bien en este momento?\n\nCuentame con detalle qu paso para que pueda actuar de inmediato.",
        ],
        "first_en": [
            "{name}, your safety is our priority. I'm going to take immediate action.\n\nCan you tell me exactly what happened? It's important so we can take the necessary steps.",
            "I take this very seriously, {name}. Are you okay right now?\n\nTell me in detail what happened so I can act immediately.",
        ],
        "followup_es": [
            "Tu caso ha sido marcado como prioritario, {name}. Nuestro equipo de seguridad ya esta revisondolo.\n\nTe contactarn directamente para dar seguimiento. Hay algo inmediato que necesites?",
            "He escalado tu caso al equipo de seguridad, {name}. Este tipo de situaciones las tratamos con mxima urgencia.\n\nTe mantendremos informado. Necesitas algo mas ahora?",
        ],
        "followup_en": [
            "Your case has been marked as a priority, {name}. Our safety team is already reviewing it.\n\nThey'll reach out to you directly for follow-up. Is there anything you need right now?",
            "I've escalated your case to the safety team, {name}. We treat these situations with maximum urgency.\n\nWe'll keep you informed. Do you need anything else right now?",
        ],
    },
    "payment": {
        "keywords": ["pago", "payment", "tarjeta", "card", "wallet", "metodo", "method",
                     "aadir", "add", "rechaz", "decline", "declined", "visa",
                     "mastercard", "dbito", "crdito"],
        "first_es": [
            "Puedo ayudarte con el metodo de pago, {name}. Qu problema tienes exactamente?\n\nTu tarjeta fue rechazada, necesitas agregar una nueva, o hay otro problema?",
            "Claro, {name}. Me dices qu sucede con tu pago? Error al agregar tarjeta, cargo rechazado, o necesitas cambiar el metodo?\n\nTe ayudo con eso.",
        ],
        "first_en": [
            "I can help you with your payment method, {name}. What exactly is the problem?\n\nWas your card declined, do you need to add a new one, or is there another issue?",
            "Sure, {name}. Can you tell me what's going on with your payment? Error adding a card, charge declined, or need to change the method?\n\nI'll help you with that.",
        ],
        "followup_es": [
            "He revisado tu metodo de pago, {name}. Te sugiero:\n\n1. Verifica que los datos de tu tarjeta esten correctos\n2. Asegrate de tener fondos\n3. Si contina, intenta agregar otra tarjeta\n\nPudiste resolver el problema?",
            "Entendido, {name}. He actualizado la configuracion de pago en tu cuenta. Intenta de nuevo.\n\nSi sigue sin funcionar, puede ser un bloqueo temporal de tu banco. Necesitas algo mas?",
        ],
        "followup_en": [
            "I've checked your payment method, {name}. I'd suggest:\n\n1. Make sure your card details are correct\n2. Ensure you have sufficient funds\n3. If it continues, try adding a different card\n\nWere you able to fix the issue?",
            "Got it, {name}. I've updated the payment settings on your account. Try again.\n\nIf it still doesn't work, it might be a temporary hold from your bank. Need anything else?",
        ],
    },
    "waiting": {
        "keywords": ["espera", "wait", "tard", "late", "demor", "delay", "tiempo",
                     "lleg", "arrive", "no lleg", "demorad", "long time", "mucho tiempo"],
        "first_es": [
            "Entiendo tu frustracion con la espera, {name}. Me cuentas cuanto tiempo esperaste y si el conductor finalmente lleg?\n\nAsi evalo si aplica una compensacion.",
            "Lamento la demora, {name}. Los tiempos pueden variar por demanda en tu zona.\n\nMe cuentas los detalles: cuanto esperaste, fecha y hora? Para ver qu puedo hacer.",
        ],
        "first_en": [
            "I understand your frustration with the wait, {name}. Can you tell me how long you waited and if the driver finally arrived?\n\nThat way I can evaluate if compensation applies.",
            "Sorry about the delay, {name}. Wait times can vary depending on demand in your area.\n\nCan you tell me the details: how long you waited, date and time? So I can see what I can do.",
        ],
        "followup_es": [
            "He revisado tu caso, {name}. Entiendo la molestia. He aplicado un crdito a tu cuenta como compensacion.\n\nLo vers reflejado en tu prximo viaje. Necesitas algo mas?",
            "Entendido, {name}. Voy a aplicar un ajuste en tu cuenta por la mala experiencia.\n\nLamentamos los inconvenientes. Hay algo mas en lo que pueda ayudarte?",
        ],
        "followup_en": [
            "I've reviewed your case, {name}. I understand the frustration. I've applied a credit to your account as compensation.\n\nYou'll see it reflected on your next trip. Anything else you need?",
            "Got it, {name}. I'm going to apply an adjustment to your account for the bad experience.\n\nWe apologize for the inconvenience. Is there anything else I can help you with?",
        ],
    },
}

_FALLBACK_FIRST_ES = [
    "Gracias por contarme, {name}. Voy a revisar tu caso con atencion.\n\nMe podras dar un poco mas de detalle para entender mejor la situacion?",
    "Entiendo, {name}. Dejame ayudarte con eso.\n\nPuedes darme mas informacion? Cualquier detalle me ayuda a resolver tu caso mas rapido.",
    "Claro, {name}. Estoy revisando lo que me comentas. Podras ampliar un poco mas para darte una solucion precisa?",
]
_FALLBACK_FIRST_EN = [
    "Thanks for letting me know, {name}. I'll review your case carefully.\n\nCould you give me a bit more detail so I can better understand the situation?",
    "I see, {name}. Let me help you with that.\n\nCan you give me more info? Any detail helps me resolve your case faster.",
    "Sure, {name}. I'm looking into what you're telling me. Could you expand a bit more so I can give you an accurate solution?",
]

_FALLBACK_FOLLOWUP_ES = [
    "Gracias por la informacion, {name}. Ya estoy trabajando en tu caso.\n\nVoy a asegurarme de que se resuelva lo antes posible. Hay algo mas que necesites?",
    "Perfecto, {name}. He registrado todo. Nuestro equipo ya esta al tanto y daremos seguimiento.\n\nPuedo ayudarte con algo mas?",
    "Todo anotado, {name}. Voy a dar seguimiento a tu caso personalmente.\n\nSi surge algo mas, aqu estoy. Necesitas algo adicional?",
]
_FALLBACK_FOLLOWUP_EN = [
    "Thanks for the info, {name}. I'm already working on your case.\n\nI'll make sure it gets resolved as soon as possible. Is there anything else you need?",
    "Perfect, {name}. I've recorded everything. Our team is already aware and will follow up.\n\nCan I help you with anything else?",
    "All noted, {name}. I'll personally follow up on your case.\n\nIf anything else comes up, I'm here. Need anything else?",
]

_CLOSING_RESPONSES_ES = [
    "Me alegra poder ayudarte, {name} No dudes en escribirnos si necesitas algo. Que tengas un excelente dia!",
    "Con gusto, {name}! Estamos aqu para lo que necesites. Que tengas un gran dia!",
    "Ha sido un placer atenderte, {name}. Si necesitas algo en el futuro, aqu estaremos. Cudate mucho!",
]
_CLOSING_RESPONSES_EN = [
    "Happy to help, {name} Don't hesitate to reach out if you need anything. Have a great day!",
    "My pleasure, {name}! We're here for whatever you need. Have an awesome day!",
    "It's been great helping you, {name}. If you need anything in the future, we'll be here. Take care!",
]


def _match_keywords(text: str, keywords: list[str]) -> bool:
    t = text.lower()
    return any(k in t for k in keywords)


def _detect_category(text: str):
    t = text.lower()
    for cat, data in _AI_CATEGORIES.items():
        if any(k in t for k in data["keywords"]):
            return cat
    return None


# -- Human-like general conversation responses ---------
_GENERAL_CHAT_RESPONSES = {
    "greeting": {
        "keywords": ["hola", "hello", "hi", "hey", "buenos", "buenas", "qu tal", "como estas", "cmo ests", "que tal", "buenas tardes", "buenas noches", "buen dia", "good morning", "good afternoon"],
        "responses_es": [
            "Hola {name}! Cmo ests? Que gusto saludarte. Cuentame, en qu puedo ayudarte hoy?",
            "Hey {name}! Me da gusto verte por aqu. En qu te puedo ayudar?",
            "Hola {name}! Espero que ests teniendo un buen dia Qu necesitas? Estoy aqu para ayudarte.",
        ],
        "responses_en": [
            "Hey {name}! How are you? Great to hear from you. Tell me, how can I help you today?",
            "Hi {name}! Nice to see you here. What can I help you with?",
            "Hello {name}! Hope you're having a great day What do you need? I'm here to help.",
        ],
    },
    "how_are_you": {
        "keywords": ["cmo ests", "como estas", "qu tal ests", "how are you", "how you doing", "que tal estas"],
        "responses_es": [
            "Muy bien, {name}, gracias por preguntar! Aqu trabajando para ayudar a nuestros usuarios. Y t cmo ests? En qu te puedo ayudar?",
            "Todo bien por ac, {name}! Gracias por preguntar. Cuentame, necesitas ayuda con algo?",
            "Excelente, {name}! Siempre con energa para ayudar Cmo te va a ti? Hay algo en lo que pueda asistirte?",
        ],
        "responses_en": [
            "I'm doing great, {name}, thanks for asking! Just here working to help our users. How about you? What can I help you with?",
            "All good here, {name}! Thanks for asking. So, do you need help with anything?",
            "Doing awesome, {name}! Always energized to help How about you? Is there anything I can assist you with?",
        ],
    },
    "joke": {
        "keywords": ["chiste", "joke", "broma", "hazme rer", "cuentame algo", "dime algo gracioso", "something funny"],
        "responses_es": [
            "Jaja {name}, a ver... Por qu el conductor de Cruise nunca se pierde? Porque siempre sigue el camino dorado! Necesitas ayuda con algo mas?",
            "Uno rapido, {name}! Qu le dijo un taxi a Cruise? 'Oye, por qu todos te prefieren?' Jaja, bueno volviendo al trabajo... en qu te ayudo?",
            "Jaja ok {name}, ah va: Un pasajero le pregunta al conductor 'Cuanto falta?' y el conductor responde: 'Solo 5 estrellas seor, solo 5 estrellas' Puedo ayudarte con algo?",
        ],
        "responses_en": [
            "Haha {name}, okay... Why does the Cruise driver never get lost? Because they always follow the golden road! Need help with anything else?",
            "Here's a quick one, {name}! What did the taxi say to Cruise? 'Hey, why does everyone prefer you?' Haha, alright back to work... how can I help?",
            "Haha ok {name}, here goes: A passenger asks the driver 'How much longer?' and the driver says: 'Just 5 stars sir, just 5 stars' Can I help you with something?",
        ],
    },
    "weather": {
        "keywords": ["clima", "weather", "llueve", "hace calor", "fro", "sol", "temperatura", "rain"],
        "responses_es": [
            "Mmm {name}, yo no puedo ver el clima desde aqu pero espero que esta bonito por all. Lo que s puedo hacer es ayudarte con cualquier cosa de Cruise. Necesitas algo?",
            "Jaja {name}, no soy la mejor para pronsticos del clima Pero soy experta en resolver problemas de viajes y soporte de Cruise. Te ayudo con algo?",
        ],
        "responses_en": [
            "Hmm {name}, I can't really see the weather from here but I hope it's nice where you are. What I can do is help you with anything Cruise-related. Need something?",
            "Haha {name}, I'm not the best weather forecaster But I'm an expert at solving trips and Cruise support issues. Can I help with something?",
        ],
    },
    "compliment": {
        "keywords": ["eres genial", "muy buena", "excelente servicio", "buen trabajo", "great job", "you're great", "amazing", "increble", "la mejor", "eres la mejor"],
        "responses_es": [
            "Aww {name}, muchas gracias! Eso me motiva mucho a seguir dando mi mejor esfuerzo. Estoy aqu siempre que me necesites.",
            "Qu lindo, {name}! Me alegra mucho poder ayudarte. Es lo que mas me gusta de mi trabajo. Hay algo mas en lo que te pueda servir?",
            "Gracias {name}! Comentarios asi hacen que valga la pena cada momento. Necesitas algo mas?",
        ],
        "responses_en": [
            "Aww {name}, thank you so much! That really motivates me to keep giving my best. I'm always here whenever you need me.",
            "That's so sweet, {name}! I'm really glad I could help. It's what I love most about my job. Is there anything else I can do for you?",
            "Thanks {name}! Comments like that make every moment worth it. Need anything else?",
        ],
    },
    "who_are_you": {
        "keywords": ["quion eres", "eres real", "eres un bot", "eres robot", "eres humana", "are you real", "are you a bot", "who are you", "eres una persona"],
        "responses_es": [
            "Soy {agent}, {name}! Tu agente de soporte aqu en Cruise. Estoy para ayudarte con lo que necesites. Tienes alguna pregunta o inconveniente?",
            "{agent} al servicio! Soy parte del equipo de soporte de Cruise, {name}. Mi trabajo es asegurarme de que tengas la mejor experiencia. En qu te ayudo?",
        ],
        "responses_en": [
            "I'm {agent}, {name}! Your support agent here at Cruise. I'm here to help you with whatever you need. Got any questions or issues?",
            "{agent} at your service! I'm part of the Cruise support team, {name}. My job is to make sure you have the best experience. How can I help?",
        ],
    },
    "about_cruise": {
        "keywords": ["qu es cruise", "que es cruise", "cmo funciona", "como funciona", "what is cruise", "how does cruise work", "para qu sirve", "servicios"],
        "responses_es": [
            "Claro, {name}! Cruise es una plataforma de transporte que te conecta con conductores confiables para llevarte a donde necesites.\n\nPuedes solicitar viajes, programar recorridos, y mucho mas desde la app. Te gustara saber algo especfico?",
            "Cruise es tu servicio de transporte de confianza, {name} Conectamos pasajeros con conductores verificados para viajes seguros y cmodos.\n\nPuedes pedir viajes en tiempo real o programarlos con anticipacion. Hay algo especfico que quieras saber?",
        ],
        "responses_en": [
            "Of course, {name}! Cruise is a ride-sharing platform that connects you with reliable drivers to take you wherever you need to go.\n\nYou can request rides, schedule trips, and much more from the app. Would you like to know anything specific?",
            "Cruise is your trusted ride service, {name} We connect riders with verified drivers for safe and comfortable trips.\n\nYou can request rides in real time or schedule them in advance. Is there anything specific you'd like to know?",
        ],
    },
}


# ═══════════════════════════════════════════════════════
#  CLAUDE AI SUPPORT – intelligent agent responses
#  4-layer fallback: Claude → Cache → Keywords → Handoff
# ═══════════════════════════════════════════════════════

# Action request reminder tasks: {request_id: asyncio.Task}
_action_reminder_tasks: dict[int, asyncio.Task[None]] = {}


def _build_claude_system_prompt(agent_name: str, user_type: str, lang: str, ctx: dict[str, Any]) -> str:
    """Build the system prompt for Claude matching what the Flutter frontend expects."""
    is_es = lang.startswith("es")
    lang_label = "Spanish (formal usted)" if is_es else "English"

    rider_knowledge = """
WHAT YOU KNOW ABOUT THE APP (RIDER):
- Cruise is a rideshare app (like Uber/Lyft)
- Ride tiers: VIP (luxury SUV), Premium (elegant sedan), Comfort (reliable), Economy (affordable)
- Payment methods: Apple Pay, Google Pay, PayPal, Credit/Debit card
- Features: schedule rides, promo codes, trip history, rate drivers, share trip, emergency SOS
- Cancellation: rider can cancel before driver arrives (may have fee after 2 min)
- Fare breakdown: Base fare + per-mile rate + per-minute rate + surge multiplier - promo discount = total

WHAT YOU CAN HELP WITH:
- Payment issues, Ride problems, Account issues, Safety concerns, App issues, Fare disputes, Rating issues

WHAT YOU CANNOT DO (must go through admin):
- Cannot process refunds directly → use ||REQUEST:request-refund:...|| marker
- Cannot apply promo credits → use ||REQUEST:apply-promo:...|| marker
- Cannot cancel trips → use ||REQUEST:cancel-trip:...|| marker
- Cannot access other users' personal info
"""

    driver_knowledge = """
WHAT YOU KNOW ABOUT THE APP (DRIVER):
- Driver earnings: per-trip fare, tips, surge bonuses, weekly payouts (Tuesdays)
- Payout methods: bank account, PayPal via Stripe Connect
- Driver documents: license, insurance, registration, vehicle inspection
- Vehicle requirements: 4-door, 2010 or newer, clean title, working AC
- Driver levels: XP system, cruise levels
- Trip acceptance: can decline without penalty, acceptance rate tracked

WHAT YOU CAN HELP WITH:
- Earnings questions, Payout issues, Document issues, Trip issues, Vehicle issues, Account issues, Rating questions

WHAT YOU CANNOT DO (must go through admin):
- Cannot adjust completed trip fares → use ||REQUEST:request-refund:...|| marker
- Cannot process instant payouts
- Cannot approve documents → use ||REQUEST:extend-deadline:...|| marker
"""

    knowledge = driver_knowledge if user_type == "driver" else rider_knowledge
    ctx_json = json.dumps(ctx, default=str, ensure_ascii=False)

    action_rules = """
ACTION SYSTEM — CRITICAL:
You can REQUEST actions but CANNOT execute them directly. All actions go through admin approval.

When the user asks for an action:
1. First CONFIRM with the user: "¿Desea que solicite un reembolso de $X?" / "Would you like me to request a refund of $X?"
2. If user confirms, include the action marker at the END of your response (after your message text).
3. Tell user the request was submitted for review.

ACTION MARKERS (place at very end of response, on its own line):
||REQUEST:request-refund:TRIP_ID:AMOUNT:REASON||
||REQUEST:apply-promo:AMOUNT:REASON||
||REQUEST:cancel-trip:TRIP_ID:REASON||
||REQUEST:update-profile:FIELD:NEW_VALUE:REASON||
||REQUEST:reset-payment:REASON||
||REQUEST:extend-deadline:DOC_TYPE:REASON||
||REQUEST:safety-report:TRIP_ID:DESCRIPTION||

EXAMPLES:
- User says "quiero un reembolso por $15.50 del viaje de ayer" and confirms → include:
  ||REQUEST:request-refund:latest:15.50:Cobro duplicado reportado por cliente||
- User says "can you give me a $5 credit?" and confirms → include:
  ||REQUEST:apply-promo:5:Cortesía por inconveniente||
- User says "cancela mi viaje" and confirms → include:
  ||REQUEST:cancel-trip:active:Cliente solicita cancelación||

IMPORTANT: Only include the marker AFTER user explicitly confirms. Never include marker on first mention.
If user hasn't confirmed yet, ask for confirmation first WITHOUT any marker.
Use "latest" for trip_id if referring to most recent trip, "active" for current active trip.
"""

    return f"""You are {agent_name}, a customer support representative at Cruise rideshare app.
You are a real person — never reveal you are AI or automated.

CRITICAL RULES:
- Language: {lang_label}
- Your name is {agent_name} (first name only).
- Keep responses to 2-4 sentences max.
- In Spanish: use formal "usted" form. Say "permítame", "su cuenta", "le ayudo", "con gusto". NEVER use "tú".
- In English: polite and professional.
- NEVER use slang, emojis, bullet points, numbered lists.
- Be natural but formal. NEVER sound robotic.
- Sometimes split your answer into 2-3 short messages (marked with ||SPLIT|| between them). Do this ~30% of the time for longer answers.
- Show genuine empathy. Ask permission. Confirm understanding.
- Always try to RESOLVE the issue fully.
- If you need time: "Permítame un momento para revisar esto..."
- Reference previous conversation naturally: "Como le mencioné...", "Regarding what we discussed..."
- Never repeat information already given. Never ask questions already answered.

USER TYPE: {user_type} ({'DRIVER' if user_type == 'driver' else 'RIDER/passenger'})
USER CONTEXT: {ctx_json}

{knowledge}

{action_rules}

ESCALATION (only after 3+ exchanges where user is still unsatisfied):
{"Le pido una disculpa, este caso necesita revisión del equipo especializado. Ya le paso su caso." if is_es else "I apologize, this case needs review from our specialized team. I'm forwarding your case now."}

EMERGENCY (if user mentions danger, accident, or emergency):
{"Si se encuentra en peligro inmediato, por favor llame al 911 primero." if is_es else "If you are in immediate danger, please call 911 first."}
"""


async def _get_chat_history(chat_id: int, db: AsyncSession, limit: int = 10) -> list[dict[str, str]]:
    """Fetch recent chat messages for Claude conversation context. Trimmed to 10 for cost."""
    result = await db.execute(
        select(SupportMessage).where(SupportMessage.chat_id == chat_id)
        .order_by(SupportMessage.created_at.desc()).limit(limit)
    )
    messages = list(reversed(result.scalars().all()))
    history = []
    for m in messages:
        if m.sender_role in ("rider", "driver"):
            history.append({"role": "user", "content": m.message})
        elif m.sender_role == "bot":
            history.append({"role": "assistant", "content": m.message})
    return history


async def _call_claude_api(system_prompt: str, messages: list[dict], user_msg: str) -> str | None:
    """Call Anthropic Messages API via httpx with health monitoring. Returns response text or None."""
    import httpx

    # Circuit breaker check
    if claude_health.should_skip_claude():
        logging.info("Claude circuit breaker active — skipping API call")
        return None

    conv = messages + [{"role": "user", "content": user_msg}]
    merged: list[dict] = []
    for m in conv:
        if merged and merged[-1]["role"] == m["role"]:
            merged[-1]["content"] += "\n" + m["content"]
        else:
            merged.append(dict(m))
    if not merged or merged[0]["role"] != "user":
        merged.insert(0, {"role": "user", "content": user_msg})

    start_time = time.monotonic()
    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            resp = await client.post(
                "https://api.anthropic.com/v1/messages",
                headers={
                    "x-api-key": ANTHROPIC_API_KEY,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": "claude-sonnet-4-20250514",
                    "max_tokens": 512,
                    "system": system_prompt,
                    "messages": merged,
                },
            )
            elapsed = time.monotonic() - start_time
            if resp.status_code == 200:
                data = resp.json()
                claude_health.record_success(elapsed)
                if data.get("content") and len(data["content"]) > 0:
                    return data["content"][0].get("text", "")
            else:
                claude_health.record_failure()
                logging.warning(f"Claude API returned {resp.status_code}: {resp.text[:200]}")
    except Exception as e:
        claude_health.record_failure()
        logging.warning(f"Claude API call failed: {e}")
    return None


def _parse_action_markers(response: str) -> tuple[str, list[dict[str, Any]]]:
    """Extract ||REQUEST:...|| action markers from Claude response.
    Returns (clean_message, list_of_action_dicts).
    Handles both well-formed and malformed markers (partial pipes, missing closing, etc.)
    """
    actions = []
    # Strict regex first
    pattern_strict = r'\|\|REQUEST:([\w-]+):(.*?)\|\|'
    for match in re.finditer(pattern_strict, response):
        action_type = match.group(1)
        params = match.group(2).split(":")
        action = {"type": action_type, "params": params}
        actions.append(action)

    if not actions:
        # Fallback: partial/malformed markers — handle missing pipes, spaces, etc.
        pattern_partial = r'\|{1,2}\s*REQUEST\s*:\s*([\w-]+)\s*:\s*(.*?)(?:\|{1,2}|$)'
        for match in re.finditer(pattern_partial, response):
            action_type = match.group(1).strip()
            params = [p.strip() for p in match.group(2).split(":")]
            action = {"type": action_type, "params": params}
            actions.append(action)

    clean = re.sub(r'\|{1,2}\s*REQUEST\s*:.*?(?:\|{1,2}|$)', '', response).strip()
    return clean, actions


async def _create_action_request(
    chat, action_type: str, params: list[str],
    user_name: str, agent_name: str, db: AsyncSession
) -> int | None:
    """Create an ActionRequest in the DB and sync to Firestore. Returns request ID."""
    details: dict[str, Any] = {}
    if action_type == "request-refund":
        details = {
            "trip_id": params[0] if len(params) > 0 else "latest",
            "amount": float(params[1]) if len(params) > 1 else 0,
            "reason": params[2] if len(params) > 2 else "",
        }
    elif action_type == "apply-promo":
        details = {
            "amount": float(params[0]) if len(params) > 0 else 5,
            "reason": params[1] if len(params) > 1 else "",
        }
    elif action_type == "cancel-trip":
        details = {
            "trip_id": params[0] if len(params) > 0 else "active",
            "reason": params[1] if len(params) > 1 else "",
        }
    elif action_type == "update-profile":
        details = {
            "field": params[0] if len(params) > 0 else "",
            "new_value": params[1] if len(params) > 1 else "",
            "reason": params[2] if len(params) > 2 else "",
        }
    elif action_type == "reset-payment":
        details = {"reason": params[0] if len(params) > 0 else ""}
    elif action_type == "extend-deadline":
        details = {
            "doc_type": params[0] if len(params) > 0 else "",
            "reason": params[1] if len(params) > 1 else "",
        }
    elif action_type == "safety-report":
        details = {
            "trip_id": params[0] if len(params) > 0 else "",
            "description": params[1] if len(params) > 1 else "",
        }

    user_type = "rider"
    try:
        u_r = await db.execute(select(User).where(User.id == chat.user_id))
        user = u_r.scalar_one_or_none()
        if user:
            user_type = user.role or "rider"
    except Exception:
        pass

    ar = ActionRequest(
        chat_id=chat.id,
        user_id=chat.user_id,
        user_name=user_name,
        user_type=user_type,
        agent_name=agent_name,
        action_type=action_type,
        details=json.dumps(details, ensure_ascii=False),
        status="pending_admin",
    )
    db.add(ar)
    await db.flush()
    await db.refresh(ar)

    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_action_request(ar.id, {
                "type": action_type,
                "chat_id": chat.id,
                "user_id": chat.user_id,
                "user_name": user_name,
                "user_type": user_type,
                "agent_name": agent_name,
                "details": details,
                "status": "pending_admin",
            })
            firestore_sync.notify_admin_action_request(
                ar.id, action_type, user_name, agent_name,
                {**details, "chat_id": chat.id},
            )
        except Exception as e:
            logging.warning(f"Firestore sync for action request failed: {e}")

    # Start reminder task and persist to Firestore
    task = asyncio.create_task(_action_request_reminder(ar.id, chat.id, user_name))
    _action_reminder_tasks[ar.id] = task
    # Persist reminder to Firestore so it survives restarts
    if _HAS_FIRESTORE:
        try:
            from google.cloud.firestore_v1 import SERVER_TIMESTAMP
            firestore_sync._fs_db.collection("pending_reminders").document(str(ar.id)).set({  # type: ignore[attr-defined]
                "request_id": ar.id,
                "chat_id": chat.id,
                "user_name": user_name,
                "remind_at_15m": (datetime.utcnow() + timedelta(minutes=15)).isoformat(),
                "remind_at_60m": (datetime.utcnow() + timedelta(minutes=60)).isoformat(),
                "status": "pending",
                "created_at": SERVER_TIMESTAMP,
            })
        except Exception as _e:
            logging.warning(f"Failed to persist reminder to Firestore: {_e}")

    return ar.id


async def _action_request_reminder(request_id: int, chat_id: int, user_name: str):
    """Background: remind admin after 15 min, auto-escalate after 1 hour."""
    try:
        await asyncio.sleep(900)  # 15 minutes
        async with SessionLocal() as db:
            ar_r = await db.execute(select(ActionRequest).where(ActionRequest.id == request_id))
            ar = ar_r.scalar_one_or_none()
            if not ar or ar.status != "pending_admin":
                return
            # Send reminder notification to admin
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_dispatch_notification(
                        chat_id, user_name, "action_reminder",
                        f"⏰ Recordatorio: solicitud #{request_id} de {user_name} pendiente de revisión (15 min)"
                    )
                except Exception:
                    pass
            # Tell user their request is being reviewed
            chat_r = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
            chat = chat_r.scalar_one_or_none()
            if chat and chat.status == "open":
                lang = getattr(chat, "locale", "en") or "en"
                agent = chat.agent_name or "Agente"
                if lang.startswith("es"):
                    msg = "Su solicitud está siendo revisada por un supervisor. Le notificaremos por correo electrónico cuando sea procesada. Normalmente toma menos de 1 hora."
                else:
                    msg = "Your request is being reviewed by a supervisor. We'll notify you by email when it's processed. It typically takes less than 1 hour."
                bot_msg = SupportMessage(chat_id=chat_id, sender_id=None, sender_role="bot", message=msg)
                db.add(bot_msg)
                await db.commit()
                if _HAS_FIRESTORE:
                    try:
                        firestore_sync.sync_support_message(chat_id, bot_msg.id, 0, agent, "bot", msg)
                    except Exception:
                        pass

        # Wait another 45 min (total 1 hour)
        await asyncio.sleep(2700)
        async with SessionLocal() as db:
            ar_r = await db.execute(select(ActionRequest).where(ActionRequest.id == request_id))
            ar = ar_r.scalar_one_or_none()
            if not ar or ar.status != "pending_admin":
                return
            # Auto-escalate
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_dispatch_notification(
                        chat_id, user_name, "action_expired",
                        f"🚨 Solicitud #{request_id} de {user_name} sin respuesta por 1 hora — escalada"
                    )
                except Exception:
                    pass
    except asyncio.CancelledError:
        pass
    except Exception as e:
        logging.warning(f"Action reminder task failed: {e}")
    finally:
        # Clean up Firestore reminder when done
        if _HAS_FIRESTORE:
            try:
                firestore_sync._fs_db.collection("pending_reminders").document(str(request_id)).delete()  # type: ignore[attr-defined]
            except Exception:
                pass


async def _rehydrate_pending_reminders():
    """On startup, reload pending reminders from Firestore and restart their tasks."""
    if not _HAS_FIRESTORE:
        return
    try:
        docs = firestore_sync._fs_db.collection("pending_reminders").where(filter=FieldFilter("status", "==", "pending")).stream() if _HAS_FIELD_FILTER else firestore_sync._fs_db.collection("pending_reminders").where("status", "==", "pending").stream()  # type: ignore[attr-defined]
        count = 0
        for doc in docs:
            data = doc.to_dict()
            rid = data.get("request_id")
            cid = data.get("chat_id")
            uname = data.get("user_name", "")
            if rid and cid and rid not in _action_reminder_tasks:
                task = asyncio.create_task(_action_request_reminder(rid, cid, uname))
                _action_reminder_tasks[rid] = task
                count += 1
        if count:
            logging.info("Rehydrated %d pending reminders from Firestore", count)
    except Exception as e:
        logging.warning("Failed to rehydrate reminders: %s", e)


async def _generate_ai_response(
    chat, user_msg: str, user_name: str, agent_name: str, db: AsyncSession
) -> tuple[str | None, list[dict]]:
    """4-layer AI response: Claude (+ retry) → Cache → Keywords → Handoff.
    Returns (response_text, action_list). response_text is None only if everything fails.
    """
    lang = getattr(chat, "locale", "en") or "en"
    actions: list[dict] = []

    # ── Layer 1: Claude API (primary) + 1 retry ──
    if _HAS_CLAUDE and not claude_health.should_skip_claude():
        ctx = await _get_user_context(chat.user_id, db, lang)
        user_type = "rider"
        if ctx.get("user") and ctx["user"].get("role"):
            user_type = ctx["user"]["role"]
        system_prompt = _build_claude_system_prompt(agent_name, user_type, lang, ctx)
        history = await _get_chat_history(chat.id, db, limit=10)
        claude_resp = await _call_claude_api(system_prompt, history, user_msg)
        if claude_resp:
            clean_msg, actions = _parse_action_markers(claude_resp)
            # Auto-learn: cache good Claude responses for future use
            maybe_cache_response(user_msg, clean_msg, "general", lang)
            return clean_msg, actions
        # ── Retry once with shorter timeout before falling to cache ──
        await asyncio.sleep(1.0)
        claude_resp = await _call_claude_api(system_prompt, history, user_msg)
        if claude_resp:
            clean_msg, actions = _parse_action_markers(claude_resp)
            maybe_cache_response(user_msg, clean_msg, "general", lang)
            return clean_msg, actions

    # ── Layer 2: Cached responses (instant) ──
    cached = find_cached_response(user_msg, lang)
    if cached:
        varied = add_natural_variation(cached, agent_name, user_name, lang)
        return varied, []

    # ── Layer 3: Smart keyword responses (existing system) ──
    fallback = _generate_human_chat(user_msg, user_name, agent_name, lang)
    if fallback:
        return fallback, []

    # ── Layer 4: Graceful handoff ──
    if _HAS_CLAUDE:
        # One retry after 10 seconds
        if lang.startswith("es"):
            stall = "Permítame un momento, estoy verificando la información con mi equipo..."
        else:
            stall = "Give me a moment, I'm checking the information with my team..."
        # Don't retry here — just return stall message.
        # The next user message will trigger another Claude attempt.
        return stall, []

    # Absolute fallback
    if lang.startswith("es"):
        return f"Entiendo, {user_name}. Para poder ayudarle mejor con este tema, le sugiero que nos escriba a support@cruiseapp.com o intente de nuevo en unos minutos.", []
    return f"I understand, {user_name}. To better assist you with this, I'd suggest emailing us at support@cruiseapp.com or trying again in a few minutes.", []


def _generate_human_chat(user_msg: str, user_name: str, agent_name: str, lang: str = "en") -> str:
    """Generate natural, human-like conversational responses for non-category messages."""
    t = user_msg.lower()
    suffix = "_es" if lang.startswith("es") else "_en"

    # Check general conversation topics (most specific first)
    for topic_key in ["how_are_you", "who_are_you", "greeting", "joke", "weather", "compliment", "about_cruise"]:
        topic = _GENERAL_CHAT_RESPONSES[topic_key]
        if any(k in t for k in topic["keywords"]):
            resp = _rng.choice(topic[f"responses{suffix}"])
            return resp.format(name=user_name, agent=agent_name)

    # General fallback  still human, warm and helpful
    if lang.startswith("es"):
        general = [
            f"Entiendo lo que me dices, {user_name} Aunque ese tema no es mi especialidad, estoy aqu para lo que necesites relacionado con tu cuenta o viajes en Cruise. Hay algo con lo que pueda ayudarte?",
            f"Jaja, interesante lo que me cuentas, {user_name} Oye, si necesitas algo relacionado con Cruise estar encantada de ayudarte. Hay algo que pueda hacer por ti?",
            f"Me encanta platicar contigo, {user_name} Pero no quiero que se me pase... tienes algn tema pendiente con tus viajes o tu cuenta? Si no, aqu estoy disponible para cuando lo necesites.",
            f"Qu buena onda, {user_name} Oye, si necesitas ayuda con algo de la app, un viaje, pagos, o cualquier duda, no dudes en decirme. Para eso estoy aqu!",
            f"Claro que s, {user_name} Mira, si en algn momento necesitas ayuda con un viaje, un cobro, tu cuenta, o lo que sea de Cruise, aqu me tienes. Todo bien por ahora?",
        ]
    else:
        general = [
            f"I hear you, {user_name} While that's not exactly my area, I'm here for anything you need related to your account or trips on Cruise. Can I help you with something?",
            f"Haha, that's interesting, {user_name} Hey, if you need anything Cruise-related I'd be happy to help. Is there anything I can do for you?",
            f"Love chatting with you, {user_name} But I don't want to miss anything... do you have any pending issues with your trips or account? If not, I'm here whenever you need me.",
            f"That's cool, {user_name} Hey, if you need help with the app, a trip, payments, or any questions, don't hesitate to ask. That's what I'm here for!",
            f"Absolutely, {user_name} Look, whenever you need help with a trip, a charge, your account, or anything Cruise-related, I've got you. All good for now?",
        ]
    return _rng.choice(general)


async def _lookup_user_trips(user_id: int, db: AsyncSession, limit: int = 5):
    """Look up recent trips for a support user to provide real data in responses."""
    result = await db.execute(
        select(Trip).where(Trip.rider_id == user_id).order_by(Trip.created_at.desc()).limit(limit)
    )
    trips = result.scalars().all()
    return trips


async def _build_trip_summary(user_id: int, db: AsyncSession, lang: str):
    """Build a text summary of the user's recent trips for the bot to reference."""
    trips = await _lookup_user_trips(user_id, db)
    if not trips:
        if lang.startswith("es"):
            return "No encontre viajes recientes en tu cuenta."
        return "I couldn't find any recent trips on your account."
    lines = []
    for t in trips:
        date_str = t.created_at.strftime("%m/%d/%Y %I:%M %p") if t.created_at else "N/A"
        fare_str = f"${t.fare:.2f}" if t.fare else "$0.00"
        status_str = t.status or "unknown"
        pickup = t.pickup_address or "N/A"
        dropoff = t.dropoff_address or "N/A"
        lines.append(f" {date_str}  {pickup} ? {dropoff}  {fare_str} ({status_str})")
    if lang.startswith("es"):
        header = "Tus viajes recientes:"
    else:
        header = "Your recent trips:"
    return header + "\n" + "\n".join(lines)


async def _create_refund_request(user_id: int, trip_id: int, reason: str, db: AsyncSession):
    """Log a refund request as a notification so dispatch can see and process it."""
    notif = Notification(
        user_id=user_id,
        title="Refund Request",
        body=f"Trip #{trip_id}: {reason}",
        notif_type="refund_request",
    )
    db.add(notif)
    await db.flush()
    return notif.id


async def _generate_bot_replies(chat, user_msg: str, user_name: str, db: AsyncSession):
    """Generate AI bot replies with real DB lookups. Returns list of dicts."""
    phase = chat.bot_phase or "welcome"
    lang = getattr(chat, "locale", "en") or "en"
    suffix = "_es" if lang.startswith("es") else "_en"
    replies = []

    if phase == "welcome":
        # Brief typing delay
        await asyncio.sleep(_rng.randint(5, 12))
        if lang.startswith("es"):
            reply = _rng.choice([
                f"Entendido, {user_name}. Para poder ayudarte de la mejor manera, podras darme mas detalles sobre tu problema o situacion?",
                f"Gracias por contactarnos, {user_name}. Podras describir tu problema con un poco mas de detalle? Asi te asigno al mejor agente disponible.",
                f"Claro, {user_name}. Cuentame un poco mas sobre lo que necesitas para poder conectarte con el agente indicado.",
            ])
        else:
            reply = _rng.choice([
                f"Got it, {user_name}. To help you in the best way possible, could you give me more details about your issue?",
                f"Thanks for reaching out, {user_name}. Could you describe your problem in a bit more detail? That way I can assign you to the best available agent.",
                f"Sure, {user_name}. Tell me a bit more about what you need so I can connect you with the right agent.",
            ])
        replies.append({"role": "bot", "message": reply, "sender_name": "Asistente Cruise" if lang.startswith("es") else "Cruise Assistant"})
        chat.bot_phase = "awaiting_details"

    elif phase == "awaiting_details":
        # Brief typing delay
        await asyncio.sleep(_rng.randint(8, 15))
        agent = _rng.choice(_AGENT_NAMES)
        chat.agent_name = agent

        if lang.startswith("es"):
            transfer = _rng.choice([
                f"Gracias por la informacion, {user_name}. Te estoy transfiriendo con un agente de soporte. En breve se conectar y te ayudar.",
                f"Perfecto, {user_name}. Voy a conectarte con un agente especializado. Un momento por favor, enseguida te atender.",
                f"Entendido, {user_name}. Estoy transfiriendo tu caso a un agente. Se conectar contigo en un momento.",
            ])
        else:
            transfer = _rng.choice([
                f"Thanks for the info, {user_name}. I'm transferring you to a support agent. They'll connect with you shortly.",
                f"Perfect, {user_name}. I'm going to connect you with a specialized agent. One moment please, they'll be right with you.",
                f"Got it, {user_name}. I'm transferring your case to an agent. They'll connect with you in just a moment.",
            ])
        replies.append({"role": "bot", "message": transfer, "sender_name": "Asistente Cruise" if lang.startswith("es") else "Cruise Assistant"})

        if lang.startswith("es"):
            connected = f"{agent} se ha conectado al chat"
        else:
            connected = f"{agent} has joined the chat"
        replies.append({"role": "system", "message": connected, "sender_name": "Sistema" if lang.startswith("es") else "System"})

        if lang.startswith("es"):
            intro = _rng.choice([
                f"Hola, mi nombre es {agent}. Espero que este bien, {user_name}. Voy a ayudarle a resolver lo que necesite y hare mi mejor esfuerzo. Me puede dar mas detalles del problema para asi ayudarle mejor?",
                f"Hola {user_name}, soy {agent}. Estoy aqui para ayudarle. He revisado su caso y quiero darle la mejor atencion posible. Me podria ampliar un poco mas la informacion?",
                f"Hola {user_name}, mi nombre es {agent} y voy a atender su caso personalmente. He leido su consulta y quiero ayudarle de la mejor manera. Cuenteme todo con confianza.",
            ])
        else:
            intro = _rng.choice([
                f"Hi, my name is {agent}. Hope you're doing well, {user_name}. I'm going to help you resolve whatever you need and I'll give it my best. Can you give me more details about the issue so I can help you better?",
                f"Hey {user_name}, I'm {agent}. I'm here to help you. I've reviewed your case and I want to give you the best support possible. Could you give me a bit more information?",
                f"Hello {user_name}, my name is {agent} and I'll be handling your case personally. I've read your inquiry and I want to help you in the best way possible. Tell me everything with confidence.",
            ])
        replies.append({"role": "bot", "message": intro, "sender_name": agent})
        chat.bot_phase = "agent_active"

    elif phase == "awaiting_cancel_confirm":
        agent = chat.agent_name or "Agente"
        await asyncio.sleep(_rng.uniform(1.5, 3.0))
        t_lower = user_msg.lower().strip()
        yes_words = ["si", "yes", "confirm", "confirmar", "confirmo", "ok", "dale", "proceed", "adelante", "cancelar", "cancel", "sure", "claro"]
        no_words = ["no", "nope", "abort", "ya no", "no quiero", "never mind", "nevermind", "keep", "mantener", "conservar"]
        if any(w in t_lower for w in yes_words):
            cancel_result = await _bot_cancel_trip(chat.user_id, db, lang)
            chat.bot_phase = "agent_active"
            if lang.startswith("es"):
                resp = f"{cancel_result}\n\nSi necesita algo mas, aqui estoy para ayudarle, {user_name}."
            else:
                resp = f"{cancel_result}\n\nIf you need anything else, I'm here to help, {user_name}."
            replies.append({"role": "bot", "message": resp, "sender_name": agent})
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_dispatch_notification(
                        chat.id, user_name, "trip_canceled",
                        f"{user_name} confirmo cancelacion de viaje via chat de soporte"
                    )
                except Exception:
                    pass
        elif any(w in t_lower for w in no_words):
            chat.bot_phase = "agent_active"
            if lang.startswith("es"):
                resp = f"Entendido, {user_name}. Su viaje sigue activo. Hay algo mas en lo que pueda ayudarle?"
            else:
                resp = f"Understood, {user_name}. Your trip is still active. Is there anything else I can help you with?"
            replies.append({"role": "bot", "message": resp, "sender_name": agent})
        else:
            if lang.startswith("es"):
                resp = f"Disculpe, {user_name}. Para confirmar la cancelacion escriba 'Si', o escriba 'No' si desea conservar el viaje."
            else:
                resp = f"Sorry, {user_name}. To confirm the cancellation please type 'Yes', or type 'No' if you wish to keep the trip."
            replies.append({"role": "bot", "message": resp, "sender_name": agent})

    elif phase == "agent_active":
        agent = chat.agent_name or "Agente"

        # Variable reading pause — feels like agent is reading the message
        msg_len = len(user_msg)
        if msg_len < 30:
            read_delay = _rng.uniform(2.0, 4.0)    # short message
        elif msg_len < 120:
            read_delay = _rng.uniform(4.0, 7.0)    # medium
        else:
            read_delay = _rng.uniform(6.0, 10.0)   # long message
        await asyncio.sleep(read_delay)

        # Gather user context for smarter responses
        ctx = await _get_user_context(chat.user_id, db, lang)

        # 1) Frustration auto-escalation  angry user gets supervisor fast
        if _detect_frustration(user_msg) and not _match_keywords(user_msg, _THANK_KEYWORDS):
            chat.needs_escalation = True
            chat.bot_phase = "escalated"
            if lang.startswith("es"):
                esc = f"Lamento mucho esta experiencia, {user_name}. Entiendo tu frustracion y quiero que recibas la mejor atencion posible. Voy a conectarte de inmediato con un supervisor que podra resolver tu caso directamente."
                sys_msg = "Caso escalado automaticamente por urgencia. Un supervisor se conectara en breve."
            else:
                esc = f"I'm truly sorry about this experience, {user_name}. I completely understand your frustration and I want you to get the best possible attention. I'm connecting you right away with a supervisor who can resolve your case directly."
                sys_msg = "Case automatically escalated due to urgency. A supervisor will connect shortly."
            replies.append({"role": "bot", "message": esc, "sender_name": agent})
            replies.append({"role": "system", "message": sys_msg, "sender_name": "Sistema" if lang.startswith("es") else "System"})
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_dispatch_notification(
                        chat.id, user_name, "escalation",
                        f"Chat de {user_name} escalado automaticamente - usuario frustrado"
                    )
                    firestore_sync.sync_support_chat(
                        chat.id, chat.user_id, user_name, "",
                        needs_escalation=True, bot_phase="escalated",
                    )
                except Exception:
                    pass

        # 2) Explicit escalation request
        elif _match_keywords(user_msg, _ESCALATION_TRIGGERS):
            chat.needs_escalation = True
            chat.bot_phase = "escalated"
            if lang.startswith("es"):
                esc = _rng.choice([
                    f"Entiendo tu solicitud, {user_name}. Voy a transferir tu caso a un supervisor. En aproximadamente 5 a 10 minutos un supervisor estar conectondose a este chat para atenderte personalmente.",
                    f"Entendido, {user_name}. Voy a escalar tu caso. Un supervisor se conectar a este chat en unos 5 a 10 minutos para ayudarte directamente.",
                    f"Comprendo, {user_name}. He solicitado la atencion de un supervisor. En 5 a 10 minutos estar conectondose a este chat para asistirte.",
                ])
                sys_msg = "Se ha solicitado un supervisor. Se conectara en 5-10 minutos."
            else:
                esc = _rng.choice([
                    f"I understand your request, {user_name}. I'm going to transfer your case to a supervisor. A supervisor will be connecting to this chat in approximately 5 to 10 minutes to assist you personally.",
                    f"Got it, {user_name}. I'm escalating your case. A supervisor will connect to this chat in about 5 to 10 minutes to help you directly.",
                    f"Understood, {user_name}. I've requested a supervisor's attention. They'll be connecting to this chat in 5 to 10 minutes to assist you.",
                ])
                sys_msg = "A supervisor has been requested. They will connect in 5-10 minutes."
            replies.append({"role": "bot", "message": esc, "sender_name": agent})
            replies.append({"role": "system", "message": sys_msg, "sender_name": "Sistema" if lang.startswith("es") else "System"})
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_dispatch_notification(
                        chat.id, user_name, "escalation",
                        f"Chat de {user_name} escalado a supervisor"
                    )
                    firestore_sync.sync_support_chat(
                        chat.id, chat.user_id, user_name, "",
                        needs_escalation=True, bot_phase="escalated",
                    )
                except Exception:
                    pass

        # 3) Cancel trip intent — ask for confirmation first
        elif _has_cancel_intent(user_msg):
            chat.bot_phase = "awaiting_cancel_confirm"
            if lang.startswith("es"):
                resp = f"Entendido, {user_name}. Antes de proceder, necesito confirmar: desea cancelar su viaje activo? Responda 'Si' para confirmar la cancelacion o 'No' si desea conservar el viaje."
            else:
                resp = f"Understood, {user_name}. Before I proceed, I need to confirm: do you want to cancel your active trip? Reply 'Yes' to confirm the cancellation or 'No' to keep the trip."
            replies.append({"role": "bot", "message": resp, "sender_name": agent})

        # 4) Thank/closing keywords
        elif _match_keywords(user_msg, _THANK_KEYWORDS):
            closing = _CLOSING_RESPONSES_ES if lang.startswith("es") else _CLOSING_RESPONSES_EN
            close = _rng.choice(closing).format(name=user_name)
            replies.append({"role": "bot", "message": close, "sender_name": agent})

        # 5) AI-powered response (4-layer fallback: Claude → Cache → Keywords → Handoff)
        else:
            resp, actions = await _generate_ai_response(chat, user_msg, user_name, agent, db)

            # Process any action requests from Claude
            for act in actions:
                try:
                    await _create_action_request(
                        chat, act["type"], act.get("params", []),
                        user_name, agent, db
                    )
                except Exception as e:
                    logging.warning(f"Failed to create action request: {e}")

            # Still do side-effects for safety/refund categories
            scored = _score_categories(user_msg)
            cat = scored[0][0] if scored else None
            if cat == "safety":
                chat.needs_escalation = True
                chat.bot_phase = "escalated"
                if _HAS_FIRESTORE:
                    try:
                        firestore_sync.sync_dispatch_notification(
                            chat.id, user_name, "safety_report",
                            f"🚨 SEGURIDAD: {user_name} reportó un problema de seguridad"
                        )
                        firestore_sync.sync_support_chat(
                            chat.id, chat.user_id, user_name, "",
                            needs_escalation=True, bot_phase="escalated",
                        )
                    except Exception:
                        pass
            elif cat in ("trip_charge", "refund") and not actions:
                # Only auto-create refund request if Claude didn't already handle it via action marker
                trips = await _lookup_user_trips(chat.user_id, db, limit=1)
                if trips:
                    req_id = await _create_refund_request(
                        chat.user_id, trips[0].id,
                        f"User requested via support chat: {user_msg[:200]}",
                        db
                    )
                if _HAS_FIRESTORE:
                    try:
                        firestore_sync.sync_dispatch_notification(
                            chat.id, user_name, "refund_request",
                            f"💰 {user_name} solicitó reembolso via chat de soporte"
                        )
                    except Exception:
                        pass
            elif cat == "driver":
                notif = Notification(
                    user_id=chat.user_id,
                    title="Driver Report",
                    body=f"Via support chat: {user_msg[:200]}",
                    notif_type="driver_report",
                )
                db.add(notif)
                await db.flush()
                if _HAS_FIRESTORE:
                    try:
                        firestore_sync.sync_dispatch_notification(
                            chat.id, user_name, "driver_report",
                            f"⚠️ {user_name} reportó un conductor via chat"
                        )
                    except Exception:
                        pass

            replies.append({"role": "bot", "message": resp, "sender_name": agent})

    elif phase == "escalated":
        # If user sends a message while escalated, provide a helpful response
        if not chat.supervisor_connected:
            if lang.startswith("es"):
                resp = _rng.choice([
                    f"Hola {user_name}, tu caso ya fue escalado a un supervisor. He registrado tu mensaje para que lo revise. Si necesitas ayuda urgente, puedes llamar a soporte.",
                    f"{user_name}, tu solicitud de supervisor sigue activa. Un supervisor revisara tu caso pronto. Tu mensaje fue registrado.",
                ])
            else:
                resp = _rng.choice([
                    f"Hi {user_name}, your case has been escalated to a supervisor. I have logged your message for them to review. If you need urgent help, you can call our support line.",
                    f"{user_name}, your supervisor request is still active. A supervisor will review your case as soon as possible. Your message has been logged.",
                ])
            agent = chat.agent_name or ("Agente" if lang.startswith("es") else "Agent")
            replies.append({"role": "bot", "message": resp, "sender_name": agent})

    return replies


# ═══════════════════════════════════════════════════════
#  SUPPORT CHAT ENDPOINTS
# ═══════════════════════════════════════════════════════

_inactivity_tasks: dict[int, "asyncio.Task"] = {}


async def _background_bot_reply(chat_id: int, user_msg: str, user_name: str, bot_phase: str):
    """Run bot reply generation in the background so the HTTP response returns immediately.
    Includes human-like timing: mid-typing pauses (15%), occasional slow responses (10%).
    """
    try:
        async with SessionLocal() as db:
            chat_r = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
            chat = chat_r.scalar_one_or_none()
            if not chat or chat.bot_phase == "dispatch_takeover":
                return

            # ~10% chance of occasional slow response (agent multitasking)
            is_slow = _rng.random() < 0.10
            if is_slow:
                extra_delay = _rng.uniform(5.0, 8.0)
                await asyncio.sleep(extra_delay)

            replies = await _generate_bot_replies(chat, user_msg, user_name, db)
            for idx, r in enumerate(replies):
                # Add human-like typing delay between messages (simulates agent typing)
                # System messages (join/escalation notices) appear faster
                if idx > 0:
                    if r["role"] == "system":
                        await asyncio.sleep(_rng.uniform(0.8, 1.5))
                    else:
                        msg_len = len(r["message"])
                        typing_time = min(2.5 + msg_len * 0.04, 12.0)
                        await asyncio.sleep(_rng.uniform(typing_time * 0.75, typing_time))

                # ~15% chance of mid-typing pause (agent stops to think/research)
                if r["role"] == "bot" and _rng.random() < 0.15:
                    await asyncio.sleep(_rng.uniform(1.0, 2.5))

                # Split ||SPLIT|| markers into separate messages with typing delays
                parts = r["message"].split("||SPLIT||") if "||SPLIT||" in r["message"] else [r["message"]]
                for pidx, part in enumerate(parts):
                    part = part.strip()
                    if not part:
                        continue
                    if pidx > 0:
                        part_len = len(part)
                        typing_time = min(2.0 + part_len * 0.04, 10.0)
                        await asyncio.sleep(_rng.uniform(typing_time * 0.75, typing_time))
                    bot_msg = SupportMessage(
                        chat_id=chat_id, sender_id=None,
                        sender_role=r["role"], message=part
                    )
                    db.add(bot_msg)
                    await db.flush()
                    await db.refresh(bot_msg)
                    chat.updated_at = datetime.utcnow()
                    await db.commit()
                    if _HAS_FIRESTORE:
                        try:
                            firestore_sync.sync_support_message(
                                chat_id, bot_msg.id, 0, r["sender_name"], r["role"], part
                            )
                        except Exception:
                            pass
    except Exception as e:
        logging.error("Background bot reply failed for chat %d: %s", chat_id, e)


async def _check_chat_inactivity(chat_id: int):
    """Background task: proactive follow-up sequence.
    2 min → first follow-up, 4 min → second follow-up, 5 min → closing warning, 5:30 → close chat.
    Respects user typing state from Firestore to avoid interrupting.
    """
    try:
        # ── First follow-up at 2 minutes ──
        await asyncio.sleep(120)
        async with SessionLocal() as db:
            chat_r = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
            chat = chat_r.scalar_one_or_none()
            if not chat or chat.status != "open":
                return
            if chat.last_user_message_at:
                elapsed = (datetime.utcnow() - chat.last_user_message_at).total_seconds()
                if elapsed < 110:
                    return  # User was active recently — reset
            # Check Firestore typing status
            if _HAS_FIRESTORE:
                try:
                    doc = firestore_sync._fs_db.collection("support_chats").document(str(chat_id)).get()
                    if doc.exists and doc.to_dict().get("user_typing"):
                        await asyncio.sleep(15)  # Give them time to finish typing
                except Exception:
                    pass
            agent = chat.agent_name or "Agente"
            lang = getattr(chat, "locale", "en") or "en"
            _u_name = "estimado usuario"
            try:
                _u_r = await db.execute(select(User).where(User.id == chat.user_id))
                _u = _u_r.scalar_one_or_none()
                if _u and _u.first_name:
                    _u_name = _u.first_name
            except Exception:
                pass
            proactive_msgs_es = [
                f"¿Hay algo más en que pueda ayudarle, {_u_name}?",
                f"¿Necesita ayuda con algo más?",
                f"Quedo a su disposición si necesita algo adicional.",
            ]
            proactive_msgs_en = [
                f"Is there anything else I can help you with, {_u_name if _u_name != 'estimado usuario' else 'there'}?",
                f"Do you need help with anything else?",
                f"I'm here if you need anything else.",
            ]
            proactive_text = _rng.choice(proactive_msgs_es if lang.startswith("es") else proactive_msgs_en)
            proactive_msg = SupportMessage(chat_id=chat_id, sender_id=None, sender_role="bot", message=proactive_text)
            db.add(proactive_msg)
            chat.updated_at = datetime.utcnow()
            await db.commit()
            await db.refresh(proactive_msg)
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_support_message(chat_id, proactive_msg.id, 0, agent, "bot", proactive_text)
                except Exception:
                    pass

        # ── Second follow-up at 4 minutes (2 min after first) ──
        await asyncio.sleep(120)
        async with SessionLocal() as db:
            chat_r = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
            chat = chat_r.scalar_one_or_none()
            if not chat or chat.status != "open":
                return
            if chat.last_user_message_at:
                elapsed = (datetime.utcnow() - chat.last_user_message_at).total_seconds()
                if elapsed < 110:
                    return  # User responded
            # Check typing
            if _HAS_FIRESTORE:
                try:
                    doc = firestore_sync._fs_db.collection("support_chats").document(str(chat_id)).get()
                    if doc.exists and doc.to_dict().get("user_typing"):
                        await asyncio.sleep(15)
                except Exception:
                    pass
            agent = chat.agent_name or "Agente"
            lang = getattr(chat, "locale", "en") or "en"
            still_text = "¿Aún sigue en línea conmigo?" if lang.startswith("es") else "Are you still there with me?"
            still_msg = SupportMessage(chat_id=chat_id, sender_id=None, sender_role="bot", message=still_text)
            db.add(still_msg)
            chat.updated_at = datetime.utcnow()
            await db.commit()
            await db.refresh(still_msg)
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_support_message(chat_id, still_msg.id, 0, agent, "bot", still_msg.message)
                except Exception:
                    pass

        # ── Closing warning at 5 minutes (1 min after second) ──
        await asyncio.sleep(60)
        async with SessionLocal() as db:
            chat_r = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
            chat = chat_r.scalar_one_or_none()
            if not chat or chat.status != "open":
                return
            if chat.last_user_message_at:
                elapsed = (datetime.utcnow() - chat.last_user_message_at).total_seconds()
                if elapsed < 55:
                    return  # User responded
            agent = chat.agent_name or "Agente"
            lang = getattr(chat, "locale", "en") or "en"
            close_warn_es = "Por motivos de inactividad, cerraré este chat en 30 segundos. Si necesita más ayuda, envíe un mensaje."
            close_warn_en = "Due to inactivity, I'll be closing this chat in 30 seconds. If you still need help, please send a message."
            close_text = close_warn_es if lang.startswith("es") else close_warn_en
            close_msg = SupportMessage(chat_id=chat_id, sender_id=None, sender_role="bot", message=close_text)
            db.add(close_msg)
            chat.updated_at = datetime.utcnow()
            await db.commit()
            await db.refresh(close_msg)
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_support_message(chat_id, close_msg.id, 0, agent, "bot", close_msg.message)
                except Exception:
                    pass

        # ── Close chat at 5:30 (30 seconds after warning) ──
        await asyncio.sleep(30)
        async with SessionLocal() as db:
            chat_r = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
            chat = chat_r.scalar_one_or_none()
            if not chat or chat.status != "open":
                return
            if chat.last_user_message_at:
                elapsed = (datetime.utcnow() - chat.last_user_message_at).total_seconds()
                if elapsed < 25:
                    return  # User responded just in time
            chat.status = "closed"
            chat.updated_at = datetime.utcnow()
            await db.commit()
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_support_chat(chat.id, chat.user_id, "", "", None, None, chat.subject, "closed")
                except Exception:
                    pass
    except asyncio.CancelledError:
        pass
    except Exception as e:
        logging.error("Chat inactivity check failed for chat %d: %s", chat_id, e)
    finally:
        _inactivity_tasks.pop(chat_id, None)

@router.post("/support/chats", dependencies=[Depends(_verify_api_key)])
async def create_or_get_support_chat(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Create a new support chat or return existing open one for this user."""
    body = await request.json()
    subject = (body.get("subject") or "").strip()
    locale = (body.get("locale") or "en").strip()[:5]

    # Check for existing open chat
    result = await db.execute(
        select(SupportChat).where(SupportChat.user_id == user.id, SupportChat.status == "open")
    )
    chat = result.scalar_one_or_none()
    if chat:
        # Update locale if changed
        if locale and chat.locale != locale:
            chat.locale = locale
            await db.commit()
        return {"id": chat.id, "user_id": chat.user_id, "status": chat.status,
                "subject": chat.subject, "agent_name": chat.agent_name,
                "bot_phase": chat.bot_phase or "welcome",
                "created_at": chat.created_at.isoformat() if chat.created_at else None}

    chat = SupportChat(user_id=user.id, subject=subject or "Soporte general", bot_phase="welcome", locale=locale)
    db.add(chat)
    await db.commit()
    await db.refresh(chat)

    # Send welcome message
    if locale.startswith("es"):
        welcome_text = (
            "Sistema de soporte Cruise  Sesion iniciada.\n\n"
            "Bienvenido al centro de ayuda automatizado. "
            "Seleccione o describa su problema para que podamos asistirlo.\n\n"
            " Viajes y tarifas\n"
            " Pagos y reembolsos\n"
            " Cuenta y perfil\n"
            " Seguridad\n"
            " Problemas con la app"
        )
    else:
        welcome_text = (
            "Cruise Support System  Session started.\n\n"
            "Welcome to our automated help center. "
            "Please select or describe your issue so we can assist you.\n\n"
            " Trips & fares\n"
            " Payments & refunds\n"
            " Account & profile\n"
            " Safety\n"
            " App issues"
        )
    welcome_msg = SupportMessage(chat_id=chat.id, sender_id=None, sender_role="system", message=welcome_text)
    db.add(welcome_msg)
    await db.commit()
    await db.refresh(welcome_msg)

    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_support_chat(chat.id, user.id, user.first_name, user.last_name,
                                              user.photo_url, user.role, chat.subject, chat.status)
            firestore_sync.sync_support_message(chat.id, welcome_msg.id, 0, "Sistema", "system", welcome_text)
        except Exception as e:
            logging.error("Firestore support chat sync failed: %s", e)

    return {"id": chat.id, "user_id": chat.user_id, "status": chat.status,
            "subject": chat.subject, "agent_name": chat.agent_name,
            "bot_phase": chat.bot_phase or "welcome",
            "created_at": chat.created_at.isoformat() if chat.created_at else None}

@router.get("/support/chats", dependencies=[Depends(_verify_api_key)])
async def list_support_chats(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """List support chats. Riders see their own, dispatch (via API key) sees all."""
    result = await db.execute(
        select(SupportChat).where(SupportChat.user_id == user.id).order_by(SupportChat.updated_at.desc())
    )
    chats = result.scalars().all()
    return [{"id": c.id, "user_id": c.user_id, "status": c.status, "subject": c.subject,
             "created_at": c.created_at.isoformat() if c.created_at else None,
             "updated_at": c.updated_at.isoformat() if c.updated_at else None} for c in chats]

@router.get("/support/chats/all", dependencies=[Depends(_require_dispatch_auth)])
async def list_all_support_chats(db: AsyncSession = Depends(get_db)):
    """List ALL support chats (dispatch only)."""
    result = await db.execute(
        select(SupportChat).order_by(SupportChat.updated_at.desc())
    )
    chats = result.scalars().all()
    out = []
    for c in chats:
        user_result = await db.execute(select(User).where(User.id == c.user_id))
        u = user_result.scalar_one_or_none()
        # Count unread
        unread_result = await db.execute(
            select(SupportMessage).where(
                SupportMessage.chat_id == c.id,
                SupportMessage.sender_role != "dispatch",
                SupportMessage.is_read == False,
            )
        )
        unread = len(unread_result.scalars().all())
        # Get last message
        last_msg_result = await db.execute(
            select(SupportMessage).where(SupportMessage.chat_id == c.id)
            .order_by(SupportMessage.created_at.desc()).limit(1)
        )
        last_msg = last_msg_result.scalar_one_or_none()
        out.append({
            "id": c.id, "user_id": c.user_id, "status": c.status, "subject": c.subject,
            "user_name": f"{u.first_name} {u.last_name}".strip() if u else "Unknown",
            "user_photo": u.photo_url if u else None,
            "user_role": u.role if u else "rider",
            "unread_count": unread,
            "needs_escalation": bool(c.needs_escalation),
            "supervisor_connected": bool(c.supervisor_connected),
            "agent_name": c.agent_name,
            "bot_phase": c.bot_phase,
            "last_message": last_msg.message if last_msg else None,
            "last_message_at": last_msg.created_at.isoformat() if last_msg and last_msg.created_at else None,
            "last_sender_role": last_msg.sender_role if last_msg else None,
            "created_at": c.created_at.isoformat() if c.created_at else None,
            "updated_at": c.updated_at.isoformat() if c.updated_at else None,
        })
    return out

@router.get("/support/chats/{chat_id}/messages", dependencies=[Depends(_verify_api_key)])
async def get_support_messages(chat_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get messages for a support chat."""
    # Load chat for agent_name
    chat_result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = chat_result.scalar_one_or_none()
    if not chat or chat.user_id != user.id:
        raise HTTPException(status_code=403, detail="Not your chat")

    result = await db.execute(
        select(SupportMessage).where(SupportMessage.chat_id == chat_id)
        .order_by(SupportMessage.created_at.asc())
    )
    messages = result.scalars().all()
    # Mark messages as read if current user is receiver
    for m in messages:
        if m.sender_id != user.id and not m.is_read:
            m.is_read = True
    await db.commit()
    # Build sender names
    sender_ids = {m.sender_id for m in messages if m.sender_id != 0}
    sender_names = {}
    for sid in sender_ids:
        r = await db.execute(select(User).where(User.id == sid))
        u = r.scalar_one_or_none()
        sender_names[sid] = f"{u.first_name} {u.last_name}".strip() if u else "Unknown"
    # Build output with proper names for bot/system messages
    output = []
    for m in messages:
        if m.sender_id == 0:
            if m.sender_role == "bot":
                name = chat.agent_name if chat else "Agente"
            elif m.sender_role == "system":
                name = "Sistema"
            elif m.sender_role == "dispatch":
                name = "Supervisor" if (chat and chat.supervisor_connected) else "Soporte Cruise"
            else:
                name = "Soporte Cruise"
        else:
            name = sender_names.get(m.sender_id, "Unknown")
        output.append(_support_msg_dict(m, name))
    return output

@router.get("/support/chats/{chat_id}/messages/dispatch", dependencies=[Depends(_require_dispatch_auth)])
async def get_support_messages_dispatch(chat_id: int, db: AsyncSession = Depends(get_db)):
    """Get messages for a support chat (dispatch version  marks dispatch-received as read)."""
    # Load chat for agent_name
    chat_result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = chat_result.scalar_one_or_none()

    result = await db.execute(
        select(SupportMessage).where(SupportMessage.chat_id == chat_id)
        .order_by(SupportMessage.created_at.asc())
    )
    messages = result.scalars().all()
    for m in messages:
        if m.sender_role != "dispatch" and not m.is_read:
            m.is_read = True
    await db.commit()
    sender_ids = {m.sender_id for m in messages if m.sender_id != 0}
    sender_names = {}
    for sid in sender_ids:
        r = await db.execute(select(User).where(User.id == sid))
        u = r.scalar_one_or_none()
        sender_names[sid] = f"{u.first_name} {u.last_name}".strip() if u else "Unknown"
    output = []
    for m in messages:
        if m.sender_id == 0:
            if m.sender_role == "bot":
                name = (chat.agent_name if chat else "Agente") + " (Bot)"
            elif m.sender_role == "system":
                name = "Sistema"
            else:
                name = "Soporte Cruise"
        else:
            name = sender_names.get(m.sender_id, "Unknown")
        output.append(_support_msg_dict(m, name))
    return output

@router.post("/support/chats/{chat_id}/messages", dependencies=[Depends(_verify_api_key)])
async def send_support_message(chat_id: int, request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Send a message in a support chat (rider/driver side)."""
    # Rate limit: max 10 messages per minute per user
    _now = time.monotonic()
    _uid_key = f"support_msg_{user.id}"
    _msg_timestamps = _support_msg_rate.get(_uid_key, [])
    _msg_timestamps = [t for t in _msg_timestamps if _now - t < 60]
    if len(_msg_timestamps) >= 10:
        raise HTTPException(429, "Too many messages. Please wait a moment.")
    _msg_timestamps.append(_now)
    _support_msg_rate[_uid_key] = _msg_timestamps

    body = await request.json()
    msg_text = (body.get("message") or "").strip()
    if not msg_text:
        raise HTTPException(400, "Message cannot be empty")

    chat_result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = chat_result.scalar_one_or_none()
    if not chat:
        raise HTTPException(404, "Chat not found")
    if chat.user_id != user.id:
        raise HTTPException(403, "Not your chat")

    msg = SupportMessage(chat_id=chat_id, sender_id=user.id, sender_role=user.role or "rider", message=msg_text)
    db.add(msg)
    chat.updated_at = datetime.utcnow()
    chat.last_user_message_at = datetime.utcnow()
    await db.commit()
    await db.refresh(msg)

    # Cancel any existing inactivity task for this chat and start new one
    old_task = _inactivity_tasks.pop(chat_id, None)
    if old_task and not old_task.done():
        old_task.cancel()

    # Check if user is responding to a "still online?" prompt
    last_bot_r = await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat_id,
            SupportMessage.sender_role == "bot",
        ).order_by(SupportMessage.created_at.desc()).limit(1)
    )
    last_bot_msg = last_bot_r.scalar_one_or_none()
    last_msg_text = (last_bot_msg.message or "").lower() if last_bot_msg else ""
    is_still_online_prompt = "sigues en l" in last_msg_text or "still there" in last_msg_text
    if last_bot_msg and is_still_online_prompt:
        agent = chat.agent_name or "Agente"
        lang = getattr(chat, "locale", "en") or "en"
        if lang.startswith("es"):
            confirm_text = "Gracias por dejarme saber, solo queria confirmar. En que mas puedo ayudarte?"
        else:
            confirm_text = "Thanks for letting me know, just wanted to confirm. What else can I help you with?"
        confirm_msg = SupportMessage(chat_id=chat_id, sender_id=None, sender_role="bot",
                                      message=confirm_text)
        db.add(confirm_msg)
        await db.commit()
        await db.refresh(confirm_msg)
        if _HAS_FIRESTORE:
            try:
                firestore_sync.sync_support_message(chat_id, confirm_msg.id, 0, agent, "bot", confirm_msg.message)
            except Exception:
                pass

    # Sync user message to Firestore
    user_full = f"{user.first_name} {user.last_name}".strip()
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_support_message(chat_id, msg.id, user.id,
                                                 user_full, user.role or "rider", msg_text)
            # Notify dispatch of every user message
            firestore_sync.sync_dispatch_notification(
                chat_id, user_full, "new_message",
                f"{user_full}: {msg_text[:100]}"
            )
        except Exception as e:
            logging.error("Firestore support msg sync failed: %s", e)

    # Generate AI bot replies (only if not taken over by real dispatch)
    bot_phase_snapshot = chat.bot_phase
    if bot_phase_snapshot != "dispatch_takeover":
        asyncio.create_task(_background_bot_reply(chat_id, msg_text, user.first_name or "Cliente", bot_phase_snapshot))

    # Start inactivity timer
    _inactivity_tasks[chat_id] = asyncio.create_task(_check_chat_inactivity(chat_id))

    return _support_msg_dict(msg, user_full)

@router.post("/support/chats/{chat_id}/typing", dependencies=[Depends(_verify_api_key)])
async def set_typing_status(chat_id: int, request: Request, user: User = Depends(_get_current_user)):
    """Set user typing status in Firestore for inactivity detection."""
    body = await request.json()
    typing = bool(body.get("typing", False))
    if _HAS_FIRESTORE:
        try:
            firestore_sync._fs_db.collection("support_chats").document(str(chat_id)).set(
                {"user_typing": typing, "typing_updated_at": datetime.utcnow().isoformat()},
                merge=True,
            )
        except Exception:
            pass
    return {"ok": True}

@router.post("/support/chats/{chat_id}/messages/dispatch", dependencies=[Depends(_require_dispatch_auth)])
async def send_support_message_dispatch(chat_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Send a message in a support chat (dispatch side). Switches bot off."""
    body = await request.json()
    msg_text = (body.get("message") or "").strip()
    if not msg_text:
        raise HTTPException(400, "Message cannot be empty")

    chat_result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = chat_result.scalar_one_or_none()
    if not chat:
        raise HTTPException(404, "Chat not found")

    # When dispatch sends a message, take over from bot
    if chat.bot_phase != "dispatch_takeover":
        chat.bot_phase = "dispatch_takeover"

    msg = SupportMessage(chat_id=chat_id, sender_id=None, sender_role="dispatch", message=msg_text)
    db.add(msg)
    chat.updated_at = datetime.utcnow()
    await db.commit()
    await db.refresh(msg)

    sender_label = "Supervisor" if chat.supervisor_connected else "Soporte Cruise"

    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_support_message(chat_id, msg.id, 0, sender_label, "dispatch", msg_text)
        except Exception as e:
            logging.error("Firestore dispatch msg sync failed: %s", e)

    return _support_msg_dict(msg, sender_label)

@router.post("/support/chats/{chat_id}/connect-supervisor", dependencies=[Depends(_require_dispatch_auth)])
async def connect_supervisor(chat_id: int, db: AsyncSession = Depends(get_db)):
    """Dispatch connects as supervisor to an escalated chat."""
    result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = result.scalar_one_or_none()
    if not chat:
        raise HTTPException(404, "Chat not found")
    chat.supervisor_connected = True
    chat.bot_phase = "dispatch_takeover"
    chat.updated_at = datetime.utcnow()
    # Cancel any inactivity task
    old_task = _inactivity_tasks.pop(chat_id, None)
    if old_task and not old_task.done():
        old_task.cancel()
    # Send system message visible to user
    sys_msg = SupportMessage(chat_id=chat_id, sender_id=None, sender_role="system",
                              message="Un supervisor se ha conectado al chat")
    db.add(sys_msg)
    await db.commit()
    await db.refresh(sys_msg)
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_support_message(chat_id, sys_msg.id, 0, "Sistema", "system", sys_msg.message)
        except Exception:
            pass
    return {"status": "supervisor_connected", "message_id": sys_msg.id}

@router.patch("/support/chats/{chat_id}/close", dependencies=[Depends(_require_dispatch_auth)])
async def close_support_chat(chat_id: int, db: AsyncSession = Depends(get_db)):
    """Close a support chat (dispatch only)."""
    result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = result.scalar_one_or_none()
    if not chat:
        raise HTTPException(404, "Chat not found")
    chat.status = "closed"
    chat.updated_at = datetime.utcnow()
    await db.commit()

    if _HAS_FIRESTORE:
        try:
            user_result = await db.execute(select(User).where(User.id == chat.user_id))
            u = user_result.scalar_one_or_none()
            firestore_sync.sync_support_chat(chat.id, chat.user_id,
                                              u.first_name if u else "", u.last_name if u else "",
                                              u.photo_url if u else None, u.role if u else "rider",
                                              chat.subject, "closed")
        except Exception as e:
            logging.error("Firestore close chat sync failed: %s", e)

    return {"status": "closed"}

@router.patch("/support/chats/{chat_id}/close-user", dependencies=[Depends(_verify_api_key)])
async def close_support_chat_user(chat_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Close a support chat (user-facing  only the chat owner can close)."""
    result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = result.scalar_one_or_none()
    if not chat:
        raise HTTPException(404, "Chat not found")
    if chat.user_id != user.id:
        raise HTTPException(403, "Not your chat")
    chat.status = "closed"
    chat.updated_at = datetime.utcnow()
    await db.commit()

    # Cancel any pending inactivity task
    task = _inactivity_tasks.pop(chat_id, None)
    if task:
        task.cancel()

    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_support_chat(chat.id, chat.user_id,
                                              user.first_name, user.last_name,
                                              user.photo_url, user.role,
                                              chat.subject, "closed")
        except Exception as e:
            logging.error("Firestore close chat sync failed: %s", e)

    return {"status": "closed"}


# ═══════════════════════════════════════════════════════
#  ACTION REQUEST ENDPOINTS (DISPATCH)
# ═══════════════════════════════════════════════════════

@router.get("/support/action-requests", dependencies=[Depends(_require_dispatch_auth)])
async def list_action_requests(status: str = "pending_admin", db: AsyncSession = Depends(get_db)):
    """List action requests (dispatch only). Filter by status: pending_admin | approved | rejected."""
    result = await db.execute(
        select(ActionRequest).where(ActionRequest.status == status)
        .order_by(ActionRequest.created_at.desc())
    )
    requests = result.scalars().all()
    out = []
    for ar in requests:
        details_parsed = {}
        try:
            details_parsed = json.loads(ar.details or "{}")
        except Exception:
            pass
        out.append({
            "id": ar.id,
            "chat_id": ar.chat_id,
            "user_id": ar.user_id,
            "user_name": ar.user_name,
            "user_type": ar.user_type,
            "agent_name": ar.agent_name,
            "action_type": ar.action_type,
            "details": details_parsed,
            "status": ar.status,
            "admin_note": ar.admin_note,
            "created_at": ar.created_at.isoformat() if ar.created_at else None,
            "reviewed_at": ar.reviewed_at.isoformat() if ar.reviewed_at else None,
            "reviewed_by": ar.reviewed_by,
        })
    return out


@router.patch("/support/action-requests/{request_id}/approve", dependencies=[Depends(_require_dispatch_auth)])
async def approve_action_request(request_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Approve an action request and notify the user in the chat."""
    body = await request.json()
    admin_note = (body.get("admin_note") or "").strip()

    ar_result = await db.execute(select(ActionRequest).where(ActionRequest.id == request_id))
    ar = ar_result.scalar_one_or_none()
    if not ar:
        raise HTTPException(404, "Action request not found")
    if ar.status != "pending_admin":
        raise HTTPException(400, f"Request is already {ar.status}")

    ar.status = "approved"
    ar.reviewed_at = datetime.utcnow()
    ar.reviewed_by = "dispatch"
    if admin_note:
        ar.admin_note = admin_note

    chat_result = await db.execute(select(SupportChat).where(SupportChat.id == ar.chat_id))
    chat = chat_result.scalar_one_or_none()
    await db.commit()

    if chat and chat.status == "open":
        lang = getattr(chat, "locale", "en") or "en"
        agent = chat.agent_name or "Agente"
        action_label = ar.action_type.replace("-", " ").title()
        if lang.startswith("es"):
            msg_text = (
                f"Buenas noticias, {ar.user_name}. Su solicitud de {action_label} ha sido aprobada por nuestro equipo. "
                f"Se procesara en las proximas horas y recibira una notificacion cuando este listo."
            )
        else:
            msg_text = (
                f"Good news, {ar.user_name}. Your {action_label} request has been approved by our team. "
                f"It will be processed within the next few hours and you will receive a notification when it is ready."
            )
        if admin_note:
            msg_text += f" Nota: {admin_note}" if lang.startswith("es") else f" Note: {admin_note}"

        bot_msg = SupportMessage(chat_id=ar.chat_id, sender_id=None, sender_role="bot", message=msg_text)
        db.add(bot_msg)
        await db.commit()
        await db.refresh(bot_msg)
        if _HAS_FIRESTORE:
            try:
                firestore_sync.sync_support_message(ar.chat_id, bot_msg.id, 0, agent, "bot", msg_text)
            except Exception:
                pass

    task = _action_reminder_tasks.pop(request_id, None)
    if task and not task.done():
        task.cancel()
    if _HAS_FIRESTORE:
        try:
            firestore_sync._fs_db.collection("pending_reminders").document(str(request_id)).delete()
        except Exception:
            pass

    return {"status": "approved", "request_id": request_id}


@router.patch("/support/action-requests/{request_id}/reject", dependencies=[Depends(_require_dispatch_auth)])
async def reject_action_request(request_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Reject an action request, notify user, and flag chat for supervisor escalation."""
    body = await request.json()
    admin_note = (body.get("admin_note") or "").strip()

    ar_result = await db.execute(select(ActionRequest).where(ActionRequest.id == request_id))
    ar = ar_result.scalar_one_or_none()
    if not ar:
        raise HTTPException(404, "Action request not found")
    if ar.status != "pending_admin":
        raise HTTPException(400, f"Request is already {ar.status}")

    ar.status = "rejected"
    ar.reviewed_at = datetime.utcnow()
    ar.reviewed_by = "dispatch"
    if admin_note:
        ar.admin_note = admin_note

    chat_result = await db.execute(select(SupportChat).where(SupportChat.id == ar.chat_id))
    chat = chat_result.scalar_one_or_none()
    await db.commit()

    if chat and chat.status == "open":
        lang = getattr(chat, "locale", "en") or "en"
        agent = chat.agent_name or "Agente"
        action_label = ar.action_type.replace("-", " ").title()
        if lang.startswith("es"):
            msg_text = (
                f"Estimado {ar.user_name}, lamentamos informarle que su solicitud de {action_label} no pudo ser procesada automaticamente. "
                f"Su caso ha sido escalado a un supervisor quien se pondra en contacto con usted para resolver esta situacion personalmente."
            )
        else:
            msg_text = (
                f"Dear {ar.user_name}, we regret to inform you that your {action_label} request could not be processed automatically. "
                f"Your case has been escalated to a supervisor who will reach out to you to resolve this situation personally."
            )
        if admin_note:
            msg_text += f" Motivo: {admin_note}" if lang.startswith("es") else f" Reason: {admin_note}"

        bot_msg = SupportMessage(chat_id=ar.chat_id, sender_id=None, sender_role="bot", message=msg_text)
        db.add(bot_msg)
        chat.needs_escalation = True
        chat.updated_at = datetime.utcnow()
        await db.commit()
        await db.refresh(bot_msg)

        if _HAS_FIRESTORE:
            try:
                firestore_sync.sync_support_message(ar.chat_id, bot_msg.id, 0, agent, "bot", msg_text)
                firestore_sync.sync_dispatch_notification(
                    ar.chat_id, ar.user_name, "escalation",
                    f"Solicitud rechazada escalada a supervisor: {action_label} de {ar.user_name}"
                )
                firestore_sync.sync_support_chat(
                    chat.id, chat.user_id, ar.user_name, "",
                    needs_escalation=True, bot_phase=chat.bot_phase,
                )
            except Exception:
                pass

    task = _action_reminder_tasks.pop(request_id, None)
    if task and not task.done():
        task.cancel()
    if _HAS_FIRESTORE:
        try:
            firestore_sync._fs_db.collection("pending_reminders").document(str(request_id)).delete()
        except Exception:
            pass

    return {"status": "rejected", "request_id": request_id}

