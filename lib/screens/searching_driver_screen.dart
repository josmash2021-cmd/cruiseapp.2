import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';

/// Premium cinematic screen shown after payment confirmation and before
/// the "Looking for your driver…" bottom sheet.  Auto-pops after ≈3.2 s.
///
/// Features: floating gold dust particles, cinematic light sweep, rotating
/// concentric rings with gold glow, floating car icon, shimmer text with
/// animated dots, glowing gold progress bar, step indicator.
class SearchingDriverScreen extends StatefulWidget {
  const SearchingDriverScreen({super.key});

  @override
  State<SearchingDriverScreen> createState() => _SearchingDriverScreenState();
}

class _SearchingDriverScreenState extends State<SearchingDriverScreen>
    with TickerProviderStateMixin {
  // ── colours ──
  static const _bg        = Color(0xFF0A0D1A);
  static const _gold      = Color(0xFFD4AF37);
  static const _goldLight = Color(0xFFFFE566);
  static const _messages  = [
    'Confirming your ride',
    'Finding nearby drivers',
    'Connecting you now',
  ];

  // ── animation controllers ──
  late final AnimationController _particleCtrl;    // 6 s  – dust drift
  late final AnimationController _pulseCtrl;       // 2 s  – ring pulse
  late final AnimationController _rotateCtrl;      // 8 s  – ring rotation
  late final AnimationController _glowCtrl;        // 1.5 s – inner glow
  late final AnimationController _sweepCtrl;       // 2.5 s – light sweep
  late final AnimationController _textShimmerCtrl; // 1.8 s – text shimmer
  late final AnimationController _progressCtrl;    // 3 s  – progress bar

  int _msgIndex = 0;
  int _dotCount = 0;
  Timer? _msgTimer;
  Timer? _dotTimer;
  Timer? _navTimer;

  // ── particles ──
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();

    _particleCtrl = AnimationController(
      vsync: this, duration: const Duration(seconds: 6))..repeat();

    _pulseCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2000))
      ..repeat(reverse: true);

    _rotateCtrl = AnimationController(
      vsync: this, duration: const Duration(seconds: 8))..repeat();

    _glowCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500))
      ..repeat(reverse: true);

    _sweepCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2500))..repeat();

    _textShimmerCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

    _progressCtrl = AnimationController(
      vsync: this, duration: const Duration(seconds: 3))..repeat();

    // 18 floating gold dust particles
    final rng = Random(42);
    _particles = List.generate(18, (i) => _Particle(
      x: rng.nextDouble(),
      y: rng.nextDouble(),
      speed: 0.15 + rng.nextDouble() * 0.35,
      size: 1.0 + rng.nextDouble() * 3.0,
      phase: rng.nextDouble(),
    ));

    // Cycle status text every 1.2 s
    _msgTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      if (mounted) setState(() => _msgIndex = (_msgIndex + 1) % _messages.length);
    });

    // Animated dots 0→1→2→3→0
    _dotTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _dotCount = (_dotCount + 1) % 4);
    });

    // Auto-pop after 3.2 s
    _navTimer = Timer(const Duration(milliseconds: 3200), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _particleCtrl.dispose();
    _pulseCtrl.dispose();
    _rotateCtrl.dispose();
    _glowCtrl.dispose();
    _sweepCtrl.dispose();
    _textShimmerCtrl.dispose();
    _progressCtrl.dispose();
    _msgTimer?.cancel();
    _dotTimer?.cancel();
    _navTimer?.cancel();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          // Layer 1 — floating gold dust particles
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

          // Layer 2 — cinematic gold light sweep across top
          Positioned(top: 0, left: 0, right: 0, child: _buildLightSweep()),

          // Layer 3 — main content
          SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 2),

                // Concentric rotating rings + floating car
                _buildConcentricRings(),

                const Spacer(),

                // Shimmer text with animated dots
                _buildShimmerText(),

                const SizedBox(height: 24),

                // Gold progress bar with glow
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: _buildGoldProgressBar(),
                ),

                const Spacer(flex: 2),

                // Step indicator
                Text('1 of 3',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 13,
                  )),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  GOLD LIGHT SWEEP (top of screen)
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildLightSweep() {
    return AnimatedBuilder(
      animation: _sweepCtrl,
      builder: (_, __) {
        final v = _sweepCtrl.value;
        return ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            colors: [
              Colors.transparent,
              _gold.withValues(alpha: 0.15),
              _goldLight.withValues(alpha: 0.3),
              _gold.withValues(alpha: 0.15),
              Colors.transparent,
            ],
            stops: [
              0.0,
              (v - 0.1).clamp(0.0, 1.0),
              v.clamp(0.0, 1.0),
              (v + 0.1).clamp(0.0, 1.0),
              1.0,
            ],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ).createShader(bounds),
          child: Container(height: 120, color: Colors.white),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  CONCENTRIC ROTATING RINGS + FLOATING CAR
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildConcentricRings() {
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseCtrl, _rotateCtrl, _glowCtrl]),
      builder: (_, __) {
        return SizedBox(
          width: 260,
          height: 260,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outer ring — slow clockwise rotation + pulse
              Transform.rotate(
                angle: _rotateCtrl.value * 2 * pi,
                child: Container(
                  width: 220 + _pulseCtrl.value * 10,
                  height: 220 + _pulseCtrl.value * 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _gold.withValues(
                          alpha: 0.15 + _glowCtrl.value * 0.1),
                      width: 1,
                    ),
                  ),
                ),
              ),

              // Middle ring — counter-clockwise rotation
              Transform.rotate(
                angle: -_rotateCtrl.value * 2 * pi * 0.7,
                child: Container(
                  width: 155,
                  height: 155,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _gold.withValues(
                          alpha: 0.25 + _glowCtrl.value * 0.15),
                      width: 1,
                    ),
                  ),
                ),
              ),

              // Inner dark circle with pulsing gold glow
              Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF0F1220),
                  boxShadow: [
                    BoxShadow(
                      color: _gold.withValues(
                          alpha: 0.2 + _glowCtrl.value * 0.2),
                      blurRadius: 20 + _glowCtrl.value * 15,
                      spreadRadius: 2,
                    ),
                  ],
                  border: Border.all(
                    color: _gold.withValues(alpha: 0.5),
                    width: 1.5,
                  ),
                ),
                // Floating car icon
                child: Center(
                  child: Transform.translate(
                    offset: Offset(0, -3 + _glowCtrl.value * 6),
                    child: Icon(
                      Icons.directions_car,
                      color: _gold,
                      size: 36,
                      shadows: [
                        Shadow(
                          color: _gold.withValues(alpha: 0.8),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  SHIMMER TEXT + ANIMATED DOTS
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildShimmerText() {
    return AnimatedBuilder(
      animation: _textShimmerCtrl,
      builder: (_, __) {
        final v = _textShimmerCtrl.value;
        return ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            colors: const [Colors.white54, Colors.white, Colors.white54],
            stops: [
              (v - 0.3).clamp(0.0, 1.0),
              v.clamp(0.0, 1.0),
              (v + 0.3).clamp(0.0, 1.0),
            ],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ).createShader(bounds),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: Text(
              '${_messages[_msgIndex]}${'.' * _dotCount}',
              key: ValueKey(_msgIndex),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w300,
                letterSpacing: 1.2,
              ),
            ),
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  GOLD PROGRESS BAR WITH GLOW
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildGoldProgressBar() {
    return AnimatedBuilder(
      animation: _progressCtrl,
      builder: (_, __) {
        return Container(
          width: double.infinity,
          height: 3,
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(2),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: _progressCtrl.value,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: const LinearGradient(
                  colors: [_gold, _goldLight, _gold],
                ),
                boxShadow: [
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.6),
                    blurRadius: 6,
                  ),
                ],
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

/// 3-D perspective flip entry + fade-out reverse.
Route<void> searchingDriverRoute() {
  return PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 600),
    reverseTransitionDuration: const Duration(milliseconds: 400),
    pageBuilder: (_, __, ___) => const SearchingDriverScreen(),
    transitionsBuilder: (_, anim, __, child) {
      final isForward = anim.status == AnimationStatus.forward ||
          anim.status == AnimationStatus.completed;
      if (isForward) {
        final curved =
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return AnimatedBuilder(
          animation: curved,
          builder: (_, __) {
            final angle = (1 - curved.value) * pi / 2;
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.001)
                ..rotateX(angle),
              child: Opacity(opacity: curved.value, child: child),
            );
          },
        );
      }
      return FadeTransition(opacity: anim, child: child);
    },
  );
}

// ═════════════════════════════════════════════════════════════════════════
//  PARTICLE MODEL + PAINTER
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
