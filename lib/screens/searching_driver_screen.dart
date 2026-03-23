import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';

/// Premium animated screen shown after payment confirmation and before
/// the "Looking for your driver…" bottom sheet.  Auto-pops after ≈3.2 s.
class SearchingDriverScreen extends StatefulWidget {
  const SearchingDriverScreen({super.key});

  @override
  State<SearchingDriverScreen> createState() => _SearchingDriverScreenState();
}

class _SearchingDriverScreenState extends State<SearchingDriverScreen>
    with TickerProviderStateMixin {
  // ── constants ──
  static const _bg = Color(0xFF0A0A1A);
  static const _gold = Color(0xFFC8973A);
  static const _messages = [
    'Confirming your ride…',
    'Finding nearby drivers…',
    'Connecting you now…',
  ];

  // ── animation controllers ──
  late final AnimationController _rippleCtrl;
  late final AnimationController _shimmerCtrl;
  int _msgIndex = 0;
  Timer? _msgTimer;
  Timer? _navTimer;

  // ── shimmer particles ──
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();

    // Ripple rings — infinite 2 s loop
    _rippleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    // Shimmer / particle drift — infinite 6 s loop
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    // Seed particles (deterministic based on index)
    final rng = Random(42);
    _particles = List.generate(10, (i) {
      return _Particle(
        x: rng.nextDouble(),
        y: rng.nextDouble(),
        speed: 0.3 + rng.nextDouble() * 0.7,
        size: 2.0 + rng.nextDouble() * 3.0,
        phase: rng.nextDouble(),
      );
    });

    // Cycle text every 1.2 s
    _msgTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      if (mounted) setState(() => _msgIndex = (_msgIndex + 1) % _messages.length);
    });

    // Auto-pop after 3.2 s
    _navTimer = Timer(const Duration(milliseconds: 3200), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _rippleCtrl.dispose();
    _shimmerCtrl.dispose();
    _msgTimer?.cancel();
    _navTimer?.cancel();
    super.dispose();
  }

  // ── build ──
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          // Background shimmer particles
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _shimmerCtrl,
              builder: (_, __) => CustomPaint(
                painter: _ParticlePainter(
                  particles: _particles,
                  progress: _shimmerCtrl.value,
                  color: _gold,
                ),
              ),
            ),
          ),

          // Main content — centered column
          SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 3),

                // Gold car icon
                Icon(Icons.directions_car_rounded, color: _gold, size: 48),
                const SizedBox(height: 8),

                // "CRUISE" text
                Text(
                  'CRUISE',
                  style: TextStyle(
                    color: _gold,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 6,
                  ),
                ),

                const Spacer(flex: 2),

                // Pulsing gold ripple rings + center icon
                SizedBox(
                  width: 240,
                  height: 240,
                  child: AnimatedBuilder(
                    animation: _rippleCtrl,
                    builder: (_, __) => Stack(
                      alignment: Alignment.center,
                      children: [
                        _buildRipple(0.0),
                        _buildRipple(0.33),
                        _buildRipple(0.66),
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _gold.withAlpha(30),
                          ),
                          child: const Icon(
                            Icons.directions_car,
                            color: _gold,
                            size: 36,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const Spacer(),

                // Animated text
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: Text(
                    _messages[_msgIndex],
                    key: ValueKey(_msgIndex),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w300,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // Gold progress bar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 64),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 3000),
                    curve: Curves.easeInOut,
                    builder: (_, value, __) {
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: value,
                          backgroundColor: Colors.white10,
                          valueColor: const AlwaysStoppedAnimation(_gold),
                          minHeight: 2,
                        ),
                      );
                    },
                  ),
                ),

                const Spacer(flex: 3),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Ripple ring widget ──
  Widget _buildRipple(double delay) {
    final raw = (_rippleCtrl.value + delay) % 1.0;
    final scale = 1.0 + raw * 2.5;
    final opacity = (1.0 - raw).clamp(0.0, 1.0);
    return Transform.scale(
      scale: scale,
      child: Opacity(
        opacity: opacity * 0.6,
        child: Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: _gold, width: 1.5),
          ),
        ),
      ),
    );
  }
}

// ── Route builder ──

/// 3-D perspective flip entry + fade-out reverse.
Route<void> searchingDriverRoute() {
  return PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 600),
    reverseTransitionDuration: const Duration(milliseconds: 400),
    pageBuilder: (_, __, ___) => const SearchingDriverScreen(),
    transitionsBuilder: (_, anim, __, child) {
      // Entry: 3-D rotateX flip
      // Exit (pop): simple fade-out
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
      // Reverse (pop) — fade out
      return FadeTransition(opacity: anim, child: child);
    },
  );
}

// ── Particle model + painter ──

class _Particle {
  final double x; // 0-1
  final double y; // 0-1
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
      // Smooth fade in-out over the particle's life
      final alpha = (sin(t * pi) * 0.45).clamp(0.0, 1.0);
      final dx = p.x * size.width;
      final dy = (p.y + t * 0.15) % 1.0 * size.height;
      canvas.drawCircle(
        Offset(dx, dy),
        p.size,
        Paint()..color = color.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.progress != progress;
}
