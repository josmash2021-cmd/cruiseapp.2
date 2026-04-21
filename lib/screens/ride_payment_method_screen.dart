import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';

// ═══════════════════════════════════════════════════════════════════
//  Payment method selection — matches the Shopify widget's pay overlay
//  (2×2 grid of Apple Pay / Google Pay / Card / Test Mode).
// ═══════════════════════════════════════════════════════════════════

const _gold = Color(0xFFE8C547);
const _bg = Color(0xFF0A0E1A);

/// Identifiers used across the app for the selected payment method.
class PaymentMethodId {
  static const apple = 'apple_pay';
  static const google = 'google_pay';
  static const card = 'card';
  static const test = 'test_mode';
}

/// Opens the payment method picker and returns the selected method id
/// (`apple_pay` | `google_pay` | `card` | `test_mode`) or `null` if the
/// user backed out.
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
    HapticFeedback.selectionClick();
    setState(() => _selected = id);
    // Small delay so the user sees the radio fill animate, then close.
    Future.delayed(const Duration(milliseconds: 260), () {
      if (mounted) Navigator.of(context).pop(id);
    });
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
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                child: GridView.count(
                  crossAxisCount: 2,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 14,
                  childAspectRatio: 0.95,
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _PaymentTile(
                      entryCtl: _entryCtl,
                      staggerDelay: 0.00,
                      id: PaymentMethodId.apple,
                      selected: _selected == PaymentMethodId.apple,
                      iconBg: Colors.black,
                      label: 'Apple Pay',
                      icon: _AppleLogo(),
                      onTap: () => _pick(PaymentMethodId.apple),
                    ),
                    _PaymentTile(
                      entryCtl: _entryCtl,
                      staggerDelay: 0.10,
                      id: PaymentMethodId.google,
                      selected: _selected == PaymentMethodId.google,
                      iconBg: Colors.white,
                      label: 'Google Pay',
                      icon: _GoogleGLogo(),
                      onTap: () => _pick(PaymentMethodId.google),
                    ),
                    _PaymentTile(
                      entryCtl: _entryCtl,
                      staggerDelay: 0.20,
                      id: PaymentMethodId.card,
                      selected: _selected == PaymentMethodId.card,
                      iconBg: const Color(0x1AFFFFFF),
                      label: 'Debit/Credit Card',
                      icon: const Icon(Icons.credit_card_rounded,
                          color: Colors.white, size: 32),
                      onTap: () => _pick(PaymentMethodId.card),
                    ),
                    if (widget.showTestMode)
                      _PaymentTile(
                        entryCtl: _entryCtl,
                        staggerDelay: 0.30,
                        id: PaymentMethodId.test,
                        selected: _selected == PaymentMethodId.test,
                        iconBg: const Color(0x1AE8C547),
                        iconBorder: const Color(0x4DE8C547),
                        label: 'Test Mode',
                        secondary: 'Simulate payment',
                        icon: const Icon(Icons.tune_rounded,
                            color: _gold, size: 30),
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
//  Header with back button + title
// ═══════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  const _Header({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Row(
        children: [
          Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onBack,
              customBorder: const CircleBorder(),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.arrow_back_rounded,
                    color: Colors.white, size: 20),
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
//  Tile — card with icon, label, radio dot
// ═══════════════════════════════════════════════════════════════════

class _PaymentTile extends StatefulWidget {
  final AnimationController entryCtl;
  final double staggerDelay; // 0..1 fraction of entry
  final String id;
  final bool selected;
  final Color iconBg;
  final Color? iconBorder;
  final String label;
  final String? secondary;
  final Widget icon;
  final VoidCallback onTap;

  const _PaymentTile({
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
  });

  @override
  State<_PaymentTile> createState() => _PaymentTileState();
}

class _PaymentTileState extends State<_PaymentTile> {
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
            offset: Offset(0, 20 * (1 - t)),
            child: child,
          ),
        );
      },
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 140),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: widget.selected
                  ? const Color(0x14E8C547)
                  : Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: widget.selected
                    ? _gold.withValues(alpha: 0.55)
                    : Colors.white.withValues(alpha: 0.08),
                width: widget.selected ? 1.4 : 1,
              ),
              boxShadow: widget.selected
                  ? [
                      BoxShadow(
                        color: _gold.withValues(alpha: 0.22),
                        blurRadius: 18,
                        spreadRadius: -2,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              children: [
                // Radio top-right
                Positioned(
                  top: 0,
                  right: 0,
                  child: _Radio(selected: widget.selected),
                ),

                // Icon + label centered
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Icon chip
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: widget.iconBg,
                          borderRadius: BorderRadius.circular(16),
                          border: widget.iconBorder != null
                              ? Border.all(color: widget.iconBorder!)
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: widget.icon,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        widget.label,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Poppins',
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.1,
                        ),
                      ),
                      if (widget.secondary != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          widget.secondary!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'Poppins',
                            color: _gold.withValues(alpha: 0.75),
                            fontSize: 10,
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
        ),
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  final bool selected;
  const _Radio({required this.selected});

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
          color: selected ? _gold : Colors.white.withValues(alpha: 0.25),
          width: 1.5,
        ),
      ),
      alignment: Alignment.center,
      child: selected
          ? const Icon(Icons.check_rounded,
              color: Color(0xFF0A0E1A), size: 14)
          : const SizedBox.shrink(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Brand logos
// ═══════════════════════════════════════════════════════════════════

class _AppleLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.apple, color: Colors.white, size: 34);
  }
}

class _GoogleGLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      child: ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF4285F4),
            Color(0xFF34A853),
            Color(0xFFFBBC05),
            Color(0xFFEA4335),
          ],
          stops: [0.0, 0.33, 0.66, 1.0],
        ).createShader(rect),
        child: const Text(
          'G',
          style: TextStyle(
            fontFamily: 'Poppins',
            fontSize: 34,
            fontWeight: FontWeight.w800,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}
