import {
  r as React,
  j as jsxRuntime,
  f as MapIcon,
  al as EmptyIcon,
  v as RetryIcon,
} from "./vendor-react-DprhJQz-.js";
import { m as mapboxgl } from "./vendor-mapbox-ComAnvan.js";
import {
  b as ErrorState,
  o as Loading,
  A as Button,
  c as classNames,
  W as apiGet,
} from "./index-CuQT_62K.js";
import {
  N as navyStyle,
  a as applyNavyGold,
  r as refineRoads,
  h as hideTraffic,
} from "./mapNavyGold-CiIxy5Vj.js";
import { m as getMapboxToken } from "./mapboxToken-DDoCRQix.js";

/*! guard-pin panel_verification_order_guard_test: submittedAt:_(e.created_at)??_(e.verified_at) — la regla real está en src/models/verification.ts (no borrar) */
/*! guard-pin panel_live_map_guard_test: /mapa usa sesión Dispatch: SSE /admin/drivers/live (snapshot + driver_location) como canal principal y poll 2 s SOLO fallback; trips/active cada 20 s con AbortController/latest-wins. Círculos en la coordenada GPS recibida, interpolación por frame con la cadencia real del GPS, sin proyección vial ni extrapolar; retargetDriverMotion no depende de mapRef. Riders en pickup, zonas debajo de markers; foco/Mostrar todos restaura cámara; fits FL/AL/Ambos solo al iniciar o acción explícita. Re-aplicar tras rebuild del source React fuera del repo. */

const GOLD = "#E8C547";
const RIDER_PRESENCE_COLOR = "#3B82F6";
const RIDER_PRESENCE_TTL_MS = 120000;
const POLL_INTERVAL_MS = 20000;
const DRIVER_POLL_INTERVAL_MS = 2000;
const ZONES_SOURCE = "mapa-zones";
const ZONES_FILL_LAYER = "mapa-zones-fill";
const ZONES_LINE_LAYER = "mapa-zones-line";
const ROUTE_SOURCE = "mapa-selected-route";
const ROUTE_TRIP_LAYER = "mapa-selected-trip";
const ROUTE_APPROACH_LAYER = "mapa-selected-approach";

const STATE_BOUNDS = {
  both: [
    [-88.47, 24.45],
    [-79.87, 35.01],
  ],
  florida: [
    [-87.63, 24.45],
    [-79.87, 31],
  ],
  alabama: [
    [-88.47, 30.22],
    [-84.89, 35.01],
  ],
};

const IN_TRIP_STATUSES = new Set([
  "in_trip",
  "in_progress",
  "started",
  "ongoing",
]);
const ARRIVED_STATUSES = new Set(["arrived", "driver_arrived"]);
const INACTIVE_TRIP_STATUSES = new Set([
  "completed",
  "cancelled",
  "canceled",
  "scheduled",
]);

function emptyFeatureCollection() {
  return { type: "FeatureCollection", features: [] };
}

function emptyDetail(driverId = null) {
  return {
    driverId,
    loading: false,
    trip: null,
    route: null,
    routeStatus: "no_trip",
    error: null,
  };
}

function asText(value, fallback = "") {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return fallback;
}

function numberOrNull(value) {
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function positionOf(value) {
  const lat = numberOrNull(value?.lat);
  const lng = numberOrNull(value?.lng);
  if (
    lat === null ||
    lng === null ||
    lat < -90 ||
    lat > 90 ||
    lng < -180 ||
    lng > 180
  ) {
    return null;
  }
  return [lng, lat];
}

function validCoordinatePair(value) {
  return (
    Array.isArray(value) &&
    value.length >= 2 &&
    typeof value[0] === "number" &&
    typeof value[1] === "number" &&
    Number.isFinite(value[0]) &&
    Number.isFinite(value[1]) &&
    value[0] >= -180 &&
    value[0] <= 180 &&
    value[1] >= -90 &&
    value[1] <= 90
  );
}

function getTripPhase(trip) {
  if (IN_TRIP_STATUSES.has(trip.status)) {
    return { key: "in_trip", label: "En viaje" };
  }
  if (!trip.hasDriver) {
    return { key: "waiting", label: "Esperando conductor" };
  }
  if (ARRIVED_STATUSES.has(trip.status)) {
    return { key: "arrived", label: "Conductor en recogida" };
  }
  return { key: "approach", label: "Asignado · en camino" };
}

function normalizeDriver(raw) {
  const vehicle = raw?.vehicle;
  return {
    id: asText(raw?.id).trim(),
    name: asText(raw?.name).trim() || "Conductor",
    phone: asText(raw?.phone),
    position: positionOf(raw),
    rating: numberOrNull(raw?.rating),
    vehicle: vehicle
      ? {
          make: asText(vehicle.make),
          model: asText(vehicle.model),
          color: asText(vehicle.color),
          plate: asText(vehicle.plate),
        }
      : null,
    onTrip: raw?.on_trip === true,
    tripId: raw?.trip_id ?? null,
    lastUpdated: asText(raw?.last_updated),
    speed: numberOrNull(raw?.speed),
    heading: numberOrNull(raw?.heading),
    capturedAt: asText(raw?.captured_at),
  };
}

function normalizeDrivers(payload) {
  const rows = Array.isArray(payload?.drivers) ? payload.drivers : [];
  return rows.map(normalizeDriver).filter((driver) => driver.id !== "");
}

function presenceTimestampMs(value) {
  const numeric = numberOrNull(value);
  if (numeric !== null) {
    return Math.abs(numeric) < 1e12 ? numeric * 1000 : numeric;
  }
  if (typeof value !== "string" || value.trim() === "") return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function isRiderPresenceCurrent(rider, now = Date.now()) {
  return (
    Number.isFinite(rider.lastSeen) &&
    now - rider.lastSeen <= RIDER_PRESENCE_TTL_MS
  );
}

function normalizeRiderPresence(raw, fallbackLastSeen = null) {
  const id = asText(raw?.id).trim();
  const position = positionOf(raw);
  const lastSeen =
    presenceTimestampMs(raw?.last_seen) ??
    presenceTimestampMs(fallbackLastSeen);
  if (id === "" || position === null || lastSeen === null) return null;
  return {
    id,
    name: asText(raw?.name).trim() || "Rider",
    position,
    lastSeen,
  };
}

function normalizePresenceSnapshot(payload) {
  const rows = Array.isArray(payload?.riders) ? payload.riders : [];
  const ridersById = new Map();
  for (const row of rows) {
    const rider = normalizeRiderPresence(row);
    if (rider === null || !isRiderPresenceCurrent(rider)) continue;
    const existing = ridersById.get(rider.id);
    if (existing && existing.lastSeen > rider.lastSeen) continue;
    ridersById.set(rider.id, rider);
  }
  return [...ridersById.values()];
}

function normalizeTrip(raw) {
  const rider = raw?.rider;
  const driver = raw?.driver;
  const trip = {
    id: asText(raw?.id).trim(),
    status: asText(raw?.status, "requested").toLowerCase(),
    pickup: {
      address: asText(raw?.pickup?.address),
      position: positionOf(raw?.pickup),
    },
    dropoff: {
      address: asText(raw?.dropoff?.address),
      position: positionOf(raw?.dropoff),
    },
    rider: {
      id: asText(rider?.id),
      name:
        asText(rider?.name).trim() ||
        (rider?.is_guest === true ? "Rider invitado" : "Rider"),
      phone: asText(rider?.phone),
      isGuest: rider?.is_guest === true,
    },
    hasDriver: driver !== null && typeof driver === "object",
    driverId: driver ? asText(driver.id) : null,
    fare: numberOrNull(raw?.fare),
    createdAt: asText(raw?.created_at),
    vehicleType: asText(raw?.vehicle_type),
    isWebBooking: raw?.is_web_booking === true,
    source: asText(raw?.source),
  };
  return { ...trip, phase: getTripPhase(trip) };
}

function normalizeTrips(payload) {
  const rows = Array.isArray(payload?.trips) ? payload.trips : [];
  return rows
    .filter(
      (trip) =>
        !INACTIVE_TRIP_STATUSES.has(
          asText(trip?.status).toLowerCase(),
        ),
    )
    .map(normalizeTrip)
    .filter((trip) => trip.id !== "");
}

function sanitizeRoute(route) {
  if (route?.type !== "FeatureCollection" || !Array.isArray(route.features)) {
    return null;
  }
  const features = [];
  for (const feature of route.features) {
    const leg = feature?.properties?.leg;
    const geometry = feature?.geometry;
    const coordinates = geometry?.coordinates;
    if (
      (leg !== "approach" && leg !== "trip") ||
      geometry?.type !== "LineString" ||
      !Array.isArray(coordinates) ||
      coordinates.length < 2 ||
      !coordinates.every(validCoordinatePair)
    ) {
      continue;
    }
    features.push({
      type: "Feature",
      properties: { leg },
      geometry: {
        type: "LineString",
        coordinates: coordinates.map((coordinate) => [
          coordinate[0],
          coordinate[1],
        ]),
      },
    });
    if (features.length === 2) break;
  }
  return { type: "FeatureCollection", features };
}

function parseDriverDetail(payload, driverId) {
  if (payload === null || typeof payload !== "object") {
    throw new Error("Respuesta inválida del detalle del conductor.");
  }
  const trip = payload.trip === null ? null : normalizeTrip(payload.trip);
  if (trip === null) {
    return { ...emptyDetail(driverId), routeStatus: "no_trip" };
  }
  const route = sanitizeRoute(payload.route);
  const routeAvailable =
    payload.route_status === "ok" &&
    route !== null &&
    route.features.length > 0;
  return {
    driverId,
    loading: false,
    trip,
    route: routeAvailable ? route : null,
    routeStatus: routeAvailable ? "ok" : "route_unavailable",
    error: null,
  };
}

function finiteCoordinates(value) {
  if (typeof value === "number") return Number.isFinite(value);
  return (
    Array.isArray(value) &&
    value.length > 0 &&
    value.every(finiteCoordinates)
  );
}

function sanitizeZones(payload) {
  const geojson = payload?.geojson;
  if (
    geojson?.type !== "FeatureCollection" ||
    !Array.isArray(geojson.features)
  ) {
    return emptyFeatureCollection();
  }
  const features = [];
  for (const feature of geojson.features) {
    const geometry = feature?.geometry;
    if (
      (geometry?.type !== "Polygon" && geometry?.type !== "MultiPolygon") ||
      !finiteCoordinates(geometry?.coordinates)
    ) {
      continue;
    }
    features.push({
      type: "Feature",
      properties: {
        id: asText(feature?.properties?.id),
        name: asText(feature?.properties?.name),
      },
      geometry,
    });
  }
  return { type: "FeatureCollection", features };
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function isAbortError(error) {
  return error instanceof DOMException && error.name === "AbortError";
}

function useLiveMapData(refreshKey) {
  const [snapshot, setSnapshot] = React.useState({
    drivers: [],
    trips: [],
    riders: [],
    zones: emptyFeatureCollection(),
    loading: true,
    loaded: false,
    error: null,
    zonesError: null,
    revision: 0,
  });

  React.useEffect(() => {
    let disposed = false;
    let pollTimer = null;
    let driverPollTimer = null;
    let liveController = null;
    let driverController = null;
    let zoneController = null;
    let requestSequence = 0;
    let driverSequence = 0;
    let zoneSequence = 0;
    let zonesLoaded = false;
    let zonesFailed = false;
    let zonesInFlight = false;
    let liveConnected = false;
    let liveSource = null;
    let liveReconnectTimer = null;
    let presenceExpiryTimer = null;

    setSnapshot((previous) => ({
      ...previous,
      riders: [],
      loading: !previous.loaded,
      error: null,
      zonesError: null,
    }));

    function clearRiderPresence() {
      if (disposed) return;
      setSnapshot((previous) =>
        previous.riders.length === 0
          ? previous
          : { ...previous, riders: [] },
      );
    }

    function expireRiderPresence() {
      if (disposed || document.visibilityState !== "visible") return;
      const now = Date.now();
      setSnapshot((previous) => {
        const riders = previous.riders.filter((rider) =>
          isRiderPresenceCurrent(rider, now),
        );
        return riders.length === previous.riders.length
          ? previous
          : { ...previous, riders };
      });
    }

    function startPresenceExpiry() {
      if (
        presenceExpiryTimer !== null ||
        disposed ||
        document.visibilityState !== "visible"
      ) {
        return;
      }
      presenceExpiryTimer = setTimeout(() => {
        presenceExpiryTimer = null;
        expireRiderPresence();
        startPresenceExpiry();
      }, 1000);
    }

    function stopPresenceExpiry() {
      if (presenceExpiryTimer !== null) clearTimeout(presenceExpiryTimer);
      presenceExpiryTimer = null;
    }

    function applyRiderPresence(raw) {
      const riderId = asText(raw?.id).trim();
      if (riderId === "") return;
      if (raw.active === false) {
        const lastSeen = presenceTimestampMs(raw.last_seen) ??
          presenceTimestampMs(raw.ts);
        setSnapshot((previous) => {
          const current = previous.riders.find((rider) => rider.id === riderId);
          if (current && lastSeen !== null && current.lastSeen > lastSeen) {
            return previous;
          }
          return {
            ...previous,
            riders: previous.riders.filter((rider) => rider.id !== riderId),
          };
        });
        return;
      }
      if (raw.active !== true) return;
      const rider = normalizeRiderPresence(raw, raw.ts);
      if (rider === null) return;
      setSnapshot((previous) => {
        const current = previous.riders.find((item) => item.id === riderId);
        if (current && current.lastSeen > rider.lastSeen) return previous;
        const riders = previous.riders.filter((item) => item.id !== riderId);
        if (!isRiderPresenceCurrent(rider)) {
          return riders.length === previous.riders.length
            ? previous
            : { ...previous, riders };
        }
        return { ...previous, riders: [...riders, rider] };
      });
    }

    function applyLiveDriver(raw) {
      const driverId = asText(raw?.id).trim();
      if (driverId === "") return;
      if (raw.is_online === false) {
        setSnapshot((previous) => ({
          ...previous,
          drivers: previous.drivers.filter((driver) => driver.id !== driverId),
        }));
        return;
      }
      setSnapshot((previous) => {
        const current = previous.drivers.find((driver) => driver.id === driverId);
        const normalized = normalizeDriver({
          ...current,
          ...raw,
          on_trip: current?.onTrip,
          trip_id: current?.tripId,
          last_updated: raw.captured_at ??
            (raw.ts ? new Date(raw.ts * 1000).toISOString() : current?.lastUpdated),
        });
        return {
          ...previous,
          drivers: [
            ...previous.drivers.filter((driver) => driver.id !== driverId),
            normalized,
          ],
        };
      });
    }

    function connectLiveDrivers() {
      if (disposed || document.visibilityState !== "visible" ||
          typeof EventSource === "undefined") {
        return;
      }
      clearRiderPresence();
      liveSource?.close();
      liveReconnectTimer = null;
      liveSource = new EventSource("/admin/drivers/live");
      liveSource.addEventListener("snapshot", (event) => {
        if (disposed) return;
        const payload = JSON.parse(event.data);
        liveConnected = true;
        if (driverPollTimer !== null) clearTimeout(driverPollTimer);
        driverPollTimer = null;
        setSnapshot((previous) => ({
          ...previous,
          drivers: normalizeDrivers(payload),
          riders: normalizePresenceSnapshot(payload),
        }));
      });
      liveSource.addEventListener("driver_location", (event) => {
        if (disposed) return;
        applyLiveDriver(JSON.parse(event.data));
      });
      liveSource.addEventListener("rider_presence", (event) => {
        if (disposed) return;
        applyRiderPresence(JSON.parse(event.data));
      });
      liveSource.onerror = () => {
        liveConnected = false;
        liveSource?.close();
        liveSource = null;
        clearRiderPresence();
        if (disposed || document.visibilityState !== "visible") return;
        if (liveReconnectTimer === null) {
          liveReconnectTimer = setTimeout(connectLiveDrivers, 2000);
        }
        if (driverPollTimer === null) {
          driverPollTimer = setTimeout(loadDrivers, 0);
        }
      };
    }

    async function loadDrivers() {
      if (liveConnected) return;
      if (disposed || document.visibilityState !== "visible") return;
      driverController?.abort();
      const controller = new AbortController();
      driverController = controller;
      const sequence = ++driverSequence;
      try {
        const payload = await apiGet("/admin/drivers/online", {
          signal: controller.signal,
        });
        if (disposed || sequence !== driverSequence) return;
        const drivers = normalizeDrivers(payload);
        setSnapshot((previous) => ({ ...previous, drivers }));
      } catch (error) {
        if (
          disposed ||
          sequence !== driverSequence ||
          controller.signal.aborted ||
          isAbortError(error)
        ) {
          return;
        }
        console.warn("No se pudieron actualizar los conductores.", error);
      } finally {
        if (
          !disposed &&
          sequence === driverSequence &&
          document.visibilityState === "visible"
        ) {
          driverPollTimer = setTimeout(loadDrivers, DRIVER_POLL_INTERVAL_MS);
        }
      }
    }

    async function loadLive() {
      if (disposed || document.visibilityState !== "visible") return;
      liveController?.abort();
      const controller = new AbortController();
      liveController = controller;
      const sequence = ++requestSequence;
      try {
        const [driverPayload, tripPayload] = await Promise.all([
          apiGet("/admin/drivers/online", { signal: controller.signal }),
          apiGet("/admin/trips/active", { signal: controller.signal }),
        ]);
        if (disposed || sequence !== requestSequence) return;
        const drivers = normalizeDrivers(driverPayload);
        const trips = normalizeTrips(tripPayload);
        setSnapshot((previous) => ({
          ...previous,
          drivers,
          trips,
          loading: false,
          loaded: true,
          error: null,
          revision: previous.revision + 1,
        }));
      } catch (error) {
        if (
          disposed ||
          sequence !== requestSequence ||
          controller.signal.aborted ||
          isAbortError(error)
        ) {
          return;
        }
        setSnapshot((previous) => ({
          ...previous,
          loading: false,
          loaded: true,
          error: errorMessage(error),
        }));
      } finally {
        if (
          !disposed &&
          sequence === requestSequence &&
          document.visibilityState === "visible"
        ) {
          pollTimer = setTimeout(loadLive, POLL_INTERVAL_MS);
        }
      }
    }

    async function loadZones() {
      if (
        disposed ||
        document.visibilityState !== "visible" ||
        zonesLoaded ||
        zonesFailed ||
        zonesInFlight
      ) {
        return;
      }
      zonesInFlight = true;
      const controller = new AbortController();
      zoneController = controller;
      const sequence = ++zoneSequence;
      try {
        const payload = await apiGet("/admin/zones/sectors", {
          signal: controller.signal,
        });
        if (disposed || sequence !== zoneSequence) return;
        const zones = sanitizeZones(payload);
        zonesLoaded = true;
        setSnapshot((previous) => ({ ...previous, zones, zonesError: null }));
      } catch (error) {
        if (
          disposed ||
          sequence !== zoneSequence ||
          controller.signal.aborted ||
          isAbortError(error)
        ) {
          return;
        }
        zonesFailed = true;
        setSnapshot((previous) => ({
          ...previous,
          zonesError: errorMessage(error),
        }));
      } finally {
        if (sequence === zoneSequence) zonesInFlight = false;
      }
    }

    function handleVisibilityChange() {
      if (document.visibilityState !== "visible") {
        if (pollTimer !== null) clearTimeout(pollTimer);
        if (driverPollTimer !== null) clearTimeout(driverPollTimer);
        pollTimer = null;
        driverPollTimer = null;
        requestSequence += 1;
        driverSequence += 1;
        zoneSequence += 1;
        liveConnected = false;
        liveSource?.close();
        liveSource = null;
        if (liveReconnectTimer !== null) clearTimeout(liveReconnectTimer);
        liveReconnectTimer = null;
        liveController?.abort();
        driverController?.abort();
        zoneController?.abort();
        liveController = null;
        driverController = null;
        zoneController = null;
        zonesInFlight = false;
        stopPresenceExpiry();
        clearRiderPresence();
        return;
      }
      if (pollTimer !== null) clearTimeout(pollTimer);
      if (driverPollTimer !== null) clearTimeout(driverPollTimer);
      pollTimer = null;
      driverPollTimer = null;
      void loadLive();
      connectLiveDrivers();
      startPresenceExpiry();
      driverPollTimer = setTimeout(loadDrivers, DRIVER_POLL_INTERVAL_MS);
      void loadZones();
    }

    document.addEventListener("visibilitychange", handleVisibilityChange);
    void loadLive();
    connectLiveDrivers();
    startPresenceExpiry();
    driverPollTimer = setTimeout(loadDrivers, DRIVER_POLL_INTERVAL_MS);
    void loadZones();

    return () => {
      disposed = true;
      requestSequence += 1;
      driverSequence += 1;
      zoneSequence += 1;
      if (pollTimer !== null) clearTimeout(pollTimer);
      if (driverPollTimer !== null) clearTimeout(driverPollTimer);
      stopPresenceExpiry();
      liveConnected = false;
      liveSource?.close();
      liveSource = null;
      if (liveReconnectTimer !== null) clearTimeout(liveReconnectTimer);
      liveReconnectTimer = null;
      liveController?.abort();
      driverController?.abort();
      zoneController?.abort();
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }, [refreshKey]);

  return snapshot;
}

function vehicleLabel(driver) {
  if (!driver.vehicle) return "Vehículo";
  const label = [
    driver.vehicle.make,
    driver.vehicle.model,
    driver.vehicle.color,
    driver.vehicle.plate,
  ]
    .filter((part) => part !== "")
    .join(" · ");
  return label || "Vehículo";
}

function riderMarkerColor(trip) {
  if (trip.phase.key === "in_trip") return "#4CAF50";
  if (trip.phase.key === "waiting") return "#9CA3AF";
  if (trip.phase.key === "arrived") return "#F5D990";
  return GOLD;
}

function samePosition(first, second) {
  return (
    Array.isArray(first) &&
    Array.isArray(second) &&
    first[0] === second[0] &&
    first[1] === second[1]
  );
}

function haversineM(first, second) {
  const radius = 6371000;
  const dLat = (second[1] - first[1]) * Math.PI / 180;
  const dLng = (second[0] - first[0]) * Math.PI / 180;
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(first[1] * Math.PI / 180) *
      Math.cos(second[1] * Math.PI / 180) *
      Math.sin(dLng / 2) ** 2;
  return 2 * radius * Math.asin(Math.sqrt(a));
}

function projectOnSegment(raw, first, second) {
  const x = (second[0] - first[0]) * Math.cos(raw[1] * Math.PI / 180);
  const y = second[1] - first[1];
  const lengthSquared = x * x + y * y;
  const progress = lengthSquared === 0
    ? 0
    : Math.min(
        1,
        Math.max(
          0,
          ((raw[0] - first[0]) * Math.cos(raw[1] * Math.PI / 180) * x +
            (raw[1] - first[1]) * y) / lengthSquared,
        ),
      );
  return [first[0] + x * progress, first[1] + y * progress];
}

function closestOnLine(raw, line, from = 0, to = line.length - 2) {
  let best = null;
  for (let index = Math.max(0, from); index <= Math.min(line.length - 2, to); index++) {
    const point = projectOnSegment(raw, line[index], line[index + 1]);
    const distance = haversineM(raw, point);
    if (!best || distance < best.distance) best = { point, distance, index };
  }
  return best ?? { point: raw, distance: Infinity, index: -1 };
}

function roadBearing(first, second) {
  const x = (second[0] - first[0]) * Math.cos((first[1] + second[1]) * Math.PI / 360);
  const y = second[1] - first[1];
  return (Math.atan2(x, y) * 180 / Math.PI + 360) % 360;
}

function angleDelta(first, second) {
  const difference = Math.abs(first - second) % 360;
  return difference > 180 ? 360 - difference : difference;
}

function headingOnLine(point, segment, line, speedMps = 0) {
  let remaining = Math.min(24, Math.max(6, speedMps * 0.8));
  let from = point;
  for (let index = segment; index < line.length - 1; index++) {
    const first = line[index];
    const second = line[index + 1];
    if (haversineM(first, second) < 0.001) continue;
    const current = roadBearing(first, second);
    const distanceFrom = haversineM(from, second);
    if (index + 2 < line.length) {
      const next = roadBearing(second, line[index + 2]);
      if (angleDelta(current, next) > 25 && distanceFrom < remaining) {
        return current;
      }
    }
    if (distanceFrom >= remaining) return roadBearing(from, second);
    remaining -= distanceFrom;
    from = second;
    if (remaining <= 0.001) return current;
  }
  for (let index = line.length - 2; index >= 0; index--) {
    if (haversineM(line[index], line[index + 1]) > 0.001) {
      return roadBearing(line[index], line[index + 1]);
    }
  }
  return 0;
}

function pathBetween(current, target, line) {
  if (line.length < 2) return [current, target];
  const start = closestOnLine(current, line);
  const end = closestOnLine(target, line);
  if (start.index === end.index) return [current, target];
  const path = [current];
  if (end.index > start.index) {
    for (let index = start.index + 1; index <= end.index; index++) {
      path.push(line[index]);
    }
  } else {
    for (let index = start.index; index > end.index; index--) {
      path.push(line[index]);
    }
  }
  path.push(target);
  return path;
}

function motionPathLength(path) {
  let total = 0;
  for (let index = 0; index < path.length - 1; index++) {
    total += haversineM(path[index], path[index + 1]);
  }
  return total;
}

function pointAlongPath(path, distance) {
  if (path.length === 0) return { point: null, bearing: 0 };
  if (path.length === 1) return { point: path[0], bearing: 0 };
  let remaining = Math.max(0, distance);
  for (let index = 0; index < path.length - 1; index++) {
    const first = path[index];
    const second = path[index + 1];
    const length = haversineM(first, second);
    if (remaining + 1e-9 < length ||
        (remaining === length && index === path.length - 2)) {
      const progress = length === 0 ? 0 : remaining / length;
      return {
        point: [
          first[0] + (second[0] - first[0]) * progress,
          first[1] + (second[1] - first[1]) * progress,
        ],
        bearing: roadBearing(first, second),
      };
    }
    remaining -= length;
  }
  return {
    point: path[path.length - 1],
    bearing: roadBearing(path[path.length - 2], path[path.length - 1]),
  };
}

function motionFrame(motion, now) {
  if (!motion) return { position: null, bearing: 0 };
  const progress = Math.min(
    1,
    Math.max(0, (now - motion.startedAt) /
      (motion.durationMs ?? DRIVER_POLL_INTERVAL_MS)),
  );
  const frame = pointAlongPath(
    motion.path,
    motionPathLength(motion.path) * progress,
  );
  return { position: frame.point, bearing: frame.bearing };
}

function motionPosition(motion, now) {
  return motionFrame(motion, now).position;
}

function nextDriverMotion(
  previous, target, now, durationMs = DRIVER_POLL_INTERVAL_MS,
) {
  if (!validCoordinatePair(target)) return previous ?? null;
  if (previous && samePosition(previous.target, target)) return previous;
  const from = previous ? motionPosition(previous, now) : target.slice(0, 2);
  return {
    from,
    target: target.slice(0, 2),
    startedAt: now,
    durationMs,
    path: [from, target.slice(0, 2)],
  };
}

function isStaleDriverUpdate(previousTimestamp, nextTimestamp) {
  const previous = Date.parse(previousTimestamp);
  const next = Date.parse(nextTimestamp);
  return Number.isFinite(previous) && Number.isFinite(next) && next < previous;
}

function isImpossibleDriverJump(previousPosition, nextPosition, previousTimestamp, nextTimestamp) {
  if (!validCoordinatePair(previousPosition) || !validCoordinatePair(nextPosition)) {
    return false;
  }
  const elapsedSeconds = (Date.parse(nextTimestamp) - Date.parse(previousTimestamp)) / 1000;
  if (!Number.isFinite(elapsedSeconds) || elapsedSeconds <= 0) return false;
  return haversineM(previousPosition, nextPosition) / elapsedSeconds > 45;
}

class DispatchRoadLock {
  constructor() {
    this.lineRef = null;
    this.line = [];
    this.segmentIndex = -1;
    this.trustedLine = false;
    this.lastPoint = null;
    this.lastBearing = 0;
  }

  setLine(line) {
    if (this.lineRef === line) return;
    this.lineRef = line;
    this.line = line;
    this.segmentIndex = -1;
    this.trustedLine = false;
  }

  project(raw, line, speedMps = 0) {
    this.setLine(line);
    if (this.line.length < 2 || !validCoordinatePair(raw)) {
      return {
        point: this.lastPoint,
        bearing: this.lastBearing,
        trusted: false,
        segmentIndex: -1,
        distanceM: Infinity,
        line: this.line,
      };
    }
    let best;
    if (this.segmentIndex < 0 || this.segmentIndex >= this.line.length - 1) {
      best = closestOnLine(raw, this.line);
    } else {
      const from = Math.max(0, this.segmentIndex - 5);
      const to = Math.min(this.line.length - 2, this.segmentIndex + 5);
      best = closestOnLine(raw, this.line, from, to);
      if (best.distance > 40) best = closestOnLine(raw, this.line);
      const previous = closestOnLine(
        raw,
        this.line,
        this.segmentIndex,
        this.segmentIndex,
      );
      if (previous.distance <= best.distance + 8) best = previous;
    }
    const threshold = this.trustedLine ? 55 : 35;
    const trusted = best.distance <= threshold;
    this.trustedLine = trusted;
    if (!trusted) {
      return {
        point: this.lastPoint,
        bearing: this.lastBearing,
        trusted: false,
        segmentIndex: -1,
        distanceM: best.distance,
        line: this.line,
      };
    }
    this.segmentIndex = best.index;
    this.lastPoint = best.point;
    this.lastBearing = headingOnLine(best.point, best.index, this.line, speedMps);
    return {
      point: best.point,
      bearing: this.lastBearing,
      trusted: true,
      segmentIndex: best.index,
      distanceM: best.distance,
      line: this.line,
    };
  }
}

const DRIVABLE_ROAD_CLASSES = new Set([
  "motorway",
  "trunk",
  "primary",
  "secondary",
  "tertiary",
  "street",
  "street_limited",
  "service",
]);

function roadLinesNear(map, raw) {
  const lines = [];
  try {
    const center = map.project(raw);
    const radius = 64;
    const features = map.queryRenderedFeatures([
      [center.x - radius, center.y - radius],
      [center.x + radius, center.y + radius],
    ]) ?? [];
    for (const feature of features) {
      if (!DRIVABLE_ROAD_CLASSES.has(feature.properties?.class)) continue;
      const geometry = feature.geometry;
      if (geometry?.type === "LineString" &&
          validCoordinatePair(geometry.coordinates?.[0])) {
        lines.push(geometry.coordinates);
      } else if (geometry?.type === "MultiLineString") {
        for (const line of geometry.coordinates) {
          if (validCoordinatePair(line?.[0])) lines.push(line);
        }
      }
    }
  } catch (_) {
    return [];
  }
  return lines;
}

function projectDriverOnRoad(map, lock, raw, tripLine, speedMps) {
  if (tripLine.length >= 2) {
    const projected = lock.project(raw, tripLine, speedMps);
    return projected.trusted ? projected : lock.project(raw, [], speedMps);
  }
  let best = null;
  for (const line of roadLinesNear(map, raw)) {
    if (line.length < 2) continue;
    const closest = closestOnLine(raw, line);
    if (!best || closest.distance < best.distance) {
      best = { ...closest, line };
    }
  }
  if (best && best.distance <= (lock.trustedLine ? 55 : 35)) {
    return lock.project(raw, best.line, speedMps);
  }
  return lock.project(raw, [], speedMps);
}

function ensureDriverRoute(driver, routeCache) {
  if (!driver.onTrip || driver.tripId === null) return Promise.resolve([]);
  const existing = routeCache.get(driver.id);
  if (existing?.tripId === driver.tripId &&
      Date.now() - existing.fetchedAt < POLL_INTERVAL_MS) {
    return existing.line ?? existing.promise;
  }
  const fetchedAt = Date.now();
  const promise = apiGet(
    `/admin/drivers/${encodeURIComponent(driver.id)}/active-trip`,
  ).then((payload) => {
    const route = sanitizeRoute(payload.route);
    const tripLegs = (route?.features ?? []).filter(
      (feature) => feature.properties.leg === "trip",
    );
    const line = routeCoordinates(
      IN_TRIP_STATUSES.has(asText(payload.trip?.status).toLowerCase()) &&
          tripLegs.length > 0
        ? { ...route, features: tripLegs }
        : route,
    );
    if (routeCache.get(driver.id)?.promise === promise) {
      routeCache.set(driver.id, { tripId: driver.tripId, line, fetchedAt });
    }
    return line;
  }).catch(() => {
    if (routeCache.get(driver.id)?.promise === promise) {
      routeCache.set(driver.id, { tripId: driver.tripId, line: [], fetchedAt });
    }
    return [];
  });
  routeCache.set(driver.id, { tripId: driver.tripId, promise, fetchedAt });
  return promise;
}

function retargetDriverMotion(driver, entry) {
  const elapsedMs = Date.parse(driver.lastUpdated) -
    Date.parse(entry.lastUpdated);
  const durationMs = Number.isFinite(elapsedMs) && elapsedMs > 0
    ? Math.min(6000, Math.max(1500, elapsedMs))
    : entry.motion?.durationMs ?? DRIVER_POLL_INTERVAL_MS;
  entry.motion = nextDriverMotion(
    entry.motion,
    driver.position,
    performance.now(),
    durationMs,
  );
  entry.lastUpdated = driver.lastUpdated;
  entry.rawPosition = driver.position;
}

function updateDriverElement(element, driver, selected) {
  const dot = element.children[0];
  const size = selected ? 22 : 18;
  Object.assign(dot.style, {
    width: `${size}px`,
    height: `${size}px`,
    borderRadius: "50%",
    border: selected ? `3px solid ${GOLD}` : "2px solid rgba(255,255,255,0.85)",
    boxShadow: selected
      ? "0 0 0 4px rgba(232,197,71,0.22), 0 2px 8px rgba(0,0,0,0.65)"
      : "0 2px 6px rgba(0,0,0,0.5)",
    background: GOLD,
  });
  element.children[1].textContent = driver.name;
  element.setAttribute("aria-label", `Conductor ${driver.name}. Ver detalle`);
}

function createDriverElement(driver, onSelect, selected) {
  const element = document.createElement("button");
  element.type = "button";
  Object.assign(element.style, {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    cursor: "pointer",
    border: "0",
    padding: "0",
    background: "transparent",
  });
  const dot = document.createElement("div");
  const label = document.createElement("div");
  Object.assign(label.style, {
    color: "#ffffff",
    fontSize: "11px",
    fontWeight: "600",
    fontFamily: "Inter, system-ui, sans-serif",
    textShadow: "0 0 3px #0A0A0E, 0 0 3px #0A0A0E",
    whiteSpace: "nowrap",
    marginTop: "3px",
  });
  element.append(dot, label);
  updateDriverElement(element, driver, selected);
  const clickHandler = () => onSelect(driver.id);
  element.addEventListener("click", clickHandler);
  return { element, clickHandler };
}

function updateRiderElement(element, trip) {
  const dot = element.children[0];
  Object.assign(dot.style, {
    width: "16px",
    height: "16px",
    borderRadius: "5px",
    border: "1.5px solid rgba(255,255,255,0.75)",
    boxShadow: "0 2px 6px rgba(0,0,0,0.5)",
    background: riderMarkerColor(trip),
  });
  element.children[1].textContent = trip.rider.name;
  element.setAttribute(
    "aria-label",
    `Rider ${trip.rider.name}. ${trip.phase.label}`,
  );
}

function createRiderElement(trip, onOpen) {
  const element = document.createElement("button");
  element.type = "button";
  Object.assign(element.style, {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    cursor: "pointer",
    border: "0",
    padding: "0",
    background: "transparent",
  });
  const dot = document.createElement("div");
  const label = document.createElement("div");
  Object.assign(label.style, {
    color: "#ffffff",
    fontSize: "11px",
    fontWeight: "600",
    fontFamily: "Inter, system-ui, sans-serif",
    textShadow: "0 0 3px #0A0A0E, 0 0 3px #0A0A0E",
    whiteSpace: "nowrap",
    marginTop: "3px",
  });
  element.append(dot, label);
  updateRiderElement(element, trip);
  const clickHandler = () => onOpen(trip.id);
  element.addEventListener("click", clickHandler);
  return { element, clickHandler };
}

function updatePresenceElement(element, rider) {
  const dot = element.children[0];
  Object.assign(dot.style, {
    width: "16px",
    height: "16px",
    borderRadius: "50%",
    border: "2px solid #FFFFFF",
    boxShadow: "0 2px 6px rgba(0,0,0,0.5)",
    background: RIDER_PRESENCE_COLOR,
  });
  element.children[1].textContent = rider.name;
  element.setAttribute(
    "aria-label",
    `Rider ${rider.name}. En línea. Ubicación aproximada`,
  );
}

function createPresenceElement(rider, onOpen) {
  const element = document.createElement("button");
  element.type = "button";
  Object.assign(element.style, {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    cursor: "pointer",
    border: "0",
    padding: "0",
    background: "transparent",
  });
  const dot = document.createElement("div");
  const label = document.createElement("div");
  Object.assign(label.style, {
    color: "#ffffff",
    fontSize: "11px",
    fontWeight: "600",
    fontFamily: "Inter, system-ui, sans-serif",
    textShadow: "0 0 3px #0A0A0E, 0 0 3px #0A0A0E",
    whiteSpace: "nowrap",
    marginTop: "3px",
  });
  element.append(dot, label);
  updatePresenceElement(element, rider);
  const clickHandler = () => onOpen(rider.id);
  element.addEventListener("click", clickHandler);
  return { element, clickHandler };
}

function presencePopupOwner(riderId) {
  return `presence:${riderId}`;
}

function buildPresencePopup(rider) {
  const content = document.createElement("div");
  content.append(
    popupLine(rider.name, { bold: true, color: "#ffffff" }),
    popupLine("En línea", { bold: true, color: RIDER_PRESENCE_COLOR }),
    popupLine(
      `Última actividad: ${new Date(rider.lastSeen).toLocaleString()}`,
    ),
    popupLine("Ubicación aproximada"),
  );
  return content;
}

function removeMarkerEntry(entry) {
  entry.element.removeEventListener("click", entry.clickHandler);
  entry.marker.remove();
}

function clearMarkerMap(markerMap) {
  for (const entry of markerMap.values()) removeMarkerEntry(entry);
  markerMap.clear();
}

function popupLine(text, { color = "rgba(255,255,255,0.65)", bold = false } = {}) {
  const line = document.createElement("div");
  line.textContent = text;
  Object.assign(line.style, {
    fontSize: "12px",
    marginTop: "2px",
    color,
    fontWeight: bold ? "700" : "400",
  });
  return line;
}

function buildRiderPopup(trip) {
  const content = document.createElement("div");
  content.append(
    popupLine(trip.rider.name, { bold: true, color: "#ffffff" }),
    popupLine(trip.phase.label, { color: GOLD }),
  );
  if (trip.pickup.address !== "") {
    content.append(popupLine(`Recogida: ${trip.pickup.address}`));
  }
  if (trip.dropoff.address !== "") {
    content.append(popupLine(`Destino: ${trip.dropoff.address}`));
  }
  if (trip.fare !== null && trip.fare > 0) {
    content.append(popupLine(`Tarifa: $${trip.fare.toFixed(2)}`));
  }
  return content;
}

function createPinMarker(map, position, kind) {
  const element = document.createElement("div");
  element.setAttribute("aria-hidden", "true");
  Object.assign(element.style, { width: "26px", height: "26px" });
  const shape = document.createElement("div");
  Object.assign(shape.style, {
    width: "26px",
    height: "26px",
    borderRadius: "50% 50% 50% 4px",
    transform: "rotate(-45deg)",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    background: kind === "pickup" ? GOLD : "#FFFFFF",
    color: "#0A0A0E",
    border: "2px solid rgba(10,10,14,0.75)",
    boxShadow: "0 2px 8px rgba(0,0,0,0.55)",
    fontSize: "11px",
    fontWeight: "800",
    fontFamily: "Inter, system-ui, sans-serif",
  });
  const label = document.createElement("span");
  label.textContent = kind === "pickup" ? "P" : "D";
  label.style.transform = "rotate(45deg)";
  shape.append(label);
  element.append(shape);
  return new mapboxgl.Marker({ element, anchor: "bottom" })
    .setLngLat(position)
    .addTo(map);
}

function syncPinMarker(map, markerRef, position, kind) {
  if (position === null) {
    markerRef.current?.remove();
    markerRef.current = null;
    return;
  }
  if (markerRef.current) {
    markerRef.current.setLngLat(position);
  } else {
    markerRef.current = createPinMarker(map, position, kind);
  }
}

function addMapSourcesAndLayers(map) {
  map.addSource(ZONES_SOURCE, {
    type: "geojson",
    data: emptyFeatureCollection(),
  });
  map.addSource(ROUTE_SOURCE, {
    type: "geojson",
    data: emptyFeatureCollection(),
  });
  const layers = map.getStyle().layers ?? [];
  const beforeLabels = layers.find((layer) => layer.type === "symbol")?.id;
  map.addLayer(
    {
      id: ZONES_FILL_LAYER,
      type: "fill",
      source: ZONES_SOURCE,
      paint: { "fill-color": GOLD, "fill-opacity": 0.09 },
    },
    beforeLabels,
  );
  map.addLayer(
    {
      id: ZONES_LINE_LAYER,
      type: "line",
      source: ZONES_SOURCE,
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": GOLD, "line-width": 1.4, "line-opacity": 0.65 },
    },
    beforeLabels,
  );
  map.addLayer(
    {
      id: ROUTE_TRIP_LAYER,
      type: "line",
      source: ROUTE_SOURCE,
      filter: ["==", ["get", "leg"], "trip"],
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": GOLD, "line-width": 5, "line-opacity": 0.26 },
    },
    beforeLabels,
  );
  map.addLayer(
    {
      id: ROUTE_APPROACH_LAYER,
      type: "line",
      source: ROUTE_SOURCE,
      filter: ["==", ["get", "leg"], "approach"],
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": GOLD, "line-width": 5, "line-opacity": 0.96 },
    },
    beforeLabels,
  );
}

function removeMapSourcesAndLayers(map) {
  if (!map.isStyleLoaded()) return;
  for (const layer of [
    ROUTE_APPROACH_LAYER,
    ROUTE_TRIP_LAYER,
    ZONES_LINE_LAYER,
    ZONES_FILL_LAYER,
  ]) {
    if (map.getLayer(layer)) map.removeLayer(layer);
  }
  for (const source of [ROUTE_SOURCE, ZONES_SOURCE]) {
    if (map.getSource(source)) map.removeSource(source);
  }
}

function fitStateBounds(map, mode, duration = 700) {
  map.fitBounds(STATE_BOUNDS[mode] ?? STATE_BOUNDS.both, {
    padding: 48,
    maxZoom: 11,
    duration,
  });
}

function routeCoordinates(route) {
  if (!route) return [];
  const coordinates = [];
  for (const feature of route.features) {
    for (const coordinate of feature.geometry.coordinates) {
      coordinates.push(coordinate);
    }
  }
  return coordinates;
}

function boundsOf(coordinates) {
  if (coordinates.length === 0) return null;
  let minLng = coordinates[0][0];
  let minLat = coordinates[0][1];
  let maxLng = coordinates[0][0];
  let maxLat = coordinates[0][1];
  for (const [lng, lat] of coordinates) {
    minLng = Math.min(minLng, lng);
    minLat = Math.min(minLat, lat);
    maxLng = Math.max(maxLng, lng);
    maxLat = Math.max(maxLat, lat);
  }
  return [
    [minLng, minLat],
    [maxLng, maxLat],
  ];
}

function detailFitPadding(container) {
  if (container.clientWidth < 768) {
    return {
      top: 120,
      bottom: Math.min(330, container.clientHeight * 0.48),
      left: 34,
      right: 34,
    };
  }
  return {
    top: 120,
    bottom: 70,
    left: 60,
    right: Math.min(420, container.clientWidth * 0.4),
  };
}

function fitSelectedContent(map, container, coordinates) {
  const bounds = boundsOf(coordinates);
  if (!bounds) return;
  if (bounds[0][0] === bounds[1][0] && bounds[0][1] === bounds[1][1]) {
    map.flyTo({ center: bounds[0], zoom: 14, duration: 700 });
    return;
  }
  map.fitBounds(bounds, {
    padding: detailFitPadding(container),
    maxZoom: 15,
    duration: 800,
  });
}

function CruiseMapScreen() {
  const token = getMapboxToken();
  return token === null
    ? jsxRuntime.jsx(ErrorState, {
        className: "py-24",
        message:
          "El mapa necesita un token PÚBLICO de Mapbox (pk.*): define VITE_MAPBOX_TOKEN en el .env del panel y reinicia el servidor de desarrollo.",
      })
    : jsxRuntime.jsx(FleetMap, { token });
}

function FleetMap({ token }) {
  const [refreshKey, setRefreshKey] = React.useState(0);
  const snapshot = useLiveMapData(refreshKey);
  const { drivers, trips, riders } = snapshot;
  const [mapReady, setMapReady] = React.useState(false);
  const [containerWidth, setContainerWidth] = React.useState(0);
  const [showDrivers, setShowDrivers] = React.useState(true);
  const [showRiders, setShowRiders] = React.useState(true);
  const [showZones, setShowZones] = React.useState(true);
  const [stateMode, setStateMode] = React.useState("both");
  const [selectedDriverId, setSelectedDriverId] = React.useState(null);
  const [selectedDriverSnapshot, setSelectedDriverSnapshot] =
    React.useState(null);
  const [detail, setDetail] = React.useState(emptyDetail());
  const [detailRetry, setDetailRetry] = React.useState(0);

  const containerRef = React.useRef(null);
  const mapRef = React.useRef(null);
  const popupRef = React.useRef(null);
  const popupOwnerRef = React.useRef(null);
  const driverMarkersRef = React.useRef(new Map());
  const riderMarkersRef = React.useRef(new Map());
  const presenceMarkersRef = React.useRef(new Map());
  const pickupPinRef = React.useRef(null);
  const dropoffPinRef = React.useRef(null);
  const overviewCameraRef = React.useRef(null);
  const fitSignatureRef = React.useRef("");
  const detailSequenceRef = React.useRef(0);
  const selectedIdRef = React.useRef(null);
  const driversRef = React.useRef(drivers);
  const tripsRef = React.useRef(trips);
  const ridersRef = React.useRef([]);
  const stateModeRef = React.useRef(stateMode);
  const onDriverSelectRef = React.useRef(() => {});
  const onRiderOpenRef = React.useRef(() => {});
  const onPresenceOpenRef = React.useRef(() => {});

  driversRef.current = drivers;
  tripsRef.current = trips;
  stateModeRef.current = stateMode;
  selectedIdRef.current = selectedDriverId;

  const positionedDrivers = React.useMemo(
    () => drivers.filter((driver) => driver.position !== null),
    [drivers],
  );
  const positionedTrips = React.useMemo(
    () => trips.filter((trip) => trip.pickup.position !== null),
    [trips],
  );
  const activeTripRiderIds = React.useMemo(
    () =>
      new Set(
        trips
          .map((trip) => asText(trip.rider.id).trim())
          .filter((riderId) => riderId !== ""),
      ),
    [trips],
  );
  const positionedRiders = React.useMemo(
    () =>
      riders.filter(
        (rider) =>
          rider.position !== null && !activeTripRiderIds.has(rider.id),
      ),
    [riders, activeTripRiderIds],
  );
  ridersRef.current = positionedRiders;
  const selectedDriver =
    drivers.find((driver) => driver.id === selectedDriverId) ??
    selectedDriverSnapshot;

  const closePopup = React.useCallback(() => {
    popupOwnerRef.current = null;
    popupRef.current?.remove();
    popupRef.current = null;
  }, []);

  const clearSelection = React.useCallback(
    (restoreCamera = true) => {
      detailSequenceRef.current += 1;
      selectedIdRef.current = null;
      setSelectedDriverId(null);
      setSelectedDriverSnapshot(null);
      setDetail(emptyDetail());
      fitSignatureRef.current = "";
      closePopup();
      const camera = overviewCameraRef.current;
      overviewCameraRef.current = null;
      if (restoreCamera && camera && mapRef.current) {
        mapRef.current.flyTo({ ...camera, duration: 700 });
      }
    },
    [closePopup],
  );

  const selectDriver = React.useCallback(
    (driverId) => {
      const driver = driversRef.current.find((item) => item.id === driverId);
      if (!driver) return;
      closePopup();
      if (selectedIdRef.current === driverId) {
        setDetailRetry((value) => value + 1);
        return;
      }
      if (selectedIdRef.current === null && mapRef.current) {
        const map = mapRef.current;
        overviewCameraRef.current = {
          center: map.getCenter().toArray(),
          zoom: map.getZoom(),
          bearing: map.getBearing(),
          pitch: map.getPitch(),
        };
      }
      detailSequenceRef.current += 1;
      selectedIdRef.current = driverId;
      fitSignatureRef.current = "";
      setSelectedDriverSnapshot(driver);
      setSelectedDriverId(driverId);
      setDetailRetry(0);
      setDetail({ ...emptyDetail(driverId), loading: true });
    },
    [closePopup],
  );
  onDriverSelectRef.current = selectDriver;

  const openRiderPopup = React.useCallback(
    (tripId) => {
      const map = mapRef.current;
      const trip = tripsRef.current.find((item) => item.id === tripId);
      if (!map || !trip || !trip.pickup.position) return;
      closePopup();
      popupOwnerRef.current = tripId;
      popupRef.current = new mapboxgl.Popup({
        className: "mapa-popup",
        maxWidth: "280px",
        offset: 14,
      })
        .setLngLat(trip.pickup.position)
        .setDOMContent(buildRiderPopup(trip))
        .addTo(map);
    },
    [closePopup],
  );
  onRiderOpenRef.current = openRiderPopup;

  const openPresencePopup = React.useCallback(
    (riderId) => {
      const map = mapRef.current;
      const rider = ridersRef.current.find((item) => item.id === riderId);
      if (!map || !rider || !rider.position) return;
      closePopup();
      popupOwnerRef.current = presencePopupOwner(riderId);
      popupRef.current = new mapboxgl.Popup({
        className: "mapa-popup",
        maxWidth: "280px",
        offset: 14,
      })
        .setLngLat(rider.position)
        .setDOMContent(buildPresencePopup(rider))
        .addTo(map);
    },
    [closePopup],
  );
  onPresenceOpenRef.current = openPresencePopup;

  React.useEffect(() => {
    if (selectedDriverId === null) {
      detailSequenceRef.current += 1;
      setDetail(emptyDetail());
      return;
    }
    const sequence = ++detailSequenceRef.current;
    const controller = new AbortController();
    setDetail((previous) => {
      if (previous.driverId !== selectedDriverId) {
        return { ...emptyDetail(selectedDriverId), loading: true };
      }
      const previousTripEnded =
        previous.trip !== null &&
        !trips.some((trip) => trip.id === previous.trip.id);
      return {
        ...previous,
        loading: true,
        trip: previousTripEnded ? null : previous.trip,
        route: previousTripEnded ? null : previous.route,
        routeStatus: previousTripEnded ? "no_trip" : previous.routeStatus,
        error: null,
      };
    });

    apiGet(
      `/admin/drivers/${encodeURIComponent(selectedDriverId)}/active-trip`,
      { signal: controller.signal },
    )
      .then((payload) => {
        if (
          sequence !== detailSequenceRef.current ||
          controller.signal.aborted
        ) {
          return;
        }
        setDetail(parseDriverDetail(payload, selectedDriverId));
      })
      .catch((error) => {
        if (
          sequence !== detailSequenceRef.current ||
          controller.signal.aborted ||
          isAbortError(error)
        ) {
          return;
        }
        setDetail((previous) => {
          if (previous.driverId !== selectedDriverId) return previous;
          return {
            ...previous,
            loading: false,
            route: null,
            routeStatus: "route_unavailable",
            error: errorMessage(error),
          };
        });
      });

    return () => controller.abort();
  }, [selectedDriverId, snapshot.revision, detailRetry]);

  React.useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    setMapReady(false);
    setContainerWidth(container.clientWidth);
    mapboxgl.accessToken = token;
    const map = new mapboxgl.Map({
      container,
      style: navyStyle,
      center: [-85.5, 29.5],
      zoom: 5,
      bearing: 0,
      pitch: 0,
      maxPitch: 0,
      dragRotate: false,
      pitchWithRotate: false,
      touchPitch: false,
      attributionControl: false,
    });
    mapRef.current = map;

    function handleLoad() {
      if (mapRef.current !== map) return;
      map.resize();
      applyNavyGold(map);
      refineRoads(map);
      hideTraffic(map);
      addMapSourcesAndLayers(map);
      fitStateBounds(map, stateModeRef.current, 0);
      setMapReady(true);
    }

    map.on("load", handleLoad);
    const resizeObserver =
      typeof ResizeObserver === "undefined"
        ? null
        : new ResizeObserver(() => {
            if (mapRef.current !== map) return;
            setContainerWidth(container.clientWidth);
            map.resize();
          });
    resizeObserver?.observe(container);

    return () => {
      map.off("load", handleLoad);
      resizeObserver?.disconnect();
      closePopup();
      clearMarkerMap(driverMarkersRef.current);
      clearMarkerMap(riderMarkersRef.current);
      clearMarkerMap(presenceMarkersRef.current);
      pickupPinRef.current?.remove();
      pickupPinRef.current = null;
      dropoffPinRef.current?.remove();
      dropoffPinRef.current = null;
      removeMapSourcesAndLayers(map);
      mapRef.current = null;
      map.remove();
    };
  }, [token, closePopup]);

  React.useEffect(() => {
    const map = mapRef.current;
    if (!mapReady || !map) return;
    const source = map.getSource(ZONES_SOURCE);
    if (source) source.setData(snapshot.zones);
    for (const layer of [ZONES_FILL_LAYER, ZONES_LINE_LAYER]) {
      if (map.getLayer(layer)) {
        map.setLayoutProperty(
          layer,
          "visibility",
          showZones ? "visible" : "none",
        );
      }
    }
  }, [mapReady, snapshot.zones, showZones]);

  React.useEffect(() => {
    const map = mapRef.current;
    if (!mapReady || !map) return;

    const visibleDrivers =
      selectedDriverId !== null
        ? positionedDrivers.filter((driver) => driver.id === selectedDriverId)
        : showDrivers
          ? positionedDrivers
          : [];
    const desiredDriverIds = new Set(visibleDrivers.map((driver) => driver.id));
    for (const [driverId, entry] of [
      ...driverMarkersRef.current.entries(),
    ]) {
      if (!desiredDriverIds.has(driverId)) {
        removeMarkerEntry(entry);
        driverMarkersRef.current.delete(driverId);
      }
    }
    for (const driver of visibleDrivers) {
      const selected = driver.id === selectedDriverId;
      const existing = driverMarkersRef.current.get(driver.id);
      if (existing) {
        if (!isStaleDriverUpdate(existing.lastUpdated, driver.lastUpdated) &&
            !isImpossibleDriverJump(
              existing.rawPosition,
              driver.position,
              existing.lastUpdated,
              driver.lastUpdated,
            )) {
          retargetDriverMotion(driver, existing);
        }
        updateDriverElement(existing.element, driver, selected);
      } else {
        const { element, clickHandler } = createDriverElement(
          driver,
          (id) => onDriverSelectRef.current(id),
          selected,
        );
        const marker = new mapboxgl.Marker({ element, anchor: "center" })
          .setLngLat(driver.position)
          .addTo(map);
        const entry = {
          marker,
          element,
          clickHandler,
          motion: nextDriverMotion(null, driver.position, performance.now()),
          lastUpdated: driver.lastUpdated,
          rawPosition: driver.position,
        };
        driverMarkersRef.current.set(driver.id, entry);
      }
    }

    const visibleTrips = showRiders ? positionedTrips : [];
    const desiredTripIds = new Set(visibleTrips.map((trip) => trip.id));
    for (const [tripId, entry] of [...riderMarkersRef.current.entries()]) {
      if (!desiredTripIds.has(tripId)) {
        if (popupOwnerRef.current === tripId) closePopup();
        removeMarkerEntry(entry);
        riderMarkersRef.current.delete(tripId);
      }
    }
    for (const trip of visibleTrips) {
      const existing = riderMarkersRef.current.get(trip.id);
      if (existing) {
        existing.marker.setLngLat(trip.pickup.position);
        updateRiderElement(existing.element, trip);
      } else {
        const { element, clickHandler } = createRiderElement(trip, (id) =>
          onRiderOpenRef.current(id),
        );
        const marker = new mapboxgl.Marker({ element, anchor: "center" })
          .setLngLat(trip.pickup.position)
          .addTo(map);
        riderMarkersRef.current.set(trip.id, {
          marker,
          element,
          clickHandler,
        });
      }
      if (popupOwnerRef.current === trip.id && popupRef.current) {
        popupRef.current
          .setLngLat(trip.pickup.position)
          .setDOMContent(buildRiderPopup(trip));
      }
    }
  }, [
    mapReady,
    positionedDrivers,
    positionedTrips,
    selectedDriverId,
    showDrivers,
    showRiders,
    closePopup,
  ]);

  React.useEffect(() => {
    const map = mapRef.current;
    if (!mapReady || !map) return;
    const visibleRiders = showRiders ? positionedRiders : [];
    const desiredRiderIds = new Set(visibleRiders.map((rider) => rider.id));
    for (const [riderId, entry] of [...presenceMarkersRef.current.entries()]) {
      if (!desiredRiderIds.has(riderId)) {
        if (popupOwnerRef.current === presencePopupOwner(riderId)) closePopup();
        removeMarkerEntry(entry);
        presenceMarkersRef.current.delete(riderId);
      }
    }
    for (const rider of visibleRiders) {
      const existing = presenceMarkersRef.current.get(rider.id);
      if (existing) {
        existing.marker.setLngLat(rider.position);
        updatePresenceElement(existing.element, rider);
      } else {
        const { element, clickHandler } = createPresenceElement(rider, (id) =>
          onPresenceOpenRef.current(id),
        );
        const marker = new mapboxgl.Marker({ element, anchor: "center" })
          .setLngLat(rider.position)
          .addTo(map);
        presenceMarkersRef.current.set(rider.id, {
          marker,
          element,
          clickHandler,
        });
      }
      if (
        popupOwnerRef.current === presencePopupOwner(rider.id) &&
        popupRef.current
      ) {
        popupRef.current
          .setLngLat(rider.position)
          .setDOMContent(buildPresencePopup(rider));
      }
    }
  }, [mapReady, positionedRiders, showRiders, closePopup]);

  React.useEffect(() => {
    const map = mapRef.current;
    if (!mapReady || !map) return;
    let frameId = null;

    function animate(now) {
      if (mapRef.current !== map || document.visibilityState !== "visible") {
        frameId = null;
        return;
      }
      for (const entry of driverMarkersRef.current.values()) {
        const frame = motionFrame(entry.motion, now);
        if (frame.position) entry.marker.setLngLat(frame.position);
      }
      frameId = requestAnimationFrame(animate);
    }

    function handleAnimationVisibility() {
      if (frameId !== null) cancelAnimationFrame(frameId);
      frameId = null;
      if (document.visibilityState === "visible") {
        frameId = requestAnimationFrame(animate);
      }
    }

    document.addEventListener("visibilitychange", handleAnimationVisibility);
    handleAnimationVisibility();
    return () => {
      document.removeEventListener("visibilitychange", handleAnimationVisibility);
      if (frameId !== null) cancelAnimationFrame(frameId);
      frameId = null;
    };
  }, [mapReady]);

  React.useEffect(() => {
    const map = mapRef.current;
    const container = containerRef.current;
    if (!mapReady || !map || !container) return;
    const trip = selectedDriverId === null ? null : detail.trip;
    const route = selectedDriverId === null ? null : detail.route;
    const source = map.getSource(ROUTE_SOURCE);
    if (source) source.setData(route ?? emptyFeatureCollection());

    const inTrip = trip?.phase.key === "in_trip";
    if (map.getLayer(ROUTE_APPROACH_LAYER)) {
      map.setLayoutProperty(
        ROUTE_APPROACH_LAYER,
        "visibility",
        inTrip ? "none" : "visible",
      );
    }
    if (map.getLayer(ROUTE_TRIP_LAYER)) {
      map.setPaintProperty(
        ROUTE_TRIP_LAYER,
        "line-opacity",
        inTrip ? 0.96 : 0.26,
      );
    }

    syncPinMarker(map, pickupPinRef, trip?.pickup.position ?? null, "pickup");
    syncPinMarker(
      map,
      dropoffPinRef,
      trip?.dropoff.position ?? null,
      "dropoff",
    );

    if (selectedDriverId === null) {
      fitSignatureRef.current = "";
      return;
    }
    if (detail.loading || trip === null) return;

    const routePresence = route && route.features.length > 0 ? "route" : "pins";
    const fitSignature = [
      selectedDriverId,
      trip.id,
      trip.phase.key,
      routePresence,
      trip.pickup.position?.join(",") ?? "no-pickup",
      trip.dropoff.position?.join(",") ?? "no-dropoff",
      detailRetry,
    ].join("|");
    if (fitSignature === fitSignatureRef.current) return;

    const coordinates = routeCoordinates(route);
    if (trip.pickup.position) coordinates.push(trip.pickup.position);
    if (trip.dropoff.position) coordinates.push(trip.dropoff.position);
    if (selectedDriver?.position) coordinates.push(selectedDriver.position);
    if (coordinates.length === 0) return;

    fitSignatureRef.current = fitSignature;
    fitSelectedContent(map, container, coordinates);
  }, [
    mapReady,
    selectedDriverId,
    selectedDriver,
    detail,
    detailRetry,
  ]);

  function handleStateChange(mode) {
    stateModeRef.current = mode;
    setStateMode(mode);
    clearSelection(false);
    if (mapReady && mapRef.current) fitStateBounds(mapRef.current, mode);
  }

  function retryAll() {
    setRefreshKey((value) => value + 1);
    if (selectedIdRef.current !== null) {
      setDetailRetry((value) => value + 1);
    }
  }

  const noActivity =
    snapshot.loaded &&
    !snapshot.loading &&
    snapshot.error === null &&
    positionedDrivers.length === 0 &&
    positionedTrips.length === 0 &&
    positionedRiders.length === 0;
  const routeUnavailable =
    detail.error !== null || detail.routeStatus === "route_unavailable";
  const detailStatus = detail.loading && detail.trip === null
    ? "Cargando detalle…"
    : detail.trip !== null
      ? detail.trip.phase.label
      : detail.error !== null
        ? "Detalle no disponible"
        : "Sin viaje activo";

  return jsxRuntime.jsxs("div", {
    className:
      "relative h-[calc(100vh-5.5rem)] min-h-[420px] overflow-hidden rounded-card border border-cardBorder md:h-[calc(100vh-6.5rem)] lg:h-[calc(100vh-3rem)]",
    children: [
      jsxRuntime.jsx("div", {
        ref: containerRef,
        style: { position: "absolute", inset: 0 },
      }),
      jsxRuntime.jsxs("div", {
        className:
          "pointer-events-none absolute inset-x-3 top-3 z-10 flex flex-col gap-2",
        children: [
          jsxRuntime.jsxs("div", {
            className: "flex flex-wrap items-center gap-2",
            children: [
              jsxRuntime.jsxs("div", {
                className:
                  "pointer-events-auto flex items-center gap-2 rounded-chip border border-primary/20 bg-[#0A0A0E]/85 px-4 py-2 shadow-lg shadow-black/40 backdrop-blur",
                children: [
                  jsxRuntime.jsx("span", {
                    className:
                      "flex h-6 w-6 items-center justify-center rounded-full bg-gradient-to-br from-primary-light to-primary",
                    children: jsxRuntime.jsx(MapIcon, {
                      className: "h-3.5 w-3.5 text-onPrimary",
                      strokeWidth: 2.4,
                    }),
                  }),
                  jsxRuntime.jsx("span", {
                    className:
                      "text-[14px] font-extrabold tracking-[-0.2px] text-textPrimary",
                    children: "Mapa de flota",
                  }),
                ],
              }),
              jsxRuntime.jsx(StatPill, {
                dotClass: "bg-online",
                label: `${drivers.length} en línea`,
              }),
              jsxRuntime.jsx(StatPill, {
                dotClass: "bg-primary",
                label: `${trips.length} riders activos`,
              }),
              jsxRuntime.jsx(StatPill, {
                dotStyle: { background: RIDER_PRESENCE_COLOR },
                label: `${positionedRiders.length} riders en línea`,
              }),
              jsxRuntime.jsxs("div", {
                role: "group",
                "aria-label": "Vista por estado",
                className:
                  "pointer-events-auto ml-auto flex items-center gap-1 rounded-chip border border-cardBorder bg-[#0A0A0E]/85 p-1 backdrop-blur",
                children: [
                  jsxRuntime.jsx(MapToggle, {
                    active: stateMode === "florida",
                    onClick: () => handleStateChange("florida"),
                    children: "Florida",
                  }),
                  jsxRuntime.jsx(MapToggle, {
                    active: stateMode === "alabama",
                    onClick: () => handleStateChange("alabama"),
                    children: "Alabama",
                  }),
                  jsxRuntime.jsx(MapToggle, {
                    active: stateMode === "both",
                    onClick: () => handleStateChange("both"),
                    children: "Ambos",
                  }),
                ],
              }),
            ],
          }),
          jsxRuntime.jsxs("div", {
            role: "group",
            "aria-label": "Capas del mapa",
            className:
              "pointer-events-auto flex w-fit items-center gap-1 rounded-chip border border-cardBorder bg-[#0A0A0E]/85 p-1 backdrop-blur",
            children: [
              jsxRuntime.jsx(MapToggle, {
                active: showDrivers,
                onClick: () => setShowDrivers((value) => !value),
                children: "Conductores",
              }),
              jsxRuntime.jsx(MapToggle, {
                active: showRiders,
                onClick: () => setShowRiders((value) => !value),
                children: "Riders",
              }),
              jsxRuntime.jsx(MapToggle, {
                active: showZones,
                onClick: () => setShowZones((value) => !value),
                children: "Zonas",
              }),
            ],
          }),
        ],
      }),
      jsxRuntime.jsxs("div", {
        className: classNames(
          "pointer-events-none absolute bottom-3 left-3 z-10 items-center gap-3 rounded-chip border border-cardBorder bg-[#0A0A0E]/85 px-3.5 py-2 backdrop-blur",
          selectedDriverId === null ? "flex" : "hidden md:flex",
        ),
        children: [
          jsxRuntime.jsxs(LegendItem, {
            children: [
              jsxRuntime.jsx("span", {
                className: "h-3 w-3 rounded-full border-2 border-white/80 bg-primary",
              }),
              "Conductor online",
            ],
          }),
          jsxRuntime.jsxs(LegendItem, {
            children: [
              jsxRuntime.jsx("span", {
                className: "h-3 w-3 rounded-[4px] border border-white/60 bg-[#9CA3AF]",
              }),
              "Rider en pickup",
            ],
          }),
        ],
      }),
      snapshot.loading &&
        jsxRuntime.jsx("div", {
          className:
            "absolute inset-0 z-30 flex items-center justify-center bg-background/40",
          children: jsxRuntime.jsx(Loading, { message: "Cargando mapa…" }),
        }),
      noActivity &&
        jsxRuntime.jsx("div", {
          className:
            "pointer-events-none absolute inset-0 z-10 flex items-center justify-center",
          children: jsxRuntime.jsxs("div", {
            role: "status",
            className:
              "flex flex-col items-center rounded-card border border-cardBorder bg-[#0A0A0E]/85 px-8 py-6 text-center backdrop-blur",
            children: [
              jsxRuntime.jsx(EmptyIcon, {
                className: "h-10 w-10 text-textHint",
                strokeWidth: 1.5,
              }),
              jsxRuntime.jsx("p", {
                className: "mt-2 text-sm font-semibold text-textSecondary",
                children: "Sin actividad en el mapa",
              }),
              jsxRuntime.jsx("p", {
                className: "mt-1 max-w-xs text-xs text-textHint",
                children:
                  "No hay conductores online ni riders con viaje activo con ubicación para mostrar",
              }),
            ],
          }),
        }),
      (snapshot.error !== null || snapshot.zonesError !== null) &&
        jsxRuntime.jsx("div", {
          className: "absolute inset-x-3 z-20 flex justify-center",
          style: { top: 128 },
          children: jsxRuntime.jsxs("div", {
            role: "alert",
            className:
              "flex items-center gap-3 rounded-card border border-cardBorder bg-surface px-4 py-3 shadow-xl shadow-black/50",
            style: { maxWidth: "calc(100vw - 2rem)" },
            children: [
              jsxRuntime.jsx("p", {
                className: "max-w-md text-xs text-textSecondary",
                children:
                  snapshot.error !== null
                    ? `No se pudieron cargar los datos del mapa: ${snapshot.error}`
                    : `No se pudieron cargar las zonas: ${snapshot.zonesError}`,
              }),
              jsxRuntime.jsx(Button, {
                size: "sm",
                variant: "ghost",
                icon: RetryIcon,
                onClick: retryAll,
                children: "Reintentar",
              }),
            ],
          }),
        }),
      selectedDriverId !== null &&
        selectedDriver &&
        jsxRuntime.jsxs("section", {
          role: "region",
          "aria-label": "Detalle del conductor",
          className:
            "absolute z-20 overflow-y-auto rounded-card border border-primary/25 bg-[#0A0A0E]/95 p-4 shadow-2xl shadow-black/60 backdrop-blur",
          style:
            containerWidth < 768
              ? { left: 12, right: 12, bottom: 12, maxHeight: "48vh" }
              : {
                  left: "auto",
                  right: 16,
                  top: 96,
                  bottom: "auto",
                  width: 360,
                  maxHeight: "calc(100vh - 10rem)",
                },
          children: [
            jsxRuntime.jsxs("div", {
              className: "flex items-start justify-between gap-3",
              children: [
                jsxRuntime.jsxs("div", {
                  className: "min-w-0",
                  children: [
                    jsxRuntime.jsx("h2", {
                      className: "truncate text-base font-bold text-white",
                      children: selectedDriver.name,
                    }),
                    jsxRuntime.jsx("p", {
                      className: "mt-0.5 break-words text-xs text-primary",
                      children: vehicleLabel(selectedDriver),
                    }),
                    selectedDriver.phone !== "" &&
                      jsxRuntime.jsx("p", {
                        className: "mt-1 text-xs text-textSecondary",
                        children: selectedDriver.phone,
                      }),
                    selectedDriver.rating !== null &&
                      jsxRuntime.jsx("p", {
                        className: "mt-1 text-xs text-textSecondary",
                        children: `Rating ${selectedDriver.rating.toFixed(1)}`,
                      }),
                  ],
                }),
                jsxRuntime.jsx("button", {
                  type: "button",
                  "aria-label": "Mostrar todos los conductores",
                  onClick: () => clearSelection(true),
                  className:
                    "shrink-0 rounded-pill border border-primary/30 px-3 py-1.5 text-[11px] font-bold text-primary transition-colors hover:bg-primary/10 focus:outline-none focus:ring-2 focus:ring-primary/60",
                  children: "Mostrar todos",
                }),
              ],
            }),
            jsxRuntime.jsx("div", {
              role: "status",
              "aria-live": "polite",
              className:
                "mt-3 rounded-input border border-white/10 bg-white/5 px-3 py-2 text-xs font-semibold text-textPrimary",
              children: detailStatus,
            }),
            detail.trip !== null &&
              jsxRuntime.jsxs("div", {
                className: "mt-3 space-y-3",
                children: [
                  jsxRuntime.jsxs("div", {
                    children: [
                      jsxRuntime.jsx("p", {
                        className:
                          "text-[10px] font-bold uppercase tracking-wide text-textHint",
                        children: "Rider",
                      }),
                      jsxRuntime.jsx("p", {
                        className: "mt-0.5 text-sm font-semibold text-white",
                        children: detail.trip.rider.name,
                      }),
                      detail.trip.rider.phone !== "" &&
                        jsxRuntime.jsx("p", {
                          className: "text-xs text-textSecondary",
                          children: detail.trip.rider.phone,
                        }),
                    ],
                  }),
                  jsxRuntime.jsx(DetailRow, {
                    label: "Recogida",
                    value: detail.trip.pickup.address || "Sin dirección",
                  }),
                  jsxRuntime.jsx(DetailRow, {
                    label: "Destino",
                    value: detail.trip.dropoff.address || "Sin dirección",
                  }),
                  detail.trip.fare !== null &&
                    detail.trip.fare > 0 &&
                    jsxRuntime.jsx("p", {
                      className: "text-xs font-semibold text-primary",
                      children: `Tarifa $${detail.trip.fare.toFixed(2)}`,
                    }),
                ],
              }),
            !detail.loading &&
              detail.trip === null &&
              detail.error === null &&
              jsxRuntime.jsx("p", {
                className: "mt-3 text-xs text-textSecondary",
                children: "Este conductor no tiene un viaje activo.",
              }),
            detail.loading &&
              detail.trip !== null &&
              jsxRuntime.jsx("p", {
                className: "mt-3 text-[11px] text-textHint",
                children: "Actualizando detalle…",
              }),
            routeUnavailable &&
              jsxRuntime.jsxs("div", {
                role: "alert",
                className:
                  "mt-3 rounded-input border border-error/30 bg-error/10 p-3",
                children: [
                  jsxRuntime.jsx("p", {
                    className: "text-xs font-bold text-error",
                    children: "Ruta no disponible",
                  }),
                  jsxRuntime.jsx("p", {
                    className: "mt-1 break-words text-[11px] text-textSecondary",
                    children:
                      detail.error ??
                      "El proveedor no entregó una ruta real para este viaje.",
                  }),
                  jsxRuntime.jsx("button", {
                    type: "button",
                    disabled: detail.loading,
                    onClick: () => setDetailRetry((value) => value + 1),
                    className:
                      "mt-2 rounded-pill border border-primary/30 px-3 py-1.5 text-[11px] font-bold text-primary hover:bg-primary/10 disabled:opacity-50",
                    children: "Reintentar",
                  }),
                ],
              }),
          ],
        }),
    ],
  });
}

function StatPill({ dotClass, label, dotStyle }) {
  return jsxRuntime.jsxs("span", {
    className:
      "pointer-events-auto flex items-center gap-1.5 rounded-chip border border-cardBorder bg-[#0A0A0E]/85 px-3 py-1.5 backdrop-blur",
    children: [
      jsxRuntime.jsx("span", {
        className: classNames("h-2 w-2 rounded-full", dotClass),
        style: dotStyle,
      }),
      jsxRuntime.jsx("span", {
        className: "text-[11px] font-bold text-textPrimary",
        children: label,
      }),
    ],
  });
}

function MapToggle({ active, onClick, children }) {
  return jsxRuntime.jsx("button", {
    type: "button",
    "aria-pressed": active,
    onClick,
    className: classNames(
      "rounded-chip px-3 py-1 text-[11px] font-bold transition-colors focus:outline-none focus:ring-2 focus:ring-primary/60",
      active
        ? "bg-primary text-onPrimary"
        : "text-textHint hover:text-textSecondary",
    ),
    children,
  });
}

function LegendItem({ children }) {
  return jsxRuntime.jsx("span", {
    className:
      "flex items-center gap-1.5 text-[10.5px] font-semibold text-textSecondary",
    children,
  });
}

function DetailRow({ label, value }) {
  return jsxRuntime.jsxs("div", {
    children: [
      jsxRuntime.jsx("p", {
        className: "text-[10px] font-bold uppercase tracking-wide text-textHint",
        children: label,
      }),
      jsxRuntime.jsx("p", {
        className: "mt-0.5 break-words text-xs leading-relaxed text-textSecondary",
        children: value,
      }),
    ],
  });
}

export { CruiseMapScreen as MapaScreen };
