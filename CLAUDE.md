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

30. **El bundle del panel en producción NO sale de la fuente React (2026-10-28):** `backend/dispatch_panel/` se parchea a mano (commits `fix(dispatch)` del 25-28 oct) y `dispatch_app/panel/src` quedó atrás (último commit 13-oct, todavía firma HMAC; producción usa cookie `dispatchPanelAuthFetch`). `tool/deploy_panel.sh` o `npm run build` + copiar = login roto, se pierden los parches y falla `test_dispatch_panel_bundle_guard.py`. Para cambiar el panel: parchear el chunk compilado con anclas únicas (script Python con `assert count == 1`), `node --check` sobre una copia `.mjs`, y correr `test_dispatch_panel_bundle_guard.py` + `test_panel_asset_cache.py`. Detalle de viaje = `assets/index-B68rRA9U.js`; mutaciones = `assets/trips-BkrykFxk.js`. Mantener la fuente React al día en paralelo (commit en `dispatch_app`).

31. **Reasignar desde dispatch es una OFERTA (2026-10-28):** `POST /admin/trips/{id}/reassign` (dispatch.py) desvincula al conductor actual (su oferta pasa a `reassigned`, sin tocar su tasa de aceptación), **NO le avisa** (dueño 2026-11-02: sin push ni buzón ni aviso en pantalla — el viaje solo desaparece de su app con el sonido de viaje en cola cancelado; un push `trip_reassigned` de un servidor viejo se ignora), espeja con `sync_trip_released`, y ofrece al de menor ETA dentro de `radius_miles` (5 por defecto) o al `driver_id` elegido. El radio queda pegado al trip 15 min (`_radius_for_trip`) para que la cascada y el re-offer respeten las 5 millas. Solo en `requested/accepted/driver_en_route`; desde `arrived` es cancel. El driver app sale del viaje por poll (`requested`/otro driver_id) o por `releasedAt` nuevo en el espejo.

32. **Android manda 0 cuando no mide (2026-10-29):** sin Doppler, `geolocator_android` no escribe `speed`/`heading` y `Position` los llena con **0.0** → "parado mirando al norte". NUNCA pasar `pos.speed`/`pos.heading` crudos al motor (SmoothMotion), a `HeadingService` ni a las subidas (`GpsService`, `updateDriverLocation`): usar `measuredSpeedMps(pos)` / `measuredCourseDeg(pos)` de [lib/utils/fix_kinematics.dart](lib/utils/fix_kinematics.dart) (devuelven null si no hubo medición; el 0 real trae `speedAccuracy > 0`).

33. **Un solo canal GPS nativo en Android (2026-10-29):** `geolocator_android` cachea UN stream y se lo da a cada llamador posterior con la configuración del PRIMERO. En pantallas del conductor, todo `getPositionStream` / `ResilientPositionStream` va con `driverLocationSettings(...)`; nunca `const LocationSettings(distanceFilter: 10)` — eso dejó la navegación con una lectura cada ~5 s durante todo el viaje. Ver `_tripGpsSettings()` en [driver_trip_accept_screen.dart](lib/screens/driver/driver_trip_accept_screen.dart).

34. **Invariantes de SmoothMotion (2026-10-29/30)** — [lib/utils/smooth_motion.dart](lib/utils/smooth_motion.dart): (a) si la flecha va POCO adelante del objetivo (< 0.8 s de recorrido), el avance se suaviza a lo largo de la calle sin retroceder (nunca clamp por eje a 0 = "avanza y se detiene"); MÁS adelante vuelve el clamp + resorte que la regresa al carro (sin ese límite quedaba esperando hasta 119 m adelante); (b) el objetivo sin señal sigue `decayedLeadSec` (frena suave hasta 5 s, no se congela a los 2 s); (c) **salto directo** solo si está a > max(120 m, 5 s de recorrido) **y** hay prueba (cuadros pausados > 1 s mientras llegaron ≥ 2 lecturas, o 2 lecturas lejanas distintas); (d) una lectura sin `timestampMs` (modo túnel) borra la base de tiempo — si no, la siguiente real calcula la velocidad sobre todo el hueco — una lectura suelta lejana se desliza. Guardias: `test/arrow_motion_owner_report_test.dart` y `test/arrow_review_regressions_test.dart` (fallan con el código anterior). Giro inmediato (`HeadingService`): brújula suavizada, umbral 3°, cada 200 ms; el re-anclaje al rumbo GPS va con `force: true`. Velocidad/rumbo derivados con ANCLA retenida (no lectura a lectura: a 0.5 s un carro en ciudad nunca pasa el umbral).

35. **Cámara de navegación (2026-10-30, cambiado 2026-11-02):** el mapa gira CON la flecha cuadro a cuadro (`_followCamBearing`), sin resorte — el resorte de ω 4.5 dejaba el mapa ~1 s atrás y en cada giro la flecha giraba en pantalla y se devolvía (dueño: "no modo resorte… no que gire y se devuelva"). Para que un quiebre de la ruta no haga girar el mapa de golpe, el rumbo de la flecha es continuo: `_navAimBearing` = cuerda a un punto 8–30 m adelante POR la ruta (atraviesa esquinas, gira en los metros antes del vértice); bajo 2 m/s usa el rumbo del road lock (sin pre-giro en un semáforo). El fix de 1 Hz y el tick usan la MISMA fuente. Flecha de nav ×1.2 (`_kNavArrowScale`) y escala de oferta forzada a 1.0 al abrir. Modo túnel: lecturas virtuales por la ruta tras 1.5 s sin GPS (≤ 30 s, en ruta ≤ 40 m, ≥ 3 m/s). Guardia: `test/nav_chase_google_like_guard_test.dart`.

36. **Línea de calle en online/offline (2026-10-29/30):** es el trazo map-matched de lecturas PASADAS; pasado su último vértice la proyección es no confiable ([driver_road_lock.dart](lib/map/driver_road_lock.dart)), y al volver del segundo plano (> 5 s) se reinicia trazo + road lock. Solo lecturas ≤ 25 m alimentan el trazo; la flecha acepta hasta 65 m tras 1.2 s sin una buena.

37. **Lo que se sube como ubicación (2026-10-29):** `GpsService.updatePosition(pos, heading?, speed?, accuracyM:)` deriva lo que falta del recorrido (movimiento < max(2 m, 0.4·precisión) = parado) e ignora una lectura > 50 m dentro de 8 s de una buena. Tras un corte se envía con heading/speed `null`, nunca `0, 0`.

38. **Foto de perfil nunca a un dueño adivinado (2026-10-29):** si `/auth/me` falla no hay id 0 ni rol "rider" por defecto: Firebase rechaza `userId <= 0`, la subida cae al servidor (`/auth/photo`, ruta `photos/user_{id}`). Dispatch cambia fotos con `POST /admin/users/{id}/photo` o con "Actualizar" en la tarjeta Foto de perfil (manda el `docType` REAL; una imagen ahí también reemplaza el avatar).

39. **Token FCM = teléfono, no cuenta (2026-10-29):** el último que hace `POST /auth/fcm-token` en un teléfono se queda el token y los demás quedan sin push. El servidor lo anota (`[FCM] token ... moved from user(s) X to user Y`). Si "no le llegó la notificación" a alguien que prueba varias cuentas en un teléfono, buscar esa línea antes de tocar código.

40. **Cuenta de revisión de Apple (2026-10-29):** pasajero 51 (`applereview@cruiseinride.com`, `TEST_MODE_RIDER_IDS=51`). En la web entra con 1234567890 + cualquier código de 6 dígitos (solo pasajero) y ve "Modo prueba"; sus viajes sin PaymentIntent pasan a `funding_source=review_test` y la plataforma paga al conductor. OJO: sus viajes SÍ se ofrecen a conductores reales.

41. **Mapa del conductor sin brújula (2026-10-30, decisión del dueño):** mover o girar el teléfono NO gira la flecha ni la cámara. `HeadingService(useCompass: false)` en [driver_online_screen.dart](lib/screens/driver/driver_online_screen.dart): el rumbo sale solo del recorrido real del carro (medido o derivado) y parado se mantiene. Reemplaza la decisión del 2026-10-16 ("heading-up con brújula"). No reactivar la brújula ni el "giro inmediato" por brújula en pantallas del conductor. Guardias: `driver_gps_rules_guard_test.dart`, `arrow_google_like_test.dart`.

42. **Robot del chat de soporte (2026-10-30, revisión de 110 chats):** corre en `gpt-5.5` ([openai_support_service.py](backend/services/openai_support_service.py)). Con gpt-5.x en `/v1/chat/completions`, las tools solo funcionan con `reasoning_effort: "none"` — con cualquier otro valor OpenAI responde 400, el código apaga las tools para toda la vida del proceso y **el robot deja de poder pasar chats al agente**. Decisión del dueño: el robot **nunca** menciona los contratos legales (`_BOT_HIDDEN_ITEMS` los saca del contexto; si preguntan, pasa al agente). El historial que ve el modelo incluye los mensajes del agente (`[Agente especializado]: …`) — sin eso, al retomar un chat contradecía al agente. Guardia: `backend/tests/test_support_bot_review.py`.

43. **Vidrio sobre el mapa del conductor (2026-10-30/31):** solo el **sheet online/offline** (y la hoja de Ayuda) es vidrio (`GlassSurface` de [lib/widgets/glass_style.dart](lib/widgets/glass_style.dart)), con `glassInnerBox` para sus tarjetas. Los **controles del mapa** (menú, campana, recentrar, ayuda, brújula de zona, chip de ganancias, calendario junto al GO, aviso de reservas) son `MapChipSurface`: gris translúcido + sombra suave para verse 3D, **sin desenfoque** — en iOS el blur sobre el Mapbox nativo es RECTANGULAR (el engine lo hace con un `UIVisualEffectView` del rectángulo del filtro, ignora `ClipOval`/`ClipRRect`) y dibujaba un cuadrado borroso alrededor de cada botón redondo (dueño 2026-10-31). El sheet abierto **sigue siendo vidrio** (el dueño rechazó el gris sólido): de reposo a abierto sube el blur (`kGlassSheetBlur`→`kGlassSheetBlurOpen`) y el tinte (`glassSheetTint`→`glassSheetOpenTint`) para que la flecha no se vea detrás, y los botones laterales online se esconden con `_hideUnderOpenSheet`. Un `BackdropFilter` dentro de `Opacity < 1`, `ImageFiltered` o cualquier save-layer **no ve el mapa** — los wrappers de entrada quedan fuera en reposo (`ImageFiltered(enabled: t < 1.0)`). La **página de reservas** (`scheduled_rides_map_screen.dart`) usa lo mismo: sheet `GlassSurface` cuyo frost sigue al `_sheetCtrl` (el builder del `DraggableScrollableSheet` corre UNA vez — sin `AnimatedBuilder` no se actualiza al arrastrar), solo dos posiciones al arrastrar (cerrado o abierto; el detalle es la única altura que pone la app), "Search this area"/recentrar con `MapChipSurface`, y el marcador de viaje = cubo de precio más grande + pin dorado 3D dibujado en `_bubbleBytes` (dueño 2026-10-31). **El menú del conductor NO es vidrio**: página sólida neu con ruta opaca (dueño 2026-10-31). Badges de reservas = `AnimatedCountBadge` (siempre montado, entra y sale animado). Reservas en vivo: el backend sube `config/scheduled_board.version` cuando cambia el tablero ([backend/services/scheduled_board.py](backend/services/scheduled_board.py), líder, cada 3 s) y `ScheduledBoardWatcher` dispara `scheduledRideRefreshNotifier`. Guardias: `test/driver_glass_chrome_guard_test.dart`, `backend/tests/test_scheduled_board_signal.py`.

44. **Reservas: conectarse 1 hora antes (dueño 2026-10-31):** un conductor con reserva (`scheduled_accepted/_active`) tiene que estar **online (`is_online`, sin exigir heartbeat fresco) 1 hora antes** de la recogida; si no, `_release_reservation` (main.py) la devuelve al tablero **en silencio para él** (sin push, sin buzón, sin "cancelado") y marca su `DispatchOffer` como `released_offline` — `/scheduled-trips/available` y `/claim` lo excluyen ("ya para él no"). Recordatorio único 1 h 15 min antes, solo si está offline. Si **dispatch** cancela o reasigna una reserva, el conductor no recibe nada; solo la cancelación del **pasajero** le avisa ("El pasajero ha cancelado su viaje", in-app si está dentro). En la app la reserva propia es la tarjeta dorada del sheet offline ("$X Viaje reservado · Conéctate antes de las…") y todo lo que desaparece se **desvanece** (sheet, Mis Reservas, Tus viajes). El fingerprint de `scheduled_board` incluye las reservas tomadas para que el cambio llegue al instante. Guardias: `backend/tests/test_scheduled_reserved_flow.py`, `test_driver_cancel_notifications.py`, `test/reservation_card_guard_test.dart`.

45. **Nada que vea un usuario dice "dispatch" (dueño 2026-10-31):** ni push, ni bandeja, ni texto de la app, ni el robot dicen que dispatch/despacho/un operador/admin hizo algo. Al conductor la cancelación desde el panel le dice "El pasajero canceló este viaje"; al pasajero "Tu viaje fue cancelado". La app del pasajero muestra `cancel_reason` tal cual, así que el panel lo guarda neutro con `rider_safe_cancel_reason()` ([backend/utils/helpers.py](backend/utils/helpers.py)). Una vez que el robot pasa el chat a un agente (`escalated`/`dispatch_takeover`) **no vuelve a responder**: ni al reabrir ni el vigilante; solo dispatch a mano con `chat_id`. Guardias: `test_no_dispatch_wording.py`, `test/no_dispatch_wording_guard_test.dart`, `test_support_resume.py`.

46. **Mapa de flota en vivo (2026-10-31):** vive SOLO en el bundle `assets/index-OW_RZUQk.js` (no hay fuente React). Un solo reloj ordena las posiciones: la hora del servidor (`ts`), nunca el `captured_at` del teléfono; el refresco de 20 s no pisa posiciones mientras el stream está vivo (`mergeLivePositions`); un salto lejano se acepta cuando una segunda lectura lo confirma. Si el bus descarta una cola llena, el stream SSE termina para que el panel se reconecte (antes quedaba mandando solo pings). El conductor sube en los latidos su **última lectura real** (`_lastRawFix` con su hora), nunca `_pos` (la flecha dibujada) ni las coordenadas de recogida/destino. `sync_support_chat` sin rol no escribe `userRole` (antes los chats de conductores salían en Riders). Guardias: `panel_live_map_guard_test.dart`, `driver_heartbeat_real_fix_guard_test.dart`, `test_support_chat_role_sync.py`.

47. **"No se puede conectar" — revisar los 403 antes que la selfie (2026-11-01):** `can-go-online` NO mira `users.status`, pero `PATCH /drivers/{id}/location` sí (`ACTIVE_ACCOUNT_STATUSES`): un "sí" del gate con 403 en cada latido = conductor atascado sin mensaje. Diagnóstico: `railway logs <deploy> -n 5000 --filter "403" --json` y contar por `/drivers/N/location`. Causa encontrada: `write_approval` escribe la palabra de REVISIÓN (`waitlist`/`approved`/`pending`) en `drivers/sql_N.status` de Firestore y el sync de `/auth/dashboard` y `/auth/account-status` la copiaba a la columna de CUENTA — 6 aprobados quedaron con `status=waitlist`. Ahora solo cruzan estados de cuenta reales (`synced_account_status`) y aprobar limpia la palabra varada (`STRANDED_REVIEW_STATUSES`). Ojo: el servidor corre `UVICORN_WORKERS=4` — cualquier estado en memoria (p. ej. la ventana `explicit_window_open` del latch) es por proceso; iOS 1.1.6+742 no manda `explicit` y no puede levantar un latch de inactividad sola. Selfie diaria: el servidor contesta al sellar y guarda la foto después (`_store_face_check`); la app (desde 757e7e92) cierra en el disparo. Guardias: `test_waitlist_status_stranded.py`, `test_face_check_review.py`, `test/selfie_check_guard_test.dart`.

48. **Quién recibe un viaje = minutos MANEJANDO, no millas en línea recta (dueño 2026-11-01, "los carros no vuelan"):** límite AL 30 / FL 15 / otros estados 30 min, reasignar desde el panel 10 min (`max_minutes`; `radius_miles` se acepta e ignora). Todo vive en [backend/services/pickup_eta.py](backend/services/pickup_eta.py): Mapbox Matrix `driving-traffic` (tráfico en vivo, choques, cierres; token pk de `routers/payments.py`, máx 9 conductores por request, 30 req/min por cuenta → 7 por worker; **el tablero `/dispatch/available` usa SOLO OSRM** (gratis, dueño 2026-11-02 "minimizar los gastos": lo consulta cada conductor en línea y Mapbox cobra la Matrix por par conductor-viaje; esos minutos solo se muestran)) → OSRM si Mapbox falla (Mapbox descansa 60 s) → línea recta vieja (30 min = 20 mi) solo si nadie contesta en 3 s; nunca se mezclan proveedores en un mismo viaje. `_find_nearest_drivers` aplica el filtro al final y ordena por minutos — todo camino de oferta (cascada, re-oferta, guardian, ghost, reasignar, tablero `/dispatch/available`, `/dispatch/claim`) pasa por ahí o por `pickup_eta`. **No reintroducir un radio en km como regla**: `_LIVE_DISPATCH_RADIUS_KM` es solo la caja SQL (la recta que ninguna calle puede ganarle). Aprende como Lyft: cada oferta guarda los segundos predichos en `pickup_eta_samples`; `calibration_loop` compara con `driver_assigned_at → arrived_at` del viaje y saca un factor por zona (~11 km) y franja de 3 h (≥12 viajes, 0.85–1.6). Guardias: `test_pickup_eta.py`, `test_admin_reassign_trip.py`, `test_state_filter_all_paths.py`. Hueco conocido: `POST /trips/{id}/accept` (fallback sin offerId) no mira distancia.

49. **Mapa y avisos del conductor estilo Lyft (dueño 2026-11-01):** (a) **Avisos** = UN banner de vidrio arriba ([lib/widgets/glass_notification_banner.dart](lib/widgets/glass_notification_banner.dart), overlay raíz, 7 s, sube + fade al salir, se quita deslizando hacia arriba; "Rechazaste una solicitud de viaje" 5 s, solo con la X, no al vencer el contador). Los pushes en primer plano pasan por `_showPushBanner` (main.dart). iOS: el AppDelegate ya no presenta banner del sistema para FCM en primer plano — un parche Shorebird lleva el Dart pero NO ese Swift, por eso `_showPushBanner` no dibuja el vidrio en iOS con build < `kFirstQuietForegroundPushIosBuild` (754): si no, salen dos. Los SnackBar de respuesta a un toque propio (error, guardado) siguen abajo. (b) **Globitos** de viajes disponibles y aeropuertos = overlay Flutter con `FlatMapProjection` (NUNCA PointAnnotation: un bitmap no se anima), un solo widget `MapCalloutBubble`; abierto en zoom ≥ 11, cerrado < 10.6; al cerrar el precio/código no cambia de x, baja al centro del ícono y crece 17→20, el ícono crece (36→44 / avión 26→34), la 2ª línea y "CRUISE" se desvanecen recortadas, 380 ms easeInOutCubic. Conductores en el aeropuerto = reales (`POST /drivers/airport-presence`, 4 km, latido de 15 min), el rótulo cambia una vez por hora, rangos 0 / 1-5 / 5-15 / 10-15 / 15-20 / 20-30 / 30+. (c) **Oferta**: tarjeta = ancho del botón (`_kOfferSideInset` 20), pasajero "Nombre I." (`shortName`), minutos sin tope (`offer_metrics.dart`; el viejo `clamp(1, 99)` imprimía 747 mi como "1 h 39 min"). (d) **Flecha/cámara**: pasado el último vértice del trazo, `DriverRoadLock.project(extendPastEnd:)` proyecta sobre la continuación recta (la flecha ya no queda a un lado de la calle con zoom cerca); la cámara del mapa en línea sigue un `BearingSpring` ω 3.5 (no copia el rumbo cuadro a cuadro); sin holgura de vértice en `_closest`. Guardias: `glass_notification_guard_test.dart`, `driver_map_callouts_guard_test.dart`, `map_callout_geometry_test.dart`, `offer_card_metrics_test.dart`, `driver_map_turn_snap_guard_test.dart`, `test_airport_presence.py`.

50. **Flecha en línea = calles de los tiles, no el trazo pasado (dueño 2026-11-02, "se sale de las vías y luego se pone bien… que gire siguiendo las vías"):** buscando viajes no hay ruta; la línea vieja era el trazo map-matched de lecturas PASADAS (cada 6 s), así que en cada curva o giro la flecha salía de la calle hasta el siguiente match. Ahora cada lectura lee las calles que el mapa ya dibujó (`queryRenderedFeatures` sobre las capas `road-/bridge-/tunnel-` línea, ~1/s, zoom ≥ 14, sin red ni costo) y [lib/map/road_network.dart](lib/map/road_network.dart) arma la calle donde va el carro, 300 m hacia adelante, cruzando uniones entre features/tiles (≤ 4 m, ≤ 60°; una esquina NO se toma por adelantado). Elige por distancia + rumbo + seguir en la misma calle; parado solo a ≤ 10 m (un carro en un parqueo no se dibuja en la calle). Sobre esa calle el rumbo de la flecha es el de la calle en el punto dibujado, sin resorte (solo tope de 180°/s) y la cámara la sigue con ω 10; sin calle cerca vuelve el trazo de Map Matching (que ahora solo se llama en ese caso). Guardias: `test/road_network_test.dart`, `driver_map_turn_snap_guard_test.dart`.

51. **Navegación del conductor: abre con la flecha SOBRE la línea (dueño 2026-11-02):** la cámara de inicio del `MapWidget` usa el MISMO centro e inset que cada escritura del chase y la flecha superpuesta (`media.padding.top + 240`, centro `_openCameraPos` = el punto proyectado en la ruta, nunca el GPS crudo). Antes abría con `+ 130` y el GPS crudo mientras la flecha se dibuja en el foco de `+ 240`: con el carro parado no corría ningún cuadro del chase, así que la flecha quedaba 55 pt abajo y al lado de la línea (que el trim ya había comido hasta el carro). Por eso `_onDotTick` escribe la pose (`_snapToChasePose`) cuando el chase lleva > 250 ms dormido, y `_startGps` también tras sembrar el punto. Pose de chase = zoom 16.8 (16.3 rápido, 17.3 con maniobra) / pitch 45 (antes 17.5/55, "no me gusta la inclinación… como esta foto 2"); línea de ruta 6.5 (antes 8, "un poquito finita pero no tanto"). Guardias: `driver_nav_arrow_guard_test.dart`, `driver_nav_guard_test.dart`.

52. **Panel de navegación — servidor (dueño 2026-11-02):** (a) **Encadenar** = el pasajero nuevo espera ≤ min(30, límite del estado) min = lo que falta del viaje + manejar del destino a la recogida (`_filter_chained_by_wait`, dispatch.py); solo con el pasajero a bordo (`in_trip`); reemplaza la regla vieja de "a 1 milla del destino". (b) **"Recibiendo viajes" / "Último viaje"** son POR VIAJE: filas `AppConfig` `chain_pause:{driver}` / `last_trip:{driver}` = id del viaje ([services/chain_pause.py](backend/services/chain_pause.py)); una fila de otro viaje no hace nada. "Último viaje" pone offline al cerrar el viaje — todo camino nuevo que cierre un viaje llama `_apply_last_trip` / `chain_pause.apply_last_trip`. (c) **No-show** (`POST /trips/{id}/no-show`): recogida = la tarifa del agente de espera ($5 estándar), parada = el tramo recogida→parada con el motor de precios (tope: la tarifa); es FINAL — el bypass de "resucitar" lo rechaza con 409; un pago ya cobrado se reembolsa hasta la tarifa; el agente de espera relee con `FOR UPDATE SKIP LOCKED` para no cobrar dos veces. (d) La app del pasajero **ignora** una cancelación cuyo motivo contiene "rider"/"passenger" (la cree propia): los códigos nuevos van sin esas palabras (`no_show:pickup`, `no_show:stop`). Guardias: `test_no_show.py`, `test_driver_availability.py`, `test_dispatch_eta_chaining.py`, `test_stop_wait.py`.

53. **Semáforos y stops en la navegación (dueño 2026-11-02):** salen de dos fuentes, ambas sobre la ruta: las banderas `traffic_signal`/`stop_sign` de las intersecciones de Mapbox Directions y los puntos `road` de clase `traffic_signals`/`stop_sign` de los tiles Mapbox Streets v8 que el mapa ya descargó (`querySourceFeatures('composite', sourceLayerIds: ['road'])`, `_mergeTileSigns`, cada 3 s). **No usar Overpass**: el servidor público daba timeout/502 y los stops no llegaban, y su corredor de 35 m metía los stops de las calles LATERALES pegados a la ruta. Un punto de tile solo cuenta si está a ≤ 4 m de la línea (`_kSignOnRouteM`) **y** en un cruce de la ruta o hasta 30 m antes en el sentido de marcha (`DirectionsService.signAtCrossing`, cruces = `intersections` de Mapbox → `RouteResult.crossings`); el stop del otro lado del cruce es de los que vienen de frente. Sin cruces conocidos no se toma ninguno de los tiles. Dedupe 30 m en orden de ruta. Lo que no está mapeado en OSM no sale (no hay otra fuente gratis). Íconos anclados abajo (`IconAnchor.BOTTOM`, parados sobre el cruce) en su propio manager `_signMgr`: ocultos en la vista de ruta completa (fundido de 0.4 s) y bajo zoom 14.5, como Lyft/Google. Guardias: `driver_nav_guard_test.dart`, `tile_signs_test.dart`.

54. **Logo de Mapbox siempre visible (dueño 2026-11-02):** los términos de Mapbox exigen el logo en el mapa y no dejan cambiarle el tamaño. Todo mapa pasa por `MapBrand` ([lib/config/map_theme.dart](lib/config/map_theme.dart)): logo abajo a la izquierda, "i" de créditos abajo a la derecha, justo encima del panel de cada pantalla y al lado de los botones del mapa (`show(ctrl, bottom:, left:, right:)`, o `showAbovePanel(ctrl, key)` para un panel pegado abajo; `applyNavyGold` hace `refresh`, que vuelve a poner la última posición). Nunca `LogoSettings(enabled: false)`, `AttributionSettings(enabled: false)`, márgenes negativos ni ícono transparente; en web `attributionControl = true` sin CSS que esconda `.mapboxgl-ctrl-logo`. Las imágenes estáticas (Static Images) siguen con `logo=false`. Guardia: `test/map_brand_guard_test.dart`.

---

**Última actualización:** 2026-11-02 (logo de Mapbox visible encima de cada panel, regla #54; semáforos y stops desde los tiles, regla #53; panel de navegación — servidor: encadenar por espera, interruptores por viaje, no-show, regla #52) — antes 2026-11-02 (navegación abre con la flecha sobre la línea, pose 16.8/45, regla #51; flecha en línea sobre las calles de los tiles, regla #50) — antes 2026-11-01 (mapa y avisos estilo Lyft, regla #49; dispatch por minutos manejando, regla #48) — antes 2026-10-30 (flecha/navegación/ubicación como Google, reglas #32-40) — antes 2026-10-28 (reasignación desde dispatch + nota sobre el bundle del panel parcheado a mano) (auditoría Firebase + Railway: pushes perdidos, rate limiter que tumbaba la API, backups efímeros, reglas RTDB/Storage)
