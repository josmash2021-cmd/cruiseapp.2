"""CRUISEAPP2 Railway Function — Serverless worker.

This function handles background tasks that don't need the full
FastAPI app running. Typical use cases:
- Scheduled cleanup jobs (cron)
- Image processing pipelines
- Batch notification sends
- Report generation

To add a cron schedule, use:
    railway functions push --cron "0 0 * * *"
"""

import os
import json
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def handler(event, context):
    """Main entry point for Railway Functions.

    Args:
        event: Dict containing trigger payload (HTTP body for HTTP triggers,
               or empty dict for cron triggers).
        context: Dict containing metadata about the invocation.

    Returns:
        Dict with status code and body for HTTP responses.
    """
    logger.info("[Function] Invoked with event: %s", json.dumps(event, default=str))

    # Example: health check endpoint
    if event.get("path") == "/health":
        return {
            "statusCode": 200,
            "body": json.dumps({"status": "ok", "function": "cruiseapp-functions"}),
        }

    # Example: scheduled cleanup task
    if event.get("trigger") == "cron":
        # Run cleanup logic here
        logger.info("[Function] Running scheduled cleanup...")
        return {
            "statusCode": 200,
            "body": json.dumps({"status": "cleanup_complete"}),
        }

    # Default: echo back
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "ok",
            "message": "CruiseApp function invoked",
            "event": event,
        }),
    }


# For local testing
if __name__ == "__main__":
    test_event = {"path": "/health", "httpMethod": "GET"}
    result = handler(test_event, {})
    print(json.dumps(result, indent=2))
