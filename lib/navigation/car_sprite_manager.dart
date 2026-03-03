import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Pre-renders 36 isometric-3D car sprites (one per 10°) at startup.
/// Design: jet-black luxury sedan viewed from a front-right-top perspective.
/// Visible faces: top (roof), front bumper, right side panel — all shaded.
class CarSpriteManager {
  CarSpriteManager._();

  static const int _frames = 36;
  static const int _tileW = 80;
  static const int _tileH = 96;

  // ── Oblique-projection constants ────────────────────────────────────────
  // Camera is to the front-right, elevated ~40°.
  // screenX = cx + worldX * S + worldY * S * kDX
  // screenY = cy - worldY * S * kDY - worldZ * S * kZ
  static const double _sc = 7.8; // pixels per unit
  static const double _cx = 38.0; // canvas center X
  static const double _cy = 60.0; // canvas center Y
  static const double _kDx = 0.30; // depth → screen X shift
  static const double _kDy = 0.50; // depth → screen Y shift
  static const double _kZ = 1.00; // height → screen Y shift
  // Camera direction for depth sorting (normalized (kDX, kDY, kZ) ≈ (0.26, 0.43, 0.86))
  static const double _cdX = 0.260;
  static const double _cdY = 0.430;
  static const double _cdZ = 0.863;

  static final List<BitmapDescriptor> _icons = [];
  static bool _ready = false;
  static bool get isReady => _ready;

  /// Call once before any GPS updates (e.g. in initState).
  static Future<void> init() async {
    if (_ready) return;
    _icons.clear();
    for (int i = 0; i < _frames; i++) {
      final bearing = i * (360.0 / _frames);
      _icons.add(await _renderFrame(bearing));
    }
    _ready = true;
  }

  /// Returns the sprite closest to [bearingDeg] (snapped to nearest 10°).
  static BitmapDescriptor iconForBearing(double bearingDeg) {
    if (!_ready || _icons.isEmpty) return BitmapDescriptor.defaultMarker;
    final idx = ((bearingDeg % 360) / (360.0 / _frames)).round() % _frames;
    return _icons[idx];
  }

  // ── Projection helpers ───────────────────────────────────────────────────

  static Offset _proj(double wx, double wy, double wz) => Offset(
    _cx + wx * _sc + wy * _sc * _kDx,
    _cy - wy * _sc * _kDy - wz * _sc * _kZ,
  );

  static Offset _rp(double x, double y, double z, double rad) {
    final nx = x * math.cos(rad) + y * math.sin(rad);
    final ny = -x * math.sin(rad) + y * math.cos(rad);
    return _proj(nx, ny, z);
  }

  /// Signed 2D area (positive = CCW in screen coords = face is front-facing).
  static double _area2d(List<Offset> pts) {
    double a = 0;
    for (int i = 0; i < pts.length; i++) {
      final j = (i + 1) % pts.length;
      a += pts[i].dx * pts[j].dy - pts[j].dx * pts[i].dy;
    }
    return a;
  }

  /// Depth key for painter's algorithm: dot(rotated_centroid, camera_dir).
  static double _depth(List<List<double>> verts, double rad) {
    double ddx = 0, ddy = 0, ddz = 0;
    for (final v in verts) {
      final nx = v[0] * math.cos(rad) + v[1] * math.sin(rad);
      final ny = -v[0] * math.sin(rad) + v[1] * math.cos(rad);
      ddx += nx;
      ddy += ny;
      ddz += v[2];
    }
    final n = verts.length;
    return ddx / n * _cdX + ddy / n * _cdY + ddz / n * _cdZ;
  }

  // ── Render ───────────────────────────────────────────────────────────────

  static Future<BitmapDescriptor> _renderFrame(double bearing) async {
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(
      rec,
      Rect.fromLTWH(0, 0, _tileW.toDouble(), _tileH.toDouble()),
    );
    _drawCar(canvas, bearing);
    final pic = rec.endRecording();
    final img = await pic.toImage(_tileW, _tileH);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(
      Uint8List.view(bytes!.buffer),
      width: _tileW.toDouble(),
    );
  }

  static void _drawCar(ui.Canvas canvas, double bearing) {
    final rad = bearing * math.pi / 180;
    Offset p(double x, double y, double z) => _rp(x, y, z, rad);

    // ── Ground shadow ──────────────────────────────────────────────────────
    canvas.save();
    final sc = p(0, 0, 0);
    canvas.translate(sc.dx, sc.dy + 4);
    canvas.scale(1.4, 0.45);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 36, height: 36),
      Paint()
        ..color = const Color(0x55000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.restore();

    // ── Car geometry (car faces +Y = forward) ─────────────────────────────
    //  Lower body:  x∈[-1.0,1.0]  y∈[-1.9,1.9]  z∈[0.0, 0.60]
    //  Cabin:       x∈[-0.82,0.82]  y∈[-0.92,0.92]  z∈[0.60, 1.42]
    //  Hood (body-top, front section):  y∈[0.92,1.9] z=0.60
    //  Trunk (body-top, rear section):  y∈[-1.9,-0.92] z=0.60
    //  Roof (cabin top):  y∈[-0.92,0.92] z=1.42

    const double W = 1.00; // body half-width
    const double L = 1.90; // body half-length
    const double H = 0.60; // body height
    const double cw = 0.82; // cabin half-width
    const double cl = 0.92; // cabin half-length
    const double cch = 1.42; // cabin total height

    // --- Face colours (3D shading) ---
    const cBodyFront = Color(0xFF1E1E1E); // front bumper (+Y face)
    const cBodyBack = Color(0xFF0E0E0E); // rear (-Y face)
    const cBodyRight = Color(0xFF181818); // right side (+X face)
    const cBodyLeft = Color(0xFF141414); // left side (-X face)
    const cHoodTop = Color(0xFF242424); // hood top (front top section)
    const cTrunkTop = Color(0xFF1C1C1C); // trunk top
    const cCabinFront = Color(0xFF252525); // cabin front (windshield pillar)
    const cCabinBack = Color(0xFF131313); // cabin rear
    const cCabinRight = Color(0xFF1C1C1C); // cabin right
    const cCabinLeft = Color(0xFF181818); // cabin left
    const cRoof = Color(0xFF2B2B2B); // roof (brightest top face)

    // Collect faces as (vertices3d, color) then sort by depth + cull
    final faceList = <(List<List<double>>, Color)>[
      // ── Lower body faces ──────────────────────────────────────────────
      // Front face (+Y, normal=(0,1,0))
      (
        [
          [-W, L, 0],
          [W, L, 0],
          [W, L, H],
          [-W, L, H],
        ],
        cBodyFront,
      ),
      // Back face (-Y)
      (
        [
          [W, -L, 0],
          [-W, -L, 0],
          [-W, -L, H],
          [W, -L, H],
        ],
        cBodyBack,
      ),
      // Right face (+X)
      (
        [
          [W, L, 0],
          [W, -L, 0],
          [W, -L, H],
          [W, L, H],
        ],
        cBodyRight,
      ),
      // Left face (-X)
      (
        [
          [-W, -L, 0],
          [-W, L, 0],
          [-W, L, H],
          [-W, -L, H],
        ],
        cBodyLeft,
      ),
      // Bottom face — usually hidden, skip

      // ── Hood top (body top, front section) ────────────────────────────
      (
        [
          [-W, L, H],
          [W, L, H],
          [cw, cl, H],
          [-cw, cl, H],
        ],
        cHoodTop,
      ),
      // ── Trunk top (body top, rear section) ────────────────────────────
      (
        [
          [-cw, -cl, H],
          [cw, -cl, H],
          [W, -L, H],
          [-W, -L, H],
        ],
        cTrunkTop,
      ),

      // ── Cabin faces ───────────────────────────────────────────────────
      // Front (windshield area)
      (
        [
          [-cw, cl, H],
          [cw, cl, H],
          [cw, cl, cch],
          [-cw, cl, cch],
        ],
        cCabinFront,
      ),
      // Back (rear window area)
      (
        [
          [cw, -cl, H],
          [-cw, -cl, H],
          [-cw, -cl, cch],
          [cw, -cl, cch],
        ],
        cCabinBack,
      ),
      // Right
      (
        [
          [cw, cl, H],
          [cw, -cl, H],
          [cw, -cl, cch],
          [cw, cl, cch],
        ],
        cCabinRight,
      ),
      // Left
      (
        [
          [-cw, -cl, H],
          [-cw, cl, H],
          [-cw, cl, cch],
          [-cw, -cl, cch],
        ],
        cCabinLeft,
      ),
      // Roof
      (
        [
          [-cw, cl, cch],
          [cw, cl, cch],
          [cw, -cl, cch],
          [-cw, -cl, cch],
        ],
        cRoof,
      ),
    ];

    // Backface cull + painter sort
    final visible = <(List<Offset>, Color, double)>[];
    for (final (verts, color) in faceList) {
      final pts = verts.map((v) => p(v[0], v[1], v[2])).toList();
      if (_area2d(pts) > 0) {
        visible.add((pts, color, _depth(verts, rad)));
      }
    }
    // Sort: deepest (smallest depth) first
    visible.sort((a, b) => a.$3.compareTo(b.$3));

    // Draw body faces
    for (final (pts, color, _) in visible) {
      final path = Path();
      path.moveTo(pts[0].dx, pts[0].dy);
      for (int i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = color);
      // Edge highlight
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0x18FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.4,
      );
    }

    // ── Windshield (front glass) ───────────────────────────────────────────
    {
      final glassPts = [
        p(-cw, cl, H),
        p(cw, cl, H),
        p(cw * 0.9, cl, cch * 0.92),
        p(-cw * 0.9, cl, cch * 0.92),
      ];
      if (_area2d(glassPts) > 0) {
        final gp = Path()..moveTo(glassPts[0].dx, glassPts[0].dy);
        for (int i = 1; i < glassPts.length; i++) {
          gp.lineTo(glassPts[i].dx, glassPts[i].dy);
        }
        gp.close();
        canvas.drawPath(gp, Paint()..color = const Color(0xCC4A6FA8));
        // Glass glare streak
        final mn = glassPts[0];
        final mx = glassPts[1];
        canvas.drawLine(
          Offset(
            mn.dx + (mx.dx - mn.dx) * 0.15,
            mn.dy + (mx.dy - mn.dy) * 0.15,
          ),
          Offset(
            glassPts[3].dx + (glassPts[2].dx - glassPts[3].dx) * 0.15,
            glassPts[3].dy + (glassPts[2].dy - glassPts[3].dy) * 0.15,
          ),
          Paint()
            ..color = const Color(0x44FFFFFF)
            ..strokeWidth = 1.2,
        );
      }
    }

    // ── Rear window ────────────────────────────────────────────────────────
    {
      final rwPts = [
        p(cw, -cl, H),
        p(-cw, -cl, H),
        p(-cw * 0.9, -cl, cch * 0.90),
        p(cw * 0.9, -cl, cch * 0.90),
      ];
      if (_area2d(rwPts) > 0) {
        final rp2 = Path()..moveTo(rwPts[0].dx, rwPts[0].dy);
        for (int i = 1; i < rwPts.length; i++) {
          rp2.lineTo(rwPts[i].dx, rwPts[i].dy);
        }
        rp2.close();
        canvas.drawPath(rp2, Paint()..color = const Color(0x882A3D55));
      }
    }

    // ── Side windows ───────────────────────────────────────────────────────
    // Right side window
    {
      final swPts = [
        p(cw, cl, H + (cch - H) * 0.15),
        p(cw, -cl, H + (cch - H) * 0.15),
        p(cw, -cl * 0.8, cch * 0.90),
        p(cw, cl * 0.8, cch * 0.90),
      ];
      if (_area2d(swPts) > 0) {
        final sp = Path()..moveTo(swPts[0].dx, swPts[0].dy);
        for (int i = 1; i < swPts.length; i++) {
          sp.lineTo(swPts[i].dx, swPts[i].dy);
        }
        sp.close();
        canvas.drawPath(sp, Paint()..color = const Color(0xAA3A5070));
      }
    }
    // Left side window
    {
      final swPts = [
        p(-cw, -cl, H + (cch - H) * 0.15),
        p(-cw, cl, H + (cch - H) * 0.15),
        p(-cw, cl * 0.8, cch * 0.90),
        p(-cw, -cl * 0.8, cch * 0.90),
      ];
      if (_area2d(swPts) > 0) {
        final sp = Path()..moveTo(swPts[0].dx, swPts[0].dy);
        for (int i = 1; i < swPts.length; i++) {
          sp.lineTo(swPts[i].dx, swPts[i].dy);
        }
        sp.close();
        canvas.drawPath(sp, Paint()..color = const Color(0x882A3D55));
      }
    }

    // ── Chrome beltline trim (horizontal line at body-top height on sides) ─
    {
      final beltR1 = p(W, L, H);
      final beltR2 = p(W, -L, H);
      if ((beltR2.dx - beltR1.dx).abs() + (beltR2.dy - beltR1.dy).abs() > 1) {
        canvas.drawLine(
          beltR1,
          beltR2,
          Paint()
            ..color = const Color(0xFFC8A84A)
            ..strokeWidth = 1.0,
        );
      }
      final beltL1 = p(-W, -L, H);
      final beltL2 = p(-W, L, H);
      if ((beltL2.dx - beltL1.dx).abs() + (beltL2.dy - beltL1.dy).abs() > 1) {
        canvas.drawLine(
          beltL1,
          beltL2,
          Paint()
            ..color = const Color(0xFFC8A84A)
            ..strokeWidth = 1.0,
        );
      }
    }

    // ── Headlights (front, +Y face) ────────────────────────────────────────
    final hlPaint = Paint()..color = const Color(0xFFF0F8FF);
    final hlGlowPaint = Paint()
      ..color = const Color(0x66D0ECFF)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    for (final hsx in [-0.6, 0.6]) {
      final hc = p(hsx, L, H * 0.6);
      final check = _area2d([p(-W, L, 0), p(W, L, 0), p(W, L, H), p(-W, L, H)]);
      if (check > 0) {
        canvas.drawOval(
          Rect.fromCenter(center: hc, width: 5, height: 3),
          hlGlowPaint,
        );
        canvas.drawOval(
          Rect.fromCenter(center: hc, width: 4, height: 2.5),
          hlPaint,
        );
      }
    }

    // ── Tail lights (rear, -Y face) ────────────────────────────────────────
    final tlPaint = Paint()..color = const Color(0xFFFF1A1A);
    final tlGlowPaint = Paint()
      ..color = const Color(0x55FF1A1A)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    for (final tsx in [-0.6, 0.6]) {
      final tc = p(tsx, -L, H * 0.6);
      final check = _area2d([
        p(W, -L, 0),
        p(-W, -L, 0),
        p(-W, -L, H),
        p(W, -L, H),
      ]);
      if (check > 0) {
        canvas.drawOval(
          Rect.fromCenter(center: tc, width: 5, height: 3),
          tlGlowPaint,
        );
        canvas.drawOval(
          Rect.fromCenter(center: tc, width: 4, height: 2.5),
          tlPaint,
        );
      }
    }

    // ── Chrome grille (front face) ─────────────────────────────────────────
    {
      final g1 = p(-0.55, L, H * 0.3);
      final g2 = p(0.55, L, H * 0.3);
      final grCheck = _area2d([
        p(-W, L, 0),
        p(W, L, 0),
        p(W, L, H),
        p(-W, L, H),
      ]);
      if (grCheck > 0) {
        canvas.drawLine(
          g1,
          g2,
          Paint()
            ..color = const Color(0xFF888888)
            ..strokeWidth = 1.5,
        );
        canvas.drawLine(
          p(-0.55, L, H * 0.18),
          p(0.55, L, H * 0.18),
          Paint()
            ..color = const Color(0xFF666666)
            ..strokeWidth = 0.8,
        );
      }
    }

    // ── Wheels ─────────────────────────────────────────────────────────────
    // 4 wheels at corners: (±1.0, ±1.3, 0)
    const double wheelY = 1.3;
    const double wheelX = 1.0;
    for (final wy2 in [wheelY, -wheelY]) {
      for (final wx2 in [wheelX, -wheelX]) {
        _drawWheel(canvas, p(wx2, wy2, 0), p(wx2, wy2, 0.35), wx2, wy2, rad);
      }
    }

    // ── Roof antenna (tiny dot) ────────────────────────────────────────────
    final antBase = p(0, 0.15, cch);
    final antTip = p(0, 0.15, cch + 0.25);
    canvas.drawLine(
      antBase,
      antTip,
      Paint()
        ..color = const Color(0xFF888888)
        ..strokeWidth = 0.8,
    );
  }

  static void _drawWheel(
    ui.Canvas canvas,
    Offset bot,
    Offset top,
    double wx,
    double wy,
    double rad,
  ) {
    Offset p2(double x, double y, double z) => _rp(x, y, z, rad);

    // Tyre side face (the rectangular side of the cylinder visible on ±X)
    final tZ = 0.35; // wheel height
    final tW = 0.18; // tyre half-width
    final tR = 0.38; // tyre radius

    // For wheels on the right (+X) side, draw the outer face
    if (wx > 0) {
      final face = [
        p2(wx + tW, wy - tR, 0),
        p2(wx + tW, wy + tR, 0),
        p2(wx + tW, wy + tR, tZ),
        p2(wx + tW, wy - tR, tZ),
      ];
      if (_area2d(face) > 0) {
        // Tyre (black)
        final tp = Path()..moveTo(face[0].dx, face[0].dy);
        for (int i = 1; i < face.length; i++) {
          tp.lineTo(face[i].dx, face[i].dy);
        }
        tp.close();
        canvas.drawPath(tp, Paint()..color = const Color(0xFF0A0A0A));
        // Rim (silver circle inset)
        final rimC = p2(wx + tW + 0.01, wy, tZ * 0.5);
        canvas.drawOval(
          Rect.fromCenter(center: rimC, width: 4.5, height: 5.5),
          Paint()..color = const Color(0xFFAAAAAA),
        );
        canvas.drawOval(
          Rect.fromCenter(center: rimC, width: 2.5, height: 3),
          Paint()..color = const Color(0xFF333333),
        );
      }
    }

    // For wheels on the left (-X) side
    if (wx < 0) {
      final face = [
        p2(wx - tW, wy + tR, 0),
        p2(wx - tW, wy - tR, 0),
        p2(wx - tW, wy - tR, tZ),
        p2(wx - tW, wy + tR, tZ),
      ];
      if (_area2d(face) > 0) {
        final tp = Path()..moveTo(face[0].dx, face[0].dy);
        for (int i = 1; i < face.length; i++) {
          tp.lineTo(face[i].dx, face[i].dy);
        }
        tp.close();
        canvas.drawPath(tp, Paint()..color = const Color(0xFF0A0A0A));
        final rimC = p2(wx - tW - 0.01, wy, tZ * 0.5);
        canvas.drawOval(
          Rect.fromCenter(center: rimC, width: 4.5, height: 5.5),
          Paint()..color = const Color(0xFFAAAAAA),
        );
        canvas.drawOval(
          Rect.fromCenter(center: rimC, width: 2.5, height: 3),
          Paint()..color = const Color(0xFF333333),
        );
      }
    }

    // Tyre bottom strip (ground contact visible at z≈0)
    final bFace = [
      p2(wx - tW, wy - tR, 0.02),
      p2(wx + tW, wy - tR, 0.02),
      p2(wx + tW, wy + tR, 0.02),
      p2(wx - tW, wy + tR, 0.02),
    ];
    if (_area2d(bFace) > 0) {
      final bp = Path()..moveTo(bFace[0].dx, bFace[0].dy);
      for (int i = 1; i < bFace.length; i++) {
        bp.lineTo(bFace[i].dx, bFace[i].dy);
      }
      bp.close();
      canvas.drawPath(bp, Paint()..color = const Color(0xFF080808));
    }
  }
}
