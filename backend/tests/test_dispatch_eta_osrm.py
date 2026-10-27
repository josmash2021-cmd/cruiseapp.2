"""ETA-based dispatch ranking via OSRM /table (2026-10-27).

The offer must go to whoever ARRIVES first (driving seconds), not whoever
is closest by haversine — a driver across the river can be nearer on the
map but slower to arrive. OSRM needs no api key; Google is the fallback.
"""

import json

import pytest

from routers.dispatch import _fetch_etas_osrm, _fetch_etas_to_pickup, _order_by_driver_eta

pytestmark = pytest.mark.asyncio


class _Driver:
    def __init__(self, id, lat, lng):
        self.id = id
        self.lat = lat
        self.lng = lng


def _osrm_payload(durations):
    return json.dumps({"code": "Ok", "durations": durations}).encode()


def _fake_urlopen(payload_by_host):
    class _Resp:
        def __init__(self, body):
            self._body = body

        def read(self):
            return self._body

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    def _open(url, timeout=0):
        for host, payload in payload_by_host.items():
            if host in url:
                return _Resp(payload)
        raise OSError("no route to host")

    return _open


def _google_payload(drivers):
    return json.dumps({
        "status": "OK",
        "rows": [
            {"elements": [{"status": "OK", "duration": {"value": 100 + i * 50}}]}
            for i, _ in enumerate(drivers)
        ],
    }).encode()


async def test_osrm_returns_seconds_for_every_candidate(monkeypatch):
    drivers = [_Driver(1, 25.7617, -80.1918), _Driver(2, 25.95, -80.3)]
    monkeypatch.setattr(
        "urllib.request.urlopen",
        _fake_urlopen({"router.project-osrm.org": _osrm_payload([[549.6], [1692.8]])}),
    )
    etas = await _fetch_etas_osrm(drivers, 25.8, -80.2)
    assert etas == {1: 549.6, 2: 1692.8}


async def test_order_by_eta_not_by_haversine(monkeypatch):
    # Driver 1 is NEARER in haversine but SLOWER by road; driver 2 is farther
    # in haversine but FASTER by road. The ETA order must put driver 2 first.
    drivers = [_Driver(1, 25.7617, -80.1918), _Driver(2, 25.95, -80.3)]
    monkeypatch.setattr(
        "urllib.request.urlopen",
        _fake_urlopen({"router.project-osrm.org": _osrm_payload([[1692.8], [549.6]])}),
    )
    ordered = await _order_by_driver_eta(drivers, 25.8, -80.2)
    assert [d.id for d in ordered] == [2, 1]


async def test_google_is_used_when_osrm_fails(monkeypatch):
    drivers = [_Driver(1, 25.7617, -80.1918), _Driver(2, 25.95, -80.3)]
    monkeypatch.setattr("routers.dispatch.GOOGLE_MAPS_API_KEY", "test-google-key")
    monkeypatch.setattr(
        "urllib.request.urlopen",
        _fake_urlopen({"maps.googleapis.com": _google_payload(drivers)}),
    )
    etas = await _fetch_etas_to_pickup(drivers, 25.8, -80.2)
    assert etas == {1: 100.0, 2: 150.0}


async def test_haversine_order_when_every_provider_fails(monkeypatch):
    drivers = [_Driver(1, 25.7617, -80.1918), _Driver(2, 25.95, -80.3)]
    monkeypatch.setattr("urllib.request.urlopen", _fake_urlopen({}))
    etas = await _fetch_etas_to_pickup(drivers, 25.8, -80.2)
    assert etas is None
