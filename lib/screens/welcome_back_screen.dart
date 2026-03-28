import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class WelcomeBackScreen extends StatefulWidget {
  const WelcomeBackScreen({
    super.key,
    required this.firstName,
    required this.destination,
  });

  final String firstName;
  final Widget destination;

  @override
  State<WelcomeBackScreen> createState() => _WelcomeBackScreenState();
}

class _WelcomeBackScreenState extends State<WelcomeBackScreen>
    with TickerProviderStateMixin {
  static const _bg = Color(0xFF000000);
  static const _gold = Color(0xFFE8C547);
  static const _goldBright = Color(0xFFFFF1C1);

  // ── Phase 1: Decorative lines fade in ──
  late AnimationController _decoCtrl;
  late Animation<double> _decoFade;

  // ── Phase 2: "WELCOME BACK" text fade + scale ──
  late AnimationController _titleCtrl;
  late Animation<double> _titleFade;
  late Animation<double> _titleScale;
  late Animation<double> _titleGlow;

  // ── Phase 3: User name fade in ──
  late AnimationController _nameCtrl;
  late Animation<double> _nameFade;

  // ── Phase 4: Everything fades out ──
  late AnimationController _exitCtrl;
  late Animation<double> _exitFade;

  bool _disposed = false;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: _bg,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    _setupAnimations();
    _runSequence();
  }

  void _setupAnimations() {
    // Deco: 600ms
    _decoCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _decoFade = CurvedAnimation(parent: _decoCtrl, curve: Curves.easeOut);

    // Title: 700ms
    _titleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _titleFade = CurvedAnimation(parent: _titleCtrl, curve: Curves.easeOut);
    _titleScale = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _titleCtrl, curve: Curves.easeOut),
    );
    _titleGlow = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _titleCtrl, curve: Curves.easeIn),
    );

    // Name: 600ms
    _nameCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _nameFade = CurvedAnimation(parent: _nameCtrl, curve: Curves.easeOut);

    // Exit: 600ms
    _exitCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _exitFade = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _exitCtrl, curve: Curves.easeInQuart),
    );
  }

  Future<void> _runSequence() async {
    // Step 1: start black
    await Future.delayed(const Duration(milliseconds: 300));
    if (_disposed || !mounted) return;

    // Step 2: deco lines fade in
    await _decoCtrl.forward().orCancel.catchError((_) {});
    if (_disposed || !mounted) return;

    // Step 3: title fades in (overlapping — starts 300ms after deco starts,
    // but deco is already done at 600ms, so this runs immediately)
    await _titleCtrl.forward().orCancel.catchError((_) {});
    if (_disposed || !mounted) return;

    // Step 4: name fades in with slight overlap
    await Future.delayed(const Duration(milliseconds: 200));
    if (_disposed || !mounted) return;
    await _nameCtrl.forward().orCancel.catchError((_) {});
    if (_disposed || !mounted) return;

    // Step 5: hold
    await Future.delayed(const Duration(milliseconds: 600));
    if (_disposed || !mounted) return;

    // Step 6: fade out everything
    _exitCtrl.forward().orCancel.catchError((_) {});
    await Future.delayed(const Duration(milliseconds: 50));
    if (_disposed || !mounted) return;

    // Step 7: navigate to home
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => widget.destination,
        transitionDuration: const Duration(milliseconds: 600),
        reverseTransitionDuration: Duration.zero,
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeIn),
          child: child,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _decoCtrl.dispose();
    _titleCtrl.dispose();
    _nameCtrl.dispose();
    _exitCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: AnimatedBuilder(
        animation: Listenable.merge([_decoCtrl, _titleCtrl, _nameCtrl, _exitCtrl]),
        builder: (context, _) {
          return Opacity(
            opacity: _exitFade.value,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ── Background radial glow ──
                Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 0.75,
                      colors: [
                        Color.lerp(
                          const Color(0xFF1A1500),
                          const Color(0xFF0A0900),
                          1 - _titleGlow.value * 0.6,
                        )!,
                        _bg,
                      ],
                      stops: const [0.0, 1.0],
                    ),
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ── Top decorative line ──
                      Opacity(
                        opacity: _decoFade.value,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildDecoLine(60),
                            const SizedBox(width: 10),
                            _buildDiamond(),
                            const SizedBox(width: 10),
                            _buildDecoLine(60),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // ── "WELCOME BACK" ──
                      Opacity(
                        opacity: _titleFade.value,
                        child: Transform.scale(
                          scale: _titleScale.value,
                          child: _buildTitleText(),
                        ),
                      ),
                      const SizedBox(height: 8),

                      // ── User's name ──
                      Opacity(
                        opacity: _nameFade.value,
                        child: Text(
                          widget.firstName.toUpperCase(),
                          style: GoogleFonts.cinzel(
                            fontSize: 11,
                            fontWeight: FontWeight.w400,
                            color: _gold.withValues(alpha: 0.7),
                            letterSpacing: 6,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),

                      // ── Bottom decorative line ──
                      Opacity(
                        opacity: _decoFade.value,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildDecoLine(60),
                            const SizedBox(width: 10),
                            _buildDiamond(),
                            const SizedBox(width: 10),
                            _buildDecoLine(60),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTitleText() {
    final glowIntensity = _titleGlow.value;
    final glowColor = Color.lerp(_gold, _goldBright, glowIntensity)!;

    return ShaderMask(
      shaderCallback: (bounds) {
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _goldBright,
            glowColor,
            _gold,
          ],
          stops: const [0.0, 0.4, 1.0],
        ).createShader(bounds);
      },
      child: Text(
        'WELCOME  BACK',
        style: GoogleFonts.cinzel(
          fontSize: 38,
          fontWeight: FontWeight.w900,
          color: Colors.white,
          letterSpacing: 6,
          shadows: [
            Shadow(
              color: _gold.withValues(alpha: 0.5 + glowIntensity * 0.5),
              blurRadius: 20 + glowIntensity * 40,
            ),
            Shadow(
              color: _goldBright.withValues(alpha: glowIntensity * 0.4),
              blurRadius: 50,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDecoLine(double width) {
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

  Widget _buildDiamond() {
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
}
