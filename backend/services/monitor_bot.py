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
  /revenue   — Today's revenue breakdown
  /today     — Full daily snapshot (trips + revenue + drivers)
  /week      — Weekly summary vs last week
  /approve <driver_id> — Approve a pending driver
  /reject <driver_id>  — Reject a pending driver
  /pending   — List drivers waiting for approval
  /ask <msg> — Ask AI about a problem (uses Claude)
  /help      — List commands
"""

import os
import asyncio
import logging
import time
from datetime import datetime, timezone, timedelta

logger = logging.getLogger(__name__)

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")
_HAS_TELEGRAM = bool(TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID)

# Health check interval: 2 minutes
_CHECK_INTERVAL = 120
# Daily briefing hour (UTC)
_BRIEFING_HOUR = 12  # 8 AM EST = 12 UTC
# Track last update_id to avoid processing old messages
_last_update_id = 0
# Track if today's briefing was sent
_last_briefing_date = None


async def _tg_send(text: str, parse_mode: str = "Markdown"):
    """Send a Telegram message."""
    if not _HAS_TELEGRAM:
        return
    try:
        import httpx
        # Telegram has a 4096 char limit; split if needed
        chunks = [text[i:i+4000] for i in range(0, len(text), 4000)]
        async with httpx.AsyncClient(timeout=10) as client:
            for chunk in chunks:
                await client.post(
                    f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage",
                    json={
                        "chat_id": TELEGRAM_CHAT_ID,
                        "text": chunk,
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
        days = uptime.days
        hours = int((uptime.total_seconds() % 86400) // 3600)
        mins = int((uptime.total_seconds() % 3600) // 60)
        uptime_str = f"{days}d {hours}h {mins}m" if days > 0 else f"{hours}h {mins}m"

        from services.event_bus import event_bus
        sse = event_bus.get_stats()

        return (
            f"🖥 *Server Status*\n\n"
            f"⏱ Uptime: `{uptime_str}`\n"
            f"💾 DB fails: {_watchdog_stats['db_failures']} | reconnects: {_watchdog_stats['db_reconnects']}\n"
            f"🔥 Firebase fails: {_watchdog_stats['firebase_failures']}\n"
            f"📡 SSE: {sse['active_driver_streams']} drivers, {sse['active_trip_streams']} trips\n"
            f"📨 Events pushed: {sse['total_events_pushed']}"
        )
    except Exception as e:
        return f"❌ Error getting status: {e}"


async def _cmd_errors() -> str:
    """Recent error stats from request guardian."""
    try:
        from guardian_agent import guardian_agent
        rg = guardian_agent.request_guardian
        total = rg.successful_requests + rg.failed_requests
        rate = (rg.failed_requests / max(total, 1)) * 100

        # Status indicator
        if rate < 1:
            indicator = "🟢"
        elif rate < 5:
            indicator = "🟡"
        else:
            indicator = "🔴"

        return (
            f"📊 *Error Stats* {indicator}\n\n"
            f"Total: `{total}` requests\n"
            f"✅ Success: {rg.successful_requests}\n"
            f"❌ Failed (5xx): {rg.failed_requests}\n"
            f"⏱ Timeouts: {rg.timeout_requests}\n"
            f"🐌 Slow (>1s): {rg.slow_requests}\n"
            f"📈 Error rate: `{rate:.1f}%`"
        )
    except Exception as e:
        return f"❌ Error getting stats: {e}"


async def _cmd_payments() -> str:
    """Payment stats."""
    try:
        from models.database import SessionLocal, Trip
        from sqlalchemy import select, func

        async with SessionLocal() as db:
            since = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0)
            result = await db.execute(
                select(
                    Trip.payment_status,
                    func.count(Trip.id),
                ).where(Trip.created_at >= since)
                .group_by(Trip.payment_status)
            )
            rows = result.all()
            lines = [f"💳 *Payments Today*\n"]
            total_count = 0
            for status, count in rows:
                emoji = "✅" if status == "paid" else "❌" if status == "failed" else "⏳"
                lines.append(f"{emoji} {status or 'pending'}: {count}")
                total_count += count
            if not rows:
                lines.append("No transactions today")
            else:
                lines.append(f"\nTotal: {total_count}")
            return "\n".join(lines)
    except Exception as e:
        return f"❌ Error getting payments: {e}"


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
            lines = [f"🚗 *Active Trips*\n"]
            total = 0
            status_emoji = {
                "requested": "🔵", "accepted": "🟢", "en_route_to_pickup": "🟡",
                "arrived_at_pickup": "🟠", "in_progress": "🔴",
            }
            for status, count in rows:
                emoji = status_emoji.get(status, "⚪")
                lines.append(f"{emoji} {status}: {count}")
                total += count
            lines.append(f"\n*Total active: {total}*")
            if not rows:
                lines = [f"🚗 *Active Trips*\n\nNo active trips right now"]
            return "\n".join(lines)
    except Exception as e:
        return f"❌ Error: {e}"


async def _cmd_drivers() -> str:
    """Online drivers."""
    try:
        from models.database import SessionLocal, User
        from sqlalchemy import select, func

        async with SessionLocal() as db:
            # Online count
            result = await db.execute(
                select(func.count(User.id)).where(
                    User.role == "driver", User.is_online == True
                )
            )
            online = result.scalar() or 0

            # Total approved drivers
            result2 = await db.execute(
                select(func.count(User.id)).where(
                    User.role == "driver", User.driver_status == "approved"
                )
            )
            total = result2.scalar() or 0

            return (
                f"🚘 *Drivers*\n\n"
                f"🟢 Online: *{online}*\n"
                f"👥 Total approved: {total}\n"
                f"📊 Online rate: {(online/max(total,1)*100):.0f}%"
            )
    except Exception as e:
        return f"❌ Error: {e}"


async def _cmd_db() -> str:
    """Database health — query latency + pool stats + host."""
    try:
        from models.database import SessionLocal, engine, DATABASE_URL
        from sqlalchemy import text
        import re

        host_match = re.search(r"@([^/]+)/", DATABASE_URL)
        host_display = host_match.group(1) if host_match else "unknown"
        is_supabase = "supabase" in host_display
        net_label = "🔒 Supabase SSL" if is_supabase else "🔒 External"

        acq_start = time.time()
        async with SessionLocal() as db:
            await db.connection()
            pool_wait_ms = (time.time() - acq_start) * 1000
            q_start = time.time()
            await db.execute(text("SELECT 1"))
            q_ms = (time.time() - q_start) * 1000

        pool = engine.pool
        pool_line = f"Pool: {pool.checkedout()}/{pool.size()} in use"

        if q_ms < 100:
            status = "🟢 Excellent"
        elif q_ms < 500:
            status = "✅ Healthy"
        elif q_ms < 1500:
            status = "⚠️ Slow"
        else:
            status = "❌ Critical"

        return (
            f"💾 *Database*\n\n"
            f"{status} — `{q_ms:.0f}ms`\n"
            f"Host: `{host_display}`\n"
            f"Network: {net_label}\n"
            f"Pool wait: {pool_wait_ms:.0f}ms\n"
            f"{pool_line}"
        )
    except Exception as e:
        return f"❌ *Database DOWN*\n\nError: {e}"


async def _cmd_revenue() -> str:
    """Today's revenue breakdown."""
    try:
        from models.database import SessionLocal, Trip
        from sqlalchemy import select, func

        async with SessionLocal() as db:
            since = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0)
            result = await db.execute(
                select(
                    func.count(Trip.id),
                    func.coalesce(func.sum(Trip.fare_amount), 0),
                    func.coalesce(func.sum(Trip.tip_amount), 0),
                    func.coalesce(func.sum(Trip.platform_fee), 0),
                    func.coalesce(func.sum(Trip.driver_earnings), 0),
                ).where(Trip.created_at >= since, Trip.status == "completed")
            )
            row = result.one()
            trips, gross, tips, platform, driver_earn = row

            return (
                f"💰 *Revenue Today*\n\n"
                f"🚗 Completed trips: `{trips}`\n"
                f"💵 Gross fares: `${gross:.2f}`\n"
                f"💝 Tips: `${tips:.2f}`\n"
                f"🏢 Platform fee: `${platform:.2f}`\n"
                f"👨‍✈️ Driver earnings: `${driver_earn:.2f}`\n"
                f"━━━━━━━━━━━━━━\n"
                f"📊 *Total collected: `${(gross + tips):.2f}`*"
            )
    except Exception as e:
        return f"❌ Error: {e}"


async def _cmd_today() -> str:
    """Full daily snapshot."""
    try:
        parts = []
        parts.append(await _cmd_revenue())
        parts.append("")
        parts.append(await _cmd_trips())
        parts.append("")
        parts.append(await _cmd_drivers())
        parts.append("")
        parts.append(await _cmd_payments())
        return "\n".join(parts)
    except Exception as e:
        return f"❌ Error: {e}"


async def _cmd_week() -> str:
    """Weekly summary with comparison to last week."""
    try:
        from models.database import SessionLocal, Trip, User
        from sqlalchemy import select, func

        now = datetime.now(timezone.utc)
        week_start = (now - timedelta(days=now.weekday())).replace(hour=0, minute=0, second=0)
        prev_week_start = week_start - timedelta(days=7)

        async with SessionLocal() as db:
            # This week
            r1 = await db.execute(
                select(
                    func.count(Trip.id),
                    func.coalesce(func.sum(Trip.fare_amount), 0),
                    func.coalesce(func.sum(Trip.tip_amount), 0),
                ).where(Trip.created_at >= week_start, Trip.status == "completed")
            )
            this_trips, this_fares, this_tips = r1.one()

            # Last week
            r2 = await db.execute(
                select(
                    func.count(Trip.id),
                    func.coalesce(func.sum(Trip.fare_amount), 0),
                    func.coalesce(func.sum(Trip.tip_amount), 0),
                ).where(
                    Trip.created_at >= prev_week_start,
                    Trip.created_at < week_start,
                    Trip.status == "completed",
                )
            )
            prev_trips, prev_fares, prev_tips = r2.one()

            # New users this week
            r3 = await db.execute(
                select(func.count(User.id)).where(User.created_at >= week_start)
            )
            new_users = r3.scalar() or 0

            # Comparisons
            def delta(current, previous):
                if previous == 0:
                    return "🆕" if current > 0 else "—"
                pct = ((current - previous) / previous) * 100
                arrow = "📈" if pct > 0 else "📉" if pct < 0 else "➡️"
                return f"{arrow} {pct:+.0f}%"

            return (
                f"📅 *This Week* (since {week_start.strftime('%b %d')})\n\n"
                f"🚗 Trips: `{this_trips}` {delta(this_trips, prev_trips)}\n"
                f"💵 Fares: `${this_fares:.2f}` {delta(this_fares, prev_fares)}\n"
                f"💝 Tips: `${this_tips:.2f}` {delta(this_tips, prev_tips)}\n"
                f"👤 New users: `{new_users}`\n"
                f"\n*Last week:* {prev_trips} trips, ${prev_fares:.2f} fares"
            )
    except Exception as e:
        return f"❌ Error: {e}"


async def _cmd_pending() -> str:
    """List pending driver approvals."""
    try:
        from models.database import SessionLocal, User
        from sqlalchemy import select

        async with SessionLocal() as db:
            result = await db.execute(
                select(User.id, User.first_name, User.last_name, User.email, User.created_at)
                .where(User.role == "driver", User.driver_status == "pending_review")
                .order_by(User.created_at.desc())
                .limit(10)
            )
            rows = result.all()
            if not rows:
                return "✅ *No pending drivers* — all caught up!"

            lines = [f"⏳ *Pending Drivers* ({len(rows)})\n"]
            for uid, fname, lname, email, created in rows:
                name = f"{fname or ''} {lname or ''}".strip() or "No name"
                ago = datetime.now(timezone.utc) - created if created else timedelta(0)
                days = ago.days
                time_str = f"{days}d ago" if days > 0 else "today"
                lines.append(f"• `{uid}` — {name} ({time_str})")

            lines.append(f"\nUse `/approve <id>` or `/reject <id>`")
            return "\n".join(lines)
    except Exception as e:
        return f"❌ Error: {e}"


async def _cmd_approve(driver_id_str: str) -> str:
    """Approve a pending driver."""
    try:
        driver_id = int(driver_id_str)
        from models.database import SessionLocal, User
        from sqlalchemy import select

        async with SessionLocal() as db:
            result = await db.execute(
                select(User).where(User.id == driver_id, User.role == "driver")
            )
            driver = result.scalar_one_or_none()
            if not driver:
                return f"❌ Driver ID `{driver_id}` not found"
            if driver.driver_status == "approved":
                return f"ℹ️ Driver `{driver_id}` already approved"

            driver.driver_status = "approved"
            await db.commit()

            name = f"{driver.first_name or ''} {driver.last_name or ''}".strip()
            return f"✅ *Driver approved!*\n\n👤 {name} (ID: `{driver_id}`)\n\nThey can now go online and accept rides."
    except ValueError:
        return "❌ Invalid ID. Use: `/approve 123`"
    except Exception as e:
        return f"❌ Error: {e}"


async def _cmd_reject(driver_id_str: str) -> str:
    """Reject a pending driver."""
    try:
        driver_id = int(driver_id_str)
        from models.database import SessionLocal, User
        from sqlalchemy import select

        async with SessionLocal() as db:
            result = await db.execute(
                select(User).where(User.id == driver_id, User.role == "driver")
            )
            driver = result.scalar_one_or_none()
            if not driver:
                return f"❌ Driver ID `{driver_id}` not found"

            driver.driver_status = "rejected"
            await db.commit()

            name = f"{driver.first_name or ''} {driver.last_name or ''}".strip()
            return f"🚫 *Driver rejected*\n\n👤 {name} (ID: `{driver_id}`)"
    except ValueError:
        return "❌ Invalid ID. Use: `/reject 123`"
    except Exception as e:
        return f"❌ Error: {e}"


async def _cmd_ask(question: str) -> str:
    """Ask Claude AI about a problem."""
    try:
        from config import ANTHROPIC_API_KEY, _HAS_CLAUDE
        if not _HAS_CLAUDE:
            return "❌ Claude AI not configured (missing ANTHROPIC\\_API\\_KEY)"

        import httpx
        async with httpx.AsyncClient(timeout=30) as client:
            status = await _cmd_status()
            errors = await _cmd_errors()
            db_info = await _cmd_db()

            resp = await client.post(
                "https://api.anthropic.com/v1/messages",
                headers={
                    "x-api-key": ANTHROPIC_API_KEY,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": "claude-haiku-4-5-20251001",
                    "max_tokens": 800,
                    "system": (
                        "You are a server monitoring assistant for CruiseApp, a ride-sharing platform. "
                        "Backend: Python/FastAPI + Supabase (PostgreSQL) + Firebase. "
                        "Answer in Spanish, be concise but thorough. Use emojis. "
                        f"Current status:\n{status}\n\nErrors:\n{errors}\n\nDB:\n{db_info}"
                    ),
                    "messages": [{"role": "user", "content": question}],
                },
            )
            data = resp.json()
            answer = data.get("content", [{}])[0].get("text", "No response")
            return f"🤖 *AI:*\n\n{answer}"
    except Exception as e:
        return f"❌ Error asking AI: {e}"


# ── Command Router ─────────────────────────────────────────────────

_COMMANDS = {
    "/status": ("🖥 Server health", _cmd_status),
    "/errors": ("📊 Error stats", _cmd_errors),
    "/payments": ("💳 Payment stats", _cmd_payments),
    "/trips": ("🚗 Active trips", _cmd_trips),
    "/drivers": ("🚘 Online drivers", _cmd_drivers),
    "/db": ("💾 Database health", _cmd_db),
    "/revenue": ("💰 Today's revenue", _cmd_revenue),
    "/today": ("📋 Full daily snapshot", _cmd_today),
    "/week": ("📅 Weekly summary", _cmd_week),
    "/pending": ("⏳ Pending drivers", _cmd_pending),
}


async def _handle_message(text: str):
    """Route a Telegram message to the right command."""
    text = text.strip()

    if text in ("/help", "/start"):
        lines = [
            "🚀 *Cruise Monitor Bot*\n",
            "*Monitoring:*",
        ]
        for cmd, (desc, _) in _COMMANDS.items():
            lines.append(f"  `{cmd}` — {desc}")
        lines.append("\n*Actions:*")
        lines.append(f"  `/approve <id>` — ✅ Approve driver")
        lines.append(f"  `/reject <id>` — 🚫 Reject driver")
        lines.append(f"  `/ask <question>` — 🤖 Ask AI")
        await _tg_send("\n".join(lines))
        return

    if text.startswith("/ask "):
        question = text[5:].strip()
        if question:
            await _tg_send("🔍 Analizando...")
            answer = await _cmd_ask(question)
            await _tg_send(answer)
        return

    if text.startswith("/approve "):
        driver_id = text[9:].strip()
        if driver_id:
            result = await _cmd_approve(driver_id)
            await _tg_send(result)
        return

    if text.startswith("/reject "):
        driver_id = text[8:].strip()
        if driver_id:
            result = await _cmd_reject(driver_id)
            await _tg_send(result)
        return

    for cmd, (_, handler) in _COMMANDS.items():
        if text == cmd:
            result = await handler()
            await _tg_send(result)
            return

    if text.startswith("/"):
        await _tg_send("❓ Comando no reconocido. Escribe /help para ver opciones.")


# ── Daily Briefing ────────────────────────────────────────────────

async def _send_daily_briefing():
    """Send morning briefing with yesterday's summary + today's outlook."""
    try:
        from models.database import SessionLocal, Trip, User
        from sqlalchemy import select, func

        yesterday_start = (datetime.now(timezone.utc) - timedelta(days=1)).replace(hour=0, minute=0, second=0)
        yesterday_end = yesterday_start + timedelta(days=1)

        async with SessionLocal() as db:
            # Yesterday's stats
            r1 = await db.execute(
                select(
                    func.count(Trip.id),
                    func.coalesce(func.sum(Trip.fare_amount), 0),
                    func.coalesce(func.sum(Trip.tip_amount), 0),
                ).where(
                    Trip.created_at >= yesterday_start,
                    Trip.created_at < yesterday_end,
                    Trip.status == "completed",
                )
            )
            trips, fares, tips = r1.one()

            # Cancelled yesterday
            r2 = await db.execute(
                select(func.count(Trip.id)).where(
                    Trip.created_at >= yesterday_start,
                    Trip.created_at < yesterday_end,
                    Trip.status == "cancelled",
                )
            )
            cancelled = r2.scalar() or 0

            # New users yesterday
            r3 = await db.execute(
                select(func.count(User.id)).where(
                    User.created_at >= yesterday_start,
                    User.created_at < yesterday_end,
                )
            )
            new_users = r3.scalar() or 0

            # Pending drivers
            r4 = await db.execute(
                select(func.count(User.id)).where(
                    User.role == "driver", User.driver_status == "pending_review"
                )
            )
            pending = r4.scalar() or 0

            # Online drivers now
            r5 = await db.execute(
                select(func.count(User.id)).where(
                    User.role == "driver", User.is_online == True
                )
            )
            online_now = r5.scalar() or 0

        date_str = yesterday_start.strftime("%b %d")
        pending_line = f"\n⚠️ *{pending} drivers pending approval!* Use /pending" if pending > 0 else ""

        briefing = (
            f"☀️ *Good Morning — Daily Briefing*\n"
            f"━━━━━━━━━━━━━━━━━━━━\n\n"
            f"📊 *Yesterday ({date_str}):*\n"
            f"  🚗 Trips: {trips} completed, {cancelled} cancelled\n"
            f"  💵 Revenue: ${fares:.2f} fares + ${tips:.2f} tips\n"
            f"  👤 New users: {new_users}\n\n"
            f"📡 *Right Now:*\n"
            f"  🟢 Drivers online: {online_now}"
            f"{pending_line}\n\n"
            f"_Have a great day! Send /help for commands._"
        )
        await _tg_send(briefing)
        logger.info("[MonitorBot] Daily briefing sent")
    except Exception as e:
        logger.error("[MonitorBot] Briefing failed: %s", e)


# ── Proactive Business Alerts ────────────────────────────────────

async def _check_business_events():
    """Check for notable business events and alert."""
    try:
        from models.database import SessionLocal, User, Trip
        from sqlalchemy import select, func

        async with SessionLocal() as db:
            # New driver signups in last 2 minutes
            since = datetime.now(timezone.utc) - timedelta(seconds=_CHECK_INTERVAL)
            r1 = await db.execute(
                select(User.id, User.first_name, User.last_name, User.email)
                .where(User.role == "driver", User.created_at >= since)
            )
            new_drivers = r1.all()
            for uid, fname, lname, email in new_drivers:
                name = f"{fname or ''} {lname or ''}".strip() or email
                await _tg_send(
                    f"🆕 *New Driver Signup!*\n\n"
                    f"👤 {name}\n"
                    f"📧 {email}\n"
                    f"ID: `{uid}`\n\n"
                    f"Use `/approve {uid}` when ready"
                )

            # New rider signups in last 2 minutes
            r2 = await db.execute(
                select(func.count(User.id))
                .where(User.role == "rider", User.created_at >= since)
            )
            new_riders = r2.scalar() or 0
            if new_riders > 0:
                await _tg_send(f"👤 *{new_riders} new rider(s)* just signed up!")

    except Exception:
        pass  # Don't let business checks break the health loop


# ── Health Monitor Loop ────────────────────────────────────────────

async def _health_check_loop():
    """Periodic health checks — alerts on critical issues."""
    global _last_briefing_date
    consecutive_db_fails = 0

    # Wait for server initialization
    await asyncio.sleep(30)
    try:
        from models.database import SessionLocal
        from sqlalchemy import text as _text
        async with SessionLocal() as _db:
            await _db.execute(_text("SELECT 1"))
        logger.info("[MonitorBot] Pool warm-up done")
    except Exception as e:
        logger.warning("[MonitorBot] Pool warm-up failed: %s", e)
    await asyncio.sleep(30)

    while True:
        try:
            await asyncio.sleep(_CHECK_INTERVAL)
            now = datetime.now(timezone.utc)

            # Daily briefing check
            today = now.date()
            if now.hour == _BRIEFING_HOUR and _last_briefing_date != today:
                _last_briefing_date = today
                await _send_daily_briefing()

            # Business events check
            await _check_business_events()

            # 1. Check database
            try:
                from models.database import SessionLocal, engine
                from sqlalchemy import text
                acq_start = time.time()
                async with SessionLocal() as db:
                    await db.connection()
                    pool_wait = (time.time() - acq_start) * 1000
                    q_start = time.time()
                    await db.execute(text("SELECT 1"))
                    latency = (time.time() - q_start) * 1000
                pool = engine.pool
                if latency > 500:
                    from services.admin_alerts import send_alert, HIGH
                    await send_alert("db_slow", "Database Slow",
                                     f"DB latency: {latency:.0f}ms | pool wait: {pool_wait:.0f}ms | pool {pool.checkedout()}/{pool.size()}", HIGH)
                elif pool_wait > 500:
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
                if chat_id == TELEGRAM_CHAT_ID and text:
                    await _handle_message(text)
            await asyncio.sleep(2)
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

    try:
        from models.database import DATABASE_URL
        import re
        host_match = re.search(r"@([^/]+)/", DATABASE_URL)
        db_host = host_match.group(1) if host_match else "unknown"
        is_supabase = "supabase" in db_host
        label = "SUPABASE SSL" if is_supabase else "EXTERNAL"
        logger.info("[MonitorBot] DB host: %s (%s)", db_host, label)
    except Exception:
        pass

    logger.info("[MonitorBot] Starting Telegram monitor bot...")
    await _tg_send(
        "🟢 *Cruise Server Online*\n\n"
        "Monitor bot active.\n"
        f"⏱ Health checks: every {_CHECK_INTERVAL}s\n"
        f"☀️ Daily briefing: {_BRIEFING_HOUR}:00 UTC\n\n"
        "Send /help for commands."
    )

    asyncio.create_task(_health_check_loop())
    asyncio.create_task(_message_poll_loop())
    logger.info("[MonitorBot] Bot running — health checks every %ds", _CHECK_INTERVAL)
