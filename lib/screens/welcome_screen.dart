import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
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

class _WelcomeScreenState extends State<WelcomeScreen> {
  static const _gold = Color(0xFFE8C547);

  // CRUISE car clip, looping muted behind the controls (user spec
  // 2026-09-19). The lockup and headline are baked into the video itself —
  // the only overlay UI is the two role buttons. The static SUV frame stays
  // underneath as the boot frame and fallback if the clip ever fails.
  VideoPlayerController? _video;
  bool _videoReady = false;

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      final c = VideoPlayerController.asset('assets/videos/welcome_bg.mp4');
      _video = c;
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(0);
      if (!mounted) return;
      setState(() => _videoReady = true);
      c.play();
    } catch (_) {
      // No clip — the static SUV frame stays as the background.
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Background frame (static, instant) — the video covers it as
          // soon as the first frame decodes. fitWidth, top-aligned — never
          // cover: the render keeps its whole frame (no side crop/zoom).
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
          if (_videoReady && _video != null)
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _video!.value.size.width,
                  height: _video!.value.size.height,
                  child: VideoPlayer(_video!),
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

          // ── Role buttons (user spec 2026-09-17): Pasajero (person, gold)
          // and Conductor (steering wheel, dark) — the icon rides LEFT of
          // the label (user spec 2026-09-19). The bottom controls render
          // static — no entrance animation (user spec 2026-09-16).
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                children: [
                  const Spacer(),

                  _NeuPressButton(
                    label: S.of(context).rider,
                    gold: true,
                    leading: const Icon(
                      Icons.person_rounded,
                      size: 21,
                      color: Color(0xFF1A1400),
                    ),
                    onTap: () {
                      Navigator.of(context)
                          .push(slideUpFadeRoute(const RiderWelcomeScreen()));
                    },
                  ),

                  const SizedBox(height: 12),

                  _NeuPressButton(
                    label: S.of(context).driver,
                    gold: false,
                    leading: const _SteeringWheelIcon(
                      color: _gold,
                      size: 21,
                    ),
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
/// the shadow (sunken feel). [leading] rides ahead of the label — the role
/// buttons read at a glance (person = Pasajero, steering wheel = Conductor).
class _NeuPressButton extends StatefulWidget {
  final String label;
  final bool gold;
  final VoidCallback onTap;
  final Widget? leading;

  const _NeuPressButton({
    required this.label,
    required this.gold,
    required this.onTap,
    this.leading,
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
              if (widget.leading != null) ...[
                widget.leading!,
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

/// Hand-painted steering wheel for the Conductor button — Material has no
/// steering-wheel glyph. Rim, three spokes at 90°/210°/330°, hub; the same
/// construction as the FasterBadge wheel on the tier cards.
class _SteeringWheelIcon extends StatelessWidget {
  const _SteeringWheelIcon({required this.color, this.size = 21});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _SteeringWheelPainter(color: color)),
    );
  }
}

class _SteeringWheelPainter extends CustomPainter {
  const _SteeringWheelPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 0.8;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.115
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(c, r, p);
    for (final deg in [90.0, 210.0, 330.0]) {
      final a = deg * math.pi / 180;
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * (r * 0.45),
        c + Offset(math.cos(a), math.sin(a)) * (r * 0.88),
        p,
      );
    }
    canvas.drawCircle(c, size.width * 0.15, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SteeringWheelPainter oldDelegate) =>
      oldDelegate.color != color;
}
