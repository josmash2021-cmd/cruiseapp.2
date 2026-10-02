"""Cruise load test — the "5,000 drivers online" proof (staging only).

Simulates the real traffic shape against the STAGING replica (never prod):

  * drivers: /loadtest/auth → online (PATCH location is_online) → GPS
    heartbeat every ~2 s (walking the map) → offer poll every ~5 s → accept
    → drive the status ladder (en_route → arrived → in_trip → completed).
  * riders: /loadtest/auth → book every ~40-60 s (test-mode: no hold) →
    poll trip status every ~3 s until the driver closes it.

Everything is plain HTTP (Locust FastHttpUser, gevent) — thousands of
virtual users from one machine. SSE is deliberately not simulated: the
poll fallback is the heavier path, so the numbers are conservative.

Run (staging):
  pip install -r backend/loadtest/requirements.txt
  LT_API_KEY=<staging> LT_HMAC_SECRET=<staging> \
  locust -f backend/loadtest/locustfile.py \
    --host https://<staging-service>.up.railway.app \
    --users 7500 --spawn-rate 50 --run-time 30m

Targets to watch: request rate (goal ≥ ~3.5k req/s sustained from drivers),
p95 latency (<500 ms), failure rate (<0.1%), and Railway CPU/RAM on the
staging service while it runs.
"""

import hashlib
import hmac as _hmac
import itertools
import os
import random
import secrets
import time

from locust import FastHttpUser, between, events, task

API_KEY = os.environ.get("LT_API_KEY", "loadtest-key")
HMAC_SECRET = os.environ.get("LT_HMAC_SECRET", "loadtest-secret")

_ids = itertools.count(1)

# Distributed runs (master + N worker processes in the same container):
# every process counts from 1, so without an offset four workers would
# auth the SAME lt_driver_1@loadtest.invalid accounts and kick each other
# off via single-device session enforcement. WORKER_ID namespaces the id
# space per process.
_WORKER_OFFSET = int(os.environ.get("WORKER_ID", "0")) * 1_000_000

# One synthetic city block — every sim lives inside it so dispatch always
# has drivers in range of every booking.
_BASE_LAT, _BASE_LNG = 25.7617, -80.1918


@events.test_start.add_listener
def _reset_staging_state(environment, **kwargs):
    """Cancel zombie trips/offers and offline every test driver BEFORE the
    spawn burst. A finished run leaves 'requested' trips behind that the
    guardian agents re-dispatch forever; without a reset each run measures
    the previous run's backlog."""
    if environment.parsed_options and getattr(environment.parsed_options, "worker", False):
        return
    import requests
    try:
        r = requests.post(
            f"{environment.host}/loadtest/reset",
            headers=_signed(),
            timeout=60,
        )
        print(f"[loadtest] reset: {r.status_code} {r.text[:200]}")
    except Exception as e:
        print(f"[loadtest] reset failed (continuing anyway): {e}")


def _signed(token: str | None = None) -> dict:
    """The same HMAC envelope the API middleware demands."""
    ts = str(int(time.time()))
    nonce = secrets.token_hex(16)
    fp = "loadtest-device"
    msg = f"{API_KEY}:{ts}:{nonce}:{fp}"
    sig = _hmac.new(HMAC_SECRET.encode(), msg.encode(), hashlib.sha256).hexdigest()
    h = {
        "x-api-key": API_KEY,
        "x-timestamp": ts,
        "x-nonce": nonce,
        "x-signature": sig,
        "x-device-fp": fp,
        "x-client-version": "loadtest-1.0",
    }
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def _xff() -> str:
    """One synthetic IP per sim — the per-IP rate buckets then see exactly
    the per-user traffic they would in prod (the middleware trusts
    X-Forwarded-For behind proxy-headers; staging only)."""
    return f"10.{random.randint(0, 255)}.{random.randint(0, 255)}.{random.randint(2, 254)}"


class _Sim:
    """Shared auth bootstrap for both roles."""

    role = "driver"

    def _auth(self, vu_tag: str) -> bool:
        self.n = next(_ids) + _WORKER_OFFSET
        self.email = f"lt_{self.role}_{self.n}@loadtest.invalid"
        self._ip = _xff()
        # Retry instead of giving up: a failed auth used to stop() the sim,
        # locust respawned it with a NEW email, and the respawn storm of
        # synthetic signups became the loudest traffic in the run (the ~26k
        # "auth 0" client timeouts per 7500-sim run — harness artifact, not
        # server load). With retries, sims come online once and STAY online,
        # which is the whole point of the concurrency proof.
        for attempt in range(6):
            with self.client.post(
                "/loadtest/auth",
                json={"email": self.email, "role": self.role},
                headers={**_signed(), "X-Forwarded-For": self._ip},
                name="loadtest/auth",
                catch_response=True,
            ) as res:
                if res.status_code == 200:
                    data = res.json()
                    self.token = data["access_token"]
                    self.user_id = data["user"]["id"]
                    # Each sim stands on its own tile so dispatch never co-locates them.
                    self.lat = _BASE_LAT + ((self.n % 100) - 50) * 0.0004
                    self.lng = _BASE_LNG + (((self.n // 100) % 100) - 50) * 0.0004
                    return True
                if attempt < 5:
                    res.success()  # transient — retry, don't count as failure
            time.sleep(2 * (attempt + 1))
        res.failure(f"auth {res.status_code}: {(res.text or '')[:120]}")
        return False

    def _get(self, path, name):
        return self.client.get(
            path,
            headers={**_signed(self.token), "X-Forwarded-For": self._ip},
            name=name)

    def _post(self, path, name, **kw):
        return self.client.post(
            path,
            headers={**_signed(self.token), "X-Forwarded-For": self._ip},
            name=name, **kw)

    def _patch(self, path, name, **kw):
        return self.client.patch(
            path,
            headers={**_signed(self.token), "X-Forwarded-For": self._ip},
            name=name, **kw)


class DriverSim(_Sim, FastHttpUser):
    """Online driver: heartbeat + offer polling + trips."""

    role = "driver"
    weight = 2  # 2:1 driver:rider — USERS=7500 means 5,000 drivers online
    wait_time = between(0.5, 1.0)

    def on_start(self):
        if not self._auth("driver"):
            self.stop()
            return
        self._heartbeat(online=True)
        self._next_hb = 0.0
        self._next_poll = time.monotonic()
        self._trip_id = None
        self._trip_stage = None
        self._trip_next = 0.0

    def _heartbeat(self, online=True):
        # A slow walk around the tile — movement keeps the ghost agent calm.
        self.lat += 0.00005
        self._patch(
            f"/drivers/{self.user_id}/location",
            "driver/location",
            json={"lat": self.lat, "lng": self.lng, "is_online": online},
        )

    def _poll_offers(self):
        res = self._get(
            f"/dispatch/driver/pending?driver_id={self.user_id}",
            "driver/pending",
        )
        if res.status_code != 200:
            return
        offers = res.json()
        if not offers:
            return
        offer = offers[0]
        oid = offer.get("offer_id") or offer.get("id")
        if not oid:
            return
        res = self._post(
            f"/dispatch/driver/accept?offer_id={oid}&driver_id={self.user_id}",
            "dispatch/accept",
        )
        if res.status_code == 409:
            # Another sim took it first — real dispatch, not a failure.
            return
        if res.status_code == 200:
            data = res.json()
            self._trip_id = data.get("trip_id") or data.get("id")
            if self._trip_id:
                self._trip_stage = "driver_en_route"
                self._trip_next = time.monotonic() + 4

    def _advance_trip(self):
        if time.monotonic() < self._trip_next:
            return
        stage = self._trip_stage
        self._patch(
            f"/trips/{self._trip_id}/status?status={stage}",
            "trip/status",
        )
        nxt = {
            "driver_en_route": "arrived",
            "arrived": "in_trip",
            "in_trip": "completed",
        }.get(stage)
        if nxt is None:
            self._trip_id = None
            self._trip_stage = None
            return
        self._trip_stage = nxt
        self._trip_next = time.monotonic() + 4

    @task
    def tick(self):
        now = time.monotonic()
        if now >= self._next_hb:
            self._next_hb = now + 2.0
            self._heartbeat()
        if now >= self._next_poll:
            self._next_poll = now + 5.0
            self._poll_offers()
        if self._trip_id is not None:
            self._advance_trip()

    def on_stop(self):
        try:
            self._heartbeat(online=False)
        except Exception:
            pass


class RiderSim(_Sim, FastHttpUser):
    """Rider: books a trip every ~40-60 s and polls until it closes."""

    role = "rider"
    wait_time = between(2.0, 4.0)

    def on_start(self):
        if not self._auth("rider"):
            self.stop()
            return
        self._trip_id = None
        self._next_book = time.monotonic() + (self.n % 30)  # spread bookings
        self._next_poll = 0.0

    def _book(self):
        res = self._post(
            "/trips",
            "trip/create",
            json={
                "rider_id": self.user_id,
                "pickup_address": "100 Loadtest Ave",
                "dropoff_address": "200 Loadtest Blvd",
                "pickup_lat": _BASE_LAT + 0.002,
                "pickup_lng": _BASE_LNG + 0.002,
                "dropoff_lat": _BASE_LAT - 0.004,
                "dropoff_lng": _BASE_LNG - 0.004,
                "vehicle_type": "standard",
            },
        )
        if res.status_code in (200, 201):
            data = res.json()
            self._trip_id = data.get("id") or data.get("trip_id")

    def _poll(self):
        if self._trip_id is None:
            return
        res = self._get(f"/trips/{self._trip_id}/poll", "trip/poll")
        if res.status_code != 200:
            return
        if res.json().get("status") in ("completed", "cancelled"):
            self._trip_id = None

    @task
    def tick(self):
        now = time.monotonic()
        if self._trip_id is None and now >= self._next_book:
            self._next_book = now + 40 + (self.n % 20)
            self._book()
        elif self._trip_id is not None and now >= self._next_poll:
            self._next_poll = now + 3.0
            self._poll()
