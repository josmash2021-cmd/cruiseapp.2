# CruiseApp Backend Architecture

## Overview

FastAPI-based ride-sharing backend with autonomous agent swarm, real-time event bus,
and multi-layered security. Designed for horizontal scaling on Railway + Supabase.

## Core Components

```
┌─────────────────────────────────────────────────────────────┐
│                        FastAPI App                           │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────────────┐  │
│  │  Auth   │ │  Trips  │ │ Drivers │ │    Payments     │  │
│  │ Router  │ │ Router  │ │ Router  │ │    (Stripe)     │  │
│  └─────────┘ └─────────┘ └─────────┘ └─────────────────┘  │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────────────┐  │
│  │ Dispatch│ │ Support │ │  Admin  │ │   Scheduled     │  │
│  │ Router  │ │ Router  │ │ Router  │ │    Rides        │  │
│  └─────────┘ └─────────┘ └─────────┘ └─────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                    Agent Swarm Layer                         │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐  │
│  │ Guardian │ │  Ghost   │ │  Safety  │ │    Wait      │  │
│  │  Agent   │ │  Driver  │ │ Monitor  │ │   Timeout    │  │
│  └──────────┘ └──────────┘ └──────────┘ └──────────────┘  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐  │
│  │ Document │ │ Document │ │  Rating  │ │   Cruise     │  │
│  │  Expiry  │ │ Approval │ │ Moderator│ │    Level     │  │
│  └──────────┘ └──────────┘ └──────────┘ └──────────────┘  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐  │
│  │ Proactive│ │  Backup  │ │  Nightly │ │   Driver     │  │
│  │ Support  │ │ Scheduler│ │Reconcile │ │  Referral    │  │
│  └──────────┘ └──────────┘ └──────────┘ └──────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                   Infrastructure Layer                       │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐  │
│  │  Redis   │ │  Query   │ │ Circuit  │ │    Rate      │  │
│  │  Cache   │ │  Cache   │ │ Breaker  │ │   Limiter    │  │
│  └──────────┘ └──────────┘ └──────────┘ └──────────────┘  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐  │
│  │  Event   │ │ Socket.io│ │  Audit   │ │   Security   │  │
│  │   Bus    │ │  (SSE)   │ │   Log    │ │   Guardian   │  │
│  └──────────┘ └──────────┘ └──────────┘ └──────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    │   PostgreSQL      │
                    │   (Supabase)      │
                    │   + PgBouncer     │
                    └───────────────────┘
```

## Agent Swarm

### Active Agents

| Agent | Purpose | Interval | Priority |
|-------|---------|----------|----------|
| **Guardian Agent** | Trip integrity, driver state, payment monitoring | 30s | Critical |
| **Security Guardian** | JWT token validation, heartbeat | 60s | Critical |
| **Wait Timeout Agent** | Auto-cancel trips after driver wait | 60s | Critical |
| **Ghost Driver Agent** | Detect fake GPS / inactive drivers | 5 min | High |
| **Safety Monitor** | Incident detection, SOS response | 2 min | High |
| **Document Expiry** | Alert on expiring driver docs | 6h | Medium |
| **Document Approval** | Auto-approve/reject uploaded docs | 5 min | Medium |
| **Rating Moderator** | Review flagged ratings | 60 min | Medium |
| **Cruise Level Agent** | Re-evaluate driver tiers | 30 min | Medium |
| **Proactive Support** | Predict and prevent issues | 15 min | Medium |
| **Backup Scheduler** | DB backups to cloud storage | 12h | Low |
| **Nightly Reconcile** | Financial reconciliation | 24h | Low |
| **Driver Referral Expiry** | Clean up expired referrals | 12h | Low |

### Agent Design Pattern

All agents follow the same pattern:

```python
class BaseAgent:
    def set_db_session_maker(self, session_maker):
        self._session_maker = session_maker
    
    async def start(self):
        self._task = asyncio.create_task(self._loop())
    
    async def stop(self):
        if self._task:
            self._task.cancel()
    
    async def _loop(self):
        while True:
            try:
                await self._run_cycle()
            except Exception as e:
                logger.error("%s error: %s", self.name, e)
            await asyncio.sleep(self.interval)
```

## Database

### Connection Strategy

- **Driver**: psycopg3 (async) — no server-side prepared statements
- **Pool**: NullPool — fresh connection per request (required for PgBouncer)
- **PgBouncer**: Port 6543, transaction mode
- **SSL**: Required with verify_mode=CERT_NONE (Railway → Supabase)

### Key Models

```
users              — Riders, drivers, admins
trips              — Ride requests, active trips, history
dispatch_offers    — Driver trip offers
ratings            — Trip ratings & tips
wallets            — Cruise Cash balances
support_chats      — AI + human support conversations
audit_logs         — Tamper-evident security log
driver_location_history — GPS trace (new)
```

## Caching Strategy

### Two-Tier Cache

1. **In-Memory** (per-process): Ultra-hot data (driver online status, 3s TTL)
2. **Redis** (shared): Hot data across workers (fare config, 5min TTL)

### Cache Keys

| Data | TTL | Backend |
|------|-----|---------|
| Driver online status | 5s | Memory |
| Nearby drivers | 3s | Memory |
| Trip status | 5s | Memory |
| User profile | 60s | Redis |
| Fare config | 300s | Redis |
| Service areas | 300s | Redis |
| Surge zones | 10s | Redis |

## Security Layers

1. **API Key** — All requests require `X-API-Key` header
2. **JWT Authentication** — Bearer tokens for user sessions
3. **Rate Limiting** — Redis-backed sliding window per IP/key
4. **Input Sanitization** — Path traversal & SQL injection patterns
5. **IP Blacklist** — Auto-ban after credential stuffing attempts
6. **Audit Logging** — Chain-hashed tamper-evident log
7. **Circuit Breaker** — Fail-fast for external service outages
8. **CORS Restriction** — Socket.io limited to app origins

## Event System

### SSE Event Bus
- Server-Sent Events for real-time updates
- Channels: `trip:{id}`, `driver:{id}`, `rider:{id}`
- Fallback: Polling via `/trips/{id}/poll`

### Socket.io
- Real-time driver location updates
- Trip offer notifications
- Chat messages

## External Integrations

| Service | Use | Circuit Breaker |
|---------|-----|-----------------|
| Stripe | Payments, payouts | ✅ |
| Twilio | SMS notifications | ✅ |
| FCM (Firebase) | Push notifications | ✅ |
| Google Maps | Routing, distance | ✅ |
| Checkr | Background checks | ✅ |
| OpenAI | Support chat AI | ✅ |
| Plaid | Bank account linking | Stub |

## Health Checks

Endpoint: `GET /health`

Checks:
- Database connectivity
- Redis connectivity
- Stripe API
- Twilio API
- FCM initialization
- Cache stats
- Rate limiter stats

## Deployment

### Railway Configuration

```env
DATABASE_URL=postgresql://postgres.REF:PASSWORD@aws-1-us-east-2.pooler.supabase.com:6543/postgres
REDIS_URL=redis://... (optional)
STRIPE_SECRET_KEY=sk_live_...
FCM_SERVICE_ACCOUNT={...}
```

### Scaling

- Horizontal: Railway auto-scales based on CPU/memory
- Database: Supabase PgBouncer handles connection pooling
- Cache: Redis (optional) or in-memory per worker
- Events: Socket.io with Redis adapter for multi-node

## Monitoring

- **Logs**: Railway native logging
- **Metrics**: `/admin/metrics` (admin only)
- **Alerts**: Telegram bot for critical errors
- **Audit**: Immutable audit log in PostgreSQL
