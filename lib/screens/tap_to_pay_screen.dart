import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/haptic_service.dart';
import '../services/tap_to_pay_service.dart';
import '../l10n/app_localizations.dart';

/// Pantalla de Tap to Pay - Similar a la UI de Stripe Terminal
/// Muestra animación de NFC y espera que el usuario acerque su tarjeta
class TapToPayScreen extends StatefulWidget {
  final double amount;
  final String currency;
  final String rideDescription;
  final VoidCallback? onPaymentSuccess;
  final VoidCallback? onPaymentCancelled;

  const TapToPayScreen({
    super.key,
    required this.amount,
    this.currency = 'USD',
    this.rideDescription = 'Cruise Ride',
    this.onPaymentSuccess,
    this.onPaymentCancelled,
  });

  @override
  State<TapToPayScreen> createState() => _TapToPayScreenState();
}

class _TapToPayScreenState extends State<TapToPayScreen>
    with TickerProviderStateMixin {
  late final TapToPayService _tapToPayService;
  
  // Animaciones
  late final AnimationController _nfcPulseController;
  late final AnimationController _particlesController;
  late final Animation<double> _nfcScaleAnimation;
  late final Animation<double> _nfcOpacityAnimation;
  
  String _statusMessage = 'Hold Here to Pay';
  bool _isProcessing = false;
  bool _paymentSuccess = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    
    _tapToPayService = TapToPayService();
    _tapToPayService.addListener(_onServiceUpdate);
    
    // Configurar animaciones NFC
    _nfcPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    
    _particlesController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();
    
    _nfcScaleAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(
        parent: _nfcPulseController,
        curve: Curves.easeInOut,
      ),
    );
    
    _nfcOpacityAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(
        parent: _nfcPulseController,
        curve: Curves.easeInOut,
      ),
    );
    
    // Iniciar el proceso de pago
    _initializePayment();
  }

  void _onServiceUpdate() {
    if (!mounted) return;
    
    final status = _tapToPayService.status;
    
    setState(() {
      switch (status) {
        case TapToPayStatus.initializing:
          _statusMessage = 'Initializing...';
          _isProcessing = true;
          break;
        case TapToPayStatus.connecting:
          _statusMessage = 'Connecting...';
          _isProcessing = true;
          break;
        case TapToPayStatus.ready:
        case TapToPayStatus.waitingForCard:
          _statusMessage = 'Hold Here to Pay';
          _isProcessing = false;
          break;
        case TapToPayStatus.readingCard:
          _statusMessage = 'Reading card...';
          _isProcessing = true;
          break;
        case TapToPayStatus.processing:
          _statusMessage = 'Processing...';
          _isProcessing = true;
          break;
        case TapToPayStatus.success:
          _statusMessage = 'Payment Successful!';
          _isProcessing = false;
          _paymentSuccess = true;
          _handleSuccess();
          break;
        case TapToPayStatus.error:
          _statusMessage = 'Payment Failed';
          _isProcessing = false;
          _errorMessage = _tapToPayService.errorMessage;
          break;
        default:
          _statusMessage = 'Hold Here to Pay';
      }
    });
  }

  Future<void> _initializePayment() async {
    try {
      await _tapToPayService.initialize();
      
      // Iniciar el pago
      final amountCents = (widget.amount * 100).round();
      await _tapToPayService.startPayment(
        amount: amountCents,
        currency: widget.currency.toLowerCase(),
        description: widget.rideDescription,
      );
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _statusMessage = 'Payment Failed';
      });
    }
  }

  void _handleSuccess() {
    HapticService.mediumImpact();
    
    // Delay para mostrar el éxito antes de cerrar
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        widget.onPaymentSuccess?.call();
        Navigator.of(context).pop(true);
      }
    });
  }

  void _onCancel() async {
    HapticService.lightImpact();
    
    await _tapToPayService.cancelPayment();
    widget.onPaymentCancelled?.call();
    
    if (mounted) {
      Navigator.of(context).pop(false);
    }
  }

  void _onRetry() {
    setState(() {
      _errorMessage = null;
      _statusMessage = 'Hold Here to Pay';
    });
    _initializePayment();
  }

  @override
  void dispose() {
    _tapToPayService.removeListener(_onServiceUpdate);
    _nfcPulseController.dispose();
    _particlesController.dispose();
    _tapToPayService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Stack(
          children: [
            // Partículas doradas animadas (fondo) - Cruise brand color
            AnimatedBuilder(
              animation: _particlesController,
              builder: (context, child) {
                return CustomPaint(
                  painter: _ParticlesPainter(
                    progress: _particlesController.value,
                    color: const Color(0xFFE8C547), // Cruise Gold
                  ),
                  size: Size.infinite,
                );
              },
            ),
            
            // Contenido principal
            Column(
              children: [
                const SizedBox(height: 80),
                
                // Icono NFC animado
                AnimatedBuilder(
                  animation: _nfcPulseController,
                  builder: (context, child) {
                    return Opacity(
                      opacity: _nfcOpacityAnimation.value,
                      child: Transform.scale(
                        scale: _nfcScaleAnimation.value,
                        child: Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.3),
                              width: 2,
                            ),
                          ),
                          child: Center(
                            child: Icon(
                              Icons.contactless,
                              size: 60,
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                
                const SizedBox(height: 24),
                
                // Texto "Hold Here to Pay"
                Text(
                  _statusMessage,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                
                const Spacer(),
                
                // Card con información del pago
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _paymentSuccess 
                        ? const Color(0xFF4CAF50).withValues(alpha: 0.5)
                        : Colors.white.withValues(alpha: 0.15),
                      width: _paymentSuccess ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Logo de Cruise
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8C547), // Cruise Gold background
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.asset(
                            'assets/images/cruise_foreground_1024.png',
                            width: 60,
                            height: 60,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      
                      // Texto descriptivo
                      Text(
                        'Pay ${widget.rideDescription}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      
                      // Monto
                      Text(
                        '${_currencySymbol()}${widget.amount.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      
                      // Estado de éxito
                      if (_paymentSuccess) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4CAF50),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle, color: Colors.white, size: 20),
                              SizedBox(width: 8),
                              Text(
                                'Paid',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      
                      // Error
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _errorMessage!,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 14,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _onRetry,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white.withValues(alpha: 0.2),
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Retry'),
                        ),
                      ],
                    ],
                  ),
                ),
                
                const Spacer(),
                
                // Botón X para cancelar
                if (!_paymentSuccess)
                  GestureDetector(
                    onTap: _onCancel,
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.close,
                        color: Colors.white.withValues(alpha: 0.7),
                        size: 28,
                      ),
                    ),
                  ),
                
                const SizedBox(height: 40),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  String _currencySymbol() {
    switch (widget.currency.toUpperCase()) {
      case 'USD':
        return '\$';
      case 'EUR':
        return '€';
      case 'GBP':
        return '£';
      default:
        return '\$';
    }
  }
}

/// Painter personalizado para las partículas azules del fondo
class _ParticlesPainter extends CustomPainter {
  final double progress;
  final Color color;
  
  _ParticlesPainter({required this.progress, required this.color});
  
  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(42); // Seed fijo para consistencia
    final paint = Paint()
      ..color = color.withValues(alpha: 0.3)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    
    // Generar partículas desde arriba
    const particleCount = 60;
    for (int i = 0; i < particleCount; i++) {
      final x = random.nextDouble() * size.width;
      final baseY = random.nextDouble() * size.height * 0.6;
      final speed = 0.5 + random.nextDouble() * 1.5;
      
      // Animar partículas hacia abajo
      final y = (baseY + progress * size.height * speed) % (size.height * 0.5);
      final opacity = 1 - (y / (size.height * 0.5));
      
      if (opacity > 0) {
        final particlePaint = Paint()
          ..color = color.withValues(alpha: opacity * 0.4)
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round;
        
        // Dibujar partícula como punto o línea corta
        canvas.drawCircle(
          Offset(x, y),
          1.5 + random.nextDouble() * 2,
          particlePaint,
        );
      }
    }
  }
  
  @override
  bool shouldRepaint(covariant _ParticlesPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

/// Función helper para navegar a la pantalla de Tap to Pay
Future<bool?> showTapToPayScreen({
  required BuildContext context,
  required double amount,
  String currency = 'USD',
  String rideDescription = 'Cruise Ride',
  VoidCallback? onPaymentSuccess,
  VoidCallback? onPaymentCancelled,
}) {
  return Navigator.of(context).push<bool>(
    PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => TapToPayScreen(
        amount: amount,
        currency: currency,
        rideDescription: rideDescription,
        onPaymentSuccess: onPaymentSuccess,
        onPaymentCancelled: onPaymentCancelled,
      ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        const begin = Offset(0.0, 1.0);
        const end = Offset.zero;
        const curve = Curves.easeInOut;
        
        var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
        var offsetAnimation = animation.drive(tween);
        
        return SlideTransition(
          position: offsetAnimation,
          child: child,
        );
      },
    ),
  );
}
