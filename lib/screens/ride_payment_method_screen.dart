import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/haptic_service.dart';
import '../services/api_service.dart';

import '../l10n/app_localizations.dart';
import 'tap_to_pay_screen.dart';

// ═══════════════════════════════════════════════════════════════════
//  Payment Method — Grid 2×2 de tarjetas cuadradas como en la web de Shopify
//
//  Layout: Cuadrícula 2×2 con:
//    - Apple Pay (fondo negro, icono blanco)
//    - Google Pay (fondo blanco, icono de colores)
//    - Tarjeta Débito/Crédito (fondo gris oscuro, icono blanco)
//    - Tap to Pay (fondo azul oscuro, icono NFC azul)
//    - Bank Account (coming soon)
//    - Modo de Prueba (fondo oscuro dorado, icono dorado)
// ═══════════════════════════════════════════════════════════════════

const _gold = Color(0xFFE8C547);
// Pure black page background to match the web overlay's backdrop-filter
// result (shows through as near-black over the dark map).
const _bg = Color(0xFF000000);

class PaymentMethodId {
  static const apple = 'apple_pay';
  static const google = 'google_pay';
  static const card = 'card';
  static const bank = 'bank_account';
  static const tapToPay = 'tap_to_pay';
  static const test = 'test_mode';
}

/// Opens the payment method picker and returns the selected method id.
Future<String?> showRidePaymentMethodPicker(
  BuildContext context, {
  required String currentMethod,
  bool showTestMode = false,
}) {
  return Navigator.of(context).push<String>(
    PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      transitionDuration: const Duration(milliseconds: 380),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, anim, __) => RidePaymentMethodScreen(
        currentMethod: currentMethod,
        showTestMode: showTestMode,
      ),
      transitionsBuilder: (_, anim, __, child) {
        // Web: cubic-bezier(.33,1,.68,1), 380ms, translateY(14→0) + scale(.985→1).
        final curved = CurvedAnimation(
          parent: anim,
          curve: const Cubic(0.33, 1, 0.68, 1),
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.04),
              end: Offset.zero,
            ).animate(curved),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.985, end: 1.0).animate(curved),
              child: child,
            ),
          ),
        );
      },
    ),
  );
}

class RidePaymentMethodScreen extends StatefulWidget {
  final String currentMethod;
  final bool showTestMode;

  const RidePaymentMethodScreen({
    super.key,
    required this.currentMethod,
    this.showTestMode = false,
  });

  @override
  State<RidePaymentMethodScreen> createState() =>
      _RidePaymentMethodScreenState();
}

class _RidePaymentMethodScreenState extends State<RidePaymentMethodScreen>
    with TickerProviderStateMixin {
  late String _selected;
  late final AnimationController _entryCtl;

  @override
  void initState() {
    super.initState();
    _selected = widget.currentMethod;
    _entryCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();
  }

  @override
  void dispose() {
    _entryCtl.dispose();
    super.dispose();
  }

  void _pick(String id) {
    HapticService.selectionClick();
    setState(() => _selected = id);
    // Small delay so the user sees the gold check animate, then close.
    Future.delayed(const Duration(milliseconds: 260), () {
      if (mounted) Navigator.of(context).pop(id);
    });
  }

  /// Open Stripe Financial Connections to link a bank account.
  Future<void> _openBankConnection(BuildContext ctx) async {
    HapticService.selectionClick();
    final s = S.of(ctx);
    
    // Show loading indicator
    if (!mounted) return;
    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: _gold),
      ),
    );

    try {
      final result = await ApiService.createFinancialConnectionsSession();
      if (!mounted) {
        Navigator.of(ctx, rootNavigator: true).pop();
        return;
      }
      Navigator.of(ctx, rootNavigator: true).pop(); // dismiss loading

      if (result != null && result['url'] != null) {
        final url = Uri.parse(result['url'] as String);
        if (await canLaunchUrl(url)) {
          await launchUrl(url, mode: LaunchMode.externalApplication);
        } else {
          if (!mounted) return;
          _showBankError(ctx, s.genericPaymentError);
        }
      } else {
        if (!mounted) return;
        _showBankError(ctx, s.genericPaymentError);
      }
    } catch (e) {
      if (!mounted) {
        Navigator.of(ctx, rootNavigator: true).pop();
        return;
      }
      Navigator.of(ctx, rootNavigator: true).pop(); // dismiss loading
      _showBankError(ctx, '${s.genericPaymentError} (${e.toString()})');
    }
  }

  void _showBankError(BuildContext ctx, String msg) {
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.red.shade800,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    final s = S.of(context);

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              title: s.paymentMethodTitle,
              onBack: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.0,
                  physics: const BouncingScrollPhysics(),
                  // iOS shows Apple Pay; Android shows Google Pay. Both
                  // platforms also see Card + Bank Account (coming soon)
                  // and — when enabled — the Test Mode tile for QA.
                  children: [
                    if (Platform.isIOS)
                      _PayCard(
                        entryCtl: _entryCtl,
                        staggerDelay: 0.00,
                        id: PaymentMethodId.apple,
                        selected: _selected == PaymentMethodId.apple,
                        iconBg: Colors.black,
                        label: 'Apple Pay',
                        icon: const Icon(Icons.apple,
                            color: Colors.white, size: 32),
                        onTap: () => _pick(PaymentMethodId.apple),
                      ),
                    if (Platform.isAndroid)
                      _PayCard(
                        entryCtl: _entryCtl,
                        staggerDelay: 0.00,
                        id: PaymentMethodId.google,
                        selected: _selected == PaymentMethodId.google,
                        iconBg: Colors.white,
                        label: 'Google Pay',
                        icon: _GoogleGLogo(size: 32),
                        onTap: () => _pick(PaymentMethodId.google),
                      ),
                    _PayCard(
                      entryCtl: _entryCtl,
                      staggerDelay: 0.08,
                      id: PaymentMethodId.card,
                      selected: _selected == PaymentMethodId.card,
                      iconBg: const Color(0xFF2A2A2A),
                      label: s.cardPaymentLabel,
                      icon: const Icon(
                        Icons.credit_card_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                      onTap: () => _pick(PaymentMethodId.card),
                    ),
                    // Tap to Pay - NFC Contactless Payment
                    // Only visible on Android. iOS requires Apple's
                    // proximity-reader entitlement which is per-app and
                    // pending approval — the SDK throws at runtime
                    // without it, so we hide the option entirely.
                    if (Platform.isAndroid)
                      _PayCard(
                        entryCtl: _entryCtl,
                        staggerDelay: 0.12,
                        id: PaymentMethodId.tapToPay,
                        selected: _selected == PaymentMethodId.tapToPay,
                        iconBg: const Color(0xFF1A237E), // Deep blue
                        iconBorder:
                            const Color(0xFF4A90D9).withValues(alpha: 0.5),
                        label: 'Tap to Pay',
                        secondary: 'Hold card to phone',
                        icon: const Icon(
                          Icons.contactless,
                          color: Color(0xFF4A90D9),
                          size: 32,
                        ),
                        onTap: () => _pick(PaymentMethodId.tapToPay),
                      ),
                    _PayCard(
                      entryCtl: _entryCtl,
                      staggerDelay: 0.16,
                      id: PaymentMethodId.bank,
                      selected: _selected == PaymentMethodId.bank,
                      iconBg: const Color(0xFF0F1A12),
                      iconBorder:
                          const Color(0xFF22C55E).withValues(alpha: 0.45),
                      label: 'Bank Account',
                      icon: const Icon(Icons.account_balance_rounded,
                          color: Color(0xFF22C55E), size: 28),
                      onTap: () => _openBankConnection(context),
                    ),
                    if (widget.showTestMode)
                      _PayCard(
                        entryCtl: _entryCtl,
                        staggerDelay: 0.24,
                        id: PaymentMethodId.test,
                        selected: _selected == PaymentMethodId.test,
                        iconBg: const Color(0xFF1A1A1A),
                        iconBorder: _gold.withValues(alpha: 0.50),
                        label: s.testModeLabel,
                        secondary: s.simulatePayment,
                        icon: const Icon(Icons.tune_rounded,
                            color: _gold, size: 28),
                        onTap: () => _pick(PaymentMethodId.test),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Header — .vipRide__payOverlay__header:
//    display:flex; align-items:center; gap:14px; padding:16px 16px 12px.
//  Back button: 38×38 circle, bg rgba(255,255,255,.07), border .10.
//  Title: 18px w700 #fff.
// ═══════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  const _Header({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onBack,
              customBorder: const CircleBorder(),
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.arrow_back_rounded,
                    color: Colors.white, size: 18),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Card — Tarjeta cuadrada para método de pago (Grid 2×2)
//  Layout: Icono grande arriba, label abajo, check esquina superior derecha
// ═══════════════════════════════════════════════════════════════════

class _PayCard extends StatefulWidget {
  final AnimationController entryCtl;
  final double staggerDelay;
  final String id;
  final bool selected;
  final Color iconBg;
  final Color? iconBorder;
  final String label;
  final String? secondary;
  final Widget icon;
  final VoidCallback onTap;
  /// When true the card is dimmed (45% opacity) and a gold "Coming Soon"
  /// diagonal ribbon is overlaid in the upper-right corner. Tap is
  /// effectively swallowed.
  final bool comingSoon;

  const _PayCard({
    required this.entryCtl,
    required this.staggerDelay,
    required this.id,
    required this.selected,
    required this.iconBg,
    this.iconBorder,
    required this.label,
    this.secondary,
    required this.icon,
    required this.onTap,
    // ignore: unused_element_parameter
    this.comingSoon = false,
  });

  @override
  State<_PayCard> createState() => _PayCardState();
}

class _PayCardState extends State<_PayCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final anim = CurvedAnimation(
      parent: widget.entryCtl,
      curve: Interval(
        widget.staggerDelay,
        (widget.staggerDelay + 0.55).clamp(0.0, 1.0),
        curve: Curves.easeOutCubic,
      ),
    );

    return AnimatedBuilder(
      animation: anim,
      builder: (_, child) {
        final t = anim.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - t)),
            child: child,
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Opacity(
              opacity: widget.comingSoon ? 0.55 : 1.0,
              child: _buildCardBody(),
            ),
            if (widget.comingSoon)
              Positioned(
                top: 14,
                right: -28,
                child: Transform.rotate(
                  angle: 0.45,
                  child: Container(
                    width: 110,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    color: const Color(0xFFE8C547),
                    child: const Text(
                      'COMING SOON',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.black,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCardBody() {
    return GestureDetector(
        onTap: widget.comingSoon ? null : widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: widget.selected
                ? const Color(0x14E8C547) // dorado muy suave
                : _pressed
                    ? Colors.white.withValues(alpha: 0.08)
                    : const Color(0xFF1A1A1F), // gris oscuro
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: widget.selected
                  ? _gold.withValues(alpha: 0.6)
                  : Colors.white.withValues(alpha: 0.10),
              width: widget.selected ? 2 : 1,
            ),
          ),
          child: Stack(
            children: [
              // Check en esquina superior derecha
              Positioned(
                top: 12,
                right: 12,
                child: _Check(selected: widget.selected),
              ),
              // Contenido centrado
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Icono grande
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: widget.iconBg,
                        borderRadius: BorderRadius.circular(14),
                        border: widget.iconBorder != null
                            ? Border.all(color: widget.iconBorder!, width: 1.5)
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: widget.icon,
                    ),
                    const SizedBox(height: 16),
                    // Label
                    Text(
                      widget.label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    // Sub-label (opcional)
                    if (widget.secondary != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.secondary!,
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          color: _gold.withValues(alpha: 0.70),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _Check extends StatelessWidget {
  final bool selected;
  const _Check({required this.selected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? _gold : Colors.transparent,
        border: Border.all(
          color: selected
              ? _gold
              // rgba(255,255,255,.15)
              : Colors.white.withValues(alpha: 0.15),
          width: 1.5,
        ),
      ),
      alignment: Alignment.center,
      child: selected
          ? const Icon(Icons.check_rounded, color: Colors.black, size: 14)
          : const SizedBox.shrink(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Google "G" — 4-color SVG logo, 1:1 with web (ride-request.liquid:201).
//  Uses a CustomPainter with the four official Google brand color paths
//  so the logo renders identically to the marketing asset.
// ═══════════════════════════════════════════════════════════════════

class _GoogleGLogo extends StatelessWidget {
  final double size;

  const _GoogleGLogo({this.size = 20});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleGPainter()),
    );
  }
}

// SVG source (web): viewBox 0 0 24 24 — 4 brand-color paths.
class _GoogleGPainter extends CustomPainter {
  static final _blue   = Paint()..color = const Color(0xFF4285F4)..style = PaintingStyle.fill;
  static final _green  = Paint()..color = const Color(0xFF34A853)..style = PaintingStyle.fill;
  static final _yellow = Paint()..color = const Color(0xFFFBBC05)..style = PaintingStyle.fill;
  static final _red    = Paint()..color = const Color(0xFFEA4335)..style = PaintingStyle.fill;

  @override
  void paint(Canvas canvas, Size size) {
    // Scale 24-unit viewBox to the actual size.
    final s = size.width / 24.0;
    canvas.scale(s, s);

    // Blue arc (top-right)
    final blue = Path()
      ..moveTo(22.56, 12.25)
      ..cubicTo(22.56, 11.47, 22.49, 10.72, 22.36, 10.0)
      ..lineTo(12, 10.0)
      ..lineTo(12, 14.26)
      ..lineTo(17.92, 14.26)
      ..cubicTo(17.66, 15.63, 16.88, 16.79, 15.72, 17.58)
      ..lineTo(15.72, 20.35)
      ..lineTo(19.29, 20.35)
      ..cubicTo(21.37, 18.43, 22.56, 15.61, 22.56, 12.25)
      ..close();
    canvas.drawPath(blue, _blue);

    // Green arc (bottom-right)
    final green = Path()
      ..moveTo(12, 23)
      ..cubicTo(14.97, 23, 17.46, 22.02, 19.28, 20.34)
      ..lineTo(15.71, 17.57)
      ..cubicTo(14.73, 18.23, 13.48, 18.63, 12, 18.63)
      ..cubicTo(9.14, 18.63, 6.71, 16.70, 5.84, 14.10)
      ..lineTo(2.18, 14.10)
      ..lineTo(2.18, 16.94)
      ..cubicTo(3.99, 20.53, 7.70, 23, 12, 23)
      ..close();
    canvas.drawPath(green, _green);

    // Yellow arc (left)
    final yellow = Path()
      ..moveTo(5.84, 14.09)
      ..cubicTo(5.62, 13.43, 5.50, 12.73, 5.50, 12.0)
      ..cubicTo(5.50, 11.28, 5.62, 10.58, 5.84, 9.91)
      ..lineTo(5.84, 7.07)
      ..lineTo(2.18, 7.07)
      ..cubicTo(1.43, 8.55, 1.0, 10.22, 1.0, 12.0)
      ..cubicTo(1.0, 13.94, 1.46, 15.77, 2.18, 17.42)
      ..lineTo(5.84, 14.58)
      ..lineTo(5.84, 14.09)
      ..close();
    canvas.drawPath(yellow, _yellow);

    // Red arc (top-left)
    final red = Path()
      ..moveTo(12, 5.38)
      ..cubicTo(13.62, 5.38, 15.06, 5.94, 16.21, 7.02)
      ..lineTo(19.36, 3.87)
      ..cubicTo(17.45, 2.09, 14.97, 1.0, 12, 1.0)
      ..cubicTo(7.70, 1.0, 3.99, 3.47, 2.18, 7.07)
      ..lineTo(5.84, 9.91)
      ..cubicTo(6.71, 7.31, 9.14, 5.38, 12, 5.38)
      ..close();
    canvas.drawPath(red, _red);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
