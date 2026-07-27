import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/neu_style.dart';

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
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _entryCtl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _entryCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    )..forward();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _entryCtl.stop();
    } else if (state == AppLifecycleState.resumed) {
      if (!_entryCtl.isCompleted) _entryCtl.forward();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _entryCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = S.of(context);

    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
        child: Stack(
          children: [
            // ─── Solid neumorphic base background ───
            Positioned.fill(
              child: Container(
                color: neuBase,
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
                    imageAsset: 'assets/airport/airport_takeoff.png',
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
    // Pressed neumorphic circle (same language as the other back buttons).
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 40,
          height: 40,
          decoration: neuBox(radius: 14, pressed: true),
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
  final String imageAsset;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _RideTypeCard({
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
    // Tarjeta cuadrada estilo web - superficie neumórfica, badge dorado
    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 130),
        child: AnimatedOpacity(
          opacity: _pressed ? 0.85 : 1.0,
          duration: const Duration(milliseconds: 130),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Tarjeta cuadrada con imagen + gold arrow badge
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 140,
                    height: 140,
                    decoration: neuBox(radius: 24),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Image.asset(
                          widget.imageAsset,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                        // Gold arrow badge - top right
                        Positioned(
                          top: -6,
                          right: -6,
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: const Color(0xFFE8C547),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.black,
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFE8C547).withValues(alpha: 0.4),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.arrow_forward_rounded,
                              color: Colors.black,
                              size: 16,
                            ),
                          ),
                        ),
                      ],
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
