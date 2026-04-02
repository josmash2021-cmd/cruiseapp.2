#!/bin/bash
echo "=== Running DB migrations ==="
python migrate.py && echo "Migrations OK" || echo "Migrations skipped/failed - continuing"

# Single worker + uvloop: async handles 1500+ concurrent connections
# Multiple workers would break in-memory SSE event_bus
if python -c "import uvloop" 2>/dev/null; then
    echo "=== Starting server on port ${PORT:-8000} (uvloop + httptools) ==="
    exec uvicorn main:app --host 0.0.0.0 --port "${PORT:-8000}" --workers 1 --timeout-keep-alive 75 --loop uvloop --http httptools
else
    echo "=== Starting server on port ${PORT:-8000} (asyncio fallback) ==="
    exec uvicorn main:app --host 0.0.0.0 --port "${PORT:-8000}" --workers 1 --timeout-keep-alive 75
fi
