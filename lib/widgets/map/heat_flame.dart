import 'package:flutter/material.dart';

import '../../map/rider_heat.dart';

/// The gold flame on a heat cloud (owner 2026-11-05: only the icon — no
/// disc behind it, no words — with a thicker dark outline so it reads on
/// the gold).
const Color kHeatFlameGold = Color(0xFFF2D46A);
const Color kHeatFlameOutline = Color(0xFF0A1128);

/// The approved demo's flame, in its own 24×24 box.
Path heatFlamePath() => Path()
  ..moveTo(12.8, 2.5)
  ..cubicTo(13.2, 5.1, 11.9, 6.5, 10.9, 7.9)
  ..cubicTo(10.1, 9.0, 9.5, 10.1, 9.9, 11.4)
  ..cubicTo(10.2, 12.4, 11.1, 13.0, 12.0, 13.0)
  ..cubicTo(13.4, 13.0, 14.2, 11.9, 14.1, 10.4)
  ..cubicTo(16.0, 12.0, 17.2, 14.1, 17.2, 16.5)
  ..arcToPoint(const Offset(11.3, 22.4),
      radius: const Radius.circular(5.9), clockwise: true)
  ..arcToPoint(const Offset(5.4, 16.5),
      radius: const Radius.circular(5.9), clockwise: true)
  ..cubicTo(5.4, 13.4, 7.2, 11.2, 8.8, 9.3)
  ..cubicTo(10.4, 7.4, 12.0, 5.6, 12.8, 2.5)
  ..close();

class HeatFlamePainter extends CustomPainter {
  const HeatFlamePainter({this.outline = true});

  /// The dark outline on the map; none inside the card's dark circle.
  final bool outline;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 24;
    canvas.save();
    canvas.translate((size.width - 24 * k) / 2, (size.height - 24 * k) / 2);
    canvas.scale(k);
    final path = heatFlamePath();
    if (outline) {
      canvas.drawPath(
        path,
        Paint()
          ..color = kHeatFlameOutline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.drawPath(path, Paint()..color = kHeatFlameGold);
    canvas.restore();
  }

  @override
  bool shouldRepaint(HeatFlamePainter old) => old.outline != outline;
}

/// Size of the flame on the map, and of the invisible tap target around it.
const double kHeatFlameSize = 31;
const double kHeatFlameTapSize = 48;

/// The flame on the map, centred on its point: fades in when the cloud
/// appears and out when it leaves, at the cloud's own pace.
class HeatFlameMarker extends StatelessWidget {
  const HeatFlameMarker({super.key, required this.visible, this.onTap});

  final bool visible;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: visible ? 1 : 0),
      duration: const Duration(milliseconds: kHeatFadeMs),
      curve: Curves.easeInOut,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: visible ? onTap : null,
        child: const SizedBox(
          width: kHeatFlameTapSize,
          height: kHeatFlameTapSize,
          child: Center(
            child: CustomPaint(
              size: Size.square(kHeatFlameSize),
              painter: HeatFlamePainter(),
            ),
          ),
        ),
      ),
    );
  }
}
