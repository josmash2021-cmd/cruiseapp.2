import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../config/page_transitions.dart';
import 'driver_info_pages.dart';
import '../../widgets/gold_particles_background.dart';

/// Premium cinematic "Welcome to the Family" screen.
/// Shows after dispatch approves a driver, auto-navigates after ~4 s.
class DriverApprovedScreen extends StatefulWidget {
  const DriverApprovedScreen({super.key});

  @override
  State<DriverApprovedScreen> createState() => _DriverApprovedScreenState();
}

class _DriverApprovedScreenState extends State<DriverApprovedScreen>
    with TickerProviderStateMixin {
  static const _bg = Color(0xFF080604);
  static const _gold = Color(0xFFD4AF37);
  static const _goldLight = Color(0xFFE8C547);
  static const _goldBright = Color(0xFFFFF1C1);

  // Phase 1: Logo ring glow
  late final AnimationController _ringCtrl;
  // Phase 2: Logo scale
  late final AnimationController _logoCtrl;
  // Phase 3: Text fade + slide
  late final AnimationController _textCtrl;
  // (Button removed — auto-navigate only)
  // Continuous: particles
  late final AnimationController _particleCtrl;
  // Continuous: ring shimmer
  late final AnimationController _shimmerCtrl;

  Timer? _navTimer;
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: _bg,
    ));

    _ringCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _logoCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _textCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
    _particleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    final rng = Random(42);
    _particles = List.generate(
      24,
      (i) => _Particle(
        x: rng.nextDouble(),
        y: rng.nextDouble(),
        speed: 0.1 + rng.nextDouble() * 0.3,
        size: 1.0 + rng.nextDouble() * 2.5,
        phase: rng.nextDouble(),
      ),
    );

    _runSequence();
  }

  Future<void> _runSequence() async {
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;

    // Ring glow appears
    _ringCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;

    // Logo scales in
    _logoCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    // Text fades in
    _textCtrl.forward();

    // Auto-navigate after total ~4s
    _navTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted) _goNext();
    });
  }

  @override
  void dispose() {
    _ringCtrl.dispose();
    _logoCtrl.dispose();
    _textCtrl.dispose();
    _shimmerCtrl.dispose();
    _particleCtrl.dispose();
    _navTimer?.cancel();
    super.dispose();
  }

  void _goNext() {
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 600),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, __, ___) => const NewDriverInstructionsScreen(),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
          child: child,
        ),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: _bg,
        body: GoldParticlesBackground(child: Stack(
          children: [
            // ── Gold dust particles ──
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

            // ── Radial background glow ──
            AnimatedBuilder(
              animation: _ringCtrl,
              builder: (_, __) => Opacity(
                opacity: _ringCtrl.value,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0, -0.2),
                      radius: 0.7,
                      colors: [
                        Color(0xFF1C1508),
                        Color(0xFF0E0B04),
                        _bg,
                      ],
                      stops: [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              ),
            ),

            // ── Main content ──
            SafeArea(
              child: SizedBox.expand(
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Spacer(flex: 2),

                  // ── Logo with animated ring ──
                  AnimatedBuilder(
                    animation: Listenable.merge([_logoCtrl, _shimmerCtrl]),
                    builder: (_, __) {
                      final scale = Curves.elasticOut
                          .transform(_logoCtrl.value.clamp(0.0, 1.0));
                      final shimmer = _shimmerCtrl.value;
                      return Transform.scale(
                        scale: 0.3 + 0.7 * scale,
                        child: Opacity(
                          opacity: _logoCtrl.value.clamp(0.0, 1.0),
                          child: _buildLogoRing(shimmer),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 48),

                  // ── Text ──
                  AnimatedBuilder(
                    animation: _textCtrl,
                    builder: (_, child) {
                      final t = Curves.easeOutCubic.transform(
                          _textCtrl.value.clamp(0.0, 1.0));
                      return Transform.translate(
                        offset: Offset(0, 20 * (1 - t)),
                        child: Opacity(opacity: t, child: child),
                      );
                    },
                    child: Column(
                      children: [
                        // Decorative line
                        _buildDecoLine(80),
                        const SizedBox(height: 20),
                        ShaderMask(
                          shaderCallback: (bounds) => const LinearGradient(
                            colors: [_goldBright, _goldLight, _gold, _goldLight],
                            stops: [0.0, 0.3, 0.7, 1.0],
                          ).createShader(bounds),
                          child: Text(
                            'WELCOME TO THE FAMILY',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.cinzel(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: 3,
                              height: 1.3,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ShaderMask(
                          shaderCallback: (bounds) => const LinearGradient(
                            colors: [_goldLight, _goldBright],
                          ).createShader(bounds),
                          child: Text(
                            'CRUISE',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.cinzel(
                              fontSize: 36,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: 12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        _buildDecoLine(80),
                        const SizedBox(height: 20),
                        Text(
                          'Your application has been approved.\nGet ready to hit the road.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _goldBright.withValues(alpha: 0.6),
                            fontSize: 14,
                            height: 1.6,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Spacer(flex: 3),
                  const SizedBox(height: 24),
                ],
              ),
              ),
            ),
          ],
        )),
      ),
    );
  }

  Widget _buildLogoRing(double shimmer) {
    return SizedBox(
      width: 160,
      height: 160,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer glow
          Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.25 + 0.1 * sin(shimmer * pi * 2)),
                  blurRadius: 40,
                  spreadRadius: 8,
                ),
              ],
            ),
          ),
          // Animated shimmer ring
          CustomPaint(
            size: const Size(150, 150),
            painter: _RingPainter(
              progress: shimmer,
              color: _gold,
              strokeWidth: 3.0,
            ),
          ),
          // Inner dark circle with app logo
          Container(
            width: 130,
            height: 130,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF0F1408),
              border: Border.all(color: _gold.withValues(alpha: 0.3), width: 1.5),
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/images/logoapp.png',
                width: 130,
                height: 130,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDecoLine(double width) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: width * 0.4,
          height: 0.6,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              Colors.transparent,
              _gold.withValues(alpha: 0.5),
            ]),
          ),
        ),
        const SizedBox(width: 10),
        Transform.rotate(
          angle: 0.785398, // 45°
          child: Container(
            width: 5,
            height: 5,
            color: _gold.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(width: 10),
        Container(
          width: width * 0.4,
          height: 0.6,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              _gold.withValues(alpha: 0.5),
              Colors.transparent,
            ]),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  Animated gold ring with shimmer highlight
// ═══════════════════════════════════════════════════════════════

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double strokeWidth;

  _RingPainter({
    required this.progress,
    required this.color,
    this.strokeWidth = 2.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Base ring
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );

    // Shimmer highlight arc
    final sweepAngle = pi * 0.6;
    final startAngle = progress * pi * 2 - sweepAngle / 2;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      Paint()
        ..color = color.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}

// ═══════════════════════════════════════════════════════════════
//  Gold dust particles
// ═══════════════════════════════════════════════════════════════

class _Particle {
  final double x, y, speed, size, phase;
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
      final alpha = (sin(t * pi) * 0.45).clamp(0.0, 1.0);
      final dx = p.x * size.width;
      final dy = (p.y - t * 0.15) % 1.0 * size.height;
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
  bool shouldRepaint(_ParticlePainter old) => old.progress != progress;
}
