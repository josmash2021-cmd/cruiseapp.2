# Informe de Auditoría — Riesgos de Clasificación Laboral

**Fecha:** 2026-07-27
**Alcance:** Repositorio completo (backend FastAPI, modelos de DB, dispatch/matching, desactivación de conductores, textos legales embebidos en la app Flutter).
**Marco analizado:** Fla. Stat. § 627.748(9) — cuatro condiciones simultáneas para mantener la clasificación de contratista independiente — y § 627.748(18)(a)3 — la TNC no puede ser dueña ni depositaria del vehículo.
**Método:** auditoría estática de solo lectura. No se modificó ningún archivo; el único archivo nuevo es este informe.

---

## 1. Resumen ejecutivo

- **Condición 4 (acuerdo escrito de contratista independiente): NO SE CUMPLE.** No existe ningún flujo donde el conductor firme/acepte un acuerdo de contratista independiente separado de los Términos generales, con timestamp y versión registrados. La infraestructura (`ConsentLog`, `terms_accepted_at`, endpoint `/auth/consent`) existe pero **nunca es invocada por la app**. Es el hallazgo más grave del informe porque la condición es de cumplimiento obligatorio y simultáneo.
- **Condición 1 (horarios/control): comprometida en 3 frentes:** asignación forzada de viajes desde el panel admin combinada con bloqueo de cancelación del conductor; textos de promociones que penalizan rechazar viajes; e infraestructura completa de bonos por volumen en ventanas de tiempo definidas por la plataforma (incluye rachas diarias de hasta 90 días).
- **Condición 2 (exclusividad): LIMPIA.** Sin detección de multi-apping, sin cláusulas de exclusividad.
- **Condición 3 (otra ocupación): LIMPIA.** Sin cláusulas de no competencia ni dedicación exclusiva.
- **Propiedad del vehículo: LIMPIA.** No hay renta, préstamo, arrendamiento ni asignación de vehículos de empresa. Una sola mención cosmética de "fleet" en un email.
- **El motor de matching automático es mayormente favorable a la defensa:** rechazo libre sin penalización, sin memoria de rechazos, orden por pura distancia, y política documentada de "decline without penalty".

---

## 2. Tabla de hallazgos (ordenados de ALTA a BAJA)

| Severidad | Condición afectada | Archivo:línea | Qué hace el código | Por qué es riesgo |
|-----------|-------------------|---------------|--------------------|-------------------|
| **ALTA** | Condición 4 — acuerdo escrito | `lib/screens/driver/driver_signup_screen.dart:308, 1668-1703, 775-850` | Único checkbox "acepto Driver Terms" en el signup: es texto plano sin enlaces al documento, gate solo en memoria local; `_submit()` jamás envía el consentimiento al servidor | Bajo § 627.748(9)(d) se exige acuerdo escrito entre ambas partes. Sin registro de aceptación (timestamp, versión, IP) no hay evidencia del consentimiento; la clasificación se cae aunque el texto del ToS diga "contratista" |
| **ALTA** | Condición 4 — acuerdo escrito | `backend/models/database.py:175-176, 195-204`; `backend/routers/auth.py:1874-1916`; `lib/services/api_service.dart:3658` | Existen `users.terms_accepted_at`, `privacy_accepted_at`, la tabla `ConsentLog` (version, IP, user-agent) y el endpoint `POST /auth/consent` — pero `ApiService.recordConsent` **no es llamado desde ningún punto de la app** (código muerto) | La infraestructura de evidencia existe y está apagada; en litigio no se puede probar quién aceptó qué versión ni cuándo |
| **ALTA** | Condición 1 — asignación forzada | `backend/routers/admin.py:1388-1389` (y duplicado en `:507-508`) | `POST /admin/trips/assign` hace `trip.driver_id = driver_id; trip.status = "accepted"` directamente, sin aceptación del conductor | Asignación unilateral de trabajo sin opción real de rechazar. Combinada con el bloqueo de cancelación (siguiente fila), la empresa asigna trabajo y el conductor no puede salir de él |
| **ALTA** | Condición 1 — asignación forzada / control de ejecución | `backend/routers/trips.py:1284-1288` (y `:879-892`); vía única `:1419-1431` → aprobación en `dispatch.py:1721, 1861` | El conductor recibe 403 al cancelar: "Drivers must contact dispatch to request a cancellation". Su única vía es un `ActionRequest` que dispatch aprueba o rechaza | El conductor no puede abandonar unilateralmente un trabajo; necesita permiso de la empresa. Control directo sobre la ejecución (no solo el resultado), argumento central de reclasificación |
| **ALTA** | Condición 1 — penalización por rechazar / bono condicionado | `lib/screens/driver/driver_promos_screen.dart:94-100` (y `:162-163`) | Textos visibles al conductor: "Canceling or declining a trip **resets your progress**", "Keep your **acceptance rate high** for maximum bonuses", "Complete 20+ trips Friday 6 PM–Sunday midnight for a 10% bonus" | Comunica consecuencia económica por rechazar viajes y bonos por volumen en ventana definida por la plataforma — ambos prohibidos por la condición 1. Aunque hoy son datos mock sin backend, el texto ya es exhibible como evidencia de presión para aceptar |
| **ALTA** | Condición 1 — bonos en ventana de tiempo | `backend/services/quest_engine.py:29-47, 219-226`; `backend/models/quest_models.py:23-35`; `backend/routers/quests.py:454-484`; `backend/routers/admin.py:1513-1528`; `backend/routers/driver_referrals.py:51-55` | Motor completo de quests: bonos por X viajes en ventanas `starts_at/ends_at` definidas por admin, quests de `peak_hours` (17:00–21:00), y **bonos por racha diaria consecutiva: $5 (3d) → $500 (90d)**; incentivos legacy "Complete N trips in 168h"; referral $200 si el referido hace 50 viajes en 60 días | Los streaks diarios con bono creciente presionan a trabajar todos los días — la aproximación más directa a prescribir un horario que existe en el código. Atenuante: `process_trip_completion` aparentemente nunca se invoca (motor dormido), pero la infraestructura está completa y cableada a la API |
| **MEDIA** | Condición 1 — desconexión forzada | `backend/ghost_driver_agent.py:27-28, 187-203, 284-342, 522-538` | Agente activo: 20 min sin heartbeat → `is_online = False` forzado; con viaje activo: warn (10 min) → re-oferta a otro conductor (13 min) → cancelación automática del viaje por "driver_abandoned" (15 min) | Auto-logout impuesto por la plataforma (categoría explícita de la condición 1). Atenuantes: sin penalización económica, el conductor puede reconectarse libremente, y la justificación (higiene del pool/conductores fantasma) es operativa, no laboral |
| **MEDIA** | Indicio de control — despido por desempeño | `backend/rating_moderator_agent.py:38-40, 189-203, 216-228`; reflejado en `docs/terms_of_service.md:80` (§5.6) | Rating 30 días < 3.8 → `status = "suspended"` automático + `is_online = False`; < 4.0 → "probation"; restauración automática si mejora | Suspensión unilateral por métrica de desempeño definida por la empresa: el "derecho de despido" es el factor que más pesan los tribunales en el test common-law. Estándar de la industria y defensible, pero es indicio de control |
| **MEDIA** | Riesgo adicional — rotulación obligatoria | `docs/terms_of_service.md:88` (§6.3) y `:76` (§5.4(h)); duplicado en `lib/screens/terms_of_service_screen.dart:99` | Obliga a exhibir el emblema Cruiseinride "legible desde 50 pies" y "reflectante de noche" mientras se está online | La rotulación obligatoria es indicio de control. Atenuante fuerte: la exhibición de trade dress es requisito estatutario TNC (Ala. Code § 32-7C y también Fla. Stat. § 627.748), defendible como cumplimiento legal. No se verifica en código (no hay `doc_type` de emblema) |
| **MEDIA** | Nota jurisdiccional (transversal) | `docs/terms_of_service.md:6, 24, 246` | Los textos legales están gobernados por **Alabama** (Cruiseinride LLC de Alabama, APSC, venue Jefferson County) | Si la defensa de clasificación se planteará bajo **Fla. Stat. § 627.748**, los textos no mencionan Florida; el marco contractual y el estatuto invocado no están armonizados |
| **BAJA** | Condición 1 — timeout contado como rechazo | `lib/screens/driver/driver_offers_screen.dart:115-118` → `backend/routers/dispatch.py:1449-1453`; métrica en `drivers.py:1412`, `auth.py:1159` | Al expirar el countdown de 20 s, la app auto-reporta `rejectOffer(reason: 'timeout')`: el timeout queda registrado como "rejected" y alimenta el acceptance_rate mostrado | Hoy el acceptance_rate es solo informativo (ningún umbral actúa sobre él — verificado), pero la infraestructura contabiliza como rechazo algo que no fue decisión del conductor. Riesgo latente si se agrega un umbral |
| **BAJA** | Indicio de control — scoring por rating en matching | `backend/routers/dispatch.py:188, 826-832` | Conductores "comfort" solo reciben ofertas premium si rating ≥ 4.7 y nivel Silver+ | Scoring por calidad (no por rechazo) que condiciona acceso a ciertos viajes. Estándar de industria, riesgo bajo |
| **BAJA** | Indicio de control — moderación admin | `backend/routers/admin.py:89-95, 1020-1029`; efecto en `auth.py:330-333`, `utils/security.py:490-491` | Admin puede poner usuarios en `blocked/deactivated` individual o masivamente | Toda plataforma necesita moderación; riesgo bajo por sí solo, pero completa el "derecho de despido" junto con los triggers automáticos |
| **BAJA** | Riesgo adicional — entrenamiento obligatorio | `lib/screens/driver/driver_approved_screen.dart:133-146, 150-151`; `lib/screens/driver/driver_info_pages.dart:884-895, 979-1056` | Walkthrough obligatorio post-aprobación: 3 páginas con `PopScope(canPop: false)`; el botón "Let's Go" solo aparece al completarlas | Puerta de onboarding obligatoria. Atenuante: contenido = instrucciones de uso de la app (no formación de conducta), sin quiz ni tracking en backend |
| **BAJA** | Condición 4 — documentos referenciados inexistentes | `lib/l10n/app_localizations.dart:2478-2480` ("Driver Terms of Service"); `docs/terms_of_service.md:210` (§18.7) y `lib/screens/terms_of_service_screen.dart:233` ("separate driver arbitration agreement") | El checkbox remite a unos "Driver Terms of Service" y el ToS a un "acuerdo de arbitraje separado para conductores" — ninguno de los dos documentos existe en el repo | Referencias contractuales rotas: el conductor "acepta" documentos que no existen; debilita la condición 4 y la cláusula arbitral |
| **BAJA** | Riesgo adicional — lockout por viaje programado | `backend/routers/scheduled.py:545-548`; usado en `dispatch.py:1031-1034` | 30 min antes de un viaje programado, el conductor deja de recibir otras ofertas | Restricción temporal de ofertas. Atenuante: el conductor optó voluntariamente por ese viaje en el marketplace; consecuencia de su propia elección |
| **BAJA** | Vocabulario — "fleet" | `backend/services/email_service.py:769` | Email al rider: "Our **fleet** may be busy" | "Fleet" sugiere vehículos de la compañía (§ 627.748(18)(a)3 exige que la TNC no sea dueña). Es solo copy — no existe ninguna flota en el código |
| **BAJA** | Vocabulario — "turno/shift" | `lib/l10n/app_localizations.dart:3044-3045` | Consejo de seguridad al conductor: "Revisa tu vehículo antes de cada **turno**" / "before each **shift**" | Único vocabulario de relación laboral dirigido al conductor en todo el codebase. Cosmético |
| **BAJA** | Riesgo adicional — cláusula anti-elusión | `docs/terms_of_service.md:76` (§5.4(f)) | Prohíbe solicitar viajes o pagos fuera de la plataforma "para viajes originados en ella" | Clausulilla estándar y estrecha; vigilar que no se lea como restricción más amplia de actividad fuera de la plataforma |
| **BAJA** | Informativo — suspensión por documentos vencidos | `backend/document_expiry_agent.py:36-37, 157-159, 184-188`; `backend/routers/drivers.py:1617-1629` | Licencia/seguro/registro vencidos → `status = "suspended"`; a los 7 días, aviso de desactivación permanente | Trigger de desactivación, pero la verificación documental es exigencia regulatoria TNC (el propio § 627.748 la requiere). Defendible |

---

## 3. Sección dedicada — Condición 4: el acuerdo escrito NO EXISTE

**Se reporta explícitamente: no existe en el repositorio ningún flujo donde el conductor acepte y firme un acuerdo de contratista independiente, separado de los Términos de Servicio generales, con registro de timestamp y versión.**

Lo que hay hoy:

1. Un checkbox en el paso 3 del signup del conductor (`driver_signup_screen.dart:1668-1703`) con texto estático sin enlaces — el conductor no puede leer el documento que acepta.
2. El checkbox es un gate local en memoria (`driver_signup_screen.dart:308`); `_submit()` (`:775-850`) nunca lo transmite al backend.
3. El backend tiene todo lo necesario apagado: campos `terms_accepted_at`/`privacy_accepted_at` (`database.py:175-176`), tabla `ConsentLog` con versión/IP/user-agent (`database.py:195-204`), endpoint `POST /auth/consent` (`auth.py:1874-1916`) — y el cliente `ApiService.recordConsent` (`api_service.dart:3658`) sin un solo llamador.
4. El texto del checkbox menciona unos "Driver Terms of Service" que no existen como documento separado, y el ToS §18.7 remite a un "separate driver arbitration agreement" que tampoco existe.

**Consecuencia:** la clasificación descansa únicamente en declaraciones unilaterales del ToS (§1.3, §5.1 — que son buenos textos protectores), cuya aceptación no se puede probar. Bajo § 627.748(9), las cuatro condiciones son simultáneas: esta sola basta para que la clasificación caiga.

---

## 4. Categorías revisadas y LIMPIAS

| Categoría | Estado | Evidencia |
|-----------|--------|-----------|
| **Condición 2 — exclusividad / prohibición de otras TNC** | LIMPIO | Sin cláusulas de exclusividad en textos (las licencias son "non-exclusive", `terms_of_service.md:164,168`); sin detección de apps competidoras (cero referencias a `com.ubercab`/`com.lyft`; el `<queries>` del manifest solo declara navegación); sin requisito de online exclusivo |
| **Condición 3 — no competencia / otra ocupación** | LIMPIO | Ninguna cláusula de non-compete ni de dedicación exclusiva en ToS, Privacy ni pantallas |
| **Propiedad del vehículo (§ 627.748(18)(a)3)** | LIMPIO | `Vehicle` (`database.py:367-384`) solo tiene make/model/year/color/plate/vin/type; cero campos de renta/lease/propiedad; sin lógica de asignación de vehículos |
| **Turnos/bloques/slots obligatorios para conductores** | LIMPIO | No existe sistema de turnos. Los `scheduled_*` son viajes programados por riders que el conductor reclama voluntariamente |
| **Cuotas de horas mínimas online** | LIMPIO | Grep de `min_hours/quota/weekly_hours` sin resultados; `online_hours` en `drivers.py:467` es solo estimación informativa |
| **Penalización por inactividad online** | LIMPIO | La única consecuencia es el auto-offline (ya reportado, MEDIA); sin multas ni strikes |
| **Umbrales de acceptance-rate con consecuencia** | LIMPIO | El rate se calcula y muestra (`drivers.py:1412`, `auth.py:1159`, `cruise_level_screen.dart:187`) pero ningún código lo compara contra umbrales; `cruise_level_agent.py:30-36` usa solo viajes completados + rating |
| **Umbrales de cancellation-rate con consecuencia** | LIMPIO | Conteo solo estadístico (`drivers.py:1401-1407`); el conductor ni siquiera puede cancelar; el `cancellation_fee` se cobra al pasajero (`trips.py:1312-1325`) |
| **Auto-aceptación tras timeout** | LIMPIO | El timeout expira la oferta y la pasa al siguiente conductor (`dispatch.py:317-340`); jamás se acepta en nombre del conductor |
| **Memoria de rechazos en el matching** | LIMPIO | `_find_nearest_drivers` (`dispatch.py:150-157`) ordena solo por distancia haversine; `UnmatchedTripRetryAgent` incluso re-ofrece a quien ya rechazó (`guardian_agent.py:1204-1207`) |
| **Botón de rechazo oculto/bloqueado** | LIMPIO | "Decline" visible y funcional (`driver_offers_screen.dart:1029-1033`); endpoint `/dispatch/driver/reject` sin consecuencia (`dispatch.py:1434-1511`) |
| **Detección/bloqueo de multi-apping** | LIMPIO | Sin plugins de apps instaladas ni geofencing anti-competencia |
| **Uniformes obligatorios** | LIMPIO | Cero hits |
| **Entrenamiento obligatorio más allá de seguridad/cumplimiento** | LIMPIO (salvo walkthrough reportado) | `LearningCenterScreen` es contenido opcional (`driver_info_pages.dart:497`); sin cursos con gate en backend |
| **Asignación obligatoria de zonas/territorios** | LIMPIO | Sin campo de zona asignada en `User`; `SurgeZone` es pricing informativo; `ServiceArea` es cobertura general, sin geofencing ni colas de aeropuerto obligatorias |
| **Vocabulario laboral (employee/payroll/salary/hired/supervisor/staff/on duty)** | LIMPIO | Cero hits reales; los "supervisor/manager" (~40) son del sistema de soporte al cliente, no de supervisión de conductores; los únicos "wages/schedules" son textos protectores del ToS |

---

## 5. Evidencia exculpatoria encontrada (útil para la defensa)

- `backend/routers/support.py:808` — base de conocimiento del bot de soporte: *"Trip acceptance: can decline without penalty, acceptance rate tracked"*.
- `docs/terms_of_service.md:18-22` — *"does not employ any drivers"*, *"does not direct or control drivers' work, routes, schedules, or conduct"*, *"All drivers… are independent contractors"*.
- `docs/terms_of_service.md:70` (§5.1) — *"Nothing in these Terms creates an employment, agency, partnership, or joint venture relationship…"*.
- El matching automático no castiga el rechazo: sin memoria, sin degradación, re-oferta incluso a quien declinó.

---

## 6. Notas fuera de alcance (informativas)

- `_find_nearest_drivers` (`dispatch.py:106-118`) no filtra por `User.status` ni `verification_status`; un conductor "suspended" solo queda fuera porque la suspensión también apaga `is_online`. Robustez, no clasificación.
- Strings en español con mojibake en `backend/routers/voice.py` y `support.py`. No es tema de esta auditoría.
- La jurisdicción real de operación (Alabama en los textos vs. Florida en el marco analizado) debe confirmarse; ver fila MEDIA de la tabla.

---

## 7. Verificación del encargo

1. ✅ No se modificó ningún archivo del repositorio; el único archivo nuevo es `audit-clasificacion.md` (verificado con `git status`).
2. ✅ Cada hallazgo indica archivo y línea exactos (los dos hallazgos ALTA de asignación/cancelación fueron verificados manualmente contra el código; el resto proviene de cinco auditorías independientes por frente).
3. ✅ Cada hallazgo está mapeado a una de las cuatro condiciones, al requisito de propiedad del vehículo, o a la lista de riesgos adicionales.
4. ✅ Se reporta explícitamente que NO existe el flujo de firma del acuerdo de contratista independiente (Sección 3).
5. ✅ Las categorías sin hallazgos se listan como revisadas y limpias (Sección 4) en lugar de omitirse.
