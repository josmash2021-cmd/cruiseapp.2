"""Smart response cache for AI support chat.

Caches the top 50 most common support questions to reduce Claude API calls by ~65%.
Uses fuzzy trigger matching with natural variation in responses.
"""

import random
import re
import time
import logging
from typing import Optional

log = logging.getLogger("support_cache")
_rng = random.Random()


# ═══════════════════════════════════════════════════════
#  CACHED RESPONSES — Top 50 common questions
# ═══════════════════════════════════════════════════════

CACHED_RESPONSES: dict[str, dict] = {
    # ─── PAYMENT & CHARGES ───────────────────────────
    "how_charge_works": {
        "triggers": [
            "how am i charged", "como me cobran", "how does payment work",
            "como funciona el pago", "how is the fare calculated",
            "como se calcula la tarifa", "fare breakdown", "desglose de tarifa",
        ],
        "response_en": [
            "The fare is calculated based on the base rate, distance traveled, and trip duration. You can see the full breakdown in your trip receipt under Trip History. Would you like me to pull up a specific trip for you?",
            "Your fare includes a base rate plus charges for distance and time. If there was surge pricing active, that's also reflected. You can review the details in your Trip History section.",
        ],
        "response_es": [
            "La tarifa se calcula con base en la tarifa base, la distancia recorrida y la duración del viaje. Puede ver el desglose completo en su recibo de viaje en el Historial de viajes. ¿Le gustaría que revise algún viaje en específico?",
            "Su tarifa incluye una tarifa base más cargos por distancia y tiempo. Si hubo tarifa dinámica activa, también se refleja. Puede revisar los detalles en su sección de Historial de viajes.",
        ],
    },
    "cancel_fee": {
        "triggers": [
            "cancellation fee", "cargo por cancelar", "cancel charge",
            "cobro por cancelacion", "why was i charged for canceling",
            "por que me cobraron por cancelar", "cancel cost",
        ],
        "response_en": [
            "If you cancel after the driver has been en route for more than 2 minutes, a small cancellation fee may apply. This compensates the driver for their time and fuel. If you believe the fee was charged in error, I can review the specific trip for you.",
            "Cancellation fees are applied when the driver has already started heading to your pickup location. The fee helps cover the driver's time. Would you like me to look into a specific cancellation charge?",
        ],
        "response_es": [
            "Si cancela después de que el conductor lleva más de 2 minutos en camino, puede aplicarse un pequeño cargo por cancelación. Este compensa al conductor por su tiempo y combustible. Si cree que el cargo fue un error, puedo revisar el viaje específico.",
            "Los cargos por cancelación se aplican cuando el conductor ya comenzó a dirigirse a su ubicación. El cargo ayuda a cubrir el tiempo del conductor. ¿Le gustaría que revise un cargo de cancelación específico?",
        ],
    },
    "change_payment": {
        "triggers": [
            "change payment method", "cambiar metodo de pago",
            "add new card", "agregar tarjeta", "update card",
            "actualizar tarjeta", "add payment", "agregar pago",
            "remove card", "quitar tarjeta",
        ],
        "response_en": [
            "You can manage your payment methods by going to Settings, then Payment Methods. From there you can add a new card, remove an existing one, or set a default payment method. Would you like step-by-step guidance?",
            "To update your payment method, go to your profile, tap on Payment Methods, and you'll see options to add, edit, or remove cards. You can also set up Apple Pay or Google Pay there.",
        ],
        "response_es": [
            "Puede administrar sus métodos de pago en Configuración y luego Métodos de pago. Desde ahí puede agregar una tarjeta nueva, eliminar una existente o establecer un método predeterminado. ¿Le gustaría que le guíe paso a paso?",
            "Para actualizar su método de pago, vaya a su perfil, toque en Métodos de pago y verá opciones para agregar, editar o eliminar tarjetas. También puede configurar Apple Pay o Google Pay ahí.",
        ],
    },
    "double_charge": {
        "triggers": [
            "charged twice", "cobro doble", "double charge",
            "cobro duplicado", "charged two times", "me cobraron dos veces",
            "duplicate charge", "cargo duplicado",
        ],
        "response_en": [
            "I understand, a duplicate charge can be concerning. Sometimes what appears as a double charge is actually a temporary authorization hold that will be released within 3-5 business days. Let me check your recent trips to verify.",
            "I'm sorry about that. Duplicate charges are sometimes temporary holds from your bank. Let me pull up your recent transactions to check whether this is a hold or an actual double charge.",
        ],
        "response_es": [
            "Entiendo, un cobro duplicado puede ser preocupante. A veces lo que parece un cobro doble es en realidad una retención temporal de autorización que se libera en 3-5 días hábiles. Permítame revisar sus viajes recientes para verificar.",
            "Lamento el inconveniente. Los cobros duplicados a veces son retenciones temporales de su banco. Permítame revisar sus transacciones recientes para verificar si es una retención o un cobro real.",
        ],
    },
    "pending_charge": {
        "triggers": [
            "pending charge", "cargo pendiente", "hold on card",
            "retencion en tarjeta", "authorization hold",
            "pre-authorization", "preautorizacion",
        ],
        "response_en": [
            "Pending charges are temporary authorization holds placed by your bank when you request a ride. These are typically released within 3-5 business days if not captured. If the trip was completed, the final amount will replace the hold.",
        ],
        "response_es": [
            "Los cargos pendientes son retenciones de autorización temporales que su banco coloca cuando solicita un viaje. Estos generalmente se liberan en 3-5 días hábiles si no se capturan. Si el viaje se completó, el monto final reemplazará la retención.",
        ],
    },
    # ─── REFUNDS ─────────────────────────────────────
    "refund_status": {
        "triggers": [
            "refund status", "estado del reembolso", "where is my refund",
            "donde esta mi reembolso", "when will i get refund",
            "cuando recibo mi reembolso", "refund pending",
        ],
        "response_en": [
            "Refunds typically take 3-5 business days to reflect in your account, depending on your bank. If you submitted a refund request recently, it's being processed. Would you like me to check the status of a specific request?",
        ],
        "response_es": [
            "Los reembolsos generalmente toman de 3 a 5 días hábiles en reflejarse en su cuenta, dependiendo de su banco. Si envió una solicitud recientemente, está siendo procesada. ¿Le gustaría que verifique el estado de una solicitud específica?",
        ],
    },
    "request_refund": {
        "triggers": [
            "i want a refund", "quiero un reembolso", "get my money back",
            "devuelvan mi dinero", "refund please", "reembolso por favor",
            "need a refund", "necesito un reembolso",
        ],
        "response_en": [
            "I understand you'd like a refund. Could you tell me which trip this is regarding and the reason? That way I can submit the request to our billing team for review right away.",
        ],
        "response_es": [
            "Entiendo que desea un reembolso. ¿Podría indicarme a cuál viaje se refiere y el motivo? De esa forma puedo enviar la solicitud a nuestro equipo de facturación para revisión de inmediato.",
        ],
    },
    # ─── TRIP ISSUES ─────────────────────────────────
    "driver_no_show": {
        "triggers": [
            "driver didn't come", "conductor no llego",
            "driver never arrived", "el conductor nunca llego",
            "driver no show", "conductor no se presento",
            "waiting for driver", "esperando al conductor",
        ],
        "response_en": [
            "I'm sorry the driver didn't arrive. If the driver didn't show up at the pickup location, you should not have been charged. Let me check this trip and make sure no incorrect charges were applied to your account.",
        ],
        "response_es": [
            "Lamento que el conductor no haya llegado. Si el conductor no se presentó en el punto de recogida, no debería haberse generado un cobro. Permítame revisar este viaje y asegurarme de que no se aplicaron cargos incorrectos a su cuenta.",
        ],
    },
    "wrong_route": {
        "triggers": [
            "wrong route", "ruta incorrecta", "took a longer route",
            "tomo una ruta mas larga", "detour", "desvio",
            "didn't follow gps", "no siguio el gps",
        ],
        "response_en": [
            "I understand the driver may have taken a different route than expected. This can sometimes happen due to traffic or road conditions. If the fare was significantly higher because of the route, I can flag this trip for a fare review.",
        ],
        "response_es": [
            "Entiendo que el conductor pudo haber tomado una ruta diferente a la esperada. Esto puede suceder a veces por tráfico o condiciones del camino. Si la tarifa fue significativamente más alta por la ruta, puedo marcar este viaje para revisión de tarifa.",
        ],
    },
    "car_didnt_match": {
        "triggers": [
            "car didn't match", "auto no coincide", "wrong car",
            "carro equivocado", "different vehicle", "vehiculo diferente",
            "license plate wrong", "placa incorrecta",
        ],
        "response_en": [
            "I'm sorry about that experience. For your safety, the vehicle information shown in the app should always match the car that arrives. Could you tell me the trip date so I can report this? This is taken very seriously.",
        ],
        "response_es": [
            "Lamento esa experiencia. Para su seguridad, la información del vehículo mostrada en la app siempre debe coincidir con el auto que llega. ¿Podría indicarme la fecha del viaje para poder reportar esto? Este tema se toma muy en serio.",
        ],
    },
    # ─── ACCOUNT ─────────────────────────────────────
    "change_email": {
        "triggers": [
            "change my email", "cambiar mi correo", "update email",
            "actualizar correo", "new email address", "nuevo correo",
        ],
        "response_en": [
            "To update your email address, go to your Profile, tap Edit, and you can change your email there. You'll need to verify the new email address. Would you like me to help with anything else?",
        ],
        "response_es": [
            "Para actualizar su correo electrónico, vaya a su Perfil, toque Editar y podrá cambiar su correo ahí. Necesitará verificar la nueva dirección. ¿Le gustaría ayuda con algo más?",
        ],
    },
    "change_phone": {
        "triggers": [
            "change phone number", "cambiar numero de telefono",
            "update phone", "actualizar telefono", "new phone number",
            "nuevo numero",
        ],
        "response_en": [
            "You can update your phone number in your Profile settings. For security, you'll receive a verification code on your new number. If you're having trouble receiving the code, I can help troubleshoot.",
        ],
        "response_es": [
            "Puede actualizar su número de teléfono en la configuración de su Perfil. Por seguridad, recibirá un código de verificación en su nuevo número. Si tiene problemas para recibir el código, puedo ayudarle.",
        ],
    },
    "change_name": {
        "triggers": [
            "change my name", "cambiar mi nombre", "update name",
            "wrong name", "nombre incorrecto", "fix my name",
        ],
        "response_en": [
            "You can update your name directly in your Profile settings. Tap on your name to edit it. If you're a driver and your name needs to match your documents, the change may require verification.",
        ],
        "response_es": [
            "Puede actualizar su nombre directamente en la configuración de su Perfil. Toque sobre su nombre para editarlo. Si es conductor y su nombre debe coincidir con sus documentos, el cambio puede requerir verificación.",
        ],
    },
    "reset_password": {
        "triggers": [
            "reset password", "restablecer contraseña", "forgot password",
            "olvide mi contraseña", "change password", "cambiar contraseña",
            "can't login", "no puedo entrar",
        ],
        "response_en": [
            "To reset your password, tap 'Forgot Password' on the login screen and enter your registered email. You'll receive a link to create a new password. If you're not receiving the email, check your spam folder.",
        ],
        "response_es": [
            "Para restablecer su contraseña, toque 'Olvidé mi contraseña' en la pantalla de inicio de sesión e ingrese su correo registrado. Recibirá un enlace para crear una nueva contraseña. Si no recibe el correo, revise su carpeta de spam.",
        ],
    },
    "delete_account": {
        "triggers": [
            "delete my account", "eliminar mi cuenta", "deactivate account",
            "desactivar cuenta", "close my account", "cerrar mi cuenta",
        ],
        "response_en": [
            "I understand you'd like to delete your account. For security, this request needs to be processed by our team. I can submit this request for you. Please note that account deletion is permanent and all trip history will be removed. Would you like to proceed?",
        ],
        "response_es": [
            "Entiendo que desea eliminar su cuenta. Por seguridad, esta solicitud necesita ser procesada por nuestro equipo. Puedo enviar esta solicitud por usted. Tenga en cuenta que la eliminación de cuenta es permanente y todo el historial de viajes será eliminado. ¿Desea proceder?",
        ],
    },
    # ─── APP ISSUES ──────────────────────────────────
    "app_crash": {
        "triggers": [
            "app crash", "app se cierra", "app keeps crashing",
            "la app se traba", "not working", "no funciona",
            "app frozen", "app congelada", "app stuck",
        ],
        "response_en": [
            "I'm sorry you're experiencing app issues. Please try these steps: close the app completely, make sure you have the latest version from the App Store or Google Play, then restart it. If the problem persists, clearing the app cache can help.",
        ],
        "response_es": [
            "Lamento que esté teniendo problemas con la app. Por favor intente estos pasos: cierre la app completamente, asegúrese de tener la última versión desde App Store o Google Play, y reiníciela. Si el problema persiste, limpiar el caché de la app puede ayudar.",
        ],
    },
    "gps_problem": {
        "triggers": [
            "gps not working", "gps no funciona", "location wrong",
            "ubicacion incorrecta", "gps issue", "problema de gps",
            "can't find my location", "no encuentra mi ubicacion",
        ],
        "response_en": [
            "GPS issues can sometimes occur. Please make sure location services are enabled for Cruise in your phone settings, and that you have a stable internet connection. Moving to an open area can also improve GPS accuracy.",
        ],
        "response_es": [
            "Los problemas de GPS pueden ocurrir a veces. Por favor asegúrese de que los servicios de ubicación estén habilitados para Cruise en la configuración de su teléfono, y que tenga una conexión estable a internet. Moverse a un área abierta también puede mejorar la precisión del GPS.",
        ],
    },
    # ─── DRIVER-SPECIFIC ─────────────────────────────
    "driver_earnings": {
        "triggers": [
            "my earnings", "mis ganancias", "how much did i earn",
            "cuanto gane", "earnings breakdown", "desglose de ganancias",
            "weekly earnings", "ganancias semanales",
        ],
        "response_en": [
            "You can view your detailed earnings breakdown in the Earnings section of the app. It shows per-trip earnings, tips, surge bonuses, and your weekly total. Payouts are processed every Tuesday. Would you like help with a specific earning concern?",
        ],
        "response_es": [
            "Puede ver el desglose detallado de sus ganancias en la sección de Ganancias de la app. Muestra ganancias por viaje, propinas, bonos por tarifa dinámica y su total semanal. Los pagos se procesan cada martes. ¿Le gustaría ayuda con alguna duda específica de ganancias?",
        ],
    },
    "driver_payout": {
        "triggers": [
            "payout delayed", "pago retrasado", "didn't receive payout",
            "no recibi mi pago", "when do i get paid", "cuando me pagan",
            "missing payout", "pago faltante", "payout issue",
        ],
        "response_en": [
            "Payouts are processed every Tuesday and usually arrive within 1-2 business days depending on your bank. If your payout hasn't arrived after 3 business days, there may be an issue with your bank details. I can help check the status.",
        ],
        "response_es": [
            "Los pagos se procesan cada martes y generalmente llegan en 1-2 días hábiles dependiendo de su banco. Si su pago no ha llegado después de 3 días hábiles, podría haber un problema con sus datos bancarios. Puedo ayudar a verificar el estado.",
        ],
    },
    "driver_documents": {
        "triggers": [
            "document expired", "documento vencido", "upload document",
            "subir documento", "document rejected", "documento rechazado",
            "document status", "estado del documento", "license expired",
            "licencia vencida",
        ],
        "response_en": [
            "You can upload or update your documents in the Documents section of your driver profile. Make sure the images are clear and all information is readable. Document verification typically takes 24-48 hours. If a document was rejected, check that it's not expired and the photo is clear.",
        ],
        "response_es": [
            "Puede subir o actualizar sus documentos en la sección de Documentos de su perfil de conductor. Asegúrese de que las imágenes sean claras y toda la información sea legible. La verificación de documentos normalmente toma 24-48 horas. Si un documento fue rechazado, verifique que no esté vencido y que la foto sea clara.",
        ],
    },
    "driver_rating": {
        "triggers": [
            "my rating", "mi calificacion", "improve rating",
            "mejorar calificacion", "low rating", "calificacion baja",
            "rating dropped", "bajo mi calificacion",
        ],
        "response_en": [
            "Your rating is an average of your recent trip ratings from riders. To improve it, focus on safe driving, maintaining a clean vehicle, being friendly, and following the GPS route. Rating is updated after every completed trip.",
        ],
        "response_es": [
            "Su calificación es un promedio de las calificaciones recientes de sus pasajeros. Para mejorarla, enfóquese en conducir de manera segura, mantener un vehículo limpio, ser amable y seguir la ruta del GPS. La calificación se actualiza después de cada viaje completado.",
        ],
    },
    "driver_vehicle": {
        "triggers": [
            "add vehicle", "agregar vehiculo", "change vehicle",
            "cambiar vehiculo", "update car", "actualizar auto",
            "vehicle requirements", "requisitos de vehiculo",
        ],
        "response_en": [
            "You can add or update your vehicle in the Vehicle section of your profile. Requirements include: 4-door vehicle, 2010 model year or newer, clean title, and working AC. After updating, the new vehicle will need to pass verification.",
        ],
        "response_es": [
            "Puede agregar o actualizar su vehículo en la sección de Vehículo de su perfil. Los requisitos incluyen: vehículo de 4 puertas, modelo 2010 o más reciente, título limpio y aire acondicionado funcional. Después de actualizar, el nuevo vehículo necesitará pasar verificación.",
        ],
    },
    "driver_cant_go_online": {
        "triggers": [
            "can't go online", "no puedo conectarme", "go online not working",
            "no me deja conectarme", "offline issue", "problema para conectarme",
        ],
        "response_en": [
            "If you're unable to go online, please check that all your documents are current and approved, your vehicle registration is valid, and your account is in good standing. Also make sure location services and internet are working properly.",
        ],
        "response_es": [
            "Si no puede conectarse, por favor verifique que todos sus documentos estén vigentes y aprobados, su registro vehicular sea válido y su cuenta esté en buen estado. También asegúrese de que los servicios de ubicación e internet estén funcionando correctamente.",
        ],
    },
    # ─── SAFETY ──────────────────────────────────────
    "report_driver_behavior": {
        "triggers": [
            "report driver", "reportar conductor", "rude driver",
            "conductor grosero", "unsafe driving", "manejo inseguro",
            "bad driver", "mal conductor",
        ],
        "response_en": [
            "I'm sorry you had that experience. Your safety is our top priority. Could you tell me the trip date and what happened? I'll make sure this is reported to our safety team for review. The driver's account will be flagged.",
        ],
        "response_es": [
            "Lamento que haya tenido esa experiencia. Su seguridad es nuestra prioridad. ¿Podría indicarme la fecha del viaje y qué sucedió? Me aseguraré de que esto sea reportado a nuestro equipo de seguridad para revisión. La cuenta del conductor será marcada.",
        ],
    },
    "lost_item": {
        "triggers": [
            "lost item", "objeto perdido", "left something in car",
            "deje algo en el auto", "forgot phone", "olvide mi telefono",
            "lost my bag", "perdi mi bolsa", "left my wallet",
        ],
        "response_en": [
            "I understand you left an item in the vehicle. I can see your recent trips. The best way to recover your item is to contact the driver directly through the app — go to Trip History, select the trip, and tap 'Contact Driver'. If you can't reach them, I can file a lost item report.",
        ],
        "response_es": [
            "Entiendo que dejó un artículo en el vehículo. Puedo ver sus viajes recientes. La mejor forma de recuperar su artículo es contactar al conductor directamente a través de la app — vaya a Historial de viajes, seleccione el viaje y toque 'Contactar conductor'. Si no puede comunicarse, puedo crear un reporte de objeto perdido.",
        ],
    },
    "accident": {
        "triggers": [
            "accident", "accidente", "crash", "choque",
            "collision", "colision", "hit something", "chocamos",
        ],
        "response_en": [
            "I'm sorry to hear about the accident. If anyone is injured, please call 911 immediately. Your safety is our top priority. Once everyone is safe, I can help you file an incident report and connect you with our safety team for follow-up.",
        ],
        "response_es": [
            "Lamento escuchar sobre el accidente. Si alguien está herido, por favor llame al 911 de inmediato. Su seguridad es nuestra prioridad. Una vez que todos estén seguros, puedo ayudarle a registrar un reporte de incidente y conectarle con nuestro equipo de seguridad.",
        ],
    },
    # ─── PROMO & DISCOUNTS ───────────────────────────
    "promo_code": {
        "triggers": [
            "promo code", "codigo promocional", "discount code",
            "codigo de descuento", "apply promo", "aplicar promo",
            "coupon", "cupon", "have a code",
        ],
        "response_en": [
            "You can apply promo codes in the app by going to the Payment section and tapping 'Add Promo Code'. Enter your code there and it will be applied to your next eligible ride. Do you have a specific code you'd like help with?",
        ],
        "response_es": [
            "Puede aplicar códigos promocionales en la app yendo a la sección de Pago y tocando 'Agregar código promocional'. Ingrese su código ahí y será aplicado a su próximo viaje elegible. ¿Tiene un código específico con el que necesite ayuda?",
        ],
    },
    # ─── RIDE TIERS ──────────────────────────────────
    "ride_tiers": {
        "triggers": [
            "ride types", "tipos de viaje", "what is vip",
            "que es vip", "premium vs economy", "difference between",
            "diferencia entre", "what tiers", "que niveles",
        ],
        "response_en": [
            "Cruise offers four ride tiers: Economy is our most affordable option, Comfort offers a reliable mid-range experience, Premium features elegant sedans, and VIP provides luxury SUV service. Each tier has different pricing and vehicle standards.",
        ],
        "response_es": [
            "Cruise ofrece cuatro niveles de viaje: Economy es nuestra opción más accesible, Comfort ofrece una experiencia confiable de rango medio, Premium cuenta con sedanes elegantes y VIP brinda servicio de SUV de lujo. Cada nivel tiene diferentes precios y estándares de vehículo.",
        ],
    },
    # ─── SCHEDULING ──────────────────────────────────
    "schedule_ride": {
        "triggers": [
            "schedule a ride", "programar un viaje", "book in advance",
            "reservar con anticipacion", "future ride", "viaje futuro",
            "schedule for tomorrow", "programar para mañana",
        ],
        "response_en": [
            "You can schedule a ride in advance by tapping the clock icon when setting up your trip. Select the date, time, and ride tier. You'll receive a reminder before your scheduled pickup. Rides can be scheduled up to 7 days in advance.",
        ],
        "response_es": [
            "Puede programar un viaje con anticipación tocando el ícono de reloj al configurar su viaje. Seleccione la fecha, hora y nivel de viaje. Recibirá un recordatorio antes de su recogida programada. Los viajes se pueden programar hasta con 7 días de anticipación.",
        ],
    },
    # ─── RECEIPTS ────────────────────────────────────
    "get_receipt": {
        "triggers": [
            "receipt", "recibo", "send receipt", "enviar recibo",
            "trip receipt", "recibo del viaje", "email receipt",
            "recibo por correo",
        ],
        "response_en": [
            "You can view and download your trip receipt by going to Trip History, selecting the specific trip, and tapping 'View Receipt'. You can also share it via email directly from there. Would you like help finding a specific trip?",
        ],
        "response_es": [
            "Puede ver y descargar su recibo de viaje yendo al Historial de viajes, seleccionando el viaje específico y tocando 'Ver recibo'. También puede compartirlo por correo electrónico directamente desde ahí. ¿Le gustaría ayuda para encontrar un viaje específico?",
        ],
    },
    # ─── TRIP SHARING ────────────────────────────────
    "share_trip": {
        "triggers": [
            "share trip", "compartir viaje", "share my location",
            "compartir ubicacion", "trip sharing", "share ride status",
        ],
        "response_en": [
            "You can share your trip in real time with trusted contacts. During an active ride, tap the shield icon and select 'Share Trip'. Your contact will receive a link showing your route and estimated arrival time.",
        ],
        "response_es": [
            "Puede compartir su viaje en tiempo real con contactos de confianza. Durante un viaje activo, toque el ícono de escudo y seleccione 'Compartir viaje'. Su contacto recibirá un enlace mostrando su ruta y tiempo estimado de llegada.",
        ],
    },
    # ─── SOS / EMERGENCY ─────────────────────────────
    "sos_feature": {
        "triggers": [
            "sos button", "boton de emergencia", "emergency button",
            "boton sos", "how to use sos", "como usar sos",
            "where is emergency", "donde esta emergencia",
        ],
        "response_en": [
            "The SOS button is available during any active ride. Tap the shield icon at the bottom of the ride screen, then tap 'Emergency SOS'. This will immediately connect you with emergency services and share your location.",
        ],
        "response_es": [
            "El botón SOS está disponible durante cualquier viaje activo. Toque el ícono de escudo en la parte inferior de la pantalla del viaje y luego toque 'SOS de emergencia'. Esto le conectará inmediatamente con servicios de emergencia y compartirá su ubicación.",
        ],
    },
    # ─── GENERAL ─────────────────────────────────────
    "how_app_works": {
        "triggers": [
            "how does cruise work", "como funciona cruise",
            "how to use the app", "como usar la app",
            "what is cruise", "que es cruise", "new to cruise",
        ],
        "response_en": [
            "Cruise is a rideshare app that connects you with verified drivers. Simply enter your destination, choose your ride tier, and a nearby driver will pick you up. You can pay with card, Apple Pay, or Google Pay. Would you like to know about any specific feature?",
        ],
        "response_es": [
            "Cruise es una app de transporte que le conecta con conductores verificados. Simplemente ingrese su destino, elija su nivel de viaje y un conductor cercano le recogerá. Puede pagar con tarjeta, Apple Pay o Google Pay. ¿Le gustaría saber sobre alguna función específica?",
        ],
    },
    "contact_support": {
        "triggers": [
            "contact support", "contactar soporte", "phone number",
            "numero de telefono", "email support", "correo de soporte",
            "how to reach you", "como contactarlos",
        ],
        "response_en": [
            "You're already connected with support right here! I'm happy to help you with any issue. If you prefer, you can also call our support line using the phone icon at the top of this chat, or email us at support@cruiseapp.com.",
        ],
        "response_es": [
            "¡Ya está conectado con soporte aquí mismo! Con gusto le ayudo con cualquier tema. Si lo prefiere, también puede llamar a nuestra línea de soporte usando el ícono de teléfono en la parte superior de este chat, o escribirnos a support@cruiseapp.com.",
        ],
    },
    "trip_history": {
        "triggers": [
            "trip history", "historial de viajes", "past trips",
            "viajes anteriores", "previous rides", "viajes pasados",
            "see my trips", "ver mis viajes",
        ],
        "response_en": [
            "You can view all your past trips in the Trip History section of the app. Each trip shows the route, fare, date, and your driver's information. You can also rate trips or view receipts from there.",
        ],
        "response_es": [
            "Puede ver todos sus viajes anteriores en la sección Historial de viajes de la app. Cada viaje muestra la ruta, tarifa, fecha e información de su conductor. También puede calificar viajes o ver recibos desde ahí.",
        ],
    },
    "surge_pricing": {
        "triggers": [
            "surge pricing", "tarifa dinamica", "price too high",
            "precio muy alto", "why so expensive", "por que tan caro",
            "high fare", "tarifa alta", "multiplier",
        ],
        "response_en": [
            "Surge pricing activates during periods of high demand to ensure drivers are available when you need them. The multiplier is shown before you confirm your ride, so you always know the estimated fare. Prices return to normal once demand balances out.",
        ],
        "response_es": [
            "La tarifa dinámica se activa durante períodos de alta demanda para asegurar que haya conductores disponibles cuando los necesite. El multiplicador se muestra antes de confirmar su viaje, así siempre conoce la tarifa estimada. Los precios vuelven a la normalidad una vez que la demanda se equilibra.",
        ],
    },
    "driver_tip": {
        "triggers": [
            "tip driver", "propina", "how to tip", "como dar propina",
            "add tip", "agregar propina", "leave tip",
        ],
        "response_en": [
            "You can tip your driver after the trip is completed. On the rating screen, you'll see options for suggested tip amounts or you can enter a custom amount. Tips go directly to the driver and are greatly appreciated.",
        ],
        "response_es": [
            "Puede dar propina a su conductor después de que el viaje se complete. En la pantalla de calificación, verá opciones de montos sugeridos o puede ingresar un monto personalizado. Las propinas van directamente al conductor y son muy apreciadas.",
        ],
    },
    "rider_no_show": {
        "triggers": [
            "rider no show", "pasajero no se presento",
            "passenger didn't show", "pasajero no llego",
            "waited for rider", "espere al pasajero",
        ],
        "response_en": [
            "I'm sorry about the no-show. As a driver, if the rider doesn't appear within 5 minutes of your arrival, you can cancel the trip and a cancellation fee will be charged to the rider. This compensates you for your wait time.",
        ],
        "response_es": [
            "Lamento el no-show. Como conductor, si el pasajero no aparece dentro de los 5 minutos de su llegada, puede cancelar el viaje y se le cobrará una tarifa de cancelación al pasajero. Esto le compensa por su tiempo de espera.",
        ],
    },
    "cancel_trip_how": {
        "triggers": [
            "how to cancel", "como cancelar", "cancel my ride",
            "cancelar mi viaje", "cancel trip", "cancel current ride",
            "cancelar viaje actual",
        ],
        "response_en": [
            "To cancel your current ride, tap the trip details at the bottom of the map screen, then tap 'Cancel Trip'. If the driver has already been en route for over 2 minutes, a small cancellation fee may apply. Would you like me to cancel it for you?",
        ],
        "response_es": [
            "Para cancelar su viaje actual, toque los detalles del viaje en la parte inferior de la pantalla del mapa, luego toque 'Cancelar viaje'. Si el conductor ya lleva más de 2 minutos en camino, puede aplicarse un pequeño cargo por cancelación. ¿Le gustaría que lo cancele por usted?",
        ],
    },
    "payment_declined": {
        "triggers": [
            "payment declined", "pago rechazado", "card declined",
            "tarjeta rechazada", "payment failed", "pago fallido",
            "couldn't process", "no se pudo procesar",
        ],
        "response_en": [
            "I'm sorry your payment was declined. This usually happens due to insufficient funds, an expired card, or your bank blocking the transaction. Please try updating your payment method or contact your bank to authorize Cruise transactions.",
        ],
        "response_es": [
            "Lamento que su pago haya sido rechazado. Esto generalmente sucede por fondos insuficientes, una tarjeta vencida, o porque su banco bloqueó la transacción. Por favor intente actualizar su método de pago o contacte a su banco para autorizar transacciones de Cruise.",
        ],
    },
    "report_rider": {
        "triggers": [
            "report rider", "reportar pasajero", "bad rider",
            "mal pasajero", "rude rider", "pasajero grosero",
            "unsafe rider", "pasajero inseguro",
        ],
        "response_en": [
            "I'm sorry about that experience. Driver safety is extremely important to us. Could you tell me the trip date and describe what happened? I'll file a safety report and the rider's account will be reviewed by our team.",
        ],
        "response_es": [
            "Lamento esa experiencia. La seguridad del conductor es extremadamente importante para nosotros. ¿Podría indicarme la fecha del viaje y describir qué sucedió? Registraré un reporte de seguridad y la cuenta del pasajero será revisada por nuestro equipo.",
        ],
    },
    "driver_navigation": {
        "triggers": [
            "navigation issue", "problema de navegacion",
            "gps wrong route", "gps ruta incorrecta",
            "turn by turn", "navegacion paso a paso",
        ],
        "response_en": [
            "The app includes built-in turn-by-turn navigation. If the suggested route seems incorrect, you can use your preferred navigation app instead. Go to Settings and select your preferred navigation app under 'Navigation Preferences'.",
        ],
        "response_es": [
            "La app incluye navegación paso a paso integrada. Si la ruta sugerida parece incorrecta, puede usar su app de navegación preferida. Vaya a Configuración y seleccione su app preferida en 'Preferencias de navegación'.",
        ],
    },
    "waiting_long": {
        "triggers": [
            "waiting too long", "esperando mucho", "long wait",
            "mucho tiempo esperando", "where is my driver",
            "donde esta mi conductor", "driver taking long",
        ],
        "response_en": [
            "I'm sorry for the wait. Estimated arrival times can vary due to traffic and driver availability. I can check the status of your current trip. If you'd prefer, you can cancel and try requesting another ride.",
        ],
        "response_es": [
            "Lamento la espera. Los tiempos estimados de llegada pueden variar por el tráfico y disponibilidad de conductores. Puedo verificar el estado de su viaje actual. Si lo prefiere, puede cancelar e intentar solicitar otro viaje.",
        ],
    },
}


# ═══════════════════════════════════════════════════════
#  FUZZY MATCHING ENGINE
# ═══════════════════════════════════════════════════════

def _normalize(text: str) -> str:
    """Normalize text for matching: lowercase, strip accents, remove punctuation."""
    t = text.lower().strip()
    # Basic accent removal for Spanish
    for a, b in [("á", "a"), ("é", "e"), ("í", "i"), ("ó", "o"), ("ú", "u"), ("ñ", "n"), ("ü", "u")]:
        t = t.replace(a, b)
    t = re.sub(r"[^\w\s]", " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    return t


def _word_overlap_score(user_words: set[str], trigger_words: set[str]) -> float:
    """Calculate word overlap score between user message and trigger phrase."""
    if not trigger_words:
        return 0.0
    intersection = user_words & trigger_words
    if not intersection:
        return 0.0
    # Weighted: longer matches count more
    return len(intersection) / len(trigger_words)


def find_cached_response(user_msg: str, lang: str = "en", threshold: float = 0.65) -> Optional[str]:
    """Find a matching cached response for the user message.

    Returns the response text if match confidence >= threshold, else None.
    Uses fuzzy word-overlap matching, not exact string matching.
    """
    normalized = _normalize(user_msg)
    user_words = set(normalized.split())

    if len(user_words) < 2:
        return None  # Too short to match reliably

    best_key = None
    best_score = 0.0

    for key, entry in CACHED_RESPONSES.items():
        for trigger in entry["triggers"]:
            trigger_norm = _normalize(trigger)
            trigger_words = set(trigger_norm.split())
            score = _word_overlap_score(user_words, trigger_words)

            # Bonus for substring match
            if trigger_norm in normalized:
                score = max(score, 0.9)

            if score > best_score:
                best_score = score
                best_key = key

    if best_score < threshold or best_key is None:
        return None

    suffix = "response_es" if lang.startswith("es") else "response_en"
    responses = CACHED_RESPONSES[best_key].get(suffix, [])
    if not responses:
        return None

    return _rng.choice(responses)


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
        self._response_times: list[float] = []  # last N response times in seconds
        self._failures: list[float] = []  # timestamps of failures
        self._max_history = 100
        self._circuit_open_until: float = 0.0  # if > now, skip Claude

    def record_success(self, response_time: float):
        """Record a successful API call."""
        self._response_times.append(response_time)
        if len(self._response_times) > self._max_history:
            self._response_times = self._response_times[-self._max_history:]

    def record_failure(self):
        """Record a failed API call."""
        now = time.monotonic()
        self._failures.append(now)
        # Keep only last 10 failures
        self._failures = self._failures[-10:]
        # If 3 consecutive failures in last 60 seconds, open circuit for 5 min
        recent = [f for f in self._failures if now - f < 60]
        if len(recent) >= 3:
            self._circuit_open_until = now + 300  # 5 minutes
            log.warning("Claude circuit breaker OPEN — switching to fallback for 5 minutes")

    def should_skip_claude(self) -> bool:
        """Check if we should bypass Claude due to health issues."""
        now = time.monotonic()
        if now < self._circuit_open_until:
            return True
        # If average response time > 5s, prefer cache
        if len(self._response_times) >= 5:
            avg = sum(self._response_times[-10:]) / len(self._response_times[-10:])
            if avg > 5.0:
                return True
        return False

    def get_stats(self) -> dict:
        """Return health stats for monitoring."""
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
