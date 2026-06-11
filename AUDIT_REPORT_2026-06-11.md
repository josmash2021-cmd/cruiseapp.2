# 🔒 CruiseApp Full Security & Quality Audit Report

**Date:** 2026-06-11  
**Commit:** `beb6ccfc` on `main`  
**Auditors:** Automated analysis (Backend, Flutter, Secrets, CI/CD)

---

## Executive Summary

| Area | Severity | Key Finding |
|------|----------|-------------|
| **Secrets** | 🔴 CRITICAL | Production API keys, DB password, keystore password, Stripe live key exposed in git |
| **Backend Security** | 🔴 CRITICAL | Password hashes synced to Firestore, SSN plaintext fallback, auth backdoor, cashout race condition |
| **Flutter Stability** | 🔴 CRITICAL | AnimationController leaks, ChatScreen missing dispose, timer leaks in map annotations |
| **Tests & CI** | 🔴 CRITICAL | ~0.07% Flutter coverage, ~4% backend coverage, CI configured to ignore test failures |

**Immediate Action Required:** Secret rotation must happen BEFORE this repository is made public or before the next production release.

---

## 1. Secrets & Configuration (CRITICAL)

### 1.1 Production Secrets Exposed in Source Control

| Secret | Location | Impact |
|--------|----------|--------|
| **Supabase DB Password** `CruiseDB2026secure` | `.claude/settings.json` lines 51, 266, 461 | Full database access |
| **Production API Key** `HWB88VurhLM-1GdVML2PT92iqNSbeJ52TU1VO37MBZS6RYlyWvfIpaTdD54GT_5u` | `.claude/settings.json` lines 163, 172, 174 | Backend admin access |
| **Android Keystore Password** `Cruise2026!` | `.claude/settings.json` lines 95, 191-196 | Code signing compromise |
| **Stripe LIVE Publishable Key** `pk_live_51T4BXG...` | `assets/pay/default_google_pay_config.json:19`, `assets/pay/google_pay.yaml:24` | Account identification for fraud |
| **Google Maps API Key** `AIzaSyALnqq4-_jJLUCLxSJaWZGZHgw27RVE78Y` | `web/index.html:53` | Quota theft |
| **Mapbox Token** `pk.eyJ1Ijoicm95YWxwdXJwbGVjb3Jw...` | `codemagic.yaml:687, 736` | Hardcoded CI fallback |
| **Firebase API Keys** (3 platforms) | `lib/firebase_options.dart:21,32,41` | Full Firebase project enumeration |
| **Full Firebase Config** | `android/app/google-services.json`, `ios/Runner/GoogleService-Info.plist` | OAuth client IDs, cert hashes |

### 1.2 Git History Contains Rotated Secrets
- Commits `0d17f785` and `57c6e3c5` previously committed `DISPATCH_API_KEY`, `HMAC_SECRET`, and OpenAI API keys
- `lib/config/env.dart` was committed and later removed but remains in git history

### 1.3 Security Misconfigurations
- `.gitignore` lists `google-services.json` and `GoogleService-Info.plist` but they are **still tracked**
- Apple review bypass backdoor emails hardcoded in `backend/scripts/patch_auth.py:20`
- Production backend URL exposed: `https://cruiseapp2-production.up.railway.app`

---

## 2. Backend Security (CRITICAL)

### 2.1 CRITICAL Issues

| # | Issue | File | Fix |
|---|-------|------|-----|
| 1 | **Password hashes synced to Firestore** — `password_hash` passed to `sync_driver`/`sync_client` | `routers/admin.py:934-955`, `firestore_sync.py:166,185,218,238` | Remove `password_hash` from all Firestore syncs; use boolean `has_password` only |
| 2 | **SSN plaintext fallback** — stores `[PLAINTEXT:]` prefix when encryption key missing | `utils/ssn_encryption.py:58-60` | Fail closed — raise `RuntimeError` if key missing |
| 3 | **Apple review bypass backdoor** — 4 hardcoded emails bypass OTP entirely | `routers/auth.py:341-355` | Move to env vars + hash comparison; rotate emails |
| 4 | **Cashout race condition** — second SELECT without `FOR UPDATE` after Stripe transfer | `routers/drivers.py:853-857` | Use locked `locked_user` object for deduction |
| 5 | **Sensitive docs stored locally on Firebase failure** — licenses, selfies, insurance cards | `routers/auth.py:1961-1998`, `routers/drivers.py:1737-1743` | Remove local fallback; return 503 if storage unavailable |
| 6 | **SQL injection in migrations** — f-strings in `text()` DDL | `models/database.py:734,807,809,940` | Use Alembic or parameterized `text()` |
| 7 | **CORS debug mode exposes production** — `DEBUG=1` adds localhost to allowlist | `main.py:483-493` | Require explicit `CORS_ORIGINS` in production |
| 8 | **Admin endpoints accept raw JSON** — no Pydantic validation on `request.json()` | `routers/admin.py:178-216,218-288,415-489`, `routers/drivers.py:1648-1685` | Convert all to Pydantic models |

### 2.2 HIGH Priority

| # | Issue | File |
|---|-------|------|
| 9 | In-memory rate limiter fails in multi-instance deployments | `middleware/rate_limit.py` |
| 10 | `login_token` JWT type not strictly validated | `utils/security.py:443-446` |
| 11 | Bank account encryption verification missing | `models/database.py:326-327` |
| 12 | Web checkout bearer key vulnerable to brute force | `routers/payments.py:510-630` |
| 13 | Trip status resurrection bypass without tamper-evident audit log | `routers/trips.py:900-924` |
| 14 | Unbounded offset in admin list endpoints | `routers/admin.py:66-82,105-175` |
| 15 | Base64 photo upload missing dimension/polyglot checks | `routers/auth.py:1575-1644,1676-1747` |

### 2.3 Dependency Vulnerabilities

| Package | Version | Issue |
|---------|---------|-------|
| `python-jose[cryptography]` | `3.4.0` | CVE-2024-33663 (ECDSA key confusion) — replace with `PyJWT` |
| `stripe` | `7.0.0` | Behind latest (~9.x) — verify API compatibility before upgrading |

---

## 3. Flutter Frontend (CRITICAL)

### 3.1 CRITICAL Issues

| # | Issue | File | Fix |
|---|-------|------|-----|
| 1 | **AnimationController leak** — `_searchCamCtrl` created dynamically but not disposed | `ride_request_screen.dart` | Add `_searchCamCtrl?.dispose()` to `dispose()` |
| 2 | **Timer leaks in map annotations** — `Timer.periodic` in `TrackingMapAnnotations` not stored/cancelled | `lib/map/tracking_map_annotations.dart:138,197` | Store timer refs and cancel in `clear()`/`reset()` |
| 3 | **ChatScreen missing dispose()** — `_pollTimer`, `_restPollTimer`, `_typingTimer`, `_rtdbConnectionSub`, controllers, focus node leak | `lib/screens/chat_screen.dart` | Add `dispose()` cancelling all timers/subscriptions and disposing controllers |
| 4 | **Dead code / null-deref risk** — `_miniMapController = null` before `flyTo()` in `_onTripCompleted()` | `home_screen.dart` | Reorder: `flyTo` first, then null the controller |

### 3.2 HIGH Priority

| # | Issue | File |
|---|-------|------|
| 5 | `_driverPhotoImage?.dispose()` after map cache — cached controller may reference disposed image | `driver_online_screen.dart` |
| 6 | `_routeDrawTicker` disposal inconsistency — 60+ `Timer.periodic` declarations, not all verified | Across multiple screens |
| 7 | Missing `mounted` guards after async payment flow | `ride_request_controller.dart` |
| 8 | SSE reconnect timer accumulation | `driver_online_controller.dart` |
| 9 | `_animScheduler` ticker callback after dispose | `rider_tracking_screen.dart` |
| 10 | `_posStream` (Geolocator) not cancelled on permission revocation | `driver_online_screen.dart` |

### 3.3 MEDIUM Priority

| # | Issue | Count |
|---|-------|-------|
| 11 | `Future.delayed` fire-and-forget without `mounted` guards | 151 usages |
| 12 | `ScaffoldMessenger.of(context)` after async gaps | 110 usages |
| 13 | `showDialog` triggered from async callbacks without `mounted` check | 35+ usages |
| 14 | `GoldLocationDot.ensureRunning()` race with widget disposal | `gold_location_dot.dart` |
| 15 | `MapControllerCache` stale annotation risk — cached controller retains native annotations | `map_controller_cache.dart` |

---

## 4. Tests & CI/CD (CRITICAL)

### 4.1 Test Coverage

| Layer | Production Code | Test Code | Coverage |
|-------|-----------------|-----------|----------|
| Flutter | ~148,600 lines (235 files) | 105 lines (3 files, 7 tests) | **~0.07%** |
| Python Backend | ~46,200 lines (157 files) | ~2,000 lines (12 files, 49 tests) | **~4%** |

### 4.2 Critical Test Gaps

- **Payments:** No tests for Stripe capture, PayPal, Tap to Pay, wallet, tipping
- **Auth:** No tests for OTP, social sign-in, token refresh
- **Driver dispatch:** No test for accept/reject cascade (404 accepted as success)
- **Trip lifecycle:** No tests for pickup → in-trip → dropoff → rating
- **Maps & location:** No tests for Mapbox, GPS, geofencing
- **Real-time:** Socket.io tests skipped if server unavailable
- **Safety:** SOS alert has zero tests
- **Admin:** Bulk operations have zero tests

### 4.3 CI/CD Issues

| File | Line | Issue |
|------|------|-------|
| `.github/workflows/ci.yml` | 20 | `flutter-version: '3.x'` — unpinned |
| `.github/workflows/ci.yml` | 60 | `continue-on-error: true` — **tests never fail the build** |
| `.github/workflows/build-ios.yml` | 16 | `flutter-version: '3.x'` — unpinned |
| `codemagic.yaml` | 165 | `pytest ... \|\| true` — **backend tests never fail the build** |
| `codemagic.yaml` | 289, 349, 459, 679, 727 | `flutter: stable` — unpinned |
| `pubspec.yaml` | 82–93 | No `mocktail`, `patrol`, `integration_test` |
| `analysis_options.yaml` | 28–32 | `unused_*: ignore` — hides dead code |
| `backend/requirements.txt` | — | No `pytest-cov`, `bandit`, `mypy`, `ruff` |

---

## 5. Remediation Checklist

### 🔴 P0 — Do Before Next Production Release

#### Secrets (Immediate)
- [ ] Rotate Supabase password `CruiseDB2026secure`
- [ ] Rotate production API key `HWB88VurhLM-...`
- [ ] Regenerate Android signing keystore (password `Cruise2026!` compromised)
- [ ] Rotate Google Maps API key `AIzaSyALnqq4-...`
- [ ] Rotate Stripe live publishable key `pk_live_51T4BXG...`
- [ ] Rotate Mapbox token `pk.eyJ1Ijoicm95YWxwdXJwbGVjb3Jw...`
- [ ] Restrict Firebase API keys to app fingerprint/bundle in Google Cloud Console
- [ ] Delete `.claude/settings.json` from git and add to `.gitignore`
- [ ] Scrub git history with `git-filter-repo` or BFG Repo-Cleaner

#### Backend Security
- [ ] Remove `password_hash` from ALL Firestore sync calls
- [ ] Make SSN encryption fail-closed (no plaintext fallback)
- [ ] Fix cashout race condition — use locked row for deduction
- [ ] Remove local-disk fallback for sensitive document uploads
- [ ] Move Apple review bypass emails to env vars + hash comparison

#### Flutter Stability
- [ ] Fix `_searchCamCtrl` disposal in `ride_request_screen.dart`
- [ ] Add `dispose()` to `ChatScreen`
- [ ] Fix `TrackingMapAnnotations` timer storage + cleanup
- [ ] Fix `_onTripCompleted()` dead code ordering

#### CI/CD
- [ ] Remove `continue-on-error: true` from `.github/workflows/ci.yml`
- [ ] Remove `|| true` from `codemagic.yaml` backend test step
- [ ] Pin Flutter version to specific release (e.g., `3.27.0`)

### 🟠 P1 — Next 2 Sprints

- [ ] Replace `python-jose` with `PyJWT`
- [ ] Add Pydantic models to all admin `request.json()` endpoints
- [ ] Enforce Redis rate limiter in production
- [ ] Cap `offset` parameters and add cursor pagination
- [ ] Add `mounted` guards to all post-await context usages
- [ ] Clear all map annotations before caching controller in `MapControllerCache`
- [ ] Add backend static analysis (`bandit`, `ruff`, `mypy`) to CI
- [ ] Add Dart static analysis gate (`flutter analyze --fatal-infos`)
- [ ] Add `mocktail` to Flutter dev_dependencies
- [ ] Write critical backend tests: dispatch cascade, payment capture, background-check gate, admin bulk ops
- [ ] Write widget tests for 5 critical screens: Login, Home, RideRequest, DriverOnline, PaymentMethod

### 🟡 P2 — Quarterly

- [ ] Target 70% backend coverage for `dispatch.py`, `payments.py`, `trips.py`, `drivers.py`
- [ ] Target 50% Flutter coverage for `services/`, `screens/`, `controllers/`
- [ ] Move SQL migrations to Alembic
- [ ] Add `Pillow` image validation to all photo upload endpoints
- [ ] Add load tests for fare estimation and dispatch
- [ ] Add contract tests for Stripe & PayPal webhooks
- [ ] Remove `test_socketio.py` skips — spin up server in pytest fixture
- [ ] Add integration tests for full trip flow
- [ ] Implement golden tests for UI regressions
- [ ] Enable GitHub Advanced Security secret scanning

---

## 6. Positive Security Controls

| Control | File | Status |
|---------|------|--------|
| Secrets read from env vars | `backend/config.py` | ✅ |
| JWT/HMAC validation at startup | `backend/utils/security.py` | ✅ |
| Auto-generated secrets only in DEBUG | `backend/utils/security.py` | ✅ |
| `.env` files gitignored | `.gitignore` | ✅ |
| Mapbox token via `--dart-define` | `lib/config/mapbox_config.dart` | ✅ |
| Google Places keys via `--dart-define` | `lib/config/api_keys.dart` | ✅ |
| `usesCleartextTraffic="false"` | `AndroidManifest.xml` | ✅ |
| `NSAllowsArbitraryLoads = false` | `Info.plist` | ✅ |
| Stripe webhook secret validation | `backend/config.py` | ✅ |
| HMAC-signed mobile API requests | `backend/utils/security.py` | ✅ |
| Brute-force protection on auth | `backend/utils/security.py` | ✅ |

---

*Report compiled from automated analysis of commit `beb6ccfc` on branch `main`.*
