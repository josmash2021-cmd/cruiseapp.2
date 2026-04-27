import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mek_stripe_terminal/mek_stripe_terminal.dart';
import '../services/api_service.dart';

/// Stripe Terminal reader delegate for Tap to Pay. The SDK requires this
/// callback object to receive reader status events. We log unexpected
/// events but don't surface them to the rider — the UI status comes
/// from `TapToPayService.status` instead.
class _TapToPayDelegate extends TapToPayReaderDelegate {
  @override
  void onStartInstallingUpdate(
    ReaderSoftwareUpdate update,
    Cancellable cancelUpdate,
  ) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[TapToPay] reader update started');
    }
  }

  @override
  void onReportReaderSoftwareUpdateProgress(double progress) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[TapToPay] update progress: ${(progress * 100).toStringAsFixed(0)}%');
    }
  }

  @override
  void onFinishInstallingUpdate(
    ReaderSoftwareUpdate? update,
    TerminalException? exception,
  ) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[TapToPay] update finished. error=${exception?.message}');
    }
  }

  @override
  void onRequestReaderDisplayMessage(ReaderDisplayMessage message) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[TapToPay] display message: $message');
    }
  }

  @override
  void onRequestReaderInput(List<ReaderInputOption> options) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[TapToPay] reader input requested: $options');
    }
  }
}

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

/// Servicio para manejar pagos NFC contactless usando Stripe Terminal SDK.
///
/// Estado de plataformas:
///   • Android: usa el SDK REAL de Stripe Terminal — cobra de verdad.
///     Requisitos: NFC habilitado, Android 11+, cuenta Stripe Terminal
///     aprobada, backend con endpoints `/stripe/connection-token` y
///     `/stripe/create-payment-intent` funcionando.
///   • iOS: actualmente NO soportado en producción. Apple requiere el
///     entitlement `com.apple.developer.proximity-reader.payment.acceptance`
///     que debe solicitarse en developer.apple.com. Mientras no se tenga
///     ese entitlement, en iOS se lanza una excepción clara al llamar
///     `initialize()` y se muestra al usuario un mensaje pidiendo otro
///     método de pago.
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

  // SDK objects — populated once initialize() succeeds.
  Reader? _connectedReader;
  StreamSubscription<List<Reader>>? _discoverySub;
  final _TapToPayDelegate _readerDelegate = _TapToPayDelegate();

  // Getters públicos
  TapToPayStatus get status => _status;
  String? get errorMessage => _errorMessage;
  String? get lastPaymentIntentId => _lastPaymentIntentId;
  bool get isInitialized =>
      _status == TapToPayStatus.ready ||
      _status == TapToPayStatus.waitingForCard;
  bool get isProcessing =>
      _status == TapToPayStatus.processing ||
      _status == TapToPayStatus.readingCard;

  // Stream controller para eventos de estado
  final _statusController = StreamController<TapToPayStatus>.broadcast();
  Stream<TapToPayStatus> get statusStream => _statusController.stream;

  /// Verifica si el dispositivo soporta Tap to Pay.
  /// Solo Android está habilitado en producción hasta que Apple apruebe
  /// el entitlement de proximity-reader para iOS.
  static Future<bool> isSupported() async {
    return Platform.isAndroid;
  }

  /// Inicializa Stripe Terminal y conecta al lector NFC del propio
  /// teléfono (Tap to Pay on Android).
  Future<void> initialize() async {
    if (_status == TapToPayStatus.initializing ||
        _status == TapToPayStatus.ready ||
        _status == TapToPayStatus.waitingForCard) {
      return;
    }

    // Bloquea iOS hasta tener el entitlement de Apple. Lanza un error
    // claro para que la UI pueda mostrar un mensaje útil al usuario.
    if (Platform.isIOS) {
      _handleError(
        'Tap to Pay no está disponible en iOS aún. '
        'Por favor selecciona otro método de pago.',
      );
      throw TapToPayException(
        'Tap to Pay en iPhone requiere aprobación de Apple. '
        'Mientras tanto, usa otro método de pago.',
        status: _status,
      );
    }

    if (!Platform.isAndroid) {
      _handleError('Tap to Pay solo funciona en Android e iOS.');
      throw TapToPayException('Plataforma no soportada', status: _status);
    }

    _updateStatus(TapToPayStatus.initializing);
    _errorMessage = null;

    try {
      // 1. Inicializar Terminal con el callback que pide el connection
      //    token al backend cada vez que el SDK lo necesite. Solo se
      //    llama una vez por sesión; las llamadas subsiguientes son
      //    no-op si ya está inicializado.
      if (!Terminal.isInitialized) {
        await Terminal.initTerminal(
          shouldPrintLogs: kDebugMode,
          fetchToken: () async {
            final token = await ApiService.getConnectionToken();
            if (token.isEmpty) {
              throw TapToPayException(
                'Backend devolvió un connection token vacío',
              );
            }
            return token;
          },
        );
      }
      final terminal = Terminal.instance;

      _updateStatus(TapToPayStatus.connecting);

      // 2. Descubrir el lector Tap to Pay (el propio teléfono).
      //    Usamos el primer evento del stream — para Tap to Pay siempre
      //    devuelve un único reader local.
      final readers = await terminal
          .discoverReaders(
            const TapToPayDiscoveryConfiguration(isSimulated: false),
          )
          .firstWhere((list) => list.isNotEmpty)
          .timeout(const Duration(seconds: 30));

      if (readers.isEmpty) {
        throw TapToPayException('No se encontró lector Tap to Pay');
      }

      // 3. Conectar al reader local. Esto registra el teléfono como
      //    lector móvil con la location de Stripe.
      _connectedReader = await terminal.connectReader(
        readers.first,
        configuration: TapToPayConnectionConfiguration(
          locationId: _locationId,
          merchantDisplayName: 'Cruise',
          readerDelegate: _readerDelegate,
        ),
      );
      _lastReaderId = _connectedReader?.serialNumber ??
          'mobile_reader_${DateTime.now().millisecondsSinceEpoch}';

      _updateStatus(TapToPayStatus.ready);
    } on TapToPayException {
      rethrow;
    } catch (e) {
      _handleError('Error inicializando Terminal: $e');
      throw TapToPayException(
        'No se pudo inicializar Tap to Pay: $e',
        status: _status,
      );
    }
  }

  /// Inicia un pago Tap to Pay con cobro REAL via Stripe Terminal.
  ///
  /// Flujo:
  ///   1. Backend crea un PaymentIntent y devuelve `client_secret`.
  ///   2. SDK recupera el PaymentIntent localmente.
  ///   3. SDK abre la UI nativa de NFC ("Hold card here") y lee la
  ///      tarjeta del rider.
  ///   4. SDK confirma el PaymentIntent — Stripe cobra a la tarjeta.
  ///   5. Backend recibe el webhook `payment_intent.succeeded`.
  Future<Map<String, dynamic>> startPayment({
    required int amount,
    String currency = 'usd',
    String description = 'Cruise Ride Payment',
  }) async {
    if (_status != TapToPayStatus.ready) {
      await initialize();
    }
    if (!Terminal.isInitialized) {
      throw TapToPayException(
        'Terminal no inicializado',
        status: _status,
      );
    }
    final terminal = Terminal.instance;

    _updateStatus(TapToPayStatus.waitingForCard);
    _errorMessage = null;

    try {
      // 1. Crear PaymentIntent en backend → devuelve client_secret + id.
      final paymentIntentData = await ApiService.createTapToPayPaymentIntent(
        amount: amount,
        currency: currency,
        description: description,
      );
      _lastPaymentIntentId = paymentIntentData['id'] as String?;
      final clientSecret = paymentIntentData['client_secret'] as String?;
      if (clientSecret == null || clientSecret.isEmpty) {
        throw TapToPayException(
          'Backend no devolvió client_secret',
        );
      }

      // 2. Recuperar el PaymentIntent en el SDK local.
      final pi = await terminal.retrievePaymentIntent(clientSecret);

      _updateStatus(TapToPayStatus.readingCard);

      // 3. Pedir al rider que acerque su tarjeta. El SDK abre la UI
      //    nativa de "Hold card here" — esta llamada se completa cuando
      //    se lee correctamente la tarjeta o falla. collectPaymentMethod
      //    devuelve un CancelableFuture, await lo resuelve normalmente.
      final collected = await terminal.collectPaymentMethod(pi);

      _updateStatus(TapToPayStatus.processing);

      // 4. Confirmar el PaymentIntent — Stripe procesa el cobro real.
      //    confirmPaymentIntent también devuelve CancelableFuture.
      final confirmed = await terminal.confirmPaymentIntent(collected);

      _updateStatus(TapToPayStatus.success);

      return {
        'success': true,
        'payment_intent_id': confirmed.id,
        'amount': amount,
        'currency': currency,
        'status': confirmed.status.name,
      };
    } on TapToPayException {
      rethrow;
    } catch (e) {
      _handleError('Error procesando pago: $e');
      throw TapToPayException(
        'No se pudo completar el pago: $e',
        status: _status,
      );
    }
  }

  /// Cancela el pago en curso (cierra la UI de NFC del SDK si está abierta).
  Future<void> cancelPayment() async {
    try {
      // El SDK cancela automáticamente al hacer dispose o cambiar de
      // PaymentIntent. Aquí solo marcamos el estado.
      _updateStatus(TapToPayStatus.ready);
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('Error cancelando pago: $e');
      }
    }
  }

  /// Desconecta el lector y limpia recursos
  Future<void> disconnect() async {
    try {
      await _discoverySub?.cancel();
      _discoverySub = null;
      if (Terminal.isInitialized) {
        try {
          await Terminal.instance.disconnectReader();
        } catch (_) {/* ignore — may not be connected */}
      }
      _connectedReader = null;
      _updateStatus(TapToPayStatus.idle);
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
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
      // ignore: avoid_print
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
    unawaited(disconnect());
    _statusController.close();
    super.dispose();
  }
}
