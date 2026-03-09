import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../l10n/app_localizations.dart';
import 'package:video_player/video_player.dart';
import '../config/page_transitions.dart';
import 'login_screen.dart';
import 'login_password_screen.dart';
import 'driver/driver_login_screen.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  late AnimationController _ctrl;
  late Animation<double> _logoFade;
  late Animation<double> _textFade;
  late Animation<double> _btnFade;
  late Animation<Offset> _btnSlide;

  late VideoPlayerController _videoCtrl;
  bool _videoReady = false;
  double _videoW = 0;
  double _videoH = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _logoFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
    );
    _textFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.3, 0.65, curve: Curves.easeOut),
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

    _ctrl.forward();

    // Initialise background video (lightweight, no audio track)
    _videoCtrl =
        VideoPlayerController.asset(
            'assets/images/welcome_bg.mp4',
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
          )
          ..setLooping(true)
          ..setVolume(0)
          ..initialize().then((_) {
            if (mounted) {
              _videoW = _videoCtrl.value.size.width;
              _videoH = _videoCtrl.value.size.height;
              setState(() => _videoReady = true);
              _videoCtrl.play();
            }
          });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _videoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Video background ──
          if (_videoReady)
            RepaintBoundary(
              child: SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _videoW,
                    height: _videoH,
                    child: VideoPlayer(_videoCtrl),
                  ),
                ),
              ),
            )
          else
            // Fallback while video loads
            Container(color: const Color(0xFF0A0B10)),

          // ── Subtle dark overlay so text is readable ──
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.15),
                  Colors.black.withValues(alpha: 0.30),
                  Colors.black.withValues(alpha: 0.65),
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 32),

                  // Logo
                  FadeTransition(
                    opacity: _logoFade,
                    child: RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: 'Cruise',
                            style: GoogleFonts.cinzel(
                              fontSize: 34,
                              fontWeight: FontWeight.w900,
                              color: _gold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const Spacer(),

                  // Main text
                  FadeTransition(
                    opacity: _textFade,
                    child: Text(
                      S.of(context).welcomeHeadline,
                      style: TextStyle(
                        fontSize: 44,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.1,
                        letterSpacing: -1,
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  FadeTransition(
                    opacity: _textFade,
                    child: Text(
                      S.of(context).welcomeSubheadline,
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.white70,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),

                  const SizedBox(height: 36),

                  // Get started button
                  SlideTransition(
                    position: _btnSlide,
                    child: FadeTransition(
                      opacity: _btnFade,
                      child: SizedBox(
                        width: double.infinity,
                        height: 58,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _gold,
                            foregroundColor: const Color(0xFF1A1400),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(30),
                            ),
                            shadowColor: _gold.withValues(alpha: 0.3),
                          ),
                          onPressed: () {
                            Navigator.of(
                              context,
                            ).push(slideUpFadeRoute(const LoginScreen()));
                          },
                          child: Text(
                            S.of(context).getStarted,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── Already have an account? ──
                  FadeTransition(
                    opacity: _btnFade,
                    child: Center(
                      child: GestureDetector(
                        onTap: () {
                          Navigator.of(
                            context,
                          ).push(slideUpFadeRoute(const LoginPasswordScreen()));
                        },
                        child: RichText(
                          text: TextSpan(
                            text: '${S.of(context).alreadyHaveAccount} ',
                            style: TextStyle(
                              fontSize: 15,
                              color: Colors.white60,
                            ),
                            children: [
                              TextSpan(
                                text: S.of(context).signIn,
                                style: TextStyle(
                                  color: _gold,
                                  fontWeight: FontWeight.w700,
                                  decoration: TextDecoration.underline,
                                  decorationColor: _gold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ── Drive with Cruise ──
                  FadeTransition(
                    opacity: _btnFade,
                    child: Center(
                      child: GestureDetector(
                        onTap: () {
                          Navigator.of(
                            context,
                          ).push(slideUpFadeRoute(const DriverLoginScreen()));
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white24, width: 1),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.directions_car_filled_rounded,
                                color: _gold,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text.rich(
                                TextSpan(
                                  text: 'Want to drive? ',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.white60,
                                  ),
                                  children: const [
                                    TextSpan(
                                      text: 'Sign up to drive',
                                      style: TextStyle(
                                        color: _gold,
                                        fontWeight: FontWeight.w700,
                                        decoration: TextDecoration.underline,
                                        decorationColor: _gold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
