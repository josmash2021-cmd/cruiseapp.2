---
applyTo: "backend/**/*.py"
---

# Python/FastAPI Backend Rules

- **async def** on ALL FastAPI endpoints
- **Auth guard**: `Depends(get_current_user)` on every protected endpoint
- **try/except** on EVERY Supabase call → raise `HTTPException` with proper status code
- **Pydantic v2** models for all request/response bodies
- **No raw SQL** — use Supabase client methods, never f-string interpolation
- **ASCII quotes only** — NEVER smart/curly quotes (caused real production bug)
- **Logging**: `logging.info/warning/error`, NEVER `print()`
- **Timestamps**: `datetime.now(timezone.utc)` or `utc_now()` helper
- **Status spelling**: `cancelled` with double L, never `canceled`
- **Status transitions**: always validate against `_VALID_TRANSITIONS` and normalize with `_STATUS_ALIASES`
- **Lock order**: when touching `trips` AND `dispatch_offers`, always lock `trips` first
