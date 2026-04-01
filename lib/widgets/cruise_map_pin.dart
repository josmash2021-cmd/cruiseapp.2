import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Cruise-branded map pin: golden crescent cup with icon floating above.
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
    final pinH = s * (68 / 72);
    final avatarSize = s * (48 / 72);
    final avatarMarginTop = s * 0.16;
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
                  // Crescent cup shape
                  CustomPaint(
                    size: Size(pinW, pinH),
                    painter: _PinPainter(),
                  ),
                  // Icon (no circle border — floats above crescent)
                  Padding(
                    padding: EdgeInsets.only(top: avatarMarginTop),
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

    // V2 crescent cup measurements
    final r = w * 0.30;
    final cupCY = w * 0.34;
    final thick = r * 0.28;
    final tipY = h - w * 0.01;
    final iconCY = cupCY;

    const arcStart = 0.5654866776; // pi * 0.18
    const arcEnd   = 2.5761455262; // pi * 0.82
    const arcSweep = arcEnd - arcStart;

    // ── 1. White fade glow behind icon ──
    final glowR = r * 0.60;
    canvas.drawCircle(
      Offset(cx, iconCY),
      glowR,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(cx, iconCY),
          glowR,
          [
            Colors.white.withValues(alpha: 0.50),
            Colors.white.withValues(alpha: 0.15),
            Colors.transparent,
          ],
          [0.0, 0.45, 1.0],
        ),
    );

    // ── 2. Gold crescent cup + sharp tail ──
    final outerPath = Path()
      ..arcTo(
        Rect.fromCircle(center: Offset(cx, cupCY), radius: r),
        arcStart, arcSweep, true,
      );

    final endX = cx + r * math.cos(arcEnd);
    final endY = cupCY + r * math.sin(arcEnd);
    final startX = cx + r * math.cos(arcStart);
    final startY = cupCY + r * math.sin(arcStart);

    outerPath.quadraticBezierTo(
      endX + r * 0.06, tipY - (tipY - endY) * 0.25,
      cx, tipY,
    );
    outerPath.quadraticBezierTo(
      startX - r * 0.06, tipY - (tipY - startY) * 0.25,
      startX, startY,
    );
    outerPath.close();

    // Crescent with inner cutout (even-odd)
    final crescent = Path()..addPath(outerPath, Offset.zero);
    final innerR = r - thick;
    final iArcStart = arcStart + 0.08;
    final iArcEnd = arcEnd - 0.08;
    crescent.moveTo(
      cx + innerR * math.cos(iArcStart),
      cupCY + innerR * math.sin(iArcStart),
    );
    crescent.arcTo(
      Rect.fromCircle(center: Offset(cx, cupCY), radius: innerR),
      iArcStart, iArcEnd - iArcStart, false,
    );
    final iStartX = cx + innerR * math.cos(iArcStart);
    final iStartY = cupCY + innerR * math.sin(iArcStart);
    final iEndY = cupCY + innerR * math.sin(iArcEnd);
    crescent.quadraticBezierTo(cx, iEndY + thick * 0.9, iStartX, iStartY);
    crescent.close();
    crescent.fillType = PathFillType.evenOdd;

    // Shadow glow
    canvas.drawPath(
      outerPath,
      Paint()
        ..color = const Color(0x73D4A800)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // Gold gradient fill
    canvas.drawPath(
      crescent,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, cupCY - r),
          Offset(cx, tipY),
          [const Color(0xFFF5DC7A), const Color(0xFFD4A800), const Color(0xFFB08800)],
          [0.0, 0.45, 1.0],
        ),
    );

    // ── 3. Subtle highlight on upper rim ──
    final hlPath = Path()
      ..arcTo(
        Rect.fromCircle(center: Offset(cx, cupCY), radius: r - 1),
        arcStart + 0.1, arcSweep * 0.35, true,
      );
    canvas.drawPath(
      hlPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.07
        ..color = Colors.white.withValues(alpha: 0.28),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
