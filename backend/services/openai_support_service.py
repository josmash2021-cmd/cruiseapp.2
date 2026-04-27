"""OpenAI-powered support chat service for CruiseApp.

Replaces the rule-based keyword bot with GPT-4o for human-like responses.
Includes function calling for autonomous actions (cancel trip, apply promo, etc.)
"""

import json
import logging
import os
from typing import Any

import openai

_log = logging.getLogger(__name__)

# Initialize OpenAI client
_OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "")
_openai_client = None

if _OPENAI_API_KEY:
    _openai_client = openai.AsyncOpenAI(api_key=_OPENAI_API_KEY)

# Model configuration
_MODEL = "gpt-4o-mini"  # Cost-effective, fast, capable
# _MODEL = "gpt-4o"     # Uncomment for higher quality (more expensive)

# System prompt for Cruise support agent
_SYSTEM_PROMPT = """You are Cruise Support, an AI assistant for a premium ride-sharing app called Cruise.

Your personality:
- Professional but warm and friendly
- Empathetic when users are frustrated
- Concise but thorough
- Bilingual: respond in the user's language (English or Spanish)

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
        except:
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
    """Generate a support response using OpenAI GPT-4o.
    
    Args:
        messages: List of message dicts with 'role' and 'content'
        user_context: Dict with user info, active trip, recent trips, etc.
    
    Returns:
        Dict with 'response' (str), 'function_call' (optional), 'escalate' (bool)
    """
    if not _openai_client:
        _log.error("OpenAI client not initialized — OPENAI_API_KEY missing")
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
        response = await _openai_client.chat.completions.create(
            model=_MODEL,
            messages=openai_messages,
            tools=_FUNCTIONS,
            tool_choice="auto",
            max_tokens=500,
            temperature=0.7,
        )

        message = response.choices[0].message

        # Check if the model wants to call a function
        if message.tool_calls:
            tool_call = message.tool_calls[0]
            function_name = tool_call.function.name
            function_args = json.loads(tool_call.function.arguments)
            
            _log.info("[OpenAI] Function call: %s(%s)", function_name, function_args)
            
            return {
                "response": message.content or "I'll help you with that right away.",
                "function_call": {
                    "name": function_name,
                    "arguments": function_args,
                },
                "escalate": False,
            }

        # Check for implicit escalation keywords
        content = message.content or ""
        escalate = any(kw in content.lower() for kw in [
            "connect you with a human", "supervisor", "human agent",
            "connect you with a supervisor", "transfer you to",
        ])

        return {
            "response": content,
            "escalate": escalate,
        }

    except openai.RateLimitError:
        _log.warning("[OpenAI] Rate limit exceeded")
        return {
            "response": "I'm experiencing high demand right now. Please try again in a moment, or I can connect you with a human agent.",
            "escalate": True,
        }
    except openai.APIError as e:
        _log.error("[OpenAI] API error: %s", e)
        return {
            "response": "I'm having technical difficulties. Let me connect you with a human agent who can assist you.",
            "escalate": True,
        }
    except Exception as e:
        _log.error("[OpenAI] Unexpected error: %s", e)
        return {
            "response": "Something went wrong on my end. Let me get a human to help you.",
            "escalate": True,
        }


def _format_user_context(ctx: dict[str, Any]) -> str:
    """Format user context for the system prompt."""
    lines = []
    
    user = ctx.get("user", {})
    if user:
        lines.append(f"User: {user.get('first_name', '')} {user.get('last_name', '')} (ID: {user.get('id', 'unknown')})")
        lines.append(f"Role: {user.get('role', 'unknown')}")
        lines.append(f"Language preference: {user.get('locale', 'en')}")
    
    active_trip = ctx.get("active_trip")
    if active_trip:
        lines.append(f"\nActive trip: #{active_trip.get('id')}")
        lines.append(f"Status: {active_trip.get('status')}")
        lines.append(f"Pickup: {active_trip.get('pickup_address', 'N/A')}")
        lines.append(f"Dropoff: {active_trip.get('dropoff_address', 'N/A')}")
        lines.append(f"Fare: ${active_trip.get('fare', 'N/A')}")
        if active_trip.get('driver_name'):
            lines.append(f"Driver: {active_trip['driver_name']}")
    
    recent_trips = ctx.get("recent_trips", [])
    if recent_trips:
        lines.append(f"\nRecent trips ({len(recent_trips)}):")
        for trip in recent_trips[:3]:
            lines.append(f"  - #{trip.get('id')}: {trip.get('status')} on {trip.get('created_at', 'N/A')}")
    
    frustration_score = ctx.get("frustration_score", 0)
    if frustration_score > 0:
        lines.append(f"\nUser frustration level: {frustration_score}/10")
    
    return "\n".join(lines) if lines else "No additional context available."
