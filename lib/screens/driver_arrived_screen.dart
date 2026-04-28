import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../widgets/verified_avatar.dart';
import '../utils/responsive.dart';

/// ════════════════════════════════════════════════════════════
///  DRIVER ARRIVED OVERLAY — Semi-transparent overlay on top
///  of the map. When rider taps the gold ring, it fades away
///  revealing the full map with the complete route visible.
/// ════════════════════════════════════════════════════════════

class DriverArrivedOverlay extends StatefulWidget {
  final String driverName;
  final String? driverPhotoUrl;
  final String driverCar;
  final String driverPlate;
  final double driverRating;
  final String? driverPhone;
  final int freeWaitMinutes;
  final VoidCallback onDismiss; // Called when rider taps the ring
  final VoidCallback? onCancel;

  const DriverArrivedOverlay({
    super.key,
    required this.driverName,
    this.driverPhotoUrl,
    required this.driverCar,
    required this.driverPlate,
    this.driverRating = 5.0,
    this.driverPhone,
    this.freeWaitMinutes = 2,
    required this.onDismiss,
    this.onCancel,
  });

  @override
  State<DriverArrivedOverlay> createState() => _DriverArrivedOverlayState();
}

class _DriverArrivedOverlayState extends State<DriverArrivedOverlay>
    with TickerProviderStateMixin {
  late AnimationController _ringController;
  late AnimationController _fadeController;
  late AnimationController _checkController;
  late AnimationController _countdownPulseController;

  late Animation<double> _fadeIn;
  late Animation<double> _checkScale;
  late Animation<double> _checkDraw;
  late Animation<double> _countdownPulse;

  Timer? _countdownTimer;
  int _remainingSeconds = 0;
  bool _isDismissing = false;

  static const _gold = Color(0xFFE8C547);

  @override
  void initState() {
    super.initState();
    _remainingSeconds = widget.freeWaitMinutes * 60;

    // ── Ring pulse animation (continuous) ──
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    // ── Staggered fade-in ──
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _fadeIn = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOutCubic,
    );

    // ── Checkmark pop + draw ──
    _checkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _checkScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _checkController,
        curve: const Interval(0.0, 0.5, curve: Curves.elasticOut),
      ),
    );
    _checkDraw = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _checkController,
        curve: const Interval(0.3, 1.0, curve: Curves.easeOutCubic),
      ),
    );

    // ── Countdown card pulse ──
    _countdownPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _countdownPulse = Tween<double>(begin: 1.0, end: 1.03).animate(
      CurvedAnimation(
        parent: _countdownPulseController,
        curve: Curves.easeInOutSine,
      ),
    );

    _startEntranceAnimation();
    _startCountdown();
  }

  void _startEntranceAnimation() async {
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;

    _fadeController.forward();
    _ringController.repeat();

    await Future.delayed(const Duration(milliseconds: 350));
    if (mounted) _checkController.forward();

    await Future.delayed(const Duration(milliseconds: 700));
    if (mounted) _countdownPulseController.repeat(reverse: true);
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_remainingSeconds > 0) {
          _remainingSeconds--;
        } else {
          timer.cancel();
          _handleAutoDismiss();
        }
      });
    });
  }

  void _handleAutoDismiss() {
    if (_isDismissing) return;
    _dismiss();
  }

  void _handleTap() {
    if (_isDismissing) return;
    _dismiss();
  }

  void _dismiss() {
    _isDismissing = true;
    _countdownTimer?.cancel();

    // Play exit fade then call onDismiss
    _fadeController.reverse().then((_) {
      if (mounted) widget.onDismiss();
    });
  }

  String get _formattedTime {
    final mins = _remainingSeconds ~/ 60;
    final secs = _remainingSeconds % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _ringController.dispose();
    _fadeController.dispose();
    _checkController.dispose();
    _countdownPulseController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);

    return FadeTransition(
      opacity: _fadeIn,
      child: Container(
        color: const Color(0xFF0A0A0A).withValues(alpha: 0.88),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 60),

              // ── Title ──
              _SlideIn(
                delay: const Duration(milliseconds: 0),
                child: Text(
                  s.yourDriverHasArrived,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: Responsive.sp(24),
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              const SizedBox(height: 6),

              // ── Subtitle ──
              _SlideIn(
                delay: const Duration(milliseconds: 80),
                child: Text(
                  '${widget.driverName} ${s.isWaiting}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: Responsive.sp(14),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),

              const Spacer(flex: 2),

              // ── Animated Gold Ring (tappable) ──
              _SlideIn(
                delay: const Duration(milliseconds: 150),
                child: GestureDetector(
                  onTap: _handleTap,
                  child: SizedBox(
                    width: 200,
                    height: 200,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Pulsing rings (2 offset)
                        ...List.generate(2, (index) {
                          return AnimatedBuilder(
                            animation: _ringController,
                            builder: (context, child) {
                              final delay = index * 0.5;
                              final t = ((_ringController.value + delay) % 1.0);
                              final scale = 0.85 + (t * 0.3);
                              final opacity = (1.0 - t) * 0.5;
                              return Transform.scale(
                                scale: scale,
                                child: Container(
                                  width: 170,
                                  height: 170,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: _gold.withValues(
                                        alpha: opacity.clamp(0.0, 0.6),
                                      ),
                                      width: 2.5,
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        }),

                        // Solid gold ring
                        Container(
                          width: 160,
                          height: 160,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _gold.withValues(alpha: 0.35),
                              width: 2,
                            ),
                            gradient: RadialGradient(
                              colors: [
                                _gold.withValues(alpha: 0.1),
                                Colors.transparent,
                              ],
                              stops: const [0.4, 1.0],
                            ),
                          ),
                        ),

                        // Inner glow
                        Container(
                          width: 130,
                          height: 130,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                _gold.withValues(alpha: 0.15),
                                _gold.withValues(alpha: 0.02),
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: _gold.withValues(alpha: 0.2),
                                blurRadius: 40,
                                spreadRadius: 8,
                              ),
                            ],
                          ),
                        ),

                        // Checkmark
                        ScaleTransition(
                          scale: _checkScale,
                          child: CustomPaint(
                            size: const Size(44, 44),
                            painter: _CheckmarkPainter(
                              color: Colors.white,
                              progress: _checkDraw.value,
                            ),
                          ),
                        ),

                        // Tap hint
                        Positioned(
                          bottom: 24,
                          child: FadeTransition(
                            opacity: _checkController,
                            child: Text(
                              s.pressWhenWithDriver,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.4),
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const Spacer(flex: 2),

              // ── Free Wait Time Countdown ──
              _SlideIn(
                delay: const Duration(milliseconds: 300),
                child: AnimatedBuilder(
                  animation: _countdownPulse,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _countdownPulse.value,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A2E1A),
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(
                            color: const Color(0xFF4CAF50).withValues(alpha: 0.3),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.access_time_rounded,
                              color: Color(0xFF4CAF50),
                              size: 15,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${s.freeWaitTime} ',
                              style: TextStyle(
                                color: const Color(0xFF4CAF50)
                                    .withValues(alpha: 0.8),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              _formattedTime,
                              style: const TextStyle(
                                color: Color(0xFF4CAF50),
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 20),

              // ── Driver Info Card ──
              _SlideIn(
                delay: const Duration(milliseconds: 400),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.06),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      VerifiedAvatar(
                        photoUrl: widget.driverPhotoUrl,
                        radius: Responsive.w(24),
                        fallbackName: widget.driverName,
                        role: 'driver',
                        isVerified: true,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.driverName,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: Responsive.sp(15),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                const Icon(
                                  Icons.star_rounded,
                                  color: _gold,
                                  size: 13,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  widget.driverRating.toStringAsFixed(1),
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.7),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            widget.driverCar,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            widget.driverPlate,
                            style: TextStyle(
                              color: _gold.withValues(alpha: 0.8),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // ── Auto-start hint ──
              _SlideIn(
                delay: const Duration(milliseconds: 500),
                child: Text(
                  s.rideStartsAutomatically,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),

              if (widget.onCancel != null) ...[
                const SizedBox(height: 12),
                _SlideIn(
                  delay: const Duration(milliseconds: 600),
                  child: TextButton(
                    onPressed: widget.onCancel,
                    child: Text(
                      s.cancelRide,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// ── Staggered slide-in animation ──
class _SlideIn extends StatelessWidget {
  final Widget child;
  final Duration delay;

  const _SlideIn({required this.child, required this.delay});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        final delayedValue =
            (value - delay.inMilliseconds / 1000).clamp(0.0, 1.0);
        return Opacity(
          opacity: delayedValue,
          child: Transform.translate(
            offset: Offset(0, (1 - delayedValue) * 16),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// ── Animated checkmark painter ──
class _CheckmarkPainter extends CustomPainter {
  final Color color;
  final double progress;

  _CheckmarkPainter({required this.color, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path();
    final p1 = Offset(size.width * 0.25, size.height * 0.55);
    final p2 = Offset(size.width * 0.45, size.height * 0.75);
    final p3 = Offset(size.width * 0.75, size.height * 0.3);

    if (progress <= 0.5) {
      final t = progress * 2;
      path.moveTo(p1.dx, p1.dy);
      path.lineTo(
        p1.dx + (p2.dx - p1.dx) * t,
        p1.dy + (p2.dy - p1.dy) * t,
      );
    } else {
      final t = (progress - 0.5) * 2;
      path.moveTo(p1.dx, p1.dy);
      path.lineTo(p2.dx, p2.dy);
      path.lineTo(
        p2.dx + (p3.dx - p2.dx) * t,
        p2.dy + (p3.dy - p2.dy) * t,
      );
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CheckmarkPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
