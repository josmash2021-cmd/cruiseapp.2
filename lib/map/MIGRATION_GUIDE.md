# Guía de Migración — Arquitectura de Mapa Único

## Resumen

Se ha implementado la arquitectura de mapa único persistente inspirada en Uber (Proyecto Carbon). Los archivos legacy siguen funcionando — la migración es progresiva.

## Archivos nuevos

```
lib/map/
├── unified_map_service.dart      # Singleton del mapa persistente
├── map_layer_manager.dart        # Gestión de capas lógicas
├── camera_director.dart          # Control de cámara centralizado
├── padding_provider.dart         # Ajuste de márgenes
├── map_shell_screen.dart         # Shell con mapa persistente
├── map_module.dart               # Exports del módulo
├── MIGRATION_GUIDE.md            # Esta guía
├── layers/                       # Capas de anotaciones
│   (definidas en map_layer_manager.dart)
└── overlays/                     # Overlays de UI
    └── home_overlay.dart         # Ejemplo: overlay de home
```

## Estado actual

✅ **Fundamentos implementados:**
- `UnifiedMapService` — singleton del mapa persistente
- `MapLayerManager` — gestión de capas (pickup_pin, dropoff_pin, route, driver_car, location_dot, nearby_cars)
- `CameraDirector` — control centralizado de cámara con locks exclusivos
- `PaddingProvider` — ajuste de márgenes por overlays
- `MapShellScreen` — contenedor con mapa persistente + overlay child
- `RiderTripController` — integrado con `_syncMapToPhase()` auto-ejecutado en cada cambio de fase

## Cómo integrar con main.dart

### Opción A: Reemplazo completo (cuando todas las pantallas estén migradas)

```dart
// main.dart
import 'map/map_module.dart';
import 'state/rider_trip_controller.dart';

// En lugar de:
// home: const SplashScreen(),

// Usar:
home: const SplashScreen(), // Splash sigue siendo entry point

// Después del login, navegar a MapShellScreen:
Navigator.of(context).pushAndRemoveUntil(
  MaterialPageRoute(
    builder: (_) => MapShellScreen(
      child: ListenableBuilder(
        listenable: riderTripController,
        builder: (ctx, _) => _buildOverlayForPhase(riderTripController.state.phase),
      ),
    ),
  ),
  (_) => false,
);

Widget _buildOverlayForPhase(RiderPhase phase) {
  return switch (phase) {
    RiderPhase.idle => const HomeOverlay(
        onWhereToTap: () => riderTripController.startLocationSelection(),
      ),
    RiderPhase.selectingLocations => const LocationSearchOverlay(),
    RiderPhase.previewRoute => const RoutePreviewOverlay(),
    RiderPhase.selectingRide => const RideOptionsOverlay(),
    RiderPhase.requesting => const SearchingOverlay(),
    RiderPhase.driverAssigned => const DriverInfoOverlay(),
    RiderPhase.driverArriving => const TrackingOverlay(),
    RiderPhase.onTrip => const OnTripOverlay(),
    RiderPhase.completed => const TripSummaryOverlay(),
    RiderPhase.cancelled => const CancelledOverlay(),
  };
}
```

### Opción B: Integración progresiva (recomendada durante la transición)

Mantener `main.dart` sin cambios. Crear una pantalla intermedia que use `MapShellScreen`:

```dart
// screens/unified_map_screen.dart
class UnifiedMapScreen extends StatelessWidget {
  const UnifiedMapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MapShellScreen(
      child: ListenableBuilder(
        listenable: riderTripController,
        builder: (ctx, _) => _buildOverlay(context),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final phase = riderTripController.state.phase;
    return switch (phase) {
      RiderPhase.idle => HomeOverlay(
          onWhereToTap: () => riderTripController.startLocationSelection(),
          onScheduleTap: () => Navigator.push(context, ...), // legacy screen
          userName: 'John',
        ),
      // ... otros overlays
      _ => const SizedBox.shrink(), // fallback mientras se migran
    };
  }
}
```

## Cómo migrar una pantalla existente

### Antes (pantalla con su propio mapa):

```dart
class MapScreen extends StatefulWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        MapWidget(...),  // ← propio mapa
        Positioned(...), // UI overlay
        Positioned(...), // UI overlay
      ]),
    );
  }
}
```

### Después (overlay sin mapa):

```dart
class RoutePreviewOverlay extends StatelessWidget {
  const RoutePreviewOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    // NO MapWidget! Solo UI overlays
    return Stack(
      fit: StackFit.expand,
      children: [
        // Bottom panel con info de ruta
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: RouteInfoPanel(...),
        ),
        // Top bar con direcciones
        Positioned(
          top: MediaQuery.of(context).padding.top + 16,
          left: 16, right: 16,
          child: AddressBar(...),
        ),
        // FABs
        Positioned(
          right: 16,
          bottom: 300,
          child: RecenterButton(...),
        ),
      ],
    );
  }
}
```

El mapa ya está renderizado debajo por `MapShellScreen`. Las capas (pins, rutas) se controlan via `UnifiedMapService.instance`.

## Cómo controlar capas desde un overlay

```dart
// Mostrar pickup pin
final layers = MapLayerManager.instance;
layers.show('pickup_pin');
(layers.get('pickup_pin') as PinLayer).setPosition(LatLng(33.5, -86.8));

// Mostrar ruta
layers.show('route');
(layers.get('route') as RouteLayer).setRoute([LatLng(33.5, -86.8), LatLng(33.6, -86.9)]);

// Ajustar cámara
UnifiedMapService.instance.whenReady(() {
  CameraDirector().fitToPoints([...]);
});
```

## Cómo manejar navegación durante la transición

### Pantallas migradas:

```dart
// No usar Navigator.push! Cambiar fase del controller:
riderTripController.setPhase(RiderPhase.previewRoute);
```

### Pantallas NO migradas (legacy):

```dart
// Navegar normalmente — el mapa persistente sigue vivo detrás
Navigator.push(context, MaterialPageRoute(builder: (_) => LegacyScreen()));
// Al volver, el mapa y sus capas siguen intactos
```

## Roadmap de migración

| # | Pantalla | Estado | Overlay |
|---|----------|--------|---------|
| 1 | HomeScreen | 🔄 Pendiente | `HomeOverlay` (esqueleto creado) |
| 2 | MapScreen (plan/pin) | ⏳ Pendiente | `LocationSearchOverlay` |
| 3 | MapScreen (route preview) | ⏳ Pendiente | `RoutePreviewOverlay` |
| 4 | MapScreen (options) | ⏳ Pendiente | `RideOptionsOverlay` |
| 5 | RideRequestScreen | ⏳ Pendiente | `SearchingOverlay` |
| 6 | RiderTrackingScreen | ⏳ Pendiente | `TrackingOverlay` |
| 7 | RideRatingScreen | ⏳ Pendiente | `TripSummaryOverlay` |
| 8 | DriverHomeScreen | ⏳ Pendiente | `DriverHomeOverlay` |
| 9 | DriverOnlineScreen | ⏳ Pendiente | `DriverOnlineOverlay` |
| 10 | DriverTripAcceptScreen | ⏳ Pendiente | `DriverPickupOverlay` |
| 11 | DriverNavScreen | ⏳ Pendiente | `DriverNavigationOverlay` |

## Notas importantes

1. **`MapControllerCache` legacy**: Sigue funcionando para pantallas no migradas. No eliminar hasta que TODO esté migrado.

2. **`RiderTripController._syncMapToPhase()`**: Se ejecuta automáticamente después de cada cambio de fase. No necesitas llamarlo manualmente.

3. **Iconos de capas**: Usar `riderTripController.setLayerIcons()` después de cargar las imágenes PNG.

4. **Memory**: El mapa persistente consume más memoria que crear/destruir. Monitorear con profiling.

5. **Testing**: Probar en Android e iOS. Mapbox puede comportarse diferente en cada plataforma.
