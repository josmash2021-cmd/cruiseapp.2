"""2026-10-31 (owner screenshot): driver chats showed under "Riders" on the
panel. The escalation syncs pass no role, and the old default wrote
userRole="rider" over the real one — plus a blank photo and subject."""
import firestore_sync as fs


class _Existing:
    exists = True

    def to_dict(self):
        return {"userName": "Yoanel Perez", "userRole": "driver",
                "userPhoto": "https://x/p.jpg", "subject": "Soporte"}


class _Ref:
    def __init__(self, sink):
        self.sink = sink

    def get(self):
        return _Existing()

    def set(self, data, merge):
        assert merge is True
        self.sink.update(data)


class _Db:
    def __init__(self, sink):
        self.sink = sink

    def collection(self, _name):
        return self

    def document(self, _doc_id):
        return _Ref(self.sink)


def test_an_escalation_sync_never_touches_role_photo_or_subject(monkeypatch):
    written: dict = {}
    monkeypatch.setattr(fs, "_db", _Db(written))
    monkeypatch.setattr(fs, "_ensure_init", lambda *a, **k: None)
    fs._sync_support_chat_now(201, 232, "Yoanel", "",
                              needs_escalation=True, bot_phase="escalated")
    assert "userRole" not in written
    assert "userPhoto" not in written
    assert "subject" not in written
    assert "userName" not in written, "first name alone must not shorten it"
    assert written["botPhase"] == "escalated"


def test_a_full_sync_still_writes_the_role(monkeypatch):
    written: dict = {}
    monkeypatch.setattr(fs, "_db", _Db(written))
    monkeypatch.setattr(fs, "_ensure_init", lambda *a, **k: None)
    fs._sync_support_chat_now(201, 232, "Yoanel", "Perez", None, "driver",
                              "Soporte", "closed")
    assert written["userRole"] == "driver"
    assert written["userName"] == "Yoanel Perez"
