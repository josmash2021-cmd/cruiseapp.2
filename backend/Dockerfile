FROM python:3.12-slim

WORKDIR /app

# Install postgresql-client for pg_dump (used by db_backup.py)
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client && rm -rf /var/lib/apt/lists/*

# Set PYTHONPATH so local imports work correctly
ENV PYTHONPATH=/app

# Copy requirements first for better Docker layer caching
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy all backend files
COPY backend/ .

# Verify files are in place
RUN echo "=== Files in /app ===" && ls -la /app && echo "=== Python version ===" && python --version

EXPOSE 8000

# Run migrations then start server
CMD ["sh", "-c", "echo '=== Starting Cruise Backend ===' && echo 'PWD:' $(pwd) && echo 'PYTHONPATH:' $PYTHONPATH && echo '=== Running migrations ===' && python migrate.py && echo '=== Starting uvicorn ===' && exec uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000} --workers 1 --timeout-keep-alive 75"]
