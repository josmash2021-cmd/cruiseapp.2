"""LLM-powered support chat service for CruiseApp.

Replaces the rule-based keyword bot with a chat model for human-like
responses, plus function calling for autonomous actions (cancel trip,
apply promo, escalate...).

Provider
--------
OpenAI (GPT) when OPENAI_API_KEY is set, Kimi (Moonshot AI) when only
MOONSHOT_API_KEY is set. Whichever key is configured second stands by: a
primary whose key is rejected or out of quota demotes to it at request
time (_demote_primary), loudly, instead of falling through to the
rule-based replies in cruise_ai_engine.

There is no fine-tuning involved for either. What makes this agent good
or bad at Cruise support is _SYSTEM_PROMPT below: the app's real
policies, written down so the model does not invent them.
"""

import json
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

# Phrases that mean the agent has already offered a human. Shared by both
# provider paths so "escalate" means the same thing whoever answered.
_ESCALATION_PHRASES = (
    "connect you with a human", "supervisor", "human agent",
    "connect you with a supervisor", "transfer you to",
)

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

# OpenAI first, Kimi behind it.
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


def _anthropic_tools() -> list[dict[str, Any]]:
    """The same tools, in Anthropic's Messages shape.

    OpenAI nests them under `function` with a `parameters` schema; Anthropic
    puts `name`/`description` at the top level and calls the schema
    `input_schema`. Converted here rather than maintained twice, so a tool
    added to _FUNCTIONS reaches both providers.
    """
    out: list[dict[str, Any]] = []
    for f in _FUNCTIONS:
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


async def _anthropic_completion(messages: list[dict[str, Any]]) -> dict[str, Any]:
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
        body["tools"] = _anthropic_tools()

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
        raise SupportAuthError(
            f"kimi rejected the key: {resp.text[:120]}",
            response=resp, body=None,
        )
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
                "response": text or "I'll help you with that right away.",
                "function_call": {
                    "name": b.get("name", ""),
                    "arguments": b.get("input") or {},
                },
                "escalate": False,
            }

    return {
        "response": text,
        "escalate": any(kw in text.lower() for kw in _ESCALATION_PHRASES),
    }


async def _openai_completion(messages: list[dict[str, Any]]) -> dict[str, Any]:
    """One turn against OpenAI's chat completions.

    Returns the same {response, function_call?, escalate} dict the Kimi
    path returns, so the caller cannot tell which provider answered.
    """
    global _TOOLS_UNSUPPORTED
    extra = {} if _TOOLS_UNSUPPORTED else {
        "tools": _FUNCTIONS,
        "tool_choice": "auto",
    }
    try:
        resp = await _openai_client.chat.completions.create(
            model=_MODEL,
            messages=messages,
            max_tokens=800,
            temperature=0.7,
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
        )

    message = resp.choices[0].message
    if message.tool_calls:
        call = message.tool_calls[0]
        _log.info("[Support AI] openai tool call: %s", call.function.name)
        return {
            "response": message.content or "I'll help you with that right away.",
            "function_call": {
                "name": call.function.name,
                "arguments": json.loads(call.function.arguments or "{}"),
            },
            "escalate": False,
        }

    text = (message.content or "").strip()
    return {
        "response": text,
        "escalate": any(kw in text.lower() for kw in _ESCALATION_PHRASES),
    }


async def _completion(messages: list[dict[str, Any]]) -> dict[str, Any]:
    """The active provider answers one turn. Both paths return the same
    dict, so switching providers mid-process (demote) is invisible here."""
    if _PROVIDER == "kimi":
        return await _anthropic_completion(messages)
    return await _openai_completion(messages)


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
_SYSTEM_PROMPT = """You are Cruise Support, an AI assistant for a premium ride-sharing app called Cruise.

Your personality:
- Professional but warm and friendly
- Empathetic when users are frustrated
- Concise but thorough
- Bilingual: answer in the language stated at the top of the context, which is the one the customer just wrote in — never switch on your own

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

Fares:
  The fare shown at booking is an estimate. Final charge can differ with
  actual distance, time, wait charges and tips. Cancellation fees and
  wait charges appear as separate line items, not as a higher fare.

What you must NOT claim:
  - You cannot see the driver's live GPS. Do not describe where the car is.
  - You cannot reassign a driver. Dispatch does that.
  - You cannot change a rider's payment method for them.

VEHICLE TIERS — Compact / Standard / Premium / Black:
  The driver never picks a tier; the car decides it from its body, seats
  and model year, verified against its documents at onboarding.
  - Compact: two-row SUVs/crossovers, 4-5 seats, roughly 2016 or newer.
  - Standard: sedans and SUVs roughly 2012-2016, and anything older that
    still qualifies to drive.
  - Premium: three-row SUVs with 6+ seats from 2020 or newer, and sedans
    from 2021 or newer.
  - Black: large SUVs with 7+ seats from 2022 or newer (Escalade,
    Suburban, Navigator...). Black cars can also take Premium requests.
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
    Compact $10, Standard $15, Premium $25, Black $35 — never more than
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
    then $0.60/min. Black: 5 free minutes, then $1.00/min. Airport
    pickups: 10 free minutes, then $0.40/min.

FOR DRIVERS:
  - New driver accounts are reviewed by the team — it usually takes 24 to
    72 hours, and the app's To-do screen updates on its own when approved.
  - Earnings: the driver keeps 70% of the fare in every tier. Payouts are
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
            "name": "escalate_to_human",
            "description": "Escalate the conversation to a human supervisor.",
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
    # Gate on the provider, not on the client object: the Kimi path talks
    # raw HTTP and legitimately has no client. Checking _openai_client here
    # silently escalated every rider even with a working Kimi key.
    if _PROVIDER == "none":
        _log.error("[Support AI] no provider configured — set OPENAI_API_KEY or MOONSHOT_API_KEY")
        return {
            "response": "I'm having trouble connecting to my knowledge base. Let me connect you with a human agent who can help you right away.",
            "escalate": True,
        }

    # Check for fraud patterns
    is_fraud, fraud_reason = await _check_fraud_patterns(user_context)
    if is_fraud:
        _log.warning("[FRAUD] Blocked action for user %s: %s", 
                    user_context.get("user", {}).get("id"), fraud_reason)
        return {
            "response": "I understand your concern. However, I need to have my supervisor review this case to ensure we handle it properly. Let me connect you with a human agent who can assist you further.",
            "escalate": True,
        }

    # Build system message with context
    context_str = _format_user_context(user_context)
    system_msg = f"{_SYSTEM_PROMPT}\n\nCurrent user context:\n{context_str}"

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
            return await _completion(openai_messages)
        except (SupportAuthError, openai.AuthenticationError,
                openai.RateLimitError) as e:
            # A rejected key or an exhausted quota demotes the primary for
            # the life of the process, and the standby answers this turn.
            if _demote_primary(str(e)[:120]):
                return await _completion(openai_messages)
            raise
    except (SupportAuthError, openai.AuthenticationError,
            openai.RateLimitError):
        _log.warning("[Support AI] credentials/quota rejected on every provider")
        return {
            "response": "I'm experiencing high demand right now. Please try again in a moment, or I can connect you with a human agent.",
            "escalate": True,
        }
    except Exception as e:
        _log.error("[Support AI] %s error: %s", _PROVIDER, e)
        return {
            "response": "I'm having technical difficulties. Let me connect you with a human agent who can assist you.",
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
    
    return "\n".join(lines) if lines else "No additional context available."
