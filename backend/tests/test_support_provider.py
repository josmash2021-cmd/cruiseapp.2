"""Support-agent provider plumbing (services/openai_support_service.py).

Pins the 2026-08-31 product call: GPT (OpenAI) leads, Kimi stands by, and
a primary whose key is rejected or out of quota demotes at request time to
the standby — it must never fall through to the rule-based form letters in
cruise_ai_engine while a working key exists. Those form letters are where
the "incoherent" support replies riders reported actually came from.

The module resolves its provider from env at import time, so every test
that touches selection reloads it; the autouse fixture puts it back.
"""
import importlib
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from services import openai_support_service as svc

pytestmark = pytest.mark.asyncio


@pytest.fixture(autouse=True)
def _reload_svc(monkeypatch):
    yield
    # Leave the module in the no-key state regardless of what ran.
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("MOONSHOT_API_KEY", raising=False)
    monkeypatch.delenv("KIMI_API_KEY", raising=False)
    importlib.reload(svc)


def _reload_with(monkeypatch, **env):
    for key in ("OPENAI_API_KEY", "MOONSHOT_API_KEY", "KIMI_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    for key, val in env.items():
        monkeypatch.setenv(key, val)
    importlib.reload(svc)


async def test_openai_leads_and_kimi_stands_by(monkeypatch):
    _reload_with(monkeypatch, OPENAI_API_KEY="sk-test", MOONSHOT_API_KEY="sk-ki-test")
    assert svc._PROVIDER == "openai"
    assert svc._MODEL == svc._OPENAI_MODEL
    assert svc._openai_client is not None
    assert svc._fallback is not None and svc._fallback[2] == "kimi"


async def test_kimi_leads_only_when_no_openai_key(monkeypatch):
    _reload_with(monkeypatch, MOONSHOT_API_KEY="sk-ki-test")
    assert svc._PROVIDER == "kimi"
    assert svc._fallback is None  # no OpenAI key behind it


async def test_no_keys_means_no_provider(monkeypatch):
    _reload_with(monkeypatch)
    assert svc._PROVIDER == "none"


async def test_demote_switches_to_the_standby_permanently(monkeypatch):
    _reload_with(monkeypatch, OPENAI_API_KEY="sk-test", MOONSHOT_API_KEY="sk-ki-test")
    assert svc._demote_primary("401 invalid key") is True
    assert svc._PROVIDER == "kimi"
    assert svc._openai_client is None
    assert svc._fallback is None
    # Nowhere left to demote.
    assert svc._demote_primary("403 quota") is False
    assert svc._PROVIDER == "kimi"


async def test_rejected_primary_still_gets_an_llm_answer(monkeypatch):
    """The whole point: a rejected key must not become a form letter while
    the standby key works."""
    _reload_with(monkeypatch, OPENAI_API_KEY="sk-test", MOONSHOT_API_KEY="sk-ki-test")

    calls = []

    async def _boom(_messages, _tools, _lang="en"):
        raise svc.SupportAuthError("openai rejected the key")

    async def _ok(_messages, _tools, _lang="en"):
        calls.append("kimi")
        return {"response": "hola", "escalate": False}

    monkeypatch.setattr(svc, "_openai_completion", _boom)
    monkeypatch.setattr(svc, "_anthropic_completion", _ok)

    out = await svc.generate_support_response(
        [{"role": "user", "content": "hola"}],
        {"user": {"id": 1}, "messages": []},
    )
    assert out["response"] == "hola"
    assert out["escalate"] is False
    assert calls == ["kimi"]
    # Demoted for every later turn too — one bad key, paid for once.
    assert svc._PROVIDER == "kimi"


async def test_tool_call_fallback_speaks_the_chats_language(monkeypatch):
    """Prod bug (chat 83, 2026-10-11): the model answered with a tool call
    and no text, so the rider read the hardcoded English fallback — inside a
    Spanish conversation. The fallback now follows the chat's language."""
    from types import SimpleNamespace
    _reload_with(monkeypatch, OPENAI_API_KEY="sk-test")

    tool_call = SimpleNamespace(
        function=SimpleNamespace(name="escalate_to_human", arguments="{}"))
    message = SimpleNamespace(content=None, tool_calls=[tool_call])

    class _FakeCompletions:
        async def create(self, **_kwargs):
            return SimpleNamespace(choices=[SimpleNamespace(message=message)])

    monkeypatch.setattr(
        svc, "_openai_client",
        SimpleNamespace(chat=SimpleNamespace(completions=_FakeCompletions())))

    out = await svc._openai_completion([{"role": "user", "content": "ok"}], [], "es")
    assert out["response"] == "Te ayudo con eso ahora mismo."
    assert out["function_call"]["name"] == "escalate_to_human"

    out = await svc._openai_completion([{"role": "user", "content": "ok"}], [], "en")
    assert out["response"] == "I'll help you with that right away."


async def test_no_provider_fallback_speaks_spanish(monkeypatch):
    _reload_with(monkeypatch)
    out = await svc.generate_support_response(
        [{"role": "user", "content": "hola"}],
        {"user": {"id": 1}, "messages": [], "lang": "es"},
    )
    assert out["escalate"] is True
    assert "agente humano" in out["response"]


async def test_provider_error_fallback_speaks_spanish(monkeypatch):
    _reload_with(monkeypatch, MOONSHOT_API_KEY="sk-ki-test")

    async def _boom(_messages, _tools, _lang="en"):
        raise RuntimeError("kimi down")

    monkeypatch.setattr(svc, "_anthropic_completion", _boom)
    out = await svc.generate_support_response(
        [{"role": "user", "content": "hola"}],
        {"user": {"id": 1}, "messages": [], "lang": "es"},
    )
    assert out["escalate"] is True
    assert "dificultades técnicas" in out["response"]


async def test_english_chat_keeps_the_english_fallbacks(monkeypatch):
    """Control: nothing changes for English conversations."""
    _reload_with(monkeypatch)
    out = await svc.generate_support_response(
        [{"role": "user", "content": "hello"}],
        {"user": {"id": 1}, "messages": [], "lang": "en"},
    )
    assert out["escalate"] is True
    assert out["response"].startswith("I'm having trouble connecting")
