# 🎮 Game Navigation System

Sistema de navegación estilo videojuego con Mapbox y Flutter.

## 📱 Visual Preview

```
┌─────────────────────────────────────┐
│  ╔══════════════╗                   │
│  ║  12m  2.4km   ║      45 km/h     │ ← UI Superior (ETA, distancia, velocidad)
│  ╚══════════════╝                   │
│                                     │
│         ╭─────────╮                 │
│        ╱           ╲                │ ← Mapa 3D isométrico
│       │   🚗        │               │    (pitch 55°, coche en lower third)
│        ╲    ✨    ╱                 │
│         ╰────✦────╯                 │ ← Ruta con glow azul
│                                     │
│         ↗ Continue straight         │
│                                     │
│  ╔════════════════════════════╗     │
│  ║  ⬆  Continue straight      ║     │ ← UI Inferior (instrucciones)
│  ║     to Miami Beach           ║     │
│  ╚════════════════════════════╝     │
└─────────────────────────────────────┘
```

## 🎯 Características Principales

### 1. Vista Isométrica 3D
- **Pitch**: 55° (ángulo de cámara elevado)
- **Bearing dinámico**: Cámara rota suavemente con la dirección del coche
- **Lower third**: El coche se posiciona en el tercio inferior de la pantalla

### 2. Coche Estilizado 3D
- Renderizado en Canvas con sombras proyectadas
- Forma aerodinámica tipo deportivo
- Gradientes para efecto 3D
- Rotación suave basada en heading GPS
- 3 variantes: Sport, SUV, Futuristic

### 3. Sistema de Cámara Cinemática
```dart
// Delay suave para efecto "cinematico"
SmoothCameraController(
  followDelay: Duration(milliseconds: 350),
  positionOffset: Offset(0, 0.35), // 35% hacia abajo
)
```

### 4. Interpolación de Movimiento (60 FPS)
```dart
// LERP suave entre puntos GPS
MovementInterpolator(
  lerpFactor: 0.12,      // Posición
  rotationLerp: 0.18,    // Rotación
)
```

### 5. Efectos Dinámicos
- **Turn tilt**: La cámara se inclina al girar
- **Speed zoom**: Zoom out automático a alta velocidad
- **Motion blur**: Efecto sutil a >54 km/h

### 6. Rutas con Glow
4 estilos disponibles:
- `RouteGlowStyle.blue` - Azul estándar
- `RouteGlowStyle.cyan` - Cyan brillante
- `RouteGlowStyle.purple` - Morado neón
- `RouteGlowStyle.gold` - Dorado premium

## 📁 Estructura de Archivos

```
lib/
├── screens/
│   └── game_navigation_screen.dart    # Pantalla principal
├── navigation/
│   ├── game_car_renderer.dart         # Renderer de coche 3D
│   └── glowing_route_renderer.dart    # Renderer de rutas glow
├── config/
│   └── mapbox_config.dart             # Configuración incluyendo styleGameNavigation
└── assets/
    └── mapbox/
        └── game-navigation-dark.json  # Estilo Mapbox custom
```

## 🚀 Uso Básico

```dart
import 'package:flutter/material.dart';
import 'models/lat_lng.dart';
import 'screens/game_navigation_screen.dart';

// Navegar a la pantalla de navegación
Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => GameNavigationScreen(
      destination: LatLng(25.7617, -80.1918), // Miami Beach
      destinationName: 'Miami Beach',
      routePoints: [ /* Lista de puntos de ruta */ ],
      onArrival: () {
        print('¡Llegada!');
      },
    ),
  ),
);
```

## 🎨 Personalización del Coche

```dart
import 'navigation/game_car_renderer.dart';

// Generar coche con color y tipo específicos
final carBytes = await GameCarRenderer.renderCar(
  color: CarColor.cyan,
  type: CarType.sport,
);

// Colores disponibles:
// - CarColor.blue (azul brillante)
// - CarColor.red (rojo deportivo)
// - CarColor.green (verde neón)
// - CarColor.gold (dorado premium)
// - CarColor.purple (morado cyberpunk)
// - CarColor.cyan (cian futurista)
```

## 🛣️ Estilos de Ruta

```dart
import 'navigation/glowing_route_renderer.dart';

// Ruta estándar con glow
await GlowingRouteRenderer.renderGlowingRoute(
  manager: polylineManager,
  points: routePoints,
  style: RouteGlowStyle.blue,
);

// Ruta tipo "carrera" con segmentos
await GlowingRouteRenderer.renderAnimatedRaceRoute(
  manager: polylineManager,
  points: routePoints,
  style: RouteGlowStyle.cyan,
);

// Ruta laser (brillante)
await GlowingRouteRenderer.renderLaserRoute(
  manager: polylineManager,
  points: routePoints,
  style: RouteGlowStyle.purple,
);
```

## ⚙️ Configuración del Estilo Mapbox

El estilo personalizado está en:
```
assets/mapbox/game-navigation-dark.json
```

Características del estilo:
- Fondo: `#0A0E1A` (azul muy oscuro)
- Carreteras: Gradiente de azul grisáceo
- Edificios: `#1A2030` con extrusión 3D a zoom >15
- POIs: Solo restaurantes, gas, hospitales (minimizados)
- Cielo: Gradiente dinámico

## 🎯 Parámetros de Cámara

| Parámetro | Valor | Descripción |
|-----------|-------|-------------|
| `pitch` | 55° | Ángulo de inclinación |
| `zoom` | 16.0-18.0 | Dinámico por velocidad |
| `bearing` | Heading GPS | Rotación de cámara |
| `followDelay` | 350ms | Delay cinemático |
| `positionOffset` | 0.35 | Offset hacia abajo |

## 📊 Lógica de Zoom por Velocidad

```dart
// Zoom automático basado en velocidad
if (speedKmh > 80) zoom = 16.0;      // Zoom out (rápido)
else if (speedKmh > 50) zoom = 16.5; // Medio
else if (speedKmh < 10) zoom = 18.0; // Zoom in (lento)
```

## 🔄 Ciclo de Animación

```
GPS Update (1Hz)
    ↓
MovementInterpolator.pushTarget()
    ↓
Animation Loop (60 FPS / 16ms)
    ↓
interpolator.tick() → LERP position/rotation
    ↓
_updateCarAnnotation() → Mapbox
    ↓
_updateCamera() → setCamera()
    ↓
_calculateDynamicEffects() → tilt/zoom
```

## 📱 UI Components

### Panel Superior
- **ETA**: Tiempo estimado de llegada
- **Distancia**: Kilómetros restantes
- **Velocidad**: km/h actual

### Panel Inferior
- **Flecha direccional**: Próxima maniobra
- **Instrucción**: Texto de navegación
- **Destino**: Nombre del lugar

### Botón Recenter
- Re-centra la cámara en el coche
- Restaura el modo "follow"

## 🎮 Game Feel Enhancements

1. **Smooth Motion**: Interpolación LERP en posición y rotación
2. **Cinematic Camera**: Delay en el seguimiento
3. **Dynamic Effects**: Tilt y zoom basados en comportamiento
4. **Glow Routes**: Múltiples capas de polilíneas
5. **3D Car**: Sombras, gradientes, luces
6. **Minimal UI**: Estilo limpio tipo juego

## 🔧 Requisitos Técnicos

```yaml
# pubspec.yaml
dependencies:
  mapbox_maps_flutter: ^2.20.0
  geolocator: ^10.1.0
```

```xml
<!-- AndroidManifest.xml -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

```plist
<!-- Info.plist -->
<key>NSLocationWhenInUseUsageDescription</key>
<string>Needed for navigation</string>
```

## 📈 Performance

- **Target FPS**: 60
- **GPS Frequency**: 1Hz
- **Memory**: ~50MB para texturas de coche
- **Battery**: Optimizado con throttling inteligente

## 🐛 Troubleshooting

| Problema | Solución |
|----------|----------|
| Coche "salta" | Verificar `lerpFactor` (0.08-0.15) |
| Cámara lenta | Reducir `followDelay` |
| Ruta no glow | Verificar `lineWidth` en polilíneas |
| Flickering | Habilitar `RepaintBoundary` |

## 📝 TODOs Futuros

- [ ] Efectos de partículas (lluvia, nieve)
- [ ] Modo noche con luces de coche
- [ ] Animaciones de UI (transiciones suaves)
- [ ] Soporte para múltiples jugadores (convoy)
- [ ] Integración con audio directions

## 🏆 Créditos

Diseño inspirado en:
- Uber Navigation
- Waze
- Forza Horizon
- Cyberpunk 2077
