import 'dart:math';
import 'package:flutter/material.dart';

/// Cruise-branded map pin: golden teardrop shape with a person avatar at top.
/// The gradient runs from dark navy at the top to gold at the tip.
/// Bounces gently while shown. Used as the fixed center overlay on the map picker.
class CruiseMapPin extends StatefulWidget {
  final double size; // pin width; height is derived proportionally
  final IconData icon; // avatar icon inside pin circle
  const CruiseMapPin({super.key, this.size = 56, this.icon = Icons.person});

  @override
  State<CruiseMapPin> createState() => _CruiseMapPinState();
}

class _CruiseMapPinState extends State<CruiseMapPin>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounceCtrl;
  late final Animation<double> _bounceAnim;

  @override
  void initState() {
    super.initState();
    _bounceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _bounceAnim = Tween<double>(begin: 0.0, end: -6.0).animate(
      CurvedAnimation(parent: _bounceCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _bounceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final pinW = s;
    final pinH = s * (78 / 72);
    final avatarSize = s * (48 / 72);
    final avatarMarginTop = s * (8 / 72);
    final iconSize = s * (32 / 72); // larger icon

    return SizedBox(
      width: pinW,
      height: pinH + 14, // extra space for floating shadow below
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          // ── Floating shadow ring — stays below, scales inverse to bounce ──
          Positioned(
            bottom: 2,
            child: AnimatedBuilder(
              animation: _bounceAnim,
              builder: (_, __) {
                final t = (_bounceAnim.value / -6.0).clamp(0.0, 1.0);
                final scale = 1.0 - t * 0.40; // bigger when pin is low
                final opacity = 0.22 - t * 0.10;
                return Transform.scale(
                  scale: scale,
                  child: Container(
                    width: pinW * 0.55,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: opacity),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                );
              },
            ),
          ),
          // ── Bouncing pin + avatar ──
          AnimatedBuilder(
            animation: _bounceAnim,
            builder: (_, child) => Transform.translate(
                offset: Offset(0, _bounceAnim.value), child: child),
            child: SizedBox(
              width: pinW,
              height: pinH,
              child: Stack(
                alignment: Alignment.topCenter,
                children: [
                  // Luxury gold teardrop
                  CustomPaint(
                    size: Size(pinW, pinH),
                    painter: _PinPainter(),
                  ),
                  // Icon circle (glass overlay)
                  Container(
                    width: avatarSize,
                    height: avatarSize,
                    margin: EdgeInsets.only(top: avatarMarginTop),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.18),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.50),
                        width: 1.5,
                      ),
                    ),
                    child: Icon(
                      widget.icon,
                      color: Colors.white,
                      size: iconSize,
                      shadows: const [Shadow(color: Color(0x55000000), blurRadius: 4)],
                    ),
                  ),
                      ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════
//  Teardrop pin shape: dark navy at top → golden yellow at sharp tip
// ═════════════════════════════════════════════════════════════════════════

class _PinPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final r = w / 2;

    // Teardrop path
    final path = Path()
      ..moveTo(cx, h)
      ..quadraticBezierTo(0, r + (h - r) * 0.35, 0, r)
      ..arcTo(Rect.fromLTWH(0, 0, w, w), pi, -pi, false)
      ..quadraticBezierTo(w, r + (h - r) * 0.35, cx, h)
      ..close();

    // ── 1. Drop shadow behind pin ──
    canvas.drawPath(
      path.shift(const Offset(0, 4)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // ── 2. Luxury gold gradient fill ──
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: const [
            Color(0xFFFFF8DC), // goldLight
            Color(0xFFE8C547), // goldMid
            Color(0xFFB8860B), // goldDeep
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );

    // ── 3. Glass sheen — white oval highlight top-left ──
    canvas.save();
    canvas.clipPath(path);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx - r * 0.25, r * 0.55),
        width: r * 0.85,
        height: r * 0.55,
      ),
      Paint()
        ..color = const Color(0x66FFFFFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawCircle(
      Offset(cx - r * 0.30, r * 0.38),
      r * 0.13,
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
    canvas.restore();

    // ── 4. Thin bright border ──
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.35),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
