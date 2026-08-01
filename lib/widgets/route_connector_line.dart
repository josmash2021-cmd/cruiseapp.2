import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The line that joins the pickup dot to the dropoff square.
///
/// It runs gold at the top, where it leaves the gold dot, and white at the
/// bottom, where it meets the white square — so each end matches the marker
/// it touches and the line reads as the trip between them rather than as a
/// rule that happens to sit there.
///
/// The point where gold hands over to white drifts slowly up and down, so
/// the line is alive without anything travelling along it.
class RouteConnectorLine extends StatefulWidget {
  const RouteConnectorLine({
    super.key,
    this.top = const Color(0xFFE8C547),
    this.bottom = Colors.white,
    this.width = 2,
  });

  final Color top;
  final Color bottom;
  final double width;

  @override
  State<RouteConnectorLine> createState() => _RouteConnectorLineState();
}

class _RouteConnectorLineState extends State<RouteConnectorLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      // Slow. This sits under a fare and above an Accept button;
      // anything brisker pulls the eye off both.
      duration: const Duration(milliseconds: 4200),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Honour the system's "reduce motion" switch. A driver who has turned
    // animations off should get the gradient standing still, not a loop
    // they cannot stop.
    final wants = !MediaQuery.of(context).disableAnimations;
    if (wants && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!wants && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => CustomPaint(
          size: Size(widget.width, double.infinity),
          painter: _ConnectorPainter(
            t: _ctrl.value,
            top: widget.top,
            bottom: widget.bottom,
          ),
        ),
      ),
    );
  }
}

class _ConnectorPainter extends CustomPainter {
  _ConnectorPainter({
    required this.t,
    required this.top,
    required this.bottom,
  });

  /// Drives the sway of the gold-to-white handover, 0 to 1 and round.
  final double t;
  final Color top;
  final Color bottom;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0 || size.width <= 0) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.width / 2),
    );

    // Gold where it leaves the dot, white where it reaches the square.
    //
    // The animation is the handover point between the two drifting up and
    // down, not a brighter band travelling through — a line running inside
    // the line reads as a second object passing over the first, and this
    // is one line.
    final sway = 0.5 - 0.20 * math.cos(t * 2 * math.pi);
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          rect.bottomCenter,
          [
            top.withValues(alpha: 0.9),
            top.withValues(alpha: 0.75),
            bottom.withValues(alpha: 0.75),
            bottom.withValues(alpha: 0.9),
          ],
          [
            0,
            (sway - 0.14).clamp(0.02, 0.5),
            (sway + 0.14).clamp(0.5, 0.98),
            1
          ],
        ),
    );
  }

  @override
  bool shouldRepaint(_ConnectorPainter old) =>
      old.t != t || old.top != top || old.bottom != bottom;
}
