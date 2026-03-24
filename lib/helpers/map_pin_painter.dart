import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Shared map pin painters used across Rider and Driver screens.
/// Ensures visual consistency for pickup, dropoff, and driver dock markers.
class MapPinPainter {
  MapPinPainter._();

  static const Color _gold = Color(0xFFE8C547);

  // ─── PICKUP PIN (white teardrop, gold inner circle) ──────────────

  static Future<Uint8List?> buildPickupPin({
    double w = 48,
    double h = 64,
  }) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
    final cx = w / 2;
    final r = w * 0.29;
    final headCY = r + 5;
    final tipY = h;

    final path = _teardropPath(cx, headCY, r, tipY);

    // Shadow
    c.drawPath(
      path.shift(const Offset(0, 2)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    // White fill
    c.drawPath(path, Paint()..color = Colors.white);
    // White head
    c.drawCircle(Offset(cx, headCY), r, Paint()..color = Colors.white);
    // Gold inner
    c.drawCircle(Offset(cx, headCY), r - 4, Paint()..color = _gold);

    return _rasterize(rec, w.toInt(), h.toInt());
  }

  // ─── DROPOFF PIN (gold teardrop, white head, gold inner) ─────────

  static Future<Uint8List?> buildDropoffPin({
    double w = 60,
    double h = 80,
  }) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
    final cx = w / 2;
    final r = w * 0.30;
    final headCY = r + 6;
    final tipY = h;

    final path = _teardropPath(cx, headCY, r, tipY);

    // Shadow
    c.drawPath(
      path.shift(const Offset(0, 2)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // Gold fill
    c.drawPath(path, Paint()..color = _gold);
    // White head circle
    c.drawCircle(Offset(cx, headCY), r, Paint()..color = Colors.white);
    // Gold inner
    c.drawCircle(Offset(cx, headCY), r - 5, Paint()..color = _gold);

    return _rasterize(rec, w.toInt(), h.toInt());
  }

  // ─── DRIVER DOCK PIN (white circle, gold ring, gold chevron) ─────

  static Future<Uint8List?> buildDriverDockPin({
    double size = 80,
  }) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, size, size));
    final cx = size / 2;
    final cy = size / 2;

    // Soft circular radial fade shadow (premium floating effect)
    c.drawCircle(
      Offset(cx, cy + size * 0.04),
      size * 0.38,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, size * 0.25),
    );
    c.drawCircle(
      Offset(cx, cy + size * 0.02),
      size * 0.28,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.10)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, size * 0.14),
    );
    // Subtle gold halo
    c.drawCircle(
      Offset(cx, cy),
      size * 0.34,
      Paint()
        ..color = _gold.withValues(alpha: 0.12)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, size * 0.18),
    );

    // White circle body
    c.drawCircle(Offset(cx, cy), size * 0.275, Paint()..color = Colors.white);

    // Gold ring border
    c.drawCircle(
      Offset(cx, cy),
      size * 0.275,
      Paint()
        ..color = const Color(0xFFD4A843).withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size * 0.038,
    );

    // Gold directional chevron
    final s = size * 0.16;
    final chevron = Path()
      ..moveTo(cx, cy - s)
      ..lineTo(cx + s * 0.62, cy + s * 0.38)
      ..lineTo(cx, cy + s * 0.08)
      ..lineTo(cx - s * 0.62, cy + s * 0.38)
      ..close();
    c.drawPath(chevron, Paint()..color = const Color(0xFFD4A843));

    return _rasterize(rec, size.toInt(), size.toInt());
  }

  // ─── LARGE ACCEPT-SCREEN PIN (gold teardrop with icon) ───────────

  static Future<Uint8List?> buildAcceptPin({
    required bool isPickup,
    double w = 100,
    double h = 130,
  }) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
    final cx = w / 2;
    const r = 30.0;
    const headCY = r + 8;
    final tipY = h;

    final path = _teardropPath(cx, headCY, r, tipY);

    // Shadow
    canvas.drawPath(
      path.shift(const Offset(0, 3)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    // Gold fill
    canvas.drawPath(path, Paint()..color = _gold);
    // White border
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.35),
    );
    // Highlight
    canvas.drawCircle(
      Offset(cx - r * 0.25, headCY - r * 0.25),
      r * 0.4,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // White center icon
    final iconPaint = Paint()..color = Colors.white..isAntiAlias = true;
    if (isPickup) {
      canvas.drawCircle(Offset(cx, headCY), r * 0.22, iconPaint);
    } else {
      final flagPath = Path()
        ..moveTo(cx - r * 0.2, headCY - r * 0.35)
        ..lineTo(cx + r * 0.35, headCY - r * 0.2)
        ..lineTo(cx - r * 0.08, headCY - r * 0.05)
        ..lineTo(cx - r * 0.08, headCY + r * 0.35)
        ..lineTo(cx - r * 0.2, headCY + r * 0.35)
        ..close();
      canvas.drawPath(flagPath, iconPaint);
    }

    return _rasterize(rec, w.toInt(), h.toInt());
  }

  // ─── HELPERS ─────────────────────────────────────────────────────

  static Path _teardropPath(double cx, double headCY, double r, double tipY) {
    return Path()
      ..moveTo(cx - r, headCY)
      ..arcTo(
        Rect.fromCircle(center: Offset(cx, headCY), radius: r),
        math.pi, -math.pi, false,
      )
      ..cubicTo(cx + r, headCY + r, cx + r * 0.22, tipY - 3, cx, tipY)
      ..cubicTo(cx - r * 0.22, tipY - 3, cx - r, headCY + r, cx - r, headCY)
      ..close();
  }

  static Future<Uint8List?> _rasterize(
    ui.PictureRecorder rec, int w, int h,
  ) async {
    final img = await rec.endRecording().toImage(w, h);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  }
}
