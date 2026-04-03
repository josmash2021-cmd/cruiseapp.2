import 'dart:math' as math;
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
  static const _bg = Color(0xFF080604);
  static const _gold = Color(0xFFD4A843);
  static const _goldLight = Color(0xFFE8C547);
  static const _goldBright = Color(0xFFFFF1C1);

  // Phase 1: Background glow
  late AnimationController _glowCtrl;
  late Animation<double> _glowFade;

  // Phase 2: "WELCOME BACK" text
  late AnimationController _titleCtrl;
  late Animation<double> _titleFade;
  late Animation<double> _titleScale;

  // Phase 3: Decorative lines
  late AnimationController _decoCtrl;
  late Animation<double> _decoFade;
  late Animation<double> _decoWidth;

  // Phase 4: User's name
  late AnimationController _nameCtrl;
  late Animation<double> _nameFade;
  late Animation<Offset> _nameSlide;

  // Phase 5: Exit
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
    // Background glow: 800ms
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _glowFade = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeOut);

    // Title: 800ms
    _titleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _titleFade = CurvedAnimation(parent: _titleCtrl, curve: Curves.easeOut);
    _titleScale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _titleCtrl, curve: Curves.easeOutCubic),
    );

    // Deco lines: 500ms
    _decoCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _decoFade = CurvedAnimation(parent: _decoCtrl, curve: Curves.easeOut);
    _decoWidth = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _decoCtrl, curve: Curves.easeOutCubic),
    );

    // Name: 700ms
    _nameCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _nameFade = CurvedAnimation(parent: _nameCtrl, curve: Curves.easeOut);
    _nameSlide = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _nameCtrl, curve: Curves.easeOutCubic));

    // Exit: 700ms
    _exitCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _exitFade = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _exitCtrl, curve: Curves.easeInQuart),
    );
  }

  Future<void> _runSequence() async {
    await Future.delayed(const Duration(milliseconds: 250));
    if (_disposed || !mounted) return;

    // Glow appears
    _glowCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 300));
    if (_disposed || !mounted) return;

    // Title fades in
    _titleCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 500));
    if (_disposed || !mounted) return;

    // Deco lines expand
    _decoCtrl.forward();
    await Future.delayed(const Duration(milliseconds: 350));
    if (_disposed || !mounted) return;

    // Name slides up
    await _nameCtrl.forward().orCancel.catchError((_) {});
    if (_disposed || !mounted) return;

    // Hold
    await Future.delayed(const Duration(milliseconds: 900));
    if (_disposed || !mounted) return;

    // Fade out — wait for exit animation to finish before navigating
    await _exitCtrl.forward().orCancel.catchError((_) {});
    if (_disposed || !mounted) return;

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
    _glowCtrl.dispose();
    _titleCtrl.dispose();
    _decoCtrl.dispose();
    _nameCtrl.dispose();
    _exitCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: _bg,
      body: AnimatedBuilder(
        animation: Listenable.merge([
          _glowCtrl, _titleCtrl, _decoCtrl, _nameCtrl, _exitCtrl,
        ]),
        builder: (context, _) {
          return Opacity(
            opacity: _exitFade.value,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ── Background radial glow ──
                Opacity(
                  opacity: _glowFade.value,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment(0, -0.05),
                        radius: 0.65,
                        colors: [
                          Color(0xFF1C1508),
                          Color(0xFF0E0B04),
                          _bg,
                        ],
                        stops: [0.0, 0.5, 1.0],
                      ),
                    ),
                  ),
                ),
                // ── Content ──
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // ── Top decorative accent ──
                        Opacity(
                          opacity: _decoFade.value,
                          child: _buildTopAccent(screenWidth),
                        ),
                        const SizedBox(height: 28),

                        // ── "WELCOME" ──
                        Opacity(
                          opacity: _titleFade.value,
                          child: Transform.scale(
                            scale: _titleScale.value,
                            child: _buildGoldText(
                              'WELCOME',
                              fontSize: 32,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 10,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),

                        // ── "BACK" ──
                        Opacity(
                          opacity: _titleFade.value,
                          child: Transform.scale(
                            scale: _titleScale.value,
                            child: _buildGoldText(
                              'BACK',
                              fontSize: 32,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 14,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),

                        // ── Center divider line ──
                        Opacity(
                          opacity: _decoFade.value,
                          child: _buildDividerLine(
                            math.min(screenWidth * 0.45, 180) * _decoWidth.value,
                          ),
                        ),
                        const SizedBox(height: 20),

                        // ── User's name ──
                        SlideTransition(
                          position: _nameSlide,
                          child: Opacity(
                            opacity: _nameFade.value,
                            child: Text(
                              widget.firstName.toUpperCase(),
                              textAlign: TextAlign.center,
                              style: GoogleFonts.cormorantGaramond(
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                                color: _goldBright.withValues(alpha: 0.9),
                                letterSpacing: 8,
                                height: 1.2,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── Bottom decorative accent ──
                        Opacity(
                          opacity: _decoFade.value,
                          child: _buildBottomAccent(screenWidth),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Gold shimmer text with glow shadow
  Widget _buildGoldText(
    String text, {
    required double fontSize,
    required FontWeight fontWeight,
    required double letterSpacing,
  }) {
    final glow = _titleFade.value;
    return ShaderMask(
      shaderCallback: (bounds) {
        return LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _goldBright,
            _goldLight,
            _gold,
            _goldLight,
          ],
          stops: const [0.0, 0.3, 0.7, 1.0],
        ).createShader(bounds);
      },
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: GoogleFonts.cinzel(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: Colors.white,
          letterSpacing: letterSpacing,
          shadows: [
            Shadow(
              color: _gold.withValues(alpha: 0.4 + glow * 0.3),
              blurRadius: 16 + glow * 24,
            ),
            Shadow(
              color: _goldBright.withValues(alpha: glow * 0.15),
              blurRadius: 40,
            ),
          ],
        ),
      ),
    );
  }

  /// Top accent: thin lines expanding from a center diamond
  Widget _buildTopAccent(double screenWidth) {
    final w = math.min(screenWidth * 0.3, 100.0) * _decoWidth.value;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDecoLine(w),
        const SizedBox(width: 12),
        _buildDiamond(4),
        const SizedBox(width: 12),
        _buildDecoLine(w),
      ],
    );
  }

  /// Bottom accent: mirrored thin lines
  Widget _buildBottomAccent(double screenWidth) {
    final w = math.min(screenWidth * 0.3, 100.0) * _decoWidth.value;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDecoLine(w),
        const SizedBox(width: 12),
        _buildDiamond(4),
        const SizedBox(width: 12),
        _buildDecoLine(w),
      ],
    );
  }

  /// Horizontal gold gradient line
  Widget _buildDividerLine(double width) {
    return Container(
      width: width,
      height: 0.6,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.transparent,
            _gold.withValues(alpha: 0.5),
            _goldLight.withValues(alpha: 0.8),
            _gold.withValues(alpha: 0.5),
            Colors.transparent,
          ],
          stops: const [0.0, 0.2, 0.5, 0.8, 1.0],
        ),
      ),
    );
  }

  Widget _buildDecoLine(double width) {
    return Container(
      width: width,
      height: 0.6,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.transparent,
            _gold.withValues(alpha: 0.6),
            Colors.transparent,
          ],
        ),
      ),
    );
  }

  Widget _buildDiamond(double size) {
    return Transform.rotate(
      angle: 0.785398,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: _gold.withValues(alpha: 0.7),
          boxShadow: [
            BoxShadow(
              color: _gold.withValues(alpha: 0.3),
              blurRadius: 6,
            ),
          ],
        ),
      ),
    );
  }
}
