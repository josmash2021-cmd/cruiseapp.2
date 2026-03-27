"""Checkr API service for driver background checks.

Supports both sandbox (api.checkr-staging.com) and production (api.checkr.com).
"""

import asyncio
import logging
import os
from datetime import datetime, timezone
from typing import Optional

import httpx

logger = logging.getLogger("cruise.checkr")

_CHECKR_API_KEY = os.getenv("CHECKR_API_KEY", "")
_CHECKR_SANDBOX = os.getenv("CHECKR_SANDBOX", "true").lower() == "true"
_BASE_URL = "https://api.checkr-staging.com" if _CHECKR_SANDBOX else "https://api.checkr.com"
_MAX_RETRIES = 3
_RETRY_DELAY = 2  # seconds


class CheckrError(Exception):
    def __init__(self, status: int, message: str):
        self.status = status
        self.message = message
        super().__init__(f"Checkr API {status}: {message}")


class CheckrService:
    """Thin wrapper around the Checkr REST API v1."""

    def __init__(self, api_key: Optional[str] = None):
        self._api_key = api_key or _CHECKR_API_KEY

    def _auth(self) -> tuple:
        return (self._api_key, "")

    async def _request(self, method: str, path: str, **kwargs) -> dict:
        """HTTP request with retry on 429 / 5xx."""
        url = f"{_BASE_URL}/v1{path}"
        last_exc: Optional[Exception] = None
        for attempt in range(1, _MAX_RETRIES + 1):
            try:
                async with httpx.AsyncClient(timeout=30) as client:
                    resp = await client.request(
                        method, url, auth=self._auth(), **kwargs
                    )
                if resp.status_code == 429:
                    wait = _RETRY_DELAY * attempt
                    logger.warning("Checkr rate-limited, retrying in %ds (attempt %d)", wait, attempt)
                    await asyncio.sleep(wait)
                    continue
                if resp.status_code >= 500:
                    wait = _RETRY_DELAY * attempt
                    logger.warning("Checkr server error %d, retrying in %ds", resp.status_code, wait)
                    await asyncio.sleep(wait)
                    continue
                if resp.status_code == 401:
                    raise CheckrError(401, "Invalid Checkr API key")
                if resp.status_code >= 400:
                    raise CheckrError(resp.status_code, resp.text)
                return resp.json()
            except httpx.HTTPError as exc:
                last_exc = exc
                await asyncio.sleep(_RETRY_DELAY * attempt)
        raise last_exc or CheckrError(500, "Max retries exceeded")

    # ── Candidates ─────────────────────────────────────────

    async def create_candidate(
        self,
        first_name: str,
        last_name: str,
        email: str,
        dob: str,  # YYYY-MM-DD
        ssn_last4: str,
        driver_license_number: str,
        driver_license_state: str,
    ) -> dict:
        """POST /v1/candidates — create a Checkr candidate."""
        payload = {
            "first_name": first_name,
            "last_name": last_name,
            "email": email,
            "dob": dob,
            "ssn": ssn_last4,  # Checkr accepts last-4
            "driver_license_number": driver_license_number,
            "driver_license_state": driver_license_state,
        }
        result = await self._request("POST", "/candidates", json=payload)
        logger.info("Created Checkr candidate %s for %s %s", result.get("id"), first_name, last_name)
        return result

    # ── Invitations ────────────────────────────────────────

    async def create_invitation(
        self,
        candidate_id: str,
        package_slug: str = "driver_pro",
    ) -> dict:
        """POST /v1/invitations — send background check invitation."""
        payload = {
            "candidate_id": candidate_id,
            "package": package_slug,
        }
        result = await self._request("POST", "/invitations", json=payload)
        logger.info("Created Checkr invitation %s for candidate %s", result.get("id"), candidate_id)
        return result

    # ── Reports ────────────────────────────────────────────

    async def get_report(self, report_id: str) -> dict:
        """GET /v1/reports/{id} — fetch a background check report."""
        result = await self._request("GET", f"/reports/{report_id}")
        logger.info("Fetched Checkr report %s status=%s", report_id, result.get("status"))
        return result


# Module-level singleton
checkr = CheckrService()
