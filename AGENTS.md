# AGENTS.md — CruiseApp Agent Navigation Index

> **Purpose:** Quick-reference index for AI coding agents working on this repository.  
> **Rule:** Read this file first, then consult `PROJECT_MAP.md` before any edit.

---

## 📚 Memory Files (Read before editing)

| File | Why read it |
|------|-------------|
| [`PROJECT_MAP.md`](./PROJECT_MAP.md) | **Complete file map.** Every folder, every important file, its editability status (🔴 NO TOUCH / 🟡 CAREFUL / 🟢 EDITABLE), and security notes. |
| [`SECURITY_ACTIONS.md`](./SECURITY_ACTIONS.md) | Security audit results: what was fixed, what is pending, and how to rotate secrets. |
| [`CLAUDE.md`](./CLAUDE.md) | Project bible: stack, trip lifecycle, conventions, known bugs, agent commands (`/ship`, `/deploy-back`), learned patterns. |
| [`PROJECT_MEMORY.md`](./PROJECT_MEMORY.md) | Secondary architecture memory (99 screens, 29 services). May be slightly outdated; verify against code. |

---

## 🚦 Edit Safety Rules

1. **If a file is marked 🔴 in `PROJECT_MAP.md` → DO NOT EDIT without explicit user approval.**
2. **If a file is marked 🟡 → Edit only if you fully understand the blast radius.**
3. **If a file is marked 🟢 → Safe to edit; still follow conventions below.**

### Never edit without approval
- `pubspec.yaml`, `codemagic.yaml`, `shorebird.yaml`, `railway.toml`
- `firebase.json`, `.firebaserc`, `database.rules.json`, `firestore.rules`, `storage.rules`
- `android/app/build.gradle.kts` (signing config)
- `ios/Runner.xcodeproj/` (codesign)
- `backend/models/database.py` without a migration plan
- `backend/utils/security.py` without regression tests
- `backend/migrations/*.py` that have already run in production
- `docs/privacy_policy.md`, `docs/rider_terms_of_service.md`, `docs/driver_terms_of_service.md`, `docs/driver_agreement.md` (legal documents); `docs/archive/terms_of_service_alabama_legacy.md` is the superseded Alabama ToS — do not restore or reference it
- `.github/copilot-instructions.md`, `.github/agents/*.md`, `.github/workflows/*.yml`

### Always do this
- Run `flutter analyze` after editing `.dart` files (hooks do this automatically).
- Run `pytest backend/tests/` after editing Python files.
- Use `try/finally` + `.dispose()` in Flutter controllers.
- Use Pydantic validation for all FastAPI inputs.
- Use SQLAlchemy ORM or `text()` with named parameters (never string-concat SQL).
- Keep code bilingual (Spanish/English) as per project convention.
- Never commit secrets (`lib/config/env.dart`, `.env`, `backend/.env`, `*.jks`).

---

## 🗂️ Folder Responsibilities

| Folder | What lives here | Typical edits |
|--------|-----------------|---------------|
| `lib/screens/` | Flutter UI (80+ screens) | Add/modify UI flows, fix layout bugs |
| `lib/services/` | Business logic / API clients | Fix API calls, add endpoints, patch caching |
| `lib/models/` | Dart data models | Add fields, update `fromJson`/`toJson` |
| `lib/map/` | Mapbox unified engine | Map layers, camera, tracking |
| `lib/widgets/` | Reusable widgets | UI components, animations |
| `lib/config/` | App config, themes, flags | Feature flags, theme tweaks |
| `lib/navigation/` | Driver navigation state machine | Trip-phase logic, car rendering |
| `backend/routers/` | FastAPI endpoints | Add endpoints, fix business logic |
| `backend/services/` | Backend business services | Notifications, caching, AI, SMS |
| `backend/models/` | SQLAlchemy + Pydantic | Schema changes (with migration!) |
| `backend/utils/` | Security, helpers, encryption | Utilities, security hardening |
| `backend/tests/` | Pytest suite | Add regression tests |
| `backend/scripts/` | One-off utility scripts | Data backfills, admin scripts |
| `docs/` | Documentation | Technical guides, setup docs |
| `assets/` | Images, sounds, fonts, configs | Add/replace assets |
| `android/`, `ios/`, `web/`, `linux/`, `macos/`, `windows/` | Platform configs | Platform-specific fixes only |

---

## 🔐 Security Reminders

- `backend/services/redis_cache.py` **no longer uses `pickle`**. Only JSON-serializable values can be cached.
- `backend/main.py` CORS defaults are production-safe; localhost only appears when `DEBUG=1`.
- Several secrets are still hardcoded in mobile/web assets (Firebase keys, Stripe pk_live, Google Maps key). **Do not commit new secrets.** See `SECURITY_ACTIONS.md` for rotation plan.

---

## 🛠️ Common Commands

```bash
# Backend tests
pytest backend/tests/ -v

# Flutter analysis
flutter analyze

# Backend deploy (Railway)
railway up --detach

# Flutter build (iOS via Codemagic / Android via Shorebird)
# Do NOT run flutter build apk manually unless instructed.
```

---

*Last updated: 2026-06-04 during full-project audit.*
