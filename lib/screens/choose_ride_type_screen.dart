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
    final now = DateTime.now();

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
                    imageBuilder: (img) => img,
                    badgeIcon: Icons.arrow_forward_rounded,
                    title: s.airportLabel,
                    subtitle: s.airportSubtitle,
                    onTap: () => Navigator.pop(context, 'airport'),
                  ),
                ),

                const SizedBox(height: 32),

                // ─── Schedule card (with dynamic date overlay) ───
                _StaggeredEntry(
                  controller: _entryCtl,
                  delay: 0.18,
                  child: _RideTypeCard(
                    floatController: _floatCtl,
                    floatPhase: math.pi,
                    imageAsset: 'assets/images/ride_type_schedule.png',
                    imageBuilder: (img) => _CalendarImageWithDate(
                      base: img,
                      date: now,
                    ),
                    badgeIcon: Icons.access_time_rounded,
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
  final Widget Function(Widget image) imageBuilder;
  final IconData badgeIcon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _RideTypeCard({
    required this.floatController,
    required this.floatPhase,
    required this.imageAsset,
    required this.imageBuilder,
    required this.badgeIcon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  State<_RideTypeCard> createState() => _RideTypeCardState();
}

class _RideTypeCardState extends State<_RideTypeCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pressCtl;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _pressCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      value: 1.0,
    );
  }

  @override
  void dispose() {
    _pressCtl.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    _pressCtl.animateTo(0.94, curve: Curves.easeOut);
    setState(() => _pressed = true);
  }

  void _onTapCancel() {
    _pressCtl.animateTo(1.0, curve: Curves.easeOut);
    setState(() => _pressed = false);
  }

  void _onTapUp(TapUpDetails _) {
    _pressCtl.animateTo(1.0, curve: Curves.easeOut);
    setState(() => _pressed = false);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedBuilder(
        animation: Listenable.merge([widget.floatController, _pressCtl]),
        builder: (_, __) {
          final floatT =
              math.sin(widget.floatController.value * 2 * math.pi +
                  widget.floatPhase);
          // ±3 px vertical float
          final dy = 3.0 * floatT;
          final scale = _pressCtl.value;

          return Transform.scale(
            scale: scale,
            child: Column(
              children: [
                // ─── Image block (132×132) with gold badge & float ───
                Transform.translate(
                  offset: Offset(0, dy),
                  child: _buildImageBlock(),
                ),
                const SizedBox(height: 14),
                // ─── Title ───
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 6),
                // ─── Subtitle ───
                Text(
                  widget.subtitle,
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildImageBlock() {
    const dim = 132.0;
    return SizedBox(
      width: dim + 16,
      height: dim + 16,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Glow behind the image (intensifies on press)
          AnimatedOpacity(
            opacity: _pressed ? 0.55 : 0.30,
            duration: const Duration(milliseconds: 220),
            child: Container(
              width: dim + 10,
              height: dim + 10,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x40E8C547),
                    blurRadius: 32,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ),
          // Card itself
          Container(
            width: dim,
            height: dim,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1A1A1A), Color(0xFF0B0B0B)],
              ),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                color: _pressed
                    ? const Color(0xFFE8C547).withValues(alpha: 0.55)
                    : Colors.white.withValues(alpha: 0.06),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: widget.imageBuilder(
                Image.asset(widget.imageAsset, fit: BoxFit.contain),
              ),
            ),
          ),
          // Gold badge (top-right)
          Positioned(
            top: 4,
            right: 4,
            child: _GoldBadge(icon: widget.badgeIcon),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Gold circular badge with shadow (top-right corner)
// ═══════════════════════════════════════════════════════════════════

class _GoldBadge extends StatelessWidget {
  final IconData icon;
  const _GoldBadge({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF5DC7A), Color(0xFFE8C547), Color(0xFFB08800)],
        ),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x66E8C547),
            blurRadius: 10,
            spreadRadius: 1,
          ),
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.black87, size: 16),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Calendar image with dynamic month+day overlay
//  The PNG shows "APR 17" — we cover that region and draw today's
//  month and day on top so the card always reflects the current date.
// ═══════════════════════════════════════════════════════════════════

class _CalendarImageWithDate extends StatelessWidget {
  final Widget base;
  final DateTime date;
  const _CalendarImageWithDate({required this.base, required this.date});

  static const _months = [
    'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
    'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
  ];

  @override
  Widget build(BuildContext context) {
    final month = _months[date.month - 1];
    final day = date.day.toString();

    return LayoutBuilder(
      builder: (_, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        // The PNG has a dark top strip (~24% of height) where "APR" sits,
        // and the big white area below shows "17". We re-render both so
        // they stay in sync with the current date.
        return Stack(
          alignment: Alignment.center,
          children: [
            // Base calendar PNG
            Positioned.fill(child: base),

            // Month label — covers the "APR" strip on the PNG
            Positioned(
              top: h * 0.15,
              left: w * 0.12,
              child: Text(
                month,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  height: 1.0,
                  shadows: [
                    Shadow(color: Colors.black, blurRadius: 0.5),
                  ],
                ),
              ),
            ),

            // Day number — sits over the "17" on the PNG
            Positioned(
              top: h * 0.48,
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  day,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: Color(0xFF1A1A1A),
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          ],
        );
      },
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
