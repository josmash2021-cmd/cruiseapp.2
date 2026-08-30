"""Guard for the read-poll exemption in the rate-limit middleware.

Prod outage 2026-08-30 (trip 625): one rider mid-trip polls /trips/{id}/poll
every 2 s, /support/chats/{id}/messages every 2 s, the unread badge peeks
/trips/{id}/chat every 8 s — 100+ req/min from ONE device. That exhausted
the shared per-IP general tier (100/min) and the SAME bucket then 429'd
real user actions: cancel trip and support-chat send were dead for that
rider. Read-only poll GETs now skip the tier (they stay under the global
DDoS cap); everything else — including POSTs on the same paths — keeps it.

If this test fails, the exemption regressed and polling users are eating
429s again on cancel/chat.

NOTE: every request needs FRESH signed headers — reusing one header set
replays the nonce and the security layer 401s/bans instead of reaching the
limiter.
"""

import pytest
from httpx import AsyncClient

from main import _is_read_poll_path
from .conftest import _make_auth_headers


def _headers(token: str) -> dict:
    h = _make_auth_headers()
    h["Authorization"] = f"Bearer {token}"
    return h


class TestReadPollPathClassification:
    def test_poll_gets_are_exempt(self):
        assert _is_read_poll_path("/trips/active")
        assert _is_read_poll_path("/support/chats")
        assert _is_read_poll_path("/trips/625/poll")
        assert _is_read_poll_path("/trips/625/chat")
        assert _is_read_poll_path("/support/chats/52/messages")

    def test_lookalikes_are_not_exempt(self):
        # Dispatch-only admin reads stay under the tier.
        assert not _is_read_poll_path("/support/chats/all")
        assert not _is_read_poll_path("/support/chats/52/messages/dispatch")
        # Plain trip fetch, trip writes, cancel — all counted.
        assert not _is_read_poll_path("/trips/625")
        assert not _is_read_poll_path("/trips/625/status")


@pytest.mark.asyncio
async def test_poll_flood_never_429s_and_never_starves_actions(
    client: AsyncClient, test_rider, test_trip
):
    """120 poll GETs (over the old 100/min tier) must all pass, and a
    counted action afterwards must still pass — the bucket was not drained
    by polling."""
    _, token = test_rider

    for _ in range(120):
        r = await client.get("/trips/active", headers=_headers(token))
        assert r.status_code != 429, "read-poll GET consumed the tier"

    # A counted endpoint afterwards still has budget (only a handful of
    # counted requests so far, far under 100).
    r = await client.get(f"/trips/{test_trip.id}", headers=_headers(token))
    assert r.status_code == 200


@pytest.mark.asyncio
async def test_counted_paths_still_throttle_at_100(
    client: AsyncClient, test_rider, test_trip
):
    """The tier itself is intact: 101 counted GETs from one IP → 429."""
    _, token = test_rider

    last = None
    for _ in range(101):
        last = await client.get(f"/trips/{test_trip.id}", headers=_headers(token))
    assert last is not None and last.status_code == 429


@pytest.mark.asyncio
async def test_chat_post_keeps_the_tier(client: AsyncClient, test_rider, test_trip):
    """Only GET is exempt — POST /trips/{id}/chat must still be counted."""
    _, token = test_rider

    # Fill the counted bucket just under the cap with trip GETs, then prove
    # a chat POST lands in the SAME counted bucket (not the exempt one).
    for _ in range(99):
        r = await client.get(f"/trips/{test_trip.id}", headers=_headers(token))
        assert r.status_code == 200

    post = await client.post(
        f"/trips/{test_trip.id}/chat", headers=_headers(token), json={"message": "hola"}
    )
    # 100th counted request — allowed regardless of chat-specific validation.
    assert post.status_code != 429
    post2 = await client.post(
        f"/trips/{test_trip.id}/chat", headers=_headers(token), json={"message": "hola"}
    )
    assert post2.status_code == 429, "chat POST escaped the counted tier"
