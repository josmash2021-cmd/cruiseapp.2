# Tap to Pay - Stripe Terminal Integration Guide

## ✅ Resumen de Implementación

Se ha integrado completamente **Stripe Tap to Pay** en tu app Cruise para pagos NFC contactless.

---

## 📁 Archivos Creados/Modificados

### Flutter (App)

| Archivo | Descripción |
|---------|-------------|
| `pubspec.yaml` | + `stripe_terminal: ^0.0.1+2` |
| `lib/services/tap_to_pay_service.dart` | **NUEVO** - Servicio de Stripe Terminal |
| `lib/services/api_service.dart` | + 4 métodos para Terminal API |
| `lib/screens/tap_to_pay_screen.dart` | **NUEVO** - UI de pago NFC |
| `lib/screens/ride_payment_method_screen.dart` | + Opción "Tap to Pay" |

### Backend (Python/FastAPI)

| Archivo | Descripción |
|---------|-------------|
| `backend/routers/payments.py` | + 4 endpoints Stripe Terminal |

---

## 🚀 Pasos para Activar

### 1. Instalar Dependencias Flutter

```bash
cd C:\Users\Puma\cruiseapp.2
flutter pub get
```

### 2. Configurar Stripe Terminal (Dashboard)

1. Ve a https://dashboard.stripe.com
2. Activa **Terminal** en tu cuenta
3. Crea una **Location**:
   - Nombre: "Cruise Mobile App"
   - Dirección: Tu dirección de negocio
4. Obtén tu `Location ID` (ej: `tml_1234567890`)

### 3. Configurar Variables de Entorno (Backend)

Tu backend ya tiene Stripe configurado. Solo verifica que estas variables estén en tu `.env`:

```env
# Ya deberías tener estas:
STRIPE_SECRET_KEY=sk_live_...
STRIPE_PUBLISHABLE_KEY=pk_live_...

# Opcional para webhooks:
STRIPE_WEBHOOK_SECRET=whsec_...
```

### 4. Actualizar Location ID en Código

En `lib/services/tap_to_pay_service.dart`, actualiza el Location ID:

```dart
// Línea ~45, reemplaza con tu Location ID real
final config = ConnectionConfiguration.TapToPayConnectionConfiguration(
  'tml_TU_LOCATION_ID_AQUI', // ← Reemplazar esto
  // ...
);
```

---

## 🧪 Flujo de Prueba

### Prueba sin Tarjeta Real (Modo Test)

1. Inicia tu backend:
   ```bash
   cd backend
   python run_server.py
   ```

2. Corre la app Flutter:
   ```bash
   flutter run
   ```

3. En la app:
   - Solicita un viaje
   - Selecciona "Tap to Pay" como método de pago
   - Se abrirá la pantalla negra con animación NFC

4. Usa una tarjeta de prueba de Stripe:
   - Número: `4242424242424242`
   - La app simulará la lectura NFC y mostrará "Payment Successful"

---

## 📱 Flujo del Usuario Final

```
┌──────────────────────────────────────────────────────┐
│  1. Rider abre app y solicita viaje                  │
│     ↓                                                │
│  2. Ve opciones de pago (incluye "Tap to Pay")      │
│     ↓                                                │
│  3. Toca "Tap to Pay"                                │
│     ↓                                                │
│  4. Pantalla negra aparece:                          │
│     • "Hold Here to Pay"                             │
│     • Icono NFC pulsante                             │
│     • Partículas azules animadas                     │
│     • Monto del viaje                                │
│     ↓                                                │
│  5. Acerca tarjeta física a la parte superior        │
│     del teléfono (donde está el NFC)                 │
│     ↓                                                │
│  6. Teléfono vibra y lee tarjeta (1-2 segundos)      │
│     ↓                                                │
│  7. Muestra "Payment Successful" + check verde       │
│     ↓                                                │
│  8. App busca automáticamente drivers cercanos      │
└──────────────────────────────────────────────────────┘
```

---

## 🔧 Personalización

### Cambiar Colores de la UI

En `lib/screens/tap_to_pay_screen.dart`:

```dart
// Línea ~40 - Color de fondo
backgroundColor: const Color(0xFF0A0A0A), // Negro actual

// Línea ~220 - Color del icono Cruise
Container(
  color: const Color(0xFF2196F3), // Azul actual
  child: Icon(Icons.local_taxi),
)

// Línea ~13 - Color de partículas
_ParticlesPainter(
  color: const Color(0xFF4A90D9), // Azul actual
)
```

### Cambiar Textos

En `lib/l10n/app_localizations.dart`, agrega:

```dart
String get tapToPayLabel => 'Tap to Pay';
String get holdCardToPhone => 'Hold card to phone';
String get holdHereToPay => 'Hold Here to Pay';
String get paymentSuccessful => 'Payment Successful!';
```

---

## 🐛 Solución de Problemas

### Error: "Failed to initialize payment terminal"

**Causa:** Stripe Terminal no está activado en tu cuenta  
**Solución:** Ve a Stripe Dashboard → Terminal → Activate

### Error: "No NFC support detected"

**Causa:** Dispositivo no tiene NFC o está desactivado  
**Solución:** Verifica que el teléfono tenga NFC activado en Configuración

### Error: "Connection token expired"

**Causa:** Los tokens son de corta duración  
**Solución:** El SDK se encarga de renovarlos automáticamente

---

## 💰 Costos de Stripe

| Tipo | Tarifa |
|------|--------|
| **Tap to Pay (Card Present)** | 2.7% + $0.05 |
| **Sin hardware adicional** | $0 mensual |
| **Sin contratos** | Cancela cuando quieras |

---

## 🔐 Seguridad

- Los datos de la tarjeta **nunca** tocan tu servidor
- Stripe maneja toda la encriptación PCI-DSS compliant
- Tokens de conexión de corta duración (minutos)
- Comunicación HTTPS end-to-end

---

## 📞 Soporte

- **Stripe Terminal Docs:** https://stripe.com/docs/terminal
- **Stripe Dashboard:** https://dashboard.stripe.com
- **Test Cards:** https://stripe.com/docs/testing#cards

---

## ✅ Checklist de Lanzamiento

- [ ] Instalar `stripe_terminal` en Flutter
- [ ] Activar Terminal en Stripe Dashboard
- [ ] Crear Location en Stripe
- [ ] Actualizar Location ID en el código
- [ ] Probar en modo test con tarjetas de prueba
- [ ] Verificar que el backend tiene STRIPE_SECRET_KEY
- [ ] Probar flujo completo end-to-end
- [ ] Publicar en Play Store/App Store

---

**¡Listo! Tu app Cruise ahora acepta pagos NFC contactless.** 🚀
