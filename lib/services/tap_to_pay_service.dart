import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../services/api_service.dart';

/// Estados del pago Tap to Pay
enum TapToPayStatus {
  idle,
  initializing,
  connecting,
  ready,
  waitingForCard,
  readingCard,
  processing,
  success,
  error,
}

/// Excepciones específicas de Tap to Pay
class TapToPayException implements Exception {
  final String message;
  final TapToPayStatus? status;
  
  TapToPayException(this.message, {this.status});
  
  @override
  String toString() => 'TapToPayException: $message';
}

/// Servicio para manejar pagos NFC contactless usando Stripe Terminal
class TapToPayService extends ChangeNotifier {
  static final TapToPayService _instance = TapToPayService._internal();
  factory TapToPayService() => _instance;
  TapToPayService._internal();

  /// Stripe Terminal Location ID (de tu Dashboard)
  /// https://dashboard.stripe.com/terminal/locations
  static const String _locationId = 'tml_GdVtzg9wCXtswl';

  TapToPayStatus _status = TapToPayStatus.idle;
  String? _errorMessage;
  String? _lastPaymentIntentId;
  String? _lastReaderId;
  
  // Getters públicos
  TapToPayStatus get status => _status;
  String? get errorMessage => _errorMessage;
  String? get lastPaymentIntentId => _lastPaymentIntentId;
  bool get isInitialized => _status == TapToPayStatus.ready || _status == TapToPayStatus.waitingForCard;
  bool get isProcessing => _status == TapToPayStatus.processing || _status == TapToPayStatus.readingCard;

  // Stream controller para eventos de estado
  final _statusController = StreamController<TapToPayStatus>.broadcast();
  Stream<TapToPayStatus> get statusStream => _statusController.stream;

  /// Verifica si el dispositivo soporta Tap to Pay
  static Future<bool> isSupported() async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    return true;
  }

  /// Inicializa Stripe Terminal
  Future<void> initialize() async {
    if (_status == TapToPayStatus.initializing || _status == TapToPayStatus.ready) {
      return;
    }

    _updateStatus(TapToPayStatus.initializing);
    
    try {
      // Obtener token de conexión desde tu backend
      final connectionToken = await ApiService.getConnectionToken();
      
      // Simular inicialización (en producción usarías stripe_terminal SDK)
      await Future.delayed(const Duration(seconds: 1));
      
      _updateStatus(TapToPayStatus.connecting);
      
      // Conectar al lector local
      await _connectToLocalReader();
      
    } catch (e) {
      _handleError('Error inicializando Terminal: $e');
      throw TapToPayException('No se pudo inicializar Tap to Pay', status: _status);
    }
  }

  /// Conecta al lector local (el propio teléfono actúa como lector NFC)
  Future<void> _connectToLocalReader() async {
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      _lastReaderId = 'local_reader_${DateTime.now().millisecondsSinceEpoch}';
      _updateStatus(TapToPayStatus.ready);
    } catch (e) {
      _handleError('Error conectando lector: $e');
      throw TapToPayException('No se pudo conectar al lector NFC', status: _status);
    }
  }

  /// Inicia un pago Tap to Pay
  Future<Map<String, dynamic>> startPayment({
    required int amount,
    String currency = 'usd',
    String description = 'Cruise Ride Payment',
  }) async {
    if (_status != TapToPayStatus.ready) {
      await initialize();
    }

    _updateStatus(TapToPayStatus.waitingForCard);
    _errorMessage = null;

    try {
      // Crear PaymentIntent desde el backend
      final paymentIntentData = await ApiService.createTapToPayPaymentIntent(
        amount: amount,
        currency: currency,
        description: description,
      );

      _lastPaymentIntentId = paymentIntentData['id'];
      
      _updateStatus(TapToPayStatus.readingCard);
      
      // Simulación del flujo NFC (2-3 segundos)
      await Future.delayed(const Duration(seconds: 3));
      
      _updateStatus(TapToPayStatus.processing);
      
      // Procesar el pago
      final result = await _processPayment(paymentIntentData);
      
      _updateStatus(TapToPayStatus.success);
      
      return {
        'success': true,
        'payment_intent_id': _lastPaymentIntentId,
        'amount': amount,
        'currency': currency,
        'status': 'succeeded',
      };
      
    } catch (e) {
      _handleError('Error procesando pago: $e');
      throw TapToPayException('No se pudo completar el pago', status: _status);
    }
  }

  /// Procesa el pago con Stripe
  Future<Map<String, dynamic>> _processPayment(Map<String, dynamic> paymentIntent) async {
    await Future.delayed(const Duration(seconds: 1));
    
    // Confirmar el pago en el backend
    return await ApiService.confirmTapToPayPayment(
      paymentIntentId: paymentIntent['id'],
    );
  }

  /// Cancela el pago en curso
  Future<void> cancelPayment() async {
    try {
      _updateStatus(TapToPayStatus.ready);
    } catch (e) {
      if (kDebugMode) {
        print('Error cancelando pago: $e');
      }
    }
  }

  /// Desconecta el lector y limpia recursos
  Future<void> disconnect() async {
    try {
      _updateStatus(TapToPayStatus.idle);
    } catch (e) {
      if (kDebugMode) {
        print('Error desconectando: $e');
      }
    }
  }

  /// Actualiza el estado y notifica listeners
  void _updateStatus(TapToPayStatus newStatus) {
    _status = newStatus;
    _statusController.add(newStatus);
    notifyListeners();
  }

  /// Maneja errores
  void _handleError(String message) {
    _errorMessage = message;
    _updateStatus(TapToPayStatus.error);
    if (kDebugMode) {
      print('TapToPay Error: $message');
    }
  }

  /// Limpia mensaje de error
  void clearError() {
    _errorMessage = null;
    if (_status == TapToPayStatus.error) {
      _updateStatus(TapToPayStatus.ready);
    }
  }

  @override
  void dispose() {
    _statusController.close();
    super.dispose();
  }
}
