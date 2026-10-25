"""Individual dispatch notifications reach FCM and the user's inbox."""

import json

import pytest
from sqlalchemy import select

from models.database import Notification
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dispatch_headers():
    return _make_auth_headers("test-dispatch-key")


def _user_headers(token):
    headers = _make_auth_headers()
    headers["Authorization"] = f"Bearer {token}"
    return headers


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    async def _fake(token, title, body, data=None, **kwargs):
        sent.append({"token": token, "title": title, "body": body, "data": data})

    monkeypatch.setattr("routers.admin._send_fcm_push_async", _fake)
    return sent


@pytest.mark.parametrize("role", ["driver", "rider"])
async def test_individual_send_persists_then_pushes_same_id(
    client, db, test_driver, test_rider, pushes, role,
):
    user, token = test_driver if role == "driver" else test_rider
    if role == "rider":
        user.fcm_token = "rider-fcm-token"
        await db.commit()

    res = await client.post(
        "/admin/notifications/send",
        headers=_dispatch_headers(),
        json={
            "user_id": user.id,
            "title": f"  Hola {role}  ",
            "body": "  Mensaje individual  ",
            "data": {
                "trip_id": "42",
                "type": "caller-cannot-override",
                "notification_id": "999999",
            },
        },
    )
    assert res.status_code == 200, res.text
    payload = res.json()
    assert payload["delivery"] == "dispatched"
    notification_id = payload["notification_id"]

    row = (await db.execute(
        select(Notification).where(Notification.id == notification_id)
    )).scalar_one()
    assert row.user_id == user.id
    assert row.title == f"Hola {role}"
    assert row.body == "Mensaje individual"
    assert row.notif_type == "dispatch_notification"
    assert row.is_read is False
    stored_data = json.loads(row.data)
    assert stored_data["trip_id"] == "42"
    assert stored_data["type"] == "dispatch_notification"
    assert stored_data["notification_id"] == str(notification_id)

    assert len(pushes) == 1
    push = pushes[0]
    assert push["token"] == user.fcm_token
    assert push["title"] == f"Hola {role}"
    assert push["body"] == "Mensaje individual"
    assert push["data"] == stored_data

    inbox = await client.get("/notifications", headers=_user_headers(token))
    assert inbox.status_code == 200, inbox.text
    item = next(n for n in inbox.json() if n["id"] == notification_id)
    assert item["type"] == "dispatch_notification"
    assert item["is_read"] is False


async def test_missing_fcm_token_still_delivers_to_inbox(
    client, db, test_rider, pushes,
):
    rider, rider_token = test_rider
    assert rider.fcm_token is None
    res = await client.post(
        "/admin/notifications/send",
        headers=_dispatch_headers(),
        json={"user_id": rider.id, "title": "Aviso", "body": "Solo bandeja"},
    )
    assert res.status_code == 200, res.text
    assert res.json()["delivery"] == "inbox_only"
    assert pushes == []

    inbox = await client.get("/notifications", headers=_user_headers(rider_token))
    assert inbox.status_code == 200, inbox.text
    assert [n["id"] for n in inbox.json()] == [res.json()["notification_id"]]


async def test_push_failure_does_not_lose_inbox_notification(
    client, db, test_driver, monkeypatch,
):
    driver, driver_token = test_driver

    async def _fail(*args, **kwargs):
        raise RuntimeError("FCM unavailable")

    monkeypatch.setattr("routers.admin._send_fcm_push_async", _fail)
    res = await client.post(
        "/admin/notifications/send",
        headers=_dispatch_headers(),
        json={"user_id": driver.id, "title": "Aviso", "body": "Conservado"},
    )
    assert res.status_code == 200, res.text
    assert res.json()["delivery"] == "inbox_only"
    inbox = await client.get("/notifications", headers=_user_headers(driver_token))
    assert [n["id"] for n in inbox.json()] == [res.json()["notification_id"]]


async def test_recipient_search_uses_role_name_email_and_phone(
    client, test_driver, test_rider,
):
    driver, _ = test_driver
    rider, _ = test_rider

    async def _search(role, term):
        res = await client.get(
            "/admin/users",
            params={"role": role, "search": term, "limit": 20},
            headers=_dispatch_headers(),
        )
        assert res.status_code == 200, res.text
        return res.json()

    rows = await _search("rider", "Test Rider")
    assert [u["id"] for u in rows] == [rider.id]
    assert all(u["role"] == "rider" for u in rows)

    rows = await _search("driver", rider.email)
    assert rows == []
    rows = await _search("rider", rider.email)
    assert [u["id"] for u in rows] == [rider.id]
    rows = await _search("driver", driver.phone)
    assert [u["id"] for u in rows] == [driver.id]


async def test_send_validates_input_user_and_dispatch_auth(
    client, db, test_driver, pushes,
):
    driver, _ = test_driver
    res = await client.post(
        "/admin/notifications/send",
        headers=_dispatch_headers(),
        json={"user_id": driver.id, "title": "   ", "body": "Contenido"},
    )
    assert res.status_code == 422

    res = await client.post(
        "/admin/notifications/send",
        headers=_dispatch_headers(),
        json={"user_id": 99999999, "title": "Aviso", "body": "Contenido"},
    )
    assert res.status_code == 404

    res = await client.post(
        "/admin/notifications/send",
        headers=_make_auth_headers(),
        json={"user_id": driver.id, "title": "Aviso", "body": "Contenido"},
    )
    assert res.status_code in (401, 403)
    assert pushes == []
    rows = (await db.execute(select(Notification))).scalars().all()
    assert rows == []


async def test_notification_read_and_delete_are_owner_only(
    client, db, test_driver, test_rider,
):
    driver, driver_token = test_driver
    rider, rider_token = test_rider
    row = Notification(
        user_id=rider.id,
        title="Privada",
        body="Solo rider",
        notif_type="dispatch_notification",
    )
    db.add(row)
    await db.commit()
    await db.refresh(row)

    res = await client.get("/notifications", headers=_user_headers(driver_token))
    assert res.status_code == 200
    assert res.json() == []

    res = await client.patch(
        f"/notifications/{row.id}/read", headers=_user_headers(driver_token),
    )
    assert res.status_code == 404
    res = await client.delete(
        f"/notifications/{row.id}", headers=_user_headers(driver_token),
    )
    assert res.status_code == 404

    res = await client.patch(
        f"/notifications/{row.id}/read", headers=_user_headers(rider_token),
    )
    assert res.status_code == 200, res.text
    await db.refresh(row)
    assert row.is_read is True

    res = await client.delete(
        f"/notifications/{row.id}", headers=_user_headers(rider_token),
    )
    assert res.status_code == 200, res.text
    inbox = await client.get("/notifications", headers=_user_headers(rider_token))
    assert inbox.json() == []
