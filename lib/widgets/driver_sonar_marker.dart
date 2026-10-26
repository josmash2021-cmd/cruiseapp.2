import 'package:flutter/widgets.dart';

import 'gold_location_dot.dart';

class DriverSonarMarker extends StatelessWidget {
  const DriverSonarMarker({
    super.key,
    required this.animation,
    required this.bearing,
    this.size = GoldLocationDot.driverOverlaySize,
  });

  final Animation<double> animation;
  final double bearing;
  final double size;

  static double waveProgress(double value, double phase) =>
      (value + phase) % 1.0;

  static double waveRadius(double progress, double size) {
    final remaining = 1.0 - progress;
    final eased = 1.0 - remaining * remaining * remaining;
    return size * (0.17 + 0.25 * eased);
  }

  static double waveOpacity(double progress) => 0.34 * (1.0 - progress);

  @override
  Widget build(BuildContext context) {
    final canvasSize = size * 1.5;
    return IgnorePointer(
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            OverflowBox(
              maxWidth: canvasSize,
              maxHeight: canvasSize,
              child: SizedBox.square(
                dimension: canvasSize,
                child: AnimatedBuilder(
                  animation: animation,
                  builder: (context, child) => CustomPaint(
                    painter: _DriverSonarPainter(
                      value: animation.value,
                      markerSize: size,
                    ),
                  ),
                ),
              ),
            ),
            GoldLocationDotOverlay(bearing: bearing, size: size),
          ],
        ),
      ),
    );
  }
}

class _DriverSonarPainter extends CustomPainter {
  const _DriverSonarPainter({required this.value, required this.markerSize});

  final double value;
  final double markerSize;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (final phase in const [0.0, 0.5]) {
      final progress = DriverSonarMarker.waveProgress(value, phase);
      final opacity = DriverSonarMarker.waveOpacity(progress);
      if (opacity == 0) continue;
      canvas.drawCircle(
        center,
        DriverSonarMarker.waveRadius(progress, markerSize),
        Paint()
          ..color = const Color(0xFFE8C547).withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_DriverSonarPainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.markerSize != markerSize;
}
