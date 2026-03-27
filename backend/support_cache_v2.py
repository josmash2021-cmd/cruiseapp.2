"""Smart response cache for AI support chat — v2.

- Firestore-backed cache (editable from dispatch panel without redeploy)
- TF-IDF semantic matching via scikit-learn (understands meaning, not just words)
- Auto-learning: good Claude responses promoted to cache after 3+ similar asks
- Backward-compatible API: find_cached_response, add_natural_variation, claude_health
"""

import random
import re
import time
import logging
import threading
from typing import Optional

log = logging.getLogger("support_cache")
_rng = random.Random()

# ═══════════════════════════════════════════════════════
#  TF-IDF MATCHER — semantic similarity via scikit-learn
# ═══════════════════════════════════════════════════════

try:
    from sklearn.feature_extraction.text import TfidfVectorizer
    from sklearn.metrics.pairwise import cosine_similarity as _cosine_sim
    _HAS_TFIDF = True
except ImportError:
    _HAS_TFIDF = False
    log.warning("scikit-learn not installed — falling back to word-overlap matching")


class CacheMatcher:
    """TF-IDF cache matcher with cosine similarity. Falls back to word overlap if sklearn missing."""

    def __init__(self):
        self._vectorizer: Optional["TfidfVectorizer"] = None
        self._tfidf_matrix = None
        self._entries: list[dict] = []  # [{key, triggers, response_en, response_es, ...}]
        self._trigger_texts: list[str] = []  # flattened trigger texts for TF-IDF
        self._trigger_to_entry: list[int] = []  # maps trigger index → entry index
        self._lock = threading.Lock()

    def load(self, entries: list[dict]):
        """Build TF-IDF matrix from cache entries."""
        with self._lock:
            self._entries = entries
            self._trigger_texts = []
            self._trigger_to_entry = []
            for i, entry in enumerate(entries):
                triggers = entry.get("triggers_en", []) + entry.get("triggers_es", [])
                if not triggers:
                    triggers = entry.get("triggers", [])
                for t in triggers:
                    self._trigger_texts.append(_normalize(t))
                    self._trigger_to_entry.append(i)

            if _HAS_TFIDF and self._trigger_texts:
                self._vectorizer = TfidfVectorizer(
                    analyzer="word",
                    ngram_range=(1, 2),  # unigrams + bigrams for better matching
                    min_df=1,
                    sublinear_tf=True,
                )
                self._tfidf_matrix = self._vectorizer.fit_transform(self._trigger_texts)
                log.info("TF-IDF matrix built: %d triggers from %d entries", len(self._trigger_texts), len(entries))
            else:
                self._vectorizer = None
                self._tfidf_matrix = None

    def find_match(self, user_msg: str, lang: str = "en") -> tuple[Optional[dict], float]:
        """Find best matching cache entry. Returns (entry_dict, score) or (None, 0.0)."""
        normalized = _normalize(user_msg)
        if len(normalized.split()) < 2:
            return None, 0.0

        with self._lock:
            if not self._entries:
                return None, 0.0

            if _HAS_TFIDF and self._vectorizer and self._tfidf_matrix is not None:
                return self._tfidf_match(normalized, lang)
            else:
                return self._word_overlap_match(normalized, lang)

    def _tfidf_match(self, normalized: str, lang: str) -> tuple[Optional[dict], float]:
        """TF-IDF cosine similarity matching."""
        try:
            user_vec = self._vectorizer.transform([normalized])
            scores = _cosine_sim(user_vec, self._tfidf_matrix)[0]
            best_idx = scores.argmax()
            best_score = float(scores[best_idx])
            if best_score >= 0.30:  # TF-IDF scores are typically lower than word overlap
                entry_idx = self._trigger_to_entry[best_idx]
                return self._entries[entry_idx], best_score
        except Exception as e:
            log.warning("TF-IDF match failed: %s", e)
        return None, 0.0

    def _word_overlap_match(self, normalized: str, lang: str) -> tuple[Optional[dict], float]:
        """Fallback word-overlap matching."""
        user_words = set(normalized.split())
        best_entry = None
        best_score = 0.0

        for i, trigger_text in enumerate(self._trigger_texts):
            trigger_words = set(trigger_text.split())
            if not trigger_words:
                continue
            intersection = user_words & trigger_words
            score = len(intersection) / len(trigger_words) if trigger_words else 0.0
            if trigger_text in normalized:
                score = max(score, 0.9)
            if score > best_score:
                best_score = score
                entry_idx = self._trigger_to_entry[i]
                best_entry = self._entries[entry_idx]

        return best_entry, best_score


# Global matcher instance
_matcher = CacheMatcher()

# Thresholds for TF-IDF vs word-overlap
_TFIDF_HIT_THRESHOLD = 0.30      # TF-IDF scores are lower — 0.30 is a strong match
_TFIDF_MAYBE_THRESHOLD = 0.20    # Possible match — use cache but flag for review
_WORD_OVERLAP_THRESHOLD = 0.65   # Legacy word-overlap threshold


# ═══════════════════════════════════════════════════════
#  DEFAULT CACHED RESPONSES — loaded on startup,
#  then overwritten by Firestore entries if available
# ═══════════════════════════════════════════════════════

DEFAULT_CACHE_ENTRIES: list[dict] = [
    # ─── PAYMENT & CHARGES ───────────────────────────
    {
        "key": "how_charge_works",
        "category": "payment",
        "triggers_en": ["how am i charged", "how does payment work", "how is the fare calculated", "fare breakdown"],
        "triggers_es": ["como me cobran", "como funciona el pago", "como se calcula la tarifa", "desglose de tarifa"],
        "response_en": "The fare is calculated based on the base rate, distance traveled, and trip duration. You can see the full breakdown in your trip receipt under Trip History. Would you like me to pull up a specific trip for you?",
        "response_es": "La tarifa se calcula en base a la tarifa base, la distancia recorrida y la duración del viaje. Puede ver el desglose completo en su recibo de viaje en el Historial de Viajes. ¿Le gustaría que revisara algún viaje en particular?",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "cancel_fee",
        "category": "payment",
        "triggers_en": ["cancel fee", "cancellation charge", "why was i charged for canceling", "charged for cancel"],
        "triggers_es": ["cargo por cancelar", "cobro por cancelación", "me cobraron por cancelar", "tarifa de cancelación"],
        "response_en": "A cancellation fee may apply if you cancel after 2 minutes of driver acceptance. This compensates the driver for their time and fuel. If you believe this was applied incorrectly, I can review the specific trip for you.",
        "response_es": "Se puede aplicar un cargo por cancelación si cancela después de 2 minutos de que el conductor aceptó. Esto compensa al conductor por su tiempo y combustible. Si cree que se aplicó incorrectamente, puedo revisar el viaje específico.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "double_charge",
        "category": "payment",
        "triggers_en": ["charged twice", "double charge", "duplicate charge", "charged two times", "billed twice"],
        "triggers_es": ["me cobraron dos veces", "cobro duplicado", "cargo doble", "cobraron doble", "cobro repetido"],
        "response_en": "I understand how concerning a double charge can be. Sometimes pending authorizations appear as separate charges but typically resolve within 3-5 business days. Let me review your recent trips to check if this was a legitimate duplicate.",
        "response_es": "Entiendo lo preocupante que puede ser un cobro doble. A veces las autorizaciones pendientes aparecen como cargos separados pero generalmente se resuelven en 3-5 días hábiles. Permítame revisar sus viajes recientes para verificar si fue un duplicado real.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "pending_charge",
        "category": "payment",
        "triggers_en": ["pending charge", "authorization hold", "temporary charge", "charge not cleared"],
        "triggers_es": ["cargo pendiente", "autorización temporal", "cobro no procesado", "cargo retenido"],
        "response_en": "Pending charges are temporary authorization holds placed at the time of your trip. These typically clear within 3-5 business days depending on your bank. If the charge hasn't cleared after 5 business days, please let me know and I'll investigate further.",
        "response_es": "Los cargos pendientes son retenciones de autorización temporales realizadas al momento de su viaje. Generalmente se liberan en 3-5 días hábiles dependiendo de su banco. Si el cargo no se ha liberado después de 5 días hábiles, avíseme y lo investigaré.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "refund_status",
        "category": "payment",
        "triggers_en": ["where is my refund", "refund status", "when will i get refund", "refund not received"],
        "triggers_es": ["donde esta mi reembolso", "estado del reembolso", "cuando recibo reembolso", "no he recibido reembolso"],
        "response_en": "Refunds typically take 5-10 business days to appear on your statement, depending on your payment provider. If it's been longer than that, I can escalate your case to our billing team for immediate review.",
        "response_es": "Los reembolsos generalmente tardan 5-10 días hábiles en aparecer en su estado de cuenta, dependiendo de su proveedor de pago. Si ha pasado más tiempo, puedo escalar su caso a nuestro equipo de facturación para revisión inmediata.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "request_refund",
        "category": "payment",
        "triggers_en": ["i want a refund", "give me refund", "refund please", "need my money back", "want money back"],
        "triggers_es": ["quiero un reembolso", "necesito reembolso", "devuelvan mi dinero", "reembolso por favor", "me devuelven"],
        "response_en": "I understand you'd like a refund. To process this, I'll need to review the specific trip. Could you tell me which trip this is regarding? I can look it up in your recent history.",
        "response_es": "Entiendo que desea un reembolso. Para procesarlo, necesito revisar el viaje específico. ¿Podría indicarme de qué viaje se trata? Puedo buscarlo en su historial reciente.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "change_payment",
        "category": "payment",
        "triggers_en": ["change payment method", "update payment", "add credit card", "remove card", "switch payment"],
        "triggers_es": ["cambiar metodo de pago", "actualizar pago", "agregar tarjeta", "quitar tarjeta", "cambiar tarjeta"],
        "response_en": "You can manage your payment methods in the app under Menu > Payment Methods. From there you can add a new card, remove an existing one, or set a default. Would you like me to walk you through the steps?",
        "response_es": "Puede administrar sus métodos de pago en la app en Menú > Métodos de Pago. Desde ahí puede agregar una nueva tarjeta, eliminar una existente o establecer una predeterminada. ¿Le gustaría que le explique los pasos?",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "payment_declined",
        "category": "payment",
        "triggers_en": ["payment declined", "card declined", "payment failed", "cant pay", "payment not working"],
        "triggers_es": ["pago rechazado", "tarjeta rechazada", "pago fallido", "no puedo pagar", "pago no funciona"],
        "response_en": "Payment declines can happen for several reasons: insufficient funds, expired card, or bank security limits. Please verify your card details in Payment Methods, or try adding a different payment method. If the issue persists, contact your bank.",
        "response_es": "Los rechazos de pago pueden ocurrir por varias razones: fondos insuficientes, tarjeta vencida o límites de seguridad del banco. Verifique los datos de su tarjeta en Métodos de Pago, o intente agregar otro método. Si el problema persiste, contacte a su banco.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "surge_pricing",
        "category": "payment",
        "triggers_en": ["surge pricing", "why so expensive", "price is high", "dynamic pricing", "higher fare"],
        "triggers_es": ["precio elevado", "por que tan caro", "tarifa alta", "precio dinamico", "cobran mucho"],
        "response_en": "During periods of high demand, prices may temporarily increase due to dynamic pricing. This helps ensure there are enough drivers available. The app always shows the estimated fare before you confirm. If you'd like to wait, prices usually normalize within 15-30 minutes.",
        "response_es": "Durante períodos de alta demanda, los precios pueden aumentar temporalmente por la tarificación dinámica. Esto ayuda a garantizar suficientes conductores disponibles. La app siempre muestra la tarifa estimada antes de confirmar. Si desea esperar, los precios generalmente se normalizan en 15-30 minutos.",
        "source": "manual", "active": True, "use_count": 0,
    },
    # ─── TRIP ISSUES ────────────────────────────────
    {
        "key": "driver_no_show",
        "category": "trip",
        "triggers_en": ["driver didnt show", "driver never arrived", "driver not coming", "waiting for driver", "no driver"],
        "triggers_es": ["conductor no llego", "no llego el conductor", "conductor no viene", "esperando conductor", "chofer no llego"],
        "response_en": "I'm sorry to hear your driver didn't arrive. This is unacceptable and I apologize for the inconvenience. If you were charged for this trip, I can flag it for a fare review. Would you like me to do that?",
        "response_es": "Lamento mucho que su conductor no haya llegado. Esto es inaceptable y le pido una disculpa por el inconveniente. Si le cobraron por este viaje, puedo marcarlo para revisión de tarifa. ¿Le gustaría que lo hiciera?",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "wrong_route",
        "category": "trip",
        "triggers_en": ["wrong route", "took longer route", "detour", "wrong way", "bad route"],
        "triggers_es": ["ruta equivocada", "ruta mas larga", "se desvio", "camino incorrecto", "mala ruta"],
        "response_en": "I understand how frustrating it is when a driver takes a different route. If this resulted in a higher fare, I can flag the trip for a fare review. Could you share the trip details so I can look into it?",
        "response_es": "Entiendo lo frustrante que es cuando un conductor toma una ruta diferente. Si esto resultó en una tarifa mayor, puedo marcar el viaje para revisión. ¿Podría compartirme los detalles del viaje para revisarlo?",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "car_didnt_match",
        "category": "trip",
        "triggers_en": ["car didnt match", "wrong car", "different vehicle", "car doesnt match", "plate doesnt match"],
        "triggers_es": ["carro no coincide", "vehiculo equivocado", "carro diferente", "placa no coincide", "auto incorrecto"],
        "response_en": "Safety is our top priority. If the vehicle didn't match what was shown in the app, that's a serious concern. I'll flag this report immediately for our safety team. Did you end up taking the ride, or did you cancel?",
        "response_es": "La seguridad es nuestra prioridad. Si el vehículo no coincidió con lo mostrado en la app, es una preocupación seria. Voy a reportar esto inmediatamente a nuestro equipo de seguridad. ¿Tomó el viaje o lo canceló?",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "lost_item",
        "category": "trip",
        "triggers_en": ["lost item", "left something", "forgot phone", "lost my bag", "left something in car"],
        "triggers_es": ["perdi algo", "deje algo", "olvide telefono", "perdi bolsa", "deje algo en el carro"],
        "response_en": "I'm sorry to hear you lost an item. You can report it through the app under Trip History > select the trip > Report Lost Item. The driver will be notified and can coordinate the return with you. Would you like me to help you with that?",
        "response_es": "Lamento que haya perdido un artículo. Puede reportarlo en la app en Historial de Viajes > seleccione el viaje > Reportar Artículo Perdido. El conductor será notificado y puede coordinar la devolución. ¿Le gustaría que le ayude con eso?",
        "source": "manual", "active": True, "use_count": 0,
    },
    # ─── ACCOUNT ─────────────────────────────────────
    {
        "key": "change_email",
        "category": "account",
        "triggers_en": ["change email", "update email", "new email", "wrong email", "email address change"],
        "triggers_es": ["cambiar correo", "actualizar correo", "nuevo correo", "correo incorrecto", "email diferente"],
        "response_en": "You can update your email address in the app under Menu > Profile > Edit. If you're having trouble accessing that option, I can help guide you through it.",
        "response_es": "Puede actualizar su correo electrónico en la app en Menú > Perfil > Editar. Si tiene problemas para acceder a esa opción, puedo guiarle paso a paso.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "change_phone",
        "category": "account",
        "triggers_en": ["change phone", "update phone number", "new phone number", "wrong phone"],
        "triggers_es": ["cambiar telefono", "actualizar numero", "nuevo numero", "telefono incorrecto"],
        "response_en": "To update your phone number, go to Menu > Profile > Edit > Phone Number. You'll receive a verification code on the new number. If you no longer have access to your old number, let me know and I can assist.",
        "response_es": "Para actualizar su número de teléfono, vaya a Menú > Perfil > Editar > Número de Teléfono. Recibirá un código de verificación en el nuevo número. Si ya no tiene acceso a su número anterior, avíseme y le puedo ayudar.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "reset_password",
        "category": "account",
        "triggers_en": ["reset password", "forgot password", "cant login", "locked out", "password not working"],
        "triggers_es": ["cambiar contraseña", "olvide contraseña", "no puedo entrar", "cuenta bloqueada", "contraseña no funciona"],
        "response_en": "To reset your password, tap 'Forgot Password' on the login screen and enter your registered email. You'll receive a reset link. If you're not receiving the email, check your spam folder or let me know and I'll help.",
        "response_es": "Para restablecer su contraseña, toque 'Olvidé mi Contraseña' en la pantalla de inicio de sesión e ingrese su correo registrado. Recibirá un enlace para restablecer. Si no recibe el correo, revise su carpeta de spam o avíseme.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "delete_account",
        "category": "account",
        "triggers_en": ["delete account", "close account", "remove account", "deactivate account", "want to leave"],
        "triggers_es": ["eliminar cuenta", "cerrar cuenta", "borrar cuenta", "desactivar cuenta", "quiero irme"],
        "response_en": "I understand you'd like to delete your account. You can request this under Menu > Settings > Delete Account. Please note this action is permanent and your data will be removed after 30 days. Is there something I can help resolve first?",
        "response_es": "Entiendo que desea eliminar su cuenta. Puede solicitarlo en Menú > Configuración > Eliminar Cuenta. Tenga en cuenta que esta acción es permanente y sus datos serán eliminados después de 30 días. ¿Hay algo que pueda ayudarle a resolver primero?",
        "source": "manual", "active": True, "use_count": 0,
    },
    # ─── APP ISSUES ──────────────────────────────────
    {
        "key": "app_crash",
        "category": "general",
        "triggers_en": ["app crashes", "app not working", "app frozen", "app keeps closing", "bug in app"],
        "triggers_es": ["app se cierra", "app no funciona", "app congelada", "app se traba", "error en app"],
        "response_en": "I'm sorry you're experiencing issues with the app. Please try these steps: 1) Close and reopen the app completely, 2) Make sure you have the latest version from the App Store/Play Store, 3) Restart your phone. If the issue persists, let me know and I'll file a bug report.",
        "response_es": "Lamento que esté experimentando problemas con la app. Por favor intente estos pasos: cierre y vuelva a abrir la app completamente, asegúrese de tener la última versión, y reinicie su teléfono. Si el problema persiste, avíseme y crearé un reporte.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "gps_problem",
        "category": "general",
        "triggers_en": ["gps not working", "wrong location", "location wrong", "pickup location wrong", "map problem"],
        "triggers_es": ["gps no funciona", "ubicacion incorrecta", "localizacion mal", "punto de recogida mal", "problema con mapa"],
        "response_en": "GPS issues can usually be resolved by enabling location services, making sure you're in an open area, and restarting the app. If the pickup pin isn't in the right spot, you can manually adjust it on the map before confirming.",
        "response_es": "Los problemas de GPS generalmente se resuelven habilitando los servicios de ubicación, asegurándose de estar en un área abierta y reiniciando la app. Si el punto de recogida no está correcto, puede ajustarlo manualmente en el mapa antes de confirmar.",
        "source": "manual", "active": True, "use_count": 0,
    },
    # ─── DRIVER-SPECIFIC ────────────────────────────
    {
        "key": "driver_earnings",
        "category": "driver",
        "triggers_en": ["how much do i earn", "earnings breakdown", "my earnings", "how pay works", "driver pay"],
        "triggers_es": ["cuanto gano", "desglose de ganancias", "mis ganancias", "como funciona el pago", "pago de conductor"],
        "response_en": "Your earnings consist of the base fare, distance and time rates, plus any tips and surge bonuses. You can view your detailed earnings in the app under Earnings. Payouts are processed weekly on Tuesdays to your linked bank account or PayPal.",
        "response_es": "Sus ganancias consisten en la tarifa base, tarifas de distancia y tiempo, más propinas y bonos de demanda alta. Puede ver sus ganancias detalladas en la app en Ganancias. Los pagos se procesan semanalmente los martes a su cuenta bancaria o PayPal vinculada.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "driver_payout",
        "category": "driver",
        "triggers_en": ["when do i get paid", "payout schedule", "payment not received", "missing payout", "late payment"],
        "triggers_es": ["cuando me pagan", "calendario de pagos", "no recibi pago", "pago faltante", "pago atrasado"],
        "response_en": "Payouts are processed every Tuesday and typically arrive within 1-2 business days. If your payout hasn't arrived by Thursday, check your bank account details in the app. If everything looks correct, I can escalate this to our payments team.",
        "response_es": "Los pagos se procesan cada martes y generalmente llegan en 1-2 días hábiles. Si su pago no ha llegado para el jueves, verifique sus datos bancarios en la app. Si todo se ve correcto, puedo escalar esto a nuestro equipo de pagos.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "driver_documents",
        "category": "driver",
        "triggers_en": ["upload documents", "expired license", "document rejected", "insurance expired", "registration expired"],
        "triggers_es": ["subir documentos", "licencia vencida", "documento rechazado", "seguro vencido", "registro vencido"],
        "response_en": "You can upload or update your documents in the app under Menu > Documents. Make sure the photos are clear, not blurry, and show the complete document. Our verification team reviews documents within 24-48 hours.",
        "response_es": "Puede subir o actualizar sus documentos en la app en Menú > Documentos. Asegúrese de que las fotos sean claras, no borrosas, y muestren el documento completo. Nuestro equipo de verificación revisa los documentos en 24-48 horas.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "driver_rating",
        "category": "driver",
        "triggers_en": ["my rating", "rating dropped", "how to improve rating", "bad rating", "low rating"],
        "triggers_es": ["mi calificacion", "bajo mi rating", "como mejorar rating", "mala calificacion", "rating bajo"],
        "response_en": "Your rating is the average of your last 100 trips. To improve it: maintain a clean vehicle, be polite and professional, follow navigation accurately, and start/end trips on time. Ratings below 4.6 may affect your account status.",
        "response_es": "Su calificación es el promedio de sus últimos 100 viajes. Para mejorarla: mantenga un vehículo limpio, sea cortés y profesional, siga la navegación con precisión y comience/termine viajes a tiempo. Calificaciones por debajo de 4.6 pueden afectar su estado de cuenta.",
        "source": "manual", "active": True, "use_count": 0,
    },
    # ─── SAFETY ────────────────────────────────────
    {
        "key": "report_safety",
        "category": "safety",
        "triggers_en": ["report driver", "unsafe driver", "dangerous driving", "felt unsafe", "driver was rude"],
        "triggers_es": ["reportar conductor", "conductor inseguro", "manejo peligroso", "me senti inseguro", "conductor grosero"],
        "response_en": "Your safety is our top priority. I'm escalating this report to our safety team immediately. Could you provide the trip date and any specific details? If you're in immediate danger, please call 911 first.",
        "response_es": "Su seguridad es nuestra prioridad. Estoy escalando este reporte a nuestro equipo de seguridad inmediatamente. ¿Podría proporcionarme la fecha del viaje y detalles específicos? Si se encuentra en peligro inmediato, llame al 911.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "sos_feature",
        "category": "safety",
        "triggers_en": ["sos button", "emergency button", "how to use sos", "emergency feature", "panic button"],
        "triggers_es": ["boton sos", "boton emergencia", "como usar sos", "funcion emergencia", "boton panico"],
        "response_en": "The SOS button is available during active trips. Tap the shield icon > SOS to alert emergency services with your real-time location. You can also share your trip with trusted contacts for live tracking.",
        "response_es": "El botón SOS está disponible durante viajes activos. Toque el ícono de escudo > SOS para alertar a servicios de emergencia con su ubicación en tiempo real. También puede compartir su viaje con contactos de confianza para rastreo en vivo.",
        "source": "manual", "active": True, "use_count": 0,
    },
    # ─── GENERAL / FEATURES ───────────────────────
    {
        "key": "promo_code",
        "category": "general",
        "triggers_en": ["promo code", "discount code", "coupon", "promotional code", "how to apply promo"],
        "triggers_es": ["codigo promocional", "codigo descuento", "cupon", "codigo promo", "como aplicar promo"],
        "response_en": "You can enter a promo code under Menu > Promotions > Enter Code. The discount will be applied automatically to your next eligible ride. Please note promo codes have expiration dates and may have usage limits.",
        "response_es": "Puede ingresar un código promocional en Menú > Promociones > Ingresar Código. El descuento se aplicará automáticamente a su próximo viaje elegible. Los códigos tienen fecha de vencimiento y pueden tener límites de uso.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "ride_tiers",
        "category": "general",
        "triggers_en": ["ride types", "what is vip", "economy vs premium", "ride tiers", "car options"],
        "triggers_es": ["tipos de viaje", "que es vip", "economy vs premium", "niveles de viaje", "opciones de vehiculo"],
        "response_en": "Cruise offers four ride tiers: Economy (affordable everyday rides), Comfort (reliable mid-range), Premium (elegant sedans), and VIP (luxury SUVs). Each tier has different pricing and vehicle standards. You can compare them when requesting a ride.",
        "response_es": "Cruise ofrece cuatro niveles: Economy (viajes económicos), Comfort (rango medio confiable), Premium (sedanes elegantes) y VIP (SUVs de lujo). Cada nivel tiene diferentes precios y estándares de vehículo. Puede compararlos al solicitar un viaje.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "schedule_ride",
        "category": "general",
        "triggers_en": ["schedule ride", "book in advance", "reserve ride", "future ride", "schedule trip"],
        "triggers_es": ["programar viaje", "reservar con anticipacion", "viaje futuro", "agendar viaje", "programar trip"],
        "response_en": "You can schedule a ride up to 7 days in advance. Tap 'Schedule' when setting your destination, then select your preferred date and time. You'll receive a notification 15 minutes before your scheduled pickup.",
        "response_es": "Puede programar un viaje hasta con 7 días de anticipación. Toque 'Programar' al establecer su destino, luego seleccione fecha y hora. Recibirá una notificación 15 minutos antes de su recogida programada.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "get_receipt",
        "category": "general",
        "triggers_en": ["get receipt", "trip receipt", "need invoice", "email receipt", "fare receipt"],
        "triggers_es": ["obtener recibo", "recibo de viaje", "necesito factura", "enviar recibo", "recibo de pago"],
        "response_en": "You can access your trip receipts under Trip History > select any trip > View Receipt. You can also have receipts emailed to you automatically under Settings > Email Receipts.",
        "response_es": "Puede acceder a sus recibos de viaje en Historial de Viajes > seleccione cualquier viaje > Ver Recibo. También puede configurar el envío automático de recibos por correo en Configuración > Recibos por Correo.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "share_trip",
        "category": "general",
        "triggers_en": ["share trip", "share my ride", "share location", "live tracking", "let someone track"],
        "triggers_es": ["compartir viaje", "compartir ubicacion", "rastreo en vivo", "seguimiento", "que me sigan"],
        "response_en": "During an active trip, tap the shield icon > Share Trip to send a real-time tracking link to your contacts. They'll be able to see your route, driver details, and ETA in real time.",
        "response_es": "Durante un viaje activo, toque el ícono de escudo > Compartir Viaje para enviar un enlace de rastreo en tiempo real a sus contactos. Podrán ver su ruta, datos del conductor y hora estimada de llegada.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "how_app_works",
        "category": "general",
        "triggers_en": ["how does cruise work", "how to use app", "new to app", "first time", "help me use"],
        "triggers_es": ["como funciona cruise", "como usar app", "soy nuevo", "primera vez", "ayuda para usar"],
        "response_en": "Welcome to Cruise! To request a ride: open the app, enter your destination, choose a ride tier, and confirm. A nearby driver will be matched to you. You can track their arrival in real time. Payment is automatic through your saved payment method.",
        "response_es": "Bienvenido a Cruise! Para solicitar un viaje: abra la app, ingrese su destino, elija un tipo de viaje y confirme. Un conductor cercano será asignado. Puede rastrear su llegada en tiempo real. El pago es automático a través de su método guardado.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "contact_support",
        "category": "general",
        "triggers_en": ["contact support", "talk to human", "real person", "customer service phone", "email support"],
        "triggers_es": ["contactar soporte", "hablar con humano", "persona real", "telefono atencion", "email soporte"],
        "response_en": "You're already connected with a support agent! I'm here to help you. If your issue needs specialized attention, I can escalate it to our team who will follow up via email within 24 hours.",
        "response_es": "Ya está conectado con un agente de soporte. Estoy aquí para ayudarle. Si su problema necesita atención especializada, puedo escalarlo a nuestro equipo que le dará seguimiento por correo en 24 horas.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "trip_history",
        "category": "general",
        "triggers_en": ["trip history", "past trips", "previous rides", "ride history", "old trips"],
        "triggers_es": ["historial viajes", "viajes anteriores", "viajes pasados", "historial de viajes", "viajes viejos"],
        "response_en": "You can view all your past trips under Menu > Trip History. Each trip shows the route, fare, driver details, and receipt. You can filter by date to find specific trips.",
        "response_es": "Puede ver todos sus viajes anteriores en Menú > Historial de Viajes. Cada viaje muestra la ruta, tarifa, datos del conductor y recibo. Puede filtrar por fecha para encontrar viajes específicos.",
        "source": "manual", "active": True, "use_count": 0,
    },
    # ─── DRIVER—SPECIFIC EXTRA ─────────────────────
    {
        "key": "report_rider",
        "category": "driver",
        "triggers_en": ["report rider", "bad passenger", "passenger was rude", "rider no show", "problem with rider"],
        "triggers_es": ["reportar pasajero", "mal pasajero", "pasajero grosero", "pasajero no llego", "problema con pasajero"],
        "response_en": "You can report a rider through the Trip History > select the trip > Report Issue. Our team reviews all driver reports. For serious safety concerns, please also contact local authorities if needed.",
        "response_es": "Puede reportar a un pasajero en Historial de Viajes > seleccione el viaje > Reportar Problema. Nuestro equipo revisa todos los reportes. Para problemas graves de seguridad, contacte también a las autoridades locales si es necesario.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "driver_navigation",
        "category": "driver",
        "triggers_en": ["navigation not working", "map wrong direction", "gps issues driving", "navigation problems"],
        "triggers_es": ["navegacion no funciona", "mapa direccion incorrecta", "problemas gps conduciendo", "problemas navegacion"],
        "response_en": "Navigation issues can usually be fixed by: restarting the app, enabling high-accuracy GPS mode, or clearing the app cache. If problems persist, you can use an external navigation app and still track the trip in Cruise.",
        "response_es": "Los problemas de navegación generalmente se resuelven: reiniciando la app, habilitando GPS de alta precisión o limpiando el caché de la app. Si los problemas persisten, puede usar una app de navegación externa y seguir rastreando el viaje en Cruise.",
        "source": "manual", "active": True, "use_count": 0,
    },
    {
        "key": "waiting_long",
        "category": "trip",
        "triggers_en": ["waiting too long", "driver taking long", "eta keeps changing", "driver is far", "long wait"],
        "triggers_es": ["mucho tiempo esperando", "conductor demora", "eta cambia", "conductor lejos", "mucha espera"],
        "response_en": "I understand the wait is frustrating. Driver ETAs can change due to traffic conditions. If the wait seems excessive, you can cancel and request a new ride. Any unfair cancellation charges will be reviewed.",
        "response_es": "Entiendo que la espera es frustrante. Los tiempos estimados pueden cambiar por el tráfico. Si la espera parece excesiva, puede cancelar y solicitar un nuevo viaje. Cualquier cargo injusto por cancelación será revisado.",
        "source": "manual", "active": True, "use_count": 0,
    },
]


# ═══════════════════════════════════════════════════════
#  FIRESTORE INTEGRATION — load/save cache entries
# ═══════════════════════════════════════════════════════

_firestore_db = None
_HAS_FIRESTORE_CACHE = False


def _init_firestore():
    """Try to connect to Firestore for cache management."""
    global _firestore_db, _HAS_FIRESTORE_CACHE
    try:
        import firebase_admin
        from firebase_admin import firestore as _fs
        # Use existing Firebase app (initialized by firestore_sync or main.py)
        if not firebase_admin._apps:
            return
        _firestore_db = _fs.client()
        _HAS_FIRESTORE_CACHE = True
        log.info("Cache connected to Firestore")
    except Exception as e:
        log.warning("Cache Firestore not available: %s", e)


def _load_from_firestore() -> list[dict]:
    """Load active cache entries from Firestore. Returns list of entry dicts."""
    if not _HAS_FIRESTORE_CACHE or not _firestore_db:
        return []
    try:
        docs = _firestore_db.collection("support_cache").where("active", "==", True).stream()
        entries = []
        for doc in docs:
            data = doc.to_dict()
            data["_doc_id"] = doc.id
            entries.append(data)
        log.info("Loaded %d cache entries from Firestore", len(entries))
        return entries
    except Exception as e:
        log.warning("Failed to load cache from Firestore: %s", e)
        return []


def _save_defaults_to_firestore():
    """Save default cache entries to Firestore if they don't exist yet."""
    if not _HAS_FIRESTORE_CACHE or not _firestore_db:
        return
    try:
        from google.cloud.firestore_v1 import SERVER_TIMESTAMP
        col = _firestore_db.collection("support_cache")
        for entry in DEFAULT_CACHE_ENTRIES:
            doc_ref = col.document(entry["key"])
            if not doc_ref.get().exists:
                doc_data = {
                    "category": entry.get("category", "general"),
                    "triggers_en": entry.get("triggers_en", []),
                    "triggers_es": entry.get("triggers_es", []),
                    "response_en": entry.get("response_en", ""),
                    "response_es": entry.get("response_es", ""),
                    "use_count": 0,
                    "last_used": None,
                    "created_at": SERVER_TIMESTAMP,
                    "source": "manual",
                    "confidence": 1.0,
                    "active": True,
                }
                doc_ref.set(doc_data)
        log.info("Default cache entries synced to Firestore")
    except Exception as e:
        log.warning("Failed to save defaults to Firestore: %s", e)


def _save_candidate_to_firestore(user_msg: str, ai_response: str, category: str, lang: str):
    """Save a Claude response as a cache candidate for auto-learning."""
    if not _HAS_FIRESTORE_CACHE or not _firestore_db:
        return
    try:
        from google.cloud.firestore_v1 import SERVER_TIMESTAMP
        _firestore_db.collection("support_cache_candidates").add({
            "user_message": user_msg[:500],
            "ai_response": ai_response[:1000],
            "language": lang,
            "category": category,
            "user_satisfied": True,
            "times_similar_asked": 1,
            "created_at": SERVER_TIMESTAMP,
        })
    except Exception as e:
        log.warning("Failed to save cache candidate: %s", e)


def _promote_candidate_if_ready(user_msg: str, ai_response: str, category: str, lang: str):
    """Check if a similar candidate has been asked 3+ times. If so, promote to active cache."""
    if not _HAS_FIRESTORE_CACHE or not _firestore_db:
        return
    try:
        # Find similar candidates (same category, recent)
        candidates = _firestore_db.collection("support_cache_candidates") \
            .where("category", "==", category) \
            .where("user_satisfied", "==", True) \
            .order_by("created_at") \
            .limit(50) \
            .stream()

        normalized_msg = _normalize(user_msg)
        best_match = None
        best_doc = None

        for doc in candidates:
            data = doc.to_dict()
            existing_norm = _normalize(data.get("user_message", ""))
            # Simple word overlap to find similar questions
            user_words = set(normalized_msg.split())
            existing_words = set(existing_norm.split())
            if not user_words or not existing_words:
                continue
            overlap = len(user_words & existing_words) / max(len(user_words), len(existing_words))
            if overlap >= 0.5:
                best_match = data
                best_doc = doc
                break

        if best_match and best_doc:
            count = best_match.get("times_similar_asked", 1) + 1
            best_doc.reference.update({"times_similar_asked": count})

            if count >= 3:
                # Promote to active cache
                from google.cloud.firestore_v1 import SERVER_TIMESTAMP
                trigger_key = f"auto_{category}_{int(time.time())}"
                triggers_field = "triggers_es" if lang.startswith("es") else "triggers_en"
                response_field = "response_es" if lang.startswith("es") else "response_en"

                _firestore_db.collection("support_cache").document(trigger_key).set({
                    "category": category,
                    triggers_field: [user_msg[:200], best_match.get("user_message", "")[:200]],
                    response_field: ai_response[:1000],
                    "use_count": 0,
                    "last_used": None,
                    "created_at": SERVER_TIMESTAMP,
                    "source": "auto_learned",
                    "confidence": 0.8,
                    "active": True,
                })
                log.info("Auto-promoted cache entry: %s (asked %d times)", trigger_key, count)

                # Trigger cache refresh
                refresh_cache()
        else:
            _save_candidate_to_firestore(user_msg, ai_response, category, lang)

    except Exception as e:
        log.warning("Candidate promotion check failed: %s", e)


# ═══════════════════════════════════════════════════════
#  CACHE INITIALIZATION & REFRESH
# ═══════════════════════════════════════════════════════

_cache_loaded = False
_last_refresh: float = 0.0
_REFRESH_INTERVAL = 300  # 5 minutes


def _normalize(text: str) -> str:
    """Lowercase, strip accents-ish, remove punctuation."""
    t = text.lower().strip()
    t = re.sub(r'[áàäâ]', 'a', t)
    t = re.sub(r'[éèëê]', 'e', t)
    t = re.sub(r'[íìïî]', 'i', t)
    t = re.sub(r'[óòöô]', 'o', t)
    t = re.sub(r'[úùüû]', 'u', t)
    t = re.sub(r'[ñ]', 'n', t)
    t = re.sub(r'[^a-z0-9\s]', ' ', t)
    t = re.sub(r'\s+', ' ', t).strip()
    return t


def load_cache():
    """Load cache entries from Firestore (or defaults) and build TF-IDF matrix."""
    global _cache_loaded, _last_refresh
    _init_firestore()

    entries = _load_from_firestore()
    if entries:
        # Normalize Firestore entries to match expected format
        normalized = []
        for e in entries:
            normed = {
                "key": e.get("_doc_id", ""),
                "category": e.get("category", "general"),
                "triggers_en": e.get("triggers_en", []),
                "triggers_es": e.get("triggers_es", []),
                "response_en": e.get("response_en", ""),
                "response_es": e.get("response_es", ""),
                "source": e.get("source", "unknown"),
                "active": e.get("active", True),
                "use_count": e.get("use_count", 0),
            }
            normalized.append(normed)
        _matcher.load(normalized)
        log.info("Cache loaded from Firestore: %d entries", len(normalized))
    else:
        # Use defaults
        _matcher.load(DEFAULT_CACHE_ENTRIES)
        log.info("Cache loaded from defaults: %d entries", len(DEFAULT_CACHE_ENTRIES))
        # Seed Firestore with defaults (in background thread to not block startup)
        threading.Thread(target=_save_defaults_to_firestore, daemon=True).start()

    _cache_loaded = True
    _last_refresh = time.monotonic()


def refresh_cache():
    """Refresh cache from Firestore if stale (called periodically)."""
    global _last_refresh
    now = time.monotonic()
    if now - _last_refresh < _REFRESH_INTERVAL:
        return
    _last_refresh = now
    entries = _load_from_firestore()
    if entries:
        normalized = []
        for e in entries:
            normalized.append({
                "key": e.get("_doc_id", ""),
                "category": e.get("category", "general"),
                "triggers_en": e.get("triggers_en", []),
                "triggers_es": e.get("triggers_es", []),
                "response_en": e.get("response_en", ""),
                "response_es": e.get("response_es", ""),
                "source": e.get("source", "unknown"),
                "active": e.get("active", True),
                "use_count": e.get("use_count", 0),
            })
        _matcher.load(normalized)
        log.info("Cache refreshed from Firestore: %d entries", len(normalized))


# ═══════════════════════════════════════════════════════
#  PUBLIC API — backward-compatible with v1
# ═══════════════════════════════════════════════════════

# Cache hit stats
_cache_stats = {"hits": 0, "misses": 0, "total": 0}


def find_cached_response(user_msg: str, lang: str = "en", threshold: float = None) -> Optional[str]:
    """Find a matching cached response using TF-IDF semantic matching.

    Returns the response text if match is confident enough, else None.
    """
    global _cache_stats

    if not _cache_loaded:
        load_cache()

    # Periodic refresh
    refresh_cache()

    _cache_stats["total"] += 1

    entry, score = _matcher.find_match(user_msg, lang)
    if entry is None:
        _cache_stats["misses"] += 1
        return None

    # Determine threshold based on matcher type
    if _HAS_TFIDF:
        effective_threshold = threshold or _TFIDF_HIT_THRESHOLD
    else:
        effective_threshold = threshold or _WORD_OVERLAP_THRESHOLD

    if score < effective_threshold:
        _cache_stats["misses"] += 1
        return None

    _cache_stats["hits"] += 1

    # Get response in correct language
    if lang.startswith("es"):
        resp = entry.get("response_es", "")
    else:
        resp = entry.get("response_en", "")

    if not resp:
        return None

    # Handle list or string response (v1 had lists, v2 has strings)
    if isinstance(resp, list):
        resp = _rng.choice(resp) if resp else None
        if not resp:
            return None

    # Update use_count in Firestore (fire-and-forget)
    _track_cache_use(entry)

    return resp


def _track_cache_use(entry: dict):
    """Increment use_count for cache entry in Firestore."""
    if not _HAS_FIRESTORE_CACHE or not _firestore_db:
        return
    try:
        key = entry.get("key", "")
        if not key:
            return
        from google.cloud.firestore_v1 import SERVER_TIMESTAMP
        _firestore_db.collection("support_cache").document(key).update({
            "use_count": (entry.get("use_count", 0) or 0) + 1,
            "last_used": SERVER_TIMESTAMP,
        })
    except Exception:
        pass  # Non-critical


def maybe_cache_response(user_msg: str, ai_response: str, category: str, lang: str, was_satisfied: bool = True):
    """Auto-learning: save good Claude responses as cache candidates.
    Call this when chat ends normally (no escalation).
    """
    if not was_satisfied or not ai_response or len(ai_response) < 20:
        return
    # Run in background thread
    threading.Thread(
        target=_promote_candidate_if_ready,
        args=(user_msg, ai_response, category, lang),
        daemon=True,
    ).start()


def get_cache_stats() -> dict:
    """Return cache hit/miss stats for monitoring."""
    total = _cache_stats["total"] or 1
    return {
        "hits": _cache_stats["hits"],
        "misses": _cache_stats["misses"],
        "total": _cache_stats["total"],
        "hit_rate": round(_cache_stats["hits"] / total * 100, 1),
        "entries_loaded": len(_matcher._entries),
        "has_tfidf": _HAS_TFIDF,
        "has_firestore": _HAS_FIRESTORE_CACHE,
    }


# ═══════════════════════════════════════════════════════
#  NATURAL VARIATION — make cached responses feel unique
# ═══════════════════════════════════════════════════════

_VARIATION_PREFIXES_ES = [
    "", "", "",  # Most of the time: no prefix (more natural)
    "Claro, ",
    "Por supuesto, ",
    "Con gusto le explico. ",
]

_VARIATION_PREFIXES_EN = [
    "", "", "",
    "Sure, ",
    "Of course, ",
    "Absolutely. ",
]


def add_natural_variation(response: str, agent_name: str, user_name: str, lang: str) -> str:
    """Add slight natural variation to a cached response so it doesn't feel canned."""
    prefixes = _VARIATION_PREFIXES_ES if lang.startswith("es") else _VARIATION_PREFIXES_EN
    prefix = _rng.choice(prefixes)
    result = prefix + response

    # Sometimes personalize with user name (~30% of the time)
    if _rng.random() < 0.3 and user_name:
        if lang.startswith("es"):
            result = result.rstrip(".") + f", {user_name}."
        else:
            result = result.rstrip(".") + f", {user_name}."

    return result


# ═══════════════════════════════════════════════════════
#  HEALTH MONITORING — track Claude API performance
# ═══════════════════════════════════════════════════════

class ClaudeHealthMonitor:
    """Tracks Claude API response times and failure rates."""

    def __init__(self):
        self._response_times: list[float] = []
        self._failures: list[float] = []
        self._max_history = 100
        self._circuit_open_until: float = 0.0

    def record_success(self, response_time: float):
        self._response_times.append(response_time)
        if len(self._response_times) > self._max_history:
            self._response_times = self._response_times[-self._max_history:]

    def record_failure(self):
        now = time.monotonic()
        self._failures.append(now)
        self._failures = self._failures[-10:]
        recent = [f for f in self._failures if now - f < 60]
        if len(recent) >= 3:
            self._circuit_open_until = now + 300
            log.warning("Claude circuit breaker OPEN — switching to fallback for 5 minutes")

    def should_skip_claude(self) -> bool:
        now = time.monotonic()
        if now < self._circuit_open_until:
            return True
        if len(self._response_times) >= 5:
            avg = sum(self._response_times[-10:]) / len(self._response_times[-10:])
            if avg > 5.0:
                return True
        return False

    def get_stats(self) -> dict:
        avg_time = 0.0
        if self._response_times:
            avg_time = sum(self._response_times[-10:]) / len(self._response_times[-10:])
        return {
            "avg_response_time": round(avg_time, 2),
            "total_calls": len(self._response_times),
            "recent_failures": len([f for f in self._failures if time.monotonic() - f < 300]),
            "circuit_open": time.monotonic() < self._circuit_open_until,
        }


# Global instance
claude_health = ClaudeHealthMonitor()
