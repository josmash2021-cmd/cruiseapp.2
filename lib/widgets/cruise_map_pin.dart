import 'package:flutter/material.dart';

/// Cruise-branded map pin: dark navy circle with a gold downward chevron (V)
/// and a teardrop pointer. Subtly bounces up and down.
class CruiseMapPin extends StatefulWidget {
  final double size;
  const CruiseMapPin({super.key, this.size = 56});

  @override
  State<CruiseMapPin> createState() => _CruiseMapPinState();
}

class _CruiseMapPinState extends State<CruiseMapPin>
    with SingleTickerProviderStateMixin {
  static const _navy = Color(0xFF0A0D1A);
  static const _gold = Color(0xFFD4AF37);

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
    return AnimatedBuilder(
      animation: _bounceAnim,
      builder: (_, child) =>
          Transform.translate(offset: Offset(0, _bounceAnim.value), child: child),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Main circle ──
          Container(
            width: s,
            height: s,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _navy,
              border: Border.all(
                color: _gold.withValues(alpha: 0.4),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.25),
                  blurRadius: 16,
                  spreadRadius: 2,
                  offset: const Offset(0, 4),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: CustomPaint(
                size: Size(s * 0.45, s * 0.35),
                painter: _ChevronPainter(color: _gold),
              ),
            ),
          ),

          // ── Bottom pointer triangle ──
          CustomPaint(
            size: const Size(14, 8),
            painter: _PinPointerPainter(
              color: _navy,
              borderColor: _gold.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════
//  Gold downward chevron (V shape)
// ═════════════════════════════════════════════════════════════════════════

class _ChevronPainter extends CustomPainter {
  final Color color;
  _ChevronPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ChevronPainter old) => old.color != color;
}

// ═════════════════════════════════════════════════════════════════════════
//  Bottom teardrop pointer
// ═════════════════════════════════════════════════════════════════════════

class _PinPointerPainter extends CustomPainter {
  final Color color;
  final Color borderColor;
  _PinPointerPainter({required this.color, required this.borderColor});

  @override
  void paint(Canvas canvas, Size size) {
    // Border triangle
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width / 2, size.height)
        ..close(),
      Paint()..color = borderColor,
    );
    // Fill triangle (inset)
    canvas.drawPath(
      Path()
        ..moveTo(1.5, 0)
        ..lineTo(size.width - 1.5, 0)
        ..lineTo(size.width / 2, size.height - 1)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_PinPointerPainter old) => false;
}
