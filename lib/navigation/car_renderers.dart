part of 'car_icon_loader.dart';


/// Sedan card image — no shadows
Future<ui.Image> _renderSedanCard(_CarPalette p) async {
  const double lw = 20, lh = 36;
  const double scale = 8.0;
  final int pw = (lw * scale).toInt();
  final int ph = (lh * scale).toInt();
  final double w = pw.toDouble();
  final double h = ph.toDouble();

  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  final cx = w / 2;
  final cy = h * 0.46;
  final bw = w * 0.30;
  final bh = h * 0.38;

  // Skip _groundShadow and _underCarShadow
  final body = _bodyPath(cx, cy, bw, bh);
  _paintBody(c, body, cx, cy, bw, bh, p);
  _bodyAO(c, body, cx, cy, bw, bh);
  _fenderCurves(c, cx, cy, bw, bh, p);
  _doorPanels(c, cx, cy, bw, bh);
  _doorHandles(c, cx, cy, bw, bh, p);
  _beltLine(c, cx, cy, bw, bh, p);
  _windshield(c, cx, cy, bw, bh);
  _rearGlass(c, cx, cy, bw, bh);
  _sideWindows(c, cx, cy, bw, bh);
  _closedRoof(c, cx, cy, bw, bh, p);
  _headlights(c, cx, cy, bw, bh);
  _taillights(c, cx, cy, bw, bh);
  _frontBumper(c, cx, cy, bw, bh, p);
  _rearBumper(c, cx, cy, bw, bh);
  _mirrors(c, cx, cy, bw, bh, p);
  _hoodCrease(c, cx, cy, bw, bh, p);

  final pic = rec.endRecording();
  return pic.toImage(pw, ph);
}

/// SUV card image — no shadows
Future<ui.Image> _renderSuvCard(_CarPalette p) async {
  const double lw = 24, lh = 40;
  const double scale = 8.0;
  final int pw = (lw * scale).toInt();
  final int ph = (lh * scale).toInt();
  final double w = pw.toDouble();
  final double h = ph.toDouble();

  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  final cx = w / 2;
  final cy = h * 0.46;
  final bw = w * 0.32;
  final bh = h * 0.40;

  // Skip _suvGroundShadow and _suvUnderCarShadow
  final body = _suvBodyPath(cx, cy, bw, bh);
  _paintBody(c, body, cx, cy, bw, bh, p);
  _bodyAO(c, body, cx, cy, bw, bh);
  _suvFenderCurves(c, cx, cy, bw, bh, p);
  _suvDoorPanels(c, cx, cy, bw, bh);
  _suvDoorHandles(c, cx, cy, bw, bh, p);
  _beltLine(c, cx, cy, bw, bh, p);
  _suvWindshield(c, cx, cy, bw, bh);
  _suvRearGlass(c, cx, cy, bw, bh);
  _suvSideWindows(c, cx, cy, bw, bh);
  _suvClosedRoof(c, cx, cy, bw, bh, p);
  _suvRoofRails(c, cx, cy, bw, bh, p);
  _suvHeadlights(c, cx, cy, bw, bh);
  _suvTaillights(c, cx, cy, bw, bh);
  _suvFrontBumper(c, cx, cy, bw, bh, p);
  _suvRearBumper(c, cx, cy, bw, bh);
  _suvMirrors(c, cx, cy, bw, bh, p);
  _suvHoodCrease(c, cx, cy, bw, bh, p);

  final pic = rec.endRecording();
  return pic.toImage(pw, ph);
}

// =================================================================
//  RENDERER — small 3D closed-roof car
// =================================================================
//  GOOGLE-MAPS-STYLE NAVIGATION CAR — used for the live driver marker
// =================================================================

// ═══════════════════════════════════════════════════════════════════
//  MODERN NAVIGATION CAR — Improved 3D design with realistic wheels
// ═══════════════════════════════════════════════════════════════════

/// Renders a Ford Fusion-style top-down 3D car.
/// FRONT = TOP of image. Fully opaque body (no transparency bleed).
/// Large visible wheels, smooth aerodynamic sedan proportions.
Future<Uint8List> _renderModernNavCarBytes() async {
  // Canvas: portrait — car faces UP = north = heading 0°
  const double w = 80.0;
  const double h = 160.0;
  final int pw = w.toInt();
  final int ph = h.toInt();

  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  final cx = w / 2;

  // ── Car metrics ──
  // front of car = top of canvas, rear = bottom
  const double bodyTop    = 12.0;   // front bumper Y
  const double bodyBot    = 148.0;  // rear bumper Y
  const double bodyMidY   = (bodyTop + bodyBot) / 2.0; // 80
  const double halfBodyW  = 26.0;   // half-width of main body
  const double roofTop    = 36.0;   // windshield base
  const double roofBot    = 112.0;  // rear glass base
  const double halfRoofW  = 20.0;

  // ── WHEEL geometry (large, clearly visible) ──
  const double wheelW     = 16.0;   // horizontal extent
  const double wheelH     = 11.0;   // vertical extent (foreshortened)
  const double fWheelY    = 38.0;   // front axle Y
  const double rWheelY    = 118.0;  // rear axle Y
  const double axleX      = halfBodyW + 3.0; // slightly outside body

  // ── PALETTE (fully opaque) ──
  const bodyDark    = Color(0xFF0F1A2E);
  const bodyMid     = Color(0xFF1A2D4A);
  const bodyLight   = Color(0xFF234068);
  const bodyHighl   = Color(0xFF2E5A8F);
  const glassColor  = Color(0xFF0E1D30);
  const glassRefl   = Color(0xFF1E3850);
  const tireColor   = Color(0xFF252528);
  const rimOuter    = Color(0xFF909AA8);
  const rimInner    = Color(0xFFC8CED6);
  const headlCol    = Color(0xFFD8ECFF);
  const tailCol     = Color(0xFFDD1010);
  const chromeCol   = Color(0xFFB0B8C4);

  // ── 1. GROUND SHADOW ──
  c.drawOval(
    Rect.fromCenter(
      center: Offset(cx, bodyBot + 8),
      width: halfBodyW * 2.8,
      height: 16,
    ),
    Paint()
      ..color = const Color(0x80000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
  );

  // ── 2. WHEELS (drawn BEFORE body so body overlaps slightly) ──
  void drawWheel(double wy, double side) {
    final wx = cx + side * axleX;
    // Tire
    c.drawOval(
      Rect.fromCenter(center: Offset(wx, wy), width: wheelW, height: wheelH),
      Paint()..color = tireColor..isAntiAlias = true,
    );
    // Rim
    c.drawOval(
      Rect.fromCenter(center: Offset(wx, wy), width: wheelW * 0.60, height: wheelH * 0.60),
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(wx - side * 1.5, wy - 1.5),
          wheelW * 0.32,
          [rimInner, rimOuter, const Color(0xFF505860)],
          [0.0, 0.55, 1.0],
        )
        ..isAntiAlias = true,
    );
    // Hub
    c.drawOval(
      Rect.fromCenter(center: Offset(wx, wy), width: wheelW * 0.22, height: wheelH * 0.22),
      Paint()..color = rimInner..isAntiAlias = true,
    );
    // Tire shine highlight
    c.drawOval(
      Rect.fromCenter(center: Offset(wx - side * 2, wy - 2), width: wheelW * 0.35, height: wheelH * 0.28),
      Paint()
        ..color = const Color(0x25FFFFFF)
        ..isAntiAlias = true,
    );
  }
  drawWheel(fWheelY, -1); drawWheel(fWheelY, 1);
  drawWheel(rWheelY, -1); drawWheel(rWheelY, 1);

  // ── 3. MAIN BODY — Ford Fusion: wider mid, tapering nose & tail ──
  final body = Path();
  // Front tip (pointed nose)
  body.moveTo(cx, bodyTop);
  // Right side going back
  body.cubicTo(
    cx + halfBodyW * 0.60, bodyTop,
    cx + halfBodyW * 1.05, bodyTop + 22,
    cx + halfBodyW, bodyMidY - 10,
  );
  body.cubicTo(
    cx + halfBodyW, bodyMidY + 10,
    cx + halfBodyW * 0.92, bodyBot - 20,
    cx + halfBodyW * 0.55, bodyBot,
  );
  body.lineTo(cx, bodyBot + 2);
  // Left side (mirror)
  body.lineTo(cx - halfBodyW * 0.55, bodyBot);
  body.cubicTo(
    cx - halfBodyW * 0.92, bodyBot - 20,
    cx - halfBodyW, bodyMidY + 10,
    cx - halfBodyW, bodyMidY - 10,
  );
  body.cubicTo(
    cx - halfBodyW * 1.05, bodyTop + 22,
    cx - halfBodyW * 0.60, bodyTop,
    cx, bodyTop,
  );
  body.close();

  // Body base fill — solid dark navy (FULLY OPAQUE)
  c.drawPath(body, Paint()..color = bodyMid..isAntiAlias = true);

  // Side-to-side metallic sheen
  c.drawPath(
    body,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx - halfBodyW, bodyMidY),
        Offset(cx + halfBodyW, bodyMidY),
        [bodyDark, bodyMid, bodyLight, bodyHighl, bodyLight, bodyMid, bodyDark],
        [0.0, 0.15, 0.35, 0.50, 0.65, 0.85, 1.0],
      )
      ..isAntiAlias = true,
  );

  // Front-to-rear depth shading
  c.drawPath(
    body,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, bodyTop),
        Offset(cx, bodyBot),
        [
          const Color(0x30406080),
          const Color(0x10203040),
          const Color(0x00000000),
          const Color(0x20000000),
          const Color(0x50000000),
        ],
        [0.0, 0.22, 0.45, 0.72, 1.0],
      )
      ..isAntiAlias = true,
  );

  // Outline
  c.drawPath(
    body,
    Paint()
      ..color = const Color(0xFF080E18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..isAntiAlias = true,
  );

  // ── 4. WINDSHIELD ──
  final wsPath = Path()
    ..moveTo(cx - halfRoofW * 1.05, roofTop + 2)
    ..lineTo(cx + halfRoofW * 1.05, roofTop + 2)
    ..lineTo(cx + halfRoofW * 0.90, roofTop + 18)
    ..lineTo(cx - halfRoofW * 0.90, roofTop + 18)
    ..close();
  c.drawPath(
    wsPath,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, roofTop + 2),
        Offset(cx, roofTop + 18),
        [glassRefl, glassColor],
      )
      ..isAntiAlias = true,
  );
  // reflection streak
  c.drawLine(
    Offset(cx - halfRoofW * 0.50, roofTop + 7),
    Offset(cx + halfRoofW * 0.40, roofTop + 7),
    Paint()
      ..color = const Color(0x3590C0F0)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round,
  );

  // ── 5. ROOF ──
  final roofPath = Path()
    ..moveTo(cx - halfRoofW * 0.90, roofTop + 18)
    ..lineTo(cx + halfRoofW * 0.90, roofTop + 18)
    ..lineTo(cx + halfRoofW * 0.85, roofBot)
    ..lineTo(cx - halfRoofW * 0.85, roofBot)
    ..close();
  c.drawPath(
    roofPath,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx - halfRoofW, bodyMidY),
        Offset(cx + halfRoofW, bodyMidY),
        [
          const Color(0xFF0E1624),
          const Color(0xFF162030),
          const Color(0xFF1E2E40),
          const Color(0xFF162030),
          const Color(0xFF0E1624),
        ],
        [0.0, 0.22, 0.50, 0.78, 1.0],
      )
      ..isAntiAlias = true,
  );
  // Roof highlight
  c.drawOval(
    Rect.fromCenter(center: Offset(cx, bodyMidY - 5), width: halfRoofW * 0.9, height: 12),
    Paint()
      ..color = const Color(0x14607898)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
  );

  // ── 6. REAR GLASS ──
  final rgPath = Path()
    ..moveTo(cx - halfRoofW * 0.85, roofBot)
    ..lineTo(cx + halfRoofW * 0.85, roofBot)
    ..lineTo(cx + halfRoofW * 0.70, roofBot + 16)
    ..lineTo(cx - halfRoofW * 0.70, roofBot + 16)
    ..close();
  c.drawPath(
    rgPath,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, roofBot),
        Offset(cx, roofBot + 16),
        [const Color(0xFF1E3050), glassColor],
      )
      ..isAntiAlias = true,
  );

  // ── 7. HEADLIGHTS — wide LED strip (Ford Fusion trapezoidal style) ──
  for (final side in [-1.0, 1.0]) {
    final hlX = cx + side * halfBodyW * 0.56;
    const hlY = bodyTop + 9.0;
    // outer glow
    c.drawOval(
      Rect.fromCenter(center: Offset(hlX, hlY), width: 18, height: 5),
      Paint()
        ..color = const Color(0x60C8E8FF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // main DRL strip
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(hlX, hlY), width: 14, height: 3.5),
        Radius.circular(2),
      ),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(hlX - 7, hlY),
          Offset(hlX + 7, hlY),
          [headlCol, Colors.white, headlCol],
        )
        ..isAntiAlias = true,
    );
  }

  // ── 8. TAILLIGHTS — bright red LED bar ──
  for (final side in [-1.0, 1.0]) {
    final tlX = cx + side * halfBodyW * 0.50;
    const tlY = bodyBot - 8.0;
    // outer glow
    c.drawOval(
      Rect.fromCenter(center: Offset(tlX, tlY), width: 18, height: 5),
      Paint()
        ..color = const Color(0x80FF1010)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // main taillight strip
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(tlX, tlY), width: 13, height: 3.5),
        Radius.circular(2),
      ),
      Paint()..color = tailCol..isAntiAlias = true,
    );
    // bright core
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(tlX, tlY), width: 6, height: 2),
        Radius.circular(1),
      ),
      Paint()..color = const Color(0xFFFF4444)..isAntiAlias = true,
    );
  }

  // ── 9. SIDE MIRRORS ──
  for (final side in [-1.0, 1.0]) {
    final mx = cx + side * (halfBodyW + 4);
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(mx, roofTop + 8), width: 9, height: 5),
        Radius.circular(2),
      ),
      Paint()..color = bodyLight..isAntiAlias = true,
    );
  }

  // ── 10. FRONT GRILLE ──
  c.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, bodyTop + 6), width: 22, height: 3),
      Radius.circular(1.5),
    ),
    Paint()..color = chromeCol..isAntiAlias = true,
  );

  // ── 11. CHARACTER LINE (body crease) ──
  for (final side in [-1.0, 1.0]) {
    final lx = cx + side * halfBodyW * 0.82;
    c.drawLine(
      Offset(lx, bodyTop + 28),
      Offset(lx, bodyBot - 24),
      Paint()
        ..color = const Color(0x20607898)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
  }

  // ── 12. HOOD CREASE ──
  c.drawLine(
    Offset(cx, bodyTop + 4),
    Offset(cx, roofTop),
    Paint()
      ..color = const Color(0x18506880)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );

  // ── ENCODE ──
  final pic = rec.endRecording();
  final img = await pic.toImage(pw, ph);
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

/// Top-down car: semi-square front, long roof, headlights flush on body,
/// 2 side windows per side, NO wheels.  FRONT = TOP of image (north = 0°).
Future<Uint8List> _renderGmapsNavCarBytes() async {
  // Canvas size — portrait, 5× scale for crisp rendering
  const double lw = 34.0, lh = 82.0;
  const double scale = 5.0;
  final int pw = (lw * scale).round();
  final int ph = (lh * scale).round();
  final double w = pw.toDouble();
  final double h = ph.toDouble();

  final rec = ui.PictureRecorder();
  final cvs = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  final cx = w * 0.5;

  // ── CAR PROPORTIONS ──────────────────────────────────────────────
  // front = top, rear = bottom
  final double front = h * 0.04;   // front bumper Y
  final double rear  = h * 0.96;   // rear bumper Y
  final double bw    = w * 0.42;   // body half-width

  // Vertical zones (fraction of total height)
  final double wsTop  = front + (rear - front) * 0.17; // windshield top
  final double wsBot  = front + (rear - front) * 0.28; // windshield bottom / roof start
  // Rear glass pushed far back for long roof
  final double rgTop  = front + (rear - front) * 0.70; // rear glass top (long roof)
  final double rgBot  = front + (rear - front) * 0.84; // rear glass bottom

  // ── 0. DROP SHADOW ───────────────────────────────────────────────
  cvs.drawOval(
    Rect.fromCenter(
      center: Offset(cx, (front + rear) * 0.5 + (rear - front) * 0.08),
      width: bw * 2.6, height: (rear - front) * 0.88,
    ),
    Paint()
      ..color = const Color(0x70000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
  );

  // ── 1. BODY PATH — semi-square front, rounded rear ───────────────
  //   Front corners: tight curve (semi-square)
  //   Rear corners: slightly wider / more rounded
  final double bodyMid = (front + rear) * 0.5;
  final body = Path();
  // front-left corner
  body.moveTo(cx - bw * 0.74, front + (rear - front) * 0.04);
  // front edge (nearly straight)
  body.lineTo(cx + bw * 0.74, front + (rear - front) * 0.04);
  // front-right corner — small radius curve
  body.cubicTo(
    cx + bw * 0.92, front + (rear - front) * 0.04,
    cx + bw * 1.00, front + (rear - front) * 0.10,
    cx + bw * 1.00, front + (rear - front) * 0.16,
  );
  // right side — straight down to rear quarter
  body.lineTo(cx + bw * 1.00, front + (rear - front) * 0.82);
  // rear-right corner — softer curve
  body.cubicTo(
    cx + bw * 1.00, front + (rear - front) * 0.90,
    cx + bw * 0.88, rear,
    cx + bw * 0.62, rear,
  );
  // rear edge
  body.lineTo(cx - bw * 0.62, rear);
  // rear-left corner
  body.cubicTo(
    cx - bw * 0.88, rear,
    cx - bw * 1.00, front + (rear - front) * 0.90,
    cx - bw * 1.00, front + (rear - front) * 0.82,
  );
  // left side
  body.lineTo(cx - bw * 1.00, front + (rear - front) * 0.16);
  // front-left corner
  body.cubicTo(
    cx - bw * 1.00, front + (rear - front) * 0.10,
    cx - bw * 0.92, front + (rear - front) * 0.04,
    cx - bw * 0.74, front + (rear - front) * 0.04,
  );
  body.close();

  // ── 2. BODY FILL — deep dark navy metallic ───────────────────────
  cvs.drawPath(
    body,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx - bw, bodyMid),
        Offset(cx + bw, bodyMid),
        const [
          Color(0xFF0A0C14),
          Color(0xFF131828),
          Color(0xFF1C253C),
          Color(0xFF131828),
          Color(0xFF0A0C14),
        ],
        [0.0, 0.18, 0.50, 0.82, 1.0],
      )
      ..isAntiAlias = true,
  );

  // Front-to-rear depth shading
  cvs.drawPath(
    body,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, front), Offset(cx, rear),
        const [
          Color(0x2C4A70A0),
          Color(0x10203858),
          Color(0x04000000),
          Color(0x18000000),
          Color(0x3C000000),
        ],
        [0.0, 0.18, 0.44, 0.72, 1.0],
      )
      ..isAntiAlias = true,
  );

  // ── 3. BODY OUTLINE ──────────────────────────────────────────────
  cvs.drawPath(
    body,
    Paint()
      ..color = const Color(0x60060810)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.022
      ..isAntiAlias = true,
  );

  // ── 4. SIDE AMBIENT OCCLUSION (edge darkening) ───────────────────
  cvs.save();
  cvs.clipPath(body);
  for (final s in [-1.0, 1.0]) {
    final x0 = cx + s * bw * 0.50;
    final x1 = cx + s * bw * 1.00;
    cvs.drawRect(
      Rect.fromLTWH(s < 0 ? x1 : x0, front, bw * 0.52, rear - front),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(x0, bodyMid), Offset(x1, bodyMid),
          const [Color(0x00000000), Color(0x48000000)],
        ),
    );
  }
  cvs.restore();

  // ── 5. HOOD HIGHLIGHT & CREASE ───────────────────────────────────
  cvs.save();
  cvs.clipPath(body);
  cvs.drawRect(
    Rect.fromLTRB(cx - bw * 0.60, front, cx + bw * 0.60, wsTop),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, front), Offset(cx, wsTop),
        const [Color(0x30507898), Color(0x04304058)],
      ),
  );
  cvs.restore();
  // Hood centre crease
  cvs.drawLine(
    Offset(cx, front + (rear - front) * 0.04),
    Offset(cx, wsTop),
    Paint()
      ..color = const Color(0x22508090)
      ..strokeWidth = w * 0.013
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );

  // ── 6. WINDSHIELD ────────────────────────────────────────────────
  final wsPath = Path()
    ..moveTo(cx - bw * 0.52, wsTop)
    ..lineTo(cx + bw * 0.52, wsTop)
    ..lineTo(cx + bw * 0.56, wsBot)
    ..lineTo(cx - bw * 0.56, wsBot)
    ..close();
  cvs.drawPath(
    wsPath,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, wsTop), Offset(cx, wsBot),
        const [Color(0xFF1C2E48), Color(0xFF243858)],
      )
      ..isAntiAlias = true,
  );
  // Windshield glare streak
  cvs.drawLine(
    Offset(cx - bw * 0.30, wsTop + (wsBot - wsTop) * 0.28),
    Offset(cx + bw * 0.28, wsTop + (wsBot - wsTop) * 0.28),
    Paint()
      ..color = const Color(0x2890C0E8)
      ..strokeWidth = h * 0.007
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );

  // ── 7. LONG ROOF (from wsBot to rgTop) ───────────────────────────
  final roofPath = Path()
    ..moveTo(cx - bw * 0.56, wsBot)
    ..lineTo(cx + bw * 0.56, wsBot)
    ..lineTo(cx + bw * 0.54, rgTop)
    ..lineTo(cx - bw * 0.54, rgTop)
    ..close();
  cvs.drawPath(
    roofPath,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx - bw * 0.5, bodyMid), Offset(cx + bw * 0.5, bodyMid),
        const [
          Color(0xFF0E1522),
          Color(0xFF182030),
          Color(0xFF20283E),
          Color(0xFF182030),
          Color(0xFF0E1522),
        ],
        [0.0, 0.22, 0.50, 0.78, 1.0],
      )
      ..isAntiAlias = true,
  );
  // Roof centre gloss
  cvs.drawOval(
    Rect.fromCenter(
      center: Offset(cx, wsBot + (rgTop - wsBot) * 0.45),
      width: bw * 0.36, height: (rgTop - wsBot) * 0.12,
    ),
    Paint()
      ..color = const Color(0x10608098)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
  );

  // ── 8. REAR GLASS ────────────────────────────────────────────────
  final rgPath = Path()
    ..moveTo(cx - bw * 0.54, rgTop)
    ..lineTo(cx + bw * 0.54, rgTop)
    ..lineTo(cx + bw * 0.50, rgBot)
    ..lineTo(cx - bw * 0.50, rgBot)
    ..close();
  cvs.drawPath(
    rgPath,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, rgTop), Offset(cx, rgBot),
        const [Color(0xCC20304E), Color(0xBB182840)],
      )
      ..isAntiAlias = true,
  );
  // Rear glass glare
  cvs.drawLine(
    Offset(cx - bw * 0.30, rgTop + (rgBot - rgTop) * 0.28),
    Offset(cx + bw * 0.28, rgTop + (rgBot - rgTop) * 0.28),
    Paint()
      ..color = const Color(0x1890C0E8)
      ..strokeWidth = h * 0.005
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );

  // ── 9. SIDE WINDOWS — 2 per side ─────────────────────────────────
  // Window dimensions: between belt line (inner edge) and body edge
  // Front window: wsBot → rgTop * 0.44 | Rear window: *0.50 → rgTop
  final double winInnerX = bw * 0.56; // inner edge (below roof edge)
  final double winOuterX = bw * 0.98; // outer edge (near body side)
  final double winGap    = (rear - front) * 0.012; // gap between windows

  // Front window Y range
  final double fwinTop = wsBot + (rear - front) * 0.006;
  final double fwinBot = wsBot + (rgTop - wsBot) * 0.46 - winGap * 0.5;
  // Rear window Y range
  final double rwinTop = wsBot + (rgTop - wsBot) * 0.46 + winGap * 0.5;
  final double rwinBot = rgTop - (rear - front) * 0.006;

  for (final s in [-1.0, 1.0]) {
    final double xIn  = cx + s * winInnerX;
    final double xOut = cx + s * winOuterX;

    // Front side window
    final fwin = Path()
      ..moveTo(xIn + s * 0, fwinTop)
      ..lineTo(xOut - s * 0, fwinTop)
      ..lineTo(xOut - s * 0, fwinBot)
      ..lineTo(xIn + s * 0, fwinBot)
      ..close();
    cvs.drawPath(
      fwin,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(xIn, fwinTop), Offset(xOut, fwinTop),
          s < 0
            ? const [Color(0xCC1C2C44), Color(0xCC243450)]
            : const [Color(0xCC243450), Color(0xCC1C2C44)],
        )
        ..isAntiAlias = true,
    );
    // front window glare
    cvs.drawLine(
      Offset(xIn + s * bw * 0.04, fwinTop + (fwinBot - fwinTop) * 0.22),
      Offset(xOut - s * bw * 0.08, fwinTop + (fwinBot - fwinTop) * 0.22),
      Paint()
        ..color = const Color(0x1890B8D8)
        ..strokeWidth = h * 0.005
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // Rear side window
    final rwin = Path()
      ..moveTo(xIn + s * 0, rwinTop)
      ..lineTo(xOut - s * 0, rwinTop)
      ..lineTo(xOut - s * 0, rwinBot)
      ..lineTo(xIn + s * 0, rwinBot)
      ..close();
    cvs.drawPath(
      rwin,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(xIn, rwinTop), Offset(xOut, rwinTop),
          s < 0
            ? const [Color(0xCC1C2C44), Color(0xCC243450)]
            : const [Color(0xCC243450), Color(0xCC1C2C44)],
        )
        ..isAntiAlias = true,
    );
    // rear window glare
    cvs.drawLine(
      Offset(xIn + s * bw * 0.04, rwinTop + (rwinBot - rwinTop) * 0.22),
      Offset(xOut - s * bw * 0.08, rwinTop + (rwinBot - rwinTop) * 0.22),
      Paint()
        ..color = const Color(0x1890B8D8)
        ..strokeWidth = h * 0.005
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // Pillar between windows (B-pillar)
    cvs.drawLine(
      Offset(xIn + s * bw * 0.06, fwinBot + winGap * 0.1),
      Offset(xIn + s * bw * 0.06, rwinTop - winGap * 0.1),
      Paint()
        ..color = const Color(0xFF0A0E18)
        ..strokeWidth = w * 0.028
        ..isAntiAlias = true,
    );
  }

  // ── 10. SIDE MIRRORS (flush against body near windshield) ─────────
  final double mirY = wsTop + (wsBot - wsTop) * 0.50;
  for (final s in [-1.0, 1.0]) {
    final mirPath = Path()
      ..moveTo(cx + s * bw * 0.84, mirY - (rear - front) * 0.022)
      ..lineTo(cx + s * bw * 1.04, mirY - (rear - front) * 0.008)
      ..lineTo(cx + s * bw * 1.04, mirY + (rear - front) * 0.016)
      ..lineTo(cx + s * bw * 0.84, mirY + (rear - front) * 0.016)
      ..close();
    cvs.drawPath(
      mirPath,
      Paint()..color = const Color(0xFF181C2A)..isAntiAlias = true,
    );
  }

  // ── 11. HEADLIGHTS — FLUSH on front face of body ─────────────────
  // Drawn INSIDE the body area at the front edge (not floating above)
  final double hlY     = front + (rear - front) * 0.055; // sits on front face
  final double hlInset = (rear - front) * 0.012;          // small inset from front edge
  for (final s in [-1.0, 1.0]) {
    final double hlCx = cx + s * bw * 0.52;
    final double hlW  = bw * 0.38;
    final double hlH  = (rear - front) * 0.028;

    // Glow (clipped to body)
    cvs.save();
    cvs.clipPath(body);
    cvs.drawOval(
      Rect.fromCenter(center: Offset(hlCx, hlY), width: hlW * 1.6, height: hlH * 4.0),
      Paint()
        ..color = const Color(0x50D8EEFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    cvs.restore();

    // Outer DRL strip
    cvs.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(hlCx + s * hlW * 0.06, hlY - hlInset),
          width: hlW * 0.90, height: hlH,
        ),
        const Radius.circular(3),
      ),
      Paint()
        ..color = const Color(0xFFE8F2FF)
        ..isAntiAlias = true,
    );
    // Inner accent strip
    cvs.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(hlCx - s * hlW * 0.10, hlY + hlInset),
          width: hlW * 0.54, height: hlH * 0.65,
        ),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0xFFCCDCF8)..isAntiAlias = true,
    );
  }

  // ── 12. REAR TAILLIGHTS — two square LED blocks ───────────────────
  // Each block sits near the rear corners, semi-square shape
  final double tlH   = (rear - front) * 0.068; // block height
  final double tlW   = bw * 0.52;               // block width
  final double tlCY  = rear - tlH * 0.60;       // vertical centre
  final double tlGap = bw * 0.08;               // gap from centre

  for (final s in [-1.0, 1.0]) {
    final double tlCX = cx + s * (tlGap * 0.5 + tlW * 0.5);

    // Outer glow
    cvs.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(tlCX, tlCY), width: tlW * 1.30, height: tlH * 1.50),
        const Radius.circular(5),
      ),
      Paint()
        ..color = const Color(0x55FF1010)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // Main LED block — dark red base with bright core gradient
    cvs.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(tlCX, tlCY), width: tlW, height: tlH),
        const Radius.circular(3),
      ),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(tlCX, tlCY - tlH * 0.5),
          Offset(tlCX, tlCY + tlH * 0.5),
          const [Color(0xFFFF2020), Color(0xFFAA0808)],
        )
        ..isAntiAlias = true,
    );

    // Bright inner highlight (gives LED depth)
    cvs.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(tlCX, tlCY - tlH * 0.12), width: tlW * 0.72, height: tlH * 0.38),
        const Radius.circular(2),
      ),
      Paint()
        ..color = const Color(0x70FF5050)
        ..isAntiAlias = true,
    );

    // Thin outline for definition
    cvs.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(tlCX, tlCY), width: tlW, height: tlH),
        const Radius.circular(3),
      ),
      Paint()
        ..color = const Color(0xFF6A0000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.012
        ..isAntiAlias = true,
    );
  }

  // ── 13. FRONT BUMPER DETAIL ───────────────────────────────────────
  cvs.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, front + (rear - front) * 0.025),
        width: bw * 0.78, height: (rear - front) * 0.016,
      ),
      const Radius.circular(2),
    ),
    Paint()..color = const Color(0xFF080A12)..isAntiAlias = true,
  );

  // ── 14. REAR BUMPER DETAIL ────────────────────────────────────────
  cvs.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, rear - (rear - front) * 0.015),
        width: bw * 1.10, height: (rear - front) * 0.016,
      ),
      const Radius.circular(2),
    ),
    Paint()..color = const Color(0xFF08090F)..isAntiAlias = true,
  );

  // ── ENCODE ────────────────────────────────────────────────────────
  final pic = rec.endRecording();
  final img = await pic.toImage(pw, ph);
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

/// Organic sedan body — tapered nose, wider at mid/rear (Google Maps style).
/// Kept for backward compat — new code uses inline body path in renderer.
Path _gmapsBodyPath(double cx, double cy, double w, double h) {
  final path = Path();
  final front = cy - h * 0.450;
  final rear = cy + h * 0.450;
  path.moveTo(cx, front);
  path.cubicTo(
    cx + w * 0.165,
    front,
    cx + w * 0.400,
    front + h * 0.120,
    cx + w * 0.415,
    cy - h * 0.050,
  );
  path.cubicTo(
    cx + w * 0.420,
    cy + h * 0.110,
    cx + w * 0.380,
    rear - h * 0.100,
    cx + w * 0.130,
    rear,
  );
  path.lineTo(cx - w * 0.130, rear);
  path.cubicTo(
    cx - w * 0.380,
    rear - h * 0.100,
    cx - w * 0.420,
    cy + h * 0.110,
    cx - w * 0.415,
    cy - h * 0.050,
  );
  path.cubicTo(
    cx - w * 0.400,
    front + h * 0.120,
    cx - w * 0.165,
    front,
    cx,
    front,
  );
  path.close();
  return path;
}

// =================================================================
//  LEGACY RENDERER — used only by card thumbnails (not the map marker)
// =================================================================

/// Renders the detailed 3D car as raw PNG bytes.
Future<Uint8List> _renderDetailedBytes(_CarPalette p) async {
  const double lw = 20, lh = 36;
  const double scale = 3.0;
  final int pw = (lw * scale).toInt();
  final int ph = (lh * scale).toInt();
  final double w = pw.toDouble();
  final double h = ph.toDouble();

  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  final cx = w / 2;
  final cy = h * 0.46;
  final bw = w * 0.30;
  final bh = h * 0.38;

  final body = _bodyPath(cx, cy, bw, bh);
  _paintBody(c, body, cx, cy, bw, bh, p);
  _bodyAO(c, body, cx, cy, bw, bh);
  _fenderCurves(c, cx, cy, bw, bh, p);
  _doorPanels(c, cx, cy, bw, bh);
  _doorHandles(c, cx, cy, bw, bh, p);
  _beltLine(c, cx, cy, bw, bh, p);
  _windshield(c, cx, cy, bw, bh);
  _rearGlass(c, cx, cy, bw, bh);
  _sideWindows(c, cx, cy, bw, bh);
  _closedRoof(c, cx, cy, bw, bh, p);
  _headlights(c, cx, cy, bw, bh);
  _taillights(c, cx, cy, bw, bh);
  _frontBumper(c, cx, cy, bw, bh, p);
  _rearBumper(c, cx, cy, bw, bh);
  _mirrors(c, cx, cy, bw, bh, p);
  _hoodCrease(c, cx, cy, bw, bh, p);

  final pic = rec.endRecording();
  final img = await pic.toImage(pw, ph);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

/// Renders the SUV as raw PNG bytes (used by iOS rotation and loadForRideBytes).
Future<Uint8List> _renderSuvBytes(_CarPalette p) async {
  const double lw = 24, lh = 40;
  const double scale = 3.0;
  final int pw = (lw * scale).toInt();
  final int ph = (lh * scale).toInt();
  final double w = pw.toDouble();
  final double h = ph.toDouble();

  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  final cx = w / 2;
  final cy = h * 0.46;
  final bw = w * 0.32;
  final bh = h * 0.40;

  final body = _suvBodyPath(cx, cy, bw, bh);
  _paintBody(c, body, cx, cy, bw, bh, p);
  _bodyAO(c, body, cx, cy, bw, bh);
  _suvFenderCurves(c, cx, cy, bw, bh, p);
  _suvDoorPanels(c, cx, cy, bw, bh);
  _suvDoorHandles(c, cx, cy, bw, bh, p);
  _beltLine(c, cx, cy, bw, bh, p);
  _suvWindshield(c, cx, cy, bw, bh);
  _suvRearGlass(c, cx, cy, bw, bh);
  _suvSideWindows(c, cx, cy, bw, bh);
  _suvClosedRoof(c, cx, cy, bw, bh, p);
  _suvRoofRails(c, cx, cy, bw, bh, p);
  _suvHeadlights(c, cx, cy, bw, bh);
  _suvTaillights(c, cx, cy, bw, bh);
  _suvFrontBumper(c, cx, cy, bw, bh, p);
  _suvRearBumper(c, cx, cy, bw, bh);
  _suvMirrors(c, cx, cy, bw, bh, p);
  _suvHoodCrease(c, cx, cy, bw, bh, p);

  final pic = rec.endRecording();
  final img = await pic.toImage(pw, ph);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  final pixelBytes = bytes!.buffer.asUint8List();
  return pixelBytes;
}

// ── SUV Ground shadow ──────────────────────────────────────────────

void _suvGroundShadow(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  c.drawOval(
    Rect.fromCenter(
      center: Offset(cx + bw * 0.04, cy + bh * 0.18),
      width: bw * 2.90,
      height: bh * 2.40,
    ),
    Paint()
      ..color = const Color(0x34000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 26),
  );
  c.drawOval(
    Rect.fromCenter(
      center: Offset(cx + bw * 0.02, cy + bh * 0.12),
      width: bw * 2.40,
      height: bh * 2.05,
    ),
    Paint()
      ..color = const Color(0x2A000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
  );
  c.drawOval(
    Rect.fromCenter(
      center: Offset(cx, cy + bh * 0.08),
      width: bw * 1.95,
      height: bh * 1.75,
    ),
    Paint()
      ..color = const Color(0x22000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
  );
}

// ── SUV Under-car darkness ─────────────────────────────────────────

void _suvUnderCarShadow(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  c.drawOval(
    Rect.fromCenter(
      center: Offset(cx, cy + bh * 0.04),
      width: bw * 1.60,
      height: bh * 1.50,
    ),
    Paint()
      ..color = const Color(0x32000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
  );
}

// ── SUV Body path (boxy, wide, squared) ────────────────────────────

Path _suvBodyPath(double cx, double cy, double bw, double bh) {
  final p = Path();

  // Front nose — semi-oval rounded SUV front
  p.moveTo(cx - bw * 0.74, cy - bh * 0.94);
  p.cubicTo(
    cx - bw * 0.35,
    cy - bh * 1.02,
    cx + bw * 0.35,
    cy - bh * 1.02,
    cx + bw * 0.74,
    cy - bh * 0.94,
  );
  // Right front fender — semi-oval corner
  p.cubicTo(
    cx + bw * 0.94,
    cy - bh * 0.88,
    cx + bw * 1.05,
    cy - bh * 0.58,
    cx + bw * 1.04,
    cy - bh * 0.14,
  );
  // Right side — gently curved
  p.cubicTo(
    cx + bw * 1.03,
    cy + bh * 0.10,
    cx + bw * 1.03,
    cy + bh * 0.30,
    cx + bw * 1.04,
    cy + bh * 0.48,
  );
  // Right rear — semi-oval corner
  p.cubicTo(
    cx + bw * 1.05,
    cy + bh * 0.68,
    cx + bw * 0.94,
    cy + bh * 0.90,
    cx + bw * 0.72,
    cy + bh * 0.97,
  );
  // Rear — wide, slightly curved
  p.cubicTo(
    cx + bw * 0.38,
    cy + bh * 1.01,
    cx - bw * 0.38,
    cy + bh * 1.01,
    cx - bw * 0.72,
    cy + bh * 0.97,
  );
  // Left rear — semi-oval corner
  p.cubicTo(
    cx - bw * 0.94,
    cy + bh * 0.90,
    cx - bw * 1.05,
    cy + bh * 0.68,
    cx - bw * 1.04,
    cy + bh * 0.48,
  );
  // Left side — gently curved
  p.cubicTo(
    cx - bw * 1.03,
    cy + bh * 0.30,
    cx - bw * 1.03,
    cy + bh * 0.10,
    cx - bw * 1.04,
    cy - bh * 0.14,
  );
  // Left front fender — semi-oval corner
  p.cubicTo(
    cx - bw * 1.05,
    cy - bh * 0.58,
    cx - bw * 0.94,
    cy - bh * 0.88,
    cx - bw * 0.74,
    cy - bh * 0.94,
  );

  p.close();
  return p;
}

// ── SUV Fender curves ──────────────────────────────────────────────

void _suvFenderCurves(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  for (final s in [-1.0, 1.0]) {
    // Front fender arch — boxier
    final ff = Path()
      ..moveTo(cx + s * bw * 0.84, cy - bh * 0.92)
      ..cubicTo(
        cx + s * bw * 1.02,
        cy - bh * 0.82,
        cx + s * bw * 1.08,
        cy - bh * 0.52,
        cx + s * bw * 1.04,
        cy - bh * 0.20,
      );
    c.drawPath(
      ff,
      Paint()
        ..color = p.fenderHighlight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    c.drawPath(
      ff,
      Paint()
        ..color = const Color(0x10000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
        ..isAntiAlias = true,
    );

    // Rear fender arch — boxier
    final rf = Path()
      ..moveTo(cx + s * bw * 1.02, cy + bh * 0.40)
      ..cubicTo(
        cx + s * bw * 1.05,
        cy + bh * 0.62,
        cx + s * bw * 0.88,
        cy + bh * 0.90,
        cx + s * bw * 0.50,
        cy + bh * 0.98,
      );
    c.drawPath(
      rf,
      Paint()
        ..color = p.fenderHighlight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    c.drawPath(
      rf,
      Paint()
        ..color = const Color(0x0C000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
        ..isAntiAlias = true,
    );
  }
}

// ── SUV Door panels (3 rows: front, rear, cargo) ───────────────────

void _suvDoorPanels(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  for (final s in [-1.0, 1.0]) {
    final x = cx + s * bw;

    // Front door outline
    final fd = Path()
      ..moveTo(x * 0.97 + cx * 0.03, cy - bh * 0.40)
      ..lineTo(x * 0.96 + cx * 0.04, cy - bh * 0.04)
      ..lineTo(x * 0.95 + cx * 0.05, cy - bh * 0.04);
    c.drawPath(
      fd,
      Paint()
        ..color = const Color(0x18000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..isAntiAlias = true,
    );

    // Rear door outline
    final rd = Path()
      ..moveTo(x * 0.96 + cx * 0.04, cy - bh * 0.04)
      ..lineTo(x * 0.96 + cx * 0.04, cy + bh * 0.32)
      ..lineTo(x * 0.95 + cx * 0.05, cy + bh * 0.32);
    c.drawPath(
      rd,
      Paint()
        ..color = const Color(0x18000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..isAntiAlias = true,
    );

    // Cargo area divider line
    c.drawLine(
      Offset(cx + s * bw * 0.90, cy + bh * 0.38),
      Offset(cx + s * bw * 0.92, cy + bh * 0.38),
      Paint()
        ..color = const Color(0x16000000)
        ..strokeWidth = 2.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
        ..isAntiAlias = true,
    );

    // Door crease shadow
    c.drawLine(
      Offset(cx + s * bw * 0.92, cy - bh * 0.36),
      Offset(cx + s * bw * 0.90, cy + bh * 0.36),
      Paint()
        ..color = const Color(0x14000000)
        ..strokeWidth = 2.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)
        ..isAntiAlias = true,
    );

    // B-pillar
    c.drawLine(
      Offset(cx + s * bw * 0.92, cy - bh * 0.08),
      Offset(cx + s * bw * 0.94, cy + bh * 0.02),
      Paint()
        ..color = const Color(0xFFBEC3CA)
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    c.drawLine(
      Offset(cx + s * bw * 0.92, cy - bh * 0.08),
      Offset(cx + s * bw * 0.94, cy + bh * 0.02),
      Paint()
        ..color = const Color(0x18000000)
        ..strokeWidth = 5.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // C-pillar (between rear window and cargo)
    c.drawLine(
      Offset(cx + s * bw * 0.88, cy + bh * 0.26),
      Offset(cx + s * bw * 0.90, cy + bh * 0.34),
      Paint()
        ..color = const Color(0xFFBEC3CA)
        ..strokeWidth = 2.8
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    c.drawLine(
      Offset(cx + s * bw * 0.88, cy + bh * 0.26),
      Offset(cx + s * bw * 0.90, cy + bh * 0.34),
      Paint()
        ..color = const Color(0x14000000)
        ..strokeWidth = 4.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
  }
}

// ── SUV Door handles ───────────────────────────────────────────────

void _suvDoorHandles(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  for (final s in [-1.0, 1.0]) {
    final hx = cx + s * bw * 0.96;

    // Front handle
    final fh = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(hx, cy - bh * 0.18),
        width: bw * 0.03,
        height: bh * 0.06,
      ),
      Radius.circular(bw * 0.015),
    );
    c.drawRRect(fh, Paint()..color = p.handleFill);

    // Rear handle
    final rh = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(hx, cy + bh * 0.14),
        width: bw * 0.03,
        height: bh * 0.06,
      ),
      Radius.circular(bw * 0.015),
    );
    c.drawRRect(rh, Paint()..color = p.handleFill);
  }
}

// ── SUV Windshield (taller, more upright) ──────────────────────────

void _suvWindshield(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  final ws = Path();
  final wsTop = cy - bh * 0.50;
  final wsBot = cy - bh * 0.18;
  final wsTopW = bw * 0.56;
  final wsBotW = bw * 0.82;

  ws.moveTo(cx - wsTopW, wsTop);
  ws.cubicTo(
    cx - wsTopW * 0.4,
    wsTop - bh * 0.03,
    cx + wsTopW * 0.4,
    wsTop - bh * 0.03,
    cx + wsTopW,
    wsTop,
  );
  ws.lineTo(cx + wsBotW, wsBot);
  ws.cubicTo(
    cx + wsBotW * 0.3,
    wsBot + bh * 0.02,
    cx - wsBotW * 0.3,
    wsBot + bh * 0.02,
    cx - wsBotW,
    wsBot,
  );
  ws.close();

  c.drawPath(ws, Paint()..color = const Color(0xFF0A0C10));

  c.save();
  c.clipPath(ws);
  c.drawRect(
    Rect.fromLTWH(
      cx - wsBotW,
      wsTop - bh * 0.05,
      wsBotW * 2,
      wsBot - wsTop + bh * 0.1,
    ),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, wsTop),
        Offset(cx, wsBot),
        [
          const Color(0xFF141618),
          const Color(0xFF080A0C),
          const Color(0xFF101214),
        ],
        [0.0, 0.5, 1.0],
      ),
  );

  // Reflection streak
  final ref = Path()
    ..moveTo(cx - wsTopW * 0.75, wsTop + (wsBot - wsTop) * 0.12)
    ..lineTo(cx - wsTopW * 0.20, wsTop + (wsBot - wsTop) * 0.08)
    ..lineTo(cx + wsBotW * 0.15, wsBot - (wsBot - wsTop) * 0.18)
    ..lineTo(cx - wsBotW * 0.35, wsBot - (wsBot - wsTop) * 0.12)
    ..close();
  c.drawPath(
    ref,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx - wsTopW, wsTop),
        Offset(cx + wsBotW * 0.15, wsBot),
        [
          const Color(0x00FFFFFF),
          const Color(0x30FFFFFF),
          const Color(0x12FFFFFF),
          const Color(0x00FFFFFF),
        ],
        [0.0, 0.28, 0.62, 1.0],
      ),
  );
  c.restore();

  // Chrome frame
  c.drawPath(
    ws,
    Paint()
      ..color = const Color(0x38AAAAAA)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..isAntiAlias = true,
  );

  // Shadow below
  c.drawLine(
    Offset(cx - wsBotW * 0.9, wsBot + 1),
    Offset(cx + wsBotW * 0.9, wsBot + 1),
    Paint()
      ..color = const Color(0x14000000)
      ..strokeWidth = 3.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
      ..isAntiAlias = true,
  );
}

// ── SUV Rear glass (wider, more upright) ───────────────────────────

void _suvRearGlass(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  final rg = Path();
  final rgTop = cy + bh * 0.54;
  final rgBot = cy + bh * 0.72;
  final rgTopW = bw * 0.66;
  final rgBotW = bw * 0.48;

  rg.moveTo(cx - rgTopW, rgTop);
  rg.cubicTo(
    cx - rgTopW * 0.3,
    rgTop - bh * 0.02,
    cx + rgTopW * 0.3,
    rgTop - bh * 0.02,
    cx + rgTopW,
    rgTop,
  );
  rg.lineTo(cx + rgBotW, rgBot);
  rg.cubicTo(
    cx + rgBotW * 0.3,
    rgBot + bh * 0.03,
    cx - rgBotW * 0.3,
    rgBot + bh * 0.03,
    cx - rgBotW,
    rgBot,
  );
  rg.close();

  c.drawPath(rg, Paint()..color = const Color(0xFF0A0C10));

  c.save();
  c.clipPath(rg);
  c.drawLine(
    Offset(cx + rgTopW * 0.3, rgTop + (rgBot - rgTop) * 0.22),
    Offset(cx + rgBotW * 0.05, rgBot - (rgBot - rgTop) * 0.22),
    Paint()
      ..color = const Color(0x1AFFFFFF)
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );
  c.restore();

  c.drawPath(
    rg,
    Paint()
      ..color = const Color(0x30AAAAAA)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..isAntiAlias = true,
  );
}

// ── SUV Side windows (3 windows: front, rear, cargo quarter) ───────

void _suvSideWindows(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  for (final s in [-1.0, 1.0]) {
    // Front side window — taller
    final fw = Path()
      ..moveTo(cx + s * bw * 0.78, cy - bh * 0.36)
      ..lineTo(cx + s * bw * 0.94, cy - bh * 0.32)
      ..lineTo(cx + s * bw * 0.96, cy - bh * 0.06)
      ..lineTo(cx + s * bw * 0.80, cy - bh * 0.08)
      ..close();
    c.drawPath(fw, Paint()..color = const Color(0xFF080A0E));

    // Rear side window — taller
    final rw = Path()
      ..moveTo(cx + s * bw * 0.80, cy + bh * 0.02)
      ..lineTo(cx + s * bw * 0.96, cy + bh * 0.04)
      ..lineTo(cx + s * bw * 0.94, cy + bh * 0.28)
      ..lineTo(cx + s * bw * 0.78, cy + bh * 0.26)
      ..close();
    c.drawPath(rw, Paint()..color = const Color(0xFF080A0E));

    // Cargo quarter window — pushed further back
    final qw = Path()
      ..moveTo(cx + s * bw * 0.78, cy + bh * 0.34)
      ..lineTo(cx + s * bw * 0.92, cy + bh * 0.36)
      ..lineTo(cx + s * bw * 0.90, cy + bh * 0.50)
      ..lineTo(cx + s * bw * 0.76, cy + bh * 0.48)
      ..close();
    c.drawPath(qw, Paint()..color = const Color(0xFF080A0E));

    // Window trims
    for (final wp in [fw, rw, qw]) {
      c.drawPath(
        wp,
        Paint()
          ..color = const Color(0x18888888)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..isAntiAlias = true,
      );
    }
  }
}

// ── SUV Closed roof (wider, longer) ────────────────────────────────

void _suvClosedRoof(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  final roof = RRect.fromRectAndCorners(
    Rect.fromCenter(
      center: Offset(cx, cy + bh * 0.10),
      width: bw * 1.70,
      height: bh * 0.72,
    ),
    topLeft: Radius.circular(bw * 0.26),
    topRight: Radius.circular(bw * 0.26),
    bottomLeft: Radius.circular(bw * 0.20),
    bottomRight: Radius.circular(bw * 0.20),
  );

  c.drawRRect(
    roof,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx - bw * 0.78, cy),
        Offset(cx + bw * 0.78, cy),
        p.roofGrad,
        [0.0, 0.20, 0.50, 0.80, 1.0],
      ),
  );

  c.drawRRect(
    roof,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, cy - bh * 0.18),
        Offset(cx, cy + bh * 0.22),
        [const Color(0x22FFFFFF), const Color(0x00FFFFFF)],
        [0.0, 1.0],
      ),
  );

  c.drawRRect(
    roof,
    Paint()
      ..color = const Color(0x1C888888)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..isAntiAlias = true,
  );

  for (final s in [-1.0, 1.0]) {
    c.drawLine(
      Offset(cx + s * bw * 0.76, cy - bh * 0.14),
      Offset(cx + s * bw * 0.76, cy + bh * 0.20),
      Paint()
        ..color = const Color(0x10000000)
        ..strokeWidth = 3.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
        ..isAntiAlias = true,
    );
  }
}

// ── SUV Roof rails (chrome, characteristic SUV detail) ─────────────

void _suvRoofRails(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  for (final s in [-1.0, 1.0]) {
    final rx = cx + s * bw * 0.72;

    // Main rail bar
    c.drawLine(
      Offset(rx, cy - bh * 0.20),
      Offset(rx, cy + bh * 0.26),
      Paint()
        ..color = const Color(0xFF9A9EA6)
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // Rail highlight
    c.drawLine(
      Offset(rx - s * 0.5, cy - bh * 0.18),
      Offset(rx - s * 0.5, cy + bh * 0.24),
      Paint()
        ..color = const Color(0x30FFFFFF)
        ..strokeWidth = 0.8
        ..isAntiAlias = true,
    );

    // Rail shadow
    c.drawLine(
      Offset(rx + s * 0.5, cy - bh * 0.18),
      Offset(rx + s * 0.5, cy + bh * 0.24),
      Paint()
        ..color = const Color(0x18000000)
        ..strokeWidth = 1.2
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
        ..isAntiAlias = true,
    );

    // Support posts
    for (final py in [-0.14, 0.06, 0.20]) {
      c.drawLine(
        Offset(rx, cy + bh * py),
        Offset(rx + s * bw * 0.06, cy + bh * py),
        Paint()
          ..color = const Color(0xFF8A8E96)
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
    }
  }
}

// ── SUV Headlights (wider, more aggressive) ────────────────────────

void _suvHeadlights(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  final hlY = cy - bh * 0.92;

  for (final s in [-1.0, 1.0]) {
    final hlx = cx + s * bw * 0.58;

    // Housing — oval following SUV front contour
    c.drawOval(
      Rect.fromCenter(
        center: Offset(hlx, hlY),
        width: bw * 0.58,
        height: bh * 0.085,
      ),
      Paint()..color = const Color(0xFFCDD2DA),
    );
    c.drawOval(
      Rect.fromCenter(
        center: Offset(hlx, hlY),
        width: bw * 0.58,
        height: bh * 0.085,
      ),
      Paint()
        ..color = const Color(0x18000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..isAntiAlias = true,
    );

    // LED element — oval
    c.drawOval(
      Rect.fromCenter(
        center: Offset(hlx, hlY),
        width: bw * 0.44,
        height: bh * 0.052,
      ),
      Paint()..color = const Color(0xFFF5F0D8),
    );

    // Bright core — small oval
    c.drawOval(
      Rect.fromCenter(
        center: Offset(hlx, hlY),
        width: bw * 0.26,
        height: bh * 0.026,
      ),
      Paint()..color = const Color(0xFFFFFFF0),
    );

    // Warm glow halo
    c.drawCircle(
      Offset(hlx, hlY),
      bw * 0.24,
      Paint()
        ..color = const Color(0x18FFFDE0)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
  }
}

// ── SUV Taillights (wider, squarer) ────────────────────────────────

void _suvTaillights(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  final tlY = cy + bh * 0.90;

  for (final s in [-1.0, 1.0]) {
    final tlx = cx + s * bw * 0.60;

    // Housing — oval following SUV rear contour
    c.drawOval(
      Rect.fromCenter(
        center: Offset(tlx, tlY),
        width: bw * 0.54,
        height: bh * 0.078,
      ),
      Paint()..color = const Color(0xFF6A1010),
    );

    // LED strip — oval
    c.drawOval(
      Rect.fromCenter(
        center: Offset(tlx, tlY),
        width: bw * 0.42,
        height: bh * 0.048,
      ),
      Paint()..color = const Color(0xFFE82222),
    );

    // Core glow — small oval
    c.drawOval(
      Rect.fromCenter(
        center: Offset(tlx, tlY),
        width: bw * 0.24,
        height: bh * 0.024,
      ),
      Paint()..color = const Color(0xFFFF4848),
    );

    // Red glow halo
    c.drawCircle(
      Offset(tlx, tlY),
      bw * 0.22,
      Paint()
        ..color = const Color(0x24FF2020)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
  }

  // Rear light bar
  c.drawLine(
    Offset(cx - bw * 0.38, tlY),
    Offset(cx + bw * 0.38, tlY),
    Paint()
      ..color = const Color(0x50E82222)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );
}

// ── SUV Front bumper (wider, more aggressive) ──────────────────────

void _suvFrontBumper(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  // Air intake — wider
  c.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, cy - bh * 0.97),
        width: bw * 0.70,
        height: bh * 0.028,
      ),
      Radius.circular(bh * 0.012),
    ),
    Paint()..color = p.bumperAccent,
  );

  // Chrome accent
  c.drawLine(
    Offset(cx - bw * 0.62, cy - bh * 0.99),
    Offset(cx + bw * 0.62, cy - bh * 0.99),
    Paint()
      ..color = const Color(0x30FFFFFF)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );

  c.drawLine(
    Offset(cx - bw * 0.76, cy - bh * 0.92),
    Offset(cx + bw * 0.76, cy - bh * 0.92),
    Paint()
      ..color = const Color(0x10000000)
      ..strokeWidth = 2.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
      ..isAntiAlias = true,
  );
}

// ── SUV Rear bumper ────────────────────────────────────────────────

void _suvRearBumper(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  c.drawLine(
    Offset(cx - bw * 0.42, cy + bh * 0.93),
    Offset(cx + bw * 0.42, cy + bh * 0.93),
    Paint()
      ..color = const Color(0x1CFFFFFF)
      ..strokeWidth = 0.8
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );

  c.drawLine(
    Offset(cx - bw * 0.55, cy + bh * 0.97),
    Offset(cx + bw * 0.55, cy + bh * 0.97),
    Paint()
      ..color = const Color(0x14000000)
      ..strokeWidth = 2.5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)
      ..isAntiAlias = true,
  );
}

// ── SUV Mirrors (larger) ───────────────────────────────────────────

void _suvMirrors(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  for (final s in [-1.0, 1.0]) {
    final mx = cx + s * bw * 1.18;
    final my = cy - bh * 0.24;

    c.drawLine(
      Offset(cx + s * bw * 1.00, my + bh * 0.01),
      Offset(mx, my),
      Paint()
        ..color = p.mirrorArm
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    c.drawOval(
      Rect.fromCenter(
        center: Offset(mx, my),
        width: bw * 0.22,
        height: bw * 0.15,
      ),
      Paint()..color = p.mirrorBody,
    );
    c.drawOval(
      Rect.fromCenter(
        center: Offset(mx + s * bw * 0.02, my),
        width: bw * 0.14,
        height: bw * 0.09,
      ),
      Paint()..color = const Color(0xFF1A1E28),
    );
    c.drawOval(
      Rect.fromCenter(
        center: Offset(mx, my + bw * 0.04),
        width: bw * 0.24,
        height: bw * 0.12,
      ),
      Paint()
        ..color = const Color(0x14000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    c.drawOval(
      Rect.fromCenter(
        center: Offset(mx, my),
        width: bw * 0.22,
        height: bw * 0.15,
      ),
      Paint()
        ..color = const Color(0x20888888)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..isAntiAlias = true,
    );
  }
}

// ── SUV Hood crease ────────────────────────────────────────────────

void _suvHoodCrease(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  c.drawLine(
    Offset(cx, cy - bh * 0.95),
    Offset(cx, cy - bh * 0.46),
    Paint()
      ..color = p.crease
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );
  for (final s in [-1.0, 1.0]) {
    c.drawLine(
      Offset(cx + s * 1.5, cy - bh * 0.93),
      Offset(cx + s * 1.5, cy - bh * 0.48),
      Paint()
        ..color = const Color(0x08000000)
        ..strokeWidth = 1.0
        ..isAntiAlias = true,
    );
  }
}

// ── Ground shadow (multi-layer for realism) ───────────────────────

void _groundShadow(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  // Outermost diffuse shadow
  c.drawOval(
    Rect.fromCenter(
      center: Offset(cx + bw * 0.04, cy + bh * 0.18),
      width: bw * 2.80,
      height: bh * 2.35,
    ),
    Paint()
      ..color = const Color(0x32000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
  );
  // Mid shadow
  c.drawOval(
    Rect.fromCenter(
      center: Offset(cx + bw * 0.02, cy + bh * 0.12),
      width: bw * 2.30,
      height: bh * 2.00,
    ),
    Paint()
      ..color = const Color(0x28000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
  );
  // Tight contact
  c.drawOval(
    Rect.fromCenter(
      center: Offset(cx, cy + bh * 0.08),
      width: bw * 1.85,
      height: bh * 1.70,
    ),
    Paint()
      ..color = const Color(0x20000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
  );
}

// ── Under-car darkness ────────────────────────────────────────────

void _underCarShadow(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  c.drawOval(
    Rect.fromCenter(
      center: Offset(cx, cy + bh * 0.04),
      width: bw * 1.50,
      height: bh * 1.40,
    ),
    Paint()
      ..color = const Color(0x30000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
  );
}

// ── Body path (compact sedan) ─────────────────────────────────────

Path _bodyPath(double cx, double cy, double bw, double bh) {
  final p = Path();

  // Front nose — slightly rounded front corners
  p.moveTo(cx - bw * 0.72, cy - bh * 0.92);
  p.cubicTo(
    cx - bw * 0.40,
    cy - bh * 1.00,
    cx + bw * 0.40,
    cy - bh * 1.00,
    cx + bw * 0.72,
    cy - bh * 0.92,
  );
  // Right front fender — slight oval at corner
  p.cubicTo(
    cx + bw * 0.92,
    cy - bh * 0.88,
    cx + bw * 1.04,
    cy - bh * 0.54,
    cx + bw * 1.02,
    cy - bh * 0.12,
  );
  // Right waist
  p.cubicTo(
    cx + bw * 0.98,
    cy + bh * 0.08,
    cx + bw * 0.97,
    cy + bh * 0.22,
    cx + bw * 1.02,
    cy + bh * 0.42,
  );
  // Right rear — more squared
  p.cubicTo(
    cx + bw * 1.04,
    cy + bh * 0.64,
    cx + bw * 0.96,
    cy + bh * 0.88,
    cx + bw * 0.68,
    cy + bh * 0.95,
  );
  // Rear — flat/wide
  p.cubicTo(
    cx + bw * 0.38,
    cy + bh * 0.99,
    cx - bw * 0.38,
    cy + bh * 0.99,
    cx - bw * 0.68,
    cy + bh * 0.95,
  );
  // Left rear — more squared
  p.cubicTo(
    cx - bw * 0.96,
    cy + bh * 0.88,
    cx - bw * 1.04,
    cy + bh * 0.64,
    cx - bw * 1.02,
    cy + bh * 0.42,
  );
  // Left waist
  p.cubicTo(
    cx - bw * 0.97,
    cy + bh * 0.22,
    cx - bw * 0.98,
    cy + bh * 0.08,
    cx - bw * 1.02,
    cy - bh * 0.12,
  );
  // Left front fender — slight oval at corner
  p.cubicTo(
    cx - bw * 1.04,
    cy - bh * 0.54,
    cx - bw * 0.92,
    cy - bh * 0.88,
    cx - bw * 0.72,
    cy - bh * 0.92,
  );

  p.close();
  return p;
}

// ── White pearl paint ─────────────────────────────────────────────

void _paintBody(
  Canvas c,
  Path body,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  c.drawPath(body, Paint()..color = p.body);

  c.save();
  c.clipPath(body);
  final r = Rect.fromCenter(
    center: Offset(cx, cy),
    width: bw * 2.3,
    height: bh * 2.3,
  );

  // Left-right barrel shading
  c.drawRect(
    r,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx - bw * 1.05, cy),
        Offset(cx + bw * 1.05, cy),
        p.barrelGrad,
        [0.0, 0.10, 0.30, 0.50, 0.70, 0.90, 1.0],
      ),
  );

  // Hood-to-trunk gradient
  c.drawRect(
    r,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, cy - bh),
        Offset(cx, cy + bh),
        [
          const Color(0x20FFFFFF),
          const Color(0x0CFFFFFF),
          const Color(0x00000000),
          const Color(0x10000000),
          const Color(0x1A000000),
        ],
        [0.0, 0.18, 0.42, 0.72, 1.0],
      ),
  );

  // Diagonal specular streak (sunlight on hood)
  final spec = Path()
    ..moveTo(cx - bw * 0.50, cy - bh * 0.96)
    ..lineTo(cx - bw * 0.05, cy - bh * 0.96)
    ..lineTo(cx + bw * 0.40, cy - bh * 0.15)
    ..lineTo(cx - bw * 0.05, cy - bh * 0.15)
    ..close();
  c.drawPath(
    spec,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx - bw * 0.3, cy - bh),
        Offset(cx + bw * 0.2, cy - bh * 0.15),
        [
          const Color(0x00FFFFFF),
          const Color(0x25FFFFFF),
          const Color(0x0CFFFFFF),
          const Color(0x00FFFFFF),
        ],
        [0.0, 0.3, 0.65, 1.0],
      ),
  );

  c.restore();

  // Body outline
  c.drawPath(
    body,
    Paint()
      ..color = p.outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..isAntiAlias = true,
  );
}

// ── Ambient occlusion ─────────────────────────────────────────────

void _bodyAO(
  Canvas c,
  Path body,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  c.save();
  c.clipPath(body);
  // Inner shadow around perimeter
  for (var i = 0; i < 3; i++) {
    c.drawPath(
      body,
      Paint()
        ..color = const Color(0x0C000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (bw * 0.12) * (3 - i)
        ..maskFilter = MaskFilter.blur(BlurStyle.inner, 3.0 + i * 2)
        ..isAntiAlias = true,
    );
  }
  c.restore();
}

// ── Fender curves (highlight arches) ──────────────────────────────

void _fenderCurves(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  for (final s in [-1.0, 1.0]) {
    // Front fender arch (matches squared front)
    final ff = Path()
      ..moveTo(cx + s * bw * 0.78, cy - bh * 0.90)
      ..cubicTo(
        cx + s * bw * 0.98,
        cy - bh * 0.80,
        cx + s * bw * 1.06,
        cy - bh * 0.50,
        cx + s * bw * 1.02,
        cy - bh * 0.18,
      );
    c.drawPath(
      ff,
      Paint()
        ..color = p.fenderHighlight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    // Shadow side of fender
    c.drawPath(
      ff,
      Paint()
        ..color = const Color(0x10000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
        ..isAntiAlias = true,
    );

    // Rear fender arch (matches rounder rear)
    final rf = Path()
      ..moveTo(cx + s * bw * 1.00, cy + bh * 0.35)
      ..cubicTo(
        cx + s * bw * 1.03,
        cy + bh * 0.58,
        cx + s * bw * 0.80,
        cy + bh * 0.88,
        cx + s * bw * 0.42,
        cy + bh * 0.97,
      );
    c.drawPath(
      rf,
      Paint()
        ..color = p.fenderHighlight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    c.drawPath(
      rf,
      Paint()
        ..color = const Color(0x0C000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
        ..isAntiAlias = true,
    );
  }
}

// ── Door panels (detailed with shadow insets) ─────────────────────

void _doorPanels(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  for (final s in [-1.0, 1.0]) {
    final x = cx + s * bw;

    // Front door outline
    final fd = Path()
      ..moveTo(x * 0.97 + cx * 0.03, cy - bh * 0.38)
      ..lineTo(x * 0.96 + cx * 0.04, cy - bh * 0.02)
      ..lineTo(x * 0.95 + cx * 0.05, cy - bh * 0.02);
    c.drawPath(
      fd,
      Paint()
        ..color = const Color(0x18000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..isAntiAlias = true,
    );

    // Rear door outline
    final rd = Path()
      ..moveTo(x * 0.96 + cx * 0.04, cy - bh * 0.02)
      ..lineTo(x * 0.96 + cx * 0.04, cy + bh * 0.35)
      ..lineTo(x * 0.95 + cx * 0.05, cy + bh * 0.35);
    c.drawPath(
      rd,
      Paint()
        ..color = const Color(0x18000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..isAntiAlias = true,
    );

    // Door crease shadow (darker inset line)
    c.drawLine(
      Offset(cx + s * bw * 0.90, cy - bh * 0.34),
      Offset(cx + s * bw * 0.88, cy + bh * 0.32),
      Paint()
        ..color = const Color(0x14000000)
        ..strokeWidth = 2.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)
        ..isAntiAlias = true,
    );

    // B-pillar (vertical divider between front/rear doors)
    c.drawLine(
      Offset(cx + s * bw * 0.90, cy - bh * 0.06),
      Offset(cx + s * bw * 0.92, cy + bh * 0.04),
      Paint()
        ..color = const Color(0xFFBEC3CA)
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    // B-pillar shadow
    c.drawLine(
      Offset(cx + s * bw * 0.90, cy - bh * 0.06),
      Offset(cx + s * bw * 0.92, cy + bh * 0.04),
      Paint()
        ..color = const Color(0x18000000)
        ..strokeWidth = 5.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // Door lower shadow (bottom edge of each door)
    c.drawLine(
      Offset(cx + s * bw * 0.82, cy + bh * 0.36),
      Offset(cx + s * bw * 0.96, cy + bh * 0.36),
      Paint()
        ..color = const Color(0x12000000)
        ..strokeWidth = 2.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
        ..isAntiAlias = true,
    );
  }
}

// ── Door handles (chrome) ─────────────────────────────────────────

void _doorHandles(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  for (final s in [-1.0, 1.0]) {
    final hx = cx + s * bw * 0.94;

    // Front handle
    final fh = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(hx, cy - bh * 0.16),
        width: bw * 0.03,
        height: bh * 0.065,
      ),
      Radius.circular(bw * 0.015),
    );
    c.drawRRect(fh, Paint()..color = p.handleFill);
    c.drawRRect(
      fh,
      Paint()
        ..color = const Color(0x18000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..isAntiAlias = true,
    );

    // Rear handle
    final rh = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(hx, cy + bh * 0.16),
        width: bw * 0.03,
        height: bh * 0.065,
      ),
      Radius.circular(bw * 0.015),
    );
    c.drawRRect(rh, Paint()..color = p.handleFill);
    c.drawRRect(
      rh,
      Paint()
        ..color = const Color(0x18000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..isAntiAlias = true,
    );
  }
}

// ── Belt line (chrome strip along side) ───────────────────────────

void _beltLine(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  for (final s in [-1.0, 1.0]) {
    c.drawLine(
      Offset(cx + s * bw * 0.85, cy - bh * 0.38),
      Offset(cx + s * bw * 0.90, cy + bh * 0.34),
      Paint()
        ..color = p.beltHighlight
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
  }
}

// ── Windshield (dark glass, properly sized) ───────────────────────

void _windshield(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  final ws = Path();
  final wsTop = cy - bh * 0.42;
  final wsBot = cy - bh * 0.10;
  final wsTopW = bw * 0.52;
  final wsBotW = bw * 0.78;

  ws.moveTo(cx - wsTopW, wsTop);
  ws.cubicTo(
    cx - wsTopW * 0.4,
    wsTop - bh * 0.04,
    cx + wsTopW * 0.4,
    wsTop - bh * 0.04,
    cx + wsTopW,
    wsTop,
  );
  ws.lineTo(cx + wsBotW, wsBot);
  ws.cubicTo(
    cx + wsBotW * 0.3,
    wsBot + bh * 0.02,
    cx - wsBotW * 0.3,
    wsBot + bh * 0.02,
    cx - wsBotW,
    wsBot,
  );
  ws.close();

  // Very dark black glass
  c.drawPath(ws, Paint()..color = const Color(0xFF0A0C10));

  c.save();
  c.clipPath(ws);

  // Glass depth
  c.drawRect(
    Rect.fromLTWH(
      cx - wsBotW,
      wsTop - bh * 0.05,
      wsBotW * 2,
      wsBot - wsTop + bh * 0.1,
    ),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, wsTop),
        Offset(cx, wsBot),
        [
          const Color(0xFF141618),
          const Color(0xFF080A0C),
          const Color(0xFF101214),
        ],
        [0.0, 0.5, 1.0],
      ),
  );

  // Bright reflection streak
  final ref = Path()
    ..moveTo(cx - wsTopW * 0.75, wsTop + (wsBot - wsTop) * 0.12)
    ..lineTo(cx - wsTopW * 0.20, wsTop + (wsBot - wsTop) * 0.08)
    ..lineTo(cx + wsBotW * 0.15, wsBot - (wsBot - wsTop) * 0.18)
    ..lineTo(cx - wsBotW * 0.35, wsBot - (wsBot - wsTop) * 0.12)
    ..close();
  c.drawPath(
    ref,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx - wsTopW, wsTop),
        Offset(cx + wsBotW * 0.15, wsBot),
        [
          const Color(0x00FFFFFF),
          const Color(0x30FFFFFF),
          const Color(0x12FFFFFF),
          const Color(0x00FFFFFF),
        ],
        [0.0, 0.28, 0.62, 1.0],
      ),
  );
  c.restore();

  // Chrome frame
  c.drawPath(
    ws,
    Paint()
      ..color = const Color(0x38AAAAAA)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..isAntiAlias = true,
  );

  // Shadow below windshield
  c.drawLine(
    Offset(cx - wsBotW * 0.9, wsBot + 1),
    Offset(cx + wsBotW * 0.9, wsBot + 1),
    Paint()
      ..color = const Color(0x14000000)
      ..strokeWidth = 3.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
      ..isAntiAlias = true,
  );
}

// ── Rear glass ────────────────────────────────────────────────────

void _rearGlass(Canvas c, double cx, double cy, double bw, double bh) {
  final rg = Path();
  final rgTop = cy + bh * 0.38;
  final rgBot = cy + bh * 0.56;
  final rgTopW = bw * 0.62;
  final rgBotW = bw * 0.42;

  rg.moveTo(cx - rgTopW, rgTop);
  rg.cubicTo(
    cx - rgTopW * 0.3,
    rgTop - bh * 0.02,
    cx + rgTopW * 0.3,
    rgTop - bh * 0.02,
    cx + rgTopW,
    rgTop,
  );
  rg.lineTo(cx + rgBotW, rgBot);
  rg.cubicTo(
    cx + rgBotW * 0.3,
    rgBot + bh * 0.03,
    cx - rgBotW * 0.3,
    rgBot + bh * 0.03,
    cx - rgBotW,
    rgBot,
  );
  rg.close();

  c.drawPath(rg, Paint()..color = const Color(0xFF0A0C10));

  c.save();
  c.clipPath(rg);
  c.drawLine(
    Offset(cx + rgTopW * 0.3, rgTop + (rgBot - rgTop) * 0.22),
    Offset(cx + rgBotW * 0.05, rgBot - (rgBot - rgTop) * 0.22),
    Paint()
      ..color = const Color(0x1AFFFFFF)
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );
  c.restore();

  c.drawPath(
    rg,
    Paint()
      ..color = const Color(0x30AAAAAA)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..isAntiAlias = true,
  );

  // Shadow above rear glass
  c.drawLine(
    Offset(cx - rgTopW * 0.85, rgTop - 1),
    Offset(cx + rgTopW * 0.85, rgTop - 1),
    Paint()
      ..color = const Color(0x12000000)
      ..strokeWidth = 2.5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)
      ..isAntiAlias = true,
  );
}

// ── Side windows ──────────────────────────────────────────────────

void _sideWindows(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  for (final s in [-1.0, 1.0]) {
    // Front side window — bigger
    final fw = Path()
      ..moveTo(cx + s * bw * 0.78, cy - bh * 0.32)
      ..lineTo(cx + s * bw * 0.90, cy - bh * 0.28)
      ..lineTo(cx + s * bw * 0.92, cy - bh * 0.06)
      ..lineTo(cx + s * bw * 0.80, cy - bh * 0.08)
      ..close();
    c.drawPath(fw, Paint()..color = const Color(0xFF080A0E));

    // Rear side window — bigger
    final rw = Path()
      ..moveTo(cx + s * bw * 0.80, cy + bh * 0.04)
      ..lineTo(cx + s * bw * 0.92, cy + bh * 0.06)
      ..lineTo(cx + s * bw * 0.90, cy + bh * 0.24)
      ..lineTo(cx + s * bw * 0.78, cy + bh * 0.22)
      ..close();
    c.drawPath(rw, Paint()..color = const Color(0xFF080A0E));

    // Window trims
    for (final wp in [fw, rw]) {
      c.drawPath(
        wp,
        Paint()
          ..color = const Color(0x18888888)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..isAntiAlias = true,
      );
    }

    // Shadow at window sill
    c.drawLine(
      Offset(cx + s * bw * 0.84, cy + bh * 0.22),
      Offset(cx + s * bw * 0.90, cy + bh * 0.22),
      Paint()
        ..color = const Color(0x14000000)
        ..strokeWidth = 2.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
        ..isAntiAlias = true,
    );
  }
}

// ── Closed roof (solid, no sunroof hole) ──────────────────────────

void _closedRoof(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  // Full roof — covers the entire cabin area (bigger)
  final roof = RRect.fromRectAndCorners(
    Rect.fromCenter(
      center: Offset(cx, cy + bh * 0.01),
      width: bw * 1.58,
      height: bh * 0.40,
    ),
    topLeft: Radius.circular(bw * 0.30),
    topRight: Radius.circular(bw * 0.30),
    bottomLeft: Radius.circular(bw * 0.24),
    bottomRight: Radius.circular(bw * 0.24),
  );

  // Roof matching body color
  c.drawRRect(
    roof,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx - bw * 0.75, cy),
        Offset(cx + bw * 0.75, cy),
        p.roofGrad,
        [0.0, 0.20, 0.50, 0.80, 1.0],
      ),
  );

  // Top-down light reflection (broad)
  c.drawRRect(
    roof,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, cy - bh * 0.14),
        Offset(cx, cy + bh * 0.17),
        [const Color(0x22FFFFFF), const Color(0x00FFFFFF)],
        [0.0, 1.0],
      ),
  );

  // Roof edge trim
  c.drawRRect(
    roof,
    Paint()
      ..color = const Color(0x1C888888)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..isAntiAlias = true,
  );

  // Roof shadow on sides
  for (final s in [-1.0, 1.0]) {
    c.drawLine(
      Offset(cx + s * bw * 0.74, cy - bh * 0.10),
      Offset(cx + s * bw * 0.74, cy + bh * 0.14),
      Paint()
        ..color = const Color(0x10000000)
        ..strokeWidth = 3.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
        ..isAntiAlias = true,
    );
  }
}

// ── Headlights (properly integrated into body curve) ──────────────

void _headlights(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  final hlY = cy - bh * 0.90;

  for (final s in [-1.0, 1.0]) {
    final hlx = cx + s * bw * 0.56;

    // Housing — oval following front body curve
    c.drawOval(
      Rect.fromCenter(
        center: Offset(hlx, hlY),
        width: bw * 0.54,
        height: bh * 0.080,
      ),
      Paint()..color = const Color(0xFFCDD2DA),
    );
    // Housing inner shadow
    c.drawOval(
      Rect.fromCenter(
        center: Offset(hlx, hlY),
        width: bw * 0.54,
        height: bh * 0.080,
      ),
      Paint()
        ..color = const Color(0x18000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..isAntiAlias = true,
    );

    // LED element — warm white oval
    c.drawOval(
      Rect.fromCenter(
        center: Offset(hlx, hlY),
        width: bw * 0.40,
        height: bh * 0.048,
      ),
      Paint()..color = const Color(0xFFF5F0D8),
    );

    // Bright core — small oval
    c.drawOval(
      Rect.fromCenter(
        center: Offset(hlx, hlY),
        width: bw * 0.22,
        height: bh * 0.024,
      ),
      Paint()..color = const Color(0xFFFFFFF0),
    );

    // Warm glow halo
    c.drawCircle(
      Offset(hlx, hlY),
      bw * 0.22,
      Paint()
        ..color = const Color(0x18FFFDE0)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
  }
}

// ── Taillights (red LED, adapted to rear curve) ───────────────────

void _taillights(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  final tlY = cy + bh * 0.88;

  for (final s in [-1.0, 1.0]) {
    final tlx = cx + s * bw * 0.56;

    // Housing — oval following rear body curve
    c.drawOval(
      Rect.fromCenter(
        center: Offset(tlx, tlY),
        width: bw * 0.50,
        height: bh * 0.072,
      ),
      Paint()..color = const Color(0xFF6A1010),
    );

    // LED strip — oval
    c.drawOval(
      Rect.fromCenter(
        center: Offset(tlx, tlY),
        width: bw * 0.38,
        height: bh * 0.042,
      ),
      Paint()..color = const Color(0xFFE82222),
    );

    // Core glow — small oval
    c.drawOval(
      Rect.fromCenter(
        center: Offset(tlx, tlY),
        width: bw * 0.20,
        height: bh * 0.022,
      ),
      Paint()..color = const Color(0xFFFF4848),
    );

    // Red glow halo
    c.drawCircle(
      Offset(tlx, tlY),
      bw * 0.20,
      Paint()
        ..color = const Color(0x24FF2020)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
  }

  // Rear light bar connector
  c.drawLine(
    Offset(cx - bw * 0.34, tlY),
    Offset(cx + bw * 0.34, tlY),
    Paint()
      ..color = const Color(0x50E82222)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );
}

// ── Front bumper ──────────────────────────────────────────────────

void _frontBumper(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  // Air intake — wider for squared front
  c.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, cy - bh * 0.96),
        width: bw * 0.60,
        height: bh * 0.025,
      ),
      Radius.circular(bh * 0.012),
    ),
    Paint()..color = p.bumperAccent,
  );

  // Bumper chrome accent
  c.drawLine(
    Offset(cx - bw * 0.55, cy - bh * 0.98),
    Offset(cx + bw * 0.55, cy - bh * 0.98),
    Paint()
      ..color = const Color(0x30FFFFFF)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );

  // Bumper bottom shadow
  c.drawLine(
    Offset(cx - bw * 0.68, cy - bh * 0.90),
    Offset(cx + bw * 0.68, cy - bh * 0.90),
    Paint()
      ..color = const Color(0x10000000)
      ..strokeWidth = 2.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1)
      ..isAntiAlias = true,
  );
}

// ── Rear bumper ───────────────────────────────────────────────────

void _rearBumper(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
) {
  // Chrome strip
  c.drawLine(
    Offset(cx - bw * 0.38, tlY(cy, bh) + bh * 0.035),
    Offset(cx + bw * 0.38, tlY(cy, bh) + bh * 0.035),
    Paint()
      ..color = const Color(0x1CFFFFFF)
      ..strokeWidth = 0.8
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );

  // Bumper shadow
  c.drawLine(
    Offset(cx - bw * 0.48, cy + bh * 0.96),
    Offset(cx + bw * 0.48, cy + bh * 0.96),
    Paint()
      ..color = const Color(0x14000000)
      ..strokeWidth = 2.5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)
      ..isAntiAlias = true,
  );
}

double tlY(double cy, double bh) => cy + bh * 0.88;

// ── Side mirrors ──────────────────────────────────────────────────

void _mirrors(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  for (final s in [-1.0, 1.0]) {
    final mx = cx + s * bw * 1.16;
    final my = cy - bh * 0.22;

    // Arm
    c.drawLine(
      Offset(cx + s * bw * 0.98, my + bh * 0.01),
      Offset(mx, my),
      Paint()
        ..color = p.mirrorArm
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // Mirror body
    c.drawOval(
      Rect.fromCenter(
        center: Offset(mx, my),
        width: bw * 0.20,
        height: bw * 0.14,
      ),
      Paint()..color = p.mirrorBody,
    );
    // Mirror glass
    c.drawOval(
      Rect.fromCenter(
        center: Offset(mx + s * bw * 0.02, my),
        width: bw * 0.12,
        height: bw * 0.08,
      ),
      Paint()..color = const Color(0xFF1A1E28),
    );
    // Mirror shadow
    c.drawOval(
      Rect.fromCenter(
        center: Offset(mx, my + bw * 0.04),
        width: bw * 0.22,
        height: bw * 0.10,
      ),
      Paint()
        ..color = const Color(0x14000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    // Mirror edge
    c.drawOval(
      Rect.fromCenter(
        center: Offset(mx, my),
        width: bw * 0.20,
        height: bw * 0.14,
      ),
      Paint()
        ..color = const Color(0x20888888)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..isAntiAlias = true,
    );
  }
}

// ── Hood crease ───────────────────────────────────────────────────

void _hoodCrease(
  Canvas c,
  double cx,
  double cy,
  double bw,
  double bh,
  _CarPalette p,
) {
  c.drawLine(
    Offset(cx, cy - bh * 0.94),
    Offset(cx, cy - bh * 0.44),
    Paint()
      ..color = p.crease
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true,
  );
  // Shadow beside crease
  for (final s in [-1.0, 1.0]) {
    c.drawLine(
      Offset(cx + s * 1.5, cy - bh * 0.92),
      Offset(cx + s * 1.5, cy - bh * 0.46),
      Paint()
        ..color = const Color(0x08000000)
        ..strokeWidth = 1.0
        ..isAntiAlias = true,
    );
  }
}

