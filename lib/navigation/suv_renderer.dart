import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Renders a top-down stylized SUV icon inspired by a Chevrolet Suburban.
/// Dark anthracite body, gold belt-line trim, wide proportions.
/// Output: PNG bytes at [w]x[h] pixels, forward direction = top (negative Y).
class SuvRenderer {
  // Canvas dimensions
  static const double _w = 140;
  static const double _h = 240;

  // Color palette — Dark Suburban + Gold trim (matches reference)
  static const _bodyBase    = Color(0xFF222326);
  static const _bodyMid     = Color(0xFF2E3035);
  static const _bodyHi      = Color(0xFF3C4049);
  static const _bodyEdge    = Color(0xFF101113);
  static const _goldTrim    = Color(0xFFC9A433);
  static const _goldGlow    = Color(0xFFE8C060);
  static const _glassColor  = Color(0xFF1A2230);
  static const _glassHi     = Color(0xFF2A3A52);
  static const _wheelBlack  = Color(0xFF0A0A0A);
  static const _rimDark     = Color(0xFF282828);
  static const _rimSpoke    = Color(0xFF4A4A4A);
  static const _ledWhite    = Color(0xFFF0F4FF);
  static const _tailRed     = Color(0xFFFF1A1A);
  static const _outline     = Color(0xFF000000);

  static Future<Uint8List> render() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, _w, _h));
    _draw(canvas);
    final img = await recorder.endRecording().toImage(_w.toInt(), _h.toInt());
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    return bd!.buffer.asUint8List();
  }

  static void _draw(Canvas canvas) {
    const cx = _w / 2;
    const cy = _h / 2;

    // Body half-extents (wide + boxy = Suburban DNA)
    const hw = 55.0;  // half-width
    const hl = 105.0; // half-length

    // ── 1. GROUND SHADOW ─────────────────────────────────────────────────────
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(cx, cy + 8), width: hw * 2 + 10, height: hl * 2 - 10),
      Paint()
        ..color = Colors.black.withOpacity(0.38)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );

    // ── 2. 3-D UNDERCARRIAGE (slight drop-shadow offset) ─────────────────────
    canvas.drawRRect(
      _bodyRRect(cx, cy + 5, hw, hl),
      Paint()..color = _bodyEdge,
    );

    // ── 3. WHEELS (before body so body covers wheel-arch tops) ───────────────
    // Wide SUV wheels — positions (top-view)
    for (final wp in <Offset>[
      Offset(cx - hw + 2, cy - hl * 0.52), // front-left
      Offset(cx + hw - 2, cy - hl * 0.52), // front-right
      Offset(cx - hw + 2, cy + hl * 0.44), // rear-left
      Offset(cx + hw - 2, cy + hl * 0.44), // rear-right
    ]) {
      _drawWheel(canvas, wp);
    }

    // ── 4. MAIN BODY ─────────────────────────────────────────────────────────
    final bodyRRect = _bodyRRect(cx, cy, hw, hl);

    // Base fill
    canvas.drawRRect(bodyRRect, Paint()..color = _bodyBase);

    // Metallic gradient (front lighter)
    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_bodyHi, _bodyMid, _bodyBase, _bodyEdge],
          stops: [0.0, 0.25, 0.7, 1.0],
        ).createShader(Rect.fromCenter(center: const Offset(cx, cy), width: hw * 2, height: hl * 2)),
    );

    // Side sheen (3D highlight from left)
    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-1, 0),
          end: const Alignment(1, 0),
          colors: [
            Colors.white.withOpacity(0.12),
            Colors.transparent,
            Colors.black.withOpacity(0.10),
          ],
        ).createShader(Rect.fromCenter(center: const Offset(cx, cy), width: hw * 2, height: hl * 2)),
    );

    // Outline
    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..color = _outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );

    // ── 5. GOLD BELT-LINE TRIM STRIP (signature Suburban accent) ─────────────
    for (final side in <double>[-1, 1]) {
      // Full-length gold stripe along each side
      final stripRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          cx + side * (hw - 5) - 3.5,
          cy - hl + 28,
          7,
          hl * 2 - 56,
        ),
        const Radius.circular(3),
      );
      canvas.drawRRect(stripRect, Paint()..color = _goldTrim);
      // Bright top highlight on the strip
      canvas.drawRRect(
        stripRect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_goldGlow.withOpacity(0.7), _goldTrim, _goldTrim.withOpacity(0.6)],
          ).createShader(stripRect.outerRect),
      );
    }

    // ── 6. PANORAMIC GLASS ROOF ──────────────────────────────────────────────
    const roofInset = 18.0;
    final roofRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        cx - hw + roofInset,
        cy - hl * 0.20,
        (hw - roofInset) * 2,
        hl * 0.68,
      ),
      const Radius.circular(5),
    );
    canvas.drawRRect(roofRect, Paint()..color = _glassColor);
    canvas.drawRRect(
      roofRect,
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-0.7, -0.7),
          end: const Alignment(0.5, 0.5),
          colors: [_glassHi.withOpacity(0.6), _glassColor, _glassColor.withOpacity(0.9)],
        ).createShader(roofRect.outerRect),
    );
    // Roof rail lines (gold)
    for (final side in <double>[-1, 1]) {
      canvas.drawLine(
        Offset(cx + side * (hw - roofInset - 2), cy - hl * 0.18),
        Offset(cx + side * (hw - roofInset - 2), cy + hl * 0.46),
        Paint()
          ..color = _goldTrim.withOpacity(0.6)
          ..strokeWidth = 2,
      );
    }

    // ── 7. WINDSHIELD ────────────────────────────────────────────────────────
    final windPath = Path()
      ..moveTo(cx - hw + 14, cy - hl + 28)
      ..lineTo(cx - hw + 20, cy - hl + 55)
      ..lineTo(cx + hw - 20, cy - hl + 55)
      ..lineTo(cx + hw - 14, cy - hl + 28)
      ..close();
    canvas.drawPath(windPath, Paint()..color = _glassColor);
    canvas.drawPath(
      windPath,
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-0.8, -0.8),
          end: const Alignment(0.5, 0.5),
          colors: [_glassHi.withOpacity(0.5), _glassColor],
        ).createShader(windPath.getBounds()),
    );

    // ── 8. REAR WINDOW ───────────────────────────────────────────────────────
    final rearPath = Path()
      ..moveTo(cx - hw + 14, cy + hl - 22)
      ..lineTo(cx - hw + 20, cy + hl - 45)
      ..lineTo(cx + hw - 20, cy + hl - 45)
      ..lineTo(cx + hw - 14, cy + hl - 22)
      ..close();
    canvas.drawPath(rearPath, Paint()..color = _glassColor);

    // ── 9. LED HEADLIGHTS (wide, rectangular — Suburban style) ───────────────
    for (final side in <double>[-1, 1]) {
      final hx = cx + side * (hw - 15);
      final hy = cy - hl + 10;
      // DRL strip
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(hx, hy), width: 26, height: 7), const Radius.circular(3)),
        Paint()..color = _ledWhite,
      );
      // Glow
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(hx, hy), width: 30, height: 10), const Radius.circular(5)),
        Paint()
          ..color = Colors.white.withOpacity(0.25)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      // Amber turn signal dot
      canvas.drawCircle(
        Offset(hx + side * 10, hy + 7),
        3,
        Paint()..color = const Color(0xFFFFAA00),
      );
    }

    // ── 10. FRONT GRILLE (wide bold bar) ─────────────────────────────────────
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy - hl + 18), width: hw * 1.2, height: 8),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFF080808),
    );
    // Grille center accent (gold chevron)
    canvas.drawRect(
      Rect.fromCenter(center: Offset(cx, cy - hl + 18), width: hw * 0.5, height: 3),
      Paint()..color = _goldTrim.withOpacity(0.7),
    );

    // ── 11. TAILLIGHT STRIP (continuous LED bar) ──────────────────────────────
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy + hl - 8), width: hw * 1.6, height: 5),
        const Radius.circular(2.5),
      ),
      Paint()..color = _tailRed,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy + hl - 8), width: hw * 1.6, height: 8),
        const Radius.circular(4),
      ),
      Paint()
        ..color = Colors.red.withOpacity(0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // ── 12. SIDE MIRRORS ─────────────────────────────────────────────────────
    for (final side in <double>[-1, 1]) {
      canvas.drawPath(
        Path()
          ..moveTo(cx + side * (hw + 1), cy - hl * 0.38)
          ..lineTo(cx + side * (hw + 9), cy - hl * 0.42)
          ..lineTo(cx + side * (hw + 9), cy - hl * 0.28)
          ..lineTo(cx + side * (hw + 1), cy - hl * 0.30)
          ..close(),
        Paint()..color = _bodyMid,
      );
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static RRect _bodyRRect(double cx, double cy, double hw, double hl) =>
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy), width: hw * 2, height: hl * 2),
        const Radius.circular(12),
      );

  static void _drawWheel(Canvas canvas, Offset center) {
    // Wide SUV tire (oval from top-down perspective)
    canvas.drawOval(
      Rect.fromCenter(center: center, width: 20, height: 30),
      Paint()..color = _wheelBlack,
    );
    // Rim face
    canvas.drawOval(
      Rect.fromCenter(center: center, width: 12, height: 19),
      Paint()..color = _rimDark,
    );
    // 5-spoke pattern
    for (int i = 0; i < 5; i++) {
      final angle = (i * 72 - 90) * (math.pi / 180.0);
      canvas.drawLine(
        center,
        center.translate(5 * math.cos(angle), 8 * math.sin(angle)),
        Paint()
          ..color = _rimSpoke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
    // Center cap (gold accent)
    canvas.drawCircle(center, 3, Paint()..color = _goldTrim);
  }
}
