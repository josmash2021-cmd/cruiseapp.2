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

# Copy application code
COPY backend/ .

# Verify files are in place during build
RUN echo "=== Files in /app ===" && ls -la /app && \
    echo "=== Checking models directory ===" && ls -la /app/models && \
    echo "=== Python version ===" && python --version

EXPOSE 8000

# Health check for Railway
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/ping', timeout=5)" || exit 1

# Start with optimized uvicorn settings
# --workers: see the UVICORN_WORKERS block above — it is 1 on purpose
# --timeout-keep-alive 75: Keep connections alive for SSE/WebSocket
# --limit-concurrency 2000: Handle many concurrent riders/drivers
# --loop uvloop: Faster event loop (if available)
CMD ["sh", "-c", "exec uvicorn main:socket_app --host 0.0.0.0 --port ${PORT:-8000} --workers ${UVICORN_WORKERS:-2} --timeout-keep-alive ${UVICORN_TIMEOUT_KEEP_ALIVE:-75} --limit-concurrency ${UVICORN_LIMIT_CONCURRENCY:-2000}"]
