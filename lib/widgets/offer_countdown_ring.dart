import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The seconds a driver has to take an offer before the card gives up on it.
///
/// The backend hands the same offer to the next driver at
/// OFFER_TIMEOUT_SECONDS (45s, see backend/routers/dispatch.py). Anything
/// shorter here throws away a window that is still live — the driver stops
/// being able to accept while the server would still have taken it. Change
/// both together or not at all.
const int kOfferCountdownSeconds = 20;

/// A ring that empties over [seconds] and then calls [onExpired] once.
///
/// Self-contained on purpose: it owns its own ticker, so the card around it
/// can rebuild as often as it likes without restarting the count. Give it a
/// ValueKey of the offer id — a new offer then gets a fresh ring, and a
/// rebuild of the same offer keeps the time already elapsed.
class OfferCountdownRing extends StatefulWidget {
  const OfferCountdownRing({
    super.key,
    required this.onExpired,
    this.seconds = kOfferCountdownSeconds,
    this.size = 54,
    this.color = const Color(0xFFE8C547),
    this.child,
  });

  final VoidCallback onExpired;
  final int seconds;
  final double size;
  final Color color;

  /// What sits inside the ring. The arc is the countdown; a number would
  /// only say the same thing twice, in the one spot the brand mark has.
  final Widget? child;

  @override
  State<OfferCountdownRing> createState() => _OfferCountdownRingState();
}

class _OfferCountdownRingState extends State<OfferCountdownRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(seconds: widget.seconds),
    )..addStatusListener((s) {
        // Guarded: a controller can report completed more than once across
        // a rebuild, and firing twice would reject an offer the driver may
        // already have accepted.
        if (s == AnimationStatus.completed && !_fired) {
          _fired = true;
          widget.onExpired();
        }
      });
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _ctrl,
        // The child is built once and handed in, not rebuilt on every
        // frame of a 20-second animation — it never depends on the tick.
        child: widget.child == null
            ? null
            : Center(
                child: Padding(
                  padding: EdgeInsets.all(widget.size * 0.14),
                  child: widget.child,
                ),
              ),
        builder: (context, child) => CustomPaint(
          painter: _RingPainter(
            progress: 1 - _ctrl.value,
            color: widget.color,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.color});

  /// 1.0 at the start, 0.0 when the time is up.
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Thin on purpose — the ring is a clock, not a frame around the
    // number, and a heavy stroke competes with the fare beside it.
    const stroke = 2.0;
    final rect = Offset.zero & size;
    final centre = rect.center;
    final radius = (math.min(size.width, size.height) - stroke) / 2;

    // The track the ring runs on — always the full circle, so the gap the
    // countdown leaves behind reads as time spent rather than as nothing.
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = Colors.white.withValues(alpha: 0.08),
    );

    // The remaining time, from twelve o'clock, clockwise.
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}
