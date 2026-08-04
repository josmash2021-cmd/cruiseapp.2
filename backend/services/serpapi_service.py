"""SerpAPI client — Google results without scraping.

Thin async wrapper around serpapi.com. The key comes from the
SERPAPI_API_KEY env var (Railway variables in production); when it is
unset every helper returns None and callers fall back to their existing
behaviour, so the integration can never take the app down.
"""
import logging

import httpx

from config import SERPAPI_API_KEY

_BASE = "https://serpapi.com/search.json"
_TIMEOUT = 12.0


def _enabled() -> bool:
    return bool(SERPAPI_API_KEY)


async def google_search(query: str, num: int = 10, **params) -> dict | None:
    """Organic Google results for [query], or None when not configured
    or the call fails."""
    if not _enabled():
        return None
    q = {"engine": "google", "q": query, "num": num,
         "api_key": SERPAPI_API_KEY, **params}
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
            r = await client.get(_BASE, params=q)
            r.raise_for_status()
            return r.json()
    except Exception as e:
        logging.warning("[SerpAPI] google_search failed: %s", e)
        return None


async def google_maps_search(query: str, lat: float | None = None,
                             lng: float | None = None,
                             zoom: int = 14) -> dict | None:
    """Google Maps local results (businesses, addresses) around an
    optional point, or None when not configured or the call fails."""
    if not _enabled():
        return None
    q = {"engine": "google_maps", "q": query,
         "type": "search", "api_key": SERPAPI_API_KEY}
    if lat is not None and lng is not None:
        q["ll"] = f"@{lat},{lng},{zoom}z"
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
            r = await client.get(_BASE, params=q)
            r.raise_for_status()
            return r.json()
    except Exception as e:
        logging.warning("[SerpAPI] google_maps_search failed: %s", e)
        return None
