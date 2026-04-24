import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';

// ═══════════════════════════════════════════════════════════════════
//  Payment Method — ported 1:1 from the Shopify widget's
//  .vipRide__payOverlay (vertical list of 4 rows, NOT a 2×2 grid).
//
//  Web CSS reference:
//    .vipRide__payOverlay__list { display:flex; flex-direction:column;
//                                 gap:6px; padding:0 16px; }
//    .vipRide__payOption { width:100%; display:flex; align-items:center;
//                          gap:14px; padding:16px; background:rgba(255,
//                          255,255,.05); border:1px solid rgba(255,255,
//                          255,.08); border-radius:14px; }
//    .vipRide__payOption.is-selected {
//      border-color: rgba(232,197,71,.5);
//      background:   rgba(232,197,71,.08);
//    }
//    .vipRide__payIcon  { width:36px; height:36px; border-radius:10px; }
//    .vipRide__payCheck { width:22px; height:22px; border-radius:50%; }
// ═══════════════════════════════════════════════════════════════════

const _gold = Color(0xFFE8C547);
// Pure black page background to match the web overlay's backdrop-filter
// result (shows through as near-black over the dark map).
const _bg = Color(0xFF000000);

class PaymentMethodId {
  static const apple = 'apple_pay';
  static const google = 'google_pay';
  static const card = 'card';
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
    HapticFeedback.selectionClick();
    setState(() => _selected = id);
    // Small delay so the user sees the gold check animate, then close.
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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                physics: const BouncingScrollPhysics(),
                children: [
                  _PayRow(
                    entryCtl: _entryCtl,
                    staggerDelay: 0.00,
                    id: PaymentMethodId.apple,
                    selected: _selected == PaymentMethodId.apple,
                    iconBg: Colors.black,
                    label: 'Apple Pay',
                    icon: const Icon(Icons.apple, color: Colors.white, size: 20),
                    onTap: () => _pick(PaymentMethodId.apple),
                  ),
                  const SizedBox(height: 6),
                  _PayRow(
                    entryCtl: _entryCtl,
                    staggerDelay: 0.08,
                    id: PaymentMethodId.google,
                    selected: _selected == PaymentMethodId.google,
                    iconBg: Colors.white,
                    label: 'Google Pay',
                    icon: _GoogleGLogo(),
                    onTap: () => _pick(PaymentMethodId.google),
                  ),
                  const SizedBox(height: 6),
                  _PayRow(
                    entryCtl: _entryCtl,
                    staggerDelay: 0.16,
                    id: PaymentMethodId.card,
                    selected: _selected == PaymentMethodId.card,
                    iconBg: Colors.white.withValues(alpha: 0.10),
                    label: s.cardPaymentLabel,
                    icon: const Icon(
                      Icons.credit_card_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    onTap: () => _pick(PaymentMethodId.card),
                  ),
                  if (widget.showTestMode) ...[
                    // Web: .vipRide__payOption--test has a gold hairline on top
                    // (border-top: 1px solid rgba(232,197,71,.12); margin-top:4px).
                    const SizedBox(height: 10),
                    _PayRow(
                      entryCtl: _entryCtl,
                      staggerDelay: 0.24,
                      id: PaymentMethodId.test,
                      selected: _selected == PaymentMethodId.test,
                      iconBg: _gold.withValues(alpha: 0.10),
                      iconBorder: _gold.withValues(alpha: 0.30),
                      label: s.testModeLabel,
                      secondary: s.simulatePayment,
                      icon: const Icon(Icons.tune_rounded, color: _gold, size: 18),
                      onTap: () => _pick(PaymentMethodId.test),
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
//  Row — .vipRide__payOption (ONE horizontal row per method).
//  Layout: [icon 36] gap 14 [label flex] [check 22]
// ═══════════════════════════════════════════════════════════════════

class _PayRow extends StatefulWidget {
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

  const _PayRow({
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
  State<_PayRow> createState() => _PayRowState();
}

class _PayRowState extends State<_PayRow> {
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
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: widget.selected
                // rgba(232,197,71,.08)
                ? const Color(0x14E8C547)
                : _pressed
                    // :active → rgba(255,255,255,.10)
                    ? Colors.white.withValues(alpha: 0.10)
                    // default → rgba(255,255,255,.05)
                    : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: widget.selected
                  // rgba(232,197,71,.5)
                  ? _gold.withValues(alpha: 0.5)
                  // rgba(255,255,255,.08)
                  : Colors.white.withValues(alpha: 0.08),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              // .vipRide__payIcon — 36×36, radius 10px
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: widget.iconBg,
                  borderRadius: BorderRadius.circular(10),
                  border: widget.iconBorder != null
                      ? Border.all(color: widget.iconBorder!)
                      : null,
                ),
                alignment: Alignment.center,
                child: widget.icon,
              ),
              const SizedBox(width: 14),
              // .vipRide__payLabel — flex:1
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (widget.secondary != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        widget.secondary!,
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          color: _gold.withValues(alpha: 0.60),
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 14),
              // .vipRide__payCheck — 22×22 circle; selected: gold fill + ✓
              _Check(selected: widget.selected),
            ],
          ),
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
//  Google "G" — 4-color gradient letter to match the web SVG.
// ═══════════════════════════════════════════════════════════════════

class _GoogleGLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ShaderMask(
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
          fontSize: 20,
          fontWeight: FontWeight.w800,
          height: 1.0,
        ),
      ),
    );
  }
}
