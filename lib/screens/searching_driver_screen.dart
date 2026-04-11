import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Spectacular "Confirming your ride." screen with radar pulse rings,
/// orbiting dots, floating particles, shimmer text, and a gleaming
/// progress bar.  Stays open until a driver is found or user cancels.
class SearchingDriverScreen extends StatefulWidget {
  const SearchingDriverScreen({
    super.key,
    this.onCancel,
    this.paymentCallback,
    this.onPaymentDeclined,
    this.initiallyDeclined = false,
    this.driverFound,
  });

  /// Called when the rider confirms they want to cancel the ride.
  final VoidCallback? onCancel;

  /// If provided, called ~800 ms into the animation to authorize payment.
  /// Return true = approved, false = user cancelled, throws = bank declined.
  final Future<bool> Function()? paymentCallback;

  /// Called just before popping when payment was declined by the bank.
  final VoidCallback? onPaymentDeclined;

  /// Start immediately in the payment-declined state (used when native pay
  /// sheet was shown before this screen and the bank rejected the charge).
  final bool initiallyDeclined;

  /// When this notifier becomes true, pop immediately (driver was matched).
  final ValueNotifier<bool>? driverFound;

  @override
  State<SearchingDriverScreen> createState() => _SearchingDriverScreenState();
}

class _SearchingDriverScreenState extends State<SearchingDriverScreen>
    with TickerProviderStateMixin {
  // ── constants ──
  static const _bg   = Color(0xFF0A0D14);
  static const _gold = Color(0xFFE8C547);
  static const _goldEnd = Color(0xFFF5D990);

  // ── controllers ──
  late final AnimationController _radarCtrl;    // 2400 ms – radar pulse rings
  late final AnimationController _glowCtrl;     // 1200 ms – car glow + scale
  late final AnimationController _particleCtrl; // 4000 ms – floating particles
  late final AnimationController _progressCtrl; // 4000 ms – progress bar (repeating)
  late final AnimationController _shimmerCtrl;  // 2000 ms – text shimmer
  late final AnimationController _barGleamCtrl; // 1200 ms – progress bar gleam

  // ── derived animations for 4 radar rings ──
  late final Animation<double> _ring1, _ring2, _ring3, _ring4;

  // ── declined state ──
  bool _paymentDeclined = false;
  Timer? _paymentStartTimer;
  Timer? _declinedPopTimer;

  // ── status text cycling ──
  // 0 = "Confirming your ride…" (briefly)
  // 1 = "Looking for your driver…"
  // 2 = "Connecting to nearby drivers…"
  int _textPhase = 0;
  Timer? _textPhaseTimer;

  // ── driver-found early-pop ──
  VoidCallback? _driverFoundCb;

  // ── particles (20 total) ──
  late final List<_Particle> _particles;
  late final List<AnimationController> _twinkleControllers;

  @override
  void initState() {
    super.initState();

    // ── 1. Radar pulse rings ──
    _radarCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _ring1 = CurvedAnimation(parent: _radarCtrl, curve: const Interval(0.0,  1.0,  curve: Curves.easeOut));
    _ring2 = CurvedAnimation(parent: _radarCtrl, curve: const Interval(0.25, 1.0,  curve: Curves.easeOut));
    _ring3 = CurvedAnimation(parent: _radarCtrl, curve: const Interval(0.5,  1.0,  curve: Curves.easeOut));
    _ring4 = CurvedAnimation(parent: _radarCtrl, curve: const Interval(0.75, 1.0,  curve: Curves.easeOut));

    // ── 2. Car glow pulse ──
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    // ── 3. Particle drift ──
    _particleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat();

    final rng = Random(7);
    _particles = List.generate(20, (_) => _Particle(
      x: rng.nextDouble(),
      y: rng.nextDouble(),
      size: 2.0 + rng.nextDouble() * 2.0,
      driftSpeed: 0.02 + rng.nextDouble() * 0.04,
      phase: rng.nextDouble(),
    ));

    // 4 shared twinkle controllers — each serves 5 particles (visually indistinguishable
    // from 20 individual controllers, but 5× fewer animation tickers)
    _twinkleControllers = List.generate(4, (i) {
      final ms = 800 + (i * 300); // staggered: 800, 1100, 1400, 1700
      return AnimationController(
        vsync: this,
        duration: Duration(milliseconds: ms),
      )..repeat(reverse: true);
    });

    // ── 5. Progress bar (repeating — loops while searching) ──
    _progressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat();

    // ── 6. Text shimmer ──
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    // ── 7. Progress bar gleam sweep ──
    _barGleamCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    // Policy 2026-04-11: this screen is ONLY for the payment-authorization
    // phase. It shows a single "Confirming your ride..." label while the
    // Stripe paymentCallback runs, then pops on success so the
    // RideRequestScreen can enter its waiting-for-driver map mode. We no
    // longer cycle through "Looking for driver" / "Connecting" strings or
    // listen on a driverFound notifier — driver matching happens on the
    // next screen.
    _textPhase = 0; // always "Confirming your ride…"

    // Legacy: a driverFound notifier may still be passed by old callers
    // during the refactor. Retain the listener so the screen pops if the
    // driver matches while it's still showing (edge case on slow payments).
    if (widget.driverFound != null) {
      _driverFoundCb = () {
        if (widget.driverFound!.value && mounted) {
          Navigator.of(context).pop();
        }
      };
      widget.driverFound!.addListener(_driverFoundCb!);
      if (widget.driverFound!.value && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
      }
    }

    // ── Payment handling ──────────────────────────────────────────────
    // On success we pop the screen so the caller (RideRequestScreen) can
    // transition to its waiting-for-driver map state. On user-cancel we
    // pop with `true` so the caller knows to roll back. On bank decline
    // we flash the declined state and then pop with `false`.
    if (widget.initiallyDeclined) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _handleDeclined());
    } else if (widget.paymentCallback != null) {
      _paymentStartTimer = Timer(const Duration(milliseconds: 800), () async {
        if (!mounted) return;
        try {
          final ok = await widget.paymentCallback!();
          if (!mounted) return;
          if (!ok) {
            // User explicitly cancelled from payment sheet.
            widget.onCancel?.call();
            Navigator.of(context).pop(true);
          } else {
            // Payment succeeded — caller picks up and transitions the
            // parent screen into waiting-for-driver mode.
            Navigator.of(context).pop(false);
          }
        } catch (_) {
          if (mounted) _handleDeclined();
        }
      });
    }
  }

  @override
  void dispose() {
    _textPhaseTimer?.cancel();
    if (_driverFoundCb != null) widget.driverFound?.removeListener(_driverFoundCb!);
    _paymentStartTimer?.cancel();
    _declinedPopTimer?.cancel();
    _radarCtrl.dispose();
    _glowCtrl.dispose();
    _particleCtrl.dispose();
    _progressCtrl.dispose();
    _shimmerCtrl.dispose();
    _barGleamCtrl.dispose();
    for (final c in _twinkleControllers) {
      c.dispose();
    }
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════════════
  void _handleDeclined() {
    if (!mounted || _paymentDeclined) return;
    setState(() => _paymentDeclined = true);
    _progressCtrl.stop();
    _radarCtrl.stop();
    _glowCtrl.stop();
    _declinedPopTimer?.cancel();
    _declinedPopTimer = Timer(const Duration(milliseconds: 2000), () {
      if (!mounted) return;
      widget.onPaymentDeclined?.call();
      Navigator.of(context).pop();
    });
  }

  void _showCancelDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a2e),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFc8a951), width: 1),
        ),
        title: Text(
          S.of(context).cancelRideQuestion,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
          textAlign: TextAlign.center,
        ),
        content: Text(
          S.of(context).cancelRideMsg,
          style: const TextStyle(color: Colors.grey, fontSize: 14),
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              S.of(context).keepWaiting,
              style: const TextStyle(color: Color(0xFFc8a951)),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFc8a951),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () {
              Navigator.pop(ctx);            // close dialog
              widget.onCancel?.call();      // run cancel logic in controller
              Navigator.of(context).pop(true); // pop this screen with cancelled=true
            },
            child: Text(
              S.of(context).yesCancelBtn,
              style: const TextStyle(color: Colors.black),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          // Background
          Container(color: _bg),

          // Floating particles layer
          Positioned.fill(
            child: AnimatedBuilder(
              animation: Listenable.merge([_particleCtrl, ..._twinkleControllers]),
              builder: (_, __) => CustomPaint(
                painter: _ParticlePainter(
                  particles: _particles,
                  drift: _particleCtrl.value,
                  twinkleValues: List.generate(20, (i) => _twinkleControllers[i % 4].value),
                  color: _gold,
                ),
              ),
            ),
          ),

          // Center content
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Radar rings + orbit dots + car icon
                SizedBox(
                  width: 220,
                  height: 220,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Radar pulse rings
                      AnimatedBuilder(
                        animation: _radarCtrl,
                        builder: (_, __) => CustomPaint(
                          size: const Size(220, 220),
                          painter: _RadarRingsPainter(
                            rings: [_ring1.value, _ring2.value, _ring3.value, _ring4.value],
                            color: _gold,
                          ),
                        ),
                      ),
                      // Car icon with glow
                      _buildCarIcon(),
                    ],
                  ),
                ),

                const SizedBox(height: 48),

                // Shimmer text
                _buildShimmerText(),

                const SizedBox(height: 24),

                // Progress bar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: _buildProgressBar(),
                ),
              ],
            ),
          ),

          // Cancel button + step indicator at bottom
          Positioned(
            bottom: 32,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: _showCancelDialog,
                  child: Text(
                    S.of(context).cancel,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 14,
                    ),
                  ),
                ),

              ],
            ),
          ),
        ],
      ),
    ));
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  CAR ICON WITH GLOW PULSE
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildCarIcon() {
    return AnimatedBuilder(
      animation: _glowCtrl,
      builder: (_, __) {
        final g = _glowCtrl.value; // 0→1→0
        final scale = 0.95 + g * 0.1;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF0F1220),
              border: Border.all(color: _gold.withValues(alpha: 0.5), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.3 + g * 0.5),
                  blurRadius: 18 + g * 14,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(
              Icons.directions_car,
              color: _gold,
              size: 32,
              shadows: [
                Shadow(color: _gold.withValues(alpha: 0.8), blurRadius: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  SHIMMER TEXT
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildShimmerText() {
    if (_paymentDeclined) {
      return Text(
        S.of(context).paymentDeclined,
        style: const TextStyle(
          color: Color(0xFFFF4444),
          fontSize: 22,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
        ),
      );
    }
    return AnimatedBuilder(
      animation: _shimmerCtrl,
      builder: (_, __) {
        final v = _shimmerCtrl.value;
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              colors: const [
                Colors.white70,
                Colors.white,
                Color(0xFFF5C518),
                Colors.white,
                Colors.white70,
              ],
              stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
              begin: Alignment(v * 3 - 1.5, 0),
              end: Alignment(v * 3 - 0.5, 0),
            ).createShader(bounds);
          },
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: Text(
            key: ValueKey(_textPhase),
            _textPhase == 0
                ? S.of(context).searchStatusMsg4   // "Confirming your ride…"
                : _textPhase == 1
                    ? S.of(context).searchStatusMsg1 // "Looking for your driver…"
                    : S.of(context).searchStatusMsg2, // "Connecting to nearby drivers…"
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w300,
              letterSpacing: 0.5,
            ),
          ),
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  PROGRESS BAR WITH GLEAM
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildProgressBar() {
    if (_paymentDeclined) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: const SizedBox(
          width: double.infinity,
          height: 3,
          child: ColoredBox(color: Color(0xFFFF4444)),
        ),
      );
    }
    return AnimatedBuilder(
      animation: Listenable.merge([_progressCtrl, _barGleamCtrl]),
      builder: (_, __) {
        final fill = _progressCtrl.value;
        final gleam = _barGleamCtrl.value;
        return ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            width: double.infinity,
            height: 3,
            child: CustomPaint(
              painter: _ProgressBarPainter(
                fill: fill,
                gleam: gleam,
                goldStart: _gold,
                goldEnd: _goldEnd,
              ),
            ),
          ),
        );
      },
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════
//  ROUTE BUILDER
// ═════════════════════════════════════════════════════════════════════════

Route<bool> searchingDriverRoute({
  VoidCallback? onCancel,
  Future<bool> Function()? paymentCallback,
  VoidCallback? onPaymentDeclined,
  bool initiallyDeclined = false,
  ValueNotifier<bool>? driverFound,
}) {
  return PageRouteBuilder<bool>(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, __, ___) => SearchingDriverScreen(
      onCancel: onCancel,
      paymentCallback: paymentCallback,
      onPaymentDeclined: onPaymentDeclined,
      initiallyDeclined: initiallyDeclined,
      driverFound: driverFound,
    ),
    transitionsBuilder: (_, anim, __, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
        child: child,
      );
    },
  );
}

// ═════════════════════════════════════════════════════════════════════════
//  RADAR PULSE RINGS PAINTER
// ═════════════════════════════════════════════════════════════════════════

class _RadarRingsPainter extends CustomPainter {
  final List<double> rings; // 4 progress values 0→1
  final Color color;
  _RadarRingsPainter({required this.rings, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;
    for (final v in rings) {
      if (v <= 0) continue;
      final radius = 30 + v * (maxRadius - 30);
      final opacity = (0.6 * (1.0 - v)).clamp(0.0, 1.0);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_RadarRingsPainter old) => true;
}

// ═════════════════════════════════════════════════════════════════════════
//  PROGRESS BAR PAINTER (fill + gleam)
// ═════════════════════════════════════════════════════════════════════════

class _ProgressBarPainter extends CustomPainter {
  final double fill;
  final double gleam;
  final Color goldStart;
  final Color goldEnd;
  _ProgressBarPainter({
    required this.fill,
    required this.gleam,
    required this.goldStart,
    required this.goldEnd,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Track background
    canvas.drawRRect(
      RRect.fromLTRBR(0, 0, size.width, size.height, const Radius.circular(2)),
      Paint()..color = Colors.white.withValues(alpha: 0.1),
    );

    if (fill <= 0) return;
    final fillWidth = size.width * fill;

    // Gold fill gradient
    final fillRect = RRect.fromLTRBR(0, 0, fillWidth, size.height, const Radius.circular(2));
    canvas.drawRRect(
      fillRect,
      Paint()
        ..shader = LinearGradient(
          colors: [goldStart, goldEnd],
        ).createShader(Rect.fromLTWH(0, 0, fillWidth, size.height)),
    );

    // Gleam highlight sweeping across fill
    final gleamCenter = gleam * fillWidth;
    const gleamHalf = 30.0;
    canvas.save();
    canvas.clipRRect(fillRect);
    canvas.drawRect(
      Rect.fromLTWH(gleamCenter - gleamHalf, 0, gleamHalf * 2, size.height),
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.35),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(
            gleamCenter - gleamHalf, 0, gleamHalf * 2, size.height)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ProgressBarPainter old) =>
      old.fill != fill || old.gleam != gleam;
}

// ═════════════════════════════════════════════════════════════════════════
//  PARTICLE MODEL + PAINTER
// ═════════════════════════════════════════════════════════════════════════

class _Particle {
  final double x;
  final double y;
  final double size;
  final double driftSpeed;
  final double phase;
  const _Particle({
    required this.x,
    required this.y,
    required this.size,
    required this.driftSpeed,
    required this.phase,
  });
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double drift;
  final List<double> twinkleValues;
  final Color color;
  _ParticlePainter({
    required this.particles,
    required this.drift,
    required this.twinkleValues,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < particles.length; i++) {
      final p = particles[i];
      final tw = twinkleValues[i];
      final alpha = 0.1 + tw * 0.3; // 0.1→0.4
      final dx = p.x * size.width;
      final dy = ((p.y - drift * p.driftSpeed + p.phase) % 1.0) * size.height;
      canvas.drawCircle(
        Offset(dx, dy),
        p.size,
        Paint()
          ..color = color.withValues(alpha: alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, p.size * 0.4),
      );
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => true;
}
