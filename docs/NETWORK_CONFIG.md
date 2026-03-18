# 🌐 Configuración de Red - Funcionamiento desde Cualquier Red

Guía completa para asegurar que las dos apps (móvil + admin) funcionen desde cualquier red (WiFi, celular, etc.)

---

## ✅ ESTADO ACTUAL

### App Móvil (Rider/Driver)

| Componente | Configuración | Estado |
|-----------|----------------|--------|
| **Permiso Internet** | `android.permission.INTERNET` | ✅ Configurado |
| **HTTP Local** | `android:usesCleartextTraffic="true"` | ✅ Permite localhost |
| **iOS Arbitrary Loads** | `NSAllowsArbitraryLoads = true` | ✅ Permite HTTP |
| **URL Producción** | `https://cruiseapp2-production.up.railway.app` | ✅ HTTPS |
| **URL Local** | `http://localhost:8000` | ✅ Solo desarrollo |
| **Auto-detección** | `probeAndSetBestUrl()` | ✅ Implementado |
| **Firebase** | Cloud Firestore | ✅ Funciona en cualquier red |
| **Mapbox** | Token configurado | ✅ Funciona en cualquier red |

### Admin Dashboard

| Componente | Configuración | Estado |
|-----------|----------------|--------|
| **Firestore** | `cloud_firestore` | ✅ Conectado |
| **Mapbox Web** | Token en JS/HTML | ⚠️ Verificar |
| **Hosting** | Flutter Web | ⚠️ Necesita deploy |
| **CORS** | Configuración backend | ⚠️ Verificar |

---

## 🔧 CONFIGURACIÓN CLAVE

### 1. Servidor Backend (FastAPI)

**URLs Configuradas en `lib/services/api_service.dart`:**

```dart
// Producción - Funciona desde cualquier red
static const String _productionUrl = 
    'https://cruiseapp2-production.up.railway.app';

// Local - Solo desarrollo en misma máquina
static const String _localUrl = 'http://localhost:8000';
```

**Lógica de Selección Automática:**

```dart
// En modo Release (producción): usa URL de Railway
static String _activeUrl = kReleaseMode ? _productionUrl : _localUrl;

// Probe automático detecta la mejor URL disponible
static Future<String?> probeAndSetBestUrl({
  List<String>? candidates,
  Duration timeout = const Duration(seconds: 5),
}) async {
  // Prueba todas las URLs en paralelo
  // Primera que responda 200 OK gana
  // Fallback a producción si ninguna funciona
}
```

**Funcionamiento:**
1. App inicia y prueba `_productionUrl` y `_localUrl` en paralelo
2. La primera que responda con HTTP 200 se usa
3. Si localhost no responde (red diferente), usa Railway automáticamente
4. Resultado: ✅ **Funciona en cualquier red sin configuración manual**

---

### 2. Android - Permisos de Red

**Archivo: `android/app/src/main/AndroidManifest.xml`**

```xml
<!-- Permiso básico de Internet - REQUERIDO -->
<uses-permission android:name="android.permission.INTERNET" />

<!-- Permite HTTP sin cifrar (necesario para localhost en desarrollo) -->
<application
    android:usesCleartextTraffic="true">
    
<!-- Token de Mapbox para acceso desde cualquier red -->
<meta-data
    android:name="MAPBOX_ACCESS_TOKEN"
    android:value="pk.eyJ1Ijoicm95YWxwdXJwbGVjb3Jw..." />
```

**Estado:** ✅ Configurado correctamente

**Nota:** `usesCleartextTraffic` debe ser `false` en producción para seguridad (solo HTTPS)

---

### 3. iOS - Permisos de Red

**Archivo: `ios/Runner/Info.plist`**

```xmln<!-- Permite conexiones HTTP no seguras (necesario para localhost) -->
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>

<!-- Token de Mapbox -->
<key>MBXAccessToken</key>
<string>pk.eyJ1Ijoicm95YWxwdXJwbGVjb3Jw...</string>
```

**Estado:** ✅ Configurado correctamente

**Nota:** `NSAllowsArbitraryLoads` debe ser `false` en producción

---

### 4. Firebase / Firestore

**Funcionamiento:**
- ✅ Cloud Firestore funciona desde **cualquier red automáticamente**
- ✅ No requiere configuración especial de red
- ✅ Usa conexiones seguras (HTTPS/WSS) por defecto
- ✅ Funciona en WiFi, celular, roaming, etc.

**Verificación en Código:**
```dart
// lib/services/trip_firestore_service.dart
static final _db = FirebaseFirestore.instance;
static CollectionReference get _trips => _db.collection('trips');

// Funciona en cualquier red sin cambios
static Future<String> submitRideRequest({...}) async {
  final docRef = await _trips.add({...});  // ✅ Siempre funciona
  return docRef.id;
}
```

---

### 5. Mapbox

**Configuración:**
- ✅ Token público configurado en AndroidManifest e Info.plist
- ✅ Token configurado en código: `MapboxConfig.accessToken`
- ✅ Mapbox funciona desde cualquier red (CDN global)

---

## 📋 CHECKLIST PARA PRODUCCIÓN

### Antes de Release:

#### Android:
```xml
<!-- Cambiar en android/app/src/main/AndroidManifest.xml -->
<application
    android:usesCleartextTraffic="false">  <!-- ❌ Desactivar HTTP claro -->
    
<!-- O usar network_security_config para permitir solo dominios específicos -->
<application
    android:networkSecurityConfig="@xml/network_security_config">
```

#### iOS:
```xml
<!-- Cambiar en ios/Runner/Info.plist -->
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>  <!-- ❌ Desactivar HTTP claro -->
    
    <!-- Permitir solo dominios específicos si es necesario -->
    <key>NSExceptionDomains</key>
    <dict>
        <key>cruiseapp2-production.up.railway.app</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <false/>
        </dict>
    </dict>
</dict>
```

#### Backend:
```python
# FastAPI - Configurar CORS para permitir app móvil desde cualquier origen
from fastapi.middleware.cors import CORSMiddleware

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # O lista específica de dominios
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
```

---

## 🚀 FLUJO DE FUNCIONAMIENTO

### Escenario 1: Usuario en WiFi Local (Desarrollo)
```
1. App inicia
2. Prueba localhost:8000 → ✅ Responde (misma red)
3. Usa localhost para desarrollo rápido
4. Firestore funciona en paralelo (nube)
```

### Escenario 2: Usuario en Celular/4G/5G (Producción)
```
1. App inicia
2. Prueba localhost:8000 → ❌ Timeout (no accesible)
3. Prueba Railway URL → ✅ Responde
4. Usa automáticamente Railway
5. Firestore funciona normalmente
6. Mapbox funciona normalmente
```

### Escenario 3: Usuario en WiFi Pública
```
1. App inicia
2. Prueba localhost → ❌ No accesible
3. Prueba Railway → ✅ Responde
4. Usa Railway automáticamente
5. Todo funciona (Firebase, Mapbox, API)
```

---

## 🔒 SEGURIDAD RECOMENDADA PARA PRODUCCIÓN

### 1. Forzar HTTPS en Backend
```python
# FastAPI - Redirect HTTP a HTTPS
from fastapi import Request
from fastapi.responses import RedirectResponse

@app.middleware("http")
async def https_redirect(request: Request, call_next):
    if request.headers.get("X-Forwarded-Proto") == "http":
        return RedirectResponse(
            url=request.url.replace(scheme="https"), 
            status_code=301
        )
    return await call_next(request)
```

### 2. Certificados SSL Válidos
- ✅ Railway proporciona SSL automáticamente
- ✅ Firebase tiene SSL siempre
- ✅ Mapbox usa SSL siempre

### 3. Headers de Seguridad
```python
# FastAPI
@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["Strict-Transport-Security"] = "max-age=31536000"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    return response
```

---

## 🧪 TESTING

### Verificar Funcionamiento desde Cualquier Red:

```bash
# 1. Build release APK
flutter build apk --release

# 2. Instalar en dispositivo físico
adb install build/app/outputs/flutter-apk/app-release.apk

# 3. Probar escenarios:
#    - Celular con datos móviles (no WiFi)
#    - WiFi diferente a la del servidor
#    - Modo avión + solo WiFi
#    - Red lenta (2G/3G)
```

### Logs de Verificación:
```dart
// En main.dart o ApiService.init()
debugPrint('[Network] Active URL: ${ApiService.activeServerUrl}');
debugPrint('[Network] Is local: ${ApiService.isLocalUrl}');

// Verificar Firestore
FirebaseFirestore.instance.enableNetwork().then((_) {
  debugPrint('[Network] Firestore connected');
});
```

---

## 📊 RESUMEN

### ✅ Ya Funciona desde Cualquier Red:
- **App Móvil**: Sí, via auto-detección de URLs
- **Firebase/Firestore**: Sí, siempre funciona
- **Mapbox**: Sí, siempre funciona
- **Backend Railway**: Sí, HTTPS público
- **Admin Web**: Sí, si está hosteado

### ⚠️ Consideraciones de Seguridad:
- Desactivar `usesCleartextTraffic` en Android para release
- Desactivar `NSAllowsArbitraryLoads` en iOS para release
- Usar HTTPS siempre en producción
- Configurar CORS apropiadamente en backend

### 🎯 Conclusión:
**Las apps están configuradas para funcionar desde cualquier red automáticamente.** El sistema de probe URLs detecta y usa la mejor conexión disponible, y Firebase/Mapbox funcionan desde cualquier red sin configuración adicional.

---

## 🔗 Referencias

- `lib/services/api_service.dart` - Lógica de URLs y probe
- `lib/config/mapbox_config.dart` - Token Mapbox
- `android/app/src/main/AndroidManifest.xml` - Permisos Android
- `ios/Runner/Info.plist` - Permisos iOS
