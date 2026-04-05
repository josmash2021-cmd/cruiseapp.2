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
                children: [
                  const SizedBox(height: 36),

                  // ── CRUISE title (centered) ──
                  FadeTransition(
                    opacity: _logoFade,
                    child: Text(
                      'CRUISE',
                      style: GoogleFonts.cinzel(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        color: _gold,
                        letterSpacing: 8,
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── Gold diamond separator (centered) ──
                  FadeTransition(
                    opacity: _logoFade,
                    child: SizedBox(
                      width: 200,
                      height: 14,
                      child: CustomPaint(painter: _DiamondSeparatorPainter()),
                    ),
                  ),

                  const Spacer(flex: 2),

                  // ── Headline (centered) ──
                  FadeTransition(
                    opacity: _textFade,
                    child: Text(
                      S.of(context).welcomeHeadline,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.1,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),

                  // ── Subheadline (small, centered) ──
                  FadeTransition(
                    opacity: _textFade,
                    child: Text(
                      S.of(context).welcomeSubheadline,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white60,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),

                  const Spacer(flex: 2),

                  // ── Get started button (gold filled) ──
                  SlideTransition(
                    position: _btnSlide,
                    child: FadeTransition(
                      opacity: _btnFade,
                      child: SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _gold,
                            foregroundColor: const Color(0xFF1A1400),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(30),
                            ),
                          ),
                          onPressed: () {
                            Navigator.of(context)
                                .push(slideUpFadeRoute(const LoginScreen()));
                          },
                          child: Text(
                            S.of(context).getStarted,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── Already have account? button (outlined) ──
                  SlideTransition(
                    position: _btnSlide,
                    child: FadeTransition(
                      opacity: _btnFade,
                      child: SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(color: Colors.white.withValues(alpha: 0.3), width: 1.2),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(30),
                            ),
                          ),
                          onPressed: () {
                            Navigator.of(context)
                                .push(slideUpFadeRoute(const LoginPasswordScreen()));
                          },
                          child: Text(
                            S.of(context).alreadyHaveAccount,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ── Want to drive? Sign up to drive (text link) ──
                  FadeTransition(
                    opacity: _btnFade,
                    child: GestureDetector(
                      onTap: () {
                        Navigator.of(context)
                            .push(slideUpFadeRoute(const DriverLoginScreen()));
                      },
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

/// Gold line with centered diamond shape — matches foto 3 separator.
class _DiamondSeparatorPainter extends CustomPainter {
  static const _gold = Color(0xFFE8C547);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _gold.withValues(alpha: 0.6)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final cy = size.height / 2;
    final cx = size.width / 2;
    const diamondSize = 5.0;

    // Left line
    canvas.drawLine(Offset(0, cy), Offset(cx - diamondSize - 6, cy), paint);
    // Right line
    canvas.drawLine(Offset(cx + diamondSize + 6, cy), Offset(size.width, cy), paint);

    // Diamond (filled)
    final diamondPaint = Paint()
      ..color = _gold
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(cx, cy - diamondSize)
      ..lineTo(cx + diamondSize, cy)
      ..lineTo(cx, cy + diamondSize)
      ..lineTo(cx - diamondSize, cy)
      ..close();
    canvas.drawPath(path, diamondPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
