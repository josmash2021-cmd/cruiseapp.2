# 🏗️ Arquitectura de Servidores - Cruise App

## 📊 Resumen: ¿Cuántos Servidores Tienes?

Actualmente tienes **2 tipos de servidores**:

1. **Backend Server (FastAPI)** - El cerebro de tu aplicación
2. **Frontend Server (Flutter Web)** - La interfaz visual en el navegador

---

## 🔧 1. BACKEND SERVER (FastAPI + Python)

### ¿Qué es?
El **backend** es el "cerebro" de tu aplicación. Es un servidor que:
- Procesa toda la lógica de negocio
- Maneja la base de datos
- Gestiona autenticación y seguridad
- Procesa pagos con Stripe
- Calcula rutas y precios
- Conecta drivers con pasajeros

### Ubicación
- **Código:** `C:\Users\Puma\CascadeProjects\cruise-app-main\backend\`
- **Archivo principal:** `backend/main.py`
- **Puerto:** 8000
- **URL Local:** http://localhost:8000

### Tecnologías
- **Framework:** FastAPI (Python)
- **Base de datos:** SQLite (`cruise.db`)
- **Servidor web:** Uvicorn
- **APIs externas:** 
  - Google Maps (rutas y geocoding)
  - Stripe (pagos)
  - Firebase (notificaciones)

### ¿Qué hace exactamente?

#### 🔐 Autenticación y Usuarios
```
POST /register        → Registrar nuevos usuarios
POST /login          → Iniciar sesión
GET /profile         → Obtener perfil de usuario
PUT /profile         → Actualizar perfil
```

#### 🚗 Gestión de Viajes
```
POST /request-ride   → Solicitar un viaje
GET /active-trip     → Obtener viaje activo
POST /accept-trip    → Driver acepta viaje
POST /start-trip     → Iniciar viaje
POST /complete-trip  → Finalizar viaje
POST /cancel-trip    → Cancelar viaje
```

#### 💰 Pagos y Finanzas
```
POST /process-payment     → Procesar pago con Stripe
POST /add-tip            → Agregar propina
GET /driver-earnings     → Ver ganancias del driver
POST /payout-transfer    → Transferir ganancias
```

#### 📍 Ubicación y Rutas
```
POST /update-location    → Actualizar ubicación del driver
GET /nearby-drivers      → Buscar drivers cercanos
POST /calculate-fare     → Calcular precio del viaje
GET /surge-pricing       → Obtener multiplicador de surge
```

#### ⭐ Features Adicionales
```
GET /referral-code       → Obtener código de referido
POST /favorite-location  → Guardar ubicación favorita
GET /driver-incentives   → Ver incentivos activos
POST /rate-trip         → Calificar viaje
```

### Estado Actual
- ✅ **Corriendo en:** PID 4980, Puerto 8000
- ✅ **Features:** 20+ endpoints implementados
- ✅ **Seguridad:** 10 capas de protección
- ✅ **Base de datos:** Migrada y funcional

---

## 🎨 2. FRONTEND SERVER (Flutter Web)

### ¿Qué es?
El **frontend** es la interfaz visual que ves en el navegador. Es la aplicación Flutter compilada para web.

### Ubicación
- **Código:** `C:\Users\Puma\CascadeProjects\cruise-app-main\lib\`
- **Archivo principal:** `lib/main.dart`
- **Puerto:** Dinámico (asignado por Flutter)
- **URL:** http://127.0.0.1:[puerto]/

### Tecnologías
- **Framework:** Flutter (Dart)
- **Plataforma:** Web (Chrome/Edge)
- **Servidor:** Flutter DevTools Server

### ¿Qué hace?
- Muestra la interfaz de usuario (pantallas, botones, mapas)
- Captura las acciones del usuario (clicks, inputs)
- Se comunica con el backend para obtener/enviar datos
- Renderiza mapas de Google Maps
- Gestiona navegación entre pantallas

### Pantallas Principales
```
🏠 Splash Screen        → Pantalla de inicio
🔐 Login/Register       → Autenticación
🗺️  Home Map            → Mapa principal (rider/driver)
🚗 Request Ride         → Solicitar viaje
📍 Navigation           → Navegación en tiempo real
💳 Payment              → Procesar pago
⭐ Rating               → Calificar viaje
👤 Profile              → Perfil de usuario
```

### Estado Actual
- ✅ **Corriendo en:** Chrome
- ✅ **Debug Service:** ws://127.0.0.1:52858/...
- ⚠️ **Conectividad:** Intentando conectar al backend

---

## 🔄 ¿Cómo Funcionan Juntos?

```
┌─────────────────────────────────────────────────────────┐
│                    TU TELÉFONO/PC                       │
│  ┌───────────────────────────────────────────────┐     │
│  │         FRONTEND (Flutter App)                 │     │
│  │  - Muestra la interfaz                        │     │
│  │  - Captura acciones del usuario               │     │
│  │  - Renderiza mapas                            │     │
│  └───────────────┬───────────────────────────────┘     │
│                  │                                       │
│                  │ HTTP Requests                        │
│                  │ (GET, POST, PUT)                     │
│                  ▼                                       │
│  ┌───────────────────────────────────────────────┐     │
│  │         BACKEND (FastAPI Server)               │     │
│  │  - Procesa lógica de negocio                  │     │
│  │  - Maneja base de datos                       │     │
│  │  - Conecta con APIs externas                  │     │
│  │  - Gestiona autenticación                     │     │
│  └───────────────┬───────────────────────────────┘     │
│                  │                                       │
│                  ▼                                       │
│  ┌───────────────────────────────────────────────┐     │
│  │         BASE DE DATOS (cruise.db)              │     │
│  │  - Usuarios                                    │     │
│  │  - Viajes                                      │     │
│  │  - Pagos                                       │     │
│  │  - Ubicaciones                                 │     │
│  └───────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────┘
                          │
                          │ APIs Externas
                          ▼
        ┌─────────────────────────────────┐
        │  🗺️  Google Maps API             │
        │  💳 Stripe Payment API           │
        │  🔔 Firebase Cloud Messaging     │
        └─────────────────────────────────┘
```

---

## 🌐 Opciones de Despliegue del Backend

### Opción A: Local (Actual)
- **URL:** http://localhost:8000
- **Ventaja:** Gratis, control total
- **Desventaja:** Requiere PC encendida, solo funciona en tu red local

### Opción B: Railway (Recomendado)
- **URL:** https://tu-app.up.railway.app
- **Ventaja:** 24/7, accesible desde cualquier lugar, HTTPS gratis
- **Desventaja:** ~$5-10/mes

### Opción C: Cloudflare Tunnel
- **URL:** https://xxx.trycloudflare.com
- **Ventaja:** Gratis, accesible desde cualquier lugar
- **Desventaja:** URL cambia cada vez que reinicias

---

## 📦 ¿Qué es cada archivo importante?

### Backend
```
backend/
├── main.py              → Servidor principal (FastAPI)
├── requirements.txt     → Dependencias de Python
├── cruise.db           → Base de datos SQLite
├── migrate_db.py       → Script para actualizar base de datos
├── server_guardian.py  → Script de auto-reinicio
└── Dockerfile          → Configuración para Railway
```

### Frontend
```
lib/
├── main.dart                  → Punto de entrada de la app
├── pages/                     → Pantallas de la app
│   ├── driver_navigation_page.dart
│   ├── home_page.dart
│   └── ...
├── services/                  → Servicios de comunicación
│   ├── api_service.dart      → Conexión con backend
│   └── ...
├── widgets/                   → Componentes reutilizables
│   ├── driver_action_panel.dart
│   └── ...
└── navigation/               → Sistema de navegación GPS
```

---

## 🎯 Flujo de un Viaje Completo

1. **Pasajero abre la app** (Frontend)
   - Flutter carga el mapa
   - Muestra ubicación actual

2. **Pasajero solicita viaje** (Frontend → Backend)
   - Frontend envía: `POST /request-ride`
   - Backend busca drivers cercanos
   - Backend crea registro en la base de datos

3. **Driver recibe notificación** (Backend → Frontend)
   - Backend envía notificación push
   - Frontend del driver muestra alerta

4. **Driver acepta viaje** (Frontend → Backend)
   - Frontend envía: `POST /accept-trip`
   - Backend actualiza estado del viaje
   - Backend notifica al pasajero

5. **Navegación en tiempo real** (Frontend ↔ Backend)
   - Frontend envía ubicación cada segundo
   - Backend calcula ETA y distancia
   - Frontend muestra ruta actualizada

6. **Finalizar viaje** (Frontend → Backend)
   - Frontend envía: `POST /complete-trip`
   - Backend calcula precio final
   - Backend procesa pago con Stripe

7. **Calificación** (Frontend → Backend)
   - Frontend envía: `POST /rate-trip`
   - Backend guarda calificación
   - Backend actualiza rating del driver

---

## 💡 Analogía Simple

Imagina una pizzería:

- **Frontend (Flutter)** = El menú y la caja registradora
  - Es lo que el cliente ve y toca
  - Muestra opciones y captura pedidos

- **Backend (FastAPI)** = La cocina
  - Procesa los pedidos
  - Prepara la comida
  - Gestiona inventario
  - Calcula precios

- **Base de Datos** = El almacén
  - Guarda ingredientes (datos)
  - Historial de pedidos
  - Información de clientes

- **APIs Externas** = Proveedores
  - Google Maps = Servicio de delivery
  - Stripe = Procesador de pagos
  - Firebase = Sistema de notificaciones

---

## ✅ Resumen

**Tienes 2 servidores principales:**

1. **Backend (FastAPI)** - Puerto 8000
   - El cerebro que procesa todo
   - Maneja datos, lógica, seguridad
   - Se comunica con APIs externas

2. **Frontend (Flutter Web)** - Puerto dinámico
   - La cara visible de la app
   - Muestra la interfaz al usuario
   - Se comunica con el backend

**El backend es esencial** - Sin él, la app no puede:
- Autenticar usuarios
- Guardar viajes
- Procesar pagos
- Conectar drivers con pasajeros
- Calcular rutas y precios

Por eso es importante mantenerlo siempre activo (Railway o Server Guardian).
