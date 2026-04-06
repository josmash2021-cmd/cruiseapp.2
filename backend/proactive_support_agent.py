"""
Proactive Support Agent — detects bad trips and reaches out to users before they complain.
Runs every 10 minutes via the app lifespan startup hook.

Agent 3 of the CruiseApp autonomous support agent suite.
"""
import asyncio
import logging
from datetime import datetime, timedelta, timezone
from sqlalchemy import select, and_, func
from models.database import SessionLocal, User, Trip, SupportChat, SupportMessage
from services.fcm_service import _send_fcm_push

log = logging.getLogger(__name__)

_PROACTIVE_COOLDOWN_HOURS = 48  # Don't contact the same user more than once per 48 h


async def _user_has_recent_support(user_id: int, db, hours: int = 48) -> bool:
    """Return True if the user already has a support chat created in the last `hours` hours."""
    cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
    r = await db.execute(
        select(SupportChat).where(
            SupportChat.user_id == user_id,
            SupportChat.created_at >= cutoff,
        ).limit(1)
    )
    return r.scalar_one_or_none() is not None


async def _create_proactive_chat(
    user_id: int, subject: str, first_message: str, lang: str, db
) -> int | None:
    """Open a support chat proactively on behalf of the system and post the first message."""
    try:
        chat = SupportChat(
            user_id=user_id,
            status="open",
            subject=subject,
            bot_phase="proactive",
            locale=lang,
            agent_name="Cruise Support",
        )
        db.add(chat)
        await db.flush()
        await db.refresh(chat)

        msg = SupportMessage(
            chat_id=chat.id,
            sender_id=None,
            sender_role="bot",
            message=first_message,
        )
        db.add(msg)
        await db.commit()
        return chat.id
    except Exception as e:
        log.error("_create_proactive_chat failed for user %d: %s", user_id, e)
        await db.rollback()
        return None


async def check_bad_trips(db) -> int:
    """
    Detect trips that ended badly and proactively reach out to the affected riders.
    Returns the count of users successfully contacted.

    Two detection rules:
      1. Rider gave a 1-2 star rating to the driver in the last 4 hours.
      2. Trip actual duration was more than 3x the estimated duration in the last 4 hours.
    """
    contacted = 0
    cutoff_start = datetime.now(timezone.utc) - timedelta(hours=4)
    cutoff_end = datetime.now(timezone.utc) - timedelta(minutes=30)  # at least 30 min ago

    # --- Rule 1: Low driver rating (1-2 stars) ---
    try:
        bad_rated_r = await db.execute(
            select(Trip).where(
                and_(
                    Trip.status == "completed",
                    Trip.rating_driver.isnot(None),
                    Trip.rating_driver <= 2,
                    Trip.completed_at >= cutoff_start,
                    Trip.completed_at <= cutoff_end,
                )
            ).limit(20)
        )
        bad_rated_trips = bad_rated_r.scalars().all()

        for trip in bad_rated_trips:
            if not trip.rider_id:
                continue
            if await _user_has_recent_support(trip.rider_id, db, hours=24):
                continue

            user_r = await db.execute(select(User).where(User.id == trip.rider_id))
            user = user_r.scalar_one_or_none()
            if not user:
                continue

            lang = "es"  # default; can be extended to read user locale
            name = (user.first_name or "").strip() or "Cliente"

            if lang.startswith("es"):
                subject = f"Viaje #{trip.id} — experiencia negativa"
                msg = (
                    f"Hola {name}, notamos que tu viaje reciente no fue de tu agrado. "
                    f"Tuviste algun problema con tu conductor o el servicio? "
                    f"Estoy aqui para ayudarte a resolverlo."
                )
                push_title = "Tuviste algun problema en tu viaje?"
                push_body = f"Hola {name}, nos importa tu experiencia. Escribenos si necesitas ayuda."
            else:
                subject = f"Trip #{trip.id} — negative experience"
                msg = (
                    f"Hi {name}, we noticed your recent trip didn't go as expected. "
                    f"Did you have any issues with your driver or the service? "
                    f"I'm here to help resolve it."
                )
                push_title = "Did something go wrong on your trip?"
                push_body = f"Hi {name}, your experience matters to us. Message us if you need help."

            chat_id = await _create_proactive_chat(trip.rider_id, subject, msg, lang, db)
            if chat_id and user.fcm_token:
                await _send_fcm_push(
                    token=user.fcm_token,
                    title=push_title,
                    body=push_body,
                    data={"type": "proactive_support", "chat_id": str(chat_id)},
                )
                contacted += 1
                log.info(
                    "Proactive outreach sent to user %d for bad-rated trip %d",
                    trip.rider_id, trip.id,
                )

    except Exception as e:
        log.error("Proactive agent bad-rating check failed: %s", e)

    # --- Rule 2: Trip took 3x the estimated duration ---
    try:
        slow_r = await db.execute(
            select(Trip).where(
                and_(
                    Trip.status == "completed",
                    Trip.actual_duration_min.isnot(None),
                    Trip.estimated_duration_min.isnot(None),
                    Trip.actual_duration_min > Trip.estimated_duration_min * 3,
                    Trip.completed_at >= cutoff_start,
                    Trip.completed_at <= cutoff_end,
                )
            ).limit(10)
        )
        slow_trips = slow_r.scalars().all()

        for trip in slow_trips:
            if not trip.rider_id:
                continue
            if await _user_has_recent_support(trip.rider_id, db, hours=_PROACTIVE_COOLDOWN_HOURS):
                continue

            user_r = await db.execute(select(User).where(User.id == trip.rider_id))
            user = user_r.scalar_one_or_none()
            if not user:
                continue

            lang = "es"
            name = (user.first_name or "").strip() or "Cliente"
            extra_min = int((trip.actual_duration_min or 0) - (trip.estimated_duration_min or 0))

            if lang.startswith("es"):
                subject = f"Viaje #{trip.id} — duracion excesiva"
                msg = (
                    f"Hola {name}, notamos que tu viaje tomo aproximadamente {extra_min} minutos "
                    f"mas de lo estimado. Tuviste algun inconveniente con la ruta? "
                    f"Puedo revisar el cobro si hubo un recargo injusto."
                )
                push_title = "Tu viaje tardo mas de lo esperado"
                push_body = f"Hola {name}, todo bien? Podemos revisar el cobro de tu ultimo viaje."
            else:
                subject = f"Trip #{trip.id} — excessive duration"
                msg = (
                    f"Hi {name}, we noticed your trip took about {extra_min} extra minutes "
                    f"beyond the estimate. Did you have any issues with the route? "
                    f"I can review the charge if there was an unfair added cost."
                )
                push_title = "Your trip took longer than expected"
                push_body = f"Hi {name}, is everything okay? We can review your last trip charge."

            chat_id = await _create_proactive_chat(trip.rider_id, subject, msg, lang, db)
            if chat_id and user.fcm_token:
                await _send_fcm_push(
                    token=user.fcm_token,
                    title=push_title,
                    body=push_body,
                    data={"type": "proactive_support", "chat_id": str(chat_id)},
                )
                contacted += 1
                log.info(
                    "Proactive outreach for slow trip %d -> user %d (+%d min)",
                    trip.id, trip.rider_id, extra_min,
                )

    except Exception as e:
        log.error("Proactive agent slow-trip check failed: %s", e)

    # Rule 3: Driver canceled after accepting (rider stranded)
    try:
        stranded_r = await db.execute(
            select(Trip).where(
                and_(
                    Trip.status == "canceled",
                    Trip.driver_id != None,
                    Trip.cancel_reason != None,
                    Trip.updated_at >= cutoff_start,
                    Trip.updated_at <= cutoff_end,
                )
            ).filter(
                Trip.cancel_reason.ilike("%driver%")
            ).limit(10)
        )
        stranded_trips = stranded_r.scalars().all()
        for trip in stranded_trips:
            if not trip.rider_id:
                continue
            if await _user_has_recent_support(trip.rider_id, db, hours=24):
                continue
            user_r = await db.execute(select(User).where(User.id == trip.rider_id))
            user = user_r.scalar_one_or_none()
            if not user:
                continue
            lang = "es"
            name = (user.first_name or "").strip() or "Cliente"
            if lang.startswith("es"):
                subject = f"Viaje #{trip.id} -- conductor cancelo"
                msg = (
                    f"Hola {name}, lamentamos que tu conductor haya cancelado tu viaje. "
                    f"Entendemos que eso puede ser muy inconveniente. "
                    f"Te cobraron alguna tarifa de cancelacion? Puedo revisarlo y procesarla si aplica."
                )
                push_title = "Lamentamos la cancelacion de tu conductor"
                push_body = f"Hola {name}, puedo ayudarte con tu viaje cancelado?"
            else:
                subject = f"Trip #{trip.id} -- driver canceled"
                msg = (
                    f"Hi {name}, we're sorry your driver canceled your trip. "
                    f"We understand that can be very inconvenient. "
                    f"Were you charged any cancellation fee? I can review and waive it if applicable."
                )
                push_title = "Sorry about your driver's cancellation"
                push_body = f"Hi {name}, can I help with your canceled trip?"
            chat_id = await _create_proactive_chat(trip.rider_id, subject, msg, lang, db)
            if chat_id and user.fcm_token:
                await _send_fcm_push(
                    token=user.fcm_token, title=push_title, body=push_body,
                    data={"type": "proactive_support", "chat_id": str(chat_id)},
                )
                contacted += 1
    except Exception as e:
        log.error("Proactive agent stranded-rider check failed: %s", e)

    # Rule 4: New driver first trip completed -- onboarding check-in
    try:
        new_driver_r = await db.execute(
            select(User).where(
                and_(
                    User.role == "driver",
                    User.created_at >= datetime.now(timezone.utc) - timedelta(days=7),
                )
            ).limit(20)
        )
        new_drivers = new_driver_r.scalars().all()
        for driver in new_drivers:
            # Check if they completed exactly 1 trip total
            trip_count_r = await db.execute(
                select(func.count(Trip.id)).where(
                    and_(Trip.driver_id == driver.id, Trip.status == "completed")
                )
            )
            trip_count = trip_count_r.scalar() or 0
            if trip_count != 1:
                continue
            if await _user_has_recent_support(driver.id, db, hours=72):
                continue
            name = (driver.first_name or "").strip() or "Conductor"
            subject = "Bienvenido a Cruise! Primer viaje completado"
            msg = (
                f"Felicitaciones {name}! Completaste tu primer viaje en Cruise. "
                f"Todo salio bien? Si tienes alguna pregunta sobre tus ganancias, documentos o la app, "
                f"estoy aqui para ayudarte."
            )
            push_title = "Felicitaciones por tu primer viaje!"
            push_body = f"Hola {name}, como te fue? Estamos aqui si necesitas ayuda."
            chat_id = await _create_proactive_chat(driver.id, subject, msg, "es", db)
            if chat_id and driver.fcm_token:
                await _send_fcm_push(
                    token=driver.fcm_token, title=push_title, body=push_body,
                    data={"type": "proactive_support", "chat_id": str(chat_id)},
                )
                contacted += 1
                log.info("Onboarding check-in sent to new driver %d", driver.id)
    except Exception as e:
        log.error("Proactive agent new-driver check failed: %s", e)

    # Rule 5: Payment failure after completed trip
    try:
        failed_pay_r = await db.execute(
            select(Trip).where(
                and_(
                    Trip.status == "completed",
                    Trip.payment_status == "failed",
                    Trip.completed_at >= cutoff_start,
                    Trip.completed_at <= cutoff_end,
                )
            ).limit(10)
        )
        failed_pay_trips = failed_pay_r.scalars().all()
        for trip in failed_pay_trips:
            if not trip.rider_id:
                continue
            if await _user_has_recent_support(trip.rider_id, db, hours=_PROACTIVE_COOLDOWN_HOURS):
                continue
            user_r = await db.execute(select(User).where(User.id == trip.rider_id))
            user = user_r.scalar_one_or_none()
            if not user:
                continue
            name = (user.first_name or "").strip() or "Cliente"
            lang = "es"
            if lang.startswith("es"):
                subject = f"Viaje #{trip.id} -- problema de pago"
                msg = (
                    f"Hola {name}, notamos que hubo un inconveniente con el pago de tu viaje reciente. "
                    f"No te preocupes, tu viaje esta registrado. "
                    f"Podemos revisar juntos tu metodo de pago para resolverlo?"
                )
                push_title = "Problema con tu pago -- podemos ayudar"
                push_body = f"Hola {name}, hay un detalle con el pago de tu ultimo viaje."
            else:
                subject = f"Trip #{trip.id} -- payment issue"
                msg = (
                    f"Hi {name}, we noticed there was an issue with the payment for your recent trip. "
                    f"Don't worry, your trip is on record. "
                    f"Can we review your payment method together to resolve it?"
                )
                push_title = "Payment issue -- we can help"
                push_body = f"Hi {name}, there's a detail with your last trip payment."
            chat_id = await _create_proactive_chat(trip.rider_id, subject, msg, lang, db)
            if chat_id and user.fcm_token:
                await _send_fcm_push(
                    token=user.fcm_token, title=push_title, body=push_body,
                    data={"type": "proactive_support", "chat_id": str(chat_id)},
                )
                contacted += 1
    except Exception as e:
        log.error("Proactive agent payment-failure check failed: %s", e)

    return contacted


async def run_proactive_agent_loop() -> None:
    """Run proactive detection checks every 10 minutes. Called from app lifespan."""
    log.info("Proactive support agent started")
    while True:
        try:
            await asyncio.sleep(600)  # 10 minutes
            async with SessionLocal() as db:
                count = await check_bad_trips(db)
                if count > 0:
                    log.info("Proactive support agent contacted %d user(s)", count)
        except asyncio.CancelledError:
            break
        except Exception as e:
            log.error("Proactive agent loop error: %s", e)
