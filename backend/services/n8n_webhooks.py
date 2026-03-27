"""Fire-and-forget n8n webhook triggers."""
import logging, httpx

try:
    from .config import N8N_WEBHOOK_BASE, _HAS_N8N
except ImportError:
    from config import N8N_WEBHOOK_BASE, _HAS_N8N

_client = httpx.AsyncClient(timeout=10.0) if _HAS_N8N else None


async def fire(path: str, payload: dict) -> None:
    """POST *payload* to N8N_WEBHOOK_BASE/<path>. Swallows all errors."""
    if not _HAS_N8N or _client is None:
        return
    url = f"{N8N_WEBHOOK_BASE.rstrip('/')}/{path.lstrip('/')}"
    try:
        resp = await _client.post(url, json=payload)
        if resp.status_code >= 400:
            logging.warning("[n8n] %s returned %s", path, resp.status_code)
    except Exception as exc:
        logging.warning("[n8n] %s failed: %s", path, exc)
