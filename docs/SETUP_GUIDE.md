# 🗺️ Mapbox Game Navigation - Setup Guide

Guía completa de instalación y configuración del sistema de navegación tipo juego.

## 📋 Requisitos Previos

- Flutter 3.24.0 o superior
- Dart 3.5.0 o superior
- Mapbox Account (para API token)

## 🔧 Instalación

### 1. Dependencias

```yaml
# pubspec.yaml
dependencies:
  flutter:
    sdk: flutter
  
  # Mapbox SDK
  mapbox_maps_flutter: ^2.20.0
  
  # Geolocalización
  geolocator: ^10.1.0
  
  # Utilidades
  permission_handler: ^11.3.0
```

```bash
flutter pub get
```

### 2. Configuración Android

```gradle
// android/build.gradle
allprojects {
    repositories {
        google()
        mavenCentral()
        // Mapbox Maven
        maven {
            url 'https://api.mapbox.com/downloads/v2/releases/maven'
            authentication {
                basic(BasicAuthentication)
            }
            credentials {
                username = 'mapbox'
                password = MAPBOX_DOWNLOADS_TOKEN
            }
        }
    }
}
```

```gradle
// android/app/build.gradle
android {
    compileSdkVersion 34
    
    defaultConfig {
        minSdkVersion 23
        targetSdkVersion 34
    }
}
```

```xml
<!-- android/app/src/main/AndroidManifest.xml -->
<manifest>
    <!-- Permisos de ubicación -->
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
    
    <application
        android:label="Cruise Navigation"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher">
        
        <activity ...>
            ...
        </activity>
        
        <!-- Servicio de ubicación en foreground -->
        <service
            android:name="com.lyokone.location.FlutterLocationService"
            android:foregroundServiceType="location"
            android:exported="false" />
    </application>
</manifest>
```

### 3. Configuración iOS

```plist
<!-- ios/Runner/Info.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Permisos de ubicación -->
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>La aplicación necesita acceder a tu ubicación para mostrar la navegación en tiempo real.</string>
    
    <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
    <string>La aplicación necesita acceder a tu ubicación en segundo plano para continuar la navegación.</string>
    
    <key>NSLocationAlwaysUsageDescription</key>
    <string>La aplicación necesita acceder a tu ubicación en segundo plano.</string>
    
    <!-- Modo de background para location -->
    <key>UIBackgroundModes</key>
    <array>
        <string>location</string>
    </array>
</dict>
</plist>
```

```ruby
# ios/Podfile
platform :ios, '14.0'

target 'Runner' do
  use_frameworks!
  use_modular_headers!
  
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
end
```

### 4. Token de Mapbox

```dart
// lib/config/mapbox_config.dart
class MapboxConfig {
  static const String accessToken = 'TU_TOKEN_AQUI';
  
  static const String styleDark = 'mapbox://styles/mapbox/navigation-night-v1';
  static const String styleGameNavigation = 'asset://assets/mapbox/game-navigation-dark.json';
}
```

```dart
// lib/main.dart
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'config/mapbox_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Configurar token global
  MapboxOptions.setAccessToken(MapboxConfig.accessToken);
  
  runApp(const MyApp());
}
```

## 📂 Estructura de Archivos

```
lib/
├── config/
│   └── mapbox_config.dart              # Token y URLs de estilos
├── models/
│   └── lat_lng.dart                    # Modelo LatLng propio
├── navigation/
│   ├── game_car_renderer.dart          # Renderer de coche 3D
│   ├── glowing_route_renderer.dart     # Renderer de rutas glow
│   ├── movement_interpolator.dart      # LERP 60 FPS
│   └── smooth_camera_controller.dart   # Cámara cinemática
├── screens/
│   └── game_navigation_screen.dart     # Pantalla principal
└── main.dart

assets/
└── mapbox/
    └── game-navigation-dark.json       # Estilo Mapbox custom

docs/
└── GAME_NAVIGATION.md                  # Documentación completa
```

## 🚀 Uso Rápido

```dart
import 'package:flutter/material.dart';
import 'models/lat_lng.dart';
import 'screens/game_navigation_screen.dart';

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  void _startNavigation(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GameNavigationScreen(
          destination: LatLng(25.7617, -80.1918), // Miami
          destinationName: 'Miami Beach',
          routePoints: [
            LatLng(25.774, -80.19),
            LatLng(25.768, -80.195),
            LatLng(25.7617, -80.1918),
          ],
          onArrival: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('¡Has llegado!')),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Cruise Navigation')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => _startNavigation(context),
          child: Text('Iniciar Navegación'),
        ),
      ),
    );
  }
}
```

## 🎨 Personalización

### Colores del Coche

```dart
import 'navigation/game_car_renderer.dart';

// Cambiar color del coche
final carImage = await GameCarRenderer.renderCar(
  color: CarColor.cyan,
  type: CarType.sport,
);
```

**Colores disponibles:**
- `CarColor.blue` - Azul brillante
- `CarColor.red` - Rojo deportivo  
- `CarColor.green` - Verde neón
- `CarColor.gold` - Dorado premium
- `CarColor.purple` - Morado cyberpunk
- `CarColor.cyan` - Cian futurista

**Tipos disponibles:**
- `CarType.sport` - Deportivo aerodinámico
- `CarType.suv` - SUV robusto
- `CarType.futuristic` - Estilo cyberpunk

### Estilos de Ruta

```dart
import 'navigation/glowing_route_renderer.dart';

// Diferentes estilos de ruta
await GlowingRouteRenderer.renderGlowingRoute(
  manager: polylineManager,
  points: routePoints,
  style: RouteGlowStyle.cyan, // blue, cyan, purple, gold
);
```

### Parámetros de Cámara

```dart
// En game_navigation_screen.dart

// Delay de seguimiento (más alto = más cinemático)
final cameraController = SmoothCameraController(
  followDelay: Duration(milliseconds: 500),
  positionOffset: Offset(0, 0.40), // 40% hacia abajo
);

// Factor de interpolación (0.05-0.20)
final interpolator = MovementInterpolator(
  lerpFactor: 0.15,      // Movimiento más suave
  rotationLerp: 0.20,    // Rotación más suave
);
```

## 📊 Optimización de Performance

### Reducir uso de batería

```dart
// Aumentar intervalo de GPS cuando no es crítico
Geolocator.getPositionStream(
  locationSettings: AppleSettings(
    activityType: ActivityType.automotiveNavigation,
    pauseLocationUpdatesAutomatically: true,
  ),
);
```

### Reducir uso de memoria

```dart
// Limpiar recursos al salir
@override
void dispose() {
  _animationTimer?.cancel();
  _gpsSubscription?.cancel();
  _carImage?.dispose(); // Liberar imagen del coche
  super.dispose();
}
```

## 🐛 Troubleshooting

### Error: "Mapbox token not set"
```bash
# Asegúrate de llamar MapboxOptions.setAccessToken() en main.dart
```

### Error: "Location permission denied"
```dart
// Solicitar permisos antes de navegar
final status = await Permission.locationWhenInUse.request();
if (status.isGranted) {
  // Iniciar navegación
}
```

### Coche no aparece
```dart
// Verificar que la imagen se generó correctamente
final bytes = await GameCarRenderer.renderCar();
if (bytes == null || bytes.isEmpty) {
  print('Error generando imagen del coche');
}
```

### Ruta no se ve con glow
```dart
// Verificar que el manager está inicializado
_polylineAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager();
await GlowingRouteRenderer.renderGlowingRoute(
  manager: _polylineAnnotMgr!, // Asegurar que no es null
  points: routePoints,
);
```

## 📱 Preview en Dispositivo

### Modo Debug
```bash
flutter run --debug
```

### Modo Profile (para testear performance)
```bash
flutter run --profile
```

### Release
```bash
flutter build apk --release
flutter build ios --release
```

## 🔗 Recursos

- [Mapbox Flutter SDK Docs](https://docs.mapbox.com/flutter/maps/)
- [Geolocator Plugin](https://pub.dev/packages/geolocator)
- [Custom Map Styles](https://docs.mapbox.com/mapbox-gl-js/style-spec/)

## 📄 Licencia

Este proyecto está diseñado para Cruise App.
