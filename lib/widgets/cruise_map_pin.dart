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
    // Preserve original 72×88 proportions
    final pinW = s;
    final pinH = s * (88 / 72);
    final avatarSize = s * (48 / 72);
    final avatarMarginTop = s * (8 / 72);
    final iconSize = s * (28 / 72);

    return AnimatedBuilder(
      animation: _bounceAnim,
      builder: (_, child) =>
          Transform.translate(offset: Offset(0, _bounceAnim.value), child: child),
      child: SizedBox(
        width: pinW,
        height: pinH,
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            // ── Teardrop pin shape (navy→gold gradient) ──
            CustomPaint(
              size: Size(pinW, pinH),
              painter: _PinPainter(),
            ),
            // ── Person avatar circle at top of pin ──
            Container(
              width: avatarSize,
              height: avatarSize,
              margin: EdgeInsets.only(top: avatarMarginTop),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF1A1F2E),
                border: Border.all(color: Colors.white24, width: 1),
              ),
              child: Icon(
                widget.icon,
                color: Colors.white,
                size: iconSize,
              ),
            ),
          ],
        ),
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
    final r = w / 2; // radius of the rounded top
    final cx = w / 2;

    // Teardrop path:
    //  • Rounded top — semicircle arc from left equator edge to right equator edge
    //  • Two quadratic bezier curves tapering to the sharp tip at the bottom
    final path = Path();
    path.moveTo(cx, h); // start at tip
    // Left side curve: tip → left equator edge
    path.quadraticBezierTo(0, r + (h - r) * 0.35, 0, r);
    // Top arc: counter-clockwise from (0, r) through top centre to (w, r)
    path.arcTo(
      Rect.fromLTWH(0, 0, w, w),
      pi,   // start: points left → (0, r)
      -pi,  // sweep: −180° (counter-clockwise) → ends at (w, r)
      false,
    );
    // Right side curve: right equator edge → tip
    path.quadraticBezierTo(w, r + (h - r) * 0.35, cx, h);
    path.close();

    // Drop shadow
    canvas.drawShadow(path, Colors.black, 6, false);

    // Solid gold fill (unified gold pin design)
    const goldColor = Color(0xFFE8C547);
    final fillPaint = Paint()
      ..color = goldColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    // White border highlight
    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawPath(path, borderPaint);

    // Specular highlight on top-left
    final highlightPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    canvas.drawCircle(Offset(cx - r * 0.25, r * 0.4), r * 0.35, highlightPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
