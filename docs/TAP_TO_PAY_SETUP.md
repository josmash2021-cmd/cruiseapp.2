# Tap to Pay (Stripe Terminal NFC) — Setup Guide

Esta guía describe lo que necesitas configurar fuera del código para que Tap
to Pay funcione en producción.

## Estado actual

| Componente | Estado | Plataforma |
|------------|--------|------------|
| Frontend Flutter (SDK real) | ✅ Listo | Android |
| Backend FastAPI (endpoints) | ✅ Listo | — |
| Permisos Android (NFC, Bluetooth) | ✅ Listo | Android |
| iOS Tap to Pay | 🔒 Oculto | iOS (esperando Apple) |

## Lo que tienes que configurar tú

### 1. Stripe Dashboard

1. Ve a <https://dashboard.stripe.com/terminal>.
2. **Activar Tap to Pay on Android**:
   - Settings → Terminal → Tap to Pay
   - Click en "Activate Tap to Pay on Android"
3. **Verificar la Location**:
   - El código usa el Location ID `tml_GdVtzg9wCXtswl`.
   - Confirma que esa Location pertenece a TU cuenta:
     <https://dashboard.stripe.com/terminal/locations>
   - Si es de otra cuenta o no existe, crea una nueva y actualiza el ID en
     `lib/services/tap_to_pay_service.dart` (constante `_locationId`).

### 2. Backend env vars (Railway / tu hosting)

El backend usa la API de Stripe. Configura estas variables de entorno donde
corras el backend (Railway, Render, etc.):

```env
STRIPE_SECRET_KEY=sk_test_...   # para pruebas
# o
STRIPE_SECRET_KEY=sk_live_...   # para producción real
STRIPE_WEBHOOK_SECRET=whsec_...
```

Sin `STRIPE_SECRET_KEY` el backend devuelve datos mock y NO procesa pagos.

### 3. Codemagic env vars (build de la app)

En Codemagic → tu workflow → Environment variables:

```env
STRIPE_PK=pk_test_...   # para pruebas
# o
STRIPE_PK=pk_live_...   # para producción
```

Esta es la clave pública (no la secreta) que usa la app para Apple Pay,
Google Pay y card entry. Tap to Pay no la necesita directamente, pero
ya la tienes en tu env.

### 4. Probar el flow

#### Modo de prueba (recomendado primero)

Con `STRIPE_SECRET_KEY=sk_test_...`:

1. Compila y abre la app en un Android 11+ con NFC.
2. Pide un viaje, selecciona "Tap to Pay" como método de pago.
3. Click en "Request Now".
4. Aparece la UI nativa de "Hold here to pay".
5. Acerca una **tarjeta de prueba contactless** al teléfono. Stripe acepta:
   - Visa: `4242 4242 4242 4242`
   - Visa débito: `4000 0566 5566 5556`
   - Mastercard: `5555 5555 5555 4444`
6. La app muestra "Payment Successful!" y crea el viaje.

> **Nota**: Las tarjetas de prueba no se cobran pero igual aparecen como
> transacciones en tu Dashboard en modo Test.

#### Modo producción

Con `STRIPE_SECRET_KEY=sk_live_...`:

- Repite el mismo flow con una tarjeta real.
- **Se cobrará el monto real** a tu cuenta Stripe.
- Verifica el cobro en <https://dashboard.stripe.com/payments>.

## Lo que está oculto en iOS

Tap to Pay no aparece en el selector de métodos de pago en iOS porque Apple
requiere el entitlement `com.apple.developer.proximity-reader.payment.acceptance`.

Para activar iOS cuando Apple apruebe:

1. Solicita el entitlement aquí:
   <https://developer.apple.com/contact/request/tap-to-pay-on-iphone/>
2. Cuando aprueben, agrega al archivo `ios/Runner/Runner.entitlements`:

   ```xml
   <key>com.apple.developer.proximity-reader.payment.acceptance</key>
   <true/>
   ```

3. Quita el `if (Platform.isAndroid)` en estos dos archivos:
   - `lib/screens/ride_payment_method_screen.dart` (~línea 189)
   - `lib/screens/ride_request_controller.dart` (~línea 1942)
4. Cambia `static Future<bool> isSupported()` en
   `lib/services/tap_to_pay_service.dart` a `return Platform.isAndroid || Platform.isIOS;`
5. Quita el bloque `if (Platform.isIOS) { throw ... }` en
   `tap_to_pay_service.dart` (~línea 96).

## Endpoints del backend (referencia)

Todos en `backend/routers/payments.py`:

- `POST /stripe/connection-token` — devuelve token para que el SDK se conecte.
- `POST /stripe/create-payment-intent` — crea PaymentIntent con
  `payment_method_types=["card_present"]` (requerido por Terminal).
- `POST /stripe/capture-payment-intent` — verifica/captura el cobro final.
- `GET /stripe/payment-status/:id` — consulta estado del cobro.

## Troubleshooting

### Build de Android falla con "Duplicate class bouncycastle"

Ya está manejado en `android/app/build.gradle.kts` con `pickFirsts` y
`exclude(group = "org.bouncycastle", module = "bcprov-jdk15to18")`.

### "Backend devolvió un connection token vacío"

Significa que `STRIPE_SECRET_KEY` no está configurado en el backend o es
inválido. Revisa env vars de Railway.

### "No se encontró lector Tap to Pay" / timeout 30s

El dispositivo Android no soporta NFC, está deshabilitado, o la cuenta
Stripe no tiene Tap to Pay activado.

### "Location is not in the merchant account"

El Location ID `tml_GdVtzg9wCXtswl` no pertenece a tu cuenta Stripe.
Crea una nueva location en el Dashboard y actualiza la constante
`_locationId` en `lib/services/tap_to_pay_service.dart`.
