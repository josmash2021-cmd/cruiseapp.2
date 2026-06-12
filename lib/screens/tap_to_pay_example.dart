// EJEMPLO: Cómo integrar Tap to Pay en el flujo de reserva de viaje
// 
// Este archivo muestra cómo usar Tap to Pay en tu código existente.
// Puedes copiar estas funciones a tu RideRequestScreen o donde manejes
// el flujo de pago.

import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'tap_to_pay_screen.dart';
import '../services/local_data_service.dart';

class TapToPayExample {
  
  /// MÉTODO 1: Desde el selector de métodos de pago
  /// 
  /// Cuando el usuario selecciona "Tap to Pay" en la pantalla de 
  /// métodos de pago, navega a la pantalla de Tap to Pay.
  /// 
  /// Ubicación sugerida: ride_payment_method_screen.dart
  static Future<void> handleTapToPaySelection({
    required BuildContext context,
    required double amount,
    String currency = 'USD',
    required VoidCallback onSuccess,
  }) async {
    // Navegar a la pantalla de Tap to Pay
    final result = await showTapToPayScreen(
      context: context,
      amount: amount,
      currency: currency,
      rideDescription: 'Cruise Ride',
      onPaymentSuccess: () {
        // Guardar que el usuario pagó con Tap to Pay
        LocalDataService.linkPaymentMethod('tap_to_pay');
        onSuccess();
      },
      onPaymentCancelled: () {
        // Usuario canceló el pago
        debugPrint('Pago cancelado');
      },
    );
    
    if (result == true) {
      // Pago exitoso - continuar con el flujo
      debugPrint('Pago completado exitosamente');
    }
  }
  
  /// MÉTODO 2: Antes de buscar conductores
  /// 
  /// Cuando el usuario confirma el viaje y necesita pagar antes de
  /// buscar conductores disponibles.
  /// 
  /// Ubicación sugerida: ride_request_screen.dart o booking flow
  static Future<bool> processTapToPayBeforeBooking({
    required BuildContext context,
    required double fareEstimate,
    String currency = 'USD',
  }) async {
    // Verificar si el método de pago seleccionado es Tap to Pay
    final linkedMethods = await LocalDataService.getLinkedPaymentMethods();
    
    if (linkedMethods.contains('tap_to_pay')) {
      // Mostrar pantalla de Tap to Pay
      if (!context.mounted) return false;
      final paymentResult = await showTapToPayScreen(
        context: context,
        amount: fareEstimate,
        currency: currency,
        rideDescription: 'Cruise Ride',
      );
      
      // Retornar true solo si el pago fue exitoso
      return paymentResult == true;
    }
    
    // Otro método de pago seleccionado
    return false;
  }
  
  /// MÉTODO 3: En tu RideRequestScreen (ejemplo completo)
  /// 
  /// Este es un ejemplo de cómo integrarlo en tu pantalla principal
  /// de solicitud de viaje.
  static Future<void> completeBookingWithTapToPay({
    required BuildContext context,
    required double amount,
    required VoidCallback onPaymentComplete,
    required VoidCallback onPaymentFailed,
  }) async {
    try {
      // Mostrar diálogo de confirmación
      final shouldProceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(S.of(context).confirmPayment),
          content: Text('Pay \$${amount.toStringAsFixed(2)} using Tap to Pay?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(S.of(context).cancel),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE8C547),
              ),
              child: Text(S.of(context).payNow),
            ),
          ],
        ),
      );
      
      if (shouldProceed != true) return;
      
      // Navegar a pantalla de Tap to Pay
      if (!context.mounted) return;
      final paymentSuccess = await showTapToPayScreen(
        context: context,
        amount: amount,
        currency: 'USD',
        rideDescription: 'Cruise Ride',
      );
      
      if (paymentSuccess == true) {
        // ¡Pago exitoso! Ahora buscar conductores
        onPaymentComplete();
        
        // Ejemplo: Navegar a pantalla de búsqueda de drivers
        // Navigator.push(context, MaterialPageRoute(
        //   builder: (_) => SearchingDriverScreen(),
        // ));
      } else {
        // Pago fallido o cancelado
        onPaymentFailed();
      }
      
    } catch (e) {
      debugPrint('Error en Tap to Pay: $e');
      onPaymentFailed();
    }
  }
}

/// INTEGRACIÓN EN TU CÓDIGO EXISTENTE:
///
/// En ride_payment_method_screen.dart, reemplaza el handler de Tap to Pay:
///
/// ```dart
/// if (id == PaymentMethodId.tapToPay) {
///   await TapToPayExample.handleTapToPaySelection(
///     context: context,
///     amount: rideFare, // El monto estimado del viaje
///     onSuccess: () {
///       // Continuar al siguiente paso (buscar drivers)
///       _goToNextScreen(id);
///     },
///   );
///   return;
/// }
/// ```
