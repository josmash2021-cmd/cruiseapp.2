# 🗺️ PROJECT MAP — CruiseApp Memory & Navigation Guide

> **Generated:** 2026-06-04  
> **Purpose:** Mapa completo de arquitectura, archivos editables, archivos protegidos y decisiones de seguridad.  
> **Rule:** Antes de editar cualquier archivo, consultar esta guía. Si un archivo está marcado como 🔴 NO TOCAR, requiere aprobación explícita del usuario.

---

## 📦 Stack Técnico

| Capa | Tecnología | Versión |
|------|------------|---------|
| Frontend | Flutter | 3.x (SDK >=3.0.0 <4.0.0) |
| Backend | FastAPI (Python) | 0.115.0 |
| DB | PostgreSQL (Supabase/Railway) | — |
| ORM | SQLAlchemy 2.0 async | 2.0.35 |
| Realtime | Socket.io + SSE (EventBus) + Firebase RTDB (fallback) | — |
| Maps | Mapbox Maps Flutter | ^2.5.0 |
| Pagos | Stripe (primary) + PayPal (secondary) + Apple/Google Pay | — |
| Auth | JWT + HMAC-SHA256 + API Key + bcrypt | — |
| Push | Firebase Cloud Messaging (FCM) | — |
| CI/CD | Codemagic (iOS) + Shorebird OTA (Android) + Railway (backend) | — |

---

## 🗂️ Estructura de Carpetas y Archivos

### 1. Raíz del Proyecto

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `pubspec.yaml` | 🔴 CRÍTICO — NO EDITAR | Dependencias Flutter, versión `1.0.3+480`, assets, launcher icons. Bumpear versión dispara builds automáticos. |
| `analysis_options.yaml` | 🟡 CUIDADO | Reglas del analyzer Dart. Ignora `unused_*` intencionalmente. |
| `codemagic.yaml` | 🔴 CRÍTICO — NO EDITAR | CI/CD iOS/Android. Contiene scripts de firma de código, keystore, certificados, provisioning profiles. |
| `shorebird.yaml` | 🔴 CRÍTICO — NO EDITAR | Config OTA patches Shorebird (`app_id`). |
| `railway.toml` | 🔴 CRÍTICO — NO EDITAR | Deploy backend FastAPI en Railway. |
| `firebase.json` | 🔴 CRÍTICO — NO EDITAR | Config Firebase project (`cruise-af9f1`). |
| `.firebaserc` | 🔴 CRÍTICO — NO EDITAR | Alias de proyecto Firebase. |
| `database.rules.json` | 🔴 CRÍTICO — NO EDITAR | Reglas Firebase Realtime Database (GPS drivers, chat, ratings). |
| `firestore.rules` | 🔴 CRÍTICO — NO EDITAR | Reglas Firestore (trips, users, verifications). |
| `storage.rules` | 🔴 CRÍTICO — NO EDITAR | Reglas Firebase Storage (fotos, documentos, videos). |
| `vercel.json` | 🟡 CUIDADO | Config edge proxy en Vercel. Afecta proxy de API en producción. |
| `netlify.toml` | 🟢 EDITABLE | Redirects de Netlify. |
| `.env.example` | 🟢 EDITABLE | Template de variables de entorno. Documentar nuevas vars aquí. |
| `.gitignore` | 🟢 EDITABLE | Ya ignora `lib/config/env.dart`, `backend/.env`, keystores, build outputs. |
| `.metadata` | 🔴 NO EDITAR | Metadata Flutter. Dice explícitamente "should not be manually edited". |

### 2. Documentación (`docs/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `docs/privacy_policy.md` | 🔴 CRÍTICO — LEGAL | Política de privacidad (GDPR, CCPA, LGPD). Requerido por stores. Cambios requieren revisión legal. |
| `docs/terms_of_service.md` | 🔴 CRÍTICO — LEGAL | Términos de servicio. Requerido por stores. |
| `docs/GAME_NAVIGATION.md` | 🟢 EDITABLE | Sistema de navegación estilo videojuego (isométrico 3D, glow routes). |
| `docs/INFRASTRUCTURE_MIGRATION_PLAN.md` | 🟢 EDITABLE | Plan de migración de región PostgreSQL. |
| `docs/NETWORK_CONFIG.md` | 🟢 EDITABLE | Config de red para funcionar desde cualquier red. |
| `docs/REALTIME_AUDIT.md` | 🟡 REFERENCIA | Auditoría arquitectura real-time (enero 2025). |
| `docs/REALTIME_IMPLEMENTATION_PLAN.md` | 🟡 REFERENCIA | Plan de implementación Socket.io (1,378 líneas). Roadmap. |
| `docs/SETUP_GUIDE.md` | 🟢 EDITABLE | Setup de Mapbox Game Navigation. |
| `docs/SMOOTH_UI_GUIDE.md` | 🟢 EDITABLE | Guía de transiciones fluidas (fadeSlide, scaleFade, shimmer, 60 FPS). |
| `docs/TAP_TO_PAY_SETUP.md` | 🟢 EDITABLE | Guía Stripe Terminal NFC. |

### 3. Archivos de Memoria/Auditoría en Raíz

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `CLAUDE.md` | 🔴 CRÍTICO — NO EDITAR | Biblia del proyecto: stack técnico, trip lifecycle, convenciones de código, bugs conocidos, comandos `/ship`, `/deploy-back`, sub-agentes disponibles. |
| `PROJECT_MEMORY.md` | 🟡 CUIDADO | Memoria arquitectónica completa (99 screens, 29 services). Fuente de verdad secundaria. Mantener sincronizado. |
| `AUDIT_REPORT.md` | 🛑 HISTÓRICO | Auditoría seguridad abril 2026 (146 hallazgos). Referencia para fixes. |
| `AUDIT_REPORT_FINAL.txt` | 🛑 HISTÓRICO | Auditoría diciembre 2024. |
| `AUDIT_SUMMARY_FINAL.txt` | 🛑 HISTÓRICO | Resumen ejecutivo diciembre 2024. |
| `FINAL_AUDIT_REPORT.txt` | 🛑 HISTÓRICO | Reporte final en español. |
| `LAUNCH_READINESS_FINAL.txt` | 🛑 HISTÓRICO | Checklist de lanzamiento. |
| `LAUNCH_VERIFICATION_COMPLETE.txt` | 🛑 HISTÓRICO | Verificación de completitud. |
| `SHOPIFY.md` | 🟡 CUIDADO | Documentación widget VIP Ride en Shopify. Editable solo para cambios Shopify. |
| `TAP_TO_PAY_SETUP.md` | 🟢 EDITABLE | Guía integración Stripe Terminal. |
| `TAP_TO_PAY_SUMMARY.md` | 🟢 EDITABLE | Resumen implementación Tap to Pay. |
| `TAP_TO_PAY_VERIFICATION.md` | 🟢 EDITABLE | Verificación widget en métodos de pago. |
| `VERIFY_TAP_TO_PAY.md` | 🟢 EDITABLE | Checklist final Tap to Pay. |

### 4. CI/CD (`.github/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `.github/workflows/ci.yml` | 🔴 PROTEGIDO | GitHub Actions CI: Flutter analyze + tests, backend pytest. Corre en push/PR a `main`/`develop`. |
| `.github/workflows/build-ios.yml` | 🔴 PROTEGIDO | Build manual de iOS. Afecta builds manuales. |
| `.github/copilot-instructions.md` | 🔴 PROTEGIDO | Instrucciones para AI. Reglas críticas: read-before-edit, no extras, commit after work, bilingual, dispose patterns, lock order PostgreSQL, cancel rule. |
| `.github/agents/*.md` (28 archivos) | 🟡 PROTEGIDOS | Definiciones de sub-agentes especializados. |
| `.github/instructions/dart.instructions.md` | 🟡 PROTEGIDO | Instrucciones Dart/Flutter para agentes. |
| `.github/instructions/python-backend.instructions.md` | 🟡 PROTEGIDO | Instrucciones Python/FastAPI para agentes. |
| `.github/instructions/shopify-js.instructions.md` | 🟡 PROTEGIDO | Instrucciones Shopify JS para agentes. |

---

## 🧠 Backend (`backend/`)

### Archivos de Configuración y Entry Points

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `backend/main.py` | 🟡 IMPORTANTE | Entry point FastAPI + Socket.io + agent startup. 1,656 líneas. 10 capas de seguridad, lifespan optimizado, background tasks. **Cambios en CORS, headers, o startup pueden romper producción.** |
| `backend/config.py` | 🔴 CRÍTICO — NO EDITAR | Secrets de Stripe, Firebase, JWT, HMAC. Contiene credenciales sensibles en runtime. |
| `backend/requirements.txt` | 🟡 CUIDADO | Dependencias Python. Cambios afectan deploy. |
| `backend/Dockerfile` | 🔴 NO EDITAR | Multi-stage build para Railway. |
| `backend/docker-compose.yml` | 🟡 CUIDADO | Infraestructura local. |
| `backend/.env.template` | 🟢 EDITABLE | Template de variables de entorno. **NO debe contener valores reales.** |
| `backend/start.sh` / `start_backend.bat` / `run_server.py` | 🟡 CUIDADO | Scripts de arranque. |
| `backend/railway_helpers.py` | 🔴 NO EDITAR | Helpers específicos de Railway. |
| `backend/db_url.py` | 🟢 EDITABLE | Resolución de DATABASE_URL. |

### Modelos (`backend/models/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `backend/models/database.py` | 🔴 CRÍTICO — CUIDADO | Schema SQLAlchemy (~30 tablas, ~1005 líneas). Engine async con tuning para Supabase PgBouncer. **Cualquier cambio requiere migración correspondiente.** |
| `backend/models/schemas.py` | 🟢 EDITABLE | Pydantic request/response schemas (~247 líneas). |
| `backend/models/quest_models.py` | 🟢 EDITABLE | Modelos del sistema de quests/misiones. |

### Routers (`backend/routers/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `backend/routers/auth.py` | 🟡 IMPORTANTE | ~2,831 líneas. Registro, login, OTP, social, refresh, FCM tokens, Apple Review bypass. |
| `backend/routers/trips.py` | 🟡 IMPORTANTE | ~2,262 líneas. CRUD viajes, status machine, charge, refund, fare breakdown. |
| `backend/routers/drivers.py` | 🟡 IMPORTANTE | ~2,273 líneas. Ubicación, earnings, cashout, Stripe Connect. |
| `backend/routers/dispatch.py` | 🟡 IMPORTANTE | ~1,939 líneas. Dispatch owner, cascade, nearest drivers, SSE stream. |
| `backend/routers/payments.py` | 🟡 IMPORTANTE | ~2,898 líneas. Stripe, PayPal, web checkout, webhooks, Financial Connections. |
| `backend/routers/admin.py` | 🟡 IMPORTANTE | ~2,082 líneas. Panel admin, verifications, stats, cancel-all-active. |
| `backend/routers/support.py` | 🟡 IMPORTANTE | ~2,487 líneas. Chat AI, support bot, action requests, SSE stream. |
| `backend/routers/webhooks.py` | 🟡 IMPORTANTE | ~255 líneas. Stripe webhooks consolidados. |
| `backend/routers/scheduled.py` | 🟢 EDITABLE | Viajes programados. |
| `backend/routers/referrals.py` | 🟢 EDITABLE | Referidos rider (Cruise Cash). |
| `backend/routers/driver_referrals.py` | 🟢 EDITABLE | Referidos driver. |
| `backend/routers/quests.py` | 🟢 EDITABLE | Sistema de misiones. |
| `backend/routers/vip.py` | 🟢 EDITABLE | Menú VIP, bebidas. |
| `backend/routers/uploads.py` | 🟢 EDITABLE | Subida de archivos. |
| `backend/routers/voice.py` | 🟢 EDITABLE | Llamadas/voz. |
| `backend/routers/misc.py` | 🟢 EDITABLE | Misceláneos. |
| `backend/routers/system.py` | 🟢 EDITABLE | Health, métricas. |
| `backend/routers/worker.py` | 🟢 EDITABLE | Tareas en background. |

### Servicios (`backend/services/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `backend/services/fcm_service.py` | 🟡 IMPORTANTE | Firebase Cloud Messaging. Canales prioritarios, auto-limpia tokens stale. |
| `backend/services/socketio_service.py` | 🟡 IMPORTANTE | WebSocket/Socket.io real-time. JWT auth. |
| `backend/services/event_bus.py` | 🟡 IMPORTANTE | SSE in-memory pub/sub. Heartbeat cada 15s. |
| `backend/services/redis_cache.py` | 🟡 IMPORTANTE | Redis wrapper + in-memory fallback. **Reemplazado pickle por JSON en auditoría 2026-06-04.** |
| `backend/services/circuit_breaker.py` | 🟢 EDITABLE | Circuit breaker para APIs externas. |
| `backend/services/query_cache.py` | 🟢 EDITABLE | Cache de consultas DB. |
| `backend/services/email_service.py` | 🟢 EDITABLE | Emails (SMTP, EmailJS). |
| `backend/services/sms_service.py` | 🟢 EDITABLE | Twilio SMS. |
| `backend/services/storage.py` | 🟢 EDITABLE | S3/Railway Bucket storage. |
| `backend/services/checkr_service.py` | 🟢 EDITABLE | Background checks Checkr. |
| `backend/services/openai_support_service.py` | 🟢 EDITABLE | AI support (OpenAI/Claude). |
| `backend/services/cruise_ai_engine.py` | 🟢 EDITABLE | Motor de soporte AI. |
| `backend/services/quest_engine.py` | 🟢 EDITABLE | Motor de quests. |
| `backend/services/n8n_webhooks.py` | 🟢 EDITABLE | Integración n8n. |

### Seguridad y Utilidades (`backend/utils/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `backend/utils/security.py` | 🔴 CRÍTICO — CUIDADO | JWT, bcrypt, HMAC, rate limiting, audit logs (~685 líneas). Cambios aquí afectan toda la seguridad del backend. |
| `backend/utils/helpers.py` | 🟢 EDITABLE | Funciones utilitarias (haversine, utc_now, etc.). |
| `backend/utils/ssn_encryption.py` | 🟡 CUIDADO | Encriptación de SSN. Cambios pueden invalidar datos encriptados. |
| `backend/utils/bounded_cache.py` | 🟢 EDITABLE | TTLCache, BoundedDict. |
| `backend/utils/n8n_trigger.py` | 🟢 EDITABLE | Triggers hacia n8n. |

### Migraciones (`backend/migrations/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `backend/migrations/*.py` (ejecutados) | 🔴 NO EDITAR | Migraciones que ya corrieron en producción. Cambiarlas corrompe el estado de la DB. |
| `backend/migrations/run_migration.py` | 🔴 NO EDITAR | Script de ejecución de migraciones. |
| `backend/migrate.py` | 🔴 NO EDITAR | Migraciones idempotentes. Romperlo = destruir schema de PostgreSQL. |

### Tests (`backend/tests/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `backend/tests/conftest.py` | 🟡 CUIDADO | Fixtures pytest (SQLite in-memory). Modificar requiere reescribir tests. |
| `backend/tests/test_auth.py` | 🟢 EDITABLE | Tests de autenticación. |
| `backend/tests/test_trips.py` | 🟢 EDITABLE | Tests de viajes. |
| `backend/tests/test_payments.py` | 🟢 EDITABLE | Tests de pagos. |
| `backend/tests/test_dispatch.py` | 🟢 EDITABLE | Tests de dispatch. |
| `backend/tests/test_fare.py` | 🟢 EDITABLE | Tests de tarifas. |
| `backend/tests/test_socketio.py` | 🟢 EDITABLE | Tests de WebSocket. |
| `backend/tests/test_stripe_webhooks.py` | 🟢 EDITABLE | Tests de webhooks Stripe. |
| `backend/tests/test_support_chat.py` | 🟢 EDITABLE | Tests de chat AI. |
| `backend/tests/test_upload.py` | 🟢 EDITABLE | Tests de uploads. |
| `backend/tests/test_checkr_service.py` / `test_checkr_webhooks.py` | 🟢 EDITABLE | Tests de background checks. |

### Agentes Autónomos (`backend/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `backend/guardian_agent.py` | 🟡 CUIDADO | Health monitoring, DB integrity. |
| `backend/security_guardian.py` | 🟡 CUIDADO | Threat detection, JWT validation. |
| `backend/ghost_driver_agent.py` | 🟡 CUIDADO | Detección de GPS falso. |
| `backend/safety_monitor_agent.py` | 🟡 CUIDADO | Incidentes, SOS. |
| `backend/document_expiry_agent.py` | 🟢 EDITABLE | Expiración de documentos. |
| `backend/document_approval_agent.py` | 🟢 EDITABLE | Aprobación de documentos. |
| `backend/rating_moderator_agent.py` | 🟢 EDITABLE | Moderación de ratings. |
| `backend/cruise_level_agent.py` | 🟢 EDITABLE | Niveles de conductor. |
| `backend/proactive_support_agent.py` | 🟢 EDITABLE | Soporte proactivo. |
| `backend/wait_timeout_agent.py` | 🟢 EDITABLE | Auto-cancel por timeout. |

### Scripts (`backend/scripts/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `backend/scripts/cancel_via_api.py` | 🟡 CUIDADO | Script de cancelación de viajes por API. **Credenciales movidas a variables de entorno en auditoría 2026-06-04.** |
| `backend/scripts/backfill_trip_distance_duration.py` | 🟢 EDITABLE | Backfill de distancia/duración. |
| `backend/scripts/cancel_active_trip.py` | 🟢 EDITABLE | Cancelación de viaje activo. |
| `backend/scripts/patch_auth.py` | 🟢 EDITABLE | Parche de auth. |

---

## 📱 Frontend Flutter (`lib/`)

### Configuración (`lib/config/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `lib/config/app_config.dart` | 🟢 EDITABLE | Configuración global de la app. |
| `lib/config/api_keys.dart` | 🟡 CUIDADO | Proxy que lee claves desde `Env` y `String.fromEnvironment`. Si `env.dart` falta, la app no compila. |
| `lib/config/app_theme.dart` | 🟢 EDITABLE | Temas de la app. |
| `lib/config/env.template.dart` | 🟢 EDITABLE | Plantilla para variables de entorno locales. |
| `lib/config/env.dart` | 🔴 NO COMMITEAR | **No existe en repo** (gitignorado). Requiere `--dart-define` para CI. |
| `lib/config/feature_flags.dart` | 🟢 EDITABLE | Feature flags con Firebase Remote Config. |
| `lib/config/mapbox_config.dart` | 🟢 EDITABLE | Config de Mapbox. |
| `lib/config/map_styles.dart` | 🟢 EDITABLE | Estilos de mapa custom. |
| `lib/config/page_transitions.dart` | 🟢 EDITABLE | Transiciones de navegación. |
| `lib/config/smooth_transitions.dart` | 🟢 EDITABLE | Transiciones fluidas. |
| `lib/config/theme_notifier.dart` | 🟢 EDITABLE | Notificador de tema. |

### Entry Point y Servicios Críticos (`lib/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `lib/main.dart` | 🟡 IMPORTANTE | **Núcleo de la app.** 1,228 líneas. Inicialización por fases (Group 1 / Group 2), manejo de errores global, FCM background handler, navegación imperativa. **Cambios en orden de init pueden romper Firebase, Mapbox o Stripe.** |
| `lib/firebase_options.dart` | 🔴 CRÍTICO — CUIDADO | Configuración hardcodeada de Firebase. Contiene API keys reales. No es ideal pero es funcional. |
| `lib/services/api_service.dart` | 🟡 IMPORTANTE | 3,801 líneas. Núcleo de backend. Headers HMAC, retry, circuit breaker. Cualquier cambio afecta toda la app. |
| `lib/services/security_service.dart` | 🟡 CUIDADO | 10 capas de defensa. Cambios pueden invalidar datos encriptados en dispositivos de usuarios. |
| `lib/services/user_session.dart` | 🟡 CUIDADO | Datos de usuario local. Cambios en keys de SharedPreferences pueden causar pérdida de sesión o fotos. |
| `lib/services/socket_service.dart` | 🟡 IMPORTANTE | Socket.io real-time. Heartbeat cada 15s, reconexión automática. |
| `lib/services/gps_service.dart` | 🟡 IMPORTANTE | Dual upload: Socket.io cada 1s + Firebase RTDB cada 5s. Delta compression. |
| `lib/services/notification_service.dart` | 🟡 IMPORTANTE | FCM + flutter_local_notifications. Canales personalizadas, sonidos custom. |
| `lib/services/tap_to_pay_service.dart` | 🟡 CUIDADO | Stripe Terminal SDK. Solo Android en producción. `locationId` hardcodeado. |
| `lib/services/payment_service.dart` | 🟢 EDITABLE | Wrapper de Google Pay / Apple Pay. |
| `lib/services/background_service.dart` | 🟢 EDITABLE | Foreground service para Android. |

### Screens (`lib/screens/`)

**Flujo de Pasajero (Rider):**
| Screen | Estado | Descripción |
|--------|--------|-------------|
| `lib/screens/splash_screen.dart` | 🟢 EDITABLE | Animación de inicio + `heavyInit()`. |
| `lib/screens/welcome_screen.dart` / `welcome_back_screen.dart` | 🟢 EDITABLE | Onboarding / re-bienvenida. |
| `lib/screens/login_screen.dart` / `login_verify_screen.dart` / `create_password_screen.dart` | 🟢 EDITABLE | Auth por email/teléfono + OTP. |
| `lib/screens/home_screen.dart` | 🟡 IMPORTANTE | **Home principal.** 2,219 líneas. Mapa interactivo, sheet inferior, favoritos, notificaciones. Usa `part` files. |
| `lib/screens/pickup_dropoff_search_screen.dart` | 🟢 EDITABLE | Búsqueda de direcciones (Google Places). |
| `lib/screens/choose_ride_type_screen.dart` | 🟢 EDITABLE | Selección de tipo de vehículo. |
| `lib/screens/ride_request_screen.dart` / `searching_driver_screen.dart` | 🟢 EDITABLE | Solicitud de viaje y búsqueda de conductor. |
| `lib/screens/rider_tracking_screen.dart` | 🟡 IMPORTANTE | **Tracking en vivo** del conductor. |
| `lib/screens/ride_rating_screen.dart` / `trip_receipt_screen.dart` | 🟢 EDITABLE | Post-viaje. |
| `lib/screens/scheduled_rides_screen.dart` / `schedule_booking_screen.dart` | 🟢 EDITABLE | Viajes programados. |
| `lib/screens/airport_terminal_sheet.dart` | 🟢 EDITABLE | Flujo de aeropuerto. |
| `lib/screens/chat_screen.dart` | 🟢 EDITABLE | Chat rider-driver en tiempo real. |
| `lib/screens/wallet_screen.dart` / `payment_method_screen.dart` / `tap_to_pay_screen.dart` | 🟢 EDITABLE | Pagos y billetera. |
| `lib/screens/account_screen.dart` / `edit_profile_screen.dart` / `profile_photo_screen.dart` | 🟢 EDITABLE | Perfil. |

**Flujo de Conductor (Driver):**
| Screen | Estado | Descripción |
|--------|--------|-------------|
| `lib/screens/driver/driver_login_screen.dart` / `driver_signup_screen.dart` | 🟢 EDITABLE | Auth específico de conductor. |
| `lib/screens/driver/driver_pending_review_screen.dart` | 🟢 EDITABLE | Pantalla de espera de aprobación. |
| `lib/screens/driver/driver_home_screen.dart` | 🟡 IMPORTANTE | **Dashboard conductor.** 2,297 líneas. Mapa, stats diarios, botón Go Online. |
| `lib/screens/driver/driver_online_screen.dart` / `driver_online_map.dart` / `driver_online_widgets.dart` | 🟢 EDITABLE | Conductor en línea recibiendo ofertas. |
| `lib/screens/driver/driver_offers_screen.dart` | 🟢 EDITABLE | Lista de ofertas entrantes. |
| `lib/screens/driver/driver_trip_accept_screen.dart` / `trip_accepted_screen.dart` | 🟢 EDITABLE | Aceptación y navegación al pickup. |
| `lib/screens/driver/driver_earnings_screen.dart` / `driver_analytics_screen.dart` | 🟢 EDITABLE | Ingresos y estadísticas. |
| `lib/screens/driver/driver_documents_screen.dart` / `license_scanner_screen.dart` / `background_check_consent_screen.dart` | 🟢 EDITABLE | Verificación de identidad y documentos. |
| `lib/screens/driver/driver_vehicle_screen.dart` | 🟢 EDITABLE | Gestión del vehículo. |
| `lib/screens/driver/driver_settings_screen.dart` / `driver_menu_screen.dart` | 🟢 EDITABLE | Configuración. |
| `lib/screens/driver/cruise_level_screen.dart` | 🟢 EDITABLE | Sistema de niveles/insignias. |

### Mapas (`lib/map/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `lib/map/unified_map_service.dart` | 🔴 CRÍTICO — CUIDADO | **Singleton persistente** de Mapbox. Evita múltiples instancias (PlatformView). Pantallas manipulan capas lógicas encima. |
| `lib/map/camera_director.dart` | 🟢 EDITABLE | Director de cámara del mapa. |
| `lib/map/map_layer_manager.dart` | 🟢 EDITABLE | Gestor de capas del mapa. |
| `lib/map/tracking_map_*.dart` | 🟢 EDITABLE | Widgets de mapa de tracking. |

### Navegación y Estado (`lib/navigation/`, `lib/state/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `lib/navigation/nav_state_machine.dart` | 🟡 IMPORTANTE | Máquina de estados de fases de viaje del conductor. |
| `lib/navigation/route_service.dart` | 🟢 EDITABLE | Servicio de rutas. |
| `lib/navigation/smooth_motion.dart` | 🟢 EDITABLE | Movimiento suave del coche en mapa. |
| `lib/navigation/car_renderers.dart` | 🟢 EDITABLE | Renderizado de coches. |
| `lib/navigation/game_car_renderer.dart` | 🟢 EDITABLE | Renderer de coche estilo juego. |
| `lib/navigation/offers_controller.dart` | 🟢 EDITABLE | Controlador de ofertas. |
| `lib/state/accessibility_notifier.dart` | 🟢 EDITABLE | Notificador de accesibilidad. |
| `lib/state/rider_trip_controller.dart` | 🟢 EDITABLE | Controlador de viaje del pasajero. |

### Modelos (`lib/models/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `lib/models/ride_offer.dart` | 🟢 EDITABLE | Oferta para conductor. Factory `fromJson` robusto. |
| `lib/models/airport_models.dart` | 🟢 EDITABLE | Modelo rico de aeropuertos. |
| `lib/models/chat_message.dart` | 🟢 EDITABLE | Mensajes de chat rider-driver. |
| `lib/models/lat_lng.dart` | 🟢 EDITABLE | Modelo propio simple de coordenadas. |

### Widgets (`lib/widgets/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `lib/widgets/*.dart` | 🟢 EDITABLE | Widgets reutilizables: pines dorados, avatares, paneles de tracking, insignias de nivel, etc. |

### Localización (`lib/l10n/`)

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `lib/l10n/app_localizations.dart` | 🟡 CUIDADO | **3,817 líneas.** Localización monolítica (inglés/español inline, no usa ARB). Cambios grandes requieren cuidado. |

### Plataformas Nativas

| Carpeta/Archivo | Estado | Descripción |
|-----------------|--------|-------------|
| `android/app/build.gradle.kts` | 🔴 CRÍTICO — NO EDITAR | Config de firma de Shorebird/Android. Rompe builds signed de Play Store. |
| `android/app/google-services.json` | 🔴 CRÍTICO — SENSIBLE | Credenciales Firebase. **No subir a repos públicos.** |
| `android/app/src/main/AndroidManifest.xml` | 🟡 CUIDADO | Permisos de localización, cámara, NFC, Bluetooth. |
| `ios/Runner/Info.plist` | 🟡 CUIDADO | Bundle ID, URL schemes, Google OAuth client ID hardcodeado, permisos de privacidad. |
| `ios/Runner/GoogleService-Info.plist` | 🔴 CRÍTICO — SENSIBLE | Credenciales Firebase iOS. |
| `ios/Runner/PrivacyInfo.xcprivacy` | 🟢 EDITABLE | Manifest de privacidad de Apple. |
| `ios/Runner/Runner.entitlements` | 🟡 CUIDADO | Entitlements (Apple Pay / Push). |
| `web/index.html` | 🟡 CUIDADO | Contiene Google Maps API key expuesta (`AIzaSyALnqq4-_jJLUCLxSJaWZGZHgw27RVE78Y`). |
| `web/manifest.json` | 🟢 EDITABLE | Manifest de Flutter web. |

---

## 🧪 Tests

| Archivo | Estado | Descripción |
|---------|--------|-------------|
| `test/widget_test.dart` | 🟢 EDITABLE | Smoke test básico. |
| `test/background_check_test.dart` | 🟢 EDITABLE | Lógica de background check. |
| `test/services_test.dart` | 🟢 EDITABLE | Tests de servicios. |

---

## 🔒 Reglas de Seguridad para Ediciones

### NUNCA hacer esto sin autorización explícita:
1. Editar `pubspec.yaml`, `codemagic.yaml`, `shorebird.yaml`, `railway.toml`.
2. Editar archivos de firma/certificados (`android/app/build.gradle.kts` signing configs, `ios/Runner.xcodeproj/`).
3. Editar reglas de Firebase (`database.rules.json`, `firestore.rules`, `storage.rules`).
4. Editar migraciones ya ejecutadas (`backend/migrations/*.py`).
5. Editar `backend/models/database.py` sin plan de migración correspondiente.
6. Editar `backend/utils/security.py` sin tests de regresión exhaustivos.
7. Commit de secretos (`lib/config/env.dart`, `.env`, `backend/.env`, `*.jks`, `*.keystore`).
8. Editar documentos legales (`docs/privacy_policy.md`, `docs/terms_of_service.md`).

### SIEMPRE hacer esto antes de editar código:
1. Consultar `CLAUDE.md` para convenciones del proyecto.
2. Verificar que el archivo no esté marcado como 🔴 en este mapa.
3. Asegurar que `flutter analyze` pase después de editar archivos `.dart`.
4. Asegurar que `pytest` pase después de editar archivos Python.
5. Usar `try/finally` y `.dispose()` en controllers de Flutter.
6. Validar Pydantic en inputs de FastAPI.
7. Usar SQLAlchemy ORM o `text()` con parámetros nombrados (nunca concatenar SQL).

---

## ⚠️ Vulnerabilidades Conocidas y Estado

| # | Hallazgo | Estado | Archivo |
|---|----------|--------|---------|
| 1 | Secrets hardcodeados en script de cancelación | ✅ **CORREGIDO** 2026-06-04 | `backend/scripts/cancel_via_api.py` |
| 2 | OpenAI API key real en `.env.template` | ✅ **CORREGIDO** 2026-06-04 | `backend/.env.template` |
| 3 | `pickle` en `redis_cache.py` (RCE potencial) | ✅ **CORREGIDO** 2026-06-04 | `backend/services/redis_cache.py` |
| 4 | `python-jose` con CVEs conocidos | 🔄 **PENDIENTE** migrar a `PyJWT` | `backend/requirements.txt` |
| 5 | CORS fallback incluye localhost | 🔄 **PENDIENTE** quitar fallback en prod | `backend/main.py` |
| 6 | Endpoint `/photos/{filename}` público | 🔄 **PENDIENTE** evaluar URLs firmadas | `backend/routers/auth.py` |
| 7 | API keys Firebase hardcodeadas en Flutter | 🔄 **PENDIENTE** rotar y mover a CI/CD | `lib/firebase_options.dart` |
| 8 | Google Maps API key en `web/index.html` | 🔄 **PENDIENTE** mover a variable de entorno | `web/index.html` |
| 9 | Stripe pk_live en assets de pago | 🔄 **PENDIENTE** rotar clave y mover a config | `assets/pay/*` |
| 10 | Secretos expuestos en historial de git | 🔄 **PENDIENTE** limpiar con `git-filter-repo` | Historial de commits |

---

## 🚀 Comandos Importantes del Proyecto

| Comando | Descripción |
|---------|-------------|
| `/ship` | Build + deploy Flutter (según `CLAUDE.md`). |
| `/deploy-back` | Deploy backend a Railway. |
| `flutter analyze` | Corre automáticamente después de editar archivos `.dart` (PostToolUse hook). |
| `pytest backend/tests/` | Corre tests del backend. |
| `railway up --detach` | Deploy backend manual a Railway. |

---

## 📝 Notas de Contexto

- **Versión actual:** `1.0.3+480` (`pubspec.yaml`). Documentación desfasada (`README.md` dice `1.0.2+434`, `PROJECT_MEMORY.md` dice `1.0.2+435`, `CLAUDE.md` dice `1.0.2+301`).
- **Backend URL:** `https://cruiseapp2-production.up.railway.app`
- **Regla de oro:** *"NUNCA uses `--no-verify` en commits. Si un pre-commit hook falla, arregla el root cause."*
- **Build iOS:** Codemagic. **Build Android:** Shorebird OTA. No hacer `flutter build apk` manual.
- **Preferencia de idioma:** Bilingüe (español/inglés) en código y docs.
