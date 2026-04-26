import 'package:flutter/material.dart';

/// Animated gold "running glow" border painter — the same effect used on
/// the driver-side "Finding trips" panel (see driver_online_screen.dart:
/// _SearchingBorderPainter). Extracted here so the rider home top-bar
/// header can use the identical animation when the rider is in the
/// idle/listening state, without duplicating 90+ lines of painter code.
///
/// Usage:
/// ```dart
/// CustomPaint(
///   foregroundPainter: SearchingBorderPainter(
///     progress: anim.value, // 0..1, loop
///     expansion: 1.0,       // 0 = all-sides round, 1 = top-edge flat
///   ),
///   child: yourCardContent,
/// )
/// ```
///
/// Drives a 48-step micro-segment trail that fades smoothly via a
/// smoothstep easing — visually identical to the rider Where-to and
/// driver Finding-trips panels.
class SearchingBorderPainter extends CustomPainter {
  final double progress; // 0.0 → 1.0, loops continuously
  final double expansion; // 0.0 = collapsed (rounded all sides), 1.0 = expanded (square bottom)
  final double cornerRadius;

  static const Color _gold = Color(0xFFE8C547);
  static const Color _goldLight = Color(0xFFFBE47A);

  SearchingBorderPainter({
    required this.progress,
    this.expansion = 0.0,
    this.cornerRadius = 20.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final botRadius = cornerRadius * (1.0 - expansion);
    final rrect = RRect.fromRectAndCorners(
      rect,
      topLeft: Radius.circular(cornerRadius),
      topRight: Radius.circular(cornerRadius),
      bottomLeft: Radius.circular(botRadius),
      bottomRight: Radius.circular(botRadius),
    );

    // Subtle base border — always visible
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..isAntiAlias = true
        ..color = _gold.withValues(alpha: 0.12),
    );

    final borderPath = Path()..addRRect(rrect);
    final metricsList = borderPath.computeMetrics().toList();
    if (metricsList.isEmpty) return;
    final pm = metricsList.first;
    final total = pm.length;

    const glowFraction = 0.18;
    final glowLen = total * glowFraction;
    final headDist = (progress * total) % total;

    const steps = 48;
    final stepLen = glowLen / steps;

    for (int k = 0; k < steps; k++) {
      final t = 1.0 - k / steps;
      final fadeAlpha = t * t * (3 - 2 * t); // smoothstep
      if (fadeAlpha < 0.02) continue;

      final segEnd = (headDist - k * stepLen + total) % total;
      final segStart = (segEnd - stepLen + total) % total;

      final Path seg;
      if (segStart <= segEnd) {
        seg = pm.extractPath(segStart, segEnd);
      } else {
        seg = pm.extractPath(segStart, total)
          ..addPath(pm.extractPath(0, segEnd), Offset.zero);
      }

      canvas.drawPath(
        seg,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true
          ..color = Color.lerp(_gold, _goldLight, t)!
              .withValues(alpha: fadeAlpha * 0.95),
      );

      if (k % 2 == 0) {
        canvas.drawPath(
          seg,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 12
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
            ..color = _goldLight.withValues(alpha: fadeAlpha * 0.30),
        );
      }
    }
  }

  @override
  bool shouldRepaint(SearchingBorderPainter old) =>
      old.progress != progress ||
      old.expansion != expansion ||
      old.cornerRadius != cornerRadius;
}
