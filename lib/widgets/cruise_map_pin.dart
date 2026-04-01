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
    final r = w * 0.42;
    final headCY = r + w * 0.08;
    final iconCY = headCY - r * 0.10;

    // ── 1. White fade glow behind icon ──
    canvas.drawCircle(
      Offset(cx, iconCY),
      r * 0.85,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.30),
            Colors.white.withValues(alpha: 0.07),
            Colors.transparent,
          ],
          stops: const [0.0, 0.50, 1.0],
        ).createShader(
          Rect.fromCircle(center: Offset(cx, iconCY), radius: r * 0.85),
        ),
    );

    // ── 2. Golden crescent cup ──
    final openY = headCY + r * 0.15;
    final halfW = r * 0.88;
    final cupPath = Path()
      ..moveTo(cx - halfW, openY)
      ..cubicTo(
        cx - halfW * 1.12, openY + (h - openY) * 0.52,
        cx - r * 0.10, h - (h - openY) * 0.10,
        cx, h,
      )
      ..cubicTo(
        cx + r * 0.10, h - (h - openY) * 0.10,
        cx + halfW * 1.12, openY + (h - openY) * 0.52,
        cx + halfW, openY,
      )
      ..quadraticBezierTo(
        cx, openY - r * 0.30,
        cx - halfW, openY,
      );

    canvas.drawPath(
      cupPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [
            Color(0xFFFFF8DC),
            Color(0xFFE8C547),
            Color(0xFFB8860B),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromLTWH(0, openY, w, h - openY)),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
