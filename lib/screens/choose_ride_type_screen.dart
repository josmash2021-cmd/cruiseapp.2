import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';

/// Full-screen "Choose ride type" picker — replaces the old bottom sheet.
///
/// Returns `'airport'` or `'schedule'` via Navigator.pop (or `null` if the
/// user hits back), keeping the downstream flow untouched.
class ChooseRideTypeScreen extends StatefulWidget {
  const ChooseRideTypeScreen({super.key});

  @override
  State<ChooseRideTypeScreen> createState() => _ChooseRideTypeScreenState();
}

class _ChooseRideTypeScreenState extends State<ChooseRideTypeScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entryCtl;
  late final AnimationController _floatCtl;

  @override
  void initState() {
    super.initState();
    _entryCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    )..forward();
    _floatCtl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    
  }

  @override
  void dispose() {
    _entryCtl.dispose();
    _floatCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = S.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // ─── Solid black background ───
            Positioned.fill(
              child: Container(
                color: Colors.black,
              ),
            ),
            // ─── Subtle gold glow overlay ───
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _AmbientGlowPainter()),
              ),
            ),

            Column(
              children: [
                // ─── Header: back button + title ───
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      _BackButton(onTap: () => Navigator.pop(context)),
                      Expanded(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 44),
                            child: Text(
                              s.chooseRideType,
                              style: const TextStyle(
                                fontFamily: 'Poppins',
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const Spacer(flex: 2),

                // ─── Airport card ───
                _StaggeredEntry(
                  controller: _entryCtl,
                  delay: 0.0,
                  child: _RideTypeCard(
                    floatController: _floatCtl,
                    floatPhase: 0,
                    imageAsset: 'assets/images/ride_type_airport.png',
                    title: s.airportLabel,
                    subtitle: s.airportSubtitle,
                    onTap: () => Navigator.pop(context, 'airport'),
                  ),
                ),

                const SizedBox(height: 32),

                // ─── Schedule card — render the PNG as-is (no overlay) ───
                _StaggeredEntry(
                  controller: _entryCtl,
                  delay: 0.18,
                  child: _RideTypeCard(
                    floatController: _floatCtl,
                    floatPhase: math.pi,
                    imageAsset: 'assets/images/ride_type_schedule.png',
                    title: s.schedule,
                    subtitle: s.scheduleSubtitle,
                    onTap: () => Navigator.pop(context, 'schedule'),
                  ),
                ),

                const Spacer(flex: 3),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Back button (circular, glass-morph)
// ═══════════════════════════════════════════════════════════════════

class _BackButton extends StatelessWidget {
  final VoidCallback onTap;
  const _BackButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
              width: 1,
            ),
          ),
          child: const Icon(
            Icons.arrow_back_rounded,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Entry animation — fade + slide up, with stagger delay
// ═══════════════════════════════════════════════════════════════════

class _StaggeredEntry extends StatelessWidget {
  final AnimationController controller;
  final double delay; // 0.0 – 1.0 — fraction of the total duration
  final Widget child;

  const _StaggeredEntry({
    required this.controller,
    required this.delay,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final anim = CurvedAnimation(
      parent: controller,
      curve: Interval(delay, 1.0, curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (_, c) {
        return Opacity(
          opacity: anim.value,
          child: Transform.translate(
            offset: Offset(0, 28 * (1 - anim.value)),
            child: c,
          ),
        );
      },
      child: child,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Ride type card — image + title + subtitle + gold badge
// ═══════════════════════════════════════════════════════════════════

class _RideTypeCard extends StatefulWidget {
  final AnimationController floatController;
  final double floatPhase; // radians — offset the sine wave per card
  final String imageAsset;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _RideTypeCard({
    required this.floatController,
    required this.floatPhase,
    required this.imageAsset,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  State<_RideTypeCard> createState() => _RideTypeCardState();
}

class _RideTypeCardState extends State<_RideTypeCard> {
  bool _pressed = false;

  void _onTapDown(TapDownDetails _) {
    setState(() => _pressed = true);
  }

  void _onTapCancel() {
    setState(() => _pressed = false);
  }

  void _onTapUp(TapUpDetails _) {
    setState(() => _pressed = false);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    // Tarjeta cuadrada estilo web - fondo oscuro, borde dorado sutil
    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedBuilder(
        animation: widget.floatController,
        builder: (_, __) {
          final floatT = math.sin(
              widget.floatController.value * 2 * math.pi + widget.floatPhase);
          // ±3 px vertical float (idle breathing)
          final dy = 3.0 * floatT;

          return AnimatedScale(
            scale: _pressed ? 0.97 : 1.0,
            duration: const Duration(milliseconds: 130),
            child: AnimatedOpacity(
              opacity: _pressed ? 0.85 : 1.0,
              duration: const Duration(milliseconds: 130),
              child: Transform.translate(
                offset: Offset(0, dy),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Tarjeta cuadrada con imagen
                    Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1F),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: const Color(0xFFE8C547).withValues(alpha: 0.3),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFE8C547).withValues(alpha: 0.1),
                            blurRadius: 20,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Image.asset(
                          widget.imageAsset,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Título con glow dorado
                    Text(
                      widget.title,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        shadows: [
                          Shadow(
                            color: Color(0xFFE8C547),
                            blurRadius: 20,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Subtítulo en gris
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 200),
                      child: Text(
                        widget.subtitle,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Ambient background gold glow — very subtle, behind everything
// ═══════════════════════════════════════════════════════════════════

class _AmbientGlowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFE8C547).withValues(alpha: 0.08),
          Colors.transparent,
        ],
        stops: const [0.0, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_) => false;
}
