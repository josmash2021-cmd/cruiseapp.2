# AGENTS.md — Cerebro de navegación Kimi · CruiseApp

> **Propósito:** trabajar con el mapa ya conocido, SIN gastar tokens explorando.
> Este archivo se carga solo en cada sesión — cada línea cuesta tokens siempre, así que es denso a propósito.
> **Regla de oro:** si el flujo está en el mapa de abajo, ve DIRECTO a los archivos listados. No lances agentes de exploración ni leas carpetas enteras para territorio ya mapeado.

---

## ⚡ Workflow token-eficiente

1. Lee la tarea → ubica el flujo en el mapa → lee SOLO los archivos/funciones listados (`Read` con `line_offset`, no archivos completos de 3,000 líneas).
2. Agente `explore`: SOLO para flujos NO mapeados aquí. Nunca para "confirmar" lo que este mapa ya dice.
3. El mapa dice DÓNDE; antes de editar lee igual la región exacta (los números de línea se mueven con cada commit). La forma de trabajar NO cambia: diffs mínimos, estilo del archivo, verificación obligatoria.
4. Verificación tras editar: `flutter analyze` (Dart) · `cd backend && ./.venv/Scripts/python.exe -m pytest tests/ -q` (Python).
5. `CLAUDE.md` (biblia: stack, trip lifecycle, 29 patrones aprendidos) y `PROJECT_MAP.md` (estatus 🔴/🟡/🟢 de cada archivo): léelos SOLO si el flujo no está mapeado aquí o dudas del estatus de un archivo raro. Ya no son lectura obligatoria de cada sesión.
6. Antes de commitear: `git status` — el usuario suele tener WIP propio sin commitear; no arrastres archivos ajenos al commit (si no hay forma, decláralo en el mensaje). Nunca commitees `.claude/scheduled_tasks.lock`. Mensajes en español, estilo conventional (`fix(fcm): ...`). Push al remote después de cada change set (preferencia durable del usuario).

---

## 🧠 Mapa de flujos — dónde está cada cosa

**Push de oferta al driver (Issue 1, arreglado 2026-08-07; endurecido 2026-08-08)**
- Backend: `backend/routers/dispatch.py` → `_send_offer_to_driver` (~L575-800): crea DispatchOffer, re-verifica `is_online` antes de enviar, SSE + FCM con body `"$ fare · $/hr · mi · min"`. `_auto_cascade` (~L751): OFFER_TIMEOUT_SECONDS = **20 s** (`config.py:44`) × máx 10 drivers. El FCM solo se suprime si hay token LA **y** `apns_configured()` (sin credenciales APNs, el banner sale igual). `accept_offer` ya limpia la isla (`_clear_live_activity_offer`), igual que reject/expire. `get_driver_pending` exige `user.id == driver_id` (403 como el SSE).
- Payload FCM/APNs: `backend/services/fcm_service.py` → `_send_fcm_push` (~L236-372): canales `cruise_offers` (max) / `cruise_premium`, sonido `cruise_online`, TTL 45 s, APNs time-sensitive para ofertas. Test guardián: `backend/tests/test_fcm_message_builds.py`.
- App: `lib/main.dart` — bg handler (~L133-219: ofertas retornan temprano, las dibuja el OS), foreground (~L922-1045), tap routing (`_handleDriverRideOffer` ~L222). `lib/services/notification_service.dart` — canales (~L278-329), `showOfferNotification` (~L453-518, fullScreenIntent, timeSensitive).
- Token: `NotificationService.ensureTokenRegistered` → `POST /auth/fcm-token`. SSE en vivo: `ApiService.streamDriverOffers` → `driver_online_controller._applyOffers` (los handlers SSE/poll pasan la lista AUNQUE VACÍA a `_applyOffers` — si no, la oferta muerta se queda pintada; guardián: `test/offer_live_activity_guard_test.dart`). Resume fuerza `_startPolling(force: true)`. `registerLiveActivityToken` reintenta 1× a los 10 s.
- iOS Live Activity: `ios/Runner/AppDelegate.swift` `CruiseLiveActivityManager` + `lib/services/live_activity_service.dart`; arranca al ir online (`_showOnlinePresence`), ofertas por `_syncOfferLiveActivity` y por push APNs `liveactivity` (`backend/services/apns_liveactivity.py`, `httpx[http2]` en requirements — sin el extra muere en silencio en redeploy). Push-to-start SÍ implementado (iOS 17.2+, `pushToStartTokenUpdates` kind `push_to_start` → `event:"start"` backend): con la app muerta la isla arranca sola si el start-token llegó al servidor. Guardianes backend: `backend/tests/test_live_activity_offers.py` (payload APNs, stale 400/410, fallback FCM, 403 pending).

**Mapa rider — pedir viaje / picker pin-drop (Issues 2 y 4, arreglados 2026-08-07)**
- `lib/screens/ride_request_{screen,controller,map,widgets}.dart` = UNA sola State class vía part files.
- Estado: `lib/state/rider_trip_controller.dart` (`RiderPhase`; `_tryFetchRoute` CONSERVA `pickingLocation`; la salida del picker es SOLO por `finishPickingLocation()`).
- Picker "Set your drop-off" = `RideRequestScreen(pickerMode: true)` empujado desde `pickup_dropoff_search_screen.dart`. Latch anti-snap `_userTookCamera`; gate GPS `_gpsMayMoveCamera`; reverse-geocode desde el CENTRO del mapa (`_pickerOnCameraIdle`). Si el MapWidget se recrea (GPU/handoff), bootea desde `_lastCam*` (último frame real, alimentado por `onCameraChangeListener`) — NUNCA del handoff/GPS. Test guardián: `test/picker_camera_guard_test.dart` (pineado 2026-08-08 — si falla, el snap-back volvió).
- "Driver Found": `_dfFlyMainCamera` encuadra la ruta COMPLETA una vez (pitch 20), nunca zoom al punto medio.

**Tracking rider (viaje en curso)**
- `lib/screens/rider_tracking_screen.dart` + `lib/controllers/rider_tracking_controller.dart` (fases `_TrackPhase`) + `lib/widgets/tracking/tracking_map_view.dart` (fase arriving encuadra driver→pickup A PROPÓSITO — no "arreglarlo") + `lib/map/tracking_map_camera.dart` (chase por frame).
- Encuadre onTrip (arreglado 2026-08-08): `_tripFramePoints()` usa `_tripRoutePts` = ruta COMPLETA pickup→dropoff, sembrada UNA vez en `_initRoute`. El traffic refresh (cada 2 min) y los reroutes solo reemplazan `_routePts` (pata restante, para dibujo/ETA) — JAMÁS `_tripRoutePts` o el frame colapsa a carro→dropoff (foto del zoom cerrado). Test guardián: `test/tracking_full_route_guard_test.dart`.

**Driver online / ofertas / viaje**
- `lib/screens/driver/driver_online_{screen,controller,map}.dart` — preview de oferta con fit a ruta (follow suprimido); tras aceptar, chase por frame zoom 17.5/pitch 55 = navegación turn-by-turn (intencional). `driver_trip_accept_screen.dart` — mini-mapa fit único (pickup+dropoff+ruta, SIN driverPos; zoom −0.2 clamp [9,15.5]; carrito = PNG del tracking rider `car_suv/sedan.png` iconSize 0.50, spec 2026-08-08); GPS solo mueve el carrito. Guardián: `test/driver_trip_minimap_guard_test.dart`.

**Registro driver — documentos + biometría (Issues 3 y 5, arreglados 2026-08-07)**
- `lib/screens/driver/driver_signup_screen.dart` (3 pasos). Licencia Front/Back → `license_guidelines_screen.dart` (página de guías) → `license_scanner_screen.dart` (cámara + OCR). Seguro/registro de auto: `_showPickOptions` (cámara/galería).
- Cara 4 pasos: `lib/screens/face_liveness_screen.dart` (minFaceSize 0.1, feedback visible, errores en pantalla) + `lib/utils/face_oval_fit.dart` (math pineada por `test/face_oval_fit_test.dart` — no cambiar umbrales).
- Guías compartidas: `lib/widgets/doc_guidelines_view.dart` — UNA sola fuente del diseño; la usa también el KYC rider.

**Identidad rider (KYC + auto-verificación por nombre, 2026-08-08)**
- `lib/screens/identity_verification_screen.dart` — paso 7 = guías (`DocGuidelinesView`), scanner inline con OCR + crop (`lib/utils/doc_frame_crop.dart`, pineado por `test/doc_frame_crop_test.dart`). El OCR COMPLETO del frente del ID viaja como `id_ocr_text` en `submitVerification` (el dorso no — es ruido de barcode).
- Flujo: submit → rider queda `pending` (YA NO auto-aprueba) → `_auto_verify_rider` en `backend/routers/auth.py` resuelve a los 10 s: `_name_matches` (`backend/utils/helpers.py`: tokens sin acentos, TODOS los del nombre de cuenta deben estar en el OCR) → approved / rejected con `verification_reason` `name_mismatch` | `ocr_unreadable`. Decisión admin NO se pisa. Guardianes: `backend/tests/test_rider_name_verify.py`, `test_rider_autoapprove.py` (reescrito).
- Gate UI: hero "Where to?" SIEMPRE se ve normal (rama `verificationBlocked` eliminada); tap y Schedule (`schedule_booking_screen._book`) gatean con `_ensureVerified()` → abren el KYC. Server-side: `POST /trips` 403 (trips.py:336).
- Tiempo real cuenta: `SocketService.accountStatusStream` escucha `account_status_changed` (blocked/deleted → logout, deactivated → `AccountDeactivatedScreen`, approved → refresh); poll de 300 s queda de respaldo. `AccountDeactivatedScreen` tiene FAB dorado de chat soporte.
- Guardián Flutter: `test/rider_verification_guard_test.dart`.

**Motor de mapas**
- `lib/map/`: `unified_map_service`, `camera_director` (locks exclusivos), `tracking_map_camera`, `map_surface_coordinator` (una sola superficie viva). Web = Mapbox GL JS en `web_map_view_web.dart`. SDK `mapbox_maps_flutter ^2.5.0`.

**Trip lifecycle backend**
- `backend/routers/trips.py`: statuses canónicos + `_STATUS_ALIASES` + `_VALID_TRANSITIONS` (forward-only), comisiones `_COMMISSION_BY_TYPE`. `Trip.distance` = MILLAS, `Trip.duration` = MINUTOS; ambos NULL hasta que el viaje completa.

---

## 🪤 Trampas y bugs silenciosos conocidos

0. **Columna ORM nueva ≠ columna en prod** (outage 2026-08-08): agregar una Column al modelo + a las listas ensure-column NO garantiza que el boot migration la cree — cada query de la tabla entera falla con `UndefinedColumn` y envenena la transacción (500s en cadena, `InFailedSqlTransaction`). Remedio inmediato sin redeploy: `railway run bash -c 'curl -s -X POST -H "x-api-key: $API_KEY" https://cruiseapp2-production.up.railway.app/admin/run-migrations'`. Verificación: logs sin `UndefinedColumn` fresco. Tras cualquier deploy con columna nueva, chequear los logs por "Added column" / "migration skip".

1. **FCM `priority="max"` va en palabra pelada** — el SDK la prefija con `PRIORITY_`; pasar el nombre de wire mata el Message ENTERO en silencio (pasó dos veces). Hay test guardián.
2. **El bloque `notification` del FCM SE QUEDA** — sin él Android no dispara `onMessageOpenedApp`/`getInitialMessage` y el tap no hace nada. El dedup vive en el cliente (bg handler retorna temprano en ofertas).
3. **Sonido APNs custom:** el `.wav` debe ser miembro del target Runner en `project.pbxproj` (lo es desde 2026-08-07). Si falta, iOS cae al sonido default SIN error ni log.
4. **`Runner.entitlements` lleva `aps-environment=production`** (2026-08-07) — exige la capability Push Notifications en el App ID de App Store Connect o la firma falla.
5. **Cambios nativos NO viajan por Shorebird OTA** (pbxproj, entitlements, AndroidManifest, pods): requieren build completo (Codemagic iOS / build Android).
6. **`pickerMode` queda `true` tras un Confirm exitoso** — jamás gates con `widget.pickerMode`; gatea por fase `pickingLocation`.
7. **Checklist anti-bug-silencioso (aplicar a TODO fix):** (a) ¿el archivo/asset es miembro del bundle/target nativo? (b) ¿el error llega a la UI o solo a `debugPrint`/`catch (_) {}`? (c) ¿todo gate de fase/estado tiene su camino de salida explícito? (d) ¿el push lleva contenido visible o solo ids? (e) ¿hay entradas HERMANAS al mismo flujo (front/back, cámara/galería, Android/iOS) que necesitan el mismo cambio? — grep por hermanos, no solo el caso reportado.
8. **`face_liveness_screen_new.dart` fue borrado** (duplicado muerto con el bug yuv420 + catch silencioso) — no recrear ni re-importar.
9. **Tests que ya fallaban en HEAD (no son tuyos, no los persigas):** `test_dispatch_radius.py::test_every_live_path_uses_the_shared_ceiling`, `test_rating_thresholds.py` (3), `test_rider_terms_compliance.py::test_wait_fee_schedule_consistent_between_ui_and_backend`, `test_state_filter_all_paths.py::test_live_dispatch_has_no_state_filter`.
10. **Las reglas Firebase del repo NO son las desplegadas** — nunca `firebase deploy` de rules sin comparar con la consola (detalle: CLAUDE.md #27-29).
11. **`flutter_stripe` y Mapbox no corren en web** (crash en primer layout) — todo flujo con ellos va tras `kIsWeb`; por eso las pantallas de mapa/pagos no se verifican en `localhost`.

---

## 🚦 Edit safety

**Nunca editar sin aprobación explícita:** `pubspec.yaml`, `codemagic.yaml`, `shorebird.yaml`, `railway.toml`, `firebase.json`, `.firebaserc`, `database.rules.json`, `firestore.rules`, `storage.rules`, `android/app/build.gradle.kts`, signing en `ios/Runner.xcodeproj/` (agregar RECURSOS como sonidos sí está permitido si el fix lo requiere — verificado 2026-08-07), `backend/models/database.py` (sin plan de migración), `backend/migrations/*.py` ya corridas, `backend/migrate.py`, `backend/config.py`, `backend/utils/security.py` (sin tests de regresión), docs legales en `docs/` (privacy/ToS/agreements), `.github/copilot-instructions.md`, `.github/agents/*.md`, `.github/workflows/*.yml`, `CLAUDE.md`.

**Siempre:** `flutter analyze` tras editar `.dart`; `pytest` tras editar Python; `try/finally` + `.dispose()` en controllers; Pydantic en inputs FastAPI; SQLAlchemy ORM o `text()` con parámetros nombrados; strings user-facing vía `S.of(context).xxx` (bilingüe ES/EN); `maybeOf` fuera de `build()` (CLAUDE.md #26); nunca commitear secretos.

## 🔐 Seguridad

- `backend/services/redis_cache.py` ya NO usa `pickle` — solo valores JSON-serializables.
- CORS en `backend/main.py` es production-safe; localhost solo con `DEBUG=1`.
- Hay secretos hardcodeados históricos en assets móviles/web (Firebase keys, Stripe pk_live, Google Maps key) — no agregar nuevos; plan de rotación en `SECURITY_ACTIONS.md`.

## 🛠️ Comandos

```bash
flutter analyze                                            # tras editar Dart
cd backend && ./.venv/Scripts/python.exe -m pytest tests/ -q   # tras editar Python
railway up --detach                                        # deploy backend
# iOS = Codemagic · Android = Shorebird OTA — NUNCA flutter build apk manual
```

*Última actualización: 2026-08-07 — convertido en cerebro de navegación Kimi tras la sesión de 5 fixes (push ofertas, snaps de mapa, guías licencia, cara).*
