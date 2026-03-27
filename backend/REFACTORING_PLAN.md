# main.py Refactoring Plan
## Analysis of 10,205-line monolith → modular routers

---

## 1. ENDPOINTS BY DOMAIN (194 total)

### Group "health" (3 endpoints)
- GET /health (line 1244)
- GET /health/security (line 1289)
- GET /health/guardian (line 1308)

### Group "auth" (24 endpoints)
- POST /auth/fcm-token (line 1704)
- POST /auth/register (line 1895)
- POST /auth/check-exists (line 1988)
- POST /auth/login (line 1997)
- POST /auth/send-otp (line 2084)
- POST /auth/verify-otp (line 2248)
- POST /auth/resend-email-verification (line 2304)
- POST /auth/verify-email (line 2360)
- POST /auth/complete-login (line 2386)
- POST /auth/social (line 2406)
- POST /auth/refresh (line 2501)
- GET /auth/me (line 2528)
- POST /auth/offline (line 2544)
- PATCH /auth/me (line 2562)
- POST /auth/photo (line 2656)
- POST /auth/photo-url (line 2723)
- DELETE /auth/me (line 2839)
- GET /auth/export-data (line 2864)
- POST /auth/consent (line 2959)
- POST /auth/verify-request (line 3004)
- GET /auth/verification-status (line 3166)
- GET /auth/driver-approval-status (line 3197)
- GET /auth/account-status (line 3287)
- POST /auth/forgot-password (line 7822)
- GET /auth/reset-page (line 7885)
- POST /auth/reset-password-web (line 7966)
- POST /auth/reset-password (line 7996)

### Group "users" (4 endpoints)
- POST /users/me/photo (line 2753)
- GET /photos/{filename} (line 2826)
- GET /users/{user_id}/ratings (line 5186)
- GET /uploads/documents/{filename} (line 8872)

### Group "trips" (20 endpoints)
- POST /trips (line 3353)
- GET /trips/{trip_id} (line 3392)
- GET /trips/available (line 3403)
- POST /trips/{trip_id}/accept (line 3417)
- POST /trips/{trip_id}/charge (line 3493)
- POST /trips/{trip_id}/refund (line 3510)
- GET /trips/{trip_id}/fare-breakdown (line 3560)
- PATCH /trips/{trip_id}/status (line 3642)
- GET /trips/scheduled/rider/{rider_id} (line 3716)
- GET /trips/scheduled/driver/{driver_id} (line 3728)
- POST /trips/{trip_id}/cancel (line 3740)
- POST /trips/{trip_id}/share (line 5028)
- GET /trips/shared/{token} (line 5066)
- GET /trips/shared/{token}/location (line 5093)
- GET /track/{token} (line 5122)
- POST /trips/{trip_id}/rate (line 5138)
- POST /trips/{trip_id}/chat (line 5210)
- GET /trips/{trip_id}/chat (line 5244)
- POST /trips/{trip_id}/tip (line 9443)
- POST /trips/{trip_id}/split (line 9501)
- POST /trips/{trip_id}/split/{split_id}/respond (line 9556)
- GET /trips/{trip_id}/splits (line 9590)
- POST /trips/{trip_id}/waypoints (line 9618)
- DELETE /trips/{trip_id}/waypoints/{index} (line 9651)
- PATCH /trips/{trip_id}/preferences (line 9681)
- POST /trips/{trip_id}/wait-time/start (line 10494)
- POST /trips/{trip_id}/wait-time/end (line 10507)

### Group "drivers" (24 endpoints)
- PATCH /drivers/{driver_id}/location (line 3778)
- GET /drivers/nearby (line 3801)
- GET /drivers/{driver_id}/trips (line 3824)
- GET /drivers/earnings (line 3836)
- POST /drivers/stripe-connect (line 3896)
- GET /drivers/stripe-connect/status (line 3928)
- POST /drivers/cashout (line 3947)
- GET /drivers/cashouts (line 4008)
- GET /drivers/payouts/next-date (line 4013)
- GET /drivers/payout-methods (line 4127)
- POST /drivers/payout-methods (line 4132)
- DELETE /drivers/payout-methods/{payout_id} (line 4140)
- GET /drivers/{driver_id}/stats (line 4398)
- GET /drivers/vehicle (line 4727)
- POST /drivers/vehicle (line 4735)
- GET /drivers/documents (line 4775)
- POST /drivers/documents (line 4783)
- POST /drivers/{driver_id}/background-check (line 4853)
- GET /drivers/{driver_id}/background-check/status (line 4915)
- POST /drivers/background-check (line 4937, 10779)
- GET /drivers/background-check/status (line 4947)
- POST /drivers/stripe-connect/onboard (line 9140)
- POST /drivers/payout/transfer (line 9171)
- GET /drivers/incentives (line 9832)
- POST /drivers/incentives/{incentive_id}/claim (line 9841)
- GET /drivers/demand-heatmap (line 10166)

### Group "riders" (3 endpoints)
- GET /riders/{rider_id}/trips (line 3816)
- GET /riders/payment-methods (line 4174)
- POST /riders/payment-methods (line 4184)
- DELETE /riders/payment-methods/{pm_id} (line 4203)
- PATCH /riders/payment-methods/{pm_id}/default (line 4213)

### Group "dispatch" (6 endpoints)
- POST /dispatch/login (line 1341)
- POST /dispatch/logout (line 1394)
- GET /dispatch (line 1404)
- POST /dispatch/request (line 4452)
- GET /dispatch/driver/pending (line 4516)
- POST /dispatch/driver/accept (line 4549)
- POST /dispatch/driver/reject (line 4618)
- GET /dispatch/trip/status (line 4674)

### Group "payments" (9 endpoints)
- POST /payments/setup-intent (line 3627)
- POST /payments/create-intent (line 8925)
- GET /payments/intent/{intent_id} (line 8978)
- POST /payments/paypal/create-order (line 9006)
- POST /payments/paypal/capture-order (line 9050)
- POST /payments/stripe/webhook (line 9086)
- POST /paypal/create-order (line 10599)

### Group "wallet" (5 endpoints)
- GET /wallet/balance (line 4241)
- GET /wallet/transactions (line 4252)
- POST /wallet/top-up (line 4285)
- POST /wallet/pay-ride (line 4325)
- POST /wallet/refund (line 4357)

### Group "admin" (26 endpoints)
- POST /admin/run-migrations (line 1320)
- POST /admin/sync-verifications (line 1453)
- POST /admin/backfill-approved (line 1483)
- POST /auth/dispatch-approve/{user_id} (line 3230)
- POST /auth/dispatch-reject/{user_id} (line 3263)
- GET /api/dispatch/action-requests (line 8041)
- POST /api/dispatch/action-requests/{request_id}/approve (line 8067)
- POST /api/dispatch/action-requests/{request_id}/reject (line 8207)
- GET /admin/users (line 8286)
- PATCH /admin/users/{user_id}/status (line 8303)
- GET /admin/trips (line 8324)
- POST /admin/trips (line 8356)
- PATCH /admin/trips/{trip_id} (line 8397)
- DELETE /admin/trips/{trip_id} (line 8421)
- GET /admin/stats (line 8433, 9951)
- POST /admin/dispatch (line 8504)
- GET /admin/verifications (line 8582)
- PATCH /admin/verifications/{user_id} (line 8618)
- GET /admin/users/{user_id} (line 8670)
- PATCH /admin/users/{user_id} (line 8707)
- DELETE /admin/users/{user_id} (line 8766)
- DELETE /admin/users (line 8801)
- GET /admin/users/{user_id}/chats (line 8832)
- GET /admin/users/{user_id}/documents (line 8858)
- GET /admin/users/{user_id}/payment-methods (line 8890)
- POST /admin/surge/update (line 9422)
- POST /admin/incentives/create (line 10546)
- GET /admin/drivers/online (line 10029)
- GET /admin/trips/active (line 10077)
- GET /admin/heatmap (line 10136)
- POST /admin/trips/assign (line 10196)
- POST /admin/drivers/message (line 10257)

### Group "support" (13 endpoints)
- POST /support/chats (line 6807)
- GET /support/chats (line 6876)
- GET /support/chats/all (line 6887)
- GET /support/chats/{chat_id}/messages (line 6931)
- GET /support/chats/{chat_id}/messages/dispatch (line 6974)
- POST /support/chats/{chat_id}/messages (line 7010)
- POST /support/chats/{chat_id}/typing (line 7089)
- POST /support/chats/{chat_id}/messages/dispatch (line 7104)
- POST /support/chats/{chat_id}/connect-supervisor (line 7138)
- PATCH /support/chats/{chat_id}/close (line 7165)
- PATCH /support/chats/{chat_id}/close-user (line 7189)

### Group "webhooks" (3 endpoints)
- POST /webhooks/checkr (line 4956)
- POST /drivers/background-check/webhook (line 10847)
- POST /payments/stripe/webhook (line 9086)

### Group "voice" (5 endpoints)
- POST /voice/incoming (line 7631)
- POST /voice/language (line 7667)
- GET /voice/phone-number (line 7692)
- POST /voice/gather (line 7698)
- POST /voice/status (line 7729)

### Group "promo" (2 endpoints)
- POST /promo/validate (line 7745)
- POST /promo/create (line 7762)

### Group "notifications" (3 endpoints)
- GET /notifications (line 7784)
- PATCH /notifications/{notif_id}/read (line 7798)
- POST /notifications/read-all (line 7808)

### Group "routing" (3 endpoints)
- GET /routing/preview (line 9242)
- GET /estimate-fare (line 9362)
- GET /navigation/instructions (line 10290)

### Group "misc" (8 endpoints)
- GET /tunnel-url (line 8026)
- GET /tips/presets (line 9467)
- GET /vehicle-preferences/options (line 9720)
- GET /referral/code (line 9737)
- POST /referral/apply (line 9749)
- POST /referral/complete/{referral_id} (line 10526)
- GET /surge/current (line 9201)
- POST /surge/auto-calculate (line 10712)
- POST /safety/sos-alert (line 10650)
- GET /service-area/check (line 9860)
- POST /plaid/create-link-token (line 4154)
- POST /plaid/exchange-token (line 4158)

### Group "favorites" (4 endpoints)
- GET /favorites (line 9770)
- POST /favorites (line 9777)
- PUT /favorites/{favorite_id} (line 9797)
- DELETE /favorites/{favorite_id} (line 9817)

### Group "places" (3 endpoints)
- GET /places/autocomplete (line 10902)
- GET /places/details (line 10966)
- GET /places/geocode (line 11023)

---

## 2. HELPER FUNCTIONS (64 total)

### Security & Auth (used by: auth, all routers)
- `_check_login_throttle()` — brute force protection
- `_record_login_failure()` — log failed login
- `_clear_login_failures()` — clear on success
- `_record_violation()` — IP violation tracking
- `_sanitize_string()` — SQL/XSS injection prevention
- `_check_nonce_replay()` — replay attack prevention
- `_security_audit_log()` — tamper-evident logging
- `_verify_api_key()` — HMAC signature verification
- `_verify_dispatch_key()` — admin-only key check
- `_require_dispatch_auth()` — dual auth (JWT or HMAC)
- `_require_admin()` — admin role verification
- `_create_token()` — JWT access token
- `_create_refresh_token()` — JWT refresh token  
- `_create_login_token()` — short-lived login token
- `_get_current_user()` — extract user from JWT

### Database (used by: startup, migrations)
- `_column_missing()` — check SQLite column
- `_migrate_add_columns()` — SQLite migrations
- `_migrate_postgres()` — PostgreSQL migrations

### Scheduling (used by: startup, drivers)
- `_next_tuesday_2am()` — payout scheduling
- `_auto_payout_all_drivers()` — weekly auto-payout
- `_schedule_weekly_payouts()` — background scheduler
- `_scheduled_ride_dispatcher()` — scheduled ride dispatch
- `_connection_watchdog()` — connection health

### Notifications (used by: auth, trips, support)
- `_send_fcm_push()` — Firebase push notifications
- `_send_email()` — multi-provider email cascade

### Data Serialization (used by: all routers)
- `_user_dict()` — User → JSON
- `_trip_dict()` — Trip → JSON
- `_vehicle_dict()` — Vehicle → JSON
- `_doc_dict()` — Document → JSON
- `_support_msg_dict()` — SupportMessage → JSON

### Trip Logic (used by: trips, payments)
- `_charge_trip()` — process trip payment
- `_haversine()` — distance calculation

### Wallet (used by: wallet, payments)
- `_get_or_create_wallet()` — get/create user wallet

### Support Chat / AI (used by: support)
- `_detect_frustration()` — sentiment detection
- `_has_cancel_intent()` — cancel request detection
- `_get_user_context()` — build AI context
- `_bot_cancel_trip()` — AI trip cancellation
- `_score_categories()` — support categorization
- `_match_keywords()` — keyword matching
- `_detect_category()` — intent classification
- `_build_claude_system_prompt()` — AI prompt
- `_get_chat_history()` — fetch chat history
- `_call_claude_api()` — Claude AI call
- `_parse_action_markers()` — parse AI response
- `_create_action_request()` — create admin action
- `_action_request_reminder()` — reminder scheduling
- `_rehydrate_pending_reminders()` — restore reminders
- `_generate_ai_response()` — full AI response pipeline
- `_generate_human_chat()` — fallback responses
- `_lookup_user_trips()` — trip lookup for support
- `_build_trip_summary()` — trip summary for AI
- `_create_refund_request()` — refund request
- `_generate_bot_replies()` — bot reply pipeline
- `_background_bot_reply()` — async bot reply
- `_check_chat_inactivity()` — inactivity detection

### Voice IVR (used by: voice)
- `_voice_detect_category_en()` — voice intent detection
- `_get_voice_responses()` — localized responses
- `_generate_voice_response()` — TwiML generation
- `_twiml_say()` — TwiML say element
- `_twiml_gather_speech()` — TwiML gather
- `_twiml_hangup()` — TwiML hangup

### Navigation (used by: routing)
- `_parse_maneuver_to_type()` — maneuver parsing
- `_clean_html_instructions()` — HTML cleaning

### PayPal (used by: payments)
- `_paypal_base_url()` — PayPal environment
- `_get_paypal_access_token()` — PayPal auth

---

## 3. PYDANTIC SCHEMAS (21 total)

### Auth Schemas
- `RegisterIn` — user registration
- `CheckExistsIn` — email/phone check
- `LoginIn` — user login
- `CompleteLoginIn` — complete OTP login
- `SocialAuthIn` — Google/Apple OAuth
- `SendOtpIn` — send OTP request
- `VerifyOtpIn` — verify OTP code
- `OwnerLogin` — dispatch owner login

### Trip Schemas
- `CreateTripIn` — create trip request
- `AcceptTripIn` — driver accept trip
- `DispatchRequestIn` — dispatch create trip

### Driver Schemas
- `DriverLocationIn` — driver GPS update
- `CashoutIn` — driver cashout request
- `PayoutMethodIn` — add payout method

### Payment Schemas
- `RiderPaymentMethodIn` — add payment method
- `WalletTopUpIn` — wallet top-up
- `WalletWithdrawIn` — wallet withdrawal
- `PaymentIntentIn` — Stripe payment intent
- `PayPalOrderIn` — PayPal order
- `PayPalCaptureIn` — PayPal capture

### Other Schemas
- `ApplyReferralIn` — apply referral code
- `AdminStatsResponse` — admin stats response

---

## 4. SQLALCHEMY MODELS (26 total)

- `User` — users table
- `ConsentLog` — GDPR consent logs
- `Trip` — trips table
- `FareSplit` — fare split requests
- `DispatchOffer` — driver dispatch offers
- `PayoutMethod` — driver payout methods
- `RiderPaymentMethod` — rider payment methods
- `Wallet` — user wallets
- `WalletTransaction` — wallet transactions
- `Cashout` — driver cashouts
- `Vehicle` — driver vehicles
- `Document` — driver documents
- `Rating` — trip ratings
- `ChatMessage` — trip chat messages
- `SupportChat` — support chats
- `SupportMessage` — support messages
- `ActionRequest` — admin action requests
- `Notification` — push notifications
- `PromoCode` — promo codes
- `PasswordResetToken` — password reset tokens
- `Referral` — referral tracking
- `FavoriteLocation` — saved addresses
- `DriverIncentive` — driver incentives
- `SurgeZone` — surge pricing zones
- `ServiceArea` — service area definitions

---

## 5. GLOBAL VARIABLES & CONFIG

### Environment Config
- `DATABASE_URL`, `API_KEY`, `HMAC_SECRET`, `JWT_SECRET`
- `DISPATCH_API_KEY`, `OWNER_EMAIL`, `OWNER_PASSWORD`
- `TWILIO_*` — Twilio credentials
- `SMTP_*`, `MAILGUN_*`, `SENDGRID_*`, `BREVO_*` — Email
- `GOOGLE_MAPS_API_KEY` — Directions API
- `ANTHROPIC_API_KEY` — Claude AI

### In-Memory State
- `_otp_store` — OTP codes
- `_pending_cache` — driver pending offers cache
- `_rate_buckets` — rate limiting
- `_login_attempts` — brute force protection
- `_ip_blacklist`, `_ip_violations` — IP banning
- `_used_nonces` — replay protection
- `_audit_chain` — security audit log
- `_dispatch_sessions` — active owner sessions

### Database
- `engine`, `SessionLocal` — SQLAlchemy async engine

---

## 6. PROPOSED FILE STRUCTURE

```
backend/
├── main.py                          (~150 lines)
│   └── FastAPI app, middleware, lifespan, include_router
│
├── config.py                        (~100 lines)
│   └── Environment variables, constants
│
├── models/
│   ├── __init__.py
│   ├── database.py                  (~100 lines)
│   │   └── engine, SessionLocal, Base, get_db
│   └── tables.py                    (~400 lines)
│       └── All SQLAlchemy models (26 tables)
│
├── schemas/
│   ├── __init__.py
│   ├── auth.py                      (~100 lines)
│   │   └── RegisterIn, LoginIn, SocialAuthIn, etc.
│   ├── trips.py                     (~80 lines)
│   │   └── CreateTripIn, AcceptTripIn, etc.
│   ├── payments.py                  (~80 lines)
│   │   └── PaymentIntentIn, WalletTopUpIn, etc.
│   └── misc.py                      (~60 lines)
│       └── DriverLocationIn, CashoutIn, etc.
│
├── utils/
│   ├── __init__.py
│   ├── security.py                  (~350 lines)
│   │   └── JWT, HMAC, nonce, rate limiting, audit
│   ├── helpers.py                   (~150 lines)
│   │   └── _haversine, _sanitize_string, _user_dict, etc.
│   └── email.py                     (~150 lines)
│       └── _send_email (Mailgun, SendGrid, Brevo, SMTP)
│
├── services/
│   ├── __init__.py
│   ├── fcm_service.py               (~80 lines)
│   │   └── _send_fcm_push
│   ├── support_ai.py                (~600 lines)
│   │   └── All Claude AI + support chat logic
│   ├── voice_ivr.py                 (~200 lines)
│   │   └── TwiML generation, voice handlers
│   └── paypal.py                    (~100 lines)
│       └── PayPal OAuth + order logic
│
├── routers/
│   ├── __init__.py
│   ├── health.py                    (~80 lines)
│   │   └── /health, /health/security, /health/guardian
│   ├── auth.py                      (~600 lines)
│   │   └── 24 auth endpoints
│   ├── users.py                     (~200 lines)
│   │   └── photos, ratings, documents
│   ├── trips.py                     (~700 lines)
│   │   └── 27 trip endpoints
│   ├── drivers.py                   (~600 lines)
│   │   └── 24 driver endpoints
│   ├── riders.py                    (~150 lines)
│   │   └── payment methods
│   ├── dispatch.py                  (~400 lines)
│   │   └── 8 dispatch endpoints
│   ├── payments.py                  (~400 lines)
│   │   └── Stripe, PayPal, wallet
│   ├── wallet.py                    (~200 lines)
│   │   └── 5 wallet endpoints
│   ├── admin.py                     (~800 lines)
│   │   └── 30 admin endpoints
│   ├── support.py                   (~500 lines)
│   │   └── 11 support endpoints
│   ├── voice.py                     (~250 lines)
│   │   └── 5 voice IVR endpoints
│   ├── webhooks.py                  (~300 lines)
│   │   └── Stripe, Checkr webhooks
│   ├── routing.py                   (~300 lines)
│   │   └── routing preview, fare estimate, navigation
│   ├── places.py                    (~200 lines)
│   │   └── autocomplete, details, geocode
│   ├── favorites.py                 (~100 lines)
│   │   └── CRUD favorites
│   ├── promo.py                     (~80 lines)
│   │   └── validate, create
│   ├── notifications.py             (~100 lines)
│   │   └── list, mark read
│   └── misc.py                      (~300 lines)
│       └── referral, surge, safety, tips, etc.
```

### Line Count Summary
- main.py: 150 lines
- config.py: 100 lines
- models/: 500 lines
- schemas/: 320 lines
- utils/: 650 lines
- services/: 980 lines
- routers/: 5,680 lines
- **Total: ~8,380 lines** (same content, modular)

### Max File Sizes
- No router exceeds 800 lines
- No service exceeds 600 lines
- No model file exceeds 400 lines

---

## 7. EXECUTION ORDER

### Step 1: Extract shared code (R1.2)
1. Create `config.py` — env vars
2. Create `models/database.py` — engine, Base
3. Create `models/tables.py` — all SQLAlchemy models
4. Create `schemas/` — all Pydantic models
5. Create `utils/security.py` — auth helpers
6. Create `utils/helpers.py` — utility functions
7. Create `utils/email.py` — email sender
8. Create `services/fcm_service.py` — FCM push
9. Update main.py imports

### Step 2: Extract routers (R1.3)
1. Create each router file
2. Move endpoints to respective routers
3. Update main.py with include_router()
4. main.py should only have:
   - App creation
   - Middleware
   - Lifespan (startup/shutdown)
   - Router includes

### Step 3: Verify (R1.4)
1. Run `python -c "from main import app"`
2. Run `uvicorn main:app`
3. Check /docs Swagger UI
4. Run tests

---

## 8. RISKS & MITIGATIONS

### Circular Imports
- Risk: Models import utils, utils import models
- Mitigation: Keep database.py minimal, use TYPE_CHECKING

### Breaking Changes
- Risk: Changed import paths break tests
- Mitigation: Create __init__.py re-exports

### Missing Dependencies  
- Risk: Function needs another function from same file
- Mitigation: Careful dependency mapping (done above)

### Startup Order
- Risk: Lifespan needs all modules loaded
- Mitigation: Import routers after config/models/utils
