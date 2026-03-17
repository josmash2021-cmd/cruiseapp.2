#!/bin/bash
echo "=== Running DB migrations ==="
python migrate.py && echo "Migrations OK" || echo "Migrations skipped/failed - continuing"
echo "=== Starting server on port ${PORT:-8000} ==="
exec uvicorn main:app --host 0.0.0.0 --port "${PORT:-8000}"
