"""Tests for Checkr background check service."""

import os
import json
from unittest.mock import patch, AsyncMock, MagicMock

import pytest

# Ensure env vars are set before importing
os.environ.setdefault("CHECKR_API_KEY", "test_checkr_key")
os.environ.setdefault("CHECKR_SANDBOX", "true")

from services.checkr_service import CheckrService


@pytest.fixture
def service():
    """Create a fresh CheckrService for each test."""
    svc = CheckrService()
    svc.api_key = "test_checkr_key"
    svc.base_url = "https://api.checkr-staging.com/v1"
    return svc


@pytest.mark.asyncio
async def test_create_candidate_success(service):
    """create_candidate returns candidate data on 201."""
    mock_response = MagicMock()
    mock_response.status_code = 201
    mock_response.json.return_value = {
        "id": "cand_abc123",
        "email": "driver@test.com",
        "first_name": "Test",
        "last_name": "Driver",
    }

    with patch.object(service._client, "post", new_callable=AsyncMock, return_value=mock_response):
        result = await service.create_candidate(
            email="driver@test.com",
            first_name="Test",
            last_name="Driver",
            dob="1990-01-15",
        )
    assert result is not None
    assert result["id"] == "cand_abc123"
    assert result["email"] == "driver@test.com"


@pytest.mark.asyncio
async def test_create_candidate_failure(service):
    """create_candidate returns None on non-2xx."""
    mock_response = MagicMock()
    mock_response.status_code = 400
    mock_response.text = "Bad request"

    with patch.object(service._client, "post", new_callable=AsyncMock, return_value=mock_response):
        result = await service.create_candidate(
            email="bad@test.com",
            first_name="Bad",
            last_name="User",
            dob="invalid",
        )
    assert result is None


@pytest.mark.asyncio
async def test_create_invitation_success(service):
    """create_invitation returns invitation with URL on 201."""
    mock_response = MagicMock()
    mock_response.status_code = 201
    mock_response.json.return_value = {
        "id": "inv_xyz789",
        "candidate_id": "cand_abc123",
        "invitation_url": "https://checkr.com/invite/xyz",
    }

    with patch.object(service._client, "post", new_callable=AsyncMock, return_value=mock_response):
        result = await service.create_invitation(candidate_id="cand_abc123")
    assert result is not None
    assert result["invitation_url"] == "https://checkr.com/invite/xyz"


@pytest.mark.asyncio
async def test_create_invitation_custom_package(service):
    """create_invitation uses custom package slug."""
    mock_response = MagicMock()
    mock_response.status_code = 201
    mock_response.json.return_value = {"id": "inv_custom"}

    with patch.object(service._client, "post", new_callable=AsyncMock, return_value=mock_response) as mock_post:
        result = await service.create_invitation(
            candidate_id="cand_abc123",
            package_slug="driver_standard",
        )
    assert result is not None
    call_kwargs = mock_post.call_args
    body = json.loads(call_kwargs.kwargs.get("content", "{}"))
    assert body["package"] == "driver_standard"


@pytest.mark.asyncio
async def test_get_report_success(service):
    """get_report returns report data on 200."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {
        "id": "rpt_456",
        "status": "clear",
        "candidate_id": "cand_abc123",
    }

    with patch.object(service._client, "get", new_callable=AsyncMock, return_value=mock_response):
        result = await service.get_report(report_id="rpt_456")
    assert result is not None
    assert result["status"] == "clear"


@pytest.mark.asyncio
async def test_get_report_not_found(service):
    """get_report returns None on 404."""
    mock_response = MagicMock()
    mock_response.status_code = 404
    mock_response.text = "Not found"

    with patch.object(service._client, "get", new_callable=AsyncMock, return_value=mock_response):
        result = await service.get_report(report_id="rpt_nonexistent")
    assert result is None
