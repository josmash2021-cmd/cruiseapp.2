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
      backgroundColor: c.bg,
      body: SafeArea(
        child: Stack(
          children: [
            // ─── Ambient gold glow behind content ───
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
    // .vipRide__laterCard--v
    //   display:flex; flex-direction:column; align-items:center;
    //   justify-content:center; text-align:center;
    //   gap:10px; padding:10px 16px;
    //   border-radius:22px; background:transparent; border:none;
    //   :active { transform: scale(.97); opacity: .85; }
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
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // .vipRide__laterCard__icon
                    //   width:112; height:112; border-radius:26;
                    //   background:transparent; overflow:hidden;
                    Transform.translate(
                      offset: Offset(0, dy),
                      child: _buildImageBlock(),
                    ),
                    const SizedBox(height: 10),
                    // .vipRide__laterCard__title
                    //   font-family: Poppins;
                    //   font-size: 22; font-weight: 700; color: #fff;
                    //   letter-spacing: -.025em; line-height: 1.2;
                    //   text-shadow:
                    //     0 0 14px rgba(232,197,71,.55),
                    //     0 2px 6px rgba(232,197,71,.35)
                    Text(
                      widget.title,
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.55,
                        height: 1.2,
                        shadows: [
                          Shadow(
                            color: Color(0x8CE8C547),
                            blurRadius: 14,
                          ),
                          Shadow(
                            color: Color(0x59E8C547),
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    // .vipRide__laterCard__sub
                    //   font-size: 13; color: rgba(255,255,255,.5);
                    //   line-height: 1.45; max-width: 240; font-weight: 400;
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: Text(
                        widget.subtitle,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          height: 1.45,
                          letterSpacing: 0.065,
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

  Widget _buildImageBlock() {
    // 112×112 transparent container, radius 26, overflow hidden.
    const dim = 112.0;
    return SizedBox(
      width: dim,
      height: dim,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: Image.asset(
          widget.imageAsset,
          fit: BoxFit.contain,
          width: dim,
          height: dim,
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
