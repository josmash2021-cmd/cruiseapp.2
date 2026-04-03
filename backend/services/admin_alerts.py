"""Cruise App — Admin alert notification service.

Sends real-time alerts to the dispatch app via:
1. Firestore `admin_alerts` collection (dispatch app listens in real-time)
2. Telegram bot (optional — direct to owner's phone)

Alert types: payment_failed, server_error, security_threat, high_latency,
             driver_issue, ride_stuck, stripe_error, db_slow, db_down,
             db_pool_exhausted, high_error_rate, new_driver, driver_approved,
             driver_rejected, revenue_milestone, trip_milestone
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
# Critical alerts have shorter cooldown
_CRITICAL_COOLDOWN_SECONDS = 60.0

# Severity levels
CRITICAL = "critical"  # Payment failures, server down, security breach
HIGH = "high"          # Stripe errors, stuck rides, DB slow
MEDIUM = "medium"      # High latency, driver issues
LOW = "low"            # Informational
INFO = "info"          # Positive events (new signup, milestone)

# Alert counters for stats
_alert_counts: dict[str, int] = {}


async def send_alert(
    alert_type: str,
    title: str,
    message: str,
    severity: str = HIGH,
    data: Optional[dict] = None,
):
    """Send alert to Firestore (dispatch app) + Telegram. Rate-limited per alert_type."""
    # Rate limit check (critical alerts have shorter cooldown)
    now = time.time()
    cooldown_key = f"{alert_type}:{severity}"
    cooldown = _CRITICAL_COOLDOWN_SECONDS if severity == CRITICAL else _COOLDOWN_SECONDS
    if severity not in (CRITICAL, INFO):
        last_sent = _alert_cooldowns.get(cooldown_key, 0)
        if now - last_sent < cooldown:
            return  # Skip — already alerted recently
    _alert_cooldowns[cooldown_key] = now

    # Track counts
    _alert_counts[alert_type] = _alert_counts.get(alert_type, 0) + 1

    severity_emoji = {
        CRITICAL: "🔴",
        HIGH: "🟠",
        MEDIUM: "🟡",
        LOW: "🟢",
        INFO: "🔵",
    }.get(severity, "⚪")

    logger.warning("[ALERT] %s %s: %s — %s", severity_emoji, severity.upper(), title, message)

    # 1. Write to Firestore admin_alerts collection (dispatch app listens here)
    asyncio.create_task(_save_to_firestore(alert_type, title, message, severity, data))

    # 2. Telegram message (if configured)
    if _HAS_TELEGRAM:
        asyncio.create_task(_send_telegram(title, message, severity_emoji, severity, data))


async def send_info(title: str, message: str, data: Optional[dict] = None):
    """Shortcut for informational alerts (positive events)."""
    await send_alert("info", title, message, INFO, data)


def get_alert_stats() -> dict:
    """Return alert counts by type."""
    return dict(_alert_counts)


async def _save_to_firestore(alert_type: str, title: str, message: str, severity: str, data: dict = None):
    """Write alert to Firestore admin_alerts collection for dispatch app to show."""
    try:
        from config import _HAS_FIRESTORE
        if not _HAS_FIRESTORE:
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
    except Exception as e:
        logger.error("[Alert] Telegram failed: %s", e)
