"""Cruise App — 24/7 Telegram monitoring bot with AI assistant.

Runs as a background task on the server. Monitors app health and sends
alerts to Telegram. Owner can send commands back to check status or
ask the AI to analyze problems.

Commands:
  /status    — Server health summary
  /errors    — Recent error count
  /payments  — Payment success/failure stats
  /trips     — Active trip count
  /drivers   — Online drivers count
  /db        — Database health + latency
  /ask <msg> — Ask AI about a problem (uses Claude)
  /help      — List commands
"""

import os
import asyncio
import logging
import time
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")
_HAS_TELEGRAM = bool(TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID)

# Health check interval: 2 minutes
_CHECK_INTERVAL = 120
# Track last update_id to avoid processing old messages
_last_update_id = 0


async def _tg_send(text: str, parse_mode: str = "Markdown"):
    """Send a Telegram message."""
    if not _HAS_TELEGRAM:
        return
    try:
        import httpx
        async with httpx.AsyncClient(timeout=10) as client:
            await client.post(
                f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage",
                json={
                    "chat_id": TELEGRAM_CHAT_ID,
                    "text": text,
                    "parse_mode": parse_mode,
                },
            )
    except Exception as e:
        logger.error("[MonitorBot] Telegram send failed: %s", e)


async def _tg_get_updates() -> list:
    """Poll for new Telegram messages."""
    global _last_update_id
    if not _HAS_TELEGRAM:
        return []
    try:
        import httpx
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(
                f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/getUpdates",
                params={"offset": _last_update_id + 1, "timeout": 5},
            )
            data = resp.json()
            updates = data.get("result", [])
            if updates:
                _last_update_id = updates[-1]["update_id"]
            return updates
    except Exception:
        return []


# ── Command Handlers ───────────────────────────────────────────────

async def _cmd_status() -> str:
    """Server health summary."""
    try:
        from config import _SERVER_START_TIME, _watchdog_stats
        uptime = datetime.now(timezone.utc) - _SERVER_START_TIME
        hours = int(uptime.total_seconds() // 3600)
        mins = int((uptime.total_seconds() % 3600) // 60)

        from services.event_bus import event_bus
        sse = event_bus.get_stats()

        return (
            f"*Server Status*\n\n"
            f"Uptime: {hours}h {mins}m\n"
            f"DB failures: {_watchdog_stats['db_failures']}\n"
            f"DB reconnects: {_watchdog_stats['db_reconnects']}\n"
            f"Firebase failures: {_watchdog_stats['firebase_failures']}\n"
            f"SSE streams: {sse['active_driver_streams']} drivers, "
            f"{sse['active_trip_streams']} trips\n"
            f"Total events pushed: {sse['total_events_pushed']}"
        )
    except Exception as e:
        return f"Error getting status: {e}"


async def _cmd_errors() -> str:
    """Recent error stats from request guardian."""
    try:
        from guardian_agent import guardian_agent
        rg = guardian_agent.request_guardian
        total = rg.successful_requests + rg.failed_requests
        rate = (rg.failed_requests / max(total, 1)) * 100
        return (
            f"*Error Stats*\n\n"
            f"Total requests: {total}\n"
            f"Successful: {rg.successful_requests}\n"
            f"Failed (5xx): {rg.failed_requests}\n"
            f"Timeouts: {rg.timeout_requests}\n"
            f"Slow (>1s): {rg.slow_requests}\n"
            f"Error rate: {rate:.1f}%"
        )
    except Exception as e:
        return f"Error getting stats: {e}"


async def _cmd_payments() -> str:
    """Payment stats."""
    try:
        from models.database import SessionLocal, Trip
        from sqlalchemy import select, func

        async with SessionLocal() as db:
            # Last 24h payment stats
            since = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0)
            result = await db.execute(
                select(
                    Trip.payment_status,
                    func.count(Trip.id),
                ).where(Trip.created_at >= since)
                .group_by(Trip.payment_status)
            )
            rows = result.all()
            lines = [f"*Payments Today*\n"]
            for status, count in rows:
                emoji = "✅" if status == "paid" else "❌" if status == "failed" else "⏳"
                lines.append(f"{emoji} {status or 'pending'}: {count}")
            if not rows:
                lines.append("No trips today")
            return "\n".join(lines)
    except Exception as e:
        return f"Error getting payments: {e}"


async def _cmd_trips() -> str:
    """Active trips."""
    try:
        from models.database import SessionLocal, Trip
        from sqlalchemy import select, func

        async with SessionLocal() as db:
            result = await db.execute(
                select(Trip.status, func.count(Trip.id))
                .where(Trip.status.notin_(["completed", "cancelled"]))
                .group_by(Trip.status)
            )
            rows = result.all()
            lines = [f"*Active Trips*\n"]
            total = 0
            for status, count in rows:
                lines.append(f"• {status}: {count}")
                total += count
            lines.append(f"\nTotal active: {total}")
            if not rows:
                lines.append("No active trips")
            return "\n".join(lines)
    except Exception as e:
        return f"Error: {e}"


async def _cmd_drivers() -> str:
    """Online drivers."""
    try:
        from models.database import SessionLocal, User
        from sqlalchemy import select, func

        async with SessionLocal() as db:
            result = await db.execute(
                select(func.count(User.id)).where(
                    User.role == "driver", User.is_online == True
                )
            )
            count = result.scalar() or 0
            return f"*Online Drivers:* {count}"
    except Exception as e:
        return f"Error: {e}"


async def _cmd_db() -> str:
    """Database health — query latency + pool stats."""
    try:
        from models.database import SessionLocal, engine
        from sqlalchemy import text

        acq_start = time.time()
        async with SessionLocal() as db:
            pool_wait_ms = (time.time() - acq_start) * 1000
            q_start = time.time()
            await db.execute(text("SELECT 1"))
            q_ms = (time.time() - q_start) * 1000

        pool = engine.pool
        pool_line = f"Pool: {pool.checkedout()}/{pool.size()} checked-out"
        status = "✅ Healthy" if q_ms < 100 else "⚠️ Slow" if q_ms < 500 else "❌ Critical"
        return (
            f"*Database*\n\n"
            f"{status}\n"
            f"Query latency: {q_ms:.0f}ms\n"
            f"Pool wait: {pool_wait_ms:.0f}ms\n"
            f"{pool_line}"
        )
    except Exception as e:
        return f"❌ *Database DOWN*\n\nError: {e}"


async def _cmd_ask(question: str) -> str:
    """Ask Claude AI about a problem."""
    try:
        from config import ANTHROPIC_API_KEY, _HAS_CLAUDE
        if not _HAS_CLAUDE:
            return "Claude AI not configured (missing ANTHROPIC_API_KEY)"

        import httpx
        async with httpx.AsyncClient(timeout=30) as client:
            # Get current system context
            status = await _cmd_status()
            errors = await _cmd_errors()

            resp = await client.post(
                "https://api.anthropic.com/v1/messages",
                headers={
                    "x-api-key": ANTHROPIC_API_KEY,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": "claude-haiku-4-5-20251001",
                    "max_tokens": 500,
                    "system": (
                        "You are a server monitoring assistant for a rideshare app called Cruise. "
                        "Answer in Spanish, be concise (max 4 lines). "
                        f"Current server status:\n{status}\n\nError stats:\n{errors}"
                    ),
                    "messages": [{"role": "user", "content": question}],
                },
            )
            data = resp.json()
            answer = data.get("content", [{}])[0].get("text", "No response")
            return f"*AI:* {answer}"
    except Exception as e:
        return f"Error asking AI: {e}"


# ── Command Router ─────────────────────────────────────────────────

_COMMANDS = {
    "/status": ("Server health", _cmd_status),
    "/errors": ("Error stats", _cmd_errors),
    "/payments": ("Payment stats", _cmd_payments),
    "/trips": ("Active trips", _cmd_trips),
    "/drivers": ("Online drivers", _cmd_drivers),
    "/db": ("Database health", _cmd_db),
}


async def _handle_message(text: str):
    """Route a Telegram message to the right command."""
    text = text.strip()

    if text == "/help" or text == "/start":
        lines = ["*Cruise Monitor Bot*\n"]
        for cmd, (desc, _) in _COMMANDS.items():
            lines.append(f"`{cmd}` — {desc}")
        lines.append(f"`/ask <pregunta>` — Pregunta a la IA")
        await _tg_send("\n".join(lines))
        return

    if text.startswith("/ask "):
        question = text[5:].strip()
        if question:
            await _tg_send("Analizando...")
            answer = await _cmd_ask(question)
            await _tg_send(answer)
        return

    for cmd, (_, handler) in _COMMANDS.items():
        if text == cmd:
            result = await handler()
            await _tg_send(result)
            return

    # Unknown command
    if text.startswith("/"):
        await _tg_send("Comando no reconocido. Escribe /help para ver opciones.")


# ── Health Monitor Loop ────────────────────────────────────────────

async def _health_check_loop():
    """Periodic health checks — alerts on critical issues."""
    consecutive_db_fails = 0

    while True:
        try:
            await asyncio.sleep(_CHECK_INTERVAL)

            # 1. Check database
            try:
                from models.database import SessionLocal, engine
                from sqlalchemy import text
                acq_start = time.time()
                async with SessionLocal() as db:
                    pool_wait = (time.time() - acq_start) * 1000
                    q_start = time.time()
                    await db.execute(text("SELECT 1"))
                    latency = (time.time() - q_start) * 1000
                pool = engine.pool
                if latency > 200:
                    from services.admin_alerts import send_alert, HIGH
                    await send_alert("db_slow", "Database Slow",
                                     f"DB latency: {latency:.0f}ms | pool wait: {pool_wait:.0f}ms | pool {pool.checkedout()}/{pool.size()}", HIGH)
                elif pool_wait > 1000:
                    from services.admin_alerts import send_alert, HIGH
                    await send_alert("db_pool_exhausted", "DB Pool Exhausted",
                                     f"Pool wait: {pool_wait:.0f}ms — {pool.checkedout()}/{pool.size()} connections in use", HIGH)
                consecutive_db_fails = 0
            except Exception as e:
                consecutive_db_fails += 1
                if consecutive_db_fails >= 3:
                    from services.admin_alerts import send_alert, CRITICAL
                    await send_alert("db_down", "Database DOWN",
                                     f"DB unreachable for {consecutive_db_fails} checks: {e}",
                                     CRITICAL)

            # 2. Check error rate
            try:
                from guardian_agent import guardian_agent
                rg = guardian_agent.request_guardian
                total = rg.successful_requests + rg.failed_requests
                if total > 100:
                    rate = (rg.failed_requests / total) * 100
                    if rate > 10:
                        from services.admin_alerts import send_alert, HIGH
                        await send_alert("high_error_rate", "High Error Rate",
                                         f"Error rate: {rate:.1f}% ({rg.failed_requests}/{total})",
                                         HIGH)
            except Exception:
                pass

        except asyncio.CancelledError:
            break
        except Exception as e:
            logger.error("[MonitorBot] Health check error: %s", e)


# ── Message Polling Loop ──────────────────────────────────────────

async def _message_poll_loop():
    """Poll Telegram for incoming commands."""
    while True:
        try:
            updates = await _tg_get_updates()
            for update in updates:
                msg = update.get("message", {})
                text = msg.get("text", "")
                chat_id = str(msg.get("chat", {}).get("id", ""))
                # Only respond to the configured admin chat
                if chat_id == TELEGRAM_CHAT_ID and text:
                    await _handle_message(text)
            await asyncio.sleep(2)  # Poll every 2 seconds
        except asyncio.CancelledError:
            break
        except Exception as e:
            logger.error("[MonitorBot] Poll error: %s", e)
            await asyncio.sleep(10)


# ── Public API ─────────────────────────────────────────────────────

async def start_monitor_bot():
    """Start the monitoring bot (call from lifespan)."""
    if not _HAS_TELEGRAM:
        logger.info("[MonitorBot] Telegram not configured, bot disabled")
        return

    logger.info("[MonitorBot] Starting Telegram monitor bot...")
    await _tg_send("🟢 *Cruise Server Online*\n\nMonitor bot active. Send /help for commands.")

    # Run both loops concurrently
    asyncio.create_task(_health_check_loop())
    asyncio.create_task(_message_poll_loop())
    logger.info("[MonitorBot] Bot running — health checks every %ds", _CHECK_INTERVAL)
