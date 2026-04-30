"""CRUISEAPP2 Background Worker — Python Web Service.

This module exposes a lightweight FastAPI app that runs as a separate
Railway Web Service (NOT a Railway Function, since Railway Functions
are Bun/JS-only). It handles background tasks that don't need the full
FastAPI app running:

- Scheduled cleanup jobs (cron via external scheduler hitting /cleanup)
- Image processing pipelines
- Batch notification sends
- Report generation
- Health checks for the worker itself

Start command:
    uvicorn backend.functions.cruiseapp-functions:app --host 0.0.0.0 --port $PORT

Or via the root railway.toml startCommand override for this service.
"""

import os
import json
import logging
from datetime import datetime, timezone
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup / shutdown lifecycle."""
    logger.info("[Worker] Background worker starting up...")
    yield
    logger.info("[Worker] Background worker shutting down...")


app = FastAPI(
    title="CruiseApp Background Worker",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


@app.get("/health")
async def health():
    """Health check for Railway load balancer / monitoring."""
    return {"status": "ok", "service": "cruiseapp-functions", "timestamp": datetime.now(timezone.utc).isoformat()}


@app.post("/cleanup")
async def cleanup(request: Request):
    """Run scheduled cleanup tasks.

    Triggered by an external cron scheduler (e.g. Railway cron, GitHub
    Actions, or n8n) via HTTP POST.
    """
    body = await request.json() if request.headers.get("content-type") == "application/json" else {}
    logger.info("[Worker] Cleanup triggered with payload: %s", json.dumps(body, default=str))

    # TODO: Add real cleanup logic here:
    # - Delete old temp files from S3/Railway Volume
    # - Archive completed trips older than 90 days
    # - Clear expired OTP codes from Redis
    # - Remove stale FCM tokens
    # - Compress old audit logs

    return {"status": "cleanup_complete", "timestamp": datetime.now(timezone.utc).isoformat()}


@app.post("/batch-notify")
async def batch_notify(request: Request):
    """Send batch push notifications.

    Payload:
        {
            "tokens": ["token1", "token2", ...],
            "title": "Hello",
            "body": "World",
            "data": {"type": "announcement"}
        }
    """
    body = await request.json() if request.headers.get("content-type") == "application/json" else {}
    tokens = body.get("tokens", [])
    title = body.get("title", "")
    body_text = body.get("body", "")
    data = body.get("data", {})

    logger.info("[Worker] Batch notify: %d tokens, title=%r", len(tokens), title)

    # TODO: Integrate with services.fcm_service to send pushes
    # from services.fcm_service import _send_fcm_push_async
    # for token in tokens:
    #     asyncio.create_task(_send_fcm_push_async(token, title, body_text, data))

    return {"status": "queued", "count": len(tokens)}


@app.post("/process-images")
async def process_images(request: Request):
    """Process uploaded images (resize, compress, upload to S3).

    Payload:
        {"image_urls": ["url1", "url2"], "target_width": 800}
    """
    body = await request.json() if request.headers.get("content-type") == "application/json" else {}
    urls = body.get("image_urls", [])
    logger.info("[Worker] Image processing: %d URLs", len(urls))

    # TODO: Add Pillow + aiobotocore image processing pipeline

    return {"status": "processing", "count": len(urls)}


@app.post("/generate-report")
async def generate_report(request: Request):
    """Generate admin reports (CSV/PDF) and email them.

    Payload:
        {"report_type": "daily_trips", "email": "admin@example.com"}
    """
    body = await request.json() if request.headers.get("content-type") == "application/json" else {}
    report_type = body.get("report_type", "unknown")
    email = body.get("email", "")
    logger.info("[Worker] Report generation: type=%s, email=%s", report_type, email)

    # TODO: Query DB, generate CSV/PDF, upload to S3, send email

    return {"status": "report_queued", "type": report_type}


# Default catch-all for unknown paths (helps with Railway health probes)
@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def catch_all(request: Request, path: str):
    logger.warning("[Worker] Unhandled path: %s %s", request.method, path)
    return JSONResponse(
        {"status": "ok", "message": "CruiseApp worker is running", "path": path},
        status_code=200,
    )
