import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../widgets/neu_style.dart';

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
  static const _bg   = Color(0xFF000000);
  static const _gold = Color(0xFFE8C547);
  static const _goldEnd = Color(0xFFF5D990);

  /// Total time this screen may stay on top before it pops itself.
  static const _visibleCap = Duration(seconds: 4);

  /// What _finishAndPop costs on the way out: ~300 ms filling the progress
  /// bar + the 450 ms exit fade. Kept next to _visibleCap so the two stay
  /// in sync — if the exit animation changes, this is the number to update.
  static const _exitCost = Duration(milliseconds: 750);

  // ── controllers ──
  late final AnimationController _radarCtrl;    // 2400 ms – radar pulse rings
  late final AnimationController _glowCtrl;     // 1200 ms – car glow + scale
  late final AnimationController _particleCtrl; // 4000 ms – floating particles
  late final AnimationController _progressCtrl; // 4000 ms – progress bar (repeating)
  late final AnimationController _shimmerCtrl;  // 2000 ms – text shimmer
  late final AnimationController _barGleamCtrl; // 1200 ms – progress bar gleam
  late final AnimationController _exitCtrl;     // 450 ms – animated exit (fade+scale)

  // ── derived animations for 4 radar rings ──
  late final Animation<double> _ring1, _ring2, _ring3, _ring4;

  // ── declined state ──
  bool _paymentDeclined = false;
  Timer? _paymentStartTimer;
  Timer? _declinedPopTimer;
  Timer? _searchTimeoutTimer; // Safety timeout to prevent getting stuck
  Timer? _hardTimeoutTimer; // Pops even if the exit animations never finish

  // ── status text cycling ──
  // 0 = "Confirming your ride…" (briefly)
  // 1 = "Looking for your driver…"
  // 2 = "Connecting to nearby drivers…"
  int _textPhase = 0;
  Timer? _textPhaseTimer;

  // ── driver-found early-pop ──
  VoidCallback? _driverFoundCb;
  bool _popping = false; // Prevents double-pop when driver matched

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

    // ── 5. Progress bar (one-shot — fills over ~4s then holds at 100%) ──
    // When driver is matched, the bar completes and transitions smoothly.
    _progressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    );
    _progressCtrl.forward();

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

    // ── 8. Animated exit (fade + slight zoom before popping) ──
    _exitCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );

    // Policy 2026-04-11: this screen is ONLY for the payment-authorization
    // phase. It shows a single "Confirming your ride..." label while the
    // Stripe paymentCallback runs, then pops on success so the
    // RideRequestScreen can enter its waiting-for-driver map mode. We no
    // longer cycle through "Looking for driver" / "Connecting" strings or
    // listen on a driverFound notifier — driver matching happens on the
    // next screen.
    _textPhase = 0; // always "Confirming your ride…"

    // When driver is matched, complete the progress bar to 100% first,
    // then exit with the fade+zoom animation. This ensures the bar never
    // resets mid-animation — it always finishes smoothly before
    // transitioning to the next screen.
    if (widget.driverFound != null) {
      _driverFoundCb = () {
        if (widget.driverFound!.value && mounted && !_popping) {
          _finishAndPop();
        }
      };
      widget.driverFound!.addListener(_driverFoundCb!);
      if (widget.driverFound!.value && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_popping) _finishAndPop();
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
            _finishAndPop(true);
          } else {
            // Payment succeeded — caller picks up and transitions the
            // parent screen into waiting-for-driver mode.
            _finishAndPop(false);
          }
        } catch (_) {
          if (mounted) _handleDeclined();
        }
      });
    }

    // ── Hard cap: this screen is a transition, not a waiting room. After
    // 4 s it completes the bar and pops no matter what, dropping the rider
    // back onto the ride-request map in waiting-for-driver mode — where
    // there is a real map, a real ETA and a cancel button, instead of a
    // black screen with a spinner.
    //
    // Safe to cut this short because the caller passes paymentCallback:
    // null — the charge is already authorized before this screen opens, so
    // popping early can never abandon a payment mid-flight. Driver matching
    // continues on the screen underneath.
    //
    // Fired early on purpose: _finishAndPop spends ~300 ms filling the
    // progress bar and 450 ms on the exit fade, so starting at a flat 4 s
    // would leave the screen up until ~4.75 s. Subtracting that exit cost
    // is what makes it actually GONE at 4 s.
    _searchTimeoutTimer = Timer(
      _visibleCap - _exitCost,
      () {
        if (mounted && !_popping) {
          debugPrint('[SearchingDriverScreen] 4s cap reached — completing bar and popping');
          _finishAndPop(false);
        }
      },
    );

    // A second timer that does not wait for anything.
    //
    // The graceful exit awaits two animations — the bar filling and the fade
    // — and an awaited animation is only as reliable as its ticker. A
    // backgrounded browser tab pauses tickers, so both awaits can sit there
    // for as long as the tab is away and the screen never leaves, which is
    // the one thing a timeout exists to prevent.
    //
    // One second past the visible cap, this pops outright. If the graceful
    // path already ran, _popping is set and this does nothing.
    _hardTimeoutTimer = Timer(
      _visibleCap + const Duration(seconds: 1),
      () {
        if (!mounted || _popping) return;
        debugPrint('[SearchingDriverScreen] hard cap — popping without waiting');
        _popping = true;
        Navigator.of(context).pop(false);
      },
    );
  }

  @override
  void dispose() {
    _textPhaseTimer?.cancel();
    if (_driverFoundCb != null) widget.driverFound?.removeListener(_driverFoundCb!);
    _paymentStartTimer?.cancel();
    _declinedPopTimer?.cancel();
    _searchTimeoutTimer?.cancel();
    _hardTimeoutTimer?.cancel();
    _radarCtrl.dispose();
    _glowCtrl.dispose();
    _particleCtrl.dispose();
    _progressCtrl.dispose();
    _shimmerCtrl.dispose();
    _barGleamCtrl.dispose();
    _exitCtrl.dispose();
    for (final c in _twinkleControllers) {
      c.dispose();
    }
    super.dispose();
  }

  /// Coordinated animated exit: finish the progress bar, fade+zoom the
  /// splash out, then pop so the underlying map (waiting-for-driver card)
  /// is revealed smoothly instead of an abrupt cut.
  Future<void> _finishAndPop([bool? result, bool completeBar = true]) async {
    if (_popping) return;
    _popping = true;
    if (completeBar) {
      final remaining = 1.0 - _progressCtrl.value;
      if (remaining > 0.01) {
        try {
          await _progressCtrl.animateTo(
            1.0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutQuart,
          );
        } catch (_) {}
      }
    }
    if (!mounted) return;
    try {
      await _exitCtrl.forward();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pop(result);
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
      _finishAndPop(null, false);
    });
  }

  void _showCancelDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
          decoration: neuBox(radius: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: neuBox(radius: 18, pressed: true),
                child: const Icon(
                  Icons.cancel_outlined,
                  color: _gold,
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                S.of(context).cancelRideQuestion,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                S.of(context).cancelRideMsg,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  // Keep waiting — pressed neumorphic well, gold text
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        decoration: neuBox(radius: 12, pressed: true),
                        child: Text(
                          S.of(context).keepWaiting,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Yes, cancel — solid gold primary
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        Navigator.pop(ctx); // close dialog
                        widget.onCancel
                            ?.call(); // run cancel logic in controller
                        Navigator.of(
                          context,
                        ).pop(true); // pop this screen with cancelled=true
                      },
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _gold,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          S.of(context).yesCancelBtn,
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AnimatedBuilder(
        animation: _exitCtrl,
        builder: (context, child) {
          // Exit animation: fade out with a slight zoom-in, then the route's
          // own reverse fade hands off to the map (waiting-for-driver card).
          final t = Curves.easeInCubic.transform(_exitCtrl.value);
          return Opacity(
            opacity: 1.0 - t,
            child: Transform.scale(scale: 1.0 + t * 0.06, child: child),
          );
        },
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
        ),
      ),
    );
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
              color: Colors.black,
              border: Border.all(color: _gold.withValues(alpha: 0.5), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.3 + g * 0.5),
                  blurRadius: 18 + g * 14,
                  spreadRadius: 2,
                ),
              ],
            ),
            // App logo fills the whole circle (logoapp.png is the gold
            // car-in-circle brand mark, already on a black background).
            child: ClipOval(
              child: Image.asset(
                'assets/images/logoapp.png',
                fit: BoxFit.cover,
                width: 72,
                height: 72,
              ),
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
    // opaque: true so the matching screen fully covers the ride_request
    // bottom sheet ("Almost there..." card) underneath. Once this screen
    // pops (after the matching animation completes), the underlying card
    // becomes visible again — that is the intended sequence.
    opaque: true,
    transitionDuration: const Duration(milliseconds: 420),
    reverseTransitionDuration: const Duration(milliseconds: 420),
    pageBuilder: (_, __, ___) => SearchingDriverScreen(
      onCancel: onCancel,
      paymentCallback: paymentCallback,
      onPaymentDeclined: onPaymentDeclined,
      initiallyDeclined: initiallyDeclined,
      driverFound: driverFound,
    ),
    transitionsBuilder: (_, anim, __, child) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: anim,
          curve: Curves.easeInOutCubic,
          reverseCurve: Curves.easeInOutCubic,
        ),
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
