import 'package:flutter/gestures.dart';
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
  late Animation<double> _btnFade;
  late Animation<Offset> _btnSlide;
  late Animation<double> _introFade;
  late Animation<Offset> _introSlide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _btnFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.55, 1.0, curve: Curves.easeOut),
    );
    _btnSlide = Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _ctrl,
            curve: const Interval(0.55, 1.0, curve: Curves.easeOutCubic),
          ),
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

    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
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
                              Image.asset(
                                'assets/images/cruise_logo.png',
                                width: 42,
                                height: 42,
                              ),
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
                    opacity: _introFade,
                    child: SlideTransition(
                      position: _introSlide,
                      child: Column(
                        children: [
                          Text(
                            s.welcomeHeadline,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.playfairDisplay(
                              fontSize: 34,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF1A1400),
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            s.welcomeSubheadline,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.playfairDisplay(
                              fontSize: 15,
                              fontStyle: FontStyle.italic,
                              fontWeight: FontWeight.w500,
                              color: const Color(0xFF1A1400),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const Spacer(),

                  // ── Get started button (gold neumorphic) ──
                  SlideTransition(
                    position: _btnSlide,
                    child: FadeTransition(
                      opacity: _btnFade,
                      child: _NeuPressButton(
                        label: S.of(context).getStarted,
                        gold: true,
                        onTap: () {
                          Navigator.of(context)
                              .push(slideUpFadeRoute(const RiderWelcomeScreen()));
                        },
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── Already have account? button (dark neumorphic) ──
                  SlideTransition(
                    position: _btnSlide,
                    child: FadeTransition(
                      opacity: _btnFade,
                      child: _NeuPressButton(
                        label: S.of(context).alreadyHaveAccount,
                        gold: false,
                        onTap: () {
                          Navigator.of(context).push(
                              slideUpFadeRoute(const RiderWelcomeScreen()));
                        },
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ── Want to drive? Sign up to drive (text link) ──
                  FadeTransition(
                    opacity: _btnFade,
                    child: GestureDetector(
                      child: RichText(
                        text: TextSpan(
                          style: const TextStyle(fontSize: 14, color: Colors.white54),
                          children: [
                            const TextSpan(text: 'Want to drive? '),
                            TextSpan(
                              text: 'Sign up to drive',
                              style: TextStyle(
                                color: _gold,
                                fontWeight: FontWeight.w700,
                              ),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () => Navigator.of(context).push(
                                      onboardingFadeSlideRoute(const DriverWelcomeScreen()),
                                    ),
                            ),
                            const TextSpan(text: ' or '),
                            TextSpan(
                              text: 'Sign in',
                              style: TextStyle(
                                color: _gold,
                                fontWeight: FontWeight.w700,
                              ),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () => Navigator.of(context).push(
                                      onboardingFadeSlideRoute(const DriverWelcomeScreen()),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
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
/// the shadow (sunken feel).
class _NeuPressButton extends StatefulWidget {
  final String label;
  final bool gold;
  final VoidCallback onTap;

  const _NeuPressButton({
    required this.label,
    required this.gold,
    required this.onTap,
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
          child: Text(
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
        ),
      ),
    );
  }
}
