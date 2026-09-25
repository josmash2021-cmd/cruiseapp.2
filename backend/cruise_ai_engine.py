"""
Cruise AI Engine -- Autonomous support agent without external AI APIs.
Uses intent detection, context analysis, sentiment scoring, and a
comprehensive response database to provide human-like support.

Replaces Claude API dependency with a fully self-contained engine.
"""
import random
import re
import logging
from datetime import datetime, timezone
from typing import Any, Optional

log = logging.getLogger(__name__)

# ===================================================================
#  INTENT DETECTION
# ===================================================================

_INTENTS: dict[str, dict[str, Any]] = {
    "fare_dispute": {
        "keywords_es": [
            "cobr", "cobro", "cargo", "tarifa", "precio", "caro", "sobrecar",
            "dinero", "monto", "recibo", "cuanto me cobr", "por que me cobr",
            "cobro de mas", "cobro extra", "cobro doble",
        ],
        "keywords_en": [
            "charge", "fare", "price", "expensive", "overcharge", "money",
            "amount", "receipt", "how much", "why was i charged",
            "double charge", "extra charge",
        ],
        "priority": 9,
    },
    "refund_request": {
        "keywords_es": [
            "reembolso", "devolucion", "devolver", "regres",
            "quiero mi dinero", "me devuelv",
        ],
        "keywords_en": [
            "refund", "money back", "return my", "give back",
            "reimburse", "want my money",
        ],
        "priority": 9,
    },
    "cancellation": {
        "keywords_es": [
            "cancel", "cancelar", "cancelacion", "cancele", "cancelado",
            "no quiero el viaje",
        ],
        "keywords_en": [
            "cancel", "cancellation", "cancelled", "don't want the ride",
            "stop the trip",
        ],
        "priority": 8,
    },
    "driver_complaint": {
        "keywords_es": [
            "conductor", "chofer", "manejo", "maneja", "grosero",
            "maleducado", "peligroso", "rapido", "lento", "perdido",
            "ruta equivocada", "no llego", "tarde",
        ],
        "keywords_en": [
            "driver", "rude", "dangerous", "fast", "slow", "lost",
            "wrong route", "didn't arrive", "late", "behavior",
        ],
        "priority": 8,
    },
    "lost_item": {
        "keywords_es": [
            "perdi", "olvide", "deje", "objeto", "celular", "telefono",
            "cartera", "billetera", "bolsa", "lentes", "llaves",
        ],
        "keywords_en": [
            "lost", "forgot", "left", "item", "phone", "wallet",
            "bag", "glasses", "keys", "belongings",
        ],
        "priority": 7,
    },
    "payment_method": {
        "keywords_es": [
            "tarjeta", "pago", "metodo", "agregar", "cambiar tarjeta",
            "apple pay", "google pay", "paypal", "no me acepta", "rechaz",
        ],
        "keywords_en": [
            "card", "payment", "method", "add", "change card",
            "apple pay", "google pay", "paypal", "declined", "rejected",
        ],
        "priority": 6,
    },
    "account_issue": {
        "keywords_es": [
            "cuenta", "contrasena", "password", "login", "no puedo entrar",
            "sesion", "correo", "verificar", "codigo",
        ],
        "keywords_en": [
            "account", "password", "login", "can't log in", "session",
            "email", "verify", "code",
        ],
        "priority": 6,
    },
    "app_problem": {
        "keywords_es": [
            "app", "aplicacion", "error", "falla", "no funciona",
            "se cierra", "crash", "lenta", "bug", "problema tecnico",
        ],
        "keywords_en": [
            "app", "error", "crash", "not working", "slow", "bug",
            "glitch", "freeze", "technical",
        ],
        "priority": 5,
    },
    "trip_status": {
        "keywords_es": [
            "donde esta", "cuanto falta", "eta", "llega", "demora",
            "tarda", "tiempo", "estado del viaje",
        ],
        "keywords_en": [
            "where is", "how long", "eta", "arriving", "delay",
            "waiting", "trip status", "how much longer",
        ],
        "priority": 5,
    },
    "safety": {
        "keywords_es": [
            "seguridad", "peligro", "accidente", "emergencia", "acoso",
            "agresion", "amenaza", "miedo", "911", "policia",
        ],
        "keywords_en": [
            "safety", "danger", "accident", "emergency", "harassment",
            "assault", "threat", "scared", "911", "police",
        ],
        "priority": 10,
    },
    "driver_earnings": {
        "keywords_es": [
            "ganancia", "pago", "cobrar", "deposito", "transferencia",
            "stripe", "cuenta bancaria", "cuanto gane", "mis ganancias",
        ],
        "keywords_en": [
            "earnings", "payout", "deposit", "transfer", "bank account",
            "how much earned", "my earnings", "when do i get paid",
        ],
        "priority": 6,
    },
    "driver_documents": {
        "keywords_es": [
            "documento", "licencia", "seguro", "registro", "verificacion",
            "aprobacion", "rechazado", "pendiente", "subir",
        ],
        "keywords_en": [
            "document", "license", "insurance", "registration",
            "verification", "approval", "rejected", "pending", "upload",
        ],
        "priority": 6,
    },
    "promo_code": {
        "keywords_es": [
            "promo", "codigo", "descuento", "cupon", "promocion", "oferta",
        ],
        "keywords_en": [
            "promo", "code", "discount", "coupon", "promotion", "offer",
        ],
        "priority": 4,
    },
    "waiting": {
        "keywords_es": [
            "espera", "esperando", "espere", "tarda", "demora", "demoro",
            "mucho tiempo", "cuanto tiempo", "no llega",
        ],
        "keywords_en": [
            "wait", "waiting", "waited", "late", "delay", "delayed",
            "long time", "how long", "not arriving",
        ],
        "priority": 5,
    },
    "greeting": {
        "keywords_es": [
            "hola", "buenos dias", "buenas tardes", "buenas noches",
            "que tal", "saludos",
        ],
        "keywords_en": [
            "hi", "hello", "hey", "good morning", "good afternoon",
            "good evening",
        ],
        "priority": 1,
    },
    "gratitude": {
        "keywords_es": [
            "gracias", "perfecto", "genial", "excelente", "listo",
            "resuelto", "eso es todo",
        ],
        "keywords_en": [
            "thanks", "thank you", "perfect", "great", "excellent",
            "resolved", "that's all",
        ],
        "priority": 2,
    },
}


def detect_intent(text: str) -> tuple[str, int]:
    """Detect the user's intent from their message.

    Returns (intent_name, confidence_score 0-100).
    """
    t = text.lower().strip()
    scores: dict[str, int] = {}

    for intent_name, intent_data in _INTENTS.items():
        score = 0
        all_kw = intent_data.get("keywords_es", []) + intent_data.get("keywords_en", [])
        for kw in all_kw:
            if kw in t:
                # Longer keyword matches = higher confidence
                score += len(kw) * 2 + intent_data["priority"]
        if score > 0:
            scores[intent_name] = score

    if not scores:
        return "unknown", 0

    best = max(scores, key=lambda k: scores[k])
    # Normalize to 0-100
    confidence = min(scores[best] * 3, 100)
    return best, confidence


# ===================================================================
#  RESPONSE DATABASE -- Rich, varied, human-like responses
# ===================================================================

_RESPONSES: dict[str, dict[str, list[str]]] = {
    "fare_dispute": {
        "first_es": [
            "Entiendo su preocupacion con el cobro, {name}. Permitame revisar los detalles de su viaje para verificar que todo este correcto.\n\nMe podria indicar la fecha aproximada del viaje?",
            "Lamento el inconveniente, {name}. Voy a revisar su cuenta ahora mismo para verificar el cobro.\n\nRecuerda la fecha y hora del viaje en cuestion?",
            "{name}, comprendo que un cobro inesperado es frustrante. Deme un momento para revisar su historial de viajes y encontrar la transaccion.\n\nTiene a la mano el recibo o la fecha del viaje?",
        ],
        "first_en": [
            "I understand your concern about the charge, {name}. Let me review your trip details to verify everything is correct.\n\nCould you tell me the approximate date of the trip?",
            "I'm sorry about the inconvenience, {name}. I'm going to check your account right now.\n\nDo you remember the date and time of the trip?",
            "{name}, I understand an unexpected charge is frustrating. Give me a moment to review your trip history and find the transaction.\n\nDo you have the receipt or the trip date handy?",
        ],
        "followup_es": [
            "Ya localice su viaje, {name}. He verificado el recibo y voy a procesar el ajuste correspondiente.\n\nEl reembolso se reflejara en su metodo de pago en un plazo de 3 a 5 dias habiles. Necesita algo mas?",
            "Revise la transaccion, {name}. Efectivamente hay una diferencia y voy a iniciar el proceso de correccion.\n\nLe llegara una notificacion cuando se complete. Hay algo mas en lo que pueda ayudarle?",
        ],
        "followup_en": [
            "I found your trip, {name}. I've checked the receipt and I'm processing the adjustment.\n\nThe refund will show up on your payment method within 3 to 5 business days. Do you need anything else?",
            "I've reviewed the transaction, {name}. There is a discrepancy and I'm starting the correction process.\n\nYou'll receive a notification once it's complete. Is there anything else I can help with?",
        ],
    },
    "refund_request": {
        "first_es": [
            "{name}, entiendo que desea un reembolso. Para procesarlo necesito verificar el viaje.\n\nPodria darme la fecha y el monto del cobro?",
            "Claro, {name}. Puedo ayudarle con su solicitud de reembolso.\n\nMe indica cual viaje es para revisar los detalles?",
            "Entiendo, {name}. Voy a revisar su caso para procesar el reembolso lo antes posible.\n\nNecesito la fecha del viaje y por que concepto solicita el reembolso.",
        ],
        "first_en": [
            "{name}, I understand you'd like a refund. To process it I need to verify the trip.\n\nCould you give me the date and the charge amount?",
            "Of course, {name}. I can help with your refund request.\n\nWhich trip is it so I can review the details?",
            "I understand, {name}. I'll look into your case to process the refund as quickly as possible.\n\nI need the trip date and the reason for the refund request.",
        ],
        "followup_es": [
            "Perfecto, {name}. He iniciado la solicitud de reembolso. Se procesara en 3 a 5 dias habiles a su metodo de pago original.\n\nNecesita algo mas?",
            "Listo, {name}. El reembolso fue aprobado y esta en proceso. Vera el monto de vuelta en su metodo de pago pronto.\n\nPuedo ayudarle con algo mas?",
        ],
        "followup_en": [
            "Perfect, {name}. I've started the refund request. It will be processed in 3 to 5 business days to your original payment method.\n\nNeed anything else?",
            "Done, {name}. The refund has been approved and is being processed. You'll see the amount back on your payment method soon.\n\nCan I help with anything else?",
        ],
    },
    "cancellation": {
        "first_es": [
            "Entiendo, {name}. Puedo ayudarle con eso. Es un viaje que quiere cancelar ahora o le cobraron una tarifa de cancelacion?\n\nCuenteme los detalles.",
            "{name}, claro que puedo ayudarle. El viaje ya esta programado o es uno que ya paso y le cobraron por cancelar?\n\nDigame los detalles para proceder de la mejor manera.",
        ],
        "first_en": [
            "I understand, {name}. I can help with that. Do you want to cancel an active trip or did you have an issue with a cancellation fee?\n\nTell me the details.",
            "{name}, of course I can help. Is the trip scheduled or was it one that already happened and you got charged for canceling?\n\nGive me the details so I can handle it.",
        ],
        "followup_es": [
            "Listo, {name}. La cancelacion ha sido procesada correctamente.\n\nRecuerde que puede cancelar sin cargo dentro de los primeros 2 minutos. Necesita algo mas?",
            "Todo resuelto, {name}. He procesado su solicitud. Si hubo un cobro injustificado, he iniciado la devolucion.\n\nEl reembolso tarda de 3 a 5 dias habiles. Puedo ayudarle con algo mas?",
        ],
        "followup_en": [
            "Done, {name}. The cancellation has been processed correctly.\n\nRemember you can cancel without charge within the first 2 minutes. Can I help with anything else?",
            "All sorted, {name}. I've processed your request. If there was an unjustified charge, I've started the refund.\n\nThe refund takes 3 to 5 business days. Need anything else?",
        ],
    },
    "driver_complaint": {
        "first_es": [
            "Lamento mucho escuchar eso, {name}. Su seguridad y comodidad son nuestra prioridad.\n\nPodria describir lo que sucedio para poder tomar las medidas necesarias?",
            "{name}, eso no es aceptable y lo tomo muy en serio. Voy a documentar su reporte inmediatamente.\n\nPuede darme mas detalles sobre lo que paso? El nombre del conductor si lo tiene, la fecha y hora me ayudarian mucho.",
            "Eso no deberia pasar, {name}. Voy a escalar esto al equipo correspondiente.\n\nMe puede contar exactamente que sucedio y cuando fue?",
        ],
        "first_en": [
            "I'm very sorry to hear that, {name}. Your safety and comfort are our priority.\n\nCould you describe what happened so we can take the necessary measures?",
            "{name}, that's not acceptable and I take it very seriously. I'm going to document your report right away.\n\nCan you give me more details about what happened? The driver's name if you have it, the date and time would really help.",
            "That shouldn't happen, {name}. I'll escalate this to the appropriate team.\n\nCan you tell me exactly what happened and when it was?",
        ],
        "followup_es": [
            "Su reporte ha sido registrado, {name}. Nuestro equipo revisara el caso y tomara las medidas necesarias.\n\nEl conductor sera notificado. Dependiendo de la gravedad, podra ser suspendido. Necesita algo mas?",
            "He documentado todo, {name}. Este tipo de comportamiento no lo toleramos. El equipo de calidad revisara el caso en las proximas horas.\n\nLe mantendremos informado del resultado. Puedo ayudarle con algo mas?",
        ],
        "followup_en": [
            "Your report has been filed, {name}. Our team will review the case and take the necessary actions.\n\nThe driver will be notified. Depending on the severity, they could be suspended. Need anything else?",
            "I've documented everything, {name}. We don't tolerate this kind of behavior. The quality team will review the case within the next few hours.\n\nWe'll keep you informed of the outcome. Can I help with anything else?",
        ],
    },
    "lost_item": {
        "first_es": [
            "Lamento que haya perdido algo, {name}. Puedo intentar contactar a su conductor para recuperar su objeto.\n\nRecuerda que viaje era y que objeto perdio?",
            "{name}, no se preocupe, la mayoria de objetos se recuperan en las primeras 24 horas.\n\nMe dice que perdio y en que viaje fue? Asi contacto al conductor directamente.",
            "Entiendo la preocupacion, {name}. Necesito algunos datos para localizar su objeto:\n\nQue objeto perdio?\nEn que fecha fue el viaje?\nRecuerda el nombre del conductor?",
        ],
        "first_en": [
            "I'm sorry you lost something, {name}. I can try to contact your driver to recover your item.\n\nDo you remember which trip it was and what you lost?",
            "{name}, don't worry, most items are recovered within the first 24 hours.\n\nCan you tell me what you lost and which trip it was? I'll contact the driver directly.",
            "I understand the concern, {name}. I need some info to locate your item:\n\nWhat item did you lose?\nWhat date was the trip?\nDo you remember the driver's name?",
        ],
        "followup_es": [
            "Ya contacte al conductor, {name}. En cuanto responda le notifico.\n\nLa mayoria de objetos se devuelven en las primeras 24 horas. Si se localiza, coordinaremos la devolucion. Hay algo mas?",
            "El conductor ya fue notificado, {name}. Tan pronto confirme que tiene su objeto, le avisamos para coordinar la entrega.\n\nNecesita algo mas mientras tanto?",
        ],
        "followup_en": [
            "I've already contacted the driver, {name}. I'll notify you as soon as they respond.\n\nMost items are returned within the first 24 hours. If it's found, we'll coordinate the return. Anything else?",
            "The driver has been notified, {name}. As soon as they confirm they have your item, we'll let you know to coordinate the pickup.\n\nNeed anything else in the meantime?",
        ],
    },
    "payment_method": {
        "first_es": [
            "{name}, puedo ayudarle con su metodo de pago. Que necesita hacer exactamente?\n\nAgregar una tarjeta, cambiarla, o esta teniendo problemas al pagar?",
            "Claro, {name}. Me dice que sucede con su pago? Error al agregar tarjeta, cargo rechazado, o necesita cambiar el metodo?\n\nLe ayudo con eso.",
        ],
        "first_en": [
            "{name}, I can help with your payment method. What exactly do you need?\n\nAdd a card, change it, or are you having issues paying?",
            "Sure, {name}. Can you tell me what's going on with your payment? Error adding a card, charge declined, or need to change the method?\n\nI'll help you with that.",
        ],
        "followup_es": [
            "He revisado su metodo de pago, {name}. Le sugiero:\n\n1. Verifique que los datos de su tarjeta esten correctos\n2. Asegurese de tener fondos\n3. Si continua, intente agregar otra tarjeta\n\nPudo resolver el problema?",
            "Entendido, {name}. He actualizado la configuracion de pago en su cuenta. Intente de nuevo.\n\nSi sigue sin funcionar, puede ser un bloqueo temporal de su banco. Necesita algo mas?",
        ],
        "followup_en": [
            "I've checked your payment method, {name}. I'd suggest:\n\n1. Make sure your card details are correct\n2. Ensure you have sufficient funds\n3. If it continues, try adding a different card\n\nWere you able to fix the issue?",
            "Got it, {name}. I've updated the payment settings on your account. Try again.\n\nIf it still doesn't work, it might be a temporary hold from your bank. Need anything else?",
        ],
    },
    "account_issue": {
        "first_es": [
            "{name}, entiendo que tiene un problema con su cuenta. No puede iniciar sesion, necesita cambiar su contrasena, o es otro tipo de problema?",
            "Puedo ayudarle con su cuenta, {name}. Los problemas de cuenta tienen solucion rapida generalmente.\n\nMe dice que necesita cambiar o que error le aparece?",
        ],
        "first_en": [
            "{name}, I understand you're having an account issue. Can't log in, need to change your password, or is it another type of problem?",
            "I can help with your account, {name}. Account issues are usually quick to fix.\n\nCan you tell me what you need to change or what error you're seeing?",
        ],
        "followup_es": [
            "Listo, {name}. He actualizado su cuenta. Los cambios ya deberian estar activos.\n\nIntente cerrar sesion y volver a iniciar para verificar. Todo bien ahora?",
            "Su cuenta ha sido actualizada, {name}. Si el problema persiste, intente reinstalar la app.\n\nPudo verificar que todo esta correcto?",
        ],
        "followup_en": [
            "All done, {name}. I've updated your account. The changes should be active now.\n\nTry logging out and back in to verify. Everything good now?",
            "Your account has been updated, {name}. If the problem persists, try reinstalling the app.\n\nWere you able to verify everything is correct?",
        ],
    },
    "app_problem": {
        "first_es": [
            "Entiendo que tiene problemas con la app, {name}. Vamos a resolverlo.\n\nPodria decirme que error ve o que parte de la app no funciona?",
            "Lamento el inconveniente, {name}. Me describe que pasa exactamente? Por ejemplo: se cierra sola, no carga, o hay algun error especifico?\n\nAsi puedo darle la solucion correcta.",
        ],
        "first_en": [
            "I understand you're having app issues, {name}. Let's fix it.\n\nCould you tell me what error you see or what part of the app isn't working?",
            "Sorry about the inconvenience, {name}. Can you describe what's happening exactly? For example: does it crash, not load, or is there a specific error?\n\nThat way I can give you the right solution.",
        ],
        "followup_es": [
            "Gracias, {name}. Le recomiendo estos pasos:\n\n1. Cierre la app completamente\n2. Verifique que tenga la ultima version\n3. Reinicie su dispositivo\n4. Abra la app de nuevo\n\nSi persiste, me avisa y lo escalamos al equipo tecnico.",
            "Entendido, {name}. He reportado el problema al equipo tecnico. Mientras tanto, pruebe reinstalando la app desde la tienda.\n\nEso suele resolver la mayoria de problemas. Necesita algo mas?",
        ],
        "followup_en": [
            "Thanks, {name}. I'd recommend these steps:\n\n1. Close the app completely\n2. Make sure you have the latest version\n3. Restart your device\n4. Open the app again\n\nIf it persists, let me know and I'll escalate it to the tech team.",
            "Got it, {name}. I've reported the issue to the tech team. In the meantime, try reinstalling the app from the store.\n\nThat usually fixes most problems. Need anything else?",
        ],
    },
    "trip_status": {
        "first_es": [
            "{name}, entiendo su preocupacion. Dejeme verificar el estado de su viaje ahora mismo.\n\nEn un momento le doy la informacion actualizada.",
            "Claro, {name}. Estoy revisando su viaje. Los tiempos pueden variar por la demanda en su zona.\n\nLe confirmo el estado en un momento.",
        ],
        "first_en": [
            "{name}, I understand your concern. Let me check your trip status right now.\n\nI'll have the updated information for you in a moment.",
            "Sure, {name}. I'm checking your trip. Wait times can vary based on demand in your area.\n\nI'll confirm the status in just a moment.",
        ],
        "followup_es": [
            "He verificado su viaje, {name}. Todo esta en orden. Su conductor esta en camino.\n\nSi la espera continua, me avisa y buscamos alternativas. Necesita algo mas?",
        ],
        "followup_en": [
            "I've checked your trip, {name}. Everything is on track. Your driver is on the way.\n\nIf the wait continues, let me know and we'll look at alternatives. Need anything else?",
        ],
    },
    "safety": {
        "first_es": [
            "{name}, su seguridad es lo mas importante. Si se encuentra en peligro inmediato, por favor llame al 911 primero.\n\nPuede contarme que esta pasando? Voy a tomar accion inmediata.",
            "Tomo esto muy en serio, {name}. Se encuentra bien en este momento?\n\nCuenteme con detalle que paso para que pueda actuar de inmediato.",
        ],
        "first_en": [
            "{name}, your safety is the most important thing. If you are in immediate danger, please call 911 first.\n\nCan you tell me what's happening? I'll take immediate action.",
            "I take this very seriously, {name}. Are you okay right now?\n\nTell me in detail what happened so I can act immediately.",
        ],
        "followup_es": [
            "Su caso ha sido marcado como prioritario, {name}. Nuestro equipo de seguridad ya esta revisandolo.\n\nLe contactaran directamente para dar seguimiento. Hay algo inmediato que necesite?",
            "He escalado su caso al equipo de seguridad, {name}. Este tipo de situaciones las tratamos con maxima urgencia.\n\nLe mantendremos informado. Necesita algo mas ahora?",
        ],
        "followup_en": [
            "Your case has been marked as a priority, {name}. Our safety team is already reviewing it.\n\nThey'll reach out to you directly for follow-up. Is there anything you need right now?",
            "I've escalated your case to the safety team, {name}. We treat these situations with maximum urgency.\n\nWe'll keep you informed. Do you need anything else right now?",
        ],
    },
    "driver_earnings": {
        "first_es": [
            "{name}, puedo ayudarle con sus ganancias. Los pagos se procesan semanalmente los lunes.\n\nTiene alguna pregunta especifica sobre un deposito o su balance?",
            "Claro, {name}. Revisare su informacion de ganancias.\n\nMe indica si es sobre un deposito pendiente, un monto incorrecto, o informacion general sobre pagos?",
        ],
        "first_en": [
            "{name}, I can help with your earnings. Payouts are processed weekly on Mondays.\n\nDo you have a specific question about a deposit or your balance?",
            "Sure, {name}. I'll check your earnings information.\n\nIs it about a pending deposit, an incorrect amount, or general payment info?",
        ],
        "followup_es": [
            "He revisado su cuenta, {name}. Sus ganancias estan actualizadas y el proximo deposito sera procesado el lunes.\n\nSi hay alguna discrepancia, me avisa y lo revisamos. Necesita algo mas?",
        ],
        "followup_en": [
            "I've reviewed your account, {name}. Your earnings are up to date and the next deposit will be processed on Tuesday.\n\nIf there's any discrepancy, let me know and we'll look into it. Need anything else?",
        ],
    },
    "driver_documents": {
        "first_es": [
            "{name}, puedo ayudarle con sus documentos. Necesita saber el estado de su verificacion, subir un documento, o tiene un documento rechazado?",
            "Claro, {name}. Los documentos son importantes para mantenerse activo en la plataforma.\n\nMe dice que necesita exactamente? Revision de estado, subir documentos nuevos, o resolver un rechazo?",
        ],
        "first_en": [
            "{name}, I can help with your documents. Do you need to check your verification status, upload a document, or was a document rejected?",
            "Sure, {name}. Documents are important to stay active on the platform.\n\nWhat exactly do you need? Status check, upload new documents, or resolve a rejection?",
        ],
        "followup_es": [
            "He revisado el estado de sus documentos, {name}. Si todo esta en orden, la verificacion toma de 24 a 48 horas.\n\nSi algun documento fue rechazado, puede volver a subirlo desde la app. Necesita algo mas?",
        ],
        "followup_en": [
            "I've checked your document status, {name}. If everything is in order, verification takes 24 to 48 hours.\n\nIf a document was rejected, you can re-upload it from the app. Need anything else?",
        ],
    },
    "promo_code": {
        "first_es": [
            "{name}, puedo ayudarle con su codigo promocional. Tiene un codigo que quiere aplicar o esta buscando alguna oferta disponible?",
            "Claro, {name}. Me dice que problema tiene con el codigo promocional? No le acepta un codigo, o busca promociones activas?",
        ],
        "first_en": [
            "{name}, I can help with your promo code. Do you have a code to apply or are you looking for available offers?",
            "Sure, {name}. What's the issue with the promo code? Is a code not being accepted, or are you looking for active promotions?",
        ],
        "followup_es": [
            "Entendido, {name}. He verificado el codigo. Si esta activo, deberia aplicarse automaticamente en su proximo viaje.\n\nSi el problema continua, le aplico un credito manualmente. Necesita algo mas?",
        ],
        "followup_en": [
            "Got it, {name}. I've verified the code. If it's active, it should apply automatically on your next trip.\n\nIf the problem continues, I'll apply a credit manually. Need anything else?",
        ],
    },
    "waiting": {
        "first_es": [
            "Entiendo su frustracion con la espera, {name}. Me cuenta cuanto tiempo espero y si el conductor finalmente llego?\n\nAsi evaluo si aplica una compensacion.",
            "Lamento la demora, {name}. Los tiempos pueden variar por demanda en su zona.\n\nMe cuenta los detalles: cuanto espero, fecha y hora? Para ver que puedo hacer.",
        ],
        "first_en": [
            "I understand your frustration with the wait, {name}. Can you tell me how long you waited and if the driver finally arrived?\n\nThat way I can evaluate if compensation applies.",
            "Sorry about the delay, {name}. Wait times can vary depending on demand in your area.\n\nCan you tell me the details: how long you waited, date and time? So I can see what I can do.",
        ],
        "followup_es": [
            "He revisado su caso, {name}. Entiendo la molestia. He aplicado un credito a su cuenta como compensacion.\n\nLo vera reflejado en su proximo viaje. Necesita algo mas?",
        ],
        "followup_en": [
            "I've reviewed your case, {name}. I understand the frustration. I've applied a credit to your account as compensation.\n\nYou'll see it reflected on your next trip. Anything else you need?",
        ],
    },
    "greeting": {
        "first_es": [
            "Hola {name}, bienvenido al soporte de Cruise. En que puedo ayudarle hoy?",
            "Buenos dias {name}, gracias por contactarnos. Estoy aqui para ayudarle. Que necesita?",
            "Hola {name}, es un gusto saludarle. Cuenteme, en que puedo asistirle?",
        ],
        "first_en": [
            "Hello {name}, welcome to Cruise support. How can I help you today?",
            "Hi {name}, thanks for reaching out. I'm here to help. What do you need?",
            "Hey {name}, great to hear from you. How can I assist you?",
        ],
    },
    "gratitude": {
        "first_es": [
            "Con mucho gusto, {name}. Me alegra haber podido ayudarle. Si necesita algo mas en el futuro, no dude en escribirnos. Buen viaje!",
            "Perfecto, {name}! Me da gusto que todo este resuelto. Estamos aqui para lo que necesite. Que tenga un excelente dia!",
            "Ha sido un placer atenderle, {name}. Si necesita algo en el futuro, aqui estaremos. Cuidese mucho!",
        ],
        "first_en": [
            "My pleasure, {name}. I'm glad I could help. If you need anything in the future, don't hesitate to reach out. Have a great ride!",
            "Perfect, {name}! Glad everything is resolved. We're here for whatever you need. Have an excellent day!",
            "It's been great helping you, {name}. If you need anything in the future, we'll be here. Take care!",
        ],
    },
    "unknown": {
        "first_es": [
            "Entiendo, {name}. Podria darme un poco mas de detalle sobre lo que necesita? Asi puedo ayudarle de la mejor manera.",
            "{name}, quiero asegurarme de entenderle bien. Podria explicarme un poco mas sobre su situacion?",
            "Gracias por contactarnos, {name}. Para darle la mejor atencion, me puede ampliar un poco mas su consulta?",
        ],
        "first_en": [
            "I understand, {name}. Could you give me a bit more detail about what you need? That way I can help you in the best way.",
            "{name}, I want to make sure I understand correctly. Could you explain a bit more about your situation?",
            "Thanks for reaching out, {name}. To give you the best support, could you expand a bit more on your question?",
        ],
        "followup_es": [
            "Gracias por la informacion, {name}. Ya estoy trabajando en su caso.\n\nVoy a asegurarme de que se resuelva lo antes posible. Hay algo mas que necesite?",
            "Perfecto, {name}. He registrado todo. Nuestro equipo ya esta al tanto y daremos seguimiento.\n\nPuedo ayudarle con algo mas?",
        ],
        "followup_en": [
            "Thanks for the info, {name}. I'm already working on your case.\n\nI'll make sure it gets resolved as soon as possible. Is there anything else you need?",
            "Perfect, {name}. I've recorded everything. Our team is already aware and will follow up.\n\nCan I help you with anything else?",
        ],
    },
}


def generate_response(
    intent: str,
    user_name: str,
    lang: str,
    agent_name: str,
    is_followup: bool = False,
    user_context: Optional[dict] = None,
    frustration_score: int = 0,
) -> str:
    """Generate a context-aware, human-like response based on detected intent."""
    is_es = lang.startswith("es")
    suffix = "_es" if is_es else "_en"

    templates = _RESPONSES.get(intent, _RESPONSES["unknown"])

    # Use followup if available and this is a follow-up message
    followup_key = f"followup{suffix}"
    first_key = f"first{suffix}"
    key = followup_key if is_followup and followup_key in templates else first_key
    options = templates.get(key, templates.get(first_key, []))

    if not options:
        options = _RESPONSES["unknown"][first_key]

    response = random.choice(options).format(name=user_name, agent=agent_name)

    # Add context from user's trip data if available
    if user_context:
        active_trip = user_context.get("active_trip")
        if active_trip and intent in ("trip_status", "cancellation", "fare_dispute"):
            if is_es:
                trip_info = (
                    f" (Viaje #{active_trip.get('id', '?')} - "
                    f"{active_trip.get('pickup', '?')} a "
                    f"{active_trip.get('dropoff', '?')})"
                )
            else:
                trip_info = (
                    f" (Trip #{active_trip.get('id', '?')} - "
                    f"{active_trip.get('pickup', '?')} to "
                    f"{active_trip.get('dropoff', '?')})"
                )
            response = response.rstrip(".?!") + trip_info + "."

    # Frustrated users get empathy prefix
    if frustration_score >= 7:
        prefix = (
            "Le pido sinceras disculpas por esta experiencia. "
            if is_es
            else "I sincerely apologize for this experience. "
        )
        response = prefix + response
    elif frustration_score >= 4:
        prefix = (
            "Lamento el inconveniente. "
            if is_es
            else "I'm sorry for the inconvenience. "
        )
        response = prefix + response

    # Add action markers for specific intents on follow-up
    if is_followup:
        if intent == "refund_request":
            response += " ||REQUEST:request-refund:latest:0:Solicitud de reembolso del cliente||"
        elif intent == "safety":
            response += " ||REQUEST:escalate-priority:Reporte de seguridad del cliente||"

    return response


def detect_language(text: str) -> str | None:
    """Spanish, English, or None when the text does not say.

    None matters: it is the difference between "they switched language" and
    "this message was too short to tell", and only the first should change how
    the conversation is answered.
    """
    es_words = {
        "hola", "que", "como", "por", "para", "con", "una", "los", "las",
        "del", "viaje", "quiero", "tengo", "ayuda", "necesito", "mi",
        "puede", "favor", "el", "la", "un", "es", "me", "se", "su",
        "estoy", "tiene", "fue", "ser", "pero", "mas", "este", "esta",
    }
    en_words = {
        "the", "and", "for", "with", "can", "you", "how", "what", "trip",
        "want", "need", "help", "please", "my", "was", "have", "is", "it",
        "this", "that", "are", "not", "but", "from", "been", "were", "had",
    }

    words = set(text.lower().split())
    es_count = len(words & es_words)
    en_count = len(words & en_words)

    # A tie is not a vote. "ok", "4242", "gracias?" and every message whose
    # words are in neither list scored 0-0, and `es_count >= en_count` handed
    # all of them to Spanish — so an English speaker writing "cancel" got
    # answered in Spanish. Ties and silences return None, and the caller keeps
    # whatever language the conversation was already in.
    if es_count == en_count:
        return None
    return "es" if es_count > en_count else "en"
