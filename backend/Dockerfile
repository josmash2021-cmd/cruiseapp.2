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
# WORKERS is capped by the DATABASE, not by CPU. The service has 24 vCPU and
# 24 GB available, and the app is I/O-bound, so cores are not the limit —
# Postgres max_connections=100 is. Each worker builds its own pool
# (DB_POOL_SIZE + DB_MAX_OVERFLOW = 18 by default), so 4 workers reserve at
# most 72 connections and leave room for the scheduler leader's lock plus
# admin sessions. Going higher means raising max_connections or putting a
# pooler in front FIRST — otherwise extra workers make things worse, failing
# checkouts instead of queueing them.
#
# This was 2, with a comment reading "2 CPUs on Hobby plan": the plan grew,
# the setting did not, so the service was running on 2 of its 24 cores.
ENV UVICORN_WORKERS=4
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
# --workers 2: Railway Hobby has 2 CPUs
# --timeout-keep-alive 75: Keep connections alive for SSE/WebSocket
# --limit-concurrency 2000: Handle many concurrent riders/drivers
# --loop uvloop: Faster event loop (if available)
CMD ["sh", "-c", "exec uvicorn main:socket_app --host 0.0.0.0 --port ${PORT:-8000} --workers ${UVICORN_WORKERS:-2} --timeout-keep-alive ${UVICORN_TIMEOUT_KEEP_ALIVE:-75} --limit-concurrency ${UVICORN_LIMIT_CONCURRENCY:-2000}"]
