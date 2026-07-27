# Masked Rider↔Driver Calls (Twilio Voice Bridge)

Real phone numbers are never exposed between rider and driver. Both sides dial
the company's Twilio number with a short-lived 6-digit extension; the backend
bridges the call with `<Dial callerId=<twilio_number>>`, so both parties only
ever see the Twilio number.

## Flow

1. App: `GET /trips/{trip_id}/masked-contact?role=rider|driver` (JWT + API key).
   Validates the caller is a party to the trip and the trip is active.
   Returns `{phone_number, extension, expires_in}` — never a real number.
2. App dials `tel:<phone_number>,,,<extension>` (commas = pauses; the dialer
   auto-sends the extension as DTMF once connected).
3. Twilio webhook `POST /voice/bridge` (`backend/routers/masked_calls.py`)
   collects the extension, re-validates the trip, verifies the caller's
   `From` matches the party the extension was issued to, and returns TwiML
   `<Dial callerId=...>` to the counterparty's real number.

Guest riders (no app) are supported on the driver side: the bridge dials
`trip.guest_phone`. Guest SMS no longer contains the driver's phone number.

## Twilio console configuration (one-time)

1. Buy a **dedicated** Twilio number for masked calls. Do **not** reuse the
   support IVR number — a Twilio number has a single voice webhook, and the
   support line already points at `/voice/incoming`.
2. Set env var `TWILIO_PROXY_PHONE_NUMBER=<that number, E.164>`
   (falls back to `TWILIO_PHONE_NUMBER` when unset — dev only).
3. Twilio console → Phone Numbers → the masked-calls number → Voice & Fax:
   - **"A call comes in"** → Webhook: `POST {PUBLIC_URL}/voice/bridge`
   - No TwiML App, no Proxy product needed.
4. Signature validation (`X-Twilio-Signature`) reuses `TWILIO_AUTH_TOKEN`,
   same as `routers/voice.py`.

## Limitations

- Extension codes live in an in-memory `TTLCache` (same pattern as the voice
  IVR sessions). Single-process deployments only; move `_bridge_codes` to
  Redis if the backend ever runs multiple workers.
- Auto-DTMF via commas in `tel:` URIs works on stock Android/iOS dialers. If
  a dialer drops the pauses, the caller hears a bilingual prompt asking for
  the 6-digit code — currently there is no in-app UI showing the code, so in
  that rare case the call simply fails and the user can retry.
