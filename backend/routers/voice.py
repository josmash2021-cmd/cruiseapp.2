import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text
from sqlalchemy.ext.asyncio import AsyncSession
from config import TWILIO_PHONE_NUMBER, TWILIO_AUTH_TOKEN
from utils.bounded_cache import TTLCache

router = APIRouter()

# ═══════════════════════════════════════════════════════
#  TWILIO AI VOICE CALL ENDPOINTS
# ═══════════════════════════════════════════════════════

def _validate_twilio_sig(url: str, form_data: dict, signature: str) -> None:
    """Validate Twilio webhook signature. Skipped if TWILIO_AUTH_TOKEN not configured."""
    if not TWILIO_AUTH_TOKEN:
        return  # Dev/test mode – skip validation
    try:
        from twilio.request_validator import RequestValidator
        validator = RequestValidator(TWILIO_AUTH_TOKEN)
        if not validator.validate(url, form_data, signature):
            raise HTTPException(403, "Invalid Twilio webhook signature")
    except ImportError:
        pass  # twilio package not installed – skip

# In-memory voice session store: call_sid -> {agent_name, phase, category, msg_count, lang}
# Bounded: max 2,000 sessions, entries expire after 30 minutes
_voice_sessions = TTLCache[str, dict](ttl_seconds=1800, max_size=2000, name="voice_sessions")

_AGENT_NAMES = [
    "Lucía", "Sofía", "Isabella", "Valentina", "Camila",
    "Mariana", "Daniela", "Gabriela", "Andrea", "Carolina",
    "Ana Paula", "Laura", "Diana", "Natalia", "Alejandra",
]

# -- Voice configuration per language ------------------
_VOICE_CONFIG = {
    "es": {
        "voice": "Google.es-US-Studio-B",
        "lang": "es-US",
        "agent_names": _AGENT_NAMES,
    },
    "en": {
        "voice": "Google.en-US-Studio-O",
        "lang": "en-US",
        "agent_names": [
            "Sarah", "Emily", "Jessica", "Rachel", "Amanda",
            "Ashley", "Samantha", "Olivia", "Sophia", "Isabella",
            "Victoria", "Natalie", "Lauren", "Grace", "Megan",
        ],
    },
}

# -- Spanish responses ---------------------------------
_VOICE_ES = {
    "welcome": [
        "Hola, bienvenido al centro de soporte de Cruise. Mi nombre es {agent}, y voy a ser tu agente personal el d�a de hoy. Cu�ntame, �en qu� puedo ayudarte?",
        "Hola, gracias por llamar a Cruise. Soy {agent}, tu agente de soporte. Estoy aqu� para ayudarte con lo que necesites. �C�mo puedo asistirte?",
        "Bienvenido a Cruise. Mi nombre es {agent} y estoy encantada de atenderte. Dime, �qu� puedo hacer por ti hoy?",
    ],
    "fallback_first": [
        "Entiendo lo que me dices. Para poder ayudarte de la mejor manera, �me podr�as dar un poco m�s de detalle sobre tu situaci�n?",
        "Gracias por contarme. Necesito un poco m�s de informaci�n para darte una soluci�n precisa. �Puedes ampliar los detalles?",
        "De acuerdo. Quiero asegurarme de resolver esto correctamente. �Me puedes dar m�s informaci�n sobre lo que sucedi�?",
    ],
    "fallback_followup": [
        "Ya tengo toda la informaci�n. Nuestro equipo le dar� seguimiento a tu caso de inmediato. �Hay algo m�s en lo que pueda ayudarte?",
        "Perfecto, he registrado todos los detalles. Tu caso ya est� en proceso. �Puedo ayudarte con algo m�s?",
        "Todo ha quedado anotado. Me asegurar� personalmente de que se d� seguimiento. �Necesitas algo adicional?",
    ],
    "closing": [
        "Me alegra mucho haber podido ayudarte. No dudes en llamarnos cuando lo necesites. Que tengas un excelente d�a, cu�date mucho.",
        "Ha sido un placer atenderte. Recuerda que estamos aqu� siempre que nos necesites. Que tengas un maravilloso d�a.",
        "Con mucho gusto. Espero que todo se resuelva perfectamente. Si necesitas algo m�s en el futuro, aqu� estaremos. Que te vaya muy bien.",
    ],
    "escalation": [
        "Entiendo perfectamente tu solicitud. Voy a transferir tu caso a un supervisor especializado que podr� darte una mejor atenci�n. Te contactar� lo m�s pronto posible.",
        "Comprendo tu situaci�n. Estoy escalando tu caso ahora mismo a un supervisor. Se pondr� en contacto contigo en breve para resolverlo personalmente.",
    ],
    "escalated_reply": "Tu caso ya fue escalado a un supervisor y se encuentra en proceso. Se comunicar� contigo muy pronto. �Hay algo urgente que necesites mientras tanto?",
    "no_input": "Parece que no alcanc� a escucharte. �Podr�as repetir tu consulta por favor?",
    "no_input_bye": "No logr� escuchar nada. Si necesitas ayuda, no dudes en llamarnos nuevamente. Hasta pronto.",
    "categories": {
        "trip_charge": {
            "first": [
                "Entiendo tu preocupaci�n con el cobro. D�jame revisar los detalles de tu viaje. �Me podr�as indicar la fecha y la hora aproximada del viaje?",
                "Lamento el inconveniente con el cobro. Voy a revisar tu cuenta ahora mismo. �Podr�as darme la fecha del viaje y el monto que te cobraron?",
            ],
            "followup": [
                "Ya localic� tu viaje y he verificado el recibo. He procesado el ajuste correspondiente. El reembolso se reflejar� en tu m�todo de pago en un plazo de tres a cinco d�as h�biles. �Necesitas algo m�s?",
                "Ya revis� la transacci�n. Efectivamente hay una diferencia y voy a iniciar el proceso de correcci�n. Te llegar� una notificaci�n cuando se complete. �Hay algo m�s en lo que pueda ayudarte?",
            ],
        },
        "cancellation": {
            "first": [
                "Puedo ayudarte con eso. �Es un viaje que quieres cancelar ahora, o te cobraron una tarifa de cancelaci�n que quieres disputar?",
                "Claro que s�. �El viaje est� programado todav�a, o ya pas� y te cobraron por la cancelaci�n? Cu�ntame los detalles.",
            ],
            "followup": [
                "He procesado tu solicitud correctamente. Si hubo un cobro injustificado, ya inici� el proceso de devoluci�n. El reembolso tardar� de tres a cinco d�as h�biles. �Puedo ayudarte con algo m�s?",
                "La cancelaci�n ha sido procesada sin ning�n problema. Recuerda que puedes cancelar sin cargo dentro de los primeros dos minutos despu�s de solicitar el viaje. �Necesitas algo m�s?",
            ],
        },
        "refund": {
            "first": [
                "Entiendo que necesitas un reembolso. Para procesarlo r�pidamente, �me podr�as indicar la fecha del viaje y el motivo de tu solicitud?",
                "Claro que puedo ayudarte con el reembolso. �Cu�l fue la fecha del viaje y el monto que te cobraron? As� lo proceso lo m�s r�pido posible.",
            ],
            "followup": [
                "He procesado tu solicitud de reembolso exitosamente. El monto se reflejar� en tu cuenta en un plazo de tres a cinco d�as h�biles. Te enviaremos una confirmaci�n. �Hay algo m�s que necesites?",
                "El reembolso ha sido aprobado y ya est� en proceso. Lo ver�s de vuelta en tu m�todo de pago muy pronto. �Puedo ayudarte con algo m�s?",
            ],
        },
        "driver": {
            "first": [
                "Lamento mucho que hayas tenido esa experiencia. Tomamos estos reportes con la mayor seriedad. �Me podr�as dar m�s detalles? El nombre del conductor y la fecha del viaje me ayudar�an mucho.",
                "Eso no deber�a pasar bajo ninguna circunstancia. Voy a documentar tu reporte de inmediato. �Puedes contarme exactamente qu� sucedi� y cu�ndo fue?",
            ],
            "followup": [
                "Tu reporte ha sido registrado oficialmente. Nuestro equipo de calidad revisar� el caso y tomar� las medidas disciplinarias necesarias. �Hay algo m�s que necesites?",
                "He documentado todo detalladamente. Este tipo de comportamiento no lo toleramos en Cruise. El equipo de calidad revisar� el caso en las pr�ximas horas. �Algo m�s?",
            ],
        },
        "lost_item": {
            "first": [
                "No te preocupes, vamos a hacer todo lo posible por recuperar tu objeto. �Qu� fue lo que perdiste y en qu� fecha fue el viaje?",
                "Entiendo tu preocupaci�n. La buena noticia es que la mayor�a de objetos se recuperan en las primeras veinticuatro horas. �Me dices qu� olvidaste y cu�ndo fue el viaje?",
            ],
            "followup": [
                "Ya me comuniqu� con el conductor. En cuanto nos confirme que tiene tu objeto, te notificaremos para coordinar la entrega. �Hay algo m�s que necesites?",
                "El conductor ya fue notificado de tu caso. Tan pronto confirme que tiene tu objeto, nos pondremos en contacto contigo para acordar la devoluci�n. �Necesitas algo m�s?",
            ],
        },
        "account": {
            "first": [
                "Con gusto puedo ayudarte con tu cuenta. �Qu� problema est�s teniendo exactamente? �Es con el inicio de sesi�n, con tus datos de perfil, o algo diferente?",
                "Los problemas de cuenta generalmente tienen una soluci�n r�pida. �Me dices qu� necesitas cambiar o qu� error te est� apareciendo?",
            ],
            "followup": [
                "He actualizado la informaci�n de tu cuenta. Los cambios ya deber�an estar activos. Te recomiendo cerrar sesi�n y volver a iniciar para verificar. �Todo bien ahora?",
                "Tu cuenta ha sido actualizada correctamente. Si el problema persiste, te sugiero reinstalar la aplicaci�n. �Puedo ayudarte con algo m�s?",
            ],
        },
        "app_problem": {
            "first": [
                "Entiendo que est�s teniendo problemas con la aplicaci�n. �Me podr�as describir qu� error ves o qu� parte de la app no est� funcionando?",
                "Lamento el inconveniente con la app. �Se cierra por s� sola, no carga correctamente, o hay alg�n mensaje de error espec�fico que te aparece?",
            ],
            "followup": [
                "Te recomiendo seguir estos pasos: primero, cierra la aplicaci�n completamente. Luego, verifica que tengas la �ltima versi�n disponible. Reinicia tu dispositivo y abre la app de nuevo. Si el problema contin�a, me avisas y lo escalamos al equipo t�cnico.",
                "He reportado el problema directamente al equipo t�cnico. Mientras tanto, te sugiero reinstalar la aplicaci�n desde la tienda. Eso suele resolver la mayor�a de los problemas. �Necesitas algo m�s?",
            ],
        },
        "safety": {
            "first": [
                "Tu seguridad es nuestra m�xima prioridad. Voy a tomar acci�n de inmediato sobre tu caso. �Puedes contarme exactamente qu� sucedi�?",
                "Tomo esto con la mayor seriedad. Antes que nada, �te encuentras bien en este momento? Cu�ntame con todo detalle lo que pas� para poder actuar de inmediato.",
            ],
            "followup": [
                "Tu caso ha sido marcado como prioridad m�xima. Nuestro equipo de seguridad ya est� revis�ndolo y te contactar�n directamente. �Hay algo inmediato que necesites ahora?",
                "He escalado tu caso directamente al equipo de seguridad. Este tipo de situaciones las tratamos con la mayor urgencia posible. Te mantendremos informado. �Necesitas algo m�s en este momento?",
            ],
        },
        "payment": {
            "first": [
                "Con gusto te ayudo con el m�todo de pago. �Qu� problema est�s teniendo? �Tu tarjeta fue rechazada, necesitas agregar una nueva, o hay alg�n otro inconveniente?",
                "Entiendo. �Qu� sucede exactamente con tu pago? �Es un error al agregar la tarjeta, un cargo rechazado, o necesitas cambiar tu m�todo de pago?",
            ],
            "followup": [
                "Te sugiero verificar que los datos de tu tarjeta est�n correctos y que tengas fondos disponibles. Si el problema contin�a, intenta agregar una tarjeta diferente. �Pudiste resolverlo?",
                "He actualizado la configuraci�n de pago en tu cuenta. Intenta realizar el pago nuevamente. Si sigue sin funcionar, podr�a ser un bloqueo temporal de tu banco. �Necesitas algo m�s?",
            ],
        },
        "waiting": {
            "first": [
                "Entiendo tu frustraci�n con el tiempo de espera. �Me puedes contar cu�nto tiempo tuviste que esperar y si el conductor finalmente lleg�?",
                "Lamento mucho la demora que experimentaste. Los tiempos pueden variar dependiendo de la demanda en tu zona. �Me cuentas los detalles de cu�nto esperaste y cu�ndo fue?",
            ],
            "followup": [
                "He revisado tu caso detenidamente. Entiendo la molestia y he aplicado un cr�dito especial a tu cuenta como compensaci�n. Lo ver�s reflejado en tu pr�ximo viaje. �Hay algo m�s que necesites?",
                "Voy a aplicar un ajuste en tu cuenta por la mala experiencia que tuviste. Lamentamos sinceramente los inconvenientes. �Puedo ayudarte con algo m�s?",
            ],
        },
    },
}

# -- English responses ---------------------------------
_VOICE_EN = {
    "welcome": [
        "Hello, welcome to Cruise support. My name is {agent}, and I'll be your personal agent today. How can I help you?",
        "Hi there, thank you for calling Cruise. I'm {agent}, your support agent. I'm here to help with anything you need. What can I do for you?",
        "Welcome to Cruise. My name is {agent} and I'm happy to assist you today. Please tell me, how can I help?",
    ],
    "fallback_first": [
        "I understand. To help you in the best way possible, could you give me a bit more detail about your situation?",
        "Thank you for sharing that. I need a little more information to provide you with an accurate solution. Could you elaborate?",
        "Got it. I want to make sure I resolve this correctly. Can you tell me more about what happened?",
    ],
    "fallback_followup": [
        "I have all the information I need. Our team will follow up on your case right away. Is there anything else I can help you with?",
        "Perfect, I've recorded all the details. Your case is now being processed. Can I help you with anything else?",
        "Everything has been noted. I'll personally make sure it gets followed up on. Do you need anything else?",
    ],
    "closing": [
        "I'm so glad I could help. Don't hesitate to call us whenever you need to. Have an excellent day, take care.",
        "It was a pleasure assisting you. Remember, we're always here when you need us. Have a wonderful day.",
        "You're very welcome. I hope everything gets resolved perfectly. If you need anything in the future, we'll be right here. Take care.",
    ],
    "escalation": [
        "I completely understand your request. I'm going to transfer your case to a specialized supervisor who can better assist you. They'll contact you as soon as possible.",
        "I understand your situation. I'm escalating your case right now to a supervisor. They'll get in touch with you shortly to resolve this personally.",
    ],
    "escalated_reply": "Your case has already been escalated to a supervisor and is being processed. They'll reach out to you very soon. Is there anything urgent you need in the meantime?",
    "no_input": "It seems I couldn't hear you. Could you please repeat your question?",
    "no_input_bye": "I wasn't able to hear anything. If you need help, please don't hesitate to call us again. Goodbye.",
    "categories": {
        "trip_charge": {
            "first": [
                "I understand your concern about the charge. Let me review the details of your trip. Could you tell me the approximate date and time?",
                "I'm sorry about the inconvenience with the charge. I'm going to review your account right now. Could you give me the trip date and the amount you were charged?",
            ],
            "followup": [
                "I've located your trip and verified the receipt. I've processed the corresponding adjustment. The refund will appear in your payment method within three to five business days. Is there anything else you need?",
                "I've reviewed the transaction. There is indeed a discrepancy, and I'm initiating the correction process. You'll receive a notification when it's complete. Anything else I can help with?",
            ],
        },
        "cancellation": {
            "first": [
                "I can definitely help you with that. Are you looking to cancel an upcoming trip, or were you charged a cancellation fee you'd like to dispute?",
                "Of course. Is the trip still scheduled, or did it already happen and you were charged for the cancellation? Tell me the details.",
            ],
            "followup": [
                "I've processed your request successfully. If there was an unjustified charge, I've already initiated the refund. It will take three to five business days. Can I help with anything else?",
                "The cancellation has been processed without any issues. Remember, you can cancel free of charge within the first two minutes of requesting a ride. Need anything else?",
            ],
        },
        "refund": {
            "first": [
                "I understand you need a refund. To process it quickly, could you tell me the trip date and the reason for your request?",
                "I can absolutely help you with the refund. What was the trip date and the amount charged? I'll process it as fast as possible.",
            ],
            "followup": [
                "Your refund request has been processed successfully. The amount will appear in your account within three to five business days. We'll send you a confirmation. Anything else?",
                "The refund has been approved and is already in process. You'll see it back in your payment method very soon. Can I help with anything else?",
            ],
        },
        "driver": {
            "first": [
                "I'm very sorry you had that experience. We take these reports extremely seriously. Could you give me more details? The driver's name and trip date would be very helpful.",
                "That should never happen under any circumstances. I'm going to document your report immediately. Can you tell me exactly what happened and when?",
            ],
            "followup": [
                "Your report has been officially filed. Our quality team will review the case and take the necessary disciplinary measures. Is there anything else you need?",
                "I've documented everything in detail. This kind of behavior is absolutely not tolerated at Cruise. The quality team will review the case within the next few hours. Anything else?",
            ],
        },
        "lost_item": {
            "first": [
                "Don't worry, we'll do everything possible to recover your item. What did you lose and what was the date of the trip?",
                "I understand your concern. The good news is that most items are recovered within the first twenty-four hours. Can you tell me what you left behind and when the trip was?",
            ],
            "followup": [
                "I've already reached out to the driver. As soon as they confirm they have your item, we'll notify you to arrange the return. Anything else you need?",
                "The driver has been notified about your case. As soon as they confirm they have your item, we'll contact you to arrange the pickup. Need anything else?",
            ],
        },
        "account": {
            "first": [
                "I'd be happy to help with your account. What issue are you experiencing exactly? Is it with logging in, your profile information, or something else?",
                "Account issues usually have a quick fix. Can you tell me what you need to change or what error you're seeing?",
            ],
            "followup": [
                "I've updated your account information. The changes should be active now. I recommend logging out and back in to verify. Is everything working?",
                "Your account has been updated successfully. If the issue persists, I'd suggest reinstalling the app. Can I help with anything else?",
            ],
        },
        "app_problem": {
            "first": [
                "I understand you're having issues with the app. Could you describe what error you're seeing or which part of the app isn't working?",
                "I'm sorry about the inconvenience. Does the app close on its own, fail to load, or is there a specific error message showing up?",
            ],
            "followup": [
                "I recommend these steps: first, close the app completely. Then, check that you have the latest version. Restart your device and open the app again. If the problem continues, let me know and I'll escalate it to the tech team.",
                "I've reported the issue directly to our technical team. In the meantime, I'd suggest reinstalling the app from the store. That usually resolves most issues. Need anything else?",
            ],
        },
        "safety": {
            "first": [
                "Your safety is our absolute top priority. I'm going to take immediate action on your case. Can you tell me exactly what happened?",
                "I take this very seriously. First of all, are you okay right now? Please tell me everything that happened so I can act immediately.",
            ],
            "followup": [
                "Your case has been flagged as maximum priority. Our safety team is already reviewing it and will contact you directly. Is there anything you need right now?",
                "I've escalated your case directly to our safety team. We treat these situations with the utmost urgency. We'll keep you informed. Do you need anything else at this moment?",
            ],
        },
        "payment": {
            "first": [
                "I'd be happy to help with your payment method. What issue are you having? Was your card declined, do you need to add a new one, or is it something else?",
                "I see. What's happening exactly with your payment? Is it an error adding a card, a declined charge, or do you need to change your payment method?",
            ],
            "followup": [
                "I'd suggest verifying that your card details are correct and that you have available funds. If the problem continues, try adding a different card. Were you able to resolve it?",
                "I've updated the payment settings on your account. Try making the payment again. If it still doesn't work, it might be a temporary hold from your bank. Need anything else?",
            ],
        },
        "waiting": {
            "first": [
                "I understand your frustration with the wait time. Can you tell me how long you had to wait and whether the driver eventually arrived?",
                "I'm truly sorry about the delay you experienced. Wait times can vary depending on demand in your area. Can you tell me how long you waited and when this happened?",
            ],
            "followup": [
                "I've reviewed your case carefully. I understand the inconvenience and I've applied a special credit to your account as compensation. You'll see it on your next ride. Anything else?",
                "I'm going to apply an adjustment to your account for the poor experience. We sincerely apologize for the inconvenience. Can I help with anything else?",
            ],
        },
    },
}

# English keywords for category detection
_EN_KEYWORDS = {
    "trip_charge": ["charge", "fare", "price", "expensive", "overcharge", "receipt", "amount", "money", "cost", "bill", "charged"],
    "cancellation": ["cancel", "cancellation", "cancelled", "canceled"],
    "refund": ["refund", "money back", "return my money", "reimburse", "reimbursement"],
    "driver": ["driver", "rude", "unsafe", "dangerous", "report", "complaint", "behavior", "attitude", "driving"],
    "lost_item": ["lost", "forgot", "left", "item", "phone in car", "left my", "forgotten"],
    "account": ["account", "login", "password", "email", "phone", "access", "profile", "log in", "sign in"],
    "app_problem": ["app", "crash", "error", "bug", "not working", "map", "gps", "loading", "slow", "update", "screen", "won't open", "closes"],
    "safety": ["safety", "accident", "emergency", "danger", "harassment", "threat", "scared", "fear", "assault"],
    "payment": ["payment", "card", "wallet", "method", "add", "declined", "visa", "mastercard", "debit", "credit"],
    "waiting": ["wait", "late", "delay", "long time", "didn't arrive", "took forever", "waiting"],
}

# English closing/escalation keywords
_EN_THANK_KEYWORDS = ["thanks", "thank you", "thx", "ty", "perfect", "great", "that's all", "nothing else", "no thanks", "resolved", "all good", "bye", "goodbye"]
_EN_ESCALATION_TRIGGERS = ["manager", "supervisor", "boss", "speak to your manager", "escalate", "someone else", "higher up", "in charge"]


def _voice_detect_category_en(text: str):
    t = text.lower()
    for cat, keywords in _EN_KEYWORDS.items():
        if any(k in t for k in keywords):
            return cat
    return None


def _get_voice_responses(lang: str):
    return _VOICE_ES if lang == "es" else _VOICE_EN


def _generate_voice_response(call_sid: str, speech_text: str) -> str:
    """Generate the spoken AI response based on voice session state and language."""
    session = _voice_sessions.get(call_sid, {})
    phase = session.get("phase", "active")
    msg_count = session.get("msg_count", 0)
    lang = session.get("lang", "es")
    vr = _get_voice_responses(lang)

    # Check for closing/thank keywords
    thank_kw = _THANK_KEYWORDS if lang == "es" else _EN_THANK_KEYWORDS
    if _match_keywords(speech_text, thank_kw):
        resp = _rng.choice(vr["closing"])
        session["phase"] = "closing"
        _voice_sessions[call_sid] = session
        return resp

    # Check for escalation
    esc_kw = _ESCALATION_TRIGGERS if lang == "es" else _EN_ESCALATION_TRIGGERS
    if _match_keywords(speech_text, esc_kw):
        resp = _rng.choice(vr["escalation"])
        session["phase"] = "escalated"
        _voice_sessions[call_sid] = session
        return resp

    if phase == "escalated":
        return vr["escalated_reply"]

    # Detect category
    if lang == "es":
        cat = _detect_category(speech_text)
    else:
        cat = _voice_detect_category_en(speech_text)

    cats = vr["categories"]
    if cat and cat in cats:
        if msg_count <= 1:
            resp = _rng.choice(cats[cat]["first"])
        else:
            resp = _rng.choice(cats[cat]["followup"])
        session["category"] = cat
    elif msg_count <= 1:
        resp = _rng.choice(vr["fallback_first"])
    else:
        resp = _rng.choice(vr["fallback_followup"])

    session["msg_count"] = msg_count + 1
    _voice_sessions[call_sid] = session
    return resp


def _twiml_say(text: str, lang: str) -> str:
    """Build a <Say> tag with the right neural voice and natural SSML prosody."""
    cfg = _VOICE_CONFIG[lang]
    # Add natural pauses after periods and commas for human-like rhythm
    ssml_text = text.replace(". ", '.<break time="400ms"/> ')
    ssml_text = ssml_text.replace("? ", '?<break time="350ms"/> ')
    ssml_text = ssml_text.replace(", ", ',<break time="200ms"/> ')
    return (
        f'<Say voice="{cfg["voice"]}" language="{cfg["lang"]}">' 
        f'<prosody rate="95%" pitch="-2%">{ssml_text}</prosody>'
        f'</Say>'
    )


def _twiml_gather_speech(text: str, lang: str, action: str = "/voice/gather") -> str:
    """Build a full TwiML response that speaks then listens for speech."""
    cfg = _VOICE_CONFIG[lang]
    vr = _get_voice_responses(lang)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<Response>"
        f'<Gather input="speech" language="{cfg["lang"]}" speechTimeout="auto" '
        f'speechModel="phone_call" enhanced="true" action="{action}" method="POST">'
        f'{_twiml_say(text, lang)}'
        "</Gather>"
        f'{_twiml_say(vr["no_input_bye"], lang)}'
        "</Response>"
    )


def _twiml_hangup(text: str, lang: str) -> str:
    """Build TwiML that speaks a final message and hangs up."""
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<Response>"
        f'{_twiml_say(text, lang)}'
        "<Hangup/>"
        "</Response>"
    )


@router.post("/voice/incoming")
async def voice_incoming(request: Request):
    """Twilio webhook: incoming call � language selection menu (1=ES, 2=EN)."""
    form = await request.form()
    call_sid = form.get("CallSid", "unknown")

    _validate_twilio_sig(str(request.url), dict(form), request.headers.get("X-Twilio-Signature", ""))
    # Pre-create session
    _voice_sessions[call_sid] = {"phase": "lang_select", "msg_count": 0}

    twiml = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<Response>"
        '<Gather input="dtmf" numDigits="1" action="/voice/language" method="POST" timeout="8">'
        '<Say voice="Google.es-US-Studio-B" language="es-US">'
        '<prosody rate="95%" pitch="-2%">'
        "Gracias por llamar a Cruise."
        '<break time="400ms"/>'
        " Para espa�ol,<break time=\"200ms\"/> presiona uno."
        "</prosody>"
        "</Say>"
        "<Pause length=\"1\"/>"
        '<Say voice="Google.en-US-Studio-O" language="en-US">'
        '<prosody rate="95%" pitch="-2%">'
        "Thank you for calling Cruise."
        '<break time="400ms"/>'
        " For English,<break time=\"200ms\"/> press two."
        "</prosody>"
        "</Say>"
        "</Gather>"
        # Default to Spanish if no input
        '<Redirect method="POST">/voice/language?Digits=1</Redirect>'
        "</Response>"
    )
    return Response(content=twiml, media_type="application/xml")


@router.post("/voice/language")
async def voice_language(request: Request):
    """Twilio webhook: processes language choice and greets with AI agent."""
    form = await request.form()
    call_sid = form.get("CallSid", "unknown")
    digits = form.get("Digits", "1")

    _validate_twilio_sig(str(request.url), dict(form), request.headers.get("X-Twilio-Signature", ""))
    lang = "en" if digits == "2" else "es"
    cfg = _VOICE_CONFIG[lang]

    agent = _rng.choice(cfg["agent_names"])
    _voice_sessions[call_sid] = {
        "agent_name": agent,
        "phase": "active",
        "category": None,
        "msg_count": 0,
        "lang": lang,
    }

    vr = _get_voice_responses(lang)
    welcome = _rng.choice(vr["welcome"]).format(agent=agent)
    twiml = _twiml_gather_speech(welcome, lang)
    return Response(content=twiml, media_type="application/xml")


@router.get("/voice/phone-number")
async def get_voice_phone_number():
    """Return the Twilio support phone number for the mobile app."""
    return {"phone_number": TWILIO_PHONE_NUMBER}


@router.post("/voice/gather")
async def voice_gather(request: Request):
    """Twilio webhook: processes caller speech and responds with AI."""
    form = await request.form()
    call_sid = form.get("CallSid", "unknown")
    speech_result = form.get("SpeechResult", "")
    _validate_twilio_sig(str(request.url), dict(form), request.headers.get("X-Twilio-Signature", ""))

    session = _voice_sessions.get(call_sid, {})
    lang = session.get("lang", "es")
    vr = _get_voice_responses(lang)

    if not speech_result:
        twiml = _twiml_gather_speech(vr["no_input"], lang)
        return Response(content=twiml, media_type="application/xml")

    logging.info("[Voice AI] CallSid=%s Lang=%s Speech: %s", call_sid, lang, speech_result)

    reply = _generate_voice_response(call_sid, speech_result)

    session = _voice_sessions.get(call_sid, {})
    is_closing = session.get("phase") == "closing"

    if is_closing:
        twiml = _twiml_hangup(reply, lang)
        _voice_sessions.pop(call_sid, None)
    else:
        twiml = _twiml_gather_speech(reply, lang)

    return Response(content=twiml, media_type="application/xml")


@router.post("/voice/status")
async def voice_status(request: Request):
    """Twilio webhook: call status callback. Cleans up voice sessions."""
    form = await request.form()
    call_sid = form.get("CallSid", "unknown")
    call_status = form.get("CallStatus", "")
    logging.info("[Voice] CallSid=%s Status=%s", call_sid, call_status)
    if call_status in ("completed", "failed", "busy", "no-answer", "canceled"):
        _voice_sessions.pop(call_sid, None)
    return Response(content="<Response/>", media_type="application/xml")


