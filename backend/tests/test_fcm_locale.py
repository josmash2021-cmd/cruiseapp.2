"""FCM notification language (2026-10-05, user spec): an individual push
follows the recipient's phone language (users.locale, reported by the app
at boot). The service resolves it from the FCM token (claim-on-write: one
row per token) unless the caller passes `locale=` explicitly. Spanish is
the default — the historical behaviour for old builds.
"""

import pytest

import services.fcm_service as fcm
from models.database import User
from utils.helpers import user_lang

pytestmark = pytest.mark.asyncio


@pytest.fixture
def capture(monkeypatch):
    sent = []
    monkeypatch.setattr(
        fcm, "_send_fcm_push",
        lambda token, title, body, data=None, is_offer=False, **kw: sent.append((title, body)),
    )
    fcm._LOCALE_CACHE.clear()
    return sent


async def _mk_user(db, email, token, locale):
    u = User(
        first_name="T", last_name="U", email=email, phone=f"+1999{abs(hash(email)) % 10**7:07d}",
        password_hash="x", role="driver", status="active",
        fcm_token=token, locale=locale,
    )
    db.add(u)
    await db.commit()
    return u


async def test_picks_english_from_token_owner(db, capture):
    await _mk_user(db, "en@test.com", "tok-en-1", "en")
    await fcm._send_fcm_push_async("tok-en-1", "Hola", "Cuerpo",
                                   title_en="Hello", body_en="Body")
    assert capture == [("Hello", "Body")]


async def test_picks_spanish_from_token_owner(db, capture):
    await _mk_user(db, "es@test.com", "tok-es-1", "es")
    await fcm._send_fcm_push_async("tok-es-1", "Hola", "Cuerpo",
                                   title_en="Hello", body_en="Body")
    assert capture == [("Hola", "Cuerpo")]


async def test_unknown_token_defaults_spanish(capture):
    await fcm._send_fcm_push_async("tok-nadie", "Hola", "Cuerpo",
                                   title_en="Hello", body_en="Body")
    assert capture == [("Hola", "Cuerpo")]


async def test_explicit_locale_wins_over_token(db, capture):
    await _mk_user(db, "es2@test.com", "tok-es-2", "es")
    await fcm._send_fcm_push_async("tok-es-2", "Hola", "Cuerpo",
                                   title_en="Hello", body_en="Body", locale="en")
    assert capture == [("Hello", "Body")]


async def test_missing_english_piece_falls_back_to_spanish(db, capture):
    await _mk_user(db, "en2@test.com", "tok-en-2", "en")
    await fcm._send_fcm_push_async("tok-en-2", "Hola", "Cuerpo", title_en="Hello")
    assert capture == [("Hello", "Cuerpo")]


async def test_no_en_variants_untouched(db, capture):
    await _mk_user(db, "en3@test.com", "tok-en-3", "en")
    await fcm._send_fcm_push_async("tok-en-3", "Hola", "Cuerpo")
    assert capture == [("Hola", "Cuerpo")]


async def test_sync_path_uses_explicit_locale(capture):
    fcm._send_fcm_push  # patched by the fixture; call the real wrapper logic
    # The sync function is patched, so exercise _apply_lang directly.
    assert fcm._apply_lang("en", "Hola", "Cuerpo", "Hello", "Body") == ("Hello", "Body")
    assert fcm._apply_lang("es", "Hola", "Cuerpo", "Hello", "Body") == ("Hola", "Cuerpo")
    assert fcm._apply_lang(None, "Hola", "Cuerpo", "Hello", "Body") == ("Hola", "Cuerpo")


def test_user_lang_helper():
    class _U:
        pass
    u = _U()
    u.locale = "en"
    assert user_lang(u) == "en"
    u.locale = "es-MX"
    assert user_lang(u) == "es"
    u.locale = None
    assert user_lang(u) == "es"
