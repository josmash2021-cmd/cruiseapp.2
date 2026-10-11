import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';

/// Nav intro (user mockup 2026-10-08): shown ONCE, the first time a driver
/// opens in-app navigation toward a pickup (gate lives in
/// driver_trip_accept_screen.dart `_enterNavMode`, flag
/// `driver_nav_intro_seen_v1` in LocalCache). "Get started" just pops and
/// the nav opens behind it.
class NavIntroScreen extends StatelessWidget {
  const NavIntroScreen({super.key});

  // Exact bg of the hero art (sampled 2026-10-10: RGB 20,21,22) — the card
  // melts into the page instead of reading as a grey frame around it.
  static const _navy = Color(0xFF141516);
  static const _gold = Color(0xFFE8C547);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: _navy,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),
              // The design's own hero art (user spec 2026-10-10: "esta página
              // debe tener esta imagen de esta foto"). Served from the
              // backend because Shorebird patches never carry new assets;
              // the code-drawn card below stays as the loading/failure
              // stand-in so the page never renders broken.
              ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Image.network(
                  '${ApiService.currentBaseUrl}/static/nav_intro_hero.png',
                  fit: BoxFit.fitWidth,
                  // Same rule as the update gate (2026-10-10): warm cache
                  // paints with the page; a late frame fades, never pops.
                  frameBuilder: (context, child, frame, wasSync) {
                    if (wasSync) return child;
                    if (frame == null) return const _RouteIllustration();
                    return TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOut,
                      builder: (_, v, c) => Opacity(opacity: v, child: c),
                      child: child,
                    );
                  },
                  errorBuilder: (context, error, stack) =>
                      const _RouteIllustration(),
                ),
              ),
              const SizedBox(height: 34),
              Text(
                s.navIntroTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 28),
              _feature(
                Icons.route_rounded,
                s.navIntroDirectionsTitle,
                s.navIntroDirectionsBody,
              ),
              const SizedBox(height: 18),
              _feature(
                // notifications_outlined / bar_chart_rounded, not
                // notifications_active_outlined / traffic_rounded: OTA
                // patches can only use glyphs that shipped in the store
                // build's icon font — those two rendered as "?" boxes.
                Icons.notifications_outlined,
                s.navIntroRideTitle,
                s.navIntroRideBody,
              ),
              const SizedBox(height: 18),
              _feature(
                Icons.bar_chart_rounded,
                s.navIntroInsightsTitle,
                s.navIntroInsightsBody,
              ),
              const Spacer(flex: 3),
              SizedBox(
                height: 56,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: Text(
                    s.navIntroStart,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  Widget _feature(IconData icon, String title, String body) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _gold.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, color: _gold, size: 21),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                body,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The mockup's hero, drawn in code: the stand-in while the real art
/// downloads from /static/nav_intro_hero.png (or if it ever fails).
/// (2026-10-10: la página usa el PNG del diseño — esto queda de respaldo.)
class _RouteIllustration extends StatelessWidget {
  const _RouteIllustration();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.35,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0C0C12),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: CustomPaint(painter: _RoutePainter()),
      ),
    );
  }
}

class _RoutePainter extends CustomPainter {
  static const _gold = Color(0xFFE8C547);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Faint street grid for the map feel.
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 1.2;
    for (var x = w * 0.12; x < w; x += w * 0.17) {
      canvas.drawLine(Offset(x, 0), Offset(x - w * 0.06, h), grid);
    }
    for (var y = h * 0.15; y < h; y += h * 0.19) {
      canvas.drawLine(Offset(0, y), Offset(w, y - h * 0.08), grid);
    }

    // The route: a smooth gold S-curve from bottom-left to top-right.
    final start = Offset(w * 0.20, h * 0.74);
    final end = Offset(w * 0.78, h * 0.24);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(
        start.dx + w * 0.05, start.dy - h * 0.34,
        end.dx - w * 0.34, end.dy + h * 0.22,
        end.dx, end.dy,
      );
    final routePaint = Paint()
      ..color = _gold
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, routePaint);

    // Start pin: gold teardrop.
    _teardrop(canvas, start, 15, _gold);
    // End pin: white flag pin (a flag, like the app's dropoff marker).
    _teardrop(canvas, end, 13, Colors.white);
    canvas.drawRect(
      Rect.fromLTWH(end.dx + 1, end.dy - 34, 3, 22),
      Paint()..color = Colors.white,
    );
    canvas.drawPath(
      Path()
        ..moveTo(end.dx + 4, end.dy - 34)
        ..lineTo(end.dx + 18, end.dy - 29)
        ..lineTo(end.dx + 4, end.dy - 24)
        ..close(),
      Paint()..color = _gold,
    );
  }

  void _teardrop(Canvas canvas, Offset c, double r, Color color) {
    final p = Path()
      ..addOval(Rect.fromCircle(center: Offset(c.dx, c.dy - r * 0.5), radius: r))
      ..moveTo(c.dx - r * 0.7, c.dy + r * 0.2)
      ..lineTo(c.dx, c.dy + r * 1.4)
      ..lineTo(c.dx + r * 0.7, c.dy + r * 0.2)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
    canvas.drawCircle(
      Offset(c.dx, c.dy - r * 0.5),
      r * 0.38,
      Paint()..color = const Color(0xFF14141A),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
