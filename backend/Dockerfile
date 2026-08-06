# ═══════════════════════════════════════════════════════════════
#  Cruise Backend — Production Dockerfile (Optimized)
#  Multi-stage build for smaller image + faster deploys
# ═══════════════════════════════════════════════════════════════

# ── Stage 1: Builder ───────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /app

# Install build dependencies (only needed for compiling packages)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies into a virtual environment
# This keeps the final image clean
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY backend/requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# ── Stage 2: Runtime ───────────────────────────────────────────
FROM python:3.12-slim

WORKDIR /app

# Install only runtime dependencies (postgresql-client for backups)
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Copy virtual environment from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Set Python environment
ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Uvicorn tuning.
#
# ONE WORKER, and it is not about CPU or about the database.
#
# The realtime layer is process-local. services/event_bus.py keeps its
# subscribers in a plain dict of asyncio.Queues, and socketio_service.py has
# its Redis client_manager commented out — so an SSE stream and a Socket.io
# room only exist inside the single process that accepted them. The driver's
# PATCH /trips/{id}/status lands on whichever worker the proxy picks, and
# push_trip_update() drops the event into that worker's queues. At four
# workers the rider was on a different process three times out of four, and
# both of their "instant" channels stayed silent while looking perfectly
# connected: the passenger's screen only caught up when the HTTP poll or the
# Firestore mirror got there, seconds after the driver swiped.
#
# So: DO NOT raise this until the event bus is bridged across processes
# (Redis pub/sub) AND the Socket.io Redis manager is re-enabled. REDIS_URL is
# already provisioned for exactly that. Until then every extra worker is a
# 1-in-N chance of silently losing every trip status event.
#
# The database ceiling, for whenever that day comes: Postgres
# max_connections=100, each worker builds its own pool of
# DB_POOL_SIZE + DB_MAX_OVERFLOW = 18, so four workers reserve at most 72 and
# leave room for the scheduler leader's lock plus admin sessions.
ENV UVICORN_WORKERS=1
ENV UVICORN_TIMEOUT_KEEP_ALIVE=75
ENV UVICORN_LIMIT_CONCURRENCY=2000

# Proxy trust boundary. See the --forwarded-allow-ips note on the CMD below
# before changing this value.
#
# Railway terminates TLS at its own edge proxy and forwards over the private
# network, so the peer address uvicorn sees is the proxy, not the user: in
# production every client_ip logged was 100.64.0.4 ... 100.64.0.23. That is
# Railway's carrier-grade NAT range (100.64.0.0/10, RFC 6598). Uvicorn
# defaults to trusting only 127.0.0.1, so it refused to honour the real
# client address in X-Forwarded-For and EVERY user collapsed onto ~20 IPs -
# sharing one 100 req/min bucket, and making IP bans and the login lockout
# hit random innocent slices of the user base.
#
# 127.0.0.1 is kept so the container's own loopback probe keeps uvicorn's
# default behaviour. Override in Railway if the internal range ever changes.
ENV FORWARDED_ALLOW_IPS=100.64.0.0/10,127.0.0.1

# Copy application code
COPY backend/ .

# Verify files are in place during build
RUN echo "=== Files in /app ===" && ls -la /app && \
    echo "=== Checking models directory ===" && ls -la /app/models && \
    echo "=== Python version ===" && python --version

EXPOSE 8000

# Health check for Docker (Railway runs its own probe against railway.toml's
# healthcheckPath=/ping, so this is belt-and-braces).
# Shell form on purpose: ${PORT} must expand at RUNTIME. This used to hardcode
# 8000 while CMD binds ${PORT:-8000}, so the probe checked the wrong port on
# any platform that assigns one.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:${PORT:-8000}/ping', timeout=5)" || exit 1

# Start with optimized uvicorn settings
# --workers: see the UVICORN_WORKERS block above — it is 1 on purpose. The
#   fallback is :-1, NOT :-2. An unset or EMPTY UVICORN_WORKERS (an empty
#   value in the Railway dashboard makes ${VAR:-N} fall through) must not be
#   able to silently start a second worker: the event bus and Socket.io rooms
#   are process-local, so that breaks realtime in a way that looks like a
#   Firebase bug rather than a config bug.
# --timeout-keep-alive 75: Keep connections alive for SSE/WebSocket
# --limit-concurrency 2000: Handle many concurrent riders/drivers
# --proxy-headers + --forwarded-allow-ips: honour X-Forwarded-For from
#   Railway's proxy so per-IP rate limits, IP bans and the login brute-force
#   lockout apply to the real client instead of to ~20 shared proxy IPs.
#
#   SECURITY - trust boundary. Trusting X-Forwarded-For means trusting
#   whoever can set it. The trust boundary here is the network peer: uvicorn
#   only reads the header when the TCP peer is inside FORWARDED_ALLOW_IPS.
#   Railway's proxy is the only thing that can reach this container's port,
#   and it appends the real client address to the chain, so trusting that
#   range is correct. A direct attacker cannot forge a peer address.
#
#   We deliberately do NOT use the "*" wildcard. In uvicorn 0.31.0
#   (see requirements.txt) the two settings behave very differently:
#     - "*"  -> always_trust, and get_trusted_client_host() returns
#              x_forwarded_for[0], the LEFTMOST entry. That value is fully
#              client-controlled, so any user could send
#              "X-Forwarded-For: 1.2.3.4" and pick their own identity -
#              trivially evading rate limits and IP bans.
#     - CIDR -> walks the chain in REVERSE and returns the first host NOT in
#              the trusted set, i.e. the address Railway itself appended.
#              A spoofed prefix is ignored.
#   So the narrow range is not merely tighter, it is the setting that
#   actually defeats spoofing. Its failure mode is also safe: if Railway ever
#   moves off 100.64.0.0/10 the header is simply not trusted and we are back
#   to today's behaviour (proxy IP as client) - degraded, never broken.
CMD ["sh", "-c", "exec uvicorn main:socket_app --host 0.0.0.0 --port ${PORT:-8000} --workers ${UVICORN_WORKERS:-1} --timeout-keep-alive ${UVICORN_TIMEOUT_KEEP_ALIVE:-75} --limit-concurrency ${UVICORN_LIMIT_CONCURRENCY:-2000} --proxy-headers --forwarded-allow-ips \"${FORWARDED_ALLOW_IPS:-100.64.0.0/10,127.0.0.1}\""]
