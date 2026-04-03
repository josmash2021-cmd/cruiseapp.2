"""Cruise App — Admin alert notification service.

Sends real-time alerts to the dispatch app via:
1. Firestore `admin_alerts` collection (dispatch app listens in real-time)
2. Telegram bot (optional — direct to owner's phone)

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
    """Send alert to Firestore (dispatch app) + Telegram. Rate-limited per alert_type."""
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

    # 1. Write to Firestore admin_alerts collection (dispatch app listens here)
    asyncio.create_task(_save_to_firestore(alert_type, title, message, severity, data))

    # 2. Telegram message (if configured)
    if _HAS_TELEGRAM:
        asyncio.create_task(_send_telegram(title, message, severity_emoji, severity, data))


async def _save_to_firestore(alert_type: str, title: str, message: str, severity: str, data: dict = None):
    """Write alert to Firestore admin_alerts collection for dispatch app to show."""
    try:
        from config import _HAS_FIRESTORE
        if not _HAS_FIRESTORE:
            logger.warning("[Alert] Firestore not available, alert not saved")
            return

        from firebase_admin import firestore as _fs
        db = _fs.client()
        doc_data = {
            "type": alert_type,
            "title": title,
            "message": message,
            "severity": severity,
            "data": data or {},
            "read": False,
            "createdAt": _fs.SERVER_TIMESTAMP,
        }
        db.collection("admin_alerts").add(doc_data)
        logger.info("[Alert] Saved to Firestore admin_alerts")
    except Exception as e:
        logger.error("[Alert] Firestore save failed: %s", e)


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
