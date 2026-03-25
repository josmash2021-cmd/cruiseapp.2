import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';

import '../../config/page_transitions.dart';
import 'driver_home_screen.dart';

/// Premium cinematic "You're Approved!" screen.
/// Shows for ~3.2 s then auto-navigates to [DriverHomeScreen].
class DriverApprovedScreen extends StatefulWidget {
  const DriverApprovedScreen({super.key});

  @override
  State<DriverApprovedScreen> createState() => _DriverApprovedScreenState();
}

class _DriverApprovedScreenState extends State<DriverApprovedScreen>
    with TickerProviderStateMixin {
  static const _bg   = Color(0xFF0A0A0A);
  static const _gold = Color(0xFFD4AF37);

  late final AnimationController _checkCtrl;   // checkmark draw
  late final AnimationController _glowCtrl;    // circle glow pulse
  late final AnimationController _textCtrl;    // text slide-up + fade
  late final AnimationController _particleCtrl; // dust drift
  Timer? _navTimer;

  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();

    _checkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _textCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _particleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    // 18 gold dust particles
    final rng = Random(42);
    _particles = List.generate(18, (i) => _Particle(
      x: rng.nextDouble(),
      y: rng.nextDouble(),
      speed: 0.15 + rng.nextDouble() * 0.35,
      size: 1.0 + rng.nextDouble() * 3.0,
      phase: rng.nextDouble(),
    ));

    // Start text after checkmark finishes
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _textCtrl.forward();
    });

    // Auto-navigate to driver home after 3.2 s
    _navTimer = Timer(const Duration(milliseconds: 3200), () {
      if (mounted) _goToDriverHome();
    });
  }

  @override
  void dispose() {
    _checkCtrl.dispose();
    _glowCtrl.dispose();
    _textCtrl.dispose();
    _particleCtrl.dispose();
    _navTimer?.cancel();
    super.dispose();
  }

  void _goToDriverHome() {
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, __, ___) => const DriverHomeScreen(),
        transitionsBuilder: (_, anim, __, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
            child: child,
          );
        },
      ),
      (_) => false,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: _bg,
        body: Stack(
          children: [
            // Gold dust particles
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _particleCtrl,
                builder: (_, __) => CustomPaint(
                  painter: _ParticlePainter(
                    particles: _particles,
                    progress: _particleCtrl.value,
                    color: _gold,
                  ),
                ),
              ),
            ),

            // Main content
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // ── Gold checkmark circle with glow ──
                  AnimatedBuilder(
                    animation: _glowCtrl,
                    builder: (_, __) => Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF0F1A0A),
                        border: Border.all(color: _gold, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(
                                alpha: 0.2 + _glowCtrl.value * 0.3),
                            blurRadius: 30 + _glowCtrl.value * 20,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: AnimatedBuilder(
                        animation: _checkCtrl,
                        builder: (_, __) => CustomPaint(
                          painter: _CheckmarkPainter(
                            progress: _checkCtrl.value,
                            color: _gold,
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 40),

                  // ── Fade text ──
                  FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _textCtrl,
                      curve: Curves.easeInOut,
                    ),
                    child: Column(
                        children: [
                          const Text(
                            "You're Approved!",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Welcome to Cruise.\nGet ready to drive.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.54),
                              fontSize: 16,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 32),
                          // Gold pill
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 10),
                            decoration: BoxDecoration(
                              color: _gold,
                              borderRadius: BorderRadius.circular(30),
                            ),
                            child: const Text(
                              'Opening driver app…',
                              style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
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
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════
//  ANIMATED CHECKMARK PAINTER
// ═════════════════════════════════════════════════════════════════════════

class _CheckmarkPainter extends CustomPainter {
  final double progress;
  final Color color;
  _CheckmarkPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (progress == 0) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final p1 = Offset(size.width * 0.25, size.height * 0.52);
    final p2 = Offset(size.width * 0.43, size.height * 0.68);
    final p3 = Offset(size.width * 0.75, size.height * 0.36);

    final path = Path()..moveTo(p1.dx, p1.dy);

    if (progress <= 0.5) {
      final t = progress / 0.5;
      path.lineTo(
        p1.dx + (p2.dx - p1.dx) * t,
        p1.dy + (p2.dy - p1.dy) * t,
      );
    } else {
      final t = (progress - 0.5) / 0.5;
      path.lineTo(p2.dx, p2.dy);
      path.lineTo(
        p2.dx + (p3.dx - p2.dx) * t,
        p2.dy + (p3.dy - p2.dy) * t,
      );
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CheckmarkPainter old) => old.progress != progress;
}

// ═════════════════════════════════════════════════════════════════════════
//  GOLD DUST PARTICLES
// ═════════════════════════════════════════════════════════════════════════

class _Particle {
  final double x;
  final double y;
  final double speed;
  final double size;
  final double phase;
  const _Particle({
    required this.x,
    required this.y,
    required this.speed,
    required this.size,
    required this.phase,
  });
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double progress;
  final Color color;
  _ParticlePainter({
    required this.particles,
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final t = (progress * p.speed + p.phase) % 1.0;
      final alpha = (sin(t * pi) * 0.5).clamp(0.0, 1.0);
      final dx = p.x * size.width;
      final dy = (p.y - t * 0.2) % 1.0 * size.height;
      canvas.drawCircle(
        Offset(dx, dy),
        p.size,
        Paint()
          ..color = color.withValues(alpha: alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, p.size * 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.progress != progress;
}
