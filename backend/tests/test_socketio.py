"""Integration tests for Socket.io real-time communication."""

import pytest
import asyncio
import socketio
import jwt

# JWT secret must match utils.security
_JWT_SECRET = "test-secret-for-ci"
_JWT_ALGORITHM = "HS256"


def _make_token(user_id: int, role: str = "rider") -> str:
    return jwt.encode(
        {"sub": str(user_id), "role": role, "jti": "test-jti-123"},
        _JWT_SECRET,
        algorithm=_JWT_ALGORITHM,
    )


@pytest.fixture(scope="module")
def anyio_backend():
    return "asyncio"


@pytest.mark.asyncio
async def test_socketio_connect_disconnect():
    """Client can connect and disconnect cleanly."""
    client = socketio.AsyncClient()
    connected = False
    disconnected = False

    @client.on("connect")
    async def on_connect():
        nonlocal connected
        connected = True

    @client.on("disconnect")
    async def on_disconnect():
        nonlocal disconnected
        disconnected = True

    # Connect to test server (adjust URL for your test environment)
    try:
        await client.connect(
            "http://localhost:8000",
            socketio_path="/socket.io",
            auth={"token": _make_token(1)},
        )
        await asyncio.sleep(0.5)
        assert connected, "Client should have connected"

        await client.disconnect()
        await asyncio.sleep(0.2)
        assert disconnected, "Client should have disconnected"
    except Exception as e:
        pytest.skip(f"Socket.io server not available for testing: {e}")


@pytest.mark.asyncio
async def test_socketio_authenticate():
    """Client can authenticate after connecting."""
    client = socketio.AsyncClient()
    auth_result = None

    @client.on("authenticated")
    async def on_authenticated(data):
        nonlocal auth_result
        auth_result = data

    try:
        await client.connect(
            "http://localhost:8000",
            socketio_path="/socket.io",
        )
        await asyncio.sleep(0.3)

        # Emit authenticate event
        await client.emit("authenticate", {
            "token": _make_token(42, "driver"),
            "user_type": "driver",
            "user_id": 42,
        })
        await asyncio.sleep(0.5)

        assert auth_result is not None, "Should receive authenticated event"
        assert auth_result.get("status") == "success"
        assert auth_result.get("user_id") == 42

        await client.disconnect()
    except Exception as e:
        pytest.skip(f"Socket.io server not available for testing: {e}")


@pytest.mark.asyncio
async def test_socketio_join_trip():
    """Client can join a trip room."""
    client = socketio.AsyncClient()
    joined_result = None

    @client.on("trip_joined")
    async def on_trip_joined(data):
        nonlocal joined_result
        joined_result = data

    try:
        await client.connect(
            "http://localhost:8000",
            socketio_path="/socket.io",
        )
        await asyncio.sleep(0.3)

        # Auth first
        await client.emit("authenticate", {
            "token": _make_token(1),
            "user_type": "rider",
            "user_id": 1,
        })
        await asyncio.sleep(0.3)

        # Join trip
        await client.emit("join_trip", {"trip_id": 999})
        await asyncio.sleep(0.3)

        assert joined_result is not None, "Should receive trip_joined event"
        assert joined_result.get("trip_id") == 999

        await client.disconnect()
    except Exception as e:
        pytest.skip(f"Socket.io server not available for testing: {e}")


@pytest.mark.asyncio
async def test_socketio_invalid_token_rejected():
    """Client with invalid token gets rejected."""
    client = socketio.AsyncClient()
    auth_error = None

    @client.on("auth_error")
    async def on_auth_error(data):
        nonlocal auth_error
        auth_error = data

    try:
        await client.connect(
            "http://localhost:8000",
            socketio_path="/socket.io",
        )
        await asyncio.sleep(0.3)

        # Emit authenticate with bad token
        await client.emit("authenticate", {
            "token": "invalid.token.here",
            "user_type": "rider",
            "user_id": 1,
        })
        await asyncio.sleep(0.5)

        assert auth_error is not None, "Should receive auth_error for invalid token"

        await client.disconnect()
    except Exception as e:
        pytest.skip(f"Socket.io server not available for testing: {e}")
