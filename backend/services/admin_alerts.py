"""Cruise App — Admin alert notification service.

Sends real-time alerts to the app owner via:
1. FCM push notification (to owner's phone)
2. Telegram bot (optional)
3. In-app admin inbox (always)

Alert types: payment_failed, server_error, security_threat, high_latency,
             driver_issue, ride_stuck, stripe_error, db_slow
"""

import os
import logging
import time
import asyncio
from typing import Optional
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

# Telegram bot config (optional)
TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")
_HAS_TELEGRAM = bool(TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID)

# Rate limit: max 1 alert per type per 5 minutes (avoid spam)
_alert_cooldowns: dict[str, float] = {}
_COOLDOWN_SECONDS = 300.0

# Severity levels
CRITICAL = "critical"  # Payment failures, server down, security breach
HIGH = "high"          # Stripe errors, stuck rides, DB slow
MEDIUM = "medium"      # High latency, driver issues
LOW = "low"            # Informational


async def send_alert(
    alert_type: str,
    title: str,
    message: str,
    severity: str = HIGH,
    data: Optional[dict] = None,
):
    """Send alert to all configured channels. Rate-limited per alert_type."""
    # Rate limit check (critical alerts bypass)
    now = time.time()
    cooldown_key = f"{alert_type}:{severity}"
    if severity != CRITICAL:
        last_sent = _alert_cooldowns.get(cooldown_key, 0)
        if now - last_sent < _COOLDOWN_SECONDS:
            return  # Skip — already alerted recently
    _alert_cooldowns[cooldown_key] = now

    severity_emoji = {
        CRITICAL: "🔴",
        HIGH: "🟠",
        MEDIUM: "🟡",
        LOW: "🟢",
    }.get(severity, "⚪")

    logger.warning("[ALERT] %s %s: %s — %s", severity_emoji, severity.upper(), title, message)

    # 1. Save to admin notifications in DB (always)
    asyncio.create_task(_save_to_db(alert_type, title, message, severity, data))

    # 2. FCM push to owner (if configured)
    asyncio.create_task(_send_fcm_alert(title, message, severity, alert_type, data))

    # 3. Telegram message (if configured)
    if _HAS_TELEGRAM:
        asyncio.create_task(_send_telegram(title, message, severity_emoji, severity, data))


async def _save_to_db(alert_type: str, title: str, message: str, severity: str, data: dict = None):
    """Save alert to admin notifications table."""
    try:
        from models.database import get_db, Notification, User
        from sqlalchemy import select
        from sqlalchemy.ext.asyncio import AsyncSession
        from models.database import SessionLocal

        async with SessionLocal() as db:
            # Find admin users to notify
            result = await db.execute(select(User).where(User.role == "admin"))
            admins = result.scalars().all()
            for admin in admins:
                notif = Notification(
                    user_id=admin.id,
                    title=f"[{severity.upper()}] {title}",
                    body=message,
                    notif_type="admin_alert",
                )
                db.add(notif)
            await db.commit()
    except Exception as e:
        logger.error("[Alert] DB save failed: %s", e)


async def _send_fcm_alert(title: str, message: str, severity: str, alert_type: str, data: dict = None):
    """Send FCM push to all admin users."""
    try:
        from models.database import User
        from sqlalchemy import select
        from models.database import SessionLocal
        from services.fcm_service import _send_fcm_push

        async with SessionLocal() as db:
            result = await db.execute(
                select(User).where(User.role == "admin", User.fcm_token.isnot(None))
            )
            admins = result.scalars().all()
            for admin in admins:
                if admin.fcm_token:
                    _send_fcm_push(
                        token=admin.fcm_token,
                        title=f"Cruise Alert: {title}",
                        body=message,
                        data={
                            "type": "admin_alert",
                            "alert_type": alert_type,
                            "severity": severity,
                            **(data or {}),
                        },
                    )
    except Exception as e:
        logger.error("[Alert] FCM push failed: %s", e)


async def _send_telegram(title: str, message: str, emoji: str, severity: str, data: dict = None):
    """Send alert via Telegram bot."""
    try:
        import httpx
        text = (
            f"{emoji} *{severity.upper()}: {title}*\n\n"
            f"{message}\n\n"
            f"_{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}_"
        )
        if data:
            details = "\n".join(f"• {k}: {v}" for k, v in data.items())
            text += f"\n\n```\n{details}\n```"

        async with httpx.AsyncClient(timeout=10) as client:
            await client.post(
                f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage",
                json={
                    "chat_id": TELEGRAM_CHAT_ID,
                    "text": text,
                    "parse_mode": "Markdown",
                },
            )
        logger.info("[Alert] Telegram message sent")
    except Exception as e:
        logger.error("[Alert] Telegram failed: %s", e)
