FROM python:3.12-slim

WORKDIR /app

# Install postgresql-client for pg_dump (used by db_backup.py)
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client && rm -rf /var/lib/apt/lists/*

# Set PYTHONPATH so local imports work correctly
ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1

# Copy requirements first for better Docker layer caching
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy all backend files
COPY backend/ .

# Verify files are in place during build
RUN echo "=== Files in /app ===" && ls -la /app && echo "=== Checking models directory ===" && ls -la /app/models && echo "=== Python version ===" && python --version

EXPOSE 8000

# Use a startup script that verifies everything before starting
RUN echo '#!/bin/sh\n\
echo "=== Cruise Backend Startup ==="\n\
echo "PWD: $(pwd)"\n\
echo "PYTHONPATH: $PYTHONPATH"\n\
echo "=== Verifying files ==="\n\
ls -la /app/\n\
ls -la /app/models/\n\
echo "=== Running migrations ==="\n\
python /app/migrate.py\n\
echo "=== Starting uvicorn ==="\n\
exec uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000} --workers 1 --timeout-keep-alive 75\n\
' > /app/start.sh && chmod +x /app/start.sh

CMD ["/app/start.sh"]
