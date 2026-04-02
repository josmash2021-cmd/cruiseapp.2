FROM python:3.12-slim

WORKDIR /app

# Install postgresql-client for pg_dump (used by db_backup.py)
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client && rm -rf /var/lib/apt/lists/*

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/ .

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/ping')" || exit 1

CMD ["sh", "-c", "python migrate.py; if python -c 'import uvloop' 2>/dev/null; then exec uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000} --workers 1 --timeout-keep-alive 75 --loop uvloop --http httptools --limit-concurrency 2000; else exec uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000} --workers 1 --timeout-keep-alive 75 --limit-concurrency 2000; fi"]
