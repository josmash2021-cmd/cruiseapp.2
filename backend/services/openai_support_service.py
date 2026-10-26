"""LLM-powered support chat service for CruiseApp.

Replaces the rule-based keyword bot with a chat model for human-like
responses, plus function calling for autonomous actions (cancel trip,
apply promo, escalate...).

Provider
--------
Kimi (Moonshot AI) — product call 2026-10-02: Moonshot-only. The OpenAI
path below stays wired (client, model, demote machinery) but with no
OPENAI_API_KEY configured it never builds a client; _build_kimi is the
primary and there is no standby. If a second provider is ever wanted
again, the two-provider demote/fallback code is dormant, not deleted.

There is no fine-tuning involved for either. What makes this agent good
or bad at Cruise support is _SYSTEM_PROMPT below: the app's real
policies, written down so the model does not invent them.
"""

import json
import asyncio
import logging
import os
from typing import Any

import httpx
import openai


class SupportAuthError(Exception):
    """Kimi rejected our credentials, our quota, or the request itself.

    Was openai.AuthenticationError, borrowed as a shared vocabulary back when
    two providers had to raise something the same code could catch. With only
    Kimi left, importing an SDK this file never calls to get an exception name
    is a dependency pretending to be a design.
    """


class SupportBadRequest(Exception):
    """The provider refused the request shape — tools, most often."""


_log = logging.getLogger(__name__)


def _localized(lang: str, es: str, en: str) -> str:
    """Pick the string for the conversation's language.

    Every canned fallback below ships ES/EN — a hardcoded English string is
    how a Spanish chat got "I'll help you with that right away." mid
    conversation (prod, chat 83, 2026-10-11).
    """
    return es if (lang or "en").startswith("es") else en

# ── Provider ─────────────────────────────────────────────────────────
# OpenAI (GPT) leads; Kimi stands by. Product call 2026-08-31: the support
# agent runs on GPT — the Kimi Code endpoint is a coding subscription
# sharing its quota with production support, which is how riders ended up
# reading rule-based form letters when it ran dry. A primary whose key is
# missing, rejected or out of quota now demotes at request time
# (_demote_primary) to the other provider instead of falling through.
_MOONSHOT_API_KEY = os.getenv("MOONSHOT_API_KEY", "") or os.getenv("KIMI_API_KEY", "")
_OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "")

# Kimi Code (kimi.com/code) speaks the ANTHROPIC Messages protocol, not
# OpenAI's — verified against a live key. Keys from that console are the
# `sk-ki...` ones; they do NOT authenticate against Moonshot's platform,
# which is a separate product with separate billing.
_KIMI_BASE_URL = os.getenv("MOONSHOT_BASE_URL", "https://api.kimi.com/coding")

# Model ids move faster than this file does, so both are env-overridable.
_MOONSHOT_MODEL = os.getenv("MOONSHOT_MODEL", "k3")
_OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")

def _build_openai() -> tuple[Any, str, str] | None:
    if not _OPENAI_API_KEY:
        return None
    return (openai.AsyncOpenAI(api_key=_OPENAI_API_KEY), _OPENAI_MODEL, "openai")


def _build_kimi() -> tuple[Any, str, str] | None:
    """Kimi needs no client object — _anthropic_completion talks raw HTTP.

    The Anthropic wire format is a single POST and httpx is already a pinned
    dependency, so this never needed an SDK to change one call's shape.
    """
    if not _MOONSHOT_API_KEY:
        return None
    return (None, _MOONSHOT_MODEL, "kimi")


_openai_client = None
_MODEL = _OPENAI_MODEL
_PROVIDER = "none"

# Moonshot-only (product call 2026-10-02) — _build_openai() returns None
# with no key configured, so _build_kimi wins by construction.
_primary = _build_openai() or _build_kimi()
if _primary:
    _openai_client, _MODEL, _PROVIDER = _primary

# The standby is whatever the primary is not — it is what a rejected or
# exhausted primary key falls back TO.
_fallback = (
    _build_kimi() if _PROVIDER == "openai"
    else _build_openai() if _PROVIDER == "kimi"
    else None
)

# Not logged here: main.py's lifespan reports the resolved provider at
# startup, which is where an operator actually looks. Logging it at import
# too printed the same line twice per worker.

# Set once a tools= request has been rejected by the provider, so the
# retry path below stops paying for a round-trip it knows will fail.
_TOOLS_UNSUPPORTED = False


def _anthropic_tools(tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The same tools, in Anthropic's Messages shape.

    OpenAI nests them under `function` with a `parameters` schema; Anthropic
    puts `name`/`description` at the top level and calls the schema
    `input_schema`. Converted here rather than maintained twice, so a tool
    added to _FUNCTIONS reaches both providers.
    """
    out: list[dict[str, Any]] = []
    for f in tools:
        fn = f.get("function") or {}
        if not fn.get("name"):
            continue
        out.append({
            "name": fn["name"],
            "description": fn.get("description", ""),
            "input_schema": fn.get("parameters")
            or {"type": "object", "properties": {}},
        })
    return out


async def _anthropic_completion(messages: list[dict[str, Any]],
                                tools: list[dict[str, Any]],
                                lang: str = "en") -> dict[str, Any]:
    """One turn against an Anthropic-format endpoint (Kimi Code).

    Kimi Code speaks the Anthropic Messages protocol, not OpenAI's, so this
    is a separate call path rather than a base-URL swap: the system prompt
    is a top-level field instead of a message, tools carry `input_schema`,
    and the reply is a list of content blocks.

    Returns the same {response, function_call?, escalate} dict the OpenAI
    path returns, so the caller doesn't care which provider answered.
    """
    system = ""
    convo: list[dict[str, Any]] = []
    for m in messages:
        if m["role"] == "system":
            # Anthropic takes the system prompt as its own field. Later
            # system turns are folded in rather than dropped.
            system = f"{system}\n\n{m['content']}".strip() if system else m["content"]
            continue
        convo.append({"role": m["role"], "content": m["content"]})

    # The conversation must start with a user turn and alternate; a stray
    # leading assistant message is a 400.
    while convo and convo[0]["role"] != "user":
        convo.pop(0)
    if not convo:
        convo = [{"role": "user", "content": "Hello"}]

    body: dict[str, Any] = {
        "model": _MODEL,
        "max_tokens": 800,
        "system": system,
        "messages": convo,
    }
    if not _TOOLS_UNSUPPORTED:
        body["tools"] = _anthropic_tools(tools)

    async with httpx.AsyncClient(timeout=45.0) as client:
        resp = await client.post(
            f"{_KIMI_BASE_URL.rstrip('/')}/v1/messages",
            headers={
                "x-api-key": _MOONSHOT_API_KEY,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json=body,
        )

    if resp.status_code == 401:
        # Plain Exception: positional message only — the OpenAI-SDK-shaped
        # kwargs this used to carry (response=, body=) crashed the raise
        # itself with "takes no keyword arguments" and hid the real 401.
        raise SupportAuthError(
            f"kimi rejected the key: {resp.text[:120]}")
    if resp.status_code >= 400:
        raise RuntimeError(f"kimi {resp.status_code}: {resp.text[:200]}")

    data = resp.json()
    blocks = data.get("content") or []

    # K3 returns `thinking` blocks alongside the answer. They are the
    # model reasoning to itself — never show them to a rider, and never
    # mistake one for the reply.
    text = "".join(
        b.get("text", "") for b in blocks
        if isinstance(b, dict) and b.get("type") == "text"
    ).strip()

    for b in blocks:
        if isinstance(b, dict) and b.get("type") == "tool_use":
            _log.info("[Support AI] kimi tool call: %s", b.get("name"))
            return {
                "response": text or _localized(
                    lang, "Te ayudo con eso ahora mismo.",
                    "I'll help you with that right away."),
                "function_call": {
                    "name": b.get("name", ""),
                    "arguments": b.get("input") or {},
                },
                "escalate": False,
            }

    return {
        "response": text,
        # Text alone never escalates: an OFFER of a human ("si quieres te
        # paso con un supervisor…") is not a transfer. The model escalates by
        # calling escalate_to_human (rule 10); the old substring scan fired
        # on the bot's own mentions and escalated chats nobody asked to
        # escalate (prod chat 84, 2026-10-11).
        "escalate": False,
    }


async def _openai_completion(messages: list[dict[str, Any]],
                             tools: list[dict[str, Any]],
                             lang: str = "en") -> dict[str, Any]:
    """One turn against OpenAI's chat completions.

    Returns the same {response, function_call?, escalate} dict the Kimi
    path returns, so the caller cannot tell which provider answered.
    """
    global _TOOLS_UNSUPPORTED
    extra = {} if _TOOLS_UNSUPPORTED else {
        "tools": tools,
        "tool_choice": "auto",
    }
    # One turn against OpenAI's chat completions. `timeout` rides EVERY call
    # (2026-10-14, Fernando's silence: a hung TLS to the provider used to
    # hang the reply task forever — a silent failure with nothing in the
    # logs. A timeout raises, the router falls back, the user gets an answer).
    try:
        resp = await _openai_client.chat.completions.create(
            model=_MODEL,
            messages=messages,
            max_tokens=800,
            temperature=0.7,
            timeout=30.0,
            **extra,
        )
    except openai.BadRequestError as e:
        if _TOOLS_UNSUPPORTED:
            raise
        _log.warning(
            "[Support AI] openai rejected tools (%s) — retrying without them", e,
        )
        _TOOLS_UNSUPPORTED = True
        resp = await _openai_client.chat.completions.create(
            model=_MODEL,
            messages=messages,
            max_tokens=800,
            temperature=0.7,
            timeout=30.0,
        )

    message = resp.choices[0].message
    if message.tool_calls:
        call = message.tool_calls[0]
        _log.info("[Support AI] openai tool call: %s", call.function.name)
        return {
            "response": message.content or _localized(
                lang, "Te ayudo con eso ahora mismo.",
                "I'll help you with that right away."),
            "function_call": {
                "name": call.function.name,
                "arguments": json.loads(call.function.arguments or "{}"),
            },
            "escalate": False,
        }

    text = (message.content or "").strip()
    return {
        "response": text,
        # Text alone never escalates (see the Kimi path above) — only the
        # escalate_to_human tool or the deliberate early returns below do.
        "escalate": False,
    }


async def _completion(messages: list[dict[str, Any]],
                      tools: list[dict[str, Any]],
                      lang: str = "en") -> dict[str, Any]:
    """The active provider answers one turn. Both paths return the same
    dict, so switching providers mid-process (demote) is invisible here."""
    if _PROVIDER == "kimi":
        return await _anthropic_completion(messages, tools, lang)
    return await _openai_completion(messages, tools, lang)


def _demote_primary(reason: str) -> bool:
    """Primary provider rejected our credentials or ran out of quota —
    switch to the standby, permanently, and say so loudly.

    Config-time selection alone is not a fallback chain: a key that is
    present but INVALID would otherwise shadow a perfectly good standby
    and answer every rider with the escalation message, with nothing in
    the logs explaining why. A rejected key has to demote at request time.

    Returns True when a standby took over.
    """
    global _openai_client, _MODEL, _PROVIDER, _fallback, _TOOLS_UNSUPPORTED
    if not _fallback:
        _log.error(
            "[Support AI] %s rejected the request (%s) and no standby is "
            "configured — falling through to rule-based replies. A 401 is a "
            "bad key; a 403/429 is quota, not configuration.",
            _PROVIDER, reason,
        )
        return False
    _log.error(
        "[Support AI] %s rejected the request (%s) — falling back to %s. "
        "Fix or remove that key.",
        _PROVIDER, reason, _fallback[2],
    )
    _openai_client, _MODEL, _PROVIDER = _fallback
    _fallback = None
    _TOOLS_UNSUPPORTED = False  # a different provider, a different answer
    return True

# System prompt for Cruise support agent
_CORE_PROMPT = """You are Cruise Support, an AI assistant for a premium ride-sharing app called Cruise.

Your personality:
- Professional but warm and friendly
- Empathetic when users are frustrated
- When someone has been waiting on us (a review, a payout, an answer),
  acknowledge the wait and thank their patience BEFORE explaining — that is
  how a good human agent opens, and it is what de-escalates
- Concise but thorough
- Bilingual: answer in the language stated at the top of the context, which is the one the customer just wrote in — never switch on your own

How a great conversation reads (this is the house style — match it):
- Open warm and ready to help. Get the one or two facts that matter early
  (rider or driver? when did it happen?) — a question or two, never a
  questionnaire.
- Use their name once you have it — people stay calm when they feel
  remembered. With a title, match the person's gender: "Sr. Juan" for a
  man, "Sra. María" for a woman (never "Sr. María"). If the gender is not
  clear, the plain first name ("Juan", "María") is always right. If the
  context does not carry the name and the moment calls for it, ask for it
  the way a courteous agent would.
- Give certainty about process whenever you honestly can: a driver who just
  finished onboarding should hear that their information is complete and
  already in the review queue, and that the team notifies them by email and
  in the app — never leave them guessing what happens next.
- Before closing, ask once if there is anything else you can help with. If
  there is not, sign off warm and personal — "Estamos a la orden, que tenga
  un excelente día" — in the customer's language.

THE OWNER'S OWN VOICE — model your answers on this real dispatch reply
(prod chat 143, 2026-10-22): "Hola, buenas tardes Yusmel, soy un agente
especializado del equipo, permíteme unos minutos para revisar tu cuenta y
ayudarte lo mejor posible" — and then the answer came back reviewed and
exact. That is the house standard: greet by name, say what you will do,
do it, thank their patience. Polite, unhurried, and ALWAYS on the topic
they asked about — never bring up anything they did not ask.

Your capabilities:
- Answer questions about trips, payments, accounts, and the app
- Help resolve issues with rides
- Process refunds and credits when appropriate
- Cancel trips (only if no driver assigned or within 2 min window)
- Escalate to human supervisors for complex or sensitive issues
- Provide emotional support after bad experiences

Rules:
1. ALWAYS verify user identity before making changes to their account
2. NEVER share personal information of other users (drivers, other riders)
3. For safety issues, ALWAYS escalate to human immediately
4. For refunds over $50, get confirmation before processing
5. Be transparent that you are an AI assistant
6. If you don't know something, admit it and offer to connect with a human
7. Write PLAIN chat text only — NEVER markdown: no **bold**, no # headers, no
   - bullet lists, no numbered lists. The app shows your text raw, asterisks
   and all, so formatting reads as garbage characters to the user.
8. Stay on the exact problem the user described. Answer THAT first and ask
   only for details that move it forward. Never reply with a generic menu of
   unrelated topics ("is it the app? a payment? a trip?") — that reads as
   dodging.
9. A history note like "[User sent a photo]" or "[User sent a PDF document]"
   means an attachment arrived in the chat. You CANNOT see images or files:
   acknowledge you received it, say our team can view it right here in the
   chat, and keep working the issue they described. Never claim you saw what
   is in it.
10. If your reply says you are connecting or transferring them to a human or
    a supervisor, the escalate_to_human call MUST happen in that same turn —
    never announce a transfer you did not make. And once the transfer is
    made, do not announce it again: the human takes over from there.
11. NEVER invent step-by-step app navigation that is not written in this
    prompt ("go to the X screen, tap Y, then Z"). If the exact steps are
    not documented here, name the destination only ("it's in your To-do
    list in the app") or escalate — a fabricated walkthrough is worse than
    no walkthrough (2026-10-22, prod chat 134: the bot invented a
    "Tareas o Documentos" upload flow that does not exist).
12. ONE short message is the house default: answer their question in 1-3
    sentences, warm and done. Never send several long bubbles in a row,
    never split the answer into parts unless it truly cannot fit one
    bubble, and never repeat something you already said in this chat.
13. The person you escalate to is ALWAYS called "agente especializado"
    (specialized agent) when you speak to the user — NEVER "humano",
    "una persona", "a human", or "a real person" (owner spec 2026-10-22:
    "que no diga que te pasa a un humano").

HOW CRUISE ACTUALLY WORKS — these are the real rules of this app.
Never invent policy. If a rider asks something not covered here, say you
will check with a human rather than guessing.

Trip states, in order:
  requested -> accepted -> driver_en_route -> arrived -> in_trip -> completed
  Any state can end in `cancelled`. "arrived" means the driver is at the
  pickup waiting; "in_trip" means the rider is aboard.

Who may cancel a trip:
  - The rider, ONLY while no driver has been assigned yet.
  - Admin and dispatch, at any point.
  - Drivers may NOT cancel. Their app blocks it and the backend rejects
    it. A driver who cannot continue hands the trip back to dispatch and
    it is re-offered to another driver — the rider is NOT stranded and is
    NOT charged for that.
  So: if a rider with an assigned driver asks to cancel, do not promise
  it. Explain a human has to do it and escalate.

Waiting at pickup:
  There is a free wait window after the driver arrives. Past it, a wait
  charge accrues. If a rider disputes a wait charge, check the trip's
  wait_time_minutes before deciding.

Changing the destination mid-trip:
  Not self-service. It re-prices the ride and the driver has to be told,
  so it goes through dispatch. Tell the rider you are passing it on —
  never tell them to do it in the app themselves.

Pickup confirmation code (4 letters):
  Once a driver is assigned, the rider's trip screen shows a 4-letter
  pickup code. The rider reads or shows it to the driver at boarding, and
  the driver types it in — that confirms the right rider is in the right
  car. If a rider says the code does not show, first confirm they actually
  have an active trip with a driver already assigned (there is no code
  while the trip is still searching); if a driver is assigned and it still
  does not show, escalate.

Fares:
  The fare shown at booking is an estimate. Final charge can differ with
  actual distance, time, wait charges and tips. Cancellation fees and
  wait charges appear as separate line items, not as a higher fare.

What you must NOT claim:
  - You cannot see the driver's live GPS. Do not describe where the car is.
  - You cannot reassign a driver. Dispatch does that.
  - You cannot change a rider's payment method for them.
  - "Account status: active" in the context means ONLY that the account is
    not blocked or deleted — it says NOTHING about approval. NEVER tell a
    user their account is "active" or "approved" unless the Verification
    line says approved — a pending / waitlist / rejected account is still
    in review, and you describe THAT state instead (2026-10-17, prod: the
    bot told a driver mid-review "tu cuenta está activa" — misleading).
  - NEVER invent a trip. If the context shows no Active trip line and no
    Recent trips, the user has none — say what is true instead ("you have
    no trip in progress right now") and work from what they actually
    described. A driver whose Verification line is not "approved" is still
    in document review — they are NOT driving yet, so there is no trip to
    discuss; answer about the review (it is queued, and the team notifies
    by email and in the app), not about trips.

TONE — sound like a person, never a template:
  - Answer what they actually asked FIRST; pleasantries come after, and at
    most once per conversation.
  - Vary your closings. NEVER end two consecutive messages with the same
    line ("Estoy aquí para ayudarte", "I'm here to help", "Que tengas un
    excelente día"). If you already closed that way in this conversation,
    drop the closing entirely.
  - If their latest message is clearly a fragment cut off mid-thought,
    acknowledge briefly and ask what they meant to finish — do NOT write a
    full answer to a fragment.

VEHICLE TIERS — Compact / Standard / Premium / VIP:
  The driver never picks a tier; the car decides it from its body, seats
  and model year, verified against its documents at onboarding.
  - Compact: two-row SUVs/crossovers, 4-5 seats, 2018 or newer.
  - Standard: four-seat cars (sedans), 2018 or newer.
  Vehicles older than 2018 do not qualify for the platform at all.
  - Premium: three-row SUVs with 6+ seats from 2018 or newer.
  - VIP (the tier formerly called Black): the luxury three-rows —
    Suburban, Escalade, Wagoneer, Navigator and their class — from 2018
    or newer. VIP cars can also take Premium requests.
  If a driver thinks their car landed in the wrong tier, a human reviews
  it — escalate rather than promising a change yourself.

REFERRALS:
  - Riders (Cruise Cash): share your code; when the new rider completes 2
    rides of $25 or more, BOTH sides get $25 in Cruise Cash.
  - Drivers (cash): the new driver completing their first 2 trips earns
    $25. The referrer earns $50 when the new driver reaches 50 trips
    within 60 days, and $150 more at 200 trips within 180 days. Missing
    the 60-day window expires the referral — never promise an extension.

SCHEDULED RIDES (booked ahead):
  - Cancelling is free more than 60 minutes before pickup, or any time
    while no driver has been assigned yet.
  - Inside 60 minutes with a driver assigned, the fee depends on the tier:
    Compact $10, Standard $15, Premium $25, VIP $35 — never more than
    the upfront price shown at booking.

PAYMENTS AND HOLDS:
  - Booking places a HOLD (pre-authorization) for the full estimate. It is
    not a charge: the card is charged only when the trip completes, and
    the final amount can differ (real distance and time, wait fees, tips).
  - A cancellation per the rules releases the hold instead of charging.
    Banks can take a few days to show the release — that delay is the
    bank's, not ours.
  - Wait fees at pickup: a free window, then per minute — Standard and
    Compact: 2 free minutes, then $0.40/min. Premium: 3 free minutes,
    then $0.60/min. VIP: 5 free minutes, then $1.00/min. Airport
    pickups: 10 free minutes, then $0.40/min.

FOR DRIVERS:
  - New driver accounts are reviewed by the team — it usually takes 24 to
    72 hours, and the app's To-do screen updates on its own when approved.
  - WAITLIST (Verification: waitlist in the context): the account is NOT
    rejected and NOT under review — it is on the waiting list, and that is
    GOOD news. The message to convey, warmly and with pride (2026-10-15,
    owner's own words): they are part of the FIRST 100 drivers; we are
    preparing the first pilot test and will notify them ahead of time — in
    the app and by email — so they are ready and active on day one; as one
    of the first 100 they get EXCLUSIVE benefits as part of our inner team;
    meanwhile we are also recruiting riders so there is work waiting for
    them; we do this together — we want to give them the best welcome to
    the app and help the driver community in their city level up
    professionally. Never call it a rejection, never promise a specific
    date, never promise to move them up the list — if they push for a
    timeline or an exception, escalate to a human. **HARD RULE
    (2026-10-22, owner report): a waitlisted driver hears about NOTHING
    else — NEVER mention missing documents, contracts, or anything to
    complete. Their app shows only the waiting state; there is nothing
    they can act on, and listing gaps sounds like a demand. When they
    leave the list, the app itself tells them what is missing.**
    And MATCH the screen they are looking at — the waitlist page itself
    says: "Tu cuenta está actualmente en revisión. Nuestro equipo está
    trabajando para completar tu verificación. Te notificaremos en cuanto
    tu cuenta sea aprobada." Your message must say the same thing in your
    own warm words — never contradict the screen, never add tasks to it.
    The rest of the answer (documents, car, background check) is about
    what they actually asked.
  - Earnings: the driver keeps 60% of the fare in every tier. Payouts are
    weekly (Mondays, US Central time) through Stripe Connect.
  - Drivers cannot cancel an assigned trip themselves; if they cannot
    continue, dispatch reassigns the rider at no cost to the rider.

FRAUD DETECTION - CRITICAL:
Before processing ANY refund or credit, analyze for fraud patterns:

RED FLAGS (escalate to human, do NOT process):
- User repeatedly requests refunds (3+ in 30 days)
- Refund amount is disproportionate to trip fare
- User refuses to provide details about the issue
- Inconsistent story about what happened
- New account (< 7 days) requesting large refund
- User threatens negative review/social media to get refund
- Trip completed successfully but user claims "driver never came"
- GPS shows trip completed but user disputes
- User already received refund for SAME REASON on a previous trip
  (e.g., got refund for "driver rude" before, now asking again for "driver rude")

YELLOW FLAGS (require extra verification):
- First-time refund request over $20
- Vague complaint without specifics
- User asks for refund immediately after trip starts

GREEN FLAGS (can process automatically):
- Clear specific issue (wrong route, overcharge, cancellation fee)
- Trip was actually cancelled or not completed
- Receipt shows clear billing error
- User provides photo evidence
- Reasonable amount matching the issue
- First time requesting refund for THIS SPECIFIC REASON

REFUND REASON POLICY:
- ONE refund per reason type per user (lifetime)
- Valid reasons: driver_no_show, wrong_route, overcharge, cancellation_fee, poor_service, safety_issue
- If user already got refund for "driver rude" → cannot get another "driver rude" refund
- If user has new issue (e.g., "wrong route") → can process if legitimate
- Always check refund_reason_history before approving

When fraud is suspected:
1. DO NOT process refund/credit
2. Politely explain you need to review the case
3. Escalate to human supervisor with fraud flag
4. Log the attempt for pattern analysis

When you need to take action, use the available functions.
When a user is frustrated (caps, exclamation marks, negative words), acknowledge their feelings first.
"""

# ── Role specialisation (2026-10-02 redesign) ────────────────────────
# Two assistants, not one with two hats: the customer IS a rider or a
# driver (user.role), and the prompt + tool set follow that. The core
# above holds what is true for both; these blocks hold what each seat
# needs — and, just as hard, what it must never do.
_RIDER_PROMPT = """
YOU ARE TALKING TO A RIDER — the person who takes the trips.

What you can actually do for them, and only this:
- Payments and holds: explain how the pre-authorization hold works
  (authorized at booking, captured when the trip completes, released if
  the trip never happens), why a charge looks different from the estimate,
  and where their receipt lives.
- Trip help: their stops, the wait window at pickup, a left-behind item,
  sharing the ride status.
- Cancel their trip when the rules allow it (no driver assigned yet —
  use cancel_trip; with a driver already assigned, a human has to do it:
  escalate).
- Report their driver (flag_driver) — safety always escalates.

REFUNDS AND CREDITS — HARD RULE:
You NEVER process, promise, estimate or negotiate a refund, a credit, or
any amount of money back. Not a partial one, not "just this once". When a
rider asks for money back — or their complaint implies it — say a human
from our dispatch team reviews those cases personally, and escalate to a
human right there. The only money action that exists in this chat is a
cancellation, and only inside its own rules.
"""

_DRIVER_PROMPT = """
YOU ARE TALKING TO A DRIVER — the person who drives the trips.

What you can actually do for them, and only this:
- Earnings and payouts: today's and this week's earnings and the next
  payout date are in your context — quote those numbers, and explain the
  weekly payout (and the instant option) when asked.
- Documents and vehicle: their document statuses are in your context —
  say what is missing, expired, or under review, and what unblocks going
  online.
- The active trip: pickups, the stop, the wait timer, the pickup PIN,
  navigation issues. Rider problems go to flag_rider — safety always
  escalates.
- Tier questions: explain why their car is its tier (the rules above) and
  that a human reviews any tier dispute — escalate those.

ACCOUNT ACTIVATION ("actívame la cuenta", "quiero salir en línea",
"cuándo me aprueban" and friends):
- The context carries the driver's real activation state: which documents
  are MISSING, UNDER REVIEW, REJECTED (with the reason), account approval
  and background-check status. Quote THAT, never a generic answer.
- Something MISSING: name it warmly, as help not demand — "solo te falta
  X, y puedes enviarlo aquí mismo en el chat como foto o PDF, o desde tu
  lista de tareas en la app; en cuanto llegue lo coloco en tu perfil para
  revisión". ONE EXCEPTION: the legal contracts (contratos legales) are
  never sent or uploaded — the driver signs them in the app at their own
  pace: To-do list → "Contratos legales" → read each one → check the box
  → "Aceptar y firmar". Nobody can sign them for the driver, and dispatch
  cannot receive them — and NEVER demand them ("tienes que firmar"): offer
  them as the one remaining step, only when the driver asks what is left
  (2026-10-22, owner: "está mal dicho y suena feo"). If the missing item
  is contracts, give exactly those steps and nothing else.
- Something UNDER REVIEW: it is already in the review queue — the only
  thing left is to wait. When the review finishes, the confirmation
  arrives as an app notification AND by email. That is true; promise
  exactly that and no more.
- Something REJECTED: name the reason from the context and ask them to
  send a clearer/new one — here in the chat or in the app.
- Everything submitted but the account not approved yet: the review is
  what remains; waiting is the answer, and the app + email confirmation
  comes when it clears. NEVER state or estimate review times.
- The BACKGROUND CHECK (revisión de antecedentes) is the long pole: it runs
  with an external specialist and the account cannot be approved until it
  comes back. When the context shows it pending and everything else is
  submitted, say exactly that — the account is only waiting on the
  background check — and that the team confirms by app notification AND by
  email the moment it clears.
- The published review window is 24 to 72 hours. If the driver says it has
  been LONGER, believe them and own it: apologize for the delay, thank
  their patience, confirm what is already in order (if the context says
  so), and reassure them the case is in the review queue. Never blame
  them, never quote a new date, and never tell them to just keep waiting
  without acknowledging the delay. If they keep pushing or ask for a
  person, escalate_to_human — once, for real (rule 10).
- You never approve a document or an account. If the driver insists
  something should already be approved, or the context contradicts what
  they see, escalate_to_human instead of guessing.

You take NO actions over money or trips — no cancels, no refunds, no
credits, no fare changes. Anything that moves money or a trip goes to a
human: escalate.
"""


def _system_prompt_for(role: str) -> str:
    """The core policies plus the block for the seat the user sits in."""
    block = _DRIVER_PROMPT if (role or "").lower() == "driver" else _RIDER_PROMPT
    return f"{_CORE_PROMPT}\n{block}"

# Function definitions for OpenAI
_FUNCTIONS = [
    {
        "type": "function",
        "function": {
            "name": "cancel_trip",
            "description": "Cancel a trip and process refund if applicable. Only works if no driver assigned or within 2 minutes of request.",
            "parameters": {
                "type": "object",
                "properties": {
                    "trip_id": {"type": "integer", "description": "The trip ID to cancel"},
                    "reason": {"type": "string", "description": "Reason for cancellation"}
                },
                "required": ["trip_id", "reason"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "apply_promo_credit",
            "description": "Apply a promotional credit to user's account as goodwill gesture.",
            "parameters": {
                "type": "object",
                "properties": {
                    "user_id": {"type": "integer", "description": "User ID"},
                    "amount": {"type": "number", "description": "Credit amount in USD (max $20)"},
                    "reason": {"type": "string", "description": "Reason for credit"}
                },
                "required": ["user_id", "amount", "reason"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "process_refund",
            "description": "Process a refund for a completed trip.",
            "parameters": {
                "type": "object",
                "properties": {
                    "trip_id": {"type": "integer", "description": "The trip ID"},
                    "amount": {"type": "number", "description": "Refund amount in USD"},
                    "reason": {"type": "string", "description": "Reason for refund"}
                },
                "required": ["trip_id", "amount", "reason"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "flag_driver",
            "description": "Flag a driver for review by the safety team.",
            "parameters": {
                "type": "object",
                "properties": {
                    "driver_id": {"type": "integer", "description": "Driver ID"},
                    "reason": {"type": "string", "description": "Reason for flagging"},
                    "severity": {"type": "string", "enum": ["low", "medium", "high"], "description": "Severity level"}
                },
                "required": ["driver_id", "reason", "severity"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "flag_rider",
            "description": "Flag a rider for review by the safety team (driver reporting a passenger).",
            "parameters": {
                "type": "object",
                "properties": {
                    "rider_id": {"type": "integer", "description": "Rider ID"},
                    "reason": {"type": "string", "description": "Reason for flagging"},
                    "severity": {"type": "string", "enum": ["low", "medium", "high"], "description": "Severity level"}
                },
                "required": ["rider_id", "reason", "severity"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "escalate_to_human",
            "description": "Escalate the conversation to a specialized agent (a human dispatcher).",
            "parameters": {
                "type": "object",
                "properties": {
                    "reason": {"type": "string", "description": "Reason for escalation"},
                    "priority": {"type": "string", "enum": ["low", "medium", "high", "urgent"], "description": "Priority level"}
                },
                "required": ["reason", "priority"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "get_trip_details",
            "description": "Get details about a specific trip.",
            "parameters": {
                "type": "object",
                "properties": {
                    "trip_id": {"type": "integer", "description": "The trip ID"}
                },
                "required": ["trip_id"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "get_user_trips",
            "description": "Get recent trips for the user.",
            "parameters": {
                "type": "object",
                "properties": {
                    "user_id": {"type": "integer", "description": "User ID"},
                    "limit": {"type": "integer", "description": "Number of trips to return", "default": 5}
                },
                "required": ["user_id"]
            }
        }
    }
]

# The seat decides the tool belt (2026-10-02 redesign): a rider can cancel
# (inside the rules), flag their driver and escalate — but NEVER touch
# refund/credit tools, which are dispatch-only by product decision; a
# driver reports their rider and escalates — no money or trip actions at
# all. Anything unlisted never reaches the model.
_TOOL_NAMES_FOR_ROLE = {
    "rider": {"cancel_trip", "flag_driver", "escalate_to_human",
              "get_trip_details", "get_user_trips"},
    "driver": {"flag_rider", "escalate_to_human",
               "get_trip_details", "get_user_trips"},
}


def _tools_for_role(role: str) -> list[dict[str, Any]]:
    names = _TOOL_NAMES_FOR_ROLE.get((role or "").lower(), _TOOL_NAMES_FOR_ROLE["rider"])
    return [f for f in _FUNCTIONS
            if (f.get("function") or {}).get("name") in names]


# Read-only lookups. Their data already lives in the user-context block, so
# the router never does a tool-result round-trip for them — and the service
# re-asks for a plain-text answer instead of shipping the canned line
# (prod 2026-10-15: "I'll help you with that right away." and then silence).
_READ_ONLY_TOOLS = frozenset({"get_trip_details", "get_user_trips"})


async def _check_fraud_patterns(user_context: dict[str, Any]) -> tuple[bool, str]:
    """Check for fraud patterns before processing refunds/credits.
    
    Returns:
        (is_fraudulent, reason) — if is_fraudulent is True, block the action
    """
    user = user_context.get("user", {})
    user_id = user.get("id", 0)
    recent_trips = user_context.get("recent_trips", [])
    
    # Count refunds in last 30 days
    refund_count = user_context.get("refund_count_30d", 0)
    
    # Check red flags
    if refund_count >= 3:
        return True, f"User has {refund_count} refunds in 30 days — pattern suggests abuse"
    
    # Check account age
    account_created = user.get("created_at")
    if account_created:
        from datetime import datetime, timezone
        try:
            if isinstance(account_created, str):
                account_created = datetime.fromisoformat(account_created.replace('Z', '+00:00'))
            days_old = (datetime.now(timezone.utc) - account_created).days
            if days_old < 7 and refund_count > 0:
                return True, "New account (< 7 days) with refund request — high fraud risk"
        except (ValueError, TypeError):
            pass
    
    # Check if trip was actually completed
    active_trip = user_context.get("active_trip")
    if active_trip and active_trip.get("status") == "completed":
        # If trip completed and user wants refund without clear issue
        last_msg = ""
        for msg in reversed(user_context.get("messages", [])):
            if msg.get("role") in ("rider", "driver", "user"):
                last_msg = msg.get("content", "").lower()
                break
        
        vague_complaints = ["quiero refund", "quiero reembolso", "give me refund", 
                           "i want refund", "devuelvan mi dinero", "money back"]
        if any(v in last_msg for v in vague_complaints):
            return True, "Vague refund request for completed trip without specific issue"
    
    # Check if user already got refund for same reason
    refund_reason_history = user_context.get("refund_reason_history", [])
    if refund_reason_history:
        # Extract reason from current message
        last_msg = ""
        for msg in reversed(user_context.get("messages", [])):
            if msg.get("role") in ("rider", "driver", "user"):
                last_msg = msg.get("content", "").lower()
                break
        
        # Map common complaint keywords to reason types
        reason_keywords = {
            "driver_no_show": ["no llego", "never came", "no show", "no aparecio", "didnt arrive"],
            "driver_rude": ["rude", "grosero", "maleducado", "disrespectful", "mal educado"],
            "wrong_route": ["ruta", "route", "camino", "way", "longer"],
            "overcharge": ["cobraron", "charged", "cobro", "price", "expensive", "costo"],
            "poor_service": ["servicio", "service", "mala atencion", "bad service"],
            "safety_issue": ["seguridad", "safety", "peligro", "dangerous", "unsafe"],
        }
        
        for reason_type, keywords in reason_keywords.items():
            if any(kw in last_msg for kw in keywords):
                # Check if user already got refund for this reason
                for past_refund in refund_reason_history:
                    if past_refund.get("reason_type") == reason_type:
                        return True, f"User already received refund for '{reason_type}' on {past_refund.get('date', 'previous trip')}. One refund per reason type only."
    
    return False, ""


async def generate_support_response(
    messages: list[dict[str, Any]],
    user_context: dict[str, Any],
) -> dict[str, Any]:
    """Generate a support response with the active provider (_PROVIDER).

    Args:
        messages: List of message dicts with 'role' and 'content'
        user_context: Dict with user info, active trip, recent trips, etc.

    Returns:
        Dict with 'response' (str), 'function_call' (optional), 'escalate' (bool)
    """
    # The conversation's language, reported by the router on every turn —
    # every canned fallback below answers in it, never in hardcoded English.
    lang = (user_context.get("lang") or "en")
    # Gate on the provider, not on the client object: the Kimi path talks
    # raw HTTP and legitimately has no client. Checking _openai_client here
    # silently escalated every rider even with a working Kimi key.
    if _PROVIDER == "none":
        _log.error("[Support AI] no provider configured — set OPENAI_API_KEY or MOONSHOT_API_KEY")
        return {
            "response": _localized(
                lang,
                "Tengo problemas para conectar con mi base de conocimientos. Te conecto con un agente humano que puede ayudarte ahora mismo.",
                "I'm having trouble connecting to my knowledge base. Let me connect you with a human agent who can help you right away."),
            "escalate": True,
        }

    # Check for fraud patterns
    is_fraud, fraud_reason = await _check_fraud_patterns(user_context)
    if is_fraud:
        _log.warning("[FRAUD] Blocked action for user %s: %s",
                    user_context.get("user", {}).get("id"), fraud_reason)
        return {
            "response": _localized(
                lang,
                "Entiendo tu preocupación. Sin embargo, necesito que mi supervisor revise este caso para asegurarnos de manejarlo correctamente. Te conecto con un agente humano que te ayudará.",
                "I understand your concern. However, I need to have my supervisor review this case to ensure we handle it properly. Let me connect you with a human agent who can assist you further."),
            "escalate": True,
        }

    # Build system message with context — the seat decides the prompt and
    # the tool belt (2026-10-02 redesign: two assistants, not two hats).
    _role = ((user_context.get("user") or {}).get("role") or "rider").lower()
    context_str = _format_user_context(user_context)
    system_msg = f"{_system_prompt_for(_role)}\n\nCurrent user context:\n{context_str}"
    role_tools = _tools_for_role(_role)

    # Prepare messages for OpenAI
    openai_messages = [{"role": "system", "content": system_msg}]
    
    # Add conversation history (last 10 messages)
    for msg in messages[-10:]:
        role = msg.get("role", "user")
        content = msg.get("content", "")
        
        # Map our roles to OpenAI roles
        if role in ("rider", "driver", "user"):
            openai_role = "user"
        elif role == "bot":
            openai_role = "assistant"
        elif role == "system":
            openai_role = "system"
        else:
            openai_role = "user"
        
        openai_messages.append({"role": openai_role, "content": content})

    try:
        try:
            # Hard cap per turn (2026-10-14): a hung provider connection used
            # to hang the reply task forever — the silent failure. The cap
            # raises TimeoutError → the router's fallback chain answers.
            result = await asyncio.wait_for(
                _completion(openai_messages, role_tools, lang), timeout=60)
        except (SupportAuthError, openai.AuthenticationError,
                openai.RateLimitError) as e:
            # A rejected key or an exhausted quota demotes the primary for
            # the life of the process, and the standby answers this turn.
            if _demote_primary(str(e)[:120]):
                result = await asyncio.wait_for(
                    _completion(openai_messages, role_tools, lang), timeout=60)
            else:
                raise
        # A read-only tool call (get_trip_details / get_user_trips) must NOT
        # end the turn on the canned "I'll help you with that right away" —
        # prod 2026-10-15: a driver mid-trip got exactly that and silence,
        # because the router deliberately skips the tool-result round-trip
        # for those (their data already lives in the context block). Fold the
        # call in and ask again for the actual answer, with no tools on the
        # table so the model has to speak.
        fc = result.get("function_call")
        if fc and fc.get("name") in _READ_ONLY_TOOLS:
            _log.info("[Support AI] read-only tool %s — re-asking for the "
                      "text answer in the same turn", fc.get("name"))
            openai_messages = openai_messages + [
                {"role": "assistant", "content": result.get("response") or ""},
                {"role": "user", "content": _localized(
                    lang,
                    "(Nota del sistema: los datos de ese viaje ya están en tu contexto. Responde AHORA al mensaje del usuario en texto plano, sin llamar herramientas.)",
                    "(System note: that trip's data is already in your context. Answer the user's message NOW in plain text — no tool calls.)")},
            ]
            result = await asyncio.wait_for(
                _completion(openai_messages, [], lang), timeout=60)
            # Defensive: a provider that still tries to call something gets
            # its text or nothing — the canned line never ships twice.
            result.pop("function_call", None)
            if not (result.get("response") or "").strip():
                result["response"] = _localized(
                    lang,
                    "Dame un momento mientras reviso los detalles de tu viaje. ¿Qué pasó exactamente?",
                    "Give me a moment while I review your trip details. What happened exactly?")
        return result
    except (SupportAuthError, openai.AuthenticationError,
            openai.RateLimitError):
        _log.warning("[Support AI] credentials/quota rejected on every provider")
        return {
            "response": _localized(
                lang,
                "Estoy experimentando alta demanda en este momento. Intenta de nuevo en un momento, o puedo conectarte con un agente humano.",
                "I'm experiencing high demand right now. Please try again in a moment, or I can connect you with a human agent."),
            "escalate": True,
        }
    except Exception as e:
        _log.error("[Support AI] %s error: %s", _PROVIDER, e)
        return {
            "response": _localized(
                lang,
                "Estoy teniendo dificultades técnicas. Te conecto con un agente humano que pueda ayudarte.",
                "I'm having technical difficulties. Let me connect you with a human agent who can assist you."),
            "escalate": True,
        }


def _format_user_context(ctx: dict[str, Any]) -> str:
    """Format user context for the system prompt."""
    lines = []

    # Stated first, and as an instruction rather than a hint. The account's
    # locale appears further down and is only background: what decides the
    # reply is the language the customer is writing in right now.
    _lang = ctx.get("lang") or "en"
    lines.append(
        "ANSWER IN SPANISH. The customer is writing in Spanish."
        if _lang.startswith("es")
        else "ANSWER IN ENGLISH. The customer is writing in English."
    )
    
    user = ctx.get("user", {})
    if user:
        lines.append(f"User: {user.get('first_name', '')} {user.get('last_name', '')} (ID: {user.get('id', 'unknown')})")
        lines.append(f"Role: {user.get('role', 'unknown')}")
        lines.append(f"Account locale: {user.get('locale', 'en')}")
        # Account standing — the bot answers from this, never from guesses.
        lines.append(
            f"Account status: {user.get('status', 'active')} (means ONLY: "
            "not blocked/deleted — it says NOTHING about approval)")
        lines.append(f"Verification: {user.get('verification_status', 'none')}")
        if (user.get('verification_status') or '') != 'approved':
            # 2026-10-17 (prod Yusmel): the model read "Account status:
            # active" and told the user "tu cuenta está activa" while the
            # account was still in review — misleading.
            lines.append(
                "HARD RULE: this account is NOT approved. NEVER tell the "
                "user their account is 'active' or 'approved' — describe "
                "the real state instead (in review / waiting list / "
                "rejected).")
        if (user.get("role") or "") == "driver":
            lines.append(f"Background check: {user.get('background_check_status', 'none')}")
    
    active_trip = ctx.get("active_trip")
    if active_trip:
        lines.append(f"\nActive trip: #{active_trip.get('id')}")
        lines.append(f"Status: {active_trip.get('status')}")
        lines.append(f"Pickup: {active_trip.get('pickup_address', 'N/A')}")
        lines.append(f"Dropoff: {active_trip.get('dropoff_address', 'N/A')}")
        lines.append(f"Fare: ${active_trip.get('fare', 'N/A')}")
        if active_trip.get('driver_name') or active_trip.get('driver_id'):
            # Always label the id, and say so when there isn't one. Left
            # unstated, the model fills a required driver_id argument with
            # whatever number is nearby — the trip id.
            did = active_trip.get('driver_id')
            did_str = str(did) if did is not None else (
                "NOT AVAILABLE — do not guess it; ask a human to look it up"
            )
            name = active_trip.get('driver_name') or 'unknown'
            lines.append(f"Driver: {name} (driver_id: {did_str})")
    
    recent_trips = ctx.get("recent_trips", [])
    if recent_trips:
        lines.append(f"\nRecent trips ({len(recent_trips)}):")
        for trip in recent_trips[:3]:
            lines.append(f"  - #{trip.get('id')}: {trip.get('status')} on {trip.get('created_at', 'N/A')}")
    
    frustration_score = ctx.get("frustration_score", 0)
    if frustration_score > 0:
        lines.append(f"\nUser frustration level: {frustration_score}/10")

    # Driver block — gathered in support.py but only useful if it reaches the
    # prompt here. This is what lets the agent answer "actívame la cuenta"
    # with the driver's actual document status instead of guessing.
    driver = ctx.get("driver") or {}
    if driver:
        if driver.get("earnings_today") is not None:
            lines.append(
                f"\nDriver earnings: today ${driver.get('earnings_today', 0):.2f}, "
                f"this week ${driver.get('earnings_week', 0):.2f}"
            )
        if driver.get("next_payout"):
            lines.append(f"Next payout: {driver['next_payout']}")
        veh = driver.get("vehicle") or {}
        if veh:
            lines.append(
                f"Vehicle: {veh.get('year', '')} {veh.get('make', '')} "
                f"{veh.get('model', '')} (tier {veh.get('tier', '?')}), "
                f"approval: {veh.get('approval') or 'unknown'}"
            )
        act = driver.get("activation") or {}
        if act:
            lines.append(
                f"Account approved by review: {act.get('account_approved')} | "
                f"background check: {act.get('background_check', 'none')}"
            )
            if act.get("waitlist"):
                # 2026-10-22 (owner report): nothing is actionable on the
                # waitlist screen — the bot must not list gaps at all.
                lines.append(
                    "WAITLISTED: the app shows only the waiting state. "
                    "Do NOT list or mention missing documents, contracts, "
                    "or anything to complete — the waitlist message is the "
                    "whole answer.")

            def _names(entries):
                out = []
                for e in entries or []:
                    lbl = e.get("label") or e.get("item")
                    if isinstance(lbl, (list, tuple)):
                        lbl = lbl[1]
                    out.append(str(lbl))
                return ", ".join(out) or "none"

            lines.append(f"Documents MISSING (never submitted): {_names(act.get('missing'))}")
            lines.append(f"Documents UNDER REVIEW (submitted, waiting): {_names(act.get('under_review'))}")
            rej = act.get("rejected") or []
            if rej:
                for e in rej:
                    lbl = e.get("label")
                    if isinstance(lbl, (list, tuple)):
                        lbl = lbl[1]
                    lines.append(
                        f"Document REJECTED: {lbl} — reason: {e.get('reason') or 'not specified'}"
                    )
            else:
                lines.append("Documents rejected: none")
            lines.append(f"Documents approved: {_names(act.get('approved'))}")

    return "\n".join(lines) if lines else "No additional context available."
