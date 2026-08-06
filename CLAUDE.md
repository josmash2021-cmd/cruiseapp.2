# CLAUDE.md — Cruise App

Este archivo se carga automáticamente en cada sesión. Contiene el contexto completo del proyecto para que Claude pueda ayudar sin preguntas repetidas.

---

## Qué es Cruise

App de ride-sharing premium estilo Uber/Lyft. Rider pide viaje → driver acepta → trip se ejecuta → pago automático → rating.

**Tres apps Flutter** comparten el mismo backend:
- **Rider app** — pedir viajes, tracking en vivo, pagos
- **Driver app** — aceptar viajes, GPS, cobros, earnings
- **Dispatch app** — panel admin para operadores humanos (gestión manual de trips, drivers, soporte)

---

## Stack Técnico

### Backend
- **Framework:** Python FastAPI (async)
- **DB:** Supabase PostgreSQL (migrado desde Railway Postgres — latencia ~50ms vs ~400ms anteriores)
- **Real-time:** Firebase Firestore (trips en vivo) + Firebase Realtime Database (GPS de drivers)
- **Auth:** Firebase Auth + JWT propio
- **Notifications:** FCM (Firebase Cloud Messaging)
- **Payments:** Stripe (Connect para drivers + regular checkout para riders)
- **SMS:** Twilio
- **Hosting backend:** Railway (proyecto `Cruise in Ride`, env `production`, servicio `cruiseapp.2`, URL `cruiseapp2-production.up.railway.app`, región US East, volumen `cruiseapp-volume` en `/app/data`)

### Frontend (Flutter)
- **Framework:** Flutter 3.x, Dart SDK >=3.0.0
- **Maps:** Mapbox (`mapbox_maps_flutter`)
- **State:** StatefulWidget nativo (no Riverpod/Bloc)
- **Tema:** Dark mode — negro `#000000` + gold `#FFD700` + fuente **Poppins**
- **Storage local:** Hive + shared_preferences + flutter_secure_storage
- **ML:** Google ML Kit (face detection + OCR para verificación de documentos)

### Deployment
- **iOS:** Codemagic (CI/CD cloud)
- **Android:** Shorebird (OTA patches, builds más rápidos)
- **Backend:** Railway CLI (`railway up --detach`)
- **Dispatch panel:** separado, Flutter web

---

## Versionado

- **Archivo:** `pubspec.yaml` línea 5 → `version: 1.0.2+XXX`
- **Formato:** `1.0.2+BUILD_NUMBER` — solo bumpeas el build number (+291, +292, +293...)
- **Versión actual:** 1.0.5+506 (leer siempre `pubspec.yaml` línea 5 — este número queda viejo rápido)
- **Usa `/ship`** — es el wrapper oficial que bumpea, valida Python, commitea con mensaje auto-generado, hace push y deploya el backend en un solo paso. Ver abajo en "Slash commands disponibles".

### Workflow de bump de versión

```bash
# 1. Editar pubspec.yaml (bump del build number)
# 2. Commit con mensaje: "chore: bump version to 1.0.2+XXX"
# 3. Push a main
# 4. Lanzar builds (Shorebird Android + Codemagic iOS)
```

---

## Comandos Clave

### Backend (Railway)

```bash
# Deploy directo (bypassa GitHub CI, usa filesystem local)
railway up --detach

# Ver logs en vivo
railway logs

# Ver logs de build (para debuggear deploys fallidos)
railway logs --build
```

**⚠️ IMPORTANTE:**
- `git push` también triggea un deploy vía GitHub integration — a veces falla el healthcheck por problemas de red de Railway. Si pasa, usa `railway up --detach` para bypassarlo.
- **NUNCA** uses `--no-verify` en commits. Si un pre-commit hook falla, arregla el root cause.
- Siempre **push al remote después de cada cambio** (preferencia del usuario, está en memoria).

### Git

```bash
git add <archivos-específicos>          # NUNCA git add -A o git add .
git commit -m "mensaje descriptivo"
git push                                 # SIEMPRE después de commit
```

---

## Estructura del Proyecto

```
cruiseapp.2/
├── backend/                    # FastAPI backend
│   ├── main.py                # Entry point, scheduler loops, lifespan
│   ├── config.py              # Env vars, Stripe, Firebase config
│   ├── routers/
│   │   ├── trips.py           # ⭐ CRÍTICO — trip lifecycle, status transitions
│   │   ├── dispatch.py        # Dispatch flow, auto-cascade, offer/accept/reject
│   │   ├── drivers.py         # Driver auth, location, earnings, cashouts
│   │   ├── auth.py            # Login, signup, JWT
│   │   ├── payments.py        # Stripe webhooks, fare splits, rider methods
│   │   ├── admin.py           # Admin endpoints, pricing config
│   │   └── support.py         # Support chat, action requests
│   ├── models/
│   │   ├── database.py        # SQLAlchemy models (User, Trip, DispatchOffer...)
│   │   └── schemas.py         # Pydantic validation
│   ├── services/
│   │   ├── fcm_service.py     # Push notifications
│   │   ├── event_bus.py       # Server-side event pub/sub
│   │   └── firestore_sync.py  # Postgres → Firestore mirror
│   ├── utils/
│   │   ├── security.py        # JWT, password hashing, API key check
│   │   └── helpers.py         # utc_now, haversine, trip_dict
│   ├── ghost_driver_agent.py  # ⭐ Background agent — detecta drivers fantasma
│   ├── cruise_level_agent.py  # Rating-based driver tier evaluation
│   └── migrate.py             # Schema migrations (idempotent)
│
├── lib/                        # Flutter app (rider + driver)
│   ├── main.dart
│   ├── screens/
│   │   ├── rider_tracking_screen.dart          # ⭐ CRÍTICO
│   │   ├── driver/
│   │   │   ├── driver_trip_accept_screen.dart  # ⭐ CRÍTICO
│   │   │   └── driver_online_controller.dart   # SSE + online state
│   │   └── ...
│   ├── controllers/
│   │   └── rider_tracking_controller.dart      # ⭐ CRÍTICO — poll + Firestore listener + phases
│   └── services/
│       ├── api_service.dart                    # HTTP client al backend
│       └── local_data_service.dart             # Persistencia local
│
├── pubspec.yaml               # Flutter deps + version
├── shorebird.yaml             # Shorebird config
├── CLAUDE.md                  # Este archivo
└── .claude/
    ├── agents/                # Sub-agentes custom (backend-architect, code-reviewer, python-pro, ui-ux-designer)
    ├── skills/                # Skills reutilizables
    └── settings.json
```

---

## Conceptos de Dominio

### Trip Lifecycle (state machine)

```
requested → accepted → driver_en_route → arrived → in_trip → completed
         ↘               ↓                   ↓         ↓
           cancelled  cancelled           cancelled  cancelled
```

**Canonical statuses** (usados en DB y transitions):
- `requested` — rider creó el trip, esperando driver
- `accepted` — driver aceptó (set por `/dispatch/driver/accept`)
- `driver_en_route` — driver manejando al pickup
- `arrived` — driver llegó al pickup, esperando al rider
- `in_trip` — rider abordó, trip en progreso
- `completed` — terminado, pago procesado
- `cancelled` — terminal (con dos 'L', NO `canceled`)

**Aliases en `_STATUS_ALIASES`** ([backend/routers/trips.py:43-56](backend/routers/trips.py#L43)): convierten variantes del Flutter driver app a canónicos (ej: `on_trip` → `in_trip`, `driver_arrived` → `arrived`, `canceled` → `cancelled`).

### Rider Tracking Phases (Flutter)

Enum `_TrackPhase` en [lib/controllers/rider_tracking_controller.dart](lib/controllers/rider_tracking_controller.dart):

- `arriving` — fase inicial, driver manejando hacia rider
- `arrived` — driver en pickup
- `onTrip` — trip en progreso
- `nearDestination` — cerca del destino
- `completed` — terminado, navega a rating

### Commission Splits por vehicle type

```python
# backend/routers/trips.py
_COMMISSION_BY_TYPE = {
    "sedan":    (0.40, 0.60),  # (platform, driver)
    "comfort":  (0.40, 0.60),  # 60% driver
    "premium":  (0.35, 0.65),  # 65% driver
    "vip":      (0.30, 0.70),  # 70% driver
}
```

### Dispatch Cascade

Cuando un rider pide un trip:
1. Se crean `DispatchOffer` para los N drivers más cercanos (orden: haversine SQL)
2. `_auto_cascade()` en `dispatch.py` re-ofrece cada 45 segundos al siguiente driver si el actual no acepta
3. Máximo 10 intentos antes de que el trip caiga en "no drivers found"
4. Ghost Driver Agent (background, cada 90s) detecta drivers inactivos >20 min y los fuerza offline — **PERO** ahora excluye drivers con trips activos

### Active Trip Statuses

```python
_ACTIVE_TRIP_STATUSES = [
    "requested", "accepted", "driver_en_route",
    "arrived", "in_trip",
    "scheduled_accepted", "scheduled_active",
]
```

Drivers con trips en estos estados NO deben ser forzados offline por el ghost agent.

---

## Datos de Prueba

- **Driver test:** #3 — Jhon Martinez
- **Proyecto Railway:** `Cruise in Ride` / env `production` / servicio `cruiseapp.2`
  - Project ID: `82c2a240-f567-4cd9-acb1-62d0f0e7d71e`
  - El CLI ya está autenticado localmente (`railway whoami` → josmash2021@gmail.com), no hace falta token
  - **NUNCA correr `railway variables` sin filtrar** — imprime secretos en claro. Para listar solo nombres: `railway variables --kv | cut -d= -f1 | sort`
- **Git remote:** `https://github.com/josmash2021-cmd/cruiseapp.2`
- **Git user:** `josmash2021-cmd`
- **Branch principal:** `main`

---

## Convenciones de Código

### Backend (Python)

- **Logging:** usar `logging.info/warning/error`, NUNCA `print()`
- **Async:** todos los endpoints FastAPI son `async def`, usar `await` en queries Supabase/SQLAlchemy
- **Error handling:** `raise HTTPException(status_code, detail)` en endpoints, nunca retornar `{"error": ...}`
- **Auth:** usar `Depends(_get_current_user)` para endpoints protegidos
- **Queries:** SQLAlchemy ORM para CRUD, `text()` raw SQL solo cuando el ORM sea demasiado lento (ej: `/trips/{id}/poll`)
- **Timestamps:** siempre UTC con `datetime.now(timezone.utc)` o `utc_now()` helper
- **Status transitions:** pasar por `_VALID_TRANSITIONS` y normalizar con `_STATUS_ALIASES`

### Frontend (Flutter/Dart)

- **setState safety:** SIEMPRE usar helper `_setState()` que verifica `mounted` antes
- **Dispose:** cancelar todos los `StreamSubscription`, `Timer`, `AnimationController` en `dispose()`
- **Async guards:** `if (!mounted) return;` después de cada `await`
- **Tema:** negro + gold + Poppins (no Material Design default)
- **Debug logs:** `debugPrint('[NombreScreen] mensaje')` con prefijo de screen/controller
- **GPS smoothing en map markers:** usar [lib/utils/smooth_motion.dart](lib/utils/smooth_motion.dart) — `SmoothMotion()` con `setTarget(lat, lng, bearing)` + `tick(dtSec)`. NO reintroducir decay exponencial (`_pow(1-decay, dt)`) — el viejo helper está eliminado. La excepción es [lib/controllers/rider_tracking_controller.dart](lib/controllers/rider_tracking_controller.dart) que tiene su propio interp route-projected.

---

## Qué NO Tocar Sin Permiso Explícito

- **`backend/migrate.py`** — migraciones idempotentes, romperlas destruye producción
- **`backend/config.py`** — secrets de Stripe, Firebase, etc.
- **`.env`** y archivos con credenciales
- **`backend/models/database.py`** — schema SQLAlchemy, cambios aquí requieren migración correspondiente
- **`android/app/build.gradle`** — firma de Shorebird
- **`ios/Runner.xcodeproj/`** — firma de Codemagic
- **Commits de versión** — no bumpear `pubspec.yaml` sin que el usuario lo pida explícitamente

---

## Bugs Conocidos / Historial Reciente

### v1.0.2+301 — 2026-04-11 (commit `ff0b4a7d`, pendiente build)

1. **Rider overlay "confirmar pickup" se repetía después de tap** — [lib/screens/rider_tracking_screen.dart:529](lib/screens/rider_tracking_screen.dart#L529). El `onConfirmed` callback reseteaba `_confirmPickupShown = false` inmediatamente, pero el backend sigue con status `arrived` hasta que el driver tape Start Ride. El próximo poll volvía a mostrar el overlay. Fix: mantener el guard `true`, solo hide el overlay. El guard se resetea correctamente en `_transitionToOnTrip()` cuando llega `in_trip`.

2. **Driver sliders (Arrived / Start Ride) se reseteaban al volver de Google Maps** — [lib/screens/driver/driver_home_screen.dart:2023](lib/screens/driver/driver_home_screen.dart#L2023). Cuando el driver abría Google Maps con `_openNativeMaps()` y volvía al app, `didChangeAppLifecycleState(resumed)` llamaba `_resumeActiveTrip()` → pusheaba una nueva `DriverTripAcceptScreen` encima de la existente con `arrivedAtPickup/rideStarted` derivados del status de Firestore (atrasado). Lo mismo con el poll de 15s. Fix: guard `ModalRoute.of(context)?.isCurrent != true` → skip si DriverHomeScreen no es el route visible.

3. **Driver gold-dot / nav-car con "catch-up-then-stall"** — [lib/screens/driver/driver_online_controller.dart:966](lib/screens/driver/driver_online_controller.dart#L966). El `_onSmoothTick` usaba decay exponencial 14%/frame, lo cual decelera al acercarse al target. Se sentía drifty. Reemplazado por `SmoothMotion` (`lib/utils/smooth_motion.dart`) — constant-velocity advance + shortest-arc bearing low-pass + 4s extrapolation freeze. También subí el throttle RTDB del rider de 125ms → 66ms (8 Hz → 15 Hz) para alimentar mejor su `_interpolate` route-projected.

### v1.0.2+292 — fixes desplegados

1. **Ghost agent no kickea drivers con trip activo** — [backend/ghost_driver_agent.py](backend/ghost_driver_agent.py). Antes forzaba offline a drivers inactivos 20 min, incluso si estaban manejando un trip. Ahora consulta `_ACTIVE_TRIP_STATUSES` primero.

2. **Driver-override bypass extendido a admin/dispatch** — [backend/routers/trips.py:675-690](backend/routers/trips.py#L675). Antes solo el driver podía forward-progression desde `cancelled`, ahora también admin/dispatch (el panel dispatch a veces cancela y luego necesita reabrir).

3. **Scheduler escribe `cancelled` (doble L)** — [backend/main.py](backend/main.py). Antes escribía `canceled` (una L), causando mismatch con los string checks del frontend.

4. **Rider tracking no ignora `cancelled` en fase arriving** — [lib/controllers/rider_tracking_controller.dart:646](lib/controllers/rider_tracking_controller.dart#L646). El guard "stale cancelled" ignoraba cancels legítimos durante la fase inicial, dejando el rider atascado polleando. Ahora solo ignora en fases `onTrip`/`nearDestination`.

5. **Mojibake en drivers.py:410** — fix(drivers): remove corrupted mojibake chars. Carácter `â€"` corrupto rompía el parser Python al import.

### Issues abiertos

- **Driver phone backgrounding** — cuando el driver bloquea el teléfono durante un trip, el heartbeat se detiene. El ghost agent ahora no lo kickea (fix ghost), pero el GPS deja de actualizar. Posible solución: background isolate en Flutter para mantener GPS activo.
- **FCM token stale para driver #3** — push notifications fallan con "Requested entity was not found". Necesita refresh del token.
- **v301 no tiene build publicado todavía** — los 3 fixes de arriba están en `main` pero NO en rider/driver phones hasta que corras Codemagic iOS + Shorebird Android.

---

## Workflows Comunes

### Fix → Deploy backend

```bash
# 1. Editar archivo(s)
# 2. Commit
git add backend/routers/trips.py
git commit -m "fix(trips): descripción corta"
# 3. Push (triggea GitHub CI deploy)
git push
# 4. Opcional: bypass GitHub deploy con railway up directo
railway up --detach
# 5. Verificar logs
railway logs | tail -30
```

### Bump de versión + Build

```bash
# 1. Edit pubspec.yaml version line
# 2. Commit
git add pubspec.yaml
git commit -m "chore: bump version to 1.0.2+293"
git push
# 3. Lanzar Shorebird Android (OTA patch)
#    Comando: [PENDIENTE — confirmar con usuario]
# 4. Lanzar Codemagic iOS
#    Método: [PENDIENTE — confirmar con usuario]
```

---

## Notas del Usuario

- **OS:** Windows 11 Home, repo en `C:\Users\josma\Desktop\cruiseapp.2`. Shell Git Bash disponible (sintaxis Unix, forward slashes, `/dev/null` no `NUL`) y PowerShell 5.1
- **Workflow preferido:** siempre push al remote después de cada change set
- **Build workflow:** iOS = Codemagic, Android = Shorebird OTA (NO `flutter build apk` manual)
- **Memoria persistente:** activa en `C:\Users\josma\.claude\projects\c--Users-josma-Desktop-cruiseapp-2\memory\`
- **Sesiones paralelas:** el usuario a veces corre más de una sesión de Claude sobre el mismo working tree. Antes de commitear, `git status` y verificar que el diff de cada archivo sea tuyo; si arrastras cambios ajenos, decláralo en el mensaje del commit
- **Preferencia de comunicación:** respuestas cortas y directas, explicaciones simplificadas cuando pregunta "explícame"

---

## 🛠️ Slash commands disponibles

Todos viven en [.claude/commands/](.claude/commands/). Prefiere usarlos antes de ejecutar cada paso a mano.

| Command | Qué hace | Cuándo usarlo |
|---|---|---|
| **`/ship`** | Bump version + py_compile + commit + push + `railway up --detach` + health check. El wrapper oficial de release. | Al final de cada change set listo para producción. |
| **`/deploy-back`** | Solo deploya el backend a Railway sin bumpear versión. | Hotfix backend-only sin cambios Flutter. |
| **`/bump`** | Solo incrementa el build number en `pubspec.yaml`, commit y push. | Cuando quieres bump manual sin deploy. |
| **`/hotfix <bug>`** | Flujo de diagnóstico → fix → test → deploy para bugs urgentes. | Bug crítico en producción. |
| **`/health`** | Chequeo rápido de Railway logs + errores 5xx + estado del deploy. | Cuando quieres un status check rápido. |
| **`/audit-trips`** | Genera 7 queries SQL para Supabase que buscan trips en estados sospechosos (stuck, orphaned, money drift, ghost). | Revisión de integridad. |
| **`/stuck [optional hint]`** | Para retroceder cuando estamos dando vueltas — analiza últimas 15-20 turns y propone 3 salidas. **Invocado proactivamente** cuando detecto >3 edits al mismo archivo, mismo error dos veces, o user pushback repetido. | Cuando un flujo no avanza. |

## 🪝 Hooks activos

### `PostToolUse` → `flutter analyze` en archivos `.dart`
- **Archivo:** [.claude/settings.json](.claude/settings.json)
- **Dispara cuando:** Edit/Write/MultiEdit termina en `.dart`
- **Modo:** `async` — no bloquea siguientes instrucciones
- **Timeout:** 180s (cold cache ~78s, warm ~1.5s)
- **Output:** silencioso cuando no hay issues; imprime `=== flutter analyze <file> ===` + últimas 30 líneas si hay errores/warnings
- **Para qué sirve:** caza errores Dart localmente antes de que Codemagic falle

## 🤖 Sub-agentes disponibles

En [.claude/agents/](.claude/agents/):

| Agent | Úsalo para |
|---|---|
| **`backend-architect`** | Diseño de features, schemas, API contracts, sync strategies. Invocar proactivamente cuando el user pide "design", "architecture", "schema", "how should we structure". |
| **`python-pro`** | Implementación de endpoints FastAPI, queries Supabase, Pydantic models, bug fixes backend. Invocar cuando el user pide implementación o fix de backend. |
| **`code-reviewer`** | Review de código antes de commit, auditoría de seguridad, verificación de null safety/dispose/mounted. Invocar proactivamente antes de commit de cambios grandes. |
| **`ui-ux-designer`** | Review de layouts, accesibilidad, usabilidad, critical de screens/widgets. Invocar cuando el user comparte screenshot o pide "review design". |
| **`Explore`** | Búsquedas codebase de 3+ queries o investigaciones multi-archivo. Usar en vez de grep manual cuando el alcance es amplio. |
| **`general-purpose`** | Tareas que no encajan en los anteriores. |
| **`shopify-module-dev`** | Crear/editar módulos del widget Shopify VIP Ride. Conoce el patrón VR.register, event bus, null-safe queries, backward compat. Invocar para cualquier cambio en `vip-ride-mod-*.js`. |
| **`shopify-landing-design`** | Modificar landing page HTML/CSS de Shopify. Conoce qué data-attributes son requeridos, el tema (dark+gold), y qué NO tocar. Invocar para cambios visuales del landing. |
| **`shopify-widget-audit`** | Auditar los 14 módulos del widget: conflictos de eventos, missing wiring, null-safety, ES5 compliance, flujos completos. Invocar antes de deploy grande. |
| **`shopify-deploy`** | Upload archivos a Shopify CDN + actualizar URLs en el Liquid. Conoce el store (cruise-8575), el orden de carga, y el patrón de URLs. |

### Reglas de uso pro
- **Paraleliza cuando puedas.** Si necesitas 2 tareas independientes (ej: ghost recovery + money reconciliation), lanza 2 agentes python-pro en el mismo mensaje en vez de secuencial.
- **No duplicar.** Si delegas a un agente, NO toques los mismos archivos en el main thread — trabaja en archivos distintos mientras el agente corre.
- **Code reviewer para cambios grandes.** Después de edits a 5+ archivos o lógica crítica (dinero, auth, trips), pasa por code-reviewer antes de commit.

## 🎯 Workflow pro recomendado

1. **Bug o feature nueva** → primero decide si el scope justifica un agente o es un edit chico
2. **Scope chico (1-2 archivos)** → Edit directo
3. **Scope mediano (3-5 archivos, 1 dominio)** → python-pro o yo mismo con sub-tasks
4. **Scope grande (paralelizable)** → 2-3 agentes en paralelo (1 mensaje, múltiples Agent calls)
5. **Antes de commit** → code-reviewer si fue algo serio, `/stuck` si llevamos vueltas
6. **Para cerrar** → `/ship` (hace todo el flujo end-to-end)

## 🩹 Patrones aprendidos (evitar regresiones)

Estos son bugs que ya arreglé y patterns que deben mantenerse:

1. **Regla estricta cancel (v295):** solo rider propio (sin driver) + admin/dispatch pueden cancelar. Drivers bloqueados con 403 en ambos endpoints (`PATCH /trips/{id}/status` y `POST /trips/{id}/cancel`). Si agregas un nuevo endpoint que toque `status=cancelled`, aplica la misma regla.

2. **Lock order canónico PostgreSQL:** cuando una transacción toca `trips` Y `dispatch_offers`, **siempre** locker `trips` primero. Para cleanups bulk, usa `FOR UPDATE SKIP LOCKED` con `ORDER BY id` determinístico. Ver [backend/routers/dispatch.py:1160](backend/routers/dispatch.py#L1160).

3. **Dedup pre-DB:** los PATCH status idempotentes tienen un cache `_recent_status_patches` (ventana 10s) ANTES del `SELECT FOR UPDATE`. Evita storms.

4. **State machine forward-only:** `_VALID_TRANSITIONS` en trips.py no permite regresiones (ej: `in_trip → arrived` bloqueado). Mantener.

5. **Subcollection Firestore rules:** cuando crees una subcollection nueva, agregar `match /{sub}/{id}` dentro del parent. Las rules no se heredan. Ver [firestore.rules](firestore.rules).

6. **Auth guard defensivo:** cualquier escritura Firestore en pantalla crítica debe llamar `_ensureFirebaseAuth()` antes. Anon session puede expirar.

7. **Circuit breaker:** el cliente usa `_CircuitBreaker` en `api_service.dart` — después de 4 fallos consecutivos se abre 30s. No introducir paths que lo bypaseen.

8. **Localización 100%:** todos los strings user-facing via `S.of(context).xxx`. Nunca hardcode en ES ni EN — hay test implícito vía el hook de flutter analyze + code review.

9. **Lock order Flutter:** `mounted` check **después de cada await**. Siempre. Sin excepción.

10. **Memory reconciliation:** el cron nocturno en `main.py` chequea drift de `pending_balance`. Si ves warnings `[Reconcile] drift=...` en logs, NO auto-fixear — loguear para review humano.

11. **Overlay dedup rider pickup (v301):** el guard `_confirmPickupShown` en [rider_tracking_screen.dart](lib/screens/rider_tracking_screen.dart) debe mantenerse `true` desde el primer arrived hasta que el backend flipee a `in_trip`. NO resetearlo en el `onConfirmed` del overlay — el backend sigue con status `arrived` hasta Start Ride y polls subsecuentes re-disparan el overlay.

12. **No re-pushear DriverTripAcceptScreen (v301):** `DriverHomeScreen._resumeActiveTrip()` debe bailar temprano si no es la ruta top (`ModalRoute.of(context)?.isCurrent != true`). Sin esto, cada `didChangeAppLifecycleState(resumed)` y cada poll de 15s pushea una pantalla nueva encima resetando los sliders locales del driver.

13. **SmoothMotion, no decay exponencial (v301):** todo marcador GPS que no sea route-projected usa [lib/utils/smooth_motion.dart](lib/utils/smooth_motion.dart). El old `_pow(1-decay, dt)` se eliminó — si lo ves en un agent-generated diff, rechazar.

14. **Commit workflow completo:** al cerrar un change set, `git status` primero y commitear TODOS los archivos pendientes agrupados en commits lógicos, no solo los que tocó la sesión actual. Ver [feedback_push_on_finish.md](../.claude/projects/c--Users-Puma-cruiseapp-2/memory/feedback_push_on_finish.md) en memoria.

15. **Session start = ground in reality:** al arrancar una sesión (o después de compact), leer `CLAUDE.md` + `git status` + `git log -10` antes de la primera edición. Memoria se expira; no citar file:line sin verificar primero.

16. **Part files + `static const` = riesgo de build (v494):** cuando una constante se declare como `static const` dentro de una clase y se use dentro de un `part` file en una expresión `const` (ej. `const Duration(seconds: _x)` o `const Icon(color: _y)`), el compilador de iOS puede fallar con "Not a constant expression" / "getter isn't defined". La regla es: **cualquier constante usada en un part file dentro de `const` debe declararse a top-level**, no como `static const` de clase. Ver [lib/screens/home_screen.dart:92](lib/screens/home_screen.dart#L92).

17. **Mapbox annotation dedup: `deleteAll()` antes de `create` + null inmediato en `update` fallido (v494):** `PointAnnotationManager.update()`/`delete()` pueden fallar silenciosamente y dejar el marcador viejo visible, causando dots duplicados cuando el siguiente tick crea uno nuevo. Para evitarlo: (a) antes de cada `mgr.create()` hacer `try { await mgr.deleteAll(); } catch (_) {}`; (b) en el `catchError` de `mgr.update()`, setear `_miniMapAnnot = null` **inmediatamente** y lanzar el `mgr.delete(annot)` fire-and-forget; (c) nunca esperar el `delete` antes de invalidar el handle. Ver [lib/screens/home_screen.dart:290](lib/screens/home_screen.dart#L290).

18. **Neumorfismo = sistema compartido, no helpers locales (v504):** todo diseño nuevo usa `neuBox()` / `neuBase` / `neuSurface` / `neuPressed` de [lib/widgets/neu_style.dart](lib/widgets/neu_style.dart). Idiom establecido: fondo `neuBase`, tarjetas elevadas `neuBox(radius: N)`, íconos en pozos hundidos `neuBox(radius: N, pressed: true)`, secciones agrupadas con divisores hairline `Colors.white.withValues(alpha: 0.05)`. **El sistema es dark-only** — si la pantalla usa `DriverColors`/`AppColors` para light mode, migrar a neu la deja fija en oscuro (aceptado en las ya migradas). **Nunca redeclarar helpers `_neu()` locales**; sobre negro puro (`#000000`) las sombras neumórficas son invisibles, por eso `neuBase` es `#14141A`.

19. **Una sola ruta por path en FastAPI (v506):** FastAPI se queda con la **primera** ruta registrada para un path y **ignora en silencio** las demás — sin error, sin log. Había dos routers declarando `POST /webhooks/stripe` y uno llevaba meses sin ejecutar un solo evento. Antes de agregar un router nuevo, `grep -rn '"/tu/path"' backend --include=*.py`. Si encuentras lógica duplicada de pagos en dos archivos, uno está muerto.

20. **Los handlers de webhook corren DESPUÉS del 200 (v506):** el dispatcher usa `background_tasks.add_task(...)` y responde 200 a Stripe de inmediato. Una excepción dentro de un handler **no se reintenta** — el evento se pierde en silencio y un viaje pagado queda marcado como impago para siempre. Todo parseo dentro de un handler (`int()`, `json.loads()`, indexado de dict) va con guard y fallback, nunca crudo.

21. **Nunca cerrar sesión por un error de servidor (v505):** `getMe()` devuelve `null` para 401, 502, timeout y sin-red por igual. Tratar ese `null` como "token inválido" cerraba la sesión de todos en cada redeploy de Railway (mientras cambia el contenedor devuelve 502). Para validar sesión usar `ApiService.isTokenValid()` — tri-estado: `true` aceptado, `false` rechazado (única razón válida para logout), `null` no concluyente. **Nunca usar `getMe() == null` como señal de logout.**

22. **Stripe Financial Connections no tiene URL hospedada (v504):** `POST /drivers/financial-connections` devuelve `client_secret`, **no** `url`. Vincular banco va por SDK nativo: `Stripe.instance.collectBankAccountToken(clientSecret:)` → `btok_` → backend lo adjunta como external_account. Igual para tarjetas: `createToken()` **exige un `CardField` montado** que buffere el PAN — llamarlo sin campo en pantalla no levanta ninguna hoja nativa, simplemente falla. Tokens de payout necesitan `currency: 'usd'`.

23. **`flutter_stripe` y Mapbox no tienen implementación web:** ambos revientan en Flutter web (`Platform._operatingSystem`, crash en el primer layout). Todo flujo que los use va con guard `kIsWeb` y un mensaje. Por eso las pantallas con mapa no se pueden verificar en `flutter run -d web-server`.

24. **Un ticker parado no redibuja nada (v505):** `GoldLocationDot` solo dispara `onTick` cuando la posición cambia, y `_smoothTicker` del driver se apaga al llegar al target. Con el driver quieto **nadie redibuja el dot**: si el bitmap no estaba listo o el `iconSize` quedó a medias, se queda roto hasta que el driver se mueva. De ahí los watchdogs de 2s en `driver_home_screen` y `driver_online_controller`, que además **reconstruyen el bitmap si `!_goldDot.isReady`** — el rasterizado puede fallar (GPU perdida en background, OOM) y deja `currentBytes` en null para siempre.

25. **Flush de `mgr.update()` que se pierde (v505):** las escrituras a anotaciones Mapbox se saltan cuando el IPC anterior sigue en vuelo. En una animación, **el último paso es el que más probablemente se pierda** — justo el que lleva el valor final. Si un valor tiene que quedar asentado (tamaño, posición final), forzar el flush con reintentos, no confiar en el último frame.

26. **`Navigator.of` / `ScaffoldMessenger.of` / `MediaQuery.of` crashean SOLO en release (v542):** los tres terminan en un `!` dentro del framework (`navigator.dart` → `return navigator!`). El `assert` que explica el error se compila fuera del release, así que lo único que queda es el `!` → `Null check operator used on a null value`. Y **`if (mounted)` no protege**: `deactivateChild()` pone `_parent = null` al instante, pero `State.mounted` (`_element != null`) sigue `true` hasta que corre `dispose()` al final del frame — en esa ventana el lookup ya devuelve null. Como son estáticos chiquitos, AOT los inlinea y Crashlytics culpa a **nuestro** archivo, no al framework. Regla: fuera de `build()` (post-frame callbacks, `Future.delayed`, timers, listeners de `ChangeNotifier`, `onTap` de sheets que se están cerrando) usar **siempre** `maybeOf`. En la librería `ride_request` están los helpers `_nav` / `_rootNav` / `_messenger` ([ride_request_controller.dart](lib/screens/ride_request_controller.dart)); en `build()` sí es seguro el `.of()` directo. Mismo criterio para `ui.Image.toByteData()`, que devuelve null real en iOS cuando se pierde el contexto de raster.

27. **Las reglas de Firebase del repo NO son las desplegadas (2026-08-06):** `database.rules.json` decía `".read": true` en `driver_locations/$driverId` y `drivers/$driverId` — público sin autenticación. Producción **niega** esas rutas con 401, o sea que lo desplegado es más estricto que el archivo. Nada en el repo despliega reglas (no hay `firebase deploy` en CI ni en ningún script), así que llevaban meses divergiendo en silencio. **Consecuencia:** un `firebase deploy` desde el checkout **abre el GPS en vivo de toda la flota a internet**. Antes de tocar reglas: comparar con la consola (Firestore → Rules → historial, Realtime Database → Rules, Storage → Rules) y desplegar solo `--only` el servicio que revisaste. Y al probar RTDB, **las reglas no se heredan hacia arriba**: pedir `/drivers.json` da 401 aunque `/drivers/3.json` sea público, así que hay que probar la ruta hija o el test miente.

28. **`firestore.rules` no se puede endurecer sin arreglar los datos primero (2026-08-06):** casi todas las reglas terminan en `|| isAuthenticated()`, lo que anula las comprobaciones de propiedad de arriba. Pero **borrarlo rompe todo**: `trip_firestore_service.dart` escribe `passengerId: ''` y `driverId: null`, así que cualquier regla de propiedad contra esos campos deja fuera a todos los usuarios. El orden correcto es: (1) escribir los uid reales (`user_{id}`) en esos campos, (2) añadir un custom claim de rol al token en `auth.py` para que dispatch siga viendo todo, (3) recién ahí endurecer las reglas. Igual con `isOwnDoc()`, que compara `auth.uid` (`user_{id}`) contra el id del documento (`sql_{id}`) y por eso es **siempre falso**.

29. **El id del driver ES el id de usuario (2026-08-06):** `GpsService.startTracking()` recibe `ApiService.getCurrentUserId()`, y el token custom del backend es `create_custom_token(f"user_{user.id}")`. Por eso `auth.uid === 'user_' + $driverId` sí funciona en las reglas de RTDB. **Lo que NO funciona** es validar el chat con `newData.child('senderId').val() === auth.uid`: `senderId` se escribe como id numérico en string (`driverId?.toString() ?? 'driver'`), no como `user_{id}`, así que esa validación bloquearía todos los mensajes. Verificar siempre el formato del id antes de escribir una regla de propiedad.

---

**Última actualización:** 2026-08-06 (auditoría Firebase + Railway: pushes perdidos, rate limiter que tumbaba la API, backups efímeros, reglas RTDB/Storage)
