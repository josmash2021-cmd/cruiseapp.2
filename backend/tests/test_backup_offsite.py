"""Off-site backup copy (2026-10-15, user spec: respaldo ante cualquier
problema). Every finished pg_dump must land in S3 — the Railway volume
dies with the project; the S3 copy is the disaster-recovery store.
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import db_backup

pytestmark = pytest.mark.asyncio


class _FakeS3Client:
    def __init__(self):
        self.puts = []

    async def put_object(self, **kw):
        self.puts.append(kw)

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False


class _FakeSession:
    def __init__(self, client):
        self._client = client

    def create_client(self, *a, **kw):
        return self._client


async def test_finished_dump_uploads_offsite(monkeypatch, tmp_path):
    dump = tmp_path / "cruise_backup_20261015_120000.sql.gz"
    dump.write_bytes(b"\x1f\x8b fake dump bytes")

    monkeypatch.setenv("S3_ENDPOINT", "https://s3.test")
    monkeypatch.setenv("S3_BUCKET_NAME", "cruise-test")
    monkeypatch.setenv("S3_ACCESS_KEY", "k")
    monkeypatch.setenv("S3_SECRET_KEY", "s")
    import config
    monkeypatch.setattr(config, "S3_ENDPOINT", "https://s3.test")
    monkeypatch.setattr(config, "S3_BUCKET_NAME", "cruise-test")
    monkeypatch.setattr(config, "S3_ACCESS_KEY", "k")
    monkeypatch.setattr(config, "S3_SECRET_KEY", "s")

    client = _FakeS3Client()

    import aiobotocore.session
    monkeypatch.setattr(aiobotocore.session, "get_session",
                        lambda: _FakeSession(client))

    db_backup._last_offsite_key = None
    key = await db_backup.upload_backup_to_s3(dump)

    assert key == "backups/postgres/cruise_backup_20261015_120000.sql.gz"
    assert db_backup._last_offsite_key == key
    assert client.puts[0]["Bucket"] == "cruise-test"
    assert client.puts[0]["ContentType"] == "application/gzip"
    assert client.puts[0]["Body"] == dump.read_bytes()


async def test_upload_fails_soft_and_loudly(monkeypatch, tmp_path, caplog):
    """A broken S3 must never break the local backup — but it logs ERROR."""
    dump = tmp_path / "cruise_backup_x.sql.gz"
    dump.write_bytes(b"x")
    import config
    monkeypatch.setattr(config, "S3_ENDPOINT", "https://s3.test")
    monkeypatch.setattr(config, "S3_BUCKET_NAME", "cruise-test")
    monkeypatch.setattr(config, "S3_ACCESS_KEY", "k")
    monkeypatch.setattr(config, "S3_SECRET_KEY", "s")

    import aiobotocore.session

    class _Boom:
        def get_session(self):
            raise RuntimeError("s3 down")

    monkeypatch.setattr(aiobotocore.session, "get_session", lambda: None)
    monkeypatch.setattr(aiobotocore.session, "AioSession", None)
    # get_session returning None → create_client raises AttributeError inside
    monkeypatch.setattr(aiobotocore.session, "get_session",
                        lambda: type("S", (), {"create_client": lambda *a, **k: (_ for _ in ()).throw(RuntimeError("s3 down"))})())

    key = await db_backup.upload_backup_to_s3(dump)
    assert key is None
    assert "off-site S3 copy FAILED" in caplog.text
