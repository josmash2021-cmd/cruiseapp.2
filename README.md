# 🚗 CruiseApp

**Cruise** — Premium ride-sharing app connecting riders with professional drivers.

[![Flutter Version](https://img.shields.io/badge/Flutter-3.24+-blue.svg)](https://flutter.dev)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.115+-green.svg)](https://fastapi.tiangolo.com)
[![License](https://img.shields.io/badge/License-Proprietary-red.svg)]()

> Multi-platform ride-sharing application (Android, iOS, Web, Windows, macOS, Linux) with real-time tracking, premium payments, and professional driver fleet.

---

## 📱 Screenshots

*Rider, Driver, and Admin interfaces*

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        FLUTTER APP                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │  Rider   │  │  Driver  │  │  Admin   │  │  Splash  │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
│                                                             │
│  Real-time: Socket.io (primary) + Firebase RTDB (backup)   │
│  Maps: Mapbox Maps + Navigation SDK                         │
│  Payments: Stripe + PayPal + Tap to Pay (NFC)              │
│  Auth: Firebase Auth + JWT + Social (Google, Apple)        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼ HTTPS / WebSocket
┌─────────────────────────────────────────────────────────────┐
│                     FASTAPI BACKEND                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │  REST API    │  │  Socket.io   │  │   Agents     │     │
│  │  (10 layers  │  │  Real-time   │  │  (12 auto)   │     │
│  │   security)  │  │  <200ms GPS  │  │              │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
│                                                             │
│  Database: PostgreSQL (prod) / SQLite (dev)                │
│  Cache: In-memory + Redis-ready                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 🚀 Quick Start

### Prerequisites

- Flutter 3.24+ (`flutter doctor`)
- Python 3.11+
- Firebase project (for Auth, Firestore, FCM)
- Mapbox account
- Stripe account

### Backend Setup

```bash
cd backend

# Create virtual environment
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt

# Environment variables (create .env file)
cp .env.template .env
# Edit .env with your keys: API_KEY, JWT_SECRET, HMAC_SECRET, DATABASE_URL, etc.

# Run server
python main.py
# Server starts at http://localhost:8000
# Socket.io at ws://localhost:8000/socket.io
```

### Flutter Setup

```bash
# Install dependencies
flutter pub get

# Environment (for local dev, keys are proxied through backend)
# No additional setup needed for basic development

# Run app
flutter run

# Or build for specific platform
flutter build apk --release
flutter build ios --release
```

---

## 📁 Project Structure

```
cruiseapp.2/
├── lib/                          # Flutter application
│   ├── screens/                  # UI screens (rider, driver, admin)
│   ├── services/                 # Business logic & API clients
│   │   ├── socket_service.dart   # Socket.io real-time client
│   │   ├── gps_service.dart      # Driver GPS upload
│   │   └── api_service.dart      # REST API client
│   ├── controllers/              # Screen controllers/extensions
│   ├── state/                    # State management (controllers)
│   ├── models/                   # Data models
│   ├── config/                   # App configuration
│   │   └── feature_flags.dart    # Feature flags (Socket.io rollout)
│   └── main.dart                 # App entry point
│
├── backend/                      # FastAPI backend
│   ├── main.py                   # App entry + lifespan
│   ├── routers/                  # API endpoints
│   ├── services/                 # Business logic
│   │   └── socketio_service.py   # Socket.io server
│   ├── models/                   # SQLAlchemy + Pydantic schemas
│   ├── utils/                    # Security, helpers
│   └── tests/                    # pytest suite
│
├── docs/                         # Documentation
│   ├── REALTIME_IMPLEMENTATION_PLAN.md
│   ├── SETUP_GUIDE.md
│   └── NETWORK_CONFIG.md
│
└── assets/                       # Images, fonts, map styles
```

---

## ⚡ Real-Time Performance

| Metric | Before | After (Socket.io) |
|--------|--------|-------------------|
| GPS Driver → Rider | 2,300-2,500ms | **<200ms** |
| Trip Status Updates | ~5s (HTTP poll) | **<100ms** |
| App Cold Start | Not measured | **<800ms target** |
| Login Flow | Not measured | **<1,000ms target** |

**Strategy:** Socket.io-first with Firebase RTDB backup. See `docs/REALTIME_IMPLEMENTATION_PLAN.md`.

---

## 🔐 Security

10 layers of protection:

1. **CORS** — Origin allowlist
2. **Security Headers** — HSTS, CSP, X-Frame
3. **Rate Limiting** — Per-IP sliding window (60 req/min)
4. **Request Size Limit** — 5MB max body
5. **Brute Force Protection** — 5 attempts / 5min lockout
6. **IP Blacklist** — Auto-ban after 20 violations
7. **Input Sanitization** — SQL injection + XSS regex
8. **Crash Protection** — Global exception handler
9. **Nonce Replay Protection** — Server-side dedup
10. **Audit Logging** — Tamper-evident hash-chain

---

## 🧪 Testing

```bash
# Backend tests
cd backend
pytest tests/ -v

# Socket.io integration tests
pytest tests/test_socketio.py -v

# Flutter tests
flutter test
```

---

## 🚢 Deployment

### Backend (Railway)

```bash
# Push to main branch triggers auto-deploy
# Environment variables configured in Railway dashboard
```

### Mobile (Codemagic)

```bash
# Build pipeline configured in codemagic.yaml
# Automatic iOS/Android builds on tag push
```

---

## 📚 Documentation

- [`docs/SETUP_GUIDE.md`](docs/SETUP_GUIDE.md) — Full development setup
- [`docs/REALTIME_IMPLEMENTATION_PLAN.md`](docs/REALTIME_IMPLEMENTATION_PLAN.md) — Real-time optimization plan
- [`docs/NETWORK_CONFIG.md`](docs/NETWORK_CONFIG.md) — Production network hardening
- [`docs/SMOOTH_UI_GUIDE.md`](docs/SMOOTH_UI_GUIDE.md) — UI/UX patterns
- [`docs/TAP_TO_PAY_SETUP.md`](docs/TAP_TO_PAY_SETUP.md) — NFC payment setup

---

## 🤝 Contributing

1. Create feature branch: `git checkout -b feature/nombre`
2. Commit changes: `git commit -am "feat: descripción"`
3. Push branch: `git push origin feature/nombre`
4. Open Pull Request

### Commit Convention

- `feat:` — New feature
- `fix:` — Bug fix
- `perf:` — Performance improvement
- `refactor:` — Code restructuring
- `test:` — Tests only
- `docs:` — Documentation only

---

## 📄 License

Proprietary — All rights reserved.

---

**Version:** 1.0.2+434  
**Repository:** https://github.com/josmash2021-cmd/cruiseapp.2.git
