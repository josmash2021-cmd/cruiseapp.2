"""Notices on the operators' phones (Web Push, 2026-11-16): the same two
kinds as the panel, one notification per kind that says the count, never
twice a minute, nothing old after a restart, and only the browsers' push
services as endpoints."""
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from services import panel_push
from tests.conftest import _make_auth_headers

PANEL = Path(__file__).resolve().parents[1] / "dispatch_panel"
NOW = datetime.now(timezone.utc)
APPLE = "https://web.push.apple.com/QAbc123"
KEYS = {"p256dh": "B" + "x" * 86, "auth": "a" * 22}


def _panel():
    return _make_auth_headers("test-dispatch-key")


def _pulse(sup=0, una=0, oldest_min=1, name="María L.", chat_id=201, trip_id=852):
    oldest = (NOW - timedelta(minutes=oldest_min)).isoformat()
    return {"support": {"n": sup, "oldest": oldest if sup else None,
                        "first": {"chat_id": chat_id, "name": name} if sup else None},
            "unassigned": {"n": una, "oldest": oldest if una else None,
                           "first": {"trip_id": trip_id, "reservation": False, "label": "A → B"} if una else None}}


def test_decide_one_notice_per_kind_that_counts():
    st = {}
    # A restart: what already waits is the baseline, nothing is pushed.
    assert panel_push.decide(st, _pulse(sup=2), 0, NOW) == []
    # One more arrives: one push with the count.
    [p] = panel_push.decide(st, _pulse(sup=3), 100, NOW)
    assert p["tag"] == "cruise-support" and p["body"].startswith("3 personas esperan respuesta")
    # More within the minute: wait; after the minute: one push with the new count.
    assert panel_push.decide(st, _pulse(sup=5), 130, NOW) == []
    [p] = panel_push.decide(st, _pulse(sup=6), 170, NOW)
    assert p["body"].startswith("6 personas")
    # All answered, then a new one: it pushes again ("0 → 1").
    assert panel_push.decide(st, _pulse(sup=0), 400, NOW) == []
    [p] = panel_push.decide(st, _pulse(sup=1), 500, NOW)
    assert p["body"] == "María L. escribió a soporte" and p["url"] == "/soporte/chat/201"


def test_decide_long_wait_pushes_once_and_rides_too():
    st = {}
    panel_push.decide(st, _pulse(una=1, oldest_min=2), 0, NOW)
    # Nobody new, but the oldest passes 5 min: one push saying so.
    [p] = panel_push.decide(st, _pulse(una=1, oldest_min=6), 100, NOW)
    assert p["tag"] == "cruise-unassigned" and "#852" in p["body"] and p["url"] == "/viajes/viaje/sql_852"
    assert panel_push.decide(st, _pulse(una=1, oldest_min=8), 300, NOW) == []
    [p] = panel_push.decide(st, _pulse(una=4, oldest_min=9), 400, NOW)
    assert p["body"].startswith("4 viajes sin conductor") and p["url"] == "/viajes"


def test_only_push_services_are_endpoints():
    assert panel_push.clean({"endpoint": APPLE, "keys": KEYS})
    assert panel_push.clean({"endpoint": "https://fcm.googleapis.com/fcm/send/x", "keys": KEYS})
    for bad in ("http://web.push.apple.com/x", "https://169.254.169.254/latest", "https://evil.io/web.push.apple.com",
                "https://web.push.apple.com.evil.io/x"):
        assert panel_push.clean({"endpoint": bad, "keys": KEYS}) is None, bad
    assert panel_push.clean({"endpoint": APPLE, "keys": {"p256dh": "x"}}) is None
    assert panel_push.clean("nope") is None


def test_vapid_key_is_stable_and_a_p256_point():
    priv, pub = panel_push.keys()
    assert panel_push.keys() == (priv, pub)
    assert len(pub) == 87 and len(priv) == 43   # 65-byte point, 32-byte scalar (base64url)


@pytest.mark.asyncio
async def test_subscribe_test_and_unsubscribe(client, db, monkeypatch):
    sent = []

    async def _send(payload, only=None):
        sent.append((payload, only))
        return 1

    monkeypatch.setattr(panel_push, "send", _send)
    assert (await client.get("/admin/panel/push/key", headers=_make_auth_headers())).status_code in (401, 403)
    r = await client.get("/admin/panel/push/key", headers=_panel())
    assert r.json()["public_key"] == panel_push.keys()[1]

    bad = await client.post("/admin/panel/push/subscribe", headers=_panel(),
                            json={"subscription": {"endpoint": "https://evil.io/x", "keys": KEYS}})
    assert bad.status_code == 400
    r = await client.post("/admin/panel/push/subscribe", headers=_panel(),
                          json={"subscription": {"endpoint": APPLE, "keys": KEYS}, "label": "iPhone"})
    assert r.status_code == 200, r.text
    assert [s["endpoint"] for s in await panel_push.subscriptions(db)] == [APPLE]

    # The test goes to THIS device only.
    r = await client.post("/admin/panel/push/test", headers=_panel(), json={"endpoint": APPLE})
    assert r.status_code == 200 and sent[-1][1] == APPLE
    assert (await client.post("/admin/panel/push/test", headers=_panel(),
                              json={"endpoint": "https://web.push.apple.com/other"})).status_code == 404

    r = await client.post("/admin/panel/push/unsubscribe", headers=_panel(), json={"endpoint": APPLE})
    assert r.json() == {"ok": True, "removed": True}
    assert await panel_push.subscriptions(db) == []


def test_panel_is_installable_and_keeps_its_push_worker():
    html = (PANEL / "index.html").read_text(encoding="utf-8")
    assert '<link rel="manifest" href="/panel/manifest.json" />' in html
    assert '<link rel="apple-touch-icon" href="/panel/icons/apple-touch-icon.png" />' in html
    sw = (PANEL / "push-sw.js").read_text(encoding="utf-8")
    assert 'addEventListener("push"' in sw and 'addEventListener("notificationclick"' in sw
    assert '"fetch"' not in sw, "push only: a fetch handler could serve an old panel"
    main = (PANEL / "assets" / "index-CuQT_62K.js").read_text(encoding="utf-8")
    assert main.count("guard-pin panel_push_sw_kept") == 1
    assert '.endsWith("/panel/push-sw.js")' in main
    pulse = (PANEL / "assets" / "panel-pulse-Cruise2026.js").read_text(encoding="utf-8")
    # Apple only lets the permission be asked inside the tap: it goes first.
    turn_on = pulse[pulse.index("const turnOn=async()=>{"):]
    assert turn_on.index("Notification.requestPermission()") < turn_on.index("serviceWorker.register(")
    for name in ("icon-192.png", "icon-512.png", "apple-touch-icon.png"):
        assert (PANEL / "icons" / name).exists()
