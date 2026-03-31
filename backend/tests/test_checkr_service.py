"""Tests for Checkr background check service."""

import os
from unittest.mock import patch, AsyncMock, MagicMock

import pytest

# Ensure env vars are set before importing
os.environ.setdefault("CHECKR_API_KEY", "test_checkr_key")
os.environ.setdefault("CHECKR_SANDBOX", "true")

from services.checkr_service import CheckrService, CheckrError


@pytest.fixture
def service():
    """Create a fresh CheckrService for each test."""
    return CheckrService(api_key="test_checkr_key")


def _make_http_mock(status_code: int, json_data: dict = None, text: str = ""):
    """Build a mock httpx.AsyncClient context manager returning the given response."""
    mock_response = MagicMock()
    mock_response.status_code = status_code
    mock_response.text = text
    if json_data is not None:
        mock_response.json.return_value = json_data

    mock_client = AsyncMock()
    mock_client.request = AsyncMock(return_value=mock_response)

    mock_ctx = MagicMock()
    mock_ctx.__aenter__ = AsyncMock(return_value=mock_client)
    mock_ctx.__aexit__ = AsyncMock(return_value=False)

    return mock_ctx, mock_client


@pytest.mark.asyncio
async def test_create_candidate_success(service):
    """create_candidate returns candidate data on 2xx."""
    json_data = {
        "id": "cand_abc123",
        "email": "driver@test.com",
        "first_name": "Test",
        "last_name": "Driver",
    }
    mock_ctx, _ = _make_http_mock(201, json_data)

    with patch("httpx.AsyncClient", return_value=mock_ctx):
        result = await service.create_candidate(
            first_name="Test",
            last_name="Driver",
            email="driver@test.com",
            dob="1990-01-15",
            ssn_last4="1234",
            driver_license_number="D1234567",
            driver_license_state="CA",
        )
    assert result["id"] == "cand_abc123"
    assert result["email"] == "driver@test.com"


@pytest.mark.asyncio
async def test_create_candidate_failure(service):
    """create_candidate raises CheckrError on 4xx."""
    mock_ctx, _ = _make_http_mock(400, text="Bad request")

    with patch("httpx.AsyncClient", return_value=mock_ctx):
        with pytest.raises(CheckrError) as exc_info:
            await service.create_candidate(
                first_name="Bad",
                last_name="User",
                email="bad@test.com",
                dob="invalid",
                ssn_last4="0000",
                driver_license_number="X0000000",
                driver_license_state="XX",
            )
    assert exc_info.value.status == 400


@pytest.mark.asyncio
async def test_create_invitation_success(service):
    """create_invitation returns invitation data on 2xx."""
    json_data = {
        "id": "inv_xyz789",
        "candidate_id": "cand_abc123",
        "invitation_url": "https://checkr.com/invite/xyz",
    }
    mock_ctx, _ = _make_http_mock(201, json_data)

    with patch("httpx.AsyncClient", return_value=mock_ctx):
        result = await service.create_invitation(candidate_id="cand_abc123")
    assert result["invitation_url"] == "https://checkr.com/invite/xyz"


@pytest.mark.asyncio
async def test_create_invitation_custom_package(service):
    """create_invitation passes the custom package slug in the request body."""
    mock_ctx, mock_client = _make_http_mock(201, {"id": "inv_custom"})

    with patch("httpx.AsyncClient", return_value=mock_ctx):
        result = await service.create_invitation(
            candidate_id="cand_abc123",
            package_slug="driver_standard",
        )
    assert result["id"] == "inv_custom"
    call_kwargs = mock_client.request.call_args
    assert call_kwargs.kwargs.get("json", {}).get("package") == "driver_standard"


@pytest.mark.asyncio
async def test_get_report_success(service):
    """get_report returns report data on 200."""
    json_data = {
        "id": "rpt_456",
        "status": "clear",
        "candidate_id": "cand_abc123",
    }
    mock_ctx, _ = _make_http_mock(200, json_data)

    with patch("httpx.AsyncClient", return_value=mock_ctx):
        result = await service.get_report(report_id="rpt_456")
    assert result["status"] == "clear"


@pytest.mark.asyncio
async def test_get_report_not_found(service):
    """get_report raises CheckrError on 404."""
    mock_ctx, _ = _make_http_mock(404, text="Not found")

    with patch("httpx.AsyncClient", return_value=mock_ctx):
        with pytest.raises(CheckrError) as exc_info:
            await service.get_report(report_id="rpt_nonexistent")
    assert exc_info.value.status == 404
