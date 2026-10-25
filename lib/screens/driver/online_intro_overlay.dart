import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/haptic_service.dart';

/// Daily instruction overlay: it floats OVER the online map (it is NOT a
/// page — the map stays mounted underneath, lightly dimmed). Every 24 hours
/// per device, dismissed only by the gold "Entendido" button; if the app
/// dies mid-overlay it simply shows again on the next GO.
///
/// Animated: scrim fade, card slide-up, PNG soft-scale, and the four info
/// blocks cascading in — plain Flutter tweens, no animation packages.

/// The first-N-drivers figure used in the copy — EDITABLE by design.
const int kFirstDriverCount = 100;

const Duration onlineIntroRepeatInterval = Duration(hours: 24);

bool onlineIntroDueNow(int? lastSeenMs, int nowMs) {
  if (lastSeenMs == null || lastSeenMs <= 0) return true;
  return nowMs - lastSeenMs >= onlineIntroRepeatInterval.inMilliseconds;
}

class OnlineIntroOverlay extends StatefulWidget {
  const OnlineIntroOverlay({super.key, required this.onUnderstood});

  /// Parent marks the seen flag and unmounts the overlay.
  final VoidCallback onUnderstood;

  @override
  State<OnlineIntroOverlay> createState() => _OnlineIntroOverlayState();
}

class _OnlineIntroOverlayState extends State<OnlineIntroOverlay>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  late final AnimationController _ctrl;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1150),
      reverseDuration: const Duration(milliseconds: 260),
    )..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_leaving) return;
    _leaving = true;
    HapticService.lightImpact();
    await _ctrl.reverse();
    if (mounted) widget.onUnderstood();
  }

  Animation<double> _window(double start, double end, {Curve? curve}) =>
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(start, end, curve: curve ?? Curves.easeOutCubic),
      );

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final bottom = MediaQuery.of(context).padding.bottom;

    return Material(
      type: MaterialType.transparency,
      child: FadeTransition(
        opacity: _window(0.0, 0.22),
        child: Container(
          color: Colors.black.withValues(alpha: 0.18),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + bottom),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.10),
                    end: Offset.zero,
                  ).animate(_window(0.12, 0.55)),
                  child: FadeTransition(
                    opacity: _window(0.12, 0.50),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.topCenter,
                          children: [
                            ClipPath(
                              clipper: _CloudClipper(),
                              child: CustomPaint(
                                foregroundPainter: _CloudBorderPainter(),
                                child: Container(
                                  margin: const EdgeInsets.only(top: 92),
                                  constraints:
                                      const BoxConstraints(maxWidth: 360),
                                  padding:
                                      const EdgeInsets.fromLTRB(14, 60, 14, 14),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE8C547),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.22),
                                        blurRadius: 26,
                                        offset: const Offset(0, 12),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        s.onlineIntroTitle,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 27,
                                          fontWeight: FontWeight.w900,
                                          height: 1.05,
                                          letterSpacing: -0.4,
                                        ),
                                      ),
                                      const SizedBox(height: 7),
                                      Container(
                                        width: 34,
                                        height: 3,
                                        color: const Color(0xFF5C4B12),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        s.onlineIntroSub(kFirstDriverCount),
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Color(0xFF3D3830),
                                          fontSize: 11.5,
                                          height: 1.35,
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                      _cascade(
                                        0,
                                        _IntroBlock(
                                          icon: Icons.groups_rounded,
                                          title: s.onlineIntroB1Title,
                                          body: s.onlineIntroB1Body,
                                        ),
                                      ),
                                      _cascade(
                                        1,
                                        _IntroBlock(
                                          icon: Icons.bar_chart_rounded,
                                          title: s.onlineIntroB2Title,
                                          body: s.onlineIntroB2Body,
                                        ),
                                      ),
                                      _cascade(
                                        2,
                                        _IntroBlock(
                                          icon: Icons.schedule_rounded,
                                          title: s.onlineIntroB3Title,
                                          body: s.onlineIntroB3Body,
                                        ),
                                      ),
                                      _cascade(
                                        3,
                                        _IntroBlock(
                                          icon: Icons.emoji_events_rounded,
                                          title: s.onlineIntroB4Title,
                                          body: s.onlineIntroB4Body(
                                              kFirstDriverCount),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: ScaleTransition(
                                scale: Tween<double>(begin: 0.92, end: 1.0)
                                    .animate(_window(0.18, 0.60,
                                        curve: Curves.easeOutBack)),
                                child: Image.asset(
                                  'assets/images/online_intro_hero.png',
                                  height: 150,
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, stackTrace) =>
                                      const SizedBox(height: 12),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        FadeTransition(
                          opacity: _window(0.72, 1.0),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 360),
                              child: SizedBox(
                                width: double.infinity,
                                height: 44,
                                child: ElevatedButton(
                                  onPressed: _dismiss,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _gold,
                                    foregroundColor: Colors.black,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  child: Text(
                                    s.onlineIntroUnderstood,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The 4 info blocks enter one after another (cascade).
  Widget _cascade(int index, Widget child) {
    final start = 0.42 + index * 0.11;
    final end = (start + 0.28).clamp(0.0, 1.0);
    return FadeTransition(
      opacity: _window(start, end),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.14),
          end: Offset.zero,
        ).animate(_window(start, end)),
        child: child,
      ),
    );
  }
}

/// Gold icon and title + dark body — one info row of the card.
/// Icons are passed as plain const constructor args (NEVER through a
/// record literal — the release tree-shaker drops those glyphs).
class _IntroBlock extends StatelessWidget {
  const _IntroBlock({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  static const _gold = Color(0xFFE8C547);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFDF6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE3CD92)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, color: _gold, size: 24),
            Container(
              width: 1.5,
              height: 42,
              margin: const EdgeInsets.symmetric(horizontal: 9),
              color: _gold.withValues(alpha: 0.55),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Color(0xFFB77A00),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    body,
                    style: TextStyle(
                      color: const Color(0xFF3D3830).withValues(alpha: 0.82),
                      fontSize: 11.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Path _cloudPath(Size size) {
  final w = size.width;
  final h = size.height;
  return Path()
    ..moveTo(0, 76)
    ..quadraticBezierTo(0, 60, 18, 56)
    ..quadraticBezierTo(w * 0.18, 48, w * 0.30, 38)
    ..quadraticBezierTo(w * 0.40, 4, w * 0.50, 0)
    ..quadraticBezierTo(w * 0.60, 4, w * 0.70, 38)
    ..quadraticBezierTo(w * 0.82, 48, w - 18, 56)
    ..quadraticBezierTo(w, 60, w, 76)
    ..lineTo(w, h - 24)
    ..quadraticBezierTo(w, h, w - 24, h)
    ..lineTo(24, h)
    ..quadraticBezierTo(0, h, 0, h - 24)
    ..close();
}

class _CloudClipper extends CustomClipper<Path> {
  const _CloudClipper();

  @override
  Path getClip(Size size) => _cloudPath(size);

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _CloudBorderPainter extends CustomPainter {
  const _CloudBorderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      _cloudPath(size),
      Paint()
        ..color = const Color(0xFFF4D876)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
