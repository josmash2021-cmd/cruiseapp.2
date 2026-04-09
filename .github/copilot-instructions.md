# CruiseApp — Copilot Workspace Instructions

## Project Overview

CruiseApp is a production ride-sharing platform (like Uber/Lyft) with a Flutter mobile app and Python FastAPI backend. It serves both riders and drivers with real-time trip tracking, payments, and dispatch.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Mobile App | Flutter 3.x / Dart |
| Backend API | Python / FastAPI (async) |
| Database | Supabase (PostgreSQL) |
| Auth | Supabase Auth (OTP email, JWT) |
| File Storage | Supabase Storage |
| Real-time | Firebase Firestore + RTDB |
| Maps | Mapbox Maps Flutter |
| Payments | Stripe (PaymentIntents, Connect payouts) |
| SMS/Voice | Twilio |
| Push Notifications | Firebase Cloud Messaging (FCM) |
| Deployment | Railway (backend), Codemagic (mobile) |

## Repository Structure

```
lib/                    # Flutter app
├── screens/            # UI screens (rider/ and driver/ subdirectories)
├── controllers/        # Screen controllers (state + logic)
├── services/           # API, GPS, auth, payment, notification services
├── models/             # Dart data models
├── widgets/            # Reusable widgets
├── l10n/               # Localization (app_localizations.dart)
└── utils/              # Helpers, constants, extensions

backend/                # FastAPI server
├── main.py             # App entry point
├── config.py           # Environment config
├── routers/            # API route handlers (auth, trips, drivers, payments, dispatch, etc.)
├── models/             # SQLAlchemy models + Pydantic schemas
├── services/           # Business logic (email, stripe, twilio, fcm)
├── tests/              # pytest test suite
└── migrate.py          # Database migration runner
```

## Coding Conventions

### Flutter/Dart
- **State management**: StatefulWidget with controllers (no Riverpod/Bloc/Provider)
- **Localization**: `S.of(context).keyName` via `lib/l10n/app_localizations.dart` — bilingual English/Spanish with `_es` ternary pattern
- **Theme**: Dark theme — black `#000000` background, gold `#FFD700` accents, Poppins font
- **Null safety**: Sound null safety. No unnecessary `dynamic`. Check `mounted` before `setState` in async callbacks
- **Dispose**: Always dispose AnimationControllers, TextEditingControllers, StreamSubscriptions, Timers
- **Part files**: Many screens use `part`/`part of` pattern (e.g., `driver_online_screen.dart` + `_controller.dart` + `_map.dart` + `_widgets.dart`)

### Python/FastAPI
- **Database**: Supabase client (`supabase.table(...).select/insert/update/delete`)
- **Auth**: `Depends(get_current_user)` on every protected endpoint
- **Validation**: Pydantic v2 models for request/response bodies
- **Error handling**: try/except on every Supabase call, proper HTTPException status codes
- **Quotes**: ASCII quotes only — never smart/curly quotes (caused real bug)
- **No raw SQL**: Always use Supabase client methods, never f-string interpolation in queries

## Critical Rules

1. **Read before edit** — always read the target file before modifying it
2. **No extras** — don't add comments, docstrings, type annotations, or refactoring the user didn't ask for
3. **Verify after edit** — check for compile/lint errors after every change
4. **Keep it simple** — one developer maintains this. No over-engineering
5. **Commit after work** — commit and push to origin/main when changes are complete
6. **Bilingual** — all user-facing strings must use the localization system (English + Spanish)

## Agent Routing Guide

| Task | Agent |
|------|-------|
| Full-stack debugging, crashes, connectivity | `cruisehero` |
| Backend API, endpoints, DB, security | `backend-guardian` |
| Backend architecture, API design, schema design | `backend-architect` |
| Python implementation | `python-pro` |
| UI/UX design review, accessibility | `ui-ux-designer` |
| Code review, security audit | `code-reviewer` |
| Firebase, Firestore, RTDB, SSE, real-time sync | `Realtime Sync` |
| Performance, memory, frame drops, build size | `Performance Optimizer` |
| Trip lifecycle, dispatch, driver assignment | `Trip Pipeline` |
| Payments, Stripe, payouts, fare calculation | `payment-processor` |
| Auth flows, JWT, OTP, login | `authentication` |
| DB schema, migrations, Supabase RLS | `database-schema` |
| Flutter patterns, state, disposal, widgets | `flutter-architecture` |
| Driver online screen | `driver-online` |
| Driver ride offer card | `Driver Ride Offer` |
| Driver trip accept screen | `Driver Trip Accept Screen` |
| Driver trip screen | `driver-trip` |
| Rider home screen | `Rider Home Screen` |
| Rider address search | `rider-search` |
| Rider ride request | `Rider Ride Request` |
| Rider confirming screen | `Rider Confirming Screen` |
| Rider tracking screen | `Rider Tracking Screen` |
