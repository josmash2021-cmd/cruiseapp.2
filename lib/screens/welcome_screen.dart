import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../widgets/neu_style.dart';
import 'rider_welcome_screen.dart';
import 'driver/driver_welcome_screen.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  late AnimationController _ctrl;
  late Animation<double> _introFade;
  late Animation<Offset> _introSlide;
  late Animation<double> _headFade;
  late Animation<Offset> _headSlide;
  late Animation<double> _tagFade;
  late Animation<Offset> _tagSlide;
  // Looping shine on the logo badge — independent, never stops.
  late AnimationController _logoCtrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _introFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
    );
    _introSlide = Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _ctrl,
            curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
          ),
        );
    // Headline rises in a beat after the lockup; the tagline floats in last.
    _headFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.22, 0.72, curve: Curves.easeOut),
    );
    _headSlide = Tween<Offset>(begin: const Offset(0, 0.22), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _ctrl,
            curve: const Interval(0.22, 0.72, curve: Curves.easeOutCubic),
          ),
        );
    _tagFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.42, 0.9, curve: Curves.easeOut),
    );
    _tagSlide = Tween<Offset>(begin: const Offset(0, 0.16), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _ctrl,
            curve: const Interval(0.42, 0.9, curve: Curves.easeOutCubic),
          ),
        );
    _logoCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat();

    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _logoCtrl.dispose();
    super.dispose();
  }

  Widget _decoLine(double width) {
    return Container(
      width: width,
      height: 0.8,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.transparent,
            _gold.withValues(alpha: 0.7),
            Colors.transparent,
          ],
        ),
      ),
    );
  }

  Widget _diamond() {
    return Transform.rotate(
      angle: 0.785398,
      child: Container(
        width: 5,
        height: 5,
        decoration: BoxDecoration(
          color: _gold.withValues(alpha: 0.8),
        ),
      ),
    );
  }

  /// The badge with its looping shine (user spec): a gold halo that
  /// breathes (sin pulse, seamless loop) plus a light band that sweeps
  /// across the circle once per 3.2 s cycle.
  Widget _buildLogoBadge() {
    return AnimatedBuilder(
      animation: _logoCtrl,
      builder: (context, child) {
        final t = _logoCtrl.value;
        final pulse = (math.sin(t * 2 * math.pi) + 1) / 2;
        final sweepOn = t < 0.45;
        final sweepT = sweepOn ? t / 0.45 : 1.0;
        return SizedBox(
          width: 64,
          height: 64,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      _gold.withValues(alpha: 0.16 + 0.20 * pulse),
                      _gold.withValues(alpha: 0.05 + 0.07 * pulse),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                ),
              ),
              ClipOval(
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Image.asset('assets/images/cruise_logo.png'),
                      ),
                      if (sweepOn)
                        Positioned(
                          left: -20 + 80 * sweepT,
                          top: -24,
                          child: Transform.rotate(
                            angle: -0.5,
                            child: Container(
                              width: 14,
                              height: 90,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.white.withValues(alpha: 0),
                                    Colors.white.withValues(alpha: 0.38),
                                    Colors.white.withValues(alpha: 0),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final media = MediaQuery.of(context);
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Background image (black SUV on golden backlight) ──
          // fitWidth, top-aligned — never cover: the render keeps its whole
          // frame (no side crop/zoom), the SUV ends above the buttons, and
          // the strip below continues the image's own dark floor tone.
          Positioned.fill(
            child: ColoredBox(
              color: const Color(0xFF33261A),
              child: Align(
                alignment: Alignment.topCenter,
                child: Image.asset(
                  'assets/images/welcome_bg_suv.png',
                  width: double.infinity,
                  fit: BoxFit.fitWidth,
                ),
              ),
            ),
          ),

          // ── Subtle dark overlay so the bottom controls stay readable ──
          // The lockup and headline are baked into the video itself, so the
          // middle barely dims; the floor area gets the real veil.
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.10),
                  Colors.black.withValues(alpha: 0.22),
                  Colors.black.withValues(alpha: 0.70),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),

          // ── Content ──
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                children: [
                  const SizedBox(height: 14),

                  // ── Lockup: badge + CRUISE, línea-diamante-línea ──
                  FadeTransition(
                    opacity: _introFade,
                    child: SlideTransition(
                      position: _introSlide,
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _buildLogoBadge(),
                              const SizedBox(width: 12),
                              Text(
                                'CRUISE',
                                style: GoogleFonts.playfairDisplay(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  letterSpacing: 2,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _decoLine(60),
                              const SizedBox(width: 10),
                              _diamond(),
                              const SizedBox(width: 10),
                              _decoLine(60),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  SizedBox(height: media.size.height * 0.15),

                  // ── Headline + tagline (dark over the golden glow) ──
                  FadeTransition(
                    opacity: _headFade,
                    child: SlideTransition(
                      position: _headSlide,
                      child: Text(
                        s.welcomeHeadline,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 34,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF1A1400),
                          height: 1.15,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FadeTransition(
                    opacity: _tagFade,
                    child: SlideTransition(
                      position: _tagSlide,
                      child: Text(
                        s.welcomeSubheadline,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 15,
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF1A1400),
                        ),
                      ),
                    ),
                  ),

                  const Spacer(),

                  // ── Role buttons (user spec 2026-09-17): Rider (person,
                  // gold) and Driver (car, dark) — one clear tap per role.
                  // The bottom controls render static — no entrance
                  // animation (user spec 2026-09-16).
                  _NeuPressButton(
                    label: S.of(context).rider,
                    gold: true,
                    icon: Icons.person_rounded,
                    onTap: () {
                      Navigator.of(context)
                          .push(slideUpFadeRoute(const RiderWelcomeScreen()));
                    },
                  ),

                  const SizedBox(height: 12),

                  _NeuPressButton(
                    label: S.of(context).driver,
                    gold: false,
                    icon: Icons.directions_car_rounded,
                    onTap: () {
                      Navigator.of(context).push(
                          onboardingFadeSlideRoute(const DriverWelcomeScreen()));
                    },
                  ),

                  const SizedBox(height: 28),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pill button with a neumorphic press effect.
/// [gold] = raised gold gradient (dark text); otherwise raised dark
/// neumorphic surface (white text). Pressing scales down and softens
/// the shadow (sunken feel). [icon] rides ahead of the label — the role
/// buttons read at a glance (person = rider, car = driver).
class _NeuPressButton extends StatefulWidget {
  final String label;
  final bool gold;
  final VoidCallback onTap;
  final IconData? icon;

  const _NeuPressButton({
    required this.label,
    required this.gold,
    required this.onTap,
    this.icon,
  });

  @override
  State<_NeuPressButton> createState() => _NeuPressButtonState();
}

class _NeuPressButtonState extends State<_NeuPressButton> {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5DC7A);
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final decoration = widget.gold
        ? BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: _pressed
                  ? const [Color(0xFFD9B53C), _gold]
                  : const [_goldLight, _gold],
            ),
            borderRadius: BorderRadius.circular(30),
            boxShadow: _pressed
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      offset: const Offset(2, 2),
                      blurRadius: 5,
                      spreadRadius: -2,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.55),
                      offset: const Offset(6, 6),
                      blurRadius: 14,
                    ),
                    BoxShadow(
                      color: _goldLight.withValues(alpha: 0.55),
                      offset: const Offset(-3, -3),
                      blurRadius: 8,
                    ),
                  ],
          )
        : neuBox(radius: 30, pressed: _pressed);

    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: double.infinity,
          height: 56,
          decoration: decoration,
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(
                  widget.icon,
                  size: 21,
                  color: widget.gold
                      ? const Color(0xFF1A1400)
                      : _gold,
                ),
                const SizedBox(width: 10),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: widget.gold ? 17 : 16,
                  fontWeight: widget.gold ? FontWeight.w700 : FontWeight.w600,
                  letterSpacing: 0.2,
                  color: widget.gold
                      ? const Color(0xFF1A1400)
                      : Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
